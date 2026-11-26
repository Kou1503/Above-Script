-- Local schematic ghosts share the paste planner's base cell and rotation.
return function(State)
    local B = State.Builder
    local S, Grid, CS = B.S, B.Grid, B.CS
    local Options, Toggles = B.Options, B.Toggles
    local Library, Tabs = State.UI.Library, State.UI.Tabs
    local LIMIT = 1500
    local model, clipboard
    local ghosts = {}
    local previewBlocks, previousStyle, swapExample
    local clearColor = Color3.fromRGB(90, 220, 255)
    local blockedColor = Color3.fromRGB(255, 90, 90)
    local skippedColor = Color3.fromRGB(255, 181, 75)
    local neutralColor = Color3.fromRGB(190, 190, 190)
    local lastAssessment
    local lastPivot, lastVersion, lastBounds
    local lastDestination, settleAt
    local blocked = 0
    local lastText

    local function status(text)
        if B.pastePreviewLabel and lastText ~= text then
            B.pastePreviewLabel:SetText(text)
            lastText = text
        end
    end

    local function clearPreview()
        if not model then return end
        model:Destroy()
        model, clipboard, lastPivot, lastVersion, lastBounds = nil, nil, nil, nil, nil
        blocked = 0
        table.clear(ghosts)
        previewBlocks, previousStyle, swapExample = nil, nil, nil
    end

    local function clearClipboard()
        clearPreview()
        if S.clip then
            for _, block in ipairs(S.clip.previewBlocks or S.clip.blocks) do
                if block.visual then block.visual:Destroy() end
            end
        end
        B.pasteAssessment, lastAssessment = nil, nil
        S.clip = nil
    end

    local function preparePart(part)
        part.Anchored = true
        part.CanCollide, part.CanTouch, part.CanQuery = false, false, false
        part.CastShadow = false
        for name in pairs(part:GetAttributes()) do part:SetAttribute(name, nil) end
    end

    local function captureVisual(part)
        if not part or not part:IsA("BasePart") then return nil end
        local visual = part:Clone()
        if not visual then return nil end
        -- Keep only appearance children. Scripts, constraints and effects never enter the preview.
        for _, child in ipairs(visual:GetChildren()) do
            if child:IsA("DataModelMesh") or child:IsA("Decal") or child:IsA("SurfaceAppearance") then
                child:ClearAllChildren()
            else
                child:Destroy()
            end
        end
        preparePart(visual)
        return visual
    end

    -- Choose exposed blocks first, keeping the full clipboard order for the paste planner.
    local function selectPreviewBlocks(blocks)
        local occupied = {}
        for _, b in ipairs(blocks) do occupied[B.key(b.dx, b.dy, b.dz)] = true end
        local surface, interior = {}, {}
        for _, b in ipairs(blocks) do
            local x, y, z = b.dx, b.dy, b.dz
            local enclosed = occupied[B.key(x+1,y,z)] and occupied[B.key(x-1,y,z)]
                and occupied[B.key(x,y+1,z)] and occupied[B.key(x,y-1,z)]
                and occupied[B.key(x,y,z+1)] and occupied[B.key(x,y,z-1)]
            if not enclosed then
                table.insert(surface, b)
                if #surface == LIMIT then break end
            elseif #interior < LIMIT then
                table.insert(interior, b)
            end
        end
        for i = 1, math.min(#interior, LIMIT - #surface) do table.insert(surface, interior[i]) end
        return surface
    end

    local function appendGhosts(blocks, pivot, transform)
        for i = #ghosts + 1, math.min(#ghosts + 32, #blocks) do
            local block = blocks[i]
            local id = B.pasteMaterial(block)
            local visual = id == block.id and block.visual or nil
            local part
            if visual then
                part = visual:Clone()
            elseif id ~= block.id and swapExample then
                part = captureVisual(swapExample.part)
            end
            local hasAppearance = part ~= nil
            part = part or Instance.new("Part")
            preparePart(part)
            part.Name = id
            if not hasAppearance then
                part.Size = Vector3.one * CS
                if id ~= block.id then
                    local config = B.Config.Build.Blocks[id]
                    if type(config) == "table" and typeof(config.color) == "Color3" then
                        part.Color = config.color
                    else
                        part.Color = Color3.fromRGB(185, 154, 228)
                    end
                end
            end
            local x, z, yaw = B.mirroredBlock(block, transform)
            local offset = Vector3.new(x * CS, block.dy * CS, z * CS)
            if visual and block.visualOffset then
                local extra = block.visualOffset
                offset += Vector3.new(transform.mirror == "Mirror X" and -extra.X or extra.X,
                    extra.Y, transform.mirror == "Mirror Z" and -extra.Z or extra.Z)
            end
            local rotation = CFrame.Angles(0, math.rad(yaw), 0)
            if visual then
                rotation = CFrame.Angles(0, math.rad(yaw - block.rot), 0) * visual.CFrame.Rotation
            elseif hasAppearance and swapExample then
                local turn = CFrame.Angles(0, math.rad(yaw - swapExample.yaw), 0)
                rotation = turn * swapExample.part.CFrame.Rotation
                offset += turn:VectorToWorldSpace(swapExample.offset)
            end
            part.CFrame = pivot * CFrame.new(offset) * rotation
            part.Transparency = math.max(part.Transparency, 0.55)
            for _, child in ipairs(part:GetChildren()) do
                if child:IsA("Decal") then child.Transparency = math.max(child.Transparency, 0.55) end
            end
            part.Parent = model
            local box = Instance.new("SelectionBox")
            box.Adornee = part
            box.LineThickness = 0.015
            box.SurfaceTransparency = 1
            box.Parent = part
            ghosts[i] = { block = block, box = box }
        end
    end

    local function createPreview(layer, transform)
        if transform.from and transform.to and transform.from ~= transform.to then
            for key, part in pairs(S.parts) do
                if S.occ[key] == transform.to and part.Parent then
                    local cell = Grid.fromKey(key)
                    if cell then
                        swapExample = { part = part, yaw = part:GetAttribute("Rotation") or 0,
                            offset = part.Position - Grid.cellToWorld(B.origin(), cell) }
                        break
                    end
                end
            end
        end
        model = Instance.new("Model")
        model.Name = "ABOVE_SchematicPreview"
        model.WorldPivot = CFrame.identity
        local bounds = Instance.new("Part")
        bounds.Name = "PasteBounds"
        preparePart(bounds)
        bounds.Transparency = 1
        local size = S.clip.size
        bounds.Size = Vector3.new(size[1], layer and 1 or size[2], size[3]) * CS
        local centerY = layer and 2 * (layer - 1) or size[2] - 1
        bounds.CFrame = CFrame.new(Vector3.new(size[1] - 1, centerY, size[3] - 1) * (CS / 2))
        previewBlocks = S.clip.previewBlocks
        if layer then
            previewBlocks = {}
            for _, block in ipairs(S.clip.blocks) do
                if block.dy == layer - 1 then table.insert(previewBlocks, block) end
                if #previewBlocks == LIMIT then break end
            end
        end
        bounds.Parent = model
        local outline = Instance.new("SelectionBox")
        outline.Adornee = bounds
        outline.Color3 = Color3.fromRGB(90, 220, 255)
        outline.LineThickness = 0.06
        outline.SurfaceTransparency = 1
        outline.Parent = bounds
        clipboard = S.clip
        model.Parent = workspace
    end

    local function updatePreview()
        local active = Library.ActiveTab == Tabs.Schem
            or (Library.ActiveTab == Tabs.Build and Options.Mode and Options.Mode.Value == "Schematic Paste")
        if not active or not Options.PasteRot or S.running or not S.clip then
            clearPreview()
            lastDestination, settleAt = nil, nil
            if not S.clip then status("Copy a region to preview it here.") end
            return
        end
        local base, err = B.pasteBase()
        local transform = base and B.pasteTransform(base)
        local destination = transform and B.pasteTransformKey(transform) or "unavailable"
        if destination ~= lastDestination then
            lastDestination, settleAt = destination, os.clock() + 0.3
        elseif settleAt and os.clock() >= settleAt and B.refreshChecklist then
            settleAt = nil
            task.defer(B.refreshChecklist)
        end
        if not base or not Toggles.ShowPastePreview or not Toggles.ShowPastePreview.Value then
            clearPreview()
            status(err or "Preview hidden.")
            return
        end
        local layer = Toggles.PreviewSingleLayer.Value and math.min(math.round(Options.PreviewLayer.Value), S.clip.size[2]) or nil
        local style = table.concat({transform.mirror, transform.from or "", transform.to or "", layer or 0}, "/")
        if clipboard ~= S.clip or previousStyle ~= style then
            clearPreview()
            createPreview(layer, transform)
            previousStyle = style
        end
        local pivot = CFrame.new(Grid.cellToWorld(B.origin(), transform.origin))
            * CFrame.Angles(0, math.rad(transform.rotation), 0)
        local moved = lastPivot ~= pivot
        if moved then
            model:PivotTo(pivot)
            lastPivot = pivot
        end
        local bounds = B.islandBounds()
        local assessment = B.pasteAssessment
        if assessment and (assessment.clip ~= clipboard or assessment.destination ~= destination
            or assessment.version ~= S.occupancyVersion) then assessment = nil end
        local changed = assessment ~= lastAssessment or moved or lastVersion ~= S.occupancyVersion or not lastBounds
            or bounds.horizontal ~= lastBounds.horizontal or bounds.above ~= lastBounds.above or bounds.below ~= lastBounds.below
        local firstNew = #ghosts + 1
        if firstNew <= #previewBlocks then
            appendGhosts(previewBlocks, pivot, transform)
        elseif not changed then
            return
        end
        lastAssessment = assessment
        lastVersion = S.occupancyVersion
        lastBounds = {horizontal = bounds.horizontal, above = bounds.above, below = bounds.below}
        for i = changed and 1 or firstNew, #ghosts do
            local ghost = ghosts[i]
            local block = ghost.block
            local cell = B.pasteCell(block, transform)
            local invalid = not Grid.isInBounds(cell, bounds) or S.occ[Grid.key(cell)] ~= nil or B.protected(cell)
            if invalid ~= ghost.invalid then
                if invalid then blocked += 1 elseif ghost.invalid then blocked -= 1 end
                ghost.invalid = invalid
            end
            local color = neutralColor
            if invalid then color = blockedColor
            elseif assessment then color = assessment.ready[Grid.key(cell)] and clearColor or skippedColor end
            if color ~= ghost.color then ghost.box.Color3 = color ghost.color = color end
        end
        local text = ("%d copied blocks at (%d, %d, %d). Blue: planned. Amber: unsupported or over capacity. Red: blocked. Gray: checking."):format(
            #S.clip.blocks, base.x, base.y, base.z)
        if layer then
            text ..= ("\nLayer %d of %d · %d ghosts shown."):format(layer, S.clip.size[2], #ghosts)
        elseif #ghosts < #S.clip.blocks then
            text ..= ("\nShowing %d blocks and the full bounding box."):format(#ghosts)
        end
        text ..= ("\n%d shown cells blocked. Check materials and support in the checklist."):format(blocked)
        if transform.from and transform.to and transform.from ~= transform.to then
            text ..= ("\nSwap: %s → %s"):format(B.niceName(transform.from), B.niceName(transform.to))
        end
        status(text)
    end

    B.selectPreviewBlocks, B.captureBlockVisual = selectPreviewBlocks, captureVisual
    B.clearPastePreview, B.clearClipboard = clearPreview, clearClipboard
    State.OnCleanup(clearClipboard)
    task.spawn(function()
        while not S.unloaded do
            task.wait(previewBlocks and #ghosts < #previewBlocks and 0.03 or 0.15)
            if S.unloaded then break end
            local ok, err = pcall(updatePreview)
            if not ok then
                clearPreview()
                status("Preview unavailable: " .. tostring(err))
            end
        end
    end)
    return true
end
