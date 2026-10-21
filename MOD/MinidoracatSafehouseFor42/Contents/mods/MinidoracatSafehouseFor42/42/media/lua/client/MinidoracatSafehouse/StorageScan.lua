-- MinidoracatSafehouse/StorageScan.lua：物品搜尋的掃描、分組、篩選與排序（使用者 2026-10-20；面板在 StoragePanel.lua）。
-- 全部在客戶端：載入範圍裡的容器內容伺服器本來就送給客戶端，沒開過的容器件數也和伺服器一樣（sh-storage-1020b），
--   所以不問伺服器。沒載入（太遠）的格子另外數，面板寫「有幾格沒載入」。
-- 掃描的地方（使用者 2026-10-20 選）：家具容器、容器裡的背包（往裡看一層）、地上的物品、停在範圍內的車。車與人形模特兒
--   身上的只能指引（walk）：車可能是別人的；模特兒身上穿的，伺服器移除時不會同步（server Storage.lua）。
--   樓層照每個 chunk 的 getMinLevel／getMaxLevel（IsoChunk.java:3106/3110，sh-storage-1020b 同一套）。
-- 分幀（使用者 2026-10-20：「記得要幫我評估是否會影響到客戶端或伺服器端的性能」）：一欄一欄掃，每個 tick 最多 BUDGET_MS
--   （sh-storperf-1020a：96×96、186 個容器、4,024 件一次掃完 38 ms；每 tick 3 ms 分 14 個 tick，最長的一個 tick 4 ms）。
-- 同名物品併成一組（顯示名稱，和玩家在物品欄看到的一樣；名稱先照 SS.nameFixer 請翻譯包修）；組裡再分「在哪裡」（place）：
--   一個容器、容器裡的一個背包、一格地上、車的一個零件。
-- 載入時不碰框架或 getPlayer（harness T.bootClient 會載入本檔）。

if not isClient() then return end

require "MinidoracatSafehouse/Contract"

local MSH = MinidoracatSafehouse
local SS = MSH.StorageScan or {}
MSH.StorageScan = SS

SS.BUDGET_MS = 3
SS.SORTS = { "name", "count", "dist" }

-- ===== 名稱 =====

-- 容器在清單上的名字：同原版戰利品視窗（ISInventoryPage.lua:1736-1741，玩家取的名字優先，再找 IGUI_ContainerTitle_<type>）
function SS.boxTitle(c)
    local custom = c:getCustomName()
    if custom ~= nil and custom ~= "" then return custom end
    local t = c:getType()
    return getTextOrNull("IGUI_ContainerTitle_" .. t) or getTextOrNull("IGUI_ContainerTitle_" .. tostring(c:getDisplayType()))
        or t
end

-- 第幾樓（z＝0 是 1 樓，同室內檢查的說法）；地下室寫地下幾樓
function SS.floorText(z)
    if z < 0 then return getText("IGUI_MSH_Storage_Basement", -z) end
    return getText("IGUI_MSH_Indoor_Floor", z + 1)
end

-- 物品分類的顯示名（原版 ISInventoryPane.lua:2532-2535 的 IGUI_ItemCat_<分類>；沒有翻譯照原字）
function SS.catText(cat)
    return getTextOrNull("IGUI_ItemCat_" .. tostring(cat)) or tostring(cat)
end

-- 伺服器組名時寫死的語言（例：屠宰的「Pork Belly (Poor Cut)」）：本體翻譯包（CatLangFor42）要玩家打開容器才換成本機
--   語言，搜尋列的多是沒打開過的容器（使用者 2026-10-21：「參考中文化那邊的作法，根據使用者語系才觸發」）。有它的
--   CatLangFor42.fixItemNames、遊戲語言不是英文時，掃到的物品先整批交給它修（打開容器時它做的同一件事，只改本機）；
--   英文玩家拿到的本來就是英文，不修也不多花時間。回 nil＝不修
function SS.nameFixer()
    local api = CatLangFor42
    if type(api) ~= "table" or type(api.fixItemNames) ~= "function" then return nil end
    if Translator.getLanguage():name() == "EN" then return nil end
    return api.fixItemNames
end

-- ===== 掃描 =====

local function addItem(out, it, at)
    local name = it:getDisplayName()
    local g = out.byName[name]
    if g == nil then
        g = { name = name, lname = string.lower(name), cat = it:getDisplayCategory() or it:getCategory(), tex = it:getTex(),
            n = 0, places = {}, byKey = {} }
        out.byName[name] = g
        out.groups[#out.groups + 1] = g
    end
    g.n = g.n + 1
    local p = g.byKey[at.key]
    if p == nil then
        p = { key = at.key, kind = at.kind, title = at.title, x = at.x, y = at.y, z = at.z, c = at.c, walk = at.walk,
            n = 0, ids = {}, dist = 0 }
        g.byKey[at.key] = p
        g.places[#g.places + 1] = p
    end
    p.n = p.n + 1
    p.ids[p.n] = it:getID()
    out.items = out.items + 1
end

-- 一批物品交給翻譯包修名稱；它出錯就這次掃描不再叫它，名稱照原樣列
local function fixNames(out, list)
    local ok, err = pcall(out.fix, list)
    if not ok then
        out.fix = nil
        MSH.log("CatLangFor42.fixItemNames failed: " .. tostring(err))
    end
end

-- 一個容器裡的東西加上背包往裡一層的（同 addContainer 列的範圍）一起修，背包的標題也用修好的名字
local function fixContainerNames(out, items, n)
    local list = {}
    for k = 0, n - 1 do
        local it = items:get(k)
        list[#list + 1] = it
        if instanceof(it, "InventoryContainer") then
            local inner = it:getInventory():getItems()
            for j = 0, inner:size() - 1 do list[#list + 1] = inner:get(j) end
        end
    end
    fixNames(out, list)
end

-- 一個容器：裡面的東西，加上背包裡的（往裡一層，背包算另一處）。沒有東西又沒人開過＝還不知道裡面有什麼
local function addContainer(out, c, key, title, kind, x, y, z, walk)
    out.containers = out.containers + 1
    local items = c:getItems()
    local n = items:size()
    if n == 0 then
        if not c:isExplored() then out.unexplored = out.unexplored + 1 end
        return
    end
    if out.fix ~= nil then fixContainerNames(out, items, n) end
    local at = { key = key, kind = kind, title = title, x = x, y = y, z = z, c = c, walk = walk }
    for k = 0, n - 1 do
        local it = items:get(k)
        addItem(out, it, at)
        if instanceof(it, "InventoryContainer") then
            local inner = it:getInventory():getItems()
            local m = inner:size()
            if m > 0 then
                local bag = { key = key .. "/" .. tostring(it:getID()), kind = "bag", x = x, y = y, z = z, c = c, walk = walk,
                    title = getText("IGUI_MSH_Storage_InBag", it:getDisplayName(), title) }
                for j = 0, m - 1 do addItem(out, inner:get(j), bag) end
            end
        end
    end
end

-- 上了鎖的（MSH.lockedFor；車：後車廂或車門鎖著、身上沒有這台的鑰匙）只算容器數與上鎖數，不列裡面的東西（2026-10-20 審查：
-- 原版只在戰利品視窗擋，列出來就等於隔空看見別人鎖起來的東西）
local function addLocked(out)
    out.containers, out.locked = out.containers + 1, out.locked + 1
end

-- 車：每個有容器的零件算一處，位置記在找到它的那格（只能指引）
local function addCar(out, v, x, y)
    local locked = (v:isTrunkLocked() or v:isAnyDoorLocked()) and out.who:getInventory():haveThisKeyId(v:getKeyId()) == nil
    for i = 0, v:getPartCount() - 1 do
        local part = v:getPartByIndex(i)
        local c = part and part:getItemContainer()
        if c ~= nil and locked then
            addLocked(out)
        elseif c ~= nil then
            local title = getText("IGUI_MSH_Storage_InCar", getText("IGUI_VehiclePart" .. c:getType()))
            addContainer(out, c, "v" .. tostring(v:getId()) .. "," .. tostring(part:getId()), title, "car", x, y, 0, true)
        end
    end
end

local function scanSquare(out, sq, x, y, z)
    local base = x .. "," .. y .. "," .. z
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        for ci = 0, o:getContainerCount() - 1 do
            local c = o:getContainerByIndex(ci)
            if c ~= nil and MSH.lockedFor(c, out.who) then
                addLocked(out)
            elseif c ~= nil then
                local walk = c:getType() == "mannequin"
                addContainer(out, c, base .. "," .. i .. "," .. ci, SS.boxTitle(c), "box", x, y, z, walk)
            end
        end
    end
    local wos = sq:getWorldObjects()
    local n = wos:size()
    if n > 0 then
        local at = { key = base .. ",f", kind = "floor", title = getText("IGUI_ContainerTitle_floor"), x = x, y = y, z = z }
        local list = {}
        for i = 0, n - 1 do
            local it = wos:get(i):getItem()
            if it ~= nil then list[#list + 1] = it end
        end
        if out.fix ~= nil and #list > 0 then fixNames(out, list) end
        for _, it in ipairs(list) do addItem(out, it, at) end
    end
    if z == 0 then
        local v = sq:getVehicleContainer()
        if v ~= nil and not out.cars[v] then
            out.cars[v] = true
            addCar(out, v, x, y)
        end
    end
end

-- 一欄（x 固定、y0..y0+h-1）：每格照所在 chunk 的樓層範圍往上下掃
local function column(out, cell, x, y0, h)
    for y = y0, y0 + h - 1 do
        local sq0 = cell:getGridSquare(x, y, 0)
        if sq0 == nil then
            out.unloaded = out.unloaded + 1
        else
            local ch = sq0:getChunk()
            local lo, hi = 0, 0
            if ch ~= nil then lo, hi = ch:getMinLevel(), ch:getMaxLevel() end
            for z = lo, hi do
                local sq = z == 0 and sq0 or cell:getGridSquare(x, y, z)
                if sq ~= nil then scanSquare(out, sq, x, y, z) end
            end
        end
    end
end

-- 開始掃一間（rects＝這間的各塊；who＝看的人，判斷鎖）。之後每個 tick 叫 SS.step，掃完回 true、job.out 是結果
function SS.start(rects, who)
    local out = { groups = {}, byName = {}, cars = {}, who = who, fix = SS.nameFixer(), items = 0, containers = 0,
        unloaded = 0, unexplored = 0, locked = 0 }
    return { rects = rects, ri = 1, col = 0, out = out }
end

-- 掃到這個 tick 的時間用完（budget 毫秒，預設 BUDGET_MS）；掃完回 true（組依名稱排好）
function SS.step(job, budget)
    if job.done then return true end
    local cell, t0, limit = getCell(), getTimestampMs(), budget or SS.BUDGET_MS
    while job.ri <= #job.rects do
        local r = job.rects[job.ri]
        if job.col >= r.w then
            job.ri, job.col = job.ri + 1, 0
        else
            column(job.out, cell, r.x + job.col, r.y, r.h)
            job.col = job.col + 1
            if getTimestampMs() - t0 >= limit then return false end
        end
    end
    local out = job.out
    out.byName, out.cars, out.who, out.fix = nil, nil, nil, nil
    for _, g in ipairs(out.groups) do g.byKey = nil end   -- 只有掃描時要用
    MSH.sortSafe(out.groups, function(a, b) return a.lname < b.lname end)
    job.done = true
    return true
end

-- ===== 距離、分類、樓層 =====

-- 每一處離 (px, py) 幾格（棋盤距離，不管樓層）。回 true＝有任何一處變了
function SS.measure(out, px, py)
    local changed = false
    for _, g in ipairs(out.groups) do
        for _, p in ipairs(g.places) do
            local d = math.max(math.abs(p.x - px), math.abs(p.y - py))
            if d ~= p.dist then p.dist, changed = d, true end
        end
    end
    return changed
end

-- 這次掃到的分類（下拉選單）：{ id, n }，依顯示名排序
function SS.cats(out)
    local by, list = {}, {}
    for _, g in ipairs(out.groups) do
        local c = by[g.cat]
        if c == nil then
            c = { id = g.cat, n = 0, label = SS.catText(g.cat) }
            by[g.cat] = c
            list[#list + 1] = c
        end
        c.n = c.n + g.n
    end
    MSH.sortSafe(list, function(a, b) return a.label < b.label end)
    return list
end

-- 這次掃到的樓層（由低到高）
function SS.floors(out)
    local seen, list = {}, {}
    for _, g in ipairs(out.groups) do
        for _, p in ipairs(g.places) do
            if not seen[p.z] then
                seen[p.z] = true
                list[#list + 1] = p.z
            end
        end
    end
    MSH.sortSafe(list, function(a, b) return a < b end)
    return list
end

-- ===== 篩選、排序、清單列 =====

-- 依 mode 排序（name／count／dist）；out.groups 已依名稱排好，合併排序穩定，同數量、同距離照名稱。回新的陣列
function SS.sorted(out, mode)
    local list = {}
    for i, g in ipairs(out.groups) do list[i] = g end
    if mode == "count" then
        MSH.sortSafe(list, function(a, b) return a.n > b.n end)
    elseif mode == "dist" then
        for _, g in ipairs(list) do
            local best = nil
            for _, p in ipairs(g.places) do
                if best == nil or p.dist < best then best = p.dist end
            end
            g.near = best or 0
        end
        MSH.sortSafe(list, function(a, b) return a.near < b.near end)
    end
    return list
end

-- 一組在篩選下的樣子：{ g, n（件數）, places（符合樓層的各處，近的在前）, dist（最近幾格）}
local function view(g, z)
    local places, n = {}, 0
    for _, p in ipairs(g.places) do
        if z == nil or p.z == z then
            places[#places + 1] = p
            n = n + p.n
        end
    end
    if #places == 0 then return nil end
    MSH.sortSafe(places, function(a, b) return a.dist < b.dist end)
    return { g = g, n = n, places = places, dist = places[1].dist }
end

-- 篩選（只比名稱）：q＝小寫的關鍵字（"" 不比）、cat＝分類（nil 全部）、z＝樓層（nil 全部）；照 sorted 的順序。
-- 只看一層時件數與距離只算那一層，依數量、距離排的要照這一層的值重排（不然二樓 1 件的會排在二樓 10 件的前面，
-- 2026-10-20 審查）；sorted 是穩定排序的結果，重排也穩定，同值照原本的順序
function SS.views(sorted, q, cat, z, mode)
    local out = {}
    for _, g in ipairs(sorted) do
        if (q == "" or string.find(g.lname, q, 1, true) ~= nil) and (cat == nil or g.cat == cat) then
            local v = view(g, z)
            if v ~= nil then out[#out + 1] = v end
        end
    end
    if z ~= nil and mode == "count" then
        MSH.sortSafe(out, function(a, b) return a.n > b.n end)
    elseif z ~= nil and mode == "dist" then
        MSH.sortSafe(out, function(a, b) return a.dist < b.dist end)
    end
    return out
end

-- 玩家換了格子：各組的最近距離跟著更新（不重排，免得清單在眼前跳動）
function SS.viewDist(views)
    for _, v in ipairs(views) do
        local best = nil
        for _, p in ipairs(v.places) do
            if best == nil or p.dist < best then best = p.dist end
        end
        v.dist = best or 0
    end
end

-- 清單列：每組一列；展開的那組（open＝它的 g）底下接各處
function SS.rows(views, open)
    local rows = {}
    for _, v in ipairs(views) do
        rows[#rows + 1] = { kind = "group", v = v }
        if v.g == open then
            for _, p in ipairs(v.places) do rows[#rows + 1] = { kind = "place", v = v, p = p } end
        end
    end
    return rows
end

-- 小寫、去頭尾空白的關鍵字
function SS.query(text)
    return string.lower(MSH.trim(text or ""))
end
