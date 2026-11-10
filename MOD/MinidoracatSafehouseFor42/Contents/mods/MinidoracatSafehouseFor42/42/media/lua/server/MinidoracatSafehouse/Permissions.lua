-- MinidoracatSafehouse/Permissions.lua：細分權限 USE／MOVE／BUILD／FARM 的伺服器防線（計畫 §6.6，契約「M2 細分權限」）。
-- 只比原版更嚴：目標格在 managed claim（R.list() 中 lifecycle＝active，含 legacy 來源）裡、actor 不是屋主、
-- MSH.Claims.roleOf 的位元缺該位 → 拒絕；managed 以外（含 foreign 原生屋）照原版。不分安全屋內外的只有三處，
-- 都是正常客戶端不會送的值：農務指令 cheat 不接受改作物的 x, y（wrapFarmingCommands；判定靠這兩個欄位）、
-- 建造的座標不是有限數就不蓋（wrapBuild）、割草沒有 character／sq 或 radius 不是數字就不割（wrapScything）。
-- 手法照 Safehouse E2E perm-mp／perm2-mp 實測（local://sharing-ref.md §3）：
--   MP 由伺服器重建 timed action 後呼叫 serverStart、到時呼叫 complete，complete 回 false＝拒絕、原版客戶端停下；
--   伺服器不跑 isValid（NetTimedAction.java:117-120, 132-139；42.22.2 和 42.21.0 相同）。NetTimedAction 以 rawget 取 serverStart／complete
--   （:97, 134），KahluaTableImpl.rawget 找不到會往 metatable 找（KahluaTableImpl.java:100），實例的 metatable 就是類別
--   （ISBaseTimedAction.lua:173-176），所以在類別上換函式就生效。
-- 取水 ISTakeWaterAction 在 serverStart 擋（animEvent 分段轉水，ISTakeWaterAction.lua:31-48, 151-161）；撬棍 ISForceOpen 在 attempt 擋
-- （伺服器 animEvent 呼叫 attempt：扣門血、打破窗戶在 attempt 裡，回 "success" 才開鎖，ISForceOpen.lua:48-103）；Actions.build
-- 不呼叫原函式（BuildAction.java:108-117 不看回傳值），照座標查建造物件會寫入的每一格（P.buildCells）；割草 ISScything 查範圍裡
-- 有作物的每一格（wrapScything）；爐子面板 client command 只能在原版處理後翻回來（ClientCommands.lua:1146-1158）。
-- 撬棍、大鎚、拆解、釘路障、拆路障的目標在邊上（門、窗、牆、柵欄）時兩側的格子都查（MSH.edgeCells、P.CELL_WRAPS）。
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
-- instanceof 是 Java isInstance（LuaManager.java:2971-2975）；IsoObject:getSquare（iso/IsoObject.java:1059）
function P.squareOf(o)
    if o == nil then return nil end
    if instanceof(o, "IsoGridSquare") then return o end
    if instanceof(o, "IsoObject") then return o:getSquare() end
    return nil
end

-- 作物：原版照座標找（SFarmingSystem.instance:getLuaObjectAt → GlobalObjectSystem.getObjectAt，SGlobalObjectSystem.lua:123-125、
-- GlobalObjectLookup.java:72-90；不看那一帶有沒有載入）。判定用同一個呼叫、同一組參數找，找到的就是原版會找到的那株
-- （客戶端送來的座標是什麼型別、原版怎麼轉都一樣）。回兩個目標（只有 getX／getY，給 P.denies；claim 是平面範圍）：
-- 那株在查表裡的位置（Java 的 GlobalObject:getX／getY，GlobalObject.java:33-39；globalObject 欄位由 SGlobalObject:new 設，
-- SGlobalObject.lua:74），以及它 Lua 欄位的 x, y（原版找到之後照這組找格子與世界物件，SGlobalObject.lua:30-36；
-- 是一般的 Lua 欄位，不保證和查表的位置相同）。兩個都查。
-- 找不到回 nil（原版也找不到）；呼叫丟錯就往外丟（原函式不會被呼叫）。
local Pos = {}
Pos.__index = Pos
function Pos:getX() return self.x end
function Pos:getY() return self.y end
function P.plantAt(x, y, z)
    local plant = SFarmingSystem.instance:getLuaObjectAt(x, y, z)
    if plant == nil then return nil end
    local g = plant.globalObject
    return setmetatable({ x = g:getX(), y = g:getY() }, Pos), setmetatable({ x = plant.x, y = plant.y }, Pos)
end

-- 作物的 timed action：self.plant 帶 x, y, z（ISSeedActionNew.lua:62、ISHarvestPlantAction.lua:59、ISCurePlantAction.lua:57、
-- ISShovelAction.lua:60、ISFertilizeAction.lua:60）
local function plantSquare(self)
    local plant = self.plant
    return P.plantAt(plant.x, plant.y, plant.z)
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
    -- 加油、修理與搬走發電機：三個都在 complete 才改發電機
    { "ISAddFuel", BIT.USE, function(a) return P.squareOf(a.generator) end },              -- ISAddFuel.lua:74
    { "ISFixGenerator", BIT.USE, function(a) return P.squareOf(a.generator) end },         -- ISFixGenerator.lua:89
    { "ISTakeGenerator", BIT.MOVE, function(a) return P.squareOf(a.generator) end },       -- ISTakeGenerator.lua:66
    { "ISFluidTransferAction", BIT.USE, fluidSquare },
    { "ISMoveablesAction", BIT.MOVE, function(a) return P.squareOf(a.square) end },         -- ISMoveablesAction.lua:274
    { "ISPlowAction", BIT.FARM, function(a) return P.squareOf(a.gridSquare) end },          -- ISPlowAction.lua:152
    { "ISSeedActionNew", BIT.FARM, plantSquare },
    { "ISHarvestPlantAction", BIT.FARM, plantSquare },
    { "ISCurePlantAction", BIT.FARM, plantSquare },
    { "ISWaterPlantAction", BIT.FARM, function(a) return P.squareOf(a.sq) end },            -- ISWaterPlantAction.lua:143
    -- 移除作物、施肥與堆肥：complete 才 removePlant／fertilize（ISShovelAction.lua:59-71、ISFertilizeAction.lua:59-64）
    { "ISShovelAction", BIT.FARM, plantSquare },
    { "ISFertilizeAction", BIT.FARM, plantSquare },
}

-- 大鎚、拆解、釘路障、拆路障：目標可能是邊上的物件（牆、門、窗、柵欄），兩側任一格拒絕就拒絕（使用者 2026-11-10；
-- 格子清單 MSH.edgeCells，Contract.lua）。大鎚與拆解另外加原版會一起拆掉的物件所在的格子（樓梯、雙開門、車庫門、墓穴：
-- ISDestroyStuffAction.lua:276-306、ISDismantleAction.lua:77-81，用原版同一組 buildUtil 呼叫找）。
local GROUP_FNS = { "getStairObjects", "getDoubleDoorObjects", "getGarageDoorObjects", "getGraveObjects" }
local function groupCells(obj, fns)
    local cells = MSH.edgeCells(obj)
    if #cells == 0 then return cells end
    for _, fn in ipairs(fns) do
        for _, o in ipairs(buildUtil[fn](obj)) do
            local more = MSH.edgeCells(o)
            for i = 1, #more do cells[#cells + 1] = more[i] end
        end
    end
    return cells
end

-- { 類別名, 位元, 取要查的格子（扁平 x1, y1, x2, y2…） }
P.CELL_WRAPS = {
    { "ISDestroyStuffAction", BIT.BUILD, function(a) return groupCells(a.item, GROUP_FNS) end },               -- ISDestroyStuffAction.lua:362
    { "ISDismantleAction", BIT.BUILD, function(a) return groupCells(a.thumpable, { "getStairObjects" }) end }, -- ISDismantleAction.lua:107
    { "ISBarricadeAction", BIT.BUILD, function(a) return MSH.edgeCells(a.item) end },                          -- ISBarricadeAction.lua:193
    { "ISUnbarricadeAction", BIT.BUILD, function(a) return MSH.edgeCells(a.item) end },                        -- ISUnbarricadeAction.lua:167
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

-- 一串格子（扁平 x1, y1, x2, y2…）任一格拒絕就拒絕；沒有 actor → false（照原版）。邊上的物件（門、窗、牆、柵欄）
-- 用 MSH.edgeCells 列出兩側的格子（使用者 2026-11-10）。
function P.deniesCells(player, cells, bit, label)
    if player == nil then return false end
    for i = 1, #cells, 2 do
        if P.deniesAt(player, cells[i], cells[i + 1], bit, label) then return true end
    end
    return false
end

-- ===== 建造的佔用範圍 =====

-- 原版多格建造類別算其餘各格的方法：只讀 square:getX/getY/getZ（ISWoodenStairs.lua:227-262、ISDoubleDoor.lua:263-298、
-- ISDoubleTileFurniture.lua:159、ISEmptyGraves.lua:188），錨點格可能還不存在，所以傳座標替身。
-- 樓梯頂端那格：AddStairs 會在那裡補地板（IsoGridSquare.java:4894-4918）。
local POS_FNS = { "getSquare2Pos", "getSquare3Pos", "getSquare4Pos", "getSquareTopPos" }

-- 建造物件 create(x, y, z, north) 會寫入的每一格的 x, y（扁平 x1, y1, x2, y2…；第一組是錨點）。claim 是平面範圍，
-- 樓層不必列。認不得的類別只有錨點。item 是伺服器重建的建造物件（BuildAction.java:121-162），
-- 呼叫物件方法的每一段都 pcall：丟錯就略過那段，錨點照查。ponytail: 照方法名認類別，子類別改寫 create 的範圍算不到；遇到再加。
function P.buildCells(item, x, y, z, north)
    local cells = { x, y }
    if type(item) ~= "table" then return cells end
    local function add(cx, cy)
        if MSH.isFinite(cx) and MSH.isFinite(cy) then
            cells[#cells + 1] = math.floor(cx)
            cells[#cells + 1] = math.floor(cy)
        end
    end
    -- entity：照 face 逐格（ISBuildIsoEntity:create :588-601；isValid :467-483 同一個判斷）。其他 MOD 的 getFace 不一定是
    -- FaceScript：Knox Buildworks 只回 getFaceName（KBWBuildingObject.lua:693-696），0.12.0 在這裡丟錯，連屋主都蓋不了。
    -- 先看方法在不在：pcall 接住的錯照樣在伺服器 log 印堆疊（KahluaThread.java:953-963）
    if type(item.getFace) == "function" then
        pcall(function()
            local face = item:getFace()
            if face == nil or type(face.getzLayers) ~= "function" then return end
            for zz = 0, face:getzLayers() - 1 do
                for xx = 0, face:getWidth() - 1 do
                    for yy = 0, face:getHeight() - 1 do
                        local info = face:getTileInfo(xx, yy, zz)
                        if info and (info:getSpriteName() or info:isBlocking()) then add(x + xx, y + yy) end
                    end
                end
            end
        end)
    end
    -- Knox Buildworks：create 照 getFootprint() 的 dx／dy 放有 sprite 的格、補建有 sprite 或 blocks 的格
    -- （KBWBuildingObject.lua:715-723, 1413-1416）。footprint 照 nSprite 選面（:685-688）：伺服器用 new 從 direction
    -- 重建（:470-486），但牆類的 create 先照 north 改 nSprite（:1313-1316）。direction 與 north 是封包裡兩個欄位，
    -- 改過的客戶端可以送不一致的，所以牆類照 create 的規則算、算完還原
    if type(item.getFootprint) == "function" then
        local saved = item.nSprite
        if item.isWallLike == true then item.nSprite = north and 2 or 1 end
        pcall(function()
            for _, t in ipairs(item:getFootprint() or {}) do
                if type(t) == "table" and (t.sprite or t.blocks) then add(x + (t.dx or 0), y + (t.dy or 0)) end
            end
        end)
        item.nSprite = saved
    end
    local pos = { getX = function() return x end, getY = function() return y end, getZ = function() return z end }
    for _, name in ipairs(POS_FNS) do
        if type(item[name]) == "function" then
            local ok, cx, cy = pcall(item[name], item, pos, north)
            if ok then add(cx, cy) end
        end
    end
    -- 兔籠：IsoHutch 照 def.extraSprites 的 xoffset／yoffset 建其餘各格（IsoHutch.java:89-117）
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
    -- 建造選單的路障（entity_barricade_*，OnCreate 是 BuildRecipeCode.barricade.OnCreate）：釘的是面向那一側的門窗，
    -- 朝 n／w 時門窗在錨點格的北邊／西邊，朝 s／e 時在 (x, y+1)／(x+1, y) 那格（buildRecipeCode.lua:98-117）。
    -- 面向那一側的鄰格也查，門窗兩側就都查到。面向的名稱同原版傳給 OnCreate 的（ISBuildIsoEntity.lua:749-752）
    if item.objectInfo ~= nil and type(item.getFace) == "function" then
        pcall(function()
            local onCreate = item.objectInfo:getScript():getOnCreate()
            if type(onCreate) ~= "string" or string.find(onCreate, "BuildRecipeCode.barricade.", 1, true) ~= 1 then return end
            local f = item:getFace():getFaceName()
            if f == "n" then add(x, y - 1) elseif f == "s" then add(x, y + 1)
            elseif f == "w" then add(x - 1, y) elseif f == "e" then add(x + 1, y) end
        end)
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
        local ok, err = pcall(sendServerCommand, e.player, MSH.MODULE, "denied", e.args)   -- LuaManager.java:8898-8902
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
        local a, b = pick(self)        -- 第二個目標只有作物有
        if P.denies(self.character, a, bit, name) or P.denies(self.character, b, bit, name) then return false end
        return orig(self)
    end
end

-- 目標是一串格子的動作（P.CELL_WRAPS）
local function wrapCompleteCells(name, bit, cells)
    local cls = _G[name]
    if type(cls) ~= "table" or type(cls.complete) ~= "function" then
        MSH.log("permissions: " .. name .. ".complete missing, not wrapped")
        return
    end
    local orig = cls.complete
    cls.complete = function(self)
        if self.character ~= nil and P.deniesCells(self.character, cells(self), bit, name) then return false end
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

-- 撬棍強開（42.22 ISForceOpen，MP 是 NetTimedAction）：伺服器 animEvent 收到 ForceOpenAttempt 就呼叫 attempt，回 "success"
-- 時 forceOpen＋sync、回 "fail" 時 forceComplete（ISForceOpen.lua:79-103）；掙扎扣門血、失敗扣門血或打破窗戶也都在 attempt 裡
-- （:61-71）。所以在 attempt 擋：回 "fail"、不呼叫原函式＝不開鎖、不扣血、不打破，complete 照 outcome 回 false（:40-42）。
-- 只包 complete 擋不住（開鎖在 animEvent）。照 BUILD（和大鎚、拆解、路障同類），門窗兩側都看（使用者 2026-11-10，
-- MSH.edgeCells）。原版 isValid 不在伺服器跑，非門窗的物件交給原函式（:49-51 回 "fail"）。
local function wrapForceOpen()
    local F = ISForceOpen
    if type(F) ~= "table" or type(F.attempt) ~= "function" then
        MSH.log("permissions: ISForceOpen.attempt missing, not wrapped")
        return
    end
    local orig = F.attempt
    F.attempt = function(self)
        if instanceof(self.object, "IForceablePortal")
            and P.deniesCells(self.character, MSH.edgeCells(self.object), BIT.BUILD, "ISForceOpen") then
            return "fail"
        end
        return orig(self)
    end
end

-- 割草（ISScything）：complete 從 sq 往 +x、+y 割 radius×radius 格，格上的作物能用鐮刀收的就收成、其他的毀掉
-- （ISScything.lua:38-51, 80-87）。範圍裡有原版會動到的作物（同 :81 的判斷）的格子，任一格拒絕就整個不做（同 Actions.build）；
-- 沒有作物的格子照原版（割草本身不看權限）。getLuaObjectOnSquare 同原版 :80。
-- radius 用 tonumber 取值：和原版 :42-43 的算術是同一個轉換（KahluaThread.java:377、BaseLib.java:353-355 都走
-- KahluaUtil.rawTonumber，數字字串也算數字），查的範圍就是原版割的範圍。沒有 character、sq 或 radius 轉不成數字時不呼叫原函式。
local function wrapScything()
    local S = ISScything
    if type(S) ~= "table" or type(S.complete) ~= "function" then
        MSH.log("permissions: ISScything.complete missing, not wrapped")
        return
    end
    local orig = S.complete
    S.complete = function(self)
        local sq, r = self.sq, tonumber(self.radius)
        if self.character == nil or sq == nil or r == nil then return false end
        local x0, y0, z = sq:getX(), sq:getY(), sq:getZ()
        for x = x0, x0 + r - 1 do
            for y = y0, y0 + r - 1 do
                local s = getSquare(x, y, z)        -- 同原版 :44
                local plant = s and SFarmingSystem.instance:getLuaObjectOnSquare(s)
                if plant and plant.state ~= "destroyed" and plant.state ~= "harvested" and plant.state ~= "plow"
                    and P.deniesAt(self.character, s:getX(), s:getY(), BIT.FARM, "ISScything") then
                    return false
                end
            end
        end
        return orig(self)
    end
end

-- 全域 Actions.build（ActionManager.lua:26-32）：任一格拒絕就不呼叫原函式；客戶端照樣顯示完成，靠 denied 推送說明。
-- 只看座標，不需要格子存在（P.deniesAt）。x, y, z 是 BuildAction 從封包的 float 轉的（BuildAction.java:58-61），
-- 不是有限數就不蓋。
local function wrapBuild()
    if type(Actions) ~= "table" or type(Actions.build) ~= "function" then
        MSH.log("permissions: Actions.build missing, not wrapped")
        return
    end
    local orig = Actions.build
    Actions.build = function(character, args)
        if type(args) == "table" and character ~= nil then
            if not (MSH.isFinite(args.x) and MSH.isFinite(args.y) and MSH.isFinite(args.z)) then return end
            local cells = P.buildCells(args.item, math.floor(args.x), math.floor(args.y), math.floor(args.z), args.north == true)
            if P.deniesCells(character, cells, BIT.BUILD, "Actions.build") then return end
        end
        return orig(character, args)
    end
end

-- SFarmingSystemCommands（farmingCommands.lua:13-141）：SFarmingSystem:OnClientCommand 每次以欄位查表（SFarmingSystem.lua:84, 577），
-- 換欄位就生效。player 為 nil 是伺服器自己呼叫（SFarmingSystem.lua:640 destroyPlant），照原版。
-- 指令照 args.x, y, z 找作物（getPlantAt，:9-11），plow 另外照同一組座標找格子（:68）：兩個都用原版的呼叫找，
-- 找到的作物或格子在安全屋裡而沒有 FARM 就不執行。
-- cheat（:127-139，照 args.var 改作物的欄位）不接受 var 是 x 或 y，不分安全屋內外：原版找到作物之後照這兩個欄位找格子
-- 與世界物件（SGlobalObject.lua:30-36），各處的判定都當它等於作物所在的位置。原版選單只送生長、水分、病蟲害與健康
-- （ISFarmingMenu.lua:468-490, 1431-1450）。
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
            if player ~= nil and type(args) == "table" then
                if name == "cheat" and (args.var == "x" or args.var == "y") then return end
                local a, b = P.plantAt(args.x, args.y, args.z)
                if P.denies(player, a, BIT.FARM, label) or P.denies(player, b, BIT.FARM, label)
                    or P.denies(player, getCell():getGridSquare(args.x, args.y, args.z), BIT.FARM, label) then
                    return
                end
            end
            return orig(player, args)
        end
    end
end

-- 爐子／微波爐面板 OK（ISOvenUI.lua:166-170、ISMicrowaveUI.lua:133-137）：原版處理器先跑（原版 Lua 排在 MOD 檔之前載入、先註冊
-- OnClientCommand：LuaManager.java:1193-1194；原版註冊在 ClientCommands.lua:1357），
-- 拒絕時把同格的 IsoStove 翻回去；原版寫入的定時與溫度不還原（§6.6）。格子用原版同一個呼叫找（getSquare，
-- ClientCommands.lua:1147）。IsoGridSquare:getObjects（IsoGridSquare.java:9212）、
-- IsoStove:Toggle（iso/objects/IsoStove.java:195；原版用例 ClientCommands.lua:1154）。
function P.onClientCommand(module, command, player, args)
    if module ~= "stove" or command ~= "setOvenParamsAndToggle" or type(args) ~= "table" then return end
    local sq = getSquare(args.x, args.y, args.z)
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
    for _, w in ipairs(P.CELL_WRAPS) do wrapCompleteCells(w[1], w[2], w[3]) end
    wrapTakeWater()
    wrapForceOpen()
    wrapBuild()
    wrapScything()
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
