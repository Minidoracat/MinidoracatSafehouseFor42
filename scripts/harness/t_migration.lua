-- Migration：自動接管既有的原版安全屋（計畫 §9；使用者 2026-10-11 決定全自動）。
-- 一次開服就接管、玩家不被擋；有問題與超過上限的留原版；前置條件不符等下次開服；三種當機組合自動修好；已有紀錄的伺服器不進入。
return function(T)
    local check = T.check
    local SBOX = { ClaimsPerPlayer = 1, CreateMode = 2 }
    local KEEP = { keepGmd = true, keepFiles = true, keepHouses = true, sandbox = SBOX }
    local SECRETS = { "alice", "bob", "carol", "dan", "eve", "fay", "gus", "x.y", "100", "200", "300", "700", "800" }
    local MSH, R, Mg

    local function boot(opts)
        opts = opts or {}
        if opts.sandbox == nil then opts.sandbox = SBOX end
        MSH = T.boot(opts)
        R, Mg = MSH.Registry, MSH.Migration
        MSH.Srv.define("testMutation", { kind = "mutation", fields = {}, run = function() return MSH.Srv.ok() end })
        return MSH
    end
    local function again(extra)
        local o = {}
        for k, v in pairs(KEEP) do o[k] = v end
        for k, v in pairs(extra or {}) do o[k] = v end
        return boot(o)
    end
    local function mutate(name) return T.cmd(T.player({ name = name or "alice" }), "testMutation", {}) end
    -- 原版留下的原生：owner 是真名，成員在 players（addSafeHouse 的 setOwner 已把 owner 移出，SafeHouse.java:68-85）
    local function native(x, owner, title, members, w)
        local hs = SafeHouse.addSafeHouse(x, x, w or 6, 6, owner)
        hs:setTitle(title)
        for _, u in ipairs(members or {}) do hs:addPlayer(u) end
        T.advance(1000)
        return hs
    end
    local function seed3()
        native(100, "alice", "A", { "bob", "carol" })
        native(200, "bob", "B", { "alice" })
        native(300, "carol", "C", {})
    end
    local function houseAt(x)
        for _, hs in ipairs(T.houses) do if hs.x == x then return hs end end
        return nil
    end
    local function marked()
        local n = 0
        for _, hs in ipairs(T.houses) do if MSH.claimIdOf(hs.owner) ~= nil then n = n + 1 end end
        return n
    end
    local function fileLines(kind)
        local f = T.files[Mg.manifestPath()]
        local n = 0
        for _, l in ipairs(f and f.lines or {}) do if string.sub(l, 1, #kind + 1) == kind .. "\t" then n = n + 1 end end
        return n
    end
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
    local function perRect()
        local out = {}
        for _, rec in ipairs(R.list()) do
            local k = MSH.Native.rectKey(rec.rect)
            out[k] = (out[k] or 0) + 1
        end
        return out
    end
    local function noRepair()
        local st = Mg.status()
        return st.restored == 0 and st.reattached == 0 and not T.logged("MIGRATION_REPAIRED") and not T.logged("QUARANTINE")
    end
    local function owned(x, owner)
        local hs = houseAt(x)
        local id = hs and MSH.claimIdOf(hs.owner)
        local rec = id and R.get(id)
        return rec ~= nil and rec.owner == owner and rec.source == "legacy" and rec.lifecycle == "active"
            and hs.players:contains(owner)
    end

    T.section("全新＋foreign 原生：一次開服就接管、玩家不被擋")
    boot({ beforeStart = function()
        seed3()
        native(500, "x.y", "BAD", {})                 -- 屋主名不合法
        native(700, "dan", "D1", {})                  -- 兩間同範圍
        native(700, "eve", "D2", {})
        native(800, "fay", "E1", {})                  -- 同起點不同大小
        native(800, "gus", "E2", {}, 8)
        T.gmd.BetterSafehouse_SubOwners = { ["123"] = { "alice" } }
    end })
    local st = Mg.status()
    check(st.state == "done" and st.adopted == 3 and st.skipped.BAD_OWNER == 1 and st.skipped.DUPLICATE_RECT == 2
        and st.skipped.DUPLICATE_ID == 2, "接管 3、略過依原因計數（實際 " .. tostring(st.adopted) .. "）")
    check(owned(100, "alice") and owned(200, "bob") and owned(300, "carol"), "屋主、legacy、active，原屋主在原生名單")
    local ra = R.get(MSH.claimIdOf(houseAt(100).owner))
    check(ra.title == "A" and #ra.grants == 2 and ra.grants[1].bits == MSH.SHARE_LEGACY and ra.nativeCreatedAt == houseAt(100).created
        and houseAt(100).players:contains("bob") and houseAt(100).players:contains("carol"), "標題、成員（SHARE_LEGACY）、原生指紋照舊")
    check(houseAt(500).owner == "x.y" and houseAt(700).owner == "dan" and houseAt(800).owner == "fay" and #R.list() == 3,
        "有問題的留原版、不建紀錄")
    check(fileLines("imp") == 3 and fileLines("skip") == 5, "completion 檔：3 行 imp、5 行 skip")
    check(mutate().ok, "接管當下玩家指令不被擋")
    check(logsClean() and T.logged("MIGRATION_ADOPTED"), "aggregate log 只有筆數")
    check(T.gmd.BetterSafehouse_SubOwners["123"][1] == "alice" and T.gmd.BetterSafehouseExpansionState == nil,
        "Better Safehouse 的 Global ModData 不改、不建")
    local admin = T.player({ name = "boss", admin = true })
    local q = T.cmd(admin, "adminMigration", {})
    check(q.ok and q.migration.state == "done" and q.migration.adopted == 3 and q.migration.skipped.BAD_OWNER == 1,
        "adminMigration：狀態與筆數")
    check(T.cmd(T.player({ name = "dan" }), "adminMigration", {}).code == "NOT_ADMIN", "adminMigration 限管理員")

    T.section("下一次開服：核對、沒有修補、之後出現的 foreign 不收")
    native(900, "zed", "Z", {})
    again()
    check(Mg.status().state == "done" and noRepair() and #R.list() == 3 and houseAt(900).owner == "zed" and mutate().ok,
        "沒有修補、不再接管")
    local p = T.player({ name = "alice", x = 1005, y = 1005 })
    check(T.cmd(p, "create", { rect = { x = 1000, y = 1000, w = 10, h = 10 } }).code == "QUOTA_FULL",
        "legacy grandfather：屋主已超過名額 1，不能再新建")

    T.section("已有紀錄或沒有原生的伺服器永遠不進入")
    boot()
    check(Mg.status().state == "none" and mutate().ok, "全新、沒有原生：none")
    native(50, "zed", "Z", {})
    again()
    check(Mg.status().state == "none" and houseAt(50).owner == "zed", "之後才出現的 foreign：照樣不接管")
    local rec = R.newRecord({ claimId = R.allocId(), rect = { x = 70, y = 70, w = 4, h = 4 }, title = "t", owner = "eve",
        source = MSH.SOURCE.DEED, deedTier = 1, createdAt = T.now })
    rec.nativeCreatedAt = MSH.Native.build(rec):getDatetimeCreated()
    R.put(rec)
    R.md.migration = nil   -- 還沒有遷移狀態、但已有紀錄的 registry
    again()
    check(Mg.status().state == "none" and houseAt(50).owner == "zed" and #R.list() == 1, "已有紀錄：有 foreign 也不接管")

    T.section("超過全服上限：依建立時間由舊到新接到上限，其餘留原版")
    boot({ beforeStart = function()
        for i = 1, MSH.LIMIT.MAX_CLAIMS + 2 do native(i * 10, "u" .. i, "T" .. i, {}) end
    end })
    st = Mg.status()
    check(st.adopted == MSH.LIMIT.MAX_CLAIMS and st.skipped.OVER_CAP == 2 and #R.list() == MSH.LIMIT.MAX_CLAIMS,
        "接到 256、略過 2（實際 " .. tostring(st.adopted) .. "）")
    check(MSH.claimIdOf(houseAt(10).owner) ~= nil and houseAt((MSH.LIMIT.MAX_CLAIMS + 1) * 10).owner == "u257"
        and houseAt((MSH.LIMIT.MAX_CLAIMS + 2) * 10).owner == "u258", "最舊的接管、最新的兩間留原版")

    T.section("前置條件不符：不接管、記原因，條件好了下次開服自動接")
    boot({ beforeStart = function()
        seed3()
        T.serverOptions.War = "true"
    end })
    check(Mg.status().state == "waiting" and Mg.status().reason == "HEALTH_BLOCKED" and #R.list() == 0 and marked() == 0
        and T.logged("MIGRATION_WAITING"), "伺服器設定不完整：等待、原生不動")
    again({ mods = { "\\BetterSafehouse", "MinidoracatSafehouseFor42" } })
    check(Mg.status().state == "waiting" and Mg.status().reason == "BSH_ACTIVE" and marked() == 0 and mutate().ok,
        "設定好了但 Better Safehouse 還在：等待、玩家不被擋")
    again()
    check(Mg.status().state == "done" and Mg.status().adopted == 3 and marked() == 3, "都好了：下次開服自動接管")

    T.section("當機：兩邊都沒存 → 重新接管，舊行忽略")
    boot({ beforeStart = seed3 })
    local oldMax = R.md.nextClaimId - 1
    boot({ keepFiles = true, beforeStart = seed3 })   -- 世界存檔（原生＋Global ModData）回到接管前，completion 檔留著
    local fresh = true
    for _, r in ipairs(R.list()) do if r.claimId <= oldMax then fresh = false end end
    check(Mg.status().state == "done" and Mg.status().adopted == 3 and #R.list() == 3 and marked() == 3 and fresh
        and noRepair(), "重新接管 3 間、claimId 不重用、沒有誤修")
    again()
    check(noRepair() and #R.list() == 3, "再開一次：沒有修補")

    T.section("當機：原生已存、registry 沒存 → 照 completion 檔重建紀錄")
    boot({ beforeStart = seed3 })
    local ids = {}
    for _, x in ipairs({ 100, 200, 300 }) do ids[x] = MSH.claimIdOf(houseAt(x).owner) end
    boot({ keepFiles = true, keepHouses = true })   -- Global ModData 回到接管前，原生留著
    st = Mg.status()
    check(st.restored == 3 and st.state == "done" and st.adopted == 3 and #R.list() == 3, "重建 3 筆紀錄")
    check(owned(100, "alice") and owned(200, "bob") and owned(300, "carol") and MSH.claimIdOf(houseAt(100).owner) == ids[100]
        and #R.get(ids[100]).grants == 2 and R.get(ids[100]).title == "A", "屋主、標題、成員照舊，claimId 不變")
    check(not T.logged("RECOVERED") and not T.logged("QUARANTINE") and mutate().ok, "沒有轉 RECOVERED、玩家不被擋")
    again()
    check(noRepair() and #R.list() == 3, "再開一次：沒有修補")

    T.section("當機：registry 已存、原生沒存 → 重新接上")
    boot({ beforeStart = seed3 })
    local created = {}
    for _, x in ipairs({ 100, 200, 300 }) do created[x] = houseAt(x).created end
    again({ keepHouses = false, beforeStart = function()   -- 原生回到接管前（原本的屋主名字、同一個建立時間）
        seed3()
        for x, c in pairs(created) do houseAt(x).created = c end
    end })
    check(Mg.status().reattached == 3 and owned(100, "alice") and owned(200, "bob") and owned(300, "carol")
        and #T.houses == 3, "3 間重新接上、沒有多建原生")
    check(not T.logged("REBUILD_OVERLAP") and not T.logged("QUARANTINE") and mutate().ok, "沒有轉 quarantine")
    again()
    check(noRepair(), "再開一次：沒有修補")

    T.section("當機：真的對不上 → 交給管理員（RECOVERED quarantine）")
    boot({ beforeStart = seed3 })
    local f = T.files[Mg.manifestPath()]
    for i, l in ipairs(f.lines) do f.lines[i] = string.gsub(l, "^(imp\t[^\t]*\t[^\t]*\t[^\t]*\t)[^\t]*", "%11") end
    boot({ keepFiles = true, keepHouses = true })
    local q3 = 0
    for _, r in ipairs(R.listAll()) do if r.quarantineReason == "RECOVERED" then q3 = q3 + 1 end end
    check(Mg.status().restored == 0 and q3 == 3, "建立時間對不上：不重建，首輪 reconcile 轉 RECOVERED")

    T.section("部分寫檔失敗：等待中、下次開服只補沒接的")
    local orig = getFileWriter
    local n = 0
    getFileWriter = function(path, c, a)
        if string.find(path, "migration", 1, true) then
            n = n + 1
            if n == 2 then return nil end
        end
        return orig(path, c, a)
    end
    boot({ beforeStart = seed3 })
    getFileWriter = orig
    check(Mg.status().state == "waiting" and Mg.status().reason == "IMPORT_FAILED" and Mg.status().adopted == 2
        and marked() == 2 and mutate().ok, "接 2、1 間寫檔失敗：等待中、玩家不被擋")
    again()
    local pr = perRect()
    check(Mg.status().state == "done" and Mg.status().adopted == 3 and pr["100,100,6,6"] == 1 and pr["200,200,6,6"] == 1
        and pr["300,300,6,6"] == 1, "下次開服補齊、每間只有一筆")

    T.section("接管中途丟錯：已接的留著、下次開服補齊、不重複")
    local restoreOwner
    boot({ beforeStart = function()
        seed3()
        local orig2 = houseAt(200).setOwner
        houseAt(200).setOwner = function() error("boom") end
        restoreOwner = function() houseAt(200).setOwner = orig2 end
    end })
    restoreOwner()
    check(Mg.status().state == "waiting" and Mg.status().reason == "IMPORT_FAILED" and marked() == 1 and #R.list() == 1,
        "丟錯：1 間已接、其餘等待")
    again()
    pr = perRect()
    check(Mg.status().state == "done" and #R.list() == 3 and marked() == 3 and pr["100,100,6,6"] == 1 and noRepair(),
        "下次開服補齊、每間只有一筆、寫了行沒完成的那筆不誤修")
    check(logsClean(), "aggregate log 只有筆數")

    -- 首輪 reconcile 開始時的 nextClaimId（Migration 是 order 11、reconcile 是 order 20）：Migration 必須已經抬過全部標記
    local function watchNextId(seen)
        return function()
            local hooks = MinidoracatSafehouse.Srv.hooks.startup
            local orig = hooks.reconcile.fn
            hooks.reconcile.fn = function(now)
                seen.next = MinidoracatSafehouse.Registry.md.nextClaimId
                return orig(now)
            end
        end
    end
    local function markerDupes()
        local n, seen = 0, {}
        for _, hs in ipairs(T.houses) do
            local id = MSH.claimIdOf(hs.owner)
            if id ~= nil then
                if seen[id] then n = n + 1 end
                seen[id] = true
            end
        end
        return n
    end
    local function create(name, x)
        local res = T.cmd(T.player({ name = name, x = x + 5, y = x + 5 }), "create", { rect = { x = x, y = x, w = 10, h = 10 } })
        return res and res.ok and res.claimId or nil
    end

    T.section("registry 遺失：接管後玩家建了屋、Global ModData 沒存 → 不重用 claimId、不接管新的 foreign")
    boot({ beforeStart = seed3 })
    local c4, c5 = create("pa", 2000), create("pb", 2100)
    check(c4 == 4 and c5 == 5, "接管 3 間後玩家建立 4、5")
    native(2500, "zed", "Z", {})   -- 管理員之後用區域編輯器建的 foreign
    local seen = {}
    boot({ keepFiles = true, keepHouses = true, beforeStart = watchNextId(seen) })   -- 原生存了、registry 全新
    st = Mg.status()
    check(seen.next == 6 and markerDupes() == 0 and houseAt(2500).owner == "zed",
        "Migration 後 nextClaimId 已抬過全部標記（實際 " .. tostring(seen.next) .. "）、沒有重複標記、foreign 不接管")
    check(st.state == "done" and st.restored == 3 and owned(100, "alice") and owned(200, "bob") and owned(300, "carol")
        and T.logged("REGISTRY_LOST"), "接管過的照 imp 行還原、記 REGISTRY_LOST")
    local rec4 = R.get(4)
    check(rec4 ~= nil and rec4.quarantineReason == "RECOVERED" and R.get(5).quarantineReason == "RECOVERED",
        "玩家建的兩間交給 reconcile（RECOVERED，管理員面板處理）")
    again()
    check(houseAt(2500).owner == "zed" and markerDupes() == 0, "再開一次也不接管")

    T.section("registry 遺失：全新世界第一次存檔就當機 → 不接管管理員建的 foreign")
    boot()
    c4, c5 = create("pa", 2000), create("pb", 2100)
    native(2500, "zed", "Z", {})
    seen = {}
    boot({ keepHouses = true, beforeStart = watchNextId(seen) })   -- Global ModData 與 completion 檔都沒有
    check(c4 == 1 and c5 == 2 and seen.next == 3 and markerDupes() == 0, "nextClaimId 抬過玩家建的 1、2")
    check(Mg.status().state == "none" and houseAt(2500).owner == "zed" and R.get(1).quarantineReason == "RECOVERED"
        and mutate().ok, "不接管 foreign、玩家的屋交給 reconcile、玩家不被擋")

    T.section("容量：registry 估算大小放不下的依建立時間留原版（OVER_CAP），之後玩家照常建立、分享")
    local function big(x, owner)
        local members = {}
        for i = 1, 300 do members[i] = owner .. string.format("%024d", i) end
        native(x, owner, "Big" .. x, members)
    end
    boot({ beforeStart = function()
        for i = 1, 10 do big(i * 100, "own" .. i) end
    end })
    st = Mg.status()
    local budget = math.floor(MSH.LIMIT.REGISTRY_BYTES * Mg.REGISTRY_SHARE)
    check(st.adopted >= 1 and (st.skipped.OVER_CAP or 0) >= 1 and st.adopted + st.skipped.OVER_CAP == 10
        and R.estimateBytes() <= budget, "接 " .. tostring(st.adopted) .. "、OVER_CAP " .. tostring(st.skipped.OVER_CAP)
        .. "、registry 在預算內")
    check(MSH.claimIdOf(houseAt(100).owner) ~= nil and houseAt(1000).owner == "own10" and fileLines("skip") == st.skipped.OVER_CAP,
        "最舊的先接、最新的留原版、寫 skip 行")
    local nid = create("newbie", 5000)
    local share = nid and T.cmd(T.player({ name = "newbie", x = 5005, y = 5005 }), "share",
        { claimId = nid, expectedRevision = R.get(nid).revision, targetUsername = "friend", bits = MSH.SHARE.MEMBER })
    check(nid ~= nil and share and share.ok, "接管後一般玩家照常建立、分享")

    T.section("容量：原生名單名字數；第一間放不下之後不讓較新的插隊；標題照建立規則清理")
    boot({ beforeStart = function()
        MinidoracatSafehouse.Migration.NAMES_SHARE = 9 / MinidoracatSafehouse.LIMIT.NATIVE_NAMES   -- 9 個名字
        native(100, "alice", string.rep("x", 60) .. "[]", { "m1", "m2", "m3" })   -- 4 個名字
        native(200, "bob", "", { "m1", "m2", "m3" })                                -- 4
        native(300, "carol", "C", { "m1", "m2", "m3", "m4", "m5" })                  -- 6：放不下
        native(400, "dan", "D", {})                                                 -- 1：放得下但比 carol 新
    end })
    st = Mg.status()
    check(st.adopted == 2 and st.skipped.OVER_CAP == 2 and houseAt(300).owner == "carol" and houseAt(400).owner == "dan",
        "接 2、OVER_CAP 2（實際 " .. tostring(st.adopted) .. "）")
    local ta, tb = R.get(MSH.claimIdOf(houseAt(100).owner)), R.get(MSH.claimIdOf(houseAt(200).owner))
    check(ta.title == string.rep("x", MSH.LIMIT.TITLE_CHARS) and tb.title == "bob", "標題：去 []、截 40 字；空的用屋主名")
end
