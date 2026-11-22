--[[
    Modules/Farm/Combat.lua  -  equip, settled / ranged bow, boss grab dodge, mining standoff,
    primary action dispatch and shiny collection.
    Source: Script1 lines 2015-2320 and 2465-2583 (verbatim; shared variables read through F).
    The Auto Catch functions between them (Script1 2322-2463) live in Catcher.lua.
]]

return function(State)
    local F = State.Farm
    local LocalPlayer = F.LocalPlayer
    local Remotes = F.Remotes
    local RequestSwing = F.RequestSwing
    local RequestShoot = F.RequestShoot
    local ProjectileEnded = F.ProjectileEnded
    local AnimationController = F.AnimationController
    local HotbarController = F.HotbarController
    local WeaponConfig = F.WeaponConfig
    local EnemyConfig = F.EnemyConfig
    local Ballistics = F.Ballistics
    local hotbarIndexByToolSlot = F.hotbarIndexByToolSlot
    local miningStandoff = F.miningStandoff
    local bossBow = F.bossBow
    local catcher = F.catcher
    local diagnostics = F.diagnostics
    local bowRetryAfter = F.bowRetryAfter
    local bowHover = F.bowHover
    local rangedShotIntervals = F.rangedShotIntervals
    local modeHoverHeights = F.modeHoverHeights
    local shinyRetryAfter = F.shinyRetryAfter
    local sharedRaycastParams = F.sharedRaycastParams
    local interactReach = F.interactReach
    local attackRange = F.attackRange
    local rangedHoverHeight = F.rangedHoverHeight
    local rangedAttackRange = F.rangedAttackRange
    local scriptAlive = F.scriptAlive
    local characterParts = F.characterParts
    local primaryTargetValid = F.primaryTargetValid
    local moveTo = F.moveTo
    local clearMovement = F.clearMovement

    local orbitStartAt = 0
    local orbitStartAngle = 0

    local function equipTool(slot, now)
        local index = hotbarIndexByToolSlot[slot]
        if not index then
            warn("[ABOVE Farm] unknown tool slot: " .. tostring(slot))
            return
        end
        local selected = HotbarController.selected()
        local selectionMatches = selected and selected.kind == "Tool" and selected.toolSlot == slot
        if F.equippedSlot == slot and selectionMatches then return end
        local ok, err = pcall(function()
            if selectionMatches then
                -- Force a real selection change so InputController sends the equip request
                -- even if a previous direct remote call left its selection cache stale.
                HotbarController.select(if index == 1 then 2 else 1)
            end
            HotbarController.select(index)
        end)
        if not ok then
            F.equippedSlot = nil
            F.equipReadyAt = now + 0.1
            warn("[ABOVE Farm] equip failed: " .. tostring(err))
            return
        end
        F.equippedSlot = slot
        F.equipReadyAt = now + 0.25
    end

    local function rangedRaycastFilter(character, target)
        -- The rendered rigs can be queryable even though the server uses separate hit parts.
        local ignored = { character, target }
        local enemyViews = workspace:FindFirstChild("EnemyViews")
        if enemyViews then table.insert(ignored, enemyViews) end
        sharedRaycastParams.FilterDescendantsInstances = ignored
        return ignored
    end

    local bowFootprint = OverlapParams.new()
    bowFootprint.FilterType = Enum.RaycastFilterType.Exclude
    bowFootprint.RespectCanCollide = true
    bowFootprint.MaxParts = 1

    local function clearBowArc(origin, position, velocity, speed, gravity)
        local aim = position
        local direction, flightTime
        for _ = 1, 3 do
            local offset = aim - origin
            direction = Ballistics.aimDirection(offset, speed, gravity)
            if not direction then return nil end
            local horizontal = Vector3.new(offset.X, 0, offset.Z).Magnitude
            local horizontalSpeed = Vector3.new(direction.X, 0, direction.Z).Magnitude * speed
            if horizontal > 0.1 and horizontalSpeed > 0.1 then
                flightTime = horizontal / horizontalSpeed
            else
                local verticalSpeed = direction.Y * speed
                local discriminant = verticalSpeed * verticalSpeed - 2 * gravity * offset.Y
                if discriminant < 0 then return nil end
                local root = math.sqrt(discriminant)
                flightTime = if offset.Y < 0 then (verticalSpeed + root) / gravity else (verticalSpeed - root) / gravity
            end
            aim = position + velocity * math.min(flightTime, 0.65)
        end

        local previous = origin
        for segment = 1, 6 do
            local t = flightTime * segment / 6
            local point = origin + direction * (speed * t) - Vector3.new(0, gravity * t * t * 0.5, 0)
            if workspace:Raycast(previous, point - previous, sharedRaycastParams) then return nil end
            previous = point
        end
        return direction
    end

    local function bowAimFrom(origin, position, velocity, speed, gravity)
        if (origin - position).Magnitude > 23 or origin.Y - position.Y < 15 then return nil end
        if #workspace:GetPartBoundsInRadius(origin, 1.2, bowFootprint) > 0 then return nil end
        return clearBowArc(origin, position, velocity, speed, gravity)
    end

    local function findClearBowOffset(origin, position, velocity, speed, gravity)
        local bestOffset, bestDistance = nil, math.huge
        for _, height in { 19, 22, 17 } do
            for _, radius in { 3, 6, 10 } do
                for sector = 1, 8 do
                    local angle = sector * math.pi / 4
                    local offset = Vector3.new(math.cos(angle) * radius, height, math.sin(angle) * radius)
                    local waypoint = position + offset
                    local distance = (waypoint - origin).Magnitude
                    if distance > 1.7 and distance < bestDistance and bowAimFrom(waypoint, position, velocity, speed, gravity) then
                        bestOffset, bestDistance = offset, distance
                    end
                end
            end
        end
        return bestOffset
    end

    function bossBow.grabRetreat(state, action, position, origin, now)
        local grab = EnemyConfig.Morten.grab
        local relative = origin - position
        local horizontal = Vector3.new(relative.X, 0, relative.Z)
        local range = grab.rangeStuds
        if action ~= state.action then
            state.action = action
            if type(action) == "string" and action:match("^grab#") and horizontal.Magnitude <= range + 6 then
                state.dodgeUntil = now + grab.warning + grab.pull + grab.hold + grab.slam + 0.15
                state.dodgeDirection = if horizontal.Magnitude > 1 then horizontal.Unit else Vector3.xAxis
                state.dodgeHeight = origin.Y
                diagnostics.count("bossGrabDodges")
            end
        end
        if not state.dodgeUntil or now >= state.dodgeUntil then return nil end

        local direction = state.dodgeDirection
        if horizontal.Magnitude > 1 and horizontal.Unit:Dot(direction) > 0.5 then
            direction = horizontal.Unit
        end
        local retreat = position + direction * (range + 14)
        if horizontal.Magnitude >= range + 14 and horizontal:Dot(direction) > 0 then
            retreat = origin
        end
        return Vector3.new(retreat.X, state.dodgeHeight, retreat.Z)
    end

    F.projectileEndedConnection = ProjectileEnded.OnClientEvent:Connect(function(_, _, userId, id)
        if userId == LocalPlayer.UserId then diagnostics.count("projectileEnds") end
        if F.bowShotPending and userId == LocalPlayer.UserId and id == F.bowShotPending then
            F.bowShotPending = nil
            F.nextShotAt = math.max(F.nextShotAt, os.clock() + 0.065)
        end
    end)

    local function fireSettledBow(candidate, root, now, bossMode)
        local character = LocalPlayer.Character
        local position = candidate.hit.Position
        if not F.bowState or F.bowState.hit ~= candidate.hit or F.bowState.boss ~= bossMode then
            F.bowState = { hit = candidate.hit, position = position, sampledAt = now, velocity = Vector3.zero, offset = bowHover, probeAt = 0, boss = bossMode }
        end
        local state = F.bowState
        if bossMode then
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            if not humanoid or humanoid.Health <= 0 then return end
            local relative = root.Position - position
            local horizontal = Vector3.new(relative.X, 0, relative.Z)
            local away = if horizontal.Magnitude > 1 then horizontal.Unit else Vector3.xAxis
            local dodge = bossBow.grabRetreat(state, candidate.hit:GetAttribute("Action"), position, root.Position, now)
            if dodge then
                state.bossOffset, state.settledSince = nil, nil
                state.position, state.sampledAt, state.velocity = position, now, Vector3.zero
                moveTo(root, character, dodge)
                return
            end
            state.bossOffset = state.bossOffset or away * 39 + Vector3.new(0, 11, 0)
        end
        local elapsed = now - state.sampledAt
        if elapsed >= 0.035 then
            local velocity = (position - state.position) / elapsed
            if velocity.Magnitude > 30 then velocity = Vector3.zero end
            state.velocity = state.velocity:Lerp(velocity, 0.45)
            state.position, state.sampledAt = position, now
        end

        local destination = position + (state.bossOffset or state.offset)
        moveTo(root, character, destination)
        if now >= F.equipReadyAt then equipTool("Weapon", now) end

        local origin = root.Position
        local distanceToDestination = (origin - destination).Magnitude
        if (origin - position).Magnitude > (if bossMode then 70 else 30) then
            state.settledSince = nil
            return
        end

        bowFootprint.FilterDescendantsInstances = rangedRaycastFilter(character, candidate.model)
        local projectile = WeaponConfig.projectileOf("SoulfireBow")
        -- Quick follow-ups can launch below full speed even when requesting power 1.
        local estimatedPower = math.clamp(now - F.lastBowShotAt + 0.15, 0.12, 1)
        local speed = WeaponConfig.launchSpeed(projectile, estimatedPower)
        local aim = if bossMode then clearBowArc else bowAimFrom
        if distanceToDestination > 5 and aim(destination, position, state.velocity, speed, projectile.gravity) then
            state.settledSince = nil
            return
        end
        local direction = if distanceToDestination <= 5 then aim(origin, position, state.velocity, speed, projectile.gravity) else nil
        if not direction then
            state.settledSince = nil
            state.blockedSince = state.blockedSince or now
            if now - state.blockedSince >= 1.1 then
                bowRetryAfter[candidate.model] = now + 3
                F.bowState = nil
                F.primaryTarget, F.primaryTargetMode, F.nextPrimaryScan = nil, nil, 0
            elseif now >= state.probeAt then
                state.probeAt = now + 0.25
                if bossMode then
                    local current = state.bossOffset
                    for _, angle in { math.pi / 6, -math.pi / 6, math.pi / 3, -math.pi / 3 } do
                        local offset = CFrame.Angles(0, angle, 0):VectorToWorldSpace(current)
                        local waypoint = position + offset
                        if #workspace:GetPartBoundsInRadius(waypoint, 1.2, bowFootprint) == 0
                            and clearBowArc(waypoint, position, state.velocity, speed, projectile.gravity) then
                            state.bossOffset = offset
                            break
                        end
                    end
                else
                    local offset = findClearBowOffset(origin, position, state.velocity, speed, projectile.gravity)
                    if offset then state.offset = offset end
                end
            end
            return
        end
        state.blockedSince = nil

        if distanceToDestination > 1.7 or (root.AssemblyLinearVelocity - state.velocity).Magnitude > 13 then
            state.settledSince = nil
            return
        end
        state.settledSince = state.settledSince or now
        if now - state.settledSince < 0.22 or now < F.nextShotAt or now < F.equipReadyAt then return end
        if F.bowShotPending and now - F.lastBowShotAt < 0.60 then return end
        local held = character and character:FindFirstChild("HeldTool")
        if not held or held:GetAttribute("ItemId") ~= "SoulfireBow" then return end

        F.shotId += 1
        F.bowShotPending, F.lastBowShotAt, F.nextShotAt = F.shotId, now, now + (if bossMode then 0.92 else 0.44)
        if diagnostics.isEnabled() then
            diagnostics.count("shots", candidate.id, "SoulfireBow", (root.Position - candidate.hit.Position).Magnitude)
        end
        RequestShoot:FireServer(origin, direction, 1, F.shotId)
    end

    local function fireRanged(candidate, root, weaponId, shotInterval, now)
        if now < F.nextShotAt then return end
        local character = LocalPlayer.Character
        local held = character and character:FindFirstChild("HeldTool")
        if not held or held:GetAttribute("ItemId") ~= weaponId then return end

        local projectile = WeaponConfig.projectileOf(weaponId)
        if not projectile then return end
        local origin = root.Position
        if not projectile.drawSeconds then
            local socket = held:FindFirstChild(WeaponConfig.ShotOriginAttachment, true)
            local handle = held:FindFirstChild("Handle", true)
            local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
            if socket and socket:IsA("Attachment") then
                origin = socket.WorldPosition
            elseif handle and handle:IsA("BasePart") then
                origin = handle.Position
            elseif hand and hand:IsA("BasePart") then
                origin = hand.Position
            end
        end

        local offset = candidate.hit.Position - origin
        if offset.Magnitude < 0.1 or offset.Magnitude > rangedAttackRange then return end
        rangedRaycastFilter(character, candidate.model)
        if workspace:Raycast(origin, offset, sharedRaycastParams) then return end
        local direction = Ballistics.aimDirection(offset, WeaponConfig.launchSpeed(projectile, 1), projectile.gravity)
            or offset.Unit

        F.nextShotAt = now + shotInterval
        if weaponId == "SoulfireBow" then F.lastBowShotAt = now end
        F.shotId += 1
        -- Soulfire accepts full power through RequestShoot without a preceding draw.
        if diagnostics.isEnabled() then
            diagnostics.count("shots", candidate.id, weaponId, (root.Position - candidate.hit.Position).Magnitude)
        end
        RequestShoot:FireServer(origin, direction, 1, F.shotId)
    end

    do
        local hitConfirmed = Remotes:FindFirstChild("HitConfirmed")
        if hitConfirmed and hitConfirmed:IsA("RemoteEvent") then
            miningStandoff.connection = hitConfirmed.OnClientEvent:Connect(function(hit)
                if hit == miningStandoff.hit then miningStandoff.unconfirmedSince = nil end
            end)
        end
    end

    function miningStandoff.mine(candidate, root, now)
        local hit = candidate.hit
        if miningStandoff.hit ~= hit then
            miningStandoff.hit = hit
            miningStandoff.close = false
            miningStandoff.unconfirmedSince = nil
        end

        local offset = root.Position - hit.Position
        local distance = offset.Magnitude
        local unconfirmedSince = miningStandoff.unconfirmedSince
        if unconfirmedSince and now - unconfirmedSince >= 0.75 then
            miningStandoff.close = true
        end
        local reach = if miningStandoff.close then 8 else interactReach
        if distance > reach then
            moveTo(root, LocalPlayer.Character, hit.Position + offset.Unit * (reach - 1))
            return
        end

        if F.movementAlign then clearMovement() end
        equipTool("Pickaxe", now)
        if now < F.equipReadyAt or root.AssemblyLinearVelocity.Magnitude > 5 or now - F.lastSwingAt < 0.10 then return end
        if miningStandoff.connection then miningStandoff.unconfirmedSince = unconfirmedSince or now end
        F.lastSwingAt = now
        diagnostics.count("miningSwings", candidate.id, nil, distance)
        pcall(function() RequestSwing:FireServer(hit) end)
    end

    local function doPrimaryAction(candidate, root, now)
        if candidate.mode == "catch" then
            F.bowState = nil
            catcher.step(candidate, root, now)
            return
        end
        catcher.stopAim()
        if F.lastSwingTarget ~= candidate.model then
            F.lastSwingTarget = candidate.model
            F.lastSwingAt = 0
        end

        if candidate.mode == "mine" and miningStandoff.enabled then
            F.bowState = nil
            miningStandoff.mine(candidate, root, now)
            return
        end
        miningStandoff.hit = nil

        local isCombat = candidate.mode == "kill" or candidate.mode == "boss"
        local weaponId = if isCombat then HotbarController.itemAt(hotbarIndexByToolSlot.Weapon) else nil
        local bossMode = candidate.mode == "boss" and bossBow.enabled
        if weaponId == "SoulfireBow" and (bossMode or F.bowAim == "Settled") then
            F.orbitTarget = nil
            fireSettledBow(candidate, root, now, bossMode)
            return
        end
        F.bowState = nil
        local shotInterval = weaponId and rangedShotIntervals[weaponId]
        if shotInterval then
            F.orbitTarget = nil
            moveTo(root, LocalPlayer.Character, candidate.hit.Position + Vector3.new(0, rangedHoverHeight, 0))
            if now >= F.equipReadyAt then
                equipTool("Weapon", now)
                if now >= F.equipReadyAt then fireRanged(candidate, root, weaponId, shotInterval, now) end
            end
            return
        end

        local targetPosition = candidate.hit.Position
        local modeHeight = if isCombat then math.min(modeHoverHeights[candidate.mode], attackRange - 0.7) else math.min(modeHoverHeights[candidate.mode], interactReach - 0.1)
        local destination = targetPosition + Vector3.new(0, modeHeight, 0)
        if isCombat and F.smoothOrbitEnabled then
            if F.orbitTarget ~= candidate.model then
                F.orbitTarget = candidate.model
                orbitStartAt = now
                orbitStartAngle = math.random() * math.pi * 2
            end
            local angle = orbitStartAngle + (now - orbitStartAt) * F.smoothOrbitSpeed
            -- Leave room for movement lag so the animation's delayed hit frame stays in range.
            local swingStandoff = attackRange - 0.55
            local orbitHeight = math.min(modeHoverHeights[candidate.mode], swingStandoff - 0.2)
            local maxOrbitRadius = math.max(0, math.sqrt(swingStandoff * swingStandoff - orbitHeight * orbitHeight) - 0.15)
            local orbitRadius = math.min(F.smoothOrbitRadius, maxOrbitRadius)
            destination = targetPosition + Vector3.new(
                math.cos(angle) * orbitRadius,
                orbitHeight,
                math.sin(angle) * orbitRadius
            )
        elseif not isCombat or not F.smoothOrbitEnabled then
            F.orbitTarget = nil
        end
        moveTo(root, LocalPlayer.Character, destination)

        local range = if isCombat then attackRange else interactReach
        local slot = if isCombat then "Weapon" else if candidate.mode == "tree" then "Axe" else "Pickaxe"
        if (root.Position - targetPosition).Magnitude <= range and now >= F.equipReadyAt then
            equipTool(slot, now)
            if now >= F.equipReadyAt then
                if isCombat then
                    -- Use the game's swing animation and hit-frame timing for combat.
                    if AnimationController.swingReady() then
                        local status = AnimationController.playSwing(function()
                            if not F.running or not scriptAlive() then return end
                            if not primaryTargetValid(candidate, candidate.mode) then return end
                            local _, _, currentRoot = characterParts()
                            if currentRoot and (currentRoot.Position - candidate.hit.Position).Magnitude <= attackRange then
                                if diagnostics.isEnabled() then
                                    diagnostics.count("combatSwings", candidate.id, weaponId, (currentRoot.Position - candidate.hit.Position).Magnitude)
                                end
                                pcall(function() RequestSwing:FireServer(candidate.hit) end)
                            end
                        end)
                        if status == "Scheduled" then F.lastSwingAt = now end
                    end
                elseif now - F.lastSwingAt >= 0.01 then
                    -- Keep the fast raw-request cadence for mining and chopping.
                    F.lastSwingAt = now
                    diagnostics.count(if candidate.mode == "tree" then "treeSwings" else "miningSwings", candidate.id)
                    pcall(function() RequestSwing:FireServer(candidate.hit) end)
                end
            end
        else
            equipTool(slot, now)
        end
    end

    local function processShiny(candidate, root, character, now)
        moveTo(root, character, candidate.part.Position + Vector3.new(0, math.min(modeHoverHeights.shiny, 5), 0))
        local reach = math.max(2, candidate.prompt.MaxActivationDistance - 1)
        if (root.Position - candidate.part.Position).Magnitude <= reach and now >= F.nextShinyPromptAt then
            F.nextShinyPromptAt = now + 0.9
            F.shinyPromptAttempts += 1

            -- Added the 0.05s server catch-up wait to prevent prompt misfires
            task.wait(0.05)
            pcall(function() fireproximityprompt(candidate.prompt) end)
            diagnostics.count("shinyPrompts")

            if F.shinyPromptAttempts >= 4 then
                shinyRetryAfter[candidate.object] = now + 10
                F.currentShiny = nil
                F.nextShinyScan = now + 0.5
                F.shinyPromptAttempts = 0
                F.nextShinyPromptAt = 0
                clearMovement()
            end
        end
    end

    F.equipTool = equipTool
    F.rangedRaycastFilter = rangedRaycastFilter
    F.bowFootprint = bowFootprint
    F.clearBowArc = clearBowArc
    F.bowAimFrom = bowAimFrom
    F.findClearBowOffset = findClearBowOffset
    F.fireSettledBow = fireSettledBow
    F.fireRanged = fireRanged
    F.doPrimaryAction = doPrimaryAction
    F.processShiny = processShiny
    return true
end
