-- MinidoracatSafehouse/Indoor.lua：室內檢查（使用者 2026-10-15：「判斷自己蓋的房子有沒有算室內，以及方便找出沒成為室內
-- 的原因」）。查詢 indoor { x, y, z }：那一格所在的房間、同一個屋頂下的其他房間算不算室內，不算的話缺哪幾條牆、哪幾格
-- 屋頂。客戶端面板（client/…/IndoorPanel.lua）只顯示與標示。設計與使用者裁定見 decisions.md（2026-10-15）。
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
-- 同一個屋頂下：從起點沿著有屋頂的格子往外找（不看牆、不進地圖房間），每碰到一個新的 region 就照上面分析一次。
-- 效能（使用者 2026-10-15：「只有需要查的時候才查，平常不用一直掃」）：只在客戶端送查詢時算（面板開著才會送），
-- 同一人 1 秒冷卻、只查 LIMIT.INDOOR_REACH 格內，一次最多走 I.LIMIT 格。實測（sh-indoor-1015h）：4x4 的房子平均 0.3 ms，
-- 16x16（256 格）平均 3 ms、最慢 5 ms。

if isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Server"

local MSH = MinidoracatSafehouse
local I = MSH.Indoor or {}
MSH.Indoor = I

local CODE = MSH.CODE

I.LIMIT = 4096        -- 一次查詢最多走幾格（房子加上各房間）
I.NEAR = 4            -- 站的那格沒有屋頂時，往外找有屋頂的格子最多幾步
I.MAX_ROOMS = 12      -- 同一個屋頂下最多分析幾間
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

-- 查詢共用的狀態：剩幾格可走、走過的外框（客戶端照它判斷附近的物件變動要不要重查）、這層的屋頂快取、找到的缺屋頂格子
-- （找同一個屋頂下的房間時可以穿過）
local function grow(ctx, x, y)
    if x < ctx.minX then ctx.minX = x end
    if x > ctx.maxX then ctx.maxX = x end
    if y < ctx.minY then ctx.minY = y end
    if y > ctx.maxY then ctx.maxY = y end
end

local function newCtx(x, y, z)
    local cache = {}
    local ctx = { left = I.LIMIT, cell = getCell(), minX = x, minY = y, maxX = x, maxY = y, partial = false, holes = {} }
    function ctx.roofed(rx, ry)
        local k = key(rx, ry)
        local v = cache[k]
        if v == nil then
            v = roofed(rx, ry, z)
            cache[k] = v
        end
        return v
    end
    return ctx
end

-- 一間的結果：verdict、size（格數）、roofs（有屋頂的格數）、walls（房子邊上有牆的邊數）、x, y（分析的起點；起點沒有
-- 屋頂時是 NEAR 步內最近的有屋頂格子）、gaps（缺牆：x, y, side 三個一組）、holes（缺屋頂：x, y 兩個一組）、
-- gapCount／holeCount（全部的數量；清單最多 MAX_MARKS 筆）
local function newRoom(x, y)
    return { x = x, y = y, size = 0, roofs = 0, walls = 0, gaps = {}, gapCount = 0, holes = {}, holeCount = 0 }
end

local function addHole(r, ctx, x, y)
    ctx.holes[key(x, y)] = true
    r.holeCount = r.holeCount + 1
    if r.holeCount > I.MAX_MARKS then return end
    local h = r.holes
    h[#h + 1] = x
    h[#h + 1] = y
end

local function addGap(r, x, y, d)
    r.gapCount = r.gapCount + 1
    if r.gapCount > I.MAX_MARKS then return end
    local ex, ey, side = edgeOf(x, y, d)
    local g = r.gaps
    g[#g + 1] = ex
    g[#g + 1] = ey
    g[#g + 1] = side
end

-- 封閉而且屋頂至少一半：整個 region 走一遍。格數與屋頂數照引擎（走到上限時清單只有一部分；判定不受影響）
local function closedRoom(r, wr, z, ctx)
    local seen, q, qi = { [key(r.x, r.y)] = true }, { r.x, r.y }, 1
    while qi <= #q and ctx.left > 0 do
        local x, y = q[qi], q[qi + 1]
        qi = qi + 2
        ctx.left = ctx.left - 1
        grow(ctx, x, y)
        if not ctx.roofed(x, y) then addHole(r, ctx, x, y) end
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
    if ctx.roofed(x0, y0) then return x0, y0 end
    local seen, q, qi = { [key(x0, y0)] = true }, { x0, y0 }, 1
    while qi <= #q do
        local x, y = q[qi], q[qi + 1]
        qi = qi + 2
        if ctx.roofed(x, y) then return x, y end
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
        grow(ctx, x, y)
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
                        if ctx.roofed(nx, ny) then
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
                if canMove(x, y, z, d) then addGap(r, x, y, d) else r.walls = r.walls + 1 end
            end
        end
    end
    r.verdict = "OPEN"
end

local function analyze(wr, x, y, z, ctx)
    local r = newRoom(x, y)
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

-- 同一個屋頂下的其他房間：從 (sx, sy) 沿著有屋頂的格子往外找（不看牆、不進地圖房間），新的 region 各分析一次
local function others(res, z, sx, sy, startId, ctx)
    local seenRegion = { [startId] = true }
    local seen, q, qi = { [key(sx, sy)] = true }, { sx, sy }, 1
    while qi <= #q and ctx.left > 0 do
        local x, y = q[qi], q[qi + 1]
        qi = qi + 2
        ctx.left = ctx.left - 1
        grow(ctx, x, y)
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
            if not seen[k] and flags(nx, ny, z) >= 0 and (ctx.roofed(nx, ny) or ctx.holes[k])
                and not mapRoom(ctx.cell, nx, ny, z) then
                seen[k] = true
                q[#q + 1] = nx
                q[#q + 1] = ny
            end
        end
    end
    if qi <= #q then ctx.partial = true end
end

-- 查一格：{ verdict, x, y, z, rooms, minX, minY, maxX, maxY, partial }。rooms[1] 是那一格所在的房間（MAP_ROOM、
-- BASEMENT、OUTSIDE 沒有 rooms）；partial＝走到上限，有房間或缺口沒列到。地圖的地下室有 RoomDef（Basements），先看
-- 地圖房間；其他地下（z < 0）不進 IsoRegions（IsoRegionWorker 只收 z >= 0），遊戲永遠不算室內
function I.check(x, y, z)
    local res = { x = x, y = y, z = z, rooms = {} }
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
            others(res, z, r.x, r.y, wr:getID(), ctx)
        end
    end
    res.minX, res.minY, res.maxX, res.maxY, res.partial = ctx.minX, ctx.minY, ctx.maxX, ctx.maxY, ctx.partial
    return res
end

function I.query(ctx)
    local a, p = ctx.args, ctx.player
    if a.z < -32 or a.z > 31 then return MSH.Srv.fail(CODE.BAD_ARGS) end
    local reach = MSH.LIMIT.INDOOR_REACH
    if math.abs(a.x - math.floor(p:getX())) > reach or math.abs(a.y - math.floor(p:getY())) > reach then
        return MSH.Srv.fail(CODE.TOO_FAR)
    end
    local t0 = getTimestampMs()
    local res = I.check(a.x, a.y, a.z)
    local ms = getTimestampMs() - t0
    if ms >= I.SLOW_MS then
        MSH.log("indoor check " .. a.x .. "," .. a.y .. "," .. a.z .. " took " .. ms .. " ms, rooms=" .. #res.rooms)
    end
    return MSH.Srv.ok(res)
end

MSH.Srv.define("indoor", { kind = "query", cooldownMs = 1000, fields = { x = "int", y = "int", z = "int" },
    run = function(ctx) return MSH.Indoor.query(ctx) end })
