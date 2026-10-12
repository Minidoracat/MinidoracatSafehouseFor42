-- MinidoracatSafehouse/FloorTint.lua：地面標示（地面顯示範圍、建立面板的框選與標紅）。兩種畫法：
-- 1. 地板染色（IsoObject:setHighlightColor＋setHighlighted(0, true, false)）：FBORenderObjectHighlight 在人物之後、照地板
--    自己的深度重畫那一格（FBORenderCell.java:1128-1137；地板用 FloorShaper 的 tint，IsoObject.java:3686-3700），站在上面
--    的人物、前面的房子照樣擋得住它（floortint-sp、sh-ranges-1012c 實機）。tint 把地板的光照色往顏色拉 a（Color.tintABGR，
--    Color.java:243-253），最後乘上地板貼圖：草地幾乎沒有藍，藍、洋紅在草地上出不來（sh-tintbright-1012b）。
-- 2. 疊色（顏色帶 ov 的：地面顯示範圍）：在 RenderOpaqueObjectsInWorld（FBORenderCell.java:1126，原版建造游標
--    ISBuildingObject.lua:694-698 的畫法）用 IsoSprite:RenderGhostTileColor 疊一張白色菱形貼圖（IsoSprite.java:519-556），
--    顏色照 alpha 混進地面，任何地面上都是同一個色相（sh-overlay-1012a：四類彼此、和標紅的色差都 ≥ 38）。但它關掉深度
--    測試（IsoSprite.java:853-862），玩家又在 :1107 先畫好：站在上面的人物、前面房子的牆與屋簷都會被蓋住
--    （sh-overlay-1013b、-1013c；把玩家重畫一次也蓋不回來）。所以在屋裡、前方的房子在畫面上擋得到（OCC_*）、人物身體
--    在畫面上蓋得到（BODY_*）的格子改用同一個顏色的地板染色（使用者 2026-10-13 選定）。
-- 一格只能有一種顏色：各圖層（Ranges、建立面板的各塊／拉到一半那塊／標紅）各自交出自己的格子，同一格取 F.ORDER 裡最前面的
--   圖層，只在那一格要顯示的東西變了才呼叫引擎。所以框選蓋過地面範圍、關掉框選後底下的顏色回來，兩邊不會互相取消。
-- 染色是常駐的（renderOnce＝false），不必每幀重設；每 SCAN_MS 對一次染色的格子（F.tick）：區塊重新載入換了地板物件、被別的
--   程式取消染色、之前沒載入的現在載入了，就重設。疊色每幀照 F.list 畫，格子變了才重排（不配置）。
-- 成本（上限 244 FPS）：染色由引擎每幀把每一塊染色的地板連同上面的物件重畫，草叢多的地方更貴（sh-tintperf2-1012a：64×64
--   全染 161、畫面看得到的 529 格 243、1,225 格 240）；疊色每格一張貼圖（sh-rangesov-1013d：1,225 格 243.4、最低 238）。
--   被擋住的判斷每格只在第一次讀格子（F.occ；1,225 格全新的一次 14 ms）。兩種都只畫畫面看得到的格子外加 MARGIN 格
--   （F.window），鏡頭移出這個範圍才重切。
-- 格子的鍵是 x、y、z 合成的整數（不配置）；z 在 -64..63、x、y 在 0..99999。

if not isClient() then return end

local MSH = MinidoracatSafehouse
local first = MSH.FloorTint == nil
local F = MSH.FloorTint or {}
MSH.FloorTint = F

F.ORDER = { "marks", "pending", "shape", "ranges" }   -- 前面的蓋過後面的
F.MARGIN = 4
F.SCAN_MS = 500
-- 被房子擋住：每層樓（牆）在畫面上 OCC_ROWS 列高，屋頂再 OCC_ROOF 列（sh-rangesov-1013c 一層樓：後面第 4 列被屋頂蓋住、
-- 第 6 列沒有）；往前最多看 OCC_DEPTH 列（兩層樓＋屋頂）
F.OCC_ROWS, F.OCC_ROOF, F.OCC_DEPTH = 3, 2, 8
F.NEAR_MS = 200                    -- 多久看一次別的玩家站在哪（本機玩家每幀看）
-- 人物在畫面上蓋住的範圍（2x 貼圖的畫素，菱形 128×64；1x 一樣比例）：腳兩側各 BODY_W、往上 BODY_TOP、往下 BODY_BOTTOM。
-- 菱形和這個矩形有重疊的格子改用染色；站在格子中央時是腳下、身後兩格與兩側共 7 格（sh-rangesov-1013a 用整塊 4×4 太大）
F.BODY_W, F.BODY_TOP, F.BODY_BOTTOM = 30, 136, 10
F.OCC_MAX = 20000                  -- 被擋住的快取上限，滿了整個清掉
-- 白色實心菱形（128×256，2x 貼圖）。B42 沒有 1x 貼圖：getOptionTexture2x 固定回 true（Core.java:3448-3450）。
-- ponytail: 只放 2x；哪天恢復 1x（Core.getTileScale() == 1）要補一張 64×128 的、照它選
F.TEX = "media/textures/MinidoracatSafehouse/FloorFill2x.png"
F.cells = F.cells or {}       -- 圖層 → { [鍵] = 顏色 }
F.floor = F.floor or {}       -- 鍵 → 染著的地板物件
F.shown = F.shown or {}       -- 鍵 → 那塊地板目前染的顏色
F.ov = F.ov or {}             -- 鍵 → 正在疊的顏色（某個顏色的 ov 表）
F.occ = F.occ or {}           -- 鍵 → 是否被房子擋住（沒載入的不記）
F.occN = F.occN or 0
F.near = F.near or {}         -- 鍵 → true：有玩家站在附近
F.list = F.list or {}         -- 疊色：x, y, z, r, g, b, a 每 7 個一格
F.n = F.n or 0
F.pk = F.pk or {}             -- 各玩家：所在格的鍵、蓋到哪幾格（BODY 的位元），兩個一組；[1]、[2] 是本機玩家
F.pn = F.pn or 0
F.last = F.last or {}         -- 圖層 → setRects／setRect 上次的參數（一樣就不動）
F.win = F.win or { seq = 0 }  -- 畫的範圍 x0, y0, x1, y1（含）、z；換了 seq 加一
for _, name in ipairs(F.ORDER) do F.cells[name] = F.cells[name] or {} end

local B = 100000
local function key(x, y, z)
    return ((z + 64) * B + x) * B + y
end
F.key = key

-- math.floor：Kahlua 的數字都是 double，除完照樣是整數值；標準 Lua 5.4（harness）的 / 回浮點，要取整才當得了格子座標
local function unkey(k)
    local y = k % B
    local t = math.floor(k / B)
    local x = t % B
    return x, y, math.floor(t / B) - 64
end

-- 同一個主題顏色的各種強度只建一次：顏色用表的同一性比對，每幀不配置
local colorCache = {}
function F.color(base, a)
    local byA = colorCache[base]
    if byA == nil then
        byA = {}
        colorCache[base] = byA
    end
    local c = byA[a]
    if c == nil then
        c = { r = base.r, g = base.g, b = base.b, a = a }
        byA[a] = c
    end
    return c
end

local function top(k)
    local cells = F.cells
    for i = 1, #F.ORDER do
        local c = cells[F.ORDER[i]][k]
        if c ~= nil then return c end
    end
    return nil
end

-- 這一格是不是房子的一部分：在屋裡或頭上有屋頂、樓板（isOutside 是 false：exterior 只在沒有房間又沒有屋頂時設，
-- IsoGridSquare.java:7306, 9431-9433）。回從這層往上幾層樓（BuildingDef:getMaxLevel，IsoBuilding.java:123、
-- BuildingDef.java:82-90；沒有房間的屋簷下、門廊算一層），不是回 0
local function storeys(cell, x, y, z)
    local sq = cell:getGridSquare(x, y, z)
    if sq == nil or sq:isOutside() then return 0 end
    local b = sq:getBuilding()   -- IsoGridSquare.java:9266-9269
    return b and b:getDef():getMaxLevel() - z + 1 or 1
end

-- 這格不能疊色：是房子的一部分，或畫面上被前方的房子擋住（疊色會畫到牆、屋頂、欄杆上）。前方第 d 列（x、y 都加 d）
-- 是房子，而且 d ≤ 樓層數 × OCC_ROWS＋OCC_ROOF。前 OCC_ROWS 列連左右半格（往畫面下方的三個方向）一起看，再往前只看
-- 正前方。沒有地板的格子（樓上的空中沒有格子，或有格子沒地板）也不能：疊色不看地板，會浮在半空；改走染色那條，沒地板
-- 就什麼都不畫（和改疊色前一樣）。沒有格子的不記：也可能是還沒載入，載入後由 F.tick 補
local function occluded(cell, k)
    local o = F.occ[k]
    if o ~= nil then return o end
    local x, y, z = unkey(k)
    local sq = cell:getGridSquare(x, y, z)
    if sq == nil then return true end
    o = not sq:isOutside() or sq:getFloor() == nil
    local d, rows = 1, F.OCC_ROWS
    while not o and d <= F.OCC_DEPTH do
        local n = storeys(cell, x + d, y + d, z)
        if d <= rows then
            o = n > 0 or storeys(cell, x + d, y + d - 1, z) > 0 or storeys(cell, x + d - 1, y + d, z) > 0
        else
            o = n > 0 and d <= rows * n + F.OCC_ROOF
        end
        d = d + 1
    end
    -- ponytail: 三層樓以上的房子只算到 OCC_DEPTH 列，再後面照樣疊色；要更高就加大 OCC_DEPTH（每格多讀一次格子）
    -- ponytail: 蓋房子、拆房子不會讓快取失效，滿 OCC_MAX 才整個清掉；要即時就在 OnObjectAdded／OnTileRemoved 清掉附近幾格
    if F.occN >= F.OCC_MAX then F.occ, F.occN = {}, 0 end
    F.occ[k], F.occN = o, F.occN + 1
    return o
end

-- 讓這一格顯示最上層的顏色（沒有就取消）：帶 ov、沒被擋、沒有人物蓋著就疊色，否則染地板。不知道地板物件時才讀格子
-- （IsoCell:getGridSquare 沒載入回 nil，IsoCell.java:3190-3192；IsoGridSquare:getFloor IsoGridSquare.java:4652）
local function show(cell, k)
    local want = top(k)
    local ov = want and want.ov
    if ov ~= nil and (F.near[k] or occluded(cell, k)) then ov = nil end
    if F.ov[k] ~= ov then F.ov[k], F.listStale = ov, true end
    if ov ~= nil then want = nil end
    local floor = F.floor[k]
    if want == nil then
        if floor ~= nil then floor:setHighlighted(0, false, false) end
        F.floor[k], F.shown[k] = nil, nil
        return
    end
    if floor == nil then
        local x, y, z = unkey(k)
        local sq = cell:getGridSquare(x, y, z)
        floor = sq and sq:getFloor()
        if floor == nil then return end   -- 沒載入：之後 F.tick 補
        F.floor[k], F.shown[k] = floor, nil
    end
    if F.shown[k] ~= want then
        floor:setHighlightColor(0, want.r, want.g, want.b, want.a)   -- IsoObject.java:5115-5119
        floor:setHighlighted(0, true, false)                          -- :5049-5061
        F.shown[k] = want
    end
end

-- 交出一格（同色就不動；地板換了或被取消染色由 F.tick 補上）
function F.put(cell, name, x, y, z, color)
    local k = key(x, y, z)
    local cells = F.cells[name]
    if cells[k] == color then return end
    cells[k] = color
    show(cell, k)
end

function F.remove(cell, name, x, y, z)
    local k = key(x, y, z)
    if F.cells[name][k] == nil then return end
    F.cells[name][k] = nil
    show(cell, k)
end

-- 整層收掉；底下的圖層有這一格就換回它的顏色。本來就是空的不配置（Ranges 關著時每次掃描都會呼叫）
function F.clear(name)
    local old = F.cells[name]
    F.last[name] = nil
    local cell = nil
    for k in pairs(old) do
        if cell == nil then
            cell = getCell()
            F.cells[name] = {}
        end
        show(cell, k)
    end
end

-- 對一格：疊色的格子之前沒載入、還不知道有沒有被擋的，重新判斷；染色的格子地板換了物件（區塊重新載入）、被取消染色
-- （isHighlighted IsoObject.java:5041-5043）、之前沒載入的現在載入了，就重設；沒載入的忘掉舊地板
local function recheck(cell, k)
    if F.ov[k] ~= nil then
        if F.occ[k] == nil then show(cell, k) end
        return
    end
    local x, y, z = unkey(k)
    local sq = cell:getGridSquare(x, y, z)
    local floor = sq and sq:getFloor()
    if floor == nil then
        F.floor[k], F.shown[k] = nil, nil
    elseif floor ~= F.floor[k] or not floor:isHighlighted(0) then
        F.floor[k], F.shown[k] = floor, nil
        show(cell, k)
    end
end

-- 人物蓋得到的候選格：所在格往 x、y 各 -4..1（往上蓋、往下一點點）；位元 i 對應 BODY_DX[i]、BODY_DY[i]
local BODY_DX, BODY_DY = {}, {}
for dx = -4, 1 do
    for dy = -4, 1 do
        BODY_DX[#BODY_DX + 1], BODY_DY[#BODY_DY + 1] = dx, dy
    end
end

-- 玩家 p 在第 z 層時回：所在格的鍵、人物蓋到哪幾格（位元和）。菱形與矩形重疊＝矩形離菱形中心最近的點在菱形裡
-- （菱形是加權的 L1 球）。只有數字運算，每幀算也不配置
local function standKey(p, z)
    local pz = math.floor(p:getZ())   -- IsoMovingObject.java:525
    if pz ~= z then return nil, 0 end
    local x, y = p:getX(), p:getY()
    local sx, sy = math.floor(x), math.floor(y)
    local fx, fy = x - sx - 0.5, y - sy - 0.5
    local px, py = (fx - fy) * 64, (fx + fy) * 32   -- 人物腳在所在格中心的哪裡（畫面畫素）
    local top, bottom = py - F.BODY_TOP, py + F.BODY_BOTTOM
    local mask, bit = 0, 1
    for i = 1, #BODY_DX do
        local cx, cy = (BODY_DX[i] - BODY_DY[i]) * 64, (BODY_DX[i] + BODY_DY[i]) * 32
        local ddx = math.max(0, math.abs(cx - px) - F.BODY_W)
        local ddy = cy < top and top - cy or (cy > bottom and cy - bottom or 0)
        if ddx / 64 + ddy / 32 < 1 then mask = mask + bit end
        bit = bit * 2
    end
    return key(sx, sy, pz), mask
end

-- 依目前各玩家蓋到的格子重算 F.near，進出的格子重新判斷（有人換了格子或蓋到的格子變了才跑，這時才配置）
function F.renear(cell)
    local old, near, pk = F.near, {}, F.pk
    for j = 1, F.pn, 2 do
        local k, mask = pk[j], pk[j + 1]
        if k ~= nil then
            local x, y, z = unkey(k)
            for i = 1, #BODY_DX do
                if mask % 2 == 1 then near[key(x + BODY_DX[i], y + BODY_DY[i], z)] = true end
                mask = math.floor(mask / 2)
            end
        end
    end
    F.near = near
    for k in pairs(near) do
        if not old[k] then show(cell, k) end
    end
    for k in pairs(old) do
        if not near[k] then show(cell, k) end
    end
end

-- 本機玩家每幀、別的玩家（getOnlinePlayers：客戶端是 GameClient 認得的全部玩家，LuaManager.java:4457-4463）每 NEAR_MS
-- 看一次站在哪、蓋到哪幾格，和上一輪一樣就不動；只看目前畫的那一層
function F.watchPlayers(now)
    local z = F.win.z
    if z == nil then return end
    local pk, changed = F.pk, false
    local me = getSpecificPlayer(0)
    local k, mask = nil, 0
    if me then k, mask = standKey(me, z) end
    if pk[1] ~= k or pk[2] ~= mask then pk[1], pk[2], changed = k, mask, true end
    local n = math.max(F.pn, 2)
    if now >= (F.nextNear or 0) then
        F.nextNear = now + F.NEAR_MS
        local list = getOnlinePlayers()
        n = 2
        for i = 0, (list and list:size() or 0) - 1 do
            local p = list:get(i)
            if p ~= me then
                k, mask = standKey(p, z)
                if k ~= nil then
                    if pk[n + 1] ~= k or pk[n + 2] ~= mask then pk[n + 1], pk[n + 2], changed = k, mask, true end
                    n = n + 2
                end
            end
        end
    end
    if n ~= F.pn then F.pn, changed = n, true end
    if changed then F.renear(getCell()) end
end

-- 每個 UI 幀（OnPreUIDraw）：看玩家站在哪；每 SCAN_MS 對一次各層交出的每一格
function F.tick()
    local now = getTimestampMs()
    F.watchPlayers(now)
    if now < (F.nextScan or 0) then return end
    F.nextScan = now + F.SCAN_MS
    local cell, order = nil, F.ORDER
    for i = 1, #order do
        for k in pairs(F.cells[order[i]]) do
            cell = cell or getCell()
            recheck(cell, k)
        end
    end
end

-- 疊色：照 F.ov 排成平的陣列（格子變了才排，重用同一張表）
local function relist()
    local l, n = F.list, 0
    for k, c in pairs(F.ov) do
        local x, y, z = unkey(k)
        l[n + 1], l[n + 2], l[n + 3], l[n + 4], l[n + 5], l[n + 6], l[n + 7] = x, y, z, c.r, c.g, c.b, c.a
        n = n + 7
    end
    F.n, F.listStale = n, false
end

-- RenderOpaqueObjectsInWorld（每幀、每個玩家畫面一次，FBORenderCell.java:3634-3656）：只畫 0 號玩家的畫面
function F.render(playerIndex)
    if playerIndex ~= 0 then return end
    if F.listStale then relist() end
    local n = F.n
    if n == 0 then return end
    local s = F.sprite
    if s == nil then
        s = IsoSprite.new()   -- 同原版 ISBuildingObject.getFloorCursorSprite（ISBuildingObject.lua:694-698）
        s:LoadSingleTexture(F.TEX)
        F.sprite = s
    end
    local l = F.list
    for i = 1, n, 7 do
        s:RenderGhostTileColor(l[i], l[i + 1], l[i + 2], l[i + 3], l[i + 4], l[i + 5], l[i + 6])   -- IsoSprite.java:515-517
    end
end

-- 螢幕上一點換成格座標，併進外框（screenToIsoX/Y LuaManager.java:3795,3806；同 Select.pick）
local function corner(sx, sy, z, x0, y0, x1, y1)
    local x, y = screenToIsoX(0, sx, sy, z), screenToIsoY(0, sx, sy, z)
    if x < x0 then x0 = x end
    if x > x1 then x1 = x end
    if y < y0 then y0 = y end
    if y > y1 then y1 = y end
    return x0, y0, x1, y1
end

-- 畫的範圍：玩家 0 的畫面四個角換成格座標的外框，外加 MARGIN 格。畫面看得到的格子還在上次的範圍裡就不換（鏡頭每移
-- MARGIN 格左右才換一次），換了 seq 加一，各圖層下次呼叫時照新範圍重切。每幀可以呼叫多次、不配置
function F.window(z)
    local core = getCore()
    local w, h = core:getScreenWidth(), core:getScreenHeight()
    local x, y = screenToIsoX(0, 0, 0, z), screenToIsoY(0, 0, 0, z)
    local x0, y0, x1, y1 = corner(w, 0, z, x, y, x, y)
    x0, y0, x1, y1 = corner(0, h, z, x0, y0, x1, y1)
    x0, y0, x1, y1 = corner(w, h, z, x0, y0, x1, y1)
    x0, y0, x1, y1 = math.floor(x0), math.floor(y0), math.floor(x1), math.floor(y1)
    local v = F.win
    if v.z == z and x0 >= v.x0 and y0 >= v.y0 and x1 <= v.x1 and y1 <= v.y1 then return v end
    local m = F.MARGIN
    v.x0, v.y0, v.x1, v.y1, v.z, v.seq = x0 - m, y0 - m, x1 + m, y1 + m, z, v.seq + 1
    return v
end

-- 一層換成這組矩形（flat：x, y, w, h, …）；第 i 個的顏色＝base 照 alphas 輪流的強度，後面的矩形蓋過前面的。
-- 只染 F.window 裡的格子。和上次同一張 flat、同一個 base、同一張 alphas、範圍沒換就不動；變了只動顏色不同的格子
function F.setRects(name, flat, base, alphas, z)
    local v = F.window(z)
    local l = F.last[name]
    if l ~= nil and l.flat == flat and l.base == base and l.alphas == alphas and l.seq == v.seq then return end
    F.last[name] = { flat = flat, base = base, alphas = alphas, seq = v.seq }
    local old, want = F.cells[name], {}
    for i = 1, #flat, 4 do
        local c = F.color(base, alphas[((i - 1) / 4) % #alphas + 1])
        local x0, y0 = math.max(flat[i], v.x0), math.max(flat[i + 1], v.y0)
        local x1, y1 = math.min(flat[i] + flat[i + 2] - 1, v.x1), math.min(flat[i + 1] + flat[i + 3] - 1, v.y1)
        for x = x0, x1 do
            for y = y0, y1 do want[key(x, y, z)] = c end
        end
    end
    F.cells[name] = want
    local cell = getCell()
    for k, c in pairs(want) do
        if old[k] ~= c then show(cell, k) end
    end
    for k in pairs(old) do
        if want[k] == nil then show(cell, k) end
    end
end

-- 一層只有一個矩形（拉到一半那塊、游標格；x 為 nil＝沒有），只染 F.window 裡的格子：只動新舊範圍不重疊的格子，
-- 拖曳中每換一格不配置
function F.setRect(name, x, y, w, h, z, color)
    local x0, y0, x1, y1
    if x ~= nil then
        local v = F.window(z)
        x0, y0 = math.max(x, v.x0), math.max(y, v.y0)
        x1, y1 = math.min(x + w - 1, v.x1), math.min(y + h - 1, v.y1)
        if x0 > x1 or y0 > y1 then x0, y0, x1, y1 = nil, nil, nil, nil end
    end
    local r = F.last[name]
    if r == nil then
        r = {}
        F.last[name] = r
    end
    if r.x0 == x0 and r.y0 == y0 and r.x1 == x1 and r.y1 == y1 and r.z == z and r.color == color then return end
    local cells, cell = F.cells[name], getCell()
    if r.x0 ~= nil then
        local keep = x0 ~= nil and r.z == z and r.color == color
        for xx = r.x0, r.x1 do
            for yy = r.y0, r.y1 do
                if not keep or xx < x0 or xx > x1 or yy < y0 or yy > y1 then
                    local k = key(xx, yy, r.z)
                    cells[k] = nil
                    show(cell, k)
                end
            end
        end
    end
    if x0 ~= nil then
        for xx = x0, x1 do
            for yy = y0, y1 do
                local k = key(xx, yy, z)
                if cells[k] ~= color then
                    cells[k] = color
                    show(cell, k)
                end
            end
        end
    end
    r.x0, r.y0, r.x1, r.y1, r.z, r.color = x0, y0, x1, y1, z, color
end

if first then
    Events.OnPreUIDraw.Add(function() MSH.FloorTint.tick() end)
    Events.RenderOpaqueObjectsInWorld.Add(function(playerIndex) MSH.FloorTint.render(playerIndex) end)   -- LuaEventManager.java:650
end
