-- Network: real-time note sync for multiplayer
-- Direct send (no buffering) to avoid server event spam

MidiMod              = MidiMod or {}
MidiMod.Network      = {}

local Network        = MidiMod.Network

local NET_STOP       = "MidiMod.Stop"
local NET_NOTES      = "MidiMod.Notes"
local NET_BUFF_START = "MidiMod.BuffStart"
local NET_BUFF_STOP  = "MidiMod.BuffStop"

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

function Network.resolveMidiPath(fileName)
    if string.find(fileName, "/") or string.find(fileName, "\\") then
        return fileName
    end
    return MidiMod.BasePath .. "Midi/" .. fileName
end

-- Play/release notes received from a remote player
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

    -- Track that this character is streaming music
    if MidiMod.Player and MidiMod.Player.streamingCharacters then
        MidiMod.Player.streamingCharacters[charID] = os.clock()
    end

    for part in string.gmatch(notesStr, "([^;]+)") do
        local note, vel = string.match(part, "(%d+),(%d+)")
        if note and vel then
            local noteNum = tonumber(note)
            local velNum = tonumber(vel)

            if velNum == 0 then
                -- noteOff: smooth fade-out
                if MidiMod.SoundEngine.releaseNote then
                    pcall(MidiMod.SoundEngine.releaseNote, noteNum, charID)
                end
            else
                -- noteOn: play the sound
                pcall(function()
                    MidiMod.SoundEngine.playNote(noteNum, velNum, worldPos, instrId, charID)
                end)
            end
        end
    end
end

-- Lightweight throttle: accumulate notes and send at most every 200ms
-- This prevents frame-by-frame network spam on fast MIDIs
local _pendingNotes = {}  -- charID -> {instrId, parts={}}
local _lastSendTime = 0
local SEND_INTERVAL = 0.2 -- seconds

function Network.broadcastNotes(charID, notesStr, instrId)
    if Game.IsSingleplayer then return end

    -- Accumulate notes
    if not _pendingNotes[charID] then
        _pendingNotes[charID] = { instrId = instrId or "accordion", parts = {} }
    end
    local pending = _pendingNotes[charID]
    pending.instrId = instrId or pending.instrId
    table.insert(pending.parts, notesStr)
end

-- Flush pending notes on a timer (called from think hook below)
local function flushPendingNotes()
    local now = os.clock()
    if (now - _lastSendTime) < SEND_INTERVAL then return end
    _lastSendTime = now

    for charID, pending in pairs(_pendingNotes) do
        if #pending.parts > 0 then
            local combined = table.concat(pending.parts, ";")

            local msg = Networking.Start(NET_NOTES)
            msg.WriteUInt16(charID)
            msg.WriteString(combined)
            msg.WriteString(pending.instrId)

            if SERVER then
                for _, c in pairs(Client.ClientList) do
                    Networking.Send(msg, c.Connection)
                end
            else
                Networking.Send(msg)
            end
        end
    end
    _pendingNotes = {}
end

Hook.Add("think", "MidiMod.Network.Flush", function()
    if Game.IsSingleplayer then return end
    flushPendingNotes()
end)

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

-- High-level: load + play a MIDI file
function Network.requestPlay(fileName, tempoMult)
    tempoMult = tempoMult or 1.0

    local character = Character.Controlled
    if not character or not MidiMod.IsHoldingInstrument(character) then
        MidiMod.Log("Not holding instrument!")
        return
    end

    -- Stop current playback first
    Network.requestStop()

    local fullPath = Network.resolveMidiPath(fileName)
    MidiMod.Log("Loading MIDI: " .. fullPath)

    local success = MidiMod.Player.loadFile(fullPath)
    if success then
        MidiMod.Player.setTempo(tempoMult)
        if not Game.IsSingleplayer then
            MidiMod.Player.isStreamingHost = true
        end
        MidiMod.Player.play(character)

        -- Tell server we started playing (for buffs)
        if not Game.IsSingleplayer then
            Network.notifyBuffStart(character)
        end

        MidiMod.Log("Started streaming MIDI!")
    else
        MidiMod.Log("Failed to load MIDI: " .. fullPath)
    end
end

-- High-level: stop playback and notify others
function Network.requestStop(charID)
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

MidiMod.Log("[Network] Loaded. Direct send, per-player stop.")
