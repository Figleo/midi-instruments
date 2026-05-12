-- Sends note bursts over the network so other clients hear roughly the same thing.

MidiMod              = MidiMod or {}
MidiMod.Network      = {}

local Network        = MidiMod.Network

local NET_STOP       = "MidiMod.Stop"
local NET_NOTES      = "MidiMod.Notes"
local NET_BUFF_START = "MidiMod.BuffStart"
local NET_BUFF_TICK  = "MidiMod.BuffTick"
local NET_BUFF_STOP  = "MidiMod.BuffStop"

function Network.init()
    if SERVER then Network.initServer() end
    if CLIENT then Network.initClient() end
end

function Network.initServer()
    Networking.Receive(NET_NOTES, function(message, client)
        local charID = message.ReadUInt16()
        local notesStr = message.ReadString()
        local instrId = "accordion"
        pcall(function() instrId = message.ReadString() end)

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

    Networking.Receive(NET_STOP, function(message, client)
        MidiMod.Log("Server: " .. client.Name .. " requests stop")

        local broadcast = Networking.Start(NET_STOP)
        for _, c in pairs(Client.ClientList) do
            if c ~= client then
                Networking.Send(broadcast, c.Connection)
            end
        end

        if MidiMod.Player then
            MidiMod.Player.stop()
        end
    end)
    Networking.Receive(NET_BUFF_START, function(message, client)
        local charID = message.ReadUInt16()

        MidiMod.Log("[Server] Buff start for char " .. charID)

        local character = nil
        pcall(function() character = Entity.FindEntityByID(charID) end)

        if character then
            if not Network.activeMusicians then
                Network.activeMusicians = {}
            end
            Network.activeMusicians[charID] = character
        end
    end)

    Networking.Receive(NET_BUFF_STOP, function(message, client)
        local charID = message.ReadUInt16()

        MidiMod.Log("[Server] Buff stop for char " .. charID)

        if Network.activeMusicians then
            Network.activeMusicians[charID] = nil
        end
    end)
end

function Network.initClient()
    Networking.Receive(NET_NOTES, function(message)
        local charID = message.ReadUInt16()
        local notesStr = message.ReadString()
        local instrId = "accordion"
        pcall(function() instrId = message.ReadString() end)

        Network.playStreamedNotes(charID, notesStr, instrId)
    end)

    Networking.Receive(NET_STOP, function(message)
        MidiMod.Log("Client: stop received")
        if MidiMod.Player then
            MidiMod.Player.stop()
        end
    end)
end

function Network.notifyBuffStart(character)
    if Game.IsSingleplayer then return end
    if not character then return end

    local msg = Networking.Start(NET_BUFF_START)
    pcall(function() msg.WriteUInt16(character.ID) end)
    Networking.Send(msg)
end

function Network.notifyBuffStop(character)
    if Game.IsSingleplayer then return end
    if not character then return end

    local msg = Networking.Start(NET_BUFF_STOP)
    pcall(function() msg.WriteUInt16(character.ID) end)
    Networking.Send(msg)
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
    pcall(function()
        character = Entity.FindEntityByID(charID)
    end)

    local currentInst, currentItem
    if character then
        currentInst, currentItem = MidiMod.GetHeldInstrument(character)
    end

    local worldPos = nil
    if currentItem then
        pcall(function() worldPos = currentItem.WorldPosition end)
    elseif character then
        pcall(function() worldPos = character.WorldPosition end)
    end

    if character and MidiMod.Player and MidiMod.Player.streamingCharacters then
        MidiMod.Player.streamingCharacters[charID] = os.clock()
    end

    for part in string.gmatch(notesStr, "([^;]+)") do
        local note, vel = string.match(part, "(%d+),(%d+)")
        if note and vel then
            pcall(MidiMod.SoundEngine.playNote, tonumber(note), tonumber(vel), worldPos, instrId)
        end
    end
end

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

function Network.requestPlay(fileName, tempoMult)
    tempoMult = tempoMult or 1.0

    local character = Character.Controlled
    if not character or not MidiMod.IsHoldingInstrument(character) then
        MidiMod.Log("Not holding instrument!")
        return
    end

    Network.requestStop()

    local fullPath = Network.resolveMidiPath(fileName)
    MidiMod.Log("Loading MIDI to Stream: " .. fullPath)

    local success = MidiMod.Player.loadFile(fullPath)
    if success then
        MidiMod.Player.setTempo(tempoMult)
        if not Game.IsSingleplayer then
            MidiMod.Player.isStreamingHost = true
        end
        MidiMod.Player.play(character)
        MidiMod.Log("Started streaming MIDI!")
    else
        MidiMod.Log("Failed to load MIDI: " .. fullPath)
    end
end

function Network.requestStop()
    if MidiMod.Player then MidiMod.Player.stop() end

    if Game.IsSingleplayer then return end

    local msg = Networking.Start(NET_STOP)
    if SERVER then
        for _, c in pairs(Client.ClientList) do
            Networking.Send(msg, c.Connection)
        end
    else
        Networking.Send(msg)
    end
end
