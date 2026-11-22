--[[
    Modules/Farm/Loop.lua  -  stopAll() and the main farming loop.
    Source: Script1 lines 2585-2619 (stopAll + unload hooks) and 2638-2775 (main loop), verbatim.
    Changes:
      * Library:OnUnload(stopAll) / STATE.onCleanup  ->  State.OnCleanup(stopAll) (the loader owns the
        single OnUnload handler and the Real cleanup hook).
      * SaveManager:LoadAutoloadConfig() (Script1 2637) already ran in Shared/Settings.lua.
      * Activity lock (approved addition): while the Builder or Pollinator owns the character the loop
        drops its own movement once and skips farming until the lock is released.
]]

return function(State)
    local F = State.Farm
    local UI = State.UI
    local Library = UI.Library
    local HotbarController = F.HotbarController
    local hotbarIndexByToolSlot = F.hotbarIndexByToolSlot
    local rangedShotIntervals = F.rangedShotIntervals
    local enabledModes = F.enabledModes
    local featurePriority = F.featurePriority
    local miningStandoff = F.miningStandoff
    local catcher = F.catcher
    local diagnostics = F.diagnostics
    local scriptAlive = F.scriptAlive
    local characterParts = F.characterParts
    local clearMovement = F.clearMovement
    local cancelHubReturn = F.cancelHubReturn
    local updateHubReturn = F.updateHubReturn
    local findNearestShiny = F.findNearestShiny
    local shinyTargetValid = F.shinyTargetValid
    local findPrimaryTarget = F.findPrimaryTarget
    local primaryTargetValid = F.primaryTargetValid
    local processShiny = F.processShiny
    local doPrimaryAction = F.doPrimaryAction
    local checkClientDisconnect = F.checkClientDisconnect
    local reportInventoryIfDue = F.reportInventoryIfDue
    local sendWebhook = F.sendWebhook
    local setAntiAfk = F.setAntiAfk
    local pendingNodeAttributeConnections = F.pendingNodeAttributeConnections

    local nextErrorWebhookAt = 0

    local function stopAll()
        if not F.running then return end
        F.running = false
        diagnostics.stop()
        F.autoShiny = false
        F.isWebhookActive = false
        F.trackingSession = nil
        for mode in pairs(enabledModes) do enabledModes[mode] = false end
        F.activeMode = nil
        pcall(catcher.stopAim)
        pcall(catcher.restoreHotbar)
        if catcher.alertConnection then catcher.alertConnection:Disconnect() end
        cancelHubReturn()
        clearMovement()
        if F.descendantAddedConn then F.descendantAddedConn:Disconnect() end
        if F.descendantRemovingConn then F.descendantRemovingConn:Disconnect() end
        for instance, connection in pairs(pendingNodeAttributeConnections) do
            connection:Disconnect()
            pendingNodeAttributeConnections[instance] = nil
        end
        if F.characterRemovingConnection then F.characterRemovingConnection:Disconnect() end
        if F.characterAddedConnection then F.characterAddedConnection:Disconnect() end
        F.projectileEndedConnection:Disconnect()
        F.inventoryConnection:Disconnect()
        if miningStandoff.connection then miningStandoff.connection:Disconnect() end
        if F.disconnectConnection then F.disconnectConnection:Disconnect() end
        setAntiAfk(false)
        if UI.flushAutosave then UI.flushAutosave() end
        if not Library.Unloaded then Library:Unload() end
    end
    F.stopAll = stopAll
    State.OnCleanup(stopAll)

    -- ==========================================
    -- 🔄 MAIN FARMING LOOP
    -- ==========================================
    local yieldedToOther = false
    task.defer(function()
        if not F.running or not scriptAlive() then return end
        diagnostics.ready = true
        if Library.Toggles.RecordSessionDiagnostics.Value then
            diagnostics.setEnabled(true)
        else
            diagnostics.onStatus("Recording is off.")
        end
        local nextDisconnectCheck = 0
        while F.running and scriptAlive() do
            local ok, err = pcall(function()
                local character, humanoid, root = characterParts()
                local now = os.clock()
                if now >= nextDisconnectCheck then
                    nextDisconnectCheck = now + 2
                    checkClientDisconnect(nil)
                end
                if diagnostics.isEnabled() then
                    local sampled, sampleError = pcall(diagnostics.sample, now, humanoid, root)
                    if not sampled then
                        warn("[ABOVE Farm] Session diagnostics stopped: " .. tostring(sampleError))
                        Library.Toggles.RecordSessionDiagnostics:SetValue(false)
                    end
                end

                reportInventoryIfDue()

                -- FARMING LOGIC
                if character and humanoid and root then
                    if F.currentCharacter ~= character then
                        clearMovement()
                        F.currentCharacter = character
                        F.equippedSlot = nil
                        F.primaryTarget = nil
                        F.primaryTargetMode = nil
                        F.activeMode = nil
                        F.currentShiny = nil
                        F.nextPrimaryScan = 0
                        F.nextShinyScan = 0
                    end

                    -- Activity lock: the Builder / Pollinator owns the character right now.
                    if State.BusyByOther("farm") then
                        if not yieldedToOther then
                            yieldedToOther = true
                            cancelHubReturn()
                            clearMovement()
                            F.bowState = nil
                            pcall(catcher.stopAim)
                            F.primaryTarget = nil
                            F.primaryTargetMode = nil
                            F.currentShiny = nil
                            F.equippedSlot = nil
                            F.nextPrimaryScan = 0
                            F.nextShinyScan = 0
                        end
                        F.activeMode = nil
                        return
                    end
                    yieldedToOther = false

                    if updateHubReturn(character, humanoid, root, now) then
                        F.activeMode = nil
                        return
                    end

                    if F.autoShiny then
                        if F.currentShiny and not shinyTargetValid(F.currentShiny) then
                            F.currentShiny = nil
                            F.shinyPromptAttempts = 0
                            F.nextShinyPromptAt = 0
                            F.nextShinyScan = 0
                        end
                        if not F.currentShiny and now >= F.nextShinyScan then
                            F.currentShiny = findNearestShiny(root)
                            F.nextShinyScan = now + 0.35
                        end
                    else
                        F.currentShiny = nil
                        F.shinyPromptAttempts = 0
                        F.nextShinyPromptAt = 0
                    end

                    if now >= F.nextPrimaryScan or (F.primaryTarget ~= nil and not primaryTargetValid(F.primaryTarget, F.primaryTargetMode)) then
                        F.primaryTarget = nil
                        F.primaryTargetMode = nil
                        for _, mode in ipairs(featurePriority) do
                            if mode ~= "shiny" and enabledModes[mode] then
                                local candidate = findPrimaryTarget(root, mode)
                                if candidate then
                                    F.primaryTarget = candidate
                                    F.primaryTargetMode = mode
                                    break
                                end
                            end
                        end
                        F.nextPrimaryScan = now + 0.15
                    end

                    local selectedMode, selectedTarget
                    for _, mode in ipairs(featurePriority) do
                        if mode == "shiny" then
                            if F.autoShiny and F.currentShiny and shinyTargetValid(F.currentShiny) then
                                selectedMode, selectedTarget = "shiny", F.currentShiny
                                break
                            end
                        elseif enabledModes[mode] and F.primaryTargetMode == mode
                            and F.primaryTarget and primaryTargetValid(F.primaryTarget, mode) then
                            selectedMode, selectedTarget = mode, F.primaryTarget
                            break
                        end
                    end
                    F.activeMode = selectedMode

                    if selectedMode == "shiny" then
                        F.bowState = nil
                        local shinyBeingProcessed = selectedTarget
                        processShiny(shinyBeingProcessed, root, character, now)
                        if F.currentShiny == shinyBeingProcessed and not shinyTargetValid(shinyBeingProcessed) then
                            F.currentShiny = nil
                            F.shinyPromptAttempts = 0
                            F.nextShinyPromptAt = 0
                            F.nextShinyScan = 0
                            clearMovement()
                        end
                    elseif selectedTarget then
                        doPrimaryAction(selectedTarget, root, now)
                    else
                        F.bowState = nil
                        pcall(catcher.stopAim)
                        F.primaryTarget = nil
                        F.primaryTargetMode = nil
                        clearMovement()
                    end
                else
                    clearMovement()
                end
            end)
            if not ok then
                diagnostics.count("loopErrors")
                warn("[ABOVE Farm] loop recovered from error: " .. tostring(err))
                local errorNow = os.clock()
                if errorNow >= nextErrorWebhookAt then
                    nextErrorWebhookAt = errorNow + 60
                    sendWebhook("⚠️ **Script Error:** Loop recovered from crash: `" .. tostring(err) .. "`")
                end
                clearMovement()
                F.primaryTarget = nil
                F.primaryTargetMode = nil
                F.currentShiny = nil
                F.nextPrimaryScan = 0
                F.nextShinyScan = 0
            end
            local weaponId = (F.activeMode == "kill" or F.activeMode == "boss")
                and HotbarController.itemAt(hotbarIndexByToolSlot.Weapon)
            task.wait(if weaponId and rangedShotIntervals[weaponId] then 0.04 else 0.1)
        end
    end)

    return { stopAll = stopAll }
end
