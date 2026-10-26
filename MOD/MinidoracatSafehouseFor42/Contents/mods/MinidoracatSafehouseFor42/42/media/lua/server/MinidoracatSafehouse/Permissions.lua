-- MinidoracatSafehouse/Permissions.lua：細分權限 USE／MOVE／BUILD／FARM 的伺服器防線（計畫 §6.6，契約「M2 細分權限」）。
-- 只比原版更嚴：目標格在 managed claim（R.list() 中 lifecycle＝active，含 legacy 來源）裡、actor 不是屋主、
-- MSH.Claims.roleOf 的位元缺該位 → 拒絕；managed 以外（含 foreign 原生屋）完全照原版。
-- 手法照 Safehouse E2E perm-mp／perm2-mp 實測（local://sharing-ref.md §3）：
--   MP 由伺服器重建 timed action 後呼叫 serverStart、到時呼叫 complete，complete 回 false＝拒絕、原版客戶端停下；
--   伺服器不跑 isValid（42.21.0 NetTimedAction.java:117-120, 132-139）。NetTimedAction 以 rawget 取 serverStart／complete
--   （:97, 134），KahluaTableImpl.rawget 找不到會往 metatable 找（KahluaTableImpl.java:98），實例的 metatable 就是類別
--   （ISBaseTimedAction.lua:173-176），所以在類別上換函式就生效。
-- 取水 ISTakeWaterAction 在 serverStart 擋（animEvent 分段轉水，ISTakeWaterAction.lua:31-48, 151-161）；Actions.build
-- 不呼叫原函式（BuildAction.java:108-117 不看回傳值），照座標查建造物件會寫入的每一格（P.buildCells）；
-- 爐子面板 client command 只能在原版處理後翻回來（ClientCommands.lua:1096-1107）。
-- 拒絕：Audit.deny 聚合（每分鐘一行）＋下個 tick 推 denied 給本人（每人每 tick 一則）。
-- 檔尾是伺服器公開 API MinidoracatSafehouse.v1.denies（契約 docs/public-api.md）。

if isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Audit"
require "MinidoracatSafehouse/Registry"
require "MinidoracatSafehouse/Identity"
require "MinidoracatSafehouse/Server"
require "MinidoracatSafehouse/Claims"

local MSH = MinidoracatSafehouse
local first = MSH.Permissions == nil
local P = MSH.Permissions or {}
MSH.Permissions = P

local BIT = MSH.SHARE
P.outbox = P.outbox or {}    -- player → { code, bit, claimId }（同一 tick 只推最後一則）

-- ===== 目標格 =====

-- 格子、世界物件 → 格子；物品（自己手上的收音機、水瓶）與其他 → nil（照原版）。
-- instanceof 是 Java isInstance（LuaManager.java:2948-2952）；IsoObject:getSquare（iso/IsoObject.java:1042）
function P.squareOf(o)
    if o == nil then return nil end
    if instanceof(o, "IsoGridSquare") then return o end
    if instanceof(o, "IsoObject") then return o:getSquare() end
    return nil
end

-- 座標 → 格子；不是數字（客戶端送來的 args）回 nil。IsoCell.java:3190-3192（未載入回 nil）
function P.squareAt(x, y, z)
    if not (MSH.isFinite(x) and MSH.isFinite(y) and MSH.isFinite(z)) then return nil end
    return getCell():getGridSquare(x, y, z)
end

-- 作物：伺服器端 SPlantGlobalObject 帶 x, y, z（ISSeedActionNew.lua:62、ISHarvestPlantAction.lua:59、ISCurePlantAction.lua:57）
local function plantSquare(self)
    local plant = self.plant
    if type(plant) ~= "table" then return nil end
    return P.squareAt(plant.x, plant.y, plant.z)
end

-- 液體面板：source／target 的擁有者（ISFluidTransferAction.lua:119-120 → ISFluidContainer:getOwner :78-85）是世界物件才算
local function fluidSquare(self)
    return P.squareOf(self.sourceOwner) or P.squareOf(self.targetOwner)
end

-- { 類別名, 位元, 取目標 }：欄位出處是各類別 :new 裡的那一行
P.WRAPS = {
    { "ISToggleLightAction", BIT.USE, function(a) return P.squareOf(a.object) end },        -- ISToggleLightAction.lua:45
    -- 裝上、取下燈泡與電池、改裝燈具（complete 才改燈，ISLightActions.lua:25-34）
    { "ISLightActions", BIT.USE, function(a) return P.squareOf(a.lightswitch) end },          -- ISLightActions.lua:110
    { "ISToggleStoveAction", BIT.USE, function(a) return P.squareOf(a.object) end },        -- ISToggleStoveAction.lua:37
    { "ISRadioAction", BIT.USE, function(a) return P.squareOf(a.device) end },              -- ISRadioAction.lua:197
    { "ISPlugGenerator", BIT.USE, function(a) return P.squareOf(a.generator) end },         -- ISPlugGenerator.lua:53
    { "ISActivateGenerator", BIT.USE, function(a) return P.squareOf(a.generator) end },     -- ISActivateGenerator.lua:62
    -- 加油、修理與搬走發電機（2026-10-14 寫 perm3-mp 時發現沒包；三個都在 complete 才改發電機）
    { "ISAddFuel", BIT.USE, function(a) return P.squareOf(a.generator) end },              -- ISAddFuel.lua:74
    { "ISFixGenerator", BIT.USE, function(a) return P.squareOf(a.generator) end },         -- ISFixGenerator.lua:89
    { "ISTakeGenerator", BIT.MOVE, function(a) return P.squareOf(a.generator) end },       -- ISTakeGenerator.lua:66
    { "ISFluidTransferAction", BIT.USE, fluidSquare },
    { "ISMoveablesAction", BIT.MOVE, function(a) return P.squareOf(a.square) end },         -- ISMoveablesAction.lua:274
    { "ISDestroyStuffAction", BIT.BUILD, function(a) return P.squareOf(a.item) end },       -- ISDestroyStuffAction.lua:362
    { "ISDismantleAction", BIT.BUILD, function(a) return P.squareOf(a.thumpable) end },     -- ISDismantleAction.lua:107
    { "ISBarricadeAction", BIT.BUILD, function(a) return P.squareOf(a.item) end },          -- ISBarricadeAction.lua:193
    { "ISUnbarricadeAction", BIT.BUILD, function(a) return P.squareOf(a.item) end },        -- ISUnbarricadeAction.lua:167
    { "ISPlowAction", BIT.FARM, function(a) return P.squareOf(a.gridSquare) end },          -- ISPlowAction.lua:152
    { "ISSeedActionNew", BIT.FARM, plantSquare },
    { "ISHarvestPlantAction", BIT.FARM, plantSquare },
    { "ISCurePlantAction", BIT.FARM, plantSquare },
    { "ISWaterPlantAction", BIT.FARM, function(a) return P.squareOf(a.sq) end },            -- ISWaterPlantAction.lua:143
}

-- ===== 判定 =====

-- 含 (x, y) 的 managed claim（active；legacy 匯入的也是 active），看每一塊。範圍互不重疊（§7.3），第一筆就是，
-- 所以不必排序：直接走 R.md.claims（同 R.list 的篩選：整數 id、table、非 malformed），每個包裝到的動作都會走這裡，
-- 不配置、不排序（照 Admin.lua、Sharing.lua 的直接走訪）。
function P.claimAt(x, y)
    local md = MSH.Registry.md
    if md == nil then return nil end
    local ACTIVE = MSH.LIFECYCLE.ACTIVE
    for id, rec in pairs(md.claims) do
        if MSH.isInt(id) and type(rec) == "table" and not rec.malformed and rec.lifecycle == ACTIVE
            and MSH.Rect.listContains(rec.rects, x, y) then
            return rec
        end
    end
    return nil
end

-- 拒絕回 true（並記錄、排推送）；不在 managed claim → false（照原版）。只看座標（claim 是平面範圍、每層都算），
-- 不需要格子存在。preview＝預檢：判定相同，不寫稽核、不推送。
function P.deniesAt(player, x, y, bit, label, preview)
    local rec = P.claimAt(x, y)
    if rec == nil then return false end
    local who = MSH.Identity.principal(player)
    local bits = nil
    if who ~= nil then
        local _, b = MSH.Claims.roleOf(rec, who)
        bits = b
    end
    if MSH.hasBit(bits, bit) then return false end
    if not preview then
        MSH.Audit.deny(who or MSH.Identity.claimedName(player), label .. "@" .. tostring(rec.claimId), MSH.CODE.PERM_DENIED)
        P.outbox[player] = { code = MSH.CODE.PERM_DENIED, bit = bit, claimId = rec.claimId }
    end
    return true
end

-- timed action 與指令的目標格；沒有 actor 或目標 → false（照原版）
function P.denies(player, sq, bit, label)
    if player == nil or sq == nil then return false end
    return P.deniesAt(player, sq:getX(), sq:getY(), bit, label)
end

-- ===== 建造的佔用範圍 =====

-- 原版多格建造類別算其餘各格的方法：只讀 square:getX/getY/getZ（ISWoodenStairs.lua:227-262、ISDoubleDoor.lua:263-298、
-- ISDoubleTileFurniture.lua:159、ISEmptyGraves.lua:188），錨點格可能還不存在，所以傳座標替身。
-- 樓梯頂端那格：AddStairs 會在那裡補地板（IsoGridSquare.java:4907-4931）。
local POS_FNS = { "getSquare2Pos", "getSquare3Pos", "getSquare4Pos", "getSquareTopPos" }

-- 建造物件 create(x, y, z, north) 會寫入的每一格的 x, y（扁平 x1, y1, x2, y2…；第一組是錨點）。claim 是平面範圍，
-- 樓層不必列。認不得的類別只有錨點。item 是伺服器重建的建造物件（BuildAction.java:121-162），
-- 取範圍的方法丟錯也只剩錨點（pcall）。ponytail: 照方法名認類別，子類別改寫 create 的範圍算不到；遇到再加。
function P.buildCells(item, x, y, z, north)
    local cells = { x, y }
    if type(item) ~= "table" then return cells end
    local function add(cx, cy)
        if MSH.isFinite(cx) and MSH.isFinite(cy) then
            cells[#cells + 1] = math.floor(cx)
            cells[#cells + 1] = math.floor(cy)
        end
    end
    -- entity：照 face 逐格（ISBuildIsoEntity:create :579-592；isValid :458-474 同一個判斷）
    if type(item.getFace) == "function" then
        local ok, face = pcall(item.getFace, item)
        if ok and face ~= nil then
            for zz = 0, face:getzLayers() - 1 do
                for xx = 0, face:getWidth() - 1 do
                    for yy = 0, face:getHeight() - 1 do
                        local info = face:getTileInfo(xx, yy, zz)
                        if info and (info:getSpriteName() or info:isBlocking()) then add(x + xx, y + yy) end
                    end
                end
            end
        end
    end
    local pos = { getX = function() return x end, getY = function() return y end, getZ = function() return z end }
    for _, name in ipairs(POS_FNS) do
        if type(item[name]) == "function" then
            local ok, cx, cy = pcall(item[name], item, pos, north)
            if ok then add(cx, cy) end
        end
    end
    -- 兔籠：IsoHutch 照 def.extraSprites 的 xoffset／yoffset 建其餘各格（IsoHutch.java:87-115）
    local def = item.def
    if type(def) == "table" and type(def.extraSprites) == "table" then
        for _, s in pairs(def.extraSprites) do
            if type(s) == "table" and MSH.isFinite(s.xoffset) and MSH.isFinite(s.yoffset) then add(x + s.xoffset, y + s.yoffset) end
        end
    end
    -- 原版坡道游標：一直線 20 格（ISBuildRampCursor.lua:5-36；north20／south20 同一段，west20／east20 同一段）
    if type(item.addRampObject) == "function" then
        local w = item.which
        for i = 1, 19 do
            if w == "north20" or w == "south20" then add(x, y - i) elseif w == "west20" or w == "east20" then add(x - i, y) end
        end
    end
    return cells
end

-- 放在 tick：不在任何呼叫端的鎖或原版處理途中送網路（契約：網路送出延後）
function P.flush()
    local list = {}
    for player, args in pairs(P.outbox) do list[#list + 1] = { player = player, args = args } end
    if #list == 0 then return end
    P.outbox = {}
    for _, e in ipairs(list) do
        local ok, err = pcall(sendServerCommand, e.player, MSH.MODULE, "denied", e.args)   -- LuaManager.java:8962-8966
        if not ok then MSH.log("denied push failed: " .. tostring(err)) end
    end
end

-- ===== 包裝 =====

local function wrapComplete(name, bit, pick)
    local cls = _G[name]
    if type(cls) ~= "table" or type(cls.complete) ~= "function" then
        MSH.log("permissions: " .. name .. ".complete missing, not wrapped")
        return
    end
    local orig = cls.complete
    cls.complete = function(self)
        if P.denies(self.character, pick(self), bit, name) then return false end
        return orig(self)
    end
end

-- 取水：serverStart 擋下就不呼叫原函式（不排 takeFluid），updateUse 變 no-op，complete 回 false
local function wrapTakeWater()
    local W = ISTakeWaterAction
    if type(W) ~= "table" or type(W.serverStart) ~= "function" or type(W.updateUse) ~= "function"
        or type(W.complete) ~= "function" then
        MSH.log("permissions: ISTakeWaterAction missing, not wrapped")
        return
    end
    local oStart, oUse, oComplete = W.serverStart, W.updateUse, W.complete
    local function target(self) return P.squareOf(self.waterObject) end   -- ISTakeWaterAction.lua:178
    W.serverStart = function(self)
        if P.denies(self.character, target(self), BIT.USE, "ISTakeWaterAction") then
            self.mshDenied = true
            return
        end
        return oStart(self)
    end
    W.updateUse = function(self, delta)
        if self.mshDenied then return end
        return oUse(self, delta)
    end
    W.complete = function(self)
        if self.mshDenied or P.denies(self.character, target(self), BIT.USE, "ISTakeWaterAction") then return false end
        return oComplete(self)
    end
end

-- 全域 Actions.build（ActionManager.lua:26-32）：任一格拒絕就不呼叫原函式；客戶端照樣顯示完成，靠 denied 推送說明。
-- 只看座標，不需要格子存在（P.deniesAt）。
local function wrapBuild()
    if type(Actions) ~= "table" or type(Actions.build) ~= "function" then
        MSH.log("permissions: Actions.build missing, not wrapped")
        return
    end
    local orig = Actions.build
    Actions.build = function(character, args)
        if type(args) == "table" and character ~= nil
            and MSH.isFinite(args.x) and MSH.isFinite(args.y) and MSH.isFinite(args.z) then
            local cells = P.buildCells(args.item, math.floor(args.x), math.floor(args.y), math.floor(args.z), args.north == true)
            for i = 1, #cells, 2 do
                if P.deniesAt(character, cells[i], cells[i + 1], BIT.BUILD, "Actions.build") then return end
            end
        end
        return orig(character, args)
    end
end

-- SFarmingSystemCommands（farmingCommands.lua:13-141）：SFarmingSystem:OnClientCommand 每次以欄位查表（SFarmingSystem.lua:84, 577），
-- 換欄位就生效。player 為 nil 是伺服器自己呼叫（SFarmingSystem.lua:640 destroyPlant），P.denies 照原版放行。
local function wrapFarmingCommands()
    local cmds = SFarmingSystemCommands
    if type(cmds) ~= "table" then
        MSH.log("permissions: SFarmingSystemCommands missing, not wrapped")
        return
    end
    local names = {}
    for name, fn in pairs(cmds) do
        if type(fn) == "function" then names[#names + 1] = name end
    end
    for _, name in ipairs(names) do
        local orig = cmds[name]
        local label = "farm:" .. tostring(name)
        cmds[name] = function(player, args)
            if type(args) == "table" and P.denies(player, P.squareAt(args.x, args.y, args.z), BIT.FARM, label) then
                return
            end
            return orig(player, args)
        end
    end
end

-- 爐子／微波爐面板 OK（ISOvenUI.lua:166-170、ISMicrowaveUI.lua:133-137）：原版處理器先跑（LuaManager.java:1192-1193），
-- 拒絕時把同格的 IsoStove 翻回去；原版寫入的定時與溫度不還原（§6.6）。IsoGridSquare:getObjects（IsoGridSquare.java:9245）、
-- IsoStove:Toggle（iso/objects/IsoStove.java:195；原版用例 ClientCommands.lua:1104）。
function P.onClientCommand(module, command, player, args)
    if module ~= "stove" or command ~= "setOvenParamsAndToggle" or type(args) ~= "table" then return end
    local sq = P.squareAt(args.x, args.y, args.z)
    if not P.denies(player, sq, BIT.USE, "stove:setOvenParamsAndToggle") then return end
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        if instanceof(o, "IsoStove") then o:Toggle() end
    end
end

-- 開服才裝：vanilla server 檔（SFarmingSystemCommands）一定載完；熱重載不重包（P.installed 隨 MSH.Permissions 保留）
function P.install()
    if P.installed then return end
    P.installed = true
    for _, w in ipairs(P.WRAPS) do wrapComplete(w[1], w[2], w[3]) end
    wrapTakeWater()
    wrapBuild()
    wrapFarmingCommands()
end

MSH.Srv.hook("startup", "permissions", function() MSH.Permissions.install() end)
MSH.Srv.hook("tick", "permissions", function() MSH.Permissions.flush() end)

if first then
    Events.OnClientCommand.Add(function(module, command, player, args)
        MSH.Permissions.onClientCommand(module, command, player, args)
    end)
end

-- ===== 伺服器公開 API：MinidoracatSafehouse.v1（契約 docs/public-api.md）=====
-- 客戶端也有一支同簽名的 denies（client/…/PublicApi.lua，只給預覽提示用）；兩邊是不同的 Lua 狀態，各自補自己的 v1。

-- denies(player, x, y, z, bit[, opts]) → denied, code。參數不對時拒絕（true, BAD_ARGS），不丟錯。
function P.apiDenies(player, x, y, z, bit, opts)
    if not MSH.apiArgsOk(player, x, y, z, bit, opts) then return true, MSH.CODE.BAD_ARGS end
    local label = opts ~= nil and type(opts.label) == "string" and opts.label or "v1.denies"
    if P.deniesAt(player, x, y, bit, label, opts ~= nil and opts.preview == true) then return true, MSH.CODE.PERM_DENIED end
    return false
end

local v1 = MSH.v1 or {}
MSH.v1 = v1
v1.API_MAJOR = 1
v1.API_REVISION = math.max(v1.API_REVISION or 0, 2)
v1.CAPABILITIES = v1.CAPABILITIES or {}
v1.CAPABILITIES.denies = true
v1.BITS = MSH.API_BITS
v1.denies = function(...) return MSH.Permissions.apiDenies(...) end
