--[[
    Modules/Pollinator/Pollinator.lua  -  auto-pollinate + auto-harvest logic, Collect All, auto loop.
    Source: Script2 lines 1467-2005 (verbatim), 2097-2109 (autoLoop) and 2118-2128 (PL exports / withMover).
    PL is State.Pollinator.  PL.shutdown is defined in Fps.lua, after the FPS helpers it calls.
    Activity lock (approved addition): every sweep / Collect All / withMover acquires "pollinator" while
    the character is being moved and releases it when that run ends.
]]

return function(State)
    local B = State.Builder
    local S, Grid, Config, Island, Remotes, Hotbar = B.S, B.Grid, B.Config, B.Island, B.Remotes, B.Hotbar
    local Options, Toggles = B.Options, B.Toggles
    local track, notify, hrp, key, islandBounds, buildState = B.track, B.notify, B.hrp, B.key, B.islandBounds, B.buildState
    local region, STRIP = B.region, B.STRIP

    ------------------------------------------------------------------------------------------
    -- Pollinator: auto-pollinate + auto-harvest.  STANDALONE - it does not use the Builder's region,
    -- parity, running state or mover.  It scans every flower on your island and applies its own logic.
    --
    -- Live-probed (ABOVE v132):
    --   Flower      = Part "HB" tagged "Flower" inside a flower Model. Attributes: FlowerCell "x,y,z",
    --                 FlowerId "GlowingBlueSnapdragon", Mature (bool), Breeding (bool, only while a pair is breeding).
    --   Species/Color/Glowing come from Config.Flower.Flowers[FlowerId] = {species, color, pattern}.
    --   Pollinate   Remotes.RequestPollinate:FireServer(HBpart) with the "Pollinator" item held.
    --               Click 1 -> server sends PollenSource(cellKey) (you now carry pollen from that flower).
    --               Click 2 on a partner (<= PartnerRadiusCells = 2) -> PollenSource(nil); both get Breeding=true.
    --               Click 2 on the SAME flower -> PollenSource(nil): that is how pollen is handed back.
    --               Pollen expires after 90s.  Breeding lasts 720-900s.
    --               Selecting the Pollinator needs ~1s to register server side; an earlier click is ignored.
    --   Reach       pollinate accepted at 18.2 studs, ignored at 22.2 -> we stay inside 16.
    --   Harvest     Remotes.RequestHarvest:FireServer(HBpart)  (separate remote; RequestSwing is not used).
    ------------------------------------------------------------------------------------------
    local CollectionService = State.Services.CollectionService
    local HarvestRemote = Remotes:WaitForChild("RequestHarvest")
    local PollinateRemote = Remotes:WaitForChild("RequestPollinate")
    local PollenRemote = Remotes:WaitForChild("PollenSource")
    local PollinatorItem = Config.Flower.PollinatorItem or "Pollinator"
    local BreedCfg = Config.Flower.Breeding
    local POLL_REACH = 16
    local HARVEST_REACH = 16
    -- Live-tested (ABOVE v145): the server answers each pollinate click in ~50 ms and accepts clicks back to
    -- back, so the old 0.35 s gap only cost time (every click still waits for its PollenSource reply).
    -- What actually drops clicks is clicking right after a glide/teleport: the server still sees the old
    -- position.  No pause after moving lost 3 of 6 moved pairs; 0.10-0.15 s lost 0-1 in 20; 0.2 s keeps margin.
    local CLICK_GAP = 0.05
    local MOVE_SETTLE = 0.2
    local PICK_TIMEOUT = 0.5                      -- 10x the normal reply time; one retry follows a miss
    local HARVEST_GAP = math.max((Config.Build.Pickup and Config.Build.Pickup.RepeatSeconds or 0.1667) + 0.04, 0.2)

    local PL = State.Pollinator
    PL.autoRun, PL.sweeping, PL.cancel = false, false, false
    PL.pollen = nil                       -- cell key of the flower we currently carry pollen from (PollenSource)
    PL.busyUntil = {}                     -- key -> clock; fallback in case the Breeding attribute lags
    PL.rejectedUntil = {}                 -- "a|b" -> clock; a pair the server refused is skipped for REJECT_SKIP s
    local REJECT_SKIP = 120
    PL.stats = { glow = 0, normal = 0, pairs = 0, rollbacks = 0, sweeps = 0, started = nil }
    PL.hidden = {}                        -- instance -> {property, original}
    PL.heldAt, PL.lastPlan, PL.parentP = 0, "no sweep yet", 0
    PL.saved, PL.nextAt = {}, 0
    PL.mover = nil                        -- { ap, att, home } - the Pollinator's own movement, separate from the Builder

    track(PollenRemote.OnClientEvent:Connect(function(v) PL.pollen = (type(v) == "string") and v or nil end))

    -- A flower's "type" for pairing is species + colour + glowing.  Plain / Striped / Dotted are all the
    -- same type ("Black Snapdragon" covers normal, dotted and striped); only Glowing is kept separate.
    local function flowerInfo(id)
        local def = Config.Flower.Flowers[id]
        if not def then return nil, nil, false, nil end
        local pattern = def.pattern
        return def.species, def.color, (type(pattern) == "string" and pattern:find("Glow") ~= nil), pattern
    end

    -- own movement -------------------------------------------------------------------------------------
    local function plStart()
        local r = hrp()
        if not r or PL.mover then return r ~= nil end
        local att = Instance.new("Attachment") att.Name = "ABOVE_PollAtt" att.Parent = r
        local ap = Instance.new("AlignPosition")
        ap.Name = "ABOVE_PollAlign"
        ap.Mode = Enum.PositionAlignmentMode.OneAttachment
        ap.Attachment0 = att
        ap.MaxForce = math.huge
        ap.MaxVelocity = Options.PollSpeed.Value
        ap.Responsiveness = 25
        ap.RigidityEnabled = false
        ap.Position = r.Position
        ap.Parent = r
        PL.mover = { ap = ap, att = att, home = r.CFrame }
        return true
    end

    local function plStop(goHome)
        local m = PL.mover
        if not m then return end
        local r = hrp()
        if goHome and r and m.home then
            if Options.PollMove.Value == "Teleport" then
                r.AssemblyLinearVelocity = Vector3.zero
                r.CFrame = m.home
                m.ap.Position = m.home.Position
                task.wait(0.15)
            else
                m.ap.Position = m.home.Position
                local t0 = os.clock()
                while os.clock() - t0 < 6 and (r.Position - m.home.Position).Magnitude > 3 do task.wait(0.05) end
            end
        end
        pcall(function() m.ap:Destroy() end)
        pcall(function() m.att:Destroy() end)
        PL.mover = nil
    end

    local function plGo(target)
        local r, m = hrp(), PL.mover
        if not r or not m then return end
        if Options.PollMove.Value == "Teleport" then
            r.AssemblyLinearVelocity = Vector3.zero
            r.CFrame = CFrame.new(target) * (r.CFrame - r.CFrame.Position)
            m.ap.Position = target
            -- The settle clock starts at the hop itself, so the pollinate pause overlaps this wait instead of
            -- adding another 0.2 s after it (harvest still gets the original 0.2 s wait).
            PL.lastMoveAt = os.clock()
            task.wait(0.2)
            return
        else
            m.ap.MaxVelocity = Options.PollSpeed.Value
            m.ap.Position = target
            local t0 = os.clock()
            local limit = (r.Position - target).Magnitude / math.max(Options.PollSpeed.Value, 1) + 2.5
            while os.clock() - t0 < limit and not PL.cancel do
                if (r.Position - target).Magnitude < 2.5 then break end
                task.wait(0.03)
            end
            task.wait(0.05)
        end
        PL.lastMoveAt = os.clock()
    end

    -- wait until the server has had MOVE_SETTLE seconds to see where we stopped
    local function settleAfterMove()
        local w = (PL.lastMoveAt or 0) + MOVE_SETTLE - os.clock()
        if w > 0 then task.wait(w) end
    end

    local function plPace(interval)
        local w = PL.nextAt - os.clock()
        if w > 0 then task.wait(w) end
        PL.nextAt = os.clock() + interval
    end

    local function ensureReach(pos, reach)
        local r = hrp()
        if not r then return false end
        if (r.Position - pos).Magnitude <= reach then return true end
        plGo(pos + Vector3.new(0, Options.PollHover.Value, 0))
        return (r.Position - pos).Magnitude <= reach + 3
    end

    -- snapshot of every flower on the island ----------------------------------------------------------
    local function snapshot(wholeIsland)
        local list, byKey, allCells = {}, {}, {}
        local now = os.clock()
        local limit = (not wholeIsland) and Toggles.PollUseRegion.Value and select(1, region(true)) and { region(true) } or nil
        for _, hb in ipairs(CollectionService:GetTagged("Flower")) do
            if hb.Parent and hb:IsDescendantOf(Island) then
                local cellKey = hb:GetAttribute("FlowerCell")
                local c = cellKey and Grid.fromKey(cellKey)
                if c then
                    allCells[cellKey] = true
                    local inside = true
                    if limit then
                        local lo, hi = limit[1], limit[2]
                        inside = c.x >= lo.X and c.x <= hi.X and c.y >= lo.Y and c.y <= hi.Y and c.z >= lo.Z and c.z <= hi.Z
                    end
                    if inside then
                        local id = hb:GetAttribute("FlowerId")
                        local species, color, glow, pattern = flowerInfo(id)
                        local e = {
                            part = hb, id = id, cell = c, key = cellKey, species = species, color = color, glow = glow, pattern = pattern,
                            mature = hb:GetAttribute("Mature") == true,
                            busy = hb:GetAttribute("Breeding") == true or (PL.busyUntil[cellKey] or 0) > now,
                        }
                        list[#list + 1] = e
                        byKey[cellKey] = e
                    end
                end
            end
        end
        return list, byKey, allCells
    end

    -- which parity are the parents?  Even / Odd, or Auto = the parity holding more mature flowers
    local function resolveParity(list)
        local mode = Options.PollParity.Value
        if mode == "Even" then return 0 elseif mode == "Odd" then return 1 end
        local count = { [0] = 0, [1] = 0 }
        for _, e in ipairs(list) do
            if e.mature then count[(e.cell.x + e.cell.z) % 2] += 1 end
        end
        return count[1] > count[0] and 1 or 0
    end

    local function hasFreeTile(e, allCells)
        local b = islandBounds()
        local rad = BreedCfg.ChildRadiusCells or 1
        for dx = -rad, rad do
            for dz = -rad, rad do
                if not (dx == 0 and dz == 0) then
                    local x, y, z = e.cell.x + dx, e.cell.y, e.cell.z + dz
                    local k = key(x, y, z)
                    if not allCells[k] and not S.occ[k] and S.occ[key(x, y - 1, z)] and Grid.isInBounds(Grid.cell(x, y, z), b) then
                        -- the baby has to spawn inside the parent's own strip: no divider wall between them
                        local g = PL.strip
                        local ok = true
                        if g then
                            local ie = STRIP.indexOf(g, e.cell)
                            if ie > 0 and ie ~= STRIP.indexOf(g, { x = x, y = y, z = z }) then ok = false end
                        end
                        if ok and STRIP.blockedBetween(e.cell, { x = x, y = y, z = z }) then ok = false end
                        if ok then return true end
                    end
                end
            end
        end
        return false
    end

    -- Strip-aware scan order.  With stone dividers present: Strip 1 -> 2 -> 3 -> 4, each strip walked along its
    -- full length lane by lane (lanes alternate direction), and every new strip starts at the end nearest to where
    -- the previous one finished, so the character never walks back across the island between strips.
    local function sortScan(list)
        local g = PL.strip
        if not g then
            table.sort(list, function(a, b)
                if a.cell.y ~= b.cell.y then return a.cell.y < b.cell.y end
                if a.cell.z ~= b.cell.z then return a.cell.z < b.cell.z end
                return a.cell.x < b.cell.x
            end)
            return list
        end
        local order, backward = STRIP.order()                                  -- which strip goes first, and which way round
        local rank = {}
        for pos, idx in ipairs(order) do rank[idx] = pos end
        for _, e in ipairs(list) do
            e._idx = (e.strip and e.strip > 0) and e.strip or 5                -- flowers outside the strips go last
            e._rank = rank[e._idx] or 5
            e._lane = g.splitX and e.cell.x or e.cell.z                        -- across the strip's width
            e._len = g.splitX and e.cell.z or e.cell.x                         -- along the strip's length
        end
        table.sort(list, function(a, b)
            if a.cell.y ~= b.cell.y then return a.cell.y < b.cell.y end
            if a._rank ~= b._rank then return a._rank < b._rank end
            if a._lane ~= b._lane then
                if backward then return a._lane > b._lane end                  -- going backwards: enter each strip on its high side
                return a._lane < b._lane
            end
            return a._len < b._len
        end)
        local lanes, cur, curKey = {}, nil, nil
        for _, e in ipairs(list) do
            local k = e.cell.y .. ":" .. e._idx .. ":" .. e._lane
            if k ~= curKey then cur = { idx = e._idx, y = e.cell.y } lanes[#lanes + 1] = cur curKey = k end
            cur[#cur + 1] = e
        end
        local out, lastLen, forward, prevStrip = {}, nil, true, nil
        for _, lane in ipairs(lanes) do
            local sk = lane.y .. ":" .. lane.idx
            if sk ~= prevStrip then                                            -- entering a new strip
                prevStrip = sk
                if lastLen then
                    forward = math.abs(lastLen - lane[1]._len) <= math.abs(lastLen - lane[#lane]._len)
                else
                    forward = true
                end
            end
            if forward then
                for i = 1, #lane do out[#out + 1] = lane[i] end
                lastLen = lane[#lane]._len
            else
                for i = #lane, 1, -1 do out[#out + 1] = lane[i] end
                lastLen = lane[1]._len
            end
            forward = not forward
        end
        return out
    end

    function STRIP.order()                                                     -- e.g. start 3 forward -> {3, 4, 1, 2}
        local start = tonumber(tostring(Options.PollStartStrip and Options.PollStartStrip.Value or "Strip 1"):match("%d")) or 1
        local back = Options.PollStripDir ~= nil and tostring(Options.PollStripDir.Value):find("Backward") ~= nil
        local out = {}
        for i = 0, 3 do
            out[#out + 1] = back and ((start - 1 - i) % 4) + 1 or ((start - 1 + i) % 4) + 1
        end
        return out, back
    end

    function STRIP.enabled(e)                                                  -- per-strip on/off toggles
        local i = e.strip or 0
        if i < 1 then return true end
        local t = Toggles["PollStrip" .. i]
        return t == nil or t.Value
    end

    -- planners ---------------------------------------------------------------------------------------
    local function planHarvest(list, P)
        local out = {}
        local ignoreBaby = Toggles.IgnoreBaby.Value
        for _, e in ipairs(list) do
            if (e.cell.x + e.cell.z) % 2 ~= P and STRIP.enabled(e) then   -- child tiles only, parents are never touched
                if e.mature or not ignoreBaby then out[#out + 1] = e end
            end
        end
        return sortScan(out)
    end

    local function planPairs(list, byKey, allCells, P)
        local parents = {}
        for _, e in ipairs(list) do
            if (e.cell.x + e.cell.z) % 2 == P and e.mature and not e.busy and e.species and STRIP.enabled(e) then
                parents[#parents + 1] = e
            end
        end
        parents = sortScan(parents)
        local radius = BreedCfg.PartnerRadiusCells or 2
        local merge = Toggles.PollMergeVariants.Value                      -- ignore Plain / Striped / Dotted differences
        local visited, pairsOut = {}, {}                                   -- VisitedThisSweep
        -- Performance: hasFreeTile(e) only depends on S.occ / allCells / PL.strip, none of which change
        -- while this loop runs (it never yields), so each flower's answer is computed once per plan.
        local freeCache = {}
        local function freeTile(e)
            local v = freeCache[e]
            if v == nil then v = hasFreeTile(e, allCells) freeCache[e] = v end
            return v
        end
        local now = os.clock()
        local function recentlyRejected(x, y)
            return (PL.rejectedUntil[x.key .. "|" .. y.key] or 0) > now or (PL.rejectedUntil[y.key .. "|" .. x.key] or 0) > now
        end
        for _, a in ipairs(parents) do
            if not visited[a.key] then
                local best, bestD
                for dx = -radius, radius do
                    for dz = -radius, radius do
                        if not (dx == 0 and dz == 0) then
                            local b = byKey[key(a.cell.x + dx, a.cell.y, a.cell.z + dz)]
                            if b and not visited[b.key] and not b.busy and b.mature and (b.cell.x + b.cell.z) % 2 == P
                                and b.species == a.species and b.color == a.color and b.glow == a.glow
                                and (merge or b.pattern == a.pattern)
                                and b.strip == a.strip and STRIP.enabled(b)          -- never across a divider
                                and not STRIP.blockedBetween(a.cell, b.cell)         -- nor through any placed block
                                -- Live-tested: the server rejected every pair where only ONE parent had a free
                                -- neighbour tile (5/5, ~1 s lost per sweep each), so both parents need one.
                                and not recentlyRejected(a, b)
                                and freeTile(a) and freeTile(b) then
                                local d = dx * dx + dz * dz
                                if not bestD or d < bestD then best, bestD = b, d end
                            end
                        end
                    end
                end
                if best then
                    visited[a.key], visited[best.key] = true, true
                    pairsOut[#pairsOut + 1] = { a = a, b = best }
                end
            end
        end
        return pairsOut
    end

    local function plan()
        local list, byKey, allCells = snapshot()
        local P = resolveParity(list)
        PL.parentP = P
        PL.strip = STRIP.current()                                           -- nil unless stone dividers are really built
        for _, e in ipairs(list) do e.strip = PL.strip and STRIP.indexOf(PL.strip, e.cell) or 0 end
        local harvest = Toggles.PollHarvest.Value and planHarvest(list, P) or {}
        local pairsList = Toggles.PollPollinate.Value and planPairs(list, byKey, allCells, P) or {}
        local ready = { 0, 0, 0, 0 }
        for _, pr in ipairs(pairsList) do if pr.a.strip > 0 then ready[pr.a.strip] += 1 end end
        PL.readyPerStrip = ready
        local babies = 0
        for _, e in ipairs(list) do if not e.mature then babies += 1 end end
        return { list = list, byKey = byKey, harvest = harvest, pairs = pairsList, babies = babies, P = P }
    end

    local function holdPollinator()
        local slot
        for i = 1, (Hotbar.TotalSlots or 9) do
            local ok, it = pcall(Hotbar.itemAt, i)
            if ok and it == PollinatorItem then slot = i break end
        end
        if not slot then return false end
        local st = buildState()
        if st and st.selectedBlockId == PollinatorItem and os.clock() - PL.heldAt > 1.5 then return true end
        pcall(Hotbar.select, slot)
        PL.heldAt = os.clock()
        task.wait(1.5)                       -- probed: a click within ~0.5s of selecting is ignored server side
        return true
    end

    local function waitPollen(expect, timeout)
        local t0 = os.clock()
        while os.clock() - t0 < timeout do
            if PL.pollen == expect then return true end
            task.wait(0.05)
        end
        return PL.pollen == expect
    end

    -- hand pollen back by clicking its source again (also the rollback guard)
    local function returnPollen(byKey)
        local src = PL.pollen
        if not src then return true end
        local e = byKey and byKey[src]
        local part = e and e.part
        if not part then
            for _, hb in ipairs(CollectionService:GetTagged("Flower")) do
                if hb:GetAttribute("FlowerCell") == src then part = hb break end
            end
        end
        if part and part.Parent then
            ensureReach(part.Position, POLL_REACH)
            settleAfterMove()
            PollinateRemote:FireServer(part)
            if waitPollen(nil, PICK_TIMEOUT) then return true end
        end
        return waitPollen(nil, 0.2)
    end

    local function pollinatePair(pr, byKey)
        local a, b = pr.a, pr.b
        if not (a.part.Parent and b.part.Parent) then return false, "gone" end
        if a.part:GetAttribute("Breeding") or b.part:GetAttribute("Breeding") then return false, "busy" end
        local mid = (a.part.Position + b.part.Position) / 2
        if not ensureReach(mid, POLL_REACH - 2) then return false, "unreachable" end
        if not holdPollinator() then return false, "no pollinator" end
        if PL.pollen then returnPollen(byKey) end                          -- never start with stale pollen
        settleAfterMove()
        plPace(CLICK_GAP)
        PollinateRemote:FireServer(a.part)                                  -- click 1: pick pollen from parent A
        if not waitPollen(a.key, PICK_TIMEOUT) then
            -- No reply: the click was dropped (usually a lag spike).  Retry once, but only while we are sure
            -- we carry nothing - clicking A again while holding its pollen would hand it back.
            if PL.pollen ~= nil then return false, "A did not take pollen" end
            task.wait(MOVE_SETTLE)
            plPace(CLICK_GAP)
            PollinateRemote:FireServer(a.part)
            if not waitPollen(a.key, PICK_TIMEOUT) then return false, "A did not take pollen" end
        end
        plPace(CLICK_GAP)
        PollinateRemote:FireServer(b.part)                                  -- click 2: deliver to parent B
        if waitPollen(nil, PICK_TIMEOUT) then
            PL.busyUntil[a.key] = os.clock() + (BreedCfg.SecondsMin or 720)
            PL.busyUntil[b.key] = PL.busyUntil[a.key]
            PL.stats.pairs += 1
            return true
        end
        -- Pollen Rollback Guard: B did not accept, so click the source again and take the pollen back
        PL.stats.rollbacks += 1
        PL.rejectedUntil[a.key .. "|" .. b.key] = os.clock() + REJECT_SKIP     -- try other partners first next sweep
        returnPollen(byKey)
        return false, "B rejected pollen (rolled back)"
    end

    -- harvest ---------------------------------------------------------------------------------------
    local function harvestOne(e, P)
        if not e.part.Parent then return false end
        if Toggles.IgnoreBaby.Value and e.part:GetAttribute("Mature") ~= true then return false end
        if (e.cell.x + e.cell.z) % 2 == (P or PL.parentP) then return false end   -- hard guard: never harvest parent tiles
        if not ensureReach(e.part.Position, HARVEST_REACH - 2) then return false end
        plPace(HARVEST_GAP)
        HarvestRemote:FireServer(e.part)
        return true
    end

    local function harvestRemoved(e)
        return (not e.part.Parent) or (not e.part:IsDescendantOf(workspace))
    end

    -- one full sweep ------------------------------------------------------------------------------------
    local function sweepOnce(dry)
        if PL.sweeping then return nil, "Already sweeping." end
        local p = plan()
        PL.lastPlan = ("%d flowers (%d babies)  |  parents: %s tiles  |  harvest %d  |  pairs %d"):format(
            #p.list, p.babies, p.P == 0 and "even" or "odd", #p.harvest, #p.pairs)
        if dry then return p end
        if #p.harvest == 0 and #p.pairs == 0 then return p end

        local locked, holder = State.Acquire("pollinator")
        if not locked then return nil, "The " .. tostring(holder) .. " is using your character." end
        PL.sweeping, PL.cancel = true, false
        if not plStart() then PL.sweeping = false State.Release("pollinator") return nil, "No character." end

        local worked = 0                                                       -- successful pairs + harvests this sweep
        local ok, e = pcall(function()
            -- 1) harvest mature child-tile flowers
            local sent = {}
            for _, f in ipairs(p.harvest) do
                if PL.cancel or S.unloaded then break end
                if harvestOne(f, p.P) then sent[#sent + 1] = f end
            end
            task.wait(0.8)
            for _, f in ipairs(sent) do
                if harvestRemoved(f) then
                    if f.glow then PL.stats.glow += 1 else PL.stats.normal += 1 end
                    worked += 1
                end
            end
            -- 2) pollinate same-type pairs
            for _, pr in ipairs(p.pairs) do
                if PL.cancel or S.unloaded then break end
                if pollinatePair(pr, p.byKey) then worked += 1 end
            end
            if PL.pollen then returnPollen(p.byKey) end                        -- never leave a sweep carrying pollen
        end)
        if not ok then warn("[Pollinator] " .. tostring(e)) end

        plStop(Toggles.PollReturn.Value)
        PL.sweeping = false
        State.Release("pollinator")
        PL.stats.sweeps += 1
        return p, nil, worked
    end

    -- Collect All: harvest every mature flower on the island - parents and children alike.  Only runs when the
    -- button is pressed (it asks for a second click); it is not part of the sweeps and ignores parity.
    local function collectAll()
        if PL.sweeping then
            -- stop a running auto loop / sweep first, then take over
            PL.autoRun, PL.cancel = false, true
            pcall(function() Toggles.PollAutoRun:SetValue(false) end)
            local t0 = os.clock()
            while PL.sweeping and os.clock() - t0 < 15 do task.wait(0.2) end
            if PL.sweeping then notify("Pollinator is still busy - try again in a moment.") return end
        end
        local list = snapshot(true)
        local targets = {}
        local includeBabies = not Toggles.IgnoreBaby.Value
        for _, e in ipairs(list) do
            if e.mature or includeBabies then targets[#targets + 1] = e end
        end
        if #targets == 0 then notify("No mature flowers to collect.") return end
        -- snake through the island row by row so the trip stays short
        table.sort(targets, function(a, b)
            if a.cell.y ~= b.cell.y then return a.cell.y < b.cell.y end
            if a.cell.z ~= b.cell.z then return a.cell.z < b.cell.z end
            return a.cell.x < b.cell.x
        end)
        local snake, i, rowN = {}, 1, 0
        while i <= #targets do
            local j = i
            while targets[j + 1] and targets[j + 1].cell.z == targets[i].cell.z and targets[j + 1].cell.y == targets[i].cell.y do j += 1 end
            rowN += 1
            if rowN % 2 == 0 then for k = j, i, -1 do snake[#snake + 1] = targets[k] end
            else for k = i, j do snake[#snake + 1] = targets[k] end end
            i = j + 1
        end

        local locked, holder = State.Acquire("pollinator")
        if not locked then notify("The " .. tostring(holder) .. " is using your character - stop it first.") return end
        PL.sweeping, PL.cancel = true, false
        if not plStart() then PL.sweeping = false State.Release("pollinator") notify("No character.") return end
        PL.stats.started = PL.stats.started or os.clock()
        local collected, total = 0, #snake
        notify(("Collecting %d flowers..."):format(total), 5)
        local ok, err = pcall(function()
            local pending = snake
            for pass = 1, 2 do                                              -- second pass retries anything that stayed
                local sent = {}
                for _, f in ipairs(pending) do
                    if PL.cancel or S.unloaded then break end
                    if f.part.Parent then
                        if ensureReach(f.part.Position, HARVEST_REACH - 2) then
                            plPace(HARVEST_GAP)
                            HarvestRemote:FireServer(f.part)
                            sent[#sent + 1] = f
                        end
                    end
                end
                task.wait(0.8)
                local left = {}
                for _, f in ipairs(sent) do
                    if harvestRemoved(f) then
                        collected += 1
                        if f.glow then PL.stats.glow += 1 else PL.stats.normal += 1 end
                    else
                        left[#left + 1] = f
                    end
                end
                if #left == 0 or PL.cancel then break end
                pending = left
            end
        end)
        if not ok then warn("[Pollinator] collect all: " .. tostring(err)) end
        plStop(Toggles.PollReturn.Value)
        PL.sweeping = false
        State.Release("pollinator")
        notify(("Collected %d / %d flowers."):format(collected, total), 6)
    end

    -- auto loop -------------------------------------------------------------------------------------
    local function autoLoop()
        while PL.autoRun and not S.unloaded do
            local _, err, worked = sweepOnce(false)
            if err and err ~= "Already sweeping." then notify("Pollinator: " .. tostring(err), 5) end
            local t0 = os.clock()
            -- A sweep only sees what is mature when it starts (a big farm takes minutes), so flowers that finished
            -- growing meanwhile - e.g. a freshly planted glowing zone - would wait a whole interval.  If the sweep
            -- did any work, look again almost immediately; only an idle sweep waits the full interval.
            local wait = (worked and worked > 0) and 3 or math.max(Options.SweepInterval.Value, 1)   -- 0 = continuous (1s floor)
            while PL.autoRun and not S.unloaded and os.clock() - t0 < wait do task.wait(0.25) end
        end
    end

    PL.plan, PL.sweepOnce, PL.pollinatePair, PL.harvestOne, PL.ensureReach, PL.collectAll = plan, sweepOnce, pollinatePair, harvestOne, ensureReach, collectAll
    -- run `fn` with the Pollinator's own movement active (used by tests / other scripts)
    function PL.withMover(fn)
        if PL.sweeping then return nil, "Already sweeping." end
        local locked, holder = State.Acquire("pollinator")
        if not locked then return nil, "The " .. tostring(holder) .. " is using your character." end
        PL.sweeping, PL.cancel = true, false
        if not plStart() then PL.sweeping = false State.Release("pollinator") return nil, "No character." end
        local res = table.pack(pcall(fn))
        plStop(Toggles.PollReturn.Value)
        PL.sweeping = false
        State.Release("pollinator")
        return table.unpack(res, 1, res.n)
    end

    PL.flowerInfo, PL.plStart, PL.plStop, PL.plGo, PL.plPace = flowerInfo, plStart, plStop, plGo, plPace
    PL.snapshot, PL.resolveParity, PL.hasFreeTile, PL.sortScan = snapshot, resolveParity, hasFreeTile, sortScan
    PL.planHarvest, PL.planPairs, PL.holdPollinator, PL.waitPollen, PL.returnPollen = planHarvest, planPairs, holdPollinator, waitPollen, returnPollen
    PL.harvestRemoved, PL.autoLoop = harvestRemoved, autoLoop
    return PL
end
