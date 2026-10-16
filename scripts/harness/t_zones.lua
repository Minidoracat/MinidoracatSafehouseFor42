-- 管理員禁建區（Zones.lua，使用者 2026-10-16）：管理員指令（權限、驗證、存檔失敗、上限、編號不重用）、zones.txt
-- 重開保留與壞行、讀不開時 fail closed；建立、預檢、重新框選壓到禁建區時 NO_BUILD（壓到的部分、相接不算）、
-- 已經建好的安全屋不動但列給管理員、沒有禁建區時預檢不列這一項；玩家的公開清單 zones 與變更推送 zonesSync（rev）。
return function(T)
    local check = T.check
    local D1 = "MinidoracatSafehouse.Deed1"
    local MSH
    local function rect(x, y, w, h) return { x = x, y = y, w = w, h = h } end
    local function boot(opts)
        MSH = T.boot(opts)
        return MSH
    end
    local function countLogs(event)
        local n = 0
        for _, line in ipairs(T.logs) do
            if string.find(line, "^" .. event .. "\t") then n = n + 1 end
        end
        return n
    end
    local function zonesFile() return T.files[MSH.Zones.path()] end
    local function sameFlat(a, want)
        if type(a) ~= "table" or #a ~= #want then return false end
        for i = 1, #want do
            if a[i] ~= want[i] then return false end
        end
        return true
    end
    local function checkOf(res, name)
        for _, c in ipairs(res and res.checks or {}) do
            if c.name == name then return c end
        end
        return nil
    end

    T.section("Zones：權限與輸入驗證")
    boot()
    local boss = T.player({ name = "boss", admin = true })
    local alice = T.player({ name = "alice" })
    local L = rect(1000, 1000, 30, 10)
    local res = T.cmd(alice, "adminZones", {})
    check(res ~= nil and res.code == "NOT_ADMIN", "非管理員查禁建區：NOT_ADMIN")
    res = T.cmd(alice, "adminAddZone", { name = "x", rects = { L } })
    check(res.code == "NOT_ADMIN" and zonesFile() == nil and #MSH.Zones.list == 0, "非管理員新增：NOT_ADMIN、不寫檔")
    res = T.cmd(boss, "adminZones", {})
    check(res.ok and #res.zones == 0 and res.max == MSH.LIMIT.MAX_ZONES and res.unreadable == false, "管理員查：空清單、上限、讀得到")
    res = T.cmd(boss, "adminAddZone", { name = "   ", rects = { L } })
    local blank = res.code == "BAD_TITLE"
    res = T.cmd(boss, "adminAddZone", { name = "a[b]", rects = { L } })
    check(blank and res.code == "BAD_TITLE" and zonesFile() == nil, "空白名稱、含 []：BAD_TITLE、不寫檔")
    res = T.cmd(boss, "adminAddZone", { name = "x", rects = { L, rect(1010, 1005, 10, 10) } })
    local overlap = res.code == "BAD_SHAPE" and res.reason == "OVERLAP"
    res = T.cmd(boss, "adminAddZone", { name = "x", rects = { L, rect(1100, 1000, 10, 10) } })
    check(overlap and res.code == "BAD_SHAPE" and res.reason == "SPLIT", "各塊重疊、沒連成一片：BAD_SHAPE 帶原因")
    res = T.cmd(boss, "adminAddZone", { name = "x", rects = { rect(0, 0, MSH.LIMIT.ZONE_SIDE + 1, 5) } })
    local wide = res.code == "BAD_ARGS"
    res = T.cmd(boss, "adminAddZone", { name = "x", rects = { rect(0, 0, 600, 5), rect(600, 0, 401, 5) } })
    check(wide and res.code == "BAD_ARGS" and #MSH.Zones.list == 0, "一塊或外框超過 ZONE_SIDE：協定層 BAD_ARGS")
    local nine = {}
    for i = 1, MSH.LIMIT.MAX_PIECES + 1 do nine[i] = rect(2000 + (i - 1) * 2, 2000, 2, 2) end
    res = T.cmd(boss, "adminAddZone", { name = "x", rects = nine })
    check(res.code == "BAD_ARGS", "超過 MAX_PIECES 塊：BAD_ARGS")

    T.section("Zones：新增、存檔失敗、上限、刪除與編號")
    T.failWrites = true
    res = T.cmd(boss, "adminAddZone", { name = "x", rects = { L } })
    T.failWrites = false
    check(res.code == "SAVE_FAILED" and #MSH.Zones.list == 0 and countLogs("ADMIN_ZONE_ADD") == 0,
        "寫檔失敗：SAVE_FAILED、記憶體不變、不寫 audit")
    -- L 形兩塊：上面一橫、左下一塊
    local road = { rect(1000, 1000, 30, 10), rect(1000, 1010, 10, 20) }
    res = T.cmd(boss, "adminAddZone", { name = " 軍事基地通路 ", rects = road })
    local z1 = res.ok and res.zones and res.zones[1]
    check(res.ok and res.zoneId == 1 and #res.zones == 1 and z1.name == "軍事基地通路" and #z1.rects == 2
        and z1.rects[2].y == 1010 and countLogs("ADMIN_ZONE_ADD") == 1, "新增成功：編號 1、名稱去空白、兩塊、寫 audit")
    local f = zonesFile()
    check(f ~= nil and f.lines[1] == "1\tnext\t2\t1" and f.lines[2] == "1\tzone\t1\t1000,1000,30,10;1000,1010,10,20\t軍事基地通路",
        "zones.txt：next 行（下一個編號、個數）＋zone 行（" .. tostring(f and f.lines[2]) .. "）")
    res = T.cmd(boss, "adminAddZone", { name = "B", rects = { rect(3000, 3000, 5, 5) } })
    check(res.ok and res.zoneId == 2 and #zonesFile().lines == 3, "第二個：編號 2、整份覆寫成三行")
    local max0 = MSH.LIMIT.MAX_ZONES
    MSH.LIMIT.MAX_ZONES = 2
    res = T.cmd(boss, "adminAddZone", { name = "C", rects = { rect(3100, 3000, 5, 5) } })
    MSH.LIMIT.MAX_ZONES = max0
    check(res.code == "BAD_ARGS" and res.reason == "FULL" and #MSH.Zones.list == 2, "到上限：BAD_ARGS FULL、不新增")
    res = T.cmd(boss, "adminRemoveZone", { zoneId = 9 })
    check(res.code == "NOT_FOUND" and #MSH.Zones.list == 2, "刪不存在的編號：NOT_FOUND")
    T.failWrites = true
    res = T.cmd(boss, "adminRemoveZone", { zoneId = 2 })
    T.failWrites = false
    check(res.code == "SAVE_FAILED" and #MSH.Zones.list == 2 and countLogs("ADMIN_ZONE_REMOVE") == 0, "刪除寫檔失敗：還在、不寫 audit")
    res = T.cmd(boss, "adminRemoveZone", { zoneId = 2 })
    check(res.ok and #res.zones == 1 and res.zones[1].id == 1 and countLogs("ADMIN_ZONE_REMOVE") == 1, "刪除編號 2")
    f = zonesFile()
    check(#f.lines == 2 and f.lines[1] == "1\tnext\t3\t1", "刪除後檔案只剩 1 號，next 仍是 3")
    res = T.cmd(boss, "adminAddZone", { name = "D", rects = { rect(3000, 3000, 5, 5) } })
    check(res.ok and res.zoneId == 3, "刪掉的 2 號不重用：新的是 3 號")

    T.section("Zones：寫檔沒寫進去（PrintWriter 吞掉錯誤）")
    local path = MSH.Zones.path()
    local saved = {}
    for i, l in ipairs(zonesFile().lines) do saved[i] = l end
    local function sameFile()
        local now = T.files[path] and T.files[path].lines or {}
        if #now ~= #saved then return false end
        for i = 1, #saved do
            if now[i] ~= saved[i] then return false end
        end
        return true
    end
    -- 新內容寫不進去（開檔時照樣截斷，寫的東西沒進去）、原本的寫得回去：SAVE_FAILED、檔案與記憶體照舊、不擋
    local realWriter = getFileWriter
    local first = true
    getFileWriter = function(p, c, a)
        if not first then return realWriter(p, c, a) end
        first = false
        T.silentWrites = true
        local w = realWriter(p, c, a)
        T.silentWrites = false
        return w
    end
    res = T.cmd(boss, "adminAddZone", { name = "G", rects = { rect(3300, 3000, 5, 5) } })
    getFileWriter = realWriter
    check(res.code == "SAVE_FAILED" and #MSH.Zones.list == 2 and sameFile() and not MSH.Zones.unreadable
        and countLogs("ADMIN_ZONE_ADD") == 3, "新內容沒寫進去：SAVE_FAILED、寫回原本的內容、記憶體不變、不寫 audit")
    T.silentWrites = true
    res = T.cmd(boss, "adminRemoveZone", { zoneId = 1 })
    T.silentWrites = false
    check(res.code == "SAVE_FAILED" and #MSH.Zones.list == 2 and MSH.Zones.unreadable,
        "連原本的都寫不回去：SAVE_FAILED、記憶體不變、標成讀不開")
    MSH.Health.evaluate(T.now)
    check(MSH.Health.blocked(), "標成讀不開後 health 馬上 blocked（不等重開）")
    boot({ keepFiles = true })
    check(MSH.Zones.unreadable and MSH.Health.blocked() and #MSH.Zones.list == 0, "重開：檔案是空的（沒有 next 行）＝壞了、fail closed")
    T.files[path] = { lines = saved }
    boot({ keepFiles = true })
    check(not MSH.Zones.unreadable and #MSH.Zones.list == 2, "放回好的檔案：重開正常讀到兩個")

    T.section("Zones：重開保留、內容對不上或讀到一半出錯時 fail closed")
    local function bootWith(edit)
        local lines = {}
        for i, l in ipairs(saved) do lines[i] = l end
        edit(lines)
        T.files[path] = { lines = lines }
        boot({ keepFiles = true })
        return MSH.Zones
    end
    local Z = bootWith(function() end)
    check(#Z.list == 2 and Z.list[1].id == 1 and Z.list[1].name == "軍事基地通路" and #Z.list[1].rects == 2
        and Z.list[2].id == 3 and Z.nextId == 4 and not Z.unreadable and not MSH.Health.blocked(), "重開：兩個禁建區照舊、編號接著 4")
    boss = T.player({ name = "boss", admin = true })
    res = T.cmd(boss, "adminAddZone", { name = "E", rects = { rect(3200, 3000, 5, 5) } })
    check(res.ok and res.zoneId == 4, "重開後新增：編號 4")
    local cases = {
        { "最後一行被截掉（個數對不上）", function(l) l[#l] = nil end },
        { "多一行讀不懂的", function(l) l[#l + 1] = "garbage" end },
        { "zone 行的範圍不合法", function(l) l[#l] = "1\tzone\t3\t5,5,0,5\tbad-size" end },
        { "重複編號", function(l) l[#l] = "1\tzone\t1\t9,9,1,1\tdup-id" end },
        { "沒有 next 行", function(l) table.remove(l, 1) end },
    }
    for _, c in ipairs(cases) do
        Z = bootWith(c[2])
        check(Z.unreadable and MSH.Health.blocked() and #Z.list == 0, c[1] .. "：當成讀不開、health blocked")
    end
    T.files[path] = { lines = saved }
    MSH = T.boot({ keepFiles = true, beforeStart = function(env) env.readFails[path] = 2 end })
    check(MSH.Zones.unreadable and MSH.Health.blocked() and #MSH.Zones.list == 0, "讀到第 2 行 readLine 丟錯：fail closed")
    check(MSH.Srv.ready == true, "讀檔出錯不中斷開服")
    boss = T.player({ name = "boss", admin = true })
    res = T.cmd(boss, "adminZones", {})
    local view = res.ok and res.unreadable == true
    res = T.cmd(boss, "adminAddZone", { name = "F", rects = { rect(3300, 3000, 5, 5) } })
    local addRefused = res.code == "SAVE_FAILED"
    res = T.cmd(boss, "adminRemoveZone", { zoneId = 1 })
    local hasStore = false
    for _, b in ipairs(MSH.Health.state.blockers) do
        if b == "PrivateStore" then hasStore = true end
    end
    check(hasStore and view and addRefused and res.code == "SAVE_FAILED" and sameFile(),
        "讀不開：列成 PrivateStore、清單標 unreadable、新增與刪除都 SAVE_FAILED、不覆寫檔案")
    local priv = MSH.Registry.privatePath()
    MSH = T.boot({ keepFiles = true, beforeStart = function(env)
        env.files[priv] = env.files[priv] or { lines = { "1\tover\tsomeone\t2" } }
        env.readFails[priv] = 1
    end })
    check(MSH.Registry.privateUnreadable and MSH.Health.blocked(), "private.txt 讀到一半出錯也 fail closed（共用的 readLines）")

    T.section("Zones：建立、預檢、重新框選")
    boot({ sandbox = { Tier1FreeSlots = 5 } })
    boss = T.player({ name = "boss", admin = true, x = 2005, y = 2005, items = { D1 } })
    alice = T.player({ name = "alice", x = 1995, y = 2005, items = { D1, D1, D1 } })
    local pv = T.cmd(alice, "preview", { rects = { rect(1990, 2000, 10, 10) }, deedType = D1 })
    check(pv.ok and pv.pass and checkOf(pv, "zones") == nil and #pv.checks == 10, "沒有禁建區：預檢不列這一項")
    T.advance(600)
    res = T.cmd(boss, "adminAddZone", { name = "通路", rects = { rect(2000, 2000, 20, 10) } })
    res = T.cmd(boss, "adminAddZone", { name = "第二區", rects = { rect(2012, 2010, 8, 8) } })
    check(res.ok and #MSH.Zones.list == 2, "兩個禁建區")
    local houses = #T.houses
    res = T.cmd(boss, "create", { rects = { rect(2000, 2000, 10, 10) }, deedType = D1 })
    check(res.code == "NO_BUILD" and res.zoneId == 1 and res.zone == "通路" and sameFlat(res.areas, { 2000, 2000, 10, 10 })
        and #T.houses == houses and boss.inv:getAllTypeRecurse(D1):size() == 1,
        "管理員自己建立也擋：NO_BUILD 帶編號、名稱、壓到的部分；不建原生、不扣地契")
    boss.x, boss.y = 2500, 2500
    alice.x, alice.y = 2015, 2015
    res = T.cmd(alice, "create", { rects = { rect(2010, 2005, 10, 12) }, deedType = D1 })
    check(res.code == "NO_BUILD" and res.zoneId == 1 and res.zone == "通路"
        and sameFlat(res.areas, { 2010, 2005, 10, 5, 2012, 2010, 8, 7 }) and alice.inv:getAllTypeRecurse(D1):size() == 3,
        "壓到兩個：回第一個的名稱，兩處都標（實際 " .. table.concat(res.areas or {}, ",") .. "）")
    alice.x, alice.y = 1995, 2005
    res = T.cmd(alice, "create", { rects = { rect(1990, 2000, 10, 10) }, deedType = D1 })
    check(res.ok, "只相接（右邊界貼著禁建區）：可以建立")
    local near = MSH.Registry.get(res.claimId)
    T.advance(600)
    -- 兩塊：左邊那塊沒事，右邊那塊 (1990,2000) 12×10 的 x 2000–2001 壓到 1 號
    pv = T.cmd(alice, "preview", { rects = { rect(1980, 2000, 10, 10), rect(1990, 2000, 12, 10) }, deedType = D1 })
    local zc = checkOf(pv, "zones")
    check(pv.ok and pv.pass == false and zc ~= nil and zc.ok == false and zc.code == "NO_BUILD" and zc.name == "zones"
        and zc.zone == "通路" and sameFlat(zc.areas, { 2000, 2000, 2, 10 }) and checkOf(pv, "roads") ~= nil,
        "預檢：zones 這組失敗、組名不被禁建區名稱蓋掉、只標壓到的那一塊，其他檢查照跑")
    T.advance(600)
    pv = T.cmd(alice, "preview", { rects = { rect(1970, 2000, 10, 10) }, deedType = D1 })
    zc = checkOf(pv, "zones")
    check(zc ~= nil and zc.ok == true and #pv.checks == 11, "有禁建區、沒壓到：預檢列出這一項且通過（11 組）")
    res = T.cmd(alice, "redraw", { claimId = near.claimId, rects = { rect(1995, 2000, 10, 10) }, expectedRevision = near.revision })
    check(res.code == "NO_BUILD" and near.lifecycle == "active" and MSH.Registry.get(near.claimId) == near,
        "重新框選壓到禁建區：NO_BUILD、舊屋不動")

    T.section("Zones：既有安全屋不動、列給管理員")
    res = T.cmd(boss, "adminAddZone", { name = "後加的", rects = { rect(1985, 1995, 10, 10) } })
    check(res.ok and near.lifecycle == "active" and T.houseOf("@MSH:" .. near.claimId) ~= nil, "後加的禁建區蓋到既有安全屋：安全屋照留")
    local row
    for _, z in ipairs(res.zones) do
        if z.name == "後加的" then row = z end
    end
    check(row ~= nil and #row.claims == 1 and row.claims[1].claimId == near.claimId and row.claims[1].owner == "alice"
        and row.claimCount == 1, "adminZones 列出壓到它的安全屋（編號、屋主、總數）")
    check(#res.zones[1].claims == 0 and res.zones[1].claimCount == 0, "沒壓到的禁建區不列安全屋")
    -- 超過列出上限：只列前 MAX_LIST_CLAIMS 間，總數照實
    local R = MSH.Registry
    for i = 1, MSH.Zones.MAX_LIST_CLAIMS + 1 do
        R.put(R.newRecord({ claimId = R.allocId(), rects = { rect(4000 + i * 3, 4000, 2, 2) }, title = "t", owner = "u" .. i,
            source = MSH.SOURCE.DEED, deedTier = 1, createdAt = T.now }))
    end
    res = T.cmd(boss, "adminAddZone", { name = "大片", rects = { rect(4000, 4000, 100, 5) } })
    row = res.ok and res.zones[#res.zones]
    check(row and #row.claims == MSH.Zones.MAX_LIST_CLAIMS and row.claimCount == MSH.Zones.MAX_LIST_CLAIMS + 1,
        "壓到 21 間：列出 20 間、總數 21")

    T.section("Zones：玩家看得到的公開清單（zones）與變更推送（zonesSync）")
    boot()
    boss = T.player({ name = "boss", admin = true })
    alice = T.player({ name = "alice" })
    local bob = T.player({ name = "bob" })
    local everyone = { boss, alice, bob }
    local function syncsOf(p)
        local out = {}
        for _, m in ipairs(T.outbox[p.name] or {}) do
            if m.command == "zonesSync" then out[#out + 1] = m.args end
        end
        return out
    end
    local function noAdminFields(zones)
        for _, z in ipairs(zones) do
            if z.claims ~= nil or z.claimCount ~= nil then return false end
        end
        return true
    end
    -- 每位在線玩家都剛好收到 n 則，最後一則是 rev、zones 個數
    local function allGot(n, rev, count)
        for _, p in ipairs(everyone) do
            local s = syncsOf(p)
            local last = s[#s]
            if #s ~= n or (n > 0 and (last.rev ~= rev or #last.zones ~= count or not noAdminFields(last.zones))) then
                return false
            end
        end
        return true
    end
    res = T.cmd(alice, "zones", {})
    check(res ~= nil and res.ok and #res.zones == 0 and res.rev == 0, "一般玩家查 zones（不是 NOT_ADMIN）：空清單、開服 rev 0")
    -- 已經建好、後來被框進禁建區的安全屋：adminZones 列出它，公開清單不能帶
    R = MSH.Registry
    R.put(R.newRecord({ claimId = R.allocId(), rects = { rect(5000, 5000, 4, 4) }, title = "t", owner = "carol",
        source = MSH.SOURCE.DEED, deedTier = 1, createdAt = T.now }))
    local lockedAtSend, realSend = {}, sendServerCommand
    sendServerCommand = function(a, b, c, d)
        if c == "zonesSync" then lockedAtSend[#lockedAtSend + 1] = MSH.Srv.locked end
        return realSend(a, b, c, d)
    end
    res = T.cmd(boss, "adminAddZone", { name = "Base", rects = { rect(4998, 4998, 10, 10) } })
    sendServerCommand = realSend
    local s1 = syncsOf(alice)[1]
    check(res.ok and res.zones[1].claimCount == 1 and allGot(1, 1, 1) and s1.zones[1].id == 1 and s1.zones[1].name == "Base"
        and s1.zones[1].rects[1].x == 4998 and s1.zones[1].rects[1].w == 10,
        "新增成功：每位在線玩家（含管理員自己）各收到一次 zonesSync，rev 加一、有編號名稱各塊、沒有 claims／claimCount")
    check(#lockedAtSend == 3 and lockedAtSend[1] == false and lockedAtSend[3] == false, "zonesSync 在放鎖之後才送")
    T.advance(1000)
    res = T.cmd(alice, "zones", {})
    check(res.ok and res.rev == 1 and #res.zones == 1 and res.zones[1].id == 1 and res.zones[1].rects[1].h == 10
        and noAdminFields(res.zones), "一般玩家查 zones：拿到清單與 rev 1，沒有 claims／claimCount")
    res = T.cmd(alice, "zones", {})
    check(res == nil, "1 秒內重送：冷卻中直接丟、不回覆")
    T.failWrites = true
    res = T.cmd(boss, "adminAddZone", { name = "C", rects = { rect(3100, 3000, 5, 5) } })
    local addFail = res.code == "SAVE_FAILED"
    res = T.cmd(boss, "adminRemoveZone", { zoneId = 1 })
    T.failWrites = false
    check(addFail and res.code == "SAVE_FAILED" and MSH.Zones.rev == 1 and allGot(1, 1, 1),
        "新增、刪除存檔失敗：不推送、rev 不變")
    res = T.cmd(boss, "adminRemoveZone", { zoneId = 9 })
    check(res.code == "NOT_FOUND" and MSH.Zones.rev == 1 and allGot(1, 1, 1), "刪不存在的：不推送")
    res = T.cmd(boss, "adminRemoveZone", { zoneId = 1 })
    check(res.ok and MSH.Zones.rev == 2 and allGot(2, 2, 0), "刪除成功：每人再收到一次，rev 2、清單空了")
    T.netUp, MSH.Srv.netUp = false, false
    local early = #T.netEarly
    local okB = pcall(MSH.Zones.broadcast)
    T.netUp, MSH.Srv.netUp = true, true
    check(okB and #T.netEarly == early and allGot(2, 2, 0), "OnServerStarted 之前（netUp 是 false）：不碰連線、不推送")
end
