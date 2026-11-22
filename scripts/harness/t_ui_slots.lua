-- 名額視窗的租約體驗（SlotsWindow.lua）：新租付款成功後問要不要開自動續租、Economy notice 的到期通知（照事件去重）、
-- 登入摘要。假 Economy 照 ECEntitlementClient：付款回覆先採用新快照再回呼（onReply）、onChanged 每個採用的快照都通知
return function(T)
    local check = T.check
    local MSH = T.bootClient()
    local SW = MSH.SlotsWindow
    T.player({ name = "alice" })
    local saved = { getText = getText, MinidoracatUI = MinidoracatUI, MinidoracatEconomy = MinidoracatEconomy }

    getText = function(key, ...)
        local a = { ... }
        if #a > 0 then return key .. "=" .. table.concat(a, ",") end
        return key
    end
    local toasts, dialog = {}, nil
    MinidoracatUI = { v1 = { API_MAJOR = 1, API_REVISION = 17, CAPABILITIES = { toast = true },
        Dialog = { show = function(o) dialog = o end },
        Toast = { show = function(o) toasts[#toasts + 1] = o end } } }

    local H = 3600000
    local states, listeners, autoCalls, list = {}, {}, {}, nil
    local quoteCb, buyCb, listCb
    local listCalls, stateCbs = 0, {}
    local E = {
        onChanged = function(fn) listeners[#listeners + 1] = fn end,
        onPush = function() end,
        getState = function(_, product) return states[product] end,
        requestState = function(_, product, cb) stateCbs[product] = cb return "rs" end,
        quote = function(_, _, _, _, cb) quoteCb = cb return "rq" end,
        purchase = function(_, _, cb) buyCb = cb return "rp" end,
        setAutoRenew = function(_, product, enabled, _, _, _, rental)
            autoCalls[#autoCalls + 1] = { product = product, enabled = enabled, rental = rental }
            return "ra"
        end,
        errorText = function(c) return "err:" .. tostring(c) end,
        currencyName = function(c) return c end,
        remainingText = function(ms) return math.floor(ms / H) .. "h" end,
        requestList = function(cb) listCalls, listCb = listCalls + 1, cb return "rl" end,
        getList = function() return list end,
    }
    MinidoracatEconomy = { v1 = { Client = { API_MAJOR = 1, API_REVISION = 7,
        CAPABILITIES = { entitlements = true, rentals = true }, Entitlements = E } } }
    -- 照 ECEntitlementClient adopt：先更新快取（getState 拿得到），再通知
    local function notify(env)
        states[env.productId] = env
        for _, fn in ipairs(listeners) do fn(env) end
    end
    local function listReply(res)
        for _, e in ipairs(res.entries or {}) do notify(e) end
        listCb(res)
    end
    local function plan(extra)
        local p = { autoRenewAllowed = true, rentalEnabled = true, rentalPrice = 100, rentalCurrency = "survivor",
            rentalDays = 7, reminderHours = 24, revision = 3 }
        for k, v in pairs(extra or {}) do p[k] = v end
        return p
    end
    local function env(product, rentals, notice, p)
        return { sourceMod = SW.SRC, productId = product, plan = p or plan(),
            entitlement = { revision = 5, rentals = rentals or {}, notice = notice } }
    end
    local visible = true
    local w = { UI = MinidoracatUI.v1, theme = {}, refresh = function() end, relayout = function() end,
        win = { isVisible = function() return visible end },
        slots = { economy = "READY", tiers = { { tier = 2, rentPrice = { amount = 100, currency = "survivor", days = 7 },
            rent = { open = true }, buyPrice = { amount = 500, currency = "survivor" }, buy = { open = true } } } } }
    SW.instance = w
    SW.listen()

    -- 確認頁 → 報價 → 付款；snapshot＝付款回覆採用的新快照（nil＝回覆沒帶，之後才推來）
    local function pay(start, orderId, snapshot, res, amount)
        dialog = nil
        start()
        dialog.onResult(true)
        dialog = nil
        quoteCb({ ok = true, quote = { id = "Q" .. orderId, orderId = orderId, amount = amount or 100, currency = "survivor" } })
        states.tier2 = snapshot or states.tier2
        buyCb(res or { ok = true })
    end
    local function rent(orderId, snapshot, res) pay(function() SW.onRent(w, { internal = 2 }) end, orderId, snapshot, res) end

    T.section("SlotsWindow：新租付款成功 → 直接問要不要開自動續租")
    local lease = { id = "O1", quantity = 1, state = "active", paidUntil = T.now + 72 * H, autoRenew = false }
    rent("O1", env("tier2", { lease }))
    check(dialog ~= nil and dialog.text == "IGUI_MSH_Slots_OfferAuto=2,72h,IGUI_MSH_Slots_Money=100,survivor,7"
        and dialog.confirmText == "IGUI_MSH_Slots_TurnOnAuto" and dialog.cancelText == "IGUI_MSH_Slots_Later",
        "付款回覆帶新租約：問開不開，寫等級、剩多久、每期金額與天數；按鈕〔開啟自動續租〕〔先不要〕")
    dialog.onResult(true)
    check(#autoCalls == 1 and autoCalls[1].rental == "O1" and autoCalls[1].enabled == true and autoCalls[1].product == "tier2",
        "同意：照既有流程對這一張送自動續租")
    w.busy, dialog = nil, nil
    notify(env("tier2", { lease }))
    check(dialog == nil and #autoCalls == 1 and w.autoOffer == nil, "問過一次就不再問")

    T.section("SlotsWindow：不該問的情況")
    dialog = nil
    rent("O2", env("tier2", { lease, { id = "O2", quantity = 1, state = "active", paidUntil = T.now + H, autoRenew = false } },
        nil, plan({ autoRenewAllowed = false })))
    check(dialog == nil and w.autoOffer == nil, "方案不允許自動續租：不問")
    rent("O3", env("tier2", { { id = "O3", quantity = 1, state = "active", paidUntil = T.now + H, autoRenewState = "on" } }))
    check(dialog == nil, "這張已經開著：不問")
    rent("O4", env("tier2", { { id = "O4", state = "active", paidUntil = T.now + H } }), { ok = true, duplicate = true })
    check(dialog == nil and w.autoOffer == nil, "重複付款（Duplicate）：不問")
    rent("O5", env("tier2", { { id = "O5", state = "active", paidUntil = T.now + H } }), { ok = false, error = "insufficient_funds" })
    check(dialog == nil and w.autoOffer == nil, "付款被拒：不問")
    states.tier2 = env("tier2", { { id = "R1", quantity = 1, state = "active", paidUntil = T.now + H, autoRenew = false } })
    pay(function() SW.onRenew(w, { tier = 2, internal = "R1" }) end, "R1-renew")
    check(dialog == nil and w.autoOffer == nil, "續租：不問（只有新租問）")
    pay(function() SW.onBuy(w, { internal = 2 }) end, "B1", env("tier2", { { id = "B1", state = "active", paidUntil = T.now + H } }),
        nil, 500)
    check(dialog == nil and w.autoOffer == nil, "買永久名額：不問")

    T.section("SlotsWindow：付款回覆時快照還沒有新租約 → 等下一個快照補問")
    states.tier2 = env("tier2", {})
    rent("O6", nil)
    check(dialog == nil and w.autoOffer ~= nil and w.autoOffer.id == "O6", "還找不到：先記著、不問")
    notify(env("OtherMod", {}))
    check(dialog == nil, "別的產品的快照：還是不問")
    states.tier2 = env("tier2", { { id = "O6", quantity = 1, state = "active", paidUntil = T.now + 48 * H, autoRenew = false } })
    notify(states.tier2)
    check(dialog ~= nil and dialog.text == "IGUI_MSH_Slots_OfferAuto=2,48h,IGUI_MSH_Slots_Money=100,survivor,7"
        and w.autoOffer == nil, "新租約到了：補問一次")
    dialog = nil
    states.tier2 = env("tier2", {})
    rent("O7", nil)
    visible = false
    states.tier2 = env("tier2", { { id = "O7", state = "active", paidUntil = T.now + H } })
    notify(states.tier2)
    check(dialog == nil and w.autoOffer == nil, "名額視窗關了：不跳、也不留著之後跳")
    visible = true

    T.section("SlotsWindow：登入摘要等資料到齊才講、只講數字")
    toasts, states = {}, {}
    local rDue = { id = "L1", quantity = 1, state = "active", paidUntil = T.now + 20 * H, autoRenew = false }
    notify(env("tier3", { rDue }, { code = "renewal_due", at = 100, rental = "L1" }))
    check(#toasts == 0, "登入摘要讀完前：只記基準、不跳")
    MSH.Client.claims = { mine = { { claimId = 1, lifecycle = "lapsed" }, { claimId = 2, lifecycle = "active" } },
        shared = { { claimId = 3, lifecycle = "lapsed" } }, byId = {} }
    MSH.Client.emit("login", true)
    check(listCalls == 1, "安全屋第一份清單成功（login(true)）：要這個登入的全部產品")
    -- 上一份成功的清單還在快取：失敗的這次不能拿它來講
    list = { entries = { env("tier2", { { id = "OLD", state = "grace", graceUntil = T.now + H } }) } }
    listCb({ ok = false, error = "timeout" })
    check(#toasts == 0 and listCalls == 1, "清單逾時：不拿快取裡的舊清單講、先不重讀")
    T.fire("OnTick")
    check(listCalls == 1, "還沒到時間：不重讀")
    T.advance(SW.SUMMARY_RETRY_MS)
    T.fire("OnTick")
    check(listCalls == 2, "隔一會兒：重讀")
    stateCbs = {}
    local PT = { id = "PT", quantity = 1, state = "paused_terms", paidUntil = T.now + 5 * H, autoRenewState = "paused_terms" }
    listReply({ ok = true, more = true, entries = {
        env("tier3", { rDue, PT }, { code = "renewal_due", at = 100, rental = "L1" }),
        env("tier4", { { id = "G1", quantity = 2, state = "grace", graceUntil = T.now + 30 * H, autoRenew = true } }),
        env("tier5", { { id = "A1", state = "active", paidUntil = T.now + 10 * H, autoRenewState = "on" } }),
        env("tier6", { { id = "P1", state = "active", paidUntil = T.now + 10 * H, autoRenewState = "paused_terms" } }),
        env("tier7", { { id = "F1", state = "active", paidUntil = T.now + 200 * H, autoRenew = false },
            { id = "PS", quantity = 3, state = "paused_system", paidUntil = T.now + 5 * H, autoRenew = false } }),
        env("insure2", { { id = "I1", state = "grace", graceUntil = T.now + H } }),
        { sourceMod = "OtherMod", productId = "tier2", plan = plan(),
            entitlement = { rentals = { { id = "X", state = "grace", graceUntil = T.now + H } } } },
    } })
    check(#toasts == 0 and stateCbs.tier1 ~= nil and stateCbs.tier2 ~= nil and stateCbs.tier8 ~= nil
        and stateCbs.tier3 == nil, "清單被截（more）：沒列到的級別逐一補讀，讀完才講")
    -- 補讀期間 tier3 推來新快照：L1 進寬限
    local lGrace = { id = "L1", quantity = 1, state = "grace", graceUntil = T.now + 6.5 * H, autoRenew = false }
    notify(env("tier3", { lGrace, PT }, { code = "grace", at = 150, rental = "L1" }))
    check(#toasts == 0, "讀取期間的新事件：先不跳")
    local t1 = env("tier1", { { id = "G2", state = "grace", graceUntil = T.now + 2 * H } })
    local t8 = env("tier8", { { id = "N1", state = "active", paidUntil = T.now + 2 * H, autoRenew = false } })
    notify(t1)
    stateCbs.tier1(t1)
    stateCbs.tier2({ ok = false, error = "timeout" })
    notify(t8)
    stateCbs.tier8(t8)
    check(#toasts == 0, "有一級逾時：不當成沒有租約、不講")
    stateCbs = {}
    T.advance(SW.SUMMARY_RETRY_MS)
    T.fire("OnTick")
    check(stateCbs.tier2 ~= nil and stateCbs.tier1 == nil and stateCbs.tier8 == nil, "隔一會兒：只補讀失敗的那一級")
    local t2 = env("tier2", {})
    notify(t2)
    stateCbs.tier2(t2)
    check(#toasts == 2 and toasts[1].title == "IGUI_MSH_Lease_Title" and toasts[1].message ==
        "IGUI_MSH_Lease_SumLapsed=1 IGUI_MSH_Lease_SumGrace=4 IGUI_MSH_Lease_SumDue=6",
        "摘要一則數字、保留期在最前；照名額數（quantity）算、用最新快照：保留期屋、寬限中、提醒期內不會自動續"
            .. "（含付了錢但暫停的）；開著的、還早的、保險、別的 MOD、分享給我的不算")
    check(toasts[2].message == "IGUI_MSH_Lease_grace=3,6h", "讀取期間的事件：摘要之後補講")
    MSH.Client.emit("login", true)
    check(#toasts == 2 and listCalls == 2, "摘要每次登入只一次")
    toasts = { toasts[1] }

    T.section("SlotsWindow：租約通知照事件去重（同一個 at 可以是不同的事）")
    notify(env("tier3", { lGrace, PT }, { code = "grace", at = 150, rental = "L1" }))
    check(#toasts == 1, "補講過的 notice 再推一次：不再跳")
    notify(env("tier3", { rDue }, { code = "grace", at = 200, rental = "L1" }))
    check(#toasts == 2 and toasts[2].message == "IGUI_MSH_Lease_grace=3,-", "新的 notice：跳一則")
    notify(env("tier3", { rDue }, { code = "grace", at = 200, rental = "L1" }))
    check(#toasts == 2, "錢包推送、requestState 帶同一個 notice 再觸發：不重跳")
    local rGrace = { id = "L1", state = "grace", graceUntil = T.now + 5 * H, autoRenew = false }
    notify(env("tier3", { rGrace }, { code = "expired", at = 300, rental = "L1" }))
    check(#toasts == 3 and toasts[3].message == "IGUI_MSH_Lease_expired=3,-", "到期：跳")
    notify(env("tier3", { rGrace }, { code = "renewed", at = 400, rental = "L1" }))
    check(#toasts == 3, "renewed 等其他 code：不跳")
    local rAuto = { id = "L2", state = "grace", graceUntil = T.now + 5 * H, autoRenewState = "on" }
    notify(env("tier3", { rAuto }, { code = "grace", at = 500, rental = "L2" }))
    check(#toasts == 3, "開著自動續租的進寬限（同一刻就扣款）：不跳")
    notify(env("tier3", { rAuto }, { code = "renewal_failed", at = 500, rental = "L2", error = "insufficient_funds" }))
    check(#toasts == 4 and toasts[4].message == "IGUI_MSH_Lease_renewal_failed=3,err:insufficient_funds",
        "同一輪緊接的扣款失敗（at 和進寬限一樣）：跳、寫原因")
    notify(env("tier3", { rAuto }, { code = "renewal_failed", at = 600, rental = "L2", error = "insufficient_funds" }))
    check(#toasts == 4, "寬限中每小時重試又失敗（同一張、同一原因）：不重跳")
    notify(env("tier3", { rAuto }, { code = "renewal_failed", at = 700, rental = "L2", error = "frozen" }))
    check(#toasts == 5, "原因變了：跳")
    notify(env("tier3", { rAuto }, { code = "renewed", at = 800, rental = "L2" }))
    notify(env("tier3", { rAuto }, { code = "renewal_failed", at = 900, rental = "L2", error = "frozen" }))
    check(#toasts == 6, "中間這張有別的事（續上了）之後又失敗：再講一次")
    local d1 = { id = "D1", state = "active", paidUntil = T.now + 4 * H, autoRenew = false }
    local d2 = { id = "D2", state = "active", paidUntil = T.now + 6 * H, autoRenew = false }
    notify(env("tier3", { d1, d2 }, { code = "renewal_due", at = 1000, rental = "D1" }))
    notify(env("tier3", { d1, d2 }, { code = "renewal_due", at = 1000, rental = "D2" }))
    check(#toasts == 8 and toasts[7].message == "IGUI_MSH_Lease_renewal_due=3,4h"
        and toasts[8].message == "IGUI_MSH_Lease_renewal_due=3,6h", "同一輪兩張到提醒期（同一個 at）：各跳一則")
    notify(env("tier3", { d1, d2 }, { code = "renewal_due", at = 1000, rental = "D2" }))
    check(#toasts == 8, "同一件再推一次：不重跳")
    notify(env("tier8", { { id = "N1", state = "active", paidUntil = T.now + 3 * H } }, { code = "renewal_due", at = 1100, rental = "N1" }))
    check(#toasts == 9 and toasts[9].message == "IGUI_MSH_Lease_renewal_due=8,3h", "補讀過的級別有基準：之後的提醒期照跳、寫剩多久")
    notify(env("tier9", {}, { code = "renewal_due", at = 1200, rental = "Q" }))
    check(#toasts == 9, "第一次看到的產品：只記基準")
    notify(env("insure2", {}, { code = "grace", at = 1 }))
    notify(env("insure2", {}, { code = "grace", at = 2 }))
    check(#toasts == 9, "保險產品：不在這裡講")
    -- Economy 的 refunded 不針對某張租約、沒有 rental（標準 Lua 拿 nil 當鍵寫入會丟錯）
    check(pcall(notify, env("tier8", {}, { code = "refunded", at = 1300 })) and #toasts == 9,
        "沒有 rental 的 notice（refunded）：不丟錯、不跳")
    -- 登入前就在寬限中扣款失敗：基準也要記下原因，下一次重試同原因不再講
    local rF = { id = "B1", state = "grace", graceUntil = T.now + H, autoRenew = true }
    notify(env("tier10", { rF }, { code = "renewal_failed", at = 1300, rental = "B1", error = "insufficient_funds" }))
    notify(env("tier10", { rF }, { code = "renewal_failed", at = 1400, rental = "B1", error = "insufficient_funds" }))
    check(#toasts == 9, "登入時已有的扣款失敗：下一次同原因再失敗不跳")
    notify(env("tier10", { rF }, { code = "renewal_failed", at = 1500, rental = "B1", error = "frozen" }))
    check(#toasts == 10 and toasts[10].message == "IGUI_MSH_Lease_renewal_failed=10,err:frozen", "換了原因：跳")

    T.section("SlotsWindow：讀不到就放棄摘要，通知照常")
    local function reboot()
        local M = T.bootClient()
        T.player({ name = "alice" })
        listeners, toasts, states = {}, {}, {}
        MinidoracatUI = { v1 = { API_MAJOR = 1, API_REVISION = 17, CAPABILITIES = { toast = true },
            Toast = { show = function(o) toasts[#toasts + 1] = o end } } }
        MinidoracatEconomy = { v1 = { Client = { API_MAJOR = 1, API_REVISION = 7,
            CAPABILITIES = { entitlements = true, rentals = true }, Entitlements = E } } }
        return M
    end
    local MSH4 = reboot()
    local calls0 = listCalls
    MSH4.Client.emit("login", true)
    for i = 1, MSH4.SlotsWindow.SUMMARY_TRIES do
        listCb({ ok = false, error = "not_ready" })
        T.advance(MSH4.SlotsWindow.SUMMARY_RETRY_MS)
        T.fire("OnTick")
    end
    check(listCalls == calls0 + MSH4.SlotsWindow.SUMMARY_TRIES and #toasts == 1
        and toasts[1].message == "IGUI_MSH_Lease_SumUnknown", "連續讀不到到上限：不再讀，只說名額讀不到（沒有數字）")
    notify(env("tier2", {}, { code = "grace", at = 1 }))
    notify(env("tier2", { { id = "Z", state = "grace", autoRenew = false } }, { code = "grace", at = 2, rental = "Z" }))
    check(#toasts == 2, "放棄摘要後：通知照常")
    local MSH5 = reboot()
    calls0 = listCalls
    MSH5.Client.emit("login", false)
    notify(env("tier2", {}, { code = "grace", at = 1 }))
    notify(env("tier2", { { id = "Z", state = "grace", autoRenew = false } }, { code = "grace", at = 2, rental = "Z" }))
    check(listCalls == calls0 and #toasts == 1, "安全屋清單一直讀不到（login(false)）：不講摘要，通知照常")
    local MSH6 = reboot()
    MSH6.Client.claims = { mine = { { claimId = 1, lifecycle = "lapsed" } }, shared = {}, byId = {} }
    MSH6.Client.emit("login", true)
    stateCbs = {}
    listReply({ ok = true, more = true, entries = {} })
    local g = env("tier1", { { id = "G9", quantity = 2, state = "grace", graceUntil = T.now + H } })
    notify(g)
    stateCbs.tier1(g)
    for t = 2, 8 do stateCbs["tier" .. t]({ ok = false, error = "timeout" }) end
    for _ = 2, MSH6.SlotsWindow.SUMMARY_TRIES do
        stateCbs = {}
        T.advance(MSH6.SlotsWindow.SUMMARY_RETRY_MS)
        T.fire("OnTick")
        check(stateCbs.tier1 == nil and stateCbs.tier5 ~= nil, "補讀：讀到的不再讀，只補失敗的")
        for t = 2, 8 do stateCbs["tier" .. t]({ ok = false, error = "timeout" }) end
    end
    stateCbs = {}
    T.advance(MSH6.SlotsWindow.SUMMARY_RETRY_MS)
    T.fire("OnTick")
    check(next(stateCbs) == nil and #toasts == 1 and toasts[1].message ==
        "IGUI_MSH_Lease_SumLapsed=1 IGUI_MSH_Lease_SumUnknown IGUI_MSH_Lease_SumGrace=2",
        "補讀到上限還有讀不到的級別：保留期照講、註明不完整（在數字前），讀到的照講")

    T.section("SlotsWindow：Economy 缺席或沒有 requestList")
    local MSH2 = T.bootClient()
    T.player({ name = "alice" })
    MinidoracatUI = { v1 = { API_MAJOR = 1, API_REVISION = 17, CAPABILITIES = { toast = true },
        Toast = { show = function(o) toasts[#toasts + 1] = o end } } }
    MinidoracatEconomy = nil
    toasts = {}
    check(pcall(MSH2.Client.emit, "login", true) and #toasts == 0, "Economy 缺席：不報錯、不跳")
    local MSH3 = T.bootClient()
    T.player({ name = "alice" })
    local old = {}
    for k, v in pairs(E) do old[k] = v end
    old.requestList, old.getList = nil, nil
    listeners = {}
    old.onChanged = function(fn) listeners[#listeners + 1] = fn end
    MinidoracatEconomy = { v1 = { Client = { API_MAJOR = 1, API_REVISION = 4,
        CAPABILITIES = { entitlements = true, rentals = true }, Entitlements = old } } }
    MSH3.Client.emit("login", true)
    notify(env("tier2", {}, { code = "grace", at = 1 }))
    notify(env("tier2", { { id = "Z", state = "grace", autoRenew = false } }, { code = "grace", at = 2, rental = "Z" }))
    check(#toasts == 1 and toasts[1].message == "IGUI_MSH_Lease_grace=2,-", "舊 Economy（沒有 requestList）：略過摘要，通知照常")

    for k, v in pairs(saved) do _G[k] = v end
end
