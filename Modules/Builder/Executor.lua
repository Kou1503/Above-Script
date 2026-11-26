--[[
    Modules/Builder/Executor.lua  -  live material checklist, glide/teleport mover, placement/break executor,
    startBuild and schematic copy.
    Source: Script2 lines 916-1307 (verbatim; checklistLabel / progressLabel / refreshSoon read through B).
    Activity lock (approved addition): runPlan acquires "builder" before moving and releases it on every exit,
    so the Farm loop yields while a build or break run is active.
]]

return function(State)
    local B = State.Builder
    local S, Grid, Config = B.S, B.Grid, B.Config
    local Options, Toggles, LP, Hotbar = B.Options, B.Toggles, B.LP, B.Hotbar
    local PlaceRemote, ResultRemote, SwingRemote = B.PlaceRemote, B.ResultRemote, B.SwingRemote
    local PLACE_REACH, BREAK_REACH = B.PLACE_REACH, B.BREAK_REACH
    local track, notify, origin, hrp = B.track, B.notify, B.origin, B.hrp
    local inventory, niceName, ensureHeld, findPickaxe, restoreHotbar, buildState =
        B.inventory, B.niceName, B.ensureHeld, B.findPickaxe, B.restoreHotbar, B.buildState
    local boxOf, updateGuides, buildPlan = B.boxOf, B.updateGuides, B.buildPlan

    ------------------------------------------------------------------------------------------
    -- Live material checklist
    ------------------------------------------------------------------------------------------
    -- One checklist + progress label per tab: B.checklistLabel / B.progressLabel (Build tab) and
    -- B.plantChecklistLabel / B.plantProgressLabel (Planter tab).
    B.checklistLabel, B.progressLabel = nil, nil
    B.plantChecklistLabel, B.plantProgressLabel = nil, nil

    local function refreshChecklistFor(checklistLabel, context)
        local ok, plan, note = pcall(buildPlan, context)
        if context == "plant" and B.updatePlantMap then B.updatePlantMap(ok and plan or nil) end
        if not ok then checklistLabel:SetText("Plan error: " .. tostring(plan)) return end
        if not plan then checklistLabel:SetText(tostring(note)) return end
        local need, order = {}, {}
        for _, e in ipairs(plan) do
            if not need[e.id] then need[e.id] = 0 order[#order + 1] = e.id end
            need[e.id] += 1
        end
        local lines = {}
        if B.currentMode(context) == "Break Region" then
            local slot, tool = findPickaxe()
            lines[#lines + 1] = slot and ("[✔] Pickaxe: %s (slot %d)"):format(niceName(tool), slot) or "[✖] Pickaxe: none on your hotbar"
            for _, id in ipairs(order) do lines[#lines + 1] = ("    will break %d x %s"):format(need[id], niceName(id)) end
        else
            local have = inventory()
            for _, id in ipairs(order) do
                local h, n = have[id] or 0, need[id]
                if h >= n then lines[#lines + 1] = ("[✔] %s: %d / %d"):format(niceName(id), h, n)
                else lines[#lines + 1] = ("[✖] %s: %d / %d (Missing %d)"):format(niceName(id), h, n, n - h) end
            end
        end
        if #order == 0 then lines[#lines + 1] = "Nothing to do (region empty/full, or no valid cells)." end
        local chunks = 0
        for _, e in ipairs(plan) do if (e.line or 0) > chunks then chunks = e.line end end
        local per = B.currentMode(context) == "Break Region" and Options.SwingInterval.Value or Options.Interval.Value
        lines[#lines + 1] = ("Cells: %d  |  lines: %d  |  est. %.0fs"):format(#plan, chunks, #plan * per + chunks * 0.5)
        if note then lines[#lines + 1] = note end
        checklistLabel:SetText(table.concat(lines, "\n"))
    end

    -- Performance: a checklist rebuilds the whole plan (~30 ms with Auto-Detect on) and the island changes
    -- constantly while the Pollinator works, so each checklist is only rebuilt while its tab is on screen.
    -- A hidden one is marked dirty and rebuilt within half a second of you opening its tab.
    local UI = State.UI
    local Library = UI.Library
    local tabs = { build = UI.Tabs.Build, plant = UI.Tabs.Plant, schematic = UI.Tabs.Schem }
    local dirty = { build = true, plant = true, schematic = true }
    local function tabVisible(context)
        if Library.Toggled == false then return false end
        local active = Library.ActiveTab
        if active == nil then return true end
        return active == tabs[context]
    end

    local refreshing
    local function refreshChecklist()
        if S.unloaded or S.running then return end
        if refreshing then
            for context in pairs(dirty) do dirty[context] = true end
            return
        end
        refreshing = true
        pcall(updateGuides)
        for _, entry in ipairs({ { "build", B.checklistLabel }, { "plant", B.plantChecklistLabel }, { "schematic", B.schematicChecklistLabel } }) do
            local context, label = entry[1], entry[2]
            if S.unloaded or S.running then break end
            if label then
                dirty[context] = not tabVisible(context)
                if not dirty[context] then
                    local ok, err = pcall(refreshChecklistFor, label, context)
                    if not ok and not S.unloaded then warn("[ABOVE Builder] Checklist: " .. tostring(err)) end
                end
            end
        end
        refreshing = false
    end

    local lastRegionText
    task.spawn(function()
        while not S.unloaded do
            task.wait(0.5)
            if S.unloaded then break end
            if B.effectiveRegionLabel and tabVisible("build") then
                local summary = B.buildRegionSummary()
                if lastRegionText ~= summary then
                    B.effectiveRegionLabel:SetText(summary)
                    lastRegionText = summary
                end
            end
            if not S.running and ((dirty.build and tabVisible("build")) or (dirty.plant and tabVisible("plant"))
                or (dirty.schematic and tabVisible("schematic"))) then
                pcall(refreshChecklist)
            end
        end
    end)

    local pendingRefresh = false
    local function refreshSoon()
        if pendingRefresh then return end
        pendingRefresh = true
        task.delay(0.3, function() pendingRefresh = false pcall(refreshChecklist) end)
    end
    B.refreshSoon = refreshSoon

    ------------------------------------------------------------------------------------------
    -- Movement: Glide (AlignPosition, speed-capped) or Teleport (CFrame hop)
    ------------------------------------------------------------------------------------------
    local mover = { ap = nil, att = nil, home = nil }

    local function startMover()
        local r = hrp()
        if not r then return false end
        mover.home = r.CFrame
        local att = Instance.new("Attachment")
        mover.att = att
        att.Name = "ABOVE_BuilderAtt" att.Parent = r
        local ap = Instance.new("AlignPosition")
        mover.ap = ap
        ap.Name = "ABOVE_BuilderAlign"
        ap.Mode = Enum.PositionAlignmentMode.OneAttachment
        ap.Attachment0 = att
        ap.MaxForce = math.huge
        ap.MaxVelocity = Options.Speed.Value
        ap.Responsiveness = 25
        ap.RigidityEnabled = false
        ap.Position = r.Position
        ap.Parent = r
        return true
    end

    local function stopMover(goHome)
        local r = hrp()
        if mover.ap then
            if goHome and r and mover.home then
                if Options.MoveMode.Value == "Teleport" then
                    r.AssemblyLinearVelocity = Vector3.zero
                    r.CFrame = mover.home
                    mover.ap.Position = mover.home.Position
                    task.wait(0.15)
                else
                    mover.ap.Position = mover.home.Position
                    local t0 = os.clock()
                    while os.clock() - t0 < 6 and (r.Position - mover.home.Position).Magnitude > 3 do task.wait(0.05) end
                end
            end
            mover.ap:Destroy()
        end
        if mover.att then mover.att:Destroy() end
        mover.ap, mover.att, mover.home = nil, nil, nil
    end

    local function cellWorld(cell) return Grid.cellToWorld(origin(), cell) end

    local function inReach(cell, reach)
        local r = hrp()
        return r and (r.Position - cellWorld(cell)).Magnitude <= reach
    end

    local function goTo(target)
        local r = hrp()
        if not r or not mover.ap then return end
        local t0 = os.clock()
        S.moves += 1
        if Options.MoveMode.Value == "Teleport" then
            r.AssemblyLinearVelocity = Vector3.zero
            r.CFrame = CFrame.new(target) * (r.CFrame - r.CFrame.Position)
            mover.ap.Position = target
            task.wait(0.2)             -- let the server see the new position before the next request
        else
            mover.ap.MaxVelocity = Options.Speed.Value
            mover.ap.Position = target
            local limit = (r.Position - target).Magnitude / math.max(Options.Speed.Value, 1) + 2.5
            while os.clock() - t0 < limit and not S.cancel do
                if (r.Position - target).Magnitude < 2.5 then break end
                task.wait(0.03)
            end
            task.wait(0.05)
        end
        S.moveTime += os.clock() - t0
    end

    ------------------------------------------------------------------------------------------
    -- Executor
    ------------------------------------------------------------------------------------------
    local seqCounter = 5000000
    local pending = {}
    local inflight = 0

    track(ResultRemote.OnClientEvent:Connect(function(seq, ok)
        local e = pending[seq]
        if not e then return end
        pending[seq] = nil
        inflight = math.max(0, inflight - 1)
        if ok == true then
            S.placed += 1
            S.rejStreak = 0
            B.setOccupant(e.key, e.id)
        else
            S.rejStreak += 1
            e.tries = (e.tries or 0) + 1
            if e.tries < 2 then S.retry[#S.retry + 1] = e else S.failed += 1 end
        end
    end))

    local nextAt = 0
    local function pace(interval)
        local w = nextAt - os.clock()
        if w > 0 then task.wait(w) end
        nextAt = os.clock() + interval
    end

    local function firePlace(e, st)
        seqCounter += 1
        pending[seqCounter] = e
        inflight += 1
        pace(Options.Interval.Value)
        PlaceRemote:FireServer(e.cell, e.id, e.yaw, Vector3.new(0, 1, 0), false, st.selectedRoll, false, seqCounter)
    end

    local function fireBreak(e, hits)
        for _ = 1, hits do
            if S.cancel or not e.part.Parent then break end
            pace(Options.SwingInterval.Value + (S.swingBoost or 0))
            SwingRemote:FireServer(e.part)
        end
    end

    local function drain(maxWait)
        local t0 = os.clock()
        while inflight > 0 and os.clock() - t0 < maxWait and not S.cancel do task.wait(0.05) end
    end

    local function setProgress(message)
        -- only the tab whose Start launched the run shows its numbers
        local progressLabel = B.context == "plant" and B.plantProgressLabel or B.progressLabel
        if B.context == "schematic" then progressLabel = B.schematicProgressLabel end
        if progressLabel then
            pcall(function()
                progressLabel:SetText(message or ("Done %d / %d   (rejected %d, stops %d)"):format(S.placed, S.total, S.failed, S.moves))
            end)
        end
    end

    local activeRun
    local function executePlan(plan, run)
        B.clearPastePreview()
        S.placed, S.failed, S.total, S.retry, S.moves, S.moveTime, S.rejStreak, S.swingBoost = 0, 0, #plan, {}, 0, 0, 0, 0
        S.startedAt = os.clock()
        pending, inflight = {}, 0
        local isBreak = plan[1] and plan[1].kind == "break"
        local reach = isBreak and BREAK_REACH or PLACE_REACH

        local char = LP.Character
        local humanoid = char and char:FindFirstChildOfClass("Humanoid")
        if humanoid then
            run.died = humanoid.Died:Connect(function() S.cancel = true end)
        end
        if not startMover() then error("No character.", 0) end

        task.spawn(function()
            while activeRun == run and not S.unloaded do setProgress() task.wait(0.25) end
        end)

        local function parkTarget(e)
            local hv = isBreak and math.min(Options.Hover.Value, 4) or Options.Hover.Value
            local hr = math.sqrt(math.max(reach * reach - hv * hv, 9))
            local axisVec = e.dirAxis == "x" and Vector3.xAxis or (e.dirAxis == "y" and Vector3.yAxis or Vector3.zAxis)
            local dir = axisVec * (e.dirSign or 1)
            if e.dirAxis == "y" then
                return cellWorld(e.cell) + dir * (reach * 0.7) + Vector3.new(hv, 0, 0), hv
            end
            return cellWorld(e.cell) + dir * (hr * 0.85) + Vector3.new(0, hv, 0), hv     -- park ahead along the line
        end

        local function position(e)
            if inReach(e.cell, reach) then return end
            local target, hv = parkTarget(e)
            goTo(target)
            if not inReach(e.cell, reach) then goTo(cellWorld(e.cell) + Vector3.new(0, hv, 0)) end
        end

        -- Move while the cooldown runs: as soon as a request has been sent, start the hop toward whatever is
        -- next but out of reach, so travel time overlaps the server cooldown instead of being added to it.
        -- (We wait ~0.12s first so the request that was just sent lands while we are still in place.)
        local function prefetch(nextE)
            if not nextE or S.cancel or inReach(nextE.cell, reach) then return end
            local target = parkTarget(nextE)
            local teleport = Options.MoveMode.Value == "Teleport"
            task.spawn(function()
                task.wait(0.12)
                if activeRun ~= run or S.cancel or not mover.ap or inReach(nextE.cell, reach) then return end
                local r = hrp()
                if not r then return end
                S.moves += 1
                if teleport then
                    r.AssemblyLinearVelocity = Vector3.zero
                    r.CFrame = CFrame.new(target) * (r.CFrame - r.CFrame.Position)
                    mover.ap.Position = target
                    nextAt = math.max(nextAt, os.clock() + 0.2)        -- the settle time rides on the cooldown too
                else
                    mover.ap.MaxVelocity = Options.Speed.Value
                    mover.ap.Position = target
                end
            end)
        end

        local function placeGroup(entries, id)
            if not ensureHeld(id) then notify("Could not equip " .. niceName(id) .. " - skipping.") return end
            local st = buildState()
            for i, e in ipairs(entries) do
                if S.cancel then return end
                if S.occ[e.key] then continue end
                if S.rejStreak >= 6 then
                    notify("6 placements in a row were rejected - stopping. Those cells are probably already taken; recalculate and try again.", 7)
                    S.cancel = true
                    return
                end
                if (st.available or 0) <= 0 and not ensureHeld(id) then notify("Out of " .. niceName(id) .. ".") return end
                position(e)
                while inflight >= 4 and not S.cancel do task.wait(0.02) end
                firePlace(e, st)
                prefetch(entries[i + 1])
            end
            drain(2)
        end

        local function breakAll(entries)
            local slot, tool = findPickaxe()
            if not slot then notify("No pickaxe on your hotbar.") return end
            pcall(Hotbar.select, slot) task.wait(0.3)
            local todo = entries
            for pass = 1, 2 do
                if pass == 2 then S.swingBoost = 0.06 end        -- anything that survived: swing a little slower this time
                for i, e in ipairs(todo) do
                    if S.cancel then return end
                    if e.part.Parent then
                        position(e)
                        if pass == 2 then task.wait(0.15) end
                        local ok, dmg = pcall(Config.Tool.blockDamageOf, tool, e.id)
                        local hp = e.part:GetAttribute("HP") or 50
                        local per = (ok and tonumber(dmg)) or Config.Tool.DefaultBlockDamage
                        fireBreak(e, math.max(1, math.ceil(hp / math.max(per, 1))))
                        prefetch(todo[i + 1])
                    end
                end
                task.wait(0.6)
                local still = {}
                for _, e in ipairs(entries) do if e.part.Parent then still[#still + 1] = e end end
                if #still == 0 then break end
                todo = still
            end
        end

        if isBreak then
            -- progress while breaking: count removed parts
            local watcher = task.spawn(function()
                while activeRun == run and not S.unloaded do
                    local n = 0
                    for _, e in ipairs(plan) do if not e.part.Parent then n += 1 end end
                    S.placed = n
                    task.wait(0.2)
                end
            end)
            breakAll(plan)
            pcall(task.cancel, watcher)
            local broke = 0
            for _, e in ipairs(plan) do if not e.part.Parent then broke += 1 end end
            S.placed, S.failed = broke, #plan - broke
        else
            local i = 1
            while i <= #plan and not S.cancel do
                local id, group = plan[i].id, {}
                while plan[i] and plan[i].id == id do group[#group + 1] = plan[i] i += 1 end
                placeGroup(group, id)
            end
            if not S.cancel and #S.retry > 0 then
                local again = S.retry
                S.retry = {}
                for _, e in ipairs(again) do
                    if S.cancel then break end
                    if not S.occ[e.key] and ensureHeld(e.id) then
                        local st = buildState()
                        position(e)
                        firePlace(e, st)
                        drain(1)
                    end
                end
                drain(2)
            end
        end

    end

    local function runPlan(plan, context)
        if S.unloaded then return end
        if S.running then notify("Already running.") return end
        local locked, holder = State.Acquire("builder")
        if not locked then notify("Stop " .. tostring(holder) .. " first.") return end
        local run = {}
        activeRun = run
        B.context = context or B.context
        S.running, S.cancel = true, false
        S.startedAt = os.clock()
        local ok, err = pcall(executePlan, plan, run)
        activeRun = nil
        local cancelled = S.cancel
        S.cancel = true
        pending, inflight = {}, 0
        if run.died then pcall(function() run.died:Disconnect() end) end
        local moved, moveErr = pcall(stopMover, ok and Toggles.ReturnHome.Value)
        if not moved then pcall(stopMover, false) end
        local restored, restoreErr = pcall(restoreHotbar)
        S.running = false
        State.Release("builder")
        local problem = (not ok and err) or (not moved and moveErr) or (not restored and restoreErr)
        S.lastRun = { mode = Options.MoveMode.Value, kind = plan[1].kind, done = S.placed, total = S.total,
            failed = S.failed, secs = os.clock() - S.startedAt, moves = S.moves, moveTime = S.moveTime }
        local message
        if problem then message = "Run failed: " .. tostring(problem)
        elseif cancelled then message = ("Stopped after %d / %d."):format(S.placed, S.total)
        else message = ("Finished %d / %d in %.1fs."):format(S.placed, S.total, S.lastRun.secs) end
        setProgress(message)
        notify(message, 5)
        task.defer(function() pcall(refreshChecklist) end)
    end

    local function startBuild(context)
        if S.unloaded or S.running then return end
        context = context or B.context
        local ok, plan, note = pcall(buildPlan, context)
        if not ok then notify("Plan error: " .. tostring(plan)) return end
        if not plan then notify(tostring(note)) return end
        if #plan == 0 then notify("Nothing to do.") return end

        if plan[1].kind == "place" then
            local have = inventory()
            local need, order = {}, {}
            for _, e in ipairs(plan) do
                if not need[e.id] then need[e.id] = 0 order[#order + 1] = e.id end
                need[e.id] += 1
            end
            local missing = false
            for _, id in ipairs(order) do if (have[id] or 0) < need[id] then missing = true end end
            if missing then
                if not Toggles.Partial.Value then
                    notify("Missing materials - see the checklist. Enable 'Build With Available Stock' to build what you have.", 6)
                    return
                end
                local budget, trimmed = {}, {}
                for _, e in ipairs(plan) do
                    budget[e.id] = budget[e.id] or (have[e.id] or 0)
                    if budget[e.id] > 0 then budget[e.id] -= 1 trimmed[#trimmed + 1] = e end
                end
                plan = trimmed
                if #plan == 0 then notify("You own none of the required items.") return end
            end
        end
        task.spawn(runPlan, plan, context)
    end

    ------------------------------------------------------------------------------------------
    -- Schematic copy
    ------------------------------------------------------------------------------------------
    local function copyRegion()
        if not (S.pos1 and S.pos2) then notify("Set a region first.") return end
        local lo, hi = boxOf(S.pos1, S.pos2)
        local blocks, skipped = {}, 0
        local function collect(c, k, id)
            if Config.Build.Blocks[id] and not (Config.Build.Footprints and Config.Build.Footprints[id]) then
                local part = S.parts[k]
                blocks[#blocks + 1] = { dx = c.x - lo.X, dy = c.y - lo.Y, dz = c.z - lo.Z, id = id,
                    rot = (part and part:GetAttribute("Rotation")) or 0 }
            else
                skipped += 1
            end
        end
        local volume = (hi.X - lo.X + 1) * (hi.Y - lo.Y + 1) * (hi.Z - lo.Z + 1)
        if volume < S.occupiedCells then
            for x = lo.X, hi.X do for y = lo.Y, hi.Y do for z = lo.Z, hi.Z do
                local k = B.key(x, y, z)
                if S.occ[k] then collect(Grid.cell(x, y, z), k, S.occ[k]) end
            end end end
        else
            for k, id in pairs(S.occ) do
                local c = Grid.fromKey(k)
                if c and c.x >= lo.X and c.x <= hi.X and c.y >= lo.Y and c.y <= hi.Y and c.z >= lo.Z and c.z <= hi.Z then
                    collect(c, k, id)
                end
            end
        end
        if #blocks == 0 then notify("No plain blocks found in that region.") return end
        local previewBlocks = B.selectPreviewBlocks(blocks)
        for _, block in ipairs(previewBlocks) do
            local sourceCell = Grid.cell(lo.X + block.dx, lo.Y + block.dy, lo.Z + block.dz)
            local part = S.parts[Grid.key(sourceCell)]
            block.visual = B.captureBlockVisual(part)
            if block.visual then block.visualOffset = part.Position - Grid.cellToWorld(origin(), sourceCell) end
        end
        B.clearClipboard()
        S.clip = { blocks = blocks, previewBlocks = previewBlocks, size = { hi.X - lo.X + 1, hi.Y - lo.Y + 1, hi.Z - lo.Z + 1 } }
        B.updateSchematicControls()
        notify(("Copied %d blocks (%d machines/plants skipped)."):format(#blocks, skipped))
        refreshSoon()
    end

    B.refreshChecklist = refreshChecklist
    B.mover, B.startMover, B.stopMover, B.cellWorld, B.inReach, B.goTo = mover, startMover, stopMover, cellWorld, inReach, goTo
    B.pace, B.firePlace, B.fireBreak, B.drain, B.setProgress = pace, firePlace, fireBreak, drain, setProgress
    B.runPlan, B.startBuild, B.copyRegion = runPlan, startBuild, copyRegion
    return true
end
