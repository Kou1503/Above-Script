--[[
    Modules/Pollinator/Fps.lua  -  client-side flower hiding, AFK FPS cap, lite graphics, PL.shutdown.
    Source: Script2 lines 2007-2095 (verbatim) and 2111-2117 (PL.shutdown).
]]

return function(State)
    local B = State.Builder
    local PL = State.Pollinator
    local S, Island, Toggles, Options = B.S, B.Island, B.Toggles, B.Options
    local CollectionService = State.Services.CollectionService
    local Lighting = State.Services.Lighting
    local genv = (getgenv and getgenv()) or _G
    local plStop = PL.plStop

    -- FPS optimiser ----------------------------------------------------------------------------------
    local function hideInst(i)
        if PL.hidden[i] then return end
        if i:IsA("BasePart") then
            if i.Name == "HB" then return end                                -- the clickable hitbox is left alone
            PL.hidden[i] = { "Transparency", i.Transparency }
            i.Transparency = 1
        elseif i:IsA("Decal") or i:IsA("Texture") then
            PL.hidden[i] = { "Transparency", i.Transparency }
            i.Transparency = 1
        elseif i:IsA("PointLight") or i:IsA("SpotLight") or i:IsA("SurfaceLight") or i:IsA("ParticleEmitter") then
            PL.hidden[i] = { "Enabled", i.Enabled }
            i.Enabled = false
        end
    end

    local function flowerModelOf(d)
        local m = d:FindFirstAncestorOfClass("Model")
        local hb = m and m:FindFirstChild("HB")
        if hb and CollectionService:HasTag(hb, "Flower") then return m end
    end

    local function hideAllFlowers()
        for _, hb in ipairs(CollectionService:GetTagged("Flower")) do
            if hb.Parent and hb:IsDescendantOf(Island) and hb.Parent:IsA("Model") then
                for _, d in ipairs(hb.Parent:GetDescendants()) do hideInst(d) end
            end
        end
    end

    local function restoreFlowers()
        for inst, rec in pairs(PL.hidden) do
            if inst.Parent then pcall(function() inst[rec[1]] = rec[2] end) end
        end
        PL.hidden = {}
    end

    local hideConn
    local function setHidden(on)
        if hideConn then hideConn:Disconnect() hideConn = nil end
        if not on then restoreFlowers() return end
        hideAllFlowers()
        hideConn = Island.DescendantAdded:Connect(function(d)             -- covers new sprouts as they spawn
            task.defer(function()
                if S.unloaded or not Toggles.HideFlowers.Value then return end
                if flowerModelOf(d) then hideInst(d) end
                if d.Name == "HB" and d.Parent and d.Parent:IsA("Model") then
                    for _, x in ipairs(d.Parent:GetDescendants()) do hideInst(x) end
                end
            end)
        end)
    end

    -- the game re-applies art as flowers grow; keep our overrides in place
    task.spawn(function()
        while not S.unloaded do
            task.wait(2)
            if next(PL.hidden) then
                for inst, rec in pairs(PL.hidden) do
                    if inst.Parent then
                        local want = (rec[1] == "Enabled") and false or 1
                        if inst[rec[1]] ~= want then pcall(function() inst[rec[1]] = want end) end
                    end
                end
            end
        end
    end)

    local setcap = setfpscap or (genv and genv.setfpscap)
    local function applyFpsCap()
        if not setcap then return end
        if Toggles.FpsCapOn.Value then pcall(setcap, Options.FpsCap.Value) else pcall(setcap, 0) end
    end

    local function setLite(on)
        if on then
            if PL.saved.shadows == nil then PL.saved.shadows = Lighting.GlobalShadows end
            Lighting.GlobalShadows = false
            pcall(function()
                if PL.saved.deco == nil then PL.saved.deco = workspace.Terrain.Decoration end
                workspace.Terrain.Decoration = false
            end)
        else
            if PL.saved.shadows ~= nil then Lighting.GlobalShadows = PL.saved.shadows PL.saved.shadows = nil end
            pcall(function()
                if PL.saved.deco ~= nil then workspace.Terrain.Decoration = PL.saved.deco PL.saved.deco = nil end
            end)
        end
    end

    function PL.shutdown()
        PL.autoRun, PL.cancel = false, true
        pcall(plStop, false)
        pcall(setHidden, false)
        pcall(setLite, false)
        if setcap then pcall(setcap, 0) end
    end

    PL.hideInst, PL.flowerModelOf, PL.hideAllFlowers, PL.restoreFlowers = hideInst, flowerModelOf, hideAllFlowers, restoreFlowers
    PL.setHidden, PL.setcap, PL.applyFpsCap, PL.setLite = setHidden, setcap, applyFpsCap, setLite
    return true
end
