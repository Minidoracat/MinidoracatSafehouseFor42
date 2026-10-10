-- Claims：建立、預檢、放棄、重新框選、改名、清單與詳細（計畫 §7.1-§7.6、§6.4、§10.3、§12.1 第 1、4、6、9、14、18、27、30、32 項）。
return function(T)
    local check = T.check
    local D1, D2, D3, D4 = "MinidoracatSafehouse.Deed1", "MinidoracatSafehouse.Deed2",
        "MinidoracatSafehouse.Deed3", "MinidoracatSafehouse.Deed4"
    local MSH, R

    local function boot(opts)
        MSH = T.boot(opts)
        R = MSH.Registry
        return MSH
    end
    local function rect(x, y, w, h) return { x = x, y = y, w = w, h = h } end
    local function deeds(p, t) return p.inv:getAllTypeRecurse(t):size() end
    local function recCount() return #R.list() end
    -- 直接放一筆紀錄（＋原生），不經指令
    local function seed(owner, r, f)
        f = f or {}
        local id = R.allocId()
        local rec = R.newRecord({ claimId = id, rect = r, title = f.title or "t", owner = owner,
            source = f.source or MSH.SOURCE.DEED, deedTier = f.tier or 1, createdAt = f.createdAt or T.now,
            grants = f.grants })
        if f.lifecycle then rec.lifecycle = f.lifecycle end
        if not f.noNative then
            local hs = MSH.Native.build(rec)
            rec.nativeCreatedAt = hs:getDatetimeCreated()
        end
        R.put(rec)
        return rec
    end
    -- 塞滿 tombstone 軟上限（released 只留在 md.tombs）
    local function fillTombs(y)
        for i = 1, MSH.LIMIT.TOMBSTONE_SOFT do
            R.markReleased(seed("u" .. i, rect(i * 6, y, 5, 5), { noNative = true }), "RELEASED", T.now)
        end
    end
    -- 被拒的建立：結果碼相符，而且原生、紀錄、地契、物品同步、nextClaimId 都沒變
    local function rejects(p, args, code, label, deedType)
        local houses, recs, syncs, nextId = #T.houses, recCount(), #T.itemSyncs, R.md.nextClaimId
        local before = deedType and deeds(p, deedType)
        local res = T.cmd(p, "create", args)
        local same = #T.houses == houses and recCount() == recs and #T.itemSyncs == syncs and R.md.nextClaimId == nextId
            and (deedType == nil or deeds(p, deedType) == before)
        check(res ~= nil and res.code == code and same, label .. "（實際 " .. tostring(res and res.code) .. "）")
        return res
    end

    T.section("建立：地契模式 happy path、replay、巢狀背包")
    boot()
    local alice = T.player({ name = "alice", x = 105, y = 105, items = { D1 } })
    local lockedAt = {}
    local origBroadcast = MSH.Native.broadcast
    MSH.Native.broadcast = function(h)
        lockedAt[#lockedAt + 1] = MSH.Srv.locked
        return origBroadcast(h)
    end
    local origSendRemove = sendRemoveItemFromContainer
    sendRemoveItemFromContainer = function(c, item)
        lockedAt[#lockedAt + 1] = MSH.Srv.locked
        return origSendRemove(c, item)
    end
    local res = T.cmd(alice, "create", { rect = rect(100, 100, 10, 10), deedType = D1, title = " 我的家 " }, "create-0001")
    sendRemoveItemFromContainer = origSendRemove
    MSH.Native.broadcast = origBroadcast
    check(res.ok and res.claimId == 1 and res.revision == 1 and res.deedTier == 1 and res.title == "我的家",
        "地契建立成功、標題清理")
    check(deeds(alice, D1) == 0, "地契已扣除")
    check(#T.itemSyncs == 1 and T.itemSyncs[1].op == "remove" and T.itemSyncs[1].container == alice.inv,
        "物品移除有同步給客戶端（用移除前的容器）")
    local hs = T.houseOf("@MSH:1")
    check(hs ~= nil and hs.players:contains("alice") and hs.title == "我的家", "原生 owner＝@MSH:1、屋主在名單、標題")
    local rec = R.get(1)
    check(rec.owner == "alice" and rec.source == "deed" and rec.deedTier == 1 and rec.lifecycle == "active"
        and rec.createdAt == T.now and rec.nativeCreatedAt == hs.created and rec.revision == 1, "紀錄欄位")
    check(#T.syncs == 1 and #lockedAt == 2 and lockedAt[1] == false and lockedAt[2] == false,
        "原生廣播與物品同步都在放鎖之後才送")
    alice.inv:AddItem(D1)
    res = T.cmd(alice, "create", { rect = rect(100, 100, 10, 10), deedType = D1, title = " 我的家 " }, "create-0001")
    check(res.ok and res.replay and res.claimId == 1 and deeds(alice, D1) == 1 and #T.houses == 1 and recCount() == 1,
        "同 requestId 重送：回原結果、不再扣第二張地契")
    R.setOverride("alice", 5)
    rejects(alice, { rect = rect(101, 101, 10, 10), deedType = D1 }, "OVERLAP", "第二個重疊的建立被拒、只扣了一張", D1)

    boot({ sandbox = { ClaimsPerPlayer = 3 } })
    local bob = T.player({ name = "bob", x = 210, y = 210 })
    local bag = T.bag()
    bag.inner:AddItem(D2)
    bob.inv:AddItem(bag)
    res = T.cmd(bob, "create", { rect = rect(200, 200, 30, 30), deedType = D2 })
    check(res.ok and res.deedTier == 2 and R.get(res.claimId).title == "bob", "巢狀背包裡的 2 級地契；沒給標題用屋主名")
    check(deeds(bob, D2) == 0 and T.itemSyncs[1].container == bag.inner, "從背包內的容器移除並同步")

    T.section("建立：免費模式")
    boot({ sandbox = { CreateMode = 2 } })
    local carol = T.player({ name = "carol", x = 305, y = 305, items = { D1 } })
    rejects(carol, { rect = rect(300, 300, 10, 10), deedType = D1 }, "BAD_DEED", "免費模式帶地契：BAD_DEED", D1)
    local big = rejects(carol, { rect = rect(300, 300, 25, 10) }, "TOO_BIG", "免費模式超過免費上限")
    check(big.maxSide == 24 and big.maxArea == 576, "TOO_BIG 帶上限")
    res = T.cmd(carol, "create", { rect = rect(300, 300, 10, 10) })
    check(res.ok and R.get(res.claimId).source == "free" and res.deedTier == 1 and deeds(carol, D1) == 1
        and #T.itemSyncs == 0, "免費模式建立：source free、不碰地契")
    carol.x = 335
    rejects(carol, { rect = rect(330, 300, 10, 10) }, "QUOTA_FULL", "免費模式名額以 tier1 計")

    T.section("建立：逐項拒絕（原生、紀錄、地契都不變）")
    boot()
    local p = T.player({ name = "dave", x = 1005, y = 1005, items = { D1, D4 } })
    local good = rect(1000, 1000, 10, 10)
    p.dead = true
    rejects(p, { rect = good, deedType = D1 }, "DEAD", "死亡", D1)
    p.dead = false
    T.serverOptions.SafehouseDaySurvivedToClaim = "7"
    p.hours = 10
    rejects(p, { rect = good, deedType = D1 }, "NOT_SURVIVED", "存活天數不足（原生 hasNotSurvivedEnoughToClaim）", D1)
    T.serverOptions.SafehouseDaySurvivedToClaim = "0"
    rejects(p, { rect = rect(1020, 1000, 10, 10), deedType = D1 }, "NOT_ON_SITE", "人不在範圍內", D1)
    p.x, p.y = 1010, 1005
    rejects(p, { rect = good, deedType = D1 }, "NOT_ON_SITE", "半開：站在右邊界外一格不算在場", D1)
    p.x, p.y = 1005.7, 1009.9
    rejects(p, { rect = good }, "NO_DEED", "地契模式沒帶地契", D1)
    rejects(p, { rect = good, deedType = D2 }, "NO_DEED", "背包裡沒有這種地契", D1)
    rejects(p, { rect = good, deedType = D4 }, "TIER_DISABLED", "未啟用的等級", D4)
    local tb = rejects(p, { rect = rect(1000, 1000, 25, 10), deedType = D1 }, "TOO_BIG", "超過 1 級邊長", D1)
    check(tb.maxSide == 24 and tb.maxArea == 576, "TOO_BIG 帶該級上限")
    T.sandbox("Tier1Area", 50)
    rejects(p, { rect = good, deedType = D1 }, "TOO_BIG", "超過 1 級面積", D1)
    T.sandbox("Tier1Area", 576)
    SafeHouse.addSafeHouse(1000, 1000, 2, 2, "stranger")
    rejects(p, { rect = good, deedType = D1 }, "ONLINE_ID_COLLISION", "和 foreign 原生同 onlineId", D1)
    T.houses = {}
    rejects(p, { rect = good, deedType = D1, title = "a[b]" }, "BAD_TITLE", "標題含 []", D1)
    rejects(p, { rect = good, deedType = D1, title = "   " }, "BAD_TITLE", "空白標題", D1)
    local eve = T.player({ name = "eve", x = 1002, y = 1002, z = 1 })
    local occ = rejects(p, { rect = good, deedType = D1 }, "OCCUPIED", "別人站在範圍內（任何 Z）", D1)
    check(occ.name == nil and occ.user == nil, "OCCUPIED 不帶名字")
    eve.x = 999
    MSH.LIMIT.REGISTRY_BYTES, MSH.LIMIT.NATIVE_NAMES = 10, 4096
    rejects(p, { rect = good, deedType = D1 }, "REGISTRY_FULL", "registry 大小上限", D1)
    MSH.LIMIT.REGISTRY_BYTES, MSH.LIMIT.NATIVE_NAMES = 256 * 1024, 0
    rejects(p, { rect = good, deedType = D1 }, "ROSTER_FULL", "原生名單名字總數上限", D1)
    MSH.LIMIT.NATIVE_NAMES = 4096
    T.steam, T.failWrites = true, true
    local br = rejects(p, { rect = good, deedType = D1 }, "BIND_REFUSED", "Steam 模式綁定寫不進去：拒絕建立", D1)
    check(br.reason == "WRITE_FAILED", "BIND_REFUSED 帶原因")
    T.steam, T.failWrites = false, false

    -- Exclusions 結果碼原樣帶回（測試暫時覆寫）
    if MSH.Exclusions == nil then
        MSH.Exclusions = { roads = function() return nil end, resources = function() return nil end,
            status = function() return { resourceApi = false } end }
    end
    local E = MSH.Exclusions
    local origRoads, origRes = E.roads, E.resources
    E.roads = function() return "ROAD", { x = 1003, y = 1004, kind = "main" } end
    local rd = rejects(p, { rect = good, deedType = D1 }, "ROAD", "道路結果碼原樣帶回", D1)
    check(rd.x == 1003 and rd.y == 1004 and rd.kind == "main", "ROAD 帶格子與類別")
    E.roads = origRoads
    E.resources = function() return "RESOURCE_PENDING" end
    rejects(p, { rect = good, deedType = D1 }, "RESOURCE_PENDING", "資源點結果碼原樣帶回", D1)
    E.resources = origRes

    T.serverOptions.War = "true"
    T.tick(6)
    rejects(p, { rect = good, deedType = D1 }, "HEALTH_BLOCKED", "health blocked 時不能建立", D1)
    T.serverOptions.War = "false"
    T.tick(6)

    T.section("建立：交易失敗與反序回滾")
    T.noLocation = true
    local nextId = R.md.nextClaimId
    res = T.cmd(p, "create", { rect = good, deedType = D1 })
    check(res.code == "NATIVE_FAILED" and #T.houses == 0 and recCount() == 0 and deeds(p, D1) == 1
        and R.md.nextClaimId == nextId + 1, "location 推不出來：NATIVE_FAILED、地契保留、claimId 用掉")
    T.noLocation = false
    T.failRemove = true
    nextId = R.md.nextClaimId
    res = T.cmd(p, "create", { rect = good, deedType = D1 })
    check(res.code == "DEED_REMOVE_FAILED" and #T.houses == 0 and recCount() == 0 and deeds(p, D1) == 1
        and #T.itemSyncs == 0 and R.md.nextClaimId == nextId + 1 and #T.syncs == 0,
        "Remove 靜默失手：DEED_REMOVE_FAILED、原生已移除、claimId 用掉、不送同步")
    T.failRemove = false
    local origPut = R.put
    R.put = function() error("put boom") end
    res = T.cmd(p, "create", { rect = good, deedType = D1 })
    R.put = origPut
    check(res.code == "INTERNAL_ERROR" and #T.houses == 0 and recCount() == 0 and deeds(p, D1) == 1
        and p.inv:getFirstTypeRecurse(D1):getContainer() == p.inv and #T.itemSyncs == 0 and #T.syncs == 0
        and MSH.Srv.locked == false, "寫紀錄丟錯：反序回滾（原生移除、地契放回、不送網路）")
    check(T.logged("CREATE_ROLLBACK"), "回滾寫 audit")
    res = T.cmd(p, "create", { rect = good, deedType = D1 })
    check(res.ok and deeds(p, D1) == 0, "回滾後同一張地契可以正常建立")

    T.section("名額：免費位照 createdAt、TierNFree、每級上限、全服上限")
    boot({ sandbox = { ClaimsPerPlayer = 2, Tier1Free = false } })
    local fay = T.player({ name = "fay", x = 2005, y = 2005, items = { D1, D2, D2, D3 } })
    local older = seed("fay", rect(2100, 2100, 5, 5), { tier = 1, createdAt = T.now - 5000 })
    local newer = seed("fay", rect(2200, 2200, 5, 5), { tier = 2, createdAt = T.now - 1000 })
    local s = MSH.Claims.slots("fay", MSH.Settings.get())
    check(s.used == 1 and s.ids[newer.claimId] and not s.ids[older.claimId], "Tier1Free 關：1 級不佔免費位、2 級補上")
    rejects(fay, { rect = rect(2000, 2000, 10, 10), deedType = D1 }, "QUOTA_FULL", "1 級不能用免費位（沒有付費名額）", D1)
    res = T.cmd(fay, "create", { rect = rect(2000, 2000, 10, 10), deedType = D2 })
    check(res.ok, "2 級用第二個免費位")
    fay.x = 2305
    fay.y = 2305
    local q = rejects(fay, { rect = rect(2300, 2300, 10, 10), deedType = D3 }, "QUOTA_FULL", "免費位用完", D3)
    check(q.tier == 3 and q.buy == nil and q.rent == nil, "QUOTA_FULL 帶等級、沒有付費選項")
    R.setOverride("fay", 3)
    res = T.cmd(fay, "create", { rect = rect(2300, 2300, 10, 10), deedType = D3 })
    check(res.ok, "個人覆寫上限 3：可以再建")
    boot({ sandbox = { ClaimsPerPlayer = 2 } })
    seed("gus", rect(2400, 2400, 5, 5), { source = MSH.SOURCE.LEGACY, createdAt = T.now })
    seed("gus", rect(2500, 2500, 5, 5), { source = MSH.SOURCE.LEGACY, createdAt = T.now })
    local gus = T.player({ name = "gus", x = 2605, y = 2605, items = { D1 } })
    s = MSH.Claims.slots("gus", MSH.Settings.get())
    check(s.used == 2, "legacy 先佔免費位")
    rejects(gus, { rect = rect(2600, 2600, 10, 10), deedType = D1 }, "QUOTA_FULL", "legacy 佔滿後新建要付費名額", D1)
    boot({ sandbox = { ClaimsPerPlayer = 5, Tier1PerPlayer = 1 } })
    seed("hal", rect(2700, 2700, 5, 5), { tier = 1 })
    local hal = T.player({ name = "hal", x = 2805, y = 2805, items = { D1, D2 } })
    local tf = rejects(hal, { rect = rect(2800, 2800, 10, 10), deedType = D1 }, "TIER_FULL", "1 級每人上限 1", D1)
    check(tf.tier == 1 and tf.limit == 1, "TIER_FULL 帶等級與上限")
    res = T.cmd(hal, "create", { rect = rect(2800, 2800, 10, 10), deedType = D2 })
    check(res.ok, "別的等級不受影響")
    boot()
    for i = 1, MSH.LIMIT.MAX_CLAIMS do
        seed("u" .. i, rect(i * 20, 5000, 5, 5), { noNative = true })
    end
    local ivy = T.player({ name = "ivy", x = 9005, y = 9005, items = { D1 } })
    rejects(ivy, { rect = rect(9000, 9000, 10, 10), deedType = D1 }, "SERVER_FULL", "全服 256 間", D1)
    boot()
    fillTombs(6000)
    check(R.tombstoneCount() == MSH.LIMIT.TOMBSTONE_SOFT and recCount() == 0, "released 搬到 md.tombs、不留在 claims")
    ivy = T.player({ name = "ivy", x = 9005, y = 9005, items = { D1 } })
    rejects(ivy, { rect = rect(9000, 9000, 10, 10), deedType = D1 }, "SERVER_FULL", "tombstone 到軟上限", D1)

    T.section("重疊與間距")
    boot({ sandbox = { ClaimsPerPlayer = 5 } })
    local jo = T.player({ name = "jo", x = 3005, y = 3002, items = { D1, D1, D1, D1, D1 } })
    SafeHouse.addSafeHouse(3010, 3000, 10, 10, "stranger")
    local ov = rejects(jo, { rect = rect(3000, 3000, 11, 10), deedType = D1 }, "OVERLAP", "和 foreign 原生重疊", D1)
    check(ov.x == 3010 and ov.w == 10, "OVERLAP 帶衝突範圍")
    rejects(jo, { rect = rect(3000, 3000, 9, 10), deedType = D1 }, "TOO_CLOSE", "foreign 也套 claimGap", D1)
    seed("kim", rect(3100, 3000, 10, 10))
    jo.x = 3111
    rejects(jo, { rect = rect(3111, 3000, 5, 5), deedType = D1 }, "TOO_CLOSE", "別的屋主：差 1 格太近", D1)
    jo.x = 3112
    res = T.cmd(jo, "create", { rect = rect(3112, 3000, 5, 5), deedType = D1 })
    check(res.ok, "別的屋主：差 2 格可以")
    jo.x = 3117
    res = T.cmd(jo, "create", { rect = rect(3117, 3000, 5, 5), deedType = D1 })
    check(res.ok, "同一屋主緊鄰可以（不套間距）")
    jo.x = 3121
    rejects(jo, { rect = rect(3121, 3000, 5, 5), deedType = D1 }, "OVERLAP", "同一屋主重疊不行", D1)
    local lapsed = seed("kim", rect(3200, 3000, 10, 10), { lifecycle = "lapsed", noNative = true })
    jo.x = 3205
    rejects(jo, { rect = rect(3205, 3000, 10, 10), deedType = D1 }, "OVERLAP", "lapsed 紀錄照樣佔位", D1)
    jo.x = 3211
    rejects(jo, { rect = rect(3211, 3000, 5, 5), deedType = D1 }, "TOO_CLOSE", "lapsed 紀錄也套間距", D1)
    lapsed.lifecycle = "quarantined"
    jo.x = 3205
    rejects(jo, { rect = rect(3205, 3000, 10, 10), deedType = D1 }, "OVERLAP", "quarantined 紀錄照樣佔位", D1)
    local intersects = SafeHouse.intersects
    SafeHouse.intersects = function() error("不得呼叫原生 intersects") end
    jo.x = 3405
    res = T.cmd(jo, "create", { rect = rect(3400, 3000, 10, 10), deedType = D1 })
    SafeHouse.intersects = intersects
    check(res.ok, "整個建立流程不呼叫原生 intersects")

    T.section("間距 0 與 16（走建立指令）")
    boot({ sandbox = { ClaimGap = 0 } })
    seed("kim", rect(3100, 3000, 10, 10))
    local gp = T.player({ name = "gp", x = 3112, y = 3002, items = { D1 } })
    res = T.cmd(gp, "create", { rect = rect(3110, 3000, 5, 5), deedType = D1 })
    check(res.ok, "ClaimGap 0：別的屋主緊鄰可以")
    boot({ sandbox = { ClaimGap = 16 } })
    seed("kim", rect(3100, 3000, 10, 10))
    gp = T.player({ name = "gp", x = 3127, y = 3002, items = { D1 } })
    rejects(gp, { rect = rect(3125, 3000, 5, 5), deedType = D1 }, "TOO_CLOSE", "ClaimGap 16：差 15 格太近", D1)
    res = T.cmd(gp, "create", { rect = rect(3126, 3000, 5, 5), deedType = D1 })
    check(res.ok, "ClaimGap 16：差 16 格可以")

    T.section("malformed 紀錄不擋建立、清單、詳細")
    boot()
    R.md.claims[50] = { claimId = 50, lifecycle = "active", owner = "uma" }   -- 缺 rect 等欄位
    R.raiseNextId(50)
    boot({ keepGmd = true, keepFiles = true })
    local mal = R.get(50)
    check(mal ~= nil and mal.malformed and mal.lifecycle == "quarantined" and mal.owner == "uma",
        "重開後轉 malformed quarantined")
    local uma = T.player({ name = "uma", x = 3505, y = 3505, items = { D1 } })
    res = T.cmd(uma, "preview", { rect = rect(3500, 3500, 10, 10), deedType = D1 })
    check(res ~= nil and res.ok and res.pass, "malformed 在時預檢照常")
    res = T.cmd(uma, "create", { rect = rect(3500, 3500, 10, 10), deedType = D1 })
    check(res.ok, "malformed 在時建立照常（實際 " .. tostring(res.code) .. "）")
    res = T.cmd(uma, "list", {})
    check(res.ok and #res.claims == 1 and res.claims[1].claimId ~= 50, "清單不列 malformed")
    res = T.cmd(uma, "detail", { claimId = 50 })
    check(res.code == "NOT_FOUND", "malformed 的詳細：NOT_FOUND（實際 " .. tostring(res.code) .. "）")
    res = T.cmd(uma, "redraw", { claimId = 50, rect = rect(3500, 3500, 10, 10), expectedRevision = mal.revision })
    check(res.code == "REDRAW_CLOSED", "malformed 不能重畫")

    T.section("協定層：超大與無限 rect")
    boot()
    local wy = T.player({ name = "wy", x = 3705, y = 3705, items = { D1 } })
    local hard = MSH.LIMIT.HARD_SIDE
    rejects(wy, { rect = rect(3700, 3700, hard + 1, 10), deedType = D1 }, "BAD_ARGS", "邊長超過 HARD_SIDE：BAD_ARGS", D1)
    -- 防線壞掉時預檢會帶著超大 rect 去掃地圖：先換成只記錄的假 Exclusions，讓測試失敗而不是卡死
    local E0, scanned = MSH.Exclusions, false
    MSH.Exclusions = { roads = function() scanned = true end, resources = function() scanned = true end }
    res = T.cmd(wy, "preview", { rect = rect(3701, 3701, 900000, 900000) })
    MSH.Exclusions = E0
    check(res ~= nil and res.code == "BAD_ARGS" and not scanned, "超大 rect 的預檢：BAD_ARGS（不跑地圖掃描）")
    rejects(wy, { rect = rect(3700, 3700, math.huge, 10), deedType = D1 }, "BAD_ARGS", "+Infinity：BAD_ARGS", D1)
    rejects(wy, { rect = rect(-math.huge, 3700, 10, 10), deedType = D1 }, "BAD_ARGS", "-Infinity：BAD_ARGS", D1)

    T.section("綁定與個人上限不在 Global ModData（§12.1 #14／#18）")
    boot({ steam = true })
    local wes = T.player({ name = "wes", x = 3805, y = 3805, sid = 76561198000000123, items = { D1 } })
    res = T.cmd(wes, "create", { rect = rect(3800, 3800, 10, 10), deedType = D1 })
    R.setOverride("wes", 4)
    check(res.ok and R.binding("wes") ~= nil and R.override("wes") == 4, "綁定與覆寫已寫入")
    local sidText, leaks = R.sidText(wes.sid), {}
    local function scan(t, path)
        for k, v in pairs(t) do
            local at = path .. "." .. tostring(k)
            if k == "bindings" or k == "overrides" or v == wes.sid
                or (type(v) == "string" and string.find(v, sidText, 1, true)) then
                leaks[#leaks + 1] = at
            end
            if type(v) == "table" then scan(v, at) end
        end
    end
    scan(T.gmd, "gmd")
    check(#leaks == 0, "Global ModData 沒有 bindings、overrides、Steam ID（" .. table.concat(leaks, " ") .. "）")

    T.section("預檢：一次回報多項、不寫入")
    boot()
    T.steam = true
    local kai = T.player({ name = "kai", x = 0, y = 0, items = { D1 } })
    SafeHouse.addSafeHouse(4000, 4000, 5, 5, "stranger")
    local houses, syncs = #T.houses, #T.syncs
    res = T.cmd(kai, "preview", { rect = rect(4000, 4000, 50, 10), deedType = D2 })
    local byName = {}
    for _, c in ipairs(res.checks) do byName[c.name] = c end
    check(res.ok and res.pass == false, "預檢失敗但指令本身成功")
    check(byName.onsite.code == "NOT_ON_SITE" and byName.deed.code == "NO_DEED" and byName.size.code == "TOO_BIG"
        and byName.overlap.code == "ONLINE_ID_COLLISION" and byName.size.maxSide == 40, "同時回報不在場、沒地契、太大、撞號")
    check(byName.identity.ok and byName.quota.ok and byName.title.ok and byName.occupancy.ok and byName.roads.ok
        and byName.resources.ok, "其他檢查通過")
    check(#T.houses == houses and #T.syncs == syncs and recCount() == 0 and deeds(kai, D1) == 1
        and R.binding("kai") == nil, "預檢不建原生、不扣地契、不寫綁定")
    res = T.cmd(kai, "preview", { rect = rect(4000, 4000, 50, 10), deedType = D2 })
    check(res == nil, "預檢 500 ms 內重送：丟掉、不回覆")
    T.advance(500)
    kai.x, kai.y = 4105, 4105
    res = T.cmd(kai, "preview", { rect = rect(4100, 4100, 10, 10), deedType = D1 })
    check(res ~= nil and res.ok and res.pass == true and #res.checks == 10, "全部通過：10 組檢查")

    T.section("放棄")
    boot({ sandbox = { ClaimsPerPlayer = 5 } })
    local lou = T.player({ name = "lou", x = 5005, y = 5005, items = { D1, D1, D1 } })
    local mia = T.player({ name = "mia", x = 0, y = 0 })
    res = T.cmd(lou, "create", { rect = rect(5000, 5000, 10, 10), deedType = D1 })
    local id1 = res.claimId
    res = T.cmd(mia, "release", { claimId = id1, expectedRevision = 1 })
    check(res.code == "NOT_OWNER" and R.get(id1).lifecycle == "active", "不是屋主不能放棄")
    res = T.cmd(lou, "release", { claimId = id1, expectedRevision = 0 })
    check(res.code == "STALE_REVISION" and R.get(id1).lifecycle == "active", "revision 過期")
    res = T.cmd(lou, "release", { claimId = id1, expectedRevision = 1 })
    local tomb = R.tomb(id1)
    check(res.ok and R.get(id1) == nil and tomb ~= nil and tomb.rect.x == 5000 and tomb.releasedAt == T.now
        and T.houseOf("@MSH:" .. id1) == nil, "放棄：原生移除、紀錄換成 tombstone")
    check(#T.broadcastsOf("nativeRemove") == 1 and deeds(lou, D1) == 2, "remove delta 已送；地契不退")
    res = T.cmd(lou, "release", { claimId = id1, expectedRevision = 3 })
    check(res.code == "NOT_FOUND", "released 的不能再放棄")
    lou.x = 5105
    res = T.cmd(lou, "create", { rect = rect(5100, 5000, 10, 10), deedType = D1 })
    local id2 = res.claimId
    T.failHouseRemove = true
    res = T.cmd(lou, "release", { claimId = id2, expectedRevision = 1 })
    T.failHouseRemove = false
    check(res.code == "RELEASE_FAILED" and R.get(id2).lifecycle == "quarantined", "原生移除失敗：quarantined、不假成功")
    res = T.cmd(lou, "release", { claimId = id2, expectedRevision = R.get(id2).revision })
    check(res.code == "WRONG_LIFECYCLE", "quarantined 不能再放棄")
    lou.x = 5205
    res = T.cmd(lou, "create", { rect = rect(5200, 5000, 10, 10), deedType = D1 })
    local id3 = res.claimId
    T.serverOptions.War = "true"
    T.tick(6)
    res = T.cmd(lou, "release", { claimId = id3, expectedRevision = 1 })
    check(res.ok, "health blocked 時照樣能放棄")
    T.serverOptions.War = "false"
    T.tick(6)

    T.section("放棄免費那間：下一間最舊的補上免費位（§12.1 #27）")
    boot({ sandbox = { ClaimsPerPlayer = 1 } })
    local first = seed("vic", rect(2900, 2900, 5, 5), { createdAt = T.now - 5000 })
    local second = seed("vic", rect(2910, 2900, 5, 5), { createdAt = T.now - 1000 })
    s = MSH.Claims.slots("vic", MSH.Settings.get())
    check(s.used == 1 and s.ids[first.claimId] and not s.ids[second.claimId], "免費位給最舊的")
    local vic = T.player({ name = "vic", x = 2902, y = 2902 })
    res = T.cmd(vic, "release", { claimId = first.claimId, expectedRevision = first.revision })
    s = MSH.Claims.slots("vic", MSH.Settings.get())
    check(res.ok and s.used == 1 and s.ids[second.claimId] and not s.ids[first.claimId], "放棄後下一間補上免費位")

    T.section("重新框選")
    boot({ sandbox = { ClaimsPerPlayer = 5 } })
    local ned = T.player({ name = "ned", x = 6005, y = 6005, items = { D2, D1 } })
    local ole = T.player({ name = "ole", x = 0, y = 0 })
    res = T.cmd(ned, "create", { rect = rect(6000, 6000, 10, 10), deedType = D2, title = "老家" })
    local old = R.get(res.claimId)
    old.grants = { { user = "ole", bits = 3 } }
    R.touch(old)
    local createdAt = old.createdAt
    ole.x, ole.y = 6011, 6011
    T.advance(60000)
    local before = deeds(ned, D2) + deeds(ned, D1)
    res = T.cmd(ned, "redraw", { claimId = old.claimId, rect = rect(6002, 6002, 12, 12), expectedRevision = 0 })
    check(res.code == "STALE_REVISION", "重新框選要對 revision")
    SafeHouse.addSafeHouse(6013, 6013, 3, 3, "stranger")
    res = T.cmd(ned, "redraw", { claimId = old.claimId, rect = rect(6002, 6002, 12, 12), expectedRevision = old.revision })
    check(res.code == "OVERLAP" and old.lifecycle == "active" and T.houseOf("@MSH:" .. old.claimId) ~= nil
        and old.revision == 2, "新範圍驗證失敗：舊屋原封不動")
    T.houses[#T.houses] = nil
    local syncs0, removes0 = #T.syncs, #T.broadcastsOf("nativeRemove")
    res = T.cmd(ned, "redraw", { claimId = old.claimId, rect = rect(6002, 6002, 12, 12), expectedRevision = old.revision })
    local new = res.ok and R.get(res.claimId)
    check(res.ok and res.replaced == old.claimId and new and new.claimId ~= old.claimId,
        "緩衝期內重畫成功（新範圍可與舊範圍重疊；舊屋成員站在新範圍內不算佔用）")
    check(old.lifecycle == "released" and old.releaseReason == "REDRAWN" and R.get(old.claimId) == nil
        and R.tomb(old.claimId) ~= nil and T.houseOf("@MSH:" .. old.claimId) == nil, "舊屋 tombstone、原生移除")
    check(new.redraws == 1, "新紀錄帶重畫次數 1")
    check(new.createdAt == createdAt and new.title == "老家" and new.source == "deed" and new.deedTier == 2
        and #new.grants == 1 and new.grants[1].user == "ole" and new.grants ~= old.grants, "新屋沿用 createdAt、標題、等級、分享")
    local nhs = T.houseOf("@MSH:" .. new.claimId)
    check(nhs and nhs.players:contains("ned") and nhs.players:contains("ole") and nhs.x == 6002,
        "新原生帶屋主與成員")
    check(deeds(ned, D2) + deeds(ned, D1) == before and #T.itemSyncs == 1, "地契數不變、沒有新的物品同步")
    check(#T.syncs == syncs0 + 1 and #T.broadcastsOf("nativeRemove") == removes0 + 1, "新屋廣播＋舊屋 remove delta")
    T.advance(29 * 60000 - 5000)
    res = T.cmd(ned, "redraw", { claimId = new.claimId, rect = rect(6000, 6000, 12, 12), expectedRevision = new.revision })
    check(res.ok, "重畫不延長緩衝期：仍在原本的 30 分內")
    local third = R.get(res.claimId)
    T.advance(60000)
    res = T.cmd(ned, "redraw", { claimId = third.claimId, rect = rect(6001, 6001, 12, 12), expectedRevision = third.revision })
    check(res.code == "REDRAW_CLOSED" and third.lifecycle == "active", "超過 RedrawMinutes：REDRAW_CLOSED")
    boot({ sandbox = { ClaimsPerPlayer = 5, RedrawMinutes = 0 } })
    ned = T.player({ name = "ned", x = 6005, y = 6005, items = { D1 } })
    res = T.cmd(ned, "create", { rect = rect(6000, 6000, 10, 10), deedType = D1 })
    res = T.cmd(ned, "redraw", { claimId = res.claimId, rect = rect(6001, 6001, 10, 10), expectedRevision = 1 })
    check(res.code == "REDRAW_CLOSED", "RedrawMinutes=0：不開放")
    boot({ sandbox = { ClaimsPerPlayer = 5 } })
    ned = T.player({ name = "ned", x = 6005, y = 6005, items = { D1, D1 } })
    local leg = seed("ned", rect(6100, 6100, 10, 10), { source = MSH.SOURCE.LEGACY })
    res = T.cmd(ned, "redraw", { claimId = leg.claimId, rect = rect(6000, 6000, 10, 10), expectedRevision = 1 })
    check(res.code == "REDRAW_CLOSED", "legacy 不能重畫")
    local lap = seed("ned", rect(6200, 6200, 10, 10), { lifecycle = "lapsed", noNative = true })
    res = T.cmd(ned, "redraw", { claimId = lap.claimId, rect = rect(6000, 6000, 10, 10), expectedRevision = 1 })
    check(res.code == "REDRAW_CLOSED", "lapsed 不能重畫")
    res = T.cmd(ned, "create", { rect = rect(6000, 6000, 10, 10), deedType = D1 })
    local cur = R.get(res.claimId)
    SafeHouse.addSafeHouse(6500, 6500, 3, 3, MSH.marker(cur.claimId))   -- 同標記重複 → 放棄時 DUPLICATE
    local count0 = #T.houses
    res = T.cmd(ned, "redraw", { claimId = cur.claimId, rect = rect(6001, 6001, 10, 10), expectedRevision = 1 })
    check(res.code == "RELEASE_FAILED" and #T.houses == count0 and cur.lifecycle == "quarantined",
        "舊屋放棄失敗：新原生移除、RELEASE_FAILED")
    T.houses[#T.houses] = nil
    ned.x, ned.y = 6305, 6305
    res = T.cmd(ned, "create", { rect = rect(6300, 6300, 10, 10), deedType = D1 })
    cur = R.get(res.claimId)
    local origPut2 = R.put
    R.put = function() error("put boom") end
    local removes1 = #T.broadcastsOf("nativeRemove")
    res = T.cmd(ned, "redraw", { claimId = cur.claimId, rect = rect(6301, 6301, 10, 10), expectedRevision = 1 })
    R.put = origPut2
    local back = T.houseOf("@MSH:" .. cur.claimId)
    check(res.code == "INTERNAL_ERROR" and cur.lifecycle == "active" and back ~= nil and back.x == 6300
        and cur.nativeCreatedAt == back.created and R.get(cur.claimId) == cur and R.tomb(cur.claimId) == nil,
        "舊屋放棄後丟錯：tombstone 撤回、舊屋寫回 active、原生重建")
    check(#T.broadcastsOf("nativeRemove") == removes1 and T.houseOf("@MSH:" .. (cur.claimId + 1)) == nil
        and MSH.Srv.locked == false, "回滾：舊屋 remove delta 不送、新原生移除")

    boot({ sandbox = { ClaimsPerPlayer = 5 } })
    ned = T.player({ name = "ned", x = 6005, y = 6005, items = { D1 } })
    res = T.cmd(ned, "create", { rect = rect(6000, 6000, 10, 10), deedType = D1 })
    cur = R.get(res.claimId)
    for i = 1, MSH.LIMIT.REDRAWS_PER_CLAIM do
        res = T.cmd(ned, "redraw", { claimId = cur.claimId, rect = rect(6000 + i % 2, 6000, 10, 10),
            expectedRevision = cur.revision })
        if not res.ok then break end
        cur = R.get(res.claimId)
    end
    check(res.ok and cur.redraws == MSH.LIMIT.REDRAWS_PER_CLAIM, "連續重畫 5 次都成功、次數沿用＋1")
    local nextR = R.md.nextClaimId
    res = T.cmd(ned, "redraw", { claimId = cur.claimId, rect = rect(6001, 6000, 10, 10), expectedRevision = cur.revision })
    check(res.code == "REDRAW_CLOSED" and cur.lifecycle == "active" and R.md.nextClaimId == nextR,
        "第 6 次：REDRAW_CLOSED（不燒 claimId）")
    res = T.cmd(ned, "preview", { rect = rect(6001, 6000, 10, 10), claimId = cur.claimId })
    check(res ~= nil and res.code == "REDRAW_CLOSED", "重畫預檢也回 REDRAW_CLOSED")
    boot({ sandbox = { ClaimsPerPlayer = 5 } })
    ned = T.player({ name = "ned", x = 6005, y = 6005, items = { D1 } })
    res = T.cmd(ned, "create", { rect = rect(6000, 6000, 10, 10), deedType = D1 })
    cur = R.get(res.claimId)
    fillTombs(7000)
    nextR = R.md.nextClaimId
    res = T.cmd(ned, "redraw", { claimId = cur.claimId, rect = rect(6001, 6000, 10, 10), expectedRevision = cur.revision })
    check(res.code == "SERVER_FULL" and cur.lifecycle == "active" and R.md.nextClaimId == nextR,
        "tombstone 到軟上限：重畫也回 SERVER_FULL")

    T.section("改名")
    boot()
    local pam = T.player({ name = "pam", x = 7005, y = 7005, items = { D1 } })
    local quinn = T.player({ name = "quinn", x = 0, y = 0 })
    res = T.cmd(pam, "create", { rect = rect(7000, 7000, 10, 10), deedType = D1 })
    local cid = res.claimId
    local syncsR = #T.syncs
    res = T.cmd(pam, "rename", { claimId = cid, title = "  新名字 ", expectedRevision = 1 })
    check(res.ok and res.title == "新名字" and res.revision == 2 and R.get(cid).title == "新名字"
        and T.houseOf("@MSH:" .. cid).title == "新名字" and #T.syncs == syncsR + 1, "改名：紀錄、原生、廣播、revision＋1")
    res = T.cmd(pam, "rename", { claimId = cid, title = "x]", expectedRevision = 2 })
    check(res.code == "BAD_TITLE" and R.get(cid).title == "新名字", "不合法標題")
    res = T.cmd(pam, "rename", { claimId = cid, title = "y", expectedRevision = 1 })
    check(res.code == "STALE_REVISION", "改名 revision 過期")
    res = T.cmd(quinn, "rename", { claimId = cid, title = "y", expectedRevision = 2 })
    check(res.code == "NOT_OWNER", "不是屋主不能改名")

    T.section("清單與詳細：ACL、狀態優先序")
    boot({ sandbox = { ClaimsPerPlayer = 5 } })
    local own = T.player({ name = "rae", x = 8005, y = 8005, items = { D1, D1 } })
    local mem = T.player({ name = "sam", x = 0, y = 0 })
    local out = T.player({ name = "tia", x = 0, y = 0 })
    res = T.cmd(own, "create", { rect = rect(8000, 8000, 10, 10), deedType = D1 })
    local cA = res.claimId
    R.get(cA).grants = { { user = "sam", bits = 1 + 8 }, { user = "tia", bits = 2 } }
    own.x = 8105
    res = T.cmd(own, "create", { rect = rect(8100, 8000, 10, 10), deedType = D1 })
    local cB = res.claimId
    T.cmd(own, "release", { claimId = cB, expectedRevision = 1 })
    res = T.cmd(own, "list", {})
    check(res.ok and #res.claims == 1 and res.claims[1].claimId == cA and res.claims[1].actorRole == "owner"
        and res.claims[1].healthSummary == "PROTECTED", "屋主清單；released 不列")
    res = T.cmd(mem, "list", {})
    check(#res.claims == 1 and res.claims[1].actorRole == "member" and res.claims[1].bits == 9, "成員清單帶權限位元")
    res = T.cmd(out, "list", {})
    check(#res.claims == 0, "沒有 MEMBER 位元不算成員")
    res = T.cmd(out, "detail", { claimId = cA })
    check(res.code == "NOT_FOUND", "非成員看詳細：NOT_FOUND")
    res = T.cmd(own, "detail", { claimId = cB })
    check(res.code == "NOT_FOUND", "released 的詳細：NOT_FOUND")
    res = T.cmd(mem, "detail", { claimId = cA })
    check(res.ok and res.actorRole == "member" and res.rect.x == 8000 and #res.roster == 3 and res.roster[1].user == "rae"
        and res.actions.canRelease == false and res.actions.canRename == false and res.actions.redrawRemainingMs == 0,
        "成員看詳細：沒有屋主操作")
    res = T.cmd(own, "detail", { claimId = cA })
    check(res.ok and res.actions.canRelease and res.actions.canRename and res.actions.redrawRemainingMs > 0
        and res.deedTier == 1 and res.source == "deed" and res.createdAt == R.get(cA).createdAt, "屋主看詳細：可放棄、改名、重畫")
    if MSH.Reconcile == nil then MSH.Reconcile = {} end
    MSH.Reconcile.claimFlags = MSH.Reconcile.claimFlags or {}
    local C = MSH.Claims
    local recA = R.get(cA)
    recA.lifecycle = "lapsed"
    check(C.healthSummary(recA) == "LAPSED", "lapsed")
    MSH.Reconcile.claimFlags[cA] = { interference = true }
    check(C.healthSummary(recA) == "INTERFERENCE", "干擾 ＞ lapsed")
    MSH.Reconcile.claimFlags[cA] = { interference = true, missing = true }
    check(C.healthSummary(recA) == "REPAIR_PAUSED", "修復暫停 ＞ 干擾")
    MSH.Health.state.blocked = true
    check(C.healthSummary(recA) == "SERVER_BLOCKED", "伺服器設定 ＞ 全部")
    MSH.Health.state.blocked = false
    MSH.Reconcile.claimFlags[cA] = nil
    recA.lifecycle = "quarantined"
    check(C.healthSummary(recA) == "QUARANTINED", "quarantined")
    recA.lifecycle = "active"
end
