function MidiMod.SetDebug(enabled)
    MidiMod.Debug = enabled
    if MidiMod.SpwCompatibility then
        pcall(function() MidiMod.SpwCompatibility.DebugEnabled = enabled end)
    end
end

Game.RemoveCommand("mididebug")
Game.AddCommand("mididebug", "mididebug [on|off] - show or change local MIDI debug logging.", function(args)
    local words = {}
    for word in args do words[#words + 1] = tostring(word):lower() end
    if #words == 1 and (words[1] == "on" or words[1] == "off") then
        MidiMod.SetDebug(words[1] == "on")
    elseif #words ~= 0 then
        MidiMod.Log("[mididebug] Usage: mididebug [on|off].")
        return
    end
    MidiMod.Log("[mididebug] Debug logging: " .. (MidiMod.Debug and "on" or "off") .. ".")
end)

if SERVER then
    -- Remote console requests must not change another process's debug setting.
    Game.AssignOnClientRequestExecute("mididebug", function()
        MidiMod.DebugLog("[mididebug] Use this command in your local console.")
    end)
end
