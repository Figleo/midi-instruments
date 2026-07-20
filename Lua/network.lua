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
local ipairs         = ipairs
local tconcat        = table.concat
local tinsert        = table.insert
local string_gmatch  = string.gmatch
local string_match   = string.match
local math_max       = math.max
local os_clock       = os.clock
local math_floor     = math.floor

-- ─── Jitter buffer ───
-- Delays incoming notes slightly to smooth out network jitter.
-- Adds JITTER_MS of latency but produces consistent rhythm.
local JITTER_MS      = 60
local _noteBuffer    = {}
local _noteBufLen    = 0

local function getNetTimeMs()
    return os_clock() * 1000
end

-- ─── Init ───

function Network.init()
    if SERVER then Network.initServer() end
    if CLIENT then Network.initClient() end
end

function Network.initServer()
    -- Relay notes from one client to all others
    Networking.Receive(NET_NOTES, function(message, client)
        local charID   = message.ReadUInt16()
        local notesStr = message.ReadString()
        local instrId  = "accordion"
        pcall(function() instrId = message.ReadString() end)

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
        local charID = message.ReadUInt16()
        MidiMod.DebugLog("Server: " .. client.Name .. " requests stop for char " .. tostring(charID))

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
        local charID = message.ReadUInt16()
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

-- ─── Helpers ───

-- Queue notes into jitter buffer instead of playing immediately.
-- Format: "delta:note,vel;delta:note,vel;..." (delta in ms from batch start)
-- Backward compat: "note,vel" without delta prefix is treated as delta=0.
function Network.playStreamedNotes(charID, notesStr, instrId)
    if not MidiMod.SoundEngine then return end

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

    if MidiMod.Player and MidiMod.Player.streamingCharacters then
        MidiMod.Player.streamingCharacters[charID] = os_clock()
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

    -- Safety cap: if buffer grows too large, something is wrong — flush it
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

-- ─── High-level requests ───

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

    if not charID then
        local ch = Character.Controlled
        if ch then charID = ch.ID else return end
    end

    -- Stop local playback
    if MidiMod.Player then
        MidiMod.Player.stop()
    end

    if Game.IsSingleplayer then return end

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
