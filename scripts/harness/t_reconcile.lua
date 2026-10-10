-- Reconcile：開服 recovery matrix、週期收斂（名單／標題／owner）、sentinel、blocked mode、干擾計數、lapsed、tombstone GC。
return function(T)
    local check = T.check
    local RESTART = { keepGmd = true, keepFiles = true, keepHouses = true }
    local DAY = 86400000

    local function mk(MSH, x, owner, grants)
        local R = MSH.Registry
        local id = R.allocId()
        local rec = R.newRecord({ claimId = id, rect = { x = x, y = x, w = 5, h = 5 }, title = "t" .. id, owner = owner,
            source = MSH.SOURCE.DEED, deedTier = 1, grants = grants or {}, createdAt = T.now })
        local hs = MSH.Native.build(rec)
        rec.nativeCreatedAt = hs:getDatetimeCreated()
        R.put(rec)
        return rec, hs
    end
    local function countLogs(fragment)
        local n = 0
        for _, line in ipairs(T.logs) do if string.find(line, fragment, 1, true) then n = n + 1 end end
        return n
    end
    local function syncsOf(hs)
        local n = 0
        for _, s in ipairs(T.syncs) do if s.house == hs then n = n + 1 end end
        return n
    end
    local function housesOf(owner)
        local n = 0
        for _, hs in ipairs(T.houses) do if hs.owner == owner then n = n + 1 end end
        return n
    end
    local function removedDelta(id)
        for _, a in ipairs(T.broadcastsOf("nativeRemove")) do if a.claimId == id then return true end end
        return false
    end
    -- 讓下一個 tick 不會因 wall-clock 掃描（只剩 sentinel／hostile 能觸發）
    local function justSwept(MSH) MSH.Reconcile.lastAttempt = T.now end
    -- 記錄每次 admin alert 送出時是否還持鎖（§6.2：網路送出在放鎖之後）
    local alertCalls = {}
    local function watchAlerts()
        local MSH = MinidoracatSafehouse
        local orig = MSH.Audit.alertAdmins
        alertCalls = {}
        MSH.Audit.alertAdmins = function(code, detail)
            alertCalls[#alertCalls + 1] = { code = code, locked = MSH.Srv.locked }
            return orig(code, detail)
        end
    end
    local function alertsOf(code)
        local n, locked = 0, false
        for _, a in ipairs(alertCalls) do
            if a.code == code then
                n = n + 1
                locked = locked or a.locked
            end
        end
        return n, locked
    end
    local function sweepNow() T.tick(5) end

    T.section("開服 recovery matrix（逐列）")
    local MSH = T.boot()
    local R, N = MSH.Registry, MSH.Native
    local bob = { { user = "bob", bits = MSH.SHARE.MEMBER } }
    local r1, hs1 = mk(MSH, 100, "alice", bob)                    -- active＋精確原生
    local r2, hs2 = mk(MSH, 200, "alice")                         -- active＋MISSING → rebuild
    N.remove(hs2)
    local rev2 = r2.revision
    local r3, hs3 = mk(MSH, 300, "alice")                         -- active＋MISSING＋重疊 → quarantined
    N.remove(hs3)
    SafeHouse.addSafeHouse(302, 302, 3, 3, "stranger")
    local r4 = mk(MSH, 400, "alice")                              -- 兩個同標記原生 → quarantined
    SafeHouse.addSafeHouse(410, 410, 3, 3, MSH.marker(r4.claimId))
    local r5, hs5 = mk(MSH, 500, "alice")                         -- 標記原生指紋不合 → quarantined
    N.remove(hs5)
    local r6 = mk(MSH, 600, "alice")                              -- releasing＋相符原生 → 移除＋released
    R.markReleasing(r6, "op6", r6.nativeCreatedAt)
    local r7, hs7 = mk(MSH, 700, "alice")                         -- releasing＋MISSING → released
    N.remove(hs7)
    R.markReleasing(r7, "op7", r7.nativeCreatedAt)
    local r8, hs8 = mk(MSH, 800, "alice")                         -- releasing＋指紋不合 → quarantined
    N.remove(hs8)
    R.markReleasing(r8, "op8", r8.nativeCreatedAt)
    local r9 = mk(MSH, 900, "alice")                              -- lapsed＋原生還在 → 移除
    r9.lifecycle, r9.lapsedAt = "lapsed", T.now
    local r10 = mk(MSH, 1000, "alice")                            -- released＋相符原生重現 → 移除
    R.markReleased(r10, "RELEASED", T.now)
    local r11, hs11 = mk(MSH, 1100, "alice")                      -- released＋不同指紋的標記原生 → 不碰、alert
    N.remove(hs11)
    R.markReleased(r11, "RELEASED", T.now)
    local r12, hs12 = mk(MSH, 1200, "alice")                      -- quarantined → 不碰
    R.markQuarantined(r12, "TEST")
    hs12:addPlayer("zed")
    T.advance(1000)
    SafeHouse.addSafeHouse(500, 500, 5, 5, MSH.marker(r5.claimId))
    SafeHouse.addSafeHouse(800, 800, 5, 5, MSH.marker(r8.claimId))
    SafeHouse.addSafeHouse(1100, 1100, 5, 5, MSH.marker(r11.claimId))
    local orphan = SafeHouse.addSafeHouse(1300, 1300, 6, 4, "@MSH:50")   -- 有標記、沒有紀錄
    orphan:setTitle("Lost")
    orphan:addPlayer("dave")
    orphan:addPlayer("erin")
    SafeHouse.addSafeHouse(1400, 1400, 5, 5, "@MSH:60")                  -- 沒有紀錄的同標記兩間
    SafeHouse.addSafeHouse(1500, 1500, 5, 5, "@MSH:60")
    local foreign = SafeHouse.addSafeHouse(1600, 1600, 5, 5, "stranger2")
    foreign:addPlayer("x")
    foreign:setTitle("F")

    -- Economy FAILED：手放的 lapsed 紀錄不被 Economy 恢復或釋出（沒裝＝ABSENT 會全部恢復，§1.3）
    MSH = T.boot({ keepGmd = true, keepFiles = true, keepHouses = true,
        beforeStart = function() watchAlerts() T.economy({ failRegister = true }) end })
    R, N = MSH.Registry, MSH.Native
    local Rc = MSH.Reconcile
    -- released 只剩 tombstone（R.get 回 nil）
    local function lc(rec)
        local r = R.get(rec.claimId)
        if r then return r.lifecycle end
        return R.tomb(rec.claimId) and "released" or nil
    end
    local function reason(rec) return R.get(rec.claimId).quarantineReason end
    check(lc(r1) == "active" and hs1.owner == MSH.marker(r1.claimId) and hs1.players:contains("alice")
        and hs1.players:contains("bob"), "active＋精確原生：維持")
    check(not hs1.players:contains(MSH.marker(r1.claimId)), "重開後 owner 標記在 players（load 殘留）：安靜移除")
    check(syncsOf(hs1) == 0 and countLogs("ROSTER_REMOVED") == 0 and Rc.claimFlags[r1.claimId] == nil,
        "load 殘留不算 drift：不廣播、不寫 audit、不設旗標")
    local new2 = T.houseOf(MSH.marker(r2.claimId))
    check(lc(r2) == "active" and new2 ~= nil and R.get(r2.claimId).nativeCreatedAt == new2.created, "active＋MISSING：重建")
    check(R.get(r2.claimId).revision == rev2 and syncsOf(new2) == 0,
        "重建不加 revision；開服首輪還沒有連線、不廣播（玩家登入時 MetaDataPacket 會送整份清單）")
    check(lc(r3) == "quarantined" and reason(r3) == "REBUILD_OVERLAP" and T.houseOf(MSH.marker(r3.claimId)) == nil,
        "active＋MISSING 但和別的原生重疊：quarantined、不建")
    check(lc(r4) == "quarantined" and reason(r4) == "DUPLICATE" and housesOf(MSH.marker(r4.claimId)) == 2,
        "同一 claimId 兩個標記原生：quarantined、不刪")
    check(lc(r5) == "quarantined" and reason(r5) == "MISMATCH", "active＋標記原生指紋不合：quarantined")
    check(lc(r6) == "released" and T.houseOf(MSH.marker(r6.claimId)) == nil and not removedDelta(r6.claimId),
        "releasing＋相符原生：移除、released（開服首輪不送 remove delta）")
    check(lc(r7) == "released", "releasing＋原生不在：released")
    check(lc(r8) == "quarantined" and reason(r8) == "RELEASE_MISMATCH" and T.houseOf(MSH.marker(r8.claimId)) ~= nil,
        "releasing＋指紋不合：quarantined、原生不動")
    check(lc(r9) == "lapsed" and T.houseOf(MSH.marker(r9.claimId)) == nil and not removedDelta(r9.claimId),
        "lapsed＋原生還在：移除、維持 lapsed（開服首輪不送 remove delta）")
    check(lc(r10) == "released" and T.houseOf(MSH.marker(r10.claimId)) == nil and not removedDelta(r10.claimId),
        "released＋相符原生重現：移除")
    check(#T.netEarly == 0, "開服首輪不碰連線：OnServerStarted 之前不查在線玩家、不廣播、不送封包（實機會 NPE）")
    local relAlerts, relLocked = alertsOf("RELEASED_NATIVE")
    check(T.houseOf(MSH.marker(r11.claimId)) ~= nil and countLogs("RELEASED_NATIVE") == 1 and relAlerts == 1,
        "released＋不同指紋的標記原生：不碰、audit、alert")
    check(not relLocked, "RELEASED_NATIVE alert 在放鎖之後才送")
    check(R.get(r11.claimId) == nil and R.tomb(r11.claimId) ~= nil, "有 tombstone 的標記原生不當孤兒轉 recovered")
    check(lc(r12) == "quarantined" and hs12.players:contains("zed") and T.houseOf(MSH.marker(r12.claimId)) == hs12,
        "quarantined：完全不碰")
    local rec50 = R.get(50)
    check(rec50 ~= nil and rec50.lifecycle == "quarantined" and rec50.quarantineReason == "RECOVERED"
        and rec50.owner == nil and rec50.title == "Lost" and rec50.rect.w == 6 and rec50.source == "deed"
        and rec50.deedTier == 1, "有標記沒紀錄：quarantined(RECOVERED)、owner 不猜、rect／title 取自原生")
    check(#rec50.candidates == 2 and rec50.candidates[1] == "dave" and rec50.candidates[2] == "erin",
        "原生名單只當候選（不含標記）")
    check(R.get(60) ~= nil and R.get(60).quarantineReason == "RECOVERED_DUPLICATE", "沒紀錄的同標記兩間：quarantined")
    check(R.md.nextClaimId == 61, "nextClaimId 高水位抬到標記 id 之後（實際 " .. tostring(R.md.nextClaimId) .. "）")
    check(foreign.owner == "stranger2" and foreign.title == "F" and foreign.players:contains("x")
        and syncsOf(foreign) == 0, "foreign 原生：不改、不廣播")
    local houses, logs = #T.houses, #T.logs
    T.syncs = {}
    sweepNow()
    sweepNow()
    check(#T.houses == houses and #T.syncs == 0 and countLogs("REBUILT") == 1, "開服之後的週期掃描不再改任何東西")

    T.section("週期收斂：名單、標題、owner drift，每間一次廣播、不傳送")
    MSH = T.boot()
    R, N, Rc = MSH.Registry, MSH.Native, MSH.Reconcile
    local c1, h1 = mk(MSH, 100, "alice", bob)
    local _, h2c = mk(MSH, 200, "carol")
    local pbob = T.player({ name = "bob", x = 102, y = 102 })
    local pmal = T.player({ name = "mallory", x = 101, y = 101 })
    sweepNow()
    T.syncs = {}
    h1:removePlayer("bob")
    h1:addPlayer("mallory")
    h1:setTitle("hacked")
    sweepNow()
    check(h1.players:contains("bob") and not h1.players:contains("mallory") and h1.title == c1.title,
        "名單與標題收斂回 registry")
    check(syncsOf(h1) == 1 and syncsOf(h2c) == 0, "變動的那間恰好一次廣播、沒變的不廣播")
    check(#T.teleports == 0 and pbob.x == 102 and pmal.x == 101, "收斂不傳送任何人（不對真實玩家 kick）")
    check(countLogs("ROSTER_REMOVED") == 1, "收掉非 canonical 成員寫一行 audit")
    T.syncs = {}
    h1:setOwner("mallory")                    -- 原版 owner packet：換屋主、把舊屋主加回成員
    h1:addPlayer(MSH.marker(c1.claimId))
    sweepNow()
    check(h1.owner == MSH.marker(c1.claimId) and not h1.players:contains("mallory")
        and not h1.players:contains(MSH.marker(c1.claimId)) and h1.players:contains("alice"), "owner drift：換回標記、名單修正")
    check(syncsOf(h1) == 1 and #T.houses == 2 and countLogs("OWNER_DRIFT") == 1, "owner drift：一次廣播、不重建")
    sweepNow()
    check(syncsOf(h1) == 1, "收斂後的下一輪不再廣播")

    T.section("sentinel：偽造 release 後一個 tick 內重建")
    T.syncs = {}
    justSwept(MSH)
    SafeHouse.removeSafeHouse(h1)
    T.tick(1)
    local back = T.houseOf(MSH.marker(c1.claimId))
    check(back ~= nil and back ~= h1 and back.players:contains("bob") and syncsOf(back) == 1, "原生清單變短：下一個 tick 就重建＋廣播")
    check(R.get(c1.claimId).lifecycle == "active", "重建後紀錄維持 active")

    T.section("重建不讓 expectedRevision 失效")
    MSH.Srv.define("testRevision", { kind = "mutation", fields = { claimId = "claimId", expectedRevision = "revision" },
        run = function(ctx)
            local rec = MSH.Registry.get(ctx.args.claimId)
            if rec.revision ~= ctx.args.expectedRevision then return MSH.Srv.fail(MSH.CODE.STALE_REVISION) end
            MSH.Registry.touch(rec)
            return MSH.Srv.ok()
        end })
    local palice = T.player({ name = "alice" })
    local revBefore = R.get(c1.claimId).revision
    SafeHouse.removeSafeHouse(back)
    T.tick(1)
    check(T.houseOf(MSH.marker(c1.claimId)) ~= nil, "再次重建")
    local res = T.cmd(palice, "testRevision", { claimId = c1.claimId, expectedRevision = revBefore })
    check(res and res.ok, "重建前拿到的 expectedRevision 仍可提交")

    T.section("hostile mode：每 tick 掃描")
    local hb = T.houseOf(MSH.marker(c1.claimId))
    justSwept(MSH)
    hb:removePlayer("bob")
    T.tick(1)
    check(not hb.players:contains("bob"), "健康時：wall-clock 週期未到、清單長度沒變 → 這個 tick 不掃")
    sweepNow()
    local imp = T.player({ name = "@MSH:9" })
    T.tick(12)
    check(MSH.Health.isHostile(), "冒名 service-owner 在線 → hostile")
    justSwept(MSH)
    hb:removePlayer("bob")
    T.tick(1)
    check(hb.players:contains("bob"), "hostile：下一個 tick 就收斂")
    T.disconnect(imp)
    T.tick(12)
    check(not MSH.Health.isHostile(), "冒名者離線 → 解除 hostile")

    T.section("干擾：re-add 每分鐘超過 5 次 → 旗標＋每分鐘最多一行 audit，成員照樣每輪 re-add")
    T.player({ name = "boss", admin = true })
    watchAlerts()
    local always = true
    for _ = 1, 9 do
        hb:removePlayer("bob")
        sweepNow()
        if not hb.players:contains("bob") then always = false end
    end
    local alerts = 0
    for _, m in ipairs(T.outbox["boss"]) do if m.command == "alert" and m.args.code == "INTERFERENCE" then alerts = alerts + 1 end end
    check(always, "每一輪都 re-add")
    check(Rc.claimFlags[c1.claimId] and Rc.claimFlags[c1.claimId].interference == true, "claim 標記成員同步受干擾")
    check(countLogs("INTERFERENCE") == 1 and alerts == 1, "一分鐘內只寫一行 audit、只 alert 一次（實際 "
        .. countLogs("INTERFERENCE") .. "／" .. alerts .. "）")
    local intAlerts, intLocked = alertsOf("INTERFERENCE")
    check(intAlerts == 1 and not intLocked, "INTERFERENCE alert 在放鎖之後才送")
    check(Rc.health().interference == 1, "health().interference 計入受干擾的 claim")
    T.advance(60000)
    sweepNow()
    check(Rc.claimFlags[c1.claimId] == nil, "安靜一分鐘後清掉干擾旗標")

    T.section("blocked mode：不重建、紀錄保留、旗標 missing；恢復後恰好一次重建")
    local h2b = T.houseOf("@MSH:2")
    T.serverOptions.War = "true"
    sweepNow()
    check(MSH.Health.blocked(), "War=true → blocked")
    local rebuilt0 = countLogs("REBUILT")
    SafeHouse.removeSafeHouse(T.houseOf(MSH.marker(c1.claimId)))
    T.tick(1)
    sweepNow()
    sweepNow()
    check(T.houseOf(MSH.marker(c1.claimId)) == nil and countLogs("REBUILT") == rebuilt0, "blocked：消失的原生不重建")
    check(R.get(c1.claimId).lifecycle == "active" and Rc.claimFlags[c1.claimId].missing == true,
        "blocked：紀錄維持 active、旗標 missing")
    h2b:removePlayer("carol")
    h2b:setTitle("x")
    sweepNow()
    check(h2b.players:contains("carol") and h2b.title == "t2", "blocked：名單與標題收斂照常")
    T.serverOptions.War = "false"
    sweepNow()
    sweepNow()
    sweepNow()
    check(not MSH.Health.blocked() and T.houseOf(MSH.marker(c1.claimId)) ~= nil, "恢復後重建")
    check(countLogs("REBUILT") == rebuilt0 + 1 and Rc.claimFlags[c1.claimId] == nil, "恰好一次重建、旗標清掉、不振盪")

    T.section("blocked 時開服：不重建；恢復後一次重建")
    MSH = T.boot()
    local b1, bh = mk(MSH, 100, "alice")
    MSH.Native.remove(bh)
    MSH = T.boot({ keepGmd = true, keepFiles = true, keepHouses = true,
        beforeStart = function(env) env.serverOptions.War = "true" end })
    check(T.houseOf(MSH.marker(b1.claimId)) == nil and MSH.Registry.get(b1.claimId).lifecycle == "active"
        and MSH.Reconcile.claimFlags[b1.claimId].missing == true, "blocked 開服：不重建、不轉 released、旗標 missing")
    T.serverOptions.War = "false"
    sweepNow()
    check(housesOf(MSH.marker(b1.claimId)) == 1 and countLogs("REBUILT") == 1, "恢復後一次重建")

    T.section("lapsed：移除殘留原生；期滿釋出不歸 Reconcile")
    MSH = T.boot()
    R = MSH.Registry
    local l1 = mk(MSH, 100, "alice")
    l1.lifecycle, l1.lapsedAt = "lapsed", T.now
    sweepNow()
    check(T.houseOf(MSH.marker(l1.claimId)) == nil and removedDelta(l1.claimId) and l1.lifecycle == "lapsed",
        "lapsed：原生移除＋remove delta、範圍仍佔位")
    sweepNow()
    check(T.houseOf(MSH.marker(l1.claimId)) == nil, "lapsed 不重建")
    MSH.Economy.status = "FAILED"   -- 期滿釋出歸 Economy（只在 READY，t_economy 測）
    T.advance(7 * DAY)
    sweepNow()
    check(l1.lifecycle == "lapsed" and R.get(l1.claimId) == l1 and R.tomb(l1.claimId) == nil,
        "Economy 不 READY：lapseKeepDays 期滿也不釋出")

    T.section("lapsed 原生的 owner drift：本輪換回標記後直接移除，不送 SafehouseSync")
    local l2, lh2 = mk(MSH, 300, "alice")
    sweepNow()
    T.syncs = {}
    lh2:setOwner("mallory")
    l2.lifecycle, l2.lapsedAt = "lapsed", T.now
    sweepNow()
    check(T.houseOf(MSH.marker(l2.claimId)) == nil and T.houseOf("mallory") == nil and removedDelta(l2.claimId),
        "owner 被換掉的 lapsed 原生：換回標記並移除＋remove delta")
    check(syncsOf(lh2) == 0, "同一輪移除的原生不廣播（實際 " .. syncsOf(lh2) .. " 次）")

    T.section("health()：上次成功時間、待修復數、drift 持續時間；pass 丟錯不算成功")
    MSH = T.boot()
    R, Rc = MSH.Registry, MSH.Reconcile
    local k1, kh1 = mk(MSH, 100, "alice")
    local k2 = mk(MSH, 200, "alice")
    R.markQuarantined(k2, "TEST")
    T.advance(1000)
    Rc.sweep(T.now)
    local hl = Rc.health()
    check(hl.lastSuccessAt == T.now and hl.pendingRepair == 1 and hl.longestDriftMs == 0 and hl.interference == 0,
        "收斂乾淨：lastSuccessAt＝這輪、pendingRepair 只算 quarantined、沒有 drift")
    T.serverOptions.War = "true"
    MSH.Native.remove(kh1)
    T.advance(1000)
    Rc.sweep(T.now)
    T.advance(3000)
    Rc.sweep(T.now)
    hl = Rc.health()
    check(MSH.Health.blocked() and hl.pendingRepair == 2 and hl.longestDriftMs == 3000,
        "blocked 缺原生：計入待修復、drift 持續時間累計（實際 " .. tostring(hl.longestDriftMs) .. "）")
    local okAt, realIndex = Rc.lastSuccessAt, MSH.Native.index
    T.advance(1000)
    MSH.Native.index = function() error("boom") end
    local swept = Rc.sweep(T.now)
    MSH.Native.index = realIndex
    check(swept == false and Rc.lastSuccessAt == okAt and Rc.lastAttempt == T.now and countLogs("INTERNAL_ERROR") == 1,
        "pass 丟錯：lastSuccessAt 不動（只更新排程用的 lastAttempt）")
    T.serverOptions.War = "false"
    T.advance(1000)
    Rc.sweep(T.now)
    T.advance(1000)
    Rc.sweep(T.now)
    hl = Rc.health()
    check(T.houseOf(MSH.marker(k1.claimId)) ~= nil and hl.pendingRepair == 1 and hl.longestDriftMs == 0
        and hl.lastSuccessAt == T.now, "恢復重建後：待修復、drift 歸零")

    T.section("malformed 紀錄：收斂略過、整輪照常成功")
    MSH = T.boot()
    local m1, mh1 = mk(MSH, 100, "alice")
    MSH.Registry.md.claims[99] = { claimId = 99, lifecycle = "active" }   -- 缺 rect 的壞紀錄
    SafeHouse.addSafeHouse(500, 500, 5, 5, "@MSH:99")
    MSH = T.boot(RESTART)
    R, Rc = MSH.Registry, MSH.Reconcile
    local bad = R.get(99)
    check(bad ~= nil and bad.malformed == true and bad.lifecycle == "quarantined" and bad.quarantineReason == "MALFORMED"
        and T.houseOf("@MSH:99") ~= nil and Rc.lastSuccessAt == T.now, "開服：壞紀錄轉 malformed、標記原生不動、首輪成功")
    check(Rc.health().pendingRepair == 1, "malformed 計入待修復")
    SafeHouse.removeSafeHouse(T.houseOf("@MSH:99"))
    bad.lifecycle = "releasing"     -- 模擬 forceRelease 中途的狀態（rect 仍是 nil）
    mh1:setTitle("x")
    T.advance(1000)
    check(Rc.sweep(T.now) and Rc.lastSuccessAt == T.now and mh1.title == R.get(m1.claimId).title
        and countLogs("INTERNAL_ERROR") == 0, "沒有 rect 的紀錄不讓整輪失敗，其他 claim 照常收斂")
    check(R.get(99) == bad and bad.lifecycle == "releasing", "malformed 紀錄收斂不碰（留給管理員 recovery）")

    T.section("tombstone GC")
    MSH = T.boot()
    R = MSH.Registry
    local g1 = mk(MSH, 100, "alice")
    MSH.Lifecycle.release(g1, "RELEASED", "op-g1", T.now)
    local g2, gh2 = mk(MSH, 200, "alice")
    MSH.Native.remove(gh2)
    MSH.Lifecycle.release(g2, "RELEASED", "op-g2", T.now)
    T.advance(1000)
    SafeHouse.addSafeHouse(200, 200, 5, 5, MSH.marker(g2.claimId))   -- 不同指紋的標記原生
    local nextId = R.md.nextClaimId
    MSH.Reconcile.gc(T.now + 31 * DAY)
    check(R.tomb(g1.claimId) ~= nil, "沒跨過重開：超過 30 天也保留")
    MSH = T.boot(RESTART)
    R = MSH.Registry
    MSH.Reconcile.gc(T.now)
    check(R.tomb(g1.claimId) ~= nil, "跨過重開但未滿 30 天：保留")
    T.advance(31 * DAY)
    T.tick(1)
    check(R.tomb(g1.claimId) == nil and countLogs("TOMBSTONE_GC") == 1, "跨過重開＋30 天＋原生不在：minute hook 刪除")
    check(R.tomb(g2.claimId) ~= nil, "該 id 還有標記原生：不刪")
    check(R.md.nextClaimId == nextId, "claimId 不回收")
    T.serverOptions.War = "true"
    MSH.Health.evaluate(T.now)
    local before = R.tombstoneCount()
    -- tombstone 格式：x,y,w,h,nativeCreatedAt,bootSeen,releasedAt（Registry）
    local function seedTomb(id, x, bootSeen, releasedAt)
        R.md.tombs[id] = table.concat({ x, 10, 1, 1, -1, bootSeen, releasedAt }, ",")
    end
    for i = 1, 3 do seedTomb(R.allocId(), 3000 + i * 10, 0, 0) end
    MSH.Reconcile.gc(T.now)
    check(R.tombstoneCount() == before + 3, "blocked mode 不刪紀錄")
    T.serverOptions.War = "false"
    MSH.Health.evaluate(T.now)
    MSH.Reconcile.gc(T.now)
    check(R.tombstoneCount() == before, "恢復後照常 GC")

    T.section("tombstone pressure GC（超過軟上限刪最舊、已跨重開、沒有原生的）")
    MSH = T.boot()
    R = MSH.Registry
    local soft = MSH.LIMIT.TOMBSTONE_SOFT
    local oldest
    for i = 1, soft + 6 do
        local id = R.allocId()
        seedTomb(id, 10 + i, i <= 2 and R.md.bootSeq or 0, T.now - (soft + 6 - i) * 1000)   -- 最舊的兩筆沒跨過重開
        if i == 3 then oldest = id end
    end
    MSH.Reconcile.gc(T.now)
    check(R.tombstoneCount() == soft, "壓回軟上限（實際 " .. R.tombstoneCount() .. "）")
    check(R.tomb(1) ~= nil and R.tomb(2) ~= nil, "沒跨過重開的不刪（即使最舊）")
    check(R.tomb(oldest) == nil and R.tomb(oldest + 5) == nil and R.tomb(oldest + 6) ~= nil, "從最舊、合格的開始刪 6 筆")
end
