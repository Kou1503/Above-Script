-- Local schematic and planter libraries. Save grid data and control values as JSON.
return function(State)
    local B, http = State.Builder, State.Services.HttpService
    local MAX_FILE_BYTES = 16 * 1024 * 1024
    local MAX_BLOCKS = 250000
    local storage = readfile and writefile and isfile and isfolder and makefolder and listfiles
    local function pathFor(folder, name)
        assert(type(name) == "string" and #name <= 60 and name:match("^[%w][%w _%-]*$"),
            "Use 1–60 letters, digits, spaces, underscores or hyphens.")
        return folder .. "/build-" .. name .. ".json"
    end

    local function saveNew(folder, name, data)
        local path = pathFor(folder, name)
        if not isfolder(State.SaveFolder) then makefolder(State.SaveFolder) end
        if not isfolder(folder) then makefolder(folder) end
        assert(not isfile(path), "That name already exists. Choose a new name.")
        local encoded = http:JSONEncode(data)
        assert(#encoded <= MAX_FILE_BYTES, "File is too large to save.")
        writefile(path, encoded)
        assert(readfile(path) == encoded, "Could not verify the saved file.")
    end

    local function names(folder)
        local values = {}
        if isfolder(folder) then
            for _, path in ipairs(listfiles(folder)) do
                local filename = path:match("([^/\\]+)$") or ""
                local name = filename:match("^build%-([%w][%w _%-]*)%.json$")
                if name and #name <= 60 then table.insert(values, name) end
            end
        end
        table.sort(values)
        return values
    end

    local function readSaved(folder, name)
        assert(name, "Choose a saved entry.")
        local encoded = readfile(pathFor(folder, name))
        assert(#encoded <= MAX_FILE_BYTES, "Saved file is too large.")
        return http:JSONDecode(encoded)
    end

    local function addPicker(group, folder, prefix, label, onChoose)
        if not storage then
            group:AddLabel("Local file storage is unavailable.", true)
            return
        end
        local input = group:AddInput(prefix .. "Name", { Text = "Name", Default = "", Finished = false })
        local ok, initial = pcall(names, folder)
        local picker = group:AddDropdown(prefix .. "Picker", {
            Text = label, Values = ok and initial or {}, AllowNull = true, Searchable = true, Callback = onChoose,
        })
        table.insert(State.UI.IgnoreIndexes, prefix .. "Name")
        table.insert(State.UI.IgnoreIndexes, prefix .. "Picker")
        local busy = false
        local function addAction(text, action)
            group:AddButton({ Text = text, Func = function()
                if busy then return end
                busy = true
                local name = input.Value:match("^%s*(.-)%s*$")
                local succeeded, message, selectName = pcall(action, name, picker.Value)
                if succeeded and selectName then
                    local listed, values = pcall(names, folder)
                    if listed then
                        picker:SetValues(values)
                        picker:SetValue(selectName)
                    end
                end
                busy = false
                B.notify(tostring(message))
            end })
        end
        return addAction
    end

    local function integer(n)
        return type(n) == "number" and n == math.floor(n) and math.abs(n) < 2147483647
    end

    local function denseArray(values, limit)
        if type(values) ~= "table" then return false end
        local length = #values
        if length > limit then return false end
        local count = 0
        for key in pairs(values) do
            if not integer(key) or key < 1 or key > length then return false end
            count += 1
        end
        return count == length
    end

    local function validOption(id, value)
        return value ~= nil and table.find(B.Options[id].Values, value) ~= nil
    end

    local function validateSchematic(data)
        assert(type(data) == "table" and data.version == 1, "Unsupported schematic format.")
        local size = data.size
        assert(denseArray(size, 3) and #size == 3, "Invalid dimensions.")
        for _, n in ipairs(size) do assert(integer(n) and n > 0 and n <= 2048, "Invalid dimensions.") end
        assert(integer(data.rotation) and data.rotation >= 0 and data.rotation < 360 and data.rotation % 90 == 0,
            "Invalid paste rotation.")
        assert(denseArray(data.blocks, MAX_BLOCKS) and #data.blocks > 0, "Invalid schematic block list.")
        local seen = {}
        for i, b in ipairs(data.blocks) do
            assert(type(b) == "table" and type(b.id) == "string" and B.Config.Build.Blocks[b.id]
                and not (B.Config.Build.Footprints and B.Config.Build.Footprints[b.id]), "Unknown block at entry " .. i)
            assert(integer(b.dx) and b.dx >= 0 and b.dx < size[1] and integer(b.dy) and b.dy >= 0 and b.dy < size[2]
                and integer(b.dz) and b.dz >= 0 and b.dz < size[3] and integer(b.rot), "Invalid block at entry " .. i)
            local key = B.key(b.dx, b.dy, b.dz)
            assert(not seen[key], "Duplicate cell at entry " .. i)
            seen[key] = true
        end
        return data
    end

    local function schematicData(variant)
        local clip = assert(B.S.clip, "Copy a region first.")
        local options = B.Options
        local data = { version = 1, size = clip.size, rotation = tonumber(options.PasteRot.Value),
            mirror = options.PasteMirror.Value, anchor = options.PasteAnchor.Value, blocks = {} }
        local swapped = false
        for i, b in ipairs(clip.blocks) do
            local id = variant and B.pasteMaterial(b) or b.id
            swapped = swapped or id ~= b.id
            data.blocks[i] = { dx = b.dx, dy = b.dy, dz = b.dz, rot = b.rot, id = id }
        end
        assert(not variant or swapped, "Choose two different materials before saving a variant.")
        return validateSchematic(data)
    end

    local function loadSchematic(data)
        local blocks = data.blocks
        local preview = B.selectPreviewBlocks(blocks)
        local examples = {}
        for key, part in pairs(B.S.parts) do
            local id = B.S.occ[key]
            if id and not examples[id] then examples[id] = part end
        end
        for _, b in ipairs(preview) do
            local part = examples[b.id]
            if part then
                b.visual = B.captureBlockVisual(part)
                if b.visual then
                    local delta = math.rad(b.rot - (part:GetAttribute("Rotation") or 0))
                    b.visual.CFrame = CFrame.Angles(0, delta, 0) * part.CFrame.Rotation
                end
            end
        end
        B.clearClipboard()
        B.S.clip = { size = data.size, blocks = blocks, previewBlocks = preview }
        B.updateSchematicControls()
        B.Options.PasteRot:SetValue(tostring(data.rotation))
        B.Options.PasteMirror:SetValue(validOption("PasteMirror", data.mirror) and data.mirror or "None")
        B.Options.PasteAnchor:SetValue(validOption("PasteAnchor", data.anchor) and data.anchor or "Copied corner")
        B.Toggles.PreviewSingleLayer:SetValue(false)
        B.Toggles.ShowPastePreview:SetValue(true)
        B.refreshSoon()
    end

    local function thumbnail(data)
        local size = data.size
        local width, depth = math.min(size[1], 12), math.min(size[3], 12)
        local bins = {}
        for _, block in ipairs(data.blocks) do
            local x = math.floor(block.dx * width / size[1])
            local z = math.floor(block.dz * depth / size[3])
            bins[z * width + x] = true
        end
        local lines = { ("%d × %d × %d · %d blocks"):format(size[1], size[2], size[3], #data.blocks) }
        for z = 0, depth - 1 do
            local row = {}
            for x = 0, width - 1 do row[x + 1] = bins[z * width + x] and "#" or "." end
            lines[#lines + 1] = '<font face="Code">' .. table.concat(row, " ") .. '</font>'
        end
        return table.concat(lines, "\n")
    end

    function B.addSchematicLibrary(group)
        local folder = State.SaveFolder .. "/schematics"
        local detail = group:AddLabel("Choose a schematic to see its footprint.", true)
        local function read(name)
            return validateSchematic(readSaved(folder, name))
        end
        local function showDetail(name)
            if not name then detail:SetText("Choose a schematic to see its footprint.") return end
            local ok, result = pcall(function() return thumbnail(read(name)) end)
            detail:SetText(ok and result or "Could not read schematic.")
        end
        local action = addPicker(group, folder, "SchematicLibrary", "Saved schematics", showDetail)
        if not action then return end
        action("Save copy", function(name)
            saveNew(folder, name, schematicData(false))
            return "Saved " .. name, name
        end)
        action("Save as variant", function(name)
            saveNew(folder, name, schematicData(true))
            return "Saved variant " .. name, name
        end)
        action("Load into preview", function(_, selected)
            loadSchematic(read(selected))
            return "Loaded " .. selected
        end)
        action("Duplicate selected", function(name, selected)
            saveNew(folder, name, read(selected))
            return "Duplicated as " .. name, name
        end)
        if delfile then
            action("Rename selected", function(name, selected)
                local data = read(selected)
                assert(name:lower() ~= selected:lower(), "Choose a different name.")
                saveNew(folder, name, data)
                local removed = pcall(function()
                    local original = pathFor(folder, selected)
                    delfile(original)
                    assert(not isfile(original))
                end)
                return (removed and "Renamed to " or "Original kept. Saved as ") .. name, name
            end)
        end
    end

    local planterFields = {
        "PlantLayout", "FlowerA", "FlowerB", "Parity", "Strip1", "Strip2", "Strip3", "Strip4", "StripAxis",
        "SplitAxis", "GapWidth", "FlipZones", "PlantOnTop", "RequireSupport", "PlantVariants",
    }

    function B.addPlanterPresets(group)
        local folder = State.SaveFolder .. "/planter-presets"
        local action = addPicker(group, folder, "PlanterPreset", "Saved presets")
        if not action then return end
        action("Save preset", function(name)
            local values = {}
            for _, id in ipairs(planterFields) do
                local value = (B.Options[id] or B.Toggles[id]).Value
                values[id] = id == "GapWidth" and math.round(value) or value
            end
            saveNew(folder, name, { version = 1, values = values })
            return "Saved " .. name, name
        end)
        action("Apply preset", function(_, selected)
            local data = readSaved(folder, selected)
            assert(type(data) == "table" and data.version == 1 and type(data.values) == "table", "Invalid preset format.")
            for _, id in ipairs(planterFields) do
                local value = data.values[id]
                local control = B.Options[id] or B.Toggles[id]
                local valid = type(control.Value) == type(value)
                if control.Values then valid = valid and validOption(id, value) end
                if id == "GapWidth" then valid = integer(value) and value >= control.Min and value <= control.Max end
                assert(valid, "Invalid preset value for " .. id)
            end
            for _, id in ipairs(planterFields) do
                local control = B.Options[id] or B.Toggles[id]
                control:SetValue(data.values[id])
            end
            B.refreshChecklist()
            return "Applied " .. selected
        end)
    end
end
