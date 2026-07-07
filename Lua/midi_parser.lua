MidiMod            = MidiMod or {}
MidiMod.MidiParser = MidiMod.Midiparser or {}

local MidiParser   = MidiMod.MidiParser

-- Cache stdlib lookups (saves 2 table lookups per call in MoonSharp)
local sbyte        = string.byte
local ssub         = string.sub
local mfloor       = math.floor


local function readBytes(data, pos, count)
    return ssub(data, pos, pos + count - 1), pos + count
end

local function readUint8(data, pos)
    return sbyte(data, pos), pos + 1
end

local function readUint16(data, pos)
    local b1, b2 = sbyte(data, pos, pos + 1)
    return b1 * 256 + b2, pos + 2
end

local function readUint32(data, pos)
    local b1, b2, b3, b4 = sbyte(data, pos, pos + 3)
    return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4, pos + 4
end

local function readVarLen(data, pos)
    local value = 0
    local byte
    repeat
        byte, pos = readUint8(data, pos)
        value = value * 128 + (byte % 128)
    until byte < 128
    return value, pos
end

local function parseHeader(data, pos)
    local chunk
    chunk, pos = readBytes(data, pos, 4)
    if chunk ~= "MThd" then
        error("[MidiParser] Invalid MIDI file: missing MThd header, got: " .. tostring(chunk))
    end

    local headerLen
    headerLen, pos = readUint32(data, pos)

    local format, trackCount, division
    format, pos = readUint16(data, pos)
    trackCount, pos = readUint16(data, pos)
    division, pos = readUint16(data, pos)

    local ticksPerQuarter = division
    if division >= 32768 then
        MidiMod.Log("Warning: SMPTE-based timing detected, defaulting to 480 ticks/quarter")
        ticksPerQuarter = 480
    end

    return {
        format = format,
        trackCount = trackCount,
        ticksPerQuarter = ticksPerQuarter,
    }, pos
end

local function parseTrack(data, pos, yieldFn)
    local chunk
    chunk, pos = readBytes(data, pos, 4)
    if chunk ~= "MTrk" then
        error("[MidiParser] Invalid track chunk: expected MTrk, got: " .. tostring(chunk))
    end

    local trackLen
    trackLen, pos = readUint32(data, pos)
    local trackEnd = pos + trackLen

    local events = {}
    local evN = 0
    local absoluteTick = 0
    local runningStatus = 0

    while pos < trackEnd do
        local delta
        delta, pos = readVarLen(data, pos)
        absoluteTick = absoluteTick + delta

        local statusByte = sbyte(data, pos)

        if statusByte >= 128 then
            runningStatus = statusByte
            pos = pos + 1
        else
            statusByte = runningStatus
        end

        local eventType = mfloor(statusByte / 16)
        local channel = statusByte % 16

        if eventType == 0x9 then
            local note, velocity
            note, pos = readUint8(data, pos)
            velocity, pos = readUint8(data, pos)
            evN = evN + 1
            events[evN] = {
                tick = absoluteTick,
                type = velocity > 0 and "noteOn" or "noteOff",
                channel = channel,
                note = note,
                velocity = velocity,
            }
        elseif eventType == 0x8 then
            local note, velocity
            note, pos = readUint8(data, pos)
            velocity, pos = readUint8(data, pos)
            evN = evN + 1
            events[evN] = {
                tick = absoluteTick,
                type = "noteOff",
                channel = channel,
                note = note,
                velocity = velocity,
            }
        elseif eventType == 0xA then
            pos = pos + 2
        elseif eventType == 0xB then
            pos = pos + 2
        elseif eventType == 0xC then
            pos = pos + 1
        elseif eventType == 0xD then
            pos = pos + 1
        elseif eventType == 0xE then
            pos = pos + 2
        elseif statusByte == 0xFF then
            local metaType
            metaType, pos = readUint8(data, pos)
            local metaLen
            metaLen, pos = readVarLen(data, pos)

            if metaType == 0x51 then
                local b1, b2, b3 = sbyte(data, pos, pos + 2)
                local usPerQuarter = b1 * 65536 + b2 * 256 + b3
                evN = evN + 1
                events[evN] = {
                    tick = absoluteTick,
                    type = "tempo",
                    usPerQuarter = usPerQuarter,
                    bpm = mfloor(60000000 / usPerQuarter + 0.5),
                }
            elseif metaType == 0x2F then
                pos = pos + metaLen
                break
            end

            pos = pos + metaLen
        elseif statusByte == 0xF0 or statusByte == 0xF7 then
            local sysexLen
            sysexLen, pos = readVarLen(data, pos)
            pos = pos + sysexLen
        else
            break
        end

        if yieldFn then yieldFn() end
    end

    return events, math.max(pos, trackEnd)
end

-- Event ordering: tick ascending; at same tick: tempo > noteOff > noteOn.
local function evLess(a, b)
    if a.tick ~= b.tick then return a.tick < b.tick end
    if a.type == "tempo" and b.type ~= "tempo" then return true end
    if b.type == "tempo" and a.type ~= "tempo" then return false end
    if a.type == "noteOff" and b.type == "noteOn" then return true end
    if a.type == "noteOn" and b.type == "noteOff" then return false end
    return false
end

local function mergeTracks(tracks)
    if #tracks == 1 then return tracks[1] end

    -- Flatten all tracks into a single array, then sort.
    -- table.sort is C-implemented and vastly faster than a Lua k-way merge.
    local result = {}
    local n = 0
    for i = 1, #tracks do
        local t = tracks[i]
        for j = 1, #t do
            n = n + 1
            result[n] = t[j]
        end
    end

    table.sort(result, evLess)
    return result
end

local function buildScore(allEvents, ticksPerQuarter, yieldFn)
    local tempo = 500000
    local lastTick = 0
    local lastTimeMs = 0
    local score = {}
    local scoreN = 0
    local activeNotes = {}

    for _, ev in ipairs(allEvents) do
        local deltaTicks = ev.tick - lastTick
        local deltaMs = (deltaTicks / ticksPerQuarter) * (tempo / 1000)
        lastTimeMs = lastTimeMs + deltaMs
        lastTick = ev.tick

        if ev.type == "tempo" then
            tempo = ev.usPerQuarter
        elseif ev.type == "noteOn" then
            local key = ev.channel * 128 + ev.note
            if activeNotes[key] then
                scoreN = scoreN + 1
                score[scoreN] = {
                    timeMs = lastTimeMs,
                    type = "off",
                    note = ev.note,
                    channel = ev.channel,
                }
            end
            activeNotes[key] = lastTimeMs
            scoreN = scoreN + 1
            score[scoreN] = {
                timeMs = lastTimeMs,
                type = "on",
                note = ev.note,
                velocity = ev.velocity,
                channel = ev.channel,
            }
        elseif ev.type == "noteOff" then
            local key = ev.channel * 128 + ev.note
            if activeNotes[key] then
                scoreN = scoreN + 1
                score[scoreN] = {
                    timeMs = lastTimeMs,
                    type = "off",
                    note = ev.note,
                    channel = ev.channel,
                }
                activeNotes[key] = nil
            end
        end

        if yieldFn then yieldFn() end
    end

    for key, startTime in pairs(activeNotes) do
        scoreN = scoreN + 1
        score[scoreN] = {
            timeMs = startTime + 200,
            type = "off",
            note = key % 128,
            channel = mfloor(key / 128),
        }
    end

    return score
end

MidiParser._cache = {}

function MidiParser.clearCache()
    for k in pairs(MidiParser._cache) do
        MidiParser._cache[k] = nil
    end
end

function MidiParser.parse(filePath)
    if MidiParser._cache[filePath] then
        MidiMod.Log("Cache hit: " .. filePath)
        local cached = MidiParser._cache[filePath]
        return cached.score, cached.header
    end

    MidiMod.Log("Parsing MIDI file: " .. filePath)

    local file = io.open(filePath, "rb")
    if not file then
        error("[MidiParser] Cannot open file: " .. filePath)
    end
    local data = file:read("*all")
    file:close()

    if not data or #data < 14 then
        error("[MidiParser] File too small or empty: " .. filePath)
    end

    local pos = 1
    local header
    header, pos = parseHeader(data, pos)

    local tracks = {}
    for i = 1, header.trackCount do
        tracks[i], pos = parseTrack(data, pos)
    end

    local allEvents = mergeTracks(tracks)
    local score     = buildScore(allEvents, header.ticksPerQuarter)
    MidiMod.Log("Parsed " .. #score .. " notes from " .. filePath)

    MidiParser._cache[filePath] = { score = score, header = header }

    return score, header
end

MidiParser._parseState = nil

function MidiParser.cancelAsync()
    MidiParser._parseState = nil
end

-- Time budget per frame for async parse pump (seconds).
local FRAME_BUDGET_SEC = 0.004

function MidiParser.parseAsync(filePath, onDone, onError)
    MidiParser._parseState = nil

    -- Check cache first — instant callback, no coroutine needed
    if MidiParser._cache[filePath] then
        MidiMod.Log("Async cache hit: " .. filePath)
        if onDone then pcall(onDone, MidiParser._cache[filePath].score) end
        return
    end

    -- Shared deadline set by the pump before each resume.
    local deadline = 0

    -- Each phase gets its own yielder to avoid double-throttling.
    -- os.clock() is a C# interop call — interval controls how often we check.
    local function makeYielder(interval)
        local counter = 0
        return function()
            counter = counter + 1
            if counter >= interval then
                counter = 0
                if os.clock() >= deadline then
                    coroutine.yield()
                end
            end
        end
    end

    local co = coroutine.create(function()
        local file = io.open(filePath, "rb")
        if not file then
            error("[MidiParser] Cannot open file: " .. filePath)
        end
        local data = file:read("*all")
        file:close()
        coroutine.yield()

        if not data or #data < 14 then
            error("[MidiParser] File too small or empty: " .. filePath)
        end

        local pos = 1
        local header
        header, pos = parseHeader(data, pos)

        local yieldTrack = makeYielder(200)

        local tracks = {}
        for i = 1, header.trackCount do
            tracks[i], pos = parseTrack(data, pos, yieldTrack)
            coroutine.yield()
        end

        -- Flatten + C-sort is far faster than Lua k-way merge
        local allEvents = mergeTracks(tracks)
        coroutine.yield()

        local yieldScore = makeYielder(200)
        local score = buildScore(allEvents, header.ticksPerQuarter, yieldScore)
        MidiMod.Log("Async parsed " .. #score .. " notes from " .. filePath)

        -- Cache the result
        MidiParser._cache[filePath] = { score = score, header = header }

        return score
    end)

    MidiParser._parseState = {
        co       = co,
        onDone   = onDone,
        onError  = onError,
        deadline = function(d) deadline = d end,
    }

    -- Kick off the first resume (reads file, then yields)
    deadline = os.clock() + FRAME_BUDGET_SEC
    local ok, val = coroutine.resume(co)
    if not ok then
        MidiParser._parseState = nil
        if onError then pcall(onError, val) end
    elseif coroutine.status(co) == "dead" then
        MidiParser._parseState = nil
        if onDone then pcall(onDone, val) end
    end
end

if CLIENT then
    Hook.Add("think", "midi_parse_pump", function()
        local state = MidiParser._parseState
        if not state then return end

        local dl = os.clock() + FRAME_BUDGET_SEC
        state.deadline(dl)

        -- Loop: resume multiple times within budget instead of once per frame
        while true do
            local ok, val = coroutine.resume(state.co)
            if not ok then
                MidiParser._parseState = nil
                if state.onError then pcall(state.onError, val) end
                return
            elseif coroutine.status(state.co) == "dead" then
                MidiParser._parseState = nil
                if state.onDone then pcall(state.onDone, val) end
                return
            end
            -- If we still have budget, resume again immediately
            if os.clock() >= dl then break end
        end
    end)
end

-- Searching MIDI files

local MIDI_STORAGE_WORKSHOP_ID = "3695216167"

local function scanFolder(dir, results)
    local dirExists = false
    pcall(function() dirExists = File.DirectoryExists(dir) end)
    if not dirExists then return 0 end

    local ok, allFiles = pcall(function() return File.GetFiles(dir) end)
    if not ok or not allFiles then return 0 end

    local count = 0
    for _, f in pairs(allFiles) do
        local fStr = tostring(f)
        if string.match(fStr:lower(), "%.midi?$") then
            if not string.find(fStr, "/") and not string.find(fStr, "\\") then
                fStr = dir .. "/" .. fStr
            end
            table.insert(results, fStr)
            count = count + 1
        end
    end
    return count
end

function MidiParser.listMidiFiles()
    local files = {}
    local basePath = MidiMod.BasePath or ""

    -- Workshop storage
    local workshopFolder = basePath:match("(.*[/\\])[^/\\]+[/\\]?$")
    local storageMidiPath = nil

    if workshopFolder then
        local storagePath = workshopFolder .. MIDI_STORAGE_WORKSHOP_ID
        storageMidiPath = storagePath .. "/Midi"

        scanFolder(storagePath, files)
        scanFolder(storageMidiPath, files)
    end

    -- Local folder — controlled by MidiMod.Debug
    if MidiMod.Debug then
        local localDir = basePath .. "Midi"
        local count = scanFolder(localDir, files)
        if count > 0 then
            MidiMod.DebugLog("[MidiParser] Loaded " .. count .. " files from " .. localDir)
        end
    end

    if #files > 0 then
        MidiMod.Log("[MidiParser] Found " .. #files .. " MIDI files")
    else
        MidiMod.Log("[MidiParser] No .mid files found.")
        MidiMod.Log("Install 'MIDI Storage' from Workshop (ID " .. MIDI_STORAGE_WORKSHOP_ID .. ").")
        if storageMidiPath then
            MidiMod.Log("Drop your files under: " .. storageMidiPath)
        else
            MidiMod.Log("Then place .mid files in that mod's Midi folder.")
        end
    end

    return files
end
