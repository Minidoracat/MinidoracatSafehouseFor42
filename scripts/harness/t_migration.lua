-- Migration：M0 migration contract spike（3 筆 legacy 匯入 → 重開核對 → 刪一筆原生再開 → 該筆 quarantined）。
return function(T)
    local check = T.check
    local RESTART = { keepGmd = true, keepFiles = true, keepHouses = true }

    local function defineMutation(MSH)
        MSH.Srv.define("testMutation", { kind = "mutation", fields = {}, run = function() return MSH.Srv.ok() end })
    end
    -- Better Safehouse 留下的原生：owner 是真名，成員在 players（addSafeHouse 的 setOwner 已把 owner 移出，SafeHouse.java:68-85）
    local function legacy(x, owner, title, members)
        local hs = SafeHouse.addSafeHouse(x, x, 6, 6, owner)
        hs:setTitle(title)
        for _, u in ipairs(members) do hs:addPlayer(u) end
        return { rect = { x = x, y = x, w = 6, h = 6 }, owner = owner, title = title, members = members,
            hash = "h" .. x }, hs
    end
    local function fixture()
        local items, houses = {}, {}
        items[1], houses[1] = legacy(100, "alice", "A", { "bob", "carol" })
        items[2], houses[2] = legacy(200, "bob", "B", { "alice" })
        items[3], houses[3] = legacy(300, "carol", "C", {})
        return items, houses
    end
    local function countLogs(fragment)
        local n = 0
        for _, line in ipairs(T.logs) do if string.find(line, fragment, 1, true) then n = n + 1 end end
        return n
    end

    T.section("匯入 3 筆 legacy")
    local MSH = T.boot()
    local R, Mg = MSH.Registry, MSH.Migration
    local items, houses = fixture()
    local sends = {}
    local out = Mg.importLegacy(items, T.now, function(fn) sends[#sends + 1] = fn end)
    check(#out.imported == 3 and #out.skipped == 0, "3 筆都匯入")
    local r1 = R.get(out.imported[1].claimId)
    check(r1.source == "legacy" and r1.deedTier == 1 and r1.owner == "alice" and r1.title == "A"
        and r1.lifecycle == "active" and r1.nativeCreatedAt == houses[1].created, "紀錄：legacy、owner、title、原生指紋")
    check(#r1.grants == 2 and r1.grants[1].user == "bob" and r1.grants[1].bits == MSH.SHARE_LEGACY
        and r1.grants[2].user == "carol", "成員轉 grants（SHARE_LEGACY），不含屋主")
    local allMarked = true
    for i, hs in ipairs(houses) do
        local id = out.imported[i].claimId
        if hs.owner ~= MSH.marker(id) or not hs.players:contains(items[i].owner) or hs.players:contains(MSH.marker(id)) then
            allMarked = false
        end
    end
    check(allMarked and houses[1].players:contains("bob") and houses[1].players:contains("carol"),
        "原生 owner 換成標記、原屋主與成員在 players")
    check(R.md.migrationCompleted == false, "匯入後 migrationCompleted=false（遷移中）")
    local path = Mg.manifestPath()
    check(path == "MinidoracatSafehouse/servertest/migration-completion.txt" and #T.files[path].lines == 3
        and T.files[path].lines[1] == "h100\t" .. out.imported[1].claimId .. "\t" .. tostring(R.md.migrationGen)
        and R.md.migrationGen ~= nil, "completion manifest：hash<TAB>claimId<TAB>代號（registry 同一代號），與私有檔同目錄")
    check(#T.syncs == 0 and #sends == 3, "廣播排到 defer")
    for _, fn in ipairs(sends) do fn() end
    check(#T.syncs == 3, "defer 送出 3 次 upsert 廣播")
    local p = T.player({ name = "alice" })
    defineMutation(MSH)
    local res = T.cmd(p, "testMutation", {})
    check(res and res.code == "MIGRATION_IN_PROGRESS", "核對前 mutation 回 MIGRATION_IN_PROGRESS")

    T.section("冪等：再匯入一次不重複")
    local again = Mg.importLegacy(items, T.now)
    check(#again.imported == 0 and #again.skipped == 3 and again.skipped[1].reason == "ALREADY_MANAGED",
        "原生已是標記 owner：略過")
    local ghost = Mg.importLegacy({ { rect = { x = 900, y = 900, w = 4, h = 4 }, owner = "zed", title = "Z", members = {},
        hash = "h900" } }, T.now)
    check(#ghost.skipped == 1 and ghost.skipped[1].reason == "NO_NATIVE" and ghost.skipped[1].hash == "h900",
        "找不到對應原生：放進 skipped")
    check(#R.list() == 3 and #T.files[path].lines == 3, "沒有新增紀錄、manifest 沒多行")

    T.section("重開：核對通過 → migrationCompleted=true、mutation 放行")
    MSH = T.boot(RESTART)
    R = MSH.Registry
    check(R.md.migrationCompleted == true and countLogs("MIGRATION_COMPLETED") == 1, "全部吻合：寫 migrationCompleted=true＋audit")
    check(#T.houses == 3 and countLogs("REBUILT") == 0 and not houses[1].players:contains(MSH.marker(r1.claimId)),
        "首輪 reconcile 不重建、只正規化 load 殘留")
    p = T.player({ name = "alice" })
    defineMutation(MSH)
    res = T.cmd(p, "testMutation", {})
    check(res and res.ok, "遷移完成後 mutation 放行")
    SafeHouse.removeSafeHouse(houses[1])
    T.tick(1)
    local re1 = T.houseOf(MSH.marker(r1.claimId))
    check(re1 ~= nil and re1.players:contains("alice") and re1.players:contains("bob") and re1.players:contains("carol"),
        "遷移後原生消失 → 重建，legacy 成員仍在")
    MSH.Lifecycle.release(R.get(out.imported[3].claimId), "RELEASED", "op-m3", T.now)
    MSH = T.boot(RESTART)
    check(MSH.Registry.md.migrationCompleted == true and countLogs("MIGRATION") == 0,
        "完成後只看旗標：legacy claim 正常 release 不算缺件")

    T.section("第二輪：匯入後刪一筆原生再開 → 該筆 quarantined、整體遷移中")
    MSH = T.boot()
    R, Mg = MSH.Registry, MSH.Migration
    items, houses = fixture()
    out = Mg.importLegacy(items, T.now)
    check(#out.imported == 3, "3 筆匯入")
    SafeHouse.removeSafeHouse(houses[2])
    MSH = T.boot(RESTART)
    R = MSH.Registry
    local lost = R.get(out.imported[2].claimId)
    check(lost.lifecycle == "quarantined" and lost.quarantineReason == "MIGRATION_MISSING"
        and T.houseOf(MSH.marker(lost.claimId)) == nil, "缺原生的那筆 quarantined、首輪 reconcile 不重建")
    check(R.get(out.imported[1].claimId).lifecycle == "active" and R.get(out.imported[3].claimId).lifecycle == "active"
        and houses[1].owner == MSH.marker(out.imported[1].claimId) and houses[3].owner == MSH.marker(out.imported[3].claimId),
        "其他兩筆不受影響")
    check(R.md.migrationCompleted == false and countLogs("MIGRATION_INCOMPLETE") == 1, "整體維持遷移中＋audit")
    p = T.player({ name = "alice" })
    defineMutation(MSH)
    res = T.cmd(p, "testMutation", {})
    check(res and res.code == "MIGRATION_IN_PROGRESS", "遷移中：mutation 回 MIGRATION_IN_PROGRESS")
    MSH = T.boot(RESTART)
    check(MSH.Registry.md.migrationCompleted == false and MSH.Registry.get(out.imported[2].claimId).lifecycle == "quarantined"
        and T.houseOf(MSH.marker(out.imported[2].claimId)) == nil, "再開一次：狀態穩定、不自動恢復")

    T.section("執行期重跑核對：管理員放棄缺件那筆後解除遷移中")
    R = MSH.Registry
    local lostRec = R.get(out.imported[2].claimId)
    local released = MSH.Srv.withLock(function()
        local done = MSH.Lifecycle.forceRelease(lostRec, "ADMIN", "op-lost", T.now)
        MSH.Migration.verify(T.now)
        return done
    end)
    check(released == true and R.get(lostRec.claimId) == nil and R.tomb(lostRec.claimId) ~= nil,
        "缺件那筆放棄：只剩 tombstone")
    check(R.md.migrationCompleted == true and countLogs("MIGRATION_COMPLETED") == 1,
        "鎖內重跑 verify：released（tombstone）不算缺件 → 遷移完成")
    p = T.player({ name = "alice" })
    defineMutation(MSH)
    res = T.cmd(p, "testMutation", {})
    check(res and res.ok, "遷移完成後 mutation 放行（不必重開）")

    T.section("崩潰回滾：manifest 已落盤、registry 回到匯入前 → claimId 不重用、舊行不擋")
    MSH = T.boot()
    out = MSH.Migration.importLegacy((fixture()), T.now)
    local maxId = out.imported[3].claimId
    MSH = T.boot({ keepFiles = true })   -- 存檔（registry＋原生）回到匯入前，manifest 留著
    R = MSH.Registry
    check(R.md.nextClaimId == maxId + 1 and R.allocId() == maxId + 1, "nextClaimId 抬過 manifest 裡的 id（實際 "
        .. tostring(R.md.nextClaimId) .. "）")
    p = T.player({ name = "alice" })
    defineMutation(MSH)
    res = T.cmd(p, "testMutation", {})
    check(R.md.migrationCompleted == nil and res and res.ok, "registry 沒有這一代：舊行忽略、不進入遷移")
    MSH = T.boot()
    MSH.Migration.importLegacy((fixture()), T.now)
    MSH = T.boot(RESTART)
    local mfile = T.files[MSH.Migration.manifestPath()]
    mfile.lines[#mfile.lines + 1] = "h777\t40"   -- 完成後又匯入一筆、registry 回滾到完成時
    MSH = T.boot(RESTART)
    check(MSH.Registry.md.migrationCompleted == true and MSH.Registry.md.nextClaimId == 41,
        "遷移已完成也照樣抬 nextClaimId（實際 " .. tostring(MSH.Registry.md.nextClaimId) .. "）")

    T.section("manifest 讀不開：fail closed")
    MSH = T.boot()
    MSH.Migration.importLegacy({ (legacy(500, "dave", "D", {})) }, T.now)
    local mpath = MSH.Migration.manifestPath()
    MSH = T.boot({ keepGmd = true, keepFiles = true, keepHouses = true,
        beforeStart = function(env) env.unreadable[mpath] = true end })
    check(MSH.Registry.md.migrationCompleted == false and countLogs("MANIFEST_UNREADABLE") == 1, "manifest 存在卻讀不開：維持遷移中")

    -- ===== M5 operator 流程（§9 第 4、5、7、11、12 點）=====
    do
        local SBOX = { ClaimsPerPlayer = 1, CreateMode = 2 }
        local AGAIN = { keepGmd = true, keepFiles = true, keepHouses = true, sandbox = SBOX }
        local SECRETS = { "alice", "bob", "carol", "x.y", "100", "200", "300", "400", "500", "ann", "ben", "cal", "1100",
            "1200", "1300" }
        local Mg
        local function boot(opts)
            MSH = T.boot(opts)
            R, Mg = MSH.Registry, MSH.Migration
            defineMutation(MSH)
            return MSH
        end
        local function mutate(name) return T.cmd(T.player({ name = name or "alice" }), "testMutation", {}) end
        -- aggregate log（MIGRATION_*）不得有名字與座標（§9 第 11 點）
        local function logsClean()
            for _, line in ipairs(T.logs) do
                if string.find(line, "MIGRATION", 1, true) then
                    for _, s in ipairs(SECRETS) do
                        if string.find(line, s, 1, true) then return false end
                    end
                end
            end
            return true
        end
        local function rows()
            local out = {}
            for _, line in ipairs(T.files[Mg.reportPath()].lines) do
                local f = {}
                for part in string.gmatch(line, "[^\t]+") do f[#f + 1] = part end
                if f[1] == "allow" or f[1] == "deny" then
                    out[#out + 1] = { decision = f[1], hash = f[2], rect = f[3], owner = f[4], bsh = f[6], problem = f[7],
                        title = f[8] }
                end
            end
            return out
        end
        local function rowOf(title)
            for _, r in ipairs(rows()) do if r.title == title then return r end end
            return nil
        end
        -- operator 照 report 寫 selection：decide(row) 回 "allow"／"deny"，nil＝漏掉這列；extra 追加在最後
        local function select(decide, extra)
            local out = {}
            for _, line in ipairs(T.files[Mg.reportPath()].lines) do
                local d, h = string.match(line, "^(%a+)\t(%S+)")
                if d == "allow" or d == "deny" then
                    local row
                    for _, r in ipairs(rows()) do if r.hash == h then row = r end end
                    local nd = decide(row)
                    if nd ~= nil then out[#out + 1] = nd .. "\t" .. h .. "\t(operator)" end
                else
                    out[#out + 1] = line
                end
            end
            for _, line in ipairs(extra or {}) do out[#out + 1] = line end
            T.files[Mg.selectionPath()] = { lines = out }
        end
        local function same(a, b)
            if type(a) ~= "table" or type(b) ~= "table" then return a == b end
            for k, v in pairs(a) do if not same(v, b[k]) then return false end end
            for k in pairs(b) do if a[k] == nil then return false end end
            return true
        end
        local function owners()
            local out = {}
            for _, hs in ipairs(T.houses) do out[hs.title] = hs.owner end
            return out
        end
        -- completion manifest 的行數：want 行或匯入行
        local function mlines(kind)
            local n = 0
            for _, l in ipairs(T.files[path].lines) do
                if (string.sub(l, 1, 5) == "want\t") == (kind == "want") then n = n + 1 end
            end
            return n
        end
        local function marked()
            local n = 0
            for _, hs in ipairs(T.houses) do if MSH.claimIdOf(hs.owner) ~= nil then n = n + 1 end end
            return n
        end
        local function seed2()
            legacy(1100, "ann", "R1", { "ben" })
            legacy(1200, "ben", "R2", {})
        end
        -- boot1＋operator 全部 allow；回傳 boot1 存檔（Global ModData）的副本
        local function toSelection()
            boot({ sandbox = SBOX, beforeStart = seed2 })
            select(function() return "allow" end)
            return T.deepcopy(T.gmd)
        end
        -- 之後第 n 次開 completion manifest 寫檔回 nil；回傳還原函式
        local function failManifestWrite(n)
            local orig, k = getFileWriter, 0
            getFileWriter = function(p, c, a)
                if p == path then
                    k = k + 1
                    if k == n then return nil end
                end
                return orig(p, c, a)
            end
            return function() getFileWriter = orig end
        end
        local function bootWith(fn)
            return boot({ keepGmd = true, keepFiles = true, keepHouses = true, sandbox = SBOX, beforeStart = fn })
        end

        T.section("operator：全新伺服器永不進入遷移")
        boot({ sandbox = SBOX })
        check(R.md.migrationCompleted == nil and Mg.status().status == "none" and mutate().ok
            and T.files[Mg.reportPath()] == nil, "沒有原生：不遷移、mutation 放行、不寫 report")
        SafeHouse.addSafeHouse(50, 50, 4, 4, "zed")
        boot(AGAIN)
        check(R.md.migrationCompleted == nil and mutate().ok and T.files[Mg.reportPath()] == nil,
            "之後才出現的 foreign 原生：重開也不進入遷移")
        local rec = R.newRecord({ claimId = R.allocId(), rect = { x = 70, y = 70, w = 4, h = 4 }, title = "t", owner = "eve",
            source = MSH.SOURCE.DEED, deedTier = 1, createdAt = T.now })
        rec.nativeCreatedAt = MSH.Native.build(rec):getDatetimeCreated()
        R.put(rec)
        R.md.migration = nil   -- M5 之前就在跑的 registry：沒有遷移檢查紀錄
        boot(AGAIN)
        check(R.md.migrationCompleted == nil and mutate().ok, "registry 已有紀錄（不是第一次裝）：有 foreign 也不進入遷移")

        T.section("operator：第一次開服 → candidate report（唯讀）、拒絕 mutation")
        local bsh
        boot({ sandbox = SBOX, beforeStart = function()
            legacy(100, "alice", "A", { "bob", "carol" })                -- BSH：Expansion baseRects
            T.advance(1000)
            local _, h2 = legacy(200, "bob", "B", { "alice" })          -- BSH：SubOwners（以建立時間為鍵）
            T.advance(1000)
            legacy(300, "carol", "C", {})                                -- 沒有 BSH 資料：預填 deny
            T.advance(1000)
            legacy(400, "alice", "A2", {})                               -- BSH：PrimaryRespawns；alice 第二間（超過名額）
            T.advance(1000)
            legacy(500, "x.y", "BAD", {})                                -- 名字不合法：problem
            T.gmd.BetterSafehouseExpansionState = { meta = { version = 3 },
                baseRects = { ["100:100:6:6"] = { x = 100, y = 100, w = 6, h = 6 } }, baseAreas = { ["100:100:6:6"] = 36 } }
            T.gmd.BetterSafehouse_SubOwners = { [string.format("%.0f", h2.created)] = { "alice" } }
            T.gmd.BetterSafehouse_PrimaryRespawns = { alice = { enabled = true, x = 402, y = 402, z = 0,
                safeX = 400, safeY = 400, safeW = 6, safeH = 6 } }
            bsh = T.deepcopy({ T.gmd.BetterSafehouseExpansionState, T.gmd.BetterSafehouse_SubOwners,
                T.gmd.BetterSafehouse_PrimaryRespawns })
        end })
        local before = owners()
        local st = Mg.status()
        check(R.md.migrationCompleted == false and st.status == "awaitingSelection" and st.candidates == 5
            and st.bshMatched == 3 and st.problems == 1, "遷移中：候選 5、BSH 對得上 3、問題 1")
        check(#rows() == 5 and rowOf("A").decision == "allow" and rowOf("A").rect == "100,100,6,6" and rowOf("A").owner == "alice"
            and rowOf("B").bsh == "bsh" and rowOf("C").decision == "deny" and rowOf("C").bsh == "-"
            and rowOf("BAD").problem == "BAD_OWNER" and rowOf("BAD").decision == "deny", "report：rect／owner／BSH／問題，預填決定")
        check(mutate().code == "MIGRATION_IN_PROGRESS", "遷移中：mutation 回 MIGRATION_IN_PROGRESS")
        check(#R.list() == 0 and same(owners(), before), "report 階段不改原生、不建紀錄")
        local admin = T.player({ name = "boss", admin = true })
        local q = T.cmd(admin, "adminMigration", {})
        check(q.ok and q.migration.status == "awaitingSelection" and q.migration.candidates == 5
            and q.migration.files.selection == Mg.selectionPath(), "adminMigration：狀態與檔案位置")
        check(T.cmd(T.player({ name = "dan" }), "adminMigration", {}).code == "NOT_ADMIN", "adminMigration 限管理員")
        check(logsClean(), "aggregate log 沒有名字與座標")
        boot(AGAIN)
        check(R.md.migrationCompleted == false and #R.list() == 0 and mutate().code == "MIGRATION_IN_PROGRESS",
            "還沒放 selection：重開照樣等")

        T.section("operator：selection 對不上 → 整批不匯入")
        local function aborts(code, label)
            boot(AGAIN)
            check(Mg.status().abort == code and #R.list() == 0 and same(owners(), before)
                and mutate().code == "MIGRATION_IN_PROGRESS" and logsClean(), label .. "（實際 " .. tostring(Mg.status().abort) .. "）")
        end
        local function good(r)
            if r.title == "C" or r.title == "BAD" then return "deny" end
            return "allow"
        end
        select(function(r) return r.title == "BAD" and "allow" or good(r) end)
        aborts("NOT_ALLOWED", "allow 有問題的候選：中止")
        select(function(r) if r.title ~= "C" then return good(r) end end)
        aborts("UNDECIDED", "漏掉一個候選：中止")
        select(good, { "deny\t123-456" })
        aborts("UNKNOWN_HASH", "不認得的 hash：中止")
        select(good, { "maybe\t" .. rowOf("C").hash })
        aborts("BAD_LINE", "看不懂的列：中止")
        select(good)
        local fp = T.files[Mg.reportPath()].lines[4]
        for _, hs in ipairs(T.houses) do if hs.title == "C" then hs:addPlayer("dave") end end   -- 審核後存檔又變了
        before = owners()
        aborts("SNAPSHOT_MISMATCH", "快照指紋不同：中止")
        check(T.files[Mg.reportPath()].lines[4] ~= fp, "中止後重寫 report（新指紋）")

        T.section("operator：第二次開服照 selection 匯入")
        select(good)
        boot(AGAIN)
        st = Mg.status()
        check(st.status == "verifying" and st.abort == nil and st.allowed == 3 and st.denied == 2 and st.imported == 3
            and st.skipped == 0, "匯入 3、deny 2（實際 " .. tostring(st.imported) .. "/" .. tostring(st.denied) .. "）")
        local now = owners()
        check(MSH.claimIdOf(now.A) ~= nil and MSH.claimIdOf(now.B) ~= nil and MSH.claimIdOf(now.A2) ~= nil
            and now.C == "carol" and now.BAD == "x.y", "只匯入 allow；deny 的原生不動")
        check(mlines("want") == 3 and mlines("import") == 3 and R.md.migrationCompleted == false
            and mutate().code == "MIGRATION_IN_PROGRESS", "寫 completion manifest（3 want＋3 匯入）、核對前仍拒絕 mutation")
        check(logsClean() and T.logged("MIGRATION_IMPORTED"), "匯入的 aggregate log 只有筆數")

        T.section("operator：第三次開服 verify 完成、legacy grandfather")
        boot(AGAIN)
        check(R.md.migrationCompleted == true and Mg.status().status == "completed" and mutate("bob").ok,
            "核對通過：遷移完成、mutation 放行")
        local mine = R.byOwner("alice")
        check(#mine == 2 and mine[1].lifecycle == "active" and mine[2].lifecycle == "active", "alice 兩間 legacy 都保留（超過名額 1）")
        local alice = T.player({ name = "alice", x = 905, y = 905 })
        check(T.cmd(alice, "create", { rect = { x = 900, y = 900, w = 10, h = 10 } }).code == "QUOTA_FULL",
            "超額的 legacy 屋主不能再新建")
        boot(AGAIN)
        check(R.md.migrationCompleted == true and #R.list() == 3 and owners().C == "carol" and logsClean(),
            "之後開服不再掃描、不收 foreign")
        check(same(bsh, { T.gmd.BetterSafehouseExpansionState, T.gmd.BetterSafehouse_SubOwners,
            T.gmd.BetterSafehouse_PrimaryRespawns }) and T.gmd.BetterSafehouse_SubOwnersMembers == nil,
            "Better Safehouse 的 Global ModData 沒被改、也沒被建")

        T.section("operator：超過全服上限中止；全部 deny 直接完成")
        boot({ beforeStart = function()
            for i = 1, MSH.LIMIT.MAX_CLAIMS + 1 do SafeHouse.addSafeHouse(i * 10, 5000, 4, 4, "u" .. i) end
        end })
        select(function() return "allow" end)
        before = owners()
        aborts("TOO_MANY", "allow 超過 256：中止")
        select(function() return "deny" end)
        boot(AGAIN)
        check(R.md.migrationCompleted == true and Mg.status().imported == 0 and #R.list() == 0 and mutate().ok,
            "全部 deny：沒有東西要核對，直接完成")

        T.section("operator：匯入後崩潰回滾 → 照同一份 selection 換新代號重匯、再下一次開服完成")
        local saved = toSelection()
        boot(AGAIN)
        local gen1, maxOld = R.md.migrationGen, 0
        for _, rec in ipairs(R.list()) do if rec.claimId > maxOld then maxOld = rec.claimId end end
        check(gen1 ~= nil and Mg.status().imported == 2 and mlines("want") == 2 and mlines("import") == 2,
            "boot2 匯入 2、manifest 有這一代的行")
        -- 崩潰：世界存檔（原生＋Global ModData）回到 boot1，Lua 資料夾的 manifest 留著
        boot({ keepFiles = true, sandbox = SBOX, beforeStart = function()
            T.gmd = T.deepcopy(saved)
            seed2()
        end })
        local fresh = true
        for _, rec in ipairs(R.list()) do if rec.claimId <= maxOld then fresh = false end end
        check(R.md.migrationGen ~= nil and R.md.migrationGen ~= gen1 and Mg.status().status == "verifying"
            and Mg.status().imported == 2 and #R.list() == 2 and marked() == 2 and fresh, "回滾後重匯：新代號、2 筆、claimId 不重用")
        boot(AGAIN)
        check(R.md.migrationCompleted == true and Mg.status().missing == 0 and mutate().ok and logsClean(),
            "回滾掉那一代的行忽略：核對完成、mutation 放行")

        T.section("operator：舊世界留下的 completion 檔＋全新 registry")
        boot({ keepFiles = true, sandbox = SBOX })
        check(R.md.migrationCompleted == nil and Mg.status().status == "none" and mutate().ok, "全新、沒有原生：不遷移")
        boot({ keepFiles = true, sandbox = SBOX, beforeStart = function() legacy(1300, "cal", "R3", {}) end })
        check(R.md.migrationCompleted == false and Mg.status().status == "awaitingSelection"
            and Mg.status().abort == "SNAPSHOT_MISMATCH" and #R.list() == 0 and marked() == 0,
            "全新＋foreign 原生：進入候選審核，舊 selection 對不上、不匯入")
        select(function() return "allow" end)
        boot(AGAIN)
        boot(AGAIN)
        check(R.md.migrationCompleted == true and #R.list() == 1 and marked() == 1 and mutate().ok,
            "新世界照自己的 selection 匯入並完成（舊世界的行不算缺件）")

        T.section("operator：部分寫檔失敗 → 維持遷移中、下次開服只補缺的、再下一次完成")
        toSelection()
        local restore
        bootWith(function() restore = failManifestWrite(3) end)   -- 第 1 次 want 行、第 2、3 次各一筆
        restore()
        st = Mg.status()
        check(st.imported == 1 and st.skipped == 1 and marked() == 1 and #R.list() == 1, "boot2：1 筆匯入、1 筆寫檔失敗")
        boot(AGAIN)
        st = Mg.status()
        check(R.md.migrationCompleted == false and st.pending == 1 and st.missing == 0 and T.logged("pending=1")
            and mutate().code == "MIGRATION_IN_PROGRESS", "boot3：少一筆不算完成（pending 1）")
        check(st.imported == 2 and marked() == 2 and #R.list() == 2, "boot3 只補匯入缺的那筆")
        boot(AGAIN)
        check(R.md.migrationCompleted == true and Mg.status().pending == 0 and #R.list() == 2 and mutate().ok,
            "boot4：補齊才完成")

        T.section("operator：匯入中途丟錯 → 已做完的留著、下次開服補齊、同一 hash 不重匯")
        toSelection()
        local origs = {}
        bootWith(function()
            local calls = 0
            for _, hs in ipairs(T.houses) do
                local orig = hs.setOwner
                origs[hs] = orig
                hs.setOwner = function(self, o)
                    calls = calls + 1
                    if calls == 2 then error("boom") end   -- 第二筆：manifest 行已寫、紀錄與原生都沒改
                    return orig(self, o)
                end
            end
        end)
        for hs, orig in pairs(origs) do hs.setOwner = orig end
        check(Mg.status().abort == "IMPORT_FAILED" and marked() == 1 and #R.list() == 1 and mlines("import") == 2
            and R.md.migrationCompleted == false, "boot2：丟錯、1 筆完成、第 2 筆只寫了行")
        boot(AGAIN)
        check(Mg.status().pending == 1 and R.md.migrationCompleted == false and marked() == 2 and #R.list() == 2,
            "boot3：沒做完的那筆補匯入")
        boot(AGAIN)
        local rects = {}
        for _, rec in ipairs(R.list()) do rects[MSH.Native.rectKey(rec.rect)] = (rects[MSH.Native.rectKey(rec.rect)] or 0) + 1 end
        check(R.md.migrationCompleted == true and #R.list() == 2 and rects["1100,1100,6,6"] == 1 and rects["1200,1200,6,6"] == 1
            and mutate().ok, "boot4：完成，每個 hash 只有一筆紀錄")

        T.section("operator：補匯入時原生已不在 → quarantined 佔位、管理員放棄後完成")
        toSelection()
        bootWith(function() restore = failManifestWrite(3) end)
        restore()
        local gone = {}
        for _, hs in ipairs(T.houses) do if MSH.claimIdOf(hs.owner) == nil then gone[#gone + 1] = hs end end
        for _, hs in ipairs(gone) do SafeHouse.removeSafeHouse(hs) end
        boot(AGAIN)
        local held
        for _, rec in ipairs(R.list()) do if rec.lifecycle == "quarantined" then held = rec end end
        check(#gone == 1 and held ~= nil and held.quarantineReason == "MIGRATION_MISSING" and Mg.status().held == 1
            and #R.list() == 2, "原生不在：建 quarantined 佔位")
        boot(AGAIN)
        check(R.md.migrationCompleted == false and Mg.status().missing == 1 and Mg.status().pending == 0,
            "佔位算缺件：維持遷移中")
        local res2 = T.cmd(T.player({ name = "boss", admin = true }), "adminRecover", { claimId = held.claimId, action = "release" })
        check(res2 and res2.ok and R.md.migrationCompleted == true and mutate().ok, "管理員放棄佔位 → 遷移完成")
    end
end
