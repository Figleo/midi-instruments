-- Schedules MIDI playback from whoever is holding the instrument.
-- Stops automatically if they put the instrument away.

MidiMod = MidiMod or {}
MidiMod.Player = {}

local Player = MidiMod.Player

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
Player.streamingCharacters = {}  -- Network replay bookkeeping.

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

local function getTimeMs()
    if Timing and Timing.TotalTime then
        return Timing.TotalTime * 1000
    end
    return os.clock() * 1000
end

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
        if CLIENT and MidiMod.Network then
            MidiMod.Network.notifyBuffStart(character)
        end
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
    local charForBuffNotify = Player.sourceCharacter
    Player.playing = false
    Player.paused = false
    Player.cursor = 1
    Player.sourceCharacter = nil
    Player.isStreamingHost = false
    if CLIENT and wasPlaying and charForBuffNotify and MidiMod.Network then
        MidiMod.Network.notifyBuffStop(charForBuffNotify)
    end
    
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

-- While playing we fake "aim" so the instrument stays up. That conflicts with
-- normal interactions, so we pause forcing aim briefly after a left click on a target.

local inputAim = nil
pcall(function() inputAim = InputType.Aim end)
inputAim = inputAim or 2

local aimSuppressUntil      = 0
local AIM_SUPPRESS_DURATION = 0.5

local function hasInteractTarget(character)
    local found = false
    pcall(function() found = (character.FocusedItem ~= nil) end)
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

-- Each frame we call item.Use() so OnUse status effects on the instrument still run
-- (talents, buffs) without you having to hold left mouse through the input stack.
-- Instrument sounds from that are muted elsewhere if needed.

-- Instruments we care about for the optional Xml hook below.
local INSTRUMENT_IDS = { accordion = true, guitar = true, harmonica = true }

local instrumentHookRegistered = false

local function registerInstrumentHook()
    if instrumentHookRegistered then return end
    instrumentHookRegistered = true

    Hook.Add("MidiMod.instrument.onUse", "MidiMod.buffHandler", 
        function(effect, deltaTime, item, targets, worldPosition, element)
            if not Player.playing then return end
            MidiMod.Log("[Buff] Hook triggered for: " .. tostring(item and item.Name))
        end
    )
    
    MidiMod.Log("[Buff] MidiMod.instrument.onUse hook registered")
end

registerInstrumentHook()

local function applyInstrumentOnUse(character)
    if not character then return end

    local _, item = MidiMod.GetHeldInstrument(character)
    if not item then return end

    local itemId = ""
    pcall(function() itemId = tostring(item.Prefab.Identifier):lower() end)
    if not INSTRUMENT_IDS[itemId] then return end

    local dt = 0.016
    pcall(function()
        if Timing and Timing.Step then dt = Timing.Step end
    end)

    local ok, err = pcall(function()
        item.Use(dt, character)
    end)
    
    if not ok then
        MidiMod.Log("[Buff] item.Use() failed: " .. tostring(err))
    end
end
function Player.debugKeys(ch)
    MidiMod.Log("[Keys] inputAim=" .. tostring(inputAim))
    for i = 0, 10 do
        local k = nil
        pcall(function() k = ch.Keys[i] end)
        MidiMod.Log("[Keys] [" .. i .. "] = " .. tostring(k))
    end
end

Game.AddCommand("testability", "Test ability system", function(args)
    local ch = Character.Controlled
    if not ch then return end
    
    local _, item = MidiMod.GetHeldInstrument(ch)
    if not item then 
        MidiMod.Log("[Ability] No instrument held")
        return 
    end
    
    MidiMod.Log("[Ability] === Testing Ability System ===")
    
    MidiMod.Log("[Ability] AbilityEffectType values:")
    pcall(function()
        MidiMod.Log("  OnUseItem = " .. tostring(AbilityEffectType.OnUseItem))
        MidiMod.Log("  OnItemUse = " .. tostring(AbilityEffectType.OnItemUse))
    end)
    
    pcall(function()
        local abilityObject = LuaUserData.CreateStatic("Barotrauma.AbilityObject")
        if abilityObject then
            MidiMod.Log("[Ability] AbilityObject created: YES")
            abilityObject.Item = item
            abilityObject.Character = ch
            MidiMod.Log("[Ability] AbilityObject.Item set: " .. tostring(abilityObject.Item ~= nil))
        else
            MidiMod.Log("[Ability] AbilityObject created: FAILED")
        end
    end)
    
    pcall(function()
        if ch.CheckTalents then
            MidiMod.Log("[Ability] CheckTalents method: EXISTS")
            
            local abilityObject = LuaUserData.CreateStatic("Barotrauma.AbilityObject")
            abilityObject.Item = item
            abilityObject.Character = ch
            
            ch.CheckTalents(AbilityEffectType.OnUseItem, abilityObject)
            MidiMod.Log("[Ability] CheckTalents called OK")
        else
            MidiMod.Log("[Ability] CheckTalents method: NOT FOUND")
        end
    end)
    
    MidiMod.Log("[Ability] === Limbs ===")
    pcall(function()
        if ch.AnimController and ch.AnimController.Limbs then
            local count = 0
            for limb in ch.AnimController.Limbs do
                local limbType = limb.type
                if limbType == LimbType.RightHand or limbType == LimbType.LeftHand then
                    count = count + 1
                    MidiMod.Log("  Hand limb #" .. count .. ", type=" .. tostring(limbType))
                    
                    if limb.UpdateUseItem then
                        limb.UpdateUseItem(0.016)
                        MidiMod.Log("    UpdateUseItem called OK")
                    else
                        MidiMod.Log("    UpdateUseItem: NOT FOUND")
                    end
                end
            end
            MidiMod.Log("  Total hand limbs: " .. count)
        end
    end)
end)
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

    local now     = getTimeMs()
    local elapsed = (now - Player.startTime) * Player.tempoMultiplier
    local streamBatch = {}

    while Player.cursor <= #Player.score do
        local note = Player.score[Player.cursor]
        if note.timeMs <= elapsed then
            if MidiMod.SoundEngine then
                pcall(MidiMod.SoundEngine.playNote, note.note, note.velocity, worldPos, currentInst)
            end
            if Player.isStreamingHost then
                table.insert(streamBatch, note.note .. "," .. note.velocity)
            end
            Player.cursor = Player.cursor + 1
        else
            break
        end
    end

    if Player.isStreamingHost and #streamBatch > 0 and Player.sourceCharacter then
        local notesStr = table.concat(streamBatch, ";")
        if MidiMod.Network and MidiMod.Network.broadcastNotes then
            pcall(MidiMod.Network.broadcastNotes, Player.sourceCharacter.ID, notesStr, currentInst)
        end
    end

    if Player.cursor > #Player.score then
        Player.playing = false
        Player.paused  = false
        MidiMod.Log("Playback complete")
        if Player.onStateChange then
            pcall(Player.onStateChange, "stop")
        end
    end
end

-- Run after vanilla reads input so our forced aim wins for that frame.
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
    MidiMod.Log("[Player] Patch A (ControlLocalPlayer.After) OK")
end)

Hook.Add("think", "MidiMod.Player.Think", function()
    local clockNow = os.clock()

    for charID, lastUpdate in pairs(Player.streamingCharacters) do
        if clockNow - lastUpdate > 1.0 then
            Player.streamingCharacters[charID] = nil
        end
    end

    if not Player.sourceCharacter or not Player.playing or Player.paused then
        return
    end

    local ch = Player.sourceCharacter

    pcall(function()
        Player.streamingCharacters[ch.ID] = clockNow
    end)

    forceAim(ch)
    applyInstrumentOnUse(ch)

    local _, heldItem = MidiMod.GetHeldInstrument(ch)
    if not heldItem then
        MidiMod.Log("Instrument dropped - stopping playback")
        Player.stop()
        return
    end

    onThink()
end)

-- Server: keep instrument buffs in sync for multiplayer.
if SERVER then
    Hook.Add("think", "MidiMod.Server.BuffApply", function()
        if not MidiMod.Network or not MidiMod.Network.activeMusicians then
            return
        end
        
        for charID, character in pairs(MidiMod.Network.activeMusicians) do
            local isValid = false
            pcall(function()
                if not character.IsDead and character.Inventory then
                    local _, item = MidiMod.GetHeldInstrument(character)
                    isValid = (item ~= nil)
                end
            end)
            
            if isValid then
                applyInstrumentOnUse(character)
            else
                MidiMod.Network.activeMusicians[charID] = nil
            end
        end
    end)
    
    MidiMod.Log("[Server] Buff apply hook registered")
end

MidiMod.Log("[Player] Loaded (aim patch after ControlLocalPlayer; OnUse via item.Use).")