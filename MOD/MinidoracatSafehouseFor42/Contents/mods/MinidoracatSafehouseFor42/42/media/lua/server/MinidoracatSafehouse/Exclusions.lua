-- MinidoracatSafehouse/Exclusions.lua：道路／資源點排除，建立確認當下判定一次（計畫 §8.1–8.3）。
-- 道路＝地面層地板圖塊（只看 getFloor，路緣、標線等覆蓋圖掛在 attachedAnimSprite、不看：CellLoader.java:256-264），
-- 倒土蓋掉的原地板照樣算（floorKind）；地圖房間裡的格子不算路（mapRooms；兩條都是使用者 2026-10-14 裁定）；
-- 自家車道放寬（使用者 2026-10-10 裁定 driveway、parkingsrc）：住宅外框＋roadMargin＋2 格內只有主要道路與 MiniMap 停車場算路；
-- 住宅的獨立車庫等附屬建築也有近區（和住宅合起來的外框＋同樣格數，見 addOutbuilding）。
-- 資源點＝MiniMap `MinidoracatMiniMapResourceAPI.buildingsIn`；MiniMap 缺席或版本不符＝不擋、設定隱藏（§8.2）。
-- 成本（§12.4）：每塊範圍（含邊界）每格讀一次，相鄰塊的邊界帶會重疊多讀幾格；道路違規時照樣掃完（和通過時一樣多），
-- 違規格合併成矩形回給客戶端標紅（使用者 2026-10-11 裁定預檢標紅）；配置只隨請求（住宅數、附屬建築數（各多查一次
-- RoomDef）、地圖房間數、停車區數、道路矩形數）成長，不逐格建表。範圍是一間的各塊（rects，使用者 2026-10-11 裁定多塊）。
-- 回傳一律 nil（通過）或 code, detail：ROAD { x, y, kind, areas }（第一格與它的類別；areas＝全部違規格的矩形，
-- 扁平 x, y, w, h, ...）、NOT_LOADED { x, y }、RESOURCE { cat, x, y, w, h }、RESOURCE_PENDING、RESOURCE_ERROR。

if isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Settings"
require "MinidoracatSafehouse/Audit"
require "MinidoracatSafehouse/Server"

local MSH = MinidoracatSafehouse
local E = MSH.Exclusions or {}
MSH.Exclusions = E

local CODE = MSH.CODE
local RULE = MSH.Settings.RULE
local Rect = MSH.Rect

-- ===== 地板圖塊分類（§8.1；E2E roadcov-sp 的 category 收斂成四類）=====
-- 不算路：blends_street_01_0–7（破損補丁）、64–71（籃球場）、其他編號、floors_exterior_street*、carpentry_02*。
function E.classify(name)
    if type(name) ~= "string" then return nil end
    local i = tonumber(string.match(name, "^blends_street_01_(%d+)$"))
    if i then
        if i >= 80 and i <= 87 then return "main" end
        if i >= 96 and i <= 103 then return "street" end
        if (i >= 32 and i <= 39) or (i >= 48 and i <= 55) then return "gravel" end
        if i >= 16 and i <= 21 then return "sidewalk" end
        return nil
    end
    if string.find(name, "^floors_exterior_tilesandstone_01_%d+$") then return "sidewalk" end
    return nil
end

-- 扁平陣列 { x0, y0, x1, y1, ... }（半開）是否有一區包含 (x, y)
local function inAny(boxes, x, y)
    for k = 1, #boxes, 4 do
        if x >= boxes[k] and y >= boxes[k + 1] and x < boxes[k + 2] and y < boxes[k + 3] then return true end
    end
    return false
end

local function hasBedroom(building)
    local rooms = building:getRooms()                     -- BuildingDef.java:98-100
    for i = 0, rooms:size() - 1 do
        if rooms:get(i):getName() == "bedroom" then return true end   -- RoomDef.java:215-217
    end
    return false
end

-- 附屬建築（獨立車庫、車棚、工具間）：沒有臥室、每間房都在 OUTBUILDING_ROOMS、外框面積 ≤ OUTBUILDING_MAX_AREA，
-- 而且外框往外 OUTBUILDING_REACH 格內有住宅的房間。房名照 2026-10-13 離線房屋分類的附屬建築名單；修車廠等商用車庫
-- 有 mechanic／office 等房、不算。面積上限：原版住宅旁的附屬建築外框 p99 56 格、最大的雙車庫 60 格。
-- 往外 5 格＝和住宅的房間之間最多隔 4 格空地，同地塊分組的間距 4；量的是房間（getRoomsIntersecting），外框含
-- emptyoutside、比房間大，改量 4 格時原版 493 塊被擋的地還有 58 塊救不回來（5 格剩 16 塊，其中 8 塊是主要道路）。
local OUTBUILDING_ROOMS = { garage = true, garagestorage = true, garage_storage = true, shed = true, ww_shed = true,
    woodshed = true, storage = true, miscstorage = true, gardeningstorage = true, hunterstorage = true, boathouse = true,
    empty = true, Empty = true, closet = true, laundry = true, bathroom = true }
local OUTBUILDING_MAX_AREA = 100
local OUTBUILDING_REACH = 5

local function isOutbuilding(building)
    if building:getW() * building:getH() > OUTBUILDING_MAX_AREA then return false end
    local rooms = building:getRooms()
    for i = 0, rooms:size() - 1 do
        if not OUTBUILDING_ROOMS[rooms:get(i):getName()] then return false end
    end
    return true
end

-- 扁平陣列加一區：[x0, x1)×[y0, y1) 往外 d 格
local function addZone(zones, x0, y0, x1, y1, d)
    local n = #zones
    zones[n + 1], zones[n + 2], zones[n + 3], zones[n + 4] = x0 - d, y0 - d, x1 + d, y1 + d
end

-- 附屬建築的近區＝它和附近每棟住宅合起來的外框往外 d 格：圈住屋子＋車庫的矩形常蓋到車庫門口往外 4–5 格的車道，
-- 只給車庫外框＋d 不夠（2026-10-13 離線：原版 493 塊「住宅＋附屬建築」地被街道格擋下，車庫外框＋d 只救 160 塊，合起來救 477 塊）
local function addOutbuilding(zones, b, d)
    local x, y, w, h = b:getX(), b:getY(), b:getW(), b:getH()
    local r = OUTBUILDING_REACH
    local list = ArrayList.new()
    getWorld():getMetaGrid():getRoomsIntersecting(x - r, y - r, w + 2 * r, h + 2 * r, list)
    local done = {}
    for i = 0, list:size() - 1 do
        local house = list:get(i):getBuilding()
        if house ~= nil and not done[house] then
            done[house] = true
            if hasBedroom(house) then
                local hx, hy = house:getX(), house:getY()
                addZone(zones, math.min(x, hx), math.min(y, hy), math.max(x + w, hx + house:getW()),
                    math.max(y + h, hy + house:getH()), d)
            end
        end
    end
end

-- 範圍碰到的住宅（任一房叫 bedroom 的 BuildingDef）外框往外 d 格，與附屬建築的近區；每塊各查一次，同一棟只記一次
local function nearZones(rects, d)
    local seen, zones = {}, {}
    for _, rect in ipairs(rects) do
        local list = ArrayList.new()   -- 原版用例 ISWidgetCraftLogicInputControl.lua:16
        -- IsoMetaGrid.java:430-441（void，結果放進 list；所有樓層、不必載入 chunk，§2.8）
        getWorld():getMetaGrid():getRoomsIntersecting(rect.x, rect.y, rect.w, rect.h, list)
        for i = 0, list:size() - 1 do
            local b = list:get(i):getBuilding()           -- RoomDef.java:207-209
            if b ~= nil and not seen[b] then
                seen[b] = true
                if hasBedroom(b) then
                    local x, y = b:getX(), b:getY()        -- BuildingDef.java:186-209
                    addZone(zones, x, y, x + b:getW(), y + b:getH(), d)
                elseif isOutbuilding(b) then
                    addOutbuilding(zones, b, d)
                end
            end
        end
    end
    return zones
end

-- MiniMap 停車場查詢（v4）：MiniMap docs/addon-api.md:795、816-827（守衛）、848-856（parkingIn）；
-- MinidoracatMiniMapResources.lua:460（resourceApiVersion = 4）、492-523（parkingIn）；行號照 MiniMap 938d829。
local function parkingApi()
    local R = MinidoracatMiniMapResourceAPI
    if type(R) == "table" and type(R.resourceApiVersion) == "number" and R.resourceApiVersion >= 4
        and type(R.parkingIn) == "function" then return R end
    return nil
end

-- 走道落在掃描範圍內的停車區外框（查詢範圍＝掃描範圍往外 1 格，外框在範圍外 1 格的也算），各往外 1 格當走道；
-- 沒有資料（缺席、版本不夠、丟錯、回 nil）＝空清單
local function parkingLots(scan)
    local R = parkingApi()
    if R == nil then return {} end
    local q = Rect.expand(scan, 1)
    local ok, boxes = pcall(function()
        local lots, n = R.parkingIn(q.x, q.y, q.w, q.h)
        local out = {}
        if lots == nil then return out end
        for i = 1, n do
            local p = lots[i]
            out[#out + 1], out[#out + 2] = p.x - 1, p.y - 1
            out[#out + 1], out[#out + 2] = p.x + p.w + 1, p.y + p.h + 1
        end
        return out
    end)
    if not ok then
        MSH.Audit.throttled("EXCL|parking", 60000, "INTERNAL_ERROR",
            { code = "PARKING_ERROR", detail = tostring(boxes) }, getTimestampMs())
        return {}
    end
    return boxes
end

-- 這格算哪一類路（只回勾選的類別）：現在的地板，加上倒土前的地板。倒土／沙等（ISNaturalFloor:create → addFloor）會換掉
-- 原地板，原本的圖塊記在新地板 modData 的 shovelledSprites[1]（ISNaturalFloor.lua:7-13；鏟回去時 ISShovelGround.lua:60-76
-- 用它還原）。B42 蓋的地板疊在原地板後面（ISBuildIsoEntity.lua:733 AddSpecialObject），getFloor 本來就讀到原地板。
-- 兩個都算路時取主要道路（它不吃住宅近區放寬）
local function floorKind(floor, kinds)
    local sprite = floor:getSprite()                       -- IsoObject.java:1999
    local kind = sprite and E.classify(sprite:getName())  -- IsoSprite.java:1980
    if kind and not kinds[kind] then kind = nil end
    if kind ~= "main" and floor:hasModData() then         -- 沒有 modData 時不呼叫 getModData（會建一張空表）
        local old = floor:getModData().shovelledSprites
        local k = type(old) == "table" and E.classify(old[1]) or nil
        if k and kinds[k] and (kind == nil or k == "main") then kind = k end
    end
    return kind
end

-- 掃描範圍（各塊含邊界）碰到的地圖房間：lotheader 的 RoomDef，z=0，不含 emptyoutside（院子等戶外區）與 userDefined。
-- B42 會把玩家圍起來的房子轉成 userDefined 的 RoomDef（WorldRegionToMetaGrid.java:275），格子的 getRoom 還優先回它
-- （IsoMetaChunk.java:282-299），所以不用 sq:getRoom()：在路上圍牆不會讓路變成房間。每次 roads 最多查一次
local function mapRooms(rects, margin)
    local out, seen = {}, {}
    for _, rect in ipairs(rects) do
        local s = Rect.expand(rect, margin)
        local list = ArrayList.new()
        getWorld():getMetaGrid():getRoomsIntersecting(s.x, s.y, s.w, s.h, list)   -- IsoMetaGrid.java:430-441
        for i = 0, list:size() - 1 do
            local r = list:get(i)
            if not seen[r] then
                seen[r] = true
                -- RoomDef.java:253-255（getZ）、355-357（isEmptyOutside）、474-476（isUserDefined）
                if r:getZ() == 0 and not r:isEmptyOutside() and not r:isUserDefined() then out[#out + 1] = r end
            end
        end
    end
    return out
end

local function inRoom(rooms, x, y)
    for i = 1, #rooms do
        if rooms[i]:contains(x, y) then return true end   -- RoomDef.java:83-91（逐個 RoomRect，半開）
    end
    return false
end

-- ===== 道路（§8.1）=====
E.MAX_ROAD_AREAS = 128   -- 回給客戶端標紅的矩形上限（封包大小與每幀繪製數）；滿了就停掃，結果照樣是 ROAD

-- 一列內連續的道路格 [x0, x1)：上一列有同起點、同寬的矩形就往下延伸（直的路併成一塊），否則新開一個
local function addRun(st, x0, x1, y)
    local areas = st.areas
    local i = st.prev[x0]
    if i ~= nil and areas[i + 2] == x1 - x0 then
        areas[i + 3] = areas[i + 3] + 1
    elseif #areas >= E.MAX_ROAD_AREAS * 4 then
        st.full = true
        return
    else
        i = #areas + 1
        areas[i], areas[i + 1], areas[i + 2], areas[i + 3] = x0, y, x1 - x0, 1
    end
    st.cur[x0] = i
end

function E.roads(rects, cfg)
    if not cfg.avoidRoads then return nil end
    local kinds = cfg.roadKinds
    local cell = getCell()
    local near, lots   -- 第一次遇到非主要道路的勾選類別才查（每次 roads 最多一次）
    local rooms        -- 第一次遇到道路格才查
    local hit, st      -- 第一個違規格（回傳的 detail）與合併矩形的狀態
    for _, rect in ipairs(rects) do
        local scan = Rect.expand(rect, cfg.roadMargin)
        local xEnd = scan.x + scan.w
        if st ~= nil then st.prev, st.cur = {}, {} end   -- 換一塊：上一塊最後一列的段不往下接
        for y = scan.y, scan.y + scan.h - 1 do
            local run = nil   -- 這一列進行中的違規段起點
            for x = scan.x, xEnd - 1 do
                -- 伺服器走 ServerMap，chunk 沒載入回 nil（IsoCell.java:3190-3192）；已經確定是 ROAD 時只當成不是路
                local sq = cell:getGridSquare(x, y, 0)
                if sq == nil and hit == nil then return CODE.NOT_LOADED, { x = x, y = y } end
                local floor = sq and sq:getFloor()        -- IsoGridSquare.java:4652（第一個 solidfloor 物件）
                local kind = floor and floorKind(floor, kinds)
                if kind then
                    rooms = rooms or mapRooms(rects, cfg.roadMargin)
                    if inRoom(rooms, x, y) then kind = nil end
                end
                if kind and kind ~= "main" then
                    if near == nil then
                        near = nearZones(rects, cfg.roadMargin + 2)
                        lots = #near > 0 and parkingLots(Rect.expand(Rect.bounds(rects), cfg.roadMargin)) or {}
                    end
                    if inAny(near, x, y) and not inAny(lots, x, y) then kind = nil end
                end
                if kind then
                    if hit == nil then
                        st = { areas = {}, prev = {}, cur = {} }
                        hit = { x = x, y = y, kind = kind, areas = st.areas }
                    end
                    run = run or x
                elseif run ~= nil then
                    addRun(st, run, x, y)
                    run = nil
                end
            end
            if run ~= nil then addRun(st, run, xEnd, y) end
            if st ~= nil then
                if st.full then return CODE.ROAD, hit end
                st.prev, st.cur = st.cur, {}
            end
        end
    end
    if hit ~= nil then return CODE.ROAD, hit end
    return nil
end

-- ===== 資源點（§8.2；MiniMap docs/addon-api.md:782-863 §3.19，MinidoracatMiniMapResources.lua:460-487，MiniMap 938d829）=====
local function resourceApi()
    local R = MinidoracatMiniMapResourceAPI
    if type(R) == "table" and type(R.resourceApiVersion) == "number" and R.resourceApiVersion >= 1
        and type(R.buildingsIn) == "function" and type(R.prepare) == "function" then return R end
    return nil
end

local function queryResources(R, rect, cfg)
    local gap = cfg.claimGap
    local version = cfg.resourceRule == RULE.ROOMS and "rooms" or "minimap"
    local hits, n = R.buildingsIn(rect.x - gap, rect.y - gap, rect.w + 2 * gap, rect.h + 2 * gap, version)
    if hits == nil then
        if n == "pending" then return CODE.RESOURCE_PENDING end
        error("buildingsIn: " .. tostring(n))
    end
    local cats = cfg.resourceCats
    for i = 1, n do
        local b = hits[i]
        for cat in pairs(b.cats) do
            if cats[cat] then return CODE.RESOURCE, { cat = cat, x = b.x, y = b.y, w = b.w, h = b.h } end
        end
    end
    return nil
end

-- 每塊各查一次（含 claimGap 邊界），第一個資源點就停
function E.resources(rects, cfg)
    if not cfg.avoidResources then return nil end
    local R = resourceApi()
    if R == nil then return nil end
    for _, rect in ipairs(rects) do
        local ok, code, detail = pcall(queryResources, R, rect, cfg)
        if not ok then
            MSH.Audit.throttled("EXCL|resource", 60000, "INTERNAL_ERROR",
                { code = CODE.RESOURCE_ERROR, detail = tostring(code) }, getTimestampMs())
            return CODE.RESOURCE_ERROR
        end
        if code ~= nil then return code, detail end
    end
    return nil
end

function E.status()
    return { resourceApi = resourceApi() ~= nil, parkingApi = parkingApi() ~= nil }
end

-- 房間資料模式開服就先開始背景掃描（MiniMap 守衛範本 addon-api.md:803-804；不呼叫也行，第一次查詢回 pending）
MSH.Srv.hook("serverStarted", "exclusionsPrepare", function()
    local R = resourceApi()
    if R == nil then return end
    local cfg = MSH.Settings.get()
    if cfg.avoidResources and cfg.resourceRule == RULE.ROOMS then R.prepare("rooms") end
end)
