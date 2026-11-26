--[[
    Modules/Builder/Tabs.lua  -  Build / Planter / Schematic / Run tabs, Builder unload, headless hooks.
    Source: Script2 lines 1309-1465 (UI, verbatim) and 2258-2288 (unload / __ABOVE_BUILDER / final hooks).
    Changes:
      * the window and tabs come from loader.lua (State.UI.Tabs.Build / Plant / Schem / Run)
      * "Unload (kill switch)" and __ABOVE_BUILDER.Unload unload the whole hub (one shared window)
      * Library:OnUnload(unload) -> State.OnCleanup(unload)
      * the UI Settings tab (Script2 2243-2256) lives in Shared/Settings.lua
]]

return function(State)
    local B = State.Builder
    local UI = State.UI
    local Library = UI.Library
    local genv = (getgenv and getgenv()) or _G
    local S, Config, LP, Remotes, Placement = B.S, B.Config, B.LP, B.Remotes, B.Placement
    local Options = B.Options
    local track, notify = B.track, B.notify
    local pickCell, setRegion, syncSliders, applySliders, layerUnderPlayer =
        B.pickCell, B.setRegion, B.syncSliders, B.applySliders, B.layerUnderPlayer
    local refreshSoon, refreshChecklist, startBuild, copyRegion, buildPlan =
        B.refreshSoon, B.refreshChecklist, B.startBuild, B.copyRegion, B.buildPlan
    local stopMover, restoreHotbar, clearGuides, updateRegionLabel = B.stopMover, B.restoreHotbar, B.clearGuides, B.updateRegionLabel
    local selPart = B.selPart
    local STRIP_SKIP, STRIP_MODE = B.STRIP_SKIP, B.STRIP_MODE

    ------------------------------------------------------------------------------------------
    -- UI
    ------------------------------------------------------------------------------------------
    local Tabs = {
        Build = UI.Tabs.Build,
        Plant = UI.Tabs.Plant,
        Schem = UI.Tabs.Schem,
    }

    local blockIds, flowerIds = {}, {}
    for id in pairs(Config.Build.Blocks) do blockIds[#blockIds + 1] = id end
    for id in pairs(Config.Flower.Flowers) do flowerIds[#flowerIds + 1] = id end
    table.sort(blockIds) table.sort(flowerIds)
    local breakValues = { "Any" }
    for _, id in ipairs(blockIds) do breakValues[#breakValues + 1] = id end
    B.blockIds, B.flowerIds, B.breakValues = blockIds, flowerIds, breakValues

    -- Build tab ------------------------------------------------------------------------------
    local gMode = Tabs.Build:AddLeftGroupbox("Mode & Region", "map")
    gMode:AddDropdown("Mode", {
        Text = "Mode", Values = { "Fill Island Layer", "Schematic Paste", "Break Region", "4-Strip Farm Base" },
        Default = 1, Callback = refreshSoon,
    })
    gMode:AddToggle("AutoLayer", {
        Text = "Auto-Detect Island Layer", Default = false,
        Tooltip = "Uses the Y layer under your feet and the island's full X/Z bounds, ignoring the region below.",
        Callback = refreshSoon,
    })
    B.effectiveRegionLabel = gMode:AddLabel("Set a region to see its dimensions.", true)
    gMode:AddDivider()
    gMode:AddButton({ Text = "Pos 1 = block under player", Func = function()
        local c = pickCell() if c then setRegion(c, S.pos2 or c) end
    end })
    gMode:AddButton({ Text = "Pos 2 = block under player", Func = function()
        local c = pickCell() if c then setRegion(S.pos1 or c, c) end
    end })
    gMode:AddButton({ Text = "Clear region", Func = function() setRegion(nil, nil) end })
    gMode:AddLabel("Stand on each corner, then press its key.", true)
    gMode:AddLabel("Pos 1 key"):AddKeyPicker("KeyPos1", { Default = "Z", Mode = "Press", Text = "Pos 1 key", NoUI = false,
        Callback = function() local c = pickCell() if c then setRegion(c, S.pos2 or c) end end })
    gMode:AddLabel("Pos 2 key"):AddKeyPicker("KeyPos2", { Default = "X", Mode = "Press", Text = "Pos 2 key", NoUI = false,
        Callback = function() local c = pickCell() if c then setRegion(S.pos1 or c, c) end end })
    B.regionLabel = gMode:AddLabel("Pos 1: unset\nPos 2: unset", true)

    local gOrder = Tabs.Build:AddLeftGroupbox("Order", "arrow-right")
    gOrder:AddDropdown("LineAxis", { Text = "Work along", Values = { "Along X", "Along Z", "Along Y" }, Default = 1, Callback = refreshSoon,
        Tooltip = "Finishes one full line, then steps to the next. Along Y = vertical columns." })
    gOrder:AddToggle("Zigzag", { Text = "Zigzag (reverse every other line)", Default = true, Callback = refreshSoon })
    gOrder:AddButton({ Text = "Swap Pos 1 / Pos 2 (reverse start)", Func = function()
        if S.pos1 and S.pos2 then setRegion(S.pos2, S.pos1) end
    end })
    gOrder:AddLabel("Starts at Pos 1 and ends at Pos 2. Layers advance the same way.", true)

    local gStrip = Tabs.Build:AddLeftGroupbox("4-Strip Farm Preset", "columns-3")
    gStrip:AddDropdown("StripAxis", { Text = "Split along", Values = { "Split along X", "Split along Z" }, Default = 1, Callback = refreshSoon,
        Tooltip = "X: the dividers are columns (constant X). Z: the dividers are rows (constant Z)." })
    gStrip:AddDropdown("DividerBlock", { Text = "Divider block", Values = blockIds, Default = (table.find(blockIds, "StoneBlock") or 1),
        Searchable = true, Callback = refreshSoon })
    gStrip:AddLabel("Layer 1 = the whole platform in the Fill block. Layer 2 = 3 one-block divider lines that cut the area into 4 equal strips. Uses the region, or Auto-Detect Island Layer (kept inside the island rim). One Start builds both.", true)
    gStrip:AddButton({ Text = "Use 4-Strip Farm Base mode", Func = function() Options.Mode:SetValue("4-Strip Farm Base") end })

    local gEdit = Tabs.Build:AddRightGroupbox("Region Editor", "move-3d")
    gEdit:AddDropdown("Anchor", { Text = "Base point is the", Values = { "Min corner", "Center" }, Default = 1,
        Callback = function() syncSliders() end })
    gEdit:AddSlider("SizeX", { Text = "Size X (width)", Default = 5, Min = 1, Max = 110, Rounding = 0, Callback = applySliders })
    gEdit:AddSlider("SizeY", { Text = "Size Y (height)", Default = 1, Min = 1, Max = 110, Rounding = 0, Callback = applySliders })
    gEdit:AddSlider("SizeZ", { Text = "Size Z (depth)", Default = 5, Min = 1, Max = 110, Rounding = 0, Callback = applySliders })
    gEdit:AddSlider("BaseX", { Text = "Base X", Default = 0, Min = -110, Max = 110, Rounding = 0, Callback = applySliders })
    gEdit:AddSlider("BaseY", { Text = "Base Y (layer)", Default = 0, Min = -110, Max = 110, Rounding = 0, Callback = applySliders })
    gEdit:AddSlider("BaseZ", { Text = "Base Z", Default = 0, Min = -110, Max = 110, Rounding = 0, Callback = applySliders })
    gEdit:AddButton({ Text = "Move base to my cell (layer under me)", Func = function()
        local y, pc = layerUnderPlayer()
        if not (y and pc) then return end
        B.syncing = true
        Options.BaseX:SetValue(pc.x) Options.BaseY:SetValue(y) Options.BaseZ:SetValue(pc.z)
        B.syncing = false
        applySliders()
    end })

    local gFill = Tabs.Build:AddRightGroupbox("Fill / Break", "layers")
    gFill:AddDropdown("BlockPick", {
        Text = "Fill block", Values = blockIds, Default = (table.find(blockIds, "GrassBlock") or 1),
        Searchable = true, Callback = refreshSoon,
    })
    gFill:AddDropdown("BreakFilter", { Text = "Break only", Values = breakValues, Default = 1, Searchable = true, Callback = refreshSoon })
    gFill:AddLabel("Fill: empty cells, chunk by chunk, each next to an existing block. Break: top layer first with your pickaxe; plain blocks only, never machines.", true)

    -- Planter tab ----------------------------------------------------------------------------
    local gPlant = Tabs.Plant:AddLeftGroupbox("Planting layout", "flower-2")
    local gStrips = Tabs.Plant:AddLeftGroupbox("Strip flowers", "columns-3")
    local gSplit = Tabs.Plant:AddRightGroupbox("Two zones", "split")
    local function showLayout(layout)
        Options.FlowerA:SetVisible(layout ~= STRIP_MODE)
        Options.FlowerB:SetVisible(layout == "Two zones")
        gSplit:SetVisible(layout == "Two zones")
        gStrips:SetVisible(layout == STRIP_MODE)
    end
    gPlant:AddDropdown("PlantLayout", {
        Text = "Layout", Values = { "One flower", "Two zones", STRIP_MODE }, Default = 2,
        Callback = function(value)
            if Options.FlowerB then showLayout(value) end
            refreshSoon()
        end,
    })
    gPlant:AddDropdown("FlowerA", { Text = "Flower A (zone 1)", Values = flowerIds, Default = 1, Searchable = true, Callback = refreshSoon })
    gPlant:AddDropdown("FlowerB", { Text = "Flower B (zone 2)", Values = flowerIds, Default = 1, Searchable = true, Callback = refreshSoon })
    gPlant:AddDropdown("Parity", { Text = "Parity", Values = { "Even", "Odd" }, Default = 1, Callback = refreshSoon, Tooltip = "Even = (gx + gz) % 2 == 0" })
    gPlant:AddToggle("PlantOnTop", { Text = "Plant on top of the region", Default = true, Callback = refreshSoon,
        Tooltip = "The region marks the ground blocks; flowers go one layer above. Auto mode always plants at layer+1." })
    gPlant:AddToggle("RequireSupport", { Text = "Require a block under each flower", Default = true, Callback = refreshSoon })
    gPlant:AddToggle("PlantVariants", { Text = "Use Dotted / Striped variants too", Default = true, Callback = refreshSoon,
        Tooltip = "Black Snapdragon then means normal + dotted + striped, planted in that order as your stock allows. Glowing is its own type: picking a glowing flower only uses glowing ones." })

    local stripFlowerValues = { STRIP_SKIP }
    for _, id in ipairs(flowerIds) do stripFlowerValues[#stripFlowerValues + 1] = id end
    for i = 1, 4 do
        gStrips:AddDropdown("Strip" .. i, { Text = "Strip " .. i .. " Flower", Values = stripFlowerValues, Default = 1,
            Searchable = true, Callback = refreshSoon })
    end

    gSplit:AddDropdown("SplitAxis", { Text = "Run along", Values = { "Row (Z)", "Column (X)" }, Default = 1, Callback = refreshSoon,
        Tooltip = "Row (Z) / Column (X): Flower A starts at one end, Flower B at the opposite end, both working toward the middle." })
    gSplit:AddSlider("GapWidth", { Text = "Minimum empty middle (cells)", Default = 2, Min = 0, Max = 60, Rounding = 0, Callback = refreshSoon,
        Tooltip = "A and B never get closer than this. If your stock runs out earlier the open area in the middle is bigger." })
    gSplit:AddToggle("FlipZones", { Text = "Swap ends (A starts at the high end)", Default = false, Callback = refreshSoon })
    gSplit:AddLabel("A plants from its end toward the centre and B does the same from the opposite end, so they never mix.", true)

    showLayout(Options.PlantLayout.Value)

    -- Schematic tab --------------------------------------------------------------------------
    local gSch = Tabs.Schem:AddLeftGroupbox("Copy & Paste", "clipboard")
    gSch:AddButton({ Text = "Copy region", Func = copyRegion })
    gSch:AddButton({ Text = "Clear clipboard", Func = function() B.clearClipboard() B.updateSchematicControls() refreshSoon() end })
    gSch:AddDropdown("PasteRot", { Text = "Y rotation", Values = { "0", "90", "180", "270" }, Default = 1, Callback = refreshSoon })
    gSch:AddDropdown("PasteMirror", {
        Text = "Mirror", Values = { "None", "Mirror X", "Mirror Z" }, Default = 1, Callback = refreshSoon,
    })
    gSch:AddDropdown("PasteAnchor", {
        Text = "Anchor", Values = { "Copied corner", "Center", "High X corner", "High Z corner", "High X and Z corner" },
        Default = 1, Callback = refreshSoon,
    })
    gSch:AddToggle("SnapPasteY", {
        Text = "Snap paste Y to layer under me (+1)", Default = true, Callback = refreshSoon,
        Tooltip = "Used when following the player or setting the destination to your position.",
    })
    gSch:AddLabel("Rotation turns the schematic around the selected anchor. Plain blocks only.", true)

    gSch:AddToggle("ShowPastePreview", { Text = "Show paste preview", Default = true })
    local singleLayer = gSch:AddToggle("PreviewSingleLayer", { Text = "Show one layer", Default = false })
    local layerControls = gSch:AddDependencyBox()
    local layerSlider = layerControls:AddSlider("PreviewLayer", {
        Text = "Layer from bottom", Default = 1, Min = 1, Max = 2, Rounding = 0, AllowRightClickInput = true,
    })
    layerControls:SetupDependencies({ { singleLayer, true } })
    B.pastePreviewLabel = gSch:AddLabel("Copy a region to preview it here.", true)

    B.schematicChecklistLabel = gSch:AddLabel("Copy a region first.", true)
    gSch:AddButton({ Text = "Paste here", Func = function() startBuild("schematic") end })
    gSch:AddButton({ Text = "Stop", Func = function() S.cancel = true end })
    B.schematicProgressLabel = gSch:AddLabel("Done 0 / 0", true)

    local gPasteRegion = Tabs.Schem:AddRightGroupbox("Placement editor", "move-3d")
    gPasteRegion:AddDropdown("PastePosition", {
        Text = "Destination", Values = { "Follow player", "Fixed coordinates" }, Default = 1,
        Callback = refreshSoon,
    })
    local pasteCoordinates = gPasteRegion:AddDependencyBox()
    local pasteBounds = B.islandBounds()
    pasteCoordinates:AddSlider("PasteX", {
        Text = "Paste X", Default = 0, Min = -pasteBounds.horizontal, Max = pasteBounds.horizontal,
        Rounding = 0, AllowRightClickInput = true, Callback = refreshSoon,
    })
    pasteCoordinates:AddSlider("PasteY", {
        Text = "Paste Y (layer)", Default = 0, Min = -pasteBounds.below, Max = pasteBounds.above,
        Rounding = 0, AllowRightClickInput = true, Callback = refreshSoon,
    })
    pasteCoordinates:AddSlider("PasteZ", {
        Text = "Paste Z", Default = 0, Min = -pasteBounds.horizontal, Max = pasteBounds.horizontal,
        Rounding = 0, AllowRightClickInput = true, Callback = refreshSoon,
    })
    pasteCoordinates:SetupDependencies({ { Options.PastePosition, "Fixed coordinates" } })
    gPasteRegion:AddButton({ Text = "Set destination to my position", Func = function()
        local cell, err = B.playerPasteBase()
        if not cell then notify(err) return end
        local destination, clipped = B.clampCell(cell)
        Options.PasteX:SetValue(destination.x)
        Options.PasteY:SetValue(destination.y)
        Options.PasteZ:SetValue(destination.z)
        Options.PastePosition:SetValue("Fixed coordinates")
        if clipped then notify("Destination trimmed to the world limit.") end
    end })
    gPasteRegion:AddLabel("Coordinates place the anchor on the island grid. Right-click a slider to type an exact value.", true)

    local swap = Tabs.Schem:AddRightGroupbox("Material swap", "layers")
    local materials = {}
    for _, id in ipairs(blockIds) do
        if not (Config.Build.Footprints and Config.Build.Footprints[id]) then table.insert(materials, id) end
    end
    local swapFrom = swap:AddDropdown("SwapMaterialFrom", {
        Text = "Replace", Values = {}, AllowNull = true, Searchable = true, Callback = refreshSoon,
    })
    local swapTo = swap:AddDropdown("SwapMaterialTo", {
        Text = "With", Values = materials, AllowNull = true, Searchable = true, Callback = refreshSoon,
    })
    local function clearSwap()
        swapFrom:SetValue(nil)
        swapTo:SetValue(nil)
    end
    swap:AddButton({ Text = "Clear swap", Func = clearSwap })
    function B.updateSchematicControls()
        local used, available = {}, {}
        if S.clip then
            for _, block in ipairs(S.clip.blocks) do used[block.id] = true end
            for _, id in ipairs(materials) do
                if used[id] then table.insert(available, id) end
            end
        end
        clearSwap()
        swapFrom:SetValues(available)
        layerSlider:SetMax(math.max(2, S.clip and S.clip.size[2] or 1))
        layerSlider:SetValue(1)
    end
    for _, id in ipairs({ "SwapMaterialFrom", "SwapMaterialTo", "PreviewLayer", "PreviewSingleLayer" }) do
        table.insert(UI.IgnoreIndexes, id)
    end

    B.addSchematicLibrary(Tabs.Schem:AddRightGroupbox("Schematic library", "folder"))
    local map = Tabs.Plant:AddRightGroupbox("Planting preview", "grid")
    local mapLabel = map:AddLabel("Select a region to preview planting.", true)
    local pageX, pageZ = 0, 0
    local cachedMap
    local function drawMap()
        if not cachedMap then mapLabel:SetText("Choose a region and flowers to preview planting.") return end
        local m = cachedMap
        local span = 12
        pageX = math.clamp(pageX, 0, math.floor((m.x1-m.x0)/span))
        pageZ = math.clamp(pageZ, 0, math.floor((m.z1-m.z0)/span))
        local x0, z0 = m.x0+pageX*span, m.z0+pageZ*span
        local x1, z1 = math.min(x0+span-1,m.x1), math.min(z0+span-1,m.z1)
        local lines = {("X %d to %d →   Z %d to %d ↓"):format(x0,x1,z0,z1)}
        for z = z0,z1 do
            local row = {}
            for x = x0,x1 do
                local divider = m.dividers[m.splitX and x or z]
                table.insert(row, divider and "|" or (m.cells[x] and m.cells[x][z]) or "·")
            end
            table.insert(lines, '<font face="Code">' .. table.concat(row," ") .. "</font>")
        end
        table.insert(lines, m.legend)
        mapLabel:SetText(table.concat(lines,"\n"))
    end
    function B.updatePlantMap(plan)
        cachedMap = nil
        if plan then
            local m = {cells={},dividers={}}
            if Options.PlantLayout.Value == STRIP_MODE then
                local g = B.stripGeometry()
                if g then
                    m.x0,m.x1,m.z0,m.z1,m.splitX = g.x0,g.x1,g.z0,g.z1,g.splitX
                    for _,d in ipairs(g.dividers) do m.dividers[d]=true end
                    m.legend = "1–4: flower strip   | divider   · no placement"
                end
            else
                local lo,hi = B.region(true)
                if lo then
                    m.x0,m.x1,m.z0,m.z1 = lo.X,hi.X,lo.Z,hi.Z
                    m.legend = "A/B: flower zone   · no placement"
                end
            end
            if m.x0 then
                for _,e in ipairs(plan) do
                    local x,z = e.cell.x,e.cell.z
                    m.cells[x] = m.cells[x] or {}
                    m.cells[x][z] = e.zone
                end
                cachedMap = m
            end
        end
        drawMap()
    end
    for _,button in ipairs({{"← X",-1,0},{"X →",1,0},{"↑ Z",0,-1},{"Z ↓",0,1}}) do
        map:AddButton({Text=button[1],Func=function()
            pageX += button[2]
            pageZ += button[3]
            drawMap()
        end})
    end

    B.addPlanterPresets(Tabs.Plant:AddLeftGroupbox("Planter presets", "folder"))

    -- Planter run (on the Planter tab) ---------------------------------------------------------
    local gPlantRun = Tabs.Plant:AddRightGroupbox("Planter Run", "play")
    B.plantChecklistLabel = gPlantRun:AddLabel("…", true)
    gPlantRun:AddButton({ Text = "Recalculate", Func = refreshChecklist })
    gPlantRun:AddDivider()
    gPlantRun:AddButton({ Text = "Start planting", Func = function() startBuild("plant") end })
    gPlantRun:AddButton({ Text = "Stop", Func = function() S.cancel = true end })
    B.plantProgressLabel = gPlantRun:AddLabel("Done 0 / 0   (rejected 0, stops 0)", true)
    gPlantRun:AddLabel("Uses the region, movement and timing settings on the Build tab.", true)

    -- Build run (on the Build tab) -------------------------------------------------------------
    local gCheck = Tabs.Build:AddLeftGroupbox("Material Checklist", "list-checks")
    B.checklistLabel = gCheck:AddLabel("…", true)
    gCheck:AddButton({ Text = "Recalculate", Func = refreshChecklist })

    local gExec = Tabs.Build:AddRightGroupbox("Execution", "play")
    gExec:AddToggle("Partial", { Text = "Build With Available Stock", Default = false })
    gExec:AddDropdown("MoveMode", { Text = "Movement between chunks", Values = { "Glide", "Teleport" }, Default = 1,
        Tooltip = "Glide = speed-capped slide. Teleport = instant hop (fewer seconds lost, unproven against anti-cheat)." })
    gExec:AddSlider("Interval", {
        Text = "Seconds per placement", Default = math.floor((Placement.CooldownSeconds + 0.025) * 1000) / 1000,
        Min = Placement.CooldownSeconds, Max = 0.6, Rounding = 3, Callback = refreshSoon,
        Tooltip = "Server cooldown is " .. Placement.CooldownSeconds .. "s. Lower just gets placements rejected.",
    })
    gExec:AddSlider("SwingInterval", { Text = "Seconds per swing (break)", Default = 0.23, Min = 0.2, Max = 0.6, Rounding = 3, Callback = refreshSoon,
        Tooltip = "The server ignores swings that arrive too fast. Measured misses: 0.20s = 9%, 0.21s = 5%, 0.22s and up = 0%. 0.23s keeps a small safety margin; a laggy client may want 0.25s." })
    gExec:AddSlider("Speed", { Text = "Glide speed (studs/s)", Default = 60, Min = 20, Max = 90, Rounding = 0 })
    gExec:AddSlider("Hover", { Text = "Hover height over target (studs)", Default = 6, Min = 3, Max = 12, Rounding = 0 })
    gExec:AddToggle("ReturnHome", { Text = "Return to start position when done", Default = true })
    gExec:AddDivider()
    gExec:AddButton({ Text = "Start building", Func = function() startBuild("build") end })
    gExec:AddButton({ Text = "Stop", Func = function() S.cancel = true end })
    B.progressLabel = gExec:AddLabel("Done 0 / 0   (rejected 0, stops 0)", true)
    gExec:AddDivider()
    gExec:AddButton({ Text = "Unload hub (kill switch)", DoubleClick = true, Func = function() Library:Unload() end })

    ------------------------------------------------------------------------------------------
    -- Unload / kill switch
    ------------------------------------------------------------------------------------------
    local function unload()
        if S.unloaded then return end
        S.unloaded = true
        S.cancel = true
        local PL = State.Pollinator
        if PL and PL.shutdown then pcall(PL.shutdown) end        -- restores hidden flowers, shadows, fps cap; stops the auto loop
        pcall(stopMover, false)
        pcall(restoreHotbar)
        for _, c in ipairs(S.conns) do pcall(function() c:Disconnect() end) end
        S.conns = {}
        pcall(function() selPart:Destroy() end)
        pcall(clearGuides)
        State.Release("builder")
        if genv.__ABOVE_BUILDER and genv.__ABOVE_BUILDER.__unified then genv.__ABOVE_BUILDER = nil end
    end
    B.unload = unload
    State.OnCleanup(unload)
    genv.__ABOVE_BUILDER = {
        __unified = true,
        Unload = function() State.Unload() end,
        -- headless hooks (tests / other scripts)
        SetRegion = setRegion, Start = function(context) startBuild(context or "build") end, Stop = function() S.cancel = true end,
        Plan = function() return buildPlan() end, State = S, Lib = Library, PL = State.Pollinator,
    }

    track(LP.CharacterRemoving:Connect(function() S.cancel = true end))
    local invRemote = Remotes:FindFirstChild("InventoryChanged")
    if invRemote then track(invRemote.OnClientEvent:Connect(function() task.delay(0.15, refreshSoon) end)) end

    updateRegionLabel()
    refreshSoon()
    notify("Loaded. Build tab: pick a mode, set a region, Start building. Planter tab: Start planting.", 5)
    return true
end
