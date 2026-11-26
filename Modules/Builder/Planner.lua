--[[
    Modules/Builder/Planner.lua  -  line ordering, fill / 4-strip / checkerboard / paste / break planners,
    strip geometry (STRIP, shared with the Pollinator) and the divider guide boxes.
    Source: Script2 lines 363-914 (verbatim).
]]

return function(State)
    local B = State.Builder
    local S, Grid, Config, Island, CS = B.S, B.Grid, B.Config, B.Island, B.CS
    local Options, Toggles = B.Options, B.Toggles
    local key, clampCell, islandBounds, protected, origin = B.key, B.clampCell, B.islandBounds, B.protected, B.origin
    local layerUnderPlayer, capacityInfo, inventory, niceName, hrp = B.layerUnderPlayer, B.capacityInfo, B.inventory, B.niceName, B.hrp
    local boxOf = B.boxOf

    -- Build and Planter are separate tabs with their own Start button. B.context says which one is
    -- planning ("build" uses the Build tab's Mode dropdown, "plant" is always the Checkerboard Planter).
    B.context = "build"
    function B.currentMode(context)
        context = context or B.context
        if context == "plant" then return "Checkerboard Planter" end
        if context == "schematic" then return "Schematic Paste" end
        return Options.Mode.Value
    end

    ------------------------------------------------------------------------------------------
    -- Line ordering: work one full line at a time (X, Z or vertical Y), step to the next line, optionally
    -- zigzagging. Direction follows Pos 1 -> Pos 2. With `sim` (placing) a cell is only emitted once it has an
    -- adjacent block, sweeping the lines again for whatever was unsupported.
    ------------------------------------------------------------------------------------------
    local function neighbourOccupied(occ, x, y, z)
        for dx = -1, 1 do for dy = -1, 1 do for dz = -1, 1 do
            if not (dx == 0 and dy == 0 and dz == 0) and occ[key(x + dx, y + dy, z + dz)] then return true end
        end end end
        return false
    end

    local function lineOrder(entries, sim, opt, usePasteOrder)
        -- direction of travel follows Pos 1 -> Pos 2 (ascending when there is no explicit region)
        local sign = { x = 1, y = 1, z = 1 }
        if not usePasteOrder and not Toggles.AutoLayer.Value and S.pos1 and S.pos2 then
            sign.x = S.pos2.x >= S.pos1.x and 1 or -1
            sign.y = S.pos2.y >= S.pos1.y and 1 or -1
            sign.z = S.pos2.z >= S.pos1.z and 1 or -1
        end
        local axis = Options.LineAxis.Value
        if opt then axis, sign = opt.axis, opt.sign end        -- planter zones choose their own start side
        local P, Sd, T
        if axis == "Along X" then P, Sd, T = "x", "z", "y"
        elseif axis == "Along Z" then P, Sd, T = "z", "x", "y"
        else P, Sd, T = "y", "x", "z" end            -- vertical columns
        local function k(e, a) return e.cell[a] * sign[a] end
        table.sort(entries, function(a, b)
            local ta, tb = k(a, T), k(b, T)
            if ta ~= tb then return ta < tb end
            local sa, sb = k(a, Sd), k(b, Sd)
            if sa ~= sb then return sa < sb end
            return k(a, P) < k(b, P)
        end)
        local lines, cur, curKey = {}, nil, nil
        for _, e in ipairs(entries) do
            local lk = k(e, T) .. ":" .. k(e, Sd)
            if lk ~= curKey then cur = {} lines[#lines + 1] = cur curKey = lk end
            cur[#cur + 1] = e
        end
        local ordered = {}
        for i, line in ipairs(lines) do
            local rev = Toggles.Zigzag.Value and i % 2 == 0
            local n = #line
            for j = 1, n do
                local e = rev and line[n - j + 1] or line[j]
                e.line, e.dirAxis, e.dirSign = i, P, (rev and -1 or 1) * sign[P]
                ordered[#ordered + 1] = e
            end
        end
        if not sim then return ordered, 0, #lines end
        -- placement needs an adjacent block: sweep the lines repeatedly, emitting whatever has support
        local out, rest = {}, ordered
        repeat
            local progress, nextRest = false, {}
            for _, e in ipairs(rest) do
                local c = e.cell
                if neighbourOccupied(sim, c.x, c.y, c.z) then
                    sim[e.key] = e.id
                    out[#out + 1] = e
                    progress = true
                else
                    nextRest[#nextRest + 1] = e
                end
            end
            rest = nextRest
        until not progress or #rest == 0
        return out, #rest, #lines
    end

    ------------------------------------------------------------------------------------------
    -- Planners.  plan = { {cell=, id=, yaw=, key=, center=, kind=}, ... } or nil, message
    ------------------------------------------------------------------------------------------
    local function region(forPlanting)
        if Toggles.AutoLayer.Value then
            local y = layerUnderPlayer()
            if not y then return nil, "No character." end
            local h = islandBounds().horizontal
            local layerY = forPlanting and (y + 1) or y
            return Vector3.new(-h, layerY, -h), Vector3.new(h, layerY, h), true
        end
        if not (S.pos1 and S.pos2) then return nil, "Set a region (Pos 1/Pos 2, the editor sliders, or enable Auto-Detect Island Layer)." end
        local lo, hi = boxOf(S.pos1, S.pos2)
        if forPlanting and Toggles.PlantOnTop.Value then
            lo = Vector3.new(lo.X, hi.Y + 1, lo.Z)
            hi = Vector3.new(hi.X, hi.Y + 1, hi.Z)
        end
        local cl = clampCell(Grid.cell(lo.X, lo.Y, lo.Z))
        local ch = clampCell(Grid.cell(hi.X, hi.Y, hi.Z))
        lo, hi = Vector3.new(cl.x, cl.y, cl.z), Vector3.new(ch.x, ch.y, ch.z)
        local vol = (hi.X - lo.X + 1) * (hi.Y - lo.Y + 1) * (hi.Z - lo.Z + 1)
        if vol > 250000 then return nil, ("Region is %d cells - shrink it (limit 250,000 to plan)."):format(vol) end
        return lo, hi, false
    end

    local function copyOcc()
        local sim = {}
        for k, v in pairs(S.occ) do sim[k] = v end
        return sim
    end

    -- keep only as many new blocks as the island can still hold
    local function trimToCapacity(plan)
        local cap, used = capacityInfo()
        local room = math.max(cap - used, 0)
        if #plan <= room then return plan, nil end
        local trimmed = {}
        for i = 1, room do trimmed[i] = plan[i] end
        return trimmed, ("Block capacity %d/%d: only %d more blocks fit, the rest are ignored."):format(used, cap, room)
    end

    local function planFill()
        local id = Options.BlockPick.Value
        if not id or id == "" then return nil, "Pick a block to fill with." end
        local lo, hi = region(false)
        if not lo then return nil, hi end
        local b = islandBounds()
        local list = {}
        for x = lo.X, hi.X do for y = lo.Y, hi.Y do for z = lo.Z, hi.Z do
            local k = key(x, y, z)
            if not S.occ[k] then
                local cell = Grid.cell(x, y, z)
                if Grid.isInBounds(cell, b) and not protected(cell) then
                    list[#list + 1] = { cell = cell, id = id, yaw = 0, key = k, kind = "place" }
                end
            end
        end end end
        local out, left = lineOrder(list, copyOcc())
        local capNote
        out, capNote = trimToCapacity(out)
        local note = (left and left > 0) and (left .. " cells have no adjacent block and were skipped.") or nil
        return out, capNote or note
    end

    ------------------------------------------------------------------------------------------
    -- 4-strip farm: a floor layer plus 3 single-block dividers on the flower layer (floorY + 1).
    -- The split axis is cut into 4 equal strips separated by 3 one-cell dividers.  Leftover cells (if the width
    -- is not 4*w+3) are ignored at the high end.  In Auto mode the footprint is kept 11 cells inside the island
    -- rim (127-wide island -> 116, adjusted so that (side - 3) % 4 == 0 -> 115) so it never reaches the edge.
    ------------------------------------------------------------------------------------------
    local STRIP = {}

    local function stripGeometry()
        local splitX = Options.StripAxis.Value ~= "Split along Z"
        local bnd = islandBounds()
        local tier = Island:GetAttribute("ExpansionTier") or 0
        local edge = 2 * bnd.horizontal + 1                                  -- full edge-to-edge width for this tier
        local cap = B.blockCapacity()                                           -- block capacity for this tier
        local x0, x1, z0, z1, floorY
        if Toggles.AutoLayer.Value then
            local y = layerUnderPlayer()
            if not y then return nil, "No character." end
            -- largest centred square that fits BOTH limits: the island edge, and floor + 3 divider lines within
            -- (capacity - 250) so there is room left for chests / vending machines; and (side - 3) % 4 == 0 so the
            -- 4 strips come out the same integer width.
            local budget = cap - 250
            local side = edge
            while side > 7 and (side * side + 3 * side > budget or (side - 3) % 4 ~= 0) do side -= 1 end
            x0 = -math.floor(side / 2)
            x1 = x0 + side - 1
            z0, z1, floorY = x0, x1, y
        else
            if not (S.pos1 and S.pos2) then
                return nil, "Set a region (Pos 1/Pos 2 or the editor sliders), or enable Auto-Detect Island Layer."
            end
            local lo, hi = boxOf(S.pos1, S.pos2)
            local a = clampCell(Grid.cell(lo.X, lo.Y, lo.Z))
            local b = clampCell(Grid.cell(hi.X, hi.Y, hi.Z))
            x0, x1, z0, z1, floorY = a.x, b.x, a.z, b.z, a.y
        end
        local c0, c1 = splitX and x0 or z0, splitX and x1 or z1
        local n = c1 - c0 + 1
        if n < 7 then return nil, ("Only %d cells along the split axis - the 4-strip layout needs at least 7."):format(n) end
        local w = math.floor((n - 3) / 4)
        local used = 4 * w + 3
        local strips, dividers = {}, {}
        local c = c0
        for i = 1, 4 do
            strips[i] = { c, c + w - 1 }
            c += w
            if i < 4 then dividers[i] = c c += 1 end
        end
        if splitX then x1 = c0 + used - 1 else z1 = c0 + used - 1 end        -- drop the leftover cells
        local fx, fz = x1 - x0 + 1, z1 - z0 + 1
        return { splitX = splitX, floorY = floorY, w = w, strips = strips, dividers = dividers,
            leftover = n - used, x0 = x0, x1 = x1, z0 = z0, z1 = z1,
            tier = tier, edge = edge, cap = cap, floorCells = fx * fz, divCells = 3 * (splitX and fz or fx) }
    end

    local function stripSummary(g)
        return ("Tier %d island: %d x %d cells | footprint %d x %d | 4 strips x %d wide | dividers at %s = %d, %d, %d%s\nBlocks: floor %d + dividers %d = %d / %d cap (250 kept spare in Auto)"):format(
            g.tier, g.edge, g.edge, g.x1 - g.x0 + 1, g.z1 - g.z0 + 1, g.w, g.splitX and "X" or "Z",
            g.dividers[1], g.dividers[2], g.dividers[3],
            g.leftover > 0 and (" | %d leftover cells ignored"):format(g.leftover) or "",
            g.floorCells, g.divCells, g.floorCells + g.divCells, g.cap)
    end

    -- helpers shared with the Pollinator ------------------------------------------------------------------
    function STRIP.solid(k)                                                 -- a placed block (not a flower) at this cell?
        local id = S.occ[k]
        return id ~= nil and Config.Build.Blocks[id] ~= nil
    end

    function STRIP.indexOf(g, cell)                                         -- 1..4 for a flower-layer cell inside a strip, else 0
        if cell.y ~= g.floorY + 1 then return 0 end
        local coord = g.splitX and cell.x or cell.z
        local other = g.splitX and cell.z or cell.x
        local o0, o1 = g.splitX and g.z0 or g.x0, g.splitX and g.z1 or g.x1
        if other < o0 or other > o1 then return 0 end
        for i = 1, 4 do
            local r = g.strips[i]
            if coord >= r[1] and coord <= r[2] then return i end
        end
        return 0
    end

    function STRIP.blockedBetween(a, b)                                     -- any placed block strictly between two cells?
        local x0, x1 = math.min(a.x, b.x), math.max(a.x, b.x)
        local z0, z1 = math.min(a.z, b.z), math.max(a.z, b.z)
        for x = x0, x1 do
            for z = z0, z1 do
                if not ((x == a.x and z == a.z) or (x == b.x and z == b.z)) and STRIP.solid(key(x, a.y, z)) then
                    return true
                end
            end
        end
        return false
    end

    function STRIP.active(g)                                                -- are the stone dividers really built?
        local fy, n, total = g.floorY + 1, 0, 0
        for _, d in ipairs(g.dividers) do
            for o = (g.splitX and g.z0 or g.x0), (g.splitX and g.z1 or g.x1) do
                total += 1
                if STRIP.solid(g.splitX and key(d, fy, o) or key(o, fy, d)) then n += 1 end
            end
        end
        return total > 0 and n >= total * 0.2
    end

    function STRIP.current()                                                -- geometry, but only if dividers exist
        local ok, g = pcall(stripGeometry)
        if ok and g and STRIP.active(g) then return g end
        return nil
    end

    local function planStripBase()
        local g, err = stripGeometry()
        if not g then return nil, err end
        local fillId, divId = Options.BlockPick.Value, Options.DividerBlock.Value
        if not fillId or fillId == "" then return nil, "Pick a Fill block." end
        if not divId or divId == "" then return nil, "Pick a divider block." end
        local b = islandBounds()
        local isDiv = {}
        for _, d in ipairs(g.dividers) do isDiv[d] = true end
        local floorList, divList = {}, {}
        for x = g.x0, g.x1 do for z = g.z0, g.z1 do
            local kf = key(x, g.floorY, z)
            local cf = Grid.cell(x, g.floorY, z)
            if not S.occ[kf] and Grid.isInBounds(cf, b) and not protected(cf) then
                floorList[#floorList + 1] = { cell = cf, id = fillId, yaw = 0, key = kf, kind = "place" }
            end
            if isDiv[g.splitX and x or z] then
                local kd = key(x, g.floorY + 1, z)
                local cd = Grid.cell(x, g.floorY + 1, z)
                if not S.occ[kd] and Grid.isInBounds(cd, b) and not protected(cd) then
                    divList[#divList + 1] = { cell = cd, id = divId, yaw = 0, key = kd, kind = "place" }
                end
            end
        end end
        local sim = copyOcc()
        local floorPlan, leftF = lineOrder(floorList, sim)                 -- layer 1 first
        local divPlan, leftD = lineOrder(divList, sim)                     -- dividers then sit on the finished floor
        local plan = {}
        for _, e in ipairs(floorPlan) do plan[#plan + 1] = e end
        for _, e in ipairs(divPlan) do plan[#plan + 1] = e end
        local capNote
        plan, capNote = trimToCapacity(plan)
        local notes = { stripSummary(g),
            ("Layer 1: %d x %s  |  Layer 2: %d x %s (3 divider lines)"):format(#floorPlan, niceName(fillId), #divPlan, niceName(divId)) }
        if (leftF or 0) + (leftD or 0) > 0 then notes[#notes + 1] = ((leftF or 0) + (leftD or 0)) .. " cells have no adjacent block and were skipped." end
        if capNote then notes[#notes + 1] = capNote end
        return plan, table.concat(notes, "\n")
    end

    -- thin guide bars over the 3 divider columns so the strip boundaries can be checked before pressing Start
    local guideFolder
    local function clearGuides()
        if guideFolder then pcall(function() guideFolder:Destroy() end) guideFolder = nil end
    end

    local STRIP_MODE = "Four strips"
    local function updateGuides()
        -- Guides show when either tab uses the 4-strip layout (both tabs are visible as separate tabs now).
        local active = Options.Mode.Value == "4-Strip Farm Base"
            or Options.PlantLayout.Value == STRIP_MODE
        local g = active and stripGeometry()
        if not g then
            clearGuides()
            return
        end
        if not guideFolder then
            guideFolder = Instance.new("Folder")
            guideFolder.Name = "ABOVE_StripGuides"
            guideFolder.Parent = workspace
        end
        local o = origin()
        for i, d in ipairs(g.dividers) do
            local lo = g.splitX and Grid.cell(d, g.floorY + 1, g.z0) or Grid.cell(g.x0, g.floorY + 1, d)
            local hi = g.splitX and Grid.cell(d, g.floorY + 1, g.z1) or Grid.cell(g.x1, g.floorY + 1, d)
            local a = Grid.cellToWorld(o, lo) - Vector3.one * (CS / 2)
            local b = Grid.cellToWorld(o, hi) + Vector3.one * (CS / 2)
            local part = guideFolder:FindFirstChild("Divider" .. i)
            if not part then
                part = Instance.new("Part")
                part.Name = "Divider" .. i
                part.Anchored, part.CanCollide, part.CanQuery, part.CanTouch = true, false, false, false
                part.Transparency = 1
                part.Parent = guideFolder
                local box = Instance.new("SelectionBox")
                box.Adornee = part
                box.LineThickness = 0.03
                box.Color3 = Color3.fromRGB(255, 170, 60)
                box.SurfaceColor3 = Color3.fromRGB(255, 170, 60)
                box.SurfaceTransparency = 0.88
                box.Parent = part
            end
            local size, position = b - a, (a + b) / 2
            if part.Size ~= size then part.Size = size end
            if part.Position ~= position then part.Position = position end
        end
    end
    -- Safety net if a later Builder module fails to load (Builder/Tabs' unload also clears it).
    State.OnCleanup(function() pcall(clearGuides) end)

    -- Every item of the same TYPE as `id`: same species + colour, same glowing state (Plain / Dotted / Striped
    -- count as one type, Glowing is its own).  The flower you picked comes first.
    local function variantIds(id)
        local def = Config.Flower.Flowers[id]
        if not def or not Toggles.PlantVariants.Value then return { id } end
        local glow = type(def.pattern) == "string" and def.pattern:find("Glow") ~= nil
        local rest = {}
        for fid, d in pairs(Config.Flower.Flowers) do
            if fid ~= id and d.species == def.species and d.color == def.color
                and ((type(d.pattern) == "string" and d.pattern:find("Glow") ~= nil) == glow) then
                rest[#rest + 1] = fid
            end
        end
        table.sort(rest)
        local out = { id }
        for _, fid in ipairs(rest) do out[#out + 1] = fid end
        return out
    end

    local STRIP_SKIP = "None / Skip"

    local function planPlantStrips()
        local g, err = stripGeometry()
        if not g then return nil, err end
        local parity = Options.Parity.Value == "Odd" and 1 or 0
        local b = islandBounds()
        local flowerY = g.floorY + 1                                         -- same layer as the stone dividers
        local stock = {}
        for id, n in pairs(inventory()) do stock[id] = n end
        local plan, used, notes, any = {}, {}, { stripSummary(g) }, false
        for s = 1, 4 do
            local flower = Options["Strip" .. s].Value
            if flower and flower ~= "" and flower ~= STRIP_SKIP then
                any = true
                local cells = {}
                local r = g.strips[s]
                local function consider(x, z)
                    if (x + z) % 2 == parity and not S.occ[key(x, flowerY, z)] then
                        local supported = (not Toggles.RequireSupport.Value) or S.occ[key(x, flowerY - 1, z)]
                        local cell = Grid.cell(x, flowerY, z)
                        if supported and Grid.isInBounds(cell, b) and not protected(cell) then
                            cells[#cells + 1] = { zone = tostring(s), cell = cell, id = flower, yaw = 0, key = key(x, flowerY, z), kind = "place" }
                        end
                    end
                end
                if g.splitX then
                    for x = r[1], r[2] do for z = g.z0, g.z1 do consider(x, z) end end
                else
                    for z = r[1], r[2] do for x = g.x0, g.x1 do consider(x, z) end end
                end
                notes[#notes + 1] = ("Strip %d (%d..%d): %s - %d cells"):format(s, r[1], r[2], niceName(flower), #cells)
                local ids = variantIds(flower)
                local k = 1
                for _, e in ipairs((lineOrder(cells, nil))) do               -- one flower type at a time, strip by strip
                    while ids[k] and (stock[ids[k]] or 0) <= 0 do k += 1 end
                    local id = ids[k] or flower
                    if ids[k] then stock[id] -= 1 end
                    e.id = id
                    used[id] = (used[id] or 0) + 1
                    plan[#plan + 1] = e
                end
            else
                notes[#notes + 1] = ("Strip %d: skipped"):format(s)
            end
        end
        if not any then return nil, "Pick a flower for at least one strip." end
        local parts = {}
        for id, n in pairs(used) do parts[#parts + 1] = ("%s x%d"):format(niceName(id), n) end
        table.sort(parts)
        if #parts > 0 then notes[#notes + 1] = "Items: " .. table.concat(parts, ", ") end
        return plan, table.concat(notes, "\n")
    end

    local function planPlant()
        if Options.PlantLayout.Value == STRIP_MODE then return planPlantStrips() end
        local lo, hi = region(true)
        if not lo then return nil, hi end
        local fa, fb = Options.FlowerA.Value, Options.FlowerB.Value
        if not fa or fa == "" then return nil, "Pick Flower A." end
        local axis = Options.PlantLayout.Value == "One flower" and "A only" or Options.SplitAxis.Value
        if axis ~= "Row (Z)" and axis ~= "Column (X)" then axis = "A only" end      -- also covers an old saved "None"
        local parity = Options.Parity.Value == "Odd" and 1 or 0
        if axis ~= "A only" and (not fb or fb == "") then return nil, "Pick Flower B for the second zone." end
        local b = islandBounds()

        -- two-sided layout: A owns one end of the split axis, B the opposite end, a gap band sits in the middle
        local c0, c1, gapLo, gapHi
        if axis ~= "A only" then
            c0 = axis == "Row (Z)" and lo.Z or lo.X
            c1 = axis == "Row (Z)" and hi.Z or hi.X
            local n = c1 - c0 + 1
            local gap = math.min(math.round(Options.GapWidth.Value), n)
            local side = math.floor((n - gap) / 2)                 -- cells each flower may use from its own end
            gapLo, gapHi = c0 + side, c1 - side                    -- everything in between stays empty
        end
        local aLow = not Toggles.FlipZones.Value                   -- A at the low end unless flipped

        local zones = {}
        for x = lo.X, hi.X do for y = lo.Y, hi.Y do for z = lo.Z, hi.Z do
            if (x + z) % 2 == parity and not S.occ[key(x, y, z)] then
                local supported = (not Toggles.RequireSupport.Value) or S.occ[key(x, y - 1, z)]
                local cell = Grid.cell(x, y, z)
                if supported and Grid.isInBounds(cell, b) and not protected(cell) then
                    local zone, skip = "A", false
                    if axis ~= "A only" then
                        local coord = axis == "Row (Z)" and z or x
                        if coord >= gapLo and coord <= gapHi then skip = true       -- the empty middle band
                        elseif coord < gapLo then zone = aLow and "A" or "B"
                        else zone = aLow and "B" or "A" end
                    end
                    if not skip then
                        local zn = zones[zone]
                        if not zn then zn = { base = zone == "A" and fa or fb, cells = {} } zones[zone] = zn end
                        table.insert(zn.cells, { zone = zone, cell = cell, id = zn.base, yaw = 0, key = key(x, y, z), kind = "place" })
                    end
                end
            end
        end end end

        -- plant each zone starting at ITS end and working toward the middle; stock runs out before the middle
        -- is reached, which is what leaves the open area between them
        local stock = {}
        for id, n in pairs(inventory()) do stock[id] = n end
        local plan, used = {}, {}
        for _, zn in ipairs({ "A", "B" }) do
            local z = zones[zn]
            if z then
                local ids = variantIds(z.base)
                local opt
                if axis ~= "A only" then
                    local fromLow = (zn == "A") == aLow             -- does this zone start at the low end of the axis?
                    local dir = fromLow and 1 or -1
                    if axis == "Row (Z)" then opt = { axis = "Along X", sign = { x = 1, y = 1, z = dir } }
                    else opt = { axis = "Along Z", sign = { x = dir, y = 1, z = 1 } } end
                end
                local k = 1
                for _, e in ipairs((lineOrder(z.cells, nil, opt))) do
                    while ids[k] and (stock[ids[k]] or 0) <= 0 do k += 1 end
                    local id = ids[k] or z.base          -- out of everything: keep the base id so the checklist shows the shortfall
                    if ids[k] then stock[id] -= 1 end
                    e.id = id
                    used[id] = (used[id] or 0) + 1
                    plan[#plan + 1] = e
                end
            end
        end
        local parts = {}
        for id, n in pairs(used) do parts[#parts + 1] = ("%s x%d"):format(niceName(id), n) end
        table.sort(parts)
        local note = (#parts > 1) and ("Variants used: " .. table.concat(parts, ", ")) or nil
        if axis ~= "A only" then
            local mid = ("Empty middle band: %d cells wide (cells %d..%d)."):format(gapHi - gapLo + 1, gapLo, gapHi)
            note = note and (note .. "\n" .. mid) or mid
        else
            local off = "One flower: " .. niceName(fa)
            note = note and (note .. "\n" .. off) or off
        end
        return plan, note
    end

    local function rotateOffset(dx, dz, r)
        if r == 0 then return dx, dz
        elseif r == 1 then return dz, -dx
        elseif r == 2 then return -dx, -dz
        else return -dz, dx end
    end

    local anchors = {
        ["Copied corner"] = {0, 0},
        ["Center"] = {0.5, 0.5},
        ["High X corner"] = {1, 0},
        ["High Z corner"] = {0, 1},
        ["High X and Z corner"] = {1, 1},
    }

    local function pasteTransform(base)
        local size = S.clip.size
        local mirror = Options.PasteMirror.Value
        local anchor = anchors[Options.PasteAnchor.Value] or anchors["Copied corner"]
        local rotation = tonumber(Options.PasteRot.Value)
        local ax = math.floor((size[1] - 1) * anchor[1])
        local az = math.floor((size[3] - 1) * anchor[2])
        local rx, rz = rotateOffset(ax, az, rotation / 90)
        return {
            rotation = rotation, mirror = mirror, maxX = size[1] - 1, maxZ = size[3] - 1,
            origin = Grid.cell(base.x - rx, base.y, base.z - rz),
            from = Options.SwapMaterialFrom.Value, to = Options.SwapMaterialTo.Value,
        }
    end

    local function mirroredBlock(block, transform)
        local x, z, yaw = block.dx, block.dz, block.rot
        if transform.mirror == "Mirror X" then
            x, yaw = transform.maxX - x, -yaw
        elseif transform.mirror == "Mirror Z" then
            z, yaw = transform.maxZ - z, 180 - yaw
        end
        return x, z, yaw % 360
    end

    local function pasteCell(block, transform)
        local x, z, yaw = mirroredBlock(block, transform)
        x, z = rotateOffset(x, z, transform.rotation / 90)
        local base = transform.origin
        return Grid.cell(base.x + x, base.y + block.dy, base.z + z), (yaw + transform.rotation) % 360
    end

    local function pasteMaterial(block)
        local replacement = Options.SwapMaterialTo.Value
        if replacement and block.id == Options.SwapMaterialFrom.Value then return replacement end
        return block.id
    end

    local function pasteTransformKey(transform)
        return table.concat({Grid.key(transform.origin), transform.rotation, transform.mirror,
            transform.from or "", transform.to or ""}, "/")
    end

    local function playerPasteBase()
        local rp = hrp()
        if not rp then return nil, "No character." end
        local base = Grid.worldToCell(origin(), rp.Position)
        if Toggles.SnapPasteY.Value then
            local y = layerUnderPlayer()
            if y then base = Grid.cell(base.x, y + 1, base.z) end
        end
        return base
    end

    local function pasteBase()
        if Options.PastePosition and Options.PastePosition.Value == "Fixed coordinates" then
            return Grid.cell(math.round(Options.PasteX.Value), math.round(Options.PasteY.Value), math.round(Options.PasteZ.Value))
        end
        return playerPasteBase()
    end

    function B.buildRegionSummary()
        local mode = Options.Mode.Value
        local width, height, depth, source, y
        if mode == "Schematic Paste" then
            if not S.clip then return "Copy a region on Schematic to see its paste area." end
            local base, err = pasteBase()
            if not base then return err end
            local size = S.clip.size
            local transform = pasteTransform(base)
            local dx, dz = rotateOffset(size[1] - 1, size[3] - 1, transform.rotation / 90)
            local corner = transform.origin
            return ("Paste area from (%d, %d, %d) to (%d, %d, %d)"):format(
                corner.x + math.min(dx, 0), corner.y, corner.z + math.min(dz, 0),
                corner.x + math.max(dx, 0), corner.y + size[2] - 1, corner.z + math.max(dz, 0))
        elseif mode == "4-Strip Farm Base" then
            local g, err = stripGeometry()
            if not g then return err end
            width, height, depth, y = g.x1 - g.x0 + 1, 2, g.z1 - g.z0 + 1, g.floorY
            source = Toggles.AutoLayer.Value and "Auto-sized four-strip base" or "Selected four-strip base"
        else
            local lo, hi = region(false)
            if not lo then return hi end
            width, height, depth, y = hi.X - lo.X + 1, hi.Y - lo.Y + 1, hi.Z - lo.Z + 1, lo.Y
            source = Toggles.AutoLayer.Value and "Using full island layer" or "Selected region"
        end
        return ("%s at Y %d\n%d wide × %d high × %d deep"):format(source, y, width, height, depth)
    end

    local function planPaste()
        if not S.clip then return nil, "Copy a region first." end
        local base, err = pasteBase()
        if not base then return nil, err end
        local transform = pasteTransform(base)
        local b = islandBounds()
        local list, outside, occupied, reserved = {}, 0, 0, 0
        for _, blk in ipairs(S.clip.blocks) do
            local c, yaw = pasteCell(blk, transform)
            local k = Grid.key(c)
            if not Grid.isInBounds(c, b) then
                outside += 1                                   -- beyond the world limit: never sent
            elseif S.occ[k] then occupied += 1
            elseif protected(c) then reserved += 1
            else
                list[#list + 1] = { cell = c, id = pasteMaterial(blk), yaw = yaw, key = k, kind = "place" }
            end
        end
        local out, left = lineOrder(list, copyOcc(), nil, true)
        local capNote
        out, capNote = trimToCapacity(out)
        local ready = {}
        for _, entry in ipairs(out) do ready[entry.key] = true end
        B.pasteAssessment = {clip = S.clip, destination = pasteTransformKey(transform),
            version = S.occupancyVersion, ready = ready}
        local notes = {("%d copied · %d planned · %d occupied · %d unsupported"):format(#S.clip.blocks, #out, occupied, left or 0)}
        if reserved > 0 then table.insert(notes, ("%d protected"):format(reserved)) end
        if outside > 0 then table.insert(notes, ("%d outside island bounds"):format(outside)) end
        if capNote then table.insert(notes, ("%d exceed capacity"):format(#list - (left or 0) - #out)) end
        return out, table.concat(notes, "\n")
    end

    local function planBreak()
        local lo, hi = region(false)
        if not lo then return nil, hi end
        local filter = Options.BreakFilter.Value
        local list = {}
        for k, id in pairs(S.occ) do
            local part = S.parts[k]
            if part and part.Parent and Config.Build.Blocks[id] and (filter == "Any" or filter == id) then
                local c = Grid.fromKey(k)
                if c and c.x >= lo.X and c.x <= hi.X and c.y >= lo.Y and c.y <= hi.Y and c.z >= lo.Z and c.z <= hi.Z
                    and not protected(c) then
                    list[#list + 1] = { cell = Grid.cell(c.x, c.y, c.z), id = id, yaw = 0, key = k, kind = "break", part = part }
                end
            end
        end
        return (lineOrder(list, nil))
    end

    local function buildPlan(context)
        context = context or B.context
        local mode = B.currentMode(context)
        if mode == "Checkerboard Planter" then
            if context ~= "plant" then return nil, "Pick a build mode (the planter has its own tab now)." end
            return planPlant()
        elseif mode == "Fill Island Layer" then return planFill()
        elseif mode == "Break Region" then return planBreak()
        elseif mode == "4-Strip Farm Base" then return planStripBase()
        else return planPaste() end
    end

    B.neighbourOccupied, B.lineOrder, B.region, B.copyOcc, B.trimToCapacity = neighbourOccupied, lineOrder, region, copyOcc, trimToCapacity
    B.planFill, B.STRIP, B.stripGeometry, B.stripSummary, B.planStripBase = planFill, STRIP, stripGeometry, stripSummary, planStripBase
    B.clearGuides, B.updateGuides, B.variantIds = clearGuides, updateGuides, variantIds
    B.STRIP_SKIP, B.STRIP_MODE = STRIP_SKIP, STRIP_MODE
    B.pasteTransform, B.mirroredBlock, B.pasteCell = pasteTransform, mirroredBlock, pasteCell
    B.pasteMaterial, B.pasteTransformKey = pasteMaterial, pasteTransformKey
    B.pasteBase, B.playerPasteBase = pasteBase, playerPasteBase
    B.planPlantStrips, B.planPlant, B.rotateOffset, B.planPaste, B.planBreak, B.buildPlan =
        planPlantStrips, planPlant, rotateOffset, planPaste, planBreak, buildPlan
    return true
end
