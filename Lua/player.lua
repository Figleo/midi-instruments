MidiMod = MidiMod or {}
MidiMod.Player = MidiMod.Player or {}

local Player = MidiMod.Player

Player.activeSongs = Player.activeSongs or {}
Player.streamingCharacters = Player.streamingCharacters or {}

function Player.init()
    Player.activeSongs = {}
    Player.streamingCharacters = {}
    MidiMod.Log("Player module initialized")
end

function Player.loadFile(filepath, charID)
    if not MidiMod.MidiParser then
        MidiMod.Log("ERROR: MidiParser not available")
        return false
    end

    local ok, result = pcall(function()
        local score, header = MidiMod.MidiParser.parse(filepath)

        if not score or #score == 0 then
            MidiMod.Log("ERROR: No notes in MIDI file")
            return false
        end

        local notes = {}
        for i, note in ipairs(score) do
            table.insert(notes, {
                time     = note.timeMs / 1000.0,
                pitch    = note.note,
                velocity = note.velocity,
                duration = note.durationMs / 1000.0,
                channel  = note.channel
            })
        end

        MidiMod.Log("MIDI Data loaded:")
        MidiMod.Log("  - Notes count: " .. #notes)
        MidiMod.Log("  - First note: pitch=" .. notes[1].pitch .. ", time=" .. notes[1].time .. "s")
        MidiMod.Log("  - Last note time: " .. notes[#notes].time .. "s")
        MidiMod.Log("  - Song duration: " .. math.floor(notes[#notes].time) .. " seconds")

        Player.activeSongs[charID] = {
            notes            = notes,
            index            = 1,
            lastTime         = nil,
            startTime        = nil,
            elapsedTime      = 0,
            tempo            = 1.0,
            isStreaming      = false,
            paused           = false,
            noInstrumentTime = nil
        }
        return true
    end)

    if not ok then
        MidiMod.Log("ERROR in loadFile: " .. tostring(result))
        return false
    end

    return result
end

function Player.stopChar(charID)
    if Player.activeSongs[charID] then
        Player.activeSongs[charID] = nil
        MidiMod.Log("Stopped playback for char " .. tostring(charID))
    end

    if Player.streamingCharacters[charID] then
        Player.streamingCharacters[charID] = nil
    end

    if MidiMod.SoundEngine and MidiMod.SoundEngine.stopAllForChar then
        MidiMod.SoundEngine.stopAllForChar(charID)
    end
end

function Player.play(character)
    if not character then return end
    local charID = character.ID

    if not Player.activeSongs[charID] then
        MidiMod.Log("No loaded song for char " .. tostring(charID))
        return
    end

    Player.activeSongs[charID].paused   = false
    Player.activeSongs[charID].lastTime = nil
    MidiMod.Log("Playing for char " .. tostring(charID))
end

function Player.setTempo(charID, tempoMult)
    if Player.activeSongs[charID] then
        Player.activeSongs[charID].tempo = tempoMult or 1.0
    end
end

function Player.setStreamingHost(charID, isHost)
    if Player.activeSongs[charID] then
        Player.activeSongs[charID].isStreaming = isHost
    end
end

if CLIENT then
    local _playerUpdateTime = 0

    Hook.Add("think", "MidiMod.Player.Update", function(deltaTime)
        _playerUpdateTime = _playerUpdateTime + deltaTime
        local now = _playerUpdateTime

        for charID, song in pairs(Player.activeSongs) do
            if not song.paused and song.notes then
                local character = nil
                pcall(function() character = Entity.FindEntityByID(charID) end)

                local shouldStop = not character or character.IsDead

                if not shouldStop then
                    local instrId, item = MidiMod.GetHeldInstrument(character)

                    if not instrId then
                        if not song.noInstrumentTime then
                            song.noInstrumentTime = now
                        elseif (now - song.noInstrumentTime) > 0.5 then
                            MidiMod.Log("No instrument held, stopping for char " .. tostring(charID))
                            shouldStop = true
                            if MidiMod.Network then MidiMod.Network.requestStop(charID) end
                        end
                    else
                        song.noInstrumentTime = nil

                        if not song.lastTime then
                            song.lastTime = now
                        end

                        if not song.startTime then
                            song.startTime = now
                        end

                        local frameDelta = (now - song.lastTime) * song.tempo
                        song.lastTime    = now
                        song.elapsedTime = song.elapsedTime + frameDelta

                        local worldPos   = nil
                        pcall(function()
                            worldPos = item and item.WorldPosition or character.WorldPosition
                        end)

                        local notesPlayed = 0
                        local streamBatch = {}

                        while song.index <= #song.notes and notesPlayed < 10 do
                            local note = song.notes[song.index]
                            if note.time > song.elapsedTime then break end

                            pcall(function()
                                if MidiMod.SoundEngine and MidiMod.SoundEngine.playNote then
                                    MidiMod.SoundEngine.playNote(
                                        note.pitch or 60,
                                        note.velocity or 80,
                                        worldPos, instrId, charID
                                    )
                                end
                            end)

                            if song.isStreaming then
                                table.insert(streamBatch,
                                    (note.pitch or 60) .. "," .. (note.velocity or 80))
                            end

                            song.index  = song.index + 1
                            notesPlayed = notesPlayed + 1
                        end

                        if #streamBatch > 0 and MidiMod.Network then
                            MidiMod.Network.broadcastNotes(
                                charID, table.concat(streamBatch, ";"), instrId)
                        end

                        if song.index > #song.notes then
                            MidiMod.Log("Song finished for char " .. tostring(charID))
                            shouldStop = true
                            if MidiMod.Network then MidiMod.Network.requestStop(charID) end
                        end
                    end
                end

                if shouldStop then
                    Player.stopChar(charID)
                end
            end
        end
    end)
end

local TALENT_BUFFS      = {
    steadytune     = "psychosisimmunity",
    melodicrespite = "melodicrespite",
}
local REQUIRED_PLAY_SEC = 10
local BUFF_STRENGTH     = 60.0
local SERVER_REFRESH    = 55
local CLIENT_REFRESH    = 8

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

local function applyAffliction(character, afflictionID, strength)
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
                MidiMod.Log("[ServerBuff] Tracking char " .. tostring(charID))
            end
        end)

    Hook.Add("MidiMod.Server.BuffStop", "MidiMod.Server.HandleStop",
        function(charID)
            serverTimers[charID] = nil
            MidiMod.Log("[ServerBuff] Stopped tracking char " .. tostring(charID))
        end)

    Hook.Add("think", "MidiMod.Server.BuffApply", function(deltaTime)
        _serverTime = _serverTime + deltaTime
        local now   = _serverTime

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
                            MidiMod.Log(string.format(
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

if CLIENT then
    local clientTimers = {}
    local _clientTime  = 0

    Hook.Add("think", "MidiMod.Client.BuffApply", function(deltaTime)
        _clientTime = _clientTime + deltaTime
        local now   = _clientTime
        for charID in pairs(Player.activeSongs) do
            if not clientTimers[charID] then
                clientTimers[charID] = {
                    playStart = now,
                    lastApply = 0
                }
            end
        end
        for charID in pairs(clientTimers) do
            if not Player.activeSongs[charID] then
                clientTimers[charID] = nil
            end
        end

        for charID, timer in pairs(clientTimers) do
            local playedEnough = (now - timer.playStart) >= REQUIRED_PLAY_SEC
            local refreshReady = (now - timer.lastApply) >= CLIENT_REFRESH

            if playedEnough and refreshReady then
                local controlled = nil
                pcall(function() controlled = Character.Controlled end)

                if controlled and controlled.ID == charID then
                    for talentID, afflictionID in pairs(TALENT_BUFFS) do
                        if hasTalentChar(controlled, talentID) then
                            applyAffliction(controlled, afflictionID, BUFF_STRENGTH)
                        end
                    end
                    timer.lastApply = now
                end
            end
        end
    end)
end

MidiMod.Log("[Player] Loaded. Multi-instance + Hybrid Buffs (server=50s, client=5s).")
