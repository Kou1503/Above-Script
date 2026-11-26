--[[
    Modules/Builder/Island.lua  -  game modules, Builder state S, island helpers, occupancy index,
    inventory and hotbar helpers.
    Source: Script2 lines 1-250 (verbatim) minus:
      * game:IsLoaded wait and the __ABOVE_BUILDER re-exec guard (now in loader.lua)
      * the Obsidian loadstrings (the shared Library comes from State.UI)
    The "island not found" error is kept: loader.lua catches it, so the Farm keeps running and the
    Builder / Planter / Schematic / Run / Pollinator tabs show an "unavailable" notice instead.

    Convention for Builder modules: B = State.Builder.  Script2 file-level variables that are reassigned
    in another module (refreshSoon, regionLabel, syncing, checklistLabel, progressLabel) live on B.
]]

return function(State)
    local B = State.Builder
    local UI = State.UI
    local Library = UI.Library

    local Players = State.Services.Players
    local RS = State.Services.ReplicatedStorage
    local LP = Players.LocalPlayer

    ------------------------------------------------------------------------------------------
    -- Game modules
    ------------------------------------------------------------------------------------------
    local Shared = RS:WaitForChild("Shared")
    local Config = require(Shared:WaitForChild("Config"))
    local Grid = require(Shared:WaitForChild("Grid"))
    local StackKey = require(Shared:WaitForChild("StackKey"))
    local Ctl = LP:WaitForChild("PlayerScripts"):WaitForChild("Client"):WaitForChild("Controllers")
    local Hotbar = require(Ctl:WaitForChild("HotbarController"))
    local BuildCtl = require(Ctl:WaitForChild("BuildController"))
    local Remotes = RS:WaitForChild("Remotes")
    local PlaceRemote = Remotes:WaitForChild("RequestPlace")
    local ResultRemote = Remotes:WaitForChild("PlaceResult")
    local SwingRemote = Remotes:WaitForChild("RequestSwing")

    local getups = (debug and debug.getupvalues) or getupvalues
    local CS = Grid.CellSize
    local Placement = Config.Build.Placement
    local PLACE_REACH = (Config.Player.BuildReachCells or 8) * CS * 0.8     -- 19.2 studs, safety margin
    local BREAK_REACH = 18   -- studs. Measured: swings landed 3/3 at every distance from 12 to 20, 0/3 at 22 -> 18 keeps a 2 stud margin

    local Options, Toggles = Library.Options, Library.Toggles

    ------------------------------------------------------------------------------------------
    -- State
    ------------------------------------------------------------------------------------------
    local S = {
        pos1 = nil, pos2 = nil,
        clip = nil,
        running = false, cancel = false,
        placed = 0, total = 0, failed = 0, moves = 0, moveTime = 0, startedAt = 0, lastRun = nil,
        conns = {}, unloaded = false,
        occ = {},                -- cellKey -> blockId (live island occupancy)
        parts = {},              -- cellKey -> Part (for breaking)
        savedSlot = nil,
        retry = {}, rejStreak = 0,
    }
    local function track(c) table.insert(S.conns, c) return c end
    local function notify(msg, t) pcall(function() Library:Notify({ Title = "ABOVE Builder", Description = msg, Time = t or 4 }) end) end

    ------------------------------------------------------------------------------------------
    -- Island helpers
    ------------------------------------------------------------------------------------------
    local function getIsland()
        local prefix = "Island_" .. LP.UserId .. ":"
        for _, c in ipairs(workspace:GetChildren()) do
            if c.Name:sub(1, #prefix) == prefix then return c end
        end
    end
    local Island = getIsland()
    if not Island then error("ABOVE Builder: your island was not found - join your island first.") end

    local function origin() return Island:GetAttribute("IslandOrigin") or BuildCtl.islandOrigin() end

    local function islandBounds()
        local tier = Island:GetAttribute("ExpansionTier") or 0
        local ok, b = pcall(Config.Build.boundsForTier, tier)
        if ok and type(b) == "table" then return b end
        return { horizontal = 25, above = 440, below = 80 }
    end

    local function hrp()
        local c = LP.Character
        return c and c:FindFirstChild("HumanoidRootPart")
    end

    local function protected(cell)
        local ok, r = pcall(Config.Build.isProtectedCell, cell)
        return ok and r == true
    end

    local function key(x, y, z) return x .. "," .. y .. "," .. z end

    -- World limits (probed): horizontal half-width by expansion tier (tier 3 = +-51 cells), vertical -80..440,
    -- plus a block capacity per tier (tier 3 = 11000).  The server refuses anything outside, so we never send it.
    local function clampCell(c)
        local b = islandBounds()
        local x = math.clamp(c.x, -b.horizontal, b.horizontal)
        local y = math.clamp(c.y, -b.below, b.above)
        local z = math.clamp(c.z, -b.horizontal, b.horizontal)
        return Grid.cell(x, y, z), (x ~= c.x or y ~= c.y or z ~= c.z)
    end

    local function blockCapacity()
        local tier = Island:GetAttribute("ExpansionTier") or 0
        local exp = Config.Build.Expansion and Config.Build.Expansion[tier + 1]
        return (exp and exp.blockCapacity) or Config.Build.MaxPlacedBlocks
    end

    local usedBlocks = 0
    S.occupiedCells = 0
    S.occupancyVersion = 0
    local function setOccupant(k, id)
        local old = S.occ[k]
        if old == id then return end
        if old and Config.Build.Blocks[old] then usedBlocks -= 1 end
        if id and Config.Build.Blocks[id] then usedBlocks += 1 end
        if old == nil then S.occupiedCells += 1 elseif id == nil then S.occupiedCells -= 1 end
        S.occ[k] = id
        S.occupancyVersion += 1
    end

    local function capacityInfo()
        return blockCapacity(), usedBlocks
    end

    -- refreshSoon is defined in Executor.lua and published as B.refreshSoon.
    local function indexPart(inst)
        local k = inst:GetAttribute("CellKey")
        if k then
            setOccupant(k, inst:GetAttribute("BlockId") or inst.Name)
            if inst:IsA("BasePart") then S.parts[k] = inst end
            return true
        end
        local fk = inst:GetAttribute("FlowerCell")          -- planted flowers: the cell is taken, but it is not a block
        if fk then
            setOccupant(fk, inst:GetAttribute("FlowerId") or "Flower")
            return true
        end
    end
    -- Safety net if a later Builder module fails to load (Builder/Tabs' unload also disconnects these).
    State.OnCleanup(function()
        S.unloaded, S.cancel = true, true
        for _, c in ipairs(S.conns) do pcall(function() c:Disconnect() end) end
        S.conns = {}
    end)
    for _, d in ipairs(Island:GetDescendants()) do indexPart(d) end
    track(Island.DescendantAdded:Connect(function(d)
        task.defer(function()
            if not S.unloaded and d:IsDescendantOf(Island) and indexPart(d) and B.refreshSoon then B.refreshSoon() end
        end)
    end))
    track(Island.DescendantRemoving:Connect(function(d)
        local k = d:GetAttribute("CellKey") or d:GetAttribute("FlowerCell")
        if k and S.occ[k] then setOccupant(k, nil) S.parts[k] = nil if B.refreshSoon then B.refreshSoon() end end
    end))

    track(Island:GetAttributeChangedSignal("ExpansionTier"):Connect(function()
        S.occupancyVersion += 1
        if B.refreshSoon then B.refreshSoon() end
    end))

    local function layerUnderPlayer()
        local r = hrp()
        if not r then return nil end
        local rp = RaycastParams.new()
        rp.FilterType = Enum.RaycastFilterType.Include
        rp.FilterDescendantsInstances = { Island }
        local hit = workspace:Raycast(r.Position, Vector3.new(0, -800, 0), rp)
        if hit then
            local inst = hit.Instance
            while inst and inst ~= Island and not inst:GetAttribute("CellKey") do inst = inst.Parent end
            local k = inst and inst:GetAttribute("CellKey")
            local c = k and Grid.fromKey(k)
            if c then return c.y, Grid.worldToCell(origin(), r.Position) end
            local c2 = Grid.worldToCell(origin(), hit.Position - hit.Normal * (CS / 2))
            return c2.y, Grid.worldToCell(origin(), r.Position)
        end
        return Config.Build.IslandTopCellY or -1, Grid.worldToCell(origin(), r.Position)
    end

    ------------------------------------------------------------------------------------------
    -- Inventory / hotbar
    ------------------------------------------------------------------------------------------
    local function buildState()
        local ok, ups = pcall(getups, BuildCtl.setSelectedBlock)
        if ok and ups then
            for _, v in pairs(ups) do
                if type(v) == "table" and (v.flipped ~= nil or v.tilted ~= nil or v.available ~= nil) then return v end
            end
        end
    end

    local function isCounts(t)
        if type(t) ~= "table" or next(t) == nil then return false end
        for k, v in pairs(t) do
            if type(k) ~= "string" or type(v) ~= "number" then return false end
        end
        return true
    end

    local function inventory()
        local counts
        for _, fn in ipairs({ Hotbar.itemAt, Hotbar.selected, Hotbar.isOnBar }) do
            local ok, ups = pcall(getups, fn)
            if ok and ups then
                for _, v in pairs(ups) do if isCounts(v) then counts = v break end end
            end
            if counts then break end
        end
        local byId = {}
        for k, n in pairs(counts or {}) do
            local id = StackKey.item(k)
            byId[id] = (byId[id] or 0) + n
        end
        return byId
    end

    local function niceName(id) return (id:gsub("(%l)(%u)", "%1 %2")) end

    local function ensureHeld(id)
        local st = buildState()
        if not st then return false end
        if st.selectedBlockId == id and (st.available or 0) > 0 then return true end
        local slot
        for i = 1, (Hotbar.TotalSlots or 9) do
            local ok, it = pcall(Hotbar.itemAt, i)
            if ok and it == id then slot = i break end
        end
        if not slot then
            slot = Hotbar.FirstFreeSlot or 4
            if not S.savedSlot then
                local ok, prev = pcall(Hotbar.itemAt, slot)
                S.savedSlot = { slot = slot, prev = ok and prev or nil }
            end
            pcall(Hotbar.assign, slot, id)
        end
        pcall(Hotbar.select, slot)
        local t0 = os.clock()
        while os.clock() - t0 < 1.2 do
            if st.selectedBlockId == id and (st.available or 0) > 0 then task.wait(0.1) return true end
            task.wait(0.05)
        end
        return false
    end

    -- pickaxe on the hotbar (used by Break mode)
    local function findPickaxe()
        for i = 1, (Hotbar.TotalSlots or 9) do
            local ok, it = pcall(Hotbar.itemAt, i)
            local def = ok and it and Config.Tool.Tools[it]
            if def and def.class == "Pickaxe" then return i, it end
        end
    end

    local function restoreHotbar()
        if S.savedSlot and S.savedSlot.prev then pcall(Hotbar.assign, S.savedSlot.slot, S.savedSlot.prev) end
        S.savedSlot = nil
    end

    -- exports -------------------------------------------------------------------------------
    B.LP, B.Shared, B.Config, B.Grid, B.StackKey, B.Ctl, B.Hotbar, B.BuildCtl = LP, Shared, Config, Grid, StackKey, Ctl, Hotbar, BuildCtl
    B.Remotes, B.PlaceRemote, B.ResultRemote, B.SwingRemote = Remotes, PlaceRemote, ResultRemote, SwingRemote
    B.getups, B.CS, B.Placement, B.PLACE_REACH, B.BREAK_REACH = getups, CS, Placement, PLACE_REACH, BREAK_REACH
    B.Options, B.Toggles = Options, Toggles
    B.S, B.track, B.notify = S, track, notify
    B.Island = Island
    B.origin, B.islandBounds, B.hrp, B.protected, B.key = origin, islandBounds, hrp, protected, key
    B.setOccupant, B.blockCapacity = setOccupant, blockCapacity
    B.clampCell, B.capacityInfo, B.indexPart, B.layerUnderPlayer = clampCell, capacityInfo, indexPart, layerUnderPlayer
    B.buildState, B.isCounts, B.inventory, B.niceName = buildState, isCounts, inventory, niceName
    B.ensureHeld, B.findPickaxe, B.restoreHotbar = ensureHeld, findPickaxe, restoreHotbar
    B.refreshSoon = nil
    return B
end
