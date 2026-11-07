MidiMod = MidiMod or {}
MidiMod.JamRangeConfig = require("range_settings").create({
    command = "midijamrange",
    label = "Play Together radius",
    field = "JamRange",
    defaultRange = 2000,
    network = "MidiMod.JamRange",
    fileName = "MidiInstruments_JamRange.txt",
})

function MidiMod.IsWithinJamRange(follower, leader)
    if not follower or not leader or follower == leader then return false end
    local ok, within = pcall(function()
        if follower.Removed or leader.Removed then return false end

        -- World positions include submarine offsets. Squared distance avoids a square root.
        local a, b = follower.WorldPosition, leader.WorldPosition
        local dx, dy = a.X - b.X, a.Y - b.Y
        return dx * dx + dy * dy <= MidiMod.JamRange * MidiMod.JamRange
    end)
    return ok and within == true
end

function MidiMod.CanJamWith(follower, leaderID)
    local leader = nil
    pcall(function() leader = Entity.FindEntityByID(leaderID) end)
    return MidiMod.IsWithinJamRange(follower, leader)
end
