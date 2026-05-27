-- AutoFarm_Hub.lua v3 — Legend Piece
-- Rewrite: EnemyEnums DB, Farm/Boss/Skill tabs, dynamic Teleport, player stats

-- ===== LOAD UI =====
local Fluent          = loadstring(game:HttpGet("https://github.com/dawid-scripts/Fluent/releases/latest/download/main.lua"))()
local SaveManager     = loadstring(game:HttpGet("https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/SaveManager.lua"))()
local InterfaceManager= loadstring(game:HttpGet("https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/InterfaceManager.lua"))()

-- ===== SERVICES =====
local Players    = game:GetService("Players")
local RS         = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local VIM        = game:GetService("VirtualInputManager")
local player     = Players.LocalPlayer

local R           = RS:WaitForChild("Packages"):WaitForChild("Warp"):WaitForChild("Index"):WaitForChild("Event"):WaitForChild("Reliable")
local SkillReq    = RS:WaitForChild("Packages"):WaitForChild("Warp"):WaitForChild("Index"):WaitForChild("Event"):WaitForChild("Request")
local Holder      = workspace:WaitForChild("Holder")
local Mobs        = Holder:WaitForChild("Mobs")
local Map         = Holder:WaitForChild("Map")
local Chests      = Holder:WaitForChild("Chests")

-- ===== OPCODES =====
local OP_M1       = "8"      -- byte 56
local OP_QUEST    = ">"
local OP_SKILL    = "\005"
local OP_HAKI     = "\010"
local OP_STAT     = "<"
local OP_USE_ITEM = "*"      -- dùng item (Sea Beast's Orb)
local OP_INTERACT = "\021"   -- interact với entity (triệu hồi sea beast)
local SK_FLAG     = "\001"

-- Sea Beast
local SB_ORB_NAME  = "Sea Beast's Orb"
local SB_STONE_EID = "3508"   -- Entity ID phiến đá triệu hồi (có thể đổi)

-- ===== ENEMY DATABASE =====
-- [mobName] = { name, island, level, enemyType, spawnTime, rewards, skills, logia }
local EnemyDB = {}
local DB_LOADED = false

local function loadEnemyDB()
    local enumsFolder
    local paths = {
        { "Modules", "Enums", "EnemyEnums" },
        { "Assets", "Modules", "Enums", "EnemyEnums" },
        { "Modules", "Enums", "Enemy Enums" },
        { "Assets", "Modules", "Enums", "Enemy Enums" },
    }
    for _, path in ipairs(paths) do
        local ok, result = pcall(function()
            local cur = RS
            for _, part in ipairs(path) do
                cur = cur:WaitForChild(part, 3)
            end
            return cur
        end)
        if ok and result then enumsFolder = result; break end
    end
    if not enumsFolder then
        warn("[EnemyDB] EnemyEnums folder not found — tried 4 paths")
        return false
    end

    local count = 0
    for _, islandFolder in ipairs(enumsFolder:GetChildren()) do
        for _, mobModule in ipairs(islandFolder:GetChildren()) do
            if mobModule:IsA("ModuleScript") then
                local ok2, data = pcall(require, mobModule)
                if ok2 and type(data) == "table" then
                    EnemyDB[mobModule.Name] = {
                        name      = mobModule.Name,
                        island    = islandFolder.Name,
                        level     = data.Level     or 0,
                        enemyType = data.EnemyType or "Mob",
                        spawnTime = data.SpawnTime or 0,
                        rewards   = data.Rewards   or {},
                        skills    = data.Skills    or {},
                        logia     = data.Logia,
                    }
                    count += 1
                end
            end
        end
    end

    DB_LOADED = true
    print(string.format("[EnemyDB] Loaded %d entries", count))
    return count > 0
end

-- Kiểm tra enemy type có phải boss không (bắt WorldBoss, RaidBoss, Event, v.v.)
local function isBossType(enemyType)
    if not enemyType then return false end
    local t = enemyType:lower()
    return t == "boss"
        or t:find("boss")   ~= nil
        or t:find("raid")   ~= nil
        or t:find("world")  ~= nil
        or t:find("event")  ~= nil
        or t:find("legend") ~= nil
end

local function getDBList(filter)
    -- filter: nil = all, "Mob", "Boss"
    local list = {}
    for name, data in pairs(EnemyDB) do
        local match
        if not filter then
            match = true
        elseif filter == "Boss" then
            match = isBossType(data.enemyType)
        elseif filter == "Mob" then
            match = not isBossType(data.enemyType)
        else
            match = data.enemyType == filter
        end
        if match then table.insert(list, name) end
    end
    table.sort(list, function(a, b)
        return (EnemyDB[a] and EnemyDB[a].level or 0) < (EnemyDB[b] and EnemyDB[b].level or 0)
    end)
    return list
end

local function getDBDropItems()
    local items, seen = {}, {}
    local skip = { MasteryXP=true, XP=true, Coin=true }
    for _, data in pairs(EnemyDB) do
        for itemName in pairs(data.rewards or {}) do
            if type(itemName) == "string" and not skip[itemName] and not seen[itemName] then
                seen[itemName] = true
                table.insert(items, itemName)
            end
        end
    end
    table.sort(items)
    return items
end

local function getMobsDropping(itemName)
    local result = {}
    for _, data in pairs(EnemyDB) do
        if data.rewards and data.rewards[itemName] then
            table.insert(result, { name = data.name, data = data, rate = data.rewards[itemName] })
        end
    end
    table.sort(result, function(a, b) return (a.rate or 0) > (b.rate or 0) end)
    return result
end

local function findBestMobForLevel(playerLevel)
    local best, bestLevel = nil, -1
    for _, data in pairs(EnemyDB) do
        -- Chỉ lấy Mob thường (không lấy boss/raid/event)
        if not isBossType(data.enemyType)
           and data.level <= playerLevel
           and data.level > bestLevel then
            bestLevel = data.level
            best = data
        end
    end
    return best
end

-- ===== STATE =====
local State = {
    AutoFarm       = false,
    AutoFarmLevel  = false,
    AutoQuest      = false,
    OverwriteQuest = true,
    BringMob       = false,
    AutoSkill      = false,
    FastAttack     = false,
    HitPerPacket   = 2,     -- số hit gộp / packet (Fast Attack)
    PacketRate     = 0.1,   -- giây / packet (Fast Attack)

    SelectedTool   = nil,
    AutoToolDelay  = 1.0,   -- giây giữa các lần tự equip tool
    SelectedIsland = "ALL",
    SelectedMob    = nil,

    ESPChest      = false,
    FarmMode      = "Float",
    HeightAbove   = 6,
    FaceDownAngle = 80,
    FarmDistance  = 5,
    M1Cooldown    = 0.1,
    QuestInterval = 5,

    BossFarm        = false,
    BossTargetNames = {},
    BossSwitchTime  = 4,

    UseNetworkSkill = false,
    SkillEntityID   = nil,

    AutoHaki     = false,
    HakiInterval = 30,

    AutoSeaBeast   = false,
    SBPhase        = "idle",  -- "farm_guardian" | "summon" | "kill_beast"

    AutoHawkeye    = false,
    HWPhase        = "idle",  -- "idle" | "farm_knight" | "kill_hawkeye"

    AutoStats    = false,
    SelectedStat = nil,   -- "Melee" | "Defense" | "Sword" | "Fruit"

    _walkSpeed = 16,
    _jumpPower = 50,
}

local currentTarget  = nil
local lastAutoLevel  = nil

-- AutoHawkeye state
local hwTarget        = nil
local hwKMKills       = 0
local hwHEKills       = 0
local hwStartTime     = nil
local hwDetectorConns = {}
local hwBossRemaining = nil
local hwCounterMethod = nil
local hwCounterPath   = nil
local hwCounterTime   = nil

-- ===== SKILL ROTATION =====
local SLOT_KEYS    = { "Z", "X", "C", "V" }
local skillRotation = {}
for i = 1, 4 do
    skillRotation[i] = {
        enabled  = false,
        name     = "",
        key      = SLOT_KEYS[i],
        cooldown = 5,
        lastFire = 0,
        holdMode = false,   -- false = Single tap | true = Hold
        holdTime = 0.3,     -- giây giữ phím (chỉ dùng khi holdMode = true)
    }
end

-- Forward declarations (UI refs used across sections)
local MobDropdown, BossDropdown, ItemDropdown, ToolDropdown

-- ===== HELPERS =====
local function getChar()     return player.Character end
local function getHRP()      local c = getChar(); return c and c:FindFirstChild("HumanoidRootPart") end
local function getHumanoid() local c = getChar(); return c and c:FindFirstChildOfClass("Humanoid") end

local function getActiveTool()
    local c = getChar(); if not c then return nil end
    local t = c:FindFirstChildOfClass("Tool")
    return t and t.Name or nil
end

local function getToolNames()
    local names, seen = {}, {}
    local function add(parent)
        for _, t in ipairs(parent:GetChildren()) do
            if t:IsA("Tool") and not seen[t.Name] then
                table.insert(names, t.Name); seen[t.Name] = true
            end
        end
    end
    local bp = player:FindFirstChild("Backpack"); if bp then add(bp) end
    local c  = getChar();                         if c  then add(c)  end
    return names
end

local lastEquipTime = 0
local function ensureEquipped()
    if not State.SelectedTool then return end
    local c, h = getChar(), getHumanoid()
    if not c or not h then return end
    if c:FindFirstChild(State.SelectedTool) then return end   -- đã cầm rồi
    local now = tick()
    if now - lastEquipTime < (tonumber(State.AutoToolDelay) or 1.0) then return end  -- chưa đủ delay
    lastEquipTime = now
    local bp = player:FindFirstChild("Backpack")
    if bp then
        local tool = bp:FindFirstChild(State.SelectedTool)
        if tool then h:EquipTool(tool) end
    end
end

-- ===== PLAYER STATS =====
local function getPlayerLevel()
    local gui = player:FindFirstChild("PlayerGui"); if not gui then return nil end
    local ok, label = pcall(function() return gui.HUD.Holder.LevelText end)
    if not ok or not label then return nil end
    return tonumber(label.Text:match("Lv%.%s*(%d+)"))
end

local function getPlayerStat(key)
    local attempts = {
        function() return player:GetAttribute(key) end,
        function() local c = getChar(); return c and c:GetAttribute(key) end,
        function()
            local ls = player:FindFirstChild("leaderstats")
            return ls and ls:FindFirstChild(key) and ls[key].Value
        end,
    }
    for _, fn in ipairs(attempts) do
        local ok, v = pcall(fn)
        if ok and v ~= nil then return tostring(v) end
    end
    return nil
end

-- ===== STAT HELPERS =====
local function getAttrsFolder()
    local ok, f = pcall(function()
        return player:WaitForChild("Data", 3):WaitForChild("Attributes", 3)
    end)
    return ok and f or nil
end

local function getPoints()
    local f = getAttrsFolder(); if not f then return 0 end
    return tonumber(f:GetAttribute("Points")) or 0
end

local function getStatValue(name)
    local f = getAttrsFolder(); if not f then return 0 end
    return tonumber(f:GetAttribute(name)) or 0
end

local function addStat(statName, amount)
    pcall(function()
        R:FireServer(buffer.fromstring(OP_STAT), {{ statName, amount }})
    end)
end

-- ===== QUEST HELPERS =====
local function hasActiveQuest()
    local gui = player:FindFirstChild("PlayerGui"); if not gui then return false end
    local ok, btn = pcall(function() return gui.QuestUI.Main.CloseButton end)
    return ok and btn and btn.Visible == true
end

local function getQuestName()
    local gui = player:FindFirstChild("PlayerGui"); if not gui then return nil end
    local ok, label = pcall(function()
        return gui.QuestUI.Main.TrackerFrame.CanvasGroup.TextLabel
    end)
    if not ok or not label then return nil end
    return label.Text:gsub("<[^>]+>", ""):match("^%s*(.-)%s*$")
end

-- ===== FIND MOB IN WORKSPACE =====
local function findMobInWorkspace(mobName)
    local function checkFolder(folder)
        for _, mob in ipairs(folder:GetChildren()) do
            if mob.Name ~= mobName then continue end
            local hum  = mob:FindFirstChildOfClass("Humanoid")
            local root = mob:FindFirstChild("HumanoidRootPart")
            if hum and root and hum.Health > 0 then return mob end
        end
        return nil
    end
    -- Nested: Mobs → island subfolder → mob
    if State.SelectedIsland ~= "ALL" then
        local island = Mobs:FindFirstChild(State.SelectedIsland)
        if island then
            local found = checkFolder(island)
            if found then return found end
        end
    else
        for _, island in ipairs(Mobs:GetChildren()) do
            local found = checkFolder(island)
            if found then return found end
        end
    end
    -- Flat fallback: mob nằm trực tiếp trong Mobs (không qua island folder)
    return checkFolder(Mobs)
end

local function findClosestMob()
    local hrp = getHRP(); if not hrp then return end
    local closest, dist = nil, math.huge
    local function scan(folder)
        for _, mob in ipairs(folder:GetChildren()) do
            if State.SelectedMob and mob.Name ~= State.SelectedMob then continue end
            local hum  = mob:FindFirstChildOfClass("Humanoid")
            local root = mob:FindFirstChild("HumanoidRootPart")
            if hum and root and hum.Health > 0 then
                local d = (root.Position - hrp.Position).Magnitude
                if d < dist then dist, closest = d, mob end
            end
        end
    end
    if State.SelectedIsland ~= "ALL" then
        local island = Mobs:FindFirstChild(State.SelectedIsland)
        if island then scan(island) end
    else
        for _, island in ipairs(Mobs:GetChildren()) do scan(island) end
    end
    return closest
end

-- Tìm boss đang sống gần nhất từ BossTargetNames — scan ALL island, không filter
local function findAliveBoss()
    local hrp = getHRP()
    local best, bestDist = nil, math.huge
    for _, island in ipairs(Mobs:GetChildren()) do
        for _, mob in ipairs(island:GetChildren()) do
            if not State.BossTargetNames[mob.Name] then continue end
            local hum  = mob:FindFirstChildOfClass("Humanoid")
            local root = mob:FindFirstChild("HumanoidRootPart")
            if hum and root and hum.Health > 0 then
                if hrp then
                    local d = (root.Position - hrp.Position).Magnitude
                    if d < bestDist then bestDist = d; best = mob end
                else
                    return mob
                end
            end
        end
    end
    return best
end

-- ===== TELEPORT =====
local function tpToIsland(name)
    local hrp = getHRP(); if not hrp then return end
    local island = Map:FindFirstChild(name)
    if not island then
        Fluent:Notify({ Title = "TP", Content = name .. " not found in Map", Duration = 3 })
        return
    end
    local ok, cf, size = pcall(function() return island:GetBoundingBox() end)
    if ok and cf then
        hrp.CFrame = CFrame.new(cf.Position + Vector3.new(0, size.Y / 2 + 5, 0))
        Fluent:Notify({ Title = "TP", Content = "→ " .. name, Duration = 2 })
    end
end

-- Cache folder RS.Assets.Models.Mobs
local _mobModelsFolder
local function getMobModelsFolder()
    if _mobModelsFolder then return _mobModelsFolder end
    local paths = {
        { "Assets", "Models", "Mobs" },
        { "Models", "Mobs" },
    }
    for _, path in ipairs(paths) do
        local ok, result = pcall(function()
            local cur = RS
            for _, part in ipairs(path) do cur = cur:WaitForChild(part, 3) end
            return cur
        end)
        if ok and result then _mobModelsFolder = result; return result end
    end
    return nil
end

-- Lấy spawn position của mob từ RS template (không cần workspace load)
local function getMobSpawnPosFromRS(mobName)
    local folder = getMobModelsFolder()
    if not folder then return nil end

    local model
    -- Thử đúng island từ DB trước
    local db = EnemyDB[mobName]
    if db and db.island then
        local islandFolder = folder:FindFirstChild(db.island)
        if islandFolder then model = islandFolder:FindFirstChild(mobName) end
    end
    -- 2. Flat: model nằm trực tiếp trong folder Mobs (không qua island)
    if not model then
        model = folder:FindFirstChild(mobName)
    end

    -- 3. Nested brute-force: tìm trong tất cả sub-folder
    if not model then
        for _, child in ipairs(folder:GetChildren()) do
            if child.Name == mobName then model = child; break end
            local found = child:FindFirstChild(mobName)
            if found then model = found; break end
        end
    end

    if not model then return nil end

    local root = model:FindFirstChild("HumanoidRootPart")
             or  model.PrimaryPart
             or  model:FindFirstChildWhichIsA("BasePart")
    if root then return root.Position end

    local ok, cf = pcall(function() return model:GetBoundingBox() end)
    if ok and cf then return cf.Position end
    return nil
end

-- TP thẳng tới spawn pos trong RS → không cần mob đang load sẵn trong workspace
local function tpToMob(mobName)
    local hrp = getHRP(); if not hrp then return false end

    -- Ưu tiên: spawn position từ RS template
    local pos = getMobSpawnPosFromRS(mobName)
    if pos then
        hrp.CFrame = CFrame.new(pos + Vector3.new(0, 8, 0))
        Fluent:Notify({ Title = "TP", Content = "→ " .. mobName, Duration = 2 })
        return true
    end

    -- Fallback 1: TP đến island của mob (từ EnemyDB)
    local db = EnemyDB[mobName]
    if db and db.island then
        tpToIsland(db.island)
        return true
    end

    -- Fallback 2: mob đang có trong workspace (ít dùng)
    local mob = findMobInWorkspace(mobName)
    if mob then
        local root = mob:FindFirstChild("HumanoidRootPart")
        if root then
            hrp.CFrame = CFrame.new(root.Position + Vector3.new(0, 8, 0))
            Fluent:Notify({ Title = "TP", Content = "→ " .. mobName .. " (workspace)", Duration = 2 })
            return true
        end
    end

    Fluent:Notify({ Title = "TP", Content = "Không tìm thấy vị trí " .. mobName, Duration = 3 })
    return false
end

-- TP tới spawn pos rồi chờ mob stream vào workspace.Holder.Mobs (ChildAdded + poll)
-- Đặt SAU tpToIsland + getMobSpawnPosFromRS để tránh lỗi upvalue nil
local function waitForMobStream(mobName, timeout)
    -- TP tới vị trí spawn từ RS template
    local spawnPos = getMobSpawnPosFromRS(mobName)
    local hrp = getHRP()
    if spawnPos and hrp then
        hrp.CFrame = CFrame.new(spawnPos + Vector3.new(0, 8, 0))
    else
        local db = EnemyDB[mobName]
        if db and db.island then tpToIsland(db.island) end
    end

    -- Kiểm tra ngay sau khi TP (có thể đã stream in rồi)
    task.wait(0.25)
    local existing = findMobInWorkspace(mobName)
    if existing then return existing end

    -- Hook ChildAdded trên Mobs và tất cả island subfolder
    local result  = nil
    local conns   = {}
    local arrived = Instance.new("BindableEvent")

    local function checkObj(obj)
        if result then return end
        if obj.Name ~= mobName then return end
        local hum  = obj:FindFirstChildOfClass("Humanoid")
        local root = obj:FindFirstChild("HumanoidRootPart")
        if hum and root and hum.Health > 0 then
            result = obj; arrived:Fire()
        end
    end

    table.insert(conns, Mobs.ChildAdded:Connect(function(child)
        checkObj(child)
        if child:IsA("Folder") then
            table.insert(conns, child.ChildAdded:Connect(checkObj))
        end
    end))
    for _, island in ipairs(Mobs:GetChildren()) do
        if island:IsA("Folder") then
            table.insert(conns, island.ChildAdded:Connect(checkObj))
        end
    end

    -- Timeout
    task.delay(timeout or 8, function()
        if not result then arrived:Fire() end
    end)

    arrived.Event:Wait()
    for _, c in ipairs(conns) do c:Disconnect() end
    pcall(function() arrived:Destroy() end)

    return result or findMobInWorkspace(mobName)
end

local function getMapIslands()
    local list = {}
    for _, v in ipairs(Map:GetChildren()) do table.insert(list, v.Name) end
    table.sort(list)
    return list
end

-- ===== ENTITY ID =====
local function detectEntityID()
    local a = player:GetAttribute("EntityID")
    if a then return tostring(a) end
    local c = getChar()
    if c then
        local b = c:GetAttribute("EntityID")
        if b then return tostring(b) end
        for _, obj in ipairs(c:GetDescendants()) do
            if obj.Name == "EntityID" then
                if obj:IsA("StringValue") then return obj.Value end
                if obj:IsA("IntValue")    then return tostring(obj.Value) end
            end
        end
    end
    local ok, pf = pcall(function() return Holder:FindFirstChild(player.Name) end)
    if ok and pf then
        local x = pf:GetAttribute("EntityID")
        if x then return tostring(x) end
        for _, obj in ipairs(pf:GetDescendants()) do
            if obj.Name == "EntityID" then
                if obj:IsA("StringValue") then return obj.Value end
                if obj:IsA("IntValue")    then return tostring(obj.Value) end
            end
        end
    end
    return nil
end

local function captureEntityIDFromRequest(onCapture)
    return pcall(function()
        local mt  = getrawmetatable(game)
        local old = mt.__namecall
        setreadonly(mt, false)
        mt.__namecall = newcclosure(function(self, ...)
            if getnamecallmethod() == "FireServer" and self == SkillReq then
                local a    = { ... }
                local data = a[3]
                if type(data) == "table" and type(data[1]) == "table" then
                    local eid = data[1][1]
                    if eid and type(eid) == "string" and tonumber(eid) then
                        mt.__namecall = old
                        setreadonly(mt, true)
                        State.SkillEntityID = eid
                        if onCapture then task.spawn(onCapture, eid) end
                    end
                end
            end
            return old(self, ...)
        end)
        setreadonly(mt, true)
    end)
end

-- ===== HAKI =====

-- Detect xem Force/Haki đang BẬT hay TẮT
-- Khi bật: game thêm ForcePart (MeshPart) vào character (RightHand, LeftHand, v.v.)
-- Khi tắt: không có ForcePart nào
local function isHakiActive()
    local c = getChar()
    if not c then return false end
    return c:FindFirstChild("ForcePart", true) ~= nil
end

local function fireHaki()
    pcall(function()
        VIM:SendKeyEvent(true,  Enum.KeyCode.J, false, game)
        task.wait(0.05)
        VIM:SendKeyEvent(false, Enum.KeyCode.J, false, game)
    end)
    return true
end

-- ===== FARM ACTIONS =====
local function getMoveset()
    -- Ưu tiên: tool đang cầm trong char (fight style / sword)
    local tool = getActiveTool()
    if tool then return tool end
    -- Thứ hai: tool đã chọn từ dropdown
    if State.SelectedTool then return State.SelectedTool end
    -- Thứ ba: bất kỳ tool nào trong backpack
    local bp = player:FindFirstChild("Backpack")
    if bp then
        local t = bp:FindFirstChildOfClass("Tool")
        if t then return t.Name end
    end
    return nil   -- không có tool → không attack
end

local function fireM1()
    local moveset = getMoveset()
    if not moveset then return end   -- silently skip, không spam warn
    if State.FastAttack then
        -- Batch mode: gom HitPerPacket hits vào 1 packet (như FastAttack.lua)
        local batch = {}
        for _ = 1, State.HitPerPacket do
            table.insert(batch, { moveset })
        end
        pcall(function() R:FireServer(buffer.fromstring(OP_M1), batch) end)
    else
        pcall(function() R:FireServer(buffer.fromstring(OP_M1), {{ moveset }}) end)
    end
end

local function fireQuest(mobName)
    if not mobName then return false end
    return pcall(function() R:FireServer(buffer.fromstring(OP_QUEST), {{ mobName }}) end)
end

local lastQuestMob = nil   -- mob cuối cùng đã gửi quest để tránh overwrite progress

local function applyQuestForMob(mobName)
    if not mobName then return end
    local hasQuest = hasActiveQuest()
    -- Quest đang chạy đúng mob → không gửi lại, giữ nguyên progress
    if hasQuest and lastQuestMob == mobName then return end
    -- Quest đang chạy cho mob khác → chỉ ghi đè nếu OverwriteQuest = true
    if hasQuest and not State.OverwriteQuest then return end
    fireQuest(mobName)
    lastQuestMob = mobName
end

-- ===== CHEST ESP =====
local chestESPs        = {}
local CHEST_PICKUP_RANGE = 8
local espInited        = false

local function getChestRoot(chest)
    return chest:FindFirstChild("RootPart") or chest:FindFirstChildWhichIsA("BasePart")
end

local function addChestESP(chest)
    if chestESPs[chest] then return end
    local root = getChestRoot(chest); if not root then return end

    local hl = Instance.new("Highlight")
    hl.FillColor           = Color3.fromRGB(255, 200, 0)
    hl.OutlineColor        = Color3.fromRGB(255, 255, 255)
    hl.FillTransparency    = 0.4
    hl.OutlineTransparency = 0
    hl.DepthMode           = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Adornee             = chest
    hl.Parent              = chest

    local bb = Instance.new("BillboardGui")
    bb.Size           = UDim2.fromOffset(140, 44)
    bb.StudsOffset    = Vector3.new(0, 4, 0)
    bb.AlwaysOnTop    = true
    bb.LightInfluence = 0
    bb.Adornee        = root
    bb.Parent         = chest

    local label = Instance.new("TextLabel", bb)
    label.Size                   = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.TextColor3             = Color3.fromRGB(255, 220, 50)
    label.TextStrokeTransparency = 0
    label.TextStrokeColor3       = Color3.fromRGB(0, 0, 0)
    label.TextScaled             = true
    label.Font                   = Enum.Font.GothamBold
    label.Text                   = "CHEST\n?"
    Instance.new("UICorner", label).CornerRadius = UDim.new(0.2, 0)

    chestESPs[chest] = { hl = hl, bb = bb, label = label }
end

local function removeChestESP(chest)
    local d = chestESPs[chest]; if not d then return end
    pcall(function() d.hl:Destroy() end)
    pcall(function() d.bb:Destroy() end)
    chestESPs[chest] = nil
end

local function clearAllChestESP()
    for chest in pairs(chestESPs) do removeChestESP(chest) end
end

local function initChestESP()
    if not espInited then
        espInited = true
        Chests.ChildAdded:Connect(function(c)
            if State.ESPChest then task.wait(0.1); addChestESP(c) end
        end)
        Chests.ChildRemoved:Connect(function(c) removeChestESP(c) end)
    end
    for _, c in ipairs(Chests:GetChildren()) do addChestESP(c) end
end

-- ===== HEARTBEAT: FLOAT LOCK + ESP =====
RunService.Heartbeat:Connect(function()
    -- Float lock / distance mode
    if State.AutoFarm then
        local hrp, hum = getHRP(), getHumanoid()
        if hrp and hum then
            -- Evaluate target validity first (handles nil currentTarget safely)
            local mobRoot = currentTarget and currentTarget.Parent
                and currentTarget:FindFirstChild("HumanoidRootPart")
            local mobHum  = currentTarget and currentTarget:FindFirstChildOfClass("Humanoid")

            if mobRoot and mobHum and mobHum.Health > 0 then
                if State.BringMob then
                    pcall(function()
                        mobRoot.CFrame = CFrame.new(hrp.Position + Vector3.new(0, 0, -3))
                    end)
                end
                if State.FarmMode == "Float" then
                    hum.PlatformStand = true
                    hrp.CFrame        = CFrame.new(
                        mobRoot.Position + Vector3.new(0, State.HeightAbove, 0)
                    ) * CFrame.Angles(-math.rad(State.FaceDownAngle), 0, 0)
                    hrp.AssemblyLinearVelocity = Vector3.zero
                else
                    hum.PlatformStand = false
                    local dir = Vector3.new(
                        hrp.Position.X - mobRoot.Position.X, 0,
                        hrp.Position.Z - mobRoot.Position.Z
                    )
                    if dir.Magnitude < 0.1 then dir = Vector3.new(1, 0, 0) end
                    local tp = mobRoot.Position + dir.Unit * State.FarmDistance
                    hrp.CFrame = CFrame.new(
                        Vector3.new(tp.X, mobRoot.Position.Y, tp.Z),
                        Vector3.new(mobRoot.Position.X, mobRoot.Position.Y, mobRoot.Position.Z)
                    )
                    hrp.AssemblyLinearVelocity = Vector3.zero
                end
            else
                -- No valid target (mob died / nil) → release PlatformStand
                hum.PlatformStand = false
                -- Zero velocity every Heartbeat frame to absorb any boss-death physics burst
                -- (khi Float mode: character bị freeze giữa không, release PlatformStand
                --  có thể bị văng do accumulated force từ boss death explosion)
                hrp.AssemblyLinearVelocity  = Vector3.zero
                hrp.AssemblyAngularVelocity = Vector3.zero
            end
        end
    end

    -- Chest ESP distance update
    if State.ESPChest then
        local hrp = getHRP()
        if hrp then
            for chest, d in pairs(chestESPs) do
                if not chest.Parent then removeChestESP(chest); continue end
                local root = getChestRoot(chest); if not root then continue end
                local dist = (root.Position - hrp.Position).Magnitude
                if dist <= CHEST_PICKUP_RANGE then removeChestESP(chest); continue end
                if d.label then d.label.Text = string.format("CHEST\n%.0f studs", dist) end
            end
        end
    end
end)

-- ===== ATTACK LOOP =====
-- Chỉ fire M1 — target resolution do Unified Farm Loop xử lý riêng
task.spawn(function()
    while task.wait() do
        if not State.AutoFarm and not State.BossFarm then continue end
        if not currentTarget or not currentTarget.Parent then continue end
        local h = currentTarget:FindFirstChildOfClass("Humanoid")
        if not h or h.Health <= 0 then continue end
        ensureEquipped()
        fireM1()
        task.wait(State.FastAttack and State.PacketRate or State.M1Cooldown)
    end
end)

-- ===== AUTO QUEST LOOP =====
task.spawn(function()
    while task.wait(State.QuestInterval) do
        if not State.AutoQuest then continue end
        if not State.AutoFarm and not State.BossFarm then continue end
        -- Quest cho mob hiện tại đang farm, hoặc SelectedMob
        local target = currentTarget
        local name   = target and target.Name or State.SelectedMob
        if name then applyQuestForMob(name) end
    end
end)

-- ===== AUTO SKILL LOOP =====
task.spawn(function()
    while task.wait(0.1) do
        if (not State.AutoFarm and not State.AutoHawkeye) or not State.AutoSkill then continue end
        -- Ưu tiên hwTarget khi Hawkeye mode, fallback currentTarget
        local activeTarget = (State.AutoHawkeye and hwTarget) or currentTarget
        if not activeTarget or not activeTarget.Parent then continue end
        local now     = tick()
        local mobRoot = activeTarget:FindFirstChild("HumanoidRootPart")
        local eid     = State.SkillEntityID
        for _, slot in ipairs(skillRotation) do
            if not slot.enabled then continue end
            if now - slot.lastFire < slot.cooldown then continue end
            slot.lastFire = now
            if State.UseNetworkSkill and slot.name ~= "" and mobRoot and eid then
                local p = mobRoot.Position
                pcall(function()
                    SkillReq:FireServer(
                        buffer.fromstring(OP_SKILL), SK_FLAG,
                        {{ eid, { "ChargeSkill", slot.name, vector.create(p.X, p.Y, p.Z) } }}
                    )
                end)
            else
                -- VIM mode: Single tap hoặc Hold
                local key = Enum.KeyCode[slot.key]
                if slot.holdMode then
                    -- Hold: giữ phím trong holdTime giây
                    pcall(function()
                        VIM:SendKeyEvent(true, key, false, game)
                    end)
                    task.wait(slot.holdTime)
                    pcall(function()
                        VIM:SendKeyEvent(false, key, false, game)
                    end)
                else
                    -- Single: tap nhanh
                    pcall(function()
                        VIM:SendKeyEvent(true,  key, false, game)
                        task.wait(0.05)
                        VIM:SendKeyEvent(false, key, false, game)
                    end)
                end
            end
        end
    end
end)

-- ===== AUTO HAKI LOOP =====
local lastHakiTime = 0
task.spawn(function()
    while task.wait(1) do
        if not State.AutoHaki then continue end

        local active = isHakiActive()

        if active == true then
            -- Force đang BẬT → không làm gì, reset timer
            lastHakiTime = tick()
            continue
        end

        -- active == false  → biết chắc đang TẮT → fire ngay
        -- active == nil    → không detect được   → dùng interval fallback
        local now = tick()
        if active == false or (now - lastHakiTime >= State.HakiInterval) then
            lastHakiTime = now
            fireHaki()
        end
    end
end)

-- ===== AUTO STATS LOOP =====
task.spawn(function()
    while task.wait(0.5) do
        if not State.AutoStats or not State.SelectedStat then continue end
        local pts = getPoints()
        if pts <= 0 then continue end
        addStat(State.SelectedStat, pts)
        task.wait(0.3)   -- chờ server cập nhật
    end
end)

-- ===== SEA BEAST =====
local sbStatusLbl  -- UI ref, gán sau khi tạo tab

-- Sea Beast's Orb nằm trong player.Data.Inventory["Sea Beast's Orb"]
-- Attribute "Amount" cho biết số lượng
local function getOrbAmount()
    local data = player:FindFirstChild("Data")
    if not data then return 0 end
    local inv = data:FindFirstChild("Inventory")
    if not inv then return 0 end
    local orb = inv:FindFirstChild(SB_ORB_NAME)
    if not orb then return 0 end
    return tonumber(orb:GetAttribute("Amount")) or 0
end

local function hasSeaBeastOrb()
    return getOrbAmount() > 0
end

-- Dùng orb (thử packet, không bắt buộc — server tự check inventory)
local function useSeaBeastOrb()
    pcall(function()
        R:FireServer(buffer.fromstring(OP_USE_ITEM), { { SB_ORB_NAME } })
    end)
end

-- Tìm ProximityPrompt trên phiến đá triệu hồi trong workspace
local function findSummonStonePrompt()
    local keywords = { "summon", "stone", "altar", "beast", "sea", "phien", "da" }
    local function hasKw(name)
        local n = name:lower()
        for _, k in ipairs(keywords) do if n:find(k) then return true end end
        return false
    end
    local function scanPP(parent)
        for _, obj in ipairs(parent:GetChildren()) do
            if hasKw(obj.Name) then
                for _, d in ipairs(obj:GetDescendants()) do
                    if d:IsA("ProximityPrompt") then return d end
                end
                if obj:IsA("ProximityPrompt") then return obj end
            end
            -- Tìm PP trực tiếp trong tất cả con của folder
            if obj:IsA("BasePart") or obj:IsA("Model") then
                for _, d in ipairs(obj:GetDescendants()) do
                    if d:IsA("ProximityPrompt") and hasKw(d.Parent and d.Parent.Name or "") then
                        return d
                    end
                end
            end
        end
        return nil
    end
    local NPCs = Holder:FindFirstChild("NPCs")
    return (NPCs and scanPP(NPCs)) or scanPP(workspace) or scanPP(Holder)
end

-- Triệu hồi sea beast: thử PP trước, fallback packet
local function summonSeaBeast()
    -- Thử ProximityPrompt trên stone
    local pp = findSummonStonePrompt()
    if pp then
        local root = pp.Parent and pp.Parent:IsA("BasePart") and pp.Parent
                  or pp:FindFirstAncestorWhichIsA("BasePart")
        local hrp = getHRP()
        if root and hrp then
            hrp.CFrame = CFrame.new(root.Position + Vector3.new(0, 4, 0))
            task.wait(0.15)
        end
        pcall(fireprompt, pp)
        return true
    end
    -- Fallback: packet interact
    pcall(function()
        SkillReq:FireServer(
            buffer.fromstring(OP_INTERACT), SK_FLAG,
            { { SB_STONE_EID, { Instance.new("Model") } } }
        )
    end)
    return false
end

-- Kiểm tra tên có phải sea beast không (rộng hơn)
local SB_KEYWORDS = {
    "seabeast", "sea beast", "seaserpent", "sea serpent",
    "leviathan", "kraken", "seamonster", "sea monster",
    "guardian of the sea", "ocean beast",
}
local function isSeaBeastName(name)
    local n = name:lower():gsub("%s+", "")
    for _, kw in ipairs(SB_KEYWORDS) do
        if n:find(kw:gsub("%s+",""), 1, true) then return true end
    end
    -- Nếu không match cụ thể: có "sea" hoặc "beast" là đủ (mob đặc biệt)
    return n:find("sea") ~= nil or n:find("beast") ~= nil
end

local function isAliveModel(obj)
    if not obj:IsA("Model") then return false end
    local hum  = obj:FindFirstChildOfClass("Humanoid")
    local root = obj:FindFirstChild("HumanoidRootPart")
    return hum ~= nil and root ~= nil and hum.Health > 0
end

local function findSeaBeastInWorkspace()
    local Wrecks = Holder:FindFirstChild("Wrecks")

    -- 1. Tìm trong tất cả island folder trong Mobs
    for _, island in ipairs(Mobs:GetChildren()) do
        for _, obj in ipairs(island:GetChildren()) do
            if isSeaBeastName(obj.Name) and isAliveModel(obj) then return obj end
        end
    end
    -- 2. Tìm trong Mobs root
    for _, obj in ipairs(Mobs:GetChildren()) do
        if isSeaBeastName(obj.Name) and isAliveModel(obj) then return obj end
    end
    -- 3. Tìm trong Wrecks
    if Wrecks then
        for _, obj in ipairs(Wrecks:GetChildren()) do
            if isSeaBeastName(obj.Name) and isAliveModel(obj) then return obj end
        end
    end
    -- 4. Tìm trong Holder
    for _, obj in ipairs(Holder:GetChildren()) do
        if isSeaBeastName(obj.Name) and isAliveModel(obj) then return obj end
    end
    -- 5. Last resort: workspace trực tiếp
    for _, obj in ipairs(workspace:GetChildren()) do
        if isSeaBeastName(obj.Name) and isAliveModel(obj) then return obj end
    end
    return nil
end

-- Chờ sea beast xuất hiện (dùng ChildAdded + poll, timeout giây)
local function waitForSeaBeast(timeout)
    local found = findSeaBeastInWorkspace()
    if found then return found end

    local result   = nil
    local conns    = {}
    local finished = Instance.new("BindableEvent")

    local function checkObj(obj)
        if result then return end
        if isSeaBeastName(obj.Name) and isAliveModel(obj) then
            result = obj
            finished:Fire()
        end
    end

    local function watchFolder(folder)
        table.insert(conns, folder.ChildAdded:Connect(checkObj))
        for _, island in ipairs(folder:GetChildren()) do
            if island:IsA("Folder") then
                table.insert(conns, island.ChildAdded:Connect(checkObj))
            end
        end
    end

    local Wrecks = Holder:FindFirstChild("Wrecks")
    watchFolder(Mobs)
    watchFolder(Holder)
    if Wrecks then watchFolder(Wrecks) end
    table.insert(conns, workspace.ChildAdded:Connect(checkObj))

    -- Timeout fallback
    task.delay(timeout or 20, function()
        if not result then finished:Fire() end
    end)

    finished.Event:Wait()
    for _, c in ipairs(conns) do c:Disconnect() end
    finished:Destroy()

    -- Poll lần cuối nếu ChildAdded miss
    return result or findSeaBeastInWorkspace()
end

local function setSBStatus(txt)
    if sbStatusLbl then sbStatusLbl.Text = txt end
end

-- ── Sea Beast main loop ──────────────────────────────────────────────
task.spawn(function()
    while task.wait(1) do
        if not State.AutoSeaBeast then continue end

        -- ── Phase 1: Chưa có Orb → farm Guardian of the Seas ────────
        if not hasSeaBeastOrb() then
            State.SBPhase = "farm_guardian"
            setSBStatus("🗡  Farm Guardian of the Seas...")

            -- Bật boss farm hướng vào Guardian (tận dụng boss loop hiện có)
            State.BossTargetNames = { ["Guardian of the Seas"] = true }
            State.BossFarm        = true
            State.AutoFarm        = true

            -- Chờ cho đến khi có orb (check mỗi 2s)
            while State.AutoSeaBeast and not hasSeaBeastOrb() do
                task.wait(2)
            end
            if not State.AutoSeaBeast then continue end

            -- Tắt boss farm trước khi sang phase summon
            State.BossFarm = false
            State.AutoFarm = false
            currentTarget  = nil
            local hum = getHumanoid()
            if hum then hum.PlatformStand = false end
            task.wait(0.5)
        end

        -- ── Phase 2: Có Orb → triệu hồi ────────────────────────────
        State.SBPhase = "summon"
        setSBStatus("Trieu hoi Sea Beast...")

        -- Thử summon tối đa 3 lần
        local summoned = false
        for attempt = 1, 3 do
            if not State.AutoSeaBeast then break end
            setSBStatus(string.format("Summon lan %d/3...", attempt))
            -- Dùng orb (không bắt buộc, server tự check)
            useSeaBeastOrb()
            task.wait(0.3)
            local usedPP = summonSeaBeast()
            setSBStatus(usedPP and "FirePrompt OK — cho sea beast spawn..."
                                or "Packet sent — cho sea beast spawn...")

            -- Chờ beast xuất hiện (20s mỗi lần thử)
            local beast = waitForSeaBeast(20)
            if beast then
                summoned = true
                -- ── Phase 3: Kill Sea Beast ──────────────────────────
                State.SBPhase = "kill_beast"
                setSBStatus("Kill Sea Beast: " .. beast.Name)

                currentTarget  = beast
                State.AutoFarm = true

                -- TP lên đầu beast
                local root = beast:FindFirstChild("HumanoidRootPart")
                local hrp  = getHRP()
                if root and hrp then
                    hrp.CFrame = CFrame.new(
                        root.Position + Vector3.new(0, State.HeightAbove, 0)
                    )
                    hrp.AssemblyLinearVelocity  = Vector3.zero
                    hrp.AssemblyAngularVelocity = Vector3.zero
                end

                -- Chờ beast chết (check mỗi 0.5s)
                while State.AutoSeaBeast do
                    task.wait(0.5)
                    local hum = beast:FindFirstChildOfClass("Humanoid")
                    if not beast.Parent or not hum or hum.Health <= 0 then break end
                    -- Re-TP nếu trôi xa
                    local r2 = beast:FindFirstChild("HumanoidRootPart")
                    local h2 = getHRP()
                    if r2 and h2 and (r2.Position - h2.Position).Magnitude > 20 then
                        h2.CFrame = CFrame.new(r2.Position + Vector3.new(0, State.HeightAbove, 0))
                    end
                end
                break
            end

            setSBStatus(string.format("Lan %d that bai — thu lai...", attempt))
            task.wait(2)
        end

        if not summoned then
            setSBStatus("Khong summon duoc — ki tra lai sau 10s")
            task.wait(10)
        end

        -- Reset về idle, bắt đầu cycle mới
        State.AutoFarm = false
        currentTarget  = nil
        local h = getHumanoid()
        if h then h.PlatformStand = false end
        State.SBPhase = "idle"
        setSBStatus("✅  Cycle xong — chờ cycle tiếp...")
        task.wait(2)
    end
end)

-- TP lên đầu mob/boss bất kỳ (dùng chung cho farm + boss)
local function tpAboveMob(mob)
    local hrp  = getHRP(); if not hrp then return end
    local root = mob:FindFirstChild("HumanoidRootPart"); if not root then return end
    hrp.CFrame = CFrame.new(
        root.Position + Vector3.new(0, State.HeightAbove, 0),
        root.Position
    )
    hrp.AssemblyLinearVelocity  = Vector3.zero
    hrp.AssemblyAngularVelocity = Vector3.zero
end

-- ===== AUTO HAWKEYE =====
-- Cơ chế: 500 Knight Monkey kills → Hawkeye spawn trên cùng map
-- Cycle: Farm KM → detect Hawkeye spawn (ChildAdded) → Kill Hawkeye → repeat

local HW_KM_NAME = "Knight Monkey"
local HW_HE_NAME = "Hawkeye"
local HW_NPC_NAME = "Hawkeyes Rest"
local HW_COUNTER_GROUP = "Group007"
local HW_INTERACT_OFFSET = Vector3.new(0, 3, -6)

local function getHawkeyeNPC()
    local ok, npc = pcall(function()
        return workspace.Holder.NPCs.Other[HW_NPC_NAME]
    end)
    if ok and npc and npc:IsA("Model") then return npc end

    local holder = workspace:FindFirstChild("Holder")
    local npcs = holder and holder:FindFirstChild("NPCs")
    local found = npcs and npcs:FindFirstChild(HW_NPC_NAME, true)
    return found and found:IsA("Model") and found or nil
end

local function getModelRoot(model)
    if not model then return nil end
    local root = model:FindFirstChild("HumanoidRootPart")
        or model.PrimaryPart
        or model:FindFirstChildWhichIsA("BasePart", true)
    return root and root:IsA("BasePart") and root or nil
end

local function clickScreen(x, y)
    return pcall(function()
        VIM:SendMouseMoveEvent(x, y, game)
        task.wait(0.03)
        VIM:SendMouseButtonEvent(x, y, 0, true, game, 0)
        task.wait(0.08)
        VIM:SendMouseButtonEvent(x, y, 0, false, game, 0)
    end)
end

local function fireGuiSignal(signal)
    if not signal then return false end
    local ok = pcall(function() firesignal(signal) end)
    if ok then return true end
    if type(getconnections) ~= "function" then return false end
    return pcall(function()
        for _, conn in ipairs(getconnections(signal)) do
            conn:Fire()
        end
    end)
end

local function clickGuiButton(button)
    if not button then return false end
    pcall(function() button:Activate() end)
    fireGuiSignal(button.Activated)
    fireGuiSignal(button.MouseButton1Click)
    return pcall(function()
        local pos, size = button.AbsolutePosition, button.AbsoluteSize
        clickScreen(pos.X + size.X / 2, pos.Y + size.Y / 2)
    end)
end

local function hawkeyeBillboardGuiButton(npc)
    local billboard = npc and npc:FindFirstChild("InteractionBillboard", true)
    if not billboard then return false, "No InteractionBillboard" end

    local count = 0
    for _, obj in ipairs(billboard:GetDescendants()) do
        if obj:IsA("GuiButton") then
            count += 1
            clickGuiButton(obj)
        end
    end

    return count > 0, count > 0 and ("GuiButton x" .. count) or "No GuiButton"
end

local function hawkeyeBillboardCenter(npc)
    local billboard = npc and npc:FindFirstChild("InteractionBillboard", true)
    if not billboard then return false, "No InteractionBillboard" end

    local ok, err = pcall(function()
        local pos, size = billboard.AbsolutePosition, billboard.AbsoluteSize
        if size.X <= 0 or size.Y <= 0 then error("bad billboard size") end
        clickScreen(pos.X + size.X / 2, pos.Y + size.Y / 2)
    end)
    return ok, ok and "Billboard center clicked" or tostring(err)
end

local function hawkeyeNPCWorldClick(npc)
    local root = getModelRoot(npc)
    local camera = workspace.CurrentCamera
    if not root then return false, "NPC root not found" end
    if not camera then return false, "Camera not found" end

    local screenPos, onScreen = camera:WorldToViewportPoint(root.Position + Vector3.new(0, 2.5, 0))
    if not onScreen then return false, "NPC offscreen" end

    local ok = clickScreen(screenPos.X, screenPos.Y)
    return ok, ok and "NPC world clicked" or "World click failed"
end

local function readHawkeyeCounter()
    local gui = player:FindFirstChild("PlayerGui")
    if not gui then return nil end

    local ok, obj = pcall(function()
        return gui.DialogueUI.Holder.DialogueFrame.TextFrame.Line001.Container[HW_COUNTER_GROUP]
    end)

    local function readNumber(target)
        if not target then return nil end
        local okText, text = pcall(function() return target.ContentText end)
        if not okText or text == nil or tostring(text) == "" then
            okText, text = pcall(function() return target.Text end)
        end
        local n = tonumber(tostring(text or ""):match("^%s*(%d+)%s*$"))
        return n, tostring(text or "")
    end

    if ok and obj then
        local n, raw = readNumber(obj)
        if n then return n, obj:GetFullName(), raw end
    end

    local dialogue = gui:FindFirstChild("DialogueUI")
    if dialogue then
        for _, desc in ipairs(dialogue:GetDescendants()) do
            local n, raw = readNumber(desc)
            if n then return n, desc:GetFullName(), raw end
        end
    end

    return nil
end

local function waitHawkeyeCounter(timeout)
    local deadline = tick() + (timeout or 1.5)
    while tick() < deadline do
        local n, path, raw = readHawkeyeCounter()
        if n then return n, path, raw end
        task.wait(0.1)
    end
    return nil
end

local function closeHawkeyeDialogue()
    local gui = player:FindFirstChild("PlayerGui")
    local dialogue = gui and gui:FindFirstChild("DialogueUI")
    if not dialogue then return end

    local close = dialogue:FindFirstChild("Close", true)
    if close and close:IsA("GuiButton") then
        clickGuiButton(close)
    end
end

local function checkHawkeyeCounter()
    local npc = getHawkeyeNPC()
    if not npc then return nil, "NPC not found" end

    local hrp = getHRP()
    local oldCFrame = hrp and hrp.CFrame
    local root = getModelRoot(npc)
    if hrp and root then
        hrp.CFrame = CFrame.new(root.Position + HW_INTERACT_OFFSET, root.Position)
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
        task.wait(0.25)
    end

    local methods = {
        { name = "Billboard GuiButton", fn = hawkeyeBillboardGuiButton },
        { name = "Billboard Center",    fn = hawkeyeBillboardCenter },
        { name = "NPC World Click",     fn = hawkeyeNPCWorldClick },
    }

    for _, method in ipairs(methods) do
        local ok, msg = method.fn(npc)
        print(("[HawkeyeCounter] Try %s | ok=%s | %s"):format(method.name, tostring(ok), tostring(msg)))
        local n, path, raw = waitHawkeyeCounter(1.2)
        if n then
            hwBossRemaining = n
            hwCounterMethod = method.name
            hwCounterPath   = path
            hwCounterTime   = tick()
            closeHawkeyeDialogue()
            if oldCFrame and hrp and hrp.Parent then
                task.wait(0.1)
                hrp.CFrame = oldCFrame
                hrp.AssemblyLinearVelocity = Vector3.zero
                hrp.AssemblyAngularVelocity = Vector3.zero
            end
            return n, nil, method.name, path, raw
        end
    end

    closeHawkeyeDialogue()
    if oldCFrame and hrp and hrp.Parent then
        task.wait(0.1)
        hrp.CFrame = oldCFrame
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
    end

    return nil, "Counter not found"
end

-- Tìm mob — scan Mobs flat + tất cả island subfolder (không filter island)
local function findMobForHW(name)
    local function check(folder)
        for _, obj in ipairs(folder:GetChildren()) do
            if obj.Name == name then
                local h = obj:FindFirstChildOfClass("Humanoid")
                local r = obj:FindFirstChild("HumanoidRootPart")
                if h and r and h.Health > 0 then return obj end
            end
        end
        return nil
    end
    local found = check(Mobs)
    if found then return found end
    for _, island in ipairs(Mobs:GetChildren()) do
        local f = check(island)
        if f then return f end
    end
    return nil
end

-- TP đến RS spawn pos → đợi mob stream (ChildAdded + BindableEvent)
local function streamHWMob(name, timeout)
    local pos = getMobSpawnPosFromRS(name)
    local hrp = getHRP()
    if pos and hrp then
        hrp.CFrame = CFrame.new(pos + Vector3.new(0, 8, 0))
    else
        local db = EnemyDB[name]
        if db and db.island then tpToIsland(db.island) end
    end
    task.wait(0.25)

    local existing = findMobForHW(name)
    if existing then return existing end

    local result  = nil
    local conns   = {}
    local arrived = Instance.new("BindableEvent")

    local function checkObj(obj)
        if result then return end
        if obj.Name ~= name then return end
        local h = obj:FindFirstChildOfClass("Humanoid")
        local r = obj:FindFirstChild("HumanoidRootPart")
        if h and r and h.Health > 0 then result = obj; arrived:Fire() end
    end

    table.insert(conns, Mobs.ChildAdded:Connect(function(child)
        checkObj(child)
        if child:IsA("Folder") then
            table.insert(conns, child.ChildAdded:Connect(checkObj))
        end
    end))
    for _, island in ipairs(Mobs:GetChildren()) do
        if island:IsA("Folder") then
            table.insert(conns, island.ChildAdded:Connect(checkObj))
        end
    end

    task.delay(timeout or 10, function()
        if not result then arrived:Fire() end
    end)
    arrived.Event:Wait()
    for _, c in ipairs(conns) do c:Disconnect() end
    pcall(function() arrived:Destroy() end)
    return result or findMobForHW(name)
end

-- Hawkeye ChildAdded detector — chạy liên tục khi module bật
local function startHWDetector()
    for _, c in ipairs(hwDetectorConns) do c:Disconnect() end
    hwDetectorConns = {}

    local function onObj(obj)
        if not State.AutoHawkeye then return end
        if obj.Name ~= HW_HE_NAME then return end
        local h = obj:FindFirstChildOfClass("Humanoid")
        local r = obj:FindFirstChild("HumanoidRootPart")
        if h and r and h.Health > 0 then
            State.HWPhase = "kill_hawkeye"
            hwTarget      = obj
            tpAboveMob(obj)
            Fluent:Notify({ Title = "🦅 Hawkeye SPAWN!", Content = "Switching to Hawkeye...", Duration = 3 })
        end
    end

    table.insert(hwDetectorConns, Mobs.ChildAdded:Connect(function(child)
        onObj(child)
        if child:IsA("Folder") then
            table.insert(hwDetectorConns, child.ChildAdded:Connect(onObj))
        end
    end))
    for _, island in ipairs(Mobs:GetChildren()) do
        if island:IsA("Folder") then
            table.insert(hwDetectorConns, island.ChildAdded:Connect(onObj))
        end
    end
end

local function stopHWDetector()
    for _, c in ipairs(hwDetectorConns) do c:Disconnect() end
    hwDetectorConns = {}
end

-- Hawkeye float lock (Heartbeat riêng, không đụng main float lock)
RunService.Heartbeat:Connect(function()
    if not State.AutoHawkeye then return end
    local target = hwTarget
    if not target or not target.Parent then return end
    local hrp  = getHRP(); if not hrp then return end
    local root = target:FindFirstChild("HumanoidRootPart"); if not root then return end
    local hum  = getHumanoid()
    if hum then hum.PlatformStand = true end
    local desired = root.Position + Vector3.new(0, State.HeightAbove, 0)
    hrp.CFrame = CFrame.new(desired, root.Position)
    hrp.AssemblyLinearVelocity  = Vector3.zero
    hrp.AssemblyAngularVelocity = Vector3.zero
end)

-- Hawkeye attack loop (riêng, dùng hwTarget)
task.spawn(function()
    while task.wait() do
        if not State.AutoHawkeye then continue end
        local target = hwTarget
        if not target or not target.Parent then continue end
        local h = target:FindFirstChildOfClass("Humanoid")
        if not h or h.Health <= 0 then continue end
        ensureEquipped()
        local moveset = getMoveset()
        if not moveset then continue end
        pcall(function() R:FireServer(buffer.fromstring(OP_M1), {{ moveset }}) end)
        task.wait(State.FastAttack and State.PacketRate or State.M1Cooldown)
    end
end)

-- Hawkeye phase manager (main loop)
task.spawn(function()
    while task.wait(0.25) do
        if not State.AutoHawkeye then
            if hwTarget then
                hwTarget = nil
                local hum = getHumanoid()
                if hum then hum.PlatformStand = false end
            end
            continue
        end

        -- ─── farm_knight ────────────────────────────────────────────────
        if State.HWPhase == "farm_knight" then
            local km = hwTarget

            if km and km.Parent then
                local h = km:FindFirstChildOfClass("Humanoid")
                if h and h.Health > 0 then continue end
                -- KM chết → đếm kill
                if km.Name == HW_KM_NAME then hwKMKills += 1 end
                hwTarget = nil
            end

            -- Hawkeye có thể đã spawn trong lúc KM chết
            if State.HWPhase == "kill_hawkeye" then continue end

            -- Tìm KM tiếp theo
            local newKM = findMobForHW(HW_KM_NAME)
            if not newKM then
                newKM = streamHWMob(HW_KM_NAME, 10)
            end

            -- Guard: Hawkeye spawn trong lúc stream-wait
            if State.HWPhase == "kill_hawkeye" then continue end

            if newKM and newKM.Parent then
                local h2 = newKM:FindFirstChildOfClass("Humanoid")
                if h2 and h2.Health > 0 then
                    hwTarget = newKM
                    tpAboveMob(newKM)
                end
            else
                task.wait(1)
            end

        -- ─── kill_hawkeye ────────────────────────────────────────────────
        elseif State.HWPhase == "kill_hawkeye" then
            local hawk = hwTarget

            -- Nếu detector chưa set target (race condition), tự tìm
            if not hawk or hawk.Name ~= HW_HE_NAME then
                hawk = findMobForHW(HW_HE_NAME)
                if not hawk then hawk = streamHWMob(HW_HE_NAME, 10) end
                hwTarget = hawk
                if hawk then tpAboveMob(hawk) end
            end

            if hawk and hawk.Parent then
                local h = hawk:FindFirstChildOfClass("Humanoid")
                if h and h.Health > 0 then continue end
                -- Hawkeye chết
                hwHEKills += 1
                hwTarget   = nil
                Fluent:Notify({
                    Title   = "Hawkeye ✓",
                    Content = string.format("Kill #%d — trở về farm KM", hwHEKills),
                    Duration = 3,
                })
            end

            task.wait(2)
            State.HWPhase = "farm_knight"

        else
            task.wait(0.5)
        end
    end
end)

-- ===== UNIFIED FARM LOOP =====
-- Boss (BossTargetNames) ưu tiên hơn SelectedMob.
-- BossFarm ON + AutoFarm ON + SelectedMob → boss khi sống, mob khi boss chết.
-- BossFarm ON + AutoFarm OFF              → chỉ boss.
-- BossFarm OFF + AutoFarm ON              → chỉ SelectedMob.

local bossQueueIdx = 1

local function getBossNameList()
    local list = {}
    for name in pairs(State.BossTargetNames) do table.insert(list, name) end
    table.sort(list)
    return list
end

local function isBossAlive(mob)
    if not mob or not mob.Parent then return false end
    local hum = mob:FindFirstChildOfClass("Humanoid")
    return hum and hum.Health > 0
end

task.spawn(function()
    while task.wait(0.25) do
        local farming = State.AutoFarm or State.BossFarm
        if not farming then
            if currentTarget then
                currentTarget = nil
                local hum = getHumanoid()
                if hum then hum.PlatformStand = false end
            end
            continue
        end

        -- Target còn sống → không làm gì, float lock + attack loop tự xử lý
        if currentTarget and currentTarget.Parent then
            local h = currentTarget:FindFirstChildOfClass("Humanoid")
            if h and h.Health > 0 then continue end
        end

        -- Target chết / nil → reset velocity rồi tìm target mới
        currentTarget = nil
        local _hrp = getHRP(); local _hum = getHumanoid()
        if _hrp and _hum then
            _hum.PlatformStand = false
            _hrp.AssemblyLinearVelocity  = Vector3.zero
            _hrp.AssemblyAngularVelocity = Vector3.zero
        end

        -- ─── Ưu tiên 1: Boss ──────────────────────────────────────────────
        if State.BossFarm then
            -- Scan workspace trước (không TP, nhanh)
            local boss = findAliveBoss()
            if boss then
                currentTarget = boss; tpAboveMob(boss)
                Fluent:Notify({ Title = "Boss", Content = "→ "..boss.Name, Duration = 2 })
                continue
            end
            -- Không có → TP spawn + chờ stream (xoay vòng boss list)
            local list = getBossNameList()
            if #list > 0 then
                if bossQueueIdx > #list then bossQueueIdx = 1 end
                local bossName = list[bossQueueIdx]; bossQueueIdx += 1
                Fluent:Notify({ Title = "Boss", Content = bossName.." — cho spawn...", Duration = 3 })
                local boss2 = waitForMobStream(bossName, 8)
                if boss2 then
                    currentTarget = boss2; tpAboveMob(boss2)
                    Fluent:Notify({ Title = "Boss", Content = "→ "..boss2.Name, Duration = 2 })
                    continue
                end
            end
        end

        -- ─── Ưu tiên 2: SelectedMob (fallback khi boss chưa spawn) ────────
        if (State.AutoFarm or State.BossFarm) and State.SelectedMob then
            -- Scan workspace trước
            local mob = findMobInWorkspace(State.SelectedMob)
            if not mob then
                -- Không có → TP spawn + chờ stream
                mob = waitForMobStream(State.SelectedMob, 6)
            end
            if mob then
                currentTarget = mob; tpAboveMob(mob)
                continue
            end
        end

        -- Không tìm được gì → thử lại sau 1s
        task.wait(1)
    end
end)

-- ===== AUTO FARM LEVEL LOOP =====
task.spawn(function()
    while task.wait(5) do
        if not State.AutoFarmLevel then continue end
        if not DB_LOADED then continue end
        local level = getPlayerLevel()
        if not level then continue end
        if level == lastAutoLevel and State.SelectedMob then continue end
        lastAutoLevel = level

        local best = findBestMobForLevel(level)
        if not best or State.SelectedMob == best.name then continue end

        State.SelectedMob    = best.name
        State.SelectedIsland = best.island
        currentTarget        = nil

        pcall(function() if MobDropdown then MobDropdown:SetValue(best.name) end end)

        -- TP to mob
        task.spawn(function()
            task.wait(0.3)
            tpToMob(best.name)
        end)

        -- Quest
        if State.AutoQuest then
            task.wait(0.3)
            applyQuestForMob(best.name)
        end

        Fluent:Notify({
            Title   = "Auto Farm Level",
            Content = string.format("Lv.%d → %s (Lv.%d)\nIsland: %s",
                level, best.name, best.level, best.island),
            Duration = 6,
        })
    end
end)

local function refreshToolDropdown()
    task.wait(1)   -- chờ backpack load
    local names = getToolNames()
    if #names == 0 then return end
    pcall(function()
        if ToolDropdown then ToolDropdown:SetValues(names) end
    end)
    -- Nếu chưa chọn tool, tự chọn cái đang cầm (hoặc cái đầu tiên)
    if not State.SelectedTool then
        local active = getActiveTool() or names[1]
        if active then
            State.SelectedTool = active
            pcall(function() if ToolDropdown then ToolDropdown:SetValue(active) end end)
        end
    end
end

-- Restore on respawn + refresh tool list
player.CharacterAdded:Connect(function(char)
    local hum = char:WaitForChild("Humanoid")
    if not State.AutoFarm then hum.PlatformStand = false end
    task.wait(1)
    local h = char:FindFirstChildOfClass("Humanoid")
    if h then h.WalkSpeed = State._walkSpeed; h.JumpPower = State._jumpPower end
    task.spawn(refreshToolDropdown)
end)

-- =========================================================
-- UI
-- =========================================================
local Window = Fluent:CreateWindow({
    Title       = "AutoFarm Hub",
    SubTitle    = "Legend Piece v3",
    TabWidth    = 155,
    Size        = UDim2.fromOffset(640, 530),
    Acrylic     = false,
    Theme       = "Dark",
    MinimizeKey = Enum.KeyCode.RightControl,
})

local Tabs = {
    Main     = Window:AddTab({ Title = "Main",     Icon = "zap"      }),
    Farm     = Window:AddTab({ Title = "Farm",     Icon = "swords"   }),
    Boss     = Window:AddTab({ Title = "Boss",     Icon = "skull"    }),
    Hawkeye  = Window:AddTab({ Title = "Hawkeye",  Icon = "eye"      }),
    SeaBeast = Window:AddTab({ Title = "SeaBeast", Icon = "waves"    }),
    Skill    = Window:AddTab({ Title = "Skill",    Icon = "sparkles" }),
    Stats    = Window:AddTab({ Title = "Stats",    Icon = "star"     }),
    Teleport = Window:AddTab({ Title = "Teleport", Icon = "map"      }),
    Misc     = Window:AddTab({ Title = "Misc",     Icon = "wrench"   }),
}

-- =========================================================
-- MAIN TAB — Stats + Auto Farm Level
-- =========================================================
Tabs.Main:AddParagraph({
    Title   = "Player Stats",
    Content = "Click Refresh để xem thông tin nhân vật hiện tại",
})

Tabs.Main:AddButton({
    Title    = "Refresh Stats",
    Callback = function()
        local level = getPlayerLevel()
        local race  = getPlayerStat("Race")
        local title = getPlayerStat("Title")
        local spawn = getPlayerStat("SetSpawn") or getPlayerStat("Spawn") or getPlayerStat("LastIsland")
        local belly = getPlayerStat("Belly") or getPlayerStat("Beli") or getPlayerStat("Coin")
        local quest = hasActiveQuest() and (getQuestName() or "Active") or "None"
        Fluent:Notify({
            Title   = "Player Stats",
            Content = string.format(
                "Level : %s\nRace  : %s\nTitle : %s\nSpawn : %s\nBelly : %s\nQuest : %s",
                level or "?", race or "?", title or "?",
                spawn or "?", belly or "?", quest
            ),
            Duration = 8,
        })
    end,
})

Tabs.Main:AddButton({
    Title       = "Load Enemy Database",
    Description = "Đọc EnemyEnums từ ReplicatedStorage (cần 1 lần trước khi farm)",
    Callback    = function()
        if DB_LOADED then
            local n = 0; for _ in pairs(EnemyDB) do n += 1 end
            Fluent:Notify({ Title = "DB", Content = "Đã load " .. n .. " entries", Duration = 3 })
            return
        end
        Fluent:Notify({ Title = "DB", Content = "Đang load...", Duration = 2 })
        task.spawn(function()
            local ok = loadEnemyDB()
            local n  = 0; for _ in pairs(EnemyDB) do n += 1 end
            Fluent:Notify({
                Title   = ok and "DB ✓" or "DB ✗",
                Content = ok
                    and string.format("%d mob/boss loaded\nFarm/Boss tabs ready!", n)
                    or  "EnemyEnums not found — kiểm tra path trong RS",
                Duration = 5,
            })
            if ok then
                pcall(function() if MobDropdown  then MobDropdown:SetValues(getDBList("Mob"))   end end)
                pcall(function() if BossDropdown then BossDropdown:SetValues(getDBList("Boss"))  end end)
                pcall(function() if ItemDropdown then ItemDropdown:SetValues(getDBDropItems())   end end)
            end
        end)
    end,
})

Tabs.Main:AddToggle("AutoFarmLevel", {
    Title       = "Auto Farm Level",
    Description = "Tự chọn mob tốt nhất theo level. Tự TP + quest mỗi 5s.",
    Default     = false,
}):OnChanged(function(v)
    State.AutoFarmLevel = v
    State.AutoFarm      = v
    if v then
        lastAutoLevel = nil
        if not DB_LOADED then
            task.spawn(function()
                loadEnemyDB()
                pcall(function() if MobDropdown  then MobDropdown:SetValues(getDBList("Mob"))   end end)
                pcall(function() if BossDropdown then BossDropdown:SetValues(getDBList("Boss"))  end end)
                pcall(function() if ItemDropdown then ItemDropdown:SetValues(getDBDropItems())   end end)
                lastAutoLevel = nil
            end)
        end
    else
        currentTarget = nil
        local hum = getHumanoid()
        if hum then hum.PlatformStand = false end
    end
end)

Tabs.Main:AddParagraph({
    Title   = "Ghi chú",
    Content = "• Auto Farm Level: không cần tour map\n  → dùng EnemyDB (require EnemyEnums trực tiếp)\n  → tự TP tới mob + nhận quest\n\n• Ctrl+RightCtrl = minimize hub",
})

-- =========================================================
-- FARM TAB — Mob Selection + Item Farm + Quest + Controls
-- =========================================================
Tabs.Farm:AddParagraph({
    Title   = "Chọn Mob",
    Content = "Gõ tên rồi nhấn Enter để lọc, hoặc chọn từ dropdown",
})

Tabs.Farm:AddInput("MobSearch", {
    Title       = "Tìm kiếm Mob",
    Description = 'VD: "Pirate" → lọc mob có tên chứa "Pirate"',
    Default     = "",
    Numeric     = false,
    Finished    = true,
    Callback    = function(v)
        if not DB_LOADED then return end
        local q        = v:lower()
        local filtered = {}
        for name, data in pairs(EnemyDB) do
            if data.enemyType == "Mob" and (q == "" or name:lower():find(q, 1, true)) then
                table.insert(filtered, name)
            end
        end
        table.sort(filtered, function(a, b)
            return (EnemyDB[a].level or 0) < (EnemyDB[b].level or 0)
        end)
        if #filtered > 0 and MobDropdown then
            pcall(function() MobDropdown:SetValues(filtered) end)
        end
    end,
})

MobDropdown = Tabs.Farm:AddDropdown("MobSelect", {
    Title       = "Mob",
    Description = "Load DB (Main tab) để xem danh sách đầy đủ",
    Values      = { "(Load DB first)" },
    Multi       = false,
    Default     = nil,
})
MobDropdown:OnChanged(function(v)
    if not v or v == "(Load DB first)" then return end
    State.SelectedMob = v
    currentTarget     = nil
    lastQuestMob      = nil   -- đổi mob → cho phép gửi quest mới

    -- Update island from DB
    local db = EnemyDB[v]
    if db then
        State.SelectedIsland = db.island
        -- Show info
        local drops = {}
        for item, rate in pairs(db.rewards or {}) do
            if type(item) == "string" and item ~= "XP" and item ~= "MasteryXP" and item ~= "Coin" then
                table.insert(drops, string.format("%s (%s)", item, tostring(rate)))
            end
        end
        table.sort(drops)
        Fluent:Notify({
            Title   = v,
            Content = string.format("Lv.%d | %s | %s\nDrops: %s",
                db.level, db.enemyType, db.island,
                #drops > 0 and table.concat(drops, ", ") or "—"),
            Duration = 6,
        })
    end

    -- Quest overwrite on mob change
    if State.AutoQuest then
        task.wait(0.2)
        applyQuestForMob(v)
    end
end)

Tabs.Farm:AddButton({
    Title    = "Refresh Mob List",
    Callback = function()
        if not DB_LOADED then
            Fluent:Notify({ Title = "Refresh", Content = "Load DB trước (Main tab)", Duration = 2 })
            return
        end
        local list = getDBList("Mob")
        if #list == 0 then list = { "(No mob in DB)" } end
        pcall(function() if MobDropdown then MobDropdown:SetValues(list) end end)
        Fluent:Notify({ Title = "Refresh", Content = #list .. " mob từ EnemyEnums", Duration = 2 })
    end,
})

Tabs.Farm:AddButton({
    Title       = "TP to Mob",
    Description = "TP thẳng đến vị trí mob đang spawn (fallback: TP đảo)",
    Callback    = function()
        if not State.SelectedMob then
            Fluent:Notify({ Title = "TP", Content = "Chọn mob trước", Duration = 2 })
            return
        end
        tpToMob(State.SelectedMob)
    end,
})

-- Farm Item section
Tabs.Farm:AddParagraph({
    Title   = "Farm Item Drop",
    Content = "Chọn item → tự tìm + set mob drop item đó",
})

ItemDropdown = Tabs.Farm:AddDropdown("ItemSelect", {
    Title       = "Item muốn farm",
    Description = "Load DB trước để xem danh sách",
    Values      = { "(Load DB first)" },
    Multi       = false,
    Default     = nil,
})

Tabs.Farm:AddButton({
    Title       = "Set Mob for this Item",
    Description = "Tìm mob drop item đã chọn và đặt làm target",
    Callback    = function()
        local item = ItemDropdown and ItemDropdown.Value
        if not item or item == "(Load DB first)" then
            Fluent:Notify({ Title = "Item Farm", Content = "Chọn item trước", Duration = 2 })
            return
        end
        local mobs = getMobsDropping(item)
        if #mobs == 0 then
            Fluent:Notify({ Title = "Item Farm", Content = "Không tìm thấy mob drop " .. item, Duration = 3 })
            return
        end
        -- Prefer Mob type over Boss
        local best = mobs[1]
        for _, m in ipairs(mobs) do
            if m.data.enemyType == "Mob" then best = m; break end
        end
        State.SelectedMob    = best.name
        State.SelectedIsland = best.data.island
        currentTarget        = nil
        pcall(function() if MobDropdown then MobDropdown:SetValue(best.name) end end)
        Fluent:Notify({
            Title   = "Item Farm",
            Content = string.format("Target: %s (Lv.%d)\nDrop: %s @ %s",
                best.name, best.data.level, item, tostring(best.rate)),
            Duration = 5,
        })
        if State.AutoQuest then
            task.wait(0.2)
            applyQuestForMob(best.name)
        end
    end,
})

Tabs.Farm:AddButton({
    Title    = "Refresh Item List",
    Callback = function()
        if not DB_LOADED then
            Fluent:Notify({ Title = "Items", Content = "Load DB trước!", Duration = 2 }); return
        end
        local items = getDBDropItems()
        pcall(function() if ItemDropdown then ItemDropdown:SetValues(items) end end)
        Fluent:Notify({ Title = "Items", Content = #items .. " items", Duration = 2 })
    end,
})

-- Quest controls
Tabs.Farm:AddParagraph({ Title = "Quest", Content = "" })

Tabs.Farm:AddToggle("AutoQuest", {
    Title       = "Auto Quest",
    Description = "Tự nhận quest theo interval",
    Default     = false,
}):OnChanged(function(v) State.AutoQuest = v end)

Tabs.Farm:AddToggle("OverwriteQuest", {
    Title       = "Overwrite Quest",
    Description = "Ghi đè quest cũ khi đổi mob",
    Default     = true,
}):OnChanged(function(v) State.OverwriteQuest = v end)

Tabs.Farm:AddButton({
    Title    = "Accept Quest Now",
    Callback = function()
        if not State.SelectedMob then
            Fluent:Notify({ Title = "Quest", Content = "Chọn mob trước", Duration = 2 }); return
        end
        fireQuest(State.SelectedMob)
        Fluent:Notify({ Title = "Quest", Content = "→ " .. State.SelectedMob, Duration = 2 })
    end,
})

Tabs.Farm:AddButton({
    Title    = "Check Quest",
    Callback = function()
        Fluent:Notify({
            Title   = "Quest",
            Content = string.format("Lv.%s | Quest: %s",
                tostring(getPlayerLevel() or "?"),
                hasActiveQuest() and (getQuestName() or "Active") or "None"),
            Duration = 4,
        })
    end,
})

Tabs.Farm:AddSlider("QuestInterval", {
    Title    = "Quest Interval (s)",
    Default  = 5, Min = 1, Max = 30, Rounding = 0,
    Callback = function(v) State.QuestInterval = tonumber(v) or 5 end,
})

-- Farm Position + Master Toggles
Tabs.Farm:AddParagraph({ Title = "Farm Controls", Content = "" })

Tabs.Farm:AddDropdown("FarmMode", {
    Title   = "Farm Position",
    Values  = { "Float", "Ground Distance" },
    Multi   = false,
    Default = "Float",
}):OnChanged(function(v)
    State.FarmMode = (v == "Float") and "Float" or "Distance"
    if State.FarmMode == "Distance" then
        local hum = getHumanoid(); if hum then hum.PlatformStand = false end
    end
end)

ToolDropdown = Tabs.Farm:AddDropdown("ToolSelect", {
    Title       = "Tool / Fight Style",
    Description = "Auto-equip khi farm. Tự refresh khi character load.",
    Values      = getToolNames(),
    Multi       = false,
    Default     = nil,
})
ToolDropdown:OnChanged(function(v) State.SelectedTool = v end)

Tabs.Farm:AddButton({
    Title    = "Refresh Tool List",
    Callback = function()
        local names = getToolNames()
        ToolDropdown:SetValues(names)
        Fluent:Notify({ Title = "Tools", Content = #names .. " tool(s)", Duration = 2 })
    end,
})

Tabs.Farm:AddSlider("AutoToolDelay", {
    Title       = "Auto Tool Delay (s)",
    Description = "Thời gian chờ giữa các lần tự equip tool",
    Default     = 1.0, Min = 0.1, Max = 5.0, Rounding = 1,
    Callback    = function(v) State.AutoToolDelay = tonumber(v) or 1.0 end,
})

Tabs.Farm:AddToggle("AutoFarmToggle", {
    Title   = "Auto Farm",
    Default = false,
}):OnChanged(function(v)
    State.AutoFarm = v
    if not v then
        currentTarget = nil
        local hum = getHumanoid(); if hum then hum.PlatformStand = false end
    end
end)

Tabs.Farm:AddToggle("FastAttack", {
    Title       = "Fast Attack",
    Description = "Gom nhiều hit / packet, dùng PacketRate thay M1 Cooldown",
    Default     = false,
}):OnChanged(function(v) State.FastAttack = v end)

Tabs.Farm:AddSlider("HitPerPacket", {
    Title       = "Hits / Packet (Fast Attack)",
    Description = "Số hit gộp trong 1 lần gửi",
    Default     = 2, Min = 1, Max = 10, Rounding = 0,
    Callback    = function(v) State.HitPerPacket = tonumber(v) or 2 end,
})

Tabs.Farm:AddSlider("PacketRate", {
    Title       = "Packet Rate (s) (Fast Attack)",
    Description = "Giây giữa mỗi lần gửi packet",
    Default     = 0.1, Min = 0.05, Max = 0.5, Rounding = 2,
    Callback    = function(v) State.PacketRate = tonumber(v) or 0.1 end,
})

Tabs.Farm:AddToggle("BringMob", {
    Title       = "Bring Mob",
    Description = "Client-side — kéo mob về phía player",
    Default     = false,
}):OnChanged(function(v) State.BringMob = v end)

Tabs.Farm:AddSlider("M1Cooldown", {
    Title    = "M1 Cooldown (s)",
    Default  = 0.1, Min = 0.05, Max = 0.5, Rounding = 2,
    Callback = function(v) State.M1Cooldown = tonumber(v) or 0.1 end,
})

Tabs.Farm:AddSlider("HeightAbove", {
    Title    = "Height Above Mob (Float)",
    Default  = 6, Min = 2, Max = 25, Rounding = 0,
    Callback = function(v) State.HeightAbove = tonumber(v) or 6 end,
})

Tabs.Farm:AddSlider("FaceAngle", {
    Title    = "Face Down Angle (°)",
    Default  = 80, Min = 0, Max = 90, Rounding = 0,
    Callback = function(v) State.FaceDownAngle = tonumber(v) or 80 end,
})

Tabs.Farm:AddSlider("FarmDist", {
    Title    = "Ground Distance (studs)",
    Default  = 5, Min = 2, Max = 20, Rounding = 0,
    Callback = function(v) State.FarmDistance = tonumber(v) or 5 end,
})

-- =========================================================
-- BOSS TAB
-- =========================================================
Tabs.Boss:AddParagraph({
    Title   = "Boss Farm",
    Content = "Load DB (Main) → chọn boss → bật Boss Farm Cycle\nScript TP + đánh xoay vòng từng boss đã chọn",
})

BossDropdown = Tabs.Boss:AddDropdown("BossTargets", {
    Title       = "Chọn Boss",
    Description = "Multi-select",
    Values      = { "(Load DB first)" },
    Multi       = true,
    Default     = {},
})
BossDropdown:OnChanged(function(v)
    State.BossTargetNames = {}
    for name, selected in pairs(v) do
        if selected and name ~= "(Load DB first)" then
            State.BossTargetNames[name] = true
        end
    end
end)

Tabs.Boss:AddButton({
    Title    = "Refresh Boss List",
    Callback = function()
        if not DB_LOADED then
            Fluent:Notify({ Title = "Boss", Content = "Load DB trước (Main tab)", Duration = 2 })
            return
        end
        local list = getDBList("Boss")
        if #list == 0 then list = { "(No boss in DB)" } end
        pcall(function() BossDropdown:SetValues(list) end)
        Fluent:Notify({ Title = "Boss", Content = #list .. " boss từ EnemyEnums", Duration = 2 })
    end,
})

Tabs.Boss:AddButton({
    Title       = "Debug: List All Enemy Types",
    Description = "In F9 tất cả EnemyType có trong DB (tìm type của Hawkeye/boss thiếu)",
    Callback    = function()
        local types = {}
        for name, data in pairs(EnemyDB) do
            local t = data.enemyType or "nil"
            if not types[t] then types[t] = {} end
            table.insert(types[t], name)
        end
        print("===== ENEMY TYPES IN DB =====")
        for t, names in pairs(types) do
            table.sort(names)
            print(string.format("[%s] (%d): %s%s",
                t, #names,
                table.concat(names, ", "):sub(1, 120),
                #table.concat(names, ", ") > 120 and "..." or ""))
        end
        print("=============================")
        -- Hiện tổng hợp trong notify
        local summary = {}
        for t, names in pairs(types) do
            table.insert(summary, string.format("%s: %d", t, #names))
        end
        table.sort(summary)
        Fluent:Notify({
            Title   = "Enemy Types",
            Content = table.concat(summary, "\n"),
            Duration = 8,
        })
    end,
})

Tabs.Boss:AddButton({
    Title    = "TP to Boss",
    Callback = function()
        local first
        for name in pairs(State.BossTargetNames) do first = name; break end
        if not first then
            Fluent:Notify({ Title = "TP", Content = "Chọn boss trước", Duration = 2 }); return
        end
        tpToMob(first)
    end,
})

Tabs.Boss:AddToggle("BossFarm", {
    Title       = "Boss Farm Cycle",
    Description = "TP spawn → chờ stream → đánh xoay vòng.\nBật cả Auto Farm (Farm tab) + chọn mob = mob làm fallback khi boss chết.",
    Default     = false,
}):OnChanged(function(v)
    State.BossFarm = v
    if v then
        bossQueueIdx  = 1
        currentTarget = nil
        local n = 0; for _ in pairs(State.BossTargetNames) do n += 1 end
        Fluent:Notify({
            Title   = "Boss Farm ON",
            Content = string.format(
                "%d boss — TP + cho stream → đánh\nMob fallback: %s",
                n, State.SelectedMob or "(chưa chọn — set ở Farm tab)"),
            Duration = 4,
        })
    else
        currentTarget = nil
        local hum = getHumanoid(); if hum then hum.PlatformStand = false end
    end
end)


Tabs.Boss:AddToggle("AutoQuestBoss", {
    Title       = "Auto Quest (Boss)",
    Description = "Tự nhận quest khi Boss Farm bật",
    Default     = false,
}):OnChanged(function(v) State.AutoQuest = v end)

-- =========================================================
-- HAWKEYE TAB
-- =========================================================
Tabs.Hawkeye:AddParagraph({
    Title   = "Auto Hawkeye",
    Content = "Cơ chế game: 500 Knight Monkey kills → Hawkeye spawn\nKhi Hawkeye xuất hiện, KM biến mất và script tự switch target\nCycle: Farm KM → Kill Hawkeye → repeat",
})

Tabs.Hawkeye:AddInput("HWKMName", {
    Title       = "Knight Monkey Name",
    Description = "Tên chính xác của mob (mặc định: Knight Monkey)",
    Default     = "Knight Monkey",
    Numeric     = false,
    Finished    = true,
    Callback    = function(v)
        v = v and v:match("^%s*(.-)%s*$")
        if v and v ~= "" then
            HW_KM_NAME = v
            Fluent:Notify({ Title = "Hawkeye", Content = "KM Name = " .. v, Duration = 2 })
        end
    end,
})

Tabs.Hawkeye:AddInput("HWHEName", {
    Title       = "Hawkeye Name",
    Description = "Tên chính xác của Hawkeye boss",
    Default     = "Hawkeye",
    Numeric     = false,
    Finished    = true,
    Callback    = function(v)
        v = v and v:match("^%s*(.-)%s*$")
        if v and v ~= "" then
            HW_HE_NAME = v
            Fluent:Notify({ Title = "Hawkeye", Content = "HE Name = " .. v, Duration = 2 })
        end
    end,
})

Tabs.Hawkeye:AddToggle("AutoHawkeye", {
    Title       = "Auto Hawkeye",
    Description = "Tự farm Knight Monkey → switch Hawkeye khi spawn → repeat",
    Default     = false,
}):OnChanged(function(v)
    State.AutoHawkeye = v
    if v then
        State.HWPhase = "farm_knight"
        hwTarget      = nil
        hwKMKills     = 0
        hwHEKills     = 0
        hwStartTime   = tick()
        startHWDetector()
        Fluent:Notify({ Title = "Auto Hawkeye ON", Content = "Farming " .. HW_KM_NAME .. "...", Duration = 3 })
    else
        stopHWDetector()
        State.HWPhase = "idle"
        hwTarget      = nil
        local hum = getHumanoid()
        if hum then hum.PlatformStand = false end
        Fluent:Notify({
            Title   = "Auto Hawkeye OFF",
            Content = string.format("KM: %d kills | Hawkeye: %d kills", hwKMKills, hwHEKills),
            Duration = 4,
        })
    end
end)

Tabs.Hawkeye:AddButton({
    Title    = "Check Status",
    Callback = function()
        local elapsed = hwStartTime and math.floor(tick() - hwStartTime) or 0
        local rate = (elapsed > 0) and math.floor(hwKMKills / elapsed * 60) or 0
        local counterAge = hwCounterTime and math.floor(tick() - hwCounterTime) or nil
        Fluent:Notify({
            Title   = "Hawkeye Status",
            Content = string.format(
                "Phase       : %s\nTarget      : %s\nKM Kills    : %d  (%d/min)\nHawkeye Kill: %d\nNPC Counter : %s\nMethod      : %s\nUptime      : %ds",
                State.HWPhase,
                hwTarget and (hwTarget.Parent and hwTarget.Name or "(removed)") or "—",
                hwKMKills, rate,
                hwHEKills,
                hwBossRemaining and (tostring(hwBossRemaining) .. (counterAge and (" (" .. counterAge .. "s ago)") or "")) or "â€”",
                hwCounterMethod or "â€”",
                elapsed
            ),
            Duration = 7,
        })
    end,
})

Tabs.Hawkeye:AddButton({
    Title       = "Check Hawkeyes Counter",
    Description = "TP tới Hawkeyes, thử Billboard GuiButton → Billboard Center → NPC World Click, đọc Group007.ContentText",
    Callback    = function()
        task.spawn(function()
            local n, err, method, path = checkHawkeyeCounter()
            if n then
                Fluent:Notify({
                    Title   = "Hawkeyes Counter",
                    Content = string.format("Còn: %d mob\nMethod: %s\nPath: %s", n, method or "?", path or "?"),
                    Duration = 7,
                })
            else
                Fluent:Notify({
                    Title   = "Hawkeyes Counter",
                    Content = err or "Check failed",
                    Duration = 4,
                })
            end
        end)
    end,
})

Tabs.Hawkeye:AddButton({
    Title       = "Reset Counters",
    Description = "Về 0 KM kills / Hawkeye kills",
    Callback    = function()
        hwKMKills   = 0
        hwHEKills   = 0
        hwStartTime = tick()
        Fluent:Notify({ Title = "Hawkeye", Content = "Counters reset", Duration = 2 })
    end,
})

Tabs.Hawkeye:AddParagraph({
    Title   = "Lưu ý",
    Content = "• M1 Cooldown / Fast Attack / Height Above: dùng chung với Farm tab\n• Khi Hawkeye spawn: KM biến mất, script tự TP lên đầu Hawkeye\n• Nếu tên mob trong game khác → sửa KM Name / Hawkeye Name ở trên",
})

-- =========================================================
-- SEA BEAST TAB
-- =========================================================
Tabs.SeaBeast:AddParagraph({
    Title   = "Auto Sea Beast",
    Content = "Cycle tự động:\n1. Farm Guardian of the Seas → lấy Sea Beast's Orb\n2. Dùng Orb + triệu hồi Sea Beast\n3. Kill Sea Beast → lặp lại",
})

sbStatusLbl = Tabs.SeaBeast:AddParagraph({
    Title   = "Trạng thái",
    Content = "Chưa bắt đầu",
}).Content   -- Fluent paragraph không có .Text setter trực tiếp → dùng helper bên dưới

-- Tạo wrapper cho status vì Fluent Paragraph không update được — dùng Notify thay thế
-- Override setSBStatus để dùng Notify khi không thể update label
sbStatusLbl = nil   -- paragraph ko update được live, dùng notify
local function setSBStatus(txt)
    Fluent:Notify({ Title = "Sea Beast", Content = txt, Duration = 3 })
end

Tabs.SeaBeast:AddToggle("AutoSeaBeast", {
    Title       = "Auto Sea Beast Cycle",
    Description = "Tự động farm Guardian → summon → kill lặp vòng",
    Default     = false,
}):OnChanged(function(v)
    State.AutoSeaBeast = v
    if not v then
        -- Dừng: tắt boss farm, reset state
        State.BossFarm = false
        State.AutoFarm = false
        currentTarget  = nil
        State.SBPhase  = "idle"
        local hum = getHumanoid()
        if hum then hum.PlatformStand = false end
        Fluent:Notify({ Title = "Sea Beast", Content = "Đã dừng", Duration = 2 })
    else
        Fluent:Notify({ Title = "Sea Beast", Content = "Bắt đầu cycle...", Duration = 2 })
    end
end)

Tabs.SeaBeast:AddParagraph({ Title = "Cấu hình", Content = "" })

Tabs.SeaBeast:AddInput("SBStoneEID", {
    Title       = "Stone Entity ID",
    Description = "Entity ID phiến đá triệu hồi (mặc định: 3508)",
    Default     = "3508",
    Numeric     = false,
    Finished    = true,
    Callback    = function(v)
        v = v and v:match("^%s*(.-)%s*$")
        if v and v ~= "" then
            SB_STONE_EID = v
            Fluent:Notify({ Title = "Sea Beast", Content = "Stone EID = " .. v, Duration = 2 })
        end
    end,
})

Tabs.SeaBeast:AddParagraph({ Title = "Thủ công", Content = "" })

Tabs.SeaBeast:AddButton({
    Title    = "Check Orb",
    Callback = function()
        local amount = getOrbAmount()
        Fluent:Notify({
            Title   = "Sea Beast's Orb",
            Content = amount > 0
                and string.format("✅  Có %d orb\nData → Inventory → Sea Beast's Orb", amount)
                or  "❌  Không có\n(Amount = 0 hoặc chưa unlock)",
            Duration = 4,
        })
    end,
})

Tabs.SeaBeast:AddButton({
    Title    = "Use Orb (manual)",
    Callback = function()
        if not hasSeaBeastOrb() then
            Fluent:Notify({ Title = "Sea Beast", Content = "Không có Orb!", Duration = 2 }); return
        end
        useSeaBeastOrb()
        Fluent:Notify({ Title = "Sea Beast", Content = "Đã dùng Orb ✓", Duration = 2 })
    end,
})

Tabs.SeaBeast:AddButton({
    Title       = "Summon Sea Beast (manual)",
    Description = "Script tu tim stone PP → TP → fireprompt. Fallback: packet",
    Callback    = function()
        local usedPP = summonSeaBeast()
        Fluent:Notify({
            Title   = "Sea Beast",
            Content = usedPP and "FirePrompt on stone OK" or "Packet sent (fallback)",
            Duration = 3,
        })
    end,
})

Tabs.SeaBeast:AddButton({
    Title       = "Scan Sea Beast (Debug)",
    Description = "In F9 tat ca Model co Humanoid — tim ten sea beast",
    Callback    = function()
        print("===== SEA BEAST SCAN =====")
        local found = findSeaBeastInWorkspace()
        if found then
            print("[FOUND]", found.Name, found:GetFullName())
            local hum = found:FindFirstChildOfClass("Humanoid")
            if hum then print("  HP:", hum.Health, "/", hum.MaxHealth) end
        else
            print("[NOT FOUND] — liet ke tat ca Model co Humanoid:")
            local Wrecks = Holder:FindFirstChild("Wrecks")
            local locs = { workspace, Holder, Mobs }
            if Wrecks then table.insert(locs, Wrecks) end
            local seen = {}
            for _, loc in ipairs(locs) do
                for _, obj in ipairs(loc:GetDescendants()) do
                    if obj:IsA("Model") and not seen[obj] then
                        local hum2 = obj:FindFirstChildOfClass("Humanoid")
                        if hum2 and hum2.Health > 0 then
                            seen[obj] = true
                            print(string.format("  [Model] %-30s @ %s  HP:%.0f",
                                obj.Name, obj:GetFullName(), hum2.Health))
                        end
                    end
                end
            end
        end
        print("===========================")
        Fluent:Notify({ Title = "Sea Beast Scan", Content = "Xem Output F9", Duration = 3 })
    end,
})

Tabs.SeaBeast:AddButton({
    Title       = "Scan Summon Stone (Debug)",
    Description = "Liet ke tat ca ProximityPrompt — tim stone dung",
    Callback    = function()
        print("===== STONE / PP SCAN =====")
        local pp = findSummonStonePrompt()
        if pp then
            print("[FOUND PP]", pp:GetFullName())
            print("  HoldDur=", pp.HoldDuration, "MaxDist=", pp.MaxActivationDistance, "Key=", pp.KeyboardKeyCode)
        end
        print("--- All ProximityPrompts in NPCs + workspace ---")
        local NPCs = Holder:FindFirstChild("NPCs")
        for _, loc in ipairs({ NPCs, workspace, Holder }) do
            if not loc then continue end
            for _, pp2 in ipairs(loc:GetDescendants()) do
                if pp2:IsA("ProximityPrompt") then
                    print(string.format("  [PP] %-30s  HoldDur=%.1f  Dist=%d",
                        pp2:GetFullName(), pp2.HoldDuration, pp2.MaxActivationDistance))
                end
            end
        end
        print("===========================")
        Fluent:Notify({ Title = "Stone Scan", Content = "Xem F9", Duration = 3 })
    end,
})

-- =========================================================
-- STATS TAB — Auto distribute Points
-- =========================================================
local STAT_NAMES = { "Melee", "Defense", "Sword", "Fruit" }

Tabs.Stats:AddParagraph({
    Title   = "Auto Stats",
    Content = "Tự tiêu Points vào stat đã chọn\nPoints lấy từ Data → Attributes",
})

Tabs.Stats:AddButton({
    Title    = "Xem Stats hiện tại",
    Callback = function()
        local pts = getPoints()
        local lines = { string.format("Points còn: %d", pts), "" }
        for _, name in ipairs(STAT_NAMES) do
            table.insert(lines, string.format("%s: %d", name, getStatValue(name)))
        end
        Fluent:Notify({
            Title    = "Stats",
            Content  = table.concat(lines, "\n"),
            Duration = 6,
        })
    end,
})

Tabs.Stats:AddDropdown("StatSelect", {
    Title       = "Stat để phân bổ",
    Description = "Points sẽ được đổ vào stat này",
    Values      = STAT_NAMES,
    Multi       = false,
    Default     = nil,
}):OnChanged(function(v) State.SelectedStat = v end)

Tabs.Stats:AddToggle("AutoStats", {
    Title       = "Auto Stats",
    Description = "Tự tiêu toàn bộ Points vào stat đã chọn mỗi 0.5s",
    Default     = false,
}):OnChanged(function(v)
    if v and not State.SelectedStat then
        Fluent:Notify({ Title = "Auto Stats", Content = "Chọn stat trước!", Duration = 2 })
        return
    end
    State.AutoStats = v
end)

Tabs.Stats:AddButton({
    Title       = "Spend Points Now",
    Description = "Tiêu ngay toàn bộ Points hiện có vào stat đã chọn",
    Callback    = function()
        if not State.SelectedStat then
            Fluent:Notify({ Title = "Stats", Content = "Chọn stat trước", Duration = 2 }); return
        end
        local pts = getPoints()
        if pts <= 0 then
            Fluent:Notify({ Title = "Stats", Content = "Không có Points", Duration = 2 }); return
        end
        addStat(State.SelectedStat, pts)
        Fluent:Notify({
            Title   = "Stats",
            Content = string.format("+ %d → %s", pts, State.SelectedStat),
            Duration = 3,
        })
    end,
})

-- =========================================================
-- SKILL TAB — Haki + Skill Rotation
-- =========================================================
Tabs.Skill:AddParagraph({
    Title   = "Auto Haki",
    Content = "Kích hoạt Haki định kỳ qua Request event\nYêu cầu Entity ID",
})

Tabs.Skill:AddButton({
    Title    = "Capture Entity ID (Hook)",
    Callback = function()
        State.SkillEntityID = nil
        local ok = captureEntityIDFromRequest(function(eid)
            Fluent:Notify({ Title = "Entity ID ✓", Content = "= " .. eid, Duration = 5 })
        end)
        if ok then
            Fluent:Notify({ Title = "Hook Active", Content = "Dùng Haki/Skill 1 lần để capture ID", Duration = 4 })
        else
            local eid = detectEntityID()
            if eid then
                State.SkillEntityID = eid
                Fluent:Notify({ Title = "Entity ID ✓", Content = "= " .. eid .. " (attribute)", Duration = 4 })
            else
                Fluent:Notify({ Title = "Thất bại", Content = "Nhập thủ công bên dưới", Duration = 3 })
            end
        end
    end,
})

Tabs.Skill:AddInput("ManualEntityID", {
    Title    = "Manual Entity ID",
    Default  = "",
    Numeric  = false,
    Finished = true,
    Callback = function(v)
        v = v and v:match("^%s*(.-)%s*$")
        if v and v ~= "" then
            State.SkillEntityID = v
            Fluent:Notify({ Title = "Entity ID", Content = "Set: " .. v, Duration = 3 })
        end
    end,
})

Tabs.Skill:AddToggle("AutoHaki", {
    Title   = "Auto Haki",
    Default = false,
}):OnChanged(function(v)
    State.AutoHaki = v
    if v then lastHakiTime = 0 end
end)

Tabs.Skill:AddSlider("HakiInterval", {
    Title    = "Haki Interval (s)",
    Default  = 30, Min = 5, Max = 120, Rounding = 0,
    Callback = function(v) State.HakiInterval = tonumber(v) or 30 end,
})

Tabs.Skill:AddButton({
    Title    = "Fire Haki Now",
    Callback = function()
        if not State.SkillEntityID then
            Fluent:Notify({ Title = "Haki", Content = "Cần Entity ID trước", Duration = 2 }); return
        end
        local ok = fireHaki()
        Fluent:Notify({ Title = ok and "Haki ✓" or "Haki ✗", Content = ok and "Fired!" or "Thất bại", Duration = 2 })
    end,
})

Tabs.Skill:AddParagraph({
    Title   = "Skill Rotation",
    Content = "4 slot — cooldown riêng\nVIM: giả lập phím | Network: Request event",
})

Tabs.Skill:AddToggle("AutoSkill", {
    Title   = "Auto Skill (Master)",
    Default = false,
}):OnChanged(function(v) State.AutoSkill = v end)

Tabs.Skill:AddToggle("UseNetworkSkill", {
    Title       = "Use Network Skill",
    Description = "ON = Request event | OFF = VirtualInput (Z/X...)",
    Default     = false,
}):OnChanged(function(v) State.UseNetworkSkill = v end)

for i = 1, 4 do
    local slot = skillRotation[i]
    Tabs.Skill:AddParagraph({ Title = "── Slot " .. i .. " (" .. SLOT_KEYS[i] .. ") ──", Content = "" })

    Tabs.Skill:AddToggle("SkillSlot" .. i, {
        Title   = "Enable Slot " .. i,
        Default = false,
    }):OnChanged(function(v) slot.enabled = v end)

    -- Key selector
    Tabs.Skill:AddDropdown("SkillKey" .. i, {
        Title   = "Key (VIM mode)",
        Values  = { "Z", "X", "C", "V", "Q", "E", "R", "F", "G", "H" },
        Default = SLOT_KEYS[i],
    }):OnChanged(function(v) slot.key = v end)

    -- Press mode: Single / Hold
    Tabs.Skill:AddDropdown("SkillMode" .. i, {
        Title       = "Press Mode",
        Description = "Single = tap nhanh | Hold = giữ phím",
        Values      = { "Single", "Hold" },
        Multi       = false,
        Default     = "Single",
    }):OnChanged(function(v)
        slot.holdMode = (v == "Hold")
    end)

    -- Hold duration (chỉ có tác dụng khi Hold mode)
    Tabs.Skill:AddSlider("SkillHold" .. i, {
        Title       = "Hold Duration (s)  [Hold mode]",
        Default     = 0.3, Min = 0.05, Max = 3.0, Rounding = 2,
        Callback    = function(v) slot.holdTime = tonumber(v) or 0.3 end,
    })

    -- Network skill name
    Tabs.Skill:AddInput("SkillName" .. i, {
        Title    = "Skill Name (Network mode)",
        Default  = "",
        Numeric  = false,
        Finished = false,
        Callback = function(v) slot.name = v end,
    })

    -- Cooldown
    Tabs.Skill:AddSlider("SkillCD" .. i, {
        Title    = "Cooldown (s)",
        Default  = 5, Min = 0.5, Max = 60, Rounding = 1,
        Callback = function(v) slot.cooldown = tonumber(v) or 5 end,
    })
end

-- =========================================================
-- TELEPORT TAB — Dynamic from Map
-- =========================================================
Tabs.Teleport:AddParagraph({
    Title   = "Island Teleport",
    Content = "Danh sách lấy từ workspace.Holder.Map (tự cập nhật)",
})

local mapIslands = getMapIslands()
if #mapIslands > 0 then
    for _, name in ipairs(mapIslands) do
        Tabs.Teleport:AddButton({
            Title    = name,
            Callback = function() tpToIsland(name) end,
        })
    end
else
    Tabs.Teleport:AddParagraph({
        Title   = "Không có đảo",
        Content = "Holder.Map trống hoặc chưa load\nChạy lại script sau khi vào game",
    })
end

-- =========================================================
-- MISC TAB
-- =========================================================
Tabs.Misc:AddToggle("ESPChest", {
    Title       = "ESP Chest",
    Description = "Highlight + distance. Tự ẩn khi đến gần.",
    Default     = false,
}):OnChanged(function(v)
    State.ESPChest = v
    if v then initChestESP() else clearAllChestESP() end
end)

Tabs.Misc:AddSlider("ChestRange", {
    Title    = "Chest Pickup Range (studs)",
    Default  = 8, Min = 3, Max = 20, Rounding = 0,
    Callback = function(v) CHEST_PICKUP_RANGE = tonumber(v) or 8 end,
})

local lastHP, dmgConn = {}, nil
Tabs.Misc:AddToggle("DamageLog", {
    Title    = "Damage Logger (F9)",
    Default  = false,
}):OnChanged(function(v)
    if v then
        dmgConn = RunService.Heartbeat:Connect(function()
            for _, island in ipairs(Mobs:GetChildren()) do
                for _, mob in ipairs(island:GetChildren()) do
                    local hum = mob:FindFirstChildOfClass("Humanoid")
                    if hum then
                        local prev = lastHP[mob]
                        if prev and prev > hum.Health then
                            print(string.format("[DMG] %s: %.0f → %.0f (-%d)",
                                mob.Name, prev, hum.Health, prev - hum.Health))
                        end
                        lastHP[mob] = hum.Health
                    end
                end
            end
        end)
    elseif dmgConn then
        dmgConn:Disconnect(); dmgConn = nil
    end
end)

Tabs.Misc:AddSlider("WalkSpeed", {
    Title    = "Walk Speed",
    Default  = 16, Min = 16, Max = 200, Rounding = 0,
    Callback = function(v)
        local n = tonumber(v) or 16
        State._walkSpeed = n
        local h = getHumanoid(); if h then h.WalkSpeed = n end
    end,
})

Tabs.Misc:AddSlider("JumpPower", {
    Title    = "Jump Power",
    Default  = 50, Min = 50, Max = 300, Rounding = 0,
    Callback = function(v)
        local n = tonumber(v) or 50
        State._jumpPower = n
        local h = getHumanoid(); if h then h.JumpPower = n end
    end,
})

Tabs.Misc:AddButton({
    Title    = "Print Entity ID Debug",
    Callback = function()
        print("===== ENTITY ID DEBUG =====")
        print("player attrs:", player:GetAttributes())
        local c = getChar()
        if c then
            print("char attrs:", c:GetAttributes())
            for _, v in ipairs(c:GetDescendants()) do
                if v.Name:lower():find("entity") or v.Name:lower():find("eid") then
                    print(" ", v:GetFullName(), "=", v:IsA("ValueBase") and v.Value or "(no value)")
                end
            end
        end
        local pf = Holder:FindFirstChild(player.Name)
        if pf then print("Holder/" .. player.Name .. ":", pf:GetAttributes()) end
        print("State.SkillEntityID:", State.SkillEntityID or "nil")
        print("===========================")
        Fluent:Notify({ Title = "Debug", Content = "Xem Output (F9)", Duration = 2 })
    end,
})

-- =========================================================
-- ADDONS + INIT
-- =========================================================
SaveManager:SetLibrary(Fluent)
InterfaceManager:SetLibrary(Fluent)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ "ConfigList", "InterfaceTheme" })
-- Dùng 1 cấp folder (underscore thay slash) để BuildFolderTree tự tạo được
-- makefolder trên Fluxus mobile không tạo được nested path từ zero
local _cfgDir = "LP_Hub_" .. player.Name   -- VD: "LP_Hub_TPC"
InterfaceManager:SetFolder(_cfgDir)
SaveManager:SetFolder(_cfgDir)  -- tạo LP_Hub_TPC/ và LP_Hub_TPC/settings/
InterfaceManager:BuildInterfaceSection(Tabs.Misc)
SaveManager:BuildConfigSection(Tabs.Misc)

Window:SelectTab(1)

-- Refresh tool dropdown lần đầu
task.spawn(refreshToolDropdown)

-- Auto-load DB on startup
task.spawn(function()
    task.wait(1.5)
    local ok = loadEnemyDB()
    local n  = 0; for _ in pairs(EnemyDB) do n += 1 end
    if ok then
        pcall(function() if MobDropdown  then MobDropdown:SetValues(getDBList("Mob"))   end end)
        pcall(function() if BossDropdown then BossDropdown:SetValues(getDBList("Boss"))  end end)
        pcall(function() if ItemDropdown then ItemDropdown:SetValues(getDBDropItems())   end end)
    end
    -- Load config SAU KHI dropdown đã có đầy đủ options
    -- (nếu load trước, giá trị mob/boss bị SetValues ghi đè)
    pcall(function() SaveManager:LoadAutoloadConfig() end)
    Fluent:Notify({
        Title   = "AutoFarm Hub v3",
        Content = ok
            and string.format("Ready! DB: %d entries\nRightCtrl = minimize", n)
            or  "Loaded (DB failed — bấm 'Load Enemy Database' ở Main)",
        Duration = 5,
    })
end)
