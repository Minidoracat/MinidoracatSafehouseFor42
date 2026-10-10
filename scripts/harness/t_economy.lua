-- Economy：付費名額（計畫 §1.3、§7.1、§10.6 付費頁、§10.7）——偵測、註冊、validatePurchase、名額、停用／恢復／釋出、
-- ABSENT／FAILED、slots、adminPlans／adminSetPlan、Tier<N>Buy／Rent 開關。假 Economy 在 env.lua 的 T.economy。
return function(T)
    local check = T.check
    local D1 = "MinidoracatSafehouse.Deed1"
    local DAY = 86400000
    local HOUR = 3600000
    local MSH, R, E

    -- econ：傳給 T.economy 的 opts；false＝不裝 Economy
    local function boot(opts)
        opts = opts or {}
        local econ, before = opts.econ, opts.beforeStart
        opts.beforeStart = function(env)
            if econ ~= false then T.economy(econ or {}) end
            if before then before(env) end
        end
        MSH = T.boot(opts)
        R, E = MSH.Registry, MSH.Economy
        return MSH
    end
    local function rect(x, y, w, h) return { x = x, y = y, w = w, h = h } end
    local function seed(owner, r, tier)
        local rec = R.newRecord({ claimId = R.allocId(), rect = r, title = owner .. r.x, owner = owner,
            source = MSH.SOURCE.DEED, deedTier = tier or 1, createdAt = T.now })
        rec.nativeCreatedAt = MSH.Native.build(rec):getDatetimeCreated()
        R.put(rec)
        T.advance(1000)
        return rec
    end
    -- paid＝paidUntil：一次到期的識別是租約 id＋paidUntil（續租後再到期是新的一次）
    local function lease(id, q, state, untilMs, paid)
        return { id = id, quantity = q, state = state, graceUntil = untilMs, paidUntil = paid }
    end
    local function minute()
        T.advance(60000)
        T.tick(1)
    end
    local function create(p, x, y)
        p.x, p.y = x + 5, y + 5
        return T.cmd(p, "create", { rect = rect(x, y, 10, 10), deedType = D1 })
    end
    local function validate(user, product, kind, projected)
        return T.econ.products[product].validatePurchase(user, product, kind, 1, projected)
    end

    T.section("偵測：ABSENT／舊版／缺能力／註冊失敗／READY")
    boot({ econ = false })
    check(E.status == "ABSENT", "沒裝 Economy → ABSENT")
    boot({ econ = { revision = 1 } })
    check(E.status == "UNSUPPORTED", "API_REVISION < 2 → UNSUPPORTED")
    boot({ econ = { caps = { entitlements = true, subscriptions = false, rentals = true, setPlan = true } } })
    check(E.status == "UNSUPPORTED", "缺 subscriptions 能力 → UNSUPPORTED")
    boot({ econ = { caps = { entitlements = true, subscriptions = true, rentals = true } } })
    check(E.status == "UNSUPPORTED", "缺 setPlan 能力 → UNSUPPORTED")
    boot({ econ = { failSource = true } })
    check(E.status == "FAILED" and E.src == nil, "registerSource 丟錯 → FAILED")
    boot({ econ = { failRegister = true } })
    check(E.status == "FAILED" and E.src == nil, "registerProduct 回 ok=false → FAILED")
    boot({ econ = { revision = 3, caps = { entitlements = true, subscriptions = true, rentals = true, setPlan = true } } })
    check(E.status == "READY" and T.econ.products.tier1.freezeWhenAbsent == nil, "rev 3 沒有 freeze：READY、不帶 freezeWhenAbsent")
    boot()
    check(E.status == "READY", "rev 4 全部能力 → READY")
    local src = T.econ.source
    check(src.modId == "MinidoracatSafehouseFor42" and #src.reasonCodes == 3 and #src.currencies == 2,
        "registerSource：modId、3 個標準 reasonCode、全部幣別")
    local n, okDefaults = 0, true
    local rents = { 100, 300, 700, 700, 700, 700, 700, 700 }
    for t = 1, 8 do
        local spec, plan = T.econ.products["tier" .. t], T.econ.plans["tier" .. t]
        if spec then n = n + 1 end
        local v = plan and plan.values
        okDefaults = okDefaults and spec ~= nil and spec.instant == true and spec.freezeWhenAbsent == true
            and type(spec.validatePurchase) == "function" and v.permanentEnabled == false and v.rentalEnabled == false
            and v.rentalPrice == rents[t] and v.permanentPrice == rents[t] * 12 and v.rentalDays == 30
            and v.permanentCurrency == "survivor" and v.rentalCurrency == "survivor"
    end
    check(n == 8 and okDefaults, "8 個產品：instant、freezeWhenAbsent、販售都關、月租 100/300/700…、買斷＝月租×12、30 天")
    local listeners = 0
    for _ in pairs(T.econ.listeners) do listeners = listeners + 1 end
    check(listeners == 1, "onEntitlementChanged 監聽一個")

    T.section("名額：免費位 → 付費名額（寬限中不能建新的）、QUOTA_FULL 只帶開著的價格")
    boot()
    local a1 = seed("alice", rect(100, 100, 5, 5), 1)
    local alice = T.player({ name = "alice", items = { D1, D1, D1, D1 } })
    local q = create(alice, 200, 200)
    check(q.code == "QUOTA_FULL" and q.tier == 1 and q.buy == nil and q.rent == nil, "販售都關：QUOTA_FULL 不帶價格")
    T.sandbox("Tier1Buy", true)
    T.sandbox("Tier1Rent", true)
    minute()
    local p1 = T.econ.plans.tier1
    local last = T.econ.setPlans[#T.econ.setPlans]
    check(p1.values.permanentEnabled == true and p1.values.rentalEnabled == true and last.opts.origin == "source",
        "Tier1Buy／Rent 打開：每分鐘檢查以 setPlan 打開兩種販售（origin＝source）")
    q = create(alice, 200, 200)
    check(q.code == "QUOTA_FULL" and q.buy and q.buy.amount == 1200 and q.buy.currency == "survivor"
        and q.rent and q.rent.amount == 100 and q.rent.days == 30, "QUOTA_FULL 帶該級買斷與月租價格")
    T.sandbox("Tier1Rent", false)
    q = create(alice, 200, 200)
    check(q.code == "QUOTA_FULL" and q.buy ~= nil and q.rent == nil, "Tier1Rent 關：只帶買斷價")
    minute()
    check(T.econ.plans.tier1.values.rentalEnabled == true, "開關關掉不把方案改回 false")
    T.econSet("alice", 1, 0, { lease("L1", 1, "grace", T.now + HOUR) })
    q = create(alice, 200, 200)
    check(q.code == "QUOTA_FULL", "寬限中的租用名額不能拿來建新的")
    T.econSet("alice", 1, 0, { lease("L1", 1, "active") })
    local res = create(alice, 200, 200)
    check(res and res.ok, "有 1 個可用名額：建立第一間付費屋")
    local a2 = R.get(res.claimId)
    q = create(alice, 300, 300)
    check(q.code == "QUOTA_FULL", "付費名額用完：QUOTA_FULL")
    T.econSet("alice", 1, 0, { lease("L1", 1, "active"), lease("L2", 1, "active") })
    res = create(alice, 300, 300)
    check(res and res.ok, "第二個租約：建立第二間付費屋")
    local a3 = R.get(res.claimId)
    local a4 = seed("alice", rect(400, 400, 5, 5), 2)
    T.econSet("alice", 2, 1, {})

    T.section("validatePurchase：開著放行；關掉或停用只到既有付費間數")
    check(validate("bob", "tier1", "permanent", { permanent = 5, rental = 0 }) == true, "等級啟用＋Tier1Buy 開：放行（不因用完擋加購）")
    local ok, why = validate("alice", "tier1", "rental", { permanent = 0, rental = 2 })
    check(ok == true, "Tier1Rent 關：付款後總數 ≤ 既有付費間數（續租）放行")
    ok, why = validate("alice", "tier1", "rental", { permanent = 0, rental = 3 })
    check(ok == false and why == "KIND_CLOSED", "Tier1Rent 關：超過既有付費間數 → KIND_CLOSED")
    ok, why = validate("alice", "tier4", "permanent", { permanent = 1, rental = 0 })
    check(ok == false and why == "TIER_DISABLED", "等級未啟用（TiersEnabled＝3）→ TIER_DISABLED")
    local a5 = seed("alice", rect(500, 500, 5, 5), 4)   -- 停用等級的既有付費屋（例：管理員調低 TiersEnabled 之前建的）
    ok = validate("alice", "tier4", "rental", { permanent = 0, rental = 1 })
    check(ok == true, "停用等級：既有付費屋可以續租")
    ok, why = validate("alice", "tier4", "rental", { permanent = 0, rental = 2 })
    check(ok == false and why == "TIER_DISABLED", "停用等級：不能多買")

    T.section("slots：免費位、各啟用等級的名額與價格")
    T.advance(1000)
    local sl = T.cmd(alice, "slots", {})
    local row1, row2 = sl.tiers[1], sl.tiers[2]
    check(sl.ok and sl.economy == "READY" and sl.blocked == nil and sl.free.n == 1 and sl.free.used == 1
        and #sl.free.titles == 1 and sl.free.titles[1] == a1.title and #sl.tiers == 3, "slots：免費位與只列 3 個啟用等級")
    check(row1.tier == 1 and row1.paid == 2 and row1.usable == 2 and row1.grace == 0 and row1.buy == true
        and row1.rent == false and row1.buyPrice.amount == 1200 and row1.rentPrice == nil, "tier1：付費 2、可用 2、只有買斷價")
    check(row2.paid == 1 and row2.usable == 1 and row2.buyPrice == nil and row2.rentPrice == nil, "tier2：販售關著沒有價格")

    T.section("停用：只有寬限結束造成的超額，停該級最新一間")
    T.econSet("alice", 1, 0, { lease("L1", 1, "active"), lease("L2", 1, "grace", T.now + HOUR) })
    T.tick(1)
    check(a2.lifecycle == "active" and a3.lifecycle == "active", "寬限中仍算 usable：不停用")
    T.advance(HOUR)
    T.econSet("alice", 1, 0, { lease("L1", 1, "active"), lease("L2", 1, "expired", nil, 1001) })
    T.tick(1)
    check(a3.lifecycle == "lapsed" and a3.lapsedAt == T.now and a2.lifecycle == "active" and a1.lifecycle == "active"
        and a4.lifecycle == "active" and a5.lifecycle == "active", "寬限結束仍超額：停 tier1 最新一間；免費位與別級不動")
    T.tick(5)
    check(T.houseOf(MSH.marker(a3.claimId)) == nil, "Reconcile 移除停用屋的原生")
    minute()
    check(a2.lifecycle == "active" and a3.lifecycle == "lapsed", "再評估：不多停")
    local info = E.claimInfo(a3)
    check(info.paid == true and info.tier == 1 and info.lapsedAt == a3.lapsedAt and info.releaseAt == a3.lapsedAt + 7 * DAY,
        "claimInfo：付費、等級、停用時間與釋出時間")
    check(E.claimInfo(a1).paid == false and E.claimInfo(a1).lapsedAt == nil, "claimInfo：免費位不是付費")

    T.section("續租恢復、Reconcile 重建原生")
    T.econSet("alice", 1, 0, { lease("L1", 1, "active"), lease("L2", 1, "active") })
    T.tick(1)
    check(a3.lifecycle == "active" and a3.lapsedAt == nil, "續租：恢復 active")
    T.tick(5)
    check(T.houseOf(MSH.marker(a3.claimId)) ~= nil, "Reconcile 重建原生")

    T.section("期滿釋出（只在 READY）")
    T.econSet("alice", 1, 0, { lease("L1", 1, "active"), lease("L2", 1, "expired", nil, 1002) })
    T.tick(1)
    check(a3.lifecycle == "lapsed", "再次到期：停用")
    T.advance(6 * DAY)
    minute()
    check(a3.lifecycle == "lapsed" and R.get(a3.claimId) == a3, "保留期內不釋出")
    T.advance(DAY)
    minute()
    check(a3.lifecycle == "released" and a3.releaseReason == "LAPSE_EXPIRED" and R.get(a3.claimId) == nil
        and R.tomb(a3.claimId) ~= nil and a2.lifecycle == "active", "lapseKeepDays 期滿 → released（只剩 tombstone）")

    T.section("寬限結束後租約直接被移除也算；寬限截止前移除（退款）與管理員調低不停用")
    local bob = T.player({ name = "bob", items = { D1 } })
    seed("bob", rect(1000, 1000, 5, 5), 1)
    T.econSet("bob", 1, 0, { lease("M1", 1, "active") })
    local b2 = R.get(create(bob, 1100, 1100).claimId)
    T.econSet("bob", 1, 0, { lease("M1", 1, "grace", T.now + HOUR) })
    T.tick(1)
    T.advance(HOUR)
    T.econSet("bob", 1, 0, {})
    T.tick(1)
    check(b2.lifecycle == "lapsed", "看過寬限、截止後租約消失 → 停用")
    local carol = T.player({ name = "carol", items = { D1 } })
    seed("carol", rect(1300, 1300, 5, 5), 1)
    T.econSet("carol", 1, 0, { lease("N1", 1, "active") })
    local c2 = R.get(create(carol, 1400, 1400).claimId)
    T.econSet("carol", 1, 0, { lease("N1", 1, "grace", T.now + HOUR) })
    T.tick(1)
    T.econSet("carol", 1, 0, {})   -- 寬限截止前退款
    T.tick(1)
    minute()
    check(c2.lifecycle == "active", "寬限截止前租約消失（退款）：不停用")
    local dave = T.player({ name = "dave", items = { D1, D1 } })
    seed("dave", rect(1600, 1600, 5, 5), 1)
    T.econSet("dave", 1, 1, {})
    local d2 = R.get(create(dave, 1700, 1700).claimId)
    T.econSet("dave", 1, 0, {})    -- 買斷被退款
    R.setOverride("dave", 0)       -- 管理員調低免費位
    T.tick(1)
    minute()
    check(d2.lifecycle == "active", "退款與管理員調低造成的超額：不停用")
    check(create(dave, 1800, 1800).code == "QUOTA_FULL", "…只擋新增")

    T.section("ABSENT：全部恢復、不釋出；FAILED：不動")
    local bobId = b2.claimId
    boot({ econ = false, keepGmd = true, keepFiles = true, keepHouses = true })
    check(R.get(bobId).lifecycle == "active", "ABSENT 開服：停用的恢復 active")
    R.get(bobId).lifecycle, R.get(bobId).lapsedAt = "lapsed", T.now
    minute()
    check(R.get(bobId).lifecycle == "active", "ABSENT 每分鐘：停用的恢復")
    R.get(bobId).lifecycle, R.get(bobId).lapsedAt = "lapsed", T.now
    boot({ econ = { keep = true, failRegister = true }, keepGmd = true, keepFiles = true, keepHouses = true })
    check(E.status == "FAILED" and R.get(bobId).lifecycle == "lapsed", "FAILED 開服：不恢復")
    T.advance(8 * DAY)
    minute()
    check(R.get(bobId) ~= nil and R.get(bobId).lifecycle == "lapsed", "FAILED：期滿也不釋出")
    T.advance(1000)
    sl = T.cmd(bob, "slots", {})
    check(sl.ok and sl.economy == "FAILED" and sl.tiers[1].usable == 0 and sl.tiers[1].buyPrice == nil,
        "不是 READY：slots 照列等級但 usable＝0、沒有價格")

    T.section("adminPlans／adminSetPlan")
    boot()
    local root = T.player({ name = "root", admin = true })
    local plans = T.cmd(root, "adminPlans", {})
    check(plans.ok and plans.economy == "READY" and #plans.tiers == 8 and plans.tiers[2].revision == 1
        and plans.tiers[2].plan.rentalPrice == 300 and #plans.currencies == 2, "adminPlans：8 級方案、revision、幣別")
    local values = plans.tiers[2].plan
    values.rentalPrice = 350
    res = T.cmd(root, "adminSetPlan", { tier = 2, values = values, expectedRevision = 1, reason = "調價" })
    check(res.ok and res.tier == 2 and res.revision == 2 and #res.changed == 1 and res.changed[1] == "rentalPrice"
        and T.econ.setPlans[#T.econ.setPlans].opts.origin == "admin", "adminSetPlan：改價、revision＋1、changed")
    values.rentalPrice = 400
    res = T.cmd(root, "adminSetPlan", { tier = 2, values = values, expectedRevision = 1 })
    check(res.code == "STALE_REVISION", "舊 revision → STALE_REVISION")
    values.rentalPrice = 0
    res = T.cmd(root, "adminSetPlan", { tier = 2, values = values, expectedRevision = 2 })
    check(res.code == "INVALID_PLAN" and res.field == "rentalPrice", "不合法 → INVALID_PLAN＋field")
    values.rentalPrice, values.bogus = 400, 1
    res = T.cmd(root, "adminSetPlan", { tier = 2, values = values, expectedRevision = 2 })
    check(res.code == "BAD_ARGS", "未知欄位在協定層就拒絕")
    values.bogus = nil
    res = T.cmd(T.player({ name = "eve" }), "adminSetPlan", { tier = 2, values = values, expectedRevision = 2 })
    check(res.code == "NOT_ADMIN", "非管理員 → NOT_ADMIN")
    boot({ econ = false })
    root = T.player({ name = "root", admin = true })
    res = T.cmd(root, "adminSetPlan", { tier = 2, values = values, expectedRevision = 2 })
    plans = T.cmd(root, "adminPlans", {})
    check(res.code == "ECONOMY_UNAVAILABLE" and plans.ok and plans.economy == "ABSENT" and #plans.tiers == 0,
        "ABSENT：adminSetPlan → ECONOMY_UNAVAILABLE、adminPlans 沒有方案")

    T.section("Tier 開關：開服就打開方案、免費建立模式只有 1 級")
    boot({ sandbox = { Tier2Rent = true } })
    check(T.econ.plans.tier2.values.rentalEnabled == true and T.econ.plans.tier2.values.permanentEnabled == false,
        "開服：Tier2Rent 開 → 方案 rentalEnabled 打開，買斷不動")
    boot({ sandbox = { CreateMode = 2, Tier2Buy = true } })
    ok, why = validate("zed", "tier2", "permanent", { permanent = 1, rental = 0 })
    check(ok == false and why == "TIER_DISABLED", "免費建立模式：2 級以上算未啟用")

    boot()

    T.section("兩次到期分別停用；同一次到期只算一次（連續列著、重開、之後退款）；續租恢復最舊的")
    local erin = T.player({ name = "erin", items = { D1, D1, D1 } })
    seed("erin", rect(2000, 2000, 5, 5), 1)
    T.econSet("erin", 1, 0, { lease("P1", 1, "active"), lease("P2", 1, "active"), lease("P3", 1, "active") })
    local eA = R.get(create(erin, 2100, 2100).claimId)
    local eB = R.get(create(erin, 2200, 2200).claimId)
    local eC = R.get(create(erin, 2300, 2300).claimId)
    T.econSet("erin", 1, 0, { lease("P1", 1, "active"), lease("P2", 1, "active"), lease("P3", 1, "expired", nil, 3003) })
    T.tick(1)
    check(eC.lifecycle == "lapsed" and eB.lifecycle == "active" and eA.lifecycle == "active", "第一次到期：停最新的 C")
    T.advance(3 * DAY)
    T.econSet("erin", 1, 0, { lease("P1", 1, "active"), lease("P2", 1, "expired", nil, 3002), lease("P3", 1, "expired", nil, 3003) })
    T.tick(1)
    check(eB.lifecycle == "lapsed" and eC.lifecycle == "lapsed" and eA.lifecycle == "active", "第二次到期：B 也停用")
    minute()
    check(eA.lifecycle == "active", "兩張 expired 租約下一輪仍列著：不多停")
    T.advance(4 * DAY)
    minute()
    check(eC.lifecycle == "released" and eB.lifecycle == "lapsed" and eA.lifecycle == "active",
        "C 期滿釋出後 B 仍停用、A 不受影響")
    T.advance(3 * DAY)
    minute()
    check(eB.lifecycle == "released" and eA.lifecycle == "active", "B 期滿釋出；A 不因舊的到期被停")
    local fred = T.player({ name = "fred", items = { D1, D1, D1 } })
    -- 先讓超額大於停用數（管理員調低免費位：只擋新增），連續列著的同一張 expired 租約才看得出有沒有重算
    local gail = T.player({ name = "gail", items = { D1, D1 } })
    local g0 = seed("gail", rect(3200, 3200, 5, 5), 1)
    T.econSet("gail", 1, 0, { lease("R1", 1, "active"), lease("R2", 1, "active") })
    local gA = R.get(create(gail, 3300, 3300).claimId)
    local gB = R.get(create(gail, 3400, 3400).claimId)
    R.setOverride("gail", 0)
    minute()
    check(g0.lifecycle == "active" and gA.lifecycle == "active" and gB.lifecycle == "active", "gail：調低免費位只擋新增")
    T.econSet("gail", 1, 0, { lease("R1", 1, "active"), lease("R2", 1, "expired", nil, 5002) })
    T.tick(1)
    check(gB.lifecycle == "lapsed" and gA.lifecycle == "active", "gail：到期停最新的一間")
    for _ = 1, 3 do
        T.econSet("gail", 1, 0, { lease("R1", 1, "active"), lease("R2", 1, "expired", nil, 5002) })
        T.tick(1)
    end
    minute()
    check(gA.lifecycle == "active" and g0.lifecycle == "active", "同一張 expired 租約連續通知三輪、超額仍大：不多停")
    seed("fred", rect(2600, 2600, 5, 5), 1)
    T.econSet("fred", 1, 0, { lease("Q1", 1, "active"), lease("Q2", 1, "active"), lease("Q3", 1, "active") })
    local fA = R.get(create(fred, 2700, 2700).claimId)
    local fB = R.get(create(fred, 2800, 2800).claimId)
    local fC = R.get(create(fred, 2900, 2900).claimId)
    T.econSet("fred", 1, 0, { lease("Q1", 1, "active"), lease("Q2", 1, "active"), lease("Q3", 1, "expired", nil, 4003) })
    T.tick(1)
    check(fC.lifecycle == "lapsed" and fB.lifecycle == "active", "fred：到期停最新的 C")
    T.econSet("fred", 1, 0, { lease("Q1", 1, "active"), lease("Q3", 1, "expired", nil, 4003) })   -- Q2 寬限前退款
    T.tick(1)
    minute()
    check(fB.lifecycle == "active" and fA.lifecycle == "active", "停用之後再退款：不多停（只擋新增）")
    local fredIds = { fA.claimId, fB.claimId, fC.claimId }
    boot({ keepGmd = true, keepFiles = true, keepHouses = true, econ = { keep = true } })
    T.tick(1)
    minute()
    local fA2, fB2, fC2 = R.get(fredIds[1]), R.get(fredIds[2]), R.get(fredIds[3])
    check(E.status == "READY" and fA2.lifecycle == "active" and fB2.lifecycle == "active" and fC2.lifecycle == "lapsed",
        "重開（RAM 清空）後同一張 expired 租約：不多停")
    T.econSet("fred", 1, 0, { lease("Q1", 1, "active"), lease("Q2", 1, "expired", nil, 4002), lease("Q3", 1, "expired", nil, 4003) })
    T.tick(1)
    check(fB2.lifecycle == "lapsed" and fC2.lifecycle == "lapsed", "重開後新的一次到期：再停 B")
    T.econSet("fred", 1, 0, { lease("Q1", 1, "active"), lease("Q2", 1, "expired", nil, 4002), lease("Q3", 1, "active") })
    T.tick(1)
    check(fB2.lifecycle == "active" and fC2.lifecycle == "lapsed", "續租一張：恢復最舊的 B、C 仍停用")
    MinidoracatEconomy = nil
end
