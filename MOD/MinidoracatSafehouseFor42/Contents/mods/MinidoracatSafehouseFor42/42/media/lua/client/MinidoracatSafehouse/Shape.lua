-- MinidoracatSafehouse/Shape.lua：框選工具的範圍形狀（使用者 2026-10-11 裁定一間可以多塊）。純函式，不碰畫面與玩家。
-- 玩家拉矩形「加入」或「挖掉」，形狀是這些操作疊出來的格子集合；送給伺服器前切成最少塊數的矩形（≤ sh.max，沙盒 MaxPieces），
--   每塊是一個原生 SafeHouse。
-- 表示法：縮減過的座標格——xs、ys 是遞增的分界線，inside[j][i]＝[xs[i], xs[i+1]) × [ys[j], ys[j+1]) 在範圍內。
--   每次操作後去掉外圍的空行列、去掉兩邊格子都一樣的分界線，剩下的線都通過形狀的頂點，格子數只隨轉角數成長，
--   和範圍多大無關。操作前的狀態留在 history（新操作建新表，舊表不改，所以直接存參照）。
-- 切塊：max 塊拼得出的形狀，頂點最多 2×max 種 x、y 座標；縮減後超過就直接判定太複雜。
--   否則在縮減格上逐步加深搜尋最少塊數（第一個沒蓋到的格子一定是下一塊的左上角），同樣塊數挑
--   「被移出的人落點在範圍內」的塊最少的切法：原生把人傳到該塊的 (x−1, y−1)（SafeHouse.java:538、840），
--   落在同一間另一塊就要等下一次越界檢查才出得去。
-- 連成一片在這裡判（切塊前）；洞照 MSH.Rect.shapeError，和伺服器同一套規則。

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Settings"

local MSH = MinidoracatSafehouse
local Shape = MSH.Shape or {}
MSH.Shape = Shape

Shape.HISTORY = 32      -- 可以復原幾步
-- 每個塊數的搜尋節點上限：超過就用目前最好的切法（形狀太怪時寧可多一塊，不卡住畫面）。逐一加深到 max 塊，
-- 所以最壞的搜尋量隨沙盒 MaxPieces 成長：調高後形狀複雜時，改動形狀的那一下可能短暫卡頓（選項提示有寫）
Shape.NODES = 20000
Shape.DRAW_MAX = 256    -- 切不出塊時逐列畫原始格子，最多畫幾段
-- 編輯中每軸最多幾條分界線：8 塊（硬上限）拼得出的形狀最多 16 條，超過的早就是「太複雜」；這個上限只防止玩家一直點散開的格子
-- 讓格子（與每一步的 history）無限長大、每次套用越來越慢（2026-10-11 審查）。超過就不套用這一步
Shape.LINES = 40

-- max：這次編輯最多切成幾塊；不傳時取開始編輯當下的沙盒 MaxPieces（伺服器確認時再照當時的值檢查一次）
function Shape.new(max)
    return { xs = {}, ys = {}, inside = {}, history = {}, max = max or MSH.Settings.get().maxPieces }
end

function Shape.isEmpty(sh)
    return #sh.xs == 0
end

function Shape.canUndo(sh)
    return #sh.history > 0
end

-- 兩條遞增數列合併去重
local function merge(a, b)
    local out, i, j = {}, 1, 1
    while i <= #a or j <= #b do
        local v
        if j > #b or (i <= #a and a[i] < b[j]) then
            v, i = a[i], i + 1
        elseif i > #a or b[j] < a[i] then
            v, j = b[j], j + 1
        else
            v, i, j = a[i], i + 1, j + 1
        end
        out[#out + 1] = v
    end
    return out
end

-- 新分界線的每一段落在舊格子的第幾段（兩邊都遞增，單調往前走）；在舊範圍外是 0
local function locate(old, new)
    local out, k = {}, 1
    for i = 1, #new - 1 do
        local v = new[i]
        if #old == 0 or v < old[1] or v >= old[#old] then
            out[i] = 0
        else
            while old[k + 1] <= v do k = k + 1 end
            out[i] = k
        end
    end
    return out
end

local function colsEqual(inside, ny, a, b)
    for j = 1, ny do
        if inside[j][a] ~= inside[j][b] then return false end
    end
    return true
end

local function rowsEqual(inside, nx, a, b)
    local ra, rb = inside[a], inside[b]
    for i = 1, nx do
        if ra[i] ~= rb[i] then return false end
    end
    return true
end

-- 去掉外圍的空行列與多餘的分界線；全空回空形狀
local function reduce(xs, ys, inside)
    local nx, ny = #xs - 1, #ys - 1
    local i0, i1, j0, j1 = nil, nil, nil, nil
    for j = 1, ny do
        for i = 1, nx do
            if inside[j][i] then
                if i0 == nil or i < i0 then i0 = i end
                if i1 == nil or i > i1 then i1 = i end
                if j0 == nil then j0 = j end
                j1 = j
            end
        end
    end
    if i0 == nil then return {}, {}, {} end
    -- 留下的欄：每段相同的欄只留第一欄當代表，分界線只留換段的地方
    local keepCol, keepX = { i0 }, { xs[i0] }
    for i = i0 + 1, i1 do
        if not colsEqual(inside, ny, keepCol[#keepCol], i) then
            keepCol[#keepCol + 1] = i
            keepX[#keepX + 1] = xs[i]
        end
    end
    keepX[#keepX + 1] = xs[i1 + 1]
    local keepRow, keepY = { j0 }, { ys[j0] }
    for j = j0 + 1, j1 do
        if not rowsEqual(inside, nx, keepRow[#keepRow], j) then
            keepRow[#keepRow + 1] = j
            keepY[#keepY + 1] = ys[j]
        end
    end
    keepY[#keepY + 1] = ys[j1 + 1]
    local out = {}
    for j, rj in ipairs(keepRow) do
        local row, src = {}, inside[rj]
        for i, ci in ipairs(keepCol) do row[i] = src[ci] == true end
        out[j] = row
    end
    return keepX, keepY, out
end

local function remember(sh)
    local h = sh.history
    h[#h + 1] = { xs = sh.xs, ys = sh.ys, inside = sh.inside }
    if #h > Shape.HISTORY then table.remove(h, 1) end
end

-- 加入（add＝true）或挖掉一塊矩形 r＝{ x, y, w, h }；分界線超過 Shape.LINES 就不套用、回 false
function Shape.apply(sh, r, add)
    local xs, ys = merge(sh.xs, { r.x, r.x + r.w }), merge(sh.ys, { r.y, r.y + r.h })
    if #xs > Shape.LINES or #ys > Shape.LINES then return false end
    remember(sh)
    local col, row0 = locate(sh.xs, xs), locate(sh.ys, ys)
    local old = sh.inside
    local inside = {}
    for j = 1, #ys - 1 do
        local row, y, oj = {}, ys[j], row0[j]
        for i = 1, #xs - 1 do
            local x = xs[i]
            if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
                row[i] = add == true
            else
                row[i] = oj > 0 and col[i] > 0 and old[oj][col[i]] == true
            end
        end
        inside[j] = row
    end
    sh.xs, sh.ys, sh.inside = reduce(xs, ys, inside)
    sh.result = nil
    return true
end

-- 重新框選既有的安全屋：從它的每一塊開始（不進 history）
function Shape.load(sh, rects)
    for _, r in ipairs(rects or {}) do Shape.apply(sh, r, true) end
    sh.history = {}
end

function Shape.undo(sh)
    local h = table.remove(sh.history)
    if h == nil then return false end
    sh.xs, sh.ys, sh.inside, sh.result = h.xs, h.ys, h.inside, nil
    return true
end

function Shape.clear(sh)
    if Shape.isEmpty(sh) then return false end
    remember(sh)
    sh.xs, sh.ys, sh.inside, sh.result = {}, {}, {}, nil
    return true
end

-- 範圍內的格子在縮減格上連成一片（上下左右）
local function connected(sh, total)
    local inside, nx, ny = sh.inside, #sh.xs - 1, #sh.ys - 1
    local start = nil
    for j = 1, ny do
        for i = 1, nx do
            if start == nil and inside[j][i] then start = (j - 1) * nx + i end
        end
    end
    local seen, stack, count = { [start] = true }, { start }, 1
    local DX, DY = { 1, -1, 0, 0 }, { 0, 0, 1, -1 }
    while #stack > 0 do
        local k = table.remove(stack)
        local i, j = (k - 1) % nx + 1, math.floor((k - 1) / nx) + 1
        for d = 1, 4 do
            local ni, nj = i + DX[d], j + DY[d]
            if ni >= 1 and ni <= nx and nj >= 1 and nj <= ny and inside[nj][ni] then
                local nk = (nj - 1) * nx + ni
                if not seen[nk] then
                    seen[nk] = true
                    count = count + 1
                    stack[#stack + 1] = nk
                end
            end
        end
    end
    return count == total
end

-- 最少塊數的切法（縮減格上的 { i0, j0, i1, j1 }，含頭含尾）；sh.max 塊切不出來回 nil
local function partition(sh)
    local inside, nx, ny = sh.inside, #sh.xs - 1, #sh.ys - 1
    local covered = {}
    for j = 1, ny do covered[j] = {} end
    local stack, best, bestScore, nodes = {}, nil, nil, 0

    local function free(i, j) return inside[j][i] and not covered[j][i] end

    local function mark(p, v)
        for j = p.j0, p.j1 do
            for i = p.i0, p.i1 do covered[j][i] = v end
        end
    end

    -- 被移出的人落點 (x−1, y−1) 在範圍內的塊數
    local function score()
        local s = 0
        for _, p in ipairs(stack) do
            if p.i0 > 1 and p.j0 > 1 and inside[p.j0 - 1][p.i0 - 1] then s = s + 1 end
        end
        return s
    end

    -- 回 true＝停止搜尋（找到落點全在外面的切法，或節點用完）
    local function dfs(k, fromJ)
        nodes = nodes + 1
        if nodes > Shape.NODES then return true end
        local i0, j0 = nil, nil
        for j = fromJ, ny do
            for i = 1, nx do
                if free(i, j) then
                    i0, j0 = i, j
                    break
                end
            end
            if i0 ~= nil then break end
        end
        if i0 == nil then
            local s = score()
            if best == nil or s < bestScore then
                best, bestScore = {}, s
                for n, p in ipairs(stack) do best[n] = p end
            end
            return bestScore == 0
        end
        if #stack >= k then return false end
        local maxW = 0
        while i0 + maxW <= nx and free(i0 + maxW, j0) do maxW = maxW + 1 end
        for w = maxW, 1, -1 do
            local h = 0
            while j0 + h <= ny do
                local ok = true
                for i = i0, i0 + w - 1 do
                    if not free(i, j0 + h) then
                        ok = false
                        break
                    end
                end
                if not ok then break end
                h = h + 1
            end
            for hh = h, 1, -1 do
                local p = { i0 = i0, j0 = j0, i1 = i0 + w - 1, j1 = j0 + hh - 1 }
                mark(p, true)
                stack[#stack + 1] = p
                local stop = dfs(k, j0)
                table.remove(stack)
                mark(p, nil)
                if stop then return true end
            end
        end
        return false
    end

    for k = 1, sh.max do
        nodes = 0
        dfs(k, 1)
        if best ~= nil then return best end
    end
    return nil
end

-- 形狀的結果（快取到下一次改動）：
--   { err = nil | "EMPTY" | "SPLIT" | "COMPLEX" | "HOLE", rects（切好的各塊；SPLIT／COMPLEX 時 nil）,
--     x, y, w, h（外框）, area, draw（扁平 x, y, w, h, ... 每幀畫的段：有切塊就是各塊，否則逐列的原始格子）}
function Shape.result(sh)
    if sh.result ~= nil then return sh.result end
    local res
    if Shape.isEmpty(sh) then
        res = { err = "EMPTY", draw = {} }
    else
        local xs, ys, inside = sh.xs, sh.ys, sh.inside
        local nx, ny = #xs - 1, #ys - 1
        local area, cells = 0, 0
        for j = 1, ny do
            for i = 1, nx do
                if inside[j][i] then
                    area = area + (xs[i + 1] - xs[i]) * (ys[j + 1] - ys[j])
                    cells = cells + 1
                end
            end
        end
        res = { x = xs[1], y = ys[1], w = xs[#xs] - xs[1], h = ys[#ys] - ys[1], area = area, draw = {} }
        local limit = sh.max * 2
        if not connected(sh, cells) then
            res.err = "SPLIT"
        elseif #xs > limit or #ys > limit then
            res.err = "COMPLEX"
        else
            local parts = partition(sh)
            if parts == nil then
                res.err = "COMPLEX"
            else
                res.rects = {}
                for n, p in ipairs(parts) do
                    res.rects[n] = { x = xs[p.i0], y = ys[p.j0], w = xs[p.i1 + 1] - xs[p.i0], h = ys[p.j1 + 1] - ys[p.j0] }
                end
                res.err = MSH.Rect.shapeError(res.rects, sh.max)   -- 只剩 HOLE 會發生
            end
        end
        local d = res.draw
        local function add(x, y, w, h)
            local n = #d
            d[n + 1], d[n + 2], d[n + 3], d[n + 4] = x, y, w, h
        end
        if res.rects ~= nil then
            for _, r in ipairs(res.rects) do add(r.x, r.y, r.w, r.h) end
        else
            for j = 1, ny do
                local i = 1
                while i <= nx and #d < Shape.DRAW_MAX * 4 do
                    if inside[j][i] then
                        local e = i
                        while e < nx and inside[j][e + 1] do e = e + 1 end
                        add(xs[i], ys[j], xs[e + 1] - xs[i], ys[j + 1] - ys[j])
                        i = e + 1
                    else
                        i = i + 1
                    end
                end
            end
        end
    end
    sh.result = res
    return res
end
