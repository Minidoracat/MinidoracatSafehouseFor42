-- MinidoracatSafehouse/ZoneList.lua：管理員區域視窗（管理員）。使用者 2026-10-16：「禁建區數量多了，顯示還會清楚嗎? 另外可能還需要
--   傳送過去確認或者查看座標，所以是不是應該另外做一個分頁或視窗來管理比較好?」管理員面板排除頁〔管理區域〕開（AP.onZoneManage：
--   先收起管理員面板，這裡關掉時開回排除頁）。側邊、非 modal，不擋角色附近的地面：開著時地上用亮紅疊色畫全部禁建區（FloorTint
--   圖層 "zones"，Ranges.COLORS.zones）、白色虛線畫道路豁免區的外緣（"zonesExempt"，ZonePanel.paintZones），〔傳送〕過去的那個
--   用黃色（"zoneSel"，ZL.SEL_COLOR），可以一個一個傳送過去看範圍。
-- 兩種區域（2026-11-25 設計稿 plan-allowzone-1125）：禁建區（nobuild，範圍不能壓到）與道路豁免區（roadexempt，區裡的道路不擋）。
--   都存在伺服器的 zones.json，服主可以手改，伺服器每 5 秒看一次、連兩次一樣才套用；〔重新載入〕立即讀（adminReloadZones）。
--   回覆的 file = { path, appliedAt?, error? }：沒有錯寫設定檔路徑、幾點套用、總數；有錯寫錯誤橫幅（哪一行或第幾筆錯在哪、
--   目前沿用哪一份），這時遊戲內不能新增或刪除（伺服器也會回 SAVE_FAILED＋reason FILE，免得蓋掉手改的檔）。
-- 清單：種類篩選（全部／禁建區／道路豁免區）＋名稱搜尋（不分大小寫的子字串）；每個區域一列 種類標籤＋名稱＋〔傳送〕＋〔刪除〕，
--   下一行左上角／外框／塊數，禁建區已經壓到的安全屋用 warning 列出、道路豁免區寫區內有幾間，列與列之間一條分隔線。
--   〔新增區域〕收起本視窗開 ZonePanel.lua，那邊關掉時開回本視窗（onClosed）。新增、刪除立即生效（adminAddZone／
--   adminRemoveZone，伺服器 Zones.lua）；刪除先 danger 確認，帶清單的 rev：檔案剛被手改過就回 STALE_REVISION 與最新清單。
-- 清單跟著伺服器：公開清單的 rev 變了（Client 事件 zones）或收到 ZONES_FILE／ZONES_RELOADED 提示（檔案錯誤出現或清掉時
--   rev 不變）就重抓。
-- 〔傳送〕送原版指令 /teleportto x.5,y.5,0 到外框中央那格（不在範圍內就用第一塊的中央，ZL.target）：
--   TeleportToCommand.java:18-35（名稱 teleportto／tpto、參數 x,y,z、要 Capability.TeleportToCoordinates）、:72-94（伺服器
--   GameServer.sendTeleport、寫 admin log）；Capability.java:17 TeleportToCoordinates；SendCommandToServer（LuaManager.java:8961-8966）；
--   getSpecificPlayer(0):getRole():hasCapability（同 AdminPanel.isAdmin）。帳號沒有這個權限時〔傳送〕停用並寫原因。
-- 框架不合（window／controls／dialog／scrollPanel）時不開（ZL.available；管理員面板的〔管理區域〕停用並寫原因），不報錯。
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
-- 〔傳送〕過去的那個：黃色疊色，蓋過其他區域；ov 以外是被房子擋住、人物蓋住那幾格改用地板染色時的顏色
ZL.SEL_COLOR = { r = 1.0, g = 0.9, b = 0.25, ov = { r = 1.0, g = 0.85, b = 0.05, a = 0.55 } }
ZL.SEL_ALPHAS = { 1.0 }
ZL.W, ZL.H = 460, 620
ZL.SEARCH_W = 220   -- 同管理員面板玩家頁的搜尋框
ZL.RULE_ALPHA = 0.35   -- 列與列之間的分隔線（textMuted 的顏色，淡一點）

-- ===== 狀態（harness t_ui_zones 直接測）=====
-- m = { fromAdmin（關掉時開回管理員面板）, selected（傳送過去的那個 id）, query（小寫）, kind（篩選，nil＝全部）,
--       zones（nil＝還沒讀到）, max, unreadable, rev, file（{ path, appliedAt?, error? }，舊伺服器沒有）, loadErr,
--       flat（禁建區的扁平 x, y, w, h, ...）, exemptFlat（道路豁免區外緣）, selFlat, selId（selFlat 是哪個 id 算的）,
--       busy（刪除或重新載入送出中）, status, statusToken, view, closed }

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

function ZL.kindOf(z)
    return MSH.ZonePanel.isExempt(z) and MSH.ZONE_KIND.ROADEXEMPT or MSH.ZONE_KIND.NOBUILD
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

-- 符合種類篩選與名稱搜尋的區域（空字串＝全部）
function ZL.matches(m)
    local out, q = {}, m.query
    for _, z in ipairs(m.zones or EMPTY) do
        if (m.kind == nil or ZL.kindOf(z) == m.kind)
            and (q == "" or string.find(string.lower(ZL.nameOf(z)), q, 1, true) ~= nil) then
            out[#out + 1] = z
        end
    end
    return out
end

-- 禁建區、道路豁免區各幾個
function ZL.counts(zones)
    local exempt = 0
    for _, z in ipairs(zones) do
        if MSH.ZonePanel.isExempt(z) then exempt = exempt + 1 end
    end
    return #zones - exempt, exempt
end

-- zones.json 目前的錯誤（沒有＝nil）
function ZL.fileError(m)
    local f = m.file
    return type(f) == "table" and type(f.error) == "table" and f.error or nil
end

-- 伺服器時間（毫秒）換成本地的 HH:MM（框架 Date.localOffsetMinutes，同 SlotsWindow.dateText）；拿不到回 nil
function ZL.clock(ms)
    if not MSH.isFinite(ms) then return nil end
    local UI = MSH.Client.ui({})
    local D = UI and UI.Date
    local offset = D and D.localOffsetMinutes and D.localOffsetMinutes() or 0
    local mins = math.floor(ms / 60000) + offset
    return string.format("%02d:%02d", math.floor(mins / 60) % 24, mins % 60)
end

-- 錯誤橫幅的那一句：哪一行或第幾筆、錯在哪（Contract：file.error = { code, line?, index?, id?, field?, reason?, max? }）
function ZL.fileErrorText(e)
    local code = tostring(e.code)
    local key = "IGUI_MSH_ZoneFile_" .. code
    local a, b = e.index, nil
    if code == "JSON" then
        a = e.line
    elseif code == "TOO_MANY" then
        a = e.max or LIMIT.MAX_ZONES
    elseif code == "DUP_ID" then
        b = e.id
    elseif code == "BAD_ID" then
        b = LIMIT.MAX_ZONE_ID   -- 伺服器的範圍：1..MAX_ZONE_ID 的整數（Contract.lua）
    elseif code == "BAD_RECTS" then
        key = key .. "_" .. tostring(e.reason)
        b = e.reason == "SIDE" and LIMIT.ZONE_SIDE or LIMIT.MAX_PIECES
    elseif code == "UNKNOWN_FIELD" then
        if e.index == nil then key, a = key .. "_TOP", e.field else b = e.field end
    end
    local text = getText(key, tostring(a or "-"), tostring(b or "-"))
    if text == key then text = getText("IGUI_MSH_ZoneFile_Other", code) end
    return text
end

-- 檔案有錯時鎖住新增與刪除（免得蓋掉手改的檔）。檔案被刪（MISSING）不鎖：伺服器照目前的清單重建檔案
function ZL.fileLocked(m)
    local e = ZL.fileError(m)
    return e ~= nil and e.code ~= "MISSING"
end

-- 〔新增區域〕停用的原因；nil＝可以新增
function ZL.addBlock(m)
    if m.zones == nil then return "" end
    if ZL.fileLocked(m) then return getText("IGUI_MSH_ZoneList_FileLock") end
    if m.unreadable then return getText("IGUI_MSH_Admin_ZonesUnreadable", getText("IGUI_MSH_Admin_Tab_rules")) end
    if #m.zones >= (m.max or LIMIT.MAX_ZONES) then return getText("IGUI_MSH_Admin_ZonesFull", #m.zones) end
    if not MSH.ZonePanel.available() then return getText("IGUI_MSH_Create_NeedFramework") end
    return nil
end

-- 可以刪除：沒有送出中、資料檔讀得到、檔案沒錯（被刪不算）
function ZL.canRemove(m)
    return m.busy == nil and not m.unreadable and not ZL.fileLocked(m)
end

function ZL.say(m, text, token)
    m.status, m.statusToken = text, token or "text"
    ZL.layout(m)
end

-- 抓清單：一次只有一筆 adminZones 在路上。送出中又要抓（推送、提示、刪除或重新載入之後的補抓）就記在 m.again
-- （推送的 rev，或 true＝沒帶 rev），回覆處理完再抓一次；回覆已經是那個 rev 就不必
function ZL.load(m, ...)
    if m.closed then return end
    local rev = (...)
    if m.loading then
        if m.again == true or rev == nil then m.again = true else m.again = rev end
        return
    end
    m.loading = true
    local rid = MSH.Client.send("adminZones", {}, function(res) ZL.onLoaded(m, res) end)
    if rid == nil then m.loading = nil end
end

function ZL.onLoaded(m, res)
    m.loading = nil
    local again = m.again
    m.again = nil
    ZL.onZones(m, res)
    if again ~= nil and not (again ~= true and res.ok and res.rev == again) then ZL.load(m) end
end

-- 換成回覆帶的清單（adminZones 同形：zones、max、unreadable、rev、file）
function ZL.take(m, res)
    m.zones, m.max, m.unreadable, m.loadErr = res.zones or {}, res.max or LIMIT.MAX_ZONES, res.unreadable == true, nil
    m.rev, m.file = res.rev, type(res.file) == "table" and res.file or nil
    local Z = MSH.ZonePanel
    m.flat, m.exemptFlat = Z.flatZones(m.zones, false), Z.exemptFlat(m.zones)
    if m.selected ~= nil and ZL.find(m, m.selected) == nil then m.selected = nil end
    m.selId = false   -- 下一幀照新清單重算選中的那個
end

-- adminZones 的回覆，或 adminRemoveZone 成功的回覆（同樣帶清單）；讀不到時留著上一次的清單、另寫原因
function ZL.onZones(m, res)
    if m.closed then return end
    if res.ok then ZL.take(m, res) else m.loadErr = res.code end
    ZL.layout(m)
end

function ZL.setQuery(m, text)
    m.query = string.lower(MSH.trim(text or ""))
    ZL.layout(m)
end

-- 種類篩選（nil＝全部）
function ZL.setKind(m, kind)
    m.kind = kind
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

-- 刪除確認的那一句：禁建區寫之後可以在這裡建；道路豁免區寫區內的安全屋保留、之後重新框選時道路照常檢查
function ZL.removeAsk(z)
    if not MSH.ZonePanel.isExempt(z) then return getText("IGUI_MSH_Admin_ZoneRemoveAsk", ZL.nameOf(z)) end
    local n = tonumber(z.claimCount) or #(type(z.claims) == "table" and z.claims or EMPTY)
    if n > 0 then return getText("IGUI_MSH_Admin_ZoneRemoveAskExempt", ZL.nameOf(z), n) end
    return getText("IGUI_MSH_Admin_ZoneRemoveAskExemptEmpty", ZL.nameOf(z))
end

-- 〔刪除〕：danger 確認框，確定才送。開框時就記下編號與看到的 rev：確認框開著時清單可能重抓（rev 變了），
-- 確定時送開框當下的 rev，檔案在這之間被改過就由伺服器回 STALE_REVISION
function ZL.remove(m, zoneId)
    local v = m.view
    if m.closed or v == nil or not ZL.canRemove(m) then return false end
    local z = ZL.find(m, zoneId)
    if z == nil then return false end
    local id, rev = z.id, m.rev
    v.UI.Dialog.show(MSH.Client.windowOpts(v.UI, { title = getText("IGUI_MSH_Admin_ZonesHead"), theme = v.theme,
        danger = true, text = ZL.removeAsk(z),
        confirmText = getText("IGUI_MSH_Admin_ZoneRemove"), cancelText = getText("UI_Cancel"),
        onResult = function(ok) if ok then ZL.sendRemove(m, id, rev) end end }))
    return true
end

-- 帶看到這份清單時的 rev：檔案在這之間被手改過（編號可能換人），伺服器回 STALE_REVISION 不刪
function ZL.sendRemove(m, zoneId, rev)
    if m.closed or not ZL.canRemove(m) then return end
    m.busy = true
    local rid = MSH.Client.send("adminRemoveZone", { zoneId = zoneId, rev = rev }, function(res) ZL.onRemoved(m, res) end,
        { mutation = true })
    if rid == nil then
        m.busy = nil
        return ZL.say(m, MSH.AdminPanel.codeText("OFFLINE"), "errorText")
    end
    ZL.say(m, nil)
end

-- 送出中被要求重抓（ZL.refresh 記的 dirty：推送的 rev，或 true＝提示沒帶 rev）：回覆處理完、清掉 busy 之後要補抓一次；
-- 回覆帶的清單已經是那個 rev（例如自己這次刪除引起的推送）就不必再抓。回傳要不要抓，由呼叫端和自己的重抓合成一次
local function idle(m, res)
    m.busy, m.status = nil, nil
    local dirty = m.dirty
    m.dirty = nil
    return dirty ~= nil and not (dirty ~= true and res.ok and res.rev == dirty)
end

local function loadIf(m, want)
    if want then ZL.load(m) end
end

-- 成功用回覆的清單重排；STALE_REVISION 換成回覆帶的最新清單、請管理員確認後再刪；檔案有錯（SAVE_FAILED＋FILE）重抓清單
-- 顯示錯誤橫幅；NOT_FOUND（別的管理員先刪了）與結果未知（伺服器快取過期）都重抓清單看實際狀況
function ZL.onRemoved(m, res)
    if m.closed then return end
    if res.code == "NO_REPLY" and res.pending and not res.expired then
        return ZL.say(m, getText("IGUI_MSH_Admin_Waiting"), "warning")
    end
    local again = idle(m, res)
    if res.ok then
        ZL.onZones(m, res)
        return loadIf(m, again)
    end
    local CODE = MSH.CODE
    if res.code == CODE.STALE_REVISION then
        if type(res.zones) == "table" then ZL.take(m, res) else again = true end
        loadIf(m, again)
        return ZL.say(m, getText("IGUI_MSH_ZoneList_Stale"), "warning")
    end
    if res.code == CODE.SAVE_FAILED and res.reason == "FILE" then
        ZL.load(m)
        return ZL.say(m, getText("IGUI_MSH_ZoneList_FileLock"), "errorText")
    end
    if res.code == "NO_REPLY" or res.code == CODE.NOT_FOUND then
        ZL.load(m)
        return ZL.layout(m)
    end
    loadIf(m, again)
    ZL.say(m, MSH.AdminPanel.codeText(res.code), "errorText")
end

-- 〔重新載入〕：伺服器立刻讀 zones.json（不等 5 秒的輪詢），回覆和 adminZones 同形
function ZL.reload(m)
    if m.closed or m.busy ~= nil or m.zones == nil then return false end
    m.busy = true
    local rid = MSH.Client.send("adminReloadZones", {}, function(res) ZL.onReloaded(m, res) end, { mutation = true })
    if rid == nil then
        m.busy = nil
        ZL.say(m, MSH.AdminPanel.codeText("OFFLINE"), "errorText")
        return false
    end
    ZL.say(m, nil)
    return true
end

function ZL.onReloaded(m, res)
    if m.closed then return end
    if res.code == "NO_REPLY" and res.pending and not res.expired then
        return ZL.say(m, getText("IGUI_MSH_Admin_Waiting"), "warning")
    end
    local again = idle(m, res)
    if res.ok then
        ZL.take(m, res)
        loadIf(m, again)
        -- 檔案有錯：橫幅已經寫了原因，狀態列不另外寫
        if ZL.fileError(m) ~= nil then return ZL.layout(m) end
        return ZL.say(m, getText("IGUI_MSH_ZoneList_Reloaded", #m.zones), "text")
    end
    if res.code == "NO_REPLY" then
        ZL.load(m)
        return ZL.layout(m)
    end
    loadIf(m, again)
    ZL.say(m, MSH.AdminPanel.codeText(res.code), "errorText")
end

-- 伺服器的清單變了（公開清單 rev 變了，或檔案錯誤出現／清掉的提示）：開著就重抓（第一次還沒抓到、或第一次就失敗也抓）；
-- 刪除或重新載入送出中先記著，回覆處理完再抓；查詢送出中由 ZL.load 合併
function ZL.refresh(rev)
    local m = ZL.model
    if m == nil or m.closed then return end
    if rev ~= nil and m.zones ~= nil and rev == m.rev then return end
    if m.busy ~= nil then
        if m.dirty == true or rev == nil then m.dirty = true else m.dirty = rev end
        return
    end
    ZL.load(m, rev)
end

-- 開回本視窗；開不成而且是從管理員面板來的，就開回管理員面板（不能就此消失）
local function reopen(fromAdmin)
    if ZL.open({ fromAdmin = fromAdmin }) == nil and fromAdmin then
        local ok, err = pcall(MSH.AdminPanel.open, { tab = "exclusions" })
        if not ok then MSH.log("AdminPanel.open failed: " .. tostring(err)) end
    end
end

-- 〔新增區域〕：先收起本視窗（框選時不擋地面），不開回管理員面板；ZonePanel 關掉時（儲存成功或取消）開回本視窗，
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
local function onKindTag(m, b) ZL.setKind(m, b.internal) end
local function onFilter(m, b) ZL.setKind(m, b.internal) end

-- 列與列之間的分隔線：框架沒有分隔線元件，同 kit 的 Label 自己畫（1 px 的 drawRect）
local Rule = nil
local function newRule()
    if Rule == nil then
        Rule = ISUIElement:derive("MinidoracatSafehouseZoneRule")
        function Rule:render()
            local c = self.color
            self:drawRect(0, 0, self.width, 1, ZL.RULE_ALPHA, c.r, c.g, c.b)
        end
    end
    local r = Rule:new(0, 0, 1, 1)
    r:initialise()
    return r
end

-- 種類標籤：chip 按鈕，圖示是原版純白貼圖染成地上的顏色（同管理視窗的地面範圍 chip）；按了只看這一種
local function kindTag(F, m, key, kind)
    local UI = F.UI
    local tag = F:get(key, function()
        local tex = UI.CAPABILITIES.buttonIconColor == true and getTexture("media/ui/whitebar.png") or nil
        local b = UI.Button.new({ x = 0, y = 0, title = "", style = "chip", icon = tex, theme = F.theme, target = m,
            onClick = onKindTag })
        if tex ~= nil then b:setIconColor(MSH.Ranges.SWATCHES[kind == MSH.ZONE_KIND.ROADEXEMPT and "roadexempt" or "zones"]) end
        return b
    end)
    tag.internal = kind
    tag:setTitle(getText("IGUI_MSH_ZoneKindTag_" .. kind))
    tag:fitWidth()
    return tag
end

-- 一列：種類標籤＋名稱（放不下就換行，不截字；選中的用 accent 並標「地上標黃」）＋〔傳送〕＋〔刪除〕，下一行範圍，
-- 禁建區壓到的安全屋（warning）或道路豁免區區內有幾間（textMuted）
function ZL.layoutRow(m, F, z, canTp, sep)
    local id = z.id
    local rects = rectsOf(z)
    local kind = ZL.kindOf(z)
    -- 鍵帶種類：同一個 id 手改成另一種時，圖示顏色跟著換
    local tag = kindTag(F, m, "zk" .. kind .. id, kind)
    local tp = F:button("zt" .. id, getText("IGUI_MSH_ZoneList_Teleport"), m, onTeleport)
    tp.internal = id
    tp:setEnabled(canTp and #rects > 0)
    local del = F:button("zd" .. id, getText("IGUI_MSH_Admin_ZoneRemove"), m, onRemove, "danger")
    del.internal = id
    del:setEnabled(ZL.canRemove(m))
    local selected = id == m.selected
    local token = selected and "accent" or "text"
    local row = { tag }
    local nameW = F.width - 2 * K.PAD - tag.width - tp.width - del.width - 3 * K.GAP
    local mark = nil
    if selected then
        mark = F:label("zm" .. id, getText("IGUI_MSH_ZoneList_Marked"), "accent")
        nameW = nameW - mark.width - K.GAP
    end
    local lines = K.wrap(F.UI, ZL.nameOf(z), math.max(40, nameW), UIFont.Small)
    row[#row + 1] = F:label("zn" .. id, lines[1] or "", token)
    if mark ~= nil then row[#row + 1] = mark end
    row[#row + 1] = tp
    row[#row + 1] = del
    F:row(row)
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
    -- 伺服器最多列 20 間，claimCount 是總數（舊伺服器沒有，就當列出的就是全部）
    local total = tonumber(z.claimCount) or #claims
    if kind == MSH.ZONE_KIND.ROADEXEMPT then
        if total > 0 then F:text("zc" .. id, getText("IGUI_MSH_ZoneList_ExemptClaims", total), "textMuted") end
    elseif #claims > 0 then
        local parts = {}
        for j, c in ipairs(claims) do parts[j] = tostring(c.owner or "-") .. " #" .. tostring(c.claimId) end
        local more = total - #claims
        if more > 0 then parts[#parts + 1] = getText("IGUI_MSH_Admin_ZoneClaimsMore", more) end
        F:text("zc" .. id, getText("IGUI_MSH_Admin_ZoneClaims", table.concat(parts, sep)), "warning")
    end
end

-- 分隔線：放在目前位置、整列寬，往下推
local function rule(F, key)
    local r = F:get(key, newRule)
    local colors = F.theme.colors
    r.color = colors.textMuted or colors.text
    r:setX(K.PAD)
    r:setY(F.y)
    r:setWidth(F.width - 2 * K.PAD)
    F.y = F.y + 1 + K.GAP
end

-- 設定檔那一段：沒有錯寫「設定檔 路徑 · 幾點套用 · 共幾個，最多幾個」；有錯寫錯誤橫幅（標題、哪裡錯、目前沿用哪一份）
local function fileLines(m, F)
    local file, n, max = m.file, #m.zones, m.max
    local path = tostring(file.path or "zones.json")
    local at = ZL.clock(file.appliedAt)
    local e = ZL.fileError(m)
    if e == nil then
        if at ~= nil then
            F:text("file", getText("IGUI_MSH_ZoneList_File", path, at, n, max), "textMuted")
        else
            F:text("file", getText("IGUI_MSH_ZoneList_FileNoTime", path, n, max), "textMuted")
        end
        return
    end
    -- 檔案被刪（MISSING）不算錯、不鎖操作：只寫那一句（已經寫了沿用上一份與之後會怎樣），不寫「有錯、沒有套用」。
    -- 開服就讀不開（unreadable）之後才被刪：沒有上一份可以沿用、新增刪除都鎖著（addBlock／canRemove），改寫錯誤樣式的專屬句
    if e.code == "MISSING" and m.unreadable then
        F:text("fileWhy", getText("IGUI_MSH_ZoneFile_MISSING_NoList"), "errorText")
    elseif e.code == "MISSING" then
        F:text("fileWhy", ZL.fileErrorText(e), "warning")
    else
        F:text("fileBad", getText("IGUI_MSH_ZoneList_FileBad"), "errorText", UIFont.Medium)
        F:text("fileWhy", ZL.fileErrorText(e), "text")
        -- 開服就壞檔（unreadable）：沒有上一份可以沿用，改寫 unreadable 那一句（layout）
        if not m.unreadable then
            if at ~= nil then
                F:text("fileKeep", getText("IGUI_MSH_ZoneList_FileKeepAt", at, n), "textMuted")
            else
                F:text("fileKeep", getText("IGUI_MSH_ZoneList_FileKeep", n), "textMuted")
            end
        end
    end
    F:text("filePath", getText("IGUI_MSH_ZoneList_FilePath", path), "textMuted")
end

-- 資料變了才排（讀到清單、篩選、搜尋、傳送、刪除），不是每幀
function ZL.layout(m)
    local v = m.view
    if v == nil then return end
    local F, UI = v.flow, v.UI
    F:begin(v.scroll:contentWidth())
    F:text("hint", getText("IGUI_MSH_ZoneList_Hint"), "textMuted")
    -- 避開道路關著：道路本來就不擋，道路豁免區沒有作用
    if MSH.Settings.get().avoidRoads ~= true then F:text("roadsOff", getText("IGUI_MSH_ZoneList_RoadsOff"), "warning") end
    local zones = m.zones
    if zones == nil then
        F:text("load", m.loadErr and MSH.AdminPanel.codeText(m.loadErr) or getText("IGUI_MSH_Admin_Loading"),
            m.loadErr and "errorText" or "textMuted")
        return F:finish()
    end
    local list = ZL.matches(m)
    if m.file ~= nil then
        fileLines(m, F)
    else
        F:text("count", getText("IGUI_MSH_Admin_ZonesCount", #zones, m.max), "textMuted")
    end
    if m.loadErr ~= nil then F:text("err", MSH.AdminPanel.codeText(m.loadErr), "errorText") end
    if m.unreadable then
        F:text("unreadable", getText("IGUI_MSH_Admin_ZonesUnreadable", getText("IGUI_MSH_Admin_Tab_rules")), "warning")
    end
    local block = ZL.addBlock(m)
    local add = F:button("zadd", getText("IGUI_MSH_Admin_ZoneAdd"), m, ZL.onAdd)
    add:setEnabled(block == nil and m.busy == nil)
    local reload = F:button("zreload", getText("IGUI_MSH_ZoneList_Reload"), m, ZL.reload)
    reload:setEnabled(m.busy == nil)
    local search = F:get("zsearch", function()
        return UI.TextField.new({ x = 0, y = 0, width = ZL.SEARCH_W, theme = v.theme,
            placeholder = getText("IGUI_MSH_ZoneList_Search"), maxLength = LIMIT.TITLE_CHARS,
            onChange = function(_, text) ZL.setQuery(m, text) end })
    end)
    F:row({ add, reload, search })
    if block ~= nil and not m.unreadable then F:text("block", block, "warning") end
    if #zones > 0 then
        local nNo, nEx = ZL.counts(zones)
        local all = F:button("fAll", getText("IGUI_MSH_ZoneList_FilterAll", #zones), m, onFilter, "chip")
        local fNo = F:button("fNo", getText("IGUI_MSH_ZoneList_FilterNobuild", nNo), m, onFilter, "chip")
        local fEx = F:button("fEx", getText("IGUI_MSH_ZoneList_FilterExempt", nEx), m, onFilter, "chip")
        all.internal, fNo.internal, fEx.internal = nil, MSH.ZONE_KIND.NOBUILD, MSH.ZONE_KIND.ROADEXEMPT
        all:setActive(m.kind == nil)
        fNo:setActive(m.kind == MSH.ZONE_KIND.NOBUILD)
        fEx:setActive(m.kind == MSH.ZONE_KIND.ROADEXEMPT)
        F:row({ all, fNo, fEx })
    end
    if m.query ~= "" or m.kind ~= nil then F:text("matched", getText("IGUI_MSH_ZoneList_Matched", #list), "textMuted") end
    local canTp = ZL.canTeleport()
    if not canTp then F:text("noTp", getText("IGUI_MSH_ZoneList_NoTeleport"), "textMuted") end
    if m.status ~= nil then
        F:text("status", m.status, m.statusToken)
    elseif m.busy ~= nil then
        F:text("status", getText("IGUI_MSH_Admin_Busy"), "textMuted")
    end
    local sep = getText("IGUI_MSH_Admin_ListSep")
    for i, z in ipairs(list) do
        if i > 1 then rule(F, "zr" .. z.id) end
        ZL.layoutRow(m, F, z, canTp, sep)
    end
    if #zones == 0 then
        F:text("empty", getText("IGUI_MSH_Admin_ZonesEmpty"), "textMuted")
    elseif #list == 0 then
        F:text("noMatch", getText("IGUI_MSH_ZoneList_NoMatch"), "textMuted")
    end
    F:finish()
end

-- 每個 UI 幀（Body:prerender）：地上的區域與選中的那個（玩家所在樓層）。選中的換了才重算它的格子；FloorTint 只在
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
    local pz = math.floor(p:getZ())
    MSH.ZonePanel.paintZones(m.flat, m.exemptFlat, pz)
    MSH.FloorTint.setRects("zoneSel", m.selFlat, ZL.SEL_COLOR, ZL.SEL_ALPHAS, pz)
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
    -- 非 modal；放右側，不擋角色附近的地面（同新增區域面板）
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

-- 關窗（Esc、〔×〕、〔新增區域〕、被新開的取代）：收掉地上的三層；從管理員面板開的就開回排除頁（會重抓個數）
function ZL.close(m)
    if m.closed then return end
    m.closed = true
    if ZL.model == m then ZL.model = nil end
    local Tint = MSH.FloorTint
    Tint.clear("zones")
    Tint.clear("zonesExempt")
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
    local m = { fromAdmin = fromAdmin, selected = opts.selected, query = "", flat = EMPTY, exemptFlat = EMPTY, selFlat = EMPTY,
        selId = false }
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

MSH.Client.on("zones", "ZoneList", function(z) MSH.ZoneList.refresh(z and z.rev) end)
MSH.Client.on("alert", "ZoneList", function(a)
    if a.code == "ZONES_FILE" or a.code == "ZONES_RELOADED" then MSH.ZoneList.refresh(nil) end
end)
