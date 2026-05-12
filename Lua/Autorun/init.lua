-- Midis mod entry. LuaCsForBarotrauma loads this file on startup.

local basePath = table.pack(...)[1] or "LocalMods/Midis"
if type(basePath) ~= "string" then
    basePath = tostring(basePath) or "LocalMods/Midis"
end
if string.sub(basePath, -1) ~= "/" and string.sub(basePath, -1) ~= "\\" then
    basePath = basePath .. "/"
end

MidiMod = MidiMod or {}
MidiMod.BasePath = basePath
MidiMod.Version = "1.0.0"
MidiMod.Debug = false
MidiMod.CurrentVolume = 0.75

MidiMod.Instruments = {
    ["accordion"] = true,
    ["guitar"] = true,
    ["harmonica"] = true
}

function MidiMod.Log(msg)
    print("[MidiMod] " .. tostring(msg))
end

function MidiMod.DebugLog(msg)
    if MidiMod.Debug then
        print("[MidiMod:Debug] " .. tostring(msg))
    end
end

-- Returns instrument id and item for the first supported hand instrument, or nil.
function MidiMod.GetHeldInstrument(character)
    if not character then return nil, nil end
    local ok, id, itemObj = pcall(function()
        local heldItems = character.HeldItems
        if not heldItems then return nil, nil end
        for item in heldItems do
            local prefabId = tostring(item.Prefab.Identifier):lower()
            if MidiMod.Instruments[prefabId] then
                return prefabId, item
            end
        end
        return nil, nil
    end)
    if ok and id then
        return id, itemObj
    end
    return nil, nil
end

-- Kept for older code; any supported instrument counts, not just accordion.
function MidiMod.IsHoldingInstrument(character)
    return MidiMod.GetHeldInstrument(character) ~= nil
end

MidiMod.Log("Base path: " .. MidiMod.BasePath)

local function safeRequire(modName)
    local ok, err = pcall(require, modName)
    if not ok then
        MidiMod.Log("ERROR loading module '" .. modName .. "': " .. tostring(err))
        return false
    end
    MidiMod.Log("Module '" .. modName .. "' loaded.")
    return true
end

safeRequire("midi_parser")
safeRequire("sound_engine")
safeRequire("player")
safeRequire("network")

if CLIENT then
    safeRequire("gui")
end

if MidiMod.SoundEngine then
    local ok, err = pcall(MidiMod.SoundEngine.init)
    if not ok then
        MidiMod.Log("ERROR initializing sound engine: " .. tostring(err))
    end
end

if MidiMod.Network then
    local ok, err = pcall(MidiMod.Network.init)
    if not ok then
        MidiMod.Log("ERROR initializing network: " .. tostring(err))
    end
end

-- MidiVolume from the companion settings XML if present.
pcall(function()
    local file = io.open("Data/Mods/MIDIInstruments/SettingsData.xml", "r")
    if file then
        local content = file:read("*all")
        file:close()

        local volume = string.match(content, 'MidiVolume[^>]*Value="([%d%.]+)"')
        if volume then
            local vol = tonumber(volume)
            if vol then
                MidiMod.CurrentVolume = math.max(0.0, math.min(1.0, vol))
                MidiMod.Log("Volume loaded from settings: " .. MidiMod.CurrentVolume)
            end
        end
    end
end)

-- Poll settings occasionally so volume changes apply without a restart.
if CLIENT then
    local lastKnownVolume = MidiMod.CurrentVolume
    local checkCounter = 0

    local function readVolumeFromXML()
        local volume = nil
        pcall(function()
            local file = io.open("Data/Mods/MIDIInstruments/SettingsData.xml", "r")
            if file then
                local content = file:read("*all")
                file:close()

                local volumeStr = string.match(content, 'MidiVolume[^>]*Value="([%d%.]+)"')
                if volumeStr then
                    volume = tonumber(volumeStr)
                end
            end
        end)
        return volume
    end

    Hook.Add("think", "midi_live_config", function()
        checkCounter = checkCounter + 1

        if checkCounter % 30 ~= 0 then return end

        local xmlVolume = readVolumeFromXML()

        if xmlVolume and math.abs(xmlVolume - lastKnownVolume) > 0.001 then
            lastKnownVolume = xmlVolume
            MidiMod.CurrentVolume = xmlVolume

            if MidiMod.SoundEngine then
                MidiMod.SoundEngine.volumeMultiplier = xmlVolume

                if MidiMod.SoundEngine.setVolume then
                    MidiMod.SoundEngine.setVolume(xmlVolume)
                end
            end
        end
    end)
end

MidiMod.Log("Initialization complete.")
