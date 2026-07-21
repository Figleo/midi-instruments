-- Playback Scheduler: plays MIDI from a character's instrument
-- Singleton: one song at a time per client
-- Includes RMB hold, buff system, and per-player network stop

MidiMod                    = MidiMod or {}
MidiMod.Player             = {}

local Player               = MidiMod.Player

Player.score               = nil
Player.cursor              = 1
Player.playing             = false
Player.startTime           = 0
Player.tempoMultiplier     = 1.0
Player.currentFile         = nil
Player.sourceCharacter     = nil
Player.isStreamingHost     = false
Player.instrumentDropped   = false
Player.streamingCharacters = {} -- tracks remote players streaming to us

local pcall                = pcall
local ipairs               = ipairs
local pairs                = pairs
local math_max             = math.max
local math_min             = math.min
local math_floor           = math.floor
local os_clock             = os.clock
local tinsert              = table.insert
local tconcat              = table.concat

-- ─── MIDI Loading ───

function Player.loadScore(score, filePath)
    Player.stop()
    if not score or #score == 0 then
        MidiMod.Log("MIDI has no notes: " .. tostring(filePath))
        return false
    end
    Player.score = score
    Player.cursor = 1
    Player.currentFile = filePath
    MidiMod.Log("Loaded MIDI: " .. #score .. " notes from " .. tostring(filePath))
    return true
end

-- ─── Time ───

local function getTimeMs()
    if Timing and Timing.TotalTime then
        return Timing.TotalTime * 1000
    end
    return os_clock() * 1000
end

-- ─── Transport Controls ───

function Player.play(character)
    if not Player.score or #Player.score == 0 then
        MidiMod.Log("No MIDI loaded to play")
        return
    end

    if character then
        Player.sourceCharacter = character
    end

    Player.cursor = 1
    Player.startTime = getTimeMs()
    Player.playing = true
    MidiMod.Log("Playback started (" .. #Player.score .. " notes)")
end

function Player.stop()
    local wasPlaying = Player.playing
    Player.playing = false
    Player.cursor = 1
    Player.sourceCharacter = nil
    Player.isStreamingHost = false
    Player.instrumentDropped = false

    if MidiMod.SoundEngine then
        pcall(MidiMod.SoundEngine.stopAll)
    end
    if MidiMod.Network and MidiMod.Network.clearBuffer then
        MidiMod.Network.clearBuffer()
    end

    if wasPlaying then
        MidiMod.Log("Playback stopped")
    end
end

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
    -- (stopAllForChar already clears activeNoteUIDs[charID])
    if MidiMod.SoundEngine and MidiMod.SoundEngine.stopAllForChar then
        MidiMod.SoundEngine.stopAllForChar(charID)
    end
    if MidiMod.Network and MidiMod.Network.clearBuffer then
        MidiMod.Network.clearBuffer(charID)
    end

    Player.streamingCharacters[charID] = nil
end

function Player.setTempo(multiplier)
    Player.tempoMultiplier = math_max(0.25, math_min(4.0, multiplier))
end

-- ─── Seek / Progress (used by the GUI slider) ───

function Player.getDurationMs()
    local score = Player.score
    if not score or #score == 0 then return 0 end
    return score[#score].timeMs or 0
end

function Player.getPositionMs()
    if not Player.playing then return 0 end
    local pos = (getTimeMs() - Player.startTime) * Player.tempoMultiplier
    return math_max(0, math_min(pos, Player.getDurationMs()))
end

function Player.seek(targetMs)
    if not Player.playing or not Player.score then return end

    local score = Player.score
    targetMs = math_max(0, math_min(targetMs or 0, Player.getDurationMs()))

    -- Cut notes sounding right now so nothing hangs across the jump.
    -- Skipped "off" events would otherwise never release them.
    local charID = nil
    pcall(function() charID = Player.sourceCharacter.ID end)
    if MidiMod.SoundEngine then
        if charID and MidiMod.SoundEngine.stopAllForChar then
            pcall(MidiMod.SoundEngine.stopAllForChar, charID)
        else
            pcall(MidiMod.SoundEngine.stopAll)
        end
    end
    if MidiMod.Network and MidiMod.Network.clearBuffer then
        pcall(MidiMod.Network.clearBuffer, charID)
    end

    -- Remote listeners also skipped the "off" events — tell them to cut our
    -- sounding notes. NET_STOP on other clients only stops sounds for this
    -- charID; the notes we stream after the seek play normally.
    if Player.isStreamingHost and charID and not Game.IsSingleplayer then
        pcall(function()
            local msg = Networking.Start("MidiMod.Stop")
            msg.WriteUInt16(charID)
            Networking.Send(msg)
        end)
        -- NET_STOP also fires BuffStop on the server — re-arm buffs since
        -- we're still playing.
        if MidiMod.BuffsEnabled and MidiMod.Network and MidiMod.Network.notifyBuffStart then
            pcall(MidiMod.Network.notifyBuffStart, Player.sourceCharacter)
        end
    end

    -- Binary search: first event with timeMs >= targetMs
    local lo, hi = 1, #score + 1
    while lo < hi do
        local mid = math_floor((lo + hi) / 2)
        if score[mid].timeMs < targetMs then lo = mid + 1 else hi = mid end
    end
    Player.cursor = lo

    -- elapsed = (now - startTime) * tempoMultiplier  =>  shift startTime
    Player.startTime = getTimeMs() - targetMs / Player.tempoMultiplier
end

-- ─── AIM: Hold instrument via forced RMB input ───
-- Suppressed when LMB is used on an interactable target

local inputAim = nil
pcall(function() inputAim = InputType.Aim end)
inputAim = inputAim or 2

local aimSuppressUntil = 0
local AIM_SUPPRESS_DURATION = 0.5

local function hasInteractTarget(character)
    local found = false
    pcall(function()
        found = character.FocusedItem ~= nil
            or character.SelectedItem ~= nil
            or character.FocusedCharacter ~= nil
            or character.SelectedConstruction ~= nil
    end)
    return found
end

local function forceAim(character)
    if not character then return end

    local isDead = true
    pcall(function() isDead = character.IsDead end)
    if isDead then return end

    local now = os_clock()

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

-- ─── Note Playback Logic ───

local function onThink(currentInst, currentItem)
    if not Player.playing then return end
    if not Player.score then return end

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
    local batchOriginMs = nil  -- first event's timeMs in this batch

    local charID = nil
    pcall(function() charID = Player.sourceCharacter.ID end)

    local score = Player.score
    local cursor = Player.cursor
    local scoreLen = #score

    while cursor <= scoreLen do
        local event = score[cursor]
        if event.timeMs <= elapsed then
            local evType = event.type or "on"

            if evType == "on" then
                if MidiMod.SoundEngine then
                    pcall(MidiMod.SoundEngine.playNote, event.note, event.velocity, worldPos, currentInst, charID)
                end
                if Player.isStreamingHost then
                    if not batchOriginMs then batchOriginMs = event.timeMs end
                    local d = math_floor(event.timeMs - batchOriginMs + 0.5)
                    tinsert(streamBatch, d .. ":" .. event.note .. "," .. event.velocity)
                end
            elseif evType == "off" then
                if MidiMod.SoundEngine and MidiMod.SoundEngine.releaseNote then
                    pcall(MidiMod.SoundEngine.releaseNote, event.note, charID)
                end
                if Player.isStreamingHost then
                    if not batchOriginMs then batchOriginMs = event.timeMs end
                    local d = math_floor(event.timeMs - batchOriginMs + 0.5)
                    tinsert(streamBatch, d .. ":" .. event.note .. ",0")
                end
            end

            cursor = cursor + 1
        else
            break
        end
    end

    Player.cursor = cursor

    -- Send notes to other players
    if Player.isStreamingHost and #streamBatch > 0 and Player.sourceCharacter then
        local notesStr = tconcat(streamBatch, ";")
        if MidiMod.Network and MidiMod.Network.broadcastNotes then
            pcall(MidiMod.Network.broadcastNotes, charID, notesStr, currentInst)
        end
    end

    -- Song finished
    if cursor > scoreLen then
        MidiMod.Log("Playback complete")
        local wasStreaming = Player.isStreamingHost
        Player.playing = false

        -- Notify other players that we stopped
        if wasStreaming and charID and MidiMod.Network then
            pcall(MidiMod.Network.requestStop, charID)
        end
    end
end

-- ─── Injection Points ───

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
    local clockNow = os_clock()

    -- Clean up stale streaming entries (remote players who stopped)
    for charID, lastUpdate in pairs(Player.streamingCharacters) do
        if clockNow - lastUpdate > 1.0 then
            Player.streamingCharacters[charID] = nil
        end
    end

    if not Player.sourceCharacter or not Player.playing then
        return
    end

    local ch = Player.sourceCharacter

    -- Stop if character is dead or unconscious (critical state)
    local isDead, isUnconscious = false, false
    pcall(function() isDead = ch.IsDead end)
    pcall(function() isUnconscious = ch.IsUnconscious end)
    if isDead or isUnconscious then
        MidiMod.Log("Character incapacitated — stopping playback")
        if MidiMod.Network then
            pcall(MidiMod.Network.requestStop)
        else
            Player.stop()
        end
        return
    end

    -- Update streaming tracker for our own character
    pcall(function()
        Player.streamingCharacters[ch.ID] = clockNow
    end)

    -- Fail-safe aim (backup for ControlLocalPlayer patch)
    forceAim(ch)

    -- Stop if instrument was dropped
    local currentInst, currentItem = MidiMod.GetHeldInstrument(ch)
    if not currentInst then
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

    onThink(currentInst, currentItem)
end)

-- ─── BUFF SYSTEM (vanilla talent trigger) ───
-- Vanilla instrument talents (steadytune/harmonica, melodicrespite/guitar)
-- hook the OnUseRangedWeapon ability event — a real player triggers it by
-- LMB-firing the instrument. We raise the same event directly, so all vanilla
-- talent logic (charging affliction, item conditions, ally radius) runs as-is.
-- Fired ~1/sec; charging (+2, max 12) reaches the 90% buff threshold in ~6s.

if SERVER then
    local AbilityRangedWeapon = LuaUserData.CreateStatic(
        "Barotrauma.Items.Components.AbilityRangedWeapon", true)

    local playing = {} -- charID -> true

    Hook.Add("MidiMod.Server.BuffStart", "MidiMod.Server.HandleStart",
        function(charID, character)
            if character then playing[charID] = true end
        end)

    Hook.Add("MidiMod.Server.BuffStop", "MidiMod.Server.HandleStop",
        function(charID) playing[charID] = nil end)

    local acc = 0
    Hook.Add("think", "MidiMod.Server.BuffApply", function(deltaTime)
        acc = acc + (deltaTime or 0)
        if acc < 1.0 then return end
        acc = 0

        for charID in pairs(playing) do
            local character = nil
            pcall(function() character = Entity.FindEntityByID(charID) end)

            if character and not character.IsDead then
                local _, item = MidiMod.GetHeldInstrument(character)
                if item then
                    pcall(function()
                        character.CheckTalents(
                            AbilityEffectType.OnUseRangedWeapon,
                            AbilityRangedWeapon.__new(item))
                    end)
                end
            else
                playing[charID] = nil
            end
        end
    end)
end

MidiMod.Log("[Player] Loaded. RMB hold + server buffs enabled.")
