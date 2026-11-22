--[[
    Modules/Farm/Cache.lua  -  workspace resource-node / shiny caching.
    Source: Script1 lines 1409-1454 (verbatim).
]]

return function(State)
    local F = State.Farm

    -- ==========================================
    -- 🔍 WORKSPACE CACHING
    -- ==========================================
    local cachedNodes = setmetatable({}, { __mode = "k" })
    local cachedShinies = setmetatable({}, { __mode = "k" })
    local pendingNodeAttributeConnections = setmetatable({}, { __mode = "k" })

    local function insideResourceField(instance)
        local cursor = instance.Parent
        while cursor and cursor ~= workspace do
            if cursor.Name == "ResourceField" then return true end
            cursor = cursor.Parent
        end
        return false
    end

    local function cacheInstance(instance)
        if instance:IsA("Model") then
            if instance:GetAttribute("NodeType") ~= nil then
                cachedNodes[instance] = true
            elseif insideResourceField(instance) and not pendingNodeAttributeConnections[instance] then
                -- Resource models can enter Workspace before NodeType replicates.
                pendingNodeAttributeConnections[instance] = instance:GetAttributeChangedSignal("NodeType"):Connect(function()
                    if instance.Parent and instance:GetAttribute("NodeType") ~= nil then
                        cachedNodes[instance] = true
                        local connection = pendingNodeAttributeConnections[instance]
                        if connection then connection:Disconnect() end
                        pendingNodeAttributeConnections[instance] = nil
                    end
                end)
            end
        elseif instance:GetAttribute("ShinyPiece") ~= nil then
            cachedShinies[instance] = true
        end
    end

    for _, instance in ipairs(workspace:GetDescendants()) do cacheInstance(instance) end

    F.descendantAddedConn = workspace.DescendantAdded:Connect(cacheInstance)
    F.descendantRemovingConn = workspace.DescendantRemoving:Connect(function(instance)
        cachedNodes[instance] = nil
        cachedShinies[instance] = nil
        local pendingConnection = pendingNodeAttributeConnections[instance]
        if pendingConnection then pendingConnection:Disconnect() end
        pendingNodeAttributeConnections[instance] = nil
    end)

    F.cachedNodes = cachedNodes
    F.cachedShinies = cachedShinies
    F.pendingNodeAttributeConnections = pendingNodeAttributeConnections
    return true
end
