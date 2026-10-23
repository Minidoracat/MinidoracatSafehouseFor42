-- MinidoracatSafehouse/ZoneList.lua：禁建區視窗（管理員）。使用者 2026-10-16：「禁建區數量多了，顯示還會清楚嗎? 另外可能還需要
--   傳送過去確認或者查看座標，所以是不是應該另外做一個分頁或視窗來管理比較好?」管理員面板排除頁〔管理禁建區〕開（AP.onZoneManage：
--   先收起管理員面板，這裡關掉時開回排除頁）。側邊、非 modal，不擋角色附近的地面：開著時地上用亮紅疊色畫全部禁建區（FloorTint
--   圖層 "zones"，Ranges.COLORS.zones），〔傳送〕過去的那個用黃色（"zoneSel"，ZL.SEL_COLOR），可以一個一個傳送過去看範圍。
-- 清單：名稱搜尋（不分大小寫的子字串）；每個禁建區一列 名稱＋〔傳送〕＋〔刪除〕，下一行左上角／外框／塊數，已經壓到的安全屋
--   用 warning 列出。〔新增禁建區〕收起本視窗開 ZonePanel.lua，那邊關掉時開回本視窗（onClosed）。新增、刪除立即生效
--   （adminAddZone／adminRemoveZone，伺服器 Zones.lua）；刪除先 danger 確認。
-- 〔傳送〕送原版指令 /teleportto x.5,y.5,0 到外框中央那格（不在範圍內就用第一塊的中央，ZL.target）：
--   TeleportToCommand.java:18-35（名稱 teleportto／tpto、參數 x,y,z、要 Capability.TeleportToCoordinates）、:72-94（伺服器
--   GameServer.sendTeleport、寫 admin log）；Capability.java:17 TeleportToCoordinates；SendCommandToServer（LuaManager.java:9025-9030）；
--   getSpecificPlayer(0):getRole():hasCapability（同 AdminPanel.isAdmin）。帳號沒有這個權限時〔傳送〕停用並寫原因。
-- 框架不合（window／controls／dialog／scrollPanel）時不開（ZL.available；管理員面板的〔管理禁建區〕停用並寫原因），不報錯。
-- 檔案載入時不碰 ISPanel、框架或玩家（harness T.bootClient 會載入本檔）。

if not isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Client"
require "MinidoracatSafehouse/FloorTint"
require "MinidoracatSafehouse/SlotsWindow"
require "MinidoracatSafehouse/AdminPanel"
require "MinidoracatSafehouse/ZonePanel"

local MSH = MinidoracatSafehouse
local ZL = MSH.ZoneList or {}
MSH.ZoneList = ZL

local K = MSH.SlotsWindow.kit
local LIMIT = MSH.LIMIT
local EMPTY = {}

ZL.CAPS = { "window", "controls", "dialog", "scrollPanel" }
-- 〔傳送〕過去的那個：黃色疊色，蓋過其他禁建區的亮紅；ov 以外是被房子擋住、人物蓋住那幾格改用地板染色時的顏色
ZL.SEL_COLOR = { r = 1.0, g = 0.9, b = 0.25, ov = { r = 1.0, g = 0.85, b = 0.05, a = 0.55 } }
ZL.SEL_ALPHAS = { 1.0 }
ZL.W, ZL.H = 460, 620
ZL.SEARCH_W = 220   -- 同管理員面板玩家頁的搜尋框

-- ===== 狀態（harness t_ui_zones 直接測）=====
-- m = { fromAdmin（關掉時開回管理員面板）, selected（傳送過去的那個 id）, query（小寫）, zones（nil＝還沒讀到）, max,
--       unreadable, loadErr, flat（全部禁建區的扁平 x, y, w, h, ...）, selFlat, selId（selFlat 是哪個 id 算的）,
--       busy（刪除送出中）, status, statusToken, view, closed }

function ZL.available()
    return MSH.Client.ui(ZL.CAPS) ~= nil
end

-- 原版 /teleportto 要的權限；Capability 或 role 缺就當沒有
function ZL.canTeleport()
    local cap = Capability and Capability.TeleportToCoordinates
    local p = getSpecificPlayer(0)
    local role = cap ~= nil and p ~= nil and p:getRole() or nil
    return role ~= nil and role:hasCapability(cap) == true
end

-- 原版 /teleportto 到那格中央（管理員面板的原版安全屋〔傳送〕也用它）
function ZL.sendTeleport(x, y)
    SendCommandToServer(string.format("/teleportto %d.5,%d.5,0", x, y))
end

local function rectsOf(z)
    return type(z.rects) == "table" and z.rects or EMPTY
end

function ZL.nameOf(z)
    return tostring(z.name or ("#" .. tostring(z.id)))
end

-- 傳送的落點：外框中央那格；不在任何一塊裡（例：L 形）就用第一塊的中央
function ZL.target(zone)
    local rects = rectsOf(zone)
    local b = MSH.Rect.bounds(rects)
    local x, y = b.x + math.floor(b.w / 2), b.y + math.floor(b.h / 2)
    if MSH.Rect.listContains(rects, x, y) then return x, y end
    local f = rects[1]
    return f.x + math.floor(f.w / 2), f.y + math.floor(f.h / 2)
end

function ZL.find(m, id)
    for _, z in ipairs(m.zones or EMPTY) do
        if z.id == id then return z end
    end
    return nil
end

-- 名稱符合搜尋的禁建區（空字串＝全部）
function ZL.matches(m)
    local out, q = {}, m.query
    for _, z in ipairs(m.zones or EMPTY) do
        if q == "" or string.find(string.lower(ZL.nameOf(z)), q, 1, true) ~= nil then out[#out + 1] = z end
    end
    return out
end

-- 〔新增禁建區〕停用的原因；nil＝可以新增
function ZL.addBlock(m)
    if m.zones == nil then return "" end
    if m.unreadable then return getText("IGUI_MSH_Admin_ZonesUnreadable", getText("IGUI_MSH_Admin_Tab_rules")) end
    if #m.zones >= (m.max or LIMIT.MAX_ZONES) then return getText("IGUI_MSH_Admin_ZonesFull", #m.zones) end
    if not MSH.ZonePanel.available() then return getText("IGUI_MSH_Create_NeedFramework") end
    return nil
end

function ZL.say(m, text, token)
    m.status, m.statusToken = text, token or "text"
    ZL.layout(m)
end

function ZL.load(m)
    MSH.Client.send("adminZones", {}, function(res) ZL.onZones(m, res) end)
end

-- adminZones 的回覆，或 adminRemoveZone 成功的回覆（同樣帶 zones、max）；讀不到時留著上一次的清單、另寫原因
function ZL.onZones(m, res)
    if m.closed then return end
    if res.ok then
        m.zones, m.max, m.unreadable, m.loadErr = res.zones or {}, res.max or LIMIT.MAX_ZONES, res.unreadable == true, nil
        m.flat = MSH.ZonePanel.flatZones(m.zones)
        if m.selected ~= nil and ZL.find(m, m.selected) == nil then m.selected = nil end
        m.selId = false   -- 下一幀照新清單重算選中的那個
    else
        m.loadErr = res.code
    end
    ZL.layout(m)
end

function ZL.setQuery(m, text)
    m.query = string.lower(MSH.trim(text or ""))
    ZL.layout(m)
end

function ZL.teleport(m, zoneId)
    if m.closed or not ZL.canTeleport() then return false end
    local z = ZL.find(m, zoneId)
    if z == nil or #rectsOf(z) == 0 then return false end
    local x, y = ZL.target(z)
    ZL.sendTeleport(x, y)
    m.selected = zoneId
    ZL.say(m, getText("IGUI_MSH_ZoneList_Teleported", ZL.nameOf(z), x, y), "text")
    return true
end

-- 〔刪除〕：danger 確認框，確定才送
function ZL.remove(m, zoneId)
    local v = m.view
    if m.closed or v == nil or m.busy ~= nil or m.unreadable then return false end
    local z = ZL.find(m, zoneId)
    if z == nil then return false end
    v.UI.Dialog.show(MSH.Client.windowOpts(v.UI, { title = getText("IGUI_MSH_Admin_ZonesHead"), theme = v.theme,
        danger = true,
        text = getText("IGUI_MSH_Admin_ZoneRemoveAsk", ZL.nameOf(z)),
        confirmText = getText("IGUI_MSH_Admin_ZoneRemove"), cancelText = getText("UI_Cancel"),
        onResult = function(ok) if ok then ZL.sendRemove(m, zoneId) end end }))
    return true
end

function ZL.sendRemove(m, zoneId)
    if m.closed or m.busy ~= nil then return end
    m.busy = true
    local rid = MSH.Client.send("adminRemoveZone", { zoneId = zoneId }, function(res) ZL.onRemoved(m, res) end,
        { mutation = true })
    if rid == nil then
        m.busy = nil
        return ZL.say(m, MSH.AdminPanel.codeText("OFFLINE"), "errorText")
    end
    ZL.say(m, nil)
end

-- 成功用回覆的清單重排；NOT_FOUND（別的管理員先刪了）與結果未知（伺服器快取過期）都重抓清單看實際狀況
function ZL.onRemoved(m, res)
    if m.closed then return end
    if res.code == "NO_REPLY" and res.pending and not res.expired then
        return ZL.say(m, getText("IGUI_MSH_Admin_Waiting"), "warning")
    end
    m.busy, m.status = nil, nil
    if res.ok then return ZL.onZones(m, res) end
    if res.code == "NO_REPLY" or res.code == MSH.CODE.NOT_FOUND then
        ZL.load(m)
        return ZL.layout(m)
    end
    ZL.say(m, MSH.AdminPanel.codeText(res.code), "errorText")
end

-- 開回本視窗；開不成而且是從管理員面板來的，就開回管理員面板（不能就此消失）
local function reopen(fromAdmin)
    if ZL.open({ fromAdmin = fromAdmin }) == nil and fromAdmin then
        local ok, err = pcall(MSH.AdminPanel.open, { tab = "exclusions" })
        if not ok then MSH.log("AdminPanel.open failed: " .. tostring(err)) end
    end
end

-- 〔新增禁建區〕：先收起本視窗（框選時不擋地面），不開回管理員面板；ZonePanel 關掉時（儲存成功或取消）開回本視窗，
-- 沒開成就馬上開回來
function ZL.onAdd(m)
    if m.closed or m.busy ~= nil or ZL.addBlock(m) ~= nil then return end
    local fromAdmin, zones = m.fromAdmin, m.zones
    m.fromAdmin = false
    ZL.close(m)
    if MSH.ZonePanel.open({ zones = zones, onClosed = function() reopen(fromAdmin) end }) == nil then reopen(fromAdmin) end
end

-- ===== 畫面 =====

local function onTeleport(m, b) ZL.teleport(m, b.internal) end
local function onRemove(m, b) ZL.remove(m, b.internal) end

-- 一列：名稱（放不下就換行，不截字；選中的用 accent）＋〔傳送〕＋〔刪除〕，下一行範圍，壓到的安全屋
function ZL.layoutRow(m, F, z, canTp, sep)
    local id = z.id
    local rects = rectsOf(z)
    local tp = F:button("zt" .. id, getText("IGUI_MSH_ZoneList_Teleport"), m, onTeleport)
    tp.internal = id
    tp:setEnabled(canTp and #rects > 0)
    local del = F:button("zd" .. id, getText("IGUI_MSH_Admin_ZoneRemove"), m, onRemove, "danger")
    del.internal = id
    del:setEnabled(m.busy == nil and not m.unreadable)
    local token = id == m.selected and "accent" or "text"
    local nameW = math.max(40, F.width - 2 * K.PAD - tp.width - del.width - 2 * K.GAP)
    local lines = K.wrap(F.UI, ZL.nameOf(z), nameW, UIFont.Small)
    F:row({ F:label("zn" .. id, lines[1] or "", token), tp, del })
    for i = 2, #lines do
        local l = F:label("zn" .. id .. "#" .. i, lines[i], token)
        l:setX(K.PAD)
        l:setY(F.y - K.GAP)
        F.y = F.y + l.height + 2
    end
    if #rects > 0 then
        local b = MSH.Rect.bounds(rects)
        F:text("za" .. id, getText("IGUI_MSH_Admin_ZoneArea", b.x, b.y, b.w, b.h, #rects), "textMuted")
    end
    local claims = type(z.claims) == "table" and z.claims or EMPTY
    if #claims > 0 then
        local parts = {}
        for j, c in ipairs(claims) do parts[j] = tostring(c.owner or "-") .. " #" .. tostring(c.claimId) end
        -- 伺服器最多列 20 間，claimCount 是總數（舊伺服器沒有，就當列出的就是全部）
        local more = (tonumber(z.claimCount) or #claims) - #claims
        if more > 0 then parts[#parts + 1] = getText("IGUI_MSH_Admin_ZoneClaimsMore", more) end
        F:text("zc" .. id, getText("IGUI_MSH_Admin_ZoneClaims", table.concat(parts, sep)), "warning")
    end
end

-- 資料變了才排（讀到清單、搜尋、傳送、刪除），不是每幀
function ZL.layout(m)
    local v = m.view
    if v == nil then return end
    local F, UI = v.flow, v.UI
    F:begin(v.scroll:contentWidth())
    F:text("hint", getText("IGUI_MSH_ZoneList_Hint"), "textMuted")
    local zones = m.zones
    if zones == nil then
        F:text("load", m.loadErr and MSH.AdminPanel.codeText(m.loadErr) or getText("IGUI_MSH_Admin_Loading"),
            m.loadErr and "errorText" or "textMuted")
        return F:finish()
    end
    local list = ZL.matches(m)
    F:text("count", getText("IGUI_MSH_Admin_ZonesCount", #zones, m.max), "textMuted")
    if m.query ~= "" then F:text("matched", getText("IGUI_MSH_ZoneList_Matched", #list), "textMuted") end
    if m.loadErr ~= nil then F:text("err", MSH.AdminPanel.codeText(m.loadErr), "errorText") end
    if m.unreadable then
        F:text("unreadable", getText("IGUI_MSH_Admin_ZonesUnreadable", getText("IGUI_MSH_Admin_Tab_rules")), "warning")
    end
    local block = ZL.addBlock(m)
    local add = F:button("zadd", getText("IGUI_MSH_Admin_ZoneAdd"), m, ZL.onAdd)
    add:setEnabled(block == nil and m.busy == nil)
    local search = F:get("zsearch", function()
        return UI.TextField.new({ x = 0, y = 0, width = ZL.SEARCH_W, theme = v.theme,
            placeholder = getText("IGUI_MSH_ZoneList_Search"), maxLength = LIMIT.TITLE_CHARS,
            onChange = function(_, text) ZL.setQuery(m, text) end })
    end)
    F:row({ add, search })
    if block ~= nil and not m.unreadable then F:text("block", block, "warning") end
    local canTp = ZL.canTeleport()
    if not canTp then F:text("noTp", getText("IGUI_MSH_ZoneList_NoTeleport"), "textMuted") end
    if m.status ~= nil then
        F:text("status", m.status, m.statusToken)
    elseif m.busy ~= nil then
        F:text("status", getText("IGUI_MSH_Admin_Busy"), "textMuted")
    end
    local sep = getText("IGUI_MSH_Admin_ListSep")
    for _, z in ipairs(list) do ZL.layoutRow(m, F, z, canTp, sep) end
    if #zones == 0 then
        F:text("empty", getText("IGUI_MSH_Admin_ZonesEmpty"), "textMuted")
    elseif #list == 0 then
        F:text("noMatch", getText("IGUI_MSH_ZoneList_NoMatch"), "textMuted")
    end
    F:finish()
end

-- 每個 UI 幀（Body:prerender）：地上的禁建區與選中的那個（玩家所在樓層）。選中的換了才重算它的格子；FloorTint 只在
-- 清單、選中或畫面範圍變了才動地板。不配置
function ZL.frame(v)
    local m = v.m
    local p = getSpecificPlayer(0)
    if p == nil or m.closed then return end
    if m.selId ~= m.selected then
        m.selId = m.selected
        local z = m.selected ~= nil and ZL.find(m, m.selected) or nil
        m.selFlat = z ~= nil and MSH.ZonePanel.flatZones({ z }) or EMPTY
    end
    local Tint, Z = MSH.FloorTint, MSH.ZonePanel
    local pz = math.floor(p:getZ())
    Tint.setRects("zones", m.flat, MSH.Ranges.COLORS.zones, Z.ZONE_ALPHAS, pz)
    Tint.setRects("zoneSel", m.selFlat, ZL.SEL_COLOR, ZL.SEL_ALPHAS, pz)
end

local Body = nil   -- 第一次開窗才 derive（harness 載入時沒有 ISPanel）
local function bodyClass()
    if Body == nil then
        Body = ISPanel:derive("MinidoracatSafehouseZoneListBody")
        function Body:prerender() ZL.frame(self.view) end
    end
    return Body
end

function ZL.build(m, UI)
    local theme = MSH.Client.theme(UI)
    local core = getCore()
    local sw, sh = core:getScreenWidth(), core:getScreenHeight()
    local w, h = math.min(ZL.W, sw - 40), math.min(ZL.H, sh - 100)
    local v = { m = m, UI = UI, theme = theme }
    -- 非 modal；放右側，不擋角色附近的地面（同禁建區面板）
    local win = UI.Window.new(MSH.Client.windowOpts(UI, { x = math.max(0, sw - w - 60), y = 60, width = w, height = h,
        theme = theme, title = getText("IGUI_MSH_Admin_ZonesHead") }))
    local top = win:contentTop()
    local body = bodyClass():new(0, top, w, h - top)
    body.background = false
    body.view = v
    body:initialise()
    win:addChild(body)
    v.scroll = UI.ScrollPanel.new({ x = 0, y = 0, width = w, height = h - top, theme = theme })
    body:addChild(v.scroll)
    v.flow = K.flow(v.scroll, UI, theme)
    v.win = win
    win.onEscape = function()
        ZL.close(m)
        return true
    end
    win.onClose = function() ZL.close(m) end
    m.view = v
    ZL.layout(m)
    win:addToUIManager()
end

-- 關窗（Esc、〔×〕、〔新增禁建區〕、被新開的取代）：收掉地上的兩層；從管理員面板開的就開回排除頁（會重抓個數）
function ZL.close(m)
    if m.closed then return end
    m.closed = true
    if ZL.model == m then ZL.model = nil end
    local Tint = MSH.FloorTint
    Tint.clear("zones")
    Tint.clear("zoneSel")
    local v = m.view
    m.view = nil
    local win = v and v.win
    if win ~= nil then
        pcall(function()
            if win:getIsVisible() then win:close() end
            win:removeFromUIManager()
        end)
    end
    if m.fromAdmin then
        local ok, err = pcall(MSH.AdminPanel.open, { tab = "exclusions" })
        if not ok then MSH.log("AdminPanel.open failed: " .. tostring(err)) end
    end
end

local function openUnsafe(opts)
    if not MSH.AdminPanel.isAdmin() then return nil end
    local UI = MSH.Client.ui(ZL.CAPS)
    if UI == nil then
        MSH.log("zone list needs MinidoracatUI rev " .. tostring(MSH.Client.MIN_REV) .. " with window/controls/dialog/scrollPanel")
        return nil
    end
    local fromAdmin = opts.fromAdmin == true
    local prev = ZL.model
    if prev ~= nil then
        -- 一次一個：開回管理員面板的事交給新的這個
        fromAdmin = fromAdmin or prev.fromAdmin
        prev.fromAdmin = false
        ZL.close(prev)
    end
    local m = { fromAdmin = fromAdmin, selected = opts.selected, query = "", flat = EMPTY, selFlat = EMPTY, selId = false }
    ZL.model = m
    ZL.build(m, UI)
    ZL.load(m)
    return m
end

-- opts = { fromAdmin = 從管理員面板開的, selected = 先選中的 id }。回 nil＝沒開成（不是管理員、框架不合、建窗失敗）：
-- 呼叫端自己開回原來的視窗
function ZL.open(opts)
    local ok, res = pcall(openUnsafe, opts or {})
    if ok then return res end
    MSH.log("zone list failed: " .. tostring(res))
    local m = ZL.model
    if m ~= nil then
        m.fromAdmin = false
        ZL.close(m)   -- 半建好的視窗一起收掉
    end
    return nil
end
