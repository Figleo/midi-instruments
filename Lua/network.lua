MidiMod                  = MidiMod or {}
MidiMod.Network          = {}

local Network            = MidiMod.Network

local NET_STOP           = "MidiMod.Stop"
local NET_NOTES          = "MidiMod.Notes"
local NET_BUFF_START     = "MidiMod.BuffStart"
local NET_BUFF_STOP      = "MidiMod.BuffStop"
local _networkClientTime = 0


function Network.init()
    if SERVER then Network.initServer() end
    if CLIENT then Network.initClient() end
end

function Network.initServer()
    Networking.Receive(NET_NOTES, function(message, client)
        local charID   = message.ReadUInt16()
        local notesStr = message.ReadString()
        local instrId  = "accordion"
        pcall(function() instrId = message.ReadString() end)

        for _, c in pairs(Client.ClientList) do
            if c ~= client then
                local broadcast = Networking.Start(NET_NOTES)
                broadcast.WriteUInt16(charID)
                broadcast.WriteString(notesStr)
                broadcast.WriteString(instrId)
                Networking.Send(broadcast, c.Connection)
            end
        end
    end)

    Networking.Receive(NET_STOP, function(message, client)
        local charID = message.ReadUInt16()
        MidiMod.Log("Server: " .. client.Name .. " requests stop for char " .. tostring(charID))

        for _, c in pairs(Client.ClientList) do
            if c ~= client then
                local broadcast = Networking.Start(NET_STOP)
                broadcast.WriteUInt16(charID)
                Networking.Send(broadcast, c.Connection)
            end
        end
        Hook.Call("MidiMod.Server.BuffStop", charID)
    end)

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
    Networking.Receive(NET_NOTES, function(message)
        local charID   = message.ReadUInt16()
        local notesStr = message.ReadString()
        local instrId  = "accordion"
        pcall(function() instrId = message.ReadString() end)
        Network.playStreamedNotes(charID, notesStr, instrId)
    end)

    Networking.Receive(NET_STOP, function(message)
        local charID = message.ReadUInt16()
        MidiMod.Log("Client: stop received for char " .. tostring(charID))
        if MidiMod.Player then MidiMod.Player.stopChar(charID) end
        if MidiMod.SoundEngine then
            pcall(function()
                if MidiMod.SoundEngine.stopAllForChar then
                    MidiMod.SoundEngine.stopAllForChar(charID)
                end
            end)
        end
    end)
end

function Network.resolveMidiPath(fileName)
    if string.find(fileName, "/") or string.find(fileName, "\\") then
        return fileName
    end
    return MidiMod.BasePath .. "Midi/" .. fileName
end

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
        MidiMod.Player.streamingCharacters[charID] = os.clock()
    end

    for part in string.gmatch(notesStr, "([^;]+)") do
        local note, vel = string.match(part, "(%d+),(%d+)")
        if note and vel then
            pcall(function()
                if MidiMod.SoundEngine.playNote then
                    MidiMod.SoundEngine.playNote(
                        tonumber(note), tonumber(vel),
                        worldPos, instrId, charID
                    )
                end
            end)
        end
    end
end

local NOTE_FLUSH_INTERVAL_MS = 500
local MAX_NOTES_PER_FLUSH    = 32

Network._noteBuf             = {}
Network._lastFlushMs         = 0

function Network.broadcastNotes(charID, notesStr, instrId)
    if Game.IsSingleplayer then return end
    if not Network._noteBuf[charID] then
        Network._noteBuf[charID] = {
            instrId = instrId or "accordion",
            notes = {}
        }
    end
    local buf = Network._noteBuf[charID]
    buf.instrId = instrId or buf.instrId
    for part in string.gmatch(notesStr, "([^;]+)") do
        if #buf.notes < 500 then
            table.insert(buf.notes, part)
        end
    end
end

local function flushNoteBuffer()
    for charID, buf in pairs(Network._noteBuf) do
        local notes = buf.notes
        if #notes == 0 then
            Network._noteBuf[charID] = nil
        else
            local i = 1
            while i <= #notes do
                local slice = {}
                for j = i, math.min(i + MAX_NOTES_PER_FLUSH - 1, #notes) do
                    table.insert(slice, notes[j])
                end
                local chunk = table.concat(slice, ";")
                if SERVER then
                    for _, c in pairs(Client.ClientList) do
                        local msg = Networking.Start(NET_NOTES)
                        msg.WriteUInt16(charID)
                        msg.WriteString(chunk)
                        msg.WriteString(buf.instrId)
                        Networking.Send(msg, c.Connection)
                    end
                else
                    local msg = Networking.Start(NET_NOTES)
                    msg.WriteUInt16(charID)
                    msg.WriteString(chunk)
                    msg.WriteString(buf.instrId)
                    Networking.Send(msg)
                end
                i = i + MAX_NOTES_PER_FLUSH
            end
            Network._noteBuf[charID] = nil
        end
    end
end

Hook.Add("think", "MidiMod.Network.FlushNotes", function(deltaTime)
    if not CLIENT then return end
    _networkClientTime = _networkClientTime + deltaTime
    local nowMs = _networkClientTime * 1000

    if (nowMs - Network._lastFlushMs) < NOTE_FLUSH_INTERVAL_MS then
        return
    end
    Network._lastFlushMs = nowMs
    flushNoteBuffer()
end)

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

function Network.requestPlay(fileName, tempoMult)
    tempoMult = tempoMult or 1.0
    local character = Character.Controlled
    if not character or not MidiMod.IsHoldingInstrument(character) then
        MidiMod.Log("Not holding instrument!")
        return
    end
    local charID = character.ID
    if MidiMod.Player then
        MidiMod.Player.stopChar(charID)
    end

    local fullPath = Network.resolveMidiPath(fileName)
    MidiMod.Log("Loading MIDI to Stream: " .. fullPath)
    local success = MidiMod.Player.loadFile(fullPath, character.ID)
    if success then
        MidiMod.Player.setTempo(character.ID, tempoMult)
        if not Game.IsSingleplayer then
            MidiMod.Player.setStreamingHost(character.ID, true)
        end
        MidiMod.Player.play(character)

        if not Game.IsSingleplayer and MidiMod.Network then
            MidiMod.Network.notifyBuffStart(character)
        end

        MidiMod.Log("Started streaming MIDI!")
    else
        MidiMod.Log("Failed to load MIDI: " .. fullPath)
    end
end

function Network.requestStop(charID)
    if not charID then
        local ch = Character.Controlled
        if ch then charID = ch.ID else return end
    end

    if MidiMod.Player then
        MidiMod.Player.stopChar(charID)
    end

    if Game.IsSingleplayer then return end
    if SERVER then
        for _, c in pairs(Client.ClientList) do
            local msg = Networking.Start(NET_STOP)
            msg.WriteUInt16(charID)
            Networking.Send(msg, c.Connection)
        end
    else
        local msg = Networking.Start(NET_STOP)
        msg.WriteUInt16(charID)
        Networking.Send(msg)
    end
end
