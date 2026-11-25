-- 道路／資源點排除（計畫 §8、§12.1 第 19–20 項、§12.4 成本）：地板分類、掃描範圍與成本、自家車道放寬、
-- MiniMap 停車場與資源點查詢（假的 MinidoracatMiniMapResourceAPI 在開機後才指定）。
return function(T)
    local check = T.check

    T.section("Exclusions：地板圖塊分類")
    local MSH = T.boot()
    local E = MSH.Exclusions
    local C = MSH.CODE
    local function all(lo, hi, want)
        for i = lo, hi do
            if E.classify("blends_street_01_" .. i) ~= want then return false end
        end
        return true
    end
    check(all(80, 87, "main"), "blends_street_01_80–87＝main")
    check(all(96, 103, "street"), "blends_street_01_96–103＝street")
    check(all(32, 39, "gravel") and all(48, 55, "gravel"), "blends_street_01_32–39、48–55＝gravel")
    check(all(16, 21, "sidewalk"), "blends_street_01_16–21＝sidewalk")
    check(E.classify("floors_exterior_tilesandstone_01_3") == "sidewalk"
        and E.classify("floors_exterior_tilesandstone_01_0") == "sidewalk"
        and E.classify("floors_exterior_tilesandstone_01_47") == "sidewalk", "floors_exterior_tilesandstone_01_*＝sidewalk")
    check(all(64, 71, nil), "blends_street_01_64–71（籃球場）不算路")
    check(all(0, 7, nil), "blends_street_01_0–7（破損補丁）不算路")
    check(all(8, 15, nil) and all(22, 31, nil) and all(40, 47, nil) and all(56, 63, nil) and all(72, 79, nil)
        and all(88, 95, nil) and all(104, 127, nil), "blends_street_01 其他編號不算路")
    check(E.classify("floors_exterior_street_01_0") == nil and E.classify("floors_exterior_street_01_16") == nil,
        "floors_exterior_street*（車庫、棚子地坪）不算路")
    check(E.classify("carpentry_02_57") == nil and E.classify("blends_natural_01_0") == nil
        and E.classify("blends_street_01_80x") == nil and E.classify(nil) == nil, "其他名稱、nil 不算路")

    T.section("Exclusions：道路掃描、類別、安全邊界、未載入")
    local cfg = MSH.Settings.get()
    local rect = { x = 100, y = 100, w = 10, h = 10 }
    local function roads()
        T.squareReads = 0
        return E.roads({ rect }, cfg)
    end
    local function sameAreas(a, want)
        if type(a) ~= "table" or #a ~= #want then return false end
        for i = 1, #want do
            if a[i] ~= want[i] then return false end
        end
        return true
    end
    local code, d = roads()
    check(code == nil and T.squareReads == 144, "乾淨範圍：邊界 1 擴張後每格恰讀一次（12×12＝144，實際 "
        .. T.squareReads .. "）")
    cfg.avoidRoads = false
    T.floor(105, 105, "blends_street_01_80")
    code = roads()
    check(code == nil and T.squareReads == 0, "AvoidRoads 關：不掃、不擋")
    cfg.avoidRoads = true
    code, d = roads()
    check(code == C.ROAD and d.x == 105 and d.y == 105 and d.kind == "main", "範圍內主要道路→ROAD｛x, y, kind｝")
    T.floor(105, 105, "blends_street_01_32")
    check(roads() == nil, "預設 main;street：碎石地不擋")
    cfg.roadKinds.gravel = true
    code, d = roads()
    check(code == C.ROAD and d.kind == "gravel", "勾 gravel 後碎石地擋")
    cfg.roadKinds.gravel = nil
    T.floor(105, 105, "floors_exterior_tilesandstone_01_3")
    check(roads() == nil, "預設不擋人行道")
    cfg.roadKinds.sidewalk = true
    code, d = roads()
    check(code == C.ROAD and d.kind == "sidewalk", "勾 sidewalk 後人行道擋")
    cfg.roadKinds.sidewalk = nil
    T.floor(105, 105, "blends_street_01_64")
    check(roads() == nil, "籃球場圖塊不擋")
    T.floor(105, 105, nil)

    T.floor(99, 105, "blends_street_01_96")
    code, d = roads()
    check(code == C.ROAD and d.x == 99 and d.kind == "street", "邊界 1：範圍外一格的街道擋")
    cfg.roadMargin = 0
    code = roads()
    check(code == nil and T.squareReads == 100, "邊界 0：同一格不擋、只讀範圍本身 100 格")
    cfg.roadMargin = 1
    T.floor(99, 105, nil)

    -- 違規格全部回給客戶端標紅：同一列連續的併成一段，和上一列同起點、同寬的往下延伸
    T.floor(101, 99, "blends_street_01_80")
    T.floor(108, 108, "blends_street_01_80")
    code, d = roads()
    check(code == C.ROAD and d.x == 101 and d.y == 99 and sameAreas(d.areas, { 101, 99, 1, 1, 108, 108, 1, 1 }),
        "回第一格，areas 列出每一塊道路格")
    T.floor(101, 99, nil)
    T.floor(108, 108, nil)
    for y = 99, 110 do
        T.floor(102, y, "blends_street_01_96")
        T.floor(103, y, "blends_street_01_96")
    end
    code, d = roads()
    check(code == C.ROAD and sameAreas(d.areas, { 102, 99, 2, 12 }), "直的路（12 列、寬 2）併成一塊")
    for y = 99, 110 do
        T.floor(102, y, nil)
        T.floor(103, y, nil)
    end
    for i = 0, 3 do T.floor(100 + i, 100 + i, "blends_street_01_96") end
    code, d = roads()
    check(sameAreas(d.areas, { 100, 100, 1, 1, 101, 101, 1, 1, 102, 102, 1, 1, 103, 103, 1, 1 }), "斜的路每列一塊")
    E.MAX_ROAD_AREAS = 2
    code, d = roads()
    check(code == C.ROAD and sameAreas(d.areas, { 100, 100, 1, 1, 101, 101, 1, 1 }), "矩形到上限就停：結果照樣是 ROAD")
    E.MAX_ROAD_AREAS = 128
    for i = 0, 3 do T.floor(100 + i, 100 + i, nil) end
    T.unloaded["104,103"] = true
    code, d = roads()
    check(code == C.NOT_LOADED and d.x == 104 and d.y == 103, "範圍內有未載入格→NOT_LOADED｛x, y｝")
    T.floor(101, 99, "blends_street_01_80")
    code, d = roads()
    check(code == C.ROAD and sameAreas(d.areas, { 101, 99, 1, 1 }), "先遇到道路再遇到未載入格：ROAD，未載入格不標")
    T.floor(101, 99, nil)
    T.unloaded["104,103"] = nil
    check(roads() == nil, "清掉後通過")

    T.section("Exclusions：道路豁免區（Claims.checkRoads → Zones.exemptBoxes，往外擴 RoadMargin）")
    local Zn = MSH.Zones
    local function zone(id, kind, x, y, w, h)
        return { id = id, kind = kind, name = "z" .. id, rects = { { x = x, y = y, w = w, h = h } } }
    end
    local function checked(rs)
        T.squareReads = 0
        return MSH.Claims.checkRoads({ rects = rs or { rect }, cfg = cfg })
    end
    -- 安全屋剛好等於豁免區 (100,100) 10×10：掃描範圍 [99,111) 正好是區往外擴 1，貼邊那格的路也放行
    Zn.list = { zone(1, "roadexempt", 100, 100, 10, 10) }
    T.floor(99, 105, "blends_street_01_96")
    T.floor(105, 105, "blends_street_01_80")
    check(checked() == nil and T.squareReads == 0,
        "整塊在豁免區內：區內與貼邊（RoadMargin）的路都放行、不讀地板（實際讀 " .. T.squareReads .. " 格）")
    T.unloaded["104,103"], T.unloaded["99,99"] = true, true
    check(checked() == nil, "豁免範圍內沒載入：不回 NOT_LOADED")
    T.unloaded["104,103"], T.unloaded["99,99"] = nil, nil
    -- 跨出區外：安全屋 (100,100) 15×10 → 掃描 [99,116)；豁免盒 [99,111)；區外 (113,105) 的路照擋，區內的不回
    T.floor(113, 105, "blends_street_01_80")
    code, d = checked({ { x = 100, y = 100, w = 15, h = 10 } })
    check(code == C.ROAD and d.x == 113 and sameAreas(d.areas, { 113, 105, 1, 1 }), "跨出豁免區：只回區外的路格")
    T.floor(113, 105, nil)
    Zn.list = { zone(1, "nobuild", 100, 100, 10, 10) }
    check(checked() == C.ROAD, "禁建區不給豁免")
    Zn.list = { zone(1, "roadexempt", 300, 300, 10, 10) }
    check(Zn.exemptBoxes({ rect }, 1) == nil and checked() == C.ROAD, "遠處的豁免區：不傳盒、不放行")
    cfg.avoidRoads = false
    Zn.list = { zone(1, "roadexempt", 100, 100, 10, 10) }
    local realBoxes, boxCalls = Zn.exemptBoxes, 0
    Zn.exemptBoxes = function(...)
        boxCalls = boxCalls + 1
        return realBoxes(...)
    end
    check(checked() == nil and T.squareReads == 0 and boxCalls == 0, "AvoidRoads 關：結果不變、不掃、不算豁免盒")
    Zn.exemptBoxes = realBoxes
    cfg.avoidRoads = true
    Zn.list = {}
    T.floor(99, 105, nil)
    T.floor(105, 105, nil)

    -- 每列的豁免區間（排序、合併、指標前進）和逐格比對每個盒等價：隨機盒（重疊、相接、蓋滿整列），兩塊的掃描範圍重疊；
    -- 每格讀不讀地板（讀幾次）要和「落在任一盒內就不讀」完全一致
    local seed = 12345
    local function rnd(n)
        seed = (seed * 16807) % 2147483647
        return seed % n
    end
    local rs = { { x = 500, y = 500, w = 30, h = 20 }, { x = 528, y = 505, w = 10, h = 10 } }
    local flat = { 480, 510, 560, 511 }   -- 蓋滿第 510 列
    local function box(x0, y0, x1, y1)
        flat[#flat + 1], flat[#flat + 2], flat[#flat + 3], flat[#flat + 4] = x0, y0, x1, y1
    end
    for _ = 1, 60 do
        local x0, y0, w, h = 495 + rnd(50), 495 + rnd(30), 1 + rnd(8), 1 + rnd(6)
        box(x0, y0, x0 + w, y0 + h)
        if rnd(3) == 0 then box(x0 + w, y0, x0 + w + 1 + rnd(3), y0 + h) end   -- 緊貼右邊
        if rnd(4) == 0 then box(x0 + 1, y0, x0 + w + 4, y0 + 1) end           -- 和上一個重疊、伸得更遠
    end
    local function inBox(x, y)
        for k = 1, #flat, 4 do
            if x >= flat[k] and y >= flat[k + 1] and x < flat[k + 2] and y < flat[k + 3] then return true end
        end
        return false
    end
    local reads, realGetCell = {}, getCell
    getCell = function()
        local c = realGetCell()
        return { getGridSquare = function(_, x, y, z)
            reads[x .. "," .. y] = (reads[x .. "," .. y] or 0) + 1
            return c:getGridSquare(x, y, z)
        end }
    end
    local eqCode = E.roads(rs, cfg, flat)
    getCell = realGetCell
    local want, cells, skipped = {}, 0, 0
    local m = cfg.roadMargin
    for _, r in ipairs(rs) do
        for y = r.y - m, r.y + r.h + m - 1 do
            for x = r.x - m, r.x + r.w + m - 1 do
                cells = cells + 1
                if inBox(x, y) then skipped = skipped + 1 else want[x .. "," .. y] = (want[x .. "," .. y] or 0) + 1 end
            end
        end
    end
    local same = true
    for k, n in pairs(want) do same = same and reads[k] == n end
    for k, n in pairs(reads) do same = same and want[k] == n end
    check(eqCode == nil and same and skipped > 0 and skipped < cells, "豁免區間和逐格比對每個盒的結果完全相同（"
        .. cells .. " 格、豁免 " .. skipped .. " 格）")

    T.section("Exclusions：自家車道放寬（住宅外框＋邊界＋2）")
    -- 住宅外框 (200,200) 10×10；邊界 1 → 近區 [197,213)；範圍 (200,200) 20×10 → 掃描 [199,221)×[199,211)
    rect = { x = 200, y = 200, w = 20, h = 10 }
    T.building(200, 200, 10, 10, { "kitchen", "bedroom" })
    T.floor(212, 205, "blends_street_01_96")
    check(roads() == nil, "近區最外一格（外框外 3 格）的街道不擋")
    T.floor(210, 205, "blends_street_01_96")
    check(roads() == nil, "外框旁的街道（自家車道）不擋")
    T.floor(211, 206, "blends_street_01_80")
    code, d = roads()
    check(code == C.ROAD and d.kind == "main" and d.x == 211 and sameAreas(d.areas, { 211, 206, 1, 1 }),
        "近區內主要道路照擋；放寬的街道格不標")
    T.floor(211, 206, nil)
    T.floor(213, 207, "blends_street_01_96")
    code, d = roads()
    check(code == C.ROAD and d.kind == "street" and d.x == 213, "近區外一格的街道照擋")
    T.floor(213, 207, nil)
    cfg.roadKinds.gravel = true
    T.floor(205, 199, "blends_street_01_48")
    check(roads() == nil, "近區內勾選的碎石地也放寬")
    cfg.roadKinds.gravel = nil
    T.floor(205, 199, nil)

    -- 不碰住宅的範圍不放寬：範圍 (211,200) 起，房子在 [200,210) 外
    rect = { x = 211, y = 200, w = 9, h = 10 }
    code, d = roads()
    check(code == C.ROAD and d.x == 210 and d.kind == "street", "範圍沒碰到住宅：街道照擋")
    rect = { x = 200, y = 200, w = 20, h = 10 }

    MSH = T.boot()
    E = MSH.Exclusions
    cfg = MSH.Settings.get()
    T.building(200, 200, 10, 10, { "kitchen", "office" })
    T.floor(210, 205, "blends_street_01_96")
    code, d = roads()
    check(code == C.ROAD and d.x == 210, "沒有臥室的建築不放寬")

    T.section("Exclusions：附屬建築（獨立車庫）的近區")
    -- 住宅 (300,300) 10×10；附屬建築在東邊、中間隔 gap 格空地；範圍＝附屬建築外框，它東邊外一格（y=302）是街道
    local function site(houseRooms, shedRooms, gap, w, h)
        MSH = T.boot()
        E = MSH.Exclusions
        cfg = MSH.Settings.get()
        w, h = w or 4, h or 5
        local x = 310 + gap
        T.building(300, 300, 10, 10, houseRooms)
        T.building(x, 300, w, h, shedRooms)
        rect = { x = x, y = 300, w = w, h = h }
        T.floor(x + w, 302, "blends_street_01_96")
        return x + w
    end
    site({ "bedroom" }, { "garagestorage" }, 4)
    check(roads() == nil, "住宅旁隔 4 格的車庫：只圈車庫時門口的車道不擋（住宅外框＋3 管不到）")
    T.floor(318, 303, "blends_street_01_80")
    code, d = roads()
    check(code == C.ROAD and d.kind == "main" and d.x == 318 and d.y == 303 and sameAreas(d.areas, { 318, 303, 1, 1 }),
        "車庫旁的主要道路照擋；放寬的街道格不標")
    local sx = site({ "bedroom" }, { "garagestorage" }, 5)
    code, d = roads()
    check(code == C.ROAD and d.x == sx and d.kind == "street", "隔 5 格（超過 OUTBUILDING_REACH）的車庫不放寬")
    sx = site({ "bedroom" }, { "mechanic" }, 4)
    code, d = roads()
    check(code == C.ROAD and d.x == sx, "住宅旁的修車廠（mechanic）不放寬")
    sx = site({ "bedroom" }, { "garage", "office" }, 4)
    code, d = roads()
    check(code == C.ROAD and d.x == sx, "有一間不是附屬房名（office）的車庫不放寬")
    sx = site({ "kitchen", "generalstore" }, { "garagestorage" }, 4)
    code, d = roads()
    check(code == C.ROAD and d.x == sx, "旁邊只有商店（沒有臥室）的車庫不放寬")
    site({ "bedroom" }, { "garage" }, 4, 10, 10)
    check(roads() == nil, "外框 100 格（OUTBUILDING_MAX_AREA）的車庫放寬")
    sx = site({ "bedroom" }, { "garage" }, 4, 10, 11)
    code, d = roads()
    check(code == C.ROAD and d.x == sx, "外框超過 100 格的車庫不放寬")

    -- 車庫 (314,308) 4×8：車庫外框＋3＝[311,321)×[305,319)、住宅外框＋3＝[297,313)²，合起來＝[297,321)×[297,319)
    MSH = T.boot()
    E = MSH.Exclusions
    cfg = MSH.Settings.get()
    T.building(300, 300, 10, 10, { "bedroom" })
    T.building(314, 308, 4, 8, { "garage" })
    rect = { x = 300, y = 300, w = 18, h = 16 }
    T.floor(305, 315, "blends_street_01_96")
    check(roads() == nil, "圈住屋子＋車庫：離兩棟外框都超過 3 格、在合起來的外框＋3 內的車道不擋")
    rect = { x = 300, y = 300, w = 21, h = 16 }
    T.floor(321, 310, "blends_street_01_96")
    code, d = roads()
    check(code == C.ROAD and d.x == 321 and d.y == 310 and sameAreas(d.areas, { 321, 310, 1, 1 }),
        "合起來的外框＋3 外一格的街道照擋")
    rect = { x = 200, y = 200, w = 20, h = 10 }

    T.section("Exclusions：MiniMap 停車場（v4 parkingIn）")
    MSH = T.boot()
    E = MSH.Exclusions
    cfg = MSH.Settings.get()
    T.building(200, 200, 10, 10, { "bedroom" })
    -- 停車區外框 (211,200) 2×3 → 走道 [210,214)×[199,204)
    local calls, lastArgs = 0, nil
    local lots = { { x = 211, y = 200, w = 2, h = 3, rows = { { x = 211, y = 200, w = 2, h = 3 } }, rowCount = 1 } }
    local function parkingApi(version, mode)
        return {
            resourceApiVersion = version,
            buildingsIn = function() return {}, 0 end,
            prepare = function() return true end,
            parkingIn = function(x, y, w, h)
                calls = calls + 1
                lastArgs = { x = x, y = y, w = w, h = h }
                if mode == "throw" then error("boom") end
                if mode == "nil" then return nil, "badrect" end
                local out, n = {}, 0   -- 照 MinidoracatMiniMapResources.lua:503-521（MiniMap 938d829）：外框與查詢範圍相交（半開）
                for _, p in ipairs(lots) do
                    if p.x < x + w and x < p.x + p.w and p.y < y + h and y < p.y + p.h then
                        n = n + 1
                        out[n] = p
                    end
                end
                return out, n
            end,
        }
    end
    MinidoracatMiniMapResourceAPI = parkingApi(4)
    check(E.status().parkingApi and E.status().resourceApi, "status：v4 有停車場資料來源")
    T.floor(210, 201, "blends_street_01_96")   -- 停車區走道內
    T.floor(210, 205, "blends_street_01_96")   -- 停車區外、近區內
    code, d = roads()
    check(code == C.ROAD and d.x == 210 and d.y == 201 and d.kind == "street", "近區內：停車區外框＋1 格的街道擋")
    check(calls == 1 and lastArgs.x == 198 and lastArgs.y == 198 and lastArgs.w == 24 and lastArgs.h == 14,
        "停車場查詢一次、範圍＝道路掃描範圍往外 1 格")
    T.floor(210, 201, nil)
    calls = 0
    code = roads()
    check(code == nil and calls == 1, "停車區外的街道不擋；兩格以上非主要道路仍只查一次")
    -- 外框在掃描範圍（y < 211）外 1 格的停車區 (205,211) 2×2：走道 [204,208)×[210,214) 落進掃描範圍
    lots[2] = { x = 205, y = 211, w = 2, h = 2, rows = { { x = 205, y = 211, w = 2, h = 2 } }, rowCount = 1 }
    T.floor(205, 210, "blends_street_01_96")
    code, d = roads()
    check(code == C.ROAD and d.x == 205 and d.y == 210, "外框在掃描範圍外 1 格的停車區：走道上的街道照擋")
    lots[2] = nil
    T.floor(205, 210, nil)
    T.floor(210, 201, "blends_street_01_96")
    for _, case in ipairs({ { api = nil, label = "API 缺席" }, { api = parkingApi(3), label = "版本 3" },
        { api = parkingApi(4, "throw"), label = "parkingIn 丟錯" }, { api = parkingApi(4, "nil"), label = "回 nil" } }) do
        MinidoracatMiniMapResourceAPI = case.api
        check(roads() == nil, case.label .. "：沒有停車場資料，近區內只擋主要道路")
    end
    MinidoracatMiniMapResourceAPI = parkingApi(3)
    check(not E.status().parkingApi and E.status().resourceApi, "status：版本 3 沒有停車場資料來源")
    -- 沒有住宅近區就不查停車場
    MSH = T.boot()
    E = MSH.Exclusions
    cfg = MSH.Settings.get()
    MinidoracatMiniMapResourceAPI = parkingApi(4)
    calls = 0
    T.floor(210, 205, "blends_street_01_96")
    code = roads()
    check(code == C.ROAD and calls == 0, "沒有住宅：街道照擋、不查停車場")

    T.section("Exclusions：倒土蓋掉的路、地圖房間裡的路")
    MSH = T.boot()
    E = MSH.Exclusions
    cfg = MSH.Settings.get()
    MinidoracatMiniMapResourceAPI = nil
    rect = { x = 100, y = 100, w = 10, h = 10 }
    -- 倒土／沙（ISNaturalFloor）換掉原地板，原圖塊記在新地板的 modData：照原圖塊算
    T.pour(105, 105, "blends_natural_01_64", "blends_street_01_80")
    code, d = roads()
    check(code == C.ROAD and d.x == 105 and d.y == 105 and d.kind == "main", "主要道路倒了土：照原圖塊擋（main）")
    T.pour(105, 105, "blends_natural_01_64", "blends_street_01_96")
    code, d = roads()
    check(code == C.ROAD and d.kind == "street", "街道倒了土：照原圖塊擋（street）")
    T.pour(105, 105, "blends_natural_01_64", "blends_street_01_32")
    check(roads() == nil, "倒土前是碎石地：預設 main;street 不擋")
    T.pour(105, 105, "blends_natural_01_64", "blends_natural_01_21")
    check(roads() == nil, "倒土前是自然地面：不擋")
    T.floorMods["105,105"] = { other = 1 }
    check(roads() == nil, "地板有 modData、沒有倒土紀錄：只看現在的地板")
    T.floor(105, 105, nil)
    T.floorMods["105,105"] = nil
    -- 住宅近區放寬街道、不放寬主要道路：現在的地板與倒土前的都算路時取主要道路
    T.building(120, 100, 10, 10, { "bedroom" })
    rect = { x = 112, y = 100, w = 10, h = 10 }
    T.pour(118, 105, "blends_street_01_96", "blends_street_01_80")
    code, d = roads()
    check(code == C.ROAD and d.x == 118 and d.kind == "main", "近區內：街道底下原本是主要道路→照擋（main）")
    T.pour(118, 105, "blends_natural_01_64", "blends_street_01_96")
    check(roads() == nil, "近區內：倒土前是街道→和街道一樣放寬")

    -- 地圖房間裡的格子不算路（使用者 2026-10-14）：Fallas Lake 那種住宅的車庫地板是主要道路圖塊
    MSH = T.boot()
    E = MSH.Exclusions
    cfg = MSH.Settings.get()
    rect = { x = 400, y = 400, w = 10, h = 10 }
    local garage = T.building(402, 402, 6, 4, { "garagestorage" })   -- 沒有臥室：沒有住宅近區放寬
    T.fillFloor(402, 402, 6, 4, "blends_street_01_80")
    check(roads() == nil, "地圖房間裡的主要道路地板不擋")
    T.floor(409, 405, "blends_street_01_80")
    code, d = roads()
    check(code == C.ROAD and d.x == 409 and d.y == 405 and sameAreas(d.areas, { 409, 405, 1, 1 }),
        "房間外的主要道路照擋；房間裡的格子不標")
    T.floor(409, 405, nil)
    local room = garage.rooms[1]
    room.userDefined = true
    code, d = roads()
    check(code == C.ROAD and d.x == 402 and d.y == 402, "玩家圍出來的房間（userDefined）不算：照擋")
    room.userDefined = nil
    room.z = 1
    check(roads() == C.ROAD, "只有樓上的房間：地面那層照擋")
    room.z = 0
    room.name = "emptyoutside"
    check(roads() == C.ROAD, "emptyoutside（院子等戶外區）不算房間：照擋")
    room.name = "garagestorage"
    T.pour(404, 403, "blends_natural_01_64", "blends_street_01_80")
    check(roads() == nil, "地圖房間裡倒過土：照樣不擋")

    T.section("Exclusions：建造、鏟土換掉路面地板（前後比對、伺服器的道路紀錄）")
    MSH = T.boot()
    E = MSH.Exclusions
    cfg = MSH.Settings.get()
    rect = { x = 100, y = 100, w = 10, h = 10 }
    local builder = T.player({ name = "builder", x = 105, y = 105 })
    -- 假的原版 create：wood＝換成新的地板物件（BuildRecipeCode.floor.OnCreate 刪掉原地板）；dirt／gravel＝照 ISNaturalFloor:create
    -- 從舊地板帶 shovelledSprites（沒有就用舊地板圖塊）換成土／碎石；wall＝不動地板
    local POURED = { dirt = "blends_natural_01_64", gravel = "blends_street_01_55" }
    local made
    T.onBuild = function(_, a)
        local key = math.floor(a.x) .. "," .. math.floor(a.y)
        if made == "wood" then
            T.floors[key], T.floorMods[key] = "carpentry_02_57", nil
        elseif POURED[made] then
            local old = T.floorMods[key] and T.floorMods[key].shovelledSprites or { T.floors[key] }
            T.floors[key], T.floorMods[key] = POURED[made], { shovelledSprites = old, pouredFloor = made }
        end
    end
    local function build(kind, x, y)
        made = kind
        Actions.build(builder, { x = x + 0.5, y = y + 0.5, z = 0, north = false })
    end
    -- 鏟土（ISShovelGround.complete）：假的原版照 shovelGround（ISShovelGround.lua:62-80）在同一個地板物件上改：
    -- 有 shovelledSprites 就還原成 [1]、清掉；沒有就記 shovelled、換成泥土
    T.onShovel = function(self)
        local sq = self.sandTile:getSquare()
        local key = sq:getX() .. "," .. sq:getY()
        local md = T.floorMods[key] or {}
        T.floorMods[key] = md
        if md.shovelledSprites then
            T.floors[key], md.shovelledSprites, md.pouredFloor = md.shovelledSprites[1], nil, nil
        else
            T.floors[key], md.shovelled = "blends_natural_01_64", true
        end
    end
    local function shovel(x, y)
        return ISShovelGround.complete(T.action("ISShovelGround", { character = builder, sandTile = T.worldObject(x, y) }))
    end
    -- 伺服器的道路紀錄（記憶體那份；檔案那份由下面的重開測試驗）；nil＝沒有紀錄
    local ROADS_FILE = MSH.Registry.privateFile("roads-servertest.txt")
    local function rec(x, y)
        local store = E.roadRecs
        return store and store[x] and store[x][y]
    end
    -- 清掉這一格的地板與所有道路紀錄（每個案例各自獨立）
    local function clear(x, y)
        T.floor(x, y, nil)
        T.floorMods[x .. "," .. y] = nil
        E.roadRecs, T.files[ROADS_FILE] = nil, nil
    end

    T.floor(105, 105, "blends_street_01_80")
    build("wood", 105, 105)
    code, d = roads()
    check(T.floors["105,105"] == "carpentry_02_57" and code == C.ROAD and d.x == 105 and d.kind == "main",
        "主要道路蓋成木地板：照原圖塊擋（main）")
    check(rec(105, 105) == "blends_street_01_80" and T.floorMods["105,105"] == nil,
        "原圖塊記在伺服器的紀錄，不寫進地板 modData")
    build("dirt", 105, 105)
    code, d = roads()
    check(code == C.ROAD and d.kind == "main" and T.floorMods["105,105"].shovelledSprites[1] == "carpentry_02_57"
        and rec(105, 105) == "blends_street_01_80", "木地板再倒土（倒土紀錄只有木地板）：紀錄不變、照擋（main）")
    -- 信任邊界：地板 modData 客戶端能整份換掉或清空（ObjectModDataPacket）
    T.floorMods["105,105"] = nil
    code, d = roads()
    check(code == C.ROAD and d.kind == "main", "地板 modData 被清空：照紀錄擋（main）")
    T.floorMods["105,105"] = { MSH_road = "blends_natural_01_21", shovelledSprites = { "blends_natural_01_21" } }
    code, d = roads()
    check(code == C.ROAD and d.kind == "main", "地板 modData 被塞進非路的假值：照紀錄擋（main）")
    T.floor(105, 105, nil)
    code, d = roads()
    check(code == C.ROAD and d.x == 105 and d.kind == "main", "記錄後地板整個沒了（大鎚、火燒）：照紀錄擋（main）")
    clear(105, 105)
    T.floor(102, 102, "blends_natural_01_21")
    T.floorMods["102,102"] = { MSH_road = "blends_street_01_80" }
    check(roads() == nil, "草地的地板 modData 被塞進假的 MSH_road：不擋")
    clear(102, 102)
    -- 原版倒土本身留得下原圖塊（shovelledSprites），照樣記進紀錄：客戶端清掉地板 modData 之後仍判原本的路
    T.floor(109, 109, "blends_street_01_96")
    build("dirt", 109, 109)
    check(rec(109, 109) == "blends_street_01_96", "路上直接倒土：照樣記進紀錄")
    T.floorMods["109,109"] = nil
    code, d = roads()
    check(code == C.ROAD and d.kind == "street", "倒土後地板 modData 被清掉：照紀錄擋（street）")
    clear(109, 109)
    -- 第一筆紀錄只來自伺服器讀到的地板：客戶端改得到的 shovelledSprites 不能把真路降級、也不能把草地升格寫進紀錄
    T.floor(109, 109, "blends_street_01_80")
    T.floorMods["109,109"] = { shovelledSprites = { "blends_street_01_55" } }
    build("wood", 109, 109)
    code, d = roads()
    check(rec(109, 109) == "blends_street_01_80" and code == C.ROAD and d.kind == "main",
        "尚無紀錄、主要道路的地板 modData 被偽造成碎石：照記主要道路")
    clear(109, 109)
    T.floor(109, 109, "blends_street_01_80")
    T.floorMods["109,109"] = { shovelledSprites = { "blends_natural_01_21" } }
    code, d = roads()
    check(code == C.ROAD and d.kind == "main", "尚無紀錄、主要道路的地板 modData 被偽造成草地：照擋（柏油類不看倒土欄位）")
    build("wood", 109, 109)
    code, d = roads()
    check(rec(109, 109) == "blends_street_01_80" and code == C.ROAD and d.kind == "main",
        "尚無紀錄、主要道路的地板 modData 被偽造成草地：改地板後照記成路、照擋")
    clear(109, 109)
    T.floor(102, 102, "blends_natural_01_21")
    T.floorMods["102,102"] = { shovelledSprites = { "blends_street_01_80" } }
    build("wood", 102, 102)
    check(rec(102, 102) == nil and roads() == nil, "尚無紀錄、草地的地板 modData 被偽造成路：改地板後不留道路紀錄、不擋")
    clear(102, 102)

    T.floor(103, 103, "blends_natural_01_21")
    build("wood", 103, 103)
    check(rec(103, 103) == nil and roads() == nil, "非路面蓋木地板：不記、不擋")
    clear(103, 103)
    T.floor(107, 107, "blends_street_01_96")
    build("wall", 107, 107)
    code, d = roads()
    check(rec(107, 107) == nil and code == C.ROAD and d.kind == "street", "路上蓋牆（地板沒換）：不記，照現在的地板擋")
    clear(107, 107)
    -- 存圖塊名不存類別：管理員之後才勾的類別照樣認得
    T.floor(104, 104, "blends_street_01_32")
    build("wood", 104, 104)
    check(rec(104, 104) == "blends_street_01_32" and roads() == nil, "碎石地蓋木地板：記下、預設不擋")
    cfg.roadKinds.gravel = true
    code, d = roads()
    check(code == C.ROAD and d.kind == "gravel", "之後勾 gravel：照紀錄擋")
    cfg.roadKinds.gravel = nil
    clear(104, 104)

    T.floor(105, 105, "blends_street_01_55")
    check(shovel(105, 105) == true and T.floors["105,105"] == "blends_natural_01_64", "鏟碎石路：照原版回傳、換成泥土")
    check(rec(105, 105) == "blends_street_01_55" and roads() == nil, "鏟掉的碎石路記下原圖塊；沒勾 gravel 不擋")
    cfg.roadKinds.gravel = true
    code, d = roads()
    check(code == C.ROAD and d.kind == "gravel", "勾 gravel：鏟掉的碎石路照擋")
    cfg.roadKinds.gravel = nil
    clear(105, 105)
    T.floor(103, 103, "blends_natural_01_21")
    shovel(103, 103)
    check(rec(103, 103) == nil and roads() == nil, "鏟草地：不記、不擋")
    clear(103, 103)
    -- 更新前就倒過的（沒有紀錄，只有 shovelledSprites）：鏟回去原版還原，判得出同一類就不記
    T.pour(106, 106, "blends_street_01_53", "blends_street_01_80")
    shovel(106, 106)
    code, d = roads()
    check(T.floors["106,106"] == "blends_street_01_80" and T.floorMods["106,106"].shovelledSprites == nil
        and rec(106, 106) == nil and code == C.ROAD and d.kind == "main", "鏟回倒碎石前的主要道路：原版還原、不記")
    clear(106, 106)
    -- 玩家倒的碎石不是原本的路：草地倒碎石記成「原本不是路」，鏟回或蓋掉都不留道路紀錄
    cfg.roadKinds.gravel = true
    T.floor(103, 103, "blends_natural_01_21")
    build("gravel", 103, 103)
    check(rec(103, 103) == false and roads() == nil, "草地倒碎石：記成原本不是路，不鏟不蓋、勾 gravel 也不擋")
    shovel(103, 103)
    check(T.floors["103,103"] == "blends_natural_01_21" and rec(103, 103) == false and roads() == nil,
        "草地→倒碎石→鏟回：不留道路紀錄、勾 gravel 也不擋")
    clear(103, 103)
    T.floor(103, 103, "blends_natural_01_21")
    build("gravel", 103, 103)
    build("wood", 103, 103)
    check(rec(103, 103) == false and roads() == nil, "草地→倒碎石→蓋木地板：不留道路紀錄、勾 gravel 也不擋")
    clear(103, 103)
    -- 更新前就在草地上倒的碎石（沒有紀錄；shovelledSprites[1]＝草地）：不算原本的路，鏟回或蓋掉都不留道路紀錄
    T.pour(103, 103, "blends_street_01_53", "blends_natural_01_21")
    check(roads() == nil, "更新前草地倒的碎石（沒有紀錄）：勾 gravel 也不擋")
    shovel(103, 103)
    check(T.floors["103,103"] == "blends_natural_01_21" and rec(103, 103) == nil and roads() == nil,
        "更新前草地倒的碎石→鏟回：沒有道路紀錄、不擋")
    clear(103, 103)
    T.pour(103, 103, "blends_street_01_53", "blends_natural_01_21")
    build("wood", 103, 103)
    check(rec(103, 103) == nil and roads() == nil, "更新前草地倒的碎石→蓋木地板：沒有道路紀錄、不擋")
    clear(103, 103)
    T.floor(103, 103, "blends_street_01_53")
    code, d = roads()
    check(code == C.ROAD and d.kind == "gravel", "對照：沒有倒土欄位的天然碎石路照擋（gravel）")
    clear(103, 103)
    cfg.roadKinds.gravel = nil
    -- 拆地面層地板：原版在同一個地板物件上換成泥土（ISDismantleAction.lua:82-88、ISMoveableSpriteProps.lua:3724-3733）
    T.floor(108, 108, "blends_street_01_80")
    build("wood", 108, 108)
    T.floors["108,108"] = "blends_natural_01_64"
    code, d = roads()
    check(code == C.ROAD and d.kind == "main", "主要道路上的木地板拆掉（剩泥土）：照擋（main）")
    shovel(108, 108)
    code, d = roads()
    check(rec(108, 108) == "blends_street_01_80" and code == C.ROAD and d.kind == "main", "拆完再鏟：紀錄不變，照擋")
    clear(108, 108)
    -- 紀錄不等世界存檔：當下附加到伺服器私有檔；當機（Global ModData 與 Lua 狀態都沒了、區塊已存下新地板）重開照檔案判
    T.floor(105, 105, "blends_street_01_80")
    build("wood", 105, 105)
    local lines = T.files[ROADS_FILE] and T.files[ROADS_FILE].lines or {}
    check(#lines == 1 and lines[1] == "R\t105\t105\tblends_street_01_80", "記下時當下附加一行到伺服器私有檔")
    MSH = T.boot({ keepFiles = true })
    E = MSH.Exclusions
    cfg = MSH.Settings.get()
    T.floor(105, 105, "carpentry_02_57")
    code, d = roads()
    check(code == C.ROAD and d.x == 105 and d.kind == "main", "當機重開（只剩新地板與紀錄檔）：照檔案裡的紀錄擋（main）")
    MSH = T.boot()
    E = MSH.Exclusions
    cfg = MSH.Settings.get()
    T.floor(105, 105, "carpentry_02_57")
    check(roads() == nil, "對照：沒有紀錄檔時同一塊木地板不擋")
    -- 壞行略過；同一格先寫的為準
    T.files[ROADS_FILE] = { lines = { "junk", "R\t105\t105\tblends_street_01_80", "R\t105\t105\t-" } }
    E.roadRecs = nil
    code, d = roads()
    check(code == C.ROAD and d.kind == "main", "紀錄檔有壞行：略過、其餘照讀，同一格先寫的為準")
    -- 紀錄檔讀不開：照沒有紀錄判，稽核之外 console 也要看得到
    T.unreadable[ROADS_FILE] = true
    E.roadRecs = nil
    T.prints = {}
    local verdict, seen = roads(), false
    for _, line in ipairs(T.prints) do
        if string.find(line, "road record file unreadable", 1, true) then seen = true end
    end
    check(verdict == nil and seen, "紀錄檔讀不開：照沒有紀錄判（木地板不擋）、console 打一行")
    T.unreadable[ROADS_FILE] = nil
    T.floor(105, 105, nil)

    T.section("Exclusions：資源點（MiniMap §3.19）")
    MSH = T.boot()
    E = MSH.Exclusions
    cfg = MSH.Settings.get()
    rect = { x = 100, y = 100, w = 10, h = 10 }
    local q, buildings = nil, {}
    local function resourceApi(version, mode)
        return {
            resourceApiVersion = version,
            prepare = function() return true end,
            buildingsIn = function(x, y, w, h, ver)
                q = { x = x, y = y, w = w, h = h, ver = ver }
                if mode == "throw" then error("boom") end
                if mode == "pending" and ver == "rooms" then return nil, "pending" end
                if mode == "badversion" then return nil, "badversion" end
                local out, n = {}, 0
                for _, b in ipairs(buildings) do
                    if b.x < x + w and x < b.x + b.w and b.y < y + h and y < b.y + b.h then
                        n = n + 1
                        out[n] = b
                    end
                end
                return out, n
            end,
        }
    end
    buildings = { { x = 104, y = 104, w = 3, h = 3, cats = { police = true } } }
    check(E.resources({ rect }, cfg) == nil and not E.status().resourceApi, "MiniMap 缺席：不擋、status 回 false")
    MinidoracatMiniMapResourceAPI = resourceApi(0)
    check(E.resources({ rect }, cfg) == nil and not E.status().resourceApi, "版本 0：不擋")
    MinidoracatMiniMapResourceAPI = { resourceApiVersion = 1, buildingsIn = resourceApi(1).buildingsIn }
    check(E.resources({ rect }, cfg) == nil, "缺 prepare：守衛不過、不擋")
    MinidoracatMiniMapResourceAPI = resourceApi(1)
    check(E.status().resourceApi and not E.status().parkingApi, "status：v1 有資源點、沒有停車場")
    code, d = E.resources({ rect }, cfg)
    check(code == C.RESOURCE and d.cat == "police" and d.x == 104 and d.w == 3 and q.ver == "minimap",
        "小地圖資源：命中勾選類別→RESOURCE｛cat, x, y, w, h｝")
    check(q.x == 98 and q.y == 98 and q.w == 14 and q.h == 14, "查詢範圍＝rect 往外 claimGap（2）")
    cfg.avoidResources = false
    q = nil
    check(E.resources({ rect }, cfg) == nil and q == nil, "AvoidResources 關：不查")
    cfg.avoidResources = true
    buildings = { { x = 104, y = 104, w = 3, h = 3, cats = { food = true, school = true } } }
    check(E.resources({ rect }, cfg) == nil, "沒勾的類別不擋")
    buildings = { { x = 111, y = 100, w = 4, h = 4, cats = { medical = true } } }
    code, d = E.resources({ rect }, cfg)
    check(code == C.RESOURCE and d.cat == "medical", "間距內（中間隔 1 格、claimGap 2）的建築擋")
    MSH.Zones.list = { { id = 1, kind = "roadexempt", name = "z", rects = { { x = 90, y = 90, w = 40, h = 40 } } } }
    code, d = MSH.Claims.checkResources({ rects = { rect }, cfg = cfg })
    MSH.Zones.list = {}
    check(code == C.RESOURCE and d.cat == "medical", "道路豁免區不豁免資源點")
    buildings = { { x = 112, y = 100, w = 4, h = 4, cats = { medical = true } } }
    check(E.resources({ rect }, cfg) == nil, "隔滿 claimGap 格的建築不擋")
    cfg.resourceRule = MSH.Settings.RULE.ROOMS
    MinidoracatMiniMapResourceAPI = resourceApi(1, "pending")
    check(E.resources({ rect }, cfg) == C.RESOURCE_PENDING and q.ver == "rooms", "房間資料還沒掃完→RESOURCE_PENDING")
    MinidoracatMiniMapResourceAPI = resourceApi(1, "badversion")
    check(E.resources({ rect }, cfg) == C.RESOURCE_ERROR, "其他失敗原因→RESOURCE_ERROR")
    MinidoracatMiniMapResourceAPI = resourceApi(1, "throw")
    T.advance(60000)   -- 跳出上一筆 RESOURCE_ERROR 的 audit 節流窗
    check(E.resources({ rect }, cfg) == C.RESOURCE_ERROR and T.logged("boom"), "丟錯→RESOURCE_ERROR、寫 audit")

    T.section("Exclusions：房間資料模式開服先 prepare")
    local prepared = {}
    local function bootWith(rule)
        prepared = {}
        T.boot({ sandbox = { ResourceRule = rule }, beforeStart = function()
            MinidoracatMiniMapResourceAPI = resourceApi(1)
            MinidoracatMiniMapResourceAPI.prepare = function(v) prepared[#prepared + 1] = v return false end
        end })
    end
    bootWith(2)
    check(#prepared == 1 and prepared[1] == "rooms", "ResourceRule=房間資料：OnServerStarted 呼叫 prepare(\"rooms\")")
    bootWith(1)
    check(#prepared == 0, "ResourceRule=小地圖資源：不 prepare")
    T.boot({ sandbox = { ResourceRule = 2 } })
    check(T.logged("exclusionsPrepare") == false, "MiniMap 缺席：hook 不出錯")
end
