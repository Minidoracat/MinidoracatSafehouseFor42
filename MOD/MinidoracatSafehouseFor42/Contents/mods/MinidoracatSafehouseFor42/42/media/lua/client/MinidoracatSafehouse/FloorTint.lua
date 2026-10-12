-- MinidoracatSafehouse/FloorTint.lua：把地面標示畫在人物下層——地板染色（地面顯示範圍、建立面板的框選與標紅）。
-- 原版畫地面框的兩種方法都會蓋住站在上面的人物：addAreaHighlightForPlayer 與 WorldMarkers 都在世界畫完後才畫、深度刻意
--   往前推一點（FBORenderAreaHighlights.java:251-259、FBORenderWorldMarkers.java:224-233；2026-10-12 使用者截圖）。
--   地板染色（IsoObject:setHighlightColor＋setHighlighted(0, true, false)）由 FBORenderObjectHighlight 在人物之後、照
--   地板自己的深度重畫那一格（FBORenderCell.java:1128-1137；地板用 FloorShaper 的 tint，IsoObject.java:3686-3700），
--   人物照樣在上面（floortint-sp 實機）。tint 是把地板的光照色往顏色拉 a 的比例（Color.tintABGR，Color.java:243-253）。
-- 一格地板只能有一種顏色：各圖層（Ranges、建立面板的各塊／拉到一半那塊／標紅）各自交出自己的格子，同一格取
--   F.ORDER 裡最前面的圖層，只在那一格要顯示的顏色變了才呼叫引擎。所以框選蓋過地面範圍、關掉框選後底下的顏色回來，
--   兩邊不會互相取消。染色是常駐的（renderOnce＝false），不必每幀重設；每 SCAN_MS 對一次所有交出的格子（F.tick）：
--   區塊重新載入換了地板物件、被別的程式取消染色、之前沒載入的現在載入了，就重設。丟掉舊地板不必先取消：已經不在格子上的
--   物件，引擎畫的時候自己移出染色集合（FBORenderObjectHighlight.java:120-122）。
-- 成本：引擎每幀把每一塊染色的地板連同那格上面的物件重畫一次，畫面外的照樣算，草叢多的地方更貴。sh-tintperf2-1012a
--   （上限 244 FPS，createtint-mp 那塊草地）：64×64 全染 161 FPS，只染畫面看得到的 529 格 243、外加 6 格的 1,225 格 240。
--   所以只染畫面看得到的格子外加 MARGIN 格（F.window）：鏡頭移出這個範圍才重切，拉出再大的框也只染畫面上的那一塊。
-- 格子的鍵是 x、y、z 合成的整數（不配置）；z 在 -64..63、x、y 在 0..99999。

if not isClient() then return end

local MSH = MinidoracatSafehouse
local first = MSH.FloorTint == nil
local F = MSH.FloorTint or {}
MSH.FloorTint = F

F.ORDER = { "marks", "pending", "shape", "ranges" }   -- 前面的蓋過後面的
F.MARGIN = 4
F.SCAN_MS = 500
F.cells = F.cells or {}       -- 圖層 → { [鍵] = 顏色 }
F.floor = F.floor or {}       -- 鍵 → 染著的地板物件
F.shown = F.shown or {}       -- 鍵 → 那塊地板目前染的顏色
F.last = F.last or {}         -- 圖層 → setRects／setRect 上次的參數（一樣就不動）
F.win = F.win or { seq = 0 }  -- 染色範圍 x0, y0, x1, y1（含）、z；換了 seq 加一
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

-- 讓這一格的地板顯示最上層的顏色（沒有就取消）。不知道地板物件時才讀格子（IsoCell:getGridSquare 沒載入回 nil，
-- IsoCell.java:3190-3192；IsoGridSquare:getFloor IsoGridSquare.java:4652）
local function show(cell, k)
    local want = top(k)
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

-- 對一格：地板換了物件（區塊重新載入）、被取消染色（isHighlighted IsoObject.java:5041-5043）、之前沒載入的現在載入了，
-- 就重設；沒載入的忘掉舊地板
local function recheck(cell, k)
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

-- 每個 UI 幀（OnPreUIDraw）只比時間；每 SCAN_MS 對一次各層交出的每一格
function F.tick()
    local now = getTimestampMs()
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

-- 螢幕上一點換成格座標，併進外框（screenToIsoX/Y LuaManager.java:3795,3806；同 Select.pick）
local function corner(sx, sy, z, x0, y0, x1, y1)
    local x, y = screenToIsoX(0, sx, sy, z), screenToIsoY(0, sx, sy, z)
    if x < x0 then x0 = x end
    if x > x1 then x1 = x end
    if y < y0 then y0 = y end
    if y > y1 then y1 = y end
    return x0, y0, x1, y1
end

-- 染色範圍：玩家 0 的畫面四個角換成格座標的外框，外加 MARGIN 格。畫面看得到的格子還在上次的範圍裡就不換（鏡頭每移
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
end
