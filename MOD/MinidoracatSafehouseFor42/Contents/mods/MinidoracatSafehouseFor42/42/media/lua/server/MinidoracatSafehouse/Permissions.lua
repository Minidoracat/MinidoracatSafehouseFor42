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
-- 撬棍、大鎚、拆除、釘路障、拆路障的目標在邊上（門、窗、牆、柵欄）時兩側的格子都查（MSH.edgeCells、P.CELL_WRAPS）；
-- 大鎚、拆除、搬家具的目標是多格物件時，每一塊的格子都查（groupCells、moveCells）。
-- 用語照原版繁中：「拆除」是 ISDismantleAction（BUILD），「拆解」是搬家具的 scrap（MOVE；目標是「拆除」拆得掉的東西時
-- BUILD 也要，使用者 2026-11-10）。
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
    { "ISPlowAction", BIT.FARM, function(a) return P.squareOf(a.gridSquare) end },          -- ISPlowAction.lua:152
    { "ISSeedActionNew", BIT.FARM, plantSquare },
    { "ISHarvestPlantAction", BIT.FARM, plantSquare },
    { "ISCurePlantAction", BIT.FARM, plantSquare },
    { "ISWaterPlantAction", BIT.FARM, function(a) return P.squareOf(a.sq) end },            -- ISWaterPlantAction.lua:143
    -- 移除作物、施肥與堆肥：complete 才 removePlant／fertilize（ISShovelAction.lua:59-71、ISFertilizeAction.lua:59-64）
    { "ISShovelAction", BIT.FARM, plantSquare },
    { "ISFertilizeAction", BIT.FARM, plantSquare },
}

-- 多格圖塊（sprite grid）每一格的 x, y 加進 cells；(x, y) 是 sprite 那一塊所在的格子
-- （IsoSpriteGrid.getSpriteGridPosX／Y；原版同一個算法：ISMoveableSpriteProps.lua:1094-1107）
local function addGridCells(cells, sprite, x, y)
    local grid = sprite ~= nil and sprite:getSpriteGrid() or nil
    if grid == nil then return end
    local left, top = x - grid:getSpriteGridPosX(sprite), y - grid:getSpriteGridPosY(sprite)
    for gx = 0, grid:getWidth() - 1 do
        for gy = 0, grid:getHeight() - 1 do
            cells[#cells + 1] = left + gx
            cells[#cells + 1] = top + gy
        end
    end
end

-- 大鎚、拆除、搬家具、釘路障、拆路障：目標可能是邊上的物件（牆、門、窗、柵欄），兩側任一格拒絕就拒絕（使用者 2026-11-10；
-- 格子清單 MSH.edgeCells，Contract.lua）。大鎚、拆除、搬家具另外加原版會一起動到的物件所在的格子（groupCells）：
-- · 各動作自己找的一組（finders）。大鎚：樓梯、雙開門四扇、車庫門、墓穴，用原版同一組 buildUtil 呼叫
--   （ISDestroyStuffAction.lua:266-271）。搬家具的修理：樓梯、車庫門、雙開門四扇（修理會把這些一起補滿，
--   ISMoveableSpriteProps.lua:3521-3561）。拆除與搬家具的其他模式：樓梯（ISDismantleAction.lua:77-81），以及伺服器移除多格物件的
--   其中一塊時一起移除的（IsoGridSquare.transmitRemoveItemFromSquare，IsoGridSquare.java:5933-5960 →
--   IsoObjectUtils.getAllMultiTileObjects，IsoObjectUtils.java:83-155）：雙開門是同一對的另一扇（1↔2、3↔4，
--   IsoDoor.java:2845-2856）、車庫門每一片。
-- · 多格 entity 用它自己的清單（SpriteConfig.getAllMultiSquareObjects，SpriteConfig.java:169-181），多格家具照 sprite grid 逐格。
-- · 雞舍：大鎚拆的是它的每一塊（IsoHutch.removeHutch，IsoHutch.java:986-1013）。
local function viaBuildUtil(name)
    return function(obj) return buildUtil[name](obj) end
end
local function doorPair(obj)
    local i = IsoDoor.getDoubleDoorIndex(obj)
    if i == -1 then return {} end
    return { IsoDoor.getDoubleDoorObject(obj, IsoDoor.getDoubleDoorPartnerIndex(i)) }
end
local SLEDGE_GROUPS = { viaBuildUtil("getStairObjects"), viaBuildUtil("getDoubleDoorObjects"), viaBuildUtil("getGarageDoorObjects"),
    viaBuildUtil("getGraveObjects") }
local REMOVE_GROUPS = { viaBuildUtil("getStairObjects"), doorPair, viaBuildUtil("getGarageDoorObjects") }
-- 修理不動樓梯頂端的平台地板（原版傳 skipFloor，ISMoveableSpriteProps.lua:3522）
local REPAIR_GROUPS = { function(obj) return buildUtil.getStairObjects(obj, true) end, viaBuildUtil("getGarageDoorObjects"),
    viaBuildUtil("getDoubleDoorObjects") }
local function groupCells(obj, finders)
    local cells = MSH.edgeCells(obj)
    if #cells == 0 then return cells end
    local function addAll(list)
        for _, o in ipairs(list) do
            local more = MSH.edgeCells(o)
            for i = 1, #more do cells[#cells + 1] = more[i] end
        end
    end
    for _, find in ipairs(finders) do addAll(find(obj)) end
    -- 雙開門只照上面各動作自己的那一組：建造選單蓋的雙開門同時是四格的 entity，但原版移除它只到同一對
    -- （getAllMultiTileObjects 先看雙開門就回，IsoObjectUtils.java:84-96）
    if IsoDoor.getDoubleDoorIndex(obj) == -1 then
        local cfg = obj:getSpriteConfig()
        if cfg ~= nil and cfg:isValidMultiSquare() then
            local parts = ArrayList.new()
            cfg:getAllMultiSquareObjects(parts)
            addAll(MSH.toArray(parts))
        end
        addGridCells(cells, obj:getSprite(), cells[1], cells[2])
    end
    if instanceof(obj, "IsoHutch") then addAll(MSH.toArray(obj:getAllHutchObjects())) end
    return cells
end

-- 旋轉多格家具：原版先撿起原本那一組（origSpriteName 的 sprite grid，從動作那格推），再以其中一塊為錨點放下新的一組
-- （ISMoveableSpriteProps.lua:2881-2897）。錨點是原本那組裡圖塊等於新圖塊的那一塊，沒有就是第一塊（左上；:2790-2797）。
local function rotateCells(cells, origName, sprite, x, y)
    local orig = type(origName) == "string" and getSprite(origName) or nil
    local grid = orig ~= nil and orig:getSpriteGrid() or nil
    if grid == nil then return end
    addGridCells(cells, orig, x, y)
    local left, top = x - grid:getSpriteGridPosX(orig), y - grid:getSpriteGridPosY(orig)
    local ax, ay, found = left, top, false
    for gx = 0, grid:getWidth() - 1 do
        for gy = 0, grid:getHeight() - 1 do
            if not found and sprite ~= nil and grid:getSprite(gx, gy) == sprite then
                ax, ay, found = left + gx, top + gy, true
            end
        end
    end
    addGridCells(cells, sprite, ax, ay)
end

-- 搬家具（MOVE）：原版各模式實際會動到的東西都查，用原版同一個找法找目標。
-- · 撿起、放下、旋轉照 a.square（ISMoveablesAction.lua:274）：撿起找 findOnSquare(square, moveProps.spriteName)
--   （ISMoveableSpriteProps.lua:1265-1267），旋轉找 findOnSquare(square, origSpriteName)（:2918）。找到的是牆上的貼圖時
--   （第二個回傳值，:1023-1030），動的是那張貼圖，不是牆，只查 a.square。
-- · 拆解、修理不看 a.square，動的是 moveProps.object（:3472-3500, 3574-3577）。
-- 找到的物件走 groupCells（邊上的物件兩側、一起移除的、多格的每一塊）。多格家具另外從 a.square 推每一格
-- （放下時物件還不存在；:1265-1282, 1975-2005 逐格處理），旋轉照 rotateCells。
local function moveCells(a)
    local cells = {}
    local function addObject(o)
        local more = groupCells(o, a.mode == "repair" and REPAIR_GROUPS or REMOVE_GROUPS)
        for i = 1, #more do cells[#cells + 1] = more[i] end
    end
    local function addFound(o, overlay)
        if overlay == nil then addObject(o) end
    end
    local props, sq = a.moveProps, P.squareOf(a.square)
    if type(props) ~= "table" then props = {} end
    if sq ~= nil then
        local x, y = sq:getX(), sq:getY()
        cells[1], cells[2] = x, y
        if a.mode == "rotate" then
            rotateCells(cells, a.origSpriteName, props.sprite, x, y)
        else
            addGridCells(cells, props.sprite, x, y)
        end
        if type(props.findOnSquare) == "function" then
            addFound(props:findOnSquare(sq, props.spriteName))
            addFound(props:findOnSquare(sq, a.origSpriteName))
        end
    end
    addObject(props.object)
    return cells
end

-- { 類別名, 位元, 取要查的格子（扁平 x1, y1, x2, y2…）, 另一個也要有的位元（選用：function(a) 回位元或 nil） }
P.CELL_WRAPS = {
    { "ISDestroyStuffAction", BIT.BUILD, function(a) return groupCells(a.item, SLEDGE_GROUPS) end },       -- ISDestroyStuffAction.lua:362
    { "ISDismantleAction", BIT.BUILD, function(a) return groupCells(a.thumpable, REMOVE_GROUPS) end },     -- ISDismantleAction.lua:107
    { "ISBarricadeAction", BIT.BUILD, function(a) return MSH.edgeCells(a.item) end },                      -- ISBarricadeAction.lua:193
    { "ISUnbarricadeAction", BIT.BUILD, function(a) return MSH.edgeCells(a.item) end },                    -- ISUnbarricadeAction.lua:167
    -- 拆解玩家蓋的東西（ISThumpableSpriteProps:scrapObjectViaCursor 這類，ISMoveableSpriteProps.lua:42, 4320-4358）和「拆除」
    -- 拆的是同一批，BUILD 也要
    { "ISMoveablesAction", BIT.MOVE, moveCells, function(a)
        if a.mode == "scrap" and type(a.moveProps) == "table" and MSH.isBuilt(a.moveProps.object) then return BIT.BUILD end
    end },
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
    -- entity 的 OnCreate 會動到 face 以外的格子（每放一塊呼叫一次，ISBuildIsoEntity.lua:749-752），照它的名字認：
    -- · 路障（BuildRecipeCode.barricade.OnCreate，entity_barricade_*）：釘的是面向那一側的門窗，朝 n／w 時門窗在錨點格的
    --   北邊／西邊，朝 s／e 時在 (x, y+1)／(x+1, y) 那格（buildRecipeCode.lua:98-117）。面向那一側的鄰格也查，門窗兩側就都
    --   查到。面向的名稱同原版傳給 OnCreate 的。
    -- · 樓梯（BuildRecipeCode.stairs.OnCreate）：頂端那一段（圖塊型別 stairsTN／stairsTW）在它北邊／西邊那格的上一層
    --   補平台地板（buildRecipeCode.lua:225-296），那一格也查。
    if item.objectInfo ~= nil and type(item.getFace) == "function" then
        pcall(function()
            local onCreate = item.objectInfo:getScript():getOnCreate()
            if type(onCreate) ~= "string" then return end
            local face = item:getFace()
            if string.find(onCreate, "BuildRecipeCode.barricade.", 1, true) == 1 then
                local f = face:getFaceName()
                if f == "n" then add(x, y - 1) elseif f == "s" then add(x, y + 1)
                elseif f == "w" then add(x - 1, y) elseif f == "e" then add(x + 1, y) end
            elseif string.find(onCreate, "BuildRecipeCode.stairs.", 1, true) == 1 then
                for zz = 0, face:getzLayers() - 1 do
                    for xx = 0, face:getWidth() - 1 do
                        for yy = 0, face:getHeight() - 1 do
                            local info = face:getTileInfo(xx, yy, zz)
                            local name = info and info:getSpriteName()
                            local sprite = name and getSprite(name)
                            local t = sprite and sprite:getTileType()
                            if t == IsoObjectType.stairsTN then add(x + xx, y + yy - 1)
                            elseif t == IsoObjectType.stairsTW then add(x + xx - 1, y + yy) end
                        end
                    end
                end
            end
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
local function wrapCompleteCells(name, bit, cells, also)
    local cls = _G[name]
    if type(cls) ~= "table" or type(cls.complete) ~= "function" then
        MSH.log("permissions: " .. name .. ".complete missing, not wrapped")
        return
    end
    local orig = cls.complete
    cls.complete = function(self)
        if self.character ~= nil then
            local list = cells(self)
            if P.deniesCells(self.character, list, bit, name) then return false end
            local more = also ~= nil and also(self) or nil
            if more ~= nil and P.deniesCells(self.character, list, more, name) then return false end
        end
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
-- 只包 complete 擋不住（開鎖在 animEvent）。照 BUILD（和大鎚、拆除、路障同類），門窗兩側都看（使用者 2026-11-10，
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
    for _, w in ipairs(P.CELL_WRAPS) do wrapCompleteCells(w[1], w[2], w[3], w[4]) end
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
