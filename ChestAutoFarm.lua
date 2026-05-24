-- ChestAutoFarm.lua — Legend Piece (optimized)
-- Positions từ GitHub đã hợp lệ → TP trực tiếp, không cần collectVisible loop

local Players = game:GetService("Players")
local player  = Players.LocalPlayer
local RS      = game:GetService("ReplicatedStorage")
local GuiService = game:GetService("GuiService")
local Holder  = workspace:WaitForChild("Holder")
local Map     = Holder:WaitForChild("Map")
local Chests  = Holder:WaitForChild("Chests")

local SkillReq    = RS:WaitForChild("Packages"):WaitForChild("Warp")
                      :WaitForChild("Index"):WaitForChild("Event"):WaitForChild("Request")
local Reliable    = RS:WaitForChild("Packages"):WaitForChild("Warp")
                      :WaitForChild("Index"):WaitForChild("Event"):WaitForChild("Reliable")
local VirtualUser = pcall(function() return game:GetService("VirtualUser") end)
    and game:GetService("VirtualUser") or nil

-- ===== ANTI AFK =====
local function setupAntiAFK()
    if getconnections then
        -- Executor hỗ trợ getconnections: ngắt tất cả Idled connections
        local ok, conns = pcall(getconnections, player.Idled)
        if ok and conns then
            for _, conn in pairs(conns) do
                if conn["Disable"] then
                    conn["Disable"](conn)
                elseif conn["Disconnect"] then
                    conn["Disconnect"](conn)
                end
            end
        end
    elseif VirtualUser then
        -- Có VirtualUser service: simulate input khi bị idle
        player.Idled:Connect(function()
            pcall(function()
                VirtualUser:CaptureController()
                VirtualUser:ClickButton2(Vector2.new())
            end)
        end)
    else
        -- Fallback: jump nhỏ để reset idle timer
        player.Idled:Connect(function()
            local c = player.Character
            local h = c and c:FindFirstChildOfClass("Humanoid")
            if h then h.Jump = true end
        end)
    end
end
setupAntiAFK()

-- ===== CONFIG =====
local GITHUB_URL   = "https://raw.githubusercontent.com/zhongthi-wq/lgpc/refs/heads/main/ChestPositions.txt"
local TOUR_DELAY   = 3      -- giây/đảo (chỉ để load streaming)
local TP_HEIGHT    = 4
local CHEST_WAIT   = 0.2    -- giây chờ sau TP trước khi tìm chest
local CHEST_RETRY  = 0.7    -- giây thêm nếu lần đầu không thấy
local PACE_MIN     = 0.3    -- giây tối thiểu mỗi chest (tránh flood)
local MAX_SKIP     = 4      -- fail liên tiếp (chest có trong WS nhưng không collect) → skip
local TOUR_THRESH  = 1100   -- skip tour nếu đã nhặt hơn số này
local LOADING_PROGRESS_TIMEOUT = 60
local LOADING_DISMISS_TIMEOUT  = 30
local BASE_UI_W, BASE_UI_H     = 300, 210

-- Claim reward (sau khi nhặt hết 1215 chest lần đầu)
local OP_CLAIM     = "\026"

-- Auto Buy Key
local OP_BUY       = "1"
local BUY_FLAG     = "\001"
local SHOP_ENTITY  = "53750"
local BUY_ITEM     = "Common Key"
local BUY_INTERVAL = 5

local VALID_IDS = {}
for i = 1, 1225 do
    if i < 1100 or i > 1109 then VALID_IDS[i] = true end
end

-- ===== CLAIM REWARD =====
local lastClaimTime = 0
local CLAIM_INTERVAL = 5   -- giây giữa mỗi lần claim trong lúc chờ respawn

local function claimReward()
    lastClaimTime = tick()
    pcall(function()
        Reliable:FireServer(buffer.fromstring(OP_CLAIM), { { { Action = "Claim" } } })
    end)
    print("[Claim] Fired ✓")
end

-- Claim ngay khi script chạy (mới vào game)
task.spawn(function() task.wait(2); claimReward() end)

-- ===== AUTO BUY KEY =====
local autoBuyKey  = false
local lastBuyTime = 0
local BuyStatusLbl

local function buyKey()
    pcall(function()
        SkillReq:FireServer(buffer.fromstring(OP_BUY), BUY_FLAG, {{SHOP_ENTITY, {BUY_ITEM}}})
    end)
end

task.spawn(function()
    while task.wait(1) do
        if not autoBuyKey then
            if BuyStatusLbl then BuyStatusLbl.Text = "" end
            continue
        end
        local left = math.ceil(BUY_INTERVAL - (tick() - lastBuyTime))
        if BuyStatusLbl then
            BuyStatusLbl.Text = left > 0 and string.format("key in %ds", left) or "buying..."
        end
        if tick() - lastBuyTime >= BUY_INTERVAL then
            lastBuyTime = tick(); buyKey()
        end
    end
end)

-- ===== DATA =====
local chestPositions = {}
local dataFolder     = nil
local skipCounts     = {}
local respawnSignal  = false   -- set bởi background monitor khi phát hiện unc tăng
local lastUncSaved   = 0       -- giá trị unc lần check trước

local function getDataFolder()
    if dataFolder and dataFolder.Parent then return dataFolder end
    local ok, f = pcall(function()
        return player:WaitForChild("Data",10):WaitForChild("Chests",10):WaitForChild("1",10)
    end)
    dataFolder = ok and f or nil
    return dataFolder
end

-- Snapshot toàn bộ attributes 1 lần → dùng cho cả pass (tránh gọi lặp)
local function snapshotAttributes()
    local f = getDataFolder()
    local snap = {}
    if f then
        for id, v in pairs(f:GetAttributes()) do snap[id] = v end
    end
    return snap
end

local function getCollectedCount(snap)
    if snap then
        local n = 0
        for _, v in pairs(snap) do if v == true then n = n + 1 end end
        return n
    end
    local f = getDataFolder(); if not f then return 0 end
    local n = 0
    for _, v in pairs(f:GetAttributes()) do if v == true then n = n + 1 end end
    return n
end

-- Real-time check (dùng sau khi collect để verify)
local function isCollectedRT(id)
    local f = getDataFolder(); if not f then return false end
    return f:GetAttribute(tostring(id)) == true
end

local function getDataUncollectedCount()
    local f = getDataFolder(); if not f then return 0 end
    local n = 0
    for _, v in pairs(f:GetAttributes()) do if v ~= true then n = n + 1 end end
    return n
end

-- Build danh sách chưa nhặt từ snapshot (O(n) thay vì O(n²))
local function buildUncollectedList(snap)
    local list = {}
    for id, pos in pairs(chestPositions) do
        local n = tonumber(id)
        if n and VALID_IDS[n]
           and snap[id] ~= true
           and (pos[1] ~= 0 or pos[2] ~= 0 or pos[3] ~= 0)
           and (skipCounts[id] or 0) < MAX_SKIP then
            table.insert(list, {id=id, n=n, pos=pos})
        end
    end
    table.sort(list, function(a,b) return a.n < b.n end)
    return list
end

-- ===== LOAD POSITIONS (local file > GitHub) =====
local LOCAL_POS_FILE = "ChestPositions.txt"

local function loadPositions()
    local txt, source

    -- Ưu tiên local file trong workspace executor (offline-friendly + nhanh)
    local hasLocal = false
    pcall(function() hasLocal = isfile and isfile(LOCAL_POS_FILE) end)
    if hasLocal then
        local ok, content = pcall(readfile, LOCAL_POS_FILE)
        if ok and content and content ~= "" then
            txt, source = content, "local: " .. LOCAL_POS_FILE
        end
    end

    -- Fallback: GitHub
    if not txt then
        local ok, t = pcall(game.HttpGet, game, GITHUB_URL)
        if ok and t and t ~= "" then txt, source = t, "GitHub" end
    end

    if not txt then return false, "Không có pos (local + GitHub đều fail)" end

    local count = 0
    for line in txt:gmatch("[^\n\r]+") do
        local id, x, y, z = line:match("^(%d+),([-%.%d]+),([-%.%d]+),([-%.%d]+)$")
        if id then
            local nx, ny, nz = tonumber(x), tonumber(y), tonumber(z)
            if math.abs(nx) > 0.5 or math.abs(ny) > 0.5 or math.abs(nz) > 0.5 then
                chestPositions[id] = {nx, ny, nz}
                count = count + 1
            end
        end
    end
    return count > 0, count, source
end

-- ===== HELPERS =====
local function getHRP()
    local c = player.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function getChestRoot(chest)
    return chest:FindFirstChild("RootPart") or chest:FindFirstChildWhichIsA("BasePart")
end

local function touchChestRoot(hrp, root, forcePhysical)
    if not hrp or not root then return false end

    local touched = false
    if type(firetouchinterest) == "function" then
        touched = pcall(function()
            firetouchinterest(hrp, root, 0)
            task.wait(0.04)
            firetouchinterest(hrp, root, 1)
        end)
    end

    -- Mobile executors may not expose firetouchinterest reliably.
    if forcePhysical or not touched then
        pcall(function()
            hrp.CFrame = root.CFrame + Vector3.new(0, 0.5, 0)
            hrp.AssemblyLinearVelocity = Vector3.zero
            hrp.AssemblyAngularVelocity = Vector3.zero
        end)
    end

    return touched
end

-- collectVisible: chỉ dùng root part (không GetDescendants)
local function collectVisible()
    local hrp = getHRP(); if not hrp then return end
    for _, chest in ipairs(Chests:GetChildren()) do
        local root = getChestRoot(chest)
        if root then touchChestRoot(hrp, root, true) end
    end
end

-- Lấy danh sách ID uncollected mà không có pos trong chestPositions
local function getMissingPosIds()
    local f = getDataFolder(); if not f then return {} end
    local missing = {}
    for id, v in pairs(f:GetAttributes()) do
        if v ~= true then
            local n = tonumber(id)
            if n and VALID_IDS[n] and not chestPositions[id] then
                table.insert(missing, id)
            end
        end
    end
    return missing
end

local function waitForCharacter()
    local c = player.Character
    if c and c:FindFirstChild("HumanoidRootPart")
           and c:FindFirstChildOfClass("Humanoid")
           and c:FindFirstChildOfClass("Humanoid").Health > 0 then return c end
    c = player.CharacterAdded:Wait()
    c:WaitForChild("HumanoidRootPart", 15)
    task.wait(1.5)
    return player.Character
end

local function getViewportSize()
    local cam = workspace.CurrentCamera
    return cam and cam.ViewportSize or Vector2.new(BASE_UI_W, BASE_UI_H)
end

-- ===== GUI =====
local existing = player.PlayerGui:FindFirstChild("ChestAutoFarm")
if existing then existing:Destroy() end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "ChestAutoFarm"; ScreenGui.ResetOnSpawn = false
ScreenGui.IgnoreGuiInset = true
ScreenGui.Parent = player.PlayerGui

local Frame = Instance.new("Frame", ScreenGui)
Frame.Size             = UDim2.fromOffset(BASE_UI_W, BASE_UI_H)
Frame.AnchorPoint      = Vector2.new(0.5, 0)
Frame.Position         = UDim2.new(0.5, 0, 0, 16)
Frame.BackgroundColor3 = Color3.fromRGB(11, 11, 16)
Frame.BorderSizePixel  = 0; Frame.Active = true; Frame.Draggable = true
local FrameScale = Instance.new("UIScale", Frame)

local function fitFrameToViewport()
    local vp = getViewportSize()
    local scaleX = (vp.X - 8) / BASE_UI_W
    local scaleY = (vp.Y - 8) / BASE_UI_H
    local scale = math.clamp(math.min(scaleX, scaleY), 0.35, 1)
    FrameScale.Scale = scale

    local safeY = 0 -- ScreenGui.IgnoreGuiInset = true; keep tiny mobile viewports usable.
    local centeredY = (vp.Y - BASE_UI_H * scale) * 0.5
    local y = math.max(2 + safeY, math.min(16 + safeY, centeredY))
    Frame.Position = UDim2.new(0.5, 0, 0, y)
end

fitFrameToViewport()
task.spawn(function()
    while not workspace.CurrentCamera do
        workspace:GetPropertyChangedSignal("CurrentCamera"):Wait()
    end
    local cam = workspace.CurrentCamera
    cam:GetPropertyChangedSignal("ViewportSize"):Connect(fitFrameToViewport)
    fitFrameToViewport()
end)
Instance.new("UICorner", Frame).CornerRadius = UDim.new(0, 10)
local Stroke = Instance.new("UIStroke", Frame)
Stroke.Color = Color3.fromRGB(255,190,50); Stroke.Thickness = 1.5; Stroke.Transparency = 0.25

local TBar = Instance.new("Frame", Frame)
TBar.Size = UDim2.new(1,0,0,28); TBar.BackgroundColor3 = Color3.fromRGB(150,100,8)
TBar.BorderSizePixel = 0
Instance.new("UICorner", TBar).CornerRadius = UDim.new(0,10)
local TFix = Instance.new("Frame", TBar)
TFix.Size = UDim2.new(1,0,0.5,0); TFix.Position = UDim2.new(0,0,0.5,0)
TFix.BackgroundColor3 = Color3.fromRGB(150,100,8); TFix.BorderSizePixel = 0
local TitleLbl = Instance.new("TextLabel", TBar)
TitleLbl.Size = UDim2.fromScale(1,1); TitleLbl.BackgroundTransparency = 1
TitleLbl.Text = "📦  Chest Auto Farm"; TitleLbl.Font = Enum.Font.GothamBold; TitleLbl.TextSize = 13
TitleLbl.TextColor3 = Color3.fromRGB(255,230,150)

local function makeLbl(y, h, txt, color, align)
    local l = Instance.new("TextLabel", Frame)
    l.Size = UDim2.new(1,-16,0,h); l.Position = UDim2.new(0,8,0,y)
    l.BackgroundTransparency = 1; l.Text = txt; l.TextWrapped = true
    l.TextColor3 = color or Color3.fromRGB(195,205,215)
    l.Font = Enum.Font.Gotham; l.TextSize = 11
    l.TextXAlignment = align or Enum.TextXAlignment.Left
    return l
end

local PhaseLbl  = makeLbl(34, 16, "Đang khởi động...", Color3.fromRGB(100,210,255))
local DetailLbl = makeLbl(51, 16, "",                   Color3.fromRGB(150,155,165))
local CollLbl   = makeLbl(68, 16, "—",                  Color3.fromRGB(255,200,55))

local BarBG = Instance.new("Frame", Frame)
BarBG.Size = UDim2.new(1,-16,0,7); BarBG.Position = UDim2.new(0,8,0,89)
BarBG.BackgroundColor3 = Color3.fromRGB(25,25,35); BarBG.BorderSizePixel = 0
Instance.new("UICorner", BarBG).CornerRadius = UDim.new(1,0)
local BarFill = Instance.new("Frame", BarBG)
BarFill.Size = UDim2.new(0,0,1,0); BarFill.BackgroundColor3 = Color3.fromRGB(255,190,50)
BarFill.BorderSizePixel = 0
Instance.new("UICorner", BarFill).CornerRadius = UDim.new(1,0)

local CycleLbl = makeLbl(101, 14, "Cycle: —", Color3.fromRGB(110,115,125))
local TimeLbl  = makeLbl(101, 14, "",          Color3.fromRGB(100,100,110), Enum.TextXAlignment.Right)

local StopBtn = Instance.new("TextButton", Frame)
StopBtn.Size = UDim2.new(1,-16,0,28); StopBtn.Position = UDim2.new(0,8,0,120)
StopBtn.BackgroundColor3 = Color3.fromRGB(80,18,18); StopBtn.BorderSizePixel = 0
StopBtn.Font = Enum.Font.GothamBold; StopBtn.TextSize = 11
StopBtn.Text = "■  Stop"; StopBtn.TextColor3 = Color3.fromRGB(255,110,110)
Instance.new("UICorner", StopBtn).CornerRadius = UDim.new(0,6)

local BuyBtn = Instance.new("TextButton", Frame)
BuyBtn.Size = UDim2.new(1,-16,0,26); BuyBtn.Position = UDim2.new(0,8,0,154)
BuyBtn.BackgroundColor3 = Color3.fromRGB(25,55,25); BuyBtn.BorderSizePixel = 0
BuyBtn.Font = Enum.Font.GothamBold; BuyBtn.TextSize = 11
BuyBtn.Text = "🔑  Auto Buy Key: OFF"; BuyBtn.TextColor3 = Color3.fromRGB(140,180,140)
Instance.new("UICorner", BuyBtn).CornerRadius = UDim.new(0,6)

BuyBtn.MouseButton1Click:Connect(function()
    autoBuyKey = not autoBuyKey
    if autoBuyKey then
        BuyBtn.Text = "🔑  Auto Buy Key: ON"
        BuyBtn.TextColor3 = Color3.fromRGB(100,255,120)
        BuyBtn.BackgroundColor3 = Color3.fromRGB(15,75,25)
        buyKey()
    else
        BuyBtn.Text = "🔑  Auto Buy Key: OFF"
        BuyBtn.TextColor3 = Color3.fromRGB(140,180,140)
        BuyBtn.BackgroundColor3 = Color3.fromRGB(25,55,25)
    end
end)

BuyStatusLbl = makeLbl(183, 13, "", Color3.fromRGB(100,140,100), Enum.TextXAlignment.Center)

local posTotal = 0
local function setBar(collected, dataLeft)
    dataLeft = dataLeft or getDataUncollectedCount()
    local total = math.max(collected + dataLeft, posTotal, 1)
    local pct   = math.clamp(collected / total, 0, 1)
    BarFill.Size = UDim2.new(pct, 0, 1, 0)
    CollLbl.Text = dataLeft > 0
        and string.format("%d nhặt  |  %d còn", collected, dataLeft)
        or  string.format("%d / %d  ✓", collected, total)
    BarFill.BackgroundColor3 =
        pct >= 1   and Color3.fromRGB(80,255,140) or
        pct >= 0.5 and Color3.fromRGB(255,210,50)  or
                       Color3.fromRGB(255,130,50)
end

-- ===== CORE LOGIC =====
local isRunning  = false
local cycleNum   = 0
local t0         = tick()
local forceTour  = false   -- sau khi detect respawn → tour bất kể collected count

-- Tour map, tìm đúng những ID thiếu pos trong workspace → lấy pos & collect luôn
local function searchAndCollectMissing(missingIds)
    if #missingIds == 0 then return 0 end
    PhaseLbl.Text = string.format("🔍  Tour tìm %d chest thiếu pos...", #missingIds)

    local missingSet = {}
    for _, id in ipairs(missingIds) do missingSet[id] = true end

    local found = 0
    local islands = Map:GetChildren()
    for i, island in ipairs(islands) do
        if not isRunning then break end
        DetailLbl.Text = string.format("→ %s  [%d/%d]", island.Name, i, #islands)

        local hrp = getHRP()
        if hrp then
            local ok, cf, sz = pcall(function() return island:GetBoundingBox() end)
            if ok and cf then
                hrp.CFrame = CFrame.new(cf.Position + Vector3.new(0, (sz and sz.Y/2 or 0) + 15, 0))
            end
        end
        task.wait(TOUR_DELAY)

        for _, chest in ipairs(Chests:GetChildren()) do
            if missingSet[chest.Name] then
                local root = getChestRoot(chest)
                if root then
                    local p = root.Position
                    if math.abs(p.X) > 0.5 or math.abs(p.Y) > 0.5 or math.abs(p.Z) > 0.5 then
                        chestPositions[chest.Name] = {p.X, p.Y, p.Z}
                        missingSet[chest.Name] = nil
                        found = found + 1
                        print(string.format("[MissingPos] Found #%s → %.2f,%.2f,%.2f  (thêm vào GitHub!)",
                            chest.Name, p.X, p.Y, p.Z))
                        local h = getHRP()
                        if h then
                            h.CFrame = CFrame.new(p + Vector3.new(0, TP_HEIGHT, 0))
                            task.wait(0.15)
                            touchChestRoot(h, root, true)
                        end
                    end
                end
            end
        end

        local rem = 0; for _ in pairs(missingSet) do rem = rem + 1 end
        if rem == 0 then break end
    end

    local rem = 0; for _ in pairs(missingSet) do rem = rem + 1 end
    DetailLbl.Text = string.format("Tìm được %d | còn thiếu %d", found, rem)
    return found
end

-- Forced TP retry: TP đến TỪNG uncollected có pos (bypass skipCounts).
-- Dùng cho 1-3 chest cuối bị kẹt do streaming/skip — wait dài + 3 attempts.
local function forcedRetryAll()
    local f = getDataFolder(); if not f then return 0 end
    local todo = {}
    for id, v in pairs(f:GetAttributes()) do
        if v ~= true then
            local pos = chestPositions[id]
            local n = tonumber(id)
            if pos and n and VALID_IDS[n] then
                table.insert(todo, {id=id, pos=pos})
            end
        end
    end
    if #todo == 0 then return 0 end

    PhaseLbl.Text = string.format("🎯  Forced TP %d chest còn lại...", #todo)
    skipCounts    = {}   -- reset để collectPass sau có thể retry nếu cần
    local got     = 0

    for i, item in ipairs(todo) do
        if not isRunning then break end
        DetailLbl.Text = string.format("→ #%s  [%d/%d]  forced", item.id, i, #todo)

        for attempt = 1, 3 do
            if not isRunning or isCollectedRT(item.id) then break end
            local hrp = getHRP()
            if not hrp then waitForCharacter(); hrp = getHRP() end
            if hrp then
                hrp.CFrame = CFrame.new(item.pos[1], item.pos[2] + TP_HEIGHT, item.pos[3])
                task.wait(0.7)   -- wait dài hơn collectPass cho streaming
                local chest = Chests:FindFirstChild(item.id)
                if not chest then
                    task.wait(0.6)
                    chest = Chests:FindFirstChild(item.id)
                end
                if chest then
                    local root = getChestRoot(chest)
                    if root then touchChestRoot(hrp, root, true) end
                end
            end
            task.wait(0.2)
        end

        if isCollectedRT(item.id) then got = got + 1 end
    end

    DetailLbl.Text = string.format("Forced: nhặt được %d/%d", got, #todo)
    return got
end

-- Tour đảo: chỉ để load streaming, không spam collectVisible
local function phaseTour()
    PhaseLbl.Text = "🗺  Tour Islands..."
    local islands = Map:GetChildren()
    for i, island in ipairs(islands) do
        if not isRunning then return end
        DetailLbl.Text = string.format("→ %s  [%d/%d]", island.Name, i, #islands)
        local hrp = getHRP()
        if hrp then
            local ok, cf, sz = pcall(function() return island:GetBoundingBox() end)
            if ok and cf then
                hrp.CFrame = CFrame.new(cf.Position + Vector3.new(0, (sz and sz.Y/2 or 0) + 15, 0))
            end
        end
        task.wait(TOUR_DELAY)
        -- 1 lần collectVisible sau delay (không loop)
        collectVisible()
    end
    DetailLbl.Text = "Tour xong!"
end

-- ===== COLLECT PASS (core) =====
-- uncAtStart: getDataUncollectedCount() trước khi pass, để detect respawn
-- Trả về: got, total, respawnDetected
local function collectPass(uncAtStart)
    -- Reset signal, khởi tạo baseline cho monitor
    respawnSignal = false
    lastUncSaved  = uncAtStart

    local snap  = snapshotAttributes()
    local list  = buildUncollectedList(snap)
    local total = #list
    if total == 0 then return 0, 0, false end

    PhaseLbl.Text = string.format("📦  Collecting  (%d chest)", total)
    local got = 0

    for i, item in ipairs(list) do
        if not isRunning then break end

        -- Background monitor đã phát hiện unc tăng → thoát ngay
        if respawnSignal then
            local curUnc = getDataUncollectedCount()
            setBar(getCollectedCount(), curUnc)
            return got, total, true
        end

        if isCollectedRT(item.id) then
            skipCounts[item.id] = nil; got = got + 1; continue
        end

        local t = tick()
        DetailLbl.Text = string.format("→ #%s  [%d/%d]", item.id, i, total)

        local hrp = getHRP()
        if not hrp then waitForCharacter(); task.wait(0.3); hrp = getHRP() end
        if not hrp then continue end

        hrp.CFrame = CFrame.new(item.pos[1], item.pos[2] + TP_HEIGHT, item.pos[3])
        task.wait(CHEST_WAIT)

        local chest = Chests:FindFirstChild(item.id)
        if not chest then
            task.wait(CHEST_RETRY)
            chest = Chests:FindFirstChild(item.id)
        end

        if chest then
            local root = getChestRoot(chest)
            if root then touchChestRoot(hrp, root, true) end

            -- Chest có trong workspace nhưng không collect được → mới tăng skip
            if isCollectedRT(item.id) then
                skipCounts[item.id] = nil; got = got + 1
            else
                skipCounts[item.id] = (skipCounts[item.id] or 0) + 1
            end
        else
            -- Chest chưa load vào workspace (streaming) → KHÔNG tăng skip
            -- Không phạt chest chưa tồn tại, tránh bị filter sớm
            if isCollectedRT(item.id) then
                skipCounts[item.id] = nil; got = got + 1
            end
        end

        -- Update bar mỗi 10 chest
        if i % 10 == 0 then setBar(getCollectedCount()) end

        local elapsed = tick() - t
        if elapsed < PACE_MIN then task.wait(PACE_MIN - elapsed) end
    end

    setBar(getCollectedCount())
    return got, total, false
end

-- Đợi chests respawn: detect khi uncollected TĂNG (không phải giảm)
-- hoặc CharacterAdded (game kill player sau khi collect hết)
local function waitForRespawn(collectedSnap)
    BarFill.BackgroundColor3 = Color3.fromRGB(80, 255, 140)
    local uncSnap    = getDataUncollectedCount()
    local respawned  = false
    local conn = player.CharacterAdded:Connect(function() respawned = true end)
    local deadline   = tick() + 600

    -- Claim ngay khi vào chờ respawn
    claimReward()

    while isRunning and not respawned and tick() < deadline do
        task.wait(3)
        local curCollected = getCollectedCount()
        local curUnc       = getDataUncollectedCount()
        local left         = math.ceil(math.max(0, deadline - tick()))
        DetailLbl.Text = string.format(
            "%d nhặt | %d còn  [chờ respawn %ds]", curCollected, curUnc, left)

        -- Fallback claim mỗi 30s trong khi chờ
        if tick() - lastClaimTime >= CLAIM_INTERVAL then
            claimReward()
        end

        -- Chest respawn: bất kỳ tăng nào là qua cycle mới
        if curUnc > uncSnap + 1 then break end
        -- Hoặc data reset: collected giảm mạnh
        if curCollected < collectedSnap - 10 then break end
    end

    conn:Disconnect()
    skipCounts    = {}
    forceTour     = true
    respawnSignal = false
    lastUncSaved  = 0
    task.wait(2)
end

-- ===== MAIN LOOP =====
StopBtn.MouseButton1Click:Connect(function()
    isRunning = false
    PhaseLbl.Text = "⏹  Đã dừng"; DetailLbl.Text = ""
    StopBtn.Text  = "■  Stopped"
    StopBtn.BackgroundColor3 = Color3.fromRGB(45,45,45)
    StopBtn.TextColor3       = Color3.fromRGB(130,130,130)
end)

task.spawn(function()
    while task.wait(1) do
        if isRunning then
            local e = math.floor(tick() - t0)
            TimeLbl.Text = string.format("⏱ %d:%02d", math.floor(e/60), e%60)
        end
    end
end)

-- Background respawn monitor: lưu số unc mỗi 1.5s, tăng = respawn → signal ngay
task.spawn(function()
    while task.wait(1.5) do
        if not isRunning then lastUncSaved = 0; continue end
        local curUnc = getDataUncollectedCount()
        if lastUncSaved > 0 and curUnc > lastUncSaved then
            -- Uncollected tăng = chests vừa respawn
            respawnSignal = true
        end
        lastUncSaved = curUnc
    end
end)

-- CharacterAdded = game kill player (sau khi nhặt hết) → cũng là tín hiệu respawn
player.CharacterAdded:Connect(function()
    if isRunning then respawnSignal = true end
end)

-- Passive collector: chạy song song với TP active, bắt chest đã load (không tốn TP riêng)
task.spawn(function()
    while task.wait(1) do
        if not isRunning then continue end
        local hrp = getHRP()
        if not hrp then continue end
        local snap = snapshotAttributes()
        for _, chest in ipairs(Chests:GetChildren()) do
            local n = tonumber(chest.Name)
            if n and VALID_IDS[n] and snap[chest.Name] ~= true then
                local root = getChestRoot(chest)
                if root then touchChestRoot(hrp, root) end
            end
        end
    end
end)

-- ===== LOADING SCREEN HANDLER =====
local function waitForLoadingScreen()
    local gui = player:WaitForChild("PlayerGui", 30)
    if not gui then return end

    local loadingGui = gui:FindFirstChild("LoadingGui")
    if not loadingGui then return end   -- đã qua loading rồi

    PhaseLbl.Text = "⏳  Chờ game load..."

    -- Chờ Progress == 1
    local progress = loadingGui:FindFirstChild("Progress")
    if progress then
        local progressDeadline = tick() + LOADING_PROGRESS_TIMEOUT
        while (tonumber(progress.Value) or 0) < 1 and tick() < progressDeadline do
            DetailLbl.Text = string.format("Loading... %.0f%%", (tonumber(progress.Value) or 0) * 100)
            task.wait(0.3)
        end
    else
        task.wait(3)
    end
    task.wait(0.5)

    local VIM
    pcall(function()
        VIM = game:GetService("VirtualInputManager")
    end)

    local function getGuiInset()
        local ok, inset = pcall(function()
            return GuiService:GetGuiInset()
        end)
        return (ok and inset) or Vector2.new(0, 0)
    end

    local function sendKey(key)
        if not VIM then return end
        pcall(function()
            VIM:SendKeyEvent(true, key, false, game)
            task.wait(0.04)
            VIM:SendKeyEvent(false, key, false, game)
        end)
    end

    local function sendMouseTap(x, y)
        if not VIM then return end
        pcall(function()
            VIM:SendMouseButtonEvent(x, y, 0, true, game, 0)
            task.wait(0.04)
            VIM:SendMouseButtonEvent(x, y, 0, false, game, 0)
        end)
    end

    local function sendTouchTap(x, y)
        if not VIM then return end
        pcall(function()
            VIM:SendTouchEvent(0, Enum.UserInputState.Begin, x, y)
            task.wait(0.04)
            VIM:SendTouchEvent(0, Enum.UserInputState.End, x, y)
        end)
        -- Some mobile executors expose a nonstandard bool-style signature.
        pcall(function()
            VIM:SendTouchEvent(x, y, 0, true, game)
            task.wait(0.04)
            VIM:SendTouchEvent(x, y, 0, false, game)
        end)
    end

    local function tapScreen(x, y)
        if not VIM then return end
        local vp = getViewportSize()
        local inset = getGuiInset()
        local points = {
            Vector2.new(x, y),
            Vector2.new(x + inset.X, y + inset.Y),
            Vector2.new(x, y + inset.Y),
            Vector2.new(x - inset.X, y - inset.Y),
        }
        for _, p in ipairs(points) do
            local px = math.clamp(math.floor(p.X + 0.5), 1, math.max(1, vp.X - 1))
            local py = math.clamp(math.floor(p.Y + 0.5), 1, math.max(1, vp.Y - 1))
            sendMouseTap(px, py)
            sendTouchTap(px, py)
        end
    end

    local function fireEvent(event, ...)
        if not event then return end
        local args = { ... }
        if firesignal then
            pcall(function() firesignal(event, table.unpack(args)) end)
        end
        if getconnections then
            local ok, conns = pcall(getconnections, event)
            if ok and conns then
                for _, conn in pairs(conns) do
                    if conn.Function then
                        pcall(function() conn.Function(table.unpack(args)) end)
                    end
                    if conn.Fire then
                        pcall(function() conn:Fire(table.unpack(args)) end)
                    end
                end
            end
        end
    end

    local function fireGuiInput(obj, x, y)
        if not obj then return end
        local pos2 = Vector2.new(x, y)
        local fakeTouchBegin = {
            UserInputType = Enum.UserInputType.Touch,
            UserInputState = Enum.UserInputState.Begin,
            Position = Vector3.new(x, y, 0),
        }
        local fakeTouchEnd = {
            UserInputType = Enum.UserInputType.Touch,
            UserInputState = Enum.UserInputState.End,
            Position = Vector3.new(x, y, 0),
        }
        local fakeMouseBegin = {
            UserInputType = Enum.UserInputType.MouseButton1,
            UserInputState = Enum.UserInputState.Begin,
            Position = Vector3.new(x, y, 0),
        }
        local fakeMouseEnd = {
            UserInputType = Enum.UserInputType.MouseButton1,
            UserInputState = Enum.UserInputState.End,
            Position = Vector3.new(x, y, 0),
        }

        local okTouchTap, touchTap = pcall(function() return obj.TouchTap end)
        if okTouchTap then fireEvent(touchTap, { pos2 }, false) end

        local okInputBegan, inputBegan = pcall(function() return obj.InputBegan end)
        if okInputBegan then
            fireEvent(inputBegan, fakeTouchBegin, false)
            fireEvent(inputBegan, fakeMouseBegin, false)
        end

        local okInputEnded, inputEnded = pcall(function() return obj.InputEnded end)
        if okInputEnded then
            fireEvent(inputEnded, fakeTouchEnd, false)
            fireEvent(inputEnded, fakeMouseEnd, false)
        end
    end

    local function fireBtn(obj)
        if not obj then return end
        for _, evName in ipairs({ "Activated", "MouseButton1Click", "MouseButton1Down", "MouseButton1Up" }) do
            local ok, event = pcall(function() return obj[evName] end)
            if ok then fireEvent(event) end
        end
        pcall(function() obj:Activate() end)
        pcall(function() GuiService.SelectedObject = obj end)
        sendKey(Enum.KeyCode.Return)
        sendKey(Enum.KeyCode.Space)
    end

    local function clickGuiObject(obj)
        if not obj or not obj:IsA("GuiObject") then return end
        fireBtn(obj)
        local pos = obj.AbsolutePosition
        local size = obj.AbsoluteSize
        if size.X > 0 and size.Y > 0 then
            local x = pos.X + size.X / 2
            local y = pos.Y + size.Y / 2
            fireGuiInput(obj, x, y)
            tapScreen(x, y)
            task.wait(0.05)
            fireGuiInput(obj, x, y)
            fireBtn(obj)
        end
    end

    local function getLoadingTargets()
        local targets, seen = {}, {}
        local function add(obj, score)
            if obj and obj:IsA("GuiObject") and not seen[obj] then
                seen[obj] = true
                table.insert(targets, { obj = obj, score = score + (obj.Visible and 0 or 50) })
            end
        end

        add(loadingGui:FindFirstChild("CloseButton", true), 1)
        add(loadingGui:FindFirstChild("Screen", true), 2)

        for _, obj in ipairs(loadingGui:GetDescendants()) do
            if obj:IsA("GuiObject") then
                local text = ""
                pcall(function() text = obj.Text or "" end)
                local label = (obj.Name .. " " .. text):lower()
                local score = obj:IsA("GuiButton") and 20 or 100
                if label:find("closebutton", 1, true) then score = 1
                elseif label:find("close", 1, true) then score = 2
                elseif label:find("continue", 1, true) then score = 3
                elseif label:find("screen", 1, true) then score = 4
                elseif label:find("skip", 1, true) then score = 5
                elseif label:find("play", 1, true) then score = 6
                end
                if obj:IsA("GuiButton") or score < 100 then add(obj, score) end
            end
        end

        table.sort(targets, function(a, b) return a.score < b.score end)
        return targets
    end

    local function loadingStillVisible()
        if not loadingGui.Parent then return false end
        if loadingGui:IsA("ScreenGui") and loadingGui.Enabled == false then return false end
        return true
    end

    -- Loop liên tục: thử cả Continue lẫn CloseButton mỗi giây
    -- cho đến khi loadingGui tự biến mất; mobile fallback sẽ đi tiếp sau timeout
    local deadline = tick() + LOADING_DISMISS_TIMEOUT
    local step     = 0
    while loadingStillVisible() and tick() < deadline do
        step = step + 1

        -- Bước A: VIM click giữa màn hình → dismiss "Click to Continue"
        DetailLbl.Text = string.format("Loading... click #%d", step)
        local vp = getViewportSize()
        tapScreen(vp.X / 2, vp.Y / 2)
        sendKey(Enum.KeyCode.Return)
        sendKey(Enum.KeyCode.Space)

        -- Bước B: tìm tất cả nút loading hiện có, ưu tiên Screen/Continue/CloseButton.
        local targets = getLoadingTargets()
        for i, item in ipairs(targets) do
            if i > 6 or not loadingStillVisible() then break end
            DetailLbl.Text = string.format("Loading... btn #%d.%d", step, i)
            clickGuiObject(item.obj)
            task.wait(0.05)
        end

        task.wait(1)
    end

    if loadingStillVisible() then
        DetailLbl.Text = "Loading timeout, continuing..."
        pcall(function() loadingGui.Enabled = false end)
        pcall(function() loadingGui:Destroy() end)
    end

    DetailLbl.Text = "Loading done ✓"
    task.wait(0.5)
end

task.spawn(function()
    waitForLoadingScreen()

    PhaseLbl.Text = "⏳  Loading..."; DetailLbl.Text = "Đang tải positions..."
    local ok, info, source = loadPositions()
    if not ok then
        PhaseLbl.Text = "❌  Load thất bại"; DetailLbl.Text = tostring(info); return
    end
    posTotal = 0
    for _ in pairs(chestPositions) do posTotal = posTotal + 1 end
    DetailLbl.Text = string.format("✓ %d positions  (%s)", posTotal, source or "?")
    task.wait(0.5)

    isRunning = true; t0 = tick()

    while isRunning do
        cycleNum = cycleNum + 1
        CycleLbl.Text = "Cycle: " .. cycleNum

        waitForCharacter()
        if not isRunning then break end

        -- ─── Tour hay collect thẳng? ───────────────────────────────────
        -- Tour chỉ chạy cycle đầu hoặc sau respawn (forceTour=true)
        local unc0 = getDataUncollectedCount()
        if cycleNum == 1 or forceTour then
            forceTour = false
            phaseTour()
            if not isRunning then break end
        else
            PhaseLbl.Text  = string.format("⚡  Skip Tour  (còn %d chest)", unc0)
            DetailLbl.Text = "Collect thẳng"
            task.wait(0.5)
        end

        -- ─── Collect loop ───────────────────────────────────────────────
        local noProgress = 0

        while isRunning do
            local uncAtStart             = getDataUncollectedCount()
            local got, total, didRespawn = collectPass(uncAtStart)
            if not isRunning then break end

            -- ── Respawn xảy ra giữa lúc collect ──────────────────────
            if didRespawn then
                claimReward()   -- game kill player = đã nhặt hết → claim luôn
                PhaseLbl.Text  = "🔄  Chests respawned! — Tour cycle mới..."
                DetailLbl.Text = ""
                skipCounts     = {}
                forceTour      = true
                break
            end

            -- ── List rỗng: tất cả đã nhặt hoặc skip ─────────────────
            if total == 0 then
                local dataLeft  = getDataUncollectedCount()
                local collected = getCollectedCount()

                if dataLeft == 0 then
                    PhaseLbl.Text = "✅  Xong! — chờ respawn..."
                else
                    -- Chest không có pos → tour tìm đúng ID trong workspace
                    local missing = getMissingPosIds()
                    if #missing > 0 then
                        searchAndCollectMissing(missing)
                    else
                        -- ID có pos nhưng đều bị skip → FORCED TP retry (bypass skipCounts)
                        forcedRetryAll()
                    end
                    collected = getCollectedCount()
                    dataLeft  = getDataUncollectedCount()
                    PhaseLbl.Text = dataLeft == 0
                        and "✅  Xong! — chờ respawn..."
                        or  string.format("⚠  %d còn lại — chờ respawn...", dataLeft)
                end

                setBar(collected, dataLeft)
                claimReward()
                waitForRespawn(collected)
                break
            end

            -- ── Pass không nhặt được gì ──────────────────────────────
            if got == 0 then
                noProgress = noProgress + 1
                local collected = getCollectedCount()

                -- < 500 nhặt: streaming có thể chưa đủ → tour lại (tối đa 2×)
                if collected < 500 and noProgress <= 2 then
                    PhaseLbl.Text = string.format(
                        "↩  %d chest chưa load — tour lại (%d/2)...", total, noProgress)
                    phaseTour()
                    if not isRunning then break end
                    skipCounts = {}
                    task.wait(0.3)
                else
                    -- Gần xong rồi: thử forced TP retry trước khi cho ngủ
                    local retried = forcedRetryAll()
                    if not isRunning then break end
                    if retried > 0 then
                        noProgress = 0   -- có tiến độ → quay lại collect pass
                        task.wait(0.3)
                    else
                        PhaseLbl.Text = string.format("⚠  Skip hết (%d) — chờ respawn...", total)
                        setBar(getCollectedCount())
                        claimReward()
                        waitForRespawn(getCollectedCount())
                        break
                    end
                end
            else
                noProgress = 0

                -- ── Proactive: nếu còn ít chest trong data nhưng buildList
                --    đang bỏ sót do skipCounts → reset để thử lại ──────────
                local dataLeft = getDataUncollectedCount()
                local inList   = total  -- số chest còn trong list pass vừa rồi
                if dataLeft > 0 and inList > 0 and dataLeft > inList then
                    -- Có chest bị skip (dataLeft > inList) → xem có đáng reset không
                    local stuckCount = dataLeft - inList
                    -- Nếu số chest bị skip > 0 và data còn ít (gần xong)
                    -- hoặc bị stuck quá nhiều so với list → reset skipCounts
                    if dataLeft <= 50 or stuckCount >= 30 then
                        PhaseLbl.Text = string.format(
                            "♻  Reset skip (%d chest kẹt) — thử lại...", stuckCount)
                        skipCounts = {}
                    end
                end

                task.wait(0.2)
            end
        end
    end
end)
