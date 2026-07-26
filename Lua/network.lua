-- Network: real-time note sync for multiplayer
-- Reliable delivery + jitter buffer for smooth remote playback

MidiMod              = MidiMod or {}
MidiMod.Network      = {}

local Network        = MidiMod.Network

local NET_STOP       = "MidiMod.Stop"
-- Like NET_STOP but only silences: the performer is still playing, it just
-- jumped in its score. Keeps jam links and buffs alive. See Player.seek.
local NET_CUT        = "MidiMod.Cut"
local NET_NOTES      = "MidiMod.Notes"
local NET_BUFF_START = "MidiMod.BuffStart"
local NET_BUFF_STOP  = "MidiMod.BuffStop"
local NET_JAM        = "MidiMod.JamAnnounce"

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

-- Safety cap on the jitter buffer. Entries are queued per TARGET, not per
-- note: a leader with three mirrors turns one packet into four times the
-- entries, so a dense passage in a full band legitimately queues several
-- hundred. The old cap of 256 was below that, so a normal jam tripped the
-- flush routinely - and the flush drops queued note-offs, leaving notes
-- ringing for everyone. Sized well clear of legitimate traffic: tripping this
-- now means a sender is flooding, not that the band got big.
local NOTE_BUF_MAX   = 1024

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

    -- Seek: relay only. Deliberately does NOT call BuffStop - the performer
    -- is still playing, so its talent buffs must keep charging.
    Networking.Receive(NET_CUT, function(message, client)
        message.ReadUInt16()
        local charID = senderCharID(client)
        if not charID then return end

        local broadcast = Networking.Start(NET_CUT)
        broadcast.WriteUInt16(charID)

        for _, c in pairs(Client.ClientList) do
            if c ~= client then
                Networking.Send(broadcast, c.Connection)
            end
        end
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

    -- Jam announce: relay "who performs / who mirrors whom" to other clients.
    -- mirrorOf is a claim about somebody else's charID and stays as sent - the
    -- worst it can do is make a mirror follow the wrong leader, and only the
    -- announcing client's own instrument is affected.
    Networking.Receive(NET_JAM, function(message, client)
        message.ReadUInt16()
        local fileName = message.ReadString()
        local mirrorOf = message.ReadUInt16() -- 0 = performer, else leader charID
        local posSec   = message.ReadUInt16()
        local durSec   = message.ReadUInt16()

        local charID = senderCharID(client)
        if not charID then return end
        if not fileName or #fileName > 128 then return end

        -- "I mirror myself" would put the sender in everyone's jamMirrors as
        -- its own leader, so playStreamedNotes would build two targets with
        -- the same charID and play every note twice - and the second channel
        -- overwrites the first's uid, so the first never gets released.
        if mirrorOf == charID then mirrorOf = 0 end

        local broadcast = Networking.Start(NET_JAM)
        broadcast.WriteUInt16(charID)
        broadcast.WriteString(fileName)
        broadcast.WriteUInt16(mirrorOf)
        broadcast.WriteUInt16(posSec)
        broadcast.WriteUInt16(durSec)

        for _, c in pairs(Client.ClientList) do
            if c ~= client then
                Networking.Send(broadcast, c.Connection)
            end
        end
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

    -- A performer seeked: drop its sounding notes but leave the jam intact
    Networking.Receive(NET_CUT, function(message)
        local charID = message.ReadUInt16()

        -- Our own seek was already applied locally in Player.seek. On a listen
        -- server this comes back to us and would cut the notes we started
        -- after the jump. Same guard as playStreamedNotes.
        local ourID = nil
        pcall(function() ourID = Character.Controlled.ID end)
        if ourID and ourID == charID then return end

        if MidiMod.Player and MidiMod.Player.cutChar then
            MidiMod.Player.cutChar(charID)
        end
    end)

    -- Jam announce received: remember performers and who mirrors whom.
    -- Entries expire in Player.getPerformers / cleanup.
    Networking.Receive(NET_JAM, function(message)
        local charID   = message.ReadUInt16()
        local fileName = message.ReadString()
        local mirrorOf = message.ReadUInt16() -- 0 = performer, else leader charID
        local posSec   = message.ReadUInt16()
        local durSec   = message.ReadUInt16()

        if MidiMod.Player then
            if mirrorOf == 0 then
                MidiMod.Player.activePerformers[charID] = {
                    fileName   = fileName,
                    receivedAt = os_clock(),
                    -- Progress at the moment this announce was sent; mirrors
                    -- interpolate from receivedAt. See Player.getJamProgress.
                    posMs      = posSec * 1000,
                    durMs      = durSec * 1000,
                }
            else
                MidiMod.Player.jamMirrors[charID] = {
                    leaderID   = mirrorOf,
                    receivedAt = os_clock(),
                }
            end
        end
    end)
end

-- === Helpers ===

-- Queue notes into jitter buffer instead of playing immediately.
-- Format: "delta:note,vel;delta:note,vel;..." (delta in ms from batch start)
-- Backward compat: "note,vel" without delta prefix is treated as delta=0.
-- Every note is queued once for the sender and once per character mirroring
-- them (jam): same notes, but the mirror's instrument and position.
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

    -- Sender first, then everyone mirroring them
    local targets = { { id = charID, inst = instrId, pos = worldPos } }

    -- If we are mirroring this sender, add ourselves. The server relays jam
    -- announces to everyone *except* the sender, so our own announce never
    -- comes back to us: we are absent from our own jamMirrors map and the
    -- loop below will not find us. Same asymmetry the leader works around by
    -- duplicating onto mirrors locally in player.onThink - without this the
    -- mirror hears the leader's instrument but not its own.
    if ourID and MidiMod.Player and MidiMod.Player.jamLeaderID == charID then
        local ourChar = Character.Controlled
        if ourChar then
            local ourInst, ourItem = MidiMod.GetHeldInstrument(ourChar)
            if ourInst then
                local ourPos = nil
                pcall(function() ourPos = ourItem.WorldPosition end)
                targets[#targets + 1] = { id = ourID, inst = ourInst, pos = ourPos }
            end
        end
    end

    if MidiMod.Player and MidiMod.Player.getMirrorsOf then
        local mirrors = MidiMod.Player.getMirrorsOf(charID)
        if mirrors then
            for i = 1, #mirrors do
                local mID = mirrors[i]
                -- Skip ourselves (already added above) and the sender (a
                -- "mirrors itself" claim). Either would be a second target
                -- with a charID we already have, so every note would play
                -- twice and only the newer channel would ever be released.
                if mID ~= ourID and mID ~= charID then
                    local mChar = nil
                    pcall(function() mChar = Entity.FindEntityByID(mID) end)
                    if mChar then
                        local mInst, mItem = MidiMod.GetHeldInstrument(mChar)
                        if mInst then
                            local mPos = nil
                            pcall(function() mPos = mItem.WorldPosition end)
                            targets[#targets + 1] = { id = mID, inst = mInst, pos = mPos }
                        end
                    end
                end
            end
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
            for t = 1, #targets do
                local target = targets[t]
                _noteBufLen = _noteBufLen + 1
                _noteBuffer[_noteBufLen] = {
                    playAt   = receiveTime + JITTER_MS + delta,
                    note     = tonumber(note),
                    vel      = tonumber(vel),
                    charID   = target.id,
                    instrId  = target.inst,
                    worldPos = target.pos,
                }
            end
        end
    end

    -- Safety cap: if the buffer grows this far something is wrong - flush it.
    -- Logged rather than silent, because the flush drops pending note-offs and
    -- whatever is sounding right then will ring out.
    if _noteBufLen > NOTE_BUF_MAX then
        MidiMod.Log("Jitter buffer overflow (" .. _noteBufLen .. " entries) - flushing")
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

-- Cut a performer's sounding notes everywhere without ending the performance.
-- Used by Player.seek. NET_STOP would silence them too, but it also drops
-- every mirror out of the band and fires BuffStop on the server.
function Network.requestCut(charID)
    if Game.IsSingleplayer or not charID then return end

    local msg = Networking.Start(NET_CUT)
    msg.WriteUInt16(charID)

    if SERVER then
        for _, c in pairs(Client.ClientList) do
            Networking.Send(msg, c.Connection)
        end
    else
        Networking.Send(msg)
    end
end

-- Jam announce: performers say what they play (mirrorOf = 0), mirrors say
-- whom they follow. Sent every couple of seconds while active.
-- posSec/durSec carry the performer's progress so mirrors can show a progress
-- bar; seconds in a UInt16 is plenty (18 hours) and mirrors interpolate
-- locally between announces. Mirrors themselves send 0/0.
local function clampU16(v)
    v = tonumber(v) or 0
    if v < 0 then return 0 end
    if v > 65535 then return 65535 end
    return math.floor(v)
end

function Network.broadcastJamAnnounce(charID, fileName, mirrorOf, posSec, durSec)
    if Game.IsSingleplayer then return end

    local msg = Networking.Start(NET_JAM)
    msg.WriteUInt16(charID)
    msg.WriteString(fileName or "")
    msg.WriteUInt16(mirrorOf or 0)
    msg.WriteUInt16(clampU16(posSec))
    msg.WriteUInt16(clampU16(durSec))

    if SERVER then
        for _, c in pairs(Client.ClientList) do
            Networking.Send(msg, c.Connection)
        end
    else
        Networking.Send(msg)
    end
end

-- Buff notifications (sent once on play start/stop, not spammed)

-- On a listen server we ARE the server, and a message we send never comes
-- back to our own Networking.Receive. So the host has to call the buff hooks
-- directly - otherwise the host is the one player who never gets talent buffs
-- from playing, and never stops charging them either.

function Network.notifyBuffStart(character)
    if Game.IsSingleplayer or not character then return end
    local charID = nil
    pcall(function() charID = character.ID end)
    if not charID then return end

    if SERVER then
        Hook.Call("MidiMod.Server.BuffStart", charID, character)
        return
    end

    local msg = Networking.Start(NET_BUFF_START)
    msg.WriteUInt16(charID)
    Networking.Send(msg)
end

function Network.notifyBuffStop(character)
    if Game.IsSingleplayer or not character then return end
    local charID = nil
    pcall(function() charID = character.ID end)
    if not charID then return end

    if SERVER then
        Hook.Call("MidiMod.Server.BuffStop", charID)
        return
    end

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

-- Join another performer: mirror their note stream on our instrument.
-- No file needed on our side - the leader's streamed notes (NET_NOTES) are
-- the sheet music, every client duplicates them onto our instrument.
-- Returns true if mirroring started, false plus a reason otherwise.
function Network.requestJoin(leaderCharID)
    if Game.IsSingleplayer then return false, "singleplayer" end

    local character = Character.Controlled
    if not character or not MidiMod.IsHoldingInstrument(character) then
        MidiMod.Log("Not holding instrument!")
        return false, "noinstrument"
    end

    if not MidiMod.Player then
        MidiMod.Log("Player module not loaded!")
        return false, "nomodule"
    end

    local entry = MidiMod.Player.activePerformers[leaderCharID]
    if not entry then
        MidiMod.Log("Performer is no longer playing")
        return false, "gone"
    end

    -- Stop current playback / mirroring first
    Network.requestStop()

    MidiMod.Player.jamLeaderID = leaderCharID
    MidiMod.Log("Mirroring char " .. tostring(leaderCharID) .. " (" .. tostring(entry.fileName) .. ")")

    -- Announce immediately so other clients start duplicating the leader's
    -- stream onto us without waiting for the periodic announce.
    local ourID = nil
    pcall(function() ourID = character.ID end)
    if ourID then
        Network.broadcastJamAnnounce(ourID, "", leaderCharID, 0, 0)
    end

    if MidiMod.BuffsEnabled then
        Network.notifyBuffStart(character)
    end
    return true
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
        -- Our own send skips the server's Receive handler, which is where the
        -- buff system normally learns about a stop. On a listen server that
        -- would leave the host charging buffs forever after it stopped.
        Hook.Call("MidiMod.Server.BuffStop", charID)
        for _, c in pairs(Client.ClientList) do
            Networking.Send(msg, c.Connection)
        end
    else
        Networking.Send(msg)
    end
end

MidiMod.Log("[Network] Loaded. Jitter buffer=" .. JITTER_MS .. "ms, per-player stop.")
