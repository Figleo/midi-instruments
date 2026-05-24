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
MidiMod.Version = "1.1.0"

-- ====== SINGLE DEBUG TOGGLE ======
-- Set to true to enable all debug logging across the entire mod.
MidiMod.Debug = true

-- Client-side volume (loaded from companion mod XML settings)
MidiMod.CurrentVolume = 0.75

MidiMod.Instruments = {
    ["accordion"] = true,
    ["guitar"] = true,
    ["guitarelectric"] = true,
    ["harmonica"] = true
}

-- Always prints (important messages only)
function MidiMod.Log(msg)
    print("[MidiMod] " .. tostring(msg))
end

-- Only prints when MidiMod.Debug is true
function MidiMod.DebugLog(msg)
    if MidiMod.Debug then
        print("[MidiMod:Debug] " .. tostring(msg))
    end
end

-- Get the ID and Item of the supported instrument the character is holding
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

-- Backward compat alias
function MidiMod.IsHoldingInstrument(character)
    return MidiMod.GetHeldInstrument(character) ~= nil
end

MidiMod.IsHoldingAccordion = MidiMod.IsHoldingInstrument

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

-- SoundEngine init (client-only, server has no audio)
if CLIENT then
    if MidiMod.SoundEngine then
        local ok, err = pcall(MidiMod.SoundEngine.init)
        if not ok then
            MidiMod.Log("ERROR initializing sound engine: " .. tostring(err))
        end
    end
end

-- Network init (both client and server)
if MidiMod.Network then
    local ok, err = pcall(MidiMod.Network.init)
    if not ok then
        MidiMod.Log("ERROR initializing network: " .. tostring(err))
    end
end

-- Read volume from companion settings XML
local function readVolumeFromXML()
    local volume = nil
    pcall(function()
        local file = io.open("Data/Mods/MIDIInstruments/SettingsData.xml", "r")
        if file then
            local content = file:read("*all")
            file:close()
            local volumeStr = string.match(content, 'MidiVolume[^>]*Value="([%d%.]+)"')
            if volumeStr then volume = tonumber(volumeStr) end
        end
    end)
    return volume
end

-- Load initial volume
local xmlVol = readVolumeFromXML()
if xmlVol then
    MidiMod.CurrentVolume = math.max(0.0, math.min(1.0, xmlVol))
    MidiMod.Log("Volume loaded from settings: " .. MidiMod.CurrentVolume)
end

-- Poll volume changes periodically (client only, every ~2 seconds)
if CLIENT then
    local lastKnownVolume = MidiMod.CurrentVolume
    local checkCounter = 0

    Hook.Add("think", "midi_live_config", function()
        checkCounter = checkCounter + 1
        if checkCounter % 120 ~= 0 then return end

        local vol = readVolumeFromXML()
        if vol and math.abs(vol - lastKnownVolume) > 0.001 then
            lastKnownVolume = vol
            MidiMod.CurrentVolume = math.max(0.0, math.min(1.0, vol))
            MidiMod.DebugLog("Volume changed to: " .. MidiMod.CurrentVolume)
        end
    end)
end

MidiMod.Log("=== Initialization complete ===")
