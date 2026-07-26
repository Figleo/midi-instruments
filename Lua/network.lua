-- Network: real-time note sync for multiplayer
-- Reliable delivery + jitter buffer for smooth remote playback

MidiMod              = MidiMod or {}
MidiMod.Network      = {}

local Network        = MidiMod.Network

local NET_STOP       = "MidiMod.Stop"
local NET_NOTES      = "MidiMod.Notes"
local NET_BUFF_START = "MidiMod.BuffStart"
local NET_BUFF_STOP  = "MidiMod.BuffStop"

local pcall          = pcall
local tonumber       = tonumber
local tostring       = tostring
local pairs          = pairs
local string_gmatch  = string.gmatch
local string_match   = string.match
local os_clock       = os.clock

-- === Jitter buffer ===
-- Delays incoming notes slightly to smooth out network jitter.
-- Adds JITTER_MS of latency but produces consistent rhythm.
local JITTER_MS      = 60
local _noteBuffer    = {}
local _noteBufLen    = 0

local function getNetTimeMs()
    return os_clock() * 1000
end

-- === Init ===

function Network.init()
    if SERVER then Network.initServer() end
    if CLIENT then Network.initClient() end
end

-- The charID a client is allowed to act as: the one it actually controls.
-- Never trust the charID on the wire - a modified client can put any value
-- there and silence other players, make notes come out of their instrument,
-- or claim arbitrary jam links. Returns nil for a client with no character,
-- in which case the message is dropped (it cannot be playing anyway).
local function senderCharID(client)
    local id = nil
    pcall(function() id = client.Character.ID end)
    return id
end

-- One frame's worth of notes is a few dozen chars. Anything larger is either
-- a bug or a client trying to make the server broadcast bulk data for it.
local MAX_NOTES_STR = 512

function Network.initServer()
    -- Relay notes from one client to all others
    Networking.Receive(NET_NOTES, function(message, client)
        -- Fields must be read in order even when discarded, or the read
        -- cursor desyncs from the message.
        message.ReadUInt16()
        local notesStr = message.ReadString()
        local instrId  = "accordion"
        pcall(function() instrId = message.ReadString() end)

        local charID = senderCharID(client)
        if not charID then return end
        if not notesStr or #notesStr > MAX_NOTES_STR then return end
        if not MidiMod.Instruments[instrId] then instrId = "accordion" end

        -- One message object, sent to every other client
        local broadcast = Networking.Start(NET_NOTES)
        broadcast.WriteUInt16(charID)
        broadcast.WriteString(notesStr)
        broadcast.WriteString(instrId)

        for _, c in pairs(Client.ClientList) do
            if c ~= client then
                Networking.Send(broadcast, c.Connection)
            end
        end
    end)

    -- Per-player stop: relay charID to other clients
    Networking.Receive(NET_STOP, function(message, client)
        message.ReadUInt16()
        local charID = senderCharID(client)
        if not charID then return end
        -- No client.Name here: it is an un-pcall'd property access sitting in
        -- front of the relay, and a throw would swallow the stop for everyone.
        MidiMod.DebugLog("Server: stop requested for char " .. tostring(charID))

        local broadcast = Networking.Start(NET_STOP)
        broadcast.WriteUInt16(charID)

        for _, c in pairs(Client.ClientList) do
            if c ~= client then
                Networking.Send(broadcast, c.Connection)
            end
        end

        -- Notify buff system that this character stopped playing
        Hook.Call("MidiMod.Server.BuffStop", charID)
    end)

    -- Buff notifications
    Networking.Receive(NET_BUFF_START, function(message, client)
        local charID    = message.ReadUInt16()
        local character = client.Character
        if character and character.ID == charID then
            Hook.Call("MidiMod.Server.BuffStart", charID, character)
        end
    end)

    Networking.Receive(NET_BUFF_STOP, function(message, client)
        message.ReadUInt16()
        local charID = senderCharID(client)
        if not charID then return end
        Hook.Call("MidiMod.Server.BuffStop", charID)
    end)
end

function Network.initClient()
    -- Receive streamed notes from other players
    Networking.Receive(NET_NOTES, function(message)
        local charID   = message.ReadUInt16()
        local notesStr = message.ReadString()
        local instrId  = "accordion"
        pcall(function() instrId = message.ReadString() end)

        Network.playStreamedNotes(charID, notesStr, instrId)
    end)

    -- Per-player stop received from server
    Networking.Receive(NET_STOP, function(message)
        local charID = message.ReadUInt16()
        MidiMod.DebugLog("Client: stop received for char " .. tostring(charID))

        if MidiMod.Player then
            MidiMod.Player.stopChar(charID)
        end
    end)
end

-- === Helpers ===

-- Queue notes into jitter buffer instead of playing immediately.
-- Format: "delta:note,vel;delta:note,vel;..." (delta in ms from batch start)
-- Backward compat: "note,vel" without delta prefix is treated as delta=0.
function Network.playStreamedNotes(charID, notesStr, instrId)
    if not MidiMod.SoundEngine then return end

    -- Never play our own stream back. On a listen server the host's own client
    -- is in Client.ClientList, so the host receives the notes it just sent and
    -- would play every note twice, 60ms apart through the jitter buffer.
    local ourID = nil
    pcall(function() ourID = Character.Controlled.ID end)
    if ourID and ourID == charID then return end

    local character = nil
    pcall(function() character = Entity.FindEntityByID(charID) end)

    local worldPos = nil
    if character then
        local _, currentItem = MidiMod.GetHeldInstrument(character)
        if currentItem then
            pcall(function() worldPos = currentItem.WorldPosition end)
        else
            pcall(function() worldPos = character.WorldPosition end)
        end
    end

    local receiveTime = getNetTimeMs()

    for part in string_gmatch(notesStr, "([^;]+)") do
        -- Try "delta:note,vel" first, fall back to "note,vel"
        local delta, note, vel = string_match(part, "(%d+):(%d+),(%d+)")
        if not delta then
            note, vel = string_match(part, "(%d+),(%d+)")
            delta = 0
        else
            delta = tonumber(delta)
        end

        if note and vel then
            _noteBufLen = _noteBufLen + 1
            _noteBuffer[_noteBufLen] = {
                playAt   = receiveTime + JITTER_MS + delta,
                note     = tonumber(note),
                vel      = tonumber(vel),
                charID   = charID,
                instrId  = instrId,
                worldPos = worldPos,
            }
        end
    end

    -- Safety cap: if buffer grows too large, something is wrong - flush it
    if _noteBufLen > 256 then
        Network.clearBuffer()
    end
end

-- Clear jitter buffer. No args = clear all; charID = clear for that player.
function Network.clearBuffer(charID)
    if _noteBufLen == 0 then return end
    if not charID then
        for i = 1, _noteBufLen do _noteBuffer[i] = nil end
        _noteBufLen = 0
        return
    end
    local kept = 0
    for i = 1, _noteBufLen do
        if _noteBuffer[i].charID ~= charID then
            kept = kept + 1
            _noteBuffer[kept] = _noteBuffer[i]
        end
    end
    for i = kept + 1, _noteBufLen do _noteBuffer[i] = nil end
    _noteBufLen = kept
end

-- Drain jitter buffer: play notes whose scheduled time has arrived
if CLIENT then
    Hook.Add("think", "MidiMod.Network.JitterPump", function()
        if _noteBufLen == 0 then return end

        local now  = getNetTimeMs()
        local kept = 0

        for i = 1, _noteBufLen do
            local entry = _noteBuffer[i]
            if entry.playAt <= now then
                if entry.vel == 0 then
                    if MidiMod.SoundEngine and MidiMod.SoundEngine.releaseNote then
                        pcall(MidiMod.SoundEngine.releaseNote, entry.note, entry.charID)
                    end
                else
                    pcall(function()
                        MidiMod.SoundEngine.playNote(
                            entry.note, entry.vel, entry.worldPos, entry.instrId, entry.charID)
                    end)
                end
            else
                kept = kept + 1
                _noteBuffer[kept] = entry
            end
        end

        for i = kept + 1, _noteBufLen do _noteBuffer[i] = nil end
        _noteBufLen = kept
    end)
end

-- Reliable delivery: a lost note is worse than a delayed note for music.
-- The jitter buffer absorbs timing variance from retries.
function Network.broadcastNotes(charID, notesStr, instrId)
    if Game.IsSingleplayer then return end

    local msg = Networking.Start(NET_NOTES)
    msg.WriteUInt16(charID)
    msg.WriteString(notesStr)
    msg.WriteString(instrId or "accordion")

    if SERVER then
        for _, c in pairs(Client.ClientList) do
            Networking.Send(msg, c.Connection)
        end
    else
        Networking.Send(msg)
    end
end

-- Buff notifications (sent once on play start/stop, not spammed)

function Network.notifyBuffStart(character)
    if Game.IsSingleplayer or not character then return end
    local charID = nil
    pcall(function() charID = character.ID end)
    if not charID then return end

    local msg = Networking.Start(NET_BUFF_START)
    msg.WriteUInt16(charID)
    Networking.Send(msg)
end

function Network.notifyBuffStop(character)
    if Game.IsSingleplayer or not character then return end
    local charID = nil
    pcall(function() charID = character.ID end)
    if not charID then return end

    local msg = Networking.Start(NET_BUFF_STOP)
    msg.WriteUInt16(charID)
    Networking.Send(msg)
end

-- === High-level requests ===

function Network.requestPlay(fileName, tempoMult)
    tempoMult = tempoMult or 1.0

    local character = Character.Controlled
    if not character or not MidiMod.IsHoldingInstrument(character) then
        MidiMod.Log("Not holding instrument!")
        return
    end

    if not MidiMod.Player then
        MidiMod.Log("Player module not loaded!")
        return
    end

    -- Stop current playback first
    Network.requestStop()

    local fullPath = fileName
    MidiMod.Log("Loading MIDI: " .. fullPath)

    MidiMod.MidiParser.parseAsync(
        fullPath,
        function(score)
            if not MidiMod.Player.loadScore(score, fullPath) then
                MidiMod.Log("Failed to load MIDI: " .. fullPath)
                return
            end
            MidiMod.Player.setTempo(tempoMult)
            if not Game.IsSingleplayer then
                MidiMod.Player.isStreamingHost = true
            end
            MidiMod.Player.play(character)
            -- Tell server we started playing (for buffs), only if player wants buffs
            if not Game.IsSingleplayer and MidiMod.BuffsEnabled then
                Network.notifyBuffStart(character)
            end
            MidiMod.Log("Started streaming MIDI!")
        end,
        function(err)
            MidiMod.Log("Failed to parse MIDI: " .. tostring(err))
        end
    )
end

function Network.requestStop(charID)
    -- Cancel any in-progress async parse
    if MidiMod.MidiParser then
        pcall(MidiMod.MidiParser.cancelAsync)
    end

    -- Resolve our charID BEFORE stopping - Player.stop() clears
    -- sourceCharacter. sourceCharacter is the more reliable source here:
    -- the usual caller is the death/incapacitated path in player.lua, and
    -- Character.Controlled is often already nil by then.
    if not charID and MidiMod.Player then
        pcall(function() charID = MidiMod.Player.sourceCharacter.ID end)
    end
    if not charID then
        pcall(function() charID = Character.Controlled.ID end)
    end

    -- Stop local playback unconditionally. Bailing out early on a missing
    -- charID used to leave Player.playing true with notes still sounding.
    if MidiMod.Player then
        MidiMod.Player.stop()
    end

    if Game.IsSingleplayer or not charID then return end

    -- Tell server (and other clients) we stopped
    local msg = Networking.Start(NET_STOP)
    msg.WriteUInt16(charID)

    if SERVER then
        for _, c in pairs(Client.ClientList) do
            Networking.Send(msg, c.Connection)
        end
    else
        Networking.Send(msg)
    end
end

MidiMod.Log("[Network] Loaded. Jitter buffer=" .. JITTER_MS .. "ms, per-player stop.")
