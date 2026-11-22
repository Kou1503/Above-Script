--[[
    Modules/Farm/Config.lua  -  Farm game modules, tuning values, target lists and shared runtime fields.
    Source: Script1 lines 4-199 (services now come from State; prioritySet moved here from line 854
    because Targeting needs it before the Farm tabs are built).

    Convention for every Farm module:
      F = State.Farm.  Any Script1 top-level variable that is REASSIGNED somewhere lives as F.<name>.
      Tables that are only mutated (never reassigned) are also stored on F and aliased as locals.
]]

return function(State)
    local F = State.Farm
    local Sv, G = State.Services, State.Game

    -- Real injects STATE into live-reload scripts; State.alive() also turns false after a hub unload.
    F.scriptAlive = State.alive

    local Players = Sv.Players
    local ReplicatedStorage = Sv.ReplicatedStorage
    local LocalPlayer = Players.LocalPlayer
    local Remotes = ReplicatedStorage:WaitForChild("Remotes")
    local RequestSwing = Remotes:WaitForChild("RequestSwing")
    local RequestShoot = Remotes:WaitForChild("RequestShoot")
    local ProjectileEnded = Remotes:WaitForChild("ProjectileEnded")
    local Shared = ReplicatedStorage:WaitForChild("Shared")
    local ClientControllers = LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client"):WaitForChild("Controllers")
    local requireModule: any = require
    local AnimationController: any = requireModule(ClientControllers:WaitForChild("AnimationController"))
    local HotbarController: any = G.HotbarController or requireModule(ClientControllers:WaitForChild("HotbarController"))
    local WeaponConfig: any = requireModule(Shared:WaitForChild("Config"):WaitForChild("WeaponConfig"))
    local EnemyConfig: any = requireModule(Shared:WaitForChild("Config"):WaitForChild("EnemyConfig"))
    local Ballistics: any = requireModule(Shared:WaitForChild("Ballistics"))
    local hotbarIndexByToolSlot = { Weapon = 1, Pickaxe = 2, Axe = 3 }

    F.LocalPlayer, F.Remotes, F.Shared, F.ClientControllers = LocalPlayer, Remotes, Shared, ClientControllers
    F.RequestSwing, F.RequestShoot, F.ProjectileEnded = RequestSwing, RequestShoot, ProjectileEnded
    F.requireModule = requireModule
    F.AnimationController, F.HotbarController = AnimationController, HotbarController
    F.WeaponConfig, F.EnemyConfig, F.Ballistics = WeaponConfig, EnemyConfig, Ballistics
    F.hotbarIndexByToolSlot = hotbarIndexByToolSlot

    F.interactReach = 20
    F.miningStandoff = { enabled = false, hit = nil :: BasePart?, unconfirmedSince = nil :: number?, close = false, connection = nil :: RBXScriptConnection? }
    F.attackRange = 15
    F.rangedHoverHeight = 20
    F.rangedAttackRange = 45
    -- Give the server cooldown room for client and network scheduling.
    F.rangedShotIntervals = { SoulfireBow = 0.32, SoulScepter = 0.85 }
    F.nextShotAt = 0
    F.shotId = 1000000
    F.bowAim = "Settled"
    F.bowHover = Vector3.new(0, 19, 0)
    F.bowRetryAfter = setmetatable({}, { __mode = "k" })
    F.bowState = nil
    F.bowShotPending = nil
    F.lastBowShotAt = -math.huge

    function F.usesSettledBow()
        return F.bowAim == "Settled" and HotbarController.itemAt(hotbarIndexByToolSlot.Weapon) == "SoulfireBow"
    end

    -- Secret: never hardcoded. Comes from ABOVE_Obsidian/secrets/webhook.txt or getgenv().ABOVE_CONFIG.
    F.WEBHOOK_URL = State.Secrets.WebhookUrl or ""
    F.pingInterval = 900

    -- ==========================================
    -- ⚙️ CORE VARIABLES
    -- ==========================================
    F.enemyTypes = {
        "GreenSlime", "BlueSlime", "PinkSlime", "OrangeSlime", "KingSlime",
        "Skeleton", "SkeletonArcher", "SkeletonKnight",
    }
    F.oreTypes = { "Stone", "Sand", "Clay", "Coal", "IronOre", "GoldOre" }
    F.treeTypes = { "Tree", "Pine" }
    local bossTypes = { "Morten" }
    local bossNameByVariant = { Morten = "Morten" }
    for _, variant in ipairs(EnemyConfig.Morten.variants or {}) do
        local id = variant.id
        if type(id) == "string" and not bossNameByVariant[id] then
            local name = variant.name or id
            bossNameByVariant[id] = name
            table.insert(bossTypes, name)
        end
    end
    F.bossTypes, F.bossNameByVariant = bossTypes, bossNameByVariant
    F.shinyFamilies = { "Blue", "Red", "Yellow" }
    F.enemyPriority = {
        "GreenSlime", "BlueSlime", "PinkSlime", "OrangeSlime",
        "Skeleton", "SkeletonArcher", "SkeletonKnight", "KingSlime",
    }
    F.preferNearestEnemy = false
    F.autoReturnToHub = false
    F.preferNearestNode = { mine = false, tree = false }
    F.orePriority = { "Stone", "IronOre", "Coal", "GoldOre", "Sand", "Clay" }
    F.treePriority = { "Tree", "Pine" }
    F.bossPriority = { "Morten" }
    F.bossBow = { enabled = false }
    F.selectedFamilies = { Blue = true, Red = true, Yellow = true }

    F.featureLabelByMode = {
        kill = "Auto Kill",
        mine = "Auto Mine",
        tree = "Auto Cut Tree",
        boss = "Auto Boss",
        shiny = "Auto Shiny",
        catch = "Auto Catch",
    }
    F.defaultFeatureOrder = { "shiny", "boss", "kill", "catch", "mine", "tree" }
    F.featurePriority = table.clone(F.defaultFeatureOrder)
    F.featurePriorityRank = { shiny = 1, boss = 2, kill = 3, catch = 4, mine = 5, tree = 6 }
    -- Mining and tree gathering are the fallback activities when no combat target exists.
    F.enabledModes = {
        kill = false,
        mine = true,
        tree = true,
        boss = false,
        catch = false,
    }

    F.activeMode = nil
    F.autoShiny = false
    F.flightSpeed = 115
    F.maxTargetDistance = 250
    F.modeHoverHeights = { kill = 4.2, boss = 4.2, mine = 19.0, tree = 19.0, shiny = 5.0 }
    F.smoothOrbitEnabled = false
    F.smoothOrbitRadius = 5.05
    F.smoothOrbitSpeed = 1.05
    F.orbitTarget = nil

    F.primaryTarget = nil
    F.primaryTargetMode = nil
    F.nextPrimaryScan = 0
    F.lastSwingTarget = nil
    F.lastSwingAt = 0
    F.equippedSlot = nil
    F.equipReadyAt = 0

    F.currentShiny = nil
    F.nextShinyScan = 0
    F.nextShinyPromptAt = 0
    F.shinyPromptAttempts = 0
    F.shinyRetryAfter = setmetatable({}, { __mode = "k" })

    F.noclipCharacter = nil
    F.movementAlign = nil
    F.currentCharacter = nil
    F.running = true

    -- Script1 854-858 (moved here: used by Targeting and Tabs)
    function F.prioritySet(order)
        local result = {}
        for _, item in ipairs(order) do result[item] = true end
        return result
    end

    -- ==========================================
    -- 🐄 AUTO CATCH (lasso wild Ruins animals)
    -- ==========================================
    -- Probed live (ABOVE v145): wild animals are anchored Parts tagged Config.Animal.Wild.Tag
    -- ("AboveWildChicken") under Workspace.Ruins.WildChickens, named Wild<Species>, with an "Action" attribute.
    -- A throw = RequestShoot:FireServer(origin, ballisticDirection, power, shotId) with the Lasso selected,
    -- wrapped in RequestSprint(true/false, "Aim") like the game's own draw.  LassoLoop: range 48 studs,
    -- speed 28..62, gravity 60, 1.3 s cooldown, 0.8 s full draw.  A catch shows as Action -> "Reeled",
    -- the part is removed and an Alert "Caught a <Species>" arrives.  A miss/scare shows as Action -> "Run".
    -- Flee ranges (AnimalConfig.Wild.FleeStuds): Chicken 20, Horse 18, Cow 15, Sheep 10 - we throw from outside.
    local catcher: any = {
        species = { Chicken = true, Cow = true, Sheep = true, Horse = true },
        margin = 6,          -- studs beyond the flee range
        height = 8,          -- studs above the animal (clears ruins walls / terrain slopes)
        slot = 9,            -- hotbar slot the Lasso is put on when it is not on the bar already
        fromAbove = true,    -- hover straight above the animal (far more accurate than throwing from the side)
        extraHeight = 0,
        nextThrowAt = 0,
        equipReadyAt = 0,
        retryAfter = setmetatable({}, { __mode = "k" }),
        lastPos = setmetatable({}, { __mode = "k" }),
        stats = { throws = 0, caught = 0, missed = 0, bySpecies = {} },
    }
    do
        local animalConfig: any = requireModule(Shared:WaitForChild("Config"):WaitForChild("AnimalConfig"))
        catcher.wildTag = (animalConfig.Wild and animalConfig.Wild.Tag) or "AboveWildChicken"
        catcher.flee = (animalConfig.Wild and animalConfig.Wild.FleeStuds) or { Chicken = 20, Cow = 15, Sheep = 10, Horse = 18 }
        catcher.projectile = WeaponConfig.Projectiles and WeaponConfig.Projectiles.LassoLoop
        catcher.sprintRemote = Remotes:WaitForChild("RequestSprint")
    end

    function catcher.refreshLabel()
        local label = catcher.label
        if not label then return end
        local parts = {}
        for _, species in ipairs({ "Chicken", "Cow", "Sheep", "Horse" }) do
            parts[#parts + 1] = species .. " " .. (catcher.stats.bySpecies[species] or 0)
        end
        pcall(function()
            label:SetText(("Throws %d | caught %d | missed %d\n%s"):format(
                catcher.stats.throws, catcher.stats.caught, catcher.stats.missed, table.concat(parts, " | ")))
        end)
    end

    function catcher.stopAim()
        if catcher.drawAt then
            catcher.drawAt = nil
            pcall(function() catcher.sprintRemote:FireServer(false, "Aim") end)
        end
    end

    function catcher.restoreHotbar()
        local saved = catcher.savedSlot
        if saved and saved.item then pcall(HotbarController.assign, saved.slot, saved.item) end
        catcher.savedSlot = nil
    end
    F.catcher = catcher

    return F
end
