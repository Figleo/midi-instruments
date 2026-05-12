-- Reads standard MIDI files and turns them into a simple note timeline.

MidiMod = MidiMod or {}
MidiMod.MidiParser = {}

local MidiParser = MidiMod.MidiParser

-- Also scan the mod's local Midi folder (handy while testing).
local DEBUG_LOCAL = true

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

local function parseTrack(data, pos)
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
    end

    return events, math.max(pos, trackEnd)
end

local function buildScore(allEvents, ticksPerQuarter)
    table.sort(allEvents, function(a, b)
        if a.tick == b.tick then
            if a.type == "tempo" then return true end
            if b.type == "tempo" then return false end
            return false
        end
        return a.tick < b.tick
    end)

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

    local score = {}
    local activeNotes = {}

    for _, ev in ipairs(allEvents) do
        if ev.type == "noteOn" then
            local key = ev.channel .. "_" .. ev.note
            activeNotes[key] = {
                timeMs = ev.timeMs,
                velocity = ev.velocity,
                note = ev.note,
                channel = ev.channel,
            }
        elseif ev.type == "noteOff" then
            local key = ev.channel .. "_" .. ev.note
            local start = activeNotes[key]
            if start then
                table.insert(score, {
                    timeMs = start.timeMs,
                    note = start.note,
                    velocity = start.velocity,
                    durationMs = ev.timeMs - start.timeMs,
                    channel = start.channel,
                })
                activeNotes[key] = nil
            end
        end
    end

    for _, start in pairs(activeNotes) do
        table.insert(score, {
            timeMs = start.timeMs,
            note = start.note,
            velocity = start.velocity,
            durationMs = 200,
            channel = start.channel,
        })
    end

    table.sort(score, function(a, b) return a.timeMs < b.timeMs end)

    return score
end

function MidiParser.parse(filePath)
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

    local allEvents = {}
    for i = 1, header.trackCount do
        local trackEvents
        trackEvents, pos = parseTrack(data, pos)
        for _, ev in ipairs(trackEvents) do
            table.insert(allEvents, ev)
        end
    end

    local score = buildScore(allEvents, header.ticksPerQuarter)
    MidiMod.Log("Parsed " .. #score .. " notes from " .. filePath)

    return score, header
end

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

    local workshopFolder = basePath:match("(.*[/\\])[^/\\]+[/\\]?$")
    local storageMidiPath = nil

    if workshopFolder then
        local storagePath = workshopFolder .. MIDI_STORAGE_WORKSHOP_ID
        storageMidiPath = storagePath .. "/Midi"

        scanFolder(storagePath, files)
        scanFolder(storageMidiPath, files)
    end

    if DEBUG_LOCAL then
        local localDir = basePath .. "Midi"
        local count = scanFolder(localDir, files)
        if count > 0 then
            MidiMod.Log("[MidiParser] DEBUG: Loaded " .. count .. " files from " .. localDir)
        end
    end

    if #files > 0 then
        MidiMod.Log("[MidiParser] Found " .. #files .. " MIDI files")
    else
        MidiMod.Log("[MidiParser] No .mid files found.")
        MidiMod.Log("As of March 2026, MIDI files live in the MIDI Storage companion mod, not here.")
        MidiMod.Log("Install MIDI Storage from the Workshop (ID " .. MIDI_STORAGE_WORKSHOP_ID .. ").")
        if storageMidiPath then
            MidiMod.Log("Drop your files under: " .. storageMidiPath)
        else
            MidiMod.Log("Then place .mid files in that mod's Midi folder.")
        end
    end

    return files
end