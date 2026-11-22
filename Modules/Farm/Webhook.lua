--[[
    Modules/Farm/Webhook.lua  -  Discord webhook transport, disconnect alerts, inventory profit tracking.
    Source: Script1 lines 201-258 (requestWebhook / sendWebhook), 444-506 (disconnect alerts),
            508-699 (inventory snapshot, session reports).  Verbatim; shared variables read through F.
    The webhook URL is never hardcoded: F.WEBHOOK_URL starts from State.Secrets.WebhookUrl.
]]

return function(State)
    local F = State.Farm
    local HttpService = State.Services.HttpService
    local LocalPlayer = F.LocalPlayer
    local Remotes = F.Remotes
    local Shared = F.Shared
    local ClientControllers = F.ClientControllers
    local requireModule = F.requireModule
    local diagnostics = F.diagnostics

    local function requestWebhook(url, method, payload, fullReport, fileName)
        local httpRequest = request or (http and http.request)
        if not httpRequest then return nil end

        local ok, response = pcall(function()
            payload.allowed_mentions = { parse = {} }
            local contentType, body = "application/json", HttpService:JSONEncode(payload)
            if fullReport then
                local boundary = HttpService:GenerateGUID(false)
                contentType = "multipart/form-data; boundary=" .. boundary
                body = table.concat({
                    "--" .. boundary,
                    'Content-Disposition: form-data; name="payload_json"',
                    "Content-Type: application/json",
                    "",
                    body,
                    "--" .. boundary,
                    'Content-Disposition: form-data; name="files[0]"; filename="' .. (fileName or "farm-report.txt") .. '"',
                    if fileName then "Content-Type: application/json" else "Content-Type: text/plain; charset=utf-8",
                    "",
                    fullReport,
                    "--" .. boundary .. "--",
                    "",
                }, "\r\n")
            end
            return httpRequest({
                Url = url,
                Method = method,
                Headers = { ["Content-Type"] = contentType },
                Body = body,
            })
        end)
        return if ok and type(response) == "table" then response else nil
    end

    local function sendWebhook(messageText, attachment, fileName, onFinished)
        local url = F.WEBHOOK_URL
        if not F.running or url == "" then
            if onFinished then onFinished(false, "Set a webhook URL first.") end
            return
        end
        task.spawn(function()
            if F.running then
                local response = requestWebhook(url, "POST", {
                    content = messageText,
                    username = "ABOVE Auto Farm (" .. LocalPlayer.Name .. ")",
                }, attachment, fileName)
                local status = response and tonumber(response.StatusCode)
                local sent = status ~= nil and status >= 200 and status < 300
                if attachment and not sent then
                    warn("[ABOVE Farm] Diagnostic webhook failed: " .. (if status then "HTTP " .. status else "no HTTP response"))
                end
                if onFinished then
                    onFinished(sent, if sent then "Discord accepted the log." elseif status then "Discord returned HTTP " .. status .. "." else "No HTTP response.")
                end
            end
        end)
    end

    F.disconnectAlertsEnabled = false
    F.disconnectConnection = nil
    local checkClientDisconnect
    do
        local guiService: any = game:GetService("GuiService")
        local alerted = false
        local lastCode = 0

        local function reportDisconnect(code, message, explicitlyCleared)
            if code == 0 and message == "" then
                if explicitlyCleared or lastCode ~= 0 then alerted = false end
                lastCode = 0
                return
            end
            if code and code ~= 0 then lastCode = code end
            if not F.running or alerted then return end
            local canSend = F.disconnectAlertsEnabled and F.WEBHOOK_URL ~= ""
            if not canSend and not diagnostics.isEnabled() then return end
            local displayedCode = message:match("[Ee]rror%s+[Cc]ode%s*:%s*(%d+)")
            if displayedCode then code = tonumber(displayedCode) or code end
            if not code or code < 256 or (code >= 512 and code ~= 600) then return end

            local status = "Disconnected"
            if code == 600 then
                status = "Experience ban reported"
            elseif code == 268 then
                status = "Kicked for unexpected client behavior"
            elseif code == 267 then
                status = "Kicked by the experience"
            elseif code == 266 or code == 277 then
                status = "Connection lost or timed out"
            end
            alerted = true
            local summary, attachment = diagnostics.onDisconnect(code, message)
            if canSend then
                local cut = utf8.offset(message, 701)
                if cut then message = message:sub(1, cut - 1) .. "…" end
                if message == "" then message = "Roblox did not provide a message." end
                sendWebhook(string.format(
                    "**Roblox client alert**\nAccount **%s** · <t:%d:f>\n%s · Error %d\n%s%s",
                    LocalPlayer.Name, os.time(), status, code, message, summary or ""
                ), attachment, "above-disconnect.json")
            end
        end

        checkClientDisconnect = function(eventMessage)
            if not F.running or (not F.disconnectAlertsEnabled and not diagnostics.isEnabled()) then return end
            local codeOk, errorCode = pcall(function() return guiService:GetErrorCode() end)
            local messageOk, message = pcall(function() return guiService:GetErrorMessage() end)
            local code = if codeOk and typeof(errorCode) == "EnumItem" then errorCode.Value else nil
            local reason = if messageOk and type(message) == "string" and message ~= "" then message
                elseif type(eventMessage) == "string" then eventMessage else ""
            reportDisconnect(code, reason, eventMessage == "")
        end

        local ok, connection = pcall(function()
            return guiService.ErrorMessageChanged:Connect(function(eventMessage)
                -- Let Roblox finish updating the paired error code and message.
                task.defer(checkClientDisconnect, eventMessage)
            end)
        end)
        if ok then F.disconnectConnection = connection end
    end

    local inventoryRemote = Remotes:WaitForChild("InventoryChanged")
    local Palette: any = requireModule(Shared:WaitForChild("Palette"))
    local latestInventory: { [string]: number }? = nil
    F.isWebhookActive = false
    F.trackingSession = nil
    local reportInFlight = false
    local nextReportAllowedAt = 0
    F.nextPingTime = os.time() + F.pingInterval

    local function updateInventory(items)
        if type(items) ~= "table" then return end
        local counts = {}
        for itemId, amount in pairs(items) do
            if type(itemId) == "string" and type(amount) == "number" and amount > 0 and amount < math.huge then
                counts[itemId] = amount
            end
        end
        latestInventory = counts
    end

    F.inventoryConnection = inventoryRemote.OnClientEvent:Connect(updateInventory)

    -- InventoryChanged sends a complete snapshot. Seed from the game's current
    -- snapshot if the script starts after the first inventory event.
    local function seedInventory()
        local toastController = ClientControllers:FindFirstChild("ToastController")
        if not toastController or type(getconnections) ~= "function" or type(getupvalues) ~= "function" then return end
        local ok, connections = pcall(getconnections, inventoryRemote.OnClientEvent)
        if not ok or type(connections) ~= "table" then return end

        for _, connection in ipairs(connections) do
            local callback = connection.Function
            if type(callback) == "function" and debug.info(callback, "s") == toastController:GetFullName() then
                local read, upvalues = pcall(getupvalues, callback)
                if read and type(upvalues) == "table" and upvalues[1] == true then
                    updateInventory(upvalues[2])
                    if latestInventory then return end
                end
            end
        end
    end
    seedInventory()

    local function currentCoinAmount()
        local leaderstats = LocalPlayer:FindFirstChild("leaderstats")
        local coins = leaderstats and leaderstats:FindFirstChild("Coins")
        return if coins and (coins:IsA("IntValue") or coins:IsA("NumberValue")) then coins.Value else nil
    end

    local function resetTrackingStats()
        F.nextPingTime = os.time()
        local inventory = latestInventory
        if not inventory then
            F.trackingSession = nil
            return
        end
        local coins = currentCoinAmount()
        -- Inventory snapshots are replaced on each event, so these references
        -- keep the counts from the start of tracking.
        F.trackingSession = {
            startedAt = os.clock(),
            startingItems = inventory,
            reportedItems = table.clone(inventory),
            startingCoins = coins,
            reportedCoins = coins,
        }
    end

    local function buildSessionReport(session, inventory, coins, forceUpdate)
        local changed = {}
        for itemId, total in pairs(inventory) do
            if total ~= (session.reportedItems[itemId] or 0) then table.insert(changed, itemId) end
        end
        for itemId in pairs(session.reportedItems) do
            if inventory[itemId] == nil then table.insert(changed, itemId) end
        end
        if not forceUpdate and #changed == 0 and (not coins or coins == session.reportedCoins) then return nil end
        table.sort(changed)

        local hours = math.max(os.clock() - session.startedAt, 1) / 3600
        local header = string.format("**Farm session · %.2f hours**\nLast updated <t:%d:R>", hours, os.time())
        if coins and session.startingCoins and session.reportedCoins then
            header ..= string.format("\n**Coins** · %d total · %+d since last report · %+.1f/hour",
                coins, coins - session.reportedCoins, (coins - session.startingCoins) / hours)
        end

        local lines = { header }
        for _, itemId in ipairs(changed) do
            local total = inventory[itemId] or 0
            local change = total - (session.reportedItems[itemId] or 0)
            local rate = (total - (session.startingItems[itemId] or 0)) / hours
            local name = Palette.displayName(itemId) or itemId
            table.insert(lines, string.format("**%s** · %d total · %+d since last report · %+.1f/hour", name, total, change, rate))
        end
        if #changed == 0 then table.insert(lines, "No inventory changes since the last report.") end
        local content = table.concat(lines, "\n")
        if #content <= 2000 then return content end
        return header .. string.format("\n%d changed items. Full details are in the attached report.", #changed), content
    end

    local function webhookMessageUrl(url, messageId)
        local base, query = url:match("^([^?]+)(.*)$")
        local thread = query and query:match("[?&]thread_id=(%d+)")
        return base:gsub("/+$", "") .. "/messages/" .. messageId .. (if thread then "?thread_id=" .. thread else "")
    end

    local function confirmedWebhookUrl(url)
        local confirmedUrl, replaced = url:gsub("([?&])wait=[^&]*", "%1wait=true")
        if replaced == 0 then
            confirmedUrl ..= (if url:find("?", 1, true) then "&" else "?") .. "wait=true"
        end
        return confirmedUrl
    end

    local function requestInventoryReport(action, onFinished)
        if not F.running or not F.isWebhookActive then return false, "Enable webhook tracking first." end
        if F.WEBHOOK_URL == "" then return false, "Enter a Discord webhook URL first." end
        if reportInFlight then return false, "A report is already being sent." end
        if os.clock() < nextReportAllowedAt then return false, "Wait a few seconds before updating again." end
        local session, inventory = F.trackingSession, latestInventory
        if not session or not inventory then return false, "Waiting for your inventory to load." end

        local url = F.WEBHOOK_URL
        local messageId = if action ~= "new" and session.messageUrl == url then session.messageId else nil
        local coins = currentCoinAmount()
        if coins and session.startingCoins == nil then
            session.startingCoins, session.reportedCoins = coins, coins
        end
        local content, fullReport = buildSessionReport(session, inventory, coins, action ~= "scheduled" or not messageId)
        F.nextPingTime = os.time() + F.pingInterval
        if not content then return true end

        reportInFlight = true
        nextReportAllowedAt = os.clock() + 5
        task.spawn(function()
            local ok, success, detail = pcall(function()
                local function stillActive()
                    return F.running and F.trackingSession == session and F.WEBHOOK_URL == url
                end
                local function deliver(id)
                    local payload = { content = content, attachments = {} }
                    if fullReport then payload.attachments = { { id = 0, filename = "farm-report.txt" } } end
                    if not id then payload.username = "ABOVE Auto Farm (" .. LocalPlayer.Name .. ")" end
                    local endpoint = if id then webhookMessageUrl(url, id) else confirmedWebhookUrl(url)
                    local response = requestWebhook(endpoint, if id then "PATCH" else "POST", payload, fullReport)
                    local status = response and tonumber(response.StatusCode)
                    local data
                    if response and type(response.Body) == "string" and response.Body ~= "" then
                        local decoded, value = pcall(HttpService.JSONDecode, HttpService, response.Body)
                        if decoded and type(value) == "table" then data = value end
                    end
                    local retryAfter = data and tonumber(data.retry_after)
                    if status == 429 and retryAfter then
                        nextReportAllowedAt = math.max(nextReportAllowedAt, os.clock() + retryAfter)
                    end
                    return status, data
                end

                if not stillActive() then return false, "Tracking session changed." end
                local status, data = deliver(messageId)
                if messageId and status == 404 and data and data.code == 10008 and stillActive() then
                    -- Discord confirms that the original message was deleted.
                    messageId = nil
                    status, data = deliver(nil)
                end
                if not status or status < 200 or status >= 300 then
                    return false, if status then "Discord returned HTTP " .. status .. "." else "The webhook request failed."
                end
                local deliveredId = messageId or (data and data.id)
                if type(deliveredId) ~= "string" or not deliveredId:match("^%d+$") then
                    return false, "Discord did not return a report message ID."
                end
                if not stillActive() then return false, "Tracking session changed." end

                session.messageId, session.messageUrl = deliveredId, url
                session.reportedItems = inventory
                if coins then session.reportedCoins = coins end
                return true, if messageId then "Report updated." else "New report posted."
            end)
            reportInFlight = false
            if onFinished and F.running then
                onFinished(ok and success, if ok then detail else "Could not process the webhook response.")
            end
        end)
        return true
    end

    local function reportInventoryIfDue()
        if not F.isWebhookActive then return end
        if not F.trackingSession and latestInventory then resetTrackingStats() end
        if os.time() >= F.nextPingTime then requestInventoryReport("scheduled") end
    end

    F.requestWebhook = requestWebhook
    F.sendWebhook = sendWebhook
    F.checkClientDisconnect = checkClientDisconnect
    F.resetTrackingStats = resetTrackingStats
    F.requestInventoryReport = requestInventoryReport
    F.reportInventoryIfDue = reportInventoryIfDue

    return {
        requestWebhook = requestWebhook, sendWebhook = sendWebhook, checkClientDisconnect = checkClientDisconnect,
        resetTrackingStats = resetTrackingStats, requestInventoryReport = requestInventoryReport,
        reportInventoryIfDue = reportInventoryIfDue,
    }
end
