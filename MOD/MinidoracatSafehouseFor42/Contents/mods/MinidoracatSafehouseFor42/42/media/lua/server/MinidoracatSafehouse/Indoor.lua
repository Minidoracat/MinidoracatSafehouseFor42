-- MinidoracatSafehouse/Indoor.lua：室內檢查（使用者 2026-10-15：「判斷自己蓋的房子有沒有算室內，以及方便找出沒成為室內
-- 的原因」）。查詢 indoor { x, y, z }：那一格所在的房間、同一棟每一層的其他房間算不算室內，不算的話缺哪幾條牆、哪幾格
-- 屋頂，另回每一層走過的範圍。客戶端面板（client/…/IndoorPanel.lua）只顯示與標示。設計與使用者裁定見 decisions.md。
-- 在伺服器算：MP 的體溫在伺服器算（BodyDamage.Update 在客戶端對活著的玩家直接返回）；客戶端的 IsoRegions 會過期
-- （IsoRegionWorker 倒序送出，舊快照最後到），isInARoom 也不準（客戶端封閉且屋頂過半就建 user-defined RoomDef）。
-- 判定照引擎（IsoWorldRegion.isPlayerRoom）：一個房間＝一個 IsoWorldRegion，封閉（isEnclosed）而且每格頭上都有屋頂
-- （getRoofCnt == getSquareSize）才算室內。地圖原有的房間照地圖算；地下（z < 0）不算。實證 sh-indoor-1015e。
-- 找原因：
--   封閉、屋頂至少一半：整個 region 走一遍，沒屋頂的格子＝缺屋頂（ROOM／NEED_ROOF）。
--   其他：從有屋頂的格子出發、不穿牆走到的有屋頂格子＝房子；同一列或同一欄夾在房子格子中間的沒屋頂格子、房子外框裡
--   外面走不進來的沒屋頂格子也算房子（缺屋頂）；從房子不穿牆走出去的邊＝缺牆（OPEN）。封閉但屋頂不到一半的（例如圍籬
--   圍起來的院子裡的棚子、屋頂才蓋一角的房間）回 PART_ROOF：那些邊在圍起來的範圍裡面，隔牆或把屋頂蓋滿都行。
--   起點 NEAR 步內沒有屋頂＝室外（OUTSIDE）。
--   缺口那條邊上有門的另外列（doors）：引擎只把有牆屬性（cutN／cutW）或門框型別的邊算牆，原版綠、白車庫門開著時的門片
--   沒有牆屬性，Knox Pass 的模型門關著也沒有（使用者 2026-10-15 正式服回報車庫門被列成缺牆）。客戶端照開著／關著寫原因；
--   關著也不算牆的原版車庫門鏈（Knox Pass 兩層樓的門、閘門）另外標，裝了 4 版 Knox Pass 的客戶端提讀頭的「算室內」開關
--   （使用者 2026-10-22 裁定）。
--   關著的門片照格子現在的物件該算牆、引擎記的卻是缺口（原版右鍵開關門不通知 IsoRegions，紀錄停在上次的樣子）：查到
--   時由伺服器請引擎重算那幾格（玩家 2026-10-22 回報，使用者同日同意）。只在查詢時比對、只比對缺口上關著的門、只重算
--   對不上的格子；門開著、紀錄卻是牆的另一個方向不修（房間封閉就不看門）。
--   缺口在西邊、那格有西牆又有柱子的也另外列（pillars）：引擎整格有 WallSE（柱子的圖塊屬性）就不算那格的西牆
--   （IsoRegions.java:336），牆在也照缺口算（玩家 2026-10-19 回報）。柱子是蓋牆時遊戲自動補的牆角（buildUtil.addCorner
--   的 isCorner）就由伺服器拆掉（使用者 2026-10-19 裁定；那格有西牆時牆角多餘，拆前拆後畫面只差柱頂幾個像素，
--   sh-pillarroot-1019a）：新蓋的牆在 buildUtil.checkCorner 之後排進佇列、下一個 tick 才拆（I.install／I.tick；同一刻拆，
--   伺服器格子上的物件順序和還沒收到新牆的客戶端不同），已經存在的在查詢查到時排進佇列。玩家自己蓋的柱子不動，客戶端叫玩家拆。
-- 同一棟（使用者 2026-10-15：「每一層都分析」）：同一層從起點沿著有屋頂的格子往外找（不看牆、不進地圖房間），每碰到
-- 一個新的 region 就照上面分析一次；樓上、樓下從相鄰那一層走過的格子裡、這一層有地板而且頭上有屋頂的格子開始找。
-- 單層房子屋頂上的平台（上面沒再蓋一層）沒有這種格子，不算一層。
-- 效能（使用者 2026-10-15：「只有需要查的時候才查，平常不用一直掃」）：只在客戶端送查詢時算（面板開著才會送），
-- 同一人 1 秒冷卻、只查 LIMIT.INDOOR_REACH 格內，一次最多走 I.LIMIT 格。實測（sh-indoor-1015i～k，每一層都分析之後）：
-- 兩層的測試屋（三間、40 格）平均 0.6 ms，16x16（256 格）平均 4 ms、最慢 6 ms。

if isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Server"

local MSH = MinidoracatSafehouse
local I = MSH.Indoor or {}
MSH.Indoor = I

local CODE = MSH.CODE

I.LIMIT = 4096        -- 一次查詢最多走幾格（房子加上各房間）
I.NEAR = 4            -- 站的那格沒有屋頂時，往外找有屋頂的格子最多幾步
I.MAX_ROOMS = 12      -- 同一棟最多分析幾間（各層合計）
I.MAX_RUNS = 512      -- 每一層的範圍最多回幾段（同一列連續的格子算一段）
I.MAX_MARKS = 256     -- 每間最多回幾條缺牆、幾格缺屋頂（封包大小；count 照實數）
I.BOX_MAX = 16384     -- 找外面走不進來的格子時，外框面積超過就略過（斜著長的屋頂外框很大）
I.SLOW_MS = 50        -- 一次查詢超過就記 log

-- IsoRegions 的位元（IsoRegions.java BIT_WALL_N 等）：那些是 Java byte 常數，Kahlua 拿來做算術會丟錯，所以寫成數字
local WALL_N, WALL_W, FLOOR, STAIR = 1, 2, 16, 32
local DX = { [0] = 0, -1, 0, 1 }   -- 方向 0..3：北、西、南、東
local DY = { [0] = -1, 0, 1, 0 }

local function has(f, b) return f >= 0 and math.floor(f / b) % 2 == 1 end
local function flags(x, y, z) return IsoRegions.getSquareFlags(x, y, z) end   -- 沒有資料回 -1
local function key(x, y) return x * 100000 + y end

-- 這格往 d 能不能走：北、西邊看本格的牆位元，南、東邊看隔壁格的（DataChunk 判斷兩格相連的規則）
local function canMove(x, y, z, d)
    if d == 0 then return not has(flags(x, y, z), WALL_N) end
    if d == 1 then return not has(flags(x, y, z), WALL_W) end
    if d == 2 then return not has(flags(x, y + 1, z), WALL_N) end
    return not has(flags(x + 1, y, z), WALL_W)
end

-- 一條邊記成存它的那一格加上 1（那格的北邊）或 2（西邊）
local function edgeOf(x, y, d)
    if d == 0 then return x, y, 1 end
    if d == 1 then return x, y, 2 end
    if d == 2 then return x, y + 1, 1 end
    return x + 1, y, 2
end

-- 引擎算不算這格頭上有屋頂：照 DataChunk.recalcRoofs 由最高一層往下走（E2E 實測和 getRoofCnt 一致）
local function roofed(x, y, z)
    local top = z
    while top < 31 and flags(x, y, top + 1) >= 0 do top = top + 1 end
    if top == z then return false end
    local f = flags(x, y, top)
    local h = f > 0 and has(f, FLOOR)
    for zz = top - 1, z, -1 do
        f = flags(x, y, zz)
        local cr = IsoRegions.getChunkRegion(x, y, zz)
        local wr = cr and cr:getIsoWorldRegion() or nil
        local enc = wr ~= nil and wr:isEnclosed()
        if f <= 0 and not enc then
            h = false
            if zz == z then return false end
        else
            h = h or has(f, STAIR)
            local counted = h and cr ~= nil
            if zz == z then return counted end
            if counted then
                if wr ~= nil and not enc then h = false end
            else
                h = false
            end
            if not h then h = has(f, FLOOR) end
        end
    end
    return false
end

-- 地圖原有的房間（不是玩家圍出來的 user-defined RoomDef）：照地圖算，不看 IsoRegions。伺服器拿不到的格子當成不是
-- （IsoGridSquare.getRoom、isUserDefinedRoom）
local function mapRoom(cell, x, y, z)
    local sq = cell:getGridSquare(x, y, z)
    return sq ~= nil and sq:getRoom() ~= nil and not sq:isUserDefinedRoom()
end

-- 查詢共用的狀態：剩幾格可走、走過的外框（客戶端照它判斷附近的物件變動要不要重查）、各層的屋頂快取、找到的缺屋頂格子
-- （找同一棟的房間時可以穿過）、各層走過的格子（範圍）與分析過的 region。z 為鍵的表用 at 取
local function at(t, z)
    local v = t[z]
    if v == nil then
        v = {}
        t[z] = v
    end
    return v
end

-- 這一格是這一棟的一部分：記進那一層的範圍、撐大外框
local function visit(ctx, x, y, z)
    local k = key(x, y)
    local foot = at(ctx.foot, z)
    if foot[k] then return end
    foot[k] = true
    local list = at(ctx.footList, z)
    list[#list + 1] = x
    list[#list + 1] = y
    if x < ctx.minX then ctx.minX = x end
    if x > ctx.maxX then ctx.maxX = x end
    if y < ctx.minY then ctx.minY = y end
    if y > ctx.maxY then ctx.maxY = y end
    if z < ctx.minZ then ctx.minZ = z end
    if z > ctx.maxZ then ctx.maxZ = z end
end

local function newCtx(x, y, z)
    local cache = {}
    local ctx = { left = I.LIMIT, cell = getCell(), minX = x, minY = y, minZ = z, maxX = x, maxY = y, maxZ = z,
        partial = false, holes = {}, foot = {}, footList = {}, regions = {}, corners = {}, fix = {}, fixSeen = {},
        doorChecks = 0 }
    function ctx.roofed(rx, ry, rz)
        local c = at(cache, rz)
        local k = key(rx, ry)
        local v = c[k]
        if v == nil then
            v = roofed(rx, ry, rz)
            c[k] = v
        end
        return v
    end
    return ctx
end

-- 一間的結果：verdict、z（哪一層）、size（格數）、roofs（有屋頂的格數）、walls（房子邊上有牆的邊數）、x, y（分析的
-- 起點；起點沒有屋頂時是 NEAR 步內最近的有屋頂格子）、gaps（缺牆：x, y, side 三個一組）、doors（缺口那條邊上有門：
-- x, y, side, 開著 1／關著也不算牆 0／關著、紀錄過期 2／關著也不算牆的原版車庫門鏈 3 四個一組）、pillars（西邊的缺口那格
-- 有牆又有柱子：x, y, 自動補的牆角 1／其他柱子 0 三個一組）、
-- holes（缺屋頂：x, y 兩個一組）、gapCount（缺牆加上有門、有柱子的缺口）／doorCount／pillarCount／holeCount（全部的
-- 數量；各清單最多 MAX_MARKS 筆）
local function newRoom(x, y, z)
    return { x = x, y = y, z = z, size = 0, roofs = 0, walls = 0, gaps = {}, gapCount = 0, doors = {}, doorCount = 0,
        pillars = {}, pillarCount = 0, holes = {}, holeCount = 0 }
end

-- 這格照現在的物件該有的 region 位元，照 IsoRegions.calculateSquareFlags（IsoRegions.java:322-349；它是 protected，
-- Lua 叫不到）：地板 16、北牆 1（北邊有窗或門框的牆 +4）、西牆 2（+8），整格有 WallSE（柱子）不算西牆，樓梯 32
function I.regionFlags(sq)
    local f = sq:has(IsoFlagType.solidfloor) and FLOOR or 0
    if sq:has(IsoFlagType.cutN) or sq:has(IsoObjectType.doorFrN) then
        f = f + ((sq:has(IsoFlagType.WindowN) or sq:has(IsoFlagType.windowN) or sq:has(IsoFlagType.DoorWallN)) and 5 or 1)
    end
    if not sq:has(IsoFlagType.WallSE) and (sq:has(IsoFlagType.cutW) or sq:has(IsoObjectType.doorFrW)) then
        f = f + ((sq:has(IsoFlagType.WindowW) or sq:has(IsoFlagType.windowW) or sq:has(IsoFlagType.DoorWallW)) and 10 or 2)
    end
    if sq:HasStairsNorth() or sq:HasStairsWest() then f = f + STAIR end
    return f
end

local function addHole(r, ctx, x, y)
    at(ctx.holes, r.z)[key(x, y)] = true
    r.holeCount = r.holeCount + 1
    if r.holeCount > I.MAX_MARKS then return end
    local h = r.holes
    h[#h + 1] = x
    h[#h + 1] = y
end

-- 缺口那條邊上的門（引擎照缺口算的門：原版綠、白車庫門開著時沒有牆的屬性，Knox Pass 的模型門關著也沒有；一般的門
-- 裝在門框裡，門框本身就算牆，不會走到這裡）。回那扇門，沒有門回 nil
local function doorOn(cell, x, y, z, side)
    local sq = cell:getGridSquare(x, y, z)
    if sq == nil then return nil end
    local objs = sq:getSpecialObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if (instanceof(o, "IsoDoor") or (instanceof(o, "IsoThumpable") and o:isDoor())) and o:getNorth() == (side == 1) then
            return o
        end
    end
    return nil
end

-- 這格有真的西牆（牆、門框、窗框；getWall 不算有 WallSE 的物件）又有柱子（WallSE）：回 "corner"＝柱子都是蓋牆時自動補的
-- 牆角（buildUtil.addCorner 的 isCorner，存檔會留，IsoThumpable.java:450, 639），"pillar"＝有玩家自己蓋的或其他的柱子；
-- 不是這種格子回 nil
local function pillarOn(cell, x, y, z)
    local sq = cell:getGridSquare(x, y, z)
    if sq == nil or not sq:has(IsoFlagType.WallSE) or sq:getWall(false) == nil then return nil end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if o:isWallSE() and not (instanceof(o, "IsoThumpable") and o:isCorner()) then return "pillar" end
    end
    return "corner"
end

-- 缺口上關著的門片那格照現在的物件該算牆（regionFlags 有那一邊的位元；side 的值就是那一邊牆的位元，1 北、2 西），
-- 引擎記的卻是缺口（走得過去才會走到這裡）＝紀錄過期，記進 ctx.fix 由 I.query 請引擎重算。沒有那一邊的位元＝這種門
-- 關著也不算牆（Knox Pass 閘門、兩層樓的門），不修。引擎沒資料的格子不碰；每次查詢最多比對 MAX_MARKS 扇
local function stale(ctx, x, y, z, side)
    if ctx.doorChecks >= I.MAX_MARKS or flags(x, y, z) < 0 then return false end
    ctx.doorChecks = ctx.doorChecks + 1
    local sq = ctx.cell:getGridSquare(x, y, z)
    if sq == nil or not has(I.regionFlags(sq), side) then return false end
    local seen, k = at(ctx.fixSeen, z), key(x, y)
    if not seen[k] then   -- 同一格北、西兩邊都是門時只重算一次
        seen[k] = true
        local f, n = ctx.fix, #ctx.fix
        f[n + 1], f[n + 2], f[n + 3] = x, y, z
    end
    return true
end

-- 門的狀態（doors 的第四欄）：開著 1；關著時紀錄過期 2；關著也不算牆時，原版車庫門鏈（IsoDoor.getGarageDoorIndex，
-- IsoDoor.java:3212-3239；Knox Pass 4 版的「算室內」只支援這種，Gates.lua G.indoorSupport）3，其他（柵欄門等）0
local function addGap(r, ctx, x, y, d)
    r.gapCount = r.gapCount + 1
    local ex, ey, side = edgeOf(x, y, d)
    local door = doorOn(ctx.cell, ex, ey, r.z, side)
    if door ~= nil then
        r.doorCount = r.doorCount + 1
        if r.doorCount > I.MAX_MARKS then return end
        local g, n = r.doors, #r.doors
        g[n + 1], g[n + 2], g[n + 3], g[n + 4] = ex, ey, side, door:IsOpen() and 1
            or stale(ctx, ex, ey, r.z, side) and 2 or IsoDoor.getGarageDoorIndex(door) ~= -1 and 3 or 0
        return
    end
    local pillar = side == 2 and pillarOn(ctx.cell, ex, ey, r.z) or nil
    if pillar ~= nil then
        r.pillarCount = r.pillarCount + 1
        if pillar == "corner" then
            local c, n = ctx.corners, #ctx.corners
            c[n + 1], c[n + 2], c[n + 3] = ex, ey, r.z
        end
        if r.pillarCount > I.MAX_MARKS then return end
        local g, n = r.pillars, #r.pillars
        g[n + 1], g[n + 2], g[n + 3] = ex, ey, pillar == "corner" and 1 or 0
        return
    end
    if r.gapCount - r.doorCount - r.pillarCount > I.MAX_MARKS then return end
    local g, n = r.gaps, #r.gaps
    g[n + 1], g[n + 2], g[n + 3] = ex, ey, side
end

-- 封閉而且屋頂至少一半：整個 region 走一遍。格數與屋頂數照引擎（走到上限時清單只有一部分；判定不受影響）
local function closedRoom(r, wr, z, ctx)
    local seen, q, qi = { [key(r.x, r.y)] = true }, { r.x, r.y }, 1
    while qi <= #q and ctx.left > 0 do
        local x, y = q[qi], q[qi + 1]
        qi = qi + 2
        ctx.left = ctx.left - 1
        visit(ctx, x, y, z)
        if not ctx.roofed(x, y, z) then addHole(r, ctx, x, y) end
        for d = 0, 3 do
            if canMove(x, y, z, d) then
                local nx, ny = x + DX[d], y + DY[d]
                local k = key(nx, ny)
                if not seen[k] then
                    seen[k] = true
                    q[#q + 1] = nx
                    q[#q + 1] = ny
                end
            end
        end
    end
    if qi <= #q then ctx.partial = true end
    r.size, r.roofs = wr:getSquareSize(), wr:getRoofCnt()
    if r.roofs >= r.size then
        r.verdict = "ROOM"
        r.holes, r.holeCount = {}, 0   -- 判定以引擎為準
    else
        r.verdict = "NEED_ROOF"
    end
end

-- 起點沒有屋頂時：NEAR 步內（不穿牆）最近的有屋頂格子，沒有回 nil
local function roofedNear(x0, y0, z, ctx)
    if ctx.roofed(x0, y0, z) then return x0, y0 end
    local seen, q, qi = { [key(x0, y0)] = true }, { x0, y0 }, 1
    while qi <= #q do
        local x, y = q[qi], q[qi + 1]
        qi = qi + 2
        if ctx.roofed(x, y, z) then return x, y end
        for d = 0, 3 do
            local nx, ny = x + DX[d], y + DY[d]
            local k = key(nx, ny)
            if not seen[k] and math.abs(nx - x0) + math.abs(ny - y0) <= I.NEAR and canMove(x, y, z, d)
                and flags(nx, ny, z) >= 0 then
                seen[k] = true
                q[#q + 1] = nx
                q[#q + 1] = ny
            end
        end
    end
    return nil
end

-- 不封閉（或屋頂不到一半）：見檔頭「找原因」。inside[鍵] 是 true（有屋頂）或 false（缺屋頂），list 是房子的格子
local function openRoom(r, z, ctx)
    local sx, sy = roofedNear(r.x, r.y, z, ctx)
    if sx == nil then
        r.verdict = "OUTSIDE"
        return
    end
    r.x, r.y = sx, sy
    local inside, list = {}, {}
    local rowMin, rowMax, colMin, colMax = {}, {}, {}, {}
    local function add(x, y, roof)
        inside[key(x, y)] = roof
        list[#list + 1] = x
        list[#list + 1] = y
        r.size = r.size + 1
        ctx.left = ctx.left - 1
        visit(ctx, x, y, z)
        if not roof then
            addHole(r, ctx, x, y)
            return
        end
        r.roofs = r.roofs + 1
        if rowMin[y] == nil or x < rowMin[y] then rowMin[y] = x end
        if rowMax[y] == nil or x > rowMax[y] then rowMax[y] = x end
        if colMin[x] == nil or y < colMin[x] then colMin[x] = y end
        if colMax[x] == nil or y > colMax[x] then colMax[x] = y end
    end
    local function between(x, y)
        return (rowMin[y] ~= nil and rowMin[y] < x and x < rowMax[y]) or (colMin[x] ~= nil and colMin[x] < y and y < colMax[x])
    end
    add(sx, sy, true)
    -- 有屋頂的格子一路走；碰到的沒屋頂格子先記著，夾在房子中間的才收進來（收進來後從它再往外走）
    local cand, candList, qi = {}, {}, 1
    while true do
        while qi <= #list and ctx.left > 0 do
            local x, y = list[qi], list[qi + 1]
            qi = qi + 2
            for d = 0, 3 do
                if canMove(x, y, z, d) then
                    local nx, ny = x + DX[d], y + DY[d]
                    local k = key(nx, ny)
                    if inside[k] == nil and flags(nx, ny, z) >= 0 then
                        if ctx.roofed(nx, ny, z) then
                            add(nx, ny, true)
                        elseif not cand[k] then
                            cand[k] = true
                            candList[#candList + 1] = nx
                            candList[#candList + 1] = ny
                        end
                    end
                end
            end
        end
        local added = false
        for i = 1, #candList, 2 do
            local cx, cy = candList[i], candList[i + 1]
            if inside[key(cx, cy)] == nil and between(cx, cy) then
                add(cx, cy, false)
                added = true
            end
        end
        if not added or ctx.left <= 0 then break end
    end
    if ctx.left <= 0 then ctx.partial = true end
    -- 房子外框裡、外面走不進來的沒屋頂格子（例如缺屋頂的角落）：外框外一圈不穿牆走得到的都是外面
    local x0, y0, x1, y1 = sx, sy, sx, sy
    for i = 1, #list, 2 do
        local x, y = list[i], list[i + 1]
        if x < x0 then x0 = x end
        if x > x1 then x1 = x end
        if y < y0 then y0 = y end
        if y > y1 then y1 = y end
    end
    if (x1 - x0 + 3) * (y1 - y0 + 3) <= I.BOX_MAX then
        local out, oq, oi = {}, {}, 1
        for x = x0 - 1, x1 + 1 do
            for y = y0 - 1, y1 + 1 do
                if (x == x0 - 1 or x == x1 + 1 or y == y0 - 1 or y == y1 + 1) and inside[key(x, y)] == nil then
                    out[key(x, y)] = true
                    oq[#oq + 1] = x
                    oq[#oq + 1] = y
                end
            end
        end
        while oi <= #oq do
            local x, y = oq[oi], oq[oi + 1]
            oi = oi + 2
            for d = 0, 3 do
                local nx, ny = x + DX[d], y + DY[d]
                local k = key(nx, ny)
                if nx >= x0 and nx <= x1 and ny >= y0 and ny <= y1 and not out[k] and inside[k] == nil
                    and canMove(x, y, z, d) then
                    out[k] = true
                    oq[#oq + 1] = nx
                    oq[#oq + 1] = ny
                end
            end
        end
        local pi = 1
        while pi <= #list and ctx.left > 0 do
            local x, y = list[pi], list[pi + 1]
            pi = pi + 2
            for d = 0, 3 do
                local nx, ny = x + DX[d], y + DY[d]
                local k = key(nx, ny)
                if inside[k] == nil and not out[k] and nx >= x0 and nx <= x1 and ny >= y0 and ny <= y1
                    and canMove(x, y, z, d) and flags(nx, ny, z) >= 0 then
                    add(nx, ny, false)
                end
            end
        end
    end
    -- 從房子往外的邊：走得過去＝缺牆，有牆就數一條（客戶端分辨屋簷下）
    for i = 1, #list, 2 do
        local x, y = list[i], list[i + 1]
        for d = 0, 3 do
            if inside[key(x + DX[d], y + DY[d])] == nil then
                if canMove(x, y, z, d) then addGap(r, ctx, x, y, d) else r.walls = r.walls + 1 end
            end
        end
    end
    r.verdict = "OPEN"
end

local function analyze(wr, x, y, z, ctx)
    local r = newRoom(x, y, z)
    if not wr:isEnclosed() then
        openRoom(r, z, ctx)
    elseif wr:getRoofCnt() * 2 >= wr:getSquareSize() then
        closedRoom(r, wr, z, ctx)
    else
        openRoom(r, z, ctx)
        if r.verdict == "OPEN" then r.verdict = "PART_ROOF" end
    end
    return r
end

-- 同一棟在 z 這一層的房間：從 seeds（x, y 兩個一組）沿著有屋頂的格子（和找到的缺屋頂格子）往外找，不看牆、不進地圖
-- 房間；新的 region 各分析一次。走過的格子記進這一層的範圍
local function level(res, z, seeds, ctx)
    local seenRegion, holes = at(ctx.regions, z), at(ctx.holes, z)
    local seen, q, qi = {}, {}, 1
    for i = 1, #seeds, 2 do
        local k = key(seeds[i], seeds[i + 1])
        if not seen[k] then
            seen[k] = true
            q[#q + 1] = seeds[i]
            q[#q + 1] = seeds[i + 1]
        end
    end
    while qi <= #q and ctx.left > 0 do
        local x, y = q[qi], q[qi + 1]
        qi = qi + 2
        ctx.left = ctx.left - 1
        visit(ctx, x, y, z)
        local wr = IsoRegions.getIsoWorldRegion(x, y, z)
        if wr ~= nil and not seenRegion[wr:getID()] then
            seenRegion[wr:getID()] = true
            if #res.rooms < I.MAX_ROOMS then
                res.rooms[#res.rooms + 1] = analyze(wr, x, y, z, ctx)
            else
                ctx.partial = true
            end
        end
        for d = 0, 3 do
            local nx, ny = x + DX[d], y + DY[d]
            local k = key(nx, ny)
            if not seen[k] and flags(nx, ny, z) >= 0 and (ctx.roofed(nx, ny, z) or holes[k])
                and not mapRoom(ctx.cell, nx, ny, z) then
                seen[k] = true
                q[#q + 1] = nx
                q[#q + 1] = ny
            end
        end
    end
    if qi <= #q then ctx.partial = true end
end

-- z 這一層的起點：相鄰那一層（from）走過的格子裡，z 這一層有資料、頭上有屋頂、不是地圖房間的
local function seedsFrom(ctx, from, z)
    local list, seeds = ctx.footList[from] or {}, {}
    for i = 1, #list, 2 do
        local x, y = list[i], list[i + 1]
        if flags(x, y, z) >= 0 and ctx.roofed(x, y, z) and not mapRoom(ctx.cell, x, y, z) then
            seeds[#seeds + 1] = x
            seeds[#seeds + 1] = y
        end
    end
    return seeds
end

-- 從起點那一層往上一層一層找，再往下（地下不進 IsoRegions，到 0 為止）；哪一層找不到起點就不再往那個方向
local function floors(res, z0, ctx)
    for dir = 1, -1, -2 do
        local from, z = z0, z0 + dir
        while z >= 0 and z <= 31 and ctx.left > 0 do
            local seeds = seedsFrom(ctx, from, z)
            if #seeds == 0 then break end
            level(res, z, seeds, ctx)
            from, z = z, z + dir
        end
    end
end

-- 一層走過的格子壓成同一列連續的一段（x, y, 寬 三個一組，由北到南、由西到東），最多 MAX_RUNS 段；第二個回傳值＝有截掉
local function runsOf(list)
    local rows, ys = {}, {}
    for i = 1, #list, 2 do
        local x, y = list[i], list[i + 1]
        local row = rows[y]
        if row == nil then
            row = {}
            rows[y] = row
            ys[#ys + 1] = y
        end
        row[#row + 1] = x
    end
    local function less(a, b) return a < b end
    MSH.sortSafe(ys, less)
    local out, n = {}, 0
    for _, y in ipairs(ys) do
        local xs = MSH.sortSafe(rows[y], less)
        local i = 1
        while i <= #xs do
            local j = i
            while j < #xs and xs[j + 1] == xs[j] + 1 do j = j + 1 end
            if n >= I.MAX_RUNS then return out, true end
            out[3 * n + 1], out[3 * n + 2], out[3 * n + 3] = xs[i], y, xs[j] - xs[i] + 1
            n = n + 1
            i = j + 1
        end
    end
    return out, false
end

-- 查一格：{ verdict, x, y, z, rooms, levels, minX, minY, minZ, maxX, maxY, maxZ, partial }。rooms[1] 是那一格所在的
-- 房間，之後是同一層、樓上、樓下的其他房間（MAP_ROOM、BASEMENT、OUTSIDE 沒有 rooms）；levels＝各層走過的範圍
-- { z, runs }（由低到高）；partial＝走到上限，有房間或缺口沒列到。地圖的地下室有 RoomDef（Basements），先看地圖房間；
-- 其他地下（z < 0）不進 IsoRegions（IsoRegionWorker 只收 z >= 0），遊戲永遠不算室內。查詢只讀不改，要改的另外回
-- （x, y, z 三個一組，不在回覆裡，I.query 處理）：第二個回傳值＝要拆自動牆角的格子，第三個＝紀錄過期、要請引擎重算的門片格子
function I.check(x, y, z)
    local res = { x = x, y = y, z = z, rooms = {}, levels = {} }
    local ctx = newCtx(x, y, z)
    if mapRoom(ctx.cell, x, y, z) then
        res.verdict = "MAP_ROOM"
    elseif z < 0 then
        res.verdict = "BASEMENT"
    else
        local wr = flags(x, y, z) >= 0 and IsoRegions.getIsoWorldRegion(x, y, z) or nil
        local r = wr and analyze(wr, x, y, z, ctx) or nil
        res.verdict = r and r.verdict or "OUTSIDE"
        if r ~= nil and r.verdict ~= "OUTSIDE" then
            res.rooms[1] = r
            at(ctx.regions, z)[wr:getID()] = true
            level(res, z, { r.x, r.y }, ctx)
            floors(res, z, ctx)
        end
    end
    for lz = ctx.minZ, ctx.maxZ do
        local list = ctx.footList[lz]
        if list ~= nil then
            local runs, cut = runsOf(list)
            if cut then ctx.partial = true end
            res.levels[#res.levels + 1] = { z = lz, runs = runs }
        end
    end
    res.minX, res.minY, res.minZ = ctx.minX, ctx.minY, ctx.minZ
    res.maxX, res.maxY, res.maxZ, res.partial = ctx.maxX, ctx.maxY, ctx.maxZ, ctx.partial
    return res, ctx.corners, ctx.fix
end

function I.query(ctx)
    local a, p = ctx.args, ctx.player
    if a.z < -32 or a.z > 31 then return MSH.Srv.fail(CODE.BAD_ARGS) end
    local reach = MSH.LIMIT.INDOOR_REACH
    if math.abs(a.x - math.floor(p:getX())) > reach or math.abs(a.y - math.floor(p:getY())) > reach then
        return MSH.Srv.fail(CODE.TOO_FAR)
    end
    local t0 = getTimestampMs()
    local res, corners, fix = I.check(a.x, a.y, a.z)
    for i = 1, #corners, 3 do I.queueCorner(corners[i], corners[i + 1], corners[i + 2]) end
    if #fix > 0 then res.fixed = I.recalc(fix, a.x, a.y, a.z) end   -- 回覆照查的當下，客戶端過了冷卻再查
    local ms = getTimestampMs() - t0
    if ms >= I.SLOW_MS then
        MSH.log("indoor check " .. a.x .. "," .. a.y .. "," .. a.z .. " took " .. ms .. " ms, rooms=" .. #res.rooms)
    end
    return MSH.Srv.ok(res)
end

MSH.Srv.define("indoor", { kind = "query", cooldownMs = 1000, fields = { x = "int", y = "int", z = "int" },
    run = function(ctx) return MSH.Indoor.query(ctx) end })

-- 請引擎照格子現在的物件重算這幾格（x, y, z 三個一組）的牆紀錄，照 Knox Pass Gates.syncRegions：squareChanged 只在算出的
-- 位元和共用的 previousFlags 不同時才排工作（IsoRegions.java:309-320），先 setPreviousFlags(nil) 把它歸 0（要重算的是
-- 關著的門片，有牆位元，不會是 0）。引擎在背景執行緒重算那個 chunk、存檔、送給每位在線玩家一份（IsoRegionWorker.java:
-- 215-262、314-338，同玩家蓋一面牆），所以只修對不上的格子。回排了幾格；記一行 log（查詢的那格）
function I.recalc(list, x, y, z)
    local cell, n = getCell(), 0
    for i = 1, #list, 3 do
        IsoRegions.setPreviousFlags(nil)
        IsoRegions.squareChanged(cell:getGridSquare(list[i], list[i + 1], list[i + 2]))
        n = n + 1
    end
    MSH.log("indoor: recalculated " .. n .. " door tile(s) near " .. x .. "," .. y .. "," .. z)
    return n
end

-- ===== 自動牆角 =====

-- 那格有真的西牆時，拆掉蓋牆時遊戲自動補的牆角（isCorner 而且是 WallSE 的 IsoThumpable）；玩家自己蓋的柱子不動。
-- transmitRemoveItemFromSquare 走原版拆物件的路（RemoveTileObject：先記改前的位元、改完重算，西牆的位元回來）。回拆了幾個
function I.dropCorners(sq)
    if sq == nil or not sq:has(IsoFlagType.WallSE) or sq:getWall(false) == nil then return 0 end
    local objs, n = sq:getObjects(), 0
    for i = objs:size() - 1, 0, -1 do
        local o = objs:get(i)
        if instanceof(o, "IsoThumpable") and o:isCorner() and o:isWallSE() then
            sq:transmitRemoveItemFromSquare(o)
            n = n + 1
        end
    end
    if n > 0 then
        MSH.log("indoor: removed " .. n .. " automatic corner(s) at " .. sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ())
    end
    return n
end

I.pending = I.pending or {}   -- 下一個 tick 要看的格子：x, y, z 三個一組

function I.queueCorner(x, y, z)
    local p = I.pending
    p[#p + 1], p[#p + 2], p[#p + 3] = x, y, z
end

function I.tick()
    local p = I.pending
    if #p == 0 then return end
    I.pending = {}
    local cell = getCell()
    for i = 1, #p, 3 do I.dropCorners(cell:getGridSquare(p[i], p[i + 1], p[i + 2])) end
end

-- 原版蓋牆、門框、窗框、圍籬的建造（ISBuildIsoEntity:create 等）放好物件後都呼叫 buildUtil.checkCorner：包它，把那一格排進
-- 佇列。開服才裝（原版 server 檔一定載完）；熱重載不重包（I.installed 隨 MSH.Indoor 保留）
function I.install()
    if I.installed then return end
    I.installed = true
    if type(buildUtil) ~= "table" or type(buildUtil.checkCorner) ~= "function" then
        MSH.log("indoor: buildUtil.checkCorner missing, not wrapped")
        return
    end
    local orig = buildUtil.checkCorner
    buildUtil.checkCorner = function(x, y, z, north, thumpable, item)
        orig(x, y, z, north, thumpable, item)
        MSH.Indoor.queueCorner(x, y, z)
    end
end

MSH.Srv.hook("startup", "indoorCorners", function() MSH.Indoor.install() end)
MSH.Srv.hook("tick", "indoorCorners", function() MSH.Indoor.tick() end)
