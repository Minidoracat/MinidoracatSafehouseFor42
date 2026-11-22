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

-- 自動續租開著（已送出取消就算關；暫停也算開，玩家才能取消。VM BU.autoRenewOn :282）
function SW.autoRenewOn(r)
    local s = r.autoRenewState
    if s == "pending_off" then return false end
    return r.autoRenew == true or s == "on" or s == "pending_on" or s == "paused_terms" or s == "paused_system"
end

-- 同意時記下的條款（autoTerms）和目前方案的租金、幣別、天數不同（VM BU.termsDiffer :293）
function SW.termsDiffer(plan, t)
    return type(t) == "table"
        and (t.price ~= plan.rentalPrice or t.currency ~= plan.rentalCurrency or t.days ~= plan.rentalDays)
end

-- 開著但到期不會扣款：條款改了、超過上限、停租、不再提供自動續租或系統暫停（VM BU.autoPaused :299）
function SW.autoPaused(plan, r)
    if not SW.autoRenewOn(r) then return false end
    local s = r.autoRenewState
    return s == "paused_terms" or s == "paused_system" or SW.termsDiffer(plan, r.autoTerms)
        or plan.rentalEnabled ~= true or plan.autoRenewAllowed ~= true
end

-- 要玩家重新同意目前條款才會續租（VM BU.needsConsent :307）。2026-11-15 正式服：改價後只顯示「開著」，到期沒扣款就停用
function SW.needsConsent(plan, r)
    return SW.autoRenewOn(r) and SW.termsDiffer(plan, r.autoTerms) and plan.rentalEnabled == true
        and plan.autoRenewAllowed == true
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
    local w = { UI = UI, theme = theme }
    w.win = UI.Window.new(MSH.Client.windowOpts(UI, { x = x, y = y, width = W, height = H,
        title = getText("IGUI_MSH_Slots_Title"), theme = theme }))
    local top = w.win:contentTop()
    w.body = UI.ScrollPanel.new({ x = 0, y = top, width = W, height = H - top, theme = theme })
    w.win:addChild(w.body)
    w.flow = K.flow(w.body, UI, theme)
    w.win:addToUIManager()
    return w
end

function SW.visible(w) return w ~= nil and w.win:isVisible() end

-- 摘要什麼時候重抓：伺服器那邊有東西變了才抓，自己讀 Economy 的回覆不抓——
--   Economy 推送 entitlement.changed（付款、續租、進寬限、到期、退款；管理員改方案的公開通知）：Economy 客戶端 onPush
--     （entitlements-api.md「客戶端 API」，ECEntitlementClient.lua:301-321）；
--   自己的安全屋清單重抓了（建立、放棄、進保留期、恢復：Client 事件 "claims"）、沙盒變了（"sandbox"）。
-- 名額視窗或建立面板開著才抓（兩邊都從 "slots" 事件更新；同時一筆、間隔由 Client.refreshSlots 管）。onChanged 是每個
-- 採用的快照（含自己 requestState 的回覆，ECEntitlementClient.lua:137-150），只重排、不重抓，所以不會自己觸發自己。
-- 2026-10-13 前用「狀態指紋變了才重抓」：展開的那一級正在讀狀態時，別處來的推送會被當成自己的回覆略過
function SW.slotsChanged()
    if SW.visible(SW.instance) or (MSH.CreatePanel ~= nil and MSH.CreatePanel.model ~= nil) then MSH.Client.refreshSlots() end
end

function SW.onEconomyPush(args)
    if type(args) ~= "table" or (args.sourceMod ~= nil and args.sourceMod ~= SW.SRC) then return end
    SW.slotsChanged()
end

function SW.onEconomyChanged(env)
    if type(env) ~= "table" or env.sourceMod ~= SW.SRC then return end
    SW.leaseNotice(env)
    local w = SW.instance
    if w == nil then return end
    SW.tryAutoOffer(w)
    if SW.visible(w) then SW.layout(w) end
end

-- ===== 租約通知（純客戶端）：Economy 寫進快照的 notice（ECEntitlements.lua visitLease／tryRenew），錢包推送與
-- requestState 會帶同一個 notice 再觸發 onChanged，同一件事只跳一次。同一輪走訪的事件共用同一個 now（進寬限與緊接的
-- 扣款失敗、兩張租約同一輪到期都一樣），所以 at 不能單獨當識別，要連租約、原因碼、錯誤一起比。第一次看到某產品只記
-- 基準（登入前的事由登入摘要講）；登入摘要讀完前變了的先不記，結算時拿最新快照再比（SW.endSummary）
SW.noticeSeen = SW.noticeSeen or {}
SW.failShown = SW.failShown or {}   -- 租約 id → 已經講過的扣款失敗原因
SW.LEASE_NOTICE = { renewal_due = true, grace = true, expired = true, renewal_failed = true }

function SW.tierOfEnv(env)
    return type(env.productId) == "string" and tonumber(string.match(env.productId, "^tier(%d+)$")) or nil
end

function SW.leaseNotice(env)
    local tier = SW.tierOfEnv(env)
    local n = type(env.entitlement) == "table" and env.entitlement.notice or nil
    if tier == nil then return end
    n = type(n) == "table" and n or {}
    local key = n.at ~= nil and table.concat({ tostring(n.rental), tostring(n.code), tostring(n.at), tostring(n.error) }, "|")
        or ""
    local last = SW.noticeSeen[env.productId]
    if last ~= nil and not SW.noticeReady then return end
    SW.noticeSeen[env.productId] = key
    if key == "" or key == last then return end
    -- 寬限中每小時重試扣款都會寫一次新的 renewal_failed：同一張、同一原因只講第一次；這張有別的事就重新算。
    -- 基準（登入前就失敗的）也要記，否則登入後下一次重試會再講一次。
    -- 不是針對某張租約的 notice（例如 refunded）沒有 rental，不能拿來當鍵
    if n.rental ~= nil then
        if n.code == "renewal_failed" then
            if SW.failShown[n.rental] == n.error then return end
            SW.failShown[n.rental] = n.error
        else
            SW.failShown[n.rental] = nil
        end
    end
    if last == nil or not SW.LEASE_NOTICE[n.code] then return end
    local E = SW.api()
    local r = SW.findRental(env, n.rental)
    local now = getTimestampMs()
    local text
    if n.code == "renewal_failed" then
        text = getText("IGUI_MSH_Lease_renewal_failed", tier, E and E.errorText(n.error) or tostring(n.error))
    else
        -- 開著自動續租的租約：進寬限的同一刻就會扣款（成功沒事、失敗另有 renewal_failed）；暫停中的由 Economy 自己提醒
        if r ~= nil and SW.autoRenewOn(r) then return end
        local untilMs = r and r[n.code == "grace" and "graceUntil" or "paidUntil"]
        local left = (E and type(untilMs) == "number") and E.remainingText(math.max(0, untilMs - now)) or "-"
        text = getText("IGUI_MSH_Lease_" .. n.code, tier, left)
    end
    MSH.Client.toast(text, nil, getText("IGUI_MSH_Lease_Title"))
end

-- 登入摘要（每次進遊戲一次，不存檔）：安全屋第一份清單成功（login(true)）後讀這個登入的全部產品，合成一則數字：
-- 保留期中的屋、寬限中的名額、快到期又不會自動續的名額（細節在名額視窗；Toast 最多 5 行，逐級列會把後面的切掉）。
-- 清單被截（more）就補讀沒列到的級別：回了快照（沒有租約也算）才算讀到，逾時、排不進佇列的隔 SUMMARY_RETRY_MS 只補
-- 那些，各 SUMMARY_TRIES 次；到上限還有讀不到的，加一句註明數字不完整。保留期屋數是本 MOD 自己的清單，照常講。
-- SW.summary：nil 還沒開始、"reading" 讀取中、"done" 講完或放棄（之後通知才跳）
SW.SUMMARY_TRIES, SW.SUMMARY_RETRY_MS = 3, 5000
-- 付過的期間還沒過（paused_*：付了錢但到期不會續，ECEntitlements.lua rentalState）
SW.PAID_STATES = { active = true, paused_terms = true, paused_system = true }

function SW.onLogin(ok)
    if SW.summary ~= nil then return end
    SW.summary = "reading"
    SW.listen()
    if not ok then return SW.endSummary(nil) end
    SW.sumEnvs, SW.sumMissing = {}, {}
    SW.readSummary(1)
end

-- 排下一次（SW.onTick 到時間呼叫）；到上限回 false
function SW.retrySummary(try, fn)
    if try >= SW.SUMMARY_TRIES then return false end
    SW.summaryRetryAt, SW.summaryRetry = getTimestampMs() + SW.SUMMARY_RETRY_MS, function() fn(try + 1) end
    return true
end

function SW.readSummary(try)
    local E = SW.api()
    if E == nil or type(E.requestList) ~= "function" then return SW.endSummary(SW.sumEnvs, false) end
    local rid = E.requestList(function(res) SW.onSummaryList(res, try) end)
    if rid == nil and not SW.retrySummary(try, SW.readSummary) then SW.endSummary(SW.sumEnvs, true) end
end

-- 只用這次回覆本身：失敗時 getList 還留著上一份成功的清單；逾時後晚到的回覆只更新快取、不再回呼
function SW.onSummaryList(res, try)
    if type(res) ~= "table" or res.ok ~= true or type(res.entries) ~= "table" then
        if not SW.retrySummary(try, SW.readSummary) then SW.endSummary(SW.sumEnvs, true) end
        return
    end
    local seen = {}
    for _, env in ipairs(res.entries) do
        local tier = type(env) == "table" and env.sourceMod == SW.SRC and SW.tierOfEnv(env)
        if tier then SW.sumEnvs[env.productId], seen[tier] = env, true end
    end
    if res.more ~= true then return SW.endSummary(SW.sumEnvs, false) end
    -- 清單跨所有 MOD 只回前 LIST_MAX 個產品（ECEntitlements.lua entitlement.list 的 more）
    for t = 1, MSH.MAX_TIER do
        if not seen[t] then SW.sumMissing[t] = true end
    end
    SW.readMissing(1)
end

-- 一輪補讀還缺的級別，這輪全部回來才決定結算或再補
function SW.readMissing(try)
    local E = SW.api()
    local waiting = 1
    local function done()
        waiting = waiting - 1
        if waiting > 0 then return end
        -- Kahlua 沒有 next()
        for _ in pairs(SW.sumMissing) do
            if not SW.retrySummary(try, SW.readMissing) then SW.endSummary(SW.sumEnvs, true) end
            return
        end
        SW.endSummary(SW.sumEnvs, false)
    end
    for t in pairs(SW.sumMissing) do
        waiting = waiting + 1
        local product = SW.product(t)
        local rid = E and E.requestState(SW.SRC, product, function(env)
            if type(env) == "table" and env.ok ~= false and type(env.entitlement) == "table" then
                SW.sumEnvs[product], SW.sumMissing[t] = env, nil
            end
            done()
        end)
        if not rid then done() end
    end
    done()
end

-- envs：productId → 讀到的快照（nil＝安全屋清單都沒有，不講）；unknown：有級別讀不到
function SW.endSummary(envs, unknown)
    SW.summary, SW.noticeReady, SW.summaryRetryAt, SW.summaryRetry = "done", true, nil, nil
    SW.sumEnvs, SW.sumMissing = nil, nil
    local E = SW.api()
    if envs ~= nil then SW.sayLoginSummary(E, envs, unknown) end
    -- 讀取期間變了的 notice（leaseNotice 先沒記）：拿最新採用的快照補講
    for product in pairs(SW.noticeSeen) do
        local env = E and E.getState(SW.SRC, product)
        if type(env) == "table" then SW.leaseNotice(env) end
    end
end

function SW.sayLoginSummary(E, envs, unknown)
    local now = getTimestampMs()
    local lapsed, grace, due = 0, 0, 0
    for _, row in ipairs(MSH.Client.claims.mine) do
        if row.lifecycle == MSH.LIFECYCLE.LAPSED then lapsed = lapsed + 1 end
    end
    for product, env in pairs(envs) do
        -- 等其他級別期間可能又推來新快照：用最新採用的
        env = E and E.getState(SW.SRC, product) or env
        local plan = env.plan or {}
        local remind = (tonumber(plan.reminderHours) or 0) * 3600000
        local ent = type(env.entitlement) == "table" and env.entitlement or {}
        for _, r in ipairs(type(ent.rentals) == "table" and ent.rentals or {}) do
            -- 一張租約可以是好幾個名額（伺服器 Economy.lua leases 也照 quantity 算）
            local q = tonumber(r.quantity) or 1
            if r.state == "grace" then
                grace = grace + q
            elseif SW.PAID_STATES[r.state] and type(r.paidUntil) == "number" and r.paidUntil - now <= remind
                and not (SW.autoRenewOn(r) and not SW.autoPaused(plan, r)) then
                due = due + q
            end
        end
    end
    local parts = {}
    if lapsed > 0 then parts[#parts + 1] = getText("IGUI_MSH_Lease_SumLapsed", lapsed) end
    -- 放在數字前面：Toast 切掉的是後面的句子，這句不能被切
    if unknown then parts[#parts + 1] = getText("IGUI_MSH_Lease_SumUnknown") end
    if grace > 0 then parts[#parts + 1] = getText("IGUI_MSH_Lease_SumGrace", grace) end
    if due > 0 then parts[#parts + 1] = getText("IGUI_MSH_Lease_SumDue", due) end
    -- 框架 Toast 不認 "\n"（Toast.lua wrapText 只走 TextWrap.cut），以空白接成一段再自動換行
    if #parts > 0 then MSH.Client.toast(table.concat(parts, " "), nil, getText("IGUI_MSH_Lease_Title"), 5) end
end

-- 登入（SW.onLogin，租約通知要整局聽）、名額視窗打開、建立面板打開時各試一次；同一個 Economy 客戶端只登記一次。onPush 是
-- Economy 0.15.0 起才有（錢包「名額」分頁）：更舊的沒有推送觸發，只剩本視窗自己付款後重抓
function SW.listen()
    local E = SW.api()
    if E == nil or SW.listening == E then return end
    SW.listening = E
    E.onChanged(function(env) MSH.SlotsWindow.onEconomyChanged(env) end)
    if type(E.onPush) == "function" then E.onPush(function(args) MSH.SlotsWindow.onEconomyPush(args) end) end
end

-- 摘要由 Client.refreshSlots 抓（同時一筆、上一筆回覆後滿 SLOTS_GAP_MS 才送下一筆、連續要求只補抓一次），結果從
-- "slots" 事件回來（SW.onSlots）
function SW.refresh(w)
    MSH.Client.refreshSlots()
end

function SW.onSlots(res)
    local w = SW.instance
    if w == nil then return end
    if res.ok then
        w.slots, w.loadError = res, nil
    else
        w.loadError = res.code
    end
    if not SW.visible(w) then return end
    SW.requestState(w)
    SW.layout(w)
end

function SW.product(tier) return "tier" .. tostring(tier) end

function SW.ready(w) return SW.blocker(w.slots, SW.api() ~= nil) == nil end

-- 只讀展開的那一級（Economy 每條指令一次一筆、間隔 650 ms，§10.7）
function SW.requestState(w)
    local E = SW.api()
    if E == nil or w.expanded == nil or not SW.ready(w) then return end
    w.stateError = nil
    local rid, why = E.requestState(SW.SRC, SW.product(w.expanded), function(res)
        w.stateError = (res.unknown or not res.ok) and SW.reasonText(res.error or "timeout", E) or nil
        SW.layout(w)
    end)
    if rid == nil then w.stateError = SW.reasonText(why or "invalid_args", E) end
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

-- 付款流程（startQuote 到 onOrder）也給管理視窗的閒置保險用（ManagerWindow insurePayer）：w 可以帶 productId（產品 id，
-- 沒有就 tier<N>）、ready(w)、relayout(w)、refresh(w)（報價變了、付款有結果時重抓）、texts（結果鍵換成自己的說法）
function SW.canPurchase(w)
    return w.busy == nil and w.order == nil and (w.ready or SW.ready)(w)
end

function SW.relayout(w) return (w.relayout or SW.layout)(w) end
function SW.reload(w) return (w.refresh or SW.refresh)(w) end

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
    local blocker = SW.blocker(s, E ~= nil)
    if blocker then F:text("blocker", getText(blocker), "warning") end
    -- 重抓失敗時畫面上是上一次的數字：說出來，不讓舊值看起來像最新的
    if w.loadError then F:text("loadErr", (MSH.Client.codeText(w.loadError)), "warning") end
    if w.msgTier == nil then SW.layoutStatus(w, F, "status") end
    local shown = false
    for _, t in ipairs(s.tiers or {}) do
        if SW.tierShown(t) then
            SW.layoutTier(w, F, t, E, blocker)
            shown = true
        end
    end
    if not shown then F:text("none", getText("IGUI_MSH_Slots_NoTiers"), "textMuted") end
    local bottom = {}
    if w.order ~= nil and w.msgTier == nil then
        bottom[1] = F:button("check", getText("IGUI_MSH_Slots_CheckOrder"), w, SW.onCheckOrder, "primary")
    end
    bottom[#bottom + 1] = F:button("refresh", getText("IGUI_MSH_Slots_Refresh"), w, SW.onRefresh)
    F:row(bottom)
    F:finish()
end

-- 處理中／結果那一行：寫在按下按鈕的那一級底下（w.msgTier），沒有等級的寫在最上面。之前寫在整頁最底下，
-- 視窗不夠高時要捲到底才看得到（2026-10-15 帳本：有玩家同一分鐘租了同一級兩次）
function SW.layoutStatus(w, F, key)
    if w.busy then
        F:text(key, getText("IGUI_MSH_Slots_Busy"), "textMuted")
    elseif w.message then
        F:text(key, w.message, w.messageToken)
    end
end

-- 這一級要不要列出來：最多 0 間而且沒有房子、沒有付費名額的不列（例：管理員把 2 級的三個數字都設成 0）
function SW.tierShown(t)
    return (t.max or 0) > 0 or (t.owned or 0) > 0 or (t.usable or 0) > 0
end

-- 「免費 1／1 · 租用 2（上限 1）」：免費寫用了幾個／共幾個，買斷、租用寫已有幾個與上限；三種都是 0 的不寫
function SW.parts(t)
    local out = {}
    local f, b, r = t.free or {}, t.buy or {}, t.rent or {}
    if (f.n or 0) > 0 or (f.used or 0) > 0 then out[#out + 1] = getText("IGUI_MSH_Slots_PartFree", f.used or 0, f.n or 0) end
    if (b.n or 0) > 0 or (b.have or 0) > 0 then out[#out + 1] = getText("IGUI_MSH_Slots_PartBuy", b.have or 0, b.n or 0) end
    if (r.n or 0) > 0 or (r.have or 0) > 0 then out[#out + 1] = getText("IGUI_MSH_Slots_PartRent", r.have or 0, r.n or 0) end
    return table.concat(out, getText("IGUI_MSH_Slots_PartSep"))
end

-- 付費名額還能再建幾間（寬限中的不算，同伺服器 checkQuota）
function SW.spare(t)
    return math.max(0, (t.usable or 0) - (t.grace or 0) - (t.paid or 0))
end

-- 一級（使用者 2026-10-15）：「N 級 · 已有 owned 間／最多 max 間」、免費／買斷／租用各自的數字、付費名額還能建幾間、
-- 〔買斷〕〔租用〕（這一級有價格才有；到上限停用並寫原因）、〔租約〕展開、這一級的付款結果。
-- 關閉的等級只在還有付費屋時列出（伺服器 E.slots）：沒有價格、不能買新的，只能展開租約續租
function SW.layoutTier(w, F, t, E, blocker)
    local n = t.tier
    F.y = F.y + K.GAP
    F:text("t" .. n, getText("IGUI_MSH_Slots_Tier", n, t.owned or 0, t.max or 0), "text", UIFont.Medium)
    local parts = SW.parts(t)
    if parts ~= "" then F:text("p" .. n, parts, "textMuted") end
    if t.enabled == false then F:text("off" .. n, getText("IGUI_MSH_Slots_Reason_TIER_DISABLED"), "warning") end
    if (t.grace or 0) > 0 then F:text("g" .. n, getText("IGUI_MSH_Slots_Grace", t.grace), "warning") end
    local spare = SW.spare(t)
    if spare > 0 then F:text("sp" .. n, getText("IGUI_MSH_Slots_Spare", spare), "text") end
    if not blocker then
        local can = SW.canPurchase(w)
        local ctrls = {}
        if t.buyPrice then
            local b = F:button("buy" .. n, getText("IGUI_MSH_Slots_Buy", SW.money(E, t.buyPrice)), w, SW.onBuy, "primary")
            b.internal = n
            b:setEnabled(can and t.buy ~= nil and t.buy.open == true)
            ctrls[#ctrls + 1] = b
        end
        if t.rentPrice then
            local b = F:button("rent" .. n, getText("IGUI_MSH_Slots_Rent", SW.money(E, t.rentPrice), t.rentPrice.days or 0), w,
                SW.onRent, "primary")
            b.internal = n
            b:setEnabled(can and t.rent ~= nil and t.rent.open == true)
            ctrls[#ctrls + 1] = b
        end
        local open = w.expanded == n
        local x = F:button("x" .. n, getText(open and "IGUI_MSH_Slots_HideLeases" or "IGUI_MSH_Slots_ShowLeases"), w, SW.onExpand)
        x.internal = n
        ctrls[#ctrls + 1] = x
        F:row(ctrls)
        -- 有在賣、但可買可租都到上限才寫原因（這一級根本不賣時 full 也是 true，數字列已經說了）
        if t.full and #ctrls > 1 then F:text("cap" .. n, getText("IGUI_MSH_Slots_Reason_TIER_FULL"), "textMuted") end
    end
    if w.msgTier == n then
        SW.layoutStatus(w, F, "status" .. n)
        if w.order ~= nil then F:row({ F:button("check" .. n, getText("IGUI_MSH_Slots_CheckOrder"), w, SW.onCheckOrder, "primary") }) end
    end
    if not blocker and w.expanded == n then SW.layoutLeases(w, F, n, E) end
end

-- 日期（框架 UI.Date；沒有就 nil）
function SW.dateText(UI, ms)
    local D = UI and UI.Date
    if not (MSH.isFinite(ms) and D and D.fromMs and D.format) then return nil end
    local yy, mm, dd = D.fromMs(ms, D.localOffsetMinutes and D.localOffsetMinutes() or 0)
    return D.format(yy, mm, dd)
end

-- 展開那一級的租約：逐張「到哪天（剩多久）」＋自動續租開關；寬限中或到期前可續租。最後寫租約和房子的關係
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
            line = getText("IGUI_MSH_Slots_Lease", i, r.quantity or 0, SW.dateText(w.UI, r.paidUntil) or "-",
                E.remainingText(r.paidUntil - now))
        else
            line = getText("IGUI_MSH_Slots_LeaseState", i, r.quantity or 0, E.stateText(r.state))
        end
        F:text(key, line, r.state == "grace" and "warning" or "text")
        local consent = SW.needsConsent(plan, r)
        if consent then
            local t, q = r.autoTerms, r.quantity or 1
            F:text(key .. "t", getText("IGUI_MSH_Slots_NewTerms",
                SW.money(E, { amount = (plan.rentalPrice or 0) * q, currency = plan.rentalCurrency }), plan.rentalDays or 0,
                SW.money(E, { amount = (t.price or 0) * q, currency = t.currency }), t.days or 0), "warning")
        end
        local ctrls = {}
        local on = SW.autoRenewOn(r)
        local label = SW.autoPaused(plan, r) and "IGUI_MSH_Slots_AutoPaused" or "IGUI_MSH_Slots_AutoRenew"
        local box = F:checkbox(key .. "a", getText(label), w, SW.onAutoRenew)
        box.internal, box.tier = r.id, n
        box:setChecked(on, true)
        box:setEnabled(w.busy == nil and (on or plan.autoRenewAllowed == true))
        ctrls[1] = box
        if consent then
            local g = F:button(key .. "g", getText("IGUI_MSH_Slots_Agree"), w, SW.onAgree, "primary")
            g.internal, g.tier = r.id, n
            g:setEnabled(w.busy == nil)
            ctrls[#ctrls + 1] = g
        end
        if (r.state == "active" or r.state == "grace") and plan.rentalEnabled == true then
            local b = F:button(key .. "r", getText("IGUI_MSH_Slots_Renew"), w, SW.onRenew)
            b.internal, b.tier = r.id, n
            b:setEnabled(SW.canPurchase(w))
            ctrls[#ctrls + 1] = b
        end
        F:row(ctrls, K.PAD + 12)
    end
    F:text("lr" .. n, getText("IGUI_MSH_Slots_LeaseRule"), "textMuted")
end

function SW.onRefresh(w)
    SW.say(w, nil)
    w.msgTier = nil
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
    w.UI.Dialog.show(MSH.Client.windowOpts(w.UI, { title = getText("IGUI_MSH_Slots_Title"), text = text, theme = w.theme,
        confirmText = getText("IGUI_MSH_Slots_Pay"), cancelText = getText("UI_Cancel"),
        onResult = function(ok) if ok then onOk() end end }))
end

function SW.onBuy(w, btn)
    local t = SW.tierOf(w, btn.internal)
    if t == nil or t.buyPrice == nil or not (t.buy and t.buy.open) or not SW.canPurchase(w) then return end
    local price = t.buyPrice
    SW.confirm(w, getText("IGUI_MSH_Slots_ConfirmBuy", t.tier, SW.money(SW.api(), price)), function()
        SW.startQuote(w, t.tier, "permanent", 1, { amount = price.amount, currency = price.currency })
    end)
end

function SW.onRent(w, btn)
    local t = SW.tierOf(w, btn.internal)
    if t == nil or t.rentPrice == nil or not (t.rent and t.rent.open) or not SW.canPurchase(w) then return end
    local price = t.rentPrice
    SW.confirm(w, getText("IGUI_MSH_Slots_ConfirmRent", t.tier, SW.money(SW.api(), price), price.days or 0), function()
        SW.startQuote(w, t.tier, "rental", 1, { amount = price.amount, currency = price.currency })
        -- 新租付款成功後直接問要不要開自動續租（續租、管理視窗的保險不問）
        if w.busy == "quote" then w.pay.offerAuto = true end
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

function SW.startQuote(w, tier, kind, quantity, expect, rental, periods)
    local E = SW.api()
    if E == nil or not SW.canPurchase(w) then return end
    local product = w.productId or SW.product(tier)
    w.busy, w.pay = "quote", { tier = tier, product = product, expect = expect }
    w.msgTier = tier
    SW.say(w, nil)
    local rid, why = E.quote(SW.SRC, product, kind, quantity, function(res) SW.onQuote(w, res) end, rental, periods)
    if rid == nil then SW.refuse(w, why) end
    SW.relayout(w)
end

-- 報價回來：金額、幣別等於確認頁的才付款；不同（方案剛改）不付、重抓摘要並說明新價格
function SW.onQuote(w, res)
    w.busy = nil
    local p = w.pay
    if res.unknown then
        SW.say(w, getText("IGUI_MSH_Slots_QuoteNoAnswer"), "errorText")
    elseif not res.ok or type(res.quote) ~= "table" then
        SW.say(w, SW.reasonText(res.error, SW.api()), "errorText")
        -- 管理視窗的保險：租約可能剛到期被移除（rental_unknown），重抓詳情拿新的租約 id；名額視窗照舊不重抓
        if w.refresh then w.refresh(w) end
    elseif p ~= nil and not SW.quoteMatches(res.quote, p.expect) then
        SW.say(w, getText("IGUI_MSH_Slots_PriceChanged", SW.money(SW.api(), res.quote)), "warning")
        SW.reload(w)
    elseif p ~= nil then
        return SW.purchase(w, res.quote)
    end
    SW.relayout(w)
end

-- 付款前先記下伺服器指定的 orderId；之後只查這一筆，不用其他訂單猜結果
function SW.purchase(w, q)
    local E = SW.api()
    if E == nil or not SW.canPurchase(w) then return SW.relayout(w) end
    w.busy = "purchase"
    w.order = { quoteId = q.id, orderId = q.orderId, tier = w.pay and w.pay.tier, product = w.pay and w.pay.product,
        offerAuto = w.pay and w.pay.offerAuto }
    local rid, why = E.purchase(SW.SRC, q.id, function(res) SW.onPurchase(w, res) end)
    if rid == nil then
        w.order = nil
        SW.refuse(w, why)
    end
    SW.relayout(w)
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
    SW.relayout(w)
end

-- 付款有結果：結果寫在那一級底下，同時跳通知（視窗外也看得到）
function SW.finish(w, key)
    local o = w.order
    w.order = nil
    local text = getText(w.texts and w.texts[key] or key)
    SW.say(w, text, "text")
    MSH.Client.toast(text)
    SW.reload(w)
    SW.requestState(w)
    if key == "IGUI_MSH_Slots_PaidDone" and o and o.offerAuto and o.orderId ~= nil then
        w.autoOffer = { tier = o.tier, id = o.orderId }
        SW.tryAutoOffer(w)
    end
end

-- 付款回覆先採用新快照再回呼（ECEntitlementClient.lua onReply），通常當下就找得到新租約；找不到就等下一個快照
-- （onEconomyChanged）再試。方案不允許、已經開著或視窗關了就不問
function SW.tryAutoOffer(w)
    local a = w.autoOffer
    if a == nil then return end
    if not SW.visible(w) then w.autoOffer = nil return end
    local E = SW.api()
    local env = E and E.getState(SW.SRC, SW.product(a.tier))
    local r = SW.findRental(env, a.id)
    if r == nil then return end
    w.autoOffer = nil
    if (env.plan or {}).autoRenewAllowed == true and not SW.autoRenewOn(r) then SW.confirmAuto(w, E, env, r, a.tier, true) end
end

-- 查詢購買結果：唯讀查同一筆（沒有 orderId 時查原 quoteId），絕不重送購買
function SW.onCheckOrder(w)
    local E = SW.api()
    local o = w.order
    if E == nil or w.busy or o == nil then return end
    local id = o.orderId or o.quoteId
    w.busy = "order"
    SW.say(w, nil)
    local rid, why = E.getOrder(SW.SRC, o.product or SW.product(o.tier), id, function(res) SW.onOrder(w, res, id) end)
    if rid == nil then SW.refuse(w, why) end
    SW.relayout(w)
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
    SW.relayout(w)
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
    if plan.autoRenewAllowed == true then SW.confirmAuto(w, E, env, r, box.tier) end
end

-- 〔同意〕新條款：開著但條款改了（暫停中），用同一個確認框重新同意目前方案
function SW.onAgree(w, b)
    local E = SW.api()
    local env = E and E.getState(SW.SRC, SW.product(b.tier))
    local r = SW.findRental(env, b.internal)
    if r == nil or w.busy or not SW.needsConsent(env.plan or {}, r) then return end
    SW.confirmAuto(w, E, env, r, b.tier)
end

-- 確認框寫目前方案的條款；同意才送（帶權益版本與條款版本，Economy 照當下方案記下同意）。offer＝新租後主動問
function SW.confirmAuto(w, E, env, r, tier, offer)
    local plan, ent = env.plan or {}, env.entitlement or {}
    local price = { amount = (plan.rentalPrice or 0) * (r.quantity or 1), currency = plan.rentalCurrency }
    local text = getText("IGUI_MSH_Slots_ConfirmAuto", SW.money(E, price), plan.rentalDays or 0)
    if offer then
        local left = type(r.paidUntil) == "number" and E.remainingText(math.max(0, r.paidUntil - getTimestampMs())) or "-"
        text = getText("IGUI_MSH_Slots_OfferAuto", tier, left, SW.money(E, price), plan.rentalDays or 0)
    end
    w.UI.Dialog.show(MSH.Client.windowOpts(w.UI, { title = getText("IGUI_MSH_Slots_Title"), theme = w.theme, text = text,
        confirmText = getText(offer and "IGUI_MSH_Slots_TurnOnAuto" or "IGUI_MSH_Slots_Agree"),
        cancelText = getText(offer and "IGUI_MSH_Slots_Later" or "UI_Cancel"),
        onResult = function(ok)
            if ok then SW.sendAutoRenew(w, tier, true, ent.revision, plan.revision, r.id) end
        end }))
end

function SW.sendAutoRenew(w, tier, enabled, revision, termsRevision, rental)
    local E = SW.api()
    if E == nil or w.busy then return end
    w.busy = "auto"
    w.msgTier = tier
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

-- 剩餘時間每分鐘重排一次（不是每幀）；登入摘要讀失敗的補讀也在這裡排
function SW.onTick()
    local w = SW.instance
    local now = getTimestampMs()
    if SW.visible(w) and w.laidOutAt ~= nil and now - w.laidOutAt >= 60000 then SW.layout(w) end
    if SW.summaryRetryAt ~= nil and now >= SW.summaryRetryAt then
        local retry = SW.summaryRetry
        SW.summaryRetryAt, SW.summaryRetry = nil, nil
        retry()
    end
end

if first then
    Events.OnTick.Add(function() MSH.SlotsWindow.onTick() end)
    MSH.Client.on("slots", "SlotsWindow", function(res) MSH.SlotsWindow.onSlots(res) end)
    MSH.Client.on("claims", "SlotsWindow", function() MSH.SlotsWindow.slotsChanged() end)
    MSH.Client.on("sandbox", "SlotsWindow", function() MSH.SlotsWindow.slotsChanged() end)
    MSH.Client.on("login", "SlotsWindow", function(ok) MSH.SlotsWindow.onLogin(ok) end)
end
