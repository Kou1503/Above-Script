--[[
    Modules/Farm/Diagnostics.lua  -  session activity recorder.
    Source: Script1 lines 260-442 (verbatim; shared Farm variables read through F).
]]

return function(State)
    local F = State.Farm
    local HttpService = State.Services.HttpService
    local LocalPlayer = F.LocalPlayer
    local Remotes = F.Remotes
    local HotbarController = F.HotbarController
    local hotbarIndexByToolSlot = F.hotbarIndexByToolSlot

    local diagnostics = { ready = false, onStatus = nil :: ((string) -> ())? }
    do
        local interval = 0.25
        local capacity = 1200
        local checkpointInterval = 30
        local enabled = false
        local session: any = nil
        local damageConnection: RBXScriptConnection? = nil

        local function rounded(value)
            return math.round(value * 10) / 10
        end

        local function settings()
            return {
                enabledModes = table.clone(F.enabledModes), autoShiny = F.autoShiny,
                featurePriority = table.clone(F.featurePriority), enemyPriority = table.clone(F.enemyPriority),
                orePriority = table.clone(F.orePriority), treePriority = table.clone(F.treePriority),
                bossPriority = table.clone(F.bossPriority), bossBow = F.bossBow.enabled, nearestEnemy = F.preferNearestEnemy,
                nearestNode = table.clone(F.preferNearestNode), shinyFamilies = table.clone(F.selectedFamilies),
                autoReturnToHub = F.autoReturnToHub, flightSpeed = F.flightSpeed, attackRange = F.attackRange,
                rangedRange = F.rangedAttackRange, rangedHoverHeight = F.rangedHoverHeight, bowAim = F.bowAim,
                hoverHeights = table.clone(F.modeHoverHeights), targetDistance = F.maxTargetDistance,
                orbitEnabled = F.smoothOrbitEnabled, orbitSpeed = F.smoothOrbitSpeed, orbitRadius = F.smoothOrbitRadius,
            }
        end

        local function save(kind, incident)
            local data = session
            if not data then return false end
            local samples = table.create(data.size)
            for index = 1, data.size do
                samples[index] = data.samples[(data.cursor - data.size + index - 1) % capacity + 1]
            end
            local snapshot = {
                schemaVersion = 1, source = "Above Autofarm diagnostics v1",
                universeId = game.GameId, placeId = game.PlaceId, placeVersion = game.PlaceVersion, serverId = game.JobId,
                account = LocalPlayer.Name, userId = LocalPlayer.UserId,
                startedAtMs = data.startedAtMs, capturedAtMs = DateTime.now().UnixTimestampMillis,
                elapsedSeconds = rounded(os.clock() - data.started), kind = kind, incident = incident,
                initialSettings = data.initialSettings, settings = settings(), totals = data.totals,
                peakCountsInSample = data.peakCounts, maxObservedSpeed = data.maxSpeed,
                maxObservedStep = data.maxStep, pendingCounts = data.pending, pendingAction = data.lastAction,
                samples = samples,
            }
            local suffix = if incident then "-disconnect-" .. data.incidents else ""
            local path = data.path .. suffix .. ".json"
            local encoded, content = pcall(function() return HttpService:JSONEncode(snapshot) end)
            local ok, err = pcall(function()
                if not encoded then error(content) end
                writefile(path, content)
                if not isfile(path) then error("File did not appear after writing.") end
            end)
            if not ok and not data.writeWarning then
                data.writeWarning = true
                warn("[ABOVE Farm] Could not save diagnostic log: " .. tostring(err))
            end
            data.status = if ok then "Saved " .. path else "Could not write the local log. See the Real console."
            if diagnostics.onStatus then diagnostics.onStatus(data.status) end
            return ok, if encoded then content else nil
        end

        function diagnostics.count(key, targetId, weaponId, distance)
            local data = session
            if not enabled or not data then return end
            data.totals[key] = (data.totals[key] or 0) + 1
            data.pending[key] = (data.pending[key] or 0) + 1
            if targetId then
                data.lastAction = {
                    t = rounded(os.clock() - data.started), kind = key,
                    target = targetId, weapon = weaponId, distance = if distance then rounded(distance) else nil,
                }
            end
        end

        function diagnostics.setEnabled(value)
            if enabled == value then return end
            if not value then
                if session then save("disabled") end
                enabled, session = false, nil
                if damageConnection then
                    damageConnection:Disconnect()
                    damageConnection = nil
                end
                if diagnostics.onStatus then diagnostics.onStatus("Recording is off.") end
                return
            end
            enabled = true
            local now = os.clock()
            local timestamp = DateTime.now().UnixTimestampMillis
            session = {
                path = string.format("ABOVE_Obsidian/diagnostics/%d/%d-%s", LocalPlayer.UserId, timestamp, HttpService:GenerateGUID(false)),
                started = now, startedAtMs = timestamp, nextSample = now, nextCheckpoint = now + checkpointInterval,
                initialSettings = settings(), samples = table.create(capacity), size = 0, cursor = 0, incidents = 0,
                totals = {}, peakCounts = {}, pending = {}, maxSpeed = 0, maxStep = 0,
            }
            local damage = Remotes:FindFirstChild("DamageDealt")
            if damage and damage:IsA("RemoteEvent") then
                damageConnection = damage.OnClientEvent:Connect(function()
                    diagnostics.count("damageEvents")
                end)
            end
            save("started")
        end

        function diagnostics.isEnabled()
            return enabled
        end

        function diagnostics.sample(now, humanoid, root)
            local data = session
            if not enabled or not data or now < data.nextSample then return end
            data.nextSample = now + interval
            if not humanoid then
                local character = LocalPlayer.Character
                humanoid = character and character:FindFirstChildOfClass("Humanoid")
            end
            if humanoid and humanoid.Health <= 0 and data.lastDeadHumanoid ~= humanoid then
                data.lastDeadHumanoid = humanoid
                diagnostics.count("observedDeaths")
            end
            local sample: any = {
                t = rounded(now - data.started), mode = F.activeMode or "idle",
                seconds = if data.lastAt then math.round((now - data.lastAt) * 1000) / 1000 else nil,
                weapon = HotbarController.itemAt(hotbarIndexByToolSlot.Weapon),
                target = F.primaryTarget and F.primaryTarget.id, flight = F.movementAlign ~= nil,
                noclip = F.noclipCharacter ~= nil, flightSpeed = F.flightSpeed, bowAim = F.bowAim,
                orbit = F.smoothOrbitEnabled, health = if humanoid then rounded(humanoid.Health) else nil,
                state = if humanoid then humanoid:GetState().Name else nil,
                counts = if next(data.pending) then data.pending else nil, lastAction = data.lastAction,
            }
            for event, count in data.pending do
                data.peakCounts[event] = math.max(data.peakCounts[event] or 0, count)
            end
            data.pending, data.lastAction = {}, nil
            local position = root and root.Position
            if root and position then
                sample.position = { rounded(position.X), rounded(position.Y), rounded(position.Z) }
                sample.physicsSpeed = rounded(root.AssemblyLinearVelocity.Magnitude)
                if root == data.lastRoot and data.lastPosition and now > data.lastAt then
                    local distance = (position - data.lastPosition).Magnitude
                    local duration = now - data.lastAt
                    local speed = distance / duration
                    sample.step, sample.observedSpeed = rounded(distance), rounded(speed)
                    data.maxSpeed = math.max(data.maxSpeed, sample.observedSpeed)
                    data.maxStep = math.max(data.maxStep, sample.step)
                end
            end
            data.lastRoot, data.lastPosition, data.lastAt = root, position, now
            data.cursor = data.cursor % capacity + 1
            data.samples[data.cursor] = sample
            data.size = math.min(data.size + 1, capacity)
            if now >= data.nextCheckpoint then
                data.nextCheckpoint = now + checkpointInterval
                save("checkpoint")
            end
        end

        function diagnostics.onDisconnect(code, message)
            local data = session
            if not enabled or not data then return nil end
            data.incidents += 1
            local saved, attachment = save("disconnect", { code = code, message = message, number = data.incidents })
            return string.format("\nDiagnostics %s · %ds recorded · peak observed %d studs/s · %d swings / %d shots",
                if saved then "saved locally" else "could not be saved", math.floor(os.clock() - data.started),
                math.round(data.maxSpeed), data.totals.combatSwings or 0, data.totals.shots or 0), attachment
        end

        function diagnostics.snapshot()
            if not enabled then return nil end
            local _, attachment = save("manual")
            return attachment
        end

        function diagnostics.stop()
            if session then save("stopped") end
            enabled, session = false, nil
            if damageConnection then
                damageConnection:Disconnect()
                damageConnection = nil
            end
        end
    end

    F.diagnostics = diagnostics
    return diagnostics
end
