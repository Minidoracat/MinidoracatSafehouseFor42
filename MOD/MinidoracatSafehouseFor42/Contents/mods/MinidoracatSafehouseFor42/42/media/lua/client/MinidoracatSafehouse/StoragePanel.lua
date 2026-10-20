-- MinidoracatSafehouse/StoragePanel.lua：物品搜尋面板（使用者 2026-10-20：「能夠搜尋安全屋範圍內的容器內的東西，玩家可以在 UI 上
-- 篩選、分類、搜尋，管理員可以設置能直接遠距離拿，或者只提供箭頭指向該容器」；設計稿 temp/plan-storage-1020，裁定見
-- decisions.md 2026-10-20）。入口：管理視窗詳情標題列〔搜尋物品〕（沙盒 StorageMode 不是「關閉」、這間 active）。
-- 掃描、分組、篩選在 StorageScan.lua（客戶端自己掃，不問伺服器）；這裡排版、帶路、拿取。
-- 效能（使用者 2026-10-20：「記得要幫我評估是否會影響到客戶端或伺服器端的性能」）：面板關著又沒在帶路時不掛任何事件；
--   掃描分幀（StorageScan.BUDGET_MS）；開著時每 DIST_MS 看一次玩家換了格子沒有，換了才重算距離；帶路每 GUIDE_MS 看一次。
-- 帶路：原版方向箭頭（WorldMarkers addDirectionArrow，放大到 ARROW px；在畫面內停在目標上方、畫面外貼著邊緣、別層換上下樓
--   圖示）；人物旁邊再加一個繞著人物轉、指向目標的箭頭（addPlayerHomingPoint，原版採集與教學用的那個；使用者 2026-10-20：
--   「人物旁邊也要有方向箭頭指引吧」）；同一層再加地面圈（別層畫圈會浮在半空，sh-storage-1020a）。走到 1 格內、同一層就結束，
--   戰利品視窗切到那個容器（ISInventoryPage:setForceSelectedContainer）；面板關了也繼續帶，按〔停止指引〕或 GUIDE_MAX_MS 後結束。
-- 遠距拿取（沙盒「可以遠距拿」、有 TAKE、站在這間裡）：storageBegin 回原版搬運時間，本地跑一個只在客戶端的計時動作
--   （類別沒有 complete，LuaTimedActionNew.java:78-80；走動就中斷），跑完送 storageTake（兩段的原因見 server Storage.lua）。
-- 清單或網格（使用者 2026-10-21：「希望能支持經濟系統那樣的切換網格顯示」；設計稿 temp/plan-storage-grid-1020，三項照建議）：
--   搜尋框右邊〔清單｜網格〕，網格一組一格（框架 rev 22 的 TileGrid；框架沒有就只有清單）。點一格選那一組，只有一處就直接選它，
--   放在好幾處時網格下面列出各處讓玩家挑。換顯示方式不重掃，搜尋字、篩選與選取都留著；記在 ModOptions `StorageGrid`
--   （和地面範圍同一頁，第一次是清單）。
-- 框架缺席或太舊：管理視窗不給〔搜尋物品〕（P.available），面板也不開。
-- 載入時不碰 ISPanel、框架或 getPlayer（harness T.bootClient 會載入本檔）；ISPanel 與計時動作的子類在第一次用到時才建。

if not isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Settings"
require "MinidoracatSafehouse/Client"
require "MinidoracatSafehouse/StorageScan"
require "MinidoracatSafehouse/Ranges"   -- ModOptions 那一頁由它建（下面的 StorageGrid 加在同一頁）

local MSH = MinidoracatSafehouse
local first = MSH.StoragePanel == nil
local P = MSH.StoragePanel or {}
MSH.StoragePanel = P
local SS = MSH.StorageScan

P.CAPS = { "window", "controls", "dialog", "virtualList", "dropdown", "focus", "textWrap" }
P.ROWS = 9                -- 清單高度（列）；固定高度，打字篩選時視窗不跳
P.MIN_ROWS = 3            -- 畫面放不下整個視窗時清單最少留幾列
P.PLACE_ROWS = 4          -- 網格下面的各處最多排幾列（再多自己捲）
P.TILE_ICON = 32          -- 網格一格的物品圖（原版物品圖 32 px，不放大才清楚）
P.TILE_MIN_W = 96         -- 網格一格最窄多少（照字型再加寬，P.tileWidth）
P.DIST_MS = 500           -- 多久看一次玩家換了格子沒有（距離、能不能拿、幾分鐘前掃描）
P.GUIDE_MS = 250          -- 帶路多久看一次到了沒有
P.GUIDE_MAX_MS = 600000   -- 帶路最多 10 分鐘
P.ARROW = 48              -- 方向箭頭大小（預設 32 在畫面邊緣很小，sh-storage-1020a）
P.GOLD = { r = 1, g = 0.82, b = 0.2 }
P.RESCAN_MS = 400         -- 拿完多久後重掃（伺服器的移除封包先到）
P.LOOT_MS = 3000          -- 到了以後讓戰利品視窗切過去的時間

local PAD, GAP, ICON = 12, 6, 16
local FONT = UIFont and UIFont.Small

function P.available()
    return MSH.Client.ui(P.CAPS) ~= nil
end

-- 網格要框架的 TileGrid（API rev 22）；沒有就只有清單，不出〔清單｜網格〕
function P.gridOK(UI)
    return UI ~= nil and UI.TileGrid ~= nil and UI.CAPABILITIES ~= nil and UI.CAPABILITIES.tileGrid == true
end

-- 上次用清單還是網格（使用者 2026-10-21 裁定：記住，第一次是清單）：ModOptions 和地面範圍同一頁，ESC 選項也改得到；
-- 選項要在檔案載入時登記（Ranges.lua 同一段的原因）。沒有 PZAPI 時只記到這次遊戲結束
if first and PZAPI and PZAPI.ModOptions then
    local opts = PZAPI.ModOptions:getOptions(MSH.Ranges.OPTIONS_ID)
    if opts ~= nil then
        P.gridOpt = opts:addTickBox("StorageGrid", "IGUI_MSH_Options_StorageGrid", false, "IGUI_MSH_Options_StorageGrid_tooltip")
    end
end

function P.gridPref()
    if P.gridOpt ~= nil then return P.gridOpt:getValue() == true end
    return P.sessionGrid == true
end

function P.setGridPref(on)
    if P.gridOpt == nil then
        P.sessionGrid = on
        return
    end
    P.gridOpt:setValue(on)
    local ok, err = pcall(PZAPI.ModOptions.save, PZAPI.ModOptions)
    if not ok then MSH.log("ModOptions save failed: " .. tostring(err)) end
end

-- 事件只在開著或帶路時掛（使用者 2026-10-15：「只有需要查的時候才查」，2026-10-20 同樣要求評估效能）
P.fnTick = P.fnTick or function() MSH.StoragePanel.tick() end
local function hook(on)
    if (P.hooked == true) == on then return end
    P.hooked = on
    if on then Events.OnTick.Add(P.fnTick) else Events.OnTick.Remove(P.fnTick) end
end

-- ===== 文字（harness 測）=====

function P.distText(d)
    if d <= 1 then return getText("IGUI_MSH_Indoor_Here") end
    return getText("IGUI_MSH_Storage_Tiles", d)
end

local function join(a, b)
    if b == nil then return a end
    return a .. getText("IGUI_MSH_Storage_Sep") .. b
end

-- 一處在哪裡，分兩段：樓層、距離。距離只算水平：別層的就算在正上方也不是「就在你旁邊」，只寫樓層（距離 nil；pz＝玩家那一層）
local function placeWhere(p, pz)
    if p.z ~= pz and p.dist <= 1 then return SS.floorText(p.z), nil end
    return SS.floorText(p.z), P.distText(p.dist)
end

-- 一處在哪裡：「1 樓 · 6 格」
function P.whereText(p, pz)
    return join(placeWhere(p, pz))
end

-- 一組在哪裡，分兩段：只有一處寫樓層與距離，多處寫幾處與最近幾格（最近的在別層正上下方時只有幾處）。
-- near：多處的距離寫「最近 N 格」（清單）；網格一格窄，只寫「N 格」（設計稿 2026-10-21 的「3 處 · 2 格」）
function P.groupWhere(v, pz, near)
    if #v.places == 1 then return placeWhere(v.places[1], pz) end
    local out = getText("IGUI_MSH_Storage_Places", #v.places)
    if v.dist > 1 then
        return out, getText(near and "IGUI_MSH_Storage_Nearest" or "IGUI_MSH_Storage_Tiles", v.dist)
    end
    for _, p in ipairs(v.places) do
        if p.z == pz and p.dist <= 1 then return out, getText("IGUI_MSH_Indoor_Here") end
    end
    return out, nil
end

-- 組那一列右邊：「3 個地方 · 最近 2 格」
function P.groupMeta(v, pz)
    return join(P.groupWhere(v, pz, true))
end

-- 選取那一行：「釘子 ×30 · 廚房櫥櫃 · 1 樓 · 6 格」
function P.selText(g, p, pz)
    local sep = getText("IGUI_MSH_Storage_Sep")
    return getText("IGUI_MSH_Storage_NameCount", g.name, p.n) .. sep .. p.title .. sep .. P.whereText(p, pz)
end

-- 不能遠距拿的原因：nil＝可以；""＝按鈕停用但不另外寫（還沒選、正在拿）；其他＝寫在按鈕下面
function P.takeBlock(m, p)
    if p == nil or P.taking ~= nil then return "" end
    if p.walk then return getText("IGUI_MSH_Storage_WalkOnly") end
    if not MSH.hasBit(m.bits, MSH.SHARE.TAKE) then
        return getText("IGUI_MSH_Perm_Denied", getText("IGUI_MSH_Share_Bit_TAKE"))
    end
    if not m.inside then return getText("IGUI_MSH_Storage_StandInside") end
    return nil
end

-- 要拿幾個：1 到 max 的整數；不合回 nil
function P.count(input, max)
    local n = tonumber(input)
    if n == nil or n ~= math.floor(n) or n < 1 or n > max then return nil end
    return n
end

-- 背包還能放幾公斤（同伺服器 Storage.plan 的算法）
function P.freeWeight(player)
    local inv = player:getInventory()
    return math.max(0, inv:getEffectiveCapacity(player) - inv:getCapacityWeight())
end

function P.kgText(w)
    return string.format("%.1f", math.floor(w * 10) / 10)
end

-- 拿完的結果：「已拿到 12 個釘子。背包滿了，另外 18 個還在廚房櫥櫃。」
function P.resultText(t, res)
    local got = res.got or 0
    local full = (t.full or 0) + (res.full or 0)
    local gone = (t.gone or 0) + (res.gone or 0) + math.max(0, (res.n or got) - got)
    local parts = { getText("IGUI_MSH_Storage_Got", got, t.name) }
    if full > 0 then parts[#parts + 1] = getText("IGUI_MSH_Storage_GotFull", full, t.title) end
    if gone > 0 then parts[#parts + 1] = getText("IGUI_MSH_Storage_GotGone", gone) end
    return table.concat(parts, " ")
end

-- ===== 掃描、篩選 =====

function P.changed(m)
    if m ~= nil and m.view ~= nil then P.layout(m.view) end
end

function P.refresh()
    P.changed(P.model)
end

function P.say(m, text, token)
    m.msg, m.msgToken = text, token or "text"
    P.changed(m)
end

-- 一句結果：面板開著寫在面板裡，關著用 Toast
function P.report(text, token)
    local m = P.model
    if m ~= nil and m.view ~= nil then return P.say(m, text, token) end
    MSH.Client.toast(text)
end

function P.reportCode(res)
    local reason, action = MSH.Client.codeText(res.code)
    if res.code == MSH.CODE.PERM_DENIED then
        reason = getText("IGUI_MSH_Perm_Denied", getText("IGUI_MSH_Share_Bit_TAKE"))
    end
    P.report(action and (reason .. " " .. action) or reason, "errorText")
end

function P.rescan(m)
    m.job = SS.start(m.rects, getSpecificPlayer(0))
    m.rescanAt = nil
    P.changed(m)
end

-- 清單列與選取跟著目前的篩選重建；選的那處不在清單上就取消。網格也讀這裡：選的那格（第幾組），和網格下面那組的各處
-- （就是 m.rows 裡接在那組後面的各列，同一批列）
function P.rebuild(m)
    m.rows = SS.rows(m.views, m.open)
    local selRow, openRow, tile, groups = nil, nil, nil, 0
    for i, r in ipairs(m.rows) do
        if r.kind == "group" then
            groups = groups + 1
            if r.v.g == m.open then openRow, tile = i, groups end
        elseif r.p == m.sel then
            selRow = i
        end
    end
    if openRow == nil then m.open = nil end
    if selRow == nil then m.sel = nil end
    m.selIndex = selRow or openRow
    m.tileIndex, m.openView, m.placeRows, m.placeIndex = tile, nil, {}, nil
    if openRow ~= nil then
        m.openView = m.rows[openRow].v
        for i = openRow + 1, openRow + #m.openView.places do m.placeRows[#m.placeRows + 1] = m.rows[i] end
        if selRow ~= nil then m.placeIndex = selRow - openRow end
    end
end

-- 只看一層時從依名稱排好的組開始（SS.views 照那一層的件數、距離重排，同值照名稱）
function P.refilter(m)
    local base = m.sorted
    if m.z ~= nil and m.out ~= nil then base = m.out.groups end
    m.views = base ~= nil and SS.views(base, m.q, m.cat, m.z, m.sort) or {}
    P.rebuild(m)
end

function P.resort(m)
    m.sorted = m.out ~= nil and SS.sorted(m.out, m.sort) or nil
    P.refilter(m)
end

-- 掃完：算距離、分類與樓層選項、照名字找回展開的那組與選的那處（拿完重掃時不會跳回最上面）
function P.scanned(m, now)
    local out = m.job.out
    m.job, m.out, m.scannedAt, m.minute = nil, out, now, 0
    local p = getSpecificPlayer(0)
    if p ~= nil then SS.measure(out, math.floor(p:getX()), math.floor(p:getY())) end
    m.cats, m.floors = SS.cats(out), SS.floors(out)
    local hasCat, hasFloor = false, false
    for _, c in ipairs(m.cats) do if c.id == m.cat then hasCat = true end end
    for _, z in ipairs(m.floors) do if z == m.z then hasFloor = true end end
    if not hasCat then m.cat = nil end
    if not hasFloor then m.z = nil end
    local openName, selKey = m.open and m.open.name, m.sel and m.sel.key
    m.open, m.sel = nil, nil
    for _, g in ipairs(out.groups) do
        if g.name == openName then
            m.open = g
            for _, pl in ipairs(g.places) do if pl.key == selKey then m.sel, m.selGroup = pl, g end end
        end
    end
    if m.view ~= nil then P.syncOptions(m.view) end
    P.resort(m)
    P.changed(m)
end

-- 玩家換了格子：距離、在不在範圍裡；掃描的分鐘數、自己的權限（清單重抓後，例如屋主拿掉遠距拿取）變了也重排
function P.where(m, now)
    local p = getSpecificPlayer(0)
    if p == nil then return end
    local relayout = false
    local minute = m.scannedAt ~= nil and math.floor((now - m.scannedAt) / 60000) or nil
    if minute ~= m.minute then m.minute, relayout = minute, true end
    local row = MSH.Client.claims.byId[m.claimId]
    if row ~= nil then m.listed = true end
    -- 被移出名單（看過這列、清單重抓後沒了）或這間不再是 active：伺服器本來就會拒絕，面板收起、不開回管理視窗（2026-10-20 審查）
    if (row == nil and m.listed) or (row ~= nil and row.lifecycle ~= nil and row.lifecycle ~= MSH.LIFECYCLE.ACTIVE) then
        m.fromManager = false
        return P.close(m)
    end
    if row ~= nil and MSH.isInt(row.bits) and row.bits ~= m.bits then m.bits, relayout = row.bits, true end
    local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
    if px ~= m.px or py ~= m.py or pz ~= m.pz then
        if pz ~= m.pz then relayout = true end   -- 「就在你旁邊」只算同一層（P.whereText）
        m.px, m.py, m.pz = px, py, pz
        local inside = MSH.Rect.listContains(m.rects, px, py)
        if inside ~= m.inside then m.inside, relayout = inside, true end
        if m.out ~= nil and SS.measure(m.out, px, py) then
            SS.viewDist(m.views)
            relayout = true
        end
    end
    if relayout then P.changed(m) end
end

function P.tick()
    local now = getTimestampMs()
    local m = P.model
    if m ~= nil then
        if m.job ~= nil and SS.step(m.job) then P.scanned(m, now) end
        if m.rescanAt ~= nil and now >= m.rescanAt then P.rescan(m) end
        if now >= (m.whereAt or 0) then
            m.whereAt = now + P.DIST_MS
            P.where(m, now)
        end
    end
    local g = P.guide
    if g ~= nil and now >= g.nextAt then
        g.nextAt = now + P.GUIDE_MS
        P.guideTick(g, now)
    end
end

-- 點一列：組＝展開／收起（只有一處就直接選它）；處＝選它
function P.pick(m, row)
    if row == nil then return end
    if row.kind == "group" then
        local g = row.v.g
        if m.open == g then
            m.open, m.sel = nil, nil
        else
            m.open, m.selGroup = g, g
            m.sel = #row.v.places == 1 and row.v.places[1] or nil
        end
    else
        m.open, m.sel, m.selGroup = row.v.g, row.p, row.v.g
    end
    m.msg = nil
    P.rebuild(m)
    P.changed(m)
end

-- 點一格（滑鼠、Enter、手把 A）：選那一組，再點不收起（清單點已展開的組才收起）；只有一處就直接選它，
-- 已經選的那處還在這組裡就留著
function P.pickTile(m, view)
    if view == nil then return end
    local g = view.g
    if m.open ~= g then m.sel = nil end
    m.open, m.selGroup = g, g
    if #view.places == 1 then m.sel = view.places[1] end
    m.msg = nil
    P.rebuild(m)
    P.changed(m)
end

-- 換顯示方式：不重掃、不送伺服器，搜尋字、篩選與選取都不動；換過去的那邊捲到選的那組（同 Economy 的網格）
function P.setGrid(m, on)
    if m.grid == on then return end
    m.grid = on
    P.setGridPref(on)
    P.changed(m)
    local v = m.view
    if v == nil then return end
    if on and m.tileIndex ~= nil then v.grid:scrollToIndex(m.tileIndex) end
    if not on and m.selIndex ~= nil then v.list:scrollToIndex(m.selIndex) end
end

function P.setQuery(m, text)
    local q = SS.query(text)
    if q == m.q then return end
    m.q = q
    P.refilter(m)
    P.changed(m)
end

function P.clearQuery(m)
    if m.view ~= nil then m.view.search:setText("") end
    P.setQuery(m, "")
end

function P.setFilter(m, key, id)
    if id == "all" then id = nil end
    if m[key] == id then return end
    m[key] = id
    P.refilter(m)
    P.changed(m)
end

function P.setSort(m, id)
    if m.sort == id then return end
    m.sort = id
    P.resort(m)
    P.changed(m)
end

-- ===== 帶路 =====

-- 地面圈只畫在同一層（別層會浮在半空，sh-storage-1020a）
local function ring(g, on)
    if (g.ring ~= nil) == on then return end
    local wm = getWorldMarkers()
    if on then
        local sq = getCell():getGridSquare(g.x, g.y, g.z)
        if sq ~= nil then g.ring = wm:addGridSquareMarker(sq, P.GOLD.r, P.GOLD.g, P.GOLD.b, true, 0.8) end
    else
        wm:removeGridSquareMarker(g.ring)
        g.ring = nil
    end
end

function P.stopGuide(quiet)
    local g = P.guide
    if g == nil then return end
    P.guide = nil
    local wm = getWorldMarkers()
    if g.arrow ~= nil then wm:removeDirectionArrow(g.arrow) end
    if g.homing ~= nil then wm:removeHomingPoint(g.homing) end
    if g.ring ~= nil then wm:removeGridSquareMarker(g.ring) end
    hook(P.model ~= nil)
    if not quiet then P.refresh() end
end

-- 到了：收掉標示，戰利品視窗切到那個容器（地上的切到地上；背包裡的切到裝它的容器）
function P.arrive(g)
    P.stopGuide(true)
    local c = g.c
    if g.kind == "floor" and ISInventoryPage ~= nil and ISInventoryPage.GetFloorContainer ~= nil then
        c = ISInventoryPage.GetFloorContainer(0)
    end
    local loot = getPlayerLoot and getPlayerLoot(0)
    if loot ~= nil and c ~= nil then
        loot:setForceSelectedContainer(c, P.LOOT_MS)
        loot:refreshBackpacks()   -- 只記下要切的容器，真的切要等 refreshBackpacks（原版在轉向、換格子時才叫，ISInventoryPage.lua:501-507）
    end
    P.report(getText("IGUI_MSH_Storage_Arrived", g.title), "text")
end

function P.guideTick(g, now)
    local p = getSpecificPlayer(0)
    if p == nil or p:isDead() or now > g.endAt then return P.stopGuide() end
    local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
    ring(g, pz == g.z)
    local d = math.max(math.abs(px - g.x), math.abs(py - g.y))
    if pz == g.z and d <= 1 then return P.arrive(g) end
    -- 人物旁的箭頭只看平面（引擎不管樓層）：目標在正上下方時它沒有方向可指，收起來，交給方向箭頭的上下樓圖示
    if g.homing ~= nil then g.homing:setActive(d > 1) end
    if d ~= g.d or pz ~= g.pz then
        g.d, g.pz = d, pz
        P.refresh()
    end
end

function P.startGuide(m, p)
    local player = getSpecificPlayer(0)
    if player == nil or p == nil then return end
    P.stopGuide(true)
    local now = getTimestampMs()
    local g = { x = p.x, y = p.y, z = p.z, title = p.title, kind = p.kind, c = p.c, endAt = now + P.GUIDE_MAX_MS, nextAt = 0 }
    local c = P.GOLD
    local wm = getWorldMarkers()
    g.arrow = wm:addDirectionArrow(player, g.x, g.y, g.z, "dir_arrow_up", c.r, c.g, c.b, 1)
    if g.arrow ~= nil then
        g.arrow:setRenderWidth(P.ARROW)
        g.arrow:setRenderHeight(P.ARROW)
    end
    -- 不往目標飄（homeOnTarget＝false）：目標上方已經有方向箭頭；目標比繞圈的半徑還近時，引擎照樣把它移到目標方向的 3/4 處
    -- （WorldMarkers.java:425-435）。放大到 ARROW：預設 32 px 的原版三角形在名字標籤旁幾乎看不出來（sh-homing-1020a）
    g.homing = wm:addPlayerHomingPoint(player, g.x, g.y, "arrow_triangle", c.r, c.g, c.b, 1, false, 0)
    if g.homing ~= nil then
        g.homing:setRenderWidth(P.ARROW)
        g.homing:setRenderHeight(P.ARROW)
    end
    P.guide = g
    m.msg = nil
    hook(true)
    P.guideTick(g, now)
    P.changed(m)
end

-- ===== 遠距拿取 =====

-- 只在客戶端的計時動作（類別沒有 complete，LuaTimedActionNew.java:78-80）；走動、跑步、瞄準就中斷（ISBaseTimedAction:new）。
-- 還沒開始就被取消（排在別的動作後面時清掉佇列）走 forceCancel，和中斷一樣收尾（ISTimedActionQueue.lua:107-112）
function P.actionClass()
    if P.Action ~= nil then return P.Action end
    local A = ISBaseTimedAction:derive("MinidoracatSafehouseStorageTake")
    function A:isValid() return true end
    function A:start()
        self:setActionAnim("Loot")
        self.character:SetVariable("LootPosition", "Mid")
        self.character:reportEvent("EventLootItem")
    end
    function A:stop()
        ISBaseTimedAction.stop(self)
        MSH.StoragePanel.onActionStopped(self.take)
    end
    function A:forceCancel()
        MSH.StoragePanel.onActionStopped(self.take)
    end
    function A:perform()
        ISBaseTimedAction.perform(self)
        MSH.StoragePanel.onActionDone(self.take)
    end
    -- 時間就是伺服器算的，不再乘心情、醉酒、手傷與體溫（原版 MP 搬東西的時間也由伺服器決定、不乘這些；乘了會超過伺服器
    -- 等的期限，2026-10-20 審查）
    function A:adjustMaxTime(maxTime) return maxTime end
    -- ms：伺服器算的原版搬運時間；1 單位 20 ms（Transaction.java:440），客戶端每秒走 48 單位，比伺服器要的晚一點
    function A:new(character, ms, take)
        local o = ISBaseTimedAction.new(self, character)
        o.maxTime = math.max(1, math.ceil(ms / 20))
        o.take = take
        return o
    end
    P.Action = A
    return A
end

function P.askTake(m)
    local v, p, g = m.view, m.sel, m.selGroup
    local player = getSpecificPlayer(0)
    if v == nil or p == nil or g == nil or player == nil or P.takeBlock(m, p) ~= nil then return end
    local limit = MSH.LIMIT.STORAGE_PICKS
    local max = math.min(p.n, limit)
    v.UI.Dialog.show(MSH.Client.windowOpts(v.UI, { title = getText("IGUI_MSH_Storage_TakeTitle", g.name), theme = v.theme,
        text = getText("IGUI_MSH_Storage_TakeAsk", p.title, p.n, P.kgText(P.freeWeight(player)), limit),
        input = { text = tostring(max), onlyNumbers = true },
        confirmText = getText("IGUI_MSH_Storage_TakeOk"), cancelText = getText("UI_Cancel"),
        onResult = function(ok, input) if ok then P.begin(m, p, g.name, input) end end }))
end

function P.begin(m, p, name, input)
    local max = math.min(p.n, MSH.LIMIT.STORAGE_PICKS)
    local n = P.count(input, max)
    if n == nil then return P.say(m, getText("IGUI_MSH_Storage_BadCount", max), "errorText") end
    if P.takeBlock(m, p) ~= nil then return end
    local ids = {}
    for i = 1, n do ids[i] = p.ids[i] end
    local t = { claimId = m.claimId, name = name, title = p.title, n = n }
    P.taking = t
    m.msg = nil
    t.rid = MSH.Client.send("storageBegin", { claimId = m.claimId, x = p.x, y = p.y, z = p.z, ids = ids },
        function(res) MSH.StoragePanel.onBegin(t, res) end, { mutation = true })
    if t.rid == nil then P.taking = nil end
    P.changed(m)
end

-- 回覆 10 秒還沒到：mutation 的結果之後照樣會來（Client.send）。同一 requestId 重送一次（回覆掉了的話伺服器回快取的結果、
-- 不會再搬一次，Client.retry），先等；過期才當成沒拿
local function waiting(res)
    if res.code ~= "NO_REPLY" or res.pending ~= true or res.expired then return false end
    MSH.Client.retry(res.requestId)
    return true
end

function P.onBegin(t, res)
    if P.taking ~= t or waiting(res) then return end
    local player = getSpecificPlayer(0)
    if not res.ok or player == nil then
        P.taking = nil
        return P.reportCode(res)
    end
    t.n, t.full, t.gone = res.n, res.full or 0, res.gone or 0
    -- 原版不收的時候（睡著、拖著屍體）回 nil，不會跑也不會收尾（ISTimedActionQueue.lua:157-168）
    if ISTimedActionQueue.add(P.actionClass():new(player, res.durMs, t)) == nil then
        P.taking = nil
        return P.reportCode({ code = MSH.CODE.TAKE_STOPPED })
    end
    P.refresh()
end

-- 計時動作跑完：送完成（伺服器自己再比一次時間與位置）
function P.onActionDone(t)
    if P.taking ~= t then return end
    t.rid = MSH.Client.send("storageTake", { claimId = t.claimId }, function(res) MSH.StoragePanel.onTaken(t, res) end,
        { mutation = true })
    if t.rid == nil then P.taking = nil end
end

function P.onActionStopped(t)
    if P.taking ~= t then return end
    P.taking = nil
    P.reportCode({ code = MSH.CODE.TAKE_STOPPED })
end

function P.onTaken(t, res)
    if P.taking ~= t or waiting(res) then return end
    P.taking = nil
    local m = P.model
    if m ~= nil and m.claimId == t.claimId then m.rescanAt = getTimestampMs() + P.RESCAN_MS end
    if not res.ok then return P.reportCode(res) end
    P.report(P.resultText(t, res), "text")
end

-- ===== 畫面 =====

local V = nil
local function classes()
    if V ~= nil then return V end
    V = {}
    V.Body = ISPanel:derive("MinidoracatSafehouseStorageBody")
    function V.Body:render() P.draw(self, self.view) end
    -- 清單列：截斷時 hover 顯示全文（借原版 ISButton:updateTooltip，同室內檢查的清單列）
    V.Cell = ISPanel:derive("MinidoracatSafehouseStorageCell")
    function V.Cell:prerender()
        if self.tooltip or self.tooltipUI then ISButton.updateTooltip(self) end
    end
    function V.Cell:render() P.drawCell(self) end
    return V
end

-- 一段文字（換行後逐行記下；只在狀態改變時重建，render 只畫）
local function para(v, text, token, y, icon)
    local indent = icon ~= nil and (ICON + 4) or 0
    for i, line in ipairs(v.UI.Text.wrap(text, v.innerW - indent, FONT)) do
        v.lines[#v.lines + 1] = { text = line, token = token, icon = i == 1 and icon or nil, x = PAD + indent, y = y }
        y = y + v.lineH
    end
    return y + 2
end

-- 一列控制項，放不下換行
local function row(v, list, y)
    local x, h = PAD, 0
    for _, b in ipairs(list) do
        if x > PAD and x + b.width > v.w - PAD then x, y, h = PAD, y + h + GAP, 0 end
        b:setX(x)
        b:setY(y)
        b:setVisible(true)
        x, h = x + b.width + GAP, math.max(h, b.height)
    end
    return y + h + GAP
end

-- 篩選列：「分類 [全部 (176)]　樓層 [全部]　排序 [名稱]」，放不下換行
local function filters(v, y)
    local x, dy = PAD, math.floor((v.ch - v.fh) / 2)
    for _, f in ipairs(v.filters) do
        local need = f.labelW + 4 + f.dd.width
        if x > PAD and x + need > v.w - PAD then x, y = PAD, y + v.ch + GAP end
        v.lines[#v.lines + 1] = { text = f.label, token = "textMuted", x = x, y = y + dy }
        f.dd:setX(x + f.labelW + 4)
        f.dd:setY(y)
        f.dd:setVisible(true)
        x = x + need + GAP * 2
    end
    return y + v.ch + GAP
end

-- 下拉選項跟著掃描結果換（分類只列這間有的，後面寫件數）
function P.syncOptions(v)
    local m = v.m
    local out = m.out
    local cats = { { id = "all", label = getText("IGUI_MSH_Storage_AllCount", out and out.items or 0) } }
    for _, c in ipairs(m.cats or {}) do
        cats[#cats + 1] = { id = c.id, label = getText("IGUI_MSH_Storage_CatCount", c.label, c.n) }
    end
    local floors = { { id = "all", label = getText("IGUI_MSH_Storage_All") } }
    for _, z in ipairs(m.floors or {}) do floors[#floors + 1] = { id = z, label = SS.floorText(z) } end
    v.ddCat:setOptions(cats)
    v.ddCat:setSelected(m.cat or "all", true)
    v.ddFloor:setOptions(floors)
    v.ddFloor:setSelected(m.z or "all", true)
end

local function agoText(m)
    if m.minute == nil then return nil end
    if m.minute < 1 then return getText("IGUI_MSH_Storage_JustNow") end
    return getText("IGUI_MSH_Storage_MinutesAgo", m.minute)
end

function P.layout(v)
    local m = v.m
    local mode = MSH.Settings.storageMode()
    local remote = mode == MSH.Settings.STORAGE.REMOTE
    local sep = getText("IGUI_MSH_Storage_Sep")
    v.lines = {}
    for _, el in ipairs(v.hideable) do el:setVisible(false) end
    local y = PAD
    -- 摘要＋〔重新掃描〕
    local summary = getText("IGUI_MSH_Storage_Scanning")
    if m.job == nil and m.out ~= nil then
        summary = getText("IGUI_MSH_Storage_Summary", m.out.containers, m.out.items)
        local ago = agoText(m)
        if ago ~= nil then summary = summary .. sep .. ago end
    end
    local rb = v.btnRescan
    rb:setEnabled(m.job == nil)
    rb:setX(v.w - PAD - rb.width)
    rb:setY(y)
    rb:setVisible(true)
    v.lines[#v.lines + 1] = { text = v.UI.Text.fit(summary, v.innerW - rb.width - GAP, FONT), token = "textMuted", x = PAD,
        y = y + math.floor((v.ch - v.fh) / 2) }
    y = y + v.ch + GAP
    -- 搜尋、〔清單｜網格〕（框架有 TileGrid 才有）、篩選
    v.search:setX(PAD)
    v.search:setY(y)
    v.search:setVisible(true)
    local tabs = v.viewTabs
    if tabs ~= nil then
        tabs:setSelected(m.grid and "grid" or "list", true)
        tabs:setX(v.w - PAD - tabs.width)
        tabs:setY(y)
        tabs:setVisible(true)
    end
    y = y + v.search.height + GAP
    y = filters(v, y)
    -- 清單或網格（同一塊、固定高度，打字篩選時視窗不跳）
    local h = (v.rows or P.ROWS) * (v.rowH + 2) + 2
    local box = m.grid and v.grid or v.list
    box:setX(PAD)
    box:setY(y)
    if box.width ~= v.innerW or box.height ~= h then box:resize(v.innerW, h) end
    if m.grid then
        v.tileGen = (v.tileGen or 0) + 1   -- 每一格的字重組（距離、樓層或篩選換了；P.drawTile）
        box:setItems(m.views)
        box:setSelectedIndex(m.tileIndex)
    else
        box:setItems(m.rows)
        box:setSelectedIndex(m.selIndex)
    end
    box:setVisible(true)
    y = y + h + GAP
    -- 掃描的說明：沒載入、沒人開過、上了鎖、空的、找不到
    local out = m.out
    if out ~= nil and m.job == nil then
        if out.unloaded > 0 then y = para(v, getText("IGUI_MSH_Storage_Unloaded", out.unloaded), "warning", y, "warning") end
        if out.unexplored > 0 then y = para(v, getText("IGUI_MSH_Storage_Unexplored", out.unexplored), "textMuted", y) end
        if out.locked > 0 then y = para(v, getText("IGUI_MSH_Storage_Locked", out.locked), "textMuted", y) end
        if out.items == 0 then
            y = para(v, getText("IGUI_MSH_Storage_Empty"), "textMuted", y)
        elseif #m.views == 0 and m.q ~= "" then
            y = para(v, getText("IGUI_MSH_Storage_NotFound", m.q), "text", y)
            y = row(v, { v.btnClear }, y)
        elseif #m.views == 0 then
            y = para(v, getText("IGUI_MSH_Storage_NoMatch"), "textMuted", y)
        end
    end
    -- 網格：選的那組放在好幾處時列出各處（近的在前）讓玩家挑，緊接在選取那一行與按鈕上面（設計稿 2026-10-21）
    if m.grid and #m.placeRows > 1 then
        local ov = m.openView
        y = para(v, getText("IGUI_MSH_Storage_NameCount", ov.g.name, ov.n) .. sep .. getText("IGUI_MSH_Storage_Places", #ov.places),
            "text", y + 2)
        local pl = v.placeList
        local ph = math.min(#m.placeRows, P.PLACE_ROWS) * (v.rowH + 2) + 2
        pl:setX(PAD)
        pl:setY(y)
        if pl.width ~= v.innerW or pl.height ~= ph then pl:resize(v.innerW, ph) end
        pl:setItems(m.placeRows)
        pl:setSelectedIndex(m.placeIndex)
        pl:setVisible(true)
        y = y + ph + GAP
    end
    -- 選取、〔指引我過去〕〔拿取...〕；不能拿的原因寫在按鈕下面
    y = y + 2
    if m.sel ~= nil and m.selGroup ~= nil then
        y = para(v, P.selText(m.selGroup, m.sel, m.pz), "text", y)
    else
        y = para(v, getText("IGUI_MSH_Storage_PickHint"), "textMuted", y)
    end
    local btns = { v.btnGuide }
    v.btnGuide:setEnabled(m.sel ~= nil)
    local why = nil
    if remote then
        why = P.takeBlock(m, m.sel)
        v.btnTake:setEnabled(why == nil)
        btns[#btns + 1] = v.btnTake
    end
    y = row(v, btns, y)
    if why ~= nil and why ~= "" then y = para(v, why, "warning", y, "warning") end
    -- 正在拿（別間的也寫：〔拿取...〕停用的原因）、帶路中、上一個結果
    local t = P.taking
    if t ~= nil then
        y = para(v, getText("IGUI_MSH_Storage_Taking", t.n, t.name), "text", y)
    end
    local g = P.guide
    if g ~= nil then
        -- 目標在別層的正上下方時水平距離是 0，不寫「還有 0 格」
        local line = (g.pz ~= nil and g.pz ~= g.z and (g.d or 0) <= 1)
            and getText("IGUI_MSH_Storage_GuidingFloor", g.title, SS.floorText(g.z))
            or getText("IGUI_MSH_Storage_Guiding", g.title, SS.floorText(g.z), g.d or 0)
        y = para(v, line, "text", y, "locate")
        y = row(v, { v.btnStop }, y)
    end
    if m.msg ~= nil then y = para(v, m.msg, m.msgToken, y) end
    -- 管理員設定
    y = para(v, getText(remote and "IGUI_MSH_Storage_ModeRemote" or "IGUI_MSH_Storage_ModeGuide"), "textMuted", y + 2)
    y = y + PAD - 2
    -- 字大或畫面矮時整個視窗放不進畫面：清單少幾列（至少 MIN_ROWS）再排一次，之後就用這個列數，不跟著內容伸縮
    local over = v.top + y - (getCore():getScreenHeight() - 20)
    local rows = v.rows or P.ROWS
    if over > 0 and rows > P.MIN_ROWS then
        v.rows = math.max(P.MIN_ROWS, rows - math.ceil(over / (v.rowH + 2)))
        return P.layout(v)
    end
    v.body:setHeight(y)
    v.win:setHeight(v.top + y)
    local Focus = v.UI.Focus
    if Focus ~= nil and Focus.invalidate ~= nil then Focus.invalidate(v.win) end
end

function P.draw(el, v)
    local colors, Icons = v.colors, v.UI.Icons
    for i = 1, #v.lines do
        local l = v.lines[i]
        local c = colors[l.token] or colors.text
        if l.icon ~= nil then Icons.draw(el, l.icon, PAD, l.y + v.iconDY, ICON, c) end
        el:drawText(l.text, l.x, l.y, c.r, c.g, c.b, c.a or 1, FONT)
    end
end

-- 清單列的字在綁定時組好（換資料、捲動、距離變了才綁），render 只畫
function P.bindCell(v, cell, item, index)
    cell.row, cell.index = item, index
    local title, right
    if item.kind == "group" then
        local vw = item.v
        title, right = getText("IGUI_MSH_Storage_NameCount", vw.g.name, vw.n), P.groupMeta(vw, v.m.pz)
        cell.tex, cell.indent = vw.g.tex, 0
        cell.chevron = vw.g == v.m.open and "chevronDown" or "chevronRight"
    else
        local p = item.p
        title, right = getText("IGUI_MSH_Storage_NameCount", p.title, p.n), P.whereText(p, v.m.pz)
        cell.tex, cell.indent, cell.chevron = nil, cell.flat and 0 or ICON + 8, nil   -- 網格下面的各處不縮排
    end
    local tm = getTextManager()
    local Text = v.UI.Text
    local textX = 8 + cell.indent + ICON + 6
    local rightW = math.min(tm:MeasureStringX(FONT, right), math.floor((cell.width - textX) / 2))
    cell.right = Text.fit(right, rightW, FONT)
    cell.rightW = tm:MeasureStringX(FONT, cell.right)
    local chevW = cell.chevron ~= nil and ICON + 6 or 0
    cell.title = Text.fit(title, cell.width - textX - cell.rightW - 14 - chevW, FONT)
    cell.tooltip = nil
    if cell.title ~= title or cell.right ~= right then cell.tooltip = title .. getText("IGUI_MSH_Storage_Sep") .. right end
end

function P.drawCell(cell)
    local item, v = cell.row, cell.view
    if item == nil then return end
    local c, fh = v.colors, v.fh
    if cell.list:isSelected(cell.index) then
        v.theme:fill(cell, 0, 0, cell.width, cell.height, "selected")
    elseif cell:isMouseOver() then
        v.theme:fill(cell, 0, 0, cell.width, cell.height, "hover")
    end
    local ty = math.floor((cell.height - fh) / 2)
    local x = 8 + cell.indent
    if cell.tex ~= nil then
        cell:drawTextureScaledAspect(cell.tex, x, math.floor((cell.height - ICON) / 2), ICON, ICON, 1, 1, 1, 1)
    end
    local t, mu = c.text, c.textMuted
    cell:drawText(cell.title, x + ICON + 6, ty, t.r, t.g, t.b, t.a or 1, FONT)
    local rx = cell.width - 8 - cell.rightW
    if cell.chevron ~= nil then
        rx = rx - ICON - 6
        v.UI.Icons.draw(cell, cell.chevron, cell.width - 8 - ICON, math.floor((cell.height - ICON) / 2), ICON, mu, 1)
    end
    cell:drawText(cell.right, rx, ty, mu.r, mu.g, mu.b, mu.a or 1, FONT)
end

-- ===== 網格一格：右上件數、物品圖、名稱、在哪裡（兩行）=====
-- 字在 P.layout 換 v.tileGen（距離、樓層、篩選換了）或格寬變了才重組，每幀只畫（框架熱路徑不配置）

-- 一格多寬：在哪裡那兩行的常見寫法放得下（各語言不同），但一列至少三格；放不下的照樣截字，滑鼠移上去看全文
function P.tileWidth(v)
    local tm, need = getTextManager(), 0
    for _, s in ipairs({ getText("IGUI_MSH_Storage_Places", 88), getText("IGUI_MSH_Storage_Tiles", 88),
        getText("IGUI_MSH_Indoor_Here"), SS.floorText(-8) }) do
        need = math.max(need, tm:MeasureStringX(FONT, s))
    end
    return math.max(P.TILE_MIN_W, math.min(need + 12, math.floor((v.innerW - 12) / 3)))
end

local function tileWords(v, view, w)
    local Text, tm, tw = v.UI.Text, getTextManager(), w - 12
    local a, b = P.groupWhere(view, v.m.pz, false)
    view.tGen, view.tW = v.tileGen, w
    view.tCount = getText("IGUI_MSH_Storage_Count", view.n)
    view.tCountW = tm:MeasureStringX(FONT, view.tCount)
    view.tName = Text.fit(view.g.name, tw, FONT)
    view.tA = Text.fit(a, tw, FONT)
    view.tB = b ~= nil and Text.fit(b, tw, FONT) or nil
    view.tCut = view.tName ~= view.g.name or view.tA ~= a or view.tB ~= b
end

-- 焦點說明與截字時的滑鼠提示：「豆子罐頭 ×5 · 2 個地方 · 最近 4 格」（同清單那一列）
local function tileLabel(v, view)
    if view.tLabelGen ~= v.tileGen then
        view.tLabelGen = v.tileGen
        view.tLabel = getText("IGUI_MSH_Storage_NameCount", view.g.name, view.n) .. getText("IGUI_MSH_Storage_Sep")
            .. P.groupMeta(view, v.m.pz)
    end
    return view.tLabel
end

-- 滑鼠下的那格一定畫過：照它上次畫的寬度（框架給的卡片寬）重組
function P.tileTip(v, view)
    if view.tGen ~= v.tileGen then tileWords(v, view, view.tW or v.grid:tileWidth()) end
    return view.tCut and tileLabel(v, view) or nil
end

-- 框架先畫好卡片底與選到、滑鼠移上去的底色；el 是要畫上去的元件，x, y 已扣掉捲動
function P.drawTile(v, el, view, x, y, w, h, state)
    if view.tGen ~= v.tileGen or view.tW ~= w then tileWords(v, view, w) end
    local c, lh = v.colors, v.lineH
    local t = c.text
    local mu = (state.picked or state.hover) and t or c.textMuted   -- 亮底上的灰字改白（同 Economy 網格）
    local cx, top = x + math.floor(w / 2), y + 6
    if view.g.tex ~= nil then
        el:drawTextureScaledAspect(view.g.tex, cx - P.TILE_ICON / 2, top, P.TILE_ICON, P.TILE_ICON, 1, 1, 1, 1)
    end
    el:drawText(view.tCount, x + w - 6 - view.tCountW, top, t.r, t.g, t.b, t.a or 1, FONT)
    local ty = top + P.TILE_ICON + 4
    el:drawTextCentre(view.tName, cx, ty, t.r, t.g, t.b, t.a or 1, FONT)
    el:drawTextCentre(view.tA, cx, ty + lh, mu.r, mu.g, mu.b, mu.a or 1, FONT)
    if view.tB ~= nil then el:drawTextCentre(view.tB, cx, ty + lh * 2, mu.r, mu.g, mu.b, mu.a or 1, FONT) end
end

function P.build(m, UI)
    classes()
    local theme = MSH.Client.theme(UI)
    local tm = getTextManager()
    local fh = tm:getFontHeight(FONT)
    local core = getCore()
    local sw, sh = core:getScreenWidth(), core:getScreenHeight()
    local w = math.max(360, math.min(fh * 28, sw - 40))
    local v = { m = m, UI = UI, theme = theme, colors = theme.colors, w = w, innerW = w - PAD * 2, lines = {}, fh = fh,
        lineH = fh + 2, ch = fh + 10, rowH = fh + 10 }
    v.iconDY = math.floor((fh - ICON) / 2)
    -- 開在右側（不擋住角色附近的地面），這次遊戲拖過就開在上次關掉的位置
    local x, y = math.max(0, sw - w - 60), 100
    local last = P.lastPos
    if last ~= nil then
        x = math.max(0, math.min(last.x, sw - w))
        y = math.max(0, math.min(last.y, sh - 200))
    end
    local win = UI.Window.new(MSH.Client.windowOpts(UI, { x = x, y = y, width = w, height = 200, icon = "search",
        theme = theme, title = getText("IGUI_MSH_Storage_Title", m.title) }))
    win.onEscape = function()
        P.close(m)
        return true
    end
    win.onClose = function() P.close(m) end
    v.win, v.top = win, win:contentTop()
    local body = V.Body:new(0, v.top, w, 100)
    body.background = false
    body.view = v
    body:initialise()
    win:addChild(body)
    v.body = body
    local function button(title, icon, style, onClick)
        local b = UI.Button.new({ x = 0, y = 0, title = title, icon = icon, style = style, theme = theme, onClick = onClick })
        b:fitWidth()
        body:addChild(b)
        return b
    end
    v.btnRescan = button(getText("IGUI_MSH_Storage_Rescan"), "reload", nil, function() P.rescan(m) end)
    v.btnClear = button(getText("IGUI_MSH_Storage_ClearSearch"), "close", nil, function() P.clearQuery(m) end)
    v.btnGuide = button(getText("IGUI_MSH_Storage_Guide"), "locate", "primary", function() P.startGuide(m, m.sel) end)
    v.btnTake = button(getText("IGUI_MSH_Storage_Take"), nil, nil, function() P.askTake(m) end)
    v.btnStop = button(getText("IGUI_MSH_Storage_StopGuide"), "close", nil, function() P.stopGuide() end)
    v.search = UI.TextField.new({ x = PAD, y = 0, width = v.innerW, placeholder = getText("IGUI_MSH_Storage_SearchHint"),
        theme = theme, clearButton = true, onChange = function(_, text) P.setQuery(m, text) end })
    body:addChild(v.search)
    -- 〔清單｜網格〕放在搜尋框右邊（同 Economy 的工具列），搜尋框讓出位置；框架沒有 TileGrid 就只有清單
    if P.gridOK(UI) then
        v.viewTabs = UI.Tabs.new({ x = 0, y = 0, height = v.search.height, theme = theme, target = m,
            selected = m.grid and "grid" or "list", onSelect = function(mm, id) P.setGrid(mm, id == "grid") end,
            items = { { id = "list", label = getText("IGUI_MSH_Storage_ViewList") },
                { id = "grid", label = getText("IGUI_MSH_Storage_ViewGrid") } } })
        body:addChild(v.viewTabs)
        v.search:setWidth(v.innerW - v.viewTabs.width - GAP)
    else
        m.grid = false
    end
    local function dropdown(options, selected, onChange)
        local dd = UI.Dropdown.new({ x = 0, y = 0, options = options, selected = selected, theme = theme, target = m,
            onChange = onChange })
        body:addChild(dd)
        return dd
    end
    v.ddCat = dropdown({ { id = "all", label = getText("IGUI_MSH_Storage_All") } }, "all",
        function(mm, id) P.setFilter(mm, "cat", id) end)
    v.ddFloor = dropdown({ { id = "all", label = getText("IGUI_MSH_Storage_All") } }, "all",
        function(mm, id) P.setFilter(mm, "z", id) end)
    local sorts = {}
    for i, id in ipairs(SS.SORTS) do sorts[i] = { id = id, label = getText("IGUI_MSH_Storage_Sort_" .. id) } end
    v.ddSort = dropdown(sorts, m.sort, function(mm, id) P.setSort(mm, id) end)
    v.filters = {}
    for i, f in ipairs({ { "IGUI_MSH_Storage_Category", v.ddCat }, { "IGUI_MSH_Storage_Floor", v.ddFloor },
        { "IGUI_MSH_Storage_Sort", v.ddSort } }) do
        local label = getText(f[1])
        v.filters[i] = { label = label, labelW = tm:MeasureStringX(FONT, label), dd = f[2] }
    end
    local c = v.colors
    -- flat：網格下面那張各處的清單（不縮排）
    local function newList(flat)
        local lst = UI.VirtualList.new({ x = PAD, y = 0, width = v.innerW, height = v.rowH, rowHeight = v.rowH, padding = 2,
            createCell = function(l)
                local cell = V.Cell:new(0, 0, 0, 0)
                cell.background = false
                cell.list, cell.view, cell.flat = l, v, flat
                return cell
            end,
            bindCell = function(_, cell, item, index) P.bindCell(v, cell, item, index) end,
            unbindCell = function(_, cell) cell.row, cell.tooltip = nil, nil end,
            onSelect = function(_, item) P.pick(m, item) end,
            colors = { thumb = c.textMuted, thumbHover = c.text, track = c.hover } })
        lst:initialise()
        body:addChild(lst)
        return lst
    end
    v.list = newList(false)
    v.hideable = { v.btnClear, v.btnStop, v.btnTake, v.list }
    if v.viewTabs ~= nil then
        v.tileW, v.tileH = P.tileWidth(v), 12 + P.TILE_ICON + 3 * v.lineH
        v.grid = UI.TileGrid.new({ x = PAD, y = 0, width = v.innerW, height = v.tileH, tileW = v.tileW, tileH = v.tileH,
            theme = theme, target = v, label = getText("IGUI_MSH_Storage_ViewGrid"), drawTile = P.drawTile,
            onPick = function(_, view) P.pickTile(m, view) end,
            focusLabel = function(_, view) return tileLabel(v, view) end,
            tooltip = function(_, view) return P.tileTip(v, view) end })
        body:addChild(v.grid)
        v.placeList = newList(true)
        v.hideable[#v.hideable + 1] = v.grid
        v.hideable[#v.hideable + 1] = v.placeList
    end
    m.view = v
    P.layout(v)
    win:addToUIManager()
    return v
end

-- ===== 開關 =====

local function openManager(claimId)
    local W = MSH.ManagerWindow
    if W == nil or W.open == nil then return end
    local ok, err = pcall(W.open, { claimId = claimId })
    if not ok then MSH.log("ManagerWindow.open failed: " .. tostring(err)) end
end

-- 關窗：拿掉事件（還在帶路就留著）；從管理視窗開的把管理視窗開回來。正在拿的照樣拿完，結果改用 Toast
function P.close(m)
    m = m or P.model
    if m == nil or m.closed then return end
    m.closed = true
    if P.model == m then P.model = nil end
    hook(P.guide ~= nil)
    local v = m.view
    m.view = nil
    if v ~= nil and v.win ~= nil then
        local win = v.win
        v.win = nil
        pcall(function()
            if v.UI.Dropdown ~= nil and v.UI.Dropdown.close ~= nil then v.UI.Dropdown.close(win) end   -- 只關這個視窗的
            if win:getIsVisible() then win:close() end
            win:removeFromUIManager()
            P.lastPos = { x = win:getX(), y = win:getY() }
        end)
    end
    if m.fromManager then openManager(m.claimId) end
end

local function openUnsafe(opts)
    local d = opts.detail
    if type(d) ~= "table" or type(d.rects) ~= "table" or #d.rects == 0 then return nil end
    local UI = MSH.Client.ui(P.CAPS)
    if UI == nil then
        MSH.log("storage panel: MinidoracatUI missing or too old")
        return nil
    end
    local old = P.model
    if old ~= nil then
        old.fromManager = false
        P.close(old)
    end
    local m = { claimId = d.claimId, title = d.title or "", rects = MSH.Rect.copyList(d.rects), bits = d.bits or 0,
        fromManager = opts.fromManager == true, q = "", sort = "name", views = {}, rows = {}, placeRows = {},
        grid = P.gridPref() }
    P.model = m
    P.build(m, UI)
    hook(true)
    P.where(m, getTimestampMs())
    P.rescan(m)
    return m
end

-- opts：{ detail（管理視窗的詳情：claimId、title、rects、bits）, fromManager }。回 model，失敗回 nil（記 log、半建好的收掉）
function P.open(opts)
    local ok, res = pcall(openUnsafe, opts or {})
    if ok then return res end
    MSH.log("storage panel failed: " .. tostring(res))
    if P.model ~= nil then P.close(P.model) end
    return nil
end

-- 管理員改了沙盒（Mirror sandboxSync → emit "sandbox"）：開著的面板照新模式重排；改成「關閉」就收起面板、停止帶路
-- （〔停止指引〕在面板裡，關閉時管理視窗也沒有〔搜尋物品〕，不停的話標示要留到走到或 10 分鐘，2026-10-20 審查）
MSH.Client.on("sandbox", "storagePanel", function()
    local P0 = MSH.StoragePanel
    local off = MSH.Settings.storageMode() == MSH.Settings.STORAGE.OFF
    if off then P0.stopGuide(true) end
    if P0.model == nil then return end
    if off then P0.close(P0.model) else P0.refresh() end
end)
