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

-- Jam (play together): performers we could mirror, fed by NET_JAM announces.
-- Only real performers (with a local file) are listed - mirrors are not.
-- charID -> { fileName, receivedAt }
Player.activePerformers    = {}
-- Who mirrors whom, fed by the same announces. All clients need this map to
-- duplicate a leader's note stream onto each mirror's instrument.
-- mirrorCharID -> { leaderID, receivedAt }
Player.jamMirrors          = {}
-- Leader we mirror ourselves; nil when not mirroring. The mod holds no score
-- in mirror mode - the leader's stream is our sheet music. When the leader's
-- stop arrives we stop too.
Player.jamLeaderID         = nil

-- How long an announce entry stays valid without a refresh
local PERFORMER_TTL_SEC    = 5.0
-- How often we announce our own playback / mirroring
local JAM_ANNOUNCE_SEC     = 2.0
local _lastJamAnnounce     = 0
-- A mirror gives up on its leader after this long without an announce. The
-- leader left, crashed or its mod died - no NET_STOP is ever coming, so this
-- is the only thing that can end the session. Three announce intervals, so a
-- couple of lost packets do not kick a mirror out of a live jam.
local LEADER_LOST_SEC      = JAM_ANNOUNCE_SEC * 3

local pcall                = pcall
local pairs                = pairs
local math_max             = math.max
local math_min             = math.min
local math_floor           = math.floor
local os_clock             = os.clock
local tinsert              = table.insert
local tconcat              = table.concat

-- === MIDI Loading ===

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

-- === Time ===

local function getTimeMs()
    if Timing and Timing.TotalTime then
        return Timing.TotalTime * 1000
    end
    return os_clock() * 1000
end

-- === Transport Controls ===

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

    -- Get our own charID before the state is cleared. Stopping our song must
    -- only cut our own notes, otherwise we also kill the notes other players
    -- are streaming to us.
    local charID = nil
    pcall(function()
        local ch = Player.sourceCharacter
        if not ch and CLIENT then ch = Character.Controlled end
        if ch then charID = ch.ID end
    end)

    Player.playing = false
    Player.cursor = 1
    Player.sourceCharacter = nil
    Player.isStreamingHost = false
    Player.instrumentDropped = false
    Player.jamLeaderID = nil

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

    if wasPlaying then
        MidiMod.Log("Playback stopped")
    end
end

-- Per-player stop: for network, stops sounds from a specific remote character
function Player.stopChar(charID)
    -- They are no longer performing / mirroring
    Player.activePerformers[charID] = nil
    Player.jamMirrors[charID] = nil

    -- If this is our own character, do a full stop
    if Player.sourceCharacter then
        local ourID = nil
        pcall(function() ourID = Player.sourceCharacter.ID end)
        if ourID and ourID == charID then
            Player.stop()
            return
        end
    end

    -- Cascade: the leader we mirror stopped, so we stop too. Clear
    -- jamLeaderID BEFORE requestStop - our own stop comes back through here
    -- and must not loop. Our requestStop notifies the rest as a normal
    -- NET_STOP, so they cut our sounds and drop us from their mirror maps.
    if Player.jamLeaderID and Player.jamLeaderID == charID then
        Player.jamLeaderID = nil
        MidiMod.Log("Jam leader stopped - stopping")
        if MidiMod.Network then
            pcall(MidiMod.Network.requestStop)
        end
        -- Fall through: still cut the leader's sounds below
    end

    -- Otherwise just stop all sounds for that remote character
    -- (stopAllForChar already clears activeNoteUIDs[charID])
    if MidiMod.SoundEngine and MidiMod.SoundEngine.stopAllForChar then
        MidiMod.SoundEngine.stopAllForChar(charID)
    end
    if MidiMod.Network and MidiMod.Network.clearBuffer then
        MidiMod.Network.clearBuffer(charID)
    end
end

function Player.setTempo(multiplier)
    Player.tempoMultiplier = math_max(0.25, math_min(4.0, multiplier))
end

-- === Jam (play together) ===

-- Live performers we can mirror: expired entries are dropped, our own
-- character is skipped. Returns charID -> entry (same tables as
-- activePerformers, do not mutate).
function Player.getPerformers()
    local now = os_clock()
    local ourID = nil
    pcall(function()
        local ch = Character.Controlled
        if ch then ourID = ch.ID end
    end)

    local result = {}
    for charID, entry in pairs(Player.activePerformers) do
        if (now - entry.receivedAt) > PERFORMER_TTL_SEC then
            Player.activePerformers[charID] = nil
        elseif charID ~= ourID then
            result[charID] = entry
        end
    end
    return result
end

-- Characters currently mirroring leaderID, as an array of charIDs.
-- Expired mirror entries are dropped on the way.
function Player.getMirrorsOf(leaderID)
    local now = os_clock()
    local result = nil
    for charID, entry in pairs(Player.jamMirrors) do
        if (now - entry.receivedAt) > PERFORMER_TTL_SEC then
            Player.jamMirrors[charID] = nil
        elseif entry.leaderID == leaderID then
            result = result or {}
            result[#result + 1] = charID
        end
    end
    return result
end

-- Progress of the leader we mirror, as posMs, durMs. Returns nil when we are
-- not mirroring or the leader has not reported a duration yet.
--
-- The leader announces its progress once every JAM_ANNOUNCE_SEC, so between
-- announces we advance the reported position by our own elapsed time. That
-- keeps the bar moving smoothly and resyncs on every announce. Tempo is not
-- factored in: it is always 1.0 in practice, and a resync every couple of
-- seconds bounds any drift anyway.
function Player.getJamProgress()
    local leaderID = Player.jamLeaderID
    if not leaderID then return nil end

    local entry = Player.activePerformers[leaderID]
    if not entry or not entry.durMs or entry.durMs <= 0 then return nil end

    local elapsedMs = (os_clock() - entry.receivedAt) * 1000
    local posMs = math_min((entry.posMs or 0) + elapsedMs, entry.durMs)
    return math_max(0, posMs), entry.durMs
end

-- Cut everything currently sounding for a character, without touching jam
-- links, buffs or playback state. This is what a seek needs: the "off" events
-- for the notes sounding right now sit on the other side of the jump and are
-- skipped, so those notes would hang forever - but the performer is still
-- playing and the band must stay together.
function Player.cutChar(charID)
    if not charID then return end

    local ourID = nil
    pcall(function() ourID = Character.Controlled.ID end)

    local function cut(id)
        if MidiMod.SoundEngine and MidiMod.SoundEngine.stopAllForChar then
            pcall(MidiMod.SoundEngine.stopAllForChar, id)
        end
        if MidiMod.Network and MidiMod.Network.clearBuffer then
            pcall(MidiMod.Network.clearBuffer, id)
        end
    end

    cut(charID)

    -- The performer's notes are duplicated onto every mirror's instrument,
    -- so those copies hang too and have to go with them. Our own id is
    -- handled below, charID is already done.
    local mirrors = Player.getMirrorsOf(charID)
    if mirrors then
        for i = 1, #mirrors do
            local mID = mirrors[i]
            if mID ~= charID and mID ~= ourID then cut(mID) end
        end
    end

    -- If we mirror this performer ourselves we are missing from the list
    -- above: our own jam announce is never relayed back to us. Same asymmetry
    -- that Network.playStreamedNotes works around when building its targets.
    if Player.jamLeaderID == charID and ourID and ourID ~= charID then
        cut(ourID)
    end
end

-- === Seek / Progress (used by the GUI slider) ===

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
    if charID then
        Player.cutChar(charID)
    elseif MidiMod.SoundEngine then
        pcall(MidiMod.SoundEngine.stopAll)
    end

    -- Remote listeners skipped those "off" events too, so tell them to drop
    -- our sounding notes. This used to reuse NET_STOP, which every mirror
    -- reads as "the leader stopped" - moving the slider threw the whole band
    -- out of the jam. NET_CUT only cuts the sound: jam links survive, the
    -- server does not fire BuffStop, and the notes we stream after the jump
    -- play normally.
    if Player.isStreamingHost and charID and not Game.IsSingleplayer then
        if MidiMod.Network and MidiMod.Network.requestCut then
            pcall(MidiMod.Network.requestCut, charID)
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

-- === AIM: Hold instrument via forced RMB input ===
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

-- === Note Playback Logic ===

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
    local batchOriginMs = nil -- first event's timeMs in this batch

    local charID = nil
    pcall(function() charID = Player.sourceCharacter.ID end)

    local score = Player.score
    local cursor = Player.cursor
    local scoreLen = #score

    -- Characters mirroring us: our own client never receives our NET_NOTES
    -- back, so we duplicate our notes onto the mirrors right here.
    local mirrors = nil
    if charID then
        mirrors = Player.getMirrorsOf(charID)
    end
    local mirrorTargets = nil
    if mirrors then
        mirrorTargets = {}
        for i = 1, #mirrors do
            local mChar = nil
            pcall(function() mChar = Entity.FindEntityByID(mirrors[i]) end)
            if mChar then
                local mInst, mItem = MidiMod.GetHeldInstrument(mChar)
                if mInst then
                    local mPos = nil
                    pcall(function() mPos = mItem.WorldPosition end)
                    mirrorTargets[#mirrorTargets + 1] = { id = mirrors[i], inst = mInst, pos = mPos }
                end
            end
        end
    end

    while cursor <= scoreLen do
        local event = score[cursor]
        if event.timeMs <= elapsed then
            local evType = event.type or "on"

            if evType == "on" then
                if MidiMod.SoundEngine then
                    pcall(MidiMod.SoundEngine.playNote, event.note, event.velocity, worldPos, currentInst, charID)
                    if mirrorTargets then
                        for i = 1, #mirrorTargets do
                            local t = mirrorTargets[i]
                            pcall(MidiMod.SoundEngine.playNote, event.note, event.velocity, t.pos, t.inst, t.id)
                        end
                    end
                end
                if Player.isStreamingHost then
                    if not batchOriginMs then batchOriginMs = event.timeMs end
                    local d = math_floor(event.timeMs - batchOriginMs + 0.5)
                    tinsert(streamBatch, d .. ":" .. event.note .. "," .. event.velocity)
                end
            elseif evType == "off" then
                if MidiMod.SoundEngine and MidiMod.SoundEngine.releaseNote then
                    pcall(MidiMod.SoundEngine.releaseNote, event.note, charID)
                    if mirrorTargets then
                        for i = 1, #mirrorTargets do
                            pcall(MidiMod.SoundEngine.releaseNote, event.note, mirrorTargets[i].id)
                        end
                    end
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

    -- Announce "we perform file X" so others see us in the jam list.
    -- Only the file name goes over the wire, purely as a label.
    if Player.isStreamingHost and charID and Player.currentFile then
        local clockNow = os_clock()
        if (clockNow - _lastJamAnnounce) >= JAM_ANNOUNCE_SEC then
            _lastJamAnnounce = clockNow
            if MidiMod.Network and MidiMod.Network.broadcastJamAnnounce then
                local fileName = string.match(Player.currentFile, "([^/\\]+)$") or Player.currentFile
                -- Progress rides along so mirrors can draw a progress bar
                pcall(MidiMod.Network.broadcastJamAnnounce, charID, fileName, 0,
                    math_floor(Player.getPositionMs() / 1000),
                    math_floor(Player.getDurationMs() / 1000))
            end
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

-- === Injection Points ===

-- ControlLocalPlayer fires every C# frame - most reliable for aim forcing
pcall(function()
    Hook.Patch(
        "Barotrauma.Character",
        "ControlLocalPlayer",
        function(instance, ptable)
            -- Performing: force the pose on our own performing character.
            -- Mirroring: we hold no score, so playing is false and
            -- sourceCharacter is nil - but the pose still has to be forced,
            -- or other players see us standing with the instrument lowered
            -- while notes come out of it. The think hook calls forceAim too,
            -- but only this patch runs at the point in the frame where the
            -- forced input survives to be networked.
            local target = nil
            if Player.playing then
                target = Player.sourceCharacter
            elseif Player.jamLeaderID then
                target = Character.Controlled
            end
            if not target or instance ~= target then return end
            forceAim(instance)
        end,
        Hook.HookMethodType.After
    )
    MidiMod.DebugLog("[Player] ControlLocalPlayer.After patch applied")
end)

-- Mirror mode think: we have no score, we just follow a leader. Keep the
-- RMB pose, re-announce the mirror link, stop on the usual conditions.
local function mirrorThink()
    local ch = Character.Controlled
    if not ch then
        -- No character to mirror with: round ended, spectating, respawning.
        -- Returning here would park the think hook on the mirror branch
        -- forever - status stuck on "Playing together" and the whole jam list
        -- suppressed, with no way out but a manual Stop. Nobody can be
        -- notified without a character, so just tear down locally.
        Player.jamLeaderID = nil
        Player.stop()
        return
    end

    local charID = nil
    pcall(function() charID = ch.ID end)

    -- Same stop conditions as normal playback
    local isDead, isUnconscious = false, false
    pcall(function() isDead = ch.IsDead end)
    pcall(function() isUnconscious = ch.IsUnconscious end)
    local currentInst = MidiMod.GetHeldInstrument(ch)

    if isDead or isUnconscious or not currentInst then
        MidiMod.Log("Mirror interrupted - stopping")
        Player.jamLeaderID = nil
        if MidiMod.Network then
            pcall(MidiMod.Network.requestStop)
        end
        return
    end

    -- The leader stopped announcing: it disconnected, crashed, or its mod
    -- died. Its NET_STOP is never arriving, and nothing else ends a mirror -
    -- we would stand in the playing pose, silent, in "Playing together"
    -- until the player hits Stop by hand.
    local leaderID    = Player.jamLeaderID
    local leaderEntry = Player.activePerformers[leaderID]
    if not leaderEntry or (os_clock() - leaderEntry.receivedAt) > LEADER_LOST_SEC then
        MidiMod.Log("Jam leader is gone - stopping")
        -- Clear the link BEFORE requesting our own stop, same as the cascade
        -- in stopChar: our stop echoes back through stopChar and must not loop.
        Player.jamLeaderID = nil
        if MidiMod.Network then
            pcall(MidiMod.Network.requestStop)
        end
        -- Drop the leader from the jam list and cut whatever of its notes is
        -- still sounding or sitting in the jitter buffer.
        Player.stopChar(leaderID)
        return
    end

    forceAim(ch)

    -- Re-announce so late joiners and packet loss do not break the link
    local clockNow = os_clock()
    if (clockNow - _lastJamAnnounce) >= JAM_ANNOUNCE_SEC then
        _lastJamAnnounce = clockNow
        if charID and MidiMod.Network and MidiMod.Network.broadcastJamAnnounce then
            -- A mirror has no score of its own, so no progress to report
            pcall(MidiMod.Network.broadcastJamAnnounce, charID, "", Player.jamLeaderID, 0, 0)
        end
    end
end

-- Think hook: note playback + aim backup
Hook.Add("think", "MidiMod.Player.Think", function()
    -- Mirroring another performer: separate lightweight path
    if Player.jamLeaderID and not Player.playing then
        mirrorThink()
        return
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
        MidiMod.Log("Character incapacitated - stopping playback")
        if MidiMod.Network then
            pcall(MidiMod.Network.requestStop)
        else
            Player.stop()
        end
        return
    end

    -- Fail-safe aim (backup for ControlLocalPlayer patch)
    forceAim(ch)

    -- Stop if instrument was dropped
    local currentInst, currentItem = MidiMod.GetHeldInstrument(ch)
    if not currentInst then
        if not Player.instrumentDropped then
            Player.instrumentDropped = true
            MidiMod.Log("Instrument dropped - stopping playback")
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

-- === BUFF SYSTEM (vanilla talent trigger) ===
-- Vanilla instrument talents (steadytune/harmonica, melodicrespite/guitar)
-- hook the OnUseRangedWeapon ability event - a real player triggers it by
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

            local isDead = true
            local ok = pcall(function() isDead = character.IsDead end)

            -- A player who disconnects mid-song leaves their body in the round,
            -- alive and still holding the instrument - so neither the death
            -- check nor the item check below notices they are gone, and their
            -- talent buffs would keep charging for the rest of the round.
            local connected = false
            pcall(function()
                for _, c in pairs(Client.ClientList) do
                    if c.Character and c.Character.ID == charID then
                        connected = true
                        break
                    end
                end
            end)

            if character and ok and not isDead and connected then
                local _, item = MidiMod.GetHeldInstrument(character)
                if item then
                    pcall(function()
                        character.CheckTalents(
                            AbilityEffectType.OnUseRangedWeapon,
                            AbilityRangedWeapon.__new(item))
                    end)
                else
                    -- Instrument holstered or dropped without a Stop reaching us
                    playing[charID] = nil
                end
            else
                playing[charID] = nil
            end
        end
    end)
end

MidiMod.Log("[Player] Loaded. RMB hold + server buffs enabled.")
