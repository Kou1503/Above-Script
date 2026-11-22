--[[
    Modules/Shared/Settings.lua  -  the shared Settings tab.
    Loaded LAST by loader.lua (after every feature tab exists) because the autosave hook only
    attaches to controls that already exist.

    Sources:
      Script1 1223-1266  Appearance + Menu and notifications groupboxes
      Script1 1268-1407  SaveManager setup, autosave profile, Save/Load/LoadJSON patches, autosave hooks
      Script1 2621-2632  Farm session groupbox (minimize / stop and unload)
      Script1 2637       SaveManager:LoadAutoloadConfig()
      Script2 2244-2256  ThemeManager + SaveManager wiring (its MenuKeybind picker is replaced by UIMenuKey)
]]

return function(State)
    local UI = State.UI
    local Library, Window = UI.Library, UI.Window
    local SaveManager, ThemeManager = UI.SaveManager, UI.ThemeManager
    local HttpService = State.Services.HttpService
    local SettingsTab = UI.Tabs.Settings
    local notify = UI.notify
    local transientControls = UI.IgnoreIndexes

    -- The webhook URL is a secret: it is stored in ABOVE_Obsidian/secrets/webhook.txt, never in a profile.
    table.insert(transientControls, "WebhookUrl")

    -- Slider only (the "(exact value)" input boxes were removed on request); right-click still types a value.
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
    UI.addSlider = UI.addSlider or addSlider

    ------------------------------------------------------------------------------------------
    -- Appearance / Menu  (Script1 1223-1266)
    ------------------------------------------------------------------------------------------
    do
    local AppearanceGroup = SettingsTab:AddLeftGroupbox("Appearance", "palette")
    local MenuGroup = SettingsTab:AddRightGroupbox("Menu and notifications", "settings")

    addSlider(AppearanceGroup, "UIScale", "UI scale (%)", 60, 150, 100, 0, function(value)
        Library:SetDPIScale(value)
    end)
    addSlider(AppearanceGroup, "UICornerRadius", "Corner radius", 0, 20, Library.CornerRadius, 0, function(value)
        Window:SetCornerRadius(value)
    end)
    AppearanceGroup:AddLabel("Accent color"):AddColorPicker("UIAccentColor", {
        Title = "Accent color",
        Default = Library.Scheme.AccentColor,
        Callback = function(value)
            Library.Scheme.AccentColor = value
            Library:UpdateColorsUsingRegistry()
        end,
    })
    AppearanceGroup:AddToggle("UICompactSidebar", {
        Text = "Compact sidebar",
        Default = Window:IsSidebarCompacted(),
        Callback = function(value) Window:SetCompact(value) end,
    })
    MenuGroup:AddLabel("Menu hotkey"):AddKeyPicker("UIMenuKey", {
        Text = "Menu hotkey",
        Default = "U",
        Mode = "Press",
        Modes = { "Press" },
        NoUI = true,
    })
    Library.ToggleKeybind = Library.Options.UIMenuKey

    MenuGroup:AddToggle("UICustomCursor", {
        Text = "Custom menu cursor",
        Default = Library.ShowCustomCursor,
        Callback = function(value) Library.ShowCustomCursor = value end,
    })
    MenuGroup:AddDropdown("UINotifyCorner", {
        Text = "Notification position",
        Values = { "TopLeft", "TopRight", "BottomLeft", "BottomRight" },
        Default = if Library.NotifySide == "Left" then "TopLeft" else if Library.NotifySide == "Right" then "TopRight" else Library.NotifySide,
        Callback = function(value) Library:SetNotifySide(value) end,
    })
    end

    ------------------------------------------------------------------------------------------
    -- Themes (Script2 2248-2255)
    ------------------------------------------------------------------------------------------
    ThemeManager:SetLibrary(Library)
    ThemeManager:SetFolder(State.SaveFolder)
    ThemeManager:ApplyToTab(SettingsTab)

    ------------------------------------------------------------------------------------------
    -- Profiles + autosave (Script1 1268-1407)
    ------------------------------------------------------------------------------------------
    SaveManager:SetLibrary(Library)
    SaveManager:IgnoreThemeSettings()
    SaveManager:SetFolder(State.SaveFolder)
    SaveManager:SetIgnoreIndexes(transientControls)
    SaveManager:SetLoadingOrder(true, { "Dropdown", "Input", "Slider", "Toggle" })
    local ConfigGroup = SaveManager:BuildConfigSection(SettingsTab)
    local activeProfile: string? = nil
    local pendingAutosave: thread? = nil
    local loadingProfiles = 0
    local saveProfile = SaveManager.Save
    local loadProfile = SaveManager.Load
    local loadProfileJSON = SaveManager.LoadJSON
    local profileStatus = ConfigGroup:AddLabel("Autosave profile: none", true)

    -- Original `running` (Farm flag) -> the hub-wide alive state, since profiles now cover every feature.
    local function running()
        return not State.Unloaded
    end

    -- LoadJSON resets these Farm toggles; skip any that do not exist because their module failed to load.
    local function setToggle(id, value)
        local toggle = Library.Toggles[id]
        if toggle then toggle:SetValue(value) end
    end

    local function setActiveProfile(name)
        activeProfile = name
        profileStatus:SetText("Autosave profile: " .. (name or "none"))
    end

    local function cancelAutosave()
        if pendingAutosave then
            task.cancel(pendingAutosave)
            pendingAutosave = nil
        end
    end

    local function saveActiveProfile()
        local name = activeProfile
        if not name then return end
        if not table.find(SaveManager:RefreshConfigList(), name) then
            setActiveProfile(nil)
            return
        end
        local ok, err = saveProfile(SaveManager, name)
        if not ok then notify("Autosave failed", tostring(err)) end
    end

    local function flushAutosave()
        if not pendingAutosave then return end
        cancelAutosave()
        saveActiveProfile()
    end

    function SaveManager:Save(name)
        local ok, err = saveProfile(self, name)
        if ok then
            cancelAutosave()
            setActiveProfile(name)
        end
        return ok, err
    end

    function SaveManager:LoadJSON(content)
        loadingProfiles += 1
        local ok, err = loadProfileJSON(self, content)
        if ok then
            flushAutosave()
            setActiveProfile(nil)
            setToggle("ProfileAutosave", false)
            setToggle("AutoReturnToHub", false)
            setToggle("WebhookDisconnectAlerts", false)
            setToggle("BossChargedBow", false)
            setToggle("ExperimentalMiningStandoff", false)
            do
                local profile = HttpService:JSONDecode(content)
                local hasDiagnosticsToggle = false
                for _, setting in profile.objects do
                    if setting.type == "Toggle" and setting.idx == "RecordSessionDiagnostics" then
                        hasDiagnosticsToggle = true
                        break
                    end
                end
                if not hasDiagnosticsToggle then setToggle("RecordSessionDiagnostics", true) end
            end
            if Library.Options.BowAim then Library.Options.BowAim:SetValue("Settled") end
            -- SaveManager applies the loaded controls through deferred callbacks.
            task.defer(function() loadingProfiles -= 1 end)
        else
            loadingProfiles -= 1
        end
        return ok, err
    end

    function SaveManager:Load(name)
        flushAutosave()
        local ok, err = loadProfile(self, name)
        if ok then setActiveProfile(name) end
        return ok, err
    end

    local function queueAutosave()
        if not running() or loadingProfiles > 0 or not activeProfile or not Library.Toggles.ProfileAutosave.Value then return end
        cancelAutosave()
        pendingAutosave = task.delay(1, function()
            pendingAutosave = nil
            saveActiveProfile()
        end)
    end

    ConfigGroup:AddToggle("ProfileAutosave", {
        Text = "Autosave active config",
        Tooltip = "Saves one second after the last change. Load, create, or update a config to make it active.",
        Default = false,
        Callback = function(enabled)
            if not running() or loadingProfiles > 0 then return end
            if enabled then
                if not activeProfile then
                    notify("Autosave", "Create, load, or update a config to choose where changes are saved.")
                end
                queueAutosave()
            elseif activeProfile then
                cancelAutosave()
                saveActiveProfile()
            end
        end,
    })

    ConfigGroup:AddButton({
        Text = "Update selected config",
        Func = function()
            local name = Library.Options.SaveManager_ConfigList.Value
            if not name or not table.find(SaveManager:RefreshConfigList(), name) then
                notify("Update config", "Select an existing config first.")
                return
            end
            local ok, err = SaveManager:Save(name)
            if ok then
                notify("Config updated", name)
            else
                notify("Update failed", tostring(err))
            end
        end,
    })

    for _, controls in { Library.Options, Library.Toggles } do
        for id, control in pairs(controls) do
            if id ~= "ProfileAutosave" and not SaveManager.Ignore[id] and control.OnChanged then
                control:OnChanged(queueAutosave)
            end
        end
    end

    -- Farm/Loop's stopAll() calls flushAutosave(); the hub unload flushes too.
    UI.flushAutosave = flushAutosave
    State.OnCleanup(flushAutosave)

    ------------------------------------------------------------------------------------------
    -- Session (Script1 2621-2632)
    ------------------------------------------------------------------------------------------
    do
        local SessionGroup = SettingsTab:AddLeftGroupbox("Session", "power")
        SessionGroup:AddLabel("Use the menu hotkey above to hide or reopen the menu. Unload stops every feature until you run the script again.", true)
        SessionGroup:AddButton({
            Text = "Minimize menu",
            Func = function() Library:Toggle(false) end,
        })
        SessionGroup:AddButton({
            Text = "Stop and unload everything",
            Func = function()
                if type(State.Farm.stopAll) == "function" then State.Farm.stopAll() end
                State.Unload()
            end,
        })
    end

    ------------------------------------------------------------------------------------------
    -- Apply the autoload profile now that every control exists (Script1 2637 / Script2 2256)
    ------------------------------------------------------------------------------------------
    SaveManager:LoadAutoloadConfig()

    return {
        addSlider = addSlider,
        flushAutosave = flushAutosave,
        queueAutosave = queueAutosave,
    }
end
