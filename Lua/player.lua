-- Playback Scheduler: plays MIDI from a character's instrument
-- Singleton: one song at a time per client
-- Includes RMB hold, buff system, and per-player network stop

MidiMod                    = MidiMod or {}
MidiMod.Player             = {}

local Player               = MidiMod.Player

Player.score               = nil
Player.cursor              = 1
Player.playing             = false
Player.paused              = false
Player.startTime           = 0
Player.pauseTime           = 0
Player.tempoMultiplier     = 1.0
Player.currentFile         = nil
Player.sourceCharacter     = nil
Player.onStateChange       = nil
Player.isStreamingHost     = false
Player.instrumentDropped   = false
Player.streamingCharacters = {} -- tracks remote players streaming to us

-- MIDI Loading

function Player.loadFile(filePath)
    Player.stop()

    if not MidiMod.MidiParser then
        MidiMod.Log("MidiParser not available!")
        return false
    end

    local ok, score = pcall(function()
        return MidiMod.MidiParser.parse(filePath)
    end)

    if not ok then
        MidiMod.Log("Failed to parse MIDI: " .. tostring(score))
        return false
    end

    if not score or #score == 0 then
        MidiMod.Log("MIDI file has no notes: " .. filePath)
        return false
    end

    Player.score = score
    Player.cursor = 1
    Player.currentFile = filePath
    MidiMod.Log("Loaded MIDI: " .. #score .. " notes from " .. filePath)
    return true
end

-- Time

local function getTimeMs()
    if Timing and Timing.TotalTime then
        return Timing.TotalTime * 1000
    end
    return os.clock() * 1000
end

-- Transport Controls

function Player.play(character)
    if not Player.score or #Player.score == 0 then
        MidiMod.Log("No MIDI loaded to play")
        return
    end

    if character then
        Player.sourceCharacter = character
    end

    if Player.paused then
        local pausedDuration = getTimeMs() - Player.pauseTime
        Player.startTime = Player.startTime + pausedDuration
        Player.paused = false
        Player.playing = true
        MidiMod.Log("Playback resumed")
    else
        Player.cursor = 1
        Player.startTime = getTimeMs()
        Player.playing = true
        Player.paused = false
        MidiMod.Log("Playback started (" .. #Player.score .. " notes)")
    end

    if Player.onStateChange then
        pcall(Player.onStateChange, "play")
    end
end

function Player.pause()
    if Player.playing and not Player.paused then
        Player.paused = true
        Player.pauseTime = getTimeMs()
        MidiMod.Log("Playback paused")
        if Player.onStateChange then
            pcall(Player.onStateChange, "pause")
        end
    end
end

function Player.stop()
    local wasPlaying = Player.playing
    Player.playing = false
    Player.paused = false
    Player.cursor = 1
    Player.sourceCharacter = nil
    Player.isStreamingHost = false
    Player.instrumentDropped = false

    if MidiMod.SoundEngine then
        pcall(MidiMod.SoundEngine.stopAll)
    end

    if wasPlaying then
        MidiMod.Log("Playback stopped")
        if Player.onStateChange then
            pcall(Player.onStateChange, "stop")
        end
    end
end

-- Per-player stop: for network, stops sounds from a specific remote character
-- Per-player stop: for network, stops sounds from a specific remote character
function Player.stopChar(charID)
    -- If this is our own character, do a full stop
    if Player.sourceCharacter then
        local ourID = nil
        pcall(function() ourID = Player.sourceCharacter.ID end)
        if ourID and ourID == charID then
            Player.stop()
            return
        end
    end

    -- Otherwise just stop all sounds for that remote character
    if MidiMod.SoundEngine and MidiMod.SoundEngine.stopAllForChar then
        MidiMod.SoundEngine.stopAllForChar(charID)
    end

    -- Очисти трекинг нот для этого персонажа
    if MidiMod.SoundEngine and MidiMod.SoundEngine.activeNoteUIDs then
        MidiMod.SoundEngine.activeNoteUIDs[charID] = nil
    end

    Player.streamingCharacters[charID] = nil
end

function Player.setTempo(multiplier)
    Player.tempoMultiplier = math.max(0.25, math.min(4.0, multiplier))
end

function Player.getProgress()
    if not Player.score or #Player.score == 0 then return 0 end
    return (Player.cursor - 1) / #Player.score
end

function Player.getTimeString()
    if not Player.playing then return "0:00 / 0:00" end

    local elapsed = (getTimeMs() - Player.startTime) * Player.tempoMultiplier
    local total = Player.score[#Player.score].timeMs

    local function formatTime(ms)
        local s = math.floor(ms / 1000)
        local m = math.floor(s / 60)
        s = s % 60
        return string.format("%d:%02d", m, s)
    end

    return formatTime(elapsed) .. " / " .. formatTime(total)
end

-- === AIM: Hold instrument via forced RMB input ===
-- Suppressed when LMB is used on an interactable target

local inputAim = nil
pcall(function() inputAim = InputType.Aim end)
inputAim = inputAim or 2

local aimSuppressUntil = 0
local AIM_SUPPRESS_DURATION = 0.5

local function hasInteractTarget(character)
    local found = false
    pcall(function() found = (character.FocusedItem ~= nil) end)
    if found then return true end
    pcall(function() found = (character.SelectedItem ~= nil) end)
    if found then return true end
    pcall(function() found = (character.FocusedCharacter ~= nil) end)
    if found then return true end
    pcall(function() found = (character.SelectedConstruction ~= nil) end)
    return found
end

local function forceAim(character)
    if not character then return end

    local isDead = true
    pcall(function() isDead = character.IsDead end)
    if isDead then return end

    local now = os.clock()

    local lmbHeld = false
    pcall(function() lmbHeld = PlayerInput.PrimaryMouseButtonHeld() end)

    if lmbHeld and hasInteractTarget(character) then
        aimSuppressUntil = now + AIM_SUPPRESS_DURATION
    end

    if now < aimSuppressUntil then return end

    pcall(function() character.SetInput(inputAim, false, true) end)
    pcall(function()
        local k = character.Keys[inputAim]
        if k then k.Held = true end
    end)
end

-- === Note Playback Logic ===

local function onThink()
    if not Player.playing or Player.paused then return end
    if not Player.score then return end

    local currentInst, currentItem = MidiMod.GetHeldInstrument(Player.sourceCharacter)
    currentInst = currentInst or "accordion"

    local worldPos = nil
    if currentItem then
        pcall(function() worldPos = currentItem.WorldPosition end)
    elseif Player.sourceCharacter then
        pcall(function() worldPos = Player.sourceCharacter.WorldPosition end)
    end

    local now = getTimeMs()
    local elapsed = (now - Player.startTime) * Player.tempoMultiplier
    local streamBatch = {}

    local charID = nil
    pcall(function() charID = Player.sourceCharacter.ID end)

    while Player.cursor <= #Player.score do
        local event = Player.score[Player.cursor]
        if event.timeMs <= elapsed then
            local evType = event.type or "on"  -- backward compat: no type = noteOn

            if evType == "on" then
                -- Note On
                if MidiMod.SoundEngine then
                    pcall(MidiMod.SoundEngine.playNote, event.note, event.velocity, worldPos, currentInst, charID)
                end
                if Player.isStreamingHost then
                    table.insert(streamBatch, event.note .. "," .. event.velocity)
                end
            elseif evType == "off" then
                -- Note Off — smooth fade-out
                if MidiMod.SoundEngine and MidiMod.SoundEngine.releaseNote then
                    pcall(MidiMod.SoundEngine.releaseNote, event.note, charID)
                end
                if Player.isStreamingHost then
                    table.insert(streamBatch, event.note .. ",0")  -- velocity 0 = noteOff
                end
            end

            Player.cursor = Player.cursor + 1
        else
            break
        end
    end

    -- Send notes to other players
    if Player.isStreamingHost and #streamBatch > 0 and Player.sourceCharacter then
        local notesStr = table.concat(streamBatch, ";")
        if MidiMod.Network and MidiMod.Network.broadcastNotes then
            pcall(MidiMod.Network.broadcastNotes, charID, notesStr, currentInst)
        end
    end

    -- Song finished
    if Player.cursor > #Player.score then
        MidiMod.Log("Playback complete")
        local wasStreaming = Player.isStreamingHost
        Player.playing = false
        Player.paused = false

        if Player.onStateChange then
            pcall(Player.onStateChange, "stop")
        end

        -- Notify other players that we stopped
        if wasStreaming and charID and MidiMod.Network then
            pcall(MidiMod.Network.requestStop, charID)
        end
    end
end

-- === Injection Points ===

-- ControlLocalPlayer fires every C# frame — most reliable for aim forcing
pcall(function()
    Hook.Patch(
        "Barotrauma.Character",
        "ControlLocalPlayer",
        function(instance, ptable)
            if instance ~= Player.sourceCharacter then return end
            if not Player.playing then return end
            forceAim(instance)
        end,
        Hook.HookMethodType.After
    )
    MidiMod.DebugLog("[Player] ControlLocalPlayer.After patch applied")
end)

-- Think hook: note playback + streaming tracker cleanup + aim backup
Hook.Add("think", "MidiMod.Player.Think", function()
    local clockNow = os.clock()

    -- Clean up stale streaming entries (remote players who stopped)
    for charID, lastUpdate in pairs(Player.streamingCharacters) do
        if clockNow - lastUpdate > 1.0 then
            Player.streamingCharacters[charID] = nil
        end
    end

    if not Player.sourceCharacter or not Player.playing or Player.paused then
        return
    end

    local ch = Player.sourceCharacter

    -- Update streaming tracker for our own character
    pcall(function()
        Player.streamingCharacters[ch.ID] = clockNow
    end)

    -- Fail-safe aim (backup for ControlLocalPlayer patch)
    forceAim(ch)

    -- Stop if instrument was dropped
    if not MidiMod.IsHoldingInstrument(ch) then
        if not Player.instrumentDropped then
            Player.instrumentDropped = true
            MidiMod.Log("Instrument dropped — stopping playback")
            if MidiMod.Network then
                pcall(MidiMod.Network.requestStop)
            else
                Player.stop()
            end
        end
        return
    end
    Player.instrumentDropped = false

    onThink()
end)

-- === BUFF SYSTEM (Server-side affliction application) ===

local TALENT_BUFFS      = {
    steadytune     = "psychosisimmunity",
    melodicrespite = "melodicrespite",
}
local REQUIRED_PLAY_SEC = 10
local BUFF_STRENGTH     = 60.0
-- Longer interval = fewer server events = less chance of pipe overload
local SERVER_REFRESH    = 30

local function hasTalentChar(character, talentID)
    local found = false
    pcall(function()
        if character.HasTalent then
            found = character.HasTalent(talentID)
        end
    end)
    if not found then
        pcall(function()
            if character.Info and character.Info.UnlockedTalents then
                for id in character.Info.UnlockedTalents do
                    if tostring(id):lower() == talentID then
                        found = true
                    end
                end
            end
        end)
    end
    return found
end

-- Check if the character already has this affliction at sufficient strength
-- to avoid redundant ApplyAffliction calls (each one generates a server sync event)
local function getAfflictionStrength(character, afflictionID)
    local strength = 0
    pcall(function()
        local prefab = AfflictionPrefab.Prefabs[afflictionID]
        if prefab and character.CharacterHealth then
            local affliction = character.CharacterHealth.GetAffliction(afflictionID)
            if affliction then
                strength = affliction.Strength
            end
        end
    end)
    return strength
end

local function applyAffliction(character, afflictionID, strength)
    -- Skip if the character already has this affliction at high enough strength
    -- This prevents generating unnecessary server entity events
    local current = getAfflictionStrength(character, afflictionID)
    if current >= strength * 0.5 then
        MidiMod.DebugLog(string.format(
            "[ServerBuff] Skipping %s (current=%.1f, threshold=%.1f)",
            afflictionID, current, strength * 0.5))
        return
    end

    pcall(function()
        local prefab = AfflictionPrefab.Prefabs[afflictionID]
        if prefab and character.CharacterHealth then
            character.CharacterHealth.ApplyAffliction(
                nil, prefab.Instantiate(strength), false)
        end
    end)
end

if SERVER then
    local serverTimers = {}
    local _serverTime  = 0

    Hook.Add("MidiMod.Server.BuffStart", "MidiMod.Server.HandleStart",
        function(charID, character)
            if character then
                serverTimers[charID] = {
                    playStart = _serverTime,
                    lastApply = 0
                }
                MidiMod.DebugLog("[ServerBuff] Tracking char " .. tostring(charID))
            end
        end)

    Hook.Add("MidiMod.Server.BuffStop", "MidiMod.Server.HandleStop",
        function(charID)
            serverTimers[charID] = nil
            MidiMod.DebugLog("[ServerBuff] Stopped tracking char " .. tostring(charID))
        end)

    Hook.Add("think", "MidiMod.Server.BuffApply", function(deltaTime)
        _serverTime = _serverTime + deltaTime
        local now = _serverTime

        for charID, timer in pairs(serverTimers) do
            local playedEnough = (now - timer.playStart) >= REQUIRED_PLAY_SEC
            local refreshReady = (now - timer.lastApply) >= SERVER_REFRESH

            if playedEnough and refreshReady then
                local character = nil
                pcall(function()
                    character = Entity.FindEntityByID(charID)
                end)

                if character and not character.IsDead then
                    for talentID, afflictionID in pairs(TALENT_BUFFS) do
                        if hasTalentChar(character, talentID) then
                            applyAffliction(character, afflictionID, BUFF_STRENGTH)
                            MidiMod.DebugLog(string.format(
                                "[ServerBuff] Applied %s to char %d",
                                afflictionID, charID))
                        end
                    end
                    timer.lastApply = now
                else
                    serverTimers[charID] = nil
                end
            end
        end
    end)
end

MidiMod.Log("[Player] Loaded. RMB hold + server buffs enabled.")
