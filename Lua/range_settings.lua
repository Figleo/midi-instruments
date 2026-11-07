local RangeSettings = {}

function RangeSettings.create(options)
    local command = options.command
    local field = options.field
    local DEFAULT_RANGE = options.defaultRange
    local MIN_RANGE = 100
    local MAX_RANGE = 50000
    local NET_GET = options.network .. ".Get"
    local NET_SET = options.network .. ".Set"
    local NET_STATE = options.network .. ".State"
    local NET_RESULT = options.network .. ".Result"
    local configPath = Game.SaveFolder .. "/ModConfigs/" .. options.fileName
    local label = options.label
    local help = command .. " [100..50000] - show " .. label:lower()
        .. " or set it as the host. Default: " .. DEFAULT_RANGE .. "."
    local messages = {
        current = label .. ": [range].",
        changed = label .. " set to [range] and saved.",
        invalid = "Usage: " .. command .. " [100..50000]. Enter one whole number.",
        hostonly = "Only the host can change " .. label:lower()
            .. ". On a dedicated server, use the server console.",
        waiting = "Requesting " .. label:lower() .. " from the server...",
        savefailed = label .. " set to [range], but could not be saved. It will reset after restarting.",
    }

    local function validRange(value)
        return type(value) == "number" and value >= MIN_RANGE and value <= MAX_RANGE
            and value == math.floor(value)
    end

    local function say(key, value)
        local text = messages[key]
        if not text then return end
        if value ~= nil then text = text:gsub("%[range%]", tostring(value)) end
        MidiMod.Log("[" .. command .. "] " .. text)
    end

    local function loadRange()
        local ok, value = pcall(function()
            if not File.Exists(configPath) then return DEFAULT_RANGE end
            return tonumber(File.Read(configPath))
        end)
        if ok and validRange(value) then return value end
        MidiMod.DebugLog("Could not read the range for " .. command .. "; using " .. DEFAULT_RANGE .. ".")
        return DEFAULT_RANGE
    end

    local function saveRange(value)
        local ok, err = pcall(function()
            File.CreateDirectory(Game.SaveFolder .. "/ModConfigs")
            File.Write(configPath, tostring(value) .. "\n")
        end)
        if not ok then MidiMod.DebugLog("Could not save the range for " .. command .. ": " .. tostring(err)) end
        return ok
    end

    -- Guests do not persist server-provided radii; this file stores their own hosting setting.
    local localRange = loadRange()
    MidiMod[field] = localRange

    local function setRange(value)
        MidiMod[field] = value
        localRange = value
        return saveRange(value)
    end

    local function sendState(client)
        local msg = Networking.Start(NET_STATE)
        msg.WriteUInt16(MidiMod[field])
        if client then
            Networking.Send(msg, client.Connection)
        else
            for _, recipient in pairs(Client.ClientList) do
                Networking.Send(msg, recipient.Connection)
            end
        end
    end

    local function sendResult(client, key)
        local msg = Networking.Start(NET_RESULT)
        msg.WriteUInt16(MidiMod[field])
        msg.WriteString(key)
        Networking.Send(msg, client.Connection)
    end

    -- Use the connection assigned by the server to identify the host, not client-supplied flags.
    local function handleServerSet(client, value)
        if not client then return end

        if not Game.Server or not Game.Server.OwnerConnection
            or client.Connection ~= Game.Server.OwnerConnection then
            sendResult(client, "hostonly")
            return
        end
        if not validRange(value) then
            sendResult(client, "invalid")
            return
        end
        local saved = setRange(value)
        sendState()
        sendResult(client, saved and "changed" or "savefailed")
    end

    if SERVER then
        Networking.Receive(NET_GET, function(_, client)
            if client then sendState(client) end
        end)

        Networking.Receive(NET_SET, function(message, client)
            local value = message.ReadUInt16()
            handleServerSet(client, value)
        end)
    end

    local synced = false
    local reportState = false
    local lastClient = CLIENT and Game.Client or nil
    local lastRequestTime = -math.huge

    -- The client object can exist before its connection is ready. Failed requests are retried in think.
    local function requestState()
        if not CLIENT or Game.IsSingleplayer or not Game.Client then return end
        lastRequestTime = os.clock()

        pcall(function() Networking.Send(Networking.Start(NET_GET)) end)
    end

    if CLIENT then
        Networking.Receive(NET_STATE, function(message)
            local value = message.ReadUInt16()
            if not validRange(value) then return end
            MidiMod[field] = value
            synced = true
            if reportState then
                reportState = false
                say("current", value)
            end
        end)

        Networking.Receive(NET_RESULT, function(message)
            local value = message.ReadUInt16()
            local key = message.ReadString()
            if not validRange(value) then return end
            MidiMod[field] = value
            synced = true
            say(key, value)
        end)

        Hook.Add("think", options.network .. ".Sync", function()
            local client = Game.Client
            if client ~= lastClient then
                lastClient = client
                synced = false
                reportState = false
                lastRequestTime = -math.huge

                -- A local server may have saved a newer value while this client was connected.
                localRange = loadRange()
                MidiMod[field] = client and DEFAULT_RANGE or localRange
            end
            if not Game.IsSingleplayer and client and not synced
                and os.clock() - lastRequestTime >= 2 then
                requestState()
            end
        end)
        Hook.Add("roundStart", options.network .. ".RoundSync", requestState)
        requestState()
    end

    Game.RemoveCommand(command)
    Game.AddCommand(command, help, function(args)

        local words = {}
        for word in args do words[#words + 1] = tostring(word) end
        if #words == 0 then
            if SERVER or not Game.Client or Game.IsSingleplayer then
                say("current", MidiMod[field])
            else
                reportState = true
                say("waiting")
                requestState()
            end
            return
        end

        local value = tonumber(words[1])
        if #words ~= 1 or not validRange(value) then
            say("invalid")
            return
        end
        if SERVER or Game.IsSingleplayer or not Game.Client then
            local saved = setRange(value)
            if SERVER then sendState() end
            say(saved and "changed" or "savefailed", value)
        elseif Game.Client.IsServerOwner then
            local msg = Networking.Start(NET_SET)
            msg.WriteUInt16(value)
            Networking.Send(msg)
        else
            say("hostonly")
        end
    end)

    if SERVER then

        -- Without a remote handler, console requests fall back to the local command and bypass the host check.
        Game.AssignOnClientRequestExecute(command, function(client, _, args)
            local words = {}
            for word in args do words[#words + 1] = tostring(word) end
            if #words == 0 then
                sendResult(client, "current")
            elseif #words ~= 1 then
                sendResult(client, "invalid")
            else
                handleServerSet(client, tonumber(words[1]))
            end
        end)
    end

    MidiMod.Log("[" .. command .. "] Range: " .. MidiMod[field] .. "; file: " .. configPath)
    return {}
end

return RangeSettings
