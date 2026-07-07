MidiMod = MidiMod or {}
MidiMod.MidiParser = MidiMod.Midiparser or {}

local MidiParser = MidiMod.MidiParser

local function readBytes(data, pos, count)
    return string.sub(data, pos, pos + count - 1), pos + count
end

local function readUint8(data, pos)
    return string.byte(data, pos), pos + 1
end

local function readUint16(data, pos)
    local b1, b2 = string.byte(data, pos, pos + 1)
    return b1 * 256 + b2, pos + 2
end

local function readUint32(data, pos)
    local b1, b2, b3, b4 = string.byte(data, pos, pos + 3)
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

local YIELD_EVERY = 64

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
    local absoluteTick = 0
    local runningStatus = 0
    local loopCount = 0

    while pos < trackEnd do
        local delta
        delta, pos = readVarLen(data, pos)
        absoluteTick = absoluteTick + delta

        local statusByte = string.byte(data, pos)

        if statusByte >= 128 then
            runningStatus = statusByte
            pos = pos + 1
        else
            statusByte = runningStatus
        end

        local eventType = math.floor(statusByte / 16)
        local channel = statusByte % 16

        if eventType == 0x9 then
            local note, velocity
            note, pos = readUint8(data, pos)
            velocity, pos = readUint8(data, pos)
            local evType = velocity > 0 and "noteOn" or "noteOff"
            table.insert(events, {
                tick = absoluteTick,
                type = evType,
                channel = channel,
                note = note,
                velocity = velocity,
            })
        elseif eventType == 0x8 then
            local note, velocity
            note, pos = readUint8(data, pos)
            velocity, pos = readUint8(data, pos)
            table.insert(events, {
                tick = absoluteTick,
                type = "noteOff",
                channel = channel,
                note = note,
                velocity = velocity,
            })
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
                local b1, b2, b3 = string.byte(data, pos, pos + 2)
                local usPerQuarter = b1 * 65536 + b2 * 256 + b3
                table.insert(events, {
                    tick = absoluteTick,
                    type = "tempo",
                    usPerQuarter = usPerQuarter,
                    bpm = math.floor(60000000 / usPerQuarter + 0.5),
                })
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

        if yieldFn then
            loopCount = loopCount + 1
            if loopCount % YIELD_EVERY == 0 then
                yieldFn()
            end
        end
    end

    return events, math.max(pos, trackEnd)
end

-- Event ordering: tick ascending; at same tick: tempo > noteOff > noteOn.
local function evLess(a, b)
    if a.tick ~= b.tick then return a.tick < b.tick end
    if a.type == "tempo"   and b.type ~= "tempo"   then return true  end
    if b.type == "tempo"   and a.type ~= "tempo"   then return false end
    if a.type == "noteOff" and b.type == "noteOn"  then return true  end
    if a.type == "noteOn"  and b.type == "noteOff" then return false end
    return false
end

local function mergeTracks(tracks, yieldFn)
    if #tracks == 1 then return tracks[1] end

    local k       = #tracks
    local indices = {}
    for i = 1, k do indices[i] = 1 end

    local result = {}
    local count  = 0

    while true do
        local bestI, bestEv
        for i = 1, k do
            local ev = tracks[i][indices[i]]
            if ev and (not bestEv or evLess(ev, bestEv)) then
                bestEv = ev
                bestI  = i
            end
        end
        if not bestI then break end

        count          = count + 1
        result[count]  = bestEv
        indices[bestI] = indices[bestI] + 1

        if yieldFn and count % YIELD_EVERY == 0 then
            yieldFn()
        end
    end

    return result
end

local function buildScore(tracks, ticksPerQuarter, yieldFn)
    local allEvents = mergeTracks(tracks, yieldFn)
    if yieldFn then yieldFn() end

    local tempo = 500000
    local lastTick = 0
    local lastTimeMs = 0

    for _, ev in ipairs(allEvents) do
        local deltaTicks = ev.tick - lastTick
        local deltaMs = (deltaTicks / ticksPerQuarter) * (tempo / 1000)
        lastTimeMs = lastTimeMs + deltaMs
        lastTick = ev.tick
        ev.timeMs = lastTimeMs

        if ev.type == "tempo" then
            tempo = ev.usPerQuarter
        end
    end

    if yieldFn then yieldFn() end

    local score = {}
    local activeNotes = {}

    for _, ev in ipairs(allEvents) do
        if ev.type == "noteOn" then
            local key = ev.channel .. "_" .. ev.note
            if activeNotes[key] then
                table.insert(score, {
                    timeMs = ev.timeMs,
                    type = "off",
                    note = ev.note,
                    channel = ev.channel,
                })
            end
            activeNotes[key] = ev.timeMs
            table.insert(score, {
                timeMs = ev.timeMs,
                type = "on",
                note = ev.note,
                velocity = ev.velocity,
                channel = ev.channel,
            })
        elseif ev.type == "noteOff" then
            local key = ev.channel .. "_" .. ev.note
            if activeNotes[key] then
                table.insert(score, {
                    timeMs = ev.timeMs,
                    type = "off",
                    note = ev.note,
                    channel = ev.channel,
                })
                activeNotes[key] = nil
            end
        end
    end

    for key, startTime in pairs(activeNotes) do
        local ch, noteStr = string.match(key, "(%d+)_(%d+)")
        table.insert(score, {
            timeMs = startTime + 200,
            type = "off",
            note = tonumber(noteStr),
            channel = tonumber(ch),
        })
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

    local score = buildScore(tracks, header.ticksPerQuarter)
    MidiMod.Log("Parsed " .. #score .. " notes from " .. filePath)

    MidiParser._cache[filePath] = { score = score, header = header }

    return score, header
end

MidiParser._parseState = nil

function MidiParser.cancelAsync()
    MidiParser._parseState = nil
end

local RESUMES_PER_FRAME = 16

function MidiParser.parseAsync(filePath, onDone, onError)
    MidiParser._parseState = nil

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

        local tracks = {}
        for i = 1, header.trackCount do
            tracks[i], pos = parseTrack(data, pos, coroutine.yield)
            coroutine.yield()
        end

        local score = buildScore(tracks, header.ticksPerQuarter, coroutine.yield)
        MidiMod.Log("Async parsed " .. #score .. " notes from " .. filePath)
        return score
    end)

    MidiParser._parseState = {
        co      = co,
        onDone  = onDone,
        onError = onError,
    }

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

        for _ = 1, RESUMES_PER_FRAME do
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
