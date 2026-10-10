-- MinidoracatSafehouse/SlotsWindow.lua：安全屋名額視窗（計畫 §10.7、§1.3）＋本 MOD 兩個視窗共用的小工具（kit：
--   文字標籤、以 key 重用元件的流式排版、框架不合時的最小直角 fallback；AdminPanel 也用）。
-- 摘要（免費位、各級名額、價格、販售開關）由伺服器 `slots` 一次回傳；Economy 客戶端 API 只對玩家展開的那一級
--   做 requestState／報價／付款／查單／自動續租（一次一個產品，§10.7）。
-- 付款照 VehicleManager BillingWindow（MinidoracatVehicleManager_BillingWindow.lua：onPay :1054、onQuote :1078、
--   purchase :1091、onPurchase :1121、onCheckOrder :1136、onOrder :1151）：確認頁金額＝伺服器摘要的價格；報價金額、幣別
--   一致才以同一張 quoteId 付款，不同就不付、重抓摘要並說明；付款逾時＝結果未知，不重送、不換報價，只「查詢購買結果」
--   （唯讀查同一筆 orderId），查回最終結果才解除付款鎖。畫面只顯示伺服器與 Economy 回來的狀態，不樂觀更新。
-- Economy 客戶端：MinidoracatEconomy.v1.Client（ECClient.lua:1339-1364）的 Entitlements
--   （ECEntitlementClient.lua：requestState :325、getState :338、quote :342、purchase :354、setAutoRenew :363、
--   getOrder :375、onChanged :383、errorText :410、stateText :434、orderOutcome :463、currencyName :485、remainingText :580）。
-- 原版：ISUIElement（client/ISUI/ISUIElement.lua：new :1965、initialise :13、drawText :1293、addChild :1451）、
--   ISPanel／ISButton（ISButton.lua:479）、getTextManager():MeasureStringX（ISButton.lua:233）、
--   getFontHeight（ISCollapsableWindow.lua:11）、getCore():getScreenWidth/Height、getTimestampMs。

if not isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Client"

local MSH = MinidoracatSafehouse
local first = MSH.SlotsWindow == nil
local SW = MSH.SlotsWindow or {}
MSH.SlotsWindow = SW
local K = SW.kit or {}
SW.kit = K

SW.SRC = MSH.MOD_ID                -- Economy source（Economy.lua registerSource 的 modId）
SW.CAPS = { "window", "controls", "dialog", "scrollPanel" }

-- ===== kit：標籤、流式排版、fallback =====
K.PAD, K.GAP = 10, 6

function K.fontH(font) return getTextManager():getFontHeight(font) end
function K.textW(font, s) return getTextManager():MeasureStringX(font, s) end

-- 文字標籤：沒有框架 Label 元件（ui-framework §0），自己畫；render 不配置任何東西
function K.newLabel()
    if K.Label == nil then
        K.Label = ISUIElement:derive("MinidoracatSafehouseLabel")
        function K.Label:render()
            local c = self.color
            self:drawText(self.text, 0, 0, c.r, c.g, c.b, c.a or 1, self.font)
        end
    end
    local l = K.Label:new(0, 0, 1, 1)
    l:initialise()
    l.text, l.font, l.color = "", UIFont.Small, { r = 1, g = 1, b = 1, a = 1 }
    return l
end

-- 換行：框架 Text.wrap（rev 16、textWrap）；沒有就截成一行（Text.fit，rev 11）
function K.wrap(UI, text, maxW, font)
    if UI.CAPABILITIES.textWrap and type(UI.Text.wrap) == "function" then return UI.Text.wrap(text, maxW, font) end
    if type(UI.Text.fit) == "function" then return { UI.Text.fit(text, maxW, font) } end
    return { text }
end

-- 以 key 重用元件的排版：每次 layout 從頭排，用到的顯示、這輪沒用到的藏起來（資料變了才排，不是每幀）
local Flow = K.Flow or {}
K.Flow = Flow
Flow.__index = Flow

function K.flow(parent, UI, theme)
    return setmetatable({ parent = parent, UI = UI, theme = theme, pool = {}, seen = {}, gen = 0, y = 0, width = 0 }, Flow)
end

function Flow:begin(width)
    self.gen, self.y, self.width = self.gen + 1, K.PAD, width
end

function Flow:get(key, make)
    local el = self.pool[key]
    if el == nil then
        el = make()
        self.parent:addChild(el)
        self.pool[key] = el
    end
    self.seen[key] = self.gen
    el:setVisible(true)
    return el
end

function Flow:finish()
    for key, el in pairs(self.pool) do
        if self.seen[key] ~= self.gen then el:setVisible(false) end
    end
end

function Flow:label(key, text, token, font)
    font = font or UIFont.Small
    local l = self:get(key, K.newLabel)
    local colors = self.theme.colors
    l.text, l.font, l.color = text, font, colors[token or "text"] or colors.text
    l:setWidth(K.textW(font, text))
    l:setHeight(K.fontH(font))
    return l
end

-- 一段文字（換行）放在目前位置，往下推
function Flow:text(key, text, token, font)
    font = font or UIFont.Small
    for i, line in ipairs(K.wrap(self.UI, text, self.width - 2 * K.PAD, font)) do
        local l = self:label(key .. "#" .. i, line, token, font)
        l:setX(K.PAD)
        l:setY(self.y)
        self.y = self.y + l.height + 2
    end
    self.y = self.y + K.GAP - 2
end

-- 一列元件由左至右，放不下換行；列內垂直置中
function Flow:row(ctrls, x0)
    x0 = x0 or K.PAD
    local x, rowY, rowH, line = x0, self.y, 0, {}
    local right = self.width - K.PAD
    for _, c in ipairs(ctrls) do
        if x > x0 and x + c.width > right then
            for _, d in ipairs(line) do d:setY(rowY + math.floor((rowH - d.height) / 2)) end
            rowY, x, rowH, line = rowY + rowH + K.GAP, x0, 0, {}
        end
        c:setX(x)
        line[#line + 1] = c
        x = x + c.width + K.GAP
        rowH = math.max(rowH, c.height)
    end
    for _, d in ipairs(line) do d:setY(rowY + math.floor((rowH - d.height) / 2)) end
    self.y = rowY + rowH + K.GAP
end

function Flow:button(key, title, target, onClick, style)
    local UI, theme = self.UI, self.theme
    local b = self:get(key, function()
        return UI.Button.new({ x = 0, y = 0, title = title, style = style, theme = theme, target = target, onClick = onClick })
    end)
    b:setTitle(title)
    b:fitWidth()
    return b
end

-- 開關＋標籤；寬度＝開關 36＋間距 8＋標籤（Controls.lua TOGGLE_WIDTH／LABEL_GAP）
function Flow:checkbox(key, label, target, onChange)
    local UI, theme = self.UI, self.theme
    local width = 48 + K.textW(UIFont.Small, label)
    local c = self:get(key, function()
        return UI.Checkbox.new({ x = 0, y = 0, width = width, label = label, theme = theme, target = target, onChange = onChange })
    end)
    c:setLabel(label)
    c:setWidth(width)
    return c
end

-- 框架缺席或能力不足：原版直角面板，只寫標題與「需要更新 Minidoracat UI 框架」（AGENTS.md 鐵則：不報錯、不消失）
function K.fallback(title, message)
    local core = getCore()
    local w, h = 460, 100
    local p = ISPanel:new(math.floor((core:getScreenWidth() - w) / 2), math.floor((core:getScreenHeight() - h) / 2), w, h)
    p:initialise()
    p.moveWithMouse = true
    p.title, p.message = title, message
    p.render = K.fallbackRender
    local b = ISButton:new(w - 90, h - 30, 80, 22, getText("UI_Close"), p, K.fallbackClose)
    b:initialise()
    p:addChild(b)
    p:addToUIManager()
    return nil
end

function K.fallbackRender(self)
    self:drawText(self.title, 10, 8, 1, 1, 1, 1, UIFont.Medium)
    self:drawText(self.message, 10, 40, 1, 1, 1, 1, UIFont.Small)
end

function K.fallbackClose(panel) panel:removeFromUIManager() end

function K.center(w, h)
    local core = getCore()
    w = math.min(w, core:getScreenWidth() - 20)
    h = math.min(h, core:getScreenHeight() - 20)
    return math.floor((core:getScreenWidth() - w) / 2), math.floor((core:getScreenHeight() - h) / 2), w, h
end

-- ===== 純邏輯（harness 測） =====

-- Economy 客戶端權益 facade（照 VM BU.api，BillingWindow.lua:25-34）；沒裝、舊版或沒有 rentals 能力回 nil
function SW.api()
    local EC = MinidoracatEconomy
    local CL = EC and EC.v1 and EC.v1.Client
    local caps = CL and CL.CAPABILITIES
    if CL and CL.API_MAJOR == 1 and (CL.API_REVISION or 0) >= 2 and type(caps) == "table"
        and caps.entitlements == true and caps.rentals == true and type(CL.Entitlements) == "table" then
        return CL.Entitlements, CL
    end
    return nil
end

SW.BLOCKERS = { OFF = "IGUI_MSH_Slots_SP", ABSENT = "IGUI_MSH_Slots_Absent", UNSUPPORTED = "IGUI_MSH_Slots_Unsupported",
    FAILED = "IGUI_MSH_Slots_Failed" }

-- 付費區不能用的原因（翻譯鍵），可用回 nil：伺服器整合狀態優先，其次本機 Economy 客戶端
function SW.blocker(slots, hasApi)
    if slots == nil then return "IGUI_MSH_Slots_Loading" end
    if slots.economy ~= "READY" then return SW.BLOCKERS[slots.economy] or "IGUI_MSH_Slots_Unsupported" end
    if not hasApi then return "IGUI_MSH_Slots_NoClient" end
    return nil
end

-- 報價與確認頁上的金額、幣別一致才付款（VM BU.quoteMatches :354）
function SW.quoteMatches(q, expect)
    return type(q) == "table" and type(expect) == "table" and q.amount == expect.amount and q.currency == expect.currency
end

-- 購買回覆 → 狀態鍵；伺服器拒絕回 nil（呼叫端顯示原因）。名額是 instant 商品，受理就是完成（VM BU.purchaseKey :62）
function SW.purchaseKey(res)
    if res.unknown or res.error == "timeout" then return "IGUI_MSH_Slots_NoAnswer" end
    if not res.ok then return nil end
    if res.duplicate then return "IGUI_MSH_Slots_Duplicate" end
    return "IGUI_MSH_Slots_PaidDone"
end

SW.OUTCOME = { paid = "IGUI_MSH_Slots_PaidDone", refunded = "IGUI_MSH_Slots_Refunded", not_paid = "IGUI_MSH_Slots_NoOrder" }

-- 查單回覆 → 最終結果鍵；不是同一筆或還沒有最終結果回 nil（付款鎖維持）
function SW.orderKey(res, pending, E)
    local order = type(res.order) == "table" and res.order or {}
    if pending == nil or order.orderId == nil or order.orderId ~= pending.orderId or res.known ~= true then return nil end
    return E and E.orderOutcome and SW.OUTCOME[E.orderOutcome(res)] or nil
end

-- 自動續租開著（已送出取消就算關，VM BU.autoRenewOn :282）
function SW.autoRenewOn(r)
    local s = r.autoRenewState
    if s == "pending_off" then return false end
    return r.autoRenew == true or s == "on" or s == "pending_on"
end

-- 本 MOD 的拒絕碼（validatePurchase 的 TIER_DISABLED／KIND_CLOSED）→ Economy 的錯誤文字 → 通用說明
function SW.reasonText(code, E)
    local key = "IGUI_MSH_Slots_Reason_" .. tostring(code)
    local t = getText(key)
    if t ~= key then return t end
    if E and E.errorText then return E.errorText(code) end
    return getText("IGUI_MSH_Slots_Failed")
end

function SW.money(E, price)
    local cur = price and price.currency
    local name = E and E.currencyName and E.currencyName(cur) or tostring(cur)
    return getText("IGUI_MSH_Slots_Money", price and price.amount or 0, name)
end

-- ===== 視窗 =====

function SW.open(opts)
    opts = opts or {}
    local UI = MSH.Client.ui(SW.CAPS)
    if UI == nil then return K.fallback(getText("IGUI_MSH_Slots_Title"), getText("IGUI_MSH_Slots_NeedFramework")) end
    local w = SW.instance
    if w == nil or w.UI ~= UI then
        w = SW.build(UI)
        SW.instance = w
    end
    if opts.tier ~= nil then w.expanded = opts.tier end
    w.win:setVisible(true)
    w.win:bringToTop()
    SW.listen()
    SW.refresh(w)
    SW.layout(w)
    return w
end

function SW.build(UI)
    local theme = MSH.Client.theme(UI)
    local x, y, W, H = K.center(480, 540)
    local w = { UI = UI, theme = theme, seen = {} }
    w.win = UI.Window.new({ x = x, y = y, width = W, height = H, title = getText("IGUI_MSH_Slots_Title"), theme = theme })
    local top = w.win:contentTop()
    w.body = UI.ScrollPanel.new({ x = 0, y = top, width = W, height = H - top, theme = theme })
    w.win:addChild(w.body)
    w.flow = K.flow(w.body, UI, theme)
    w.win:addToUIManager()
    return w
end

function SW.visible(w) return w ~= nil and w.win:isVisible() end

-- 本視窗關心的權益狀態指紋：權益／方案版本（Economy adopt 的排序鍵，ECEntitlementClient.lua:107-118）、usable、
-- 每張租約的 id／狀態／名額／自動續租狀態。只在推送時算，不在 render 裡
function SW.stateKey(env)
    local ent = type(env) == "table" and type(env.entitlement) == "table" and env.entitlement or {}
    local plan = type(env) == "table" and type(env.plan) == "table" and env.plan or {}
    local parts = { tostring(ent.revision), tostring(plan.revision), tostring(ent.usable) }
    for _, r in ipairs(type(ent.rentals) == "table" and ent.rentals or {}) do
        if type(r) == "table" then
            parts[#parts + 1] = tostring(r.id) .. ":" .. tostring(r.state) .. ":" .. tostring(r.quantity) .. ":"
                .. tostring(r.autoRenewState)
        end
    end
    return table.concat(parts, "|")
end

-- Economy 的 adopt 在版本相同、只是請求較新時照樣通知（ECEntitlementClient.lua:137-150），每個 requestState 回覆都會
-- 觸發 onChanged；通知又在回呼之前（onReply :277-280）。所以：自己這一級的 requestState 還在路上時收到的通知只記下指紋、
-- 重排，不重抓摘要（摘要剛跟這筆一起抓過）；其他通知只有指紋真的變了才重抓（VM PaidSlotsWindow.lua:865-868 同理）。
-- 指紋第一次出現（沒看過這一級）也算變了：可能是別的視窗付款後的推送。
function SW.onEconomyChanged(env)
    local w = SW.instance
    if not SW.visible(w) or type(env) ~= "table" or env.sourceMod ~= SW.SRC or type(env.productId) ~= "string" then return end
    local key = SW.stateKey(env)
    local prev = w.seen[env.productId]
    w.seen[env.productId] = key
    if prev ~= key and w.stateWaiting ~= env.productId then SW.refresh(w) end
    SW.layout(w)
end

function SW.listen()
    local E = SW.api()
    if E == nil or SW.listening == E then return end
    SW.listening = E
    E.onChanged(function(env) MSH.SlotsWindow.onEconomyChanged(env) end)
end

function SW.refresh(w)
    if w.loading then return end
    w.loading = true
    MSH.Client.send("slots", {}, function(res)
        w.loading = false
        if res.ok then
            w.slots, w.loadError = res, nil
        else
            w.loadError = res.code
        end
        SW.requestState(w)
        SW.layout(w)
    end)
end

function SW.product(tier) return "tier" .. tostring(tier) end

function SW.ready(w) return SW.blocker(w.slots, SW.api() ~= nil) == nil end

-- 只讀展開的那一級（Economy 每條指令一次一筆、間隔 650 ms，§10.7）
function SW.requestState(w)
    local E = SW.api()
    if E == nil or w.expanded == nil or not SW.ready(w) then return end
    w.stateError = nil
    local product = SW.product(w.expanded)
    w.stateWaiting = product
    local rid, why = E.requestState(SW.SRC, product, function(res)
        if w.stateWaiting == product then w.stateWaiting = nil end
        w.stateError = (res.unknown or not res.ok) and SW.reasonText(res.error or "timeout", E) or nil
        SW.layout(w)
    end)
    if rid == nil then
        w.stateWaiting = nil
        w.stateError = SW.reasonText(why or "invalid_args", E)
    end
end

function SW.say(w, text, token)
    w.message, w.messageToken = text, token or "text"
end

function SW.tierOf(w, tier)
    for _, t in ipairs(w.slots and w.slots.tiers or {}) do
        if t.tier == tier then return t end
    end
    return nil
end

function SW.canPurchase(w)
    return w.busy == nil and w.order == nil and SW.ready(w)
end

function SW.layout(w)
    if w.flow == nil then return end
    local F, s = w.flow, w.slots
    local E = SW.api()
    w.laidOutAt = getTimestampMs()
    F:begin(w.body:contentWidth())
    if s == nil then
        if w.loadError then
            F:text("load", (MSH.Client.codeText(w.loadError)), "errorText")
        else
            F:text("load", getText("IGUI_MSH_Slots_Loading"), "textMuted")
        end
        F:row({ F:button("refresh", getText("IGUI_MSH_Slots_Refresh"), w, SW.onRefresh) })
        return F:finish()
    end
    local free = s.free or {}
    F:text("free", getText("IGUI_MSH_Slots_Free", free.n or 0, free.used or 0), "text", UIFont.Medium)
    if type(free.titles) == "table" and #free.titles > 0 then
        F:text("freeTitles", getText("IGUI_MSH_Slots_FreeTitles", table.concat(free.titles, getText("IGUI_MSH_Slots_ListSep"))),
            "textMuted")
    end
    local blocker = SW.blocker(s, E ~= nil)
    if blocker then F:text("blocker", getText(blocker), "warning") end
    for _, t in ipairs(s.tiers or {}) do SW.layoutTier(w, F, t, E, blocker) end
    if w.busy then
        F:text("status", getText("IGUI_MSH_Slots_Busy"), "textMuted")
    elseif w.message then
        F:text("status", w.message, w.messageToken)
    end
    local bottom = {}
    if w.order ~= nil then bottom[#bottom + 1] = F:button("check", getText("IGUI_MSH_Slots_CheckOrder"), w, SW.onCheckOrder, "primary") end
    bottom[#bottom + 1] = F:button("refresh", getText("IGUI_MSH_Slots_Refresh"), w, SW.onRefresh)
    F:row(bottom)
    F:finish()
end

-- 一級：「N 級 · 名額 usable／使用 paid」、限制說明、〔買斷〕〔租用〕（該種販售關閉就不顯示）、〔租約〕展開
function SW.layoutTier(w, F, t, E, blocker)
    local n = t.tier
    F.y = F.y + K.GAP
    F:text("t" .. n, getText("IGUI_MSH_Slots_Tier", n, t.usable or 0, t.paid or 0), "text", UIFont.Medium)
    if (t.grace or 0) > 0 then F:text("g" .. n, getText("IGUI_MSH_Slots_Grace", t.grace), "warning") end
    if not t.free then F:text("nf" .. n, getText("IGUI_MSH_Slots_NoFree"), "textMuted") end
    if (t.perPlayer or 0) > 0 then F:text("pp" .. n, getText("IGUI_MSH_Slots_PerPlayer", t.perPlayer), "textMuted") end
    if blocker then return end
    local can = SW.canPurchase(w)
    local ctrls = {}
    if t.buy and t.buyPrice then
        local b = F:button("buy" .. n, getText("IGUI_MSH_Slots_Buy", SW.money(E, t.buyPrice)), w, SW.onBuy, "primary")
        b.internal = n
        b:setEnabled(can)
        ctrls[#ctrls + 1] = b
    end
    if t.rent and t.rentPrice then
        local b = F:button("rent" .. n, getText("IGUI_MSH_Slots_Rent", SW.money(E, t.rentPrice), t.rentPrice.days or 0), w,
            SW.onRent, "primary")
        b.internal = n
        b:setEnabled(can)
        ctrls[#ctrls + 1] = b
    end
    local open = w.expanded == n
    local x = F:button("x" .. n, getText(open and "IGUI_MSH_Slots_HideLeases" or "IGUI_MSH_Slots_ShowLeases"), w, SW.onExpand)
    x.internal = n
    ctrls[#ctrls + 1] = x
    F:row(ctrls)
    if open then SW.layoutLeases(w, F, n, E) end
end

-- 展開那一級的租約：逐張「剩多久」＋自動續租開關；寬限中或到期前可續租
function SW.layoutLeases(w, F, n, E)
    local env = E.getState(SW.SRC, SW.product(n))
    if w.stateError then return F:text("le" .. n, w.stateError, "errorText") end
    if type(env) ~= "table" then return F:text("le" .. n, getText("IGUI_MSH_Slots_Loading"), "textMuted") end
    local ent, plan = env.entitlement or {}, env.plan or {}
    local rentals = type(ent.rentals) == "table" and ent.rentals or {}
    if #rentals == 0 then return F:text("le" .. n, getText("IGUI_MSH_Slots_NoLeases"), "textMuted") end
    local now = getTimestampMs()
    for i, r in ipairs(rentals) do
        local key = "l" .. n .. ":" .. i
        local line
        if r.state == "grace" and type(r.graceUntil) == "number" then
            line = getText("IGUI_MSH_Slots_LeaseGrace", i, r.quantity or 0, E.remainingText(r.graceUntil - now))
        elseif r.state == "active" and type(r.paidUntil) == "number" then
            line = getText("IGUI_MSH_Slots_Lease", i, r.quantity or 0, E.remainingText(r.paidUntil - now))
        else
            line = getText("IGUI_MSH_Slots_LeaseState", i, r.quantity or 0, E.stateText(r.state))
        end
        F:text(key, line, r.state == "grace" and "warning" or "text")
        local ctrls = {}
        local on = SW.autoRenewOn(r)
        local box = F:checkbox(key .. "a", getText("IGUI_MSH_Slots_AutoRenew"), w, SW.onAutoRenew)
        box.internal, box.tier = r.id, n
        box:setChecked(on, true)
        box:setEnabled(w.busy == nil and (on or plan.autoRenewAllowed == true))
        ctrls[1] = box
        if (r.state == "active" or r.state == "grace") and plan.rentalEnabled == true then
            local b = F:button(key .. "r", getText("IGUI_MSH_Slots_Renew"), w, SW.onRenew)
            b.internal, b.tier = r.id, n
            b:setEnabled(SW.canPurchase(w))
            ctrls[2] = b
        end
        F:row(ctrls, K.PAD + 12)
    end
end

function SW.onRefresh(w)
    SW.say(w, nil)
    SW.refresh(w)
    SW.requestState(w)
    SW.layout(w)
end

function SW.onExpand(w, btn)
    w.expanded = w.expanded ~= btn.internal and btn.internal or nil
    SW.requestState(w)
    SW.layout(w)
end

-- 確認頁（框架 Dialog）：金額＝伺服器摘要的價格，也是報價要對上的值
function SW.confirm(w, text, onOk)
    w.UI.Dialog.show({ title = getText("IGUI_MSH_Slots_Title"), text = text, theme = w.theme,
        confirmText = getText("IGUI_MSH_Slots_Pay"), cancelText = getText("UI_Cancel"),
        onResult = function(ok) if ok then onOk() end end })
end

function SW.onBuy(w, btn)
    local t = SW.tierOf(w, btn.internal)
    if t == nil or t.buyPrice == nil or not SW.canPurchase(w) then return end
    local price = t.buyPrice
    SW.confirm(w, getText("IGUI_MSH_Slots_ConfirmBuy", t.tier, SW.money(SW.api(), price)), function()
        SW.startQuote(w, t.tier, "permanent", 1, { amount = price.amount, currency = price.currency })
    end)
end

function SW.onRent(w, btn)
    local t = SW.tierOf(w, btn.internal)
    if t == nil or t.rentPrice == nil or not SW.canPurchase(w) then return end
    local price = t.rentPrice
    SW.confirm(w, getText("IGUI_MSH_Slots_ConfirmRent", t.tier, SW.money(SW.api(), price), price.days or 0), function()
        SW.startQuote(w, t.tier, "rental", 1, { amount = price.amount, currency = price.currency })
    end)
end

-- 續租：伺服器依該張租約的名額報價（數量不送）；確認金額＝目前租金 × 該張名額
function SW.onRenew(w, btn)
    local E = SW.api()
    local env = E and E.getState(SW.SRC, SW.product(btn.tier))
    local plan = type(env) == "table" and env.plan or nil
    local r = SW.findRental(env, btn.internal)
    if plan == nil or r == nil or not SW.canPurchase(w) then return end
    local expect = { amount = (plan.rentalPrice or 0) * (r.quantity or 1), currency = plan.rentalCurrency }
    SW.confirm(w, getText("IGUI_MSH_Slots_ConfirmRenew", btn.tier, SW.money(E, expect), plan.rentalDays or 0), function()
        SW.startQuote(w, btn.tier, "rental", nil, expect, r.id)
    end)
end

function SW.findRental(env, id)
    local ent = type(env) == "table" and env.entitlement or nil
    for _, r in ipairs(ent and type(ent.rentals) == "table" and ent.rentals or {}) do
        if r.id == id then return r end
    end
    return nil
end

function SW.refuse(w, why)
    w.busy = nil
    SW.say(w, SW.reasonText(why or "invalid_args", SW.api()), "errorText")
end

function SW.startQuote(w, tier, kind, quantity, expect, rental)
    local E = SW.api()
    if E == nil or not SW.canPurchase(w) then return end
    w.busy, w.pay = "quote", { tier = tier, expect = expect }
    SW.say(w, nil)
    local rid, why = E.quote(SW.SRC, SW.product(tier), kind, quantity, function(res) SW.onQuote(w, res) end, rental)
    if rid == nil then SW.refuse(w, why) end
    SW.layout(w)
end

-- 報價回來：金額、幣別等於確認頁的才付款；不同（方案剛改）不付、重抓摘要並說明新價格
function SW.onQuote(w, res)
    w.busy = nil
    local p = w.pay
    if res.unknown then
        SW.say(w, getText("IGUI_MSH_Slots_QuoteNoAnswer"), "errorText")
    elseif not res.ok or type(res.quote) ~= "table" then
        SW.say(w, SW.reasonText(res.error, SW.api()), "errorText")
    elseif p ~= nil and not SW.quoteMatches(res.quote, p.expect) then
        SW.say(w, getText("IGUI_MSH_Slots_PriceChanged", SW.money(SW.api(), res.quote)), "warning")
        SW.refresh(w)
    elseif p ~= nil then
        return SW.purchase(w, res.quote)
    end
    SW.layout(w)
end

-- 付款前先記下伺服器指定的 orderId；之後只查這一筆，不用其他訂單猜結果
function SW.purchase(w, q)
    local E = SW.api()
    if E == nil or not SW.canPurchase(w) then return SW.layout(w) end
    w.busy = "purchase"
    w.order = { quoteId = q.id, orderId = q.orderId, tier = w.pay and w.pay.tier }
    local rid, why = E.purchase(SW.SRC, q.id, function(res) SW.onPurchase(w, res) end)
    if rid == nil then
        w.order = nil
        SW.refuse(w, why)
    end
    SW.layout(w)
end

function SW.onPurchase(w, res)
    w.busy = nil
    local key = SW.purchaseKey(res)
    local o = w.order
    if key == nil then
        w.order = nil
        SW.say(w, SW.reasonText(res.error, SW.api()), "errorText")
    elseif key == "IGUI_MSH_Slots_NoAnswer" then
        if o and res.orderId and o.orderId == nil then o.orderId = res.orderId end
        SW.say(w, getText(key), "warning")
    else
        SW.finish(w, key)
    end
    SW.layout(w)
end

function SW.finish(w, key)
    w.order = nil
    SW.say(w, getText(key), "text")
    SW.refresh(w)
    SW.requestState(w)
end

-- 查詢購買結果：唯讀查同一筆（沒有 orderId 時查原 quoteId），絕不重送購買
function SW.onCheckOrder(w)
    local E = SW.api()
    local o = w.order
    if E == nil or w.busy or o == nil then return end
    local id = o.orderId or o.quoteId
    w.busy = "order"
    SW.say(w, nil)
    local rid, why = E.getOrder(SW.SRC, SW.product(o.tier), id, function(res) SW.onOrder(w, res, id) end)
    if rid == nil then SW.refuse(w, why) end
    SW.layout(w)
end

function SW.onOrder(w, res, requestedId)
    w.busy = nil
    local pending = w.order
    if res.unknown then
        SW.say(w, getText("IGUI_MSH_Slots_NoAnswer"), "warning")
    elseif not res.ok then
        SW.say(w, SW.reasonText(res.error, SW.api()), "errorText")
    else
        local order = type(res.order) == "table" and res.order or {}
        if pending and pending.orderId == nil and requestedId == pending.quoteId and res.known == true then
            pending.orderId = order.orderId
        end
        local key = SW.orderKey(res, pending, SW.api())
        if key then
            SW.finish(w, key)
        else
            SW.say(w, getText("IGUI_MSH_Slots_NoAnswer"), "warning")
        end
    end
    SW.layout(w)
end

-- 勾選只跟伺服器：點擊後先還原；關閉直接送，開啟先在確認框同意這張租約的續租條款
function SW.onAutoRenew(w, checked, box)
    local E = SW.api()
    local env = E and E.getState(SW.SRC, SW.product(box.tier))
    local r = SW.findRental(env, box.internal)
    local on = r ~= nil and SW.autoRenewOn(r)
    box:setChecked(on, true)
    if r == nil or w.busy or checked == on then return end
    local plan, ent = env.plan or {}, env.entitlement or {}
    if not checked then return SW.sendAutoRenew(w, box.tier, false, ent.revision, plan.revision, r.id) end
    if plan.autoRenewAllowed ~= true then return end
    local price = { amount = (plan.rentalPrice or 0) * (r.quantity or 1), currency = plan.rentalCurrency }
    w.UI.Dialog.show({ title = getText("IGUI_MSH_Slots_Title"), theme = w.theme,
        text = getText("IGUI_MSH_Slots_ConfirmAuto", SW.money(E, price), plan.rentalDays or 0),
        confirmText = getText("IGUI_MSH_Slots_Agree"), cancelText = getText("UI_Cancel"),
        onResult = function(ok)
            if ok then SW.sendAutoRenew(w, box.tier, true, ent.revision, plan.revision, r.id) end
        end })
end

function SW.sendAutoRenew(w, tier, enabled, revision, termsRevision, rental)
    local E = SW.api()
    if E == nil or w.busy then return end
    w.busy = "auto"
    SW.say(w, nil)
    local rid, why = E.setAutoRenew(SW.SRC, SW.product(tier), enabled, revision, termsRevision, function(res)
        w.busy = nil
        if res.unknown then
            E.requestState(SW.SRC, SW.product(tier))
            SW.say(w, getText("IGUI_MSH_Slots_AutoRenewUnknown"), "warning")
        elseif not res.ok then
            SW.say(w, SW.reasonText(res.error, E), "errorText")
        end
        SW.layout(w)
    end, rental)
    if rid == nil then SW.refuse(w, why) end
    SW.layout(w)
end

-- 剩餘時間每分鐘重排一次（不是每幀）
function SW.onTick()
    local w = SW.instance
    if SW.visible(w) and w.laidOutAt ~= nil and getTimestampMs() - w.laidOutAt >= 60000 then SW.layout(w) end
end

if first then
    Events.OnTick.Add(function() MSH.SlotsWindow.onTick() end)
end
