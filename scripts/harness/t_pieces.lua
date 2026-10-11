-- 多塊安全屋的伺服器行為（使用者 2026-10-11 裁定：一間最多 4 塊，每塊一個原生、共用 @MSH:<id>）：
-- 建立與規則、每一塊的在場／佔用／重疊、權限、收斂（缺一塊只補那塊、重複或對不上隔離）、放棄、
-- 撤銷順序、校正、名單容量、重新框選、改名、孤兒接回。
return function(T)
    local check = T.check
    local D1 = "MinidoracatSafehouse.Deed1"
    local RESTART = { keepGmd = true, keepFiles = true, keepHouses = true }
    local function r(x, y, w, h) return { x = x, y = y, w = w, h = h } end
    -- L 形：左邊直條＋底下往右的橫條（兩塊，凹處在右上）
    local function L(x, y) return { r(x, y, 4, 10), r(x + 4, y + 6, 8, 4) } end
    local function housesOf(owner)
        local out = {}
        for _, hs in ipairs(T.houses) do if hs.owner == owner then out[#out + 1] = hs end end
        return out
    end
    local function deeds(p) return p.inv:getAllTypeRecurse(D1):size() end
    local function checkOf(res, name)
        for _, c in ipairs(res.checks or {}) do if c.name == name then return c end end
        return nil
    end
    local function removes(id)
        local n = 0
        for _, a in ipairs(T.broadcastsOf("nativeRemove")) do if a.claimId == id then n = n + 1 end end
        return n
    end

    T.section("建立：L 形兩塊")
    local MSH = T.boot()
    local R, N = MSH.Registry, MSH.Native
    local alice = T.player({ name = "alice", x = 102, y = 102, items = { D1 } })
    local res = T.cmd(alice, "create", { rects = L(100, 100), deedType = D1, title = "L" })
    local hs = housesOf("@MSH:1")
    check(res.ok and #res.rects == 2 and #hs == 2 and deeds(alice) == 0, "建立成功：兩個原生、只扣一張地契")
    check(hs[1].players:contains("alice") and hs[2].players:contains("alice") and hs[1].title == "L" and hs[2].title == "L",
        "兩塊都有屋主名單與標題")
    local rec = R.get(1)
    check(#rec.rects == 2 and rec.rects[1].created == hs[1].created and rec.rects[2].created == hs[2].created
        and rec.rects[2].x == 104 and rec.rects[2].y == 106, "紀錄每塊都有自己原生的指紋")

    T.section("建立：伺服器照同一套形狀與大小規則")
    R.setOverride("alice", 10)
    local function rejects(rects, code, reason, label)
        alice.inv:AddItem(D1)
        local houses, nextId = #T.houses, R.md.nextClaimId
        local x = rects[1] and rects[1].x or 0
        alice.x, alice.y = x + 0.5, (rects[1] and rects[1].y or 0) + 0.5
        local out = T.cmd(alice, "create", { rects = rects, deedType = D1 })
        check(out ~= nil and out.code == code and (reason == nil or out.reason == reason) and #T.houses == houses
            and deeds(alice) == 1 and R.md.nextClaimId == nextId, label .. "（實際 " .. tostring(out and out.code)
            .. " " .. tostring(out and out.reason) .. "）")
        alice.inv:Remove(alice.inv:getFirstTypeRecurse(D1))
    end
    rejects({ r(200, 200, 4, 4), r(204, 204, 4, 4) }, "BAD_SHAPE", "SPLIT", "只碰到角：不建、不扣地契")
    rejects({ r(200, 200, 6, 6), r(204, 204, 4, 4) }, "BAD_SHAPE", "OVERLAP", "塊與塊重疊")
    rejects({ r(200, 200, 6, 2), r(200, 202, 2, 2), r(204, 202, 2, 2), r(200, 204, 6, 2) }, "BAD_SHAPE", "HOLE",
        "圍出洞")
    rejects({ r(200, 200, 1, 1), r(201, 200, 1, 1), r(202, 200, 1, 1), r(203, 200, 1, 1), r(204, 200, 1, 1) },
        "BAD_ARGS", nil, "5 塊：協定就擋")
    rejects({ r(200, 200, 60, 2), r(260, 200, 40, 2) }, "BAD_ARGS", nil, "外框超過 96：協定就擋")
    rejects({ r(200, 200, 14, 2), r(214, 200, 12, 2) }, "TOO_BIG", nil, "每塊都不大，外框寬 26 超過 1 級邊長 24")
    T.sandbox("Tier1Area", 100)
    rejects({ r(200, 200, 10, 10), r(210, 200, 2, 2) }, "TOO_BIG", nil, "面積看各塊總和：104 超過 100")
    T.sandbox("Tier1Area", 576)

    T.section("每一塊：在場、佔用、重疊")
    local function preview(rects)
        T.advance(600)   -- 預檢每人 500 ms 冷卻（Claims.lua cooldownMs）
        return T.cmd(alice, "preview", { rects = rects, deedType = D1 })
    end
    alice.x, alice.y = 210.5, 207.5   -- 只在第二塊裡
    res = preview(L(200, 200))
    check(res.ok and checkOf(res, "onsite").ok, "站在第二塊：在場")
    alice.x, alice.y = 210.5, 202.5   -- L 的凹處：外框內、兩塊都不含
    res = preview(L(200, 200))
    check(not checkOf(res, "onsite").ok and checkOf(res, "onsite").code == "NOT_ON_SITE", "站在凹處：不在場")
    alice.x, alice.y = 201.5, 201.5
    local bob = T.player({ name = "bob", x = 210.5, y = 207.5 })
    res = preview(L(200, 200))
    check(checkOf(res, "occupancy").code == "OCCUPIED", "別人站在第二塊：佔用")
    bob.x, bob.y = 210.5, 202.5
    res = preview(L(200, 200))
    check(checkOf(res, "occupancy").ok, "（對照）別人站在凹處：不算佔用")
    res = preview({ r(110, 108, 4, 4) })
    local ov = checkOf(res, "overlap")
    check(ov.code == "OVERLAP" and ov.x == 104 and ov.y == 106 and ov.w == 8,
        "壓到這間的第二塊：OVERLAP，標出那一塊")
    -- 四塊一模一樣的 96×96：形狀不合規則就不掃地圖（不然同一片地掃四次，預檢可以拿來放大伺服器的工作量）
    local reads = T.squareReads
    local big = r(300, 300, 96, 96)
    res = preview({ big, big, big, big })
    check(res.ok and checkOf(res, "size").code == "BAD_SHAPE" and checkOf(res, "roads") == nil
        and T.squareReads == reads, "形狀不合規則：預檢回 BAD_SHAPE、不逐格掃道路")

    T.section("細分權限：每一塊都算這間")
    check(MSH.Permissions.claimAt(110, 107) == rec and MSH.Permissions.claimAt(101, 101) == rec,
        "兩塊裡的格子都屬於這間")
    check(MSH.Permissions.claimAt(110, 102) == nil, "凹處不屬於這間")

    T.section("收斂：缺一塊只補那塊")
    local p1, p2 = hs[1], hs[2]
    N.remove(p2)
    T.advance(5000)
    T.tick(6)
    local now = housesOf("@MSH:1")
    local fresh = nil
    for _, h in ipairs(now) do if h ~= p1 then fresh = h end end
    check(#now == 2 and now[1] == p1 and fresh ~= nil and fresh.x == 104 and fresh.y == 106 and fresh.w == 8,
        "第二塊重建，第一塊還是原來那個原生")
    check(rec.lifecycle == "active" and rec.rects[2].created == fresh.created and fresh.created ~= p2.created
        and rec.rects[1].created == p1.created and fresh.players:contains("alice"), "只更新重建那塊的指紋，名單照紀錄")
    -- 原版 owner 封包改掉其中一塊的屋主：其他塊的標記還在，照樣要認出這塊、換回標記（不是當成缺塊去重建撞到自己）
    fresh:setOwner("thief")
    T.tick(6)
    check(fresh.owner == "@MSH:1" and rec.lifecycle == "active" and #housesOf("@MSH:1") == 2,
        "一塊的屋主被改：換回標記，這間照常 active")

    T.section("收斂：同一人在每一塊被補回，一輪只算一次干擾")
    local four = T.cmd(alice, "share", { claimId = 1, expectedRevision = rec.revision, targetUsername = "carol",
        bits = MSH.SHARE.MEMBER })
    check(four.ok, "（前置）分享給 carol")
    for _ = 1, 3 do
        for _, h in ipairs(housesOf("@MSH:1")) do h:removePlayer("carol") end
        T.advance(1000)
        T.tick(6)
    end
    local flags = MSH.Reconcile.claimFlags[1]
    check(housesOf("@MSH:1")[2].players:contains("carol") and not (flags and flags.interference),
        "三輪各被移掉一次：補回來，不算受干擾（每塊各算一次會變 6 次，超過 5）")

    T.section("收斂：同一塊兩個原生、對不上的原生都隔離")
    local MSH2 = T.boot()
    local R2 = MSH2.Registry
    local function seed(id, rects, grants)
        local rr = R2.newRecord({ claimId = id, rects = rects, title = "s" .. id, owner = "alice", source = MSH2.SOURCE.DEED,
            deedTier = 1, grants = grants or {}, createdAt = T.now })
        local built = MSH2.Native.build(rr, {})
        for i, h in ipairs(built) do rr.rects[i].created = h:getDatetimeCreated() end
        R2.put(rr)
        R2.raiseNextId(id)
        return rr, built
    end
    local dup = seed(1, L(300, 300))
    SafeHouse.addSafeHouse(300, 300, 4, 10, MSH2.marker(1)).created = dup.rects[1].created
    local odd = seed(2, L(400, 400))
    SafeHouse.addSafeHouse(430, 430, 3, 3, MSH2.marker(2))
    local blocked, bh = seed(3, L(500, 500))
    MSH2.Native.remove(bh[2])
    SafeHouse.addSafeHouse(506, 506, 2, 2, "stranger")
    T.tick(6)
    check(dup.lifecycle == "quarantined" and dup.quarantineReason == "DUPLICATE", "同一塊兩個原生：隔離 DUPLICATE")
    check(odd.lifecycle == "quarantined" and odd.quarantineReason == "MISMATCH", "標記原生對不上任何一塊：隔離 MISMATCH")
    check(blocked.lifecycle == "quarantined" and blocked.quarantineReason == "REBUILD_OVERLAP"
        and #housesOf(MSH2.marker(3)) == 1, "缺的那塊位置被別人佔了：隔離、不硬建")

    T.section("放棄：每塊都拆、一個 remove delta、tombstone 記兩塊")
    MSH = T.boot()
    R, N = MSH.Registry, MSH.Native
    alice = T.player({ name = "alice", x = 102, y = 102, items = { D1 } })
    res = T.cmd(alice, "create", { rects = L(100, 100), deedType = D1, title = "L" })
    rec = R.get(res.claimId)
    local created2 = rec.rects[2].created
    res = T.cmd(alice, "release", { claimId = rec.claimId, expectedRevision = rec.revision })
    local tomb = R.tomb(1)
    check(res.ok and #housesOf("@MSH:1") == 0 and removes(1) == 1, "兩塊都拆掉，只送一次 remove delta")
    check(tomb ~= nil and #tomb.rects == 2 and tomb.rects[2].created == created2 and tomb.rects[2].w == 8,
        "tombstone 記下兩塊的範圍與指紋")
    -- 舊存檔的同一代原生重現（例如放棄途中當機回滾）：開服時認出來移除
    SafeHouse.addSafeHouse(104, 106, 8, 4, "@MSH:1").created = created2
    T.boot(RESTART)
    check(#housesOf("@MSH:1") == 0, "重開：同一代的那塊原生被移除")

    T.section("撤銷：先把人從每一塊移掉才傳送")
    MSH = T.boot()
    R, N = MSH.Registry, MSH.Native
    alice = T.player({ name = "alice", x = 501, y = 501 })
    bob = T.player({ name = "bob", x = 503.5, y = 504.5 })
    -- 第二塊的落點 (501, 503) 在第一塊裡：被移出第二塊的人會落進第一塊
    local rr = R.newRecord({ claimId = R.allocId(), rects = { r(500, 500, 2, 6), r(502, 504, 4, 2) }, title = "k",
        owner = "alice", source = MSH.SOURCE.DEED, deedTier = 1, createdAt = T.now,
        grants = { { user = "bob", bits = MSH.SHARE.MEMBER } } })
    local kb = N.build(rr, {})
    for i, h in ipairs(kb) do rr.rects[i].created = h:getDatetimeCreated() end
    R.put(rr)
    T.tick(6)
    local stillListed = nil
    local origRevoke = N.revoke
    N.revoke = function(house, user)
        if stillListed == nil then
            stillListed = false
            for _, h in ipairs(kb) do if h.players:contains(user) then stillListed = true end end
        end
        return origRevoke(house, user)
    end
    res = T.cmd(alice, "unshare", { claimId = rr.claimId, expectedRevision = rr.revision, targetUsername = "bob" })
    N.revoke = origRevoke
    check(res.ok and stillListed == false, "第一次傳送前，bob 已不在任何一塊的名單")
    check(bob.x == 501 and bob.y == 503 and not kb[1].players:contains("bob") and not kb[2].players:contains("bob"),
        "bob 從第二塊被傳到 (501, 503)，落進第一塊也不在名單（下一次越界檢查會再傳出）")

    T.section("校正：客戶端少報一塊就補送整間")
    MSH = T.boot()
    R, N = MSH.Registry, MSH.Native
    alice = T.player({ name = "alice", x = 102, y = 102, items = { D1 } })
    res = T.cmd(alice, "create", { rects = L(100, 100), deedType = D1 })
    local syncs = #T.syncs
    T.cmd(alice, "calibrate", { houses = { { claimId = 1, x = 100, y = 100, w = 4, h = 10 } } })
    check(#T.syncs == syncs + 2, "只報第一塊：兩塊都重新廣播")
    T.advance(15000)
    syncs = #T.syncs
    T.cmd(alice, "calibrate", { houses = { { claimId = 1, x = 100, y = 100, w = 4, h = 10 },
        { claimId = 1, x = 104, y = 106, w = 8, h = 4 } } })
    check(#T.syncs == syncs, "兩塊都報了：不廣播")

    T.section("名單容量：每塊各算一份")
    MSH.LIMIT.NATIVE_NAMES = 3
    rec = R.get(1)
    res = T.cmd(alice, "share", { claimId = 1, expectedRevision = rec.revision, targetUsername = "bob",
        bits = MSH.SHARE.MEMBER })
    check(res.code == "ROSTER_FULL", "兩塊的屋：屋主 2 份＋新成員 2 份＝4，超過 3")
    MSH.LIMIT.NATIVE_NAMES = 4
    res = T.cmd(alice, "share", { claimId = 1, expectedRevision = rec.revision, targetUsername = "bob",
        bits = MSH.SHARE.MEMBER })
    check(res.ok and housesOf("@MSH:1")[2].players:contains("bob"), "（對照）上限 4：分享成功，兩塊都有 bob")
    MSH.LIMIT.NATIVE_NAMES = 4096

    T.section("改名與重新框選")
    rec = R.get(1)
    res = T.cmd(alice, "rename", { claimId = 1, title = "新名", expectedRevision = rec.revision })
    local named = housesOf("@MSH:1")
    check(res.ok and named[1].title == "新名" and named[2].title == "新名", "改名：每一塊的標題都改")
    rec = R.get(1)
    local U = { r(100, 100, 4, 10), r(104, 106, 4, 4), r(108, 100, 4, 10) }
    res = T.cmd(alice, "redraw", { claimId = 1, rects = U, expectedRevision = rec.revision })
    check(res.ok and res.replaced == 1 and #res.rects == 3 and #housesOf(MSH.marker(res.claimId)) == 3
        and #housesOf("@MSH:1") == 0 and removes(1) == 1, "兩塊重畫成 U 形三塊：新屋三個原生、舊屋全拆")
    check(R.get(res.claimId).grants[1].user == "bob" and housesOf(MSH.marker(res.claimId))[3].players:contains("bob"),
        "分享照搬到新屋的每一塊")

    T.section("重新框選：拆舊屋拆到一半失敗，舊屋補回來")
    MSH = T.boot()
    R, N = MSH.Registry, MSH.Native
    alice = T.player({ name = "alice", x = 102, y = 102, items = { D1 } })
    res = T.cmd(alice, "create", { rects = L(100, 100), deedType = D1 })
    rec = R.get(res.claimId)
    local oldHouses = housesOf("@MSH:1")
    local origRemove = N.remove
    N.remove = function(h)
        if h == oldHouses[2] then return false end   -- 第二塊拆不掉（第一塊已經拆了）
        return origRemove(h)
    end
    res = T.cmd(alice, "redraw", { claimId = 1, rects = { r(100, 100, 6, 10) }, expectedRevision = rec.revision })
    N.remove = origRemove
    local back = housesOf("@MSH:1")
    check(not res.ok and res.code == "RELEASE_FAILED" and #housesOf("@MSH:2") == 0, "重畫失敗、新屋拆掉")
    check(rec.lifecycle == "active" and #back == 2 and back[1] == oldHouses[2] and back[2].x == 100 and back[2].h == 10,
        "舊屋回 active：拆掉的第一塊補回來，沒拆掉的第二塊還是原來那個")

    T.section("孤兒接回：同標記的原生是同一間的各塊")
    MSH = T.boot({ beforeStart = function()
        SafeHouse.addSafeHouse(600, 600, 4, 10, "@MSH:7").players:add("alice")
        SafeHouse.addSafeHouse(604, 606, 8, 4, "@MSH:7").players:add("alice")
        SafeHouse.addSafeHouse(700, 700, 4, 4, "@MSH:8")
        SafeHouse.addSafeHouse(700, 700, 4, 4, "@MSH:8")
    end })
    R = MSH.Registry
    local orphan, twin = R.get(7), R.get(8)
    check(orphan ~= nil and orphan.lifecycle == "quarantined" and orphan.quarantineReason == "RECOVERED"
        and #orphan.rects == 2, "兩塊相連：RECOVERED，兩塊都記進紀錄")
    check(twin ~= nil and twin.quarantineReason == "RECOVERED_DUPLICATE", "同一塊兩個原生：RECOVERED_DUPLICATE")
    local admin = T.player({ name = "admin1", admin = true })
    res = T.cmd(admin, "adminRecover", { claimId = 7, action = "rebind", targetUsername = "alice" })
    check(res.ok and orphan.lifecycle == "active" and orphan.owner == "alice"
        and orphan.rects[2].created == housesOf("@MSH:7")[2].created, "管理員接回：轉 active，兩塊的指紋對上")
    res = T.cmd(admin, "adminRecover", { claimId = 8, action = "rebind", targetUsername = "alice" })
    check(res.code == "WRONG_LIFECYCLE" and res.reason == "NATIVE_MISMATCH" and twin.lifecycle == "quarantined",
        "重複的那間不能接回")

    T.section("舊存檔：schema 1 的單塊紀錄升級")
    local old = nil
    MSH = T.boot({ beforeStart = function()
        local md = ModData.getOrCreate("MinidoracatSafehouse")
        md.schemaVersion, md.protocolVersion, md.generation, md.nextClaimId, md.bootSeq = 1, 1, 3, 3, 1
        old = SafeHouse.addSafeHouse(800, 800, 6, 6, "@MSH:1")
        old.players:add("alice")
        md.claims = { [1] = { claimId = 1, revision = 2, lifecycle = "active", rect = r(800, 800, 6, 6), title = "old",
            deedTier = 1, owner = "alice", source = "deed", grants = {}, nativeCreatedAt = old.created, bootSeen = 1,
            createdAt = T.now } }
        md.tombs = { [2] = "900,900,5,5," .. tostring(T.now) .. ",1," .. tostring(T.now), [3] = "-1,-1,-1,-1,-1,1,5" }
    end })
    R = MSH.Registry
    rec = R.get(1)
    check(R.md.schemaVersion == 2 and rec ~= nil and rec.lifecycle == "active" and rec.rect == nil and #rec.rects == 1
        and rec.rects[1].x == 800 and rec.rects[1].created == old.created, "紀錄的範圍與指紋變成第一塊，照常 active")
    check(#housesOf("@MSH:1") == 1 and housesOf("@MSH:1")[1] == old, "原本的原生認得出來，不重建、不隔離")
    local t2, t3 = R.tomb(2), R.tomb(3)
    check(t2 ~= nil and t2.rects[1].x == 900 and t2.rects[1].created == T.now and t2.bootSeen == 1
        and t3 ~= nil and t3.rects == nil and t3.releasedAt == 5, "舊 tombstone 換成新格式（沒有範圍的只留時間）")
end
