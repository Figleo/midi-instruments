if not CLIENT then return end

-- Lua supplies the active mod directory so the patch can recognize this mod's samples.
local typeName = "MidiInstruments.Compatibility.SpwDistancePitch"
local reported = nil
local nextAttempt = 0

local function install()
    local ok, status = pcall(function()
        LuaUserData.RegisterType(typeName)
        local compat = LuaUserData.CreateStatic(typeName, true)
        compat.ConfigureModDirectory(MidiMod.BasePath)
        compat.TryInstallPatch()
        return compat.Status
    end)
    if not ok then
        status = "Compatibility assembly is unavailable: " .. tostring(status)
    end
    if status ~= reported then
        MidiMod.Log("[SPW compatibility] " .. status)
        reported = status
    end
    return ok and (status == "Applied" or status:find("Incompatible SPW", 1, true) ~= nil)
end

-- Assembly and Lua initialization order can vary during reloads; installation is retried until ready.
if not install() then
    Hook.Add("think", "MidiMod.SpwCompatibility.Load", function()
        if os.clock() < nextAttempt then return end
        nextAttempt = os.clock() + 2
        if install() then
            Hook.Remove("think", "MidiMod.SpwCompatibility.Load")
        end
    end)
end
