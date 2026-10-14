-- 當機補回（Journal.lua）：建立、重新框選寫檔，建立滿 INV_DELAY_MS 補「背包已存」，真正的放棄寫 X；
-- 開機時照檔案補回沒進世界存檔的屋（背包已存→active、沒有→quarantined CRASH_UNCONFIRMED、已放棄→不補），
-- 沒補回任何一串時清成只剩高水位，有補回的就整份留著。
return function(T)
    local check = T.check
    local D1 = "MinidoracatSafehouse.Deed1"
    local MSH, R, J

    local function boot(opts)
        MSH = T.boot(opts)
        R, J = MSH.Registry, MSH.Journal
        return MSH
    end
    local function rect(x, y, w, h) return { x = x, y = y, w = w, h = h } end
    local function lines() return (T.files[J.path()] or { lines = {} }).lines end
    local function kinds()
        local out = {}
        for _, l in ipairs(lines()) do out[#out + 1] = string.sub(l, 1, 1) end
        return table.concat(out)
    end
    local function house(id) return T.houseOf(MSH.marker(id)) end
    local function journalFile() return MinidoracatSafehouse.Registry.privateFile("crash-journal.txt") end
    local function recovered()
        local n = 0
        for _, r in ipairs(R.listAll()) do
            if r.quarantineReason == "RECOVERED" or r.quarantineReason == "RECOVERED_DUPLICATE" then n = n + 1 end
        end
        return n
    end
    -- 世界存檔：Global ModData 與原生的快照（私有檔不在存檔裡，照樣留著）
    local function save()
        local houses = {}
        for i, hs in ipairs(T.houses) do
            houses[i] = { x = hs.x, y = hs.y, w = hs.w, h = hs.h, owner = hs.owner, title = hs.title,
                created = hs.created, players = { table.unpack(hs.players._raw) } }
        end
        return { gmd = T.deepcopy(T.gmd), houses = houses }
    end
    -- 當機：Global ModData 與原生回到上一次存檔、Lua 全部重建、私有檔留著
    local function crash(snap, sandbox)
        return boot({ keepFiles = true, sandbox = sandbox, beforeStart = function()
            T.gmd = T.deepcopy(snap.gmd)
            T.houses = {}
            for _, d in ipairs(snap.houses) do
                local hs = T.house(d.x, d.y, d.w, d.h, d.owner)
                hs.title, hs.created = d.title, d.created
                for _, u in ipairs(d.players) do hs:addPlayer(u) end
                hs:addPlayer(d.owner)   -- SafeHouse.load 把 owner 也放進 players（env.lua resetWorld 同樣模擬）
                T.houses[#T.houses + 1] = hs
            end
        end })
    end
    local function waitInv()
        T.advance(J.INV_DELAY_MS)
        T.tick(60)   -- 6 秒：跨過一次 TICK_MS
    end
    local function create(p, r, extra)
        local args = { rects = { r }, deedType = D1 }
        for k, v in pairs(extra or {}) do args[k] = v end
        return T.cmd(p, "create", args)
    end
    local function redraw(p, id, r)
        return T.cmd(p, "redraw", { claimId = id, rects = { r }, expectedRevision = R.get(id).revision })
    end
    local function release(p, id)
        return T.cmd(p, "release", { claimId = id, expectedRevision = R.get(id).revision })
    end

    T.section("寫檔：建立一行 C、滿 INV_DELAY_MS 補 I、放棄補 X；乾淨開機清成只剩高水位")
    boot()
    check(kinds() == "H" and lines()[1] == "H\t0", "全新開機：檔案只有高水位 0")
    local alice = T.player({ name = "alice", x = 105, y = 105, items = { D1 } })
    local res = create(alice, rect(100, 100, 10, 10), { title = "Home" })
    local id = res.claimId
    local f = R.splitTabs(lines()[2] or "")
    check(res.ok and kinds() == "HC" and f[2] == tostring(id) and f[3] == tostring(id) and f[4] == "alice" and f[5] == "1"
        and f[6] == "deed" and f[8] == "100,100,10,10," .. string.format("%.0f", R.get(id).rects[1].created)
        and f[9] == "Home", "建立：C 行帶 claimId、根、屋主、等級、來源、範圍與指紋、標題")
    T.advance(J.INV_DELAY_MS - 10000)
    T.tick(1)
    check(kinds() == "HC", "建立後 200 秒：還沒有 I")
    T.advance(10000)
    T.tick(60)
    check(kinds() == "HCI" and lines()[3] == "I\t" .. id, "滿 INV_DELAY_MS：補 I")
    T.tick(60)
    check(kinds() == "HCI", "I 只補一次")
    res = release(alice, id)
    check(res.ok and kinds() == "HCIX" and lines()[4] == "X\t" .. id, "放棄：X 行")

    T.section("當機（背包已存）：補回 active、首輪 Reconcile 建回原生、檔案整份留著")
    boot()
    local empty = save()
    local bob = T.player({ name = "bob", x = 205, y = 205, items = { D1 } })
    res = create(bob, rect(200, 200, 10, 10), { title = "Bob" })
    local bid = res.claimId
    waitInv()
    local before = kinds()
    crash(empty)
    local rec = R.get(bid)
    check(rec ~= nil and rec.lifecycle == "active" and rec.owner == "bob" and rec.source == "deed" and rec.deedTier == 1
        and rec.title == "Bob" and #rec.grants == 0, "紀錄補回 active（屋主、來源、等級、標題照建立時）")
    check(house(bid) ~= nil and house(bid).players:contains("bob") and J.status().restored == 1
        and T.logged("CRASH_RESTORED"), "原生由首輪 Reconcile 建回、屋主在名單；面板筆數 1；audit CRASH_RESTORED")
    check(kinds() == before and R.md.nextClaimId > bid, "有補回：檔案不改寫（" .. kinds() .. "）；nextClaimId 抬過它")

    T.section("補回之後還沒存檔又當機：再補一次；存檔之後開機：清成高水位")
    crash(empty)
    check(R.get(bid) ~= nil and R.get(bid).lifecycle == "active" and house(bid) ~= nil, "再當機：再補一次")
    local after = save()
    crash(after)
    check(R.get(bid) ~= nil and J.status().restored == 0 and kinds() == "H" and lines()[1] == "H\t" .. bid,
        "存檔有這間：不動、清成高水位 " .. bid)

    T.section("當機（背包還沒存）：quarantined CRASH_UNCONFIRMED，管理員決定")
    boot()
    empty = save()
    local dan = T.player({ name = "dan", x = 405, y = 405, items = { D1 } })
    res = create(dan, rect(400, 400, 10, 10))
    local did = res.claimId
    T.advance(J.INV_DELAY_MS - 10000)
    T.tick(1)
    crash(empty)
    rec = R.get(did)
    check(rec ~= nil and rec.lifecycle == "quarantined" and rec.quarantineReason == "CRASH_UNCONFIRMED"
        and rec.candidates[1] == "dan" and house(did) == nil, "沒有 I：quarantined CRASH_UNCONFIRMED、不建原生")
    local boss = T.player({ name = "boss", admin = true })
    res = T.cmd(boss, "adminClaims", {})
    check(res.ok and res.crash.unconfirmed == 1 and res.crash.restored == 0 and #res.claims == 1
        and res.claims[1].quarantineReason == "CRASH_UNCONFIRMED", "adminClaims：列出這筆、帶 crash 筆數")
    res = T.cmd(boss, "adminRecover", { claimId = did, action = "rebind" })
    check(res.ok and R.get(did).lifecycle == "active" and house(did) ~= nil and house(did).players:contains("dan"),
        "管理員重新綁定給原屋主：active、建回原生")

    T.section("原生已經在存檔、registry 沒跟上、沒有 I：照樣交給管理員（原生先存、背包後存）")
    boot()
    empty = save()
    local ivy = T.player({ name = "ivy", x = 1105, y = 1105, items = { D1 } })
    local iid = create(ivy, rect(1100, 1100, 10, 10)).claimId
    local half = save()                 -- 世界存檔寫了原生……
    half.gmd = T.deepcopy(empty.gmd)    -- ……Global ModData 還是上一次的（存檔寫到一半當機）
    crash(half)
    check(R.get(iid) ~= nil and R.get(iid).quarantineReason == "CRASH_UNCONFIRMED" and #T.houses == 1
        and R.get(iid).rects[1].created == house(iid).created and recovered() == 0,
        "CRASH_UNCONFIRMED、原生留著、指紋用原生的、不另外轉 RECOVERED")

    T.section("免費建立：不用等背包，當機就補回 active")
    local FREE = { CreateMode = 2 }
    boot({ sandbox = FREE })
    empty = save()
    local eve = T.player({ name = "eve", x = 505, y = 505 })
    res = T.cmd(eve, "create", { rects = { rect(500, 500, 10, 10) } })
    local eid = res.claimId
    crash(empty, FREE)
    check(res.ok and R.get(eid) ~= nil and R.get(eid).lifecycle == "active" and R.get(eid).source == "free"
        and house(eid) ~= nil, "免費建立：active、建回原生")

    T.section("放棄過的不補；連續當機也不重用 claimId")
    boot()
    empty = save()
    local fay = T.player({ name = "fay", x = 605, y = 605, items = { D1 } })
    res = create(fay, rect(600, 600, 10, 10))
    local fid = res.claimId
    waitInv()
    res = release(fay, fid)
    crash(empty)
    check(res.ok and R.get(fid) == nil and house(fid) == nil and J.status().restored == 0 and kinds() == "H"
        and lines()[1] == "H\t" .. fid, "放棄後當機：不補、清成高水位 " .. fid)
    crash(empty)
    fay = T.player({ name = "fay", x = 705, y = 705, items = { D1 } })
    res = create(fay, rect(700, 700, 10, 10))
    check(res.ok and res.claimId > fid, "再當機一次（存檔仍是建立前）：下一間的 claimId 仍大於 " .. fid
        .. "（實際 " .. tostring(res.claimId) .. "）")

    T.section("有補回時檔案整份留著：同一份裡已放棄的串照樣不補")
    local MANY = { ClaimsPerPlayer = 3 }
    boot({ sandbox = MANY })
    empty = save()
    local gil = T.player({ name = "gil", x = 805, y = 805, items = { D1, D1 } })
    local k1 = create(gil, rect(800, 800, 10, 10)).claimId
    waitInv()
    gil.x = 905
    local k2 = create(gil, rect(900, 800, 10, 10)).claimId
    release(gil, k2)
    before = kinds()
    crash(empty, MANY)
    check(R.get(k1) ~= nil and R.get(k1).lifecycle == "active" and R.get(k2) == nil and kinds() == before,
        "補回 " .. k1 .. "、不補已放棄的 " .. k2 .. "、檔案不改寫（" .. kinds() .. "）")
    local k1rev = R.get(k1).revision
    res = release(gil, k1)
    check(res.ok and string.sub(kinds(), -1) == "X" and lines()[#lines()] == "X\t" .. k1 and k1rev ~= nil,
        "補回的那間這次開機放棄：照樣寫 X")

    T.section("重新框選：補回最後那一間，舊的不回來")
    boot()
    empty = save()
    local gus = T.player({ name = "gus", x = 705, y = 705, items = { D1 } })
    local g1 = create(gus, rect(700, 700, 10, 10)).claimId
    waitInv()
    res = redraw(gus, g1, rect(701, 701, 10, 10))
    local g2 = res.claimId
    check(res.ok and kinds() == "HCIC", "重新框選：舊的不寫 X、新的 C 接在同一串")
    crash(empty)
    check(R.get(g1) == nil and R.get(g2) ~= nil and R.get(g2).lifecycle == "active" and house(g2) ~= nil
        and house(g2).x == 701 and house(g1) == nil, "補回新的那一間 active（沿用根的背包狀態），舊的不回來")

    boot()
    empty = save()
    gus = T.player({ name = "gus", x = 705, y = 705, items = { D1 } })
    g1 = create(gus, rect(700, 700, 10, 10)).claimId
    g2 = redraw(gus, g1, rect(701, 701, 10, 10)).claimId
    crash(empty)
    check(R.get(g1) == nil and R.get(g2) ~= nil and R.get(g2).quarantineReason == "CRASH_UNCONFIRMED",
        "根還沒有 I 就重新框選：新的那一間寫成 CRASH_UNCONFIRMED")

    T.section("重新框選寫到一半當機（舊屋放棄了、新屋那行沒寫成）：補回舊屋")
    boot()
    empty = save()
    gus = T.player({ name = "gus", x = 705, y = 705, items = { D1 } })
    g1 = create(gus, rect(700, 700, 10, 10)).claimId
    waitInv()
    local origRedrawn = J.redrawn
    J.redrawn = function() end   -- 模擬新屋那行還沒寫，程序就沒了
    g2 = redraw(gus, g1, rect(701, 701, 10, 10)).claimId
    J.redrawn = origRedrawn
    crash(empty)
    check(R.get(g1) ~= nil and R.get(g1).lifecycle == "active" and house(g1) ~= nil and R.get(g2) == nil,
        "檔案停在舊屋：補回舊屋 active")

    T.section("存檔寫了舊屋的原生、Global ModData 沒寫成，之後重新框選又當機：舊屋原生拆掉、不轉 RECOVERED")
    boot()
    empty = save()
    gus = T.player({ name = "gus", x = 705, y = 705, items = { D1 } })
    g1 = create(gus, rect(700, 700, 10, 10)).claimId
    waitInv()
    half = save()
    half.gmd = T.deepcopy(empty.gmd)
    gus.x = 725
    g2 = redraw(gus, g1, rect(720, 700, 10, 10)).claimId
    crash(half)
    check(R.get(g2) ~= nil and R.get(g2).lifecycle == "active" and house(g2) ~= nil and house(g1) == nil
        and R.tomb(g1) ~= nil and recovered() == 0, "新屋 active、舊屋寫 tombstone 由首輪 Reconcile 拆掉")

    T.section("存檔之後才重新框選：舊屋跟著存檔回來，新的不補")
    boot()
    gus = T.player({ name = "gus", x = 705, y = 705, items = { D1 } })
    g1 = create(gus, rect(700, 700, 10, 10)).claimId
    waitInv()
    local mid = save()
    g2 = redraw(gus, g1, rect(701, 701, 10, 10)).claimId
    crash(mid)
    check(R.get(g1) ~= nil and R.get(g1).lifecycle == "active" and R.get(g2) == nil and house(g2) == nil
        and J.status().restored == 0 and kinds() == "H", "舊屋在存檔裡：不補新的、清成高水位")

    T.section("重新框選失敗撤回：舊屋仍是這一串的最後一間")
    boot()
    empty = save()
    gus = T.player({ name = "gus", x = 705, y = 705, items = { D1 } })
    g1 = create(gus, rect(700, 700, 10, 10)).claimId
    waitInv()
    local origPut = R.put
    R.put = function() error("put boom") end
    res = redraw(gus, g1, rect(701, 701, 10, 10))
    R.put = origPut
    check(res.code == "INTERNAL_ERROR" and R.get(g1) ~= nil and R.get(g1).lifecycle == "active" and kinds() == "HCI",
        "撤回：檔案沒有多寫任何一行")
    crash(empty)
    check(R.get(g1) ~= nil and R.get(g1).lifecycle == "active" and house(g1) ~= nil, "當機後補回舊屋")

    T.section("開機先抬 nextClaimId：Migration 接管不撞到檔裡的 claimId")
    boot({ beforeStart = function()
        T.files[journalFile()] = { lines = { "C\t5\t5\tamy\t1\tdeed\t1700000000000\t900,900,10,10,-\tAmy" } }
        T.houses[#T.houses + 1] = T.house(950, 950, 10, 10, "zed")
    end })
    local zed = nil
    for _, hs in ipairs(T.houses) do if hs.x == 950 then zed = hs end end
    check(MSH.Migration.status().adopted == 1 and MSH.claimIdOf(zed.owner) == 6
        and R.get(5) ~= nil and R.get(5).quarantineReason == "CRASH_UNCONFIRMED",
        "接管的舊屋拿 6、檔裡的 5 補回（" .. tostring(zed and zed.owner) .. "）")

    T.section("壞行略過；讀不開或太長：不補也不改檔，只抬 claimId")
    boot({ beforeStart = function()
        T.files[journalFile()] = { lines = { "garbage", "C\tx", "I\t1\textra" } }
    end })
    check(T.logged("BAD_LINES") and kinds() == "H" and #R.listAll() == 0, "壞行：audit BAD_LINES、略過、清成高水位")
    local seven = "C\t7\t7\tamy\t1\tdeed\t1700000000000\t900,900,10,10,-\tAmy"
    boot({ beforeStart = function()
        T.files[journalFile()] = { lines = { seven, "I\t7" } }
        T.unreadable[journalFile()] = true
    end })
    check(R.get(7) == nil and T.logged("FILE_UNREADABLE") and #lines() == 2, "讀不開：不補、不覆寫")
    boot({ beforeStart = function()
        MinidoracatSafehouse.Journal.MAX_LINES = 2
        T.files[journalFile()] = { lines = { seven, "I\t7", "X\t7" } }
    end })
    check(R.get(7) == nil and T.logged("TOO_LONG") and #lines() == 3 and R.md.nextClaimId > 7,
        "超過上限：不照前段補（後段才是 X）、不改檔、claimId 照樣抬")

    T.section("寫不了檔：建立照樣成功、記 audit")
    boot()
    local hal = T.player({ name = "hal", x = 1005, y = 1005, items = { D1 } })
    local origWrite = R.writeLines
    R.writeLines = function(path, ls, append)
        if path == J.path() then return false end
        return origWrite(path, ls, append)
    end
    res = create(hal, rect(1000, 1000, 10, 10))
    R.writeLines = origWrite
    check(res.ok and R.get(res.claimId) ~= nil and T.logged("JOURNAL_FAILED") and kinds() == "H",
        "寫不了：建立成功、audit JOURNAL_FAILED")
end
