-- 多塊範圍的形狀規則（Contract：MSH.Rect.shapeError）與框選工具的形狀（client Shape.lua、Select.lua 的加入／挖掉）。
-- 使用者 2026-10-11 裁定：一間最多 4 塊矩形、塊與塊共用邊、不能圍出洞；同樣塊數時挑被移出的人落點在範圍外的切法。
return function(T)
    local check = T.check
    local function r(x, y, w, h) return { x = x, y = y, w = w, h = h } end

    T.section("形狀規則：塊數、重疊、相連、洞")
    local MSH = T.bootClient()
    local Rect = MSH.Rect
    check(Rect.shapeError({ r(0, 0, 5, 5) }) == nil, "一塊：合規則")
    check(Rect.shapeError({ r(0, 0, 2, 6), r(2, 4, 4, 2) }) == nil, "L 形（共用一段邊）：合規則")
    check(Rect.shapeError({ r(0, 0, 2, 2), r(2, 2, 2, 2) }) == "SPLIT", "只碰到角：不算相連")
    check(Rect.shapeError({ r(0, 0, 2, 2), r(5, 0, 2, 2) }) == "SPLIT", "分開兩塊：不算相連")
    check(Rect.shapeError({ r(0, 0, 4, 4), r(3, 3, 4, 4) }) == "OVERLAP", "塊與塊重疊")
    check(Rect.shapeError({ r(0, 0, 1, 1), r(1, 0, 1, 1), r(2, 0, 1, 1), r(3, 0, 1, 1), r(4, 0, 1, 1) }) == "PIECES",
        "5 塊：超過上限")
    check(Rect.shapeError({}) == "PIECES" and Rect.shapeError({ r(-1, 0, 2, 2) }) == "PIECES", "0 塊、負座標的塊")
    check(Rect.shapeError({ r(0, 0, 6, 2), r(0, 2, 2, 2), r(4, 2, 2, 2), r(0, 4, 6, 2) }) == "HOLE", "回字形：中間有洞")
    check(Rect.shapeError({ r(0, 0, 2, 6), r(4, 0, 2, 6), r(2, 4, 2, 2) }) == nil, "U 形（開口朝外）：沒有洞")
    -- 右上角只靠一個角相接：外面從那個角斜著才連得進來，上下左右走不進去，照樣算洞（圍得住人）
    check(Rect.shapeError({ r(0, 0, 3, 1), r(0, 1, 1, 2), r(0, 3, 4, 1), r(3, 1, 1, 2) }) == "HOLE",
        "四塊圍住、只在一角斜著留縫：算洞")
    check(Rect.touches(r(0, 0, 2, 2), r(2, 1, 2, 2)) and not Rect.touches(r(0, 0, 2, 2), r(2, 2, 2, 2)),
        "共用一段邊才算相鄰，只碰到角不算")
    check(Rect.listArea({ r(0, 0, 2, 6), r(2, 4, 4, 2) }) == 20 and Rect.bounds({ r(0, 0, 2, 6), r(2, 4, 4, 2) }).w == 6,
        "面積是各塊總和，外框包住全部")

    T.section("框選形狀：加入、挖掉、切塊")
    local Shape = MSH.Shape
    -- 切好的塊剛好鋪滿形狀：互不重疊、總面積等於形狀面積，而且每塊的格子都在形狀裡
    local function tiles(res, inShape)
        local area = 0
        for _, p in ipairs(res.rects or {}) do
            area = area + p.w * p.h
            for x = p.x, p.x + p.w - 1 do
                for y = p.y, p.y + p.h - 1 do
                    if not inShape(x, y) then return false end
                end
            end
        end
        return area == res.area and Rect.shapeError(res.rects) == nil
    end
    local function landingOutside(res)
        for _, p in ipairs(res.rects) do
            if Rect.listContains(res.rects, p.x - 1, p.y - 1) then return false end
        end
        return true
    end

    local sh = Shape.new()
    Shape.apply(sh, r(10, 20, 8, 6), true)
    local res = Shape.result(sh)
    check(res.err == nil and #res.rects == 1 and res.area == 48 and res.x == 10 and res.w == 8 and res.h == 6,
        "拉一塊：一塊、面積、外框")

    sh = Shape.new()
    Shape.apply(sh, r(0, 0, 10, 10), true)
    Shape.apply(sh, r(5, 0, 5, 5), false)
    res = Shape.result(sh)
    check(res.err == nil and #res.rects == 2 and res.area == 75
        and tiles(res, function(x, y) return not (x >= 5 and y < 5) end), "挖掉右上角：兩塊剛好鋪滿 L 形")

    -- 先拉直條、再拉底下的橫條（兩塊有重疊）：合成 L；切法要讓每塊的落點 (x−1, y−1) 都在範圍外
    sh = Shape.new()
    Shape.apply(sh, r(0, 0, 2, 6), true)
    Shape.apply(sh, r(0, 4, 6, 2), true)
    res = Shape.result(sh)
    check(res.err == nil and #res.rects == 2 and res.area == 20 and landingOutside(res),
        "拉兩塊合成 L：兩塊，被移出的人不會落進另一塊")

    sh = Shape.new()
    Shape.apply(sh, r(0, 0, 6, 6), true)
    Shape.apply(sh, r(2, 2, 2, 4), false)
    res = Shape.result(sh)
    check(res.err == nil and #res.rects == 3 and landingOutside(res), "開口朝下的 U：三塊，落點都在外面")

    sh = Shape.new()
    Shape.apply(sh, r(2, 0, 2, 6), true)
    Shape.apply(sh, r(0, 2, 6, 2), true)
    res = Shape.result(sh)
    check(res.err == nil and #res.rects == 3 and tiles(res, function(x, y)
        return (x >= 2 and x < 4) or (y >= 2 and y < 4)
    end), "十字：最少三塊")

    sh = Shape.new()
    for k = 0, 3 do Shape.apply(sh, r(0, k, k + 1, 1), true) end
    res = Shape.result(sh)
    check(res.err == nil and #res.rects == 4, "四階樓梯：剛好四塊")
    Shape.apply(sh, r(0, 4, 5, 1), true)
    check(Shape.result(sh).err == "COMPLEX" and Shape.result(sh).rects == nil, "五階樓梯：要五塊，太複雜")

    sh = Shape.new()
    Shape.apply(sh, r(0, 0, 20, 20), true)
    Shape.apply(sh, r(8, 0, 2, 3), false)
    Shape.apply(sh, r(0, 8, 3, 2), false)
    Shape.apply(sh, r(19, 12, 1, 2), false)
    check(Shape.result(sh).err == "COMPLEX", "三邊中間各挖一個缺口：太複雜")

    sh = Shape.new()
    Shape.apply(sh, r(0, 0, 10, 10), true)
    Shape.apply(sh, r(4, 0, 2, 10), false)
    res = Shape.result(sh)
    check(res.err == "SPLIT" and res.area == 80 and #res.draw == 8, "從中間挖斷：分成兩片，照樣畫出兩片")

    sh = Shape.new()
    Shape.apply(sh, r(0, 0, 9, 9), true)
    Shape.apply(sh, r(3, 3, 3, 3), false)
    check(Shape.result(sh).err == "HOLE", "中間挖洞：不合規則")

    T.section("框選形狀：復原、清除、從現有範圍開始")
    sh = Shape.new()
    Shape.apply(sh, r(0, 0, 10, 10), true)
    Shape.apply(sh, r(0, 0, 3, 3), false)
    check(Shape.result(sh).area == 91, "挖掉一角")
    check(Shape.undo(sh) and Shape.result(sh).area == 100 and #Shape.result(sh).rects == 1, "復原：回到挖之前")
    check(Shape.clear(sh) and Shape.isEmpty(sh) and Shape.result(sh).err == "EMPTY", "清除：範圍空了")
    check(Shape.undo(sh) and Shape.result(sh).area == 100, "清除也能復原")
    check(Shape.undo(sh) and Shape.isEmpty(sh) and not Shape.undo(sh), "復原到最前面就停")
    sh = Shape.new()
    Shape.load(sh, { r(0, 0, 2, 6), r(2, 4, 4, 2) })
    res = Shape.result(sh)
    check(res.err == nil and res.area == 20 and #res.rects == 2 and not Shape.canUndo(sh),
        "重新框選從現有的各塊開始，載入不算一步")

    T.section("框選工具：挖掉模式與拉到一半的那塊")
    local Sel = MSH.Select
    local s = Sel.new(Sel.WALK, 0)
    Sel.setCut(s, true)
    check(not s.cut, "範圍是空的：不能切到挖掉")
    local p = { getX = function() return 3 end, getY = function() return 4 end, getZ = function() return 0 end }
    Sel.mark(s, p)
    s.bx, s.by = 7, 9
    check(Sel.commit(s) and Sel.result(s).area == 30 and s.ax == nil, "走位：〔加入這塊〕把兩角之間加進範圍")
    Sel.setCut(s, true)
    Sel.mark(s, p)
    s.bx, s.by = 4, 5
    check(Sel.commit(s) and Sel.result(s).area == 26, "挖掉模式：同樣的動作改成挖掉")
    Sel.mark(s, p)
    check(Sel.undo(s) and s.ax == nil and Sel.result(s).area == 26, "〔復原〕先取消拉到一半的那塊，範圍不變")
    check(Sel.undo(s) and Sel.result(s).area == 30, "再按一次才退回上一步")
    check(Sel.clear(s) and Sel.isEmpty(s) and not s.cut, "〔清除〕：範圍空了、模式回到加入")

    T.section("框選形狀：一直點散開的格子，格子不會無限長大")
    sh = Shape.new()
    local applied = 0
    for k = 0, 39 do
        if Shape.apply(sh, r(k * 2, k * 2, 1, 1), true) then applied = applied + 1 end
    end
    local lines = #sh.xs
    local area = Shape.result(sh).area
    check(applied < 40 and lines <= Shape.LINES and Shape.result(sh).err == "SPLIT",
        "分界線到上限之後不再套用（套了 " .. applied .. " 次、" .. lines .. " 條線）")
    check(not Shape.apply(sh, r(500, 500, 1, 1), true) and Shape.result(sh).area == area, "被擋下的那一步不改範圍")
    check(Shape.undo(sh) and Shape.result(sh).area == area - 1, "（對照）復原照常")

    T.section("管理視窗：在世界中顯示畫整個形狀的外緣")
    local MW = MSH.ManagerWindow
    -- 逐格算出的外緣（範圍內、上下左右有一格在範圍外），和 MW.outline 畫的格子一格一格比
    local function sameOutline(rects)
        local areas, drawn = MW.outline(rects), {}
        for k = 1, #areas, 4 do
            for x = areas[k], areas[k] + areas[k + 2] - 1 do
                for y = areas[k + 1], areas[k + 1] + areas[k + 3] - 1 do
                    local key = x .. "," .. y
                    if drawn[key] then return false end   -- 同一格畫兩次（疊色）
                    drawn[key] = true
                end
            end
        end
        local b = Rect.bounds(rects)
        for x = b.x - 1, b.x + b.w do
            for y = b.y - 1, b.y + b.h do
                local inside = Rect.listContains(rects, x, y)
                local edge = inside and not (Rect.listContains(rects, x - 1, y) and Rect.listContains(rects, x + 1, y)
                    and Rect.listContains(rects, x, y - 1) and Rect.listContains(rects, x, y + 1))
                if edge ~= (drawn[x .. "," .. y] == true) then return false end
            end
        end
        return true
    end
    check(sameOutline({ r(0, 0, 4, 12), r(4, 8, 8, 4) }), "L 形：剛好畫外緣，交界不畫、沒有疊色")
    check(sameOutline({ r(0, 0, 2, 6), r(4, 0, 2, 6), r(2, 4, 2, 2) }), "U 形：凹進去的邊也畫")
    check(sameOutline({ r(2, 0, 2, 6), r(0, 2, 2, 2), r(4, 2, 2, 2) }), "十字")
    check(sameOutline({ r(0, 0, 1, 5) }) and sameOutline({ r(0, 0, 2, 2) }), "一格寬、2×2 的方形")
    local big = MW.outline({ r(1000, 1000, 2000, 2000) })
    check(#big == 16 and big[3] == 2000 and big[4] == 1, "接管來的 2000×2000 大屋：只算四條邊，不逐格掃")
end
