-- MinidoracatSafehouse/Exclusions.lua：道路／資源點排除，建立確認當下判定一次（計畫 §8.1–8.3）。
-- 道路＝地面層地板圖塊（只看 getFloor，路緣、標線等覆蓋圖掛在 attachedAnimSprite、不看：CellLoader.java:256-264）；
-- 自家車道放寬（使用者 2026-10-10 裁定 driveway、parkingsrc）：住宅外框＋roadMargin＋2 格內只有主要道路與 MiniMap 停車場算路。
-- 資源點＝MiniMap `MinidoracatMiniMapResourceAPI.buildingsIn`；MiniMap 缺席或版本不符＝不擋、設定隱藏（§8.2）。
-- 成本（§12.4）：每格只讀一次、遇到第一個違規就停；配置只隨請求（住宅數、停車區數）成長，不逐格建表。
-- 回傳一律 nil（通過）或 code, detail：ROAD { x, y, kind }、NOT_LOADED { x, y }、RESOURCE { cat, x, y, w, h }、
-- RESOURCE_PENDING、RESOURCE_ERROR。

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

-- 範圍碰到的住宅（任一房叫 bedroom 的 BuildingDef）外框往外 d 格
local function nearZones(rect, d)
    local list = ArrayList.new()   -- 原版用例 ISWidgetCraftLogicInputControl.lua:16
    -- IsoMetaGrid.java:430-441（void，結果放進 list；所有樓層、不必載入 chunk，§2.8）
    getWorld():getMetaGrid():getRoomsIntersecting(rect.x, rect.y, rect.w, rect.h, list)
    local seen, zones = {}, {}
    for i = 0, list:size() - 1 do
        local b = list:get(i):getBuilding()               -- RoomDef.java:207-209
        if b ~= nil and not seen[b] then
            seen[b] = true
            if hasBedroom(b) then
                -- BuildingDef.java:186-209
                local x, y = b:getX(), b:getY()
                local n = #zones
                zones[n + 1], zones[n + 2] = x - d, y - d
                zones[n + 3], zones[n + 4] = x + b:getW() + d, y + b:getH() + d
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

-- ===== 道路（§8.1）=====
function E.roads(rect, cfg)
    if not cfg.avoidRoads then return nil end
    local kinds = cfg.roadKinds
    local scan = Rect.expand(rect, cfg.roadMargin)
    local cell = getCell()
    local near, lots   -- 第一次遇到非主要道路的勾選類別才查（每次 roads 最多一次）
    for y = scan.y, scan.y + scan.h - 1 do
        for x = scan.x, scan.x + scan.w - 1 do
            -- 伺服器走 ServerMap，chunk 沒載入回 nil（IsoCell.java:3190-3192）
            local sq = cell:getGridSquare(x, y, 0)
            if sq == nil then return CODE.NOT_LOADED, { x = x, y = y } end
            local floor = sq:getFloor()                   -- IsoGridSquare.java:4652（solidfloor 物件）
            local sprite = floor and floor:getSprite()    -- IsoObject.java:1999
            local kind = sprite and E.classify(sprite:getName())   -- IsoSprite.java:1980
            if kind and kinds[kind] then
                if kind ~= "main" then
                    if near == nil then
                        near = nearZones(rect, cfg.roadMargin + 2)
                        lots = #near > 0 and parkingLots(scan) or {}
                    end
                    if inAny(near, x, y) and not inAny(lots, x, y) then kind = nil end
                end
                if kind then return CODE.ROAD, { x = x, y = y, kind = kind } end
            end
        end
    end
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

function E.resources(rect, cfg)
    if not cfg.avoidResources then return nil end
    local R = resourceApi()
    if R == nil then return nil end
    local ok, code, detail = pcall(queryResources, R, rect, cfg)
    if not ok then
        MSH.Audit.throttled("EXCL|resource", 60000, "INTERNAL_ERROR",
            { code = CODE.RESOURCE_ERROR, detail = tostring(code) }, getTimestampMs())
        return CODE.RESOURCE_ERROR
    end
    return code, detail
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
