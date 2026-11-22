--[[
    Modules/Pollinator/Tabs.lua  -  Pollinator tab (Automation, Movement, Live Telemetry, FPS Optimizer)
    and the telemetry refresh loop.
    Source: Script2 lines 2130-2241 (verbatim); the tab comes from State.UI.Tabs.Pollen.
]]

return function(State)
    local B = State.Builder
    local PL = State.Pollinator
    local S, Grid, Island, Toggles = B.S, B.Grid, B.Island, B.Toggles
    local notify, STRIP = B.notify, B.STRIP
    local CollectionService = State.Services.CollectionService
    local autoLoop, sweepOnce, collectAll = PL.autoLoop, PL.sweepOnce, PL.collectAll
    local setHidden, applyFpsCap, setcap, setLite = PL.setHidden, PL.applyFpsCap, PL.setcap, PL.setLite
    local Tabs = { Pollen = State.UI.Tabs.Pollen }

    -- Pollinator tab ---------------------------------------------------------------------------
    local gAuto = Tabs.Pollen:AddLeftGroupbox("Automation", "bot")
    gAuto:AddLabel("Standalone: scans every flower on your island. It does not use the Build tab's region, parity or run state.", true)
    gAuto:AddDropdown("PollParity", { Text = "Parent tiles", Values = { "Even", "Odd", "Auto" }, Default = 1,
        Tooltip = "Parents sit on tiles where (x + z) is Even or Odd and are NEVER harvested. Children are the other tiles. Auto = whichever parity holds more mature flowers (check the dry run first)." })
    gAuto:AddToggle("PollHarvest", { Text = "Enable Auto Harvest (Child Tiles Only)", Default = true,
        Tooltip = "Harvests only mature child-tile flowers. Parent tiles are never touched." })
    gAuto:AddToggle("PollPollinate", { Text = "Enable Auto Pollinate (Same-Type Pairs)", Default = true,
        Tooltip = "Pairs mature, idle parents within 2 cells when species, colour and glowing status match and a tile is free for the baby." })
    gAuto:AddToggle("PollMergeVariants", { Text = "Ignore Striped / Dotted variations", Default = true,
        Tooltip = "On: Black Snapdragon covers normal, dotted and striped, so they pair with each other. Glowing is always kept separate from normal. Off: the exact pattern must match too." })
    for i = 1, 4 do
        gAuto:AddToggle("PollStrip" .. i, { Text = "Strip " .. i, Default = true,
            Tooltip = "Pause harvesting and pollinating on this strip while the others keep running. Only applies when the stone dividers of the 4-strip farm are built; flowers outside the strips are always handled." })
    end
    gAuto:AddDropdown("PollStartStrip", { Text = "Start from strip", Values = { "Strip 1", "Strip 2", "Strip 3", "Strip 4" }, Default = 1,
        Tooltip = "Which strip the sweep begins with. It then continues round the other strips and wraps, e.g. start 3 forward = 3, 4, 1, 2." })
    gAuto:AddDropdown("PollStripDir", { Text = "Strip direction", Values = { "Forward (1 -> 4)", "Backward (4 -> 1)" }, Default = 1,
        Tooltip = "Forward visits strips in rising order from the start strip, Backward in falling order (start 3 backward = 3, 2, 1, 4)." })
    gAuto:AddToggle("IgnoreBaby", { Text = "Ignore Baby Sprouts", Default = true,
        Tooltip = "On: only fully mature flowers are touched. Off: sprouts are sent to the server too (it will normally refuse them)." })
    gAuto:AddToggle("PollUseRegion", { Text = "Limit to the Build tab region", Default = false,
        Tooltip = "Optional. Off = the whole island." })
    gAuto:AddSlider("SweepInterval", { Text = "Sweep Interval (s)", Default = 45, Min = 0, Max = 180, Rounding = 0,
        Tooltip = "Pause between sweeps. 0 = continuous (one second floor)." })
    gAuto:AddDivider()
    gAuto:AddToggle("PollAutoRun", { Text = "Run automatically", Default = false, Callback = function(v)
        PL.autoRun = v
        if v then
            PL.stats.started = PL.stats.started or os.clock()
            task.spawn(autoLoop)
        end
    end })
    gAuto:AddButton({ Text = "Run one sweep now", Func = function()
        if PL.sweeping then return end
        PL.stats.started = PL.stats.started or os.clock()
        task.spawn(function()
            local p, err = sweepOnce(false)
            if not p then notify(tostring(err)) else notify("Sweep done: " .. PL.lastPlan, 6) end
        end)
    end })
    gAuto:AddButton({ Text = "Dry run (plan only, nothing is clicked)", Func = function()
        local p, err = sweepOnce(true)
        notify(p and ("Plan: " .. PL.lastPlan) or tostring(err), 7)
    end })
    gAuto:AddButton({ Text = "Collect ALL flowers (whole island)", DoubleClick = true,
        Tooltip = "Harvests every mature flower on the island, parents included. Click twice to confirm. Stops the auto loop first.",
        Func = function() task.spawn(collectAll) end })
    gAuto:AddButton({ Text = "Stop", Func = function()
        PL.autoRun, PL.cancel = false, true
        pcall(function() Toggles.PollAutoRun:SetValue(false) end)
    end })

    local gMove = Tabs.Pollen:AddLeftGroupbox("Movement", "move")
    gMove:AddDropdown("PollMove", { Text = "Movement", Values = { "Glide", "Teleport" }, Default = 1 })
    gMove:AddSlider("PollSpeed", { Text = "Glide speed (studs/s)", Default = 60, Min = 20, Max = 90, Rounding = 0 })
    gMove:AddSlider("PollHover", { Text = "Hover height (studs)", Default = 6, Min = 3, Max = 12, Rounding = 0 })
    gMove:AddToggle("PollReturn", { Text = "Return to start position after a sweep", Default = true })

    local gTele = Tabs.Pollen:AddRightGroupbox("Live Telemetry", "activity")
    local teleLabel = gTele:AddLabel("…", true)
    gTele:AddButton({ Text = "Reset counters", Func = function()
        PL.stats.glow, PL.stats.normal, PL.stats.pairs, PL.stats.rollbacks, PL.stats.sweeps = 0, 0, 0, 0, 0
        PL.stats.started = PL.autoRun and os.clock() or nil
    end })

    local gFps = Tabs.Pollen:AddRightGroupbox("FPS Optimizer", "gauge")
    gFps:AddToggle("HideFlowers", { Text = "Hide Flowers Client-Side (FPS Boost)", Default = false,
        Tooltip = "Local only: makes flower art invisible and turns off their lights/particles. Clicking and the bot are unaffected.",
        Callback = function(v) setHidden(v) end })
    gFps:AddToggle("FpsCapOn", { Text = "Use AFK FPS Cap", Default = false, Callback = applyFpsCap })
    gFps:AddSlider("FpsCap", { Text = "AFK FPS Cap", Default = 20, Min = 10, Max = 60, Rounding = 0, Callback = applyFpsCap,
        Tooltip = setcap and "Applied through setfpscap." or "This executor has no setfpscap, so the cap does nothing." })
    gFps:AddToggle("LiteGfx", { Text = "Disable Shadows & Terrain Decoration", Default = false, Callback = setLite })

    task.spawn(function()
        while not S.unloaded do
            local active = 0
            if os.clock() - (PL.stripCacheAt or -999) > 10 then                 -- strip layout, refreshed every 10 s
                PL.stripCache, PL.stripCacheAt = STRIP.current(), os.clock()
            end
            local sg = PL.stripCache
            local activeBy = { 0, 0, 0, 0 }
            for _, hb in ipairs(CollectionService:GetTagged("Flower")) do
                if hb.Parent and hb:IsDescendantOf(Island) and hb:GetAttribute("Breeding") == true then
                    active += 1
                    if sg then
                        local c = Grid.fromKey(hb:GetAttribute("FlowerCell") or "")
                        local si = c and STRIP.indexOf(sg, c) or 0
                        if si > 0 then activeBy[si] += 1 end
                    end
                end
            end
            local stripLine = "n/a (no stone dividers built on the flower layer)"
            if sg then
                local rd, parts = PL.readyPerStrip or { 0, 0, 0, 0 }, {}
                for i = 1, 4 do
                    parts[i] = ("%d: %da/%dr%s"):format(i, math.floor(activeBy[i] / 2), rd[i] or 0,
                        (Toggles["PollStrip" .. i] and not Toggles["PollStrip" .. i].Value) and " off" or "")
                end
                stripLine = "[" .. table.concat(parts, " | ") .. "]  a = pairs breeding, r = pairs ready"
            end
            local hours = PL.stats.started and math.max((os.clock() - PL.stats.started) / 3600, 1 / 3600) or nil
            local total = PL.stats.glow + PL.stats.normal
            pcall(function()
                teleLabel:SetText(("Glowing Harvested: %d\nNormal Harvested: %d\nFlowers / Hr: %s\nActive Pairs: %d\nStrips: %s\nPairs started: %d  |  rollbacks: %d  |  sweeps: %d\nLast plan: %s"):format(
                    PL.stats.glow, PL.stats.normal, hours and ("%.0f"):format(total / hours) or "-", math.floor(active / 2),
                    stripLine, PL.stats.pairs, PL.stats.rollbacks, PL.stats.sweeps, PL.lastPlan))
            end)
            task.wait(1)
        end
    end)

    return true
end
