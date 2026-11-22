--[[
    Modules/Farm/Tabs.lua  -  every Auto Farm control on the shared window.
    Source: Script1 lines 719-1222 (verbatim control definitions and callbacks).
    Changes: groupboxes are placed on the unified tabs instead of one tab each (control IDs unchanged,
    so saved profiles still load); the webhook URL input also writes the local secret file.
      Combat    : Auto Kill (left)            | Auto Boss (right)
      Gathering : Auto Mine + Experimental    | Auto Cut Tree
      Collect   : Auto Shiny                  | Auto Catch
      Priority  : Feature priority
      Movement  : Shared flight controls      | Safety
      Webhook   : Discord monitoring          | Diagnostics
    The Appearance / Menu / Profiles groupboxes (Script1 1223-1407) live in Shared/Settings.lua.
]]

return function(State)
    local F = State.Farm
    local UI = State.UI
    local Tabs = UI.Tabs
    local VirtualUser = State.Services.VirtualUser
    local LocalPlayer = F.LocalPlayer
    local Remotes = F.Remotes
    local catcher = F.catcher
    local diagnostics = F.diagnostics
    local miningStandoff = F.miningStandoff
    local bossBow = F.bossBow
    local enabledModes = F.enabledModes
    local featureLabelByMode = F.featureLabelByMode
    local defaultFeatureOrder = F.defaultFeatureOrder
    local featurePriority = F.featurePriority
    local featurePriorityRank = F.featurePriorityRank
    local modeHoverHeights = F.modeHoverHeights
    local preferNearestNode = F.preferNearestNode
    local bowRetryAfter = F.bowRetryAfter
    local shinyFamilies = F.shinyFamilies
    local prioritySet = F.prioritySet
    local sendWebhook = F.sendWebhook
    local resetTrackingStats = F.resetTrackingStats
    local requestInventoryReport = F.requestInventoryReport

    local KillGroup = Tabs.Combat:AddLeftGroupbox("Combat", "swords")
    local BossGroup = Tabs.Combat:AddRightGroupbox("Ruins boss", "skull")
    local MineGroup = Tabs.Gathering:AddLeftGroupbox("Mining", "pickaxe")
    local TreeGroup = Tabs.Gathering:AddRightGroupbox("Woodcutting", "axe")
    local ShinyGroup = Tabs.Collect:AddLeftGroupbox("Collectibles", "gem")
    local PriorityGroup = Tabs.Priority:AddLeftGroupbox("Feature priority", "list-ordered")
    local MovementGroup = Tabs.Movement:AddLeftGroupbox("Shared flight controls", "move")
    local SafetyGroup = Tabs.Movement:AddRightGroupbox("Safety", "shield")
    local WebhookGroup = Tabs.Webhook:AddLeftGroupbox("Discord monitoring", "bell")
    local transientControls = UI.IgnoreIndexes
    UI.Groups.Kill, UI.Groups.Boss, UI.Groups.Mine, UI.Groups.Tree = KillGroup, BossGroup, MineGroup, TreeGroup
    UI.Groups.Shiny, UI.Groups.Priority, UI.Groups.Movement = ShinyGroup, PriorityGroup, MovementGroup
    UI.Groups.Safety, UI.Groups.Webhook = SafetyGroup, WebhookGroup

    local notify = UI.notify

    do
        local group = Tabs.Webhook:AddRightGroupbox("Session activity", "activity")
        local status = group:AddLabel("Waiting for the saved profile.", true)
        diagnostics.onStatus = function(message) status:SetText(message) end
        group:AddToggle("RecordSessionDiagnostics", {
            Text = "Record session activity",
            Tooltip = "Keeps roughly five minutes of recent activity and totals for the whole recording.",
            Default = true,
            Callback = function(value)
                if diagnostics.ready then diagnostics.setEnabled(value) end
            end,
        })
        group:AddLabel("Logs are saved in Real workspace / ABOVE_Obsidian / diagnostics, under your Roblox user ID.", true)
        group:AddButton({
            Text = "Send current log to Discord",
            Func = function()
                local attachment = diagnostics.snapshot()
                if not attachment then
                    notify("Diagnostics", "Enable recording and check that a log can be generated.")
                    return
                end
                sendWebhook("Diagnostic snapshot for **" .. LocalPlayer.Name .. "**.", attachment, "above-session.json", function(_, message)
                    notify("Diagnostics", message)
                end)
            end,
        })
    end

    do
        local group = Tabs.Gathering:AddLeftGroupbox("Experimental mining", "flask-conical")
        group:AddToggle("ExperimentalMiningStandoff", {
            Text = "Mine from maximum reach",
            Tooltip = "Mines nearby selected ores first. Tries up to 20 studs and moves closer if the server does not confirm hits.",
            Default = false,
            Callback = function(value)
                miningStandoff.enabled = value
                miningStandoff.hit = nil
                F.nextPrimaryScan = 0
            end,
        })
    end

    -- Slider only (the "(exact value)" input boxes were removed on request).
    -- AllowRightClickInput still lets you right-click a slider to type an exact number.
    local function addSlider(group, id, label, min, max, default, rounding, callback)
        return group:AddSlider(id, {
            Text = label,
            Min = min,
            Max = max,
            Default = default,
            Rounding = rounding,
            AllowRightClickInput = true,
            Callback = function(value)
                callback(value)
            end,
        })
    end
    UI.addSlider = addSlider

    local function setModeEnabled(mode: string, value: boolean)
        if enabledModes[mode] == value then return end
        enabledModes[mode] = value
        F.primaryTarget = nil
        F.primaryTargetMode = nil
        F.activeMode = nil
        F.lastSwingTarget = nil
        F.lastSwingAt = 0
        F.equippedSlot = nil
        F.equipReadyAt = 0
        F.nextPrimaryScan = 0
        if value then notify("Feature enabled", featureLabelByMode[mode] .. " is on.") end
    end

    local function addHoverControl(group, mode)
        local heightMax = if mode == "mine" or mode == "tree" then 20 else 15
        addSlider(group, "HoverHeight_" .. mode, "Hover height", 1, heightMax, modeHoverHeights[mode], 1, function(value)
            modeHoverHeights[mode] = value
        end)
    end

    local function addModeControls(group, mode, description)
        group:AddToggle("Mode_" .. mode, {
            Text = featureLabelByMode[mode],
            Tooltip = description,
            Default = enabledModes[mode],
            Callback = function(value) setModeEnabled(mode, value) end,
        })
        addHoverControl(group, mode)
    end

    local function addOrderedDropdown(group, id, label, choices, initial, apply)
        local ordered = table.clone(initial)
        local allowed = prioritySet(choices)
        local dropdown
        local orderLabel

        local function orderText()
            return "Selected order: " .. (if #ordered == 0 then "None" else table.concat(ordered, " → "))
        end

        local function applyOrder(nextOrder)
            ordered = nextOrder
            apply(ordered)
            if orderLabel then orderLabel:SetText(orderText()) end
        end

        -- Obsidian's multi-select value is an unordered set. Save the ordered list
        -- through SaveManager as a hidden input, and derive the visible selection from it.
        local orderOption = group:AddInput(id .. "_Order", {
            Default = table.concat(ordered, ","),
            Visible = false,
            AllowEmpty = true,
            Callback = function(value)
                if value == table.concat(ordered, ",") then return end
                local nextOrder = {}
                local seen = {}
                for _, item in ipairs(string.split(value, ",")) do
                    if allowed[item] and not seen[item] then
                        table.insert(nextOrder, item)
                        seen[item] = true
                    end
                end
                applyOrder(nextOrder)
                if dropdown then dropdown:SetValue(prioritySet(ordered)) end
            end,
        })

        table.insert(transientControls, id)
        dropdown = group:AddDropdown(id, {
            Text = label,
            Tooltip = "Selected targets are tried in the order you add them.",
            Values = choices,
            Default = ordered,
            Multi = true,
            AllowNull = true,
            Callback = function(selected)
                local nextOrder = {}
                local added = {}
                for _, item in ipairs(ordered) do
                    if selected[item] then
                        table.insert(nextOrder, item)
                        added[item] = true
                    end
                end
                for _, item in ipairs(choices) do
                    if selected[item] and not added[item] then table.insert(nextOrder, item) end
                end
                local value = table.concat(nextOrder, ",")
                if value == table.concat(ordered, ",") then return end
                applyOrder(nextOrder)
                orderOption:SetValue(value)
            end,
        })
        orderLabel = group:AddLabel(orderText(), true)
    end

    local function refreshTargetOrder(mode, order)
        if F.primaryTargetMode == mode and F.primaryTarget and not table.find(order, F.primaryTarget.id) then
            F.primaryTarget = nil
            F.primaryTargetMode = nil
        end
        F.nextPrimaryScan = 0
    end

    KillGroup:AddLabel("Equip Soulfire Bow or Soul Scepter in the Weapon slot for ranged combat. Bow aim also applies to Auto Boss.", true)
    addModeControls(KillGroup, "kill", "Attacks selected Hub slimes and Ruins guardians.")
    addOrderedDropdown(KillGroup, "EnemyTargets", "Enemy priority", F.enemyTypes, F.enemyPriority, function(order)
        F.enemyPriority = order
        refreshTargetOrder("kill", order)
    end)
    KillGroup:AddToggle("NearestSelectedEnemy", {
        Text = "Nearest selected mob",
        Tooltip = "Choose the closest eligible mob from your selection, regardless of the selected order.",
        Default = F.preferNearestEnemy,
        Callback = function(value)
            F.preferNearestEnemy = value
            F.nextPrimaryScan = 0
        end,
    })
    KillGroup:AddToggle("AutoReturnToHub", {
        Text = "Auto return to Hub",
        Tooltip = "Walks to your island's HUB portal when you return home, then resumes farming in the Hub.",
        Default = F.autoReturnToHub,
        Callback = function(value)
            F.autoReturnToHub = value
        end,
    })
    KillGroup:AddDropdown("BowAim", {
        Text = "Bow aim",
        Tooltip = "Settled checks the arrow path and waits for steady aim. Standard uses the original overhead shots.",
        Values = { "Settled", "Standard" },
        Default = F.bowAim,
        AllowNull = false,
        Callback = function(value)
            if value ~= "Settled" and value ~= "Standard" then return end
            F.bowAim = value
            F.bowState = nil
            F.bowShotPending = nil
            table.clear(bowRetryAfter)
            F.nextPrimaryScan = 0
        end,
    })

    local function addNearestNodeToggle(group, mode, label)
        group:AddToggle("NearestNode_" .. mode, {
            Text = label,
            Tooltip = "Choose the closest eligible target from your selection, regardless of the selected order.",
            Default = preferNearestNode[mode],
            Callback = function(value)
                preferNearestNode[mode] = value
                F.nextPrimaryScan = 0
            end,
        })
    end

    addModeControls(MineGroup, "mine", "Mines the selected resources.")
    addOrderedDropdown(MineGroup, "OreTargets", "Resource priority", F.oreTypes, F.orePriority, function(order)
        F.orePriority = order
        refreshTargetOrder("mine", order)
    end)
    addNearestNodeToggle(MineGroup, "mine", "Nearest selected resource")

    addModeControls(TreeGroup, "tree", "Chops selected trees.")
    addOrderedDropdown(TreeGroup, "TreeTargets", "Tree priority", F.treeTypes, F.treePriority, function(order)
        F.treePriority = order
        refreshTargetOrder("tree", order)
    end)
    addNearestNodeToggle(TreeGroup, "tree", "Nearest selected tree")

    addModeControls(BossGroup, "boss", "Attacks selected Morten variants in the Ruins with your equipped weapon.")
    addOrderedDropdown(BossGroup, "BossTargets", "Boss targets", F.bossTypes, F.bossPriority, function(order)
        F.bossPriority = order
        refreshTargetOrder("boss", order)
    end)
    BossGroup:AddToggle("BossChargedBow", {
        Text = "Charged bow with grab dodge",
        Tooltip = "Uses Soulfire Bow at range against selected Morten variants and retreats on grab cues.",
        Default = false,
        Callback = function(value)
            bossBow.enabled = value
            if F.bowState and F.bowState.boss then F.bowState = nil end
            F.nextPrimaryScan = 0
        end,
    })

    ShinyGroup:AddToggle("Mode_shiny", {
        Text = "Auto Shiny",
        Tooltip = "Finds shiny pickups and triggers Collect within prompt range.",
        Default = F.autoShiny,
        Callback = function(value)
            F.autoShiny = value
            F.currentShiny = nil
            F.nextShinyScan = 0
            F.shinyPromptAttempts = 0
            F.nextShinyPromptAt = 0
        end,
    })
    ShinyGroup:AddDropdown("ShinyFamilies", {
        Text = "Shiny family filter",
        Values = shinyFamilies,
        Default = shinyFamilies,
        Multi = true,
        AllowNull = true,
        Callback = function(value)
            F.selectedFamilies = value
            F.currentShiny = nil
            F.nextShinyScan = 0
        end,
    })
    addHoverControl(ShinyGroup, "shiny")

    do
        local FarmingGroup = Tabs.Collect:AddRightGroupbox("Auto Catch", "rabbit")
        UI.Groups.Farming = FarmingGroup
        FarmingGroup:AddToggle("Mode_catch", {
            Text = featureLabelByMode.catch,
            Tooltip = "Lassoes wild Ruins animals from outside their flee range. Needs a Lasso in your inventory; it is put on the hotbar slot below if it is not there already.",
            Default = enabledModes.catch,
            Callback = function(value)
                setModeEnabled("catch", value)
                if not value then catcher.stopAim() catcher.restoreHotbar() end
            end,
        })
        FarmingGroup:AddDropdown("CatchSpecies", {
            Text = "Animals to catch",
            Values = { "Chicken", "Cow", "Sheep", "Horse" },
            Default = { "Chicken", "Cow", "Sheep", "Horse" },
            Multi = true,
            Callback = function(value)
                catcher.species = value
                F.primaryTarget = nil
                F.nextPrimaryScan = 0
            end,
        })
        FarmingGroup:AddLabel("Flee ranges: Chicken 20, Horse 18, Cow 15, Sheep 10 studs. The lasso reaches 48. Be in the Ruins (or raise Maximum target distance on the Movement tab).", true)
        FarmingGroup:AddToggle("CatchFromAbove", {
            Text = "Throw from directly above",
            Tooltip = "Hovers straight over the animal at flee range + the distance below and drops the lasso. Much more accurate than throwing from the side. Off = old side throw (uses the height slider).",
            Default = true,
            Callback = function(value) catcher.fromAbove = value end,
        })
        addSlider(FarmingGroup, "CatchMargin", "Distance beyond flee range", 2, 20, catcher.margin, 0, function(value)
            catcher.margin = value
        end)
        addSlider(FarmingGroup, "CatchHeight", "Throw height above animal", 2, 20, catcher.height, 0, function(value)
            catcher.height = value
        end)
        addSlider(FarmingGroup, "CatchLassoSlot", "Hotbar slot for the Lasso", 1, 9, catcher.slot, 0, function(value)
            catcher.restoreHotbar()
            catcher.slot = value
        end)
        catcher.label = FarmingGroup:AddLabel("Throws 0 | caught 0 | missed 0", true)
        local Alert = Remotes:FindFirstChild("Alert")
        if Alert then
            catcher.alertConnection = Alert.OnClientEvent:Connect(function(text)
                local species = type(text) == "string" and string.match(text, "^Caught an? .-(%a+)$")   -- "Caught a Buff Chicken" -> Chicken
                if species then
                    catcher.stats.caught += 1
                    catcher.stats.bySpecies[species] = (catcher.stats.bySpecies[species] or 0) + 1
                    diagnostics.count("animalsCaught")
                    catcher.refreshLabel()
                end
            end)
        end
    end

    PriorityGroup:AddLabel("Rank 1 runs first. Ties use Shiny, Boss, Kill, Catch, Mine, Tree.", true)
    for _, mode in ipairs(defaultFeatureOrder) do
        addSlider(PriorityGroup, "Priority_" .. mode, featureLabelByMode[mode], 1, #defaultFeatureOrder,
            featurePriorityRank[mode], 0, function(value)
            if featurePriorityRank[mode] == value then return end
            featurePriorityRank[mode] = value
            table.sort(featurePriority, function(left, right)
                local leftRank, rightRank = featurePriorityRank[left], featurePriorityRank[right]
                if leftRank ~= rightRank then return leftRank < rightRank end
                return table.find(defaultFeatureOrder, left) < table.find(defaultFeatureOrder, right)
            end)
            F.primaryTarget = nil
            F.primaryTargetMode = nil
            F.activeMode = nil
            F.currentShiny = nil
            F.nextPrimaryScan = 0
            F.nextShinyScan = 0
        end)
    end

    MovementGroup:AddLabel("Right-click any slider to type an exact value.", true)
    addSlider(MovementGroup, "FlightSpeed", "Flight speed", 60, 500, F.flightSpeed, 0, function(value)
        F.flightSpeed = value
    end)
    addSlider(MovementGroup, "TargetDistance", "Maximum target distance", 20, 2000, F.maxTargetDistance, 0, function(value)
        if F.maxTargetDistance == value then return end
        F.maxTargetDistance = value
        F.primaryTarget = nil
        F.currentShiny = nil
        F.nextPrimaryScan = 0
        F.nextShinyScan = 0
    end)

    SafetyGroup:AddToggle("SmoothOrbit", {
        Text = "Smooth combat orbit",
        Tooltip = "Moves in a circle inside sword reach.",
        Default = F.smoothOrbitEnabled,
        Callback = function(value)
            F.smoothOrbitEnabled = value
            F.orbitTarget = nil
        end,
    })
    addSlider(SafetyGroup, "OrbitRadius", "Orbit radius", 4.5, 5.15, F.smoothOrbitRadius, 2, function(value)
        F.smoothOrbitRadius = value
    end)
    addSlider(SafetyGroup, "OrbitSpeed", "Orbit speed", 0.2, 3.0, F.smoothOrbitSpeed, 2, function(value)
        F.smoothOrbitSpeed = value
    end)

    F.antiAfkConnection = nil
    local function setAntiAfk(enabled)
        if enabled and not F.running then return end
        if enabled and not F.antiAfkConnection then
            F.antiAfkConnection = LocalPlayer.Idled:Connect(function()
                VirtualUser:CaptureController()
                VirtualUser:ClickButton2(Vector2.new())
            end)
        elseif not enabled and F.antiAfkConnection then
            F.antiAfkConnection:Disconnect()
            F.antiAfkConnection = nil
        end
    end
    F.setAntiAfk = setAntiAfk

    SafetyGroup:AddToggle("AntiAfk", {
        Text = "Anti-AFK",
        Tooltip = "Prevents Roblox from disconnecting you for idling.",
        Default = false,
        Callback = setAntiAfk,
    })

    WebhookGroup:AddInput("WebhookUrl", {
        Text = "Discord webhook URL",
        Tooltip = "Saved only in ABOVE_Obsidian/secrets/webhook.txt on this device, never in profiles.",
        Placeholder = "https://discord.com/api/webhooks/...",
        Default = F.WEBHOOK_URL,
        ClearTextOnFocus = false,
        Callback = function(value)
            F.WEBHOOK_URL = value
            State.SaveWebhook(value)
        end,
    })
    WebhookGroup:AddToggle("WebhookTracking", {
        Text = "Enable webhook tracking",
        Default = false,
        Callback = function(value)
            if F.isWebhookActive == value then return end
            F.isWebhookActive = value
            if value then resetTrackingStats() else F.trackingSession = nil end
        end,
    })
    WebhookGroup:AddToggle("WebhookDisconnectAlerts", {
        Text = "Discord disconnect alerts",
        Tooltip = "Sends the Roblox error code and message to your webhook when the client reports a disconnect.",
        Default = F.disconnectAlertsEnabled,
        Callback = function(value)
            F.disconnectAlertsEnabled = value
            if value and not F.disconnectConnection then
                notify("Disconnect alerts", "Roblox's disconnect signal is unavailable. Checking the error code periodically.")
            end
        end,
    })
    addSlider(WebhookGroup, "WebhookInterval", "Status update interval (seconds)", 60, 3600, F.pingInterval, 0, function(value)
        F.pingInterval = value
        F.nextPingTime = os.time() + value
    end)
    local function manualWebhookReport(action)
        local accepted, reason = requestInventoryReport(action, function(success, message)
            notify(if success then "Webhook report" else "Webhook error", message)
        end)
        if not accepted then notify("Webhook report", reason) end
    end

    WebhookGroup:AddButton({
        Text = "Update now",
        Func = function() manualWebhookReport("refresh") end,
    })
    WebhookGroup:AddButton({
        Text = "Post new report",
        Func = function() manualWebhookReport("new") end,
    })
    WebhookGroup:AddButton({
        Text = "Test webhook connection",
        Func = function()
            if F.WEBHOOK_URL == "" then
                notify("Webhook error", "Paste a Discord webhook URL first.")
                return
            end
            sendWebhook("Test ping from ABOVE Unified Auto Farm.")
        end,
    })

    F.setModeEnabled = setModeEnabled
    F.refreshTargetOrder = refreshTargetOrder
    return true
end
