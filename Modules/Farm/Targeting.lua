--[[
    Modules/Farm/Targeting.lua  -  target discovery and validation.
    Source: Script1 lines 1456-1775 (verbatim; shared variables read through F).
    catcher.find (Script1 1671-1687) lives in Catcher.lua and is looked up at call time.
]]

return function(State)
    local F = State.Farm
    local CollectionService = State.Services.CollectionService
    local LocalPlayer = F.LocalPlayer
    local miningStandoff = F.miningStandoff
    local bowRetryAfter = F.bowRetryAfter
    local preferNearestNode = F.preferNearestNode
    local bossNameByVariant = F.bossNameByVariant
    local shinyFamilies = F.shinyFamilies
    local shinyRetryAfter = F.shinyRetryAfter
    local cachedNodes = F.cachedNodes
    local cachedShinies = F.cachedShinies
    local catcher = F.catcher
    local prioritySet = F.prioritySet
    local usesSettledBow = F.usesSettledBow
    local interactReach = F.interactReach

    -- ==========================================
    -- 🛠️ GAME LOGIC & UTILITIES
    -- ==========================================
    local function characterParts()
        local character = LocalPlayer.Character
        if not character then return nil end
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        local root = character:FindFirstChild("HumanoidRootPart")
        if not humanoid or not root or humanoid.Health <= 0 then return nil end
        return character, humanoid, root
    end

    local function isAllowedWorld(instance)
        local hub = workspace:FindFirstChild("Hub")
        if hub and instance:IsDescendantOf(hub) then return true end
        local ruins = workspace:FindFirstChild("Ruins")
        if ruins and instance:IsDescendantOf(ruins) then return true end
        local userId = tostring(LocalPlayer.UserId)
        local cursor: Instance? = instance
        while cursor and cursor ~= workspace do
            local ownerId = cursor:GetAttribute("OwnerUserId")
            if ownerId == LocalPlayer.UserId or string.find(cursor.Name, userId, 1, true) then return true end
            cursor = cursor.Parent
        end
        return false
    end

    local function getHitPart(target)
        if target:IsA("BasePart") then return target end
        if not target:IsA("Model") then return target:FindFirstChildWhichIsA("BasePart", true) end

        local hit = target:FindFirstChild("HB", true)
        if hit and hit:IsA("BasePart") then return hit end
        if target.PrimaryPart then return target.PrimaryPart end
        return target:FindFirstChildWhichIsA("BasePart", true)
    end

    local function withinMaxDistance(part, root)
        return (part.Position - root.Position).Magnitude <= F.maxTargetDistance
    end

    local minSlimeGroundGap, maxSlimeGroundGap = 0.75, 8
    local slimeGroundProbeUp, slimeGroundProbeLength = 20, 40
    local sharedRaycastParams = RaycastParams.new()
    sharedRaycastParams.FilterType = Enum.RaycastFilterType.Exclude
    sharedRaycastParams.IgnoreWater = true

    local function hasReachableSlimeGround(enemy, hit)
        sharedRaycastParams.FilterDescendantsInstances = { enemy, LocalPlayer.Character }
        local origin = hit.Position + Vector3.new(0, slimeGroundProbeUp, 0)
        local result = workspace:Raycast(origin, Vector3.new(0, -slimeGroundProbeLength, 0), sharedRaycastParams)
        if not result then return false end
        local groundGap = hit.Position.Y - result.Position.Y
        return groundGap >= minSlimeGroundGap and groundGap <= maxSlimeGroundGap
    end

    local function findEnemyTarget(root)
        local checkBowCover = usesSettledBow()
        local now = os.clock()
        local candidates = {}
        local seen = {}

        local function addEnemy(instance)
            if instance and instance.Parent and not seen[instance] then
                seen[instance] = true
                table.insert(candidates, instance)
            end
        end

        for _, enemy in ipairs(CollectionService:GetTagged("Enemy")) do
            addEnemy(enemy)
        end

        -- Hub slimes are not consistently tagged, so include their guardian folder too.
        local hub = workspace:FindFirstChild("Hub")
        local guardians = hub and hub:FindFirstChild("Guardians")
        if guardians then
            for _, enemy in ipairs(guardians:GetChildren()) do addEnemy(enemy) end
        end

        local ranks = {}
        for rank, id in ipairs(F.enemyPriority) do
            ranks[id] = if F.preferNearestEnemy then 1 else rank
        end
        local best, bestRank, bestDistance = nil, math.huge, math.huge
        for _, enemy in ipairs(candidates) do
            local enemyId = enemy:GetAttribute("EnemyId")
            local rank = enemyId and ranks[enemyId]
            if rank and rank <= bestRank and enemy:GetAttribute("Died") == nil
                and (not checkBowCover or (bowRetryAfter[enemy] or 0) <= now) then
                local hit = getHitPart(enemy)
                local health = enemy:GetAttribute("HP") or enemy:GetAttribute("Health")
                local humanoid = enemy:FindFirstChildWhichIsA("Humanoid", true)
                local alive = (type(health) ~= "number" or health > 0)
                    and (not humanoid or humanoid.Health > 0)
                local isSlime = string.find(enemyId, "Slime", 1, true) ~= nil
                local reachable = not isSlime or (hit and hasReachableSlimeGround(enemy, hit))
                if alive and reachable and hit and hit:IsDescendantOf(workspace) and withinMaxDistance(hit, root) then
                    local distance = (hit.Position - root.Position).Magnitude
                    if rank < bestRank or distance < bestDistance then
                        best = { mode = "kill", model = enemy, hit = hit, id = enemyId }
                        bestRank, bestDistance = rank, distance
                    end
                end
            end
        end

        return best
    end

    local function findNodeTarget(root, allowedTypes, mode)
        local ranks = {}
        for rank, id in ipairs(allowedTypes) do
            ranks[id] = if preferNearestNode[mode] then 1 else rank
        end
        local best, bestRank, bestDistance = nil, math.huge, math.huge
        local seen = setmetatable({}, { __mode = "k" })
        local function considerNode(instance)
            if seen[instance] then return end
            seen[instance] = true
            if not instance:IsA("Model") then return end
            local nodeType = instance:GetAttribute("NodeType")
            local rank = nodeType and ranks[nodeType]
            if rank and isAllowedWorld(instance) then
                cachedNodes[instance] = true
                local hit = getHitPart(instance)
                if hit and hit:IsDescendantOf(workspace) and withinMaxDistance(hit, root) then
                    local distance = (hit.Position - root.Position).Magnitude
                    if mode == "mine" and miningStandoff.enabled and distance > interactReach then
                        rank += #allowedTypes
                    end
                    if rank < bestRank or (rank == bestRank and distance < bestDistance) then
                        best = { mode = mode, model = instance, hit = hit, id = nodeType }
                        bestRank, bestDistance = rank, distance
                    end
                end
            end
        end

        -- The Workspace cache can miss nodes when the game replaces ResourceField models.
        -- Rescan these small, known folders each target pass so mining/tree fallback stays live.
        for instance in pairs(cachedNodes) do
            considerNode(instance)
        end
        for _, worldName in ipairs({ "Hub", "Ruins" }) do
            local world = workspace:FindFirstChild(worldName)
            local field = world and world:FindFirstChild("ResourceField")
            if field then
                for _, instance in ipairs(field:GetChildren()) do
                    considerNode(instance)
                end
            end
        end
        return best
    end

    local function mortenTargetName(boss, hit)
        local model = if boss:IsA("Model") then boss else boss:FindFirstAncestorOfClass("Model")
        local enemyId = hit:GetAttribute("EnemyId") or boss:GetAttribute("EnemyId")
            or (model and model:GetAttribute("EnemyId")) or boss.Name
        if enemyId ~= "Morten" then return nil end
        local variant = hit:GetAttribute("MortenVariant") or boss:GetAttribute("MortenVariant")
            or (model and model:GetAttribute("MortenVariant"))
        return bossNameByVariant[variant or "Morten"]
    end

    local function findBossTarget(root)
        local checkBowCover = usesSettledBow()
        local now = os.clock()
        local ranks = {}
        for rank, name in ipairs(F.bossPriority) do ranks[name] = rank end
        local candidates = {}
        local seen = {}
        local function addBoss(instance)
            if instance and instance.Parent and not seen[instance] then
                seen[instance] = true
                table.insert(candidates, instance)
            end
        end

        for _, boss in ipairs(CollectionService:GetTagged("Boss")) do addBoss(boss) end
        -- Some game versions expose the boss through the Enemy tag before the Boss tag is applied.
        for _, enemy in ipairs(CollectionService:GetTagged("Enemy")) do
            local enemyId = enemy:GetAttribute("EnemyId")
            if enemyId == "Morten" then addBoss(enemy) end
        end

        local bestTarget, bestHit, bestId, bestRank, bestDistance
        for _, boss in ipairs(candidates) do
            local hit = getHitPart(boss)
            if hit and hit:IsDescendantOf(workspace) and (not checkBowCover or (bowRetryAfter[boss] or 0) <= now) then
                local bossId = mortenTargetName(boss, hit)
                local rank = bossId and ranks[bossId]
                local health = boss:GetAttribute("HP") or boss:GetAttribute("Health")
                    or hit:GetAttribute("HP") or hit:GetAttribute("Health")
                local died = boss:GetAttribute("Died") or hit:GetAttribute("Died")
                local humanoid = boss:FindFirstChildWhichIsA("Humanoid", true)
                if rank and died == nil
                    and (type(health) ~= "number" or health > 0)
                    and (not humanoid or humanoid.Health > 0)
                    and withinMaxDistance(hit, root) then
                    local distance = (hit.Position - root.Position).Magnitude
                    if not bestRank or rank < bestRank or (rank == bestRank and distance < bestDistance) then
                        bestTarget, bestHit, bestId, bestRank, bestDistance = boss, hit, bossId, rank, distance
                    end
                end
            end
        end

        if bestTarget then
            return { mode = "boss", model = bestTarget, hit = bestHit, id = bestId }
        end
        return nil
    end

    local function findPrimaryTarget(root, mode)
        if mode == "kill" then return findEnemyTarget(root)
        elseif mode == "mine" then return findNodeTarget(root, F.orePriority, "mine")
        elseif mode == "tree" then return findNodeTarget(root, F.treePriority, "tree")
        elseif mode == "boss" then return findBossTarget(root)
        elseif mode == "catch" then return catcher.find(root)
        end
        return nil
    end

    local function primaryTargetValid(candidate, expectedMode)
        if not candidate or not candidate.model or not candidate.model.Parent or not candidate.hit
            or not candidate.hit:IsDescendantOf(workspace) then return false end
        local mode = expectedMode or candidate.mode
        if candidate.mode ~= mode then return false end

        if mode == "kill" then
            if not prioritySet(F.enemyPriority)[candidate.id]
                or candidate.model:GetAttribute("EnemyId") ~= candidate.id
                or candidate.model:GetAttribute("Died") ~= nil then return false end
        elseif mode == "boss" then
            if (not CollectionService:HasTag(candidate.hit, "Boss")
                    and not CollectionService:HasTag(candidate.hit, "Enemy")
                    and not CollectionService:HasTag(candidate.model, "Boss")
                    and not CollectionService:HasTag(candidate.model, "Enemy"))
                or candidate.hit:GetAttribute("Died") ~= nil
                or candidate.model:GetAttribute("Died") ~= nil
                or mortenTargetName(candidate.model, candidate.hit) ~= candidate.id
                or not prioritySet(F.bossPriority)[candidate.id] then return false end
            local hitHealth = candidate.hit:GetAttribute("HP") or candidate.hit:GetAttribute("Health")
            if type(hitHealth) == "number" and hitHealth <= 0 then return false end
        elseif mode == "catch" then
            local action = candidate.hit:GetAttribute("Action")
            if not CollectionService:HasTag(candidate.hit, catcher.wildTag) or not catcher.species[candidate.id]
                or action == "Reeled" or action == "Run" then return false end
        else
            local allowed = if mode == "tree" then prioritySet(F.treePriority) else prioritySet(F.orePriority)
            if not allowed[candidate.id] or candidate.model:GetAttribute("NodeType") ~= candidate.id
                or not isAllowedWorld(candidate.model) then return false end
        end

        local healthAttribute = candidate.model:GetAttribute("HP")
            or candidate.model:GetAttribute("Health")
        if type(healthAttribute) == "number" and healthAttribute <= 0 then return false end
        local humanoid = candidate.model:FindFirstChildWhichIsA("Humanoid", true)
        if humanoid and humanoid.Health <= 0 then return false end
        return true
    end

    local function familyForPiece(piece)
        for _, family in ipairs(shinyFamilies) do
            if string.find(piece, family .. "Shiny", 1, true) then return family end
        end
        return nil
    end

    local function shinyTargetValid(candidate)
        return candidate and candidate.object and candidate.object:IsDescendantOf(workspace)
        and candidate.part and candidate.part:IsDescendantOf(workspace)
        and candidate.prompt and candidate.prompt.Parent and candidate.prompt.Enabled
        and isAllowedWorld(candidate.object)
    end

    local function findNearestShiny(root)
        local familySelection = prioritySet(shinyFamilies)
        for _, family in ipairs(shinyFamilies) do familySelection[family] = F.selectedFamilies[family] == true end

        local best, bestPart, bestPrompt, bestPiece, bestDistance
        for instance in pairs(cachedShinies) do
            local piece = instance:GetAttribute("ShinyPiece")
            if type(piece) == "string" and piece ~= "" and isAllowedWorld(instance) and (not shinyRetryAfter[instance] or shinyRetryAfter[instance] <= os.clock()) then
                local family = familyForPiece(piece)
                if family and familySelection[family] then
                    local part = if instance:IsA("BasePart") then instance else instance:FindFirstChildWhichIsA("BasePart", true)
                    local prompt = instance:FindFirstChildWhichIsA("ProximityPrompt", true)
                    if part and prompt and prompt.Enabled and withinMaxDistance(part, root) then
                        local distance = (part.Position - root.Position).Magnitude
                        if not bestDistance or distance < bestDistance then
                            best, bestPart, bestPrompt, bestPiece, bestDistance = instance, part, prompt, piece, distance
                        end
                    end
                end
            end
        end
        if best then return { object = best, part = bestPart, prompt = bestPrompt, piece = bestPiece } end
        return nil
    end

    F.characterParts = characterParts
    F.isAllowedWorld = isAllowedWorld
    F.getHitPart = getHitPart
    F.withinMaxDistance = withinMaxDistance
    F.sharedRaycastParams = sharedRaycastParams
    F.findEnemyTarget = findEnemyTarget
    F.findNodeTarget = findNodeTarget
    F.mortenTargetName = mortenTargetName
    F.findBossTarget = findBossTarget
    F.findPrimaryTarget = findPrimaryTarget
    F.primaryTargetValid = primaryTargetValid
    F.shinyTargetValid = shinyTargetValid
    F.findNearestShiny = findNearestShiny
    return true
end
