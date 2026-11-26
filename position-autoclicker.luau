-- Simple position autoclicker for Real. F6 start/stop, F7 pick, End unload.
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local env = getgenv()
local previous = env.SimplePositionClickerSaved or (env.SimplePositionClicker and env.SimplePositionClicker.snapshot())
env.SimplePositionClickerSaved = nil
if env.SimplePositionClicker then env.SimplePositionClicker.cleanup() end
local virtualInput = UIS:CreateVirtualInput()

local alive, running, picking, shiftHeld = true, false, false, false
local holdShift, cps, target, elapsed, settle = false, 5, nil, 0, false
local mouseHeld = false
if previous then
    holdShift, cps = previous.holdShift, previous.cps
    if previous.x and previous.y then target = Vector2.new(previous.x, previous.y) end
end
local connections = {}
local gui = Instance.new("ScreenGui")
gui.Name = "SimplePositionClicker"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 100000
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = gethui() or game:GetService("CoreGui")

local function make(class, props, parent)
    local obj = Instance.new(class)
    for k, v in pairs(props) do obj[k] = v end
    obj.Parent = parent
    return obj
end
local function connect(signal, fn)
    local connection = signal:Connect(fn)
    table.insert(connections, connection)
    return connection
end
local panel = make("Frame", {
    Name = "Panel", Size = UDim2.fromOffset(300, 310),
    Position = UDim2.fromOffset(40, 180), BackgroundColor3 = Color3.fromRGB(25, 28, 36),
    BorderSizePixel = 0, Active = true,
}, gui)
make("UICorner", {CornerRadius = UDim.new(0, 12)}, panel)
local function label(text, y, height)
    return make("TextLabel", {
        Size = UDim2.new(1, -28, 0, height or 24), Position = UDim2.fromOffset(14, y),
        BackgroundTransparency = 1, Text = text, TextColor3 = Color3.fromRGB(230, 234, 245),
        Font = Enum.Font.Gotham, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left,
    }, panel)
end
local title = label("ROBLOX BACKGROUND CLICKER", 10, 32)
title.Font = Enum.Font.GothamBold
local function button(text, y)
    local b = make("TextButton", {
        Size = UDim2.new(1, -28, 0, 34), Position = UDim2.fromOffset(14, y),
        BackgroundColor3 = Color3.fromRGB(46, 54, 72), BorderSizePixel = 0,
        Text = text, TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamMedium, TextSize = 14,
    }, panel)
    make("UICorner", {CornerRadius = UDim.new(0, 7)}, b)
    return b
end
local positionLabel = label("Position: not selected", 49)
if target then positionLabel.Text = string.format("Position: %d, %d", target.X, target.Y) end
local pickButton = button("Pick position  [F7]", 78)
label("Clicks per second (0.1 - 50)", 120)
local speedBox = make("TextBox", {
    Name = "Speed", Size = UDim2.new(1, -28, 0, 32), Position = UDim2.fromOffset(14, 148),
    BackgroundColor3 = Color3.fromRGB(35, 40, 52), TextColor3 = Color3.new(1, 1, 1),
    Text = tostring(cps), ClearTextOnFocus = false, Font = Enum.Font.Gotham, TextSize = 14,
    BorderSizePixel = 0,
}, panel)
make("UICorner", {CornerRadius = UDim.new(0, 6)}, speedBox)
local shiftButton = button("Hold Shift: " .. (holdShift and "ON" or "OFF"), 190)
local startButton = button("Start  [F6]", 232)
local status = label("F7 pick  |  F6 start/stop  |  End close", 274, 26)
status.TextSize = 11
local hint = make("TextLabel", {
    Size = UDim2.fromOffset(450, 36), Position = UDim2.new(0.5, -225, 0, 55),
    BackgroundColor3 = Color3.fromRGB(25, 28, 36), TextColor3 = Color3.new(1, 1, 1),
    Text = "Click your target position. Esc cancels.", Font = Enum.Font.GothamBold,
    TextSize = 16, Visible = false,
}, gui)
make("UICorner", {CornerRadius = UDim.new(0, 8)}, hint)

local function releaseShift()
    if shiftHeld then
        pcall(function() virtualInput:SendKey(false, Enum.KeyCode.LeftShift, false) end)
        shiftHeld = false
    end
end
local function releaseMouse()
    if mouseHeld and target then
        pcall(function()
            virtualInput:SendMouseButton(target, Enum.UserInputType.MouseButton1, false, 0)
        end)
        mouseHeld = false
    end
end
local function stop(message)
    running, elapsed, settle = false, 0, false
    releaseMouse()
    releaseShift()
    panel.Visible = not picking
    startButton.Text = "Start  [F6]"
    startButton.BackgroundColor3 = Color3.fromRGB(46, 54, 72)
    status.Text = message or "Stopped  |  F7 pick  |  End close"
end
local function toggle()
    if running then stop(); return end
    if picking then return end
    if not target then status.Text = "Pick a position first with F7."; return end
    running, elapsed, settle = true, 0, false
    panel.Visible = false
    status.Text = "Running"
end
local function beginPick()
    stop()
    picking = true
    panel.Visible = false
    hint.Visible = true
end
local function finishPick()
    picking = false
    hint.Visible = false
    panel.Visible = true
end
local function cleanup()
    if not alive then return end
    stop()
    alive = false
    for _, c in ipairs(connections) do c:Disconnect() end
    gui:Destroy()
    env.SimplePositionClicker = nil
end
env.SimplePositionClicker = {
    cleanup = cleanup,
    snapshot = function()
        return {running = running, picking = picking, holdShift = holdShift,
            shiftHeld = shiftHeld, cps = cps, background = true,
            x = target and target.X, y = target and target.Y, gui = gui.Parent ~= nil}
    end,
}
local reloadState = getfenv().STATE
if reloadState then reloadState.onCleanup(cleanup) end

connect(startButton.Activated, toggle)
connect(pickButton.Activated, beginPick)
connect(shiftButton.Activated, function()
    holdShift = not holdShift
    shiftButton.Text = "Hold Shift: " .. (holdShift and "ON" or "OFF")
    if not holdShift then releaseShift() end
end)
connect(speedBox.FocusLost, function()
    local n = tonumber(speedBox.Text)
    if n and n == n then cps = math.clamp(n, 0.1, 50) end
    speedBox.Text = tostring(cps)
end)
connect(UIS.InputBegan, function(input, processed)
    if picking then
        if input.KeyCode == Enum.KeyCode.Escape then
            finishPick()
        elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
            local pos = UIS:GetMouseLocation()
            target = Vector2.new(math.floor(pos.X), math.floor(pos.Y))
            positionLabel.Text = string.format("Position: %d, %d", target.X, target.Y)
            finishPick()
        end
        return
    end
    if UIS:GetFocusedTextBox() then return end
    if input.KeyCode == Enum.KeyCode.F6 then toggle()
    elseif input.KeyCode == Enum.KeyCode.F7 then beginPick()
    elseif input.KeyCode == Enum.KeyCode.End and not processed then cleanup() end
end)

-- Drag the title to move the panel.
local dragging, dragOrigin, panelOrigin = false, nil, nil
connect(title.InputBegan, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging, dragOrigin, panelOrigin = true, input.Position, panel.Position
    end
end)
connect(UIS.InputChanged, function(input)
    if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
        local delta = input.Position - dragOrigin
        panel.Position = UDim2.new(panelOrigin.X.Scale, panelOrigin.X.Offset + delta.X,
            panelOrigin.Y.Scale, panelOrigin.Y.Offset + delta.Y)
    end
end)
connect(UIS.InputEnded, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
end)

-- Roblox-internal input only. Never move or click the operating system cursor.
connect(RunService.Heartbeat, function(dt)
    if not alive or not running then return end
    local camera = workspace.CurrentCamera
    if not camera or not target then stop("Pick a position first."); return end
    local size = camera.ViewportSize
    if target.X < 0 or target.Y < 0 or target.X >= size.X or target.Y >= size.Y then
        stop("Position outside window. Pick again with F7.")
        return
    end
    local ok, err = pcall(function()
        releaseMouse()
        if holdShift and not shiftHeld then
            virtualInput:SendKey(true, Enum.KeyCode.LeftShift, false)
            shiftHeld = true
        elseif not holdShift then releaseShift() end
        virtualInput:SendMousePosition(target)
        if not settle then
            settle = true
            return
        end
        elapsed += dt
        if elapsed >= 1 / cps then
            virtualInput:SendMouseButton(target, Enum.UserInputType.MouseButton1, true, 0)
            mouseHeld = true
            elapsed = math.min(elapsed - 1 / cps, 1 / cps)
        end
    end)
    if not ok then stop("Input error: " .. tostring(err)) end
end)
print("Roblox-only background clicker ready: F7 pick, F6 start/stop, End close.")

