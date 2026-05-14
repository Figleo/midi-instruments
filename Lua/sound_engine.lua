-- Plays note samples in 3D, caps polyphony, and dulls sound through walls or closed doors.

MidiMod                       = MidiMod or {}
MidiMod.SoundEngine           = {}

local SoundEngine             = MidiMod.SoundEngine

local NOTE_NAMES              = {
    "C", "Cs", "D", "Ds", "E", "F", "Fs", "G", "Gs", "A", "As", "B"
}

local SAMPLE_MIN              = 24
local SAMPLE_MAX              = 107
local MAX_POLYPHONY           = 16
local MAX_PER_SAMPLE          = 4
local POOL_SIZE               = 2
local MAX_NEW_PER_FRAME       = 12
local LOAD_PER_FRAME          = 8
local SOUND_RANGE             = 1000.0
local SOUND_NEAR              = 35.0

local FREQ_MIN                = 0.25
local FREQ_MAX                = 4.0

local MUFFLE_GAIN             = 0.15 -- Volume when a solid wall is between listener and source.
local MUFFLE_DOOR_GAIN        = 0.55 -- Open door between rooms.
local MUFFLE_CHECK_MS         = 100  -- Cheap enough to skip most frames.

-- trying to fiure out not to make a mess with fast midi
local MAX_SAME_NOTE           = 1

-- stopAll can recurse from Dispose callbacks; guard that.
local _isStopping             = false
local _lastStopAllTime        = 0
local STOP_ALL_DEBOUNCE_MS    = 50

local _lastCleanupTime        = 0
local CLEANUP_THROTTLE_MS     = 30

SoundEngine.soundBanks        = {}
SoundEngine.soundBankIdx      = {}
SoundEngine.activeChannels    = {}
SoundEngine.noteQueue         = {}
SoundEngine.protectedChannels = {}
SoundEngine.notesThisFrame    = 0
SoundEngine.initialized       = false
SoundEngine.volumeMultiplier  = 1.0

local _loadQueue              = nil
local _loadDone               = false
local _loadSamplesLoaded      = 0
local _loadObjectsLoaded      = 0

local _wallCheckAvailable     = nil
local _gapIterMethod          = nil
local _lastMuffleCheck        = 0
local _muffleLogCount         = 0
local _weAreSettingPitch      = false

local function noteToName(midiNote)
    local octave = math.floor(midiNote / 12) - 1
    local noteIndex = (midiNote % 12) + 1
    return NOTE_NAMES[noteIndex] .. octave
end

-- Kick off background loading; the think hook drains a few files per frame.
function SoundEngine.init()
    if SoundEngine.initialized or _loadQueue ~= nil then return end

    local instruments = { "accordion", "guitar", "harmonica" }
    _loadQueue = {}

    for _, inst in ipairs(instruments) do
        SoundEngine.soundBanks[inst]   = {}
        SoundEngine.soundBankIdx[inst] = {}

        local soundDir                 = MidiMod.BasePath .. "Sounds/" .. inst .. "_notes/"
        for noteNum = SAMPLE_MIN, SAMPLE_MAX do
            local name = noteToName(noteNum)
            local path = soundDir .. inst .. "_" .. name .. ".ogg"
            table.insert(_loadQueue, { inst = inst, noteNum = noteNum, path = path })
        end
    end

    MidiMod.Log(string.format("[SoundEngine] Chunked load started: %d jobs across %d instruments.",
        #_loadQueue, #instruments))
end

local function pumpLoadQueue()
    if _loadQueue == nil or _loadDone then return end

    local processed = 0
    while #_loadQueue > 0 and processed < LOAD_PER_FRAME do
        local job = table.remove(_loadQueue, 1)
        processed = processed + 1

        local fileExists = false
        pcall(function()
            if File and File.Exists then
                fileExists = File.Exists(job.path)
            else
                local f = io.open(job.path, "r")
                if f then
                    f:close(); fileExists = true
                end
            end
        end)

        if fileExists then
            local ok, firstSound = pcall(function()
                return Game.SoundManager.LoadSound(job.path)
            end)
            if ok and firstSound then
                local pool = { firstSound }
                for copy = 2, POOL_SIZE do
                    local ok2, extra = pcall(function()
                        return Game.SoundManager.LoadSound(job.path)
                    end)
                    pool[copy] = (ok2 and extra) or firstSound
                end
                SoundEngine.soundBanks[job.inst][job.noteNum]   = pool
                SoundEngine.soundBankIdx[job.inst][job.noteNum] = 0
                _loadSamplesLoaded                              = _loadSamplesLoaded + 1
                _loadObjectsLoaded                              = _loadObjectsLoaded + #pool
            end
        end
    end

    if #_loadQueue == 0 then
        _loadDone = true
        SoundEngine.initialized = true
        MidiMod.Log(string.format(
            "[SoundEngine] Load complete: %d samples (%d objects).",
            _loadSamplesLoaded, _loadObjectsLoaded))
    end
end

local function getNextSound(inst, noteNum)
    local pool = SoundEngine.soundBanks[inst][noteNum]
    if not pool then return nil end

    local idx = SoundEngine.soundBankIdx[inst][noteNum]
    idx = (idx % #pool) + 1
    SoundEngine.soundBankIdx[inst][noteNum] = idx

    return pool[idx]
end

-- Nearest recorded note plus pitch multiplier when we lack an exact sample.
local function findClosestSample(midiNote, bank)
    if bank[midiNote] then return midiNote, 1.0 end

    local clamped = math.max(SAMPLE_MIN, math.min(SAMPLE_MAX, midiNote))
    if bank[clamped] then
        return clamped, 2 ^ ((midiNote - clamped) / 12)
    end

    for offset = 1, 127 do
        local above = clamped + offset
        if bank[above] then
            return above, 2 ^ ((midiNote - above) / 12)
        end
        local below = clamped - offset
        if bank[below] then
            return below, 2 ^ ((midiNote - below) / 12)
        end
    end
    return nil, 1.0
end

local function safeAlive(ch)
    if not ch then return false end
    local ok, playing = pcall(function() return ch.IsPlaying end)
    return ok and playing == true
end

local function safeDisposeChannelObject(ch, fade)
    if not ch then return end
    SoundEngine.protectedChannels[ch] = nil
    if fade then
        pcall(function() ch.FadeOutAndDispose(0.02) end)
    else
        pcall(function() ch.Dispose() end)
    end
end

local function removeChannelAt(idx, fade)
    local info = SoundEngine.activeChannels[idx]
    if info then
        safeDisposeChannelObject(info.channel, fade)
    end
    table.remove(SoundEngine.activeChannels, idx)
end

local function fadeDisposeChannel(idx)
    removeChannelAt(idx, true)
end

local function disposeChannel(idx)
    removeChannelAt(idx, false)
end

local function voiceSteal(sampleNote, instrument, charID)
    local count = 0
    local oldestIdx = nil

    for i, info in ipairs(SoundEngine.activeChannels) do
        if info.sampleNote == sampleNote
            and info.instrument == instrument
            and info.charID == charID then
            count = count + 1
            if not oldestIdx then oldestIdx = i end
        end
    end

    if count >= MAX_PER_SAMPLE and oldestIdx then
        fadeDisposeChannel(oldestIdx)
    end
end

local function cleanupDead()
    local now = os.clock() * 1000
    if (now - _lastCleanupTime) < CLEANUP_THROTTLE_MS then return end
    _lastCleanupTime = now

    for i = #SoundEngine.activeChannels, 1, -1 do
        if not safeAlive(SoundEngine.activeChannels[i].channel) then
            disposeChannel(i)
        end
    end
end

local function evictOldestForChar(charID)
    for i, info in ipairs(SoundEngine.activeChannels) do
        if info.charID == charID then
            fadeDisposeChannel(i)
            return
        end
    end
end

local function countChannelsForChar(charID)
    local n = 0
    for _, info in ipairs(SoundEngine.activeChannels) do
        if info.charID == charID then n = n + 1 end
    end
    return n
end

local function getHullGaps(hull)
    local gaps = {}
    if not hull then return gaps end

    if _gapIterMethod == nil or _gapIterMethod == "enum" then
        local ok = pcall(function()
            for gap in hull.ConnectedGaps do
                table.insert(gaps, gap)
            end
        end)
        if ok and #gaps > 0 then
            if _gapIterMethod == nil then
                _gapIterMethod = "enum"
                MidiMod.Log("[Muffle] Gap iteration method: enum (for...in)")
            end
            return gaps
        end
    end

    if _gapIterMethod == nil or _gapIterMethod == "count" then
        local ok = pcall(function()
            local cg = hull.ConnectedGaps
            if cg and cg.Count then
                for i = 0, cg.Count - 1 do
                    table.insert(gaps, cg[i])
                end
            end
        end)
        if ok and #gaps > 0 then
            if _gapIterMethod == nil then
                _gapIterMethod = "count"
                MidiMod.Log("[Muffle] Gap iteration method: count (indexed)")
            end
            return gaps
        end
    end

    if _gapIterMethod == nil then
        local ok = pcall(function()
            local cg = hull.ConnectedGaps
            if cg and cg.Length then
                for i = 0, cg.Length - 1 do
                    table.insert(gaps, cg[i])
                end
            end
        end)
        if ok and #gaps > 0 then
            _gapIterMethod = "count"
            MidiMod.Log("[Muffle] Gap iteration method: Length (indexed)")
            return gaps
        end
    end

    if _gapIterMethod == nil then
        _gapIterMethod = false
        MidiMod.Log("[Muffle] WARNING: Cannot iterate hull.ConnectedGaps; door detection disabled")
    end

    return gaps
end

local function gapConnectsTo(gap, targetHull)
    local connects = false

    pcall(function()
        for entity in gap.linkedTo do
            if entity == targetHull then
                connects = true
            end
        end
    end)
    if connects then return true end

    pcall(function()
        local l0 = gap.linkedTo[0]
        local l1 = gap.linkedTo[1]
        if l0 == targetHull or l1 == targetHull then
            connects = true
        end
    end)
    if connects then return true end

    pcall(function()
        local l1 = gap.linkedTo[1]
        local l2 = gap.linkedTo[2]
        if l1 == targetHull or l2 == targetHull then
            connects = true
        end
    end)

    return connects
end

-- Returns none (same space), open (door between hulls), or wall (blocked).
local function checkWallStatus(sourceWorldPos)
    if _wallCheckAvailable == false then return "none" end
    if not sourceWorldPos then return "none" end

    local listener = nil
    pcall(function() listener = Character.Controlled end)
    if not listener then return "none" end

    local listenerPos = nil
    pcall(function() listenerPos = listener.WorldPosition end)
    if not listenerPos then return "none" end

    local sourceHull = nil
    local listenerHull = nil

    local ok1 = pcall(function()
        sourceHull = Hull.FindHull(Vector2(sourceWorldPos.X, sourceWorldPos.Y))
    end)

    if not ok1 then
        if _wallCheckAvailable == nil then
            _wallCheckAvailable = false
            MidiMod.Log("[Muffle] Hull.FindHull NOT available; wall muffle disabled")
        end
        return "none"
    end

    if _wallCheckAvailable == nil then
        _wallCheckAvailable = true
        MidiMod.Log("[Muffle] Hull.FindHull available; wall muffle enabled.")
    end

    pcall(function()
        listenerHull = Hull.FindHull(Vector2(listenerPos.X, listenerPos.Y))
    end)

    if sourceHull == listenerHull then return "none" end

    if not sourceHull and not listenerHull then return "none" end

    if not sourceHull or not listenerHull then return "wall" end

    if _gapIterMethod ~= false then
        local gaps = getHullGaps(sourceHull)

        for _, gap in ipairs(gaps) do
            if gapConnectsTo(gap, listenerHull) then
                local openAmount = 0
                pcall(function() openAmount = gap.Open end)

                if openAmount > 0.1 then
                    if _muffleLogCount < 3 then
                        _muffleLogCount = _muffleLogCount + 1
                        MidiMod.Log("[Muffle] Open door detected (open=" ..
                            string.format("%.2f", openAmount) .. ")")
                    end
                    return "open"
                end
            end
        end
    end

    if _muffleLogCount < 3 then
        _muffleLogCount = _muffleLogCount + 1
        MidiMod.Log("[Muffle] Wall/closed door detected between hulls")
    end
    return "wall"
end

local function doPlayNote(midiNote, velocity, worldPos, instrument, charID)
    local bank = SoundEngine.soundBanks[instrument]
    if not bank or not next(bank) then
        bank = SoundEngine.soundBanks["accordion"]
        instrument = "accordion"
    end

    local sampleNote, freqMult = findClosestSample(midiNote, bank)
    if not sampleNote then return nil end

    local finalFreq = math.max(FREQ_MIN, math.min(FREQ_MAX, freqMult))

    -- Skip notes that would need an extreme retune (avoids bad edge cases).
    if freqMult < FREQ_MIN or freqMult > FREQ_MAX then
        if math.abs(freqMult - finalFreq) > 0.05 then
            return nil
        end
    end

    cleanupDead()
    local sameNoteCount = 0
    local oldestSameNoteIdx = nil

    for i, info in ipairs(SoundEngine.activeChannels) do
        if info.note == midiNote and info.instrument == instrument then
            sameNoteCount = sameNoteCount + 1
            if not oldestSameNoteIdx then
                oldestSameNoteIdx = i
            end
        end
    end

    if sameNoteCount >= MAX_SAME_NOTE and oldestSameNoteIdx then
        fadeDisposeChannel(oldestSameNoteIdx)
    end

    voiceSteal(sampleNote, instrument, charID)
    while countChannelsForChar(charID) >= MAX_POLYPHONY do
        evictOldestForChar(charID)
    end

    local sound = getNextSound(instrument, sampleNote)
    if not sound then return nil end

    local rawGain    = math.min(1.0, (velocity / 127))
    local volumeMult = MidiMod.CurrentVolume or SoundEngine.volumeMultiplier or 1.0
    local baseGain   = rawGain * volumeMult

    local wallStatus = checkWallStatus(worldPos)
    local playGain   = baseGain
    if wallStatus == "wall" then
        playGain = baseGain * MUFFLE_GAIN
    elseif wallStatus == "open" then
        playGain = baseGain * MUFFLE_DOOR_GAIN
    end

    local channel = nil

    if worldPos then
        local ok, ch = pcall(function()
            return sound.Play(playGain, SOUND_RANGE, Vector2(worldPos.X, worldPos.Y))
        end)
        if ok and ch then channel = ch end
    end

    if not channel then
        local ok, ch = pcall(function()
            return sound.Play(playGain, SOUND_RANGE)
        end)
        if ok and ch then channel = ch end
    end

    if not channel then return nil end

    SoundEngine.protectedChannels[channel] = finalFreq

    MidiMod.Log(string.format("[PitchLog] Note: %d (%s) | Inst: %s | Sample: %d | Mult: %.4f",
        midiNote, noteToName(midiNote), instrument, sampleNote, finalFreq))

    _weAreSettingPitch = true
    pcall(function() channel.FrequencyMultiplier = finalFreq end)
    _weAreSettingPitch = false
    if worldPos then
        pcall(function() channel.Near = SOUND_NEAR end)
        pcall(function() channel.Far = SOUND_RANGE end)
        pcall(function() channel.Position = Vector3(worldPos.X, worldPos.Y, 0) end)
    end

    table.insert(SoundEngine.activeChannels, {
        channel    = channel,
        note       = midiNote,
        sampleNote = sampleNote,
        instrument = instrument,
        freqMult   = finalFreq,
        rawGain    = rawGain,
        baseGain   = baseGain,
        worldPos   = worldPos,
        wallStatus = wallStatus,
        playTime   = os.clock(),
        charID     = charID
    })

    return channel
end

function SoundEngine.playNote(midiNote, velocity, worldPos, instrument, charID)
    if not SoundEngine.initialized then SoundEngine.init() end
    instrument = instrument or "accordion"

    for _, queued in ipairs(SoundEngine.noteQueue) do
        if queued.midiNote == midiNote and queued.instrument == instrument then
            queued.velocity = math.max(queued.velocity, velocity)
            return nil
        end
    end

    if SoundEngine.notesThisFrame < MAX_NEW_PER_FRAME then
        SoundEngine.notesThisFrame = SoundEngine.notesThisFrame + 1
        return doPlayNote(midiNote, velocity, worldPos, instrument, charID)
    end

    if #SoundEngine.noteQueue < 64 then
        table.insert(SoundEngine.noteQueue, {
            midiNote   = midiNote,
            velocity   = velocity,
            worldPos   = worldPos,
            instrument = instrument,
            charID     = charID
        })
    end
    return nil
end

Hook.Add("think", "midi_sound_tick", function()
    if not CLIENT then return end

    pumpLoadQueue()

    SoundEngine.notesThisFrame = 0

    local now = os.clock() * 1000

    cleanupDead()

    if _wallCheckAvailable ~= false and (now - _lastMuffleCheck) > MUFFLE_CHECK_MS then
        _lastMuffleCheck = now

        for _, info in ipairs(SoundEngine.activeChannels) do
            local newStatus = checkWallStatus(info.worldPos)

            if newStatus ~= info.wallStatus then
                info.wallStatus = newStatus

                local effGain = info.rawGain * (MidiMod.CurrentVolume or SoundEngine.volumeMultiplier)
                local newGain = effGain
                if newStatus == "wall" then
                    newGain = effGain * MUFFLE_GAIN
                elseif newStatus == "open" then
                    newGain = effGain * MUFFLE_DOOR_GAIN
                end

                pcall(function() info.channel.Gain = newGain end)
            end
        end
    end

    for _, info in ipairs(SoundEngine.activeChannels) do
        _weAreSettingPitch = true
        pcall(function() info.channel.FrequencyMultiplier = info.freqMult end)
        _weAreSettingPitch = false
    end

    local played = 0
    while #SoundEngine.noteQueue > 0 and played < MAX_NEW_PER_FRAME do
        local entry = table.remove(SoundEngine.noteQueue, 1)
        doPlayNote(entry.midiNote, entry.velocity, entry.worldPos, entry.instrument, entry.charID)
        played = played + 1
    end

    while #SoundEngine.noteQueue > 48 do
        table.remove(SoundEngine.noteQueue, 1)
    end
end)

-- SPW патч: защищаем FrequencyMultiplier от перезаписи.
-- Только на клиенте — Barotrauma.Sounds.SoundChannel не существует на сервере.
if CLIENT then
    Hook.Patch(
        "Barotrauma.Sounds.SoundChannel",
        "set_FrequencyMultiplier",
        function(instance, ptable)
            if _weAreSettingPitch then return end
            if not instance then return end

            local desired = SoundEngine.protectedChannels[instance]
            if not desired then return end
            _weAreSettingPitch = true
            pcall(function() instance.FrequencyMultiplier = desired end)
            _weAreSettingPitch = false
        end,
        Hook.HookMethodType.After
    )
end

function SoundEngine.stopNote(midiNote)
    for i = #SoundEngine.noteQueue, 1, -1 do
        if SoundEngine.noteQueue[i].midiNote == midiNote then
            table.remove(SoundEngine.noteQueue, i)
        end
    end

    for i = #SoundEngine.activeChannels, 1, -1 do
        if SoundEngine.activeChannels[i].note == midiNote then
            fadeDisposeChannel(i)
        end
    end
end

function SoundEngine.stopAll()
    if _isStopping then return end

    local now = os.clock() * 1000
    if (now - _lastStopAllTime) < STOP_ALL_DEBOUNCE_MS then return end
    _lastStopAllTime = now

    _isStopping = true
    SoundEngine.noteQueue = {}
    SoundEngine.notesThisFrame = 0
    for i = #SoundEngine.activeChannels, 1, -1 do
        disposeChannel(i)
    end
    _isStopping = false
end

function SoundEngine.stopAllForChar(charID)
    if not charID then return end

    for i = #SoundEngine.noteQueue, 1, -1 do
        if SoundEngine.noteQueue[i].charID == charID then
            table.remove(SoundEngine.noteQueue, i)
        end
    end

    for i = #SoundEngine.activeChannels, 1, -1 do
        if SoundEngine.activeChannels[i].charID == charID then
            fadeDisposeChannel(i)
        end
    end
end

-- Apply master volume to every live channel right away.
function SoundEngine.setVolume(v)
    v = math.max(0.0, math.min(1.0, v))
    SoundEngine.volumeMultiplier = v

    for _, info in ipairs(SoundEngine.activeChannels) do
        local effGain = (info.rawGain or info.baseGain) * v
        local newGain = effGain
        if info.wallStatus == "wall" then
            newGain = effGain * MUFFLE_GAIN
        elseif info.wallStatus == "open" then
            newGain = effGain * MUFFLE_DOOR_GAIN
        end

        pcall(function() info.channel.Gain = newGain end)
    end
end

MidiMod.Log("[SoundEngine] Pitch protection via per-frame re-apply")
