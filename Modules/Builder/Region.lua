--[[
    Modules/Builder/Region.lua  -  region (Pos 1 / Pos 2), selection box, editor sliders, player-position pick.
    Source: Script2 lines 250-361 (verbatim; regionLabel / syncing / refreshSoon read through B).
]]

return function(State)
    local B = State.Builder
    local S, Grid, CS = B.S, B.Grid, B.CS
    local Options = B.Options
    local origin, islandBounds, clampCell, layerUnderPlayer, notify = B.origin, B.islandBounds, B.clampCell, B.layerUnderPlayer, B.notify

    ------------------------------------------------------------------------------------------
    -- Region (base corner + size) and selection box
    ------------------------------------------------------------------------------------------
    local function boxOf(a, b)
        return Vector3.new(math.min(a.x, b.x), math.min(a.y, b.y), math.min(a.z, b.z)),
               Vector3.new(math.max(a.x, b.x), math.max(a.y, b.y), math.max(a.z, b.z))
    end

    local selPart = Instance.new("Part")
    selPart.Name = "ABOVE_SelectionBox"
    selPart.Anchored, selPart.CanCollide, selPart.CanQuery, selPart.CanTouch = true, false, false, false
    selPart.Transparency = 1
    selPart.Parent = workspace
    local selBox = Instance.new("SelectionBox")
    selBox.Adornee = selPart
    selBox.LineThickness = 0.06
    selBox.Color3 = Color3.fromRGB(90, 220, 120)
    selBox.SurfaceColor3 = Color3.fromRGB(90, 220, 120)
    selBox.SurfaceTransparency = 0.85
    selBox.Visible = false
    selBox.Parent = selPart
    -- Safety net if a later Builder module fails to load (Builder/Tabs' unload also destroys it).
    State.OnCleanup(function() pcall(function() selPart:Destroy() end) end)

    local function updateSelection()
        if S.pos1 and S.pos2 then
            local lo, hi = boxOf(S.pos1, S.pos2)
            local o = origin()
            local a = Grid.cellToWorld(o, Grid.cell(lo.X, lo.Y, lo.Z)) - Vector3.one * (CS / 2)
            local b = Grid.cellToWorld(o, Grid.cell(hi.X, hi.Y, hi.Z)) + Vector3.one * (CS / 2)
            selPart.Size = b - a
            selPart.Position = (a + b) / 2
            selBox.Visible = true
        else
            selBox.Visible = false
        end
    end

    B.regionLabel = nil
    B.syncing = false
    local function updateRegionLabel()
        if not B.regionLabel then return end
        local a = S.pos1 and ("(%d,%d,%d)"):format(S.pos1.x, S.pos1.y, S.pos1.z) or "unset"
        local b = S.pos2 and ("(%d,%d,%d)"):format(S.pos2.x, S.pos2.y, S.pos2.z) or "unset"
        local extra = ""
        if S.pos1 and S.pos2 then
            local lo, hi = boxOf(S.pos1, S.pos2)
            extra = ("  [%dx%dx%d = %d cells]"):format(hi.X - lo.X + 1, hi.Y - lo.Y + 1, hi.Z - lo.Z + 1,
                (hi.X - lo.X + 1) * (hi.Y - lo.Y + 1) * (hi.Z - lo.Z + 1))
        end
        local bnd = islandBounds()
        local limit = ("\nWorld limit: X/Z +-%d, Y %d..%d"):format(bnd.horizontal, -bnd.below, bnd.above)
        pcall(function() B.regionLabel:SetText(("Pos 1: %s\nPos 2: %s%s%s"):format(a, b, extra, limit)) end)
    end

    -- push the current pos1/pos2 into the editor sliders (without re-triggering them)
    local function syncSliders()
        if not (S.pos1 and S.pos2 and Options.SizeX) then return end
        local lo, hi = boxOf(S.pos1, S.pos2)
        B.syncing = true
        pcall(function()
            Options.SizeX:SetValue(hi.X - lo.X + 1)
            Options.SizeY:SetValue(hi.Y - lo.Y + 1)
            Options.SizeZ:SetValue(hi.Z - lo.Z + 1)
            local centred = Options.Anchor.Value == "Center"
            Options.BaseX:SetValue(centred and math.floor((lo.X + hi.X) / 2) or lo.X)
            Options.BaseY:SetValue(centred and math.floor((lo.Y + hi.Y) / 2) or lo.Y)
            Options.BaseZ:SetValue(centred and math.floor((lo.Z + hi.Z) / 2) or lo.Z)
        end)
        B.syncing = false
    end

    local function setRegion(a, b)
        local clipped = false
        if a then local c; a, c = clampCell(a); clipped = clipped or c end
        if b then local c; b, c = clampCell(b); clipped = clipped or c end
        S.pos1, S.pos2 = a, b
        if clipped then notify("Region trimmed to the world limit.") end
        updateRegionLabel() updateSelection() syncSliders()
        if B.refreshSoon then B.refreshSoon() end
    end

    -- rebuild pos1/pos2 from the editor sliders
    local function applySliders()
        if B.syncing then return end
        local sx, sy, sz = Options.SizeX.Value, Options.SizeY.Value, Options.SizeZ.Value
        local bx, by, bz = Options.BaseX.Value, Options.BaseY.Value, Options.BaseZ.Value
        local lx, ly, lz = bx, by, bz
        if Options.Anchor.Value == "Center" then
            lx, ly, lz = bx - math.floor((sx - 1) / 2), by - math.floor((sy - 1) / 2), bz - math.floor((sz - 1) / 2)
        end
        local p1, c1 = clampCell(Grid.cell(lx, ly, lz))
        local p2, c2 = clampCell(Grid.cell(lx + sx - 1, ly + sy - 1, lz + sz - 1))
        S.pos1, S.pos2 = p1, p2
        updateRegionLabel() updateSelection()
        if c1 or c2 then syncSliders() end            -- sliders snap back to what actually fits
        if B.refreshSoon then B.refreshSoon() end
    end

    -- Pick the player's grid column at the supporting layer under their feet.
    local function pickCell()
        local y, pc = layerUnderPlayer()
        if y and pc then return Grid.cell(pc.x, y, pc.z) end
    end

    B.boxOf, B.selPart, B.selBox = boxOf, selPart, selBox
    B.updateSelection, B.updateRegionLabel, B.syncSliders = updateSelection, updateRegionLabel, syncSliders
    B.setRegion, B.applySliders, B.pickCell = setRegion, applySliders, pickCell
    return true
end
