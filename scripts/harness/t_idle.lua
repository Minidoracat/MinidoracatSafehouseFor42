-- 閒置收回與保險（Idle.lua；使用者 2026-10-14）：起算、到訪刷新（任一塊）、停機不算、種類（免費／買斷／租用／不知道）、
-- 付費名額保護最久沒人回去的幾間（不連鎖）、保險（購買、自然到期、退款）、收回（原因 IDLE、稽核、移除通知、每次上限）、
-- detail 的 idle、validatePurchase、保險方案（IdleInsure 開關、adminPlans／adminSetPlan）、設定不健康與整個關掉。
-- 假 Economy 在 env.lua 的 T.economy／T.econSet／T.econInsure；T.visit 模擬引擎記 lastVisited。
return function(T)
    local check = T.check
    local DAY, MIN = 86400000, 60000
    local CAPS = { entitlements = true, subscriptions = true, rentals = true, setPlan = true, freeze = true,
        rentalPeriods = true }
    local MSH, R

    -- econ：傳給 T.economy 的 opts（預設有一次付多期能力）；false＝不裝 Economy
    local function boot(opts)
        opts = opts or {}
        local econ = opts.econ
        opts.beforeStart = function()
            if econ ~= false then T.economy(econ or { revision = 7, caps = CAPS }) end
        end
        MSH = T.boot(opts)
        R = MSH.Registry
        return MSH
    end
    local function rect(x, y, w, h) return { x = x, y = y, w = w, h = h } end
    local function seed(owner, rects, tier, source)
        local rec = R.newRecord({ claimId = R.allocId(), rects = rects, title = owner .. rects[1].x, owner = owner,
            source = source or MSH.SOURCE.DEED, deedTier = tier or 1, createdAt = T.now })
        local houses = MSH.Native.build(rec, {})
        for i, hs in ipairs(houses) do rec.rects[i].created = hs:getDatetimeCreated() end
        R.put(rec)
        T.advance(1000)
        return rec
    end
    local function natives(rec)
        local out = {}
        for _, hs in ipairs(T.houses) do if hs.owner == MSH.marker(rec.claimId) then out[#out + 1] = hs end end
        return out
    end
    local function released(rec) return R.get(rec.claimId) == nil and R.tomb(rec.claimId) ~= nil end
    local function alive(rec) local r = R.get(rec.claimId) return r ~= nil and r.lifecycle == "active" end
    local function minute()
        T.advance(MIN)
        T.tick(1)
    end
    -- 伺服器照常運轉 ms：每 9 分鐘檢查一次（間隔沒超過 DOWNTIME_MS，不會被記成停機）
    local function run(ms)
        local stop = T.now + ms
        while T.now + 9 * MIN <= stop do
            T.advance(9 * MIN - 100)
            T.tick(1)
        end
        if stop > T.now then
            T.advance(stop - T.now)
            T.tick(1)
        end
    end
    local function detail(name, rec)
        return T.cmd(T.player({ name = name }), "detail", { claimId = rec.claimId })
    end
    local function lease(id, state, paidUntil)
        return { { id = id, quantity = 1, state = state, paidUntil = paidUntil } }
    end

    T.section("起算：舊屋從這版第一次檢查起有完整 14 天；任一塊有人到訪就重新計時")
    boot()
    local a = seed("alice", { rect(100, 100, 5, 5) }, 1)
    local b = seed("bob", { rect(200, 200, 5, 5), rect(205, 200, 5, 5) }, 1)
    for _, hs in ipairs(natives(a)) do hs.lastVisited = T.now - 100 * DAY end   -- 原版時代最後一次到訪
    minute()
    local md = MSH.Idle.state()
    check(md.since.free ~= nil and md.since.buy ~= nil and md.at == T.now, "第一次檢查記下起算時間與檢查時間")
    run(10 * DAY)
    T.visit(natives(b)[2])   -- 第二塊有人站進去
    run(3 * DAY)
    check(alive(a) and alive(b), "第 13 天：100 天前到訪過的舊屋也還在（照第一次檢查起算）")
    local d = detail("alice", a)
    check(d.ok and d.idle and d.idle.kind == "free" and d.idle.days == 14
        and math.abs(d.idle.remainingMs - DAY) < 10 * MIN, "detail：免費屋、14 天、剩約 1 天")
    run(DAY + 20 * MIN)
    check(released(a) and #natives(a) == 0, "第 14 天過後沒人到訪：收回、原生移除")
    check(T.logged("IDLE_RELEASED") and #T.broadcastsOf("nativeRemove") >= 1, "寫 IDLE_RELEASED 稽核、送移除通知")
    check(alive(b), "反面：第二塊第 10 天有人到訪的那間還在（整間取各塊最晚的到訪）")
    run(10 * DAY)
    check(released(b), "第二塊到訪後 14 天：收回")

    T.section("停機不算：檢查間隔超過 10 分鐘記成停機，閒置時間扣掉")
    boot()
    local c = seed("carol", { rect(100, 100, 5, 5) }, 1)
    minute()
    run(10 * DAY)
    T.advance(20 * DAY)   -- 伺服器關機 20 天
    minute()
    check(alive(c), "停機 20 天後開機：沒被收回")
    md = MSH.Idle.state()
    check(#md.down == 1 and md.down[1].e - md.down[1].s >= 20 * DAY, "記下一段停機")
    d = detail("carol", c)
    check(d.idle and math.abs(d.idle.remainingMs - 4 * DAY) < 15 * MIN, "detail：停機不算，還剩約 4 天")
    run(3 * DAY)
    check(alive(c), "開機後第 3 天還在")
    run(DAY + 20 * MIN)
    check(released(c), "實際運轉滿 14 天：收回")

    T.section("種類：買斷 30 天、付費名額保護最久沒人回去的那間（不連鎖）、租用不收、讀不到不收")
    boot()
    local d1 = seed("dave", { rect(100, 100, 5, 5) }, 1)
    local d2 = seed("dave", { rect(200, 100, 5, 5) }, 1)
    T.econSet("dave", 1, 1, {})
    local e1 = seed("erin", { rect(300, 100, 5, 5) }, 1)
    T.econSet("erin", 1, 0, { { id = "R1", quantity = 1, state = "active" } })
    local f1 = seed("frank", { rect(400, 100, 5, 5) }, 1)
    T.econ.failRead.frank = true
    minute()
    local dd1, dd2 = detail("dave", d1), detail("dave", d2)
    check(dd1.idle.kind == "buy" and dd1.idle.days == 30 and dd2.idle.kind == "free" and dd2.idle.days == 14,
        "買斷 1 個：較久沒人回去的 d1 算買斷（30 天）、d2 算免費（14 天）")
    check(detail("erin", e1).idle.kind == "rent" and detail("erin", e1).idle.remainingMs == nil, "租用名額：rent、沒有倒數")
    check(detail("frank", f1).idle.kind == "unknown", "讀不到 Economy：unknown")
    run(14 * DAY + 20 * MIN)
    check(released(d2) and alive(d1), "第 14 天：免費的 d2 收回、買斷的 d1 還在")
    run(5 * DAY)
    check(alive(d1), "d2 收走後免費位沒有把 d1 的期限縮短（第 19 天還在）")
    run(11 * DAY)
    check(released(d1), "第 30 天：買斷的也收回")
    check(alive(e1), "反面：租用名額保護的 30 天沒人到訪也不收")
    check(alive(f1), "反面：讀不到 Economy 的不收")

    T.section("Economy 沒裝：沒有付費名額，照免費 14 天")
    boot({ econ = false })
    local g0 = seed("gail", { rect(100, 100, 5, 5) }, 2)
    minute()
    check(detail("gail", g0).idle.kind == "free" and detail("gail", g0).idle.insure == nil, "ABSENT：free、沒有購買資訊")
    run(14 * DAY + 20 * MIN)
    check(released(g0), "ABSENT：14 天收回")

    T.section("保險：期間視同到訪、結束後重新倒數；自然到期被移除照算、退款不算")
    boot()
    local root = T.player({ name = "root", admin = true })
    local plans = T.cmd(root, "adminPlans", {})
    check(plans.ok and plans.insureReady == true and plans.tiers[1].insure ~= nil
        and plans.tiers[1].insure.plan.rentalPrice == 10 and plans.tiers[3].insure.plan.rentalPrice == 70,
        "adminPlans：insureReady、每級保險方案（預設每日 10／30／70）")
    local ip = T.econ.plans.insure1.values
    check(ip.rentalDays == 1 and ip.rentalLimit == 1 and ip.graceHours == 0 and ip.reminderHours == 0
        and ip.autoRenewAllowed == false and ip.permanentEnabled == false and ip.rentalEnabled == false,
        "保險方案預設：每期 1 天、每人一張、沒寬限提醒、不自動續租、不賣買斷、還沒開賣")
    local gina = seed("gina", { rect(100, 100, 5, 5) }, 1)
    local ivan = seed("ivan", { rect(200, 100, 5, 5) }, 1)
    local validate = T.econ.products.insure1.validatePurchase
    local ok, why = validate("gina", "insure1", "rental", 1, {})
    check(ok == false and why == "INSURE_CLOSED", "IdleInsure 關：INSURE_CLOSED")
    T.sandbox("IdleInsure", true)
    minute()
    check(T.econ.plans.insure1.values.rentalEnabled == true and T.econ.plans.insure8.values.rentalEnabled == true,
        "IdleInsure 打開：每分鐘檢查以 setPlan 開賣各級保險")
    check(validate("gina", "insure1", "rental", 1, {}) == true, "有 1 級的屋：放行")
    ok, why = validate("gina", "insure2", "rental", 1, {})
    check(ok == false and why == "NOT_INSURABLE", "沒有 2 級的屋：NOT_INSURABLE")
    ok, why = validate("gina", "insure1", "permanent", 1, {})
    check(ok == false and why == "INSURE_CLOSED", "買斷種類：拒絕")
    local dg = detail("gina", gina)
    check(dg.idle.insure and dg.idle.insure.product == "insure1" and dg.idle.insure.price == 10
        and dg.idle.insure.currency == "survivor" and dg.idle.insure.lease == nil and dg.idle.insure.maxDays == 365,
        "屋主看得到購買資訊（產品、每日價、幣別、還沒有租約）")
    T.econInsure("gina", 1, lease("I1", "active", T.now + 10 * DAY))
    T.econInsure("ivan", 1, lease("I2", "active", T.now + 10 * DAY))
    T.tick(1)
    dg = detail("gina", gina)
    check(dg.idle.insuredMs and math.abs(dg.idle.insuredMs - 10 * DAY) < MIN and dg.idle.insure.lease == "I1"
        and math.abs(dg.idle.remainingMs - 24 * DAY) < 2 * MIN, "買 10 天：保險剩 10 天、續買帶租約 id、保留約 24 天")
    run(2 * DAY)
    T.econInsure("ivan", 1, nil)   -- 第 2 天退款：租約不在、還沒到期
    T.tick(1)
    run(8 * DAY + MIN)
    T.econInsure("gina", 1, nil)   -- 第 10 天到期，Economy 移除租約
    T.tick(1)
    run(4 * DAY + 20 * MIN)
    check(alive(gina), "第 14 天：保險自然到期被移除後照算，還在")
    check(released(ivan), "第 14 天：退款的保險不算，收回")
    run(10 * DAY)
    check(released(gina), "保險結束後 14 天（第 24 天）：收回")

    T.section("adminSetPlan：保險只改每日價與幣別，其餘固定、開賣照開關")
    local values = {}
    for k, v in pairs(T.econ.plans.insure2.values) do values[k] = v end
    values.rentalPrice, values.rentalCurrency, values.rentalDays, values.autoRenewAllowed = 45, "gold", 7, true
    local rev = T.econ.plans.insure2.revision
    local res = T.cmd(root, "adminSetPlan", { tier = 2, product = "insure", values = values, expectedRevision = rev })
    local v2 = T.econ.plans.insure2.values
    check(res.ok and res.product == "insure" and v2.rentalPrice == 45 and v2.rentalCurrency == "gold"
        and v2.permanentCurrency == "gold" and v2.rentalDays == 1 and v2.autoRenewAllowed == false
        and v2.rentalEnabled == true, "每日價與幣別照送的，每期天數、自動續租固定，開賣維持開關的值")
    check(T.econ.plans.tier2.values.rentalPrice == 300, "反面：沒動到 2 級名額方案")
    res = T.cmd(root, "adminSetPlan", { tier = 2, product = "lease", values = values, expectedRevision = rev + 1 })
    check(res.code == "BAD_ARGS", "product 只收 tier／insure")

    T.section("一次不收太多：同時到期的分幾輪收")
    boot()
    local many = {}
    for i = 1, 7 do many[i] = seed("p" .. i, { rect(100 * i, 500, 5, 5) }, 1) end
    minute()
    run(14 * DAY - 10 * MIN)
    local function count()
        local n = 0
        for _, rec in ipairs(many) do if released(rec) then n = n + 1 end end
        return n
    end
    check(count() == 0, "還沒到期：一間都沒收")
    for _ = 1, 30 do
        if count() > 0 then break end
        minute()
    end
    local first = count()
    check(first > 0 and first < #many, "同時到期 7 間：這一輪只收一部分（" .. first .. " 間）")
    minute()
    check(count() == #many, "下一輪收完剩下的")

    T.section("設定不健康時不收；整個關掉時不收、重新打開有完整期限")
    boot()
    local h1 = seed("hank", { rect(100, 100, 5, 5) }, 1)
    minute()
    T.serverOptions.SafeHouseRemovalTime = "144"
    run(14 * DAY + 20 * MIN)
    check(MSH.Health.blocked() and alive(h1), "必要設定不符（blocked）：到期也不收")
    T.serverOptions.SafeHouseRemovalTime = "0"
    run(20 * MIN)
    check(not MSH.Health.blocked() and released(h1), "設定修好：照常收回")
    local h2 = seed("hank", { rect(200, 100, 5, 5) }, 1)
    T.sandbox("IdleDays", 0)
    T.sandbox("IdleBuyDays", 0)
    run(30 * DAY)
    check(alive(h2) and detail("hank", h2).idle == nil, "IdleDays、IdleBuyDays 都是 0：不收、detail 沒有 idle")
    T.sandbox("IdleDays", 14)
    run(13 * DAY)
    check(alive(h2), "重新打開後第 13 天還在（從打開那時起算）")
    run(DAY + 20 * MIN)
    check(released(h2), "打開後滿 14 天：收回")

    T.section("失去保護後從那時起有完整天數：租約結束、買斷退款、Economy 不見、讀不到之後")
    boot()
    local rent1 = seed("rita", { rect(100, 100, 5, 5) }, 1)
    T.econSet("rita", 1, 0, { { id = "R1", quantity = 1, state = "active" } })
    local buy1 = seed("bert", { rect(200, 100, 5, 5) }, 1)
    T.econSet("bert", 1, 1, {})
    local fail1 = seed("fay", { rect(300, 100, 5, 5) }, 1)
    T.econ.failRead.fay = true
    local mid1 = seed("ron", { rect(400, 100, 5, 5) }, 1)
    T.econSet("ron", 1, 1, {})
    minute()
    run(10 * DAY)
    T.visit(natives(mid1)[1])        -- 第 10 天有人回去：失去保護時還沒超過 14 天
    run(10 * DAY)
    check(alive(rent1) and alive(buy1) and alive(fail1), "第 20 天：租用、買斷、讀不到的都還在")
    T.econSet("rita", 1, 0, {})     -- 租約移除（通知）
    T.econSet("bert", 1, 0, {})     -- 買斷退款（通知）
    T.econSet("ron", 1, 0, {})
    T.econ.failRead.fay = nil
    T.tick(1)
    minute()
    local dr = detail("rita", rent1)
    check(alive(rent1) and dr.idle.kind == "free" and math.abs(dr.idle.remainingMs - 14 * DAY) < 10 * MIN,
        "租約結束：沒被馬上收，從那時起剩 14 天")
    check(alive(buy1) and detail("bert", buy1).idle.kind == "free", "買斷退款：沒被馬上收")
    check(alive(fail1), "讀不到的期間不算：恢復時沒被一次收掉")
    local dm = detail("ron", mid1)
    check(dm.idle.kind == "free" and math.abs(dm.idle.remainingMs - 14 * DAY) < 10 * MIN,
        "10 天前有人回去、還沒到期的買斷屋退款：也從那時起剩 14 天（不是只剩 4 天）")
    run(13 * DAY)
    check(alive(rent1) and alive(buy1) and alive(fail1), "失去保護後第 13 天還在")
    run(DAY + 20 * MIN)
    check(released(rent1) and released(buy1) and released(fail1), "失去保護後滿 14 天：收回")
    boot()
    local gone = seed("gus", { rect(100, 100, 5, 5) }, 1)
    T.econSet("gus", 1, 0, { { id = "R2", quantity = 1, state = "active" } })
    minute()
    run(20 * DAY)
    boot({ econ = false, keepGmd = true, keepHouses = true, keepFiles = true })
    minute()
    check(alive(gone) and detail("gus", gone).idle.kind == "free", "Economy 拿掉後重開：原本租用保護的屋沒被馬上收")
    run(13 * DAY)
    check(alive(gone), "Economy 拿掉後第 13 天還在")
    run(DAY + 20 * MIN)
    check(released(gone), "Economy 拿掉後滿 14 天：收回")

    T.section("隔離後重新綁回：沒有上次的種類也給完整天數；保險記錄沒被清掉")
    boot()
    local qa = seed("quinn", { rect(100, 100, 5, 5) }, 1)
    T.econSet("quinn", 1, 0, { { id = "R5", quantity = 1, state = "active" } })
    local qb = seed("quill", { rect(200, 100, 5, 5) }, 1)
    T.econSet("quill", 1, 0, { { id = "R6", quantity = 1, state = "active" } })
    minute()
    run(20 * DAY)
    T.econInsure("quinn", 1, lease("Q1", "active", T.now + 30 * DAY))
    T.tick(1)
    for _, h in ipairs({ qa, qb }) do R.get(h.claimId).lifecycle = MSH.LIFECYCLE.QUARANTINED end
    minute()
    local qmd = MSH.Idle.state()
    check(qmd.kinds[qb.claimId] == nil and type(qmd.ins.quinn) == "table",
        "隔離中：種類清掉，保險記錄留著（屋主那一級還有紀錄）")
    T.econSet("quinn", 1, 0, {})      -- 隔離期間租約結束
    T.econSet("quill", 1, 0, {})
    boot({ econ = false, keepGmd = true, keepHouses = true, keepFiles = true })
    for _, h in ipairs({ qa, qb }) do R.get(h.claimId).lifecycle = MSH.LIFECYCLE.ACTIVE end   -- 管理員綁回，原生沒重建
    minute()
    check(alive(qb) and math.abs(detail("quill", qb).idle.remainingMs - 14 * DAY) < 10 * MIN,
        "綁回、20 天沒人去、租約已結束：從綁回那時起剩 14 天，沒被馬上收")
    local dq = detail("quinn", qa)
    check(alive(qa) and dq.idle.insuredMs ~= nil and dq.idle.remainingMs > 40 * DAY,
        "綁回時讀不到 Economy：照記下的保險（還有約 30 天）再加 14 天")

    T.section("管理員把天數改短：從改的那時起至少有新的天數；停機後買保險又退款，停機照樣不算")
    boot()
    local sb = seed("bea", { rect(100, 100, 5, 5) }, 1)
    T.econSet("bea", 1, 1, {})
    minute()
    run(15 * DAY)
    local sf = seed("fiz", { rect(200, 100, 5, 5) }, 1)
    run(10 * DAY)
    check(alive(sb) and alive(sf), "（前置）買斷 25 天、免費 10 天沒人去，都還在")
    T.sandbox("IdleBuyDays", 20)
    T.sandbox("IdleDays", 7)
    minute()
    local db, df = detail("bea", sb), detail("fiz", sf)
    check(alive(sb) and db.idle.kind == "buy" and math.abs(db.idle.remainingMs - 20 * DAY) < 10 * MIN,
        "IdleBuyDays 30 改 20：買斷那間沒被馬上收，從改的那時起剩 20 天")
    check(alive(sf) and math.abs(df.idle.remainingMs - 7 * DAY) < 10 * MIN, "IdleDays 14 改 7：免費那間從改的那時起剩 7 天")
    boot()
    local dh = seed("dot", { rect(100, 100, 5, 5) }, 1)
    minute()
    run(10 * DAY)
    T.advance(20 * DAY)                -- 停機 20 天（OnTick 不跑）
    minute()
    T.econInsure("dot", 1, lease("D1", "active", T.now + 10 * DAY))
    T.tick(1)
    minute()                           -- 保險中分類一次（清停機紀錄的時機）
    run(DAY)
    T.econInsure("dot", 1, nil)        -- 退款
    T.tick(1)
    minute()
    check(alive(dh) and math.abs(detail("dot", dh).idle.remainingMs - 3 * DAY) < 30 * MIN,
        "停機 20 天後買保險又退款：停機照樣不算（實際閒置 11 天，剩約 3 天）")
    boot()
    T.sandbox("IdleDays", 29)
    local up = seed("una", { rect(100, 100, 5, 5) }, 1)
    minute()
    run(28 * DAY)
    T.sandbox("IdleDays", 28)          -- 只改短免費（買斷仍是 30）：免費那邊從這時重新起算
    minute()
    run(12 * DAY)
    T.econSet("una", 1, 1, {})         -- 第 40 天買一個買斷名額：免費屋升級成買斷
    minute()
    local du = detail("una", up)
    check(alive(up) and du.idle.kind == "buy" and math.abs(du.idle.remainingMs - 18 * DAY) < 30 * MIN,
        "只把免費改短、之後買了買斷名額：從免費重新起算那時算 30 天（剩約 18 天），付了錢不會反而被收")

    T.section("同一組一輪只收一間：收掉後付費名額改保護剩下的")
    boot()
    local fa = seed("finn", { rect(100, 100, 5, 5) }, 1)
    T.econSet("finn", 1, 1, {})
    minute()
    run(16 * DAY)
    local fb = seed("finn", { rect(200, 100, 5, 5) }, 1)
    minute()
    T.serverOptions.SafeHouseRemovalTime = "144"   -- 設定不健康：照記帳、不收
    run(15 * DAY)
    T.serverOptions.SafeHouseRemovalTime = "0"
    check(alive(fa) and alive(fb), "（前置）A（買斷，31 天沒人去）、B（免費，15 天沒人去）都過了期限、都還在")
    run(20 * MIN)
    check(released(fa) and alive(fb), "設定修好後同一輪兩間都到期：只收最久沒人回去的 A")
    check(detail("finn", fb).idle.kind == "buy", "A 收走後買斷名額改保護 B（30 天），B 沒被收")

    T.section("買斷保護不比免費弱；保險自然結束後再買又退款，前一次照算；保險買不到的情況")
    boot()
    T.sandbox("IdleDays", 0)
    local keep = seed("kim", { rect(100, 100, 5, 5) }, 1)
    T.econSet("kim", 1, 1, {})
    minute()
    check(detail("kim", keep).idle == nil, "IdleDays 0：整個不收，買斷那間也不收（不會變成 30 天）、detail 沒有 idle")
    run(40 * DAY)
    check(alive(keep), "40 天後還在")
    T.sandbox("IdleInsure", true)
    local okk, whyk = MSH.Idle.canInsure("kim", 1, "rental")
    check(okk == false and whyk == "INSURE_CLOSED", "IdleDays 0（整個不收）：保險不賣，INSURE_CLOSED")
    T.sandbox("IdleInsure", false)
    T.sandbox("IdleDays", 14)
    local ins2 = seed("ivy", { rect(200, 100, 5, 5) }, 1)
    minute()
    T.econInsure("ivy", 1, lease("J1", "active", T.now + 5 * DAY))
    T.tick(1)
    run(5 * DAY + MIN)
    T.econInsure("ivy", 1, nil)          -- 第 5 天自然結束、被移除
    T.tick(1)
    run(DAY)
    T.econInsure("ivy", 1, lease("J2", "active", T.now + 5 * DAY))   -- 第 6 天再買一張
    T.tick(1)
    run(DAY)
    T.econInsure("ivy", 1, nil)          -- 第 7 天退款
    T.tick(1)
    local di = detail("ivy", ins2)
    check(di.idle.insuredMs == nil and math.abs(di.idle.remainingMs - 12 * DAY) < 10 * MIN,
        "退掉第二張：第一張的結束時間照算（第 5 天起 14 天，剩 12 天）")
    run(11 * DAY)
    check(alive(ins2), "第 18 天還在")
    run(DAY + 20 * MIN)
    check(released(ins2), "第一張保險結束後滿 14 天（第 19 天）：收回")
    T.sandbox("IdleInsure", true)
    local rentAll = seed("rae", { rect(300, 100, 5, 5) }, 1)
    T.econSet("rae", 1, 0, { { id = "R3", quantity = 1, state = "active" } })
    local ok2, why2 = MSH.Idle.canInsure("rae", 1, "rental")
    check(ok2 == false and why2 == "NOT_INSURABLE", "那一級全部由租用名額保護：保險沒有作用，NOT_INSURABLE")
    check(alive(rentAll), "（對照）屋還在")
    boot({ econ = { revision = 4, caps = { entitlements = true, subscriptions = true, rentals = true, setPlan = true,
        freeze = true } } })
    T.sandbox("IdleInsure", true)
    seed("old", { rect(100, 100, 5, 5) }, 1)
    ok2, why2 = MSH.Idle.canInsure("old", 1, "rental")
    check(MSH.Economy.insureReady == false and ok2 == false and why2 == "INSURE_CLOSED",
        "Economy 不能一次付多期：保險產品沒註冊、canInsure 回 INSURE_CLOSED")
    MinidoracatEconomy = nil
end
