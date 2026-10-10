-- 基礎模組：Contract、Settings、Registry（含私有儲存）、Health、Identity、Native、指令分派。
return function(T)
    local check = T.check

    T.section("Contract：矩形、標題、標記、排序")
    local MSH = T.boot()
    local Rect = MSH.Rect
    local r = Rect.fromCorners(10, 20, 5, 22)
    check(r.x == 5 and r.y == 20 and r.w == 6 and r.h == 3, "兩個 inclusive 角格轉成半開矩形")
    local a = { x = 0, y = 0, w = 10, h = 10 }
    check(not Rect.overlaps(a, { x = 10, y = 0, w = 5, h = 5 }, 0), "半開：右邊界相鄰不算重疊")
    check(Rect.overlaps(a, { x = 9, y = 9, w = 5, h = 5 }, 0), "角落一格重疊")
    check(Rect.overlaps(a, { x = 11, y = 0, w = 5, h = 5 }, 2), "間距 2：差 1 格算太近")
    check(not Rect.overlaps(a, { x = 12, y = 0, w = 5, h = 5 }, 2), "間距 2：差 2 格不算")
    check(Rect.containsPoint(a, 9.9, 0.1) and not Rect.containsPoint(a, 10.0, 5), "人在格內以 floor 判斷，右界不含")
    check(not Rect.valid({ x = -1, y = 0, w = 5, h = 5 }), "負座標不合法（onlineId 會撞號）")
    check(not Rect.valid({ x = 0, y = 0, w = 0 / 0, h = 5 }), "NaN 不合法")
    check(MSH.cleanTitle("  我的家  ") == "我的家", "標題去頭尾空白")
    check(MSH.cleanTitle("a[b]") == nil and MSH.cleanTitle("a\nb") == nil, "標題拒絕 [] 與控制字元")
    check(MSH.cleanTitle(string.rep("x", 41)) == nil and MSH.cleanTitle(string.rep("x", 40)) ~= nil, "標題上限 40")
    check(MSH.claimIdOf(MSH.marker(42)) == 42 and MSH.claimIdOf("alice") == nil and MSH.claimIdOf("@MSH:x") == nil,
        "service-owner 標記往返")
    check(MSH.tierOfDeed("MinidoracatSafehouse.Deed3") == 3 and MSH.tierOfDeed("MinidoracatSafehouse.Deed9") == nil,
        "地契等級只由 full type 決定")
    local list = {}
    for i = 1, 300 do list[i] = { k = i % 3, i = i } end
    MSH.sortSafe(list, function(x, y) return x.k < y.k end)
    local stable = true
    for i = 2, #list do
        if list[i - 1].k == list[i].k and list[i - 1].i > list[i].i then stable = false end
    end
    check(stable and list[1].k == 0 and list[300].k == 2, "sortSafe 穩定、300 筆不遞迴")
    check(MSH.hasBit(5, 4) and not MSH.hasBit(5, 2) and MSH.hasBit(MSH.SHARE_LEGACY, MSH.SHARE.FARM), "權限位元測試")

    T.section("Settings：80 個選項、讀取夾值、面板整批驗證")
    local Settings = MSH.Settings
    check(#Settings.OPTIONS == 80, "沙盒選項 80 個（實際 " .. #Settings.OPTIONS .. "）")
    local cfg, warn = Settings.get()
    check(#warn == 0 and cfg.claimsPerPlayer == 1 and cfg.tiersEnabled == 3, "預設值讀出無警告")
    check(cfg.roadKinds.main and cfg.roadKinds.street and not cfg.roadKinds.gravel, "道路類別預設 main;street")
    check(cfg.resourceCats.military and cfg.resourceCats.prison and not cfg.resourceCats.food, "資源類別預設 8 類")
    check(cfg.tiers[1].side == 24 and cfg.tiers[2].area == 1600 and cfg.tiers[8].side == 64, "各級預設大小")
    check(cfg.tiers[1].craft == 3 and cfg.tiers[2].craft == 1 and cfg.tiers[1].free and not cfg.tiers[1].buy,
        "製作與名額開關預設")
    T.sandbox("ClaimGap", 99)
    T.sandbox("Tier1Area", 9000)
    T.sandbox("RoadKinds", "main;lava")
    cfg, warn = Settings.get()
    check(cfg.claimGap == 16 and cfg.tiers[1].area == 576, "超出範圍夾回、面積不超過邊長平方")
    check(#warn == 3, "三個不合法值各記一筆警告（實際 " .. #warn .. "）")
    T.resetSandbox()
    local ok, key, why = Settings.validateChanges({ Tier1Side = 10, Tier1Area = 200 })
    check(not ok and key == "Tier1Area" and why == "AREA_OVER_SIDE", "面板：面積大於邊長平方整批拒絕")
    ok, key = Settings.validateChanges({ Nope = 1 })
    check(not ok and key == "Nope", "面板：未知鍵拒絕")
    ok = Settings.validateChanges({ ClaimGap = 17 })
    check(not ok, "面板：超出範圍不夾值、直接拒絕")
    ok = Settings.validateChanges({ ClaimGap = 4, RoadKinds = "main;gravel", Tier2LootChance = 2.5 })
    check(ok, "面板：合法的多欄變更通過")

    T.section("Registry：建立、壞紀錄隔離、schema 太新唯讀")
    local R = MSH.Registry
    check(R.ready() and R.md.nextClaimId == 1 and R.md.bootSeq == 1, "全新 registry、第一次開服 bootSeq=1")
    local id = R.allocId()
    R.put(R.newRecord({ claimId = id, rect = { x = 100, y = 100, w = 10, h = 10 }, title = "A", owner = "alice",
        source = MSH.SOURCE.DEED, deedTier = 1, createdAt = T.now }))
    R.md.claims[7] = { claimId = 7, lifecycle = "active" }   -- 缺欄位
    MSH = T.boot({ keepGmd = true, keepFiles = true })
    R = MSH.Registry
    check(R.get(1) ~= nil and R.get(1).lifecycle == "active", "合法紀錄重開後保留")
    check(R.get(7) ~= nil and R.get(7).lifecycle == "quarantined", "壞紀錄轉 quarantined、不刪")
    check(R.md.nextClaimId == 8, "nextClaimId 抬到現有最大 id＋1（實際 " .. tostring(R.md.nextClaimId) .. "）")
    check(R.md.bootSeq == 2, "第二次乾淨開服 bootSeq=2")
    T.gmd[MSH.TAG].schemaVersion = 99
    MSH = T.boot({ keepGmd = true })
    check(MSH.Registry.readOnly and MSH.Health.blocked(), "schema 比程式新：registry 唯讀、health blocked")
    check(T.gmd[MSH.TAG].schemaVersion == 99, "唯讀時不改寫 schemaVersion")

    T.section("Registry：私有儲存（個人上限、綁定）")
    MSH = T.boot()
    R = MSH.Registry
    check(R.setOverride("alice", 3) and R.setBinding("bob", 76561198000000016, "NEWGAME", T.now), "寫入個人上限與綁定")
    check(R.setOverride("alice", nil), "刪除個人上限")
    check(R.setOverride("carol", 0), "個人上限可設 0")
    local path = R.privatePath()
    T.files[path].lines[#T.files[path].lines + 1] = "garbage\tline"
    MSH = T.boot({ keepFiles = true })
    R = MSH.Registry
    check(R.override("alice") == nil and R.override("carol") == 0, "重開後個人上限照最後一行")
    check(R.binding("bob") ~= nil and R.binding("bob").sid == 76561198000000016, "重開後綁定的 SteamID 數值不變")
    check(R.privateBad == 1, "壞行略過並計數")
    T.failWrites = true
    check(not R.setOverride("dave", 2) and R.override("dave") == nil, "寫檔失敗就不改記憶體")
    MSH = T.boot({ keepFiles = true, beforeStart = function(env) env.unreadable[path] = true end })
    check(MSH.Registry.privateUnreadable and MSH.Health.blocked(), "私有檔存在卻讀不開：fail closed、health blocked")

    T.section("Health：設定矩陣")
    MSH = T.boot()
    local H = MSH.Health
    check(not H.blocked(), "預設測試設定通過")
    T.serverOptions.SafehouseAllowTrepass = "true"
    H.evaluate(T.now)
    check(H.blocked() and H.state.blockers[1] == "SafehouseAllowTrepass", "SafehouseAllowTrepass=true 進 blocked")
    T.serverOptions.SafehouseAllowTrepass = "false"
    T.serverOptions.AntiCheatSafeHouse = "4"
    H.evaluate(T.now)
    check(H.blocked(), "AntiCheatSafeHouse=4（關閉閘門）進 blocked")
    T.serverOptions.AntiCheatSafeHouse = "3"
    T.serverOptions.AllowCoop = "true"
    T.serverOptions.SaveWorldEveryMinutes = "0"
    H.evaluate(T.now)
    check(not H.blocked() and #H.state.warnings == 2, "AllowCoop、SaveWorldEveryMinutes=0 只是警告")
    check(T.logged("HEALTH_BLOCKED"), "進 blocked 寫 audit")

    T.section("Identity：principal、綁定、改名證據、身分異常")
    MSH = T.boot()
    local I = MSH.Identity
    local alice = T.player({ name = "alice", sid = 76561198000000016 })
    local seat2 = T.player({ name = "guest", num = 1 })
    check(I.principal(alice) == "alice" and I.principal(seat2) == nil, "非 Steam：主玩家回名字、分割畫面次玩家沒有身分")
    T.steam = true
    check(I.principal(alice) == "alice", "Steam、還沒綁定：回名字（匯入前照 VehicleManager）")
    I.onNewGame(alice)
    check(MSH.Registry.binding("alice") ~= nil, "OnNewGame 綁定登入名")
    alice.sid = 76561198000000032
    check(I.principal(alice) == nil, "SteamID 不符：沒有身分")
    alice.sid = 76561198000000016
    local mallory = T.player({ name = "mallory", sid = 76561198000000048 })
    I.onNewGame(mallory)                        -- mallory 的 Steam 帳號剛建過角色
    MSH.Registry.bindings["mallory"] = nil      -- 模擬另一個名字（下面改名）
    mallory.name = "victim"
    local okBind, why2 = I.bindForClaim(mallory, T.now)
    check(not okBind and why2 == "RENAME_EVIDENCE", "同一 SteamID 兩分鐘內以別的名字建過角色：拒絕綁定")
    check(MSH.Registry.binding("victim") == nil, "被拒時不寫綁定")
    local carol = T.player({ name = "carol", sid = 76561198000000064 })
    check(I.bindForClaim(carol, T.now) and MSH.Registry.binding("carol").src == "CLAIM", "乾淨的座位：建立時綁定建立者")
    T.steam = false
    T.player({ name = "@MSH:1" })
    I.tick(T.now + 5000)
    check(MSH.Health.isHostile(), "在線主玩家名以 @MSH: 開頭 → hostile mode")

    T.section("Native：建立、名單、廣播、remove delta")
    MSH = T.boot()
    local N = MSH.Native
    local rec = { claimId = 5, rect = { x = 200, y = 200, w = 8, h = 6 }, title = "家", owner = "alice",
        grants = { { user = "bob", bits = 1 }, { user = "eve", bits = 2 } } }
    local hs = N.build(rec)
    check(hs ~= nil and hs.owner == "@MSH:5" and hs.title == "家", "以 service-owner 建原生安全屋")
    local names = N.players(hs)
    check(#names == 2 and names[1] == "alice" and names[2] == "bob", "名單＝屋主＋帶 MEMBER 的人（eve 沒有 MEMBER）")
    local idx = N.index()
    check(idx.byClaim[5] ~= nil and #idx.foreign == 0 and idx.count == 1, "索引依標記找到")
    check(N.matches({ rect = rec.rect, nativeCreatedAt = hs.created }, idx.byClaim[5][1]), "rect＋建立時間指紋相符")
    N.broadcast(hs)
    check(#T.syncs == 1 and T.syncs[1].owner == "@MSH:5", "service-owner 廣播")
    T.noLocation = true
    local h2, code = N.build({ claimId = 6, rect = { x = 300, y = 300, w = 5, h = 5 }, title = "x", owner = "bob", grants = {} })
    check(h2 == nil and code == MSH.CODE.NATIVE_FAILED and #T.houses == 1, "location 推不出來：不建、不留殘骸")
    T.noLocation = false
    check(N.remove(hs) and #T.houses == 0, "移除後重掃確認")
    N.sendRemove(5, rec.rect)
    local rm = T.broadcastsOf("nativeRemove")
    check(#rm == 1 and rm[1].claimId == 5 and rm[1].seq == 1 and rm[1].bootId == N.bootId, "remove delta 廣播帶 bootId 與 seq")

    T.section("分派：協定、快取、鎖、閘門")
    MSH = T.boot()
    local S = MSH.Srv
    local runs = 0
    S.define("testMut", { kind = "mutation", fields = { n = "int", note = "title?" }, run = function(ctx)
        runs = runs + 1
        ctx.defer(function() T.deferLocked = S.locked end)
        return S.ok({ n = ctx.args.n })
    end })
    S.define("testBoom", { kind = "mutation", fields = {}, run = function() error("boom") end })
    S.define("testAdmin", { kind = "mutation", admin = true, whenBlocked = true, fields = {}, run = function()
        return S.ok()
    end })
    S.define("testQuery", { kind = "query", fields = {}, run = function() return S.ok() end })
    local p = T.player({ name = "alice" })
    local res = T.cmd(p, "testMut", { n = 1 }, "abcdefgh1")
    check(res.ok and res.n == 1 and runs == 1 and T.deferLocked == false, "mutation 成功；網路送出在放鎖之後")
    res = T.cmd(p, "testMut", { n = 1 }, "abcdefgh1")
    check(res.ok and res.replay and runs == 1, "同 requestId：回快取、不再執行")
    res = T.cmd(p, "testMut", { n = 1, protocol = 99 }, "abcdefgh2")
    check(not res.ok and res.code == "PROTOCOL_MISMATCH" and res.serverProtocol == MSH.PROTOCOL, "協定版本不同")
    res = T.cmd(p, "testMut", { n = 1 }, false)
    check(res.code == "BAD_REQUEST_ID", "mutation 沒帶 requestId")
    res = T.cmd(p, "testMut", { n = 1, extra = 2 })
    check(res.code == "BAD_ARGS", "未知欄位拒絕")
    res = T.cmd(p, "testMut", { n = 0 / 0 })
    check(res.code == "BAD_ARGS", "NaN 拒絕")
    res = T.cmd(p, "testMut", { n = 1, note = string.rep("x", 200) })
    check(res.code == "BAD_ARGS", "過長字串拒絕")
    res = T.cmd(p, "nope", {})
    check(res.code == "UNKNOWN_COMMAND", "未知指令")
    res = T.cmd(p, "testBoom", {})
    check(res.code == "INTERNAL_ERROR" and S.locked == false, "handler 丟錯：INTERNAL_ERROR、鎖已釋放")
    res = T.cmd(p, "testAdmin", {})
    check(res.code == "NOT_ADMIN", "非管理員不能用管理員指令")
    T.serverOptions.War = "true"
    T.tick(6)
    res = T.cmd(p, "testMut", { n = 2 })
    check(res.code == "HEALTH_BLOCKED", "blocked：一般 mutation 拒絕")
    local admin = T.player({ name = "boss", admin = true })
    res = T.cmd(admin, "testAdmin", {})
    check(res.ok, "blocked：標了 whenBlocked 的指令照常（管理員修設定、放棄、recovery）")
    res = T.cmd(p, "testQuery", {})
    check(res.ok, "blocked：查詢照常")
    T.serverOptions.War = "false"
    T.tick(6)
    MSH.Registry.md.migrationCompleted = false
    res = T.cmd(p, "testMut", { n = 3 })
    check(res.code == "MIGRATION_IN_PROGRESS", "遷移未完成：mutation 拒絕")
    MSH.Registry.md.migrationCompleted = nil
    local spam = 0
    for i = 1, 30 do
        T.fire("OnClientCommand", MSH.MODULE, "testQuery", p, { protocol = MSH.PROTOCOL })
        spam = spam + 1
    end
    res = T.cmd(p, "testMut", { n = 4 })
    check(res.code == "RATE_LIMITED", "5 秒 20 個指令以上限流")
    T.steam = true
    MSH.Registry.bindings["mallory2"] = { sid = 1, src = "TEST", at = 0 }
    local imp = T.player({ name = "mallory2", sid = 2 })
    T.fire("OnClientCommand", MSH.MODULE, "testQuery", imp, { protocol = MSH.PROTOCOL })
    T.fire("OnClientCommand", MSH.MODULE, "testQuery", imp, { protocol = MSH.PROTOCOL })
    local unv = 0
    for _, m in ipairs(T.outbox["mallory2"]) do if m.args.code == "IDENTITY_UNVERIFIED" then unv = unv + 1 end end
    check(unv == 1, "身分不符：回 IDENTITY_UNVERIFIED，每分鐘最多一次")
    -- 未驗證的封包灌 200 個亂取的指令名：audit 只記已知指令或 UNKNOWN_COMMAND、總數受同一個 5 秒 20 個的限流、
    -- 回覆照樣每分鐘一次（2026-10-10 審查：未驗證路徑不限流、把原始指令名當 audit 鍵）
    for i = 1, 200 do
        T.fire("OnClientCommand", MSH.MODULE, "junk" .. i, imp, { protocol = MSH.PROTOCOL })
    end
    local keys, denied = 0, 0
    for key, n in pairs(MSH.Audit.denyAgg) do
        if key:sub(1, #"mallory2|") == "mallory2|" then
            keys = keys + 1
            denied = denied + n
            check(key:find("junk", 1, true) == nil, "未驗證灌包：audit 鍵不含原始指令名（" .. key .. "）")
        end
    end
    check(keys <= 2 and denied <= MSH.Srv.RATE_MAX, "未驗證灌包：audit 鍵 " .. keys .. " 個、計數 " .. denied .. "（上限 "
        .. MSH.Srv.RATE_MAX .. "）")
    unv = 0
    for _, m in ipairs(T.outbox["mallory2"]) do if m.args.code == "IDENTITY_UNVERIFIED" then unv = unv + 1 end end
    check(unv == 1, "未驗證灌包：回覆仍是每分鐘一次")
    T.steam = false
    T.mode = "client"
    MSH.Srv.enabled = MSH.Health.dedicated()
    T.mode = "server"
    check(MSH.Srv.enabled == false, "不是專用伺服器時 dispatcher 停用")

    T.section("Lifecycle：放棄與重建")
    MSH = T.boot()
    local R2, L = MSH.Registry, MSH.Lifecycle
    local function mk(rect, owner)
        local rid = R2.allocId()
        local rr = R2.newRecord({ claimId = rid, rect = rect, title = "t", owner = owner, source = MSH.SOURCE.DEED,
            deedTier = 1, createdAt = T.now })
        local house = MSH.Native.build(rr)
        rr.nativeCreatedAt = house:getDatetimeCreated()
        R2.put(rr)
        return rr, house
    end
    local rec1 = mk({ x = 50, y = 50, w = 5, h = 5 }, "alice")
    local rev = rec1.revision
    local sent = {}
    local okRel = L.release(rec1, "RELEASED", "op-1", T.now, function(fn) sent[#sent + 1] = fn end)
    check(okRel and rec1.lifecycle == "released" and #T.houses == 0, "放棄：原生移除、寫 tombstone")
    check(#T.broadcastsOf("nativeRemove") == 0 and #sent == 1, "remove delta 排到 defer，不在鎖內送")
    sent[1]()
    check(#T.broadcastsOf("nativeRemove") == 1 and rec1.revision > rev, "defer 送出 remove delta；revision 增加")
    local rec2, house2 = mk({ x = 70, y = 70, w = 5, h = 5 }, "bob")
    T.failHouseRemove = true
    local okRel2, code2 = L.release(rec2, "RELEASED", "op-2", T.now)
    check(not okRel2 and code2 == "RELEASE_FAILED" and rec2.lifecycle == "quarantined", "原生移除失敗：quarantined、不假成功")
    T.failHouseRemove = false
    MSH.Native.remove(house2)
    local rec3, house3 = mk({ x = 90, y = 90, w = 5, h = 5 }, "carol")
    MSH.Native.remove(house3)
    local gen, rev3 = R2.md.generation, rec3.revision
    T.advance(1000)
    local rebuilt = L.rebuild(rec3)
    check(rebuilt ~= nil and rec3.nativeCreatedAt == rebuilt.created and rec3.revision == rev3 and R2.md.generation > gen,
        "重建：新的建立時間、generation 增加、revision 不變")
    MSH.Native.remove(rebuilt)
    SafeHouse.addSafeHouse(92, 92, 3, 3, "stranger")
    local none, why3 = L.rebuild(rec3)
    check(none == nil and why3 == "OVERLAP", "和 foreign 原生安全屋重疊：不重建")

    -- §4.2 出貨閘門：M1 schema 每個欄位都填到上限，255 間佔位紀錄＋1,024 筆 tombstone 時，第 256 間的大小檢查
    -- （Claims.lua 的 REGISTRY_FULL）不能先擋，該由 SERVER_FULL 收尾。harness 的 #s 是 UTF-8 bytes，中文標題估算比
    -- Kahlua（UTF-16 單位）再高 3 倍，所以這裡過了遊戲裡一定過。grants 只有遷移進來的舊屋才有，M2 分享另算（open-issues）。
    T.section("Registry：最壞情況放得進 256 KiB")
    MSH = T.boot()
    local R4, LIM = MSH.Registry, MSH.LIMIT
    local cjk = string.rep("安", LIM.TITLE_CHARS)
    local function worst()
        local id = R4.allocId()
        local name = ("p" .. id .. string.rep("x", LIM.USERNAME_CHARS)):sub(1, LIM.USERNAME_CHARS)
        local rr = R4.newRecord({ claimId = id, rect = { x = 19999, y = 19999, w = LIM.HARD_SIDE, h = LIM.HARD_SIDE },
            title = cjk, owner = name, source = MSH.SOURCE.DEED, deedTier = MSH.MAX_TIER,
            createdAt = 1791635924113, nativeCreatedAt = 1791635924113 })
        rr.redraws = LIM.REDRAWS_PER_CLAIM
        return rr
    end
    for _ = 1, LIM.TOMBSTONE_SOFT do
        local rr = worst()
        R4.put(rr)
        R4.markReleased(rr, "REDRAWN", 1791635924113)
    end
    for _ = 1, LIM.MAX_CLAIMS - 1 do R4.put(worst()) end
    local bytes = R4.estimateBytes(worst())
    check(R4.tombstoneCount() == LIM.TOMBSTONE_SOFT and R4.liveCount() == LIM.MAX_CLAIMS - 1
        and bytes <= LIM.REGISTRY_BYTES,
        "255 間＋1,024 筆 tombstone：第 256 間不撞 REGISTRY_FULL（估算 " .. bytes .. " / " .. LIM.REGISTRY_BYTES .. " bytes）")
end
