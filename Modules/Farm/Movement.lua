--[[
    Modules/Farm/Movement.lua  -  noclip, AlignPosition flight, auto return to Hub, character resets.
    Source: Script1 lines 1777-2013 (verbatim; shared variables read through F).
]]

return function(State)
    local F = State.Farm
    local RunService = State.Services.RunService
    local LocalPlayer = F.LocalPlayer
    local Shared = F.Shared
    local requireModule = F.requireModule
    local diagnostics = F.diagnostics
    local scriptAlive = F.scriptAlive

    local originalCollisions = setmetatable({}, { __mode = "k" })
    local noclipSteppedConn: RBXScriptConnection? = nil
    local noclipDescendantAddedConn: RBXScriptConnection? = nil
    local movementAttachment: any = nil
    local movementRoot: BasePart? = nil

    local function restoreCollisions()
        if noclipSteppedConn then
            noclipSteppedConn:Disconnect()
            noclipSteppedConn = nil
        end
        if noclipDescendantAddedConn then
            noclipDescendantAddedConn:Disconnect()
            noclipDescendantAddedConn = nil
        end
        for part, canCollide in pairs(originalCollisions) do
            if part.Parent then part.CanCollide = canCollide end
            originalCollisions[part] = nil
        end
        F.noclipCharacter = nil
    end

    local function cacheCollisionPart(instance)
        if instance:IsA("BasePart") and originalCollisions[instance] == nil then
            originalCollisions[instance] = instance.CanCollide
            if instance.CanCollide then instance.CanCollide = false end
        end
    end

    local function setNoClip(character)
        if F.noclipCharacter == character and noclipSteppedConn and noclipSteppedConn.Connected then
            return
        end
        restoreCollisions()
        F.noclipCharacter = character
        for _, instance in ipairs(character:GetDescendants()) do
            cacheCollisionPart(instance)
        end
        noclipDescendantAddedConn = character.DescendantAdded:Connect(cacheCollisionPart)
        noclipSteppedConn = RunService.Stepped:Connect(function()
            if F.noclipCharacter ~= character or not character.Parent then
                restoreCollisions()
                return
            end
            for part in pairs(originalCollisions) do
                if part.Parent and part.CanCollide then part.CanCollide = false end
            end
        end)
    end

    local function clearMovement()
        if F.movementAlign then F.movementAlign:Destroy(); F.movementAlign = nil end
        if movementAttachment then movementAttachment:Destroy(); movementAttachment = nil end
        movementRoot = nil
        F.orbitTarget = nil
        restoreCollisions()
    end

    local updateHubReturn, cancelHubReturn
    do
        local config = Shared:WaitForChild("Config")
        local buildConfig: any = requireModule(config:WaitForChild("BuildConfig"))
        local grid: any = requireModule(Shared:WaitForChild("Grid"))
        local pathfinding = game:GetService("PathfindingService")
        local islandPrefix = "Island_" .. LocalPlayer.UserId .. ":"
        local homeIsland: Model? = nil
        local nextIslandCheck, nextWalk = 0, 0
        local walkAttempt: any = nil

        local function onIsland(island, position)
            if not island or island.Parent ~= workspace then return false end
            local origin = island:GetAttribute("IslandOrigin")
            if typeof(origin) ~= "Vector3" then return false end
            local tier = island:GetAttribute("ExpansionTier")
            local bounds = buildConfig.boundsForTier(if type(tier) == "number" then tier else 0)
            local offset = position - origin
            local reach = (bounds.horizontal + 3) * grid.CellSize
            return math.abs(offset.X) <= reach and math.abs(offset.Z) <= reach
                and offset.Y >= -bounds.below * grid.CellSize and offset.Y <= bounds.above * grid.CellSize
        end

        cancelHubReturn = function()
            local attempt = walkAttempt
            walkAttempt = nil
            homeIsland = nil
            nextIslandCheck, nextWalk = 0, 0
            if attempt and LocalPlayer.Character == attempt.character and attempt.humanoid.Health > 0
                and onIsland(attempt.island, attempt.root.Position) then
                attempt.humanoid:MoveTo(attempt.root.Position)
            end
        end

        local function walkToHub(attempt, portal, touchPart)
            local character, humanoid, root = attempt.character, attempt.humanoid, attempt.root
            local function canWalk()
                return F.running and scriptAlive() and F.autoReturnToHub and walkAttempt == attempt
                    and LocalPlayer.Character == character and humanoid.Health > 0
                    and portal:IsDescendantOf(attempt.island) and onIsland(attempt.island, root.Position)
            end

            local function walkTo(position, timeout)
                if not canWalk() then return false end
                humanoid:MoveTo(position)
                local deadline = os.clock() + timeout
                while canWalk() and os.clock() < deadline do
                    local offset = root.Position - position
                    if Vector3.new(offset.X, 0, offset.Z).Magnitude < 1.5 and math.abs(offset.Y) < 5 then
                        return true
                    end
                    task.wait(0.05)
                end
                return false
            end

            local portalPosition = touchPart.Position
            local groundParams = RaycastParams.new()
            groundParams.FilterType = Enum.RaycastFilterType.Exclude
            groundParams.FilterDescendantsInstances = { character, portal }
            groundParams.RespectCanCollide = true
            local ground = workspace:Raycast(portalPosition + Vector3.new(0, 4, 0), Vector3.new(0, -22, 0), groundParams)
            if not ground then return end
            local goal = ground.Position + Vector3.new(0, 2, 0)

            local path = pathfinding:CreatePath({ WaypointSpacing = 5 })
            local ok = pcall(path.ComputeAsync, path, root.Position, goal)
            local waypoints = if ok and path.Status == Enum.PathStatus.Success then path:GetWaypoints() else {}
            path:Destroy()
            if #waypoints == 0 then return end

            for _, waypoint in ipairs(waypoints) do
                if not canWalk() then return end
                if waypoint.Action == Enum.PathWaypointAction.Jump then humanoid.Jump = true end
                if not walkTo(waypoint.Position, 2.5) then return end
            end

            -- Move through the portal's touch plane if the last waypoint stopped just short.
            local normal = portal:GetPivot().LookVector
            local side = (root.Position - portalPosition):Dot(normal)
            walkTo(goal - normal * (if side >= 0 then 3 else -3), 2)
        end

        updateHubReturn = function(character, humanoid, root, now)
            if not F.autoReturnToHub then
                if walkAttempt or homeIsland then cancelHubReturn() end
                return false
            end

            if not onIsland(homeIsland, root.Position) then
                if walkAttempt or homeIsland then cancelHubReturn() end
                if now < nextIslandCheck then return false end
                nextIslandCheck = now + 0.4
                for _, island in workspace:GetChildren() do
                    if island:IsA("Model") and island.Name:sub(1, #islandPrefix) == islandPrefix
                        and onIsland(island, root.Position) then
                        homeIsland = island
                        diagnostics.count("homeIslandEntries")
                        clearMovement()
                        F.bowState = nil
                        F.primaryTarget, F.primaryTargetMode, F.nextPrimaryScan = nil, nil, 0
                        F.currentShiny, F.nextShinyScan = nil, 0
                        break
                    end
                end
                if not homeIsland then return false end
            end

            if walkAttempt or now < nextWalk or humanoid.FloorMaterial == Enum.Material.Air then return true end
            nextWalk = now + 3.5
            local island = homeIsland
            if not island then return true end
            local portal = island:FindFirstChild("HUB")
            local touchPart = portal and portal:FindFirstChild("TouchPart", true)
            if not portal or not portal:IsA("Model") or not touchPart or not touchPart:IsA("BasePart") then return true end
            local attempt = { island = island, character = character, humanoid = humanoid, root = root }
            walkAttempt = attempt
            diagnostics.count("hubWalkAttempts")
            task.spawn(function()
                local ok, err = pcall(walkToHub, attempt, portal, touchPart)
                if not ok then warn("[ABOVE Farm] Hub portal walk failed: " .. tostring(err)) end
                if walkAttempt == attempt then
                    walkAttempt = nil
                    nextWalk = os.clock() + 3.5
                end
            end)
            return true
        end
    end

    local function resetAfterCharacterChange()
        cancelHubReturn()
        clearMovement()
        F.bowState = nil
        F.bowShotPending = nil
        F.lastBowShotAt = -math.huge
        F.currentCharacter = nil
        F.equippedSlot = nil
        F.equipReadyAt = 0
        F.primaryTarget = nil
        F.primaryTargetMode = nil
        F.lastSwingTarget = nil
        F.lastSwingAt = 0
        F.currentShiny = nil
        F.shinyPromptAttempts = 0
        F.nextShinyPromptAt = 0
        F.nextPrimaryScan = 0
        F.nextShinyScan = 0
    end

    F.characterRemovingConnection = LocalPlayer.CharacterRemoving:Connect(function()
        diagnostics.count("characterRemovals")
        resetAfterCharacterChange()
    end)
    F.characterAddedConnection = LocalPlayer.CharacterAdded:Connect(function()
        diagnostics.count("characterSpawns")
        resetAfterCharacterChange()
    end)

    local function moveTo(root, character, destination)
        if movementRoot ~= root or not F.movementAlign or not F.movementAlign.Parent then
            clearMovement()
            setNoClip(character)
            movementAttachment = Instance.new("Attachment")
            movementAttachment.Name = "UnifiedFarmAttachment"
            movementAttachment.Parent = root
            local movementAlign = Instance.new("AlignPosition")
            F.movementAlign = movementAlign
            movementAlign.Name = "UnifiedFarmAlignPosition"
            movementAlign.Mode = Enum.PositionAlignmentMode.OneAttachment
            movementAlign.Attachment0 = movementAttachment
            movementAlign.ApplyAtCenterOfMass = true
            movementAlign.RigidityEnabled = false
            movementAlign.MaxForce = 1000000
            movementAlign.MaxVelocity = F.flightSpeed
            movementAlign.Responsiveness = 45
            movementAlign.Position = root.Position
            movementAlign.Parent = root
            movementRoot = root
        end
        setNoClip(character)
        if F.movementAlign then
            F.movementAlign.MaxVelocity = F.flightSpeed
            F.movementAlign.Position = destination
        end
    end

    F.restoreCollisions = restoreCollisions
    F.setNoClip = setNoClip
    F.clearMovement = clearMovement
    F.updateHubReturn = updateHubReturn
    F.cancelHubReturn = cancelHubReturn
    F.resetAfterCharacterChange = resetAfterCharacterChange
    F.moveTo = moveTo
    return true
end
