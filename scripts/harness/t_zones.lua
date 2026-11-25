-- 管理員畫的區域（Zones.lua，使用者 2026-10-16；道路豁免區 2026-11-25）：管理員指令（權限、驗證、存檔失敗、上限、編號不重用）、
-- zones.json（一區一行、重開保留、壞檔整檔拒絕、開服壞檔 fail closed、執行中壞檔沿用上一份、輪詢連兩次相同才套用、BOM、
-- 寫入前同步磁碟、rev 不符、〔重新載入〕、zones.txt 遷移）；建立、預檢、重新框選壓到禁建區時 NO_BUILD（壓到的部分、相接不算）、
-- 已經建好的安全屋不動但列給管理員、沒有禁建區時預檢不列這一項、道路豁免區不算禁建區；玩家的公開清單 zones 與變更推送 zonesSync（rev）。
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
    local EMPTY = '{\n  "next": 1,\n  "zones": [\n  ]\n}'
    local function fileText()
        local f = zonesFile()
        return f and table.concat(f.lines, "\n")
    end
    local function setFile(text, p)
        local lines = {}
        for l in string.gmatch(text .. "\n", "(.-)\n") do lines[#lines + 1] = l end
        T.files[p or MSH.Zones.path()] = { lines = lines }
    end
    -- 一輪輪詢（WATCH_MS 後的 OnTick）
    local function poll(n)
        for _ = 1, n or 1 do
            T.advance(MSH.Zones.WATCH_MS)
            T.fire("OnTick")
        end
    end
    local function alertsTo(p, code)
        local out = {}
        for _, m in ipairs(T.outbox[p.name] or {}) do
            if m.command == "alert" and m.args.code == code then out[#out + 1] = m.args.detail end
        end
        return out
    end
    local function zoneJson(id, kind, name, x, y, w, h)
        return '    {"id": ' .. id .. ', "kind": "' .. kind .. '", "name": "' .. name .. '", "rects": [{"x": ' .. x .. ', "y": ' .. y
            .. ', "w": ' .. w .. ', "h": ' .. h .. '}]}'
    end
    local function doc(nextId, ...)
        local zs = { ... }
        local lines = { "{", '  "next": ' .. nextId .. ",", '  "zones": [' }
        for i, z in ipairs(zs) do lines[#lines + 1] = z .. (i < #zs and "," or "") end
        lines[#lines + 1] = "  ]"
        lines[#lines + 1] = "}"
        return table.concat(lines, "\n")
    end

    T.section("Zones：權限與輸入驗證")
    boot()
    check(fileText() == EMPTY, "兩檔都沒有：開服寫一份空的 zones.json 範本（" .. tostring(fileText()) .. "）")
    -- 空範本寫不進去：照樣是空清單、不擋，但沒有採用任何一份（沒有 appliedAt）
    boot({ beforeStart = function(env) env.failWrites = true end })
    T.failWrites = false
    check(not MSH.Zones.unreadable and #MSH.Zones.list == 0 and MSH.Zones.appliedAt == nil and zonesFile() == nil,
        "空範本寫不進去：空清單、不擋、沒有 appliedAt")
    boot()
    local boss = T.player({ name = "boss", admin = true })
    local alice = T.player({ name = "alice" })
    local L = rect(1000, 1000, 30, 10)
    local res = T.cmd(alice, "adminZones", {})
    check(res ~= nil and res.code == "NOT_ADMIN", "非管理員查禁建區：NOT_ADMIN")
    res = T.cmd(alice, "adminAddZone", { name = "x", rects = { L } })
    check(res.code == "NOT_ADMIN" and fileText() == EMPTY and #MSH.Zones.list == 0, "非管理員新增：NOT_ADMIN、不寫檔")
    res = T.cmd(boss, "adminZones", {})
    check(res.ok and #res.zones == 0 and res.max == MSH.LIMIT.MAX_ZONES and res.unreadable == false and res.rev == 0
        and res.file.path == MSH.Zones.path() and res.file.appliedAt ~= nil and res.file.error == nil,
        "管理員查：空清單、上限、讀得到、檔案路徑與採用時間、沒有錯誤")
    res = T.cmd(boss, "adminAddZone", { name = "   ", rects = { L } })
    local blank = res.code == "BAD_TITLE"
    res = T.cmd(boss, "adminAddZone", { name = "a[b]", rects = { L } })
    check(blank and res.code == "BAD_TITLE" and fileText() == EMPTY, "空白名稱、含 []：BAD_TITLE、不寫檔")
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
    check(res.ok and res.zoneId == 1 and #res.zones == 1 and z1.name == "軍事基地通路" and #z1.rects == 2 and z1.kind == "nobuild"
        and z1.rects[2].y == 1010 and countLogs("ADMIN_ZONE_ADD") == 1, "新增成功：編號 1、沒帶 kind＝禁建區、名稱去空白、兩塊、寫 audit")
    local f = zonesFile()
    local want1 = '    {"id": 1, "kind": "nobuild", "name": "軍事基地通路", "rects": [{"x": 1000, "y": 1000, "w": 30, "h": 10}, '
        .. '{"x": 1000, "y": 1010, "w": 10, "h": 20}]}'
    check(f ~= nil and f.lines[2] == '  "next": 2,' and f.lines[4] == want1 and #f.lines == 6,
        "zones.json：next＋一區一行（" .. tostring(f and f.lines[4]) .. "）")
    res = T.cmd(boss, "adminAddZone", { name = "B", rects = { rect(3000, 3000, 5, 5) } })
    check(res.ok and res.zoneId == 2 and #zonesFile().lines == 7 and zonesFile().lines[4] == want1 .. ",",
        "第二個：編號 2、整份覆寫、一區一行")
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
    check(#f.lines == 6 and f.lines[2] == '  "next": 3,' and f.lines[4] == want1, "刪除後檔案只剩 1 號，next 仍是 3")
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
    check(MSH.Zones.unreadable and MSH.Health.blocked() and #MSH.Zones.list == 0 and MSH.Zones.fileError.code == "JSON",
        "重開：檔案是空的＝JSON 錯、fail closed")
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
    local function zoneLine3(body) return function(l) l[5] = "    {" .. body .. "}" end end
    local R9 = '"rects": [{"x": 9, "y": 9, "w": 1, "h": 1}]'
    local function whole(text) return function(l)
        for i = #l, 1, -1 do l[i] = nil end
        l[1] = text
    end end
    local cases = {
        { "最後一行被截掉", function(l) l[#l] = nil end, { code = "JSON", line = 6 } },
        { "尾逗號", function(l) l[5] = l[5] .. "," end, { code = "JSON", line = 6 } },
        { "重複鍵", zoneLine3('"id": 3, "id": 4, "kind": "nobuild", "name": "x", ' .. R9), { code = "JSON", line = 5 } },
        { "zones 是物件", whole('{"zones": {}}'), { code = "NO_ZONES" } },
        { "沒有 zones", whole('{"next": 4}'), { code = "NO_ZONES" } },
        { "缺 kind", zoneLine3('"id": 3, "name": "x", ' .. R9), { code = "BAD_KIND", index = 2 } },
        { "kind 寫錯", zoneLine3('"id": 3, "kind": "allow", "name": "x", ' .. R9), { code = "BAD_KIND", index = 2 } },
        { "未知鍵", zoneLine3('"id": 3, "kind": "nobuild", "name": "x", "color": "red", ' .. R9),
            { code = "UNKNOWN_FIELD", index = 2, field = "color" } },
        { "各塊裡的未知鍵", zoneLine3('"id": 3, "kind": "nobuild", "name": "x", "rects": [{"x": 9, "y": 9, "w": 1, "h": 1, "z": 0}]'),
            { code = "UNKNOWN_FIELD", index = 2, field = "z" } },
        { "重複編號", function(l) l[5] = zoneJson(1, "nobuild", "dup", 9, 9, 1, 1) end, { code = "DUP_ID", index = 2, id = 1 } },
        { "編號 0", function(l) l[5] = zoneJson(0, "nobuild", "x", 9, 9, 1, 1) end, { code = "BAD_ID", index = 2, id = 0 } },
        { "編號是字串", zoneLine3('"id": "3", "kind": "nobuild", "name": "x", ' .. R9), { code = "BAD_ID", index = 2 } },
        { "名稱含 []", function(l) l[5] = zoneJson(3, "nobuild", "a[b]", 9, 9, 1, 1) end, { code = "BAD_NAME", index = 2 } },
        { "一塊的寬是 0", function(l) l[5] = zoneJson(3, "nobuild", "x", 5, 5, 0, 5) end,
            { code = "BAD_RECTS", index = 2, reason = "PIECES" } },
        { "外框超過 ZONE_SIDE", function(l) l[5] = zoneJson(3, "nobuild", "x", 5, 5, MSH.LIMIT.ZONE_SIDE + 1, 5) end,
            { code = "BAD_RECTS", index = 2, reason = "SIDE" } },
    }
    local function sameErr(e, want)
        if type(e) ~= "table" then return false end
        for _, k in ipairs({ "code", "line", "index", "id", "field", "reason", "max" }) do
            if e[k] ~= want[k] then return false end
        end
        return true
    end
    for _, c in ipairs(cases) do
        Z = bootWith(c[2])
        check(Z.unreadable and MSH.Health.blocked() and #Z.list == 0 and sameErr(Z.fileError, c[3]) and countLogs("ZONES_FILE") == 1,
            c[1] .. "：整檔拒絕、當成讀不開、health blocked、錯誤 " .. c[3].code .. "（實際 "
            .. tostring(Z.fileError and Z.fileError.code) .. " line " .. tostring(Z.fileError and Z.fileError.line) .. "）")
    end
    boss = T.player({ name = "boss", admin = true })
    res = T.cmd(boss, "adminZones", {})
    check(res.ok and res.unreadable and res.file.error.code == "BAD_RECTS" and res.file.error.reason == "SIDE"
        and res.file.appliedAt == nil and #res.zones == 0, "開服就壞：adminZones 帶 file.error、沒有 appliedAt（沒有採用任何一份）")
    Z = bootWith(function(l) table.remove(l, 2) end)
    check(not Z.unreadable and #Z.list == 2 and Z.nextId == 4, "沒寫 next：取最大編號＋1")
    Z = bootWith(function(l) l[2] = '  "next": "x",' end)
    check(not Z.unreadable and Z.nextId == 4, "next 寫錯：當成沒寫")
    local max1 = MSH.LIMIT.MAX_ZONES
    MSH.LIMIT.MAX_ZONES = 1
    local _, tooMany = Z.parse(table.concat(saved, "\n"))
    MSH.LIMIT.MAX_ZONES = max1
    local _, longKey = Z.parse('{"zones": [], "a\\u0007' .. string.rep("b", 50) .. '": 1}')
    check(sameErr(tooMany, { code = "TOO_MANY", max = 1 }) and longKey.code == "UNKNOWN_FIELD" and longKey.index == nil
        and longKey.field == "a" .. string.rep("b", 39), "超過上限 TOO_MANY 帶 max；最上層未知鍵：去控制字元、截到 40 字")
    local zs, zn = Z.parse('{"zones": []}')
    check(zs ~= nil and #zs == 0 and zn == 1, '{"zones": []} 是合法的空清單')
    -- 編號上限 LIMIT.MAX_ZONE_ID：parse 收到上限為止；next 最多上限＋1
    local maxId = MSH.LIMIT.MAX_ZONE_ID
    local atMax = Z.parse(doc(1, zoneJson("999999999", "nobuild", "末", 9, 9, 1, 1)))
    local _, overMax = Z.parse(doc(1, zoneJson("1000000000", "nobuild", "末", 9, 9, 1, 1)))
    local _, bigNext = Z.parse(doc("1000000001", zoneJson(1, "nobuild", "a", 9, 9, 1, 1)))
    check(maxId == 999999999 and atMax ~= nil and sameErr(overMax, { code = "BAD_ID", index = 1, id = 1000000000 })
        and bigNext == 2, "編號上限：999999999 收、1000000000 BAD_ID；next 超過上限＋1 當成沒寫")
    -- 數字照 JSON 文法；巢狀深度上限；解碼器丟例外也是檔案錯誤（JSON）
    local J = MSH.Json
    local numsOk = J.decode("0") == 0 and J.decode("-0") == 0 and J.decode("1.5e3") == 1500 and J.decode("10") == 10
        and J.decode("2E-1") == 0.2
    for _, bad in ipairs({ "01", "1.", ".5", "-", "1e", "+1", "-01", "1.e3" }) do
        numsOk = numsOk and J.decode(bad) == nil
    end
    local _, leadZero = Z.parse('{"zones": [{"id": 01, "kind": "nobuild", "name": "x", ' .. R9 .. '}]}')
    check(numsOk and leadZero.code == "JSON", "數字照 JSON 文法：不收前導零、1.、.5、缺指數")
    local deep = string.rep("[", J.MAX_DEPTH + 1) .. string.rep("]", J.MAX_DEPTH + 1)
    local okDeep = J.decode(string.rep("[", J.MAX_DEPTH) .. string.rep("]", J.MAX_DEPTH))
    local _, deepErr = J.decode(deep)
    local _, deepZone = Z.parse('{"zones": [], "next": ' .. deep .. "}")
    check(okDeep ~= nil and deepErr ~= nil and string.find(deepErr.msg, "too deep", 1, true) ~= nil and deepZone.code == "JSON",
        "巢狀深度上限：" .. J.MAX_DEPTH .. " 層收、多一層是解析錯誤")
    local realDecode = J.decode
    J.decode = function() error("boom") end
    local throwOk, _, thrown = pcall(Z.parse, doc(1))
    J.decode = realDecode
    check(throwOk and thrown ~= nil and thrown.code == "JSON", "解碼器丟例外：Z.parse 回 JSON 錯誤、不往外丟")
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
    local hasZonesFile, hasStore = false, false
    for _, b in ipairs(MSH.Health.state.blockers) do
        if b == "ZonesFile" then hasZonesFile = true end
        if b == "PrivateStore" then hasStore = true end
    end
    check(hasZonesFile and not hasStore and view and addRefused and res.code == "SAVE_FAILED" and sameFile(),
        "讀不開：列成 ZonesFile（不是 PrivateStore）、清單標 unreadable、新增與刪除都 SAVE_FAILED、不覆寫檔案")
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

    T.section("Zones：手改 zones.json（連兩次相同才套用、只改排版不推、壞檔沿用上一份、通知只送一次）")
    boot()
    boss = T.player({ name = "boss", admin = true })
    alice = T.player({ name = "alice" })
    everyone = { boss, alice }
    local Zs = MSH.Zones
    path = Zs.path()
    local A1 = zoneJson(1, "nobuild", "甲", 100, 100, 10, 10)
    local B2 = zoneJson(2, "roadexempt", "乙", 200, 200, 10, 10)
    setFile(doc(3, A1, B2))
    poll()
    local seenOnce = #Zs.list == 0 and Zs.rev == 0 and #syncsOf(alice) == 0
    T.advance(1000)
    T.fire("OnTick")
    local tooSoon = #Zs.list == 0
    poll()
    local s = syncsOf(alice)
    check(seenOnce and tooSoon and #Zs.list == 2 and Zs.list[2].kind == "roadexempt" and Zs.rev == 1 and #s == 1 and s[1].rev == 1
        and s[1].zones[2].kind == "roadexempt" and noAdminFields(s[1].zones) and s[1].file == nil,
        "新文字只看到一次不套用（間隔未滿也不讀），連兩次相同才套用：rev＋1、推 zonesSync（帶 kind、不帶 claims／file）")
    local rl = alertsTo(boss, "ZONES_RELOADED")
    check(#rl == 1 and rl[1] == "2,0,0" and #alertsTo(alice, "ZONES_RELOADED") == 0 and countLogs("ZONES_RELOAD") == 1,
        "套用：通知線上管理員一次 ZONES_RELOADED「新增,刪除,變更」2,0,0（一般玩家不收）、記 ZONES_RELOAD")
    local appliedNow = T.now
    res = T.cmd(boss, "adminZones", {})
    check(res.ok and res.file.appliedAt == appliedNow and res.rev == 1 and res.zones[2].kind == "roadexempt" and res.zones[2].claimCount == 0,
        "adminZones：appliedAt 是套用的時間、兩種區都列")
    setFile((string.gsub(doc(3, A1, B2), ", ", ",   ")))
    poll(2)
    check(Zs.rev == 1 and #syncsOf(alice) == 1 and #alertsTo(boss, "ZONES_RELOADED") == 1 and Zs.text == fileText(),
        "只改排版：採用但不推、rev 不變、不通知")
    local B2b = zoneJson(2, "roadexempt", "乙二", 200, 200, 10, 10)
    local good = doc(3, A1, B2b)
    setFile(good)
    poll(2)
    rl = alertsTo(boss, "ZONES_RELOADED")
    check(Zs.rev == 2 and Zs.list[2].name == "乙二" and allGot(2, 2, 2) and rl[#rl] == "0,0,1", "改名：變更 1、rev 2、再推一次")
    -- 尾逗號：第 5 行多一個逗號，第 6 行的 ] 才出錯
    setFile((string.gsub(good, "%]}\n  %]", "]},\n  ]")))
    local realParse, parses = Zs.parse, 0
    Zs.parse = function(t)
        parses = parses + 1
        return realParse(t)
    end
    poll(5)
    Zs.parse = realParse
    local fe = alertsTo(boss, "ZONES_FILE")
    MSH.Health.evaluate(T.now)
    check(#Zs.list == 2 and Zs.list[2].name == "乙二" and Zs.fileError.code == "JSON" and Zs.fileError.line == 6 and not Zs.unreadable
        and not MSH.Health.blocked() and #fe == 1 and fe[1] == "JSON,6" and countLogs("ZONES_FILE") == 1 and parses == 1
        and Zs.rev == 2 and allGot(2, 2, 2),
        "執行中讀到壞檔：兩種區沿用上一份、記錯誤、不擋、通知 ZONES_FILE「JSON,6」一次、同一份壞檔不再解析（實際解析 " .. parses .. " 次）")
    res = T.cmd(boss, "adminZones", {})
    check(res.ok and res.unreadable == false and res.file.error.code == "JSON" and res.file.error.line == 6 and #res.zones == 2,
        "adminZones 帶 file.error（code、line），清單照舊")
    local bad = fileText()
    res = T.cmd(boss, "adminAddZone", { name = "x", rects = { rect(500, 500, 5, 5) } })
    local addBad = res.code == "SAVE_FAILED" and res.reason == "FILE"
    res = T.cmd(boss, "adminRemoveZone", { zoneId = 1 })
    check(addBad and res.code == "SAVE_FAILED" and res.reason == "FILE" and fileText() == bad and #Zs.list == 2
        and #alertsTo(boss, "ZONES_FILE") == 1, "磁碟是壞檔：遊戲內新增、刪除回 SAVE_FAILED reason FILE、不覆寫、不再通知")
    setFile(good)
    poll()
    rl = alertsTo(boss, "ZONES_RELOADED")
    check(Zs.fileError == nil and rl[#rl] == "0,0,0" and Zs.rev == 2, "改回採用中的內容：錯誤解除、通知 0,0,0、不推")
    T.files[path] = nil
    poll(2)
    fe = alertsTo(boss, "ZONES_FILE")
    check(#Zs.list == 2 and Zs.fileError.code == "MISSING" and fe[#fe] == "MISSING", "執行中檔案被刪：沿用上一份、通知 MISSING")
    res = T.cmd(boss, "adminAddZone", { name = "丙", rects = { rect(300, 300, 5, 5) } })
    check(res.ok and res.zoneId == 3 and Zs.fileError == nil and #zonesFile().lines == 8 and res.file.error == nil,
        "磁碟沒檔：遊戲內新增照記憶體重建整份、錯誤解除")

    T.section("Zones：遊戲內寫入前先讀磁碟、rev 不符")
    local Z3 = zoneJson(3, "nobuild", "丙", 300, 300, 5, 5)
    setFile(doc(10, A1, B2b, Z3, zoneJson(9, "nobuild", "手改", 400, 400, 5, 5)))
    local lockedSends = {}
    local realSend2 = sendServerCommand
    sendServerCommand = function(a, b, c, d)
        if c == "zonesSync" then lockedSends[#lockedSends + 1] = MSH.Srv.locked end
        return realSend2(a, b, c, d)
    end
    res = T.cmd(boss, "adminAddZone", { name = "丁", rects = { rect(600, 600, 5, 5) } })
    sendServerCommand = realSend2
    local ids = {}
    for _, z in ipairs(Zs.list) do ids[#ids + 1] = z.id end
    rl = alertsTo(boss, "ZONES_RELOADED")
    check(res.ok and res.zoneId == 10 and table.concat(ids, ",") == "1,2,3,9,10" and string.find(fileText(), "手改", 1, true) ~= nil
        and Zs.rev == 5 and rl[#rl] == "1,0,0", "磁碟已變：先採用磁碟版（手改的 9 號還在）、再疊上新增的 10 號（實際 " .. table.concat(ids, ",") .. "）")
    check(#lockedSends == 4 and not lockedSends[1] and not lockedSends[4], "寫入前採用的推送與新增的推送都在放鎖之後")
    res = T.cmd(boss, "adminRemoveZone", { zoneId = 9, rev = Zs.rev - 1 })
    check(res.code == "STALE_REVISION" and res.rev == Zs.rev and #res.zones == 5 and res.file.path == path and #Zs.list == 5,
        "rev 不符：STALE_REVISION、帶最新清單、不刪")
    res = T.cmd(boss, "adminRemoveZone", { zoneId = 9, rev = Zs.rev })
    check(res.ok and #Zs.list == 4 and string.find(fileText(), "手改", 1, true) == nil and countLogs("ADMIN_ZONE_REMOVE") == 1,
        "rev 相符：刪除")
    local okText = fileText()
    MSH.Srv.locked = true
    setFile(doc(11, A1))
    poll(3)
    local lockSkip = #Zs.list == 4
    MSH.Srv.locked = false
    poll(2)
    check(lockSkip and #Zs.list == 1, "拿著鎖時輪詢跳過，放鎖後照常套用")

    T.section("Zones：〔重新載入〕adminReloadZones")
    res = T.cmd(alice, "adminReloadZones", {})
    check(res.code == "NOT_ADMIN", "非管理員：NOT_ADMIN")
    setFile(okText)
    res = T.cmd(boss, "adminReloadZones", {})
    check(res.ok and #res.zones == 4 and #Zs.list == 4 and res.file.appliedAt == T.now and res.rev == Zs.rev,
        "立即讀檔（不等兩次輪詢）：回最新清單")
    setFile("{")
    res = T.cmd(boss, "adminReloadZones", {})
    local n1 = #alertsTo(boss, "ZONES_FILE")
    local again = T.cmd(boss, "adminReloadZones", {})
    check(res.ok and res.file.error.code == "JSON" and #res.zones == 4 and again.ok and #alertsTo(boss, "ZONES_FILE") == n1,
        "壞檔：照樣 ok、file.error 有值、清單照舊；同一份再按不再通知")

    T.section("Zones：開服就壞 → 修好檔不必重開；BOM")
    setFile('{"zones": [}')
    boot({ keepFiles = true })
    boss = T.player({ name = "boss", admin = true })
    MSH.Health.evaluate(T.now)
    local blockedAtBoot = MSH.Health.blocked() and MSH.Zones.unreadable
    poll(3)
    local stillBlocked = MSH.Zones.unreadable and #alertsTo(boss, "ZONES_FILE") == 0
    setFile(doc(2, A1))
    poll(2)
    MSH.Health.evaluate(T.now)
    rl = alertsTo(boss, "ZONES_RELOADED")
    res = T.cmd(boss, "adminZones", {})
    check(blockedAtBoot and stillBlocked and not MSH.Zones.unreadable and not MSH.Health.blocked() and #MSH.Zones.list == 1
        and rl[1] == "1,0,0" and res.file.appliedAt ~= nil and res.file.error == nil, "開服壞檔擋住；修好後輪詢採用就解除，不必重開")
    setFile("\239\187\191" .. doc(2, A1))
    boot({ keepFiles = true })
    check(not MSH.Zones.unreadable and #MSH.Zones.list == 1, "UTF-8 BOM（記事本）：照常載入")
    -- Kahlua 的字串是 UTF-16，BOM 讀進來是一個字元 U+FEFF：假裝第一個字元是它
    setFile("\1" .. doc(2, A1))
    local realByte = string.byte
    string.byte = function(str, i, ...)
        if (i == nil or i == 1) and realByte(str, 1) == 1 then return 65279 end
        return realByte(str, i, ...)
    end
    local okBoot = pcall(boot, { keepFiles = true })
    string.byte = realByte
    check(okBoot and not MSH.Zones.unreadable and #MSH.Zones.list == 1, "Kahlua 的 U+FEFF：照常載入")

    T.section("Zones：舊 zones.txt 遷移")
    local legacy = { "1\tnext\t5\t2", "1\tzone\t1\t1000,1000,30,10;1000,1010,10,20\t軍事基地通路", "1\tzone\t3\t3000,3000,5,5\tB" }
    local function marker()
        local f = T.files[MSH.Zones.markerPath()]
        return f and table.concat(f.lines, "\n")
    end
    local function bootLegacy(lines, opts)
        T.files[path] = nil
        T.files[MSH.Zones.markerPath()] = nil
        local copy = {}
        for i, l in ipairs(lines) do copy[i] = l end
        T.files[MSH.Zones.legacyPath()] = { lines = copy }
        opts = opts or {}
        opts.keepFiles = true
        boot(opts)
        return MSH.Zones
    end
    local function legacyKept(lines)
        local now = T.files[MSH.Zones.legacyPath()].lines
        return table.concat(now, "\n") == table.concat(lines, "\n")
    end
    Z = bootLegacy(legacy)
    check(#Z.list == 2 and Z.list[1].kind == "nobuild" and Z.list[2].kind == "nobuild" and Z.list[1].name == "軍事基地通路"
        and #Z.list[1].rects == 2 and Z.list[1].rects[2].h == 20 and Z.list[2].id == 3 and Z.nextId == 5 and not Z.unreadable
        and zonesFile().lines[2] == '  "next": 5,' and zonesFile().lines[4] == want1 .. "," and legacyKept(legacy)
        and countLogs("ZONES_MIGRATED") == 1 and marker() == "done",
        "zones.json 不存在：zones.txt 全部標成禁建區寫成 JSON、讀回相同、zones.txt 不動、紀錄 done")
    boot({ keepFiles = true })
    check(#MSH.Zones.list == 2 and countLogs("ZONES_MIGRATED") == 0, "重開：zones.json 已在，不再遷移")
    local realWriter2 = getFileWriter
    Z = bootLegacy(legacy, { beforeStart = function()
        getFileWriter = function(p, c, a)
            if p ~= path then return realWriter2(p, c, a) end
            T.silentWrites = true
            local w = realWriter2(p, c, a)
            T.silentWrites = false
            return w
        end
    end })
    getFileWriter = realWriter2
    MSH.Health.evaluate(T.now)
    check(Z.unreadable and MSH.Health.blocked() and #Z.list == 0 and Z.fileError.code == "MIGRATE" and legacyKept(legacy)
        and countLogs("ZONES_MIGRATED") == 0, "寫出的 JSON 讀回不符（沒寫進去）：MIGRATE、fail closed、zones.txt 不動")
    local broken = { legacy[1], legacy[2], "garbage" }
    Z = bootLegacy(broken)
    local migLogged = false
    for _, line in ipairs(T.logs) do
        if string.find(line, "^ZONES_FILE\tfile\t%-\tMIGRATE\tzones%.txt unreadable") then migLogged = true end
    end
    check(Z.unreadable and Z.fileError.code == "MIGRATE" and zonesFile() == nil and legacyKept(broken) and migLogged,
        "zones.txt 壞了：MIGRATE、記 ZONES_FILE、fail closed、不寫 zones.json")
    -- 讀回是合法 JSON 卻對不上（寫進去的名稱被換掉）：zones.json 改寫成一行說明；重新載入、遊戲內新增、重開服都不採用
    local function bootMismatch(noteWritable)
        local writes = 0
        return bootLegacy(legacy, { beforeStart = function()
            getFileWriter = function(p, c, a)
                if p ~= path then return realWriter2(p, c, a) end
                writes = writes + 1
                if writes > 1 then
                    if noteWritable then return realWriter2(p, c, a) end
                    return { writeln = function() end, write = function() end, close = function() end }
                end
                local w = realWriter2(p, c, a)
                return { writeln = function(_, s) w:writeln((string.gsub(s, '"name": "B"', '"name": "C"'))) end,
                    write = function(_, s) w:write(s) end, close = function() w:close() end }
            end
        end })
    end
    Z = bootMismatch(true)
    getFileWriter = realWriter2
    local noted = Z.unreadable and Z.fileError.code == "MIGRATE" and fileText() == Z.MIGRATE_NOTE and legacyKept(legacy)
    boss = T.player({ name = "boss", admin = true })
    res = T.cmd(boss, "adminReloadZones", {})
    local reloadKept = res.ok and res.unreadable and res.file.error.code == "MIGRATE"
    boot({ keepFiles = true })
    check(noted and reloadKept and MSH.Zones.unreadable and MSH.Zones.fileError.code == "MIGRATE" and countLogs("ZONES_MIGRATED") == 0,
        "遷移讀回對不上：zones.json 改寫成說明、MIGRATE；重新載入照樣擋；重開服也擋（錯誤碼 MIGRATE、不再遷移）")
    Z = bootMismatch(false)
    getFileWriter = realWriter2
    local wrongKept = Z.unreadable and string.find(fileText(), '"name": "C"', 1, true) ~= nil and Z.rejected == fileText()
    boss = T.player({ name = "boss", admin = true })
    res = T.cmd(boss, "adminReloadZones", {})
    local reload2 = res.ok and res.unreadable and #res.zones == 0 and res.file.error.code == "MIGRATE"
    res = T.cmd(boss, "adminAddZone", { name = "x", rects = { rect(500, 500, 5, 5) } })
    poll(3)
    check(wrongKept and reload2 and res.code == "SAVE_FAILED" and res.reason == "FILE" and Z.unreadable and #Z.list == 0
        and string.find(fileText(), '"name": "C"', 1, true) ~= nil,
        "說明寫不進去：那份對不上的 JSON 不被重新載入、遊戲內新增、輪詢採用（這次開服照樣擋）")
    boot({ keepFiles = true })
    check(MSH.Zones.unreadable and MSH.Zones.fileError.code == "MIGRATE" and #MSH.Zones.list == 0 and marker() == "pending"
        and countLogs("ZONES_MIGRATED") == 0, "說明寫不進去之後重開服：紀錄還是 pending、zones.json 和 zones.txt 對不上 → MIGRATE、不採用")
    -- MIGRATE 期間管理員手改成合法檔：輪詢採用＝照他的意思，紀錄改 done，重開服正常
    setFile(doc(7, zoneJson(1, "nobuild", "手改", 1000, 1000, 5, 5)))
    poll(2)
    local handTaken = not MSH.Zones.unreadable and #MSH.Zones.list == 1 and marker() == "done"
    boot({ keepFiles = true })
    check(handTaken and not MSH.Zones.unreadable and #MSH.Zones.list == 1 and MSH.Zones.list[1].name == "手改",
        "MIGRATE 期間手改成合法檔：輪詢採用、紀錄 done；重開服照常載入手改的那份")
    -- 讀回截斷（最後一行沒寫進去，解析不了）：也改寫成說明；重開服 MIGRATE
    local tw = 0
    Z = bootLegacy(legacy, { beforeStart = function()
        getFileWriter = function(p, c, a)
            if p ~= path then return realWriter2(p, c, a) end
            tw = tw + 1
            local w = realWriter2(p, c, a)
            if tw > 1 then return w end
            local buf = {}
            return { writeln = function(_, s) buf[#buf + 1] = s end, write = function(_, s) buf[#buf + 1] = s end,
                close = function()
                    for i = 1, #buf - 1 do w:writeln(buf[i]) end
                    w:close()
                end }
        end
    end })
    getFileWriter = realWriter2
    local truncNoted = Z.unreadable and Z.fileError.code == "MIGRATE" and fileText() == Z.MIGRATE_NOTE and marker() == "pending"
    boot({ keepFiles = true })
    check(truncNoted and MSH.Zones.unreadable and MSH.Zones.fileError.code == "MIGRATE" and #MSH.Zones.list == 0,
        "遷移讀回截斷：zones.json 改寫成說明、紀錄 pending；重開服 MIGRATE")
    -- 紀錄寫不進去：不動 zones.json（下次開服還是沒檔、再遷一次）
    local mp = MSH.Zones.markerPath()
    Z = bootLegacy(legacy, { beforeStart = function()
        getFileWriter = function(p, c, a)
            if p == mp then return nil end
            return realWriter2(p, c, a)
        end
    end })
    getFileWriter = realWriter2
    local noMarker = Z.unreadable and Z.fileError.code == "MIGRATE" and zonesFile() == nil and marker() == nil and legacyKept(legacy)
    boot({ keepFiles = true })
    check(noMarker and not MSH.Zones.unreadable and #MSH.Zones.list == 2 and marker() == "done",
        "紀錄寫不進去：MIGRATE、不建立 zones.json；之後寫得進去時重開服重新遷移成功、紀錄 done")
    -- done 寫不進去：這次 MIGRATE（zones.json 內容是對的）；重開服比對 zones.txt 相同，自動完成並採用
    local mw = 0
    Z = bootLegacy(legacy, { beforeStart = function()
        getFileWriter = function(p, c, a)
            if p == mp then
                mw = mw + 1
                if mw > 1 then return { writeln = function() end, write = function() end, close = function() end } end
            end
            return realWriter2(p, c, a)
        end
    end })
    getFileWriter = realWriter2
    local doneFailed = Z.unreadable and Z.fileError.code == "MIGRATE" and #Z.list == 0 and marker() == "pending"
        and string.find(fileText(), "軍事基地通路", 1, true) ~= nil and countLogs("ZONES_MIGRATED") == 0
    boot({ keepFiles = true })
    check(doneFailed and not MSH.Zones.unreadable and #MSH.Zones.list == 2 and MSH.Zones.nextId == 5 and marker() == "done"
        and countLogs("ZONES_MIGRATED") == 1, "done 寫不進去：這次 MIGRATE；重開服和 zones.txt 相同 → 自動完成、採用、紀錄 done")
    -- 沒有 zones.txt：紀錄是 pending 也不看
    T.files[MSH.Zones.legacyPath()] = nil
    setFile(doc(4, zoneJson(2, "nobuild", "無舊檔", 1000, 1000, 5, 5)))
    T.files[mp] = { lines = { "pending" } }
    boot({ keepFiles = true })
    check(not MSH.Zones.unreadable and #MSH.Zones.list == 1 and MSH.Zones.list[1].name == "無舊檔" and marker() == "pending",
        "沒有 zones.txt：紀錄是 pending 也照常載入")

    T.section("Zones：道路豁免區不算禁建區")
    boot({ sandbox = { Tier1FreeSlots = 5 } })
    boss = T.player({ name = "boss", admin = true, x = 2505, y = 2505 })
    alice = T.player({ name = "alice", x = 6005, y = 6005, items = { D1 } })
    res = T.cmd(boss, "adminAddZone", { name = "x", rects = { rect(6000, 6000, 20, 20) }, kind = "allow" })
    local badKind = res.code == "BAD_ARGS"
    res = T.cmd(boss, "adminAddZone", { name = "土路", rects = { rect(6000, 6000, 20, 20) }, kind = "roadexempt" })
    local audited = false
    for _, line in ipairs(T.logs) do
        if string.find(line, "^ADMIN_ZONE_ADD\t") and string.find(line, "roadexempt 土路", 1, true) then audited = true end
    end
    check(badKind and res.ok and res.zones[1].kind == "roadexempt" and audited and string.find(fileText(), '"kind": "roadexempt"', 1, true),
        "新增道路豁免區：kind 寫錯 BAD_ARGS；帶 kind、audit 有種類、檔案存 kind")
    pv = T.cmd(alice, "preview", { rects = { rect(6005, 6005, 5, 5) }, deedType = D1 })
    check(pv.ok and pv.pass and checkOf(pv, "zones") == nil and #pv.checks == 10, "只有道路豁免區：預檢不列 zones 這一項")
    -- 另有一個遠處的禁建區：zones 這一步會跑，豁免區照樣不算禁建區
    res = T.cmd(boss, "adminAddZone", { name = "遠處", rects = { rect(7000, 7000, 5, 5) } })
    T.advance(600)
    pv = T.cmd(alice, "preview", { rects = { rect(6005, 6005, 5, 5) }, deedType = D1 })
    local zrow = checkOf(pv, "zones")
    T.advance(600)
    res = T.cmd(alice, "create", { rects = { rect(6005, 6005, 5, 5) }, deedType = D1 })
    check(zrow ~= nil and zrow.ok and res.ok, "有禁建區時在道路豁免區內預檢、建立：zones 通過、不是 NO_BUILD")

    T.section("Zones：寫之前再讀一次（主機在 syncDisk 之後改檔）、編號用完、時鐘倒退、檔案太大、解碼例外")
    boot()
    boss = T.player({ name = "boss", admin = true })
    Zs = MSH.Zones
    path = Zs.path()
    setFile(doc(2, A1))
    poll(2)
    local alertLocks = {}
    local realSend3 = sendServerCommand
    sendServerCommand = function(a, b, c, d)
        if c == "alert" then alertLocks[#alertLocks + 1] = MSH.Srv.locked end
        return realSend3(a, b, c, d)
    end
    local realRead = MSH.Registry.readLines
    -- edits[k]：第 k 次讀 zones.json 之後，主機把檔改成這份
    local function hostEdits(edits)
        local n = 0
        MSH.Registry.readLines = function(p, ...)
            local r = realRead(p, ...)
            if p == path then
                n = n + 1
                if edits[n] ~= nil then setFile(edits[n]) end
            end
            return r
        end
    end
    local hostDoc = doc(10, A1, zoneJson(9, "nobuild", "主機", 400, 400, 5, 5))
    hostEdits({ [1] = hostDoc })
    res = T.cmd(boss, "adminAddZone", { name = "丁", rects = { rect(600, 600, 5, 5) } })
    MSH.Registry.readLines = realRead
    ids = {}
    for _, z in ipairs(Zs.list) do ids[#ids + 1] = z.id end
    rl = alertsTo(boss, "ZONES_RELOADED")
    check(res.ok and res.zoneId == 10 and table.concat(ids, ",") == "1,9,10" and string.find(fileText(), "主機", 1, true) ~= nil
        and string.find(fileText(), "丁", 1, true) ~= nil and rl[#rl] == "1,0,0",
        "syncDisk 之後主機改了檔：不蓋掉，先採用主機版（9 號）再重做、疊上 10 號（實際 " .. table.concat(ids, ",") .. "）")
    local cur = fileText()
    local docA, docB = (string.gsub(cur, "主機", "主機甲")), (string.gsub(cur, "主機", "主機乙"))
    hostEdits({ [1] = docA, [3] = docB })
    res = T.cmd(boss, "adminAddZone", { name = "戊", rects = { rect(700, 700, 5, 5) } })
    MSH.Registry.readLines = realRead
    check(res.code == "SAVE_FAILED" and res.reason == nil and fileText() == docB and Zs.text == docA and #Zs.list == 3
        and Zs.list[2].name == "主機甲", "寫之前連兩次都被改：SAVE_FAILED、不蓋掉主機的檔、採用中的是讀到並採用的那份")
    poll(2)
    local docC = (string.gsub(docB, "主機乙", "主機丙"))
    local rev0 = Zs.rev
    hostEdits({ [1] = docC })
    res = T.cmd(boss, "adminRemoveZone", { zoneId = 9, rev = rev0 })
    MSH.Registry.readLines = realRead
    check(Zs.list[2].name == "主機丙" and res.code == "STALE_REVISION" and res.rev == rev0 + 1 and fileText() == docC and #Zs.list == 3,
        "刪除時 syncDisk 之後主機改了檔：採用新版、rev 變了 → STALE_REVISION、不刪、不蓋掉")
    -- 寫完、讀回之前主機存了一份合法的新檔：不寫回原本的，回去採用主機版重做（第二輪又被改照舊 SAVE_FAILED）
    local realWrite = MSH.Registry.writeLines
    local function hostWrites(edits)
        local n = 0
        MSH.Registry.writeLines = function(p, ...)
            local r = realWrite(p, ...)
            if p == path then
                n = n + 1
                if edits[n] ~= nil then setFile(edits[n]) end
            end
            return r
        end
    end
    local hostE = (string.gsub(docC, "主機丙", "主機丁"))
    hostWrites({ [1] = hostE })
    res = T.cmd(boss, "adminAddZone", { name = "己", rects = { rect(1100, 1100, 5, 5) } })
    MSH.Registry.writeLines = realWrite
    check(res.ok and #Zs.list == 4 and Zs.list[2].name == "主機丁" and string.find(fileText(), "主機丁", 1, true) ~= nil
        and string.find(fileText(), "己", 1, true) ~= nil and Zs.text == fileText(),
        "新增：寫完、讀回之前主機存了合法的新檔：不寫回，採用主機版後重做、疊在主機版上")
    local addedId = res.zoneId
    local hostF = (string.gsub(fileText(), "主機丁", "主機戊"))
    hostWrites({ [1] = hostF })
    res = T.cmd(boss, "adminRemoveZone", { zoneId = addedId })
    MSH.Registry.writeLines = realWrite
    check(res.ok and #Zs.list == 3 and Zs.list[2].name == "主機戊" and string.find(fileText(), "主機戊", 1, true) ~= nil
        and string.find(fileText(), "己", 1, true) == nil and Zs.text == fileText(),
        "刪除：寫完、讀回之前主機存了合法的新檔：不寫回，採用主機版後重做、從主機版刪掉")
    local G1, G2 = (string.gsub(fileText(), "主機戊", "主機一")), (string.gsub(fileText(), "主機戊", "主機二"))
    hostWrites({ [1] = G1, [2] = G2 })
    res = T.cmd(boss, "adminAddZone", { name = "辛", rects = { rect(1200, 1200, 5, 5) } })
    MSH.Registry.writeLines = realWrite
    check(res.code == "SAVE_FAILED" and fileText() == G2 and Zs.text == G1 and #Zs.list == 3,
        "兩輪寫完都被主機改：SAVE_FAILED、主機的檔留著、採用中的是第一份主機版")
    -- 寫完、讀回之前主機存了合法 JSON 但不合規的檔（種類打錯）：一樣不寫回原本的，留給 syncDisk 記成檔案錯誤
    poll(2)
    local adopted = Zs.text
    local hostBad = (string.gsub(fileText(), '"nobuild"', '"nobuildd"', 1))
    hostWrites({ [1] = hostBad })
    res = T.cmd(boss, "adminAddZone", { name = "壬", rects = { rect(1300, 1300, 5, 5) } })
    MSH.Registry.writeLines = realWrite
    check(res.code == "SAVE_FAILED" and res.reason == "FILE" and fileText() == hostBad and Zs.text == adopted
        and Zs.fileError ~= nil and Zs.fileError.code == "BAD_KIND",
        "寫完、讀回之前主機存了不合規的 JSON：不寫回原本的，主機的檔留著、記成檔案錯誤（SAVE_FAILED FILE）")
    -- 編號用完：下一個編號超過 LIMIT.MAX_ZONE_ID 就不能新增；zoneId 參數和 parse 用同一個上限
    setFile(doc(1, zoneJson("999999999", "nobuild", "末", 800, 800, 5, 5)))
    T.cmd(boss, "adminReloadZones", {})
    local full = fileText()
    res = T.cmd(boss, "adminAddZone", { name = "超", rects = { rect(900, 900, 5, 5) } })
    check(Zs.nextId == 1000000000 and res.code == "BAD_ARGS" and res.reason == "ID_RANGE" and fileText() == full and #Zs.list == 1,
        "編號用完（下一個超過 999999999）：BAD_ARGS ID_RANGE、不寫檔")
    res = T.cmd(boss, "adminRemoveZone", { zoneId = 1000000000 })
    local overArg = res.code == "BAD_ARGS"
    res = T.cmd(boss, "adminRemoveZone", { zoneId = 999999999 })
    check(overArg and res.ok and #Zs.list == 0, "zoneId 參數和 parse 同一個上限：1000000000 BAD_ARGS、999999999 刪得掉")
    -- 時鐘往回撥：上次輪詢的時間在「未來」也照常讀，不等時鐘追回來
    setFile(doc(3, A1))
    Zs.lastWatch = T.now + 600000
    T.advance(100)
    T.fire("OnTick")
    poll()
    check(#Zs.list == 1 and Zs.list[1].name == "甲", "時鐘往回撥：照常輪詢")
    -- 字數超過預算：readLines 當場停（不整份讀進來）；不帶預算的呼叫照舊讀完
    local big = {}
    for i = 1, 3000 do big[i] = string.rep("a", 999) end
    T.files[path] = { lines = big }
    local realReader, reads = getFileReader, 0
    getFileReader = function(p, c)
        local r = realReader(p, c)
        if p ~= path or r == nil then return r end
        return { readLine = function()
            reads = reads + 1
            return r:readLine()
        end, close = function() r:close() end }
    end
    local over = MSH.Registry.readLines(path, Zs.MAX_LINES + 1, Zs.MAX_CHARS)
    local overReads = reads
    reads = 0
    poll(2)   -- 連兩次讀到一樣才算數：兩次輪詢，每次都在第 1001 行停
    local pollReads = reads
    reads = 0
    local plain = MSH.Registry.readLines(path, Zs.MAX_LINES + 1)
    getFileReader = realReader
    check(over == false and overReads == 1001 and pollReads == 2002 and Zs.fileError ~= nil
        and Zs.fileError.code == "UNREADABLE" and type(plain) == "table" and #plain == 3000 and reads == 3001,
        "字數超過預算：讀到第 1001 行就停、回 false，輪詢記成 UNREADABLE（實際 " .. overReads .. "／" .. pollReads
        .. " 次）；不帶預算的照舊讀完")
    setFile(doc(3, A1) .. "\n" .. string.rep(" ", Zs.MAX_CHARS))
    poll(2)
    check(Zs.fileError ~= nil and Zs.fileError.code == "UNREADABLE" and #Zs.list == 1, "整份超過 MAX_CHARS 字：UNREADABLE、沿用上一份")
    local realDecode2 = MSH.Json.decode
    MSH.Json.decode = function() error("boom") end
    setFile(doc(4, A1))
    poll(2)
    MSH.Json.decode = realDecode2
    check(Zs.fileError ~= nil and Zs.fileError.code == "JSON" and Zs.pending == nil and Zs.rejected == fileText() and #Zs.list == 1,
        "輪詢時解碼器丟例外：記成檔案錯誤 JSON、rejected 設好、不留 pending")
    setFile("{ ")
    T.cmd(boss, "adminReloadZones", {})
    setFile(doc(3, A1))   -- 改回採用中的那份再按：錯誤解除的 0,0,0 也放鎖後送
    T.cmd(boss, "adminReloadZones", {})
    rl = alertsTo(boss, "ZONES_RELOADED")
    check(rl[#rl] == "0,0,0" and Zs.fileError == nil, "改回採用中的那份再按〔重新載入〕：錯誤解除、通知 0,0,0")
    sendServerCommand = realSend3
    local unlocked = #alertLocks >= 3
    for _, l in ipairs(alertLocks) do unlocked = unlocked and not l end
    check(unlocked, "採用、壞檔的管理員通知都在放鎖之後送（" .. #alertLocks .. " 則）")

    T.section("Zones：開服就讀不開、之後檔案被刪")
    setFile("{ ")
    boot({ keepFiles = true })
    boss = T.player({ name = "boss", admin = true })
    Zs = MSH.Zones
    local wasUnreadable = Zs.unreadable and Zs.fileError.code == "JSON"
    T.files[Zs.path()] = nil
    poll(2)
    res = T.cmd(boss, "adminZones", {})
    check(wasUnreadable and Zs.unreadable and Zs.fileError.code == "MISSING" and #alertsTo(boss, "ZONES_FILE") == 0
        and res.ok and res.unreadable and res.file.error.code == "MISSING" and countLogs("ZONES_FILE") >= 1,
        "開服讀不開、之後檔案被刪：fileError MISSING、不送「沿用上一份」通知；adminZones 帶 unreadable")
end
