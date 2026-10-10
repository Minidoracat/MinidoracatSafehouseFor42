-- 管理員指令（Admin.lua）與伺服器端校正（Calibrate.lua）：沙盒寫回與每分鐘比對、玩家清單、個人上限、
-- 代為放棄、targeted recovery、mirror 校正回應。
return function(T)
    local check = T.check

    local function sv(key) return SandboxVars.MinidoracatSafehouse[key] end
    local function countLogs(event)
        local n = 0
        for _, line in ipairs(T.logs) do
            if string.find(line, "^" .. event .. "\t") then n = n + 1 end
        end
        return n
    end
    local function syncsOf(p)
        local out = {}
        for _, m in ipairs(T.outbox[p.name] or {}) do
            if m.command == "sandboxSync" then out[#out + 1] = m.args end
        end
        return out
    end
    local function keyCount(t)
        local n = 0
        for _ in pairs(t) do n = n + 1 end
        return n
    end
    -- 建一筆紀錄＋原生安全屋（照 t_foundation 的 mk）
    local function mk(MSH, rect, owner, opts)
        opts = opts or {}
        local R = MSH.Registry
        local rec = R.newRecord({ claimId = R.allocId(), rect = rect, title = "t", owner = owner, source = MSH.SOURCE.DEED,
            deedTier = 1, createdAt = T.now, lifecycle = opts.lifecycle })
        local house = nil
        if not opts.noNative then
            house = MSH.Native.build(rec)
            rec.nativeCreatedAt = house:getDatetimeCreated()
        end
        R.put(rec)
        if opts.quarantine then R.markQuarantined(rec, "TEST") end
        return rec, house
    end

    T.section("Admin：權限與選項查詢")
    local MSH = T.boot()
    local S = MSH.Srv
    local boss = T.player({ name = "boss", admin = true })
    local alice = T.player({ name = "alice" })
    local bob = T.player({ name = "bob" })
    local res = T.cmd(alice, "adminOptions", {})
    check(res ~= nil and res.code == "NOT_ADMIN", "非管理員查選項：NOT_ADMIN")
    res = T.cmd(alice, "adminSetOptions", { changes = { ClaimGap = 4 } })
    check(res.code == "NOT_ADMIN" and sv("ClaimGap") == 2 and T.sbox.sets == 0, "非管理員改選項：NOT_ADMIN、沒寫入")
    res = T.cmd(boss, "adminOptions", {})
    check(res.ok and keyCount(res.values) == 81 and res.values.ClaimGap == 2 and res.values.RedrawLimit == 5,
        "管理員拿到 81 個選項的原值（含重新框選次數上限 5）")
    check(res.health.blocked == false and type(res.health.hostile) == "boolean" and type(res.settingsWarnings) == "table",
        "附 health 狀態與設定警告")
    check(type(res.resourceApi) == "boolean" and type(res.parkingApi) == "boolean", "附資源點與停車場資料來源狀態")

    T.section("Admin：沙盒寫回")
    res = T.cmd(boss, "adminSetOptions", { changes = { ClaimGap = 17, MaxShares = 3 } })
    check(res.code == "BAD_OPTION" and res.key == "ClaimGap" and res.reason == "OUT_OF_RANGE", "超出範圍：BAD_OPTION 帶鍵與原因")
    check(T.sbox.sets == 0 and T.sbox.saves == 0 and sv("MaxShares") == 8, "驗證不過：整批不寫、不存檔")
    res = T.cmd(boss, "adminSetOptions", { changes = { Tier1Side = 10, Tier1Area = 200 } })
    check(res.code == "BAD_OPTION" and res.reason == "AREA_OVER_SIDE", "面積大於邊長平方：整批拒絕")
    res = T.cmd(boss, "adminSetOptions", { changes = { RedrawLimit = 0 } })
    local lo = res.code == "BAD_OPTION" and res.key == "RedrawLimit"
    res = T.cmd(boss, "adminSetOptions", { changes = { RedrawLimit = 21 } })
    check(lo and res.code == "BAD_OPTION" and res.key == "RedrawLimit" and sv("RedrawLimit") == 5 and T.sbox.sets == 0,
        "重新框選次數上限 0 與 21：BAD_OPTION、不寫入")
    T.sbox.saveOk = false
    res = T.cmd(boss, "adminSetOptions", { changes = { ClaimGap = 4, MaxShares = 3 } })
    check(res.code == "SAVE_FAILED" and sv("ClaimGap") == 2 and sv("MaxShares") == 8, "存檔失敗：SAVE_FAILED、值還原")
    check(#syncsOf(alice) == 0 and countLogs("ADMIN_OPTIONS") == 0, "存檔失敗：不送 sandboxSync、不寫 audit")
    T.sbox.saveOk = true
    local saves0 = T.sbox.saves
    local realSend = sendServerCommand
    local lockedAtSend = {}
    sendServerCommand = function(a, b, c, d)
        if c == "sandboxSync" then lockedAtSend[#lockedAtSend + 1] = S.locked end
        return realSend(a, b, c, d)
    end
    res = T.cmd(boss, "adminSetOptions", { changes = { ClaimGap = 5, Tier2LootChance = 2.5, RoadKinds = "main;gravel" } })
    sendServerCommand = realSend
    check(res.ok and sv("ClaimGap") == 5 and sv("Tier2LootChance") == 2.5 and sv("RoadKinds") == "main;gravel", "成功寫入多個選項")
    check(T.sbox.saves == saves0 + 1, "多個選項只存一次檔")
    local allSynced = true
    for _, p in ipairs({ boss, alice, bob }) do
        local s = syncsOf(p)
        if #s ~= 1 or s[1].ClaimGap ~= 5 or keyCount(s[1]) ~= 81 then allSynced = false end
    end
    check(allSynced, "每位在線玩家各收到一份完整 81 鍵 sandboxSync")
    check(#lockedAtSend == 3 and lockedAtSend[1] == false and lockedAtSend[3] == false, "sandboxSync 在放鎖之後才送")
    check(countLogs("ADMIN_OPTIONS") == 1, "成功寫一行 ADMIN_OPTIONS audit")

    T.section("Admin：每分鐘比對沙盒")
    T.advance(60000)
    T.tick(1)
    check(countLogs("SANDBOX_CHANGED") == 0 and #syncsOf(alice) == 1, "自己的寫入不被當成外部改動")
    T.sandbox("MaxShares", 4)          -- 原版伺服器設定畫面直接改 SandboxVars
    T.advance(60000)
    T.tick(1)
    local s = syncsOf(alice)
    check(countLogs("SANDBOX_CHANGED") == 1 and #s == 2 and s[2].MaxShares == 4, "外部改動：寫 audit 並重送快照")
    T.advance(60000)
    T.tick(1)
    check(countLogs("SANDBOX_CHANGED") == 1 and #syncsOf(alice) == 2, "沒有再改：不重複 audit")

    T.section("Admin：玩家清單")
    MSH = T.boot()
    local R = MSH.Registry
    boss = T.player({ name = "boss", admin = true })
    for i = 1, 120 do R.setBinding(string.format("p%03d", i), 76561198000000000 + i * 16, "TEST", T.now) end
    for _, n in ipairs({ "Bob", "alice", "Carol" }) do R.setBinding(n, 76561198000100000, "TEST", T.now) end
    R.setOverride("erin", 2)
    mk(MSH, { x = 100, y = 100, w = 5, h = 5 }, "Frank", { noNative = true })
    res = T.cmd(boss, "adminPlayers", {})
    check(res.ok and res.total == 125 and res.pages == 3 and res.page == 1 and #res.rows == 50, "預設全部玩家、每頁 50 列")
    local firstFive = {}
    for i = 1, 5 do firstFive[i] = res.rows[i].name end
    check(table.concat(firstFive, ",") == "alice,Bob,Carol,erin,Frank", "照小寫名字排序（實際 " .. table.concat(firstFive, ",") .. "）")
    res = T.cmd(boss, "adminPlayers", { query = "bob" })
    check(res == nil, "500 ms 內重送：丟掉、不回覆")
    T.advance(600)
    res = T.cmd(boss, "adminPlayers", { query = "BOB" })
    check(res.ok and res.total == 1 and res.rows[1].name == "Bob", "關鍵字不分大小寫")
    T.advance(600)
    res = T.cmd(boss, "adminPlayers", { query = "p1", page = 2 })
    check(res.ok and res.total == 21 and res.pages == 1 and res.page == 1 and res.rows[1].name == "p100",
        "子字串比對；頁碼超過最後一頁回最後一頁")
    T.advance(600)
    res = T.cmd(boss, "adminPlayers", { page = 99 })
    check(res.page == 3 and #res.rows == 25 and res.rows[25].name == "p120", "頁碼 99 → 第 3 頁")
    T.advance(600)
    res = T.cmd(boss, "adminPlayers", { query = "zzz", page = 4 })
    check(res.ok and res.total == 0 and res.page == 1 and res.pages == 1 and #res.rows == 0, "空結果")
    T.advance(600)
    res = T.cmd(boss, "adminPlayers", { filter = "owners" })
    local r1 = res.rows[1]
    check(res.total == 1 and r1.name == "Frank" and r1.used == 1 and r1.free == 1 and r1.override == -1, "有安全屋：已用／上限")
    T.advance(600)
    res = T.cmd(boss, "adminPlayers", { filter = "overrides" })
    r1 = res.rows[1]
    check(res.total == 1 and r1.name == "erin" and r1.used == 0 and r1.free == 2 and r1.override == 2, "有自訂上限")
    T.advance(600)
    res = T.cmd(boss, "adminPlayers", { filter = "nope" })
    check(res.code == "BAD_ARGS", "未知篩選：BAD_ARGS")
    local realSort = MSH.sortSafe
    local sorts = 0
    MSH.sortSafe = function(l, f) sorts = sorts + 1 return realSort(l, f) end
    R.setBinding("bea", 76561198000200000, "TEST", T.now)
    mk(MSH, { x = 200, y = 200, w = 5, h = 5 }, "Zed", { noNative = true })
    T.advance(600)
    res = T.cmd(boss, "adminPlayers", {})
    T.advance(600)
    local res2 = T.cmd(boss, "adminPlayers", { query = "e" })
    MSH.sortSafe = realSort
    check(sorts == 0, "新名字插入、查詢都不呼叫排序（實際 " .. sorts .. " 次）")
    check(res.total == 127 and res.rows[2].name == "bea" and res2.ok, "新名字插在正確位置")
    local list, ordered = MSH.Admin.names.list, true
    for i = 2, #list do
        local a, b = list[i - 1], list[i]
        if a.lower > b.lower or (a.lower == b.lower and a.name > b.name) then ordered = false end
    end
    check(ordered and list[#list].name == "Zed", "插入後整份名單仍照小寫名字排序")

    T.section("Admin：玩家列附自己的屋")
    local g1 = mk(MSH, { x = 300, y = 300, w = 5, h = 5 }, "Gina")
    local g2 = mk(MSH, { x = 320, y = 300, w = 5, h = 5 }, "Gina")
    T.advance(600)
    res = T.cmd(boss, "adminPlayers", { query = "gina" })
    local cl = res.rows[1] and res.rows[1].claims or {}
    check(res.total == 1 and #cl == 2 and cl[1].claimId == g1.claimId and cl[2].claimId == g2.claimId
        and cl[1].tier == 1 and cl[1].revision == g1.revision and cl[1].lifecycle == g1.lifecycle and cl[1].title == "t",
        "有屋的玩家列出自己的屋（claimId、title、revision、lifecycle、tier）")
    T.advance(600)
    res = T.cmd(boss, "adminPlayers", { query = "zed" })
    cl = res.rows[1] and res.rows[1].claims or {}
    check(#cl == 1 and cl[1].claimId ~= g1.claimId and cl[1].claimId ~= g2.claimId, "別人的屋不混入")
    res = T.cmd(boss, "adminRelease", { claimId = g1.claimId })
    check(res.ok, "代為放棄 Gina 的第一間")
    T.advance(600)
    res = T.cmd(boss, "adminPlayers", { query = "gina" })
    cl = res.rows[1] and res.rows[1].claims or {}
    check(#cl == 1 and cl[1].claimId == g2.claimId, "放棄後下一次查詢不再列出（索引隨 registry generation 失效）")

    T.section("Admin：個人上限")
    res = T.cmd(boss, "adminSetOverride", { targetUsername = "erin", n = 3 })
    check(res.ok and R.override("erin") == 3 and T.logged("ADMIN_OVERRIDE"), "設定個人上限並寫 audit")
    MSH = T.boot({ keepFiles = true })
    check(MSH.Registry.override("erin") == 3, "重開後個人上限還在")
    boss = T.player({ name = "boss", admin = true })
    res = T.cmd(boss, "adminSetOverride", { targetUsername = "erin", n = -1 })
    check(res.ok and MSH.Registry.override("erin") == nil, "-1 刪除個人上限")
    MSH = T.boot({ keepFiles = true })
    check(MSH.Registry.override("erin") == nil, "重開後刪除仍有效")
    boss = T.player({ name = "boss", admin = true })
    T.failWrites = true
    res = T.cmd(boss, "adminSetOverride", { targetUsername = "erin", n = 5 })
    check(res.code == "SAVE_FAILED" and MSH.Registry.override("erin") == nil, "寫檔失敗：SAVE_FAILED")
    T.failWrites = false
    res = T.cmd(boss, "adminSetOverride", { targetUsername = "erin", n = -2 })
    check(res.code == "BAD_ARGS", "上限小於 -1：BAD_ARGS")

    T.section("Admin：代為放棄")
    MSH = T.boot()
    boss = T.player({ name = "boss", admin = true })
    alice = T.player({ name = "alice" })
    local rec = mk(MSH, { x = 100, y = 100, w = 5, h = 5 }, "alice")
    res = T.cmd(alice, "adminRelease", { claimId = rec.claimId })
    check(res.code == "NOT_ADMIN" and rec.lifecycle == "active", "非管理員：NOT_ADMIN")
    res = T.cmd(boss, "adminRelease", { claimId = rec.claimId, expectedRevision = rec.revision + 5 })
    check(res.code == "STALE_REVISION" and rec.lifecycle == "active", "revision 不符：STALE_REVISION")
    res = T.cmd(boss, "adminRelease", { claimId = rec.claimId, expectedRevision = rec.revision })
    check(res.ok and rec.lifecycle == "released" and rec.releaseReason == "ADMIN_RELEASE"
        and T.houseOf(MSH.marker(rec.claimId)) == nil, "代為放棄：原生移除")
    check(MSH.Registry.get(rec.claimId) == nil and MSH.Registry.tomb(rec.claimId) ~= nil, "代為放棄：紀錄換成 tombstone")
    check(#T.broadcastsOf("nativeRemove") == 1 and T.logged("ADMIN_RELEASE"), "送 remove delta、寫 audit")
    res = T.cmd(boss, "adminRelease", { claimId = rec.claimId })
    check(res.code == "WRONG_LIFECYCLE", "已放棄（只剩 tombstone）：WRONG_LIFECYCLE")
    res = T.cmd(boss, "adminRecover", { claimId = rec.claimId, action = "release" })
    check(res.code == "WRONG_LIFECYCLE", "recover 已放棄的：WRONG_LIFECYCLE")
    res = T.cmd(boss, "adminRelease", { claimId = 999 })
    check(res.code == "NOT_FOUND", "不存在：NOT_FOUND")

    T.section("Admin：targeted recovery")
    local act = mk(MSH, { x = 300, y = 300, w = 5, h = 5 }, "alice")
    res = T.cmd(boss, "adminRecover", { claimId = act.claimId, action = "release" })
    check(res.code == "WRONG_LIFECYCLE" and act.lifecycle == "active", "不是 quarantined：WRONG_LIFECYCLE")
    res = T.cmd(boss, "adminRecover", { claimId = act.claimId, action = "nope" })
    check(res.code == "BAD_ARGS", "未知動作：BAD_ARGS")
    local q1 = mk(MSH, { x = 400, y = 300, w = 5, h = 5 }, "bob", { quarantine = true })
    res = T.cmd(boss, "adminRecover", { claimId = q1.claimId, action = "release" })
    check(res.ok and q1.lifecycle == "released" and T.houseOf(MSH.marker(q1.claimId)) == nil
        and MSH.Registry.get(q1.claimId) == nil and MSH.Registry.tomb(q1.claimId) ~= nil, "recover release：原生移除、released")
    local q2 = mk(MSH, { x = 500, y = 300, w = 5, h = 5 }, "bob", { quarantine = true, noNative = true })
    res = T.cmd(boss, "adminRecover", { claimId = q2.claimId, action = "release" })
    check(res.ok and q2.lifecycle == "released" and MSH.Registry.tomb(q2.claimId) ~= nil, "recover release：沒有原生照樣 released")
    local function markerCount(id)
        local n = 0
        for _, h in ipairs(T.houses) do if h.owner == MSH.marker(id) then n = n + 1 end end
        return n
    end
    local qd = mk(MSH, { x = 900, y = 300, w = 5, h = 5 }, "bob")
    SafeHouse.addSafeHouse(920, 300, 5, 5, MSH.marker(qd.claimId))
    MSH.Registry.markQuarantined(qd, "RELEASE_DUPLICATE")
    local removes0 = #T.broadcastsOf("nativeRemove")
    res = T.cmd(boss, "adminRecover", { claimId = qd.claimId, action = "release" })
    check(res.ok and markerCount(qd.claimId) == 0 and MSH.Registry.get(qd.claimId) == nil
        and MSH.Registry.tomb(qd.claimId) ~= nil, "recover release DUPLICATE：兩間原生都移除、寫 tombstone")
    check(#T.broadcastsOf("nativeRemove") == removes0 + 1, "recover release DUPLICATE：送一次 remove delta")
    -- recovered：有 marker native、無 owner、沒有指紋
    local q3, h3 = mk(MSH, { x = 600, y = 300, w = 5, h = 5 }, nil, { quarantine = true })
    q3.nativeCreatedAt, q3.recovered, q3.candidates = nil, true, { "oldmember" }
    h3:addPlayer("oldmember")
    res = T.cmd(boss, "adminRecover", { claimId = q3.claimId, action = "rebind" })
    check(res.code == "BAD_USER" and q3.lifecycle == "quarantined", "owner 不明又沒給 targetUsername：BAD_USER")
    local syncs0 = #T.syncs
    T.advance(1000)
    res = T.cmd(boss, "adminRecover", { claimId = q3.claimId, action = "rebind", targetUsername = "gina" })
    check(res.ok and q3.lifecycle == "active" and q3.owner == "gina" and q3.nativeCreatedAt == h3.created,
        "rebind：轉 active、採用原生的建立時間當指紋")
    check(h3.players:contains("gina") and not h3.players:contains("oldmember"), "rebind：原生名單修成紀錄應有的人")
    check(q3.recovered == nil and q3.candidates == nil and q3.quarantineReason == nil, "rebind：清掉 recovered 標記")
    check(#T.syncs == syncs0 + 1 and T.logged("ADMIN_RECOVER"), "rebind：廣播一次、寫 audit")
    local q4 = mk(MSH, { x = 700, y = 300, w = 5, h = 5 }, "hank", { quarantine = true, noNative = true })
    SafeHouse.addSafeHouse(710, 300, 5, 5, MSH.marker(q4.claimId))
    res = T.cmd(boss, "adminRecover", { claimId = q4.claimId, action = "rebind" })
    check(res.code == "WRONG_LIFECYCLE" and q4.lifecycle == "quarantined", "rebind：同標記原生 rect 不同 → 留在 quarantined")
    res = T.cmd(boss, "adminRecover", { claimId = q4.claimId, action = "release" })
    check(res.ok and markerCount(q4.claimId) == 0 and MSH.Registry.tomb(q4.claimId) ~= nil,
        "recover release MISMATCH：rect 不同的原生也移除")
    local q5 = mk(MSH, { x = 800, y = 300, w = 5, h = 5 }, "hank", { quarantine = true, noNative = true })
    res = T.cmd(boss, "adminRecover", { claimId = q5.claimId, action = "rebind" })
    local h5 = T.houseOf(MSH.marker(q5.claimId))
    check(res.ok and q5.lifecycle == "active" and h5 ~= nil and q5.nativeCreatedAt == h5.created and q5.owner == "hank",
        "rebind：沒有原生 → 照紀錄重建")

    T.section("Admin：malformed、recovered 與 adminClaims")
    MSH = T.boot()
    R = MSH.Registry
    local good = mk(MSH, { x = 100, y = 500, w = 5, h = 5 }, "alice")
    local lapsed = mk(MSH, { x = 200, y = 500, w = 5, h = 5 }, "alice", { lifecycle = "lapsed", noNative = true })
    local badId = R.allocId()
    R.md.claims[badId] = { claimId = badId, lifecycle = "active", owner = "ivy" }   -- 缺 rect
    SafeHouse.addSafeHouse(900, 500, 5, 5, MSH.marker(badId))
    SafeHouse.addSafeHouse(1000, 500, 5, 5, MSH.marker(77)):addPlayer("dave")      -- 有標記沒紀錄
    -- Economy FAILED：手放的 lapsed 紀錄不被 Economy 恢復（沒裝＝ABSENT 會全部恢復，§1.3）
    MSH = T.boot({ keepGmd = true, keepFiles = true, keepHouses = true,
        beforeStart = function() T.economy({ failRegister = true }) end })
    R = MSH.Registry
    boss = T.player({ name = "boss", admin = true })
    alice = T.player({ name = "alice" })
    check(R.get(badId).malformed == true and R.get(77) ~= nil and R.get(77).quarantineReason == "RECOVERED",
        "前置：開服轉成 malformed 與 recovered")
    res = T.cmd(alice, "adminClaims", {})
    check(res.code == "NOT_ADMIN", "adminClaims 非管理員：NOT_ADMIN")
    res = T.cmd(boss, "adminClaims", {})
    local rows = {}
    for _, row in ipairs(res.claims or {}) do rows[row.claimId] = row end
    check(res.ok and rows[good.claimId] == nil and #res.claims == 3, "adminClaims：只列不是 active 的")
    check(rows[badId] and rows[badId].lifecycle == "quarantined" and rows[badId].quarantineReason == "MALFORMED"
        and rows[badId].rect == nil and rows[badId].owner == "ivy", "adminClaims：malformed（沒有 rect）")
    check(rows[77] and rows[77].quarantineReason == "RECOVERED" and rows[77].owner == nil and rows[77].rect.x == 1000
        and rows[77].candidates[1] == "dave", "adminClaims：recovered 附 rect 與候選")
    check(rows[lapsed.claimId] and rows[lapsed.claimId].lifecycle == "lapsed", "adminClaims：lapsed")
    res = T.cmd(boss, "adminRecover", { claimId = badId, action = "rebind", targetUsername = "ivy" })
    check(res.code == "WRONG_LIFECYCLE" and res.reason == "MALFORMED", "malformed 不能 rebind")
    local removes1 = #T.broadcastsOf("nativeRemove")
    T.advance(1000)
    local recoverAt = T.now
    res = T.cmd(boss, "adminRecover", { claimId = badId, action = "release" })
    check(res.ok and T.houseOf(MSH.marker(badId)) == nil and R.get(badId) == nil and R.tomb(badId) ~= nil
        and #T.broadcastsOf("nativeRemove") == removes1 + 1, "recover release malformed：原生移除、tombstone、remove delta")
    res = T.cmd(boss, "adminOptions", {})
    local lr = res.health.lastRecovery
    check(lr ~= nil and lr.claimId == badId and lr.action == "release" and lr.code == "OK"
        and lr.at >= recoverAt and lr.at < T.now, "health：最後一次 recovery（claimId、動作、結果、時間）")
    check(res.health.suppressed == MSH.Audit.suppressed and type(res.health.suppressed) == "number",
        "health：被節流壓下的 audit 數")
    if MSH.Reconcile and MSH.Reconcile.health then
        local h = MSH.Reconcile.health()
        check(res.health.pendingRepair == h.pendingRepair and res.health.lastSuccessAt == h.lastSuccessAt,
            "health：併入 Reconcile.health()")
    end
    local realHealth = MSH.Reconcile and MSH.Reconcile.health
    MSH.Reconcile = MSH.Reconcile or {}
    MSH.Reconcile.health = function() return { lastSuccessAt = 123, pendingRepair = 2, longestDriftMs = 456, interference = 1 } end
    res = T.cmd(boss, "adminOptions", {})
    MSH.Reconcile.health = realHealth
    check(res.health.lastSuccessAt == 123 and res.health.pendingRepair == 2 and res.health.longestDriftMs == 456
        and res.health.interference == 1 and res.health.blocked == false, "health：Reconcile.health 欄位照抄進 health")
    res = T.cmd(boss, "adminRecover", { claimId = 77, action = "rebind", targetUsername = "dave" })
    check(res.ok and R.get(77).lifecycle == "active" and R.get(77).owner == "dave", "recovered rebind 給候選人")
    res = T.cmd(boss, "adminOptions", {})
    check(res.health.lastRecovery.claimId == 77 and res.health.lastRecovery.action == "rebind", "lastRecovery 換成最新一次")
    res = T.cmd(boss, "adminClaims", {})
    check(#res.claims == 1 and res.claims[1].claimId == lapsed.claimId, "處理完只剩 lapsed")

    T.section("Calibrate：伺服器回應校正")
    MSH = T.boot()
    alice = T.player({ name = "alice" })
    local a = mk(MSH, { x = 100, y = 100, w = 5, h = 5 }, "alice")
    local rl = mk(MSH, { x = 200, y = 100, w = 5, h = 5 }, "alice")
    MSH.Lifecycle.release(rl, "RELEASED", "op-1", T.now)
    local q = mk(MSH, { x = 300, y = 100, w = 5, h = 5 }, "alice", { quarantine = true })
    local lp = mk(MSH, { x = 400, y = 100, w = 5, h = 5 }, "alice", { lifecycle = "lapsed", noNative = true })
    local function house(id, x) return { claimId = id, x = x, y = 100, w = 5, h = 5 } end
    local report = { house(rl.claimId, 200), house(q.claimId, 300), house(lp.claimId, 400), house(999, 900), house(888, 1000) }
    SafeHouse.addSafeHouse(1000, 100, 5, 5, MSH.marker(888))   -- 沒有紀錄的孤兒（開服才轉 recovered）
    local syncsC = #T.syncs
    res = T.cmd(alice, "calibrate", { houses = report })
    local removed = {}
    for _, id in ipairs(res.remove or {}) do removed[id] = true end
    check(res.ok and removed[rl.claimId] and removed[lp.claimId] and removed[999], "released、lapsed、沒有紀錄 → 移除")
    check(not removed[q.claimId] and not removed[a.claimId], "quarantined 保留")
    check(not removed[888], "沒有紀錄但伺服器有這個標記的原生（孤兒）：保留")
    check(res.bootId == MSH.Native.bootId and res.seq == MSH.Native.seq, "回覆附目前 bootId／seq")
    check(#T.syncs == syncsC + 1 and T.syncs[#T.syncs].owner == MSH.marker(a.claimId), "客戶端缺少 active → 廣播一次")
    res = T.cmd(alice, "calibrate", { houses = report })
    check(res == nil, "5 秒內重送：丟掉、不回覆")
    T.advance(6000)
    res = T.cmd(alice, "calibrate", { houses = report })
    check(res ~= nil and res.ok and #T.syncs == syncsC + 1, "10 秒內再次回報缺少：不再廣播")
    T.advance(5000)
    res = T.cmd(alice, "calibrate", { houses = report })
    check(res.ok and #T.syncs == syncsC + 2, "超過 10 秒：再廣播一次")
    T.advance(6000)
    res = T.cmd(alice, "calibrate", { houses = { { claimId = 1, x = 0, y = 0, w = 1, h = 1, extra = 1 } } })
    check(res ~= nil and res.code == "BAD_ARGS", "多出欄位：BAD_ARGS")

    T.section("Calibrate：一次校正的廣播上限")
    MSH = T.boot()
    alice = T.player({ name = "alice" })
    for i = 1, 6 do mk(MSH, { x = 100 * i, y = 700, w = 5, h = 5 }, "alice") end
    local dq = mk(MSH, { x = 800, y = 700, w = 5, h = 5 }, "alice", { quarantine = true })
    SafeHouse.addSafeHouse(900, 700, 5, 5, MSH.marker(dq.claimId))
    syncsC = #T.syncs
    res = T.cmd(alice, "calibrate", { houses = {} })
    local cap = MSH.LIMIT.CALIBRATE_UPSERTS
    check(res.ok and #T.syncs - syncsC == cap, "空清單：最多 " .. cap .. " 次廣播（實際 " .. (#T.syncs - syncsC) .. "）")
    T.advance(6000)
    syncsC = #T.syncs
    res = T.cmd(alice, "calibrate", { houses = {} })
    check(res.ok and #T.syncs - syncsC == cap, "下一次校正：補上剩下的（實際 " .. (#T.syncs - syncsC) .. "）")
    local seen = {}
    for _, s in ipairs(T.syncs) do seen[s.owner] = (seen[s.owner] or 0) + 1 end
    local all = true
    for id = 1, dq.claimId do if (seen[MSH.marker(id)] or 0) == 0 then all = false end end
    check(all and seen[MSH.marker(dq.claimId)] == 2, "兩次合計涵蓋全部 7 間（重複標記的兩間都廣播）")
end
