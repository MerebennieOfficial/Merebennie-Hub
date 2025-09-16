
-- Circular Tween UI — Delta Executor Compatible
-- Polished player-only settings panel, M1 auto-press, movable + minimizable panel.
-- Drop this file into your Delta executor and run.

-- SAFE GUARDS / EXECUTOR COMPATIBILITY
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local workspace = game:GetService("Workspace")

-- wait for LocalPlayer (Delta / some executors can be slightly different)
local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    repeat wait() LocalPlayer = Players.LocalPlayer until LocalPlayer
end

-- try to resolve PlayerGui in executor environments
local function resolvePlayerGui()
    local pg = nil
    pcall(function() pg = LocalPlayer:FindFirstChild("PlayerGui") end)
    if (not pg or not pg.Parent) then
        -- try common executor helpers
        local ok, res = pcall(function()
            if type(gethui) == "function" then
                return gethui()
            end
            if type(syn) == "table" and type(syn.protect_gui) == "function" then
                return LocalPlayer:FindFirstChild("PlayerGui") or game:GetService("CoreGui")
            end
            return nil
        end)
        if ok and res then pg = res end
    end
    if not pg then
        pg = LocalPlayer:FindFirstChild("PlayerGui")
    end
    if not pg then
        -- final fallback to CoreGui
        pg = game:GetService("CoreGui")
    end
    return pg
end

local PlayerGui = resolvePlayerGui()

-- ensure Character references
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local HRP = Character:FindFirstChild("HumanoidRootPart") or Character:WaitForChild("HumanoidRootPart")
local Humanoid = Character:FindFirstChildOfClass("Humanoid")
-- We'll reconnect when character respawns later

-- CONFIG
local MAX_RANGE            = 40
local ARC_APPROACH_RADIUS  = 11
local BEHIND_DISTANCE      = 4
local FRONT_DISTANCE       = 4
local TOTAL_TIME           = 0.3
local MIN_RADIUS           = 1.2
local MAX_RADIUS           = 14

-- ANIMS / SFX
local ANIM_LEFT_ID  = 10480796021
local ANIM_RIGHT_ID = 10480793962
local PRESS_SFX_ID = "rbxassetid://5852470908"
local DASH_SFX_ID  = "rbxassetid://72014632956520"

-- STATE
local busy = false
local currentAnimTrack = nil

local dashSound = Instance.new("Sound")
dashSound.Name = "DashSFX"
dashSound.SoundId = DASH_SFX_ID
dashSound.Volume = 2.0
dashSound.Looped = false
dashSound.Parent = workspace

-- SETTINGS
local SETTINGS = {
    useNearest = true,
    manualTarget = nil,
    M1Enabled = false,
}

-- Helper functions
local function shortestAngleDelta(target, current)
    local delta = target - current
    while delta > math.pi do delta = delta - 2*math.pi end
    while delta < -math.pi do delta = delta + 2*math.pi end
    return delta
end

local function easeOutCubic(t)
    t = math.clamp(t, 0, 1)
    return 1 - (1 - t)^3
end

local function ensureHumanoidAndAnimator()
    if not Character or not Character.Parent then return nil, nil end
    local hum = Character:FindFirstChildOfClass("Humanoid")
    if not hum then hum = Character:FindFirstChild("Humanoid") end
    if not hum then return nil, nil end
    local animator = hum:FindFirstChildOfClass("Animator")
    if not animator then
        animator = Instance.new("Animator")
        animator.Name = "Animator"
        animator.Parent = hum
    end
    return hum, animator
end

local function playSideAnimation(isLeft)
    pcall(function()
        if currentAnimTrack and currentAnimTrack.IsPlaying then currentAnimTrack:Stop() end
        currentAnimTrack = nil
    end)
    local hum, animator = ensureHumanoidAndAnimator()
    if not hum or not animator then return end
    local animId = isLeft and ANIM_LEFT_ID or ANIM_RIGHT_ID
    if not animId then return end
    local anim = Instance.new("Animation")
    anim.Name = "CircularSideAnim"
    anim.AnimationId = "rbxassetid://" .. tostring(animId)
    local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
    if not ok or not track then anim:Destroy() return end
    currentAnimTrack = track
    track.Priority = Enum.AnimationPriority.Action
    track:Play()
    pcall(function()
        if dashSound and dashSound.Parent then dashSound:Stop() dashSound:Play() end
    end)
    delay(TOTAL_TIME + 0.15, function()
        if track and track.IsPlaying then pcall(function() track:Stop() end) end
        pcall(function() anim:Destroy() end)
    end)
end

local function getNearestTarget(maxRange)
    maxRange = maxRange or MAX_RANGE
    local nearest, nearestDist = nil, math.huge
    if not HRP then return nil end
    local myPos = HRP.Position
    for _, pl in pairs(Players:GetPlayers()) do
        if pl ~= LocalPlayer and pl.Character and pl.Character:FindFirstChild("HumanoidRootPart") and pl.Character:FindFirstChildOfClass("Humanoid") then
            local hum = pl.Character:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 then
                local pos = pl.Character.HumanoidRootPart.Position
                local d = (pos - myPos).Magnitude
                if d < nearestDist and d <= maxRange then nearestDist, nearest = d, pl.Character end
            end
        end
    end
    return nearest, nearestDist
end

-- main tween (same polished arc + yaw-only camera/character lock)
local function smoothArcToTarget(targetModel)
    if busy then return end
    if not targetModel or not targetModel:FindFirstChild("HumanoidRootPart") then return end
    if not HRP then return end
    busy = true

    -- M1 auto-press (if enabled)
    if SETTINGS.M1Enabled then
        pcall(function()
            local args1 = {
                [1] = {
                    ["Mobile"] = true,
                    ["Goal"] = "LeftClick"
                }
            }
            local args2 = {
                [1] = {
                    ["Goal"] = "LeftClickRelease",
                    ["Mobile"] = true
                }
            }
            local comm = nil
            if Character then comm = Character:FindFirstChild("Communicate") end
            if comm and comm.FireServer then
                pcall(function() comm:FireServer(unpack(args1)) end)
                delay(0.05, function() pcall(function() comm:FireServer(unpack(args2)) end) end)
            end
        end)
    end

    if targetModel == nil then busy = false return end
    local targetHRP = targetModel:FindFirstChild("HumanoidRootPart")
    if not targetHRP then busy = false return end

    local center = targetHRP.Position
    local myPos = HRP.Position
    local lookVec = targetHRP.CFrame.LookVector

    local toMe = myPos - center
    local forwardDot = lookVec:Dot(toMe)
    local finalPos
    if forwardDot > 0 then
        finalPos = center - lookVec * BEHIND_DISTANCE
    else
        finalPos = center + lookVec * FRONT_DISTANCE
    end
    finalPos = Vector3.new(finalPos.X, center.Y + 1.5, finalPos.Z)

    local startRadius = (Vector3.new(myPos.X,0,myPos.Z)-Vector3.new(center.X,0,center.Z)).Magnitude
    local midRadius   = math.clamp(ARC_APPROACH_RADIUS, MIN_RADIUS, MAX_RADIUS)
    local endRadius   = (Vector3.new(finalPos.X,0,finalPos.Z)-Vector3.new(center.X,0,center.Z)).Magnitude
    local startAngle = math.atan2(myPos.Z-center.Z, myPos.X-center.X)
    local endAngle   = math.atan2(finalPos.Z-center.Z, finalPos.X-center.X)
    local deltaAngle = shortestAngleDelta(endAngle, startAngle)
    local isLeft = (deltaAngle > 0)
    pcall(function() playSideAnimation(isLeft) end)

    local cam = workspace.CurrentCamera
    local startCamLook = cam and cam.CFrame and cam.CFrame.LookVector or Vector3.new(0,0,1)
    local startPitch = math.asin(math.clamp(startCamLook.Y, -0.999, 0.999))

    local humanoid = nil
    local oldAutoRotate = nil
    pcall(function() humanoid = Character and Character:FindFirstChildOfClass("Humanoid") end)
    if humanoid then
        pcall(function() oldAutoRotate = humanoid.AutoRotate end)
        pcall(function() humanoid.AutoRotate = false end)
    end

    local startHRPLook = HRP and HRP.CFrame and HRP.CFrame.LookVector or Vector3.new(1,0,0)
    local startHRPYaw = math.atan2(startHRPLook.Z, startHRPLook.X)

    local startTime = tick()
    local conn
    conn = RunService.Heartbeat:Connect(function()
        if not targetHRP or not targetHRP.Parent then
            if humanoid and oldAutoRotate ~= nil then pcall(function() humanoid.AutoRotate = oldAutoRotate end) end
            if conn and conn.Connected then conn:Disconnect() end
            busy = false
            return
        end

        local now = tick()
        local t = math.clamp((now - startTime)/TOTAL_TIME, 0, 1)
        local e = easeOutCubic(t)

        local midT = 0.5
        local radiusNow
        if t <= midT then
            local e1 = easeOutCubic(t/midT)
            radiusNow = startRadius + (midRadius - startRadius)*e1
        else
            local e2 = easeOutCubic((t-midT)/(1-midT))
            radiusNow = midRadius + (endRadius - midRadius)*e2
        end
        radiusNow = math.clamp(radiusNow, MIN_RADIUS, MAX_RADIUS)

        local angleNow = startAngle + deltaAngle*e
        local x = center.X + radiusNow*math.cos(angleNow)
        local z = center.Z + radiusNow*math.sin(angleNow)
        local y = myPos.Y + (finalPos.Y - myPos.Y)*e
        local posNow = Vector3.new(x,y,z)

        local toTargetFromHRP = targetHRP.Position - posNow
        if toTargetFromHRP.Magnitude < 0.001 then toTargetFromHRP = Vector3.new(lookVec.X, 0, lookVec.Z) end
        local currentDesiredHRPYaw = math.atan2(toTargetFromHRP.Z, toTargetFromHRP.X)
        local deltaHRPYaw = shortestAngleDelta(currentDesiredHRPYaw, startHRPYaw)
        local hrpYawNow = startHRPYaw + deltaHRPYaw * e
        local hrpLook = Vector3.new(math.cos(hrpYawNow), 0, math.sin(hrpYawNow))

        pcall(function() HRP.CFrame = CFrame.new(posNow, posNow + hrpLook) end)

        if cam and cam.CFrame and targetHRP and targetHRP.Parent then
            local camPos = cam.CFrame.Position
            local toTargetFromCam = targetHRP.Position - camPos
            if toTargetFromCam.Magnitude < 0.001 then toTargetFromCam = Vector3.new(lookVec.X, 0, lookVec.Z) end
            local desiredCamYaw = math.atan2(toTargetFromCam.Z, toTargetFromCam.X)
            local cosP = math.cos(startPitch)
            local camLookNow = Vector3.new(math.cos(desiredCamYaw)*cosP, math.sin(startPitch), math.sin(desiredCamYaw)*cosP)
            pcall(function() cam.CFrame = CFrame.new(camPos, camPos + camLookNow) end)
        end

        if t >= 1 then
            if conn and conn.Connected then conn:Disconnect() end
            local finalToTarget = targetHRP.Position - finalPos
            if finalToTarget.Magnitude < 0.001 then finalToTarget = Vector3.new(lookVec.X, 0, lookVec.Z) end
            local finalYaw = math.atan2(finalToTarget.Z, finalToTarget.X)
            pcall(function() HRP.CFrame = CFrame.new(finalPos, finalPos + Vector3.new(math.cos(finalYaw), 0, math.sin(finalYaw))) end)
            pcall(function() if currentAnimTrack and currentAnimTrack.IsPlaying then currentAnimTrack:Stop() end currentAnimTrack = nil end)
            if humanoid and oldAutoRotate ~= nil then pcall(function() humanoid.AutoRotate = oldAutoRotate end) end
            busy = false
        end
    end)
end

-- UI ------------------------------------------------------------
-- idempotent createUI
local function createUI()
    -- attempt to destroy previous
    pcall(function()
        local old = PlayerGui:FindFirstChild("CircularTweenUI")
        if old then old:Destroy() end
    end)

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "CircularTweenUI"
    screenGui.ResetOnSpawn = false
    screenGui.Parent = PlayerGui

    -- DASH BUTTON
    local button = Instance.new("ImageButton")
    button.Name = "DashButton"
    button.Size = UDim2.new(0,110,0,110)
    button.Position = UDim2.new(0.5,-55,0.8,-55)
    button.BackgroundTransparency = 1
    button.BorderSizePixel = 0
    button.Image = "rbxassetid://99317918824094"
    button.Active = true
    button.Parent = screenGui

    local uiScale = Instance.new("UIScale", button)
    uiScale.Scale = 1

    local pressSound = Instance.new("Sound")
    pressSound.Name = "PressSFX"
    pressSound.SoundId = PRESS_SFX_ID
    pressSound.Volume = 0.9
    pressSound.Looped = false
    pressSound.Parent = button

    -- pointer drag logic for circular button
    local isPointerDown, isDragging, pointerStartPos, buttonStartPos, trackedInput = false,false,nil,nil,nil
    local dragThreshold = 8
    local function tweenUIScale(toScale,time)
        time = time or 0.06
        local ok, tw = pcall(function() return TweenService:Create(uiScale, TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Scale=toScale}) end)
        if ok and tw then tw:Play() end
    end
    local function startPointer(input)
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
            isPointerDown = true
            isDragging = false
            pointerStartPos = input.Position
            buttonStartPos = button.Position
            trackedInput = input
            tweenUIScale(0.92,0.06)
            pcall(function() pressSound:Play() end)
        end
    end
    local function updatePointer(input)
        if not isPointerDown or not pointerStartPos or input ~= trackedInput then return end
        local delta = input.Position - pointerStartPos
        if not isDragging and delta.Magnitude >= dragThreshold then
            isDragging = true
            tweenUIScale(1,0.06)
        end
        if isDragging then
            local screenW, screenH = workspace.CurrentCamera.ViewportSize.X, workspace.CurrentCamera.ViewportSize.Y
            local newX = buttonStartPos.X.Offset + delta.X
            local newY = buttonStartPos.Y.Offset + delta.Y
            newX = math.clamp(newX,0,screenW - button.AbsoluteSize.X)
            newY = math.clamp(newY,0,screenH - button.AbsoluteSize.Y)
            button.Position = UDim2.new(0,newX,0,newY)
        end
    end
    UserInputService.InputChanged:Connect(function(input) pcall(function() updatePointer(input) end) end)
    UserInputService.InputEnded:Connect(function(input)
        if input ~= trackedInput or not isPointerDown then return end
        if not isDragging and not busy then
            local target = nil
            if SETTINGS.useNearest then
                target = getNearestTarget(MAX_RANGE)
            else
                target = SETTINGS.manualTarget
            end
            if target then pcall(function() smoothArcToTarget(target) end) end
        end
        tweenUIScale(1,0.06)
        isPointerDown,isDragging,pointerStartPos,buttonStartPos,trackedInput = false,false,nil,nil,nil
    end)
    button.InputBegan:Connect(function(input) pcall(function() startPointer(input) end) end)

    -- SETTINGS PANEL
    local panel = Instance.new("Frame")
    panel.Name = "SettingsPanel"
    panel.Size = UDim2.new(0,340,0,380)
    panel.Position = UDim2.new(0.02,0,0.08,0)
    panel.BackgroundColor3 = Color3.fromRGB(18,18,18)
    panel.BorderSizePixel = 0
    panel.Parent = screenGui
    local panelCorner = Instance.new("UICorner", panel)
    panelCorner.CornerRadius = UDim.new(0,10)

    local titleBar = Instance.new("Frame")
    titleBar.Name = "TitleBar"
    titleBar.Size = UDim2.new(1,0,0,40)
    titleBar.BackgroundTransparency = 1
    titleBar.Parent = panel

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.Size = UDim2.new(1,-80,1,0)
    title.Position = UDim2.new(0,12,0,0)
    title.BackgroundTransparency = 1
    title.Text = "Circular Tween — Settings"
    title.TextColor3 = Color3.fromRGB(230,230,230)
    title.Font = Enum.Font.GothamSemibold
    title.TextSize = 16
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = titleBar

    local minimizeBtn = Instance.new("TextButton")
    minimizeBtn.Name = "Minimize"
    minimizeBtn.Size = UDim2.new(0,48,0,28)
    minimizeBtn.Position = UDim2.new(1,-56,0,6)
    minimizeBtn.BackgroundColor3 = Color3.fromRGB(40,40,40)
    minimizeBtn.Text = "-"
    minimizeBtn.TextColor3 = Color3.fromRGB(230,230,230)
    minimizeBtn.Font = Enum.Font.GothamBold
    minimizeBtn.Parent = titleBar
    local minCorner = Instance.new("UICorner", minimizeBtn)
    minCorner.CornerRadius = UDim.new(0,6)

    local miniRestore = Instance.new("TextButton")
    miniRestore.Name = "MiniRestore"
    miniRestore.Size = UDim2.new(0,36,0,36)
    miniRestore.Position = UDim2.new(0,12,0,12)
    miniRestore.BackgroundColor3 = Color3.fromRGB(40,40,40)
    miniRestore.Text = "S"
    miniRestore.TextColor3 = Color3.fromRGB(230,230,230)
    miniRestore.Font = Enum.Font.GothamBold
    miniRestore.Visible = false
    miniRestore.Parent = screenGui
    local miniCorner = Instance.new("UICorner", miniRestore)
    miniCorner.CornerRadius = UDim.new(0,8)

    -- Dragging panel
    local dragging, dragInput, dragStart, startPos = false, nil, nil, nil
    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = panel.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    titleBar.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if input == dragInput and dragging and dragStart and startPos then
            local delta = input.Position - dragStart
            local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1280,720)
            local newX = math.clamp((startPos.X.Scale * vp.X) + startPos.X.Offset + delta.X, 0, vp.X - panel.AbsoluteSize.X)
            local newY = math.clamp((startPos.Y.Scale * vp.Y) + startPos.Y.Offset + delta.Y, 0, vp.Y - panel.AbsoluteSize.Y)
            panel.Position = UDim2.new(0, newX, 0, newY)
        end
    end)

    local content = Instance.new("Frame")
    content.Name = "Content"
    content.Size = UDim2.new(1,-24,1,-64)
    content.Position = UDim2.new(0,12,0,48)
    content.BackgroundTransparency = 1
    content.Parent = panel

    -- Toggle: Nearest
    local nearestLabel = Instance.new("TextLabel", content)
    nearestLabel.Size = UDim2.new(0.6,0,0,22)
    nearestLabel.Position = UDim2.new(0,0,0,0)
    nearestLabel.BackgroundTransparency = 1
    nearestLabel.Text = "Use Nearest Player"
    nearestLabel.TextColor3 = Color3.fromRGB(210,210,210)
    nearestLabel.Font = Enum.Font.Gotham
    nearestLabel.TextSize = 14
    nearestLabel.TextXAlignment = Enum.TextXAlignment.Left

    local nearestToggle = Instance.new("TextButton", content)
    nearestToggle.Size = UDim2.new(0,66,0,22)
    nearestToggle.Position = UDim2.new(1,-66,0,0)
    nearestToggle.AnchorPoint = Vector2.new(1,0)
    nearestToggle.BackgroundColor3 = Color3.fromRGB(60,60,60)
    nearestToggle.Text = SETTINGS.useNearest and "ON" or "OFF"
    nearestToggle.TextColor3 = Color3.fromRGB(230,230,230)
    nearestToggle.Font = Enum.Font.GothamBold
    local ntCorner = Instance.new("UICorner", nearestToggle)
    ntCorner.CornerRadius = UDim.new(0,6)

    nearestToggle.MouseButton1Click:Connect(function()
        SETTINGS.useNearest = not SETTINGS.useNearest
        nearestToggle.Text = SETTINGS.useNearest and "ON" or "OFF"
        if SETTINGS.useNearest then
            SETTINGS.manualTarget = nil
            local list = content:FindFirstChild("TargetList")
            if list then
                for _,v in pairs(list:GetChildren()) do
                    if v:IsA("Frame") and v.Name == "ListItem" then
                        v.BackgroundColor3 = Color3.fromRGB(28,28,28)
                        local sel = v:FindFirstChild("SelectedMark")
                        if sel then sel.Visible = false end
                    end
                end
            end
        end
    end)

    -- M1 toggle
    local m1Label = Instance.new("TextLabel", content)
    m1Label.Size = UDim2.new(0.6,0,0,22)
    m1Label.Position = UDim2.new(0,0,0,30)
    m1Label.BackgroundTransparency = 1
    m1Label.Text = "Auto M1 (LeftClick)"
    m1Label.TextColor3 = Color3.fromRGB(210,210,210)
    m1Label.Font = Enum.Font.Gotham
    m1Label.TextSize = 14
    m1Label.TextXAlignment = Enum.TextXAlignment.Left

    local m1Toggle = Instance.new("TextButton", content)
    m1Toggle.Size = UDim2.new(0,66,0,22)
    m1Toggle.Position = UDim2.new(1,-66,0,30)
    m1Toggle.AnchorPoint = Vector2.new(1,0)
    m1Toggle.BackgroundColor3 = Color3.fromRGB(60,60,60)
    m1Toggle.Text = SETTINGS.M1Enabled and "ON" or "OFF"
    m1Toggle.TextColor3 = Color3.fromRGB(230,230,230)
    m1Toggle.Font = Enum.Font.GothamBold
    local m1Corner = Instance.new("UICorner", m1Toggle)
    m1Corner.CornerRadius = UDim.new(0,6)

    m1Toggle.MouseButton1Click:Connect(function()
        SETTINGS.M1Enabled = not SETTINGS.M1Enabled
        m1Toggle.Text = SETTINGS.M1Enabled and "ON" or "OFF"
    end)

    -- Player list header + refresh
    local listLabel = Instance.new("TextLabel", content)
    listLabel.Size = UDim2.new(0.6,0,0,22)
    listLabel.Position = UDim2.new(0,0,0,64)
    listLabel.BackgroundTransparency = 1
    listLabel.Text = "Players"
    listLabel.TextColor3 = Color3.fromRGB(210,210,210)
    listLabel.Font = Enum.Font.Gotham
    listLabel.TextSize = 14
    listLabel.TextXAlignment = Enum.TextXAlignment.Left

    local refreshBtn = Instance.new("TextButton", content)
    refreshBtn.Size = UDim2.new(0,72,0,22)
    refreshBtn.Position = UDim2.new(1,-72,0,64)
    refreshBtn.AnchorPoint = Vector2.new(1,0)
    refreshBtn.BackgroundColor3 = Color3.fromRGB(70,70,70)
    refreshBtn.Text = "Refresh"
    refreshBtn.TextColor3 = Color3.fromRGB(230,230,230)
    refreshBtn.Font = Enum.Font.GothamBold
    local refCorner = Instance.new("UICorner", refreshBtn)
    refCorner.CornerRadius = UDim.new(0,6)

    -- Scroll frame for player list
    local scroll = Instance.new("ScrollingFrame", content)
    scroll.Name = "TargetList"
    scroll.Size = UDim2.new(1,0,0,240)
    scroll.Position = UDim2.new(0,0,0,96)
    scroll.BackgroundColor3 = Color3.fromRGB(22,22,22)
    scroll.BorderSizePixel = 0
    scroll.CanvasSize = UDim2.new(0,0,0,0)
    scroll.ScrollBarThickness = 8
    local scCorner = Instance.new("UICorner", scroll)
    scCorner.CornerRadius = UDim.new(0,8)

    local listLayout = Instance.new("UIListLayout", scroll)
    listLayout.SortOrder = Enum.SortOrder.LayoutOrder
    listLayout.Padding = UDim.new(0,8)

    -- helper: build player-only list (polished visuals)
    local ITEM_HEIGHT = 48
    local function clearList()
        for _, child in pairs(scroll:GetChildren()) do
            if child:IsA("Frame") and child.Name == "ListItem" then child:Destroy() end
        end
    end

    local function buildList()
        clearList()
        local entries = {}

        -- only players (exclude LocalPlayer)
        for _, pl in pairs(Players:GetPlayers()) do
            if pl ~= LocalPlayer then
                local char = pl.Character
                local hasHRP = char and char:FindFirstChild("HumanoidRootPart")
                local hum = char and char:FindFirstChildOfClass("Humanoid")
                if hasHRP and hum and hum.Health > 0 then
                    local dist = (HRP and hasHRP and HRP.Position and hasHRP.Position and (hasHRP.Position - HRP.Position).Magnitude) or math.huge
                    table.insert(entries, {player = pl, name = pl.Name, display = pl.DisplayName or pl.Name, dist = dist})
                end
            end
        end

        table.sort(entries, function(a,b) return a.dist < b.dist end)

        for i, entry in ipairs(entries) do
            local item = Instance.new("Frame")
            item.Name = "ListItem"
            item.Size = UDim2.new(1, -12, 0, ITEM_HEIGHT)
            item.BackgroundColor3 = Color3.fromRGB(28,28,28)
            item.BorderSizePixel = 0
            item.Parent = scroll
            item.LayoutOrder = i

            local itemCorner = Instance.new("UICorner", item)
            itemCorner.CornerRadius = UDim.new(0,8)
            local itemStroke = Instance.new("UIStroke", item)
            itemStroke.Color = Color3.fromRGB(45,45,45)
            itemStroke.LineJoinMode = Enum.LineJoinMode.Round
            itemStroke.Thickness = 1

            -- avatar circle (initial)
            local avatar = Instance.new("Frame", item)
            avatar.Name = "Avatar"
            avatar.Size = UDim2.new(0,40,0,40)
            avatar.Position = UDim2.new(0,8,0.5,-20)
            avatar.BackgroundColor3 = Color3.fromRGB(70,70,70)
            avatar.BorderSizePixel = 0
            local avCorner = Instance.new("UICorner", avatar)
            avCorner.CornerRadius = UDim.new(1,0)
            local avStroke = Instance.new("UIStroke", avatar)
            avStroke.Color = Color3.fromRGB(55,55,55)
            avStroke.Thickness = 1

            local initial = Instance.new("TextLabel", avatar)
            initial.Size = UDim2.new(1,0,1,0)
            initial.BackgroundTransparency = 1
            initial.Text = string.upper(string.sub(entry.name,1,1))
            initial.Font = Enum.Font.GothamBold
            initial.TextSize = 18
            initial.TextColor3 = Color3.fromRGB(230,230,230)

            -- name + subtext
            local nameLabel = Instance.new("TextLabel", item)
            nameLabel.Size = UDim2.new(0.6,0,0,20)
            nameLabel.Position = UDim2.new(0,56,0,6)
            nameLabel.BackgroundTransparency = 1
            nameLabel.Text = entry.display
            nameLabel.TextColor3 = Color3.fromRGB(240,240,240)
            nameLabel.Font = Enum.Font.GothamSemibold
            nameLabel.TextSize = 15
            nameLabel.TextXAlignment = Enum.TextXAlignment.Left

            local distLabel = Instance.new("TextLabel", item)
            distLabel.Size = UDim2.new(0.3, -12, 0, 18)
            distLabel.Position = UDim2.new(1, -12, 0, 8)
            distLabel.AnchorPoint = Vector2.new(1,0)
            distLabel.BackgroundTransparency = 1
            distLabel.Text = string.format("%.1f m", entry.dist)
            distLabel.TextColor3 = Color3.fromRGB(180,180,180)
            distLabel.Font = Enum.Font.Gotham
            distLabel.TextSize = 13
            distLabel.TextXAlignment = Enum.TextXAlignment.Right

            -- select button / indicator area (click anywhere on item to select)
            local selectBtn = Instance.new("TextButton", item)
            selectBtn.Name = "SelectBtn"
            selectBtn.Size = UDim2.new(1,0,1,0)
            selectBtn.Position = UDim2.new(0,0,0,0)
            selectBtn.BackgroundTransparency = 1
            selectBtn.Text = ""
            selectBtn.AutoButtonColor = false

            -- selected marker
            local selectedMark = Instance.new("Frame", item)
            selectedMark.Name = "SelectedMark"
            selectedMark.Size = UDim2.new(0,6,1,0)
            selectedMark.Position = UDim2.new(1,-6,0,0)
            selectedMark.AnchorPoint = Vector2.new(1,0)
            selectedMark.BackgroundColor3 = Color3.fromRGB(100,150,255)
            selectedMark.Visible = false
            local selCorner = Instance.new("UICorner", selectedMark)
            selCorner.CornerRadius = UDim.new(0,4)

            -- hover visuals
            selectBtn.MouseEnter:Connect(function()
                if item.BackgroundColor3 ~= Color3.fromRGB(52,52,62) then
                    item.BackgroundColor3 = Color3.fromRGB(34,34,34)
                end
            end)
            selectBtn.MouseLeave:Connect(function()
                if item.BackgroundColor3 ~= Color3.fromRGB(52,52,62) then
                    item.BackgroundColor3 = Color3.fromRGB(28,28,28)
                end
            end)

            selectBtn.MouseButton1Click:Connect(function()
                SETTINGS.manualTarget = entry.player.Character
                SETTINGS.useNearest = false
                nearestToggle.Text = "OFF"
                -- clear previous selections
                for _,v in pairs(scroll:GetChildren()) do
                    if v:IsA("Frame") and v.Name == "ListItem" then
                        v.BackgroundColor3 = Color3.fromRGB(28,28,28)
                        local sm = v:FindFirstChild("SelectedMark")
                        if sm then sm.Visible = false end
                    end
                end
                -- mark this selected
                item.BackgroundColor3 = Color3.fromRGB(52,52,62)
                selectedMark.Visible = true
            end)
        end

        -- update canvas size
        local count = 0
        for _, v in pairs(scroll:GetChildren()) do
            if v:IsA("Frame") and v.Name == "ListItem" then count = count + 1 end
        end
        local totalSize = count * (ITEM_HEIGHT + listLayout.Padding.Offset) + 8
        scroll.CanvasSize = UDim2.new(0,0,0, totalSize)
    end

    -- init build
    buildList()

    refreshBtn.MouseButton1Click:Connect(function() buildList() end)

    -- minimize behavior
    minimizeBtn.MouseButton1Click:Connect(function()
        panel.Visible = false
        miniRestore.Visible = true
        miniRestore.Position = UDim2.new(0, math.clamp(panel.AbsolutePosition.X, 0, workspace.CurrentCamera.ViewportSize.X - miniRestore.AbsoluteSize.X), 0, math.clamp(panel.AbsolutePosition.Y, 0, workspace.CurrentCamera.ViewportSize.Y - miniRestore.AbsoluteSize.Y))
    end)
    miniRestore.MouseButton1Click:Connect(function()
        panel.Visible = true
        miniRestore.Visible = false
    end)

    -- dash activation helper
    button.MouseButton1Click:Connect(function()
        pcall(function() pressSound:Play() end)
        if busy then return end
        local target = nil
        if SETTINGS.useNearest then
            target = getNearestTarget(MAX_RANGE)
        else
            target = SETTINGS.manualTarget
        end
        if target then pcall(function() smoothArcToTarget(target) end) end
    end)
end

-- ensure UI created
pcall(function() createUI() end)

-- Rebind on respawn: attempt to re-resolve Character, HRP, Humanoid and re-create UI
LocalPlayer.CharacterAdded:Connect(function(char)
    Character = char or LocalPlayer.Character
    if Character then
        HRP = Character:FindFirstChild("HumanoidRootPart") or Character:WaitForChild("HumanoidRootPart")
        Humanoid = Character:FindFirstChildOfClass("Humanoid")
    end
    -- rebuild UI after short delay (allow PlayerGui to be ready)
    delay(0.6, function()
        PlayerGui = resolvePlayerGui() or PlayerGui
        pcall(function() createUI() end)
    end)
end)

-- Keybinds: X + DPadUp
UserInputService.InputBegan:Connect(function(input,processed)
    if processed or busy then return end
    if (input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.X)
        or (input.UserInputType == Enum.UserInputType.Gamepad1 and input.KeyCode == Enum.KeyCode.DPadUp) then
        local target = nil
        if SETTINGS.useNearest then
            target = getNearestTarget(MAX_RANGE)
        else
            target = SETTINGS.manualTarget
        end
        if target then pcall(function() smoothArcToTarget(target) end) end
    end
end)

print("[CircularTweenUI] Ready — Delta-compatible. X / DPadUp / mobile button active.")
