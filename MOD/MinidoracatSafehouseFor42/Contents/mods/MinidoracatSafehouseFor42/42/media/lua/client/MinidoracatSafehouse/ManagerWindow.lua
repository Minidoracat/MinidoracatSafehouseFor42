-- MinidoracatSafehouse/ManagerWindow.lua：安全屋管理視窗（M3，計畫 §10.3 版面稿、§6.4 manager 投影、§10.5 分享頁入口）。
-- 兩區「我的安全屋」／「分享給我的」來自 list；右側詳情來自 detail，分頁：概覽、成員與分享（SharingPage.lua）、土地規則。
-- 狀態只顯示最高優先的一個與下一步，其餘收進〔詳細〕；放棄用 UI.Dialog danger；重新框選帶倒數進建立面板；
--   〔在世界中顯示〕只畫外框；loading／empty／error／stale-revision／result-pending 都有明確畫面。
-- 所有動作只送提案，畫面以伺服器結果與重抓的 list／detail 為準（§10.4 最後一段）。
-- UI 框架：MSH.Client.ui(MW.CAPS)；不合時退原版 ISPanel／ISButton 最小直角 fallback（AGENTS.md 鐵則「管理視窗不得整個消失」）。
-- 載入時不碰 ISPanel、框架或 getPlayer（harness T.bootClient 會載入本檔）；ISPanel 子類在第一次開窗時才建。
-- 出處：反編譯 D:/github/pz-decompiled-reference/snapshots/42.21.0-20260928/pz/zombie/；原版 Lua
--   D:/SteamLibrary/steamapps/common/ProjectZomboid/media/lua/；框架 D:/github/MinidoracatUIFor42（rev 16＋）。

if not isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Settings"
require "MinidoracatSafehouse/Client"

local MSH = MinidoracatSafehouse
local first = MSH.ManagerWindow == nil
local MW = MSH.ManagerWindow or {}
MSH.ManagerWindow = MW
local LC, SRC = MSH.LIFECYCLE, MSH.SOURCE

-- rev 16：ScrollPanel、Text.wrap；Window／Button／Tabs／Dialog／VirtualList 更早（ui-framework 摘要 §1）
MW.CAPS = { "window", "controls", "dialog", "virtualList", "scrollPanel", "textWrap" }
MW.PAD, MW.GAP = 10, 6

-- ===== 狀態（§10.3）：只顯示最高優先的一個與下一步，其餘收進「詳細」 =====
-- 伺服器設定不完整 ＞ 修復已暫停 ＞ 成員同步受干擾 ＞ 租約寬限或已停用 ＞ 土地規則警告 ＞ 已保護；數字小＝優先。
-- 不認得的碼排在土地規則警告同級：不會被「已保護」蓋掉，也不搶前面幾級。
MW.PRIORITY = {
    SERVER_BLOCKED = 1,
    REPAIR_PAUSED = 2, QUARANTINED = 2,
    INTERFERENCE = 3, FACTION_TOO_LARGE = 3, FACTION_SUSPENDED = 3,
    LAPSED = 4,
    LAND_WARNING = 5,
    PROTECTED = 9,
}
MW.OTHER_PRIORITY = 5

function MW.rank(code)
    return MW.PRIORITY[code] or MW.OTHER_PRIORITY
end

-- d：list 列或 detail。回傳 top, rest（rest 照優先序）；沒有任何問題時 top＝PROTECTED、rest 空
function MW.statusCodes(d)
    local codes, seen = {}, {}
    local function add(c)
        if type(c) == "string" and c ~= "PROTECTED" and not seen[c] then
            seen[c] = true
            codes[#codes + 1] = c
        end
    end
    add(d.healthSummary)
    if d.lifecycle == LC.LAPSED then add("LAPSED") end
    if d.lifecycle == LC.QUARANTINED then add("QUARANTINED") end
    local fs = d.factionShare
    if type(fs) == "table" then
        if fs.state == "SUSPENDED" then
            add("FACTION_SUSPENDED")
        elseif fs.projected == false then
            add("FACTION_TOO_LARGE")
        end
    end
    if #codes == 0 then return "PROTECTED", codes end
    MSH.sortSafe(codes, function(a, b) return MW.rank(a) < MW.rank(b) end)
    return table.remove(codes, 1), codes
end

-- 狀態文字與下一步（沒有下一步回 nil）；getText 找不到鍵時回鍵本身（原版 Translator）
function MW.statusText(code)
    local key = "IGUI_MSH_Manager_Status_" .. tostring(code)
    local text = getText(key)
    if text == key then text = getText("IGUI_MSH_Manager_Status_Other", tostring(code)) end
    local nkey = "IGUI_MSH_Manager_Next_" .. tostring(code)
    local nextStep = getText(nkey)
    if nextStep == nkey then nextStep = nil end
    return text, nextStep
end

-- 放棄確認框的段落鍵（§10.3、§7.6）：第一句對齊原版 IGUI_SafehouseUI_ReleaseConfirm
-- （Translate/CH/IG_UI.json:763「你真的要放棄這個安全屋嗎?」）；用地契建的寫明地契不退；
-- 重新框選緩衝期內提示改用〔重新框選〕。不用「取消安全屋」（和〔取消〕撞字）。
function MW.releaseKeys(d, redrawLeftMs)
    local keys = { "IGUI_SafehouseUI_ReleaseConfirm" }
    if d.source == SRC.DEED then keys[#keys + 1] = "IGUI_MSH_Manager_ReleaseNoRefund" end
    if (redrawLeftMs or 0) > 0 then keys[#keys + 1] = "IGUI_MSH_Manager_ReleaseTryRedraw" end
    return keys
end

-- 〔重新框選〕的標題：剩餘時間，伺服器有給剩餘次數（actions.redrawsLeft，沙盒 RedrawLimit）時一併顯示；
-- 舊伺服器沒有這欄就只顯示時間。次數用「還能 N 次」式的句子，不寫「N＋複數名詞」
function MW.redrawTitle(leftMs, redrawsLeft)
    if MSH.isInt(redrawsLeft) and redrawsLeft > 0 then
        return getText("IGUI_MSH_Manager_RedrawTimes", MW.clock(leftMs), redrawsLeft)
    end
    return getText("IGUI_MSH_Manager_Redraw", MW.clock(leftMs))
end

-- 倒數 m:ss（秒無條件進位；固定寬度另由版面以 0 量寬）
function MW.clock(ms)
    local s = math.max(0, math.ceil(ms / 1000))
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

-- 管理員面板只在 CanSetupSafehouses 顯示（伺服器才是防線）；api-sources.md「getRole():hasCapability」
function MW.isAdmin()
    local p = getSpecificPlayer(0)
    local role = p and p:getRole()
    return role ~= nil and Capability ~= nil and role:hasCapability(Capability.CanSetupSafehouses) == true
end

-- ===== 在世界中顯示：只畫外框（§10.3 最後一點）=====
-- addAreaHighlightForPlayer 每幀要重加：FBORenderAreaHighlights.render 丟掉 renderTimeMs 不是本幀 UI 時間的
-- （FBORenderAreaHighlights.java:61-68；LuaManager.java:12515-12521）。OnPreUIDraw 在設好本幀 UI 時間之後觸發
-- （UIManager.java:273-296）。四條 1 格寬的邊、不掃任何格子，所以範圍沒變時零重掃；本函式不配置。
MW.overlay = nil
MW.OVERLAY_COLOR = { r = 1.0, g = 0.85, b = 0.4, a = 0.5 }

function MW.setOverlay(d)
    local r = d and d.rect
    if type(r) ~= "table" then
        MW.overlay = nil
        return
    end
    MW.overlay = { claimId = d.claimId, x0 = r.x, y0 = r.y, x1 = r.x + r.w, y1 = r.y + r.h }
end

function MW.drawOverlay()
    local o = MW.overlay
    if o == nil then return end
    local p = getSpecificPlayer(0)
    if p == nil then return end
    local z = math.floor(p:getZ())                                          -- IsoMovingObject.java:525
    local c = MW.OVERLAY_COLOR
    local x0, y0, x1, y1 = o.x0, o.y0, o.x1, o.y1
    addAreaHighlightForPlayer(0, x0, y0, x1, y0 + 1, z, c.r, c.g, c.b, c.a)
    if y1 - y0 > 1 then addAreaHighlightForPlayer(0, x0, y1 - 1, x1, y1, z, c.r, c.g, c.b, c.a) end
    if y1 - y0 > 2 then
        addAreaHighlightForPlayer(0, x0, y0 + 1, x0 + 1, y1 - 1, z, c.r, c.g, c.b, c.a)
        if x1 - x0 > 1 then addAreaHighlightForPlayer(0, x1 - 1, y0 + 1, x1, y1 - 1, z, c.r, c.g, c.b, c.a) end
    end
end

-- ===== ISPanel 子類（第一次開窗才建）=====
local V = nil

local function classes()
    if V ~= nil then return V end
    V = {}
    -- 文字列：排版時 add 好（text, x, y, token, icon, font），render 只畫、不配置
    local Lines = ISPanel:derive("MSHManagerLines")
    function Lines:clear() self.rows = {} end
    function Lines:add(text, x, y, token, icon, font)
        self.rows[#self.rows + 1] = { text = text or "", x = x, y = y, token = token or "text", icon = icon,
            font = font or UIFont.Small }
    end
    function Lines:render()
        local c = self.theme.colors
        local rows, size = self.rows, self.iconSize
        for i = 1, #rows do
            local r = rows[i]
            local col = c[r.token] or c.text
            local x = r.x
            if r.icon ~= nil then
                self.UI.Icons.draw(self, r.icon, x, r.y + self.iconDy, size, col, 1)
                x = x + size + 4
            end
            self:drawText(r.text, x, r.y, col.r, col.g, col.b, col.a, r.font)
        end
    end
    V.Lines = Lines

    -- 內容區：清單底色在 prerender（子元件之前）畫；倒數每秒換一次標題
    local Body = ISPanel:derive("MSHManagerBody")
    function Body:prerender() self.mw:prerender(self) end
    V.Body = Body

    -- 清單列：名稱 Text.fit，截斷時 hover 顯示全名（借原版 ISButton:updateTooltip，ISButton.lua:316-346；
    -- 框架 Controls.lua:98-105 同法）；第二行狀態圖示＋文字（已保護＝打勾，其餘＝警告色）
    local Cell = ISPanel:derive("MSHManagerCell")
    function Cell:prerender()
        if self.tooltip or self.tooltipUI then ISButton.updateTooltip(self) end
    end
    function Cell:render()
        local row = self.row
        if row == nil then return end
        local mw = self.mw
        local theme, c = mw.theme, mw.theme.colors
        if self.list:isSelected(self.index) then
            theme:fill(self, 0, 0, self.width, self.height, "selected")
        elseif self:isMouseOver() then
            theme:fill(self, 0, 0, self.width, self.height, "hover")
        end
        local t = c.text
        self:drawText(self.title, 8, 5, t.r, t.g, t.b, t.a, UIFont.Small)
        local s = c[self.token] or t
        local y = 7 + mw.fh
        mw.UI.Icons.draw(self, self.icon, 8, y + mw.iconDy, 14, s, 1)
        self:drawText(self.sub, 26, y, s.r, s.g, s.b, s.a, UIFont.Small)
    end
    V.Cell = Cell
    return V
end

-- ===== 視窗 =====
local W = {}
W.__index = W

local function measure(s, font)
    return getTextManager():MeasureStringX(font or UIFont.Small, s)              -- ISButton.lua:233
end

function W.new(UI)
    classes()
    local self = setmetatable({ UI = UI, area = "mine", tab = "overview", listState = "loading", expanded = false }, W)
    self.theme = MSH.Client.theme(UI)
    self.fh = getTextManager():getFontHeight(UIFont.Small)
    self.fhM = getTextManager():getFontHeight(UIFont.Medium)
    self.ch = self.fh + 10
    self.GAP = MW.GAP
    self.iconW = 18
    self.iconDy = math.floor((self.fh - 14) / 2)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w = math.min(860, math.floor(sw * 0.9))
    local h = math.min(560, math.floor(sh * 0.9))
    self.win = UI.Window.new(MSH.Client.windowOpts(UI, { x = math.floor((sw - w) / 2), y = math.floor((sh - h) / 2),
        width = w, height = h, title = getText("IGUI_MSH_Manager_Title"), icon = "house", theme = self.theme,
        resizable = true, minWidth = 300, minHeight = 280,
        onResize = function() self:layout() end,
        onClose = function() self:onClose() end }))
    self:build()
    return self
end

-- 框架按鈕（先 addChild 再移位：pitfalls.md UI「先 setX 再 addChild 會被夾在螢幕內」）
function W:button(parent, title, onClick, target, style, icon, width)
    local b = self.UI.Button.new({ x = 0, y = 0, width = width, height = self.ch, title = title, style = style, icon = icon,
        theme = self.theme, target = target or self, onClick = onClick })
    parent:addChild(b)
    b:setVisible(false)
    return b
end

function W:newLines(parent)
    local l = V.Lines:new(0, 0, 10, 10)
    l.background = false
    l.wantMouseEvents = false          -- 純顯示：不吃下層點擊（pitfalls.md UI「純顯示的置頂面板會吃掉下層點擊」）
    l.theme, l.UI, l.iconSize, l.iconDy = self.theme, self.UI, 14, self.iconDy
    l.rows = {}
    l:initialise()
    parent:addChild(l)
    return l
end

function W:place(el, x, y)
    el:setX(x)
    el:setY(y)
    el:setVisible(true)
end

function W:fit(s, w)
    return self.UI.Text.fit(s or "", w, UIFont.Small)
end

-- 依序排一排元件，放不下就換行；回傳最後一排的底
function W:flow(items, x0, y, w)
    local x = x0
    for _, el in ipairs(items) do
        if x > x0 and x + el.width > x0 + w then
            x, y = x0, y + self.ch + MW.GAP
        end
        self:place(el, x, y)
        x = x + el.width + MW.GAP
    end
    return y + self.ch
end

-- 文字段落換行後逐行加入；回傳下一行 y
function W:addWrapped(L, text, x, y, w, token, font)
    local lh = font == UIFont.Medium and self.fhM or self.fh
    local lines = self.UI.Text.wrap(text or "", w, font or UIFont.Small)
    for i = 1, #lines do L:add(lines[i], x, y + (i - 1) * lh, token, nil, font) end
    return y + #lines * lh
end

local LABELS = { "Role", "Owner", "Location", "Source", "Slot", "Created", "Status", "ReleaseAt", "Gap", "Roads",
    "Resources", "Number" }

function W:build()
    local UI, win = self.UI, self.win
    local top = win:contentTop()
    local body = V.Body:new(0, top, win.width, win.height - top)
    body.background = false
    body.mw = self
    body:initialise()
    win:addChild(body)
    self.body = body
    self.back = self:newLines(body)          -- 第一個子元件：狀態文字畫在其他元件底下

    self.areaTabs = UI.Tabs.new({ x = 0, y = 0, height = self.ch, theme = self.theme, target = self, onSelect = W.onArea,
        selected = "mine", items = {
            { id = "mine", label = getText("IGUI_MSH_Manager_AreaMine", 0) },
            { id = "shared", label = getText("IGUI_MSH_Manager_AreaShared", 0) } } })
    body:addChild(self.areaTabs)
    self.btnRefresh = self:button(body, getText("IGUI_MSH_Manager_Refresh"), W.onRefresh, self, nil, "reload")
    self.btnSlots = self:button(body, getText("IGUI_MSH_Manager_Slots"), W.onSlots, self, nil, "coins")
    self.btnCreate = self:button(body, getText("IGUI_MSH_Manager_Create"), W.onCreate, self, nil, "plus")
    self.btnAdmin = self:button(body, getText("IGUI_MSH_Manager_Admin"), W.onAdmin, self, nil, "settings")

    local c = self.theme.colors
    self.list = UI.VirtualList.new({ x = 0, y = 0, width = 200, height = 200, rowHeight = self.fh * 2 + 14, padding = 2,
        createCell = function(l)
            local cell = V.Cell:new(0, 0, 0, 0)
            cell.background = false
            cell.list, cell.mw = l, self
            return cell
        end,
        bindCell = function(_, cell, row, index) self:bindCell(cell, row, index) end,
        unbindCell = function(_, cell) cell.row, cell.tooltip = nil, nil end,
        onSelect = function(_, row) if row then self:select(row.claimId) end end,
        onHighlight = function(_, row) if row and not self.narrow then self:select(row.claimId) end end,
        colors = { thumb = c.textMuted, thumbHover = c.text, track = c.hover } })
    self.list:initialise()
    body:addChild(self.list)
    self.list:setVisible(false)
    self.btnCreateEmpty = self:button(body, getText("IGUI_MSH_Manager_Create"), W.onCreate, self, "primary", "plus")

    self.btnBack = self:button(body, getText("IGUI_MSH_Manager_Back"), W.onBack, self, nil, "chevronLeft")
    self.btnRename = self:button(body, getText("IGUI_MSH_Manager_Rename"), W.onRename, self)
    self.tabs = UI.Tabs.new({ x = 0, y = 0, height = self.ch, theme = self.theme, target = self, onSelect = W.onTab,
        selected = "overview", items = {
            { id = "overview", label = getText("IGUI_MSH_Manager_TabOverview") },
            { id = "share", label = getText("IGUI_MSH_Manager_TabShare") },
            { id = "land", label = getText("IGUI_MSH_Manager_TabLand") } } })
    body:addChild(self.tabs)
    self.scroll = UI.ScrollPanel.new({ x = 0, y = 0, width = 200, height = 200, theme = self.theme })
    body:addChild(self.scroll)
    self.lines = self:newLines(self.scroll)
    self.btnDetails = self:button(self.scroll, getText("IGUI_MSH_Manager_Details"), W.onDetails, self, "ghost")
    self.btnShow = self:button(self.scroll, getText("IGUI_MSH_Manager_ShowInWorld"), W.onShow, self, nil, "locate")
    self.btnRedraw = self:button(self.scroll, "", W.onRedraw, self, nil, nil, 1)     -- 明示寬度：倒數不改寬
    self.btnRelease = self:button(self.scroll, getText("IGUI_MSH_Manager_Release"), W.onRelease, self, "danger")
    self.btnLeave = self:button(self.scroll, getText("IGUI_MSH_Manager_Leave"), W.onLeave, self, "danger")
    self.overviewWidgets = { self.btnDetails, self.btnShow, self.btnRedraw, self.btnRelease, self.btnLeave }
    self.share = MSH.SharingPage.new(self, self.scroll)

    self.btnQuery = self:button(body, getText("IGUI_MSH_Manager_QueryResult"), W.onQuery, self, "primary")
    self.btnDismiss = self:button(body, getText("IGUI_MSH_Manager_Dismiss"), W.onDismiss, self)
    self.hideable = { self.list, self.btnCreateEmpty, self.btnBack, self.btnRename, self.tabs, self.scroll, self.btnQuery,
        self.btnDismiss, self.btnRefresh, self.btnSlots, self.btnCreate, self.btnAdmin }

    -- 窄版門檻：詳細欄放不下最長的標籤加一個典型值（以目前字型量測，§10.3 Narrow）
    local lw = 0
    for _, k in ipairs(LABELS) do lw = math.max(lw, measure(getText("IGUI_MSH_Manager_Label_" .. k))) end
    self.labelW = lw
    self.needW = lw + MW.GAP * 2 + measure(getText("IGUI_MSH_Manager_RectValue", "00000", "00000", "00", "00", "0000"))
        + 12 + MW.PAD
    self.ready = true
end

-- ===== 清單 =====
function W:bindCell(cell, row, index)
    cell.row, cell.index = row, index
    local w = cell.width - 16
    local title = row.title or ""
    cell.title = self:fit(title, w)
    cell.tooltip = cell.title ~= title and title or nil
    local top = MW.statusCodes(row)
    local text = MW.statusText(top)
    if row.actorRole == "member" then
        text = getText("IGUI_MSH_Manager_RowMember", text, MSH.SharingPage.bitsText(row.bits or 0))
    end
    local ok = top == "PROTECTED"
    cell.icon, cell.token = ok and "check" or "warning", ok and "textMuted" or "warning"
    cell.sub = self:fit(text, w - self.iconW)
end

function W:fillList()
    local claims = MSH.Client.claims
    local rows = claims[self.area] or {}
    self.list:setItems(rows)
    local idx = nil
    for i, r in ipairs(rows) do
        if r.claimId == self.selectedId then idx = i end
    end
    self.list:setSelectedIndex(idx)
    self.areaTabs:setItemLabel("mine", getText("IGUI_MSH_Manager_AreaMine", #claims.mine))
    self.areaTabs:setItemLabel("shared", getText("IGUI_MSH_Manager_AreaShared", #claims.shared))
end

function W:refresh()
    if MSH.Client.claims.at == nil then self.listState = "loading" end
    MSH.Client.refreshList(function(res) self:onList(res) end)
end

-- 清單成功由 claims 事件處理（onClaims）；這裡只管失敗：沒有快取＝error 畫面，有快取＝照舊顯示、底部寫原因
function W:onList(res)
    if res.ok then return end
    if MSH.Client.claims.at == nil then
        self.listState, self.listCode = "error", res.code
        self:layout()
    else
        local reason, action = MSH.Client.codeText(res.code)
        self:say(action and (reason .. " " .. action) or reason, "errorText")
    end
end

-- 指定要選的那間（建立成功後 CreatePanel 呼叫 open{ claimId }）：清單裡出現才選
function W:applyWant()
    local id = self.wantId
    local row = id and MSH.Client.claims.byId[id]
    if row == nil then return end
    self.wantId = nil
    self.area = row.actorRole == "owner" and "mine" or "shared"
    self.areaTabs:setSelected(self.area, true)
    self.selectedId = nil
    self:select(id, self.wantTab)
    self.wantTab = nil
end

function W:onClaims()
    self.listState = "ready"
    self:applyWant()
    local sel = self.selectedId
    if sel ~= nil then
        local row = MSH.Client.claims.byId[sel]
        if row == nil then
            self:clearSelection()
        elseif self.detail and row.revision ~= self.detail.revision and self.busy == nil then
            self:loadDetail()
        end
    end
    self:fillList()
    self:autoSelect()
    self:layout()
end

-- 寬版沒有選取時選該區第一間
function W:autoSelect()
    if self.selectedId ~= nil or self.narrow then return end
    local rows = MSH.Client.claims[self.area] or {}
    if rows[1] == nil then return end
    self:select(rows[1].claimId)
    self.showDetail = false   -- 自動選的不算使用者點選：窄版仍停在清單
end

function W:clearSelection()
    if MW.overlay and MW.overlay.claimId == self.selectedId then MW.overlay = nil end
    self.selectedId, self.detail, self.detailState, self.detailRid = nil, nil, nil, nil
    self.redrawDeadline, self.redrawsLeft = nil, nil
    self.showDetail = false
end

function W:select(id, tab)
    if id == self.selectedId then
        if self.narrow and not self.showDetail then
            self.showDetail = true
            self:layout()
        end
        return
    end
    self.selectedId, self.detail, self.detailState = id, nil, nil
    self.tab = tab or "overview"
    self.expanded, self.showDetail = false, true
    self.scroll:setYScroll(0)
    self:fillList()
    self:loadDetail()
    self:layout()
end

-- ===== 詳情 =====
function W:loadDetail()
    local id = self.selectedId
    if id == nil then return end
    if not (self.detail and self.detail.claimId == id) then self.detailState = "loading" end
    local rid
    rid = MSH.Client.send("detail", { claimId = id }, function(res) self:onDetail(id, rid, res) end)
    self.detailRid = rid
end

function W:onDetail(id, rid, res)
    if id ~= self.selectedId or rid ~= self.detailRid then return end   -- 換選了或有更新的請求
    self.detailRid = nil
    if res.ok then
        self.detail, self.detailState = res, "ready"
        local left = res.actions and res.actions.redrawRemainingMs or 0
        self.redrawDeadline = (MSH.isFinite(left) and left > 0) and getTimestampMs() + left or nil
        self.redrawsLeft = res.actions and res.actions.redrawsLeft or nil
        self.redrawShown = nil
        if MW.overlay and MW.overlay.claimId == id then MW.setOverlay(res) end
    elseif res.code == "NOT_FOUND" then
        self:clearSelection()
        MSH.Client.refreshList()
    else
        self.detailState, self.detailCode = "error", res.code
    end
    self:layout()
end

function W:redrawLeft()
    return self.redrawDeadline and math.max(0, self.redrawDeadline - getTimestampMs()) or 0
end

-- ===== 送出（一次一筆；送出後 disable 到伺服器結果，§10.3）=====
-- okText：成功訊息；onOk(res)：成功時呼叫，回傳字串會取代 okText
function W:mutate(command, args, okText, onOk)
    if self.busy ~= nil then return false end
    self.busyCommand, self.okText, self.onOk = command, okText, onOk
    self.busy = MSH.Client.send(command, args, function(res) self:onMutation(res) end, { mutation = true })
    if self.busy == nil then return false end
    self:say(getText("IGUI_MSH_Manager_Waiting"), "textMuted")
    return true
end

function W:finishBusy()
    self.busy, self.pendingRid, self.busyCommand, self.okText, self.onOk = nil, nil, nil, nil, nil
end

function W:reload()
    MSH.Client.refreshList()
    self:loadDetail()
end

function W:onMutation(res)
    if res.requestId ~= self.busy then return end
    if res.code == "NO_REPLY" then
        if res.pending and not res.expired then
            -- result-pending：〔查詢結果〕用同一 requestId 重送；〔關閉〕只關這段提示，不取消伺服器上的動作
            self.pendingRid = res.requestId
            self:say(getText("IGUI_MSH_Manager_Pending"), "warning")
            return
        end
        -- 伺服器結果快取過期：不解讀為失敗，重抓清單與詳情、以伺服器現況為準（§10.4 result-pending）
        self:finishBusy()
        self:say(getText("IGUI_MSH_Manager_Expired"), "warning")
        self:reload()
        return
    end
    local command, okText, onOk = self.busyCommand, self.okText, self.onOk
    self:finishBusy()
    if res.ok then
        local text = onOk and onOk(res) or okText
        if command == "release" or (command == "leave" and not res.viaFaction) then self:clearSelection() end
        self:say(text, "text")
        self:reload()
    elseif res.code == "STALE_REVISION" then
        self:say(getText("IGUI_MSH_Manager_Stale"), "warning")
        self:loadDetail()
    else
        local reason, action = MSH.Client.codeText(res.code)
        self:say(action and (reason .. " " .. action) or reason, "errorText")
        if res.code == "NOT_FOUND" or res.code == "WRONG_LIFECYCLE" then self:reload() end
    end
end

function W:say(text, token)
    self.msg, self.msgToken = text, token or "text"
    self:layout()
end

-- ===== 繪製（Body:prerender；不配置，倒數每秒換一次標題字串）=====
function W:prerender(body)
    if self.dirty then
        self.dirty = false
        self:layout()
    end
    if self.wellX then self.theme:fill(body, self.wellX, self.wellY, self.wellW, self.wellH, "well") end
    local deadline = self.redrawDeadline
    if deadline == nil or not self.btnRedraw:getIsVisible() then return end
    local left = deadline - getTimestampMs()
    local sec = math.ceil(left / 1000)
    if sec == self.redrawShown then return end
    self.redrawShown = sec
    if left <= 0 then
        self.redrawDeadline = nil
        self.dirty = true
        return
    end
    self.btnRedraw:setTitle(MW.redrawTitle(left, self.redrawsLeft))
end

-- ===== 版面 =====
function W:layout()
    if not self.ready then return end
    local body, win = self.body, self.win
    local top = win:contentTop()
    body:setWidth(win.width)
    body:setHeight(win.height - top)
    local BW, BH = body.width, body.height
    local PAD, GAP, ch, fh = MW.PAD, MW.GAP, self.ch, self.fh
    local B = self.back
    B:clear()
    B:setWidth(BW)
    B:setHeight(BH)
    for _, el in ipairs(self.hideable) do el:setVisible(false) end
    self.wellX = nil

    -- 上列：左邊兩區分頁，右邊動作；放不下就把動作換到第二排
    local claims = MSH.Client.claims
    self:place(self.areaTabs, PAD, PAD)
    local right = { self.btnRefresh }
    if MSH.SlotsWindow then right[#right + 1] = self.btnSlots end
    if MSH.CreatePanel then right[#right + 1] = self.btnCreate end
    if MSH.AdminPanel and MW.isAdmin() then right[#right + 1] = self.btnAdmin end
    local need = 0
    for _, b in ipairs(right) do need = need + b.width + GAP end
    local by = PAD
    if PAD + self.areaTabs.width + GAP + need > BW - PAD then by = PAD + ch + GAP end
    local x = BW - PAD
    for _, b in ipairs(right) do
        x = x - b.width
        self:place(b, x, by)
        x = x - GAP
    end
    local mainTop = by + ch + PAD

    -- 頁尾：訊息最多兩行；結果待定時右邊〔查詢結果〕〔關閉〕
    local footH = math.max(ch, fh * 2)
    local footY = BH - PAD - footH
    local msgW = BW - PAD * 2
    if self.pendingRid then
        x = BW - PAD - self.btnDismiss.width
        self:place(self.btnDismiss, x, footY)
        x = x - GAP - self.btnQuery.width
        self:place(self.btnQuery, x, footY)
        msgW = x - GAP - PAD
    end
    if self.msg then
        local lines = self.UI.Text.wrap(self.msg, msgW, UIFont.Small)
        for i = 1, math.min(2, #lines) do B:add(lines[i], PAD, footY + (i - 1) * fh, self.msgToken) end
    end
    local mainH = footY - GAP - mainTop

    if self.listState == "ready" and #claims.mine + #claims.shared == 0 then
        return self:layoutEmpty(PAD, mainTop, BW - PAD * 2)
    end

    local listW = math.max(160, math.min(300, math.floor(BW * 0.34)))
    local dx, dw = PAD * 2 + listW, BW - PAD * 3 - listW
    self.narrow = dw < self.needW
    local showList, showDetail = true, true
    if self.narrow then
        listW, dx, dw = BW - PAD * 2, PAD, BW - PAD * 2
        showDetail = self.showDetail == true and self.selectedId ~= nil
        showList = not showDetail
    end
    if showList then self:layoutList(PAD, mainTop, listW, mainH) end
    if showDetail then self:layoutDetail(dx, mainTop, dw, mainH) end
end

function W:layoutList(x, y, w, h)
    local B, GAP = self.back, MW.GAP
    self.wellX, self.wellY, self.wellW, self.wellH = x, y, w, h
    local rows = MSH.Client.claims[self.area] or {}
    if self.listState == "loading" then
        B:add(getText("IGUI_MSH_Manager_Loading"), x + GAP, y + GAP, "textMuted")
    elseif self.listState == "error" then
        local reason, action = MSH.Client.codeText(self.listCode)
        local ny = self:addWrapped(B, reason, x + GAP, y + GAP, w - GAP * 2, "errorText")
        if action then self:addWrapped(B, action, x + GAP, ny, w - GAP * 2, "textMuted") end
    elseif #rows == 0 then
        self:addWrapped(B, getText("IGUI_MSH_Manager_AreaEmpty_" .. self.area), x + GAP, y + GAP, w - GAP * 2, "textMuted")
    else
        self:place(self.list, x, y)
        if self.list.width ~= w or self.list.height ~= h then self.list:resize(w, h) end
    end
end

-- 沒有任何安全屋：地契說明＋〔建立安全屋〕（§10.2）
function W:layoutEmpty(x, y, w)
    local B, GAP = self.back, MW.GAP
    y = self:addWrapped(B, getText("IGUI_MSH_Manager_EmptyTitle"), x, y, w, "text", UIFont.Medium) + GAP
    local free = MSH.Settings.get().createMode == MSH.Settings.CREATE.FREE
    y = self:addWrapped(B, getText(free and "IGUI_MSH_Manager_EmptyFree" or "IGUI_MSH_Manager_EmptyDeed"), x, y, w,
        "textMuted") + GAP * 2
    if MSH.CreatePanel then
        self.btnCreateEmpty:setEnabled(self.busy == nil)
        self:place(self.btnCreateEmpty, x, y)
    end
end

function W:layoutDetail(dx, y, dw, h)
    local B, GAP, ch = self.back, MW.GAP, self.ch
    local bottom = y + h
    if self.narrow then
        self:place(self.btnBack, dx, y)
        y = y + ch + GAP
    end
    local d = self.detail
    if self.selectedId == nil then
        B:add(getText("IGUI_MSH_Manager_PickOne"), dx, y, "textMuted")
        return
    end
    if d == nil then
        if self.detailState == "error" then
            local reason, action = MSH.Client.codeText(self.detailCode)
            local ny = self:addWrapped(B, reason, dx, y, dw, "errorText")
            if action then self:addWrapped(B, action, dx, ny, dw, "textMuted") end
        else
            B:add(getText("IGUI_MSH_Manager_Loading"), dx, y, "textMuted")
        end
        return
    end
    -- 標題：Text.wrap 換行、不截（§10.3）；屋主右上〔重新命名〕
    local a = d.actions or {}
    local titleW = dw
    if a.canRename then
        self.btnRename:setEnabled(self.busy == nil)
        self:place(self.btnRename, dx + dw - self.btnRename.width, y)
        titleW = dw - self.btnRename.width - GAP
    end
    local ny = self:addWrapped(B, d.title or "", dx, y, titleW, "text", UIFont.Medium)
    y = math.max(ny, a.canRename and y + ch or ny) + GAP
    -- 分頁：分享給我的只有概覽；帶 MANAGE 或 INVITE 多「成員與分享」；土地規則只給屋主（§10.3 第一點）
    local owner = d.actorRole == "owner"
    local canShare = MSH.SharingPage.canAdd(d)
    self.tabs:setItemVisible("share", canShare)
    self.tabs:setItemVisible("land", owner)
    if (self.tab == "share" and not canShare) or (self.tab == "land" and not owner) then self.tab = "overview" end
    self.tabs:setSelected(self.tab, true)
    self:place(self.tabs, dx, y)
    y = y + ch + GAP
    self:place(self.scroll, dx, y)
    self.scroll:setWidth(dw)
    self.scroll:setHeight(math.max(ch, bottom - y))
    local cw = self.scroll:contentWidth()
    for _, el in ipairs(self.overviewWidgets) do el:setVisible(false) end
    self.share:hide()
    self.lines:clear()
    local endY
    if self.tab == "share" then
        self.lines:setVisible(false)
        endY = self.share:layout(d, 0, 0, cw)
    else
        self:place(self.lines, 0, 0)
        endY = self.tab == "land" and self:layoutLand(d, cw) or self:layoutOverview(d, cw)
        self.lines:setWidth(cw)
        self.lines:setHeight(endY + MW.PAD)
    end
end

-- 一列「標籤　值」：值換行不截
function W:infoRow(L, labelKey, value, y, vx, vw, token)
    L:add(self:fit(getText("IGUI_MSH_Manager_Label_" .. labelKey), vx - MW.GAP), 0, y, "textMuted")
    return self:addWrapped(L, value, vx, y, vw, token or "text") + 4
end

function W:dateText(ms)
    local D = self.UI.Date
    if not (MSH.isFinite(ms) and D and D.fromMs and D.format) then return nil end
    local yy, mm, dd = D.fromMs(ms, D.localOffsetMinutes and D.localOffsetMinutes() or 0)
    return D.format(yy, mm, dd)
end

-- 概覽（§10.3 版面稿、§10.3「概覽」點）：角色、位置與面積、等級、canonical createdAt、狀態＋〔詳細〕、
--   〔在世界中顯示〕〔重新框選 · 剩 m:ss〕、危險操作
function W:layoutOverview(d, cw)
    local L, GAP, ch, fh = self.lines, MW.GAP, self.ch, self.fh
    local a = d.actions or {}
    local idle = self.busy == nil
    local vx = math.min(self.labelW + GAP * 2, math.floor(cw / 3))
    local vw = cw - vx
    local y = 0
    if d.actorRole == "owner" then
        y = self:infoRow(L, "Role", getText("IGUI_MSH_Manager_RoleOwner"), y, vx, vw)
    else
        y = self:infoRow(L, "Role", getText("IGUI_MSH_Manager_RoleMember", MSH.SharingPage.bitsText(d.bits or 0)), y, vx, vw)
        local o = type(d.roster) == "table" and d.roster[1] or nil
        if o and o.role == "owner" then y = self:infoRow(L, "Owner", o.user or "", y, vx, vw) end
    end
    local r = d.rect
    if type(r) == "table" then
        y = self:infoRow(L, "Location", getText("IGUI_MSH_Manager_RectValue", r.x, r.y, r.w, r.h, r.w * r.h), y, vx, vw)
    end
    if d.source == SRC.DEED then
        y = self:infoRow(L, "Source", getText("IGUI_MSH_Manager_SourceDeed", d.deedTier or "-"), y, vx, vw)
    elseif d.source == SRC.LEGACY then
        y = self:infoRow(L, "Source", getText("IGUI_MSH_Manager_SourceLegacy"), y, vx, vw)
    else
        y = self:infoRow(L, "Source", getText("IGUI_MSH_Manager_SourceFree"), y, vx, vw)
    end
    local eco = type(d.economy) == "table" and d.economy or nil
    if eco and eco.paid then y = self:infoRow(L, "Slot", getText("IGUI_MSH_Manager_SlotPaid", eco.tier or "-"), y, vx, vw) end
    local created = self:dateText(d.createdAt)
    if created then y = self:infoRow(L, "Created", created, y, vx, vw) end
    local releaseAt = eco and self:dateText(eco.releaseAt)
    if releaseAt then y = self:infoRow(L, "ReleaseAt", releaseAt, y, vx, vw, "warning") end

    -- 狀態：已保護＝打勾＋文字（不用綠色）；其他＝警告圖示＋warning 色；下一步在下方
    local top, rest = MW.statusCodes(d)
    local text, nextStep = MW.statusText(top)
    local ok = top == "PROTECTED"
    local textDy = math.floor((ch - fh) / 2)
    self.btnDetails:setTitle(getText(self.expanded and "IGUI_MSH_Manager_HideDetails" or "IGUI_MSH_Manager_Details"))
    self:place(self.btnDetails, cw - self.btnDetails.width, y)
    L:add(self:fit(getText("IGUI_MSH_Manager_Label_Status"), vx - GAP), 0, y + textDy, "textMuted")
    L:add(self:fit(text, cw - vx - self.btnDetails.width - GAP - self.iconW), vx, y + textDy, ok and "text" or "warning",
        ok and "check" or "warning")
    y = y + ch + 2
    if nextStep then y = self:addWrapped(L, nextStep, vx, y, vw, "textMuted") + 2 end
    if self.expanded then
        for _, code in ipairs(rest) do
            local t, n = MW.statusText(code)
            L:add(self:fit(t, vw - self.iconW), vx, y, "warning", "warning")
            y = y + fh + 2
            if n then y = self:addWrapped(L, n, vx, y, vw, "textMuted") + 2 end
        end
        if (top == "REPAIR_PAUSED" or top == "QUARANTINED") then
            y = self:infoRow(L, "Number", tostring(d.claimId), y, vx, vw)
        end
        y = self:addWrapped(L, getText("IGUI_MSH_Manager_KnownLimits"), vx, y, vw, "textMuted")
    end
    y = y + GAP * 2

    -- 動作：在世界中顯示（切換）、重新框選倒數（固定寬：以 0 取代數字量寬，§10.9）
    local acts = { self.btnShow }
    local shown = MW.overlay ~= nil and MW.overlay.claimId == d.claimId
    self.btnShow:setTitle(getText(shown and "IGUI_MSH_Manager_HideInWorld" or "IGUI_MSH_Manager_ShowInWorld"))
    local left = self:redrawLeft()
    if d.actorRole == "owner" and left > 0 and MSH.CreatePanel then
        local title = MW.redrawTitle(left, self.redrawsLeft)
        self.btnRedraw:setTitle(title)
        self.btnRedraw:setWidth(measure((string.gsub(title, "%d", "0"))) + 20)
        self.btnRedraw:setEnabled(idle)
        self.redrawShown = math.ceil(left / 1000)
        acts[#acts + 1] = self.btnRedraw
    end
    y = self:flow(acts, 0, y, cw) + GAP * 3

    -- 危險操作：屋主放棄；成員離開
    local danger = nil
    if a.canRelease then
        danger = self.btnRelease
    elseif d.actorRole == "member" and a.canLeave then
        danger = self.btnLeave
    end
    if danger then
        L:add(self:fit(getText("IGUI_MSH_Manager_Danger"), cw), 0, y, "textMuted")
        y = y + fh + GAP
        danger:setEnabled(idle)
        self:place(danger, 0, y)
        y = y + ch
    end
    return y
end

-- 土地規則（§10.3「土地規則」點）：新建與重新框選套用的間距、道路、資源點；legacy 與伺服器設定狀態
function W:layoutLand(d, cw)
    local L, GAP = self.lines, MW.GAP
    local cfg = MSH.Settings.get()
    local vx = math.min(self.labelW + GAP * 2, math.floor(cw / 3))
    local vw = cw - vx
    local y = self:addWrapped(L, getText("IGUI_MSH_Manager_LandIntro"), 0, 0, cw, "textMuted") + GAP
    y = self:infoRow(L, "Gap", getText("IGUI_MSH_Manager_GapValue", cfg.claimGap), y, vx, vw)
    local roads = getText("IGUI_MSH_Manager_Off")
    if cfg.avoidRoads then
        local names = {}
        for _, k in ipairs(MSH.Settings.ROAD_KINDS) do
            if cfg.roadKinds[k] then names[#names + 1] = getText("IGUI_MSH_Manager_Road_" .. k) end
        end
        roads = getText("IGUI_MSH_Manager_RoadsValue", table.concat(names, getText("IGUI_MSH_Share_ListSep")), cfg.roadMargin)
    end
    y = self:infoRow(L, "Roads", roads, y, vx, vw)
    local res = getText("IGUI_MSH_Manager_Off")
    if cfg.avoidResources then
        res = getText(cfg.resourceRule == MSH.Settings.RULE.ROOMS and "IGUI_MSH_Manager_ResourcesRooms"
            or "IGUI_MSH_Manager_ResourcesMinimap")
    end
    y = self:infoRow(L, "Resources", res, y, vx, vw)
    y = y + GAP
    if d.source == SRC.LEGACY then y = self:addWrapped(L, getText("IGUI_MSH_Manager_LegacyNote"), 0, y, cw, "textMuted") + GAP end
    if d.healthSummary == "SERVER_BLOCKED" then
        local t, n = MW.statusText("SERVER_BLOCKED")
        y = self:addWrapped(L, t, 0, y, cw, "warning")
        if n then y = self:addWrapped(L, n, 0, y, cw, "textMuted") end
    end
    return y
end

-- ===== 按鈕 =====
function W.onArea(self, id)
    self.area = id
    self:clearSelection()
    self:fillList()
    self:autoSelect()
    self:layout()
end

function W.onTab(self, id)
    self.tab = id
    self.scroll:setYScroll(0)
    self:layout()
end

function W.onRefresh(self)
    self:refresh()
    self:loadDetail()
end

function W.onCreate()
    if MSH.CreatePanel then MSH.CreatePanel.open({ mode = "create" }) end
end

function W.onSlots()
    if MSH.SlotsWindow then MSH.SlotsWindow.open({}) end
end

function W.onAdmin()
    if MSH.AdminPanel then MSH.AdminPanel.open({}) end
end

function W.onBack(self)
    self.showDetail = false
    self:layout()
end

function W.onDetails(self)
    self.expanded = not self.expanded
    self:layout()
end

function W.onShow(self)
    local d = self.detail
    if d == nil then return end
    if MW.overlay and MW.overlay.claimId == d.claimId then MW.setOverlay(nil) else MW.setOverlay(d) end
    self:layout()
end

-- 重新框選：建立面板 selecting（標題、等級同舊屋由 CreatePanel 處理，§7.6）
function W.onRedraw(self)
    local d = self.detail
    if d == nil or MSH.CreatePanel == nil then return end
    MSH.CreatePanel.open({ mode = "redraw", claimId = d.claimId, revision = d.revision, tier = d.deedTier,
        source = d.source })
end

function W.onRename(self)
    local d = self.detail
    if d == nil or self.busy ~= nil then return end
    self.UI.Dialog.show(MSH.Client.windowOpts(self.UI, { title = getText("IGUI_MSH_Manager_Rename"),
        text = getText("IGUI_MSH_Manager_RenameText"),
        theme = self.theme, input = { text = d.title or "" }, confirmText = getText("IGUI_MSH_Manager_RenameOk"),
        cancelText = getText("UI_Cancel"),
        onResult = function(ok, input)
            if not ok then return end
            local title = MSH.cleanTitle(input)
            if title == nil then
                local reason, action = MSH.Client.codeText("BAD_TITLE")
                return self:say(action and (reason .. " " .. action) or reason, "errorText")
            end
            self:mutate("rename", { claimId = d.claimId, title = title, expectedRevision = d.revision },
                getText("IGUI_MSH_Manager_Renamed"))
        end }))
end

-- 放棄：danger 確認框，確認鈕「放棄安全屋」、另一顆「取消」；只限屋主（§10.3）
function W.onRelease(self)
    local d = self.detail
    if d == nil or self.busy ~= nil then return end
    local parts = {}
    for i, k in ipairs(MW.releaseKeys(d, self:redrawLeft())) do parts[i] = getText(k) end
    self.UI.Dialog.show(MSH.Client.windowOpts(self.UI, { title = getText("IGUI_MSH_Manager_ReleaseTitle"),
        text = table.concat(parts, "\n"),
        theme = self.theme, danger = true, confirmText = getText("IGUI_MSH_Manager_ReleaseOk"),
        cancelText = getText("UI_Cancel"),
        onResult = function(ok)
            if ok then
                self:mutate("release", { claimId = d.claimId, expectedRevision = d.revision },
                    getText("IGUI_MSH_Manager_Released"))
            end
        end }))
end

function W.onLeave(self)
    local d = self.detail
    if d == nil or self.busy ~= nil then return end
    self.UI.Dialog.show(MSH.Client.windowOpts(self.UI, { title = getText("IGUI_MSH_Manager_LeaveTitle"),
        text = getText("IGUI_MSH_Manager_LeaveText", d.title or ""), theme = self.theme, danger = true,
        confirmText = getText("IGUI_MSH_Manager_LeaveOk"), cancelText = getText("UI_Cancel"),
        onResult = function(ok)
            if not ok then return end
            self:mutate("leave", { claimId = d.claimId }, getText("IGUI_MSH_Manager_Left"), function(res)
                if res.viaFaction then return getText("IGUI_MSH_Manager_LeftViaFaction") end
                return nil
            end)
        end }))
end

-- 結果待定：同一 requestId 重送；伺服器 60 秒內回快取的原結果（Client.retry）
function W.onQuery(self)
    if self.pendingRid and MSH.Client.retry(self.pendingRid) then
        self:say(getText("IGUI_MSH_Manager_Waiting"), "textMuted")
    end
end

-- 只收掉提示、不取消伺服器上的動作；重抓清單與詳情
function W.onDismiss(self)
    MSH.Client.forget(self.pendingRid)
    self:finishBusy()
    self.msg = nil
    self:reload()
    self:layout()
end

function W:onClose()
    MW.overlay = nil
end

function W:show(opts)
    local p = getSpecificPlayer(0)
    self.me = p and p:getUsername() or nil
    if not self.added then
        self.added = true
        self.win:addToUIManager()
    else
        self.win:setVisible(true)
        self.win:bringToTop()
    end
    if opts.claimId ~= nil then
        self.wantId, self.wantTab = opts.claimId, opts.tab
    elseif opts.tab ~= nil and self.selectedId ~= nil then
        self.tab = opts.tab
    end
    if MSH.Client.claims.at ~= nil then self.listState = "ready" end
    self:fillList()
    self:applyWant()
    self:autoSelect()
    self:refresh()
    self:layout()
end

-- ===== 最小直角 fallback（框架缺或版本不合）：原版 ISPanel／ISButton，只列清單與狀態 =====
-- ISPanel:new ISPanel.lua:96；ISButton:new ISButton.lua:479；drawText ISUIElement.lua:1293
function MW.fallbackRows()
    local rows = {}
    local claims = MSH.Client.claims
    for _, list in ipairs({ claims.mine, claims.shared }) do
        for _, row in ipairs(list) do
            rows[#rows + 1] = getText("IGUI_MSH_Manager_FallbackRow", row.title or "", (MW.statusText((MW.statusCodes(row)))))
        end
    end
    return rows
end

function MW.renderFallback(panel)
    local fh = getTextManager():getFontHeight(UIFont.Small)
    local w = MSH.Client.WARNING
    panel:drawText(getText("IGUI_MSH_Manager_Title"), 10, 8, 1, 1, 1, 1, UIFont.Small)
    panel:drawText(getText("IGUI_MSH_Manager_NeedFramework"), 10, 12 + fh, w.r, w.g, w.b, 1, UIFont.Small)
    local rows = MW.fallbackLines or {}
    for i = 1, #rows do panel:drawText(rows[i], 10, 20 + fh * (i + 1), 0.8, 0.8, 0.8, 1, UIFont.Small) end
end

function MW.openFallback()
    local f = MW.fallback
    if f == nil then
        local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
        local w, h = math.min(460, math.floor(sw * 0.9)), math.min(340, math.floor(sh * 0.9))
        f = ISPanel:new(math.floor((sw - w) / 2), math.floor((sh - h) / 2), w, h)
        f.moveWithMouse = true
        f:initialise()
        f.render = MW.renderFallback
        local btn = ISButton:new(w - 90, h - 32, 80, 24, getText("UI_Close"), f, function(o) o:setVisible(false) end)
        btn:initialise()
        f:addChild(btn)
        f:addToUIManager()
        MW.fallback = f
    end
    MW.fallbackLines = MW.fallbackRows()
    f:setVisible(true)
    MSH.Client.refreshList()
    return f
end

-- ===== 入口 =====
-- opts = { claimId?, tab? }（tab：overview／share／land；契約 M3「跨模組開窗」）
function MW.open(opts)
    opts = opts or {}
    local UI = MSH.Client.ui(MW.CAPS)
    if UI == nil then
        MSH.log("manager window: MinidoracatUI rev " .. tostring(MinidoracatUI and MinidoracatUI.v1
            and MinidoracatUI.v1.API_REVISION) .. " lacks required capabilities; using fallback")
        return MW.openFallback()
    end
    local w = MW.instance
    if w == nil or w.UI ~= UI then
        w = W.new(UI)
        MW.instance = w
    end
    w:show(opts)
    return w
end

function MW.isOpen()
    local w = MW.instance
    return w ~= nil and w.win:getIsVisible()
end

-- MSH.Client 事件：清單更新（含伺服器推送 changed 之後的重抓）時重排；選中那間被改了就重抓詳情
function MW.onClaims()
    if MW.fallback and MW.fallback:getIsVisible() then MW.fallbackLines = MW.fallbackRows() end
    if MW.isOpen() then MW.instance:onClaims() end
end

function MW.onChanged(args)
    local w = MW.instance
    if MW.isOpen() and type(args) == "table" and args.claimId == w.selectedId and w.busy == nil then w:loadDetail() end
end

if first then
    MSH.Client.on("claims", "ManagerWindow", function() MSH.ManagerWindow.onClaims() end)
    MSH.Client.on("changed", "ManagerWindow", function(args) MSH.ManagerWindow.onChanged(args) end)
    Events.OnPreUIDraw.Add(function() MSH.ManagerWindow.drawOverlay() end)
end
