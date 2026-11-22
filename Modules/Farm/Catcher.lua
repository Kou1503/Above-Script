--[[
    Modules/Farm/Catcher.lua  -  Auto Catch (lasso wild Ruins animals).
    Source: Script1 lines 1671-1687 (catcher.find) and 2322-2463 (equip / clearOffset / step), verbatim.
    The catcher table itself and refreshLabel / stopAim / restoreHotbar are created in Config.lua.
]]

return function(State)
    local F = State.Farm
    local CollectionService = State.Services.CollectionService
    local RequestShoot = F.RequestShoot
    local HotbarController = F.HotbarController
    local WeaponConfig = F.WeaponConfig
    local catcher = F.catcher
    local diagnostics = F.diagnostics
    local withinMaxDistance = F.withinMaxDistance
    local moveTo = F.moveTo
    local clearBowArc = F.clearBowArc
    local bowFootprint = F.bowFootprint
    local rangedRaycastFilter = F.rangedRaycastFilter

    function catcher.find(root)
        local best, bestDistance
        local now = os.clock()
        for _, part in ipairs(CollectionService:GetTagged(catcher.wildTag)) do
            if part:IsA("BasePart") and part:IsDescendantOf(workspace) then
                local species = string.gsub(part.Name, "^Wild", "")
                local action = part:GetAttribute("Action")
                if catcher.species[species] and action ~= "Reeled" and action ~= "Run"
                    and (catcher.retryAfter[part] or 0) <= now and withinMaxDistance(part, root) then
                    local distance = (part.Position - root.Position).Magnitude
                    if not bestDistance or distance < bestDistance then best, bestDistance = part, distance end
                end
            end
        end
        if not best then return nil end
        return { mode = "catch", model = best, hit = best, id = (string.gsub(best.Name, "^Wild", "")) }
    end

    -- put the Lasso on the hotbar (if needed) and select it; equipTool() reselects the other modes' tools
    function catcher.equip(now)
        local slot
        for index = 1, (HotbarController.TotalSlots or 9) do
            local ok, item = pcall(HotbarController.itemAt, index)
            if ok and item == "Lasso" then slot = index break end
        end
        if not slot then
            slot = catcher.slot
            if not catcher.savedSlot then
                local ok, previous = pcall(HotbarController.itemAt, slot)
                catcher.savedSlot = { slot = slot, item = ok and previous or nil }
            end
            if not pcall(HotbarController.assign, slot, "Lasso") then return false end
        end
        if F.equippedSlot ~= "Lasso" or catcher.lassoSlot ~= slot then
            pcall(HotbarController.select, slot)
            F.equippedSlot = "Lasso"
            catcher.lassoSlot = slot
            catcher.equipReadyAt = now + 1.2          -- a throw right after selecting is ignored server side
        end
        return now >= catcher.equipReadyAt
    end

    -- Reuses the Settled-bow machinery: clearBowArc (lead + segment-by-segment arc collision check),
    -- bowFootprint (hover spot not inside geometry), a ring search for a clear hover offset, the
    -- "settled" check before firing and the blocked-target timeout.  Hover spots must stay outside the
    -- animal's flee range (measured in 3D, so directly above is allowed and preferred).
    function catcher.clearOffset(position, velocity, speed, gravity, minDistance, origin)
        local best, bestScore = nil, math.huge
        local base = minDistance + catcher.margin
        local heights = { base, base + 4, base + 8, base + 12 }
        local radii = if catcher.fromAbove then { 0, 3, 6, 10, 14 } else { 10, 14, 6, 3, 0 }
        for hi, height in ipairs(heights) do
            for ri, radius in ipairs(radii) do
                for sector = 1, (if radius == 0 then 1 else 8) do
                    local angle = sector * math.pi / 4
                    local offset = Vector3.new(math.cos(angle) * radius, height, math.sin(angle) * radius)
                    local waypoint = position + offset
                    if offset.Magnitude >= minDistance + 1 and offset.Magnitude <= 44
                        and #workspace:GetPartBoundsInRadius(waypoint, 1.2, bowFootprint) == 0
                        and clearBowArc(waypoint, position, velocity, speed, gravity) then
                        -- prefer straight above / low / close to where we already are
                        local score = (hi - 1) * 20 + (ri - 1) * 6 + (waypoint - origin).Magnitude * 0.05
                        if score < bestScore then best, bestScore = offset, score end
                    end
                end
            end
            if best then break end
        end
        return best
    end

    function catcher.step(candidate, root, now)
        local part = candidate.hit
        local character = root.Parent
        local position = part.Position
        local flee = catcher.flee[candidate.id] or 20
        local state = catcher.state
        if not state or state.hit ~= part then
            catcher.stopAim()
            state = { hit = part, position = position, sampledAt = now, velocity = Vector3.zero, offset = nil, probeAt = 0 }
            catcher.state = state
        end
        -- smoothed velocity, same filter as the Settled bow
        local elapsed = now - state.sampledAt
        if elapsed >= 0.035 then
            local velocity = (position - state.position) / elapsed
            if velocity.Magnitude > 30 then velocity = Vector3.zero end
            state.velocity = state.velocity:Lerp(velocity, 0.45)
            state.position, state.sampledAt = position, now
        end

        local projectile = catcher.projectile
        local speed = WeaponConfig.launchSpeed(projectile, 1)          -- always a full-power throw
        bowFootprint.FilterDescendantsInstances = rangedRaycastFilter(character, part)

        -- pick / re-check the hover offset (directly above first, then the ring search)
        if not state.offset or now >= state.probeAt then
            state.probeAt = now + 0.35
            local preferred = Vector3.new(0, flee + catcher.margin, 0)
            if catcher.fromAbove and #workspace:GetPartBoundsInRadius(position + preferred, 1.2, bowFootprint) == 0
                and clearBowArc(position + preferred, position, state.velocity, speed, projectile.gravity) then
                state.offset = preferred
            else
                local found = catcher.clearOffset(position, state.velocity, speed, projectile.gravity, flee, root.Position)
                if found then state.offset = found end
            end
        end
        if not state.offset then
            state.blockedSince = state.blockedSince or now
            if now - state.blockedSince >= 1.5 then              -- nowhere clear to throw from: try another animal
                catcher.retryAfter[part] = now + 4
                catcher.state = nil
                catcher.stopAim()
                F.primaryTarget, F.primaryTargetMode, F.nextPrimaryScan = nil, nil, 0
            end
            return
        end
        state.blockedSince = nil

        local destination = position + state.offset
        moveTo(root, character, destination)
        if not catcher.equip(now) then return end

        -- start drawing right away so the full draw builds up while flying / during the cooldown
        if not catcher.drawAt and now >= catcher.nextThrowAt - 0.95 then
            pcall(function() catcher.sprintRemote:FireServer(true, "Aim") end)
            catcher.drawAt = now
        end

        local origin = root.Position
        if (origin - position).Magnitude < flee + 1 then state.settledSince = nil return end   -- never inside the flee range
        if (origin - destination).Magnitude > 1.7 or (root.AssemblyLinearVelocity - state.velocity).Magnitude > 13 then
            state.settledSince = nil
            return
        end
        state.settledSince = state.settledSince or now
        if now - state.settledSince < 0.22 or now < catcher.nextThrowAt then return end
        if not catcher.drawAt or now - catcher.drawAt < 0.9 then return end              -- full draw (0.8 s) + margin
        local held = character and character:FindFirstChild("HeldTool")
        if not held or held:GetAttribute("ItemId") ~= "Lasso" then return end

        local direction = clearBowArc(origin, position, state.velocity, speed, projectile.gravity)
        if not direction then state.offset = nil state.settledSince = nil return end

        F.shotId += 1
        RequestShoot:FireServer(origin, direction, 1, F.shotId)
        catcher.drawAt = nil
        pcall(function() catcher.sprintRemote:FireServer(false, "Aim") end)
        catcher.nextThrowAt = now + 1.35
        catcher.stats.throws += 1
        diagnostics.count("lassoThrows")
        task.delay(1.2, function()
            if part.Parent and part:GetAttribute("Action") ~= "Reeled" then
                catcher.stats.missed += 1
                catcher.retryAfter[part] = os.clock() + 2.5
                if catcher.state and catcher.state.hit == part then catcher.state = nil end
            end
            catcher.refreshLabel()
        end)
    end

    return catcher
end
