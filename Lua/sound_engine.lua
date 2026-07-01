-- Sound Engine: Positional audio + Voice Stealing + Volume control

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

-- stopAll re-entry and debounce guards
local _isStopping             = false
local _lastStopAllTime        = 0
local STOP_ALL_DEBOUNCE_MS    = 50

-- cleanupDead throttle
local _lastCleanupTime        = 0
local CLEANUP_THROTTLE_MS     = 30

SoundEngine.soundBanks        = {}
SoundEngine.soundBankIdx      = {}
SoundEngine.activeChannels    = {}
SoundEngine.noteQueue         = {}
SoundEngine.activeNoteUIDs    = {}
SoundEngine.notesThisFrame    = 0
SoundEngine.initialized       = false


-- Chunked loading state
local _loadQueue         = nil
local _loadDone          = false
local _loadSamplesLoaded = 0
local _loadObjectsLoaded = 0


local function noteToName(midiNote)
    local octave = math.floor(midiNote / 12) - 1
    local noteIndex = (midiNote % 12) + 1
    return NOTE_NAMES[noteIndex] .. octave
end

local _channelUidCounter = 0

local function nextUID()
    _channelUidCounter = _channelUidCounter + 1
    return _channelUidCounter
end

-- Begin chunked loading — call once, then pump via think hook
function SoundEngine.init()
    if SoundEngine.initialized or _loadQueue ~= nil then return end

    local instruments = { "accordion", "guitar", "guitarelectric", "harmonica" }
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

-- Process up to LOAD_PER_FRAME jobs per frame
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

-- Channel lifecycle helpers

local function safeAlive(ch)
    if not ch then return false end
    local ok, playing = pcall(function() return ch.IsPlaying end)
    return ok and playing == true
end

local function safeDisposeChannelObject(ch, fade)
    if not ch then return end
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

local function voiceSteal(sampleNote, instrument)
    local count = 0
    local oldestIdx = nil

    for i, info in ipairs(SoundEngine.activeChannels) do
        if info.sampleNote == sampleNote and info.instrument == instrument then
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

local function evictOldest()
    if #SoundEngine.activeChannels > 0 then
        fadeDisposeChannel(1)
    end
end

-- Play Note (charID is optional, used for per-player stop)

local function doPlayNote(midiNote, velocity, worldPos, instrument, charID)
    local bank = SoundEngine.soundBanks[instrument]
    if not bank or not next(bank) then
        bank = SoundEngine.soundBanks["accordion"]
        instrument = "accordion"
    end

    local sampleNote, freqMult = findClosestSample(midiNote, bank)
    if not sampleNote then return nil end

    local finalFreq = math.max(FREQ_MIN, math.min(FREQ_MAX, freqMult))

    -- Skip notes that would need extreme retuning
    if freqMult < FREQ_MIN or freqMult > FREQ_MAX then
        if math.abs(freqMult - finalFreq) > 0.05 then
            return nil
        end
    end

    cleanupDead()
    voiceSteal(sampleNote, instrument)
    while #SoundEngine.activeChannels >= MAX_POLYPHONY do evictOldest() end

    local sound = getNextSound(instrument, sampleNote)
    if not sound then return nil end

    -- Volume: velocity scaled by user volume setting
    local volumeMult = MidiMod.CurrentVolume or 1.0
    local baseGain = math.min(1.0, (velocity / 127)) * volumeMult

    local channel = nil

    if worldPos then
        local ok, ch = pcall(function()
            return sound.Play(baseGain, SOUND_RANGE, Vector2(worldPos.X, worldPos.Y))
        end)
        if ok and ch then channel = ch end
    end

    if not channel then
        local ok, ch = pcall(function()
            return sound.Play(baseGain, SOUND_RANGE)
        end)
        if ok and ch then channel = ch end
    end

    if not channel then return nil end

    -- Set pitch
    pcall(function() channel.FrequencyMultiplier = finalFreq end)

    if worldPos then
        pcall(function() channel.Near = SOUND_NEAR end)
        pcall(function() channel.Far = SOUND_RANGE end)
        pcall(function() channel.Position = Vector3(worldPos.X, worldPos.Y, 0) end)
    end

    local uid = nextUID() -- используем глобальный счётчик

    table.insert(SoundEngine.activeChannels, {
        uid        = uid,
        channel    = channel,
        note       = midiNote,
        sampleNote = sampleNote,
        instrument = instrument,
        baseGain   = baseGain,
        worldPos   = worldPos,
        charID     = charID
    })

    -- Сохрани uid в трекинг
    if charID then
        if not SoundEngine.activeNoteUIDs[charID] then
            SoundEngine.activeNoteUIDs[charID] = {}
        end
        SoundEngine.activeNoteUIDs[charID][midiNote] = uid
    end

    return channel, uid
end

function SoundEngine.playNote(midiNote, velocity, worldPos, instrument, charID)
    if not SoundEngine.initialized then SoundEngine.init() end
    instrument = instrument or "accordion"

    -- Deduplicate: if same note already queued, just keep highest velocity
    for _, queued in ipairs(SoundEngine.noteQueue) do
        if queued.midiNote == midiNote and queued.instrument == instrument then
            queued.velocity = math.max(queued.velocity, velocity)
            return nil
        end
    end

    if SoundEngine.notesThisFrame < MAX_NEW_PER_FRAME then
        SoundEngine.notesThisFrame = SoundEngine.notesThisFrame + 1
        local ch, uid = doPlayNote(midiNote, velocity, worldPos, instrument, charID)
        return ch, uid -- ← пробросить uid наружу
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
    return nil, nil
end

-- Think Hook: cleanup + queue drain

Hook.Add("think", "midi_sound_tick", function()
    if not CLIENT then return end

    pumpLoadQueue()

    SoundEngine.notesThisFrame = 0

    cleanupDead()

    -- Drain note queue
    local played = 0
    while #SoundEngine.noteQueue > 0 and played < MAX_NEW_PER_FRAME do
        local entry = table.remove(SoundEngine.noteQueue, 1)
        doPlayNote(entry.midiNote, entry.velocity, entry.worldPos, entry.instrument, entry.charID)
        played = played + 1
    end

    -- Cap queue size to prevent unbounded growth
    while #SoundEngine.noteQueue > 48 do
        table.remove(SoundEngine.noteQueue, 1)
    end
end)

-- Release a note: gentle fade-out (noteOff from MIDI)
-- Only stops the oldest instance of this note — allows overlapping same-note sounds
local NOTE_RELEASE_FADE = 0.08  -- 80ms fade, smooth without clicks

function SoundEngine.releaseNote(midiNote, charID)
    -- Check active channels for this note
    for i = 1, #SoundEngine.activeChannels do
        local info = SoundEngine.activeChannels[i]
        if info.note == midiNote and (not charID or info.charID == charID) then
            pcall(function() info.channel.FadeOutAndDispose(NOTE_RELEASE_FADE) end)
            table.remove(SoundEngine.activeChannels, i)
            break  -- only release one instance (oldest)
        end
    end

    -- Clean tracking
    if charID and SoundEngine.activeNoteUIDs[charID] then
        SoundEngine.activeNoteUIDs[charID][midiNote] = nil
    end
end

-- Stop a specific note (hard kill, all instances)
function SoundEngine.stopNote(midiNote, charID, uid)
    -- Убрать из очереди
    for i = #SoundEngine.noteQueue, 1, -1 do
        if SoundEngine.noteQueue[i].midiNote == midiNote then
            if not charID or SoundEngine.noteQueue[i].charID == charID then
                table.remove(SoundEngine.noteQueue, i)
            end
        end
    end

    -- Убрать из активных каналов
    for i = #SoundEngine.activeChannels, 1, -1 do
        local info = SoundEngine.activeChannels[i]
        if info.note == midiNote and (not charID or info.charID == charID) then
            -- Если uid передан — убиваем только точный канал
            -- Если нет — убиваем все каналы этой ноты (старое поведение)
            if uid == nil or info.uid == uid then
                fadeDisposeChannel(i)
            end
        end
    end

    -- Очисти из трекинга
    if charID and SoundEngine.activeNoteUIDs[charID] then
        SoundEngine.activeNoteUIDs[charID][midiNote] = nil
    end
end

-- Stop all sounds globally
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

-- Stop all sounds for a specific character (per-player stop for multiplayer)
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

MidiMod.Log("[SoundEngine] Loaded.")
