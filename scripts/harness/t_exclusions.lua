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
        return E.roads(rect, cfg)
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
    check(E.resources(rect, cfg) == nil and not E.status().resourceApi, "MiniMap 缺席：不擋、status 回 false")
    MinidoracatMiniMapResourceAPI = resourceApi(0)
    check(E.resources(rect, cfg) == nil and not E.status().resourceApi, "版本 0：不擋")
    MinidoracatMiniMapResourceAPI = { resourceApiVersion = 1, buildingsIn = resourceApi(1).buildingsIn }
    check(E.resources(rect, cfg) == nil, "缺 prepare：守衛不過、不擋")
    MinidoracatMiniMapResourceAPI = resourceApi(1)
    check(E.status().resourceApi and not E.status().parkingApi, "status：v1 有資源點、沒有停車場")
    code, d = E.resources(rect, cfg)
    check(code == C.RESOURCE and d.cat == "police" and d.x == 104 and d.w == 3 and q.ver == "minimap",
        "小地圖資源：命中勾選類別→RESOURCE｛cat, x, y, w, h｝")
    check(q.x == 98 and q.y == 98 and q.w == 14 and q.h == 14, "查詢範圍＝rect 往外 claimGap（2）")
    cfg.avoidResources = false
    q = nil
    check(E.resources(rect, cfg) == nil and q == nil, "AvoidResources 關：不查")
    cfg.avoidResources = true
    buildings = { { x = 104, y = 104, w = 3, h = 3, cats = { food = true, school = true } } }
    check(E.resources(rect, cfg) == nil, "沒勾的類別不擋")
    buildings = { { x = 111, y = 100, w = 4, h = 4, cats = { medical = true } } }
    code, d = E.resources(rect, cfg)
    check(code == C.RESOURCE and d.cat == "medical", "間距內（中間隔 1 格、claimGap 2）的建築擋")
    buildings = { { x = 112, y = 100, w = 4, h = 4, cats = { medical = true } } }
    check(E.resources(rect, cfg) == nil, "隔滿 claimGap 格的建築不擋")
    cfg.resourceRule = MSH.Settings.RULE.ROOMS
    MinidoracatMiniMapResourceAPI = resourceApi(1, "pending")
    check(E.resources(rect, cfg) == C.RESOURCE_PENDING and q.ver == "rooms", "房間資料還沒掃完→RESOURCE_PENDING")
    MinidoracatMiniMapResourceAPI = resourceApi(1, "badversion")
    check(E.resources(rect, cfg) == C.RESOURCE_ERROR, "其他失敗原因→RESOURCE_ERROR")
    MinidoracatMiniMapResourceAPI = resourceApi(1, "throw")
    T.advance(60000)   -- 跳出上一筆 RESOURCE_ERROR 的 audit 節流窗
    check(E.resources(rect, cfg) == C.RESOURCE_ERROR and T.logged("boom"), "丟錯→RESOURCE_ERROR、寫 audit")

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
