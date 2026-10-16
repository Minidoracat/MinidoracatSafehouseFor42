-- 客戶端共用核心（Client.lua）：結果照 requestId 配對（冷卻中被伺服器丟掉的查詢不讓後面的回覆錯位）、
-- 10 秒沒回覆的通知、mutation 結果待定後用同一 requestId 重送、晚到的真結果、清單快取與格子權限位元、
-- 禁建區清單（zones 查詢與 zonesSync 推送的 rev、同時一筆、失敗後的間隔）。
return function(T)
    local check = T.check
    local MSH = T.bootClient()
    local C = MSH.Client
    T.player({ name = "alice" })
    local function serverCmd(command, args) T.fire("OnServerCommand", MSH.MODULE, command, args) end
    local function lastSent() return T.clientSent[#T.clientSent] end
    local function reply(sent, fields)
        local r = { command = sent.command, requestId = sent.args.requestId, ok = true, code = "OK" }
        for k, v in pairs(fields or {}) do r[k] = v end
        serverCmd("result", r)
    end

    T.section("Client：結果照 requestId 配對")
    local got = {}
    C.send("preview", { rects = { { x = 1, y = 1, w = 2, h = 2 } } }, function(r) got[#got + 1] = "first:" .. tostring(r.code) end)
    local dropped = lastSent()
    C.send("preview", { rects = { { x = 1, y = 1, w = 3, h = 3 } } }, function(r) got[#got + 1] = "second:" .. tostring(r.code) end)
    local answered = lastSent()
    check(dropped.args.requestId ~= nil and dropped.args.requestId ~= answered.args.requestId
        and MSH.validRequestId(dropped.args.requestId) and dropped.args.protocol == MSH.PROTOCOL,
        "查詢也帶合法、不重複的 requestId 與協定")
    -- 伺服器把第一筆當冷卻丟掉、只回第二筆：回覆只能交給第二筆
    reply(answered, { code = "OK" })
    check(#got == 1 and got[1] == "second:OK", "被丟掉的那筆不會拿到別筆的回覆")
    reply(answered, { code = "OK" })
    check(#got == 1, "同一筆不會回呼兩次")
    serverCmd("result", { command = "detail", requestId = answered.args.requestId, ok = true, code = "OK" })
    check(#got == 1, "指令名不符的回覆不收")

    T.section("Client：逾時")
    T.advance(10000)
    T.tick(6)
    check(#got == 2 and got[2] == "first:NO_REPLY" and not C.isPending(dropped.args.requestId),
        "查詢 10 秒沒回覆：通知一次 NO_REPLY、不再等")
    T.tick(20)
    check(#got == 2, "NO_REPLY 只通知一次")

    T.section("Client：mutation 結果待定與重送")
    local results = {}
    local rid = C.send("create", { rects = { { x = 1, y = 1, w = 2, h = 2 } } }, function(r) results[#results + 1] = r end,
        { mutation = true })
    local createSent = lastSent()
    T.advance(10000)
    T.tick(6)
    check(#results == 1 and results[1].code == "NO_REPLY" and results[1].pending == true and C.isPending(rid),
        "mutation 10 秒沒回覆：通知待定、保留這筆")
    local before = #T.clientSent
    check(C.retry(rid) and #T.clientSent == before + 1 and lastSent().args.requestId == rid
        and lastSent().args.rects == createSent.args.rects, "重送：同一 requestId、同一份參數")
    reply(lastSent(), { claimId = 7 })
    check(#results == 2 and results[2].ok == true and results[2].claimId == 7 and not C.isPending(rid),
        "晚到的真結果照樣交回")

    local lost = {}
    local rid2 = C.send("create", {}, function(r) lost[#lost + 1] = r end, { mutation = true })
    T.advance(71000)
    T.tick(6)
    check(not C.isPending(rid2) and #lost == 1 and lost[1].expired == true,
        "過了伺服器快取時間：不再等，標 expired（不當失敗解讀由呼叫端決定）")

    T.section("Client：清單快取與格子權限位元")
    SafeHouse.addSafeHouse(100, 100, 10, 10, "@MSH:3")
    SafeHouse.addSafeHouse(200, 200, 10, 10, "@MSH:4")
    SafeHouse.addSafeHouse(300, 300, 10, 10, "someone")
    C.refreshList()
    reply(lastSent(), { claims = {
        { claimId = 3, revision = 1, title = "a", actorRole = "owner", bits = MSH.SHARE_ALL, lifecycle = "active" },
        { claimId = 5, revision = 1, title = "b", actorRole = "member", bits = 3, lifecycle = "active" },
    } })
    check(#C.claims.mine == 1 and #C.claims.shared == 1 and C.claims.byId[5].bits == 3, "清單分成我的與分享給我的")
    local b3 = C.bitsAt(105, 105)
    local b4 = C.bitsAt(205, 209)
    check(b3 == MSH.SHARE_ALL and b4 == 0, "managed 格子：有角色回位元、沒有角色回 0")
    check(C.bitsAt(305, 305) == nil and C.bitsAt(110, 105) == nil, "foreign 與範圍外（半開）回 nil")

    T.section("Client：changed 推送合併成一筆 list")
    local before = #T.clientSent
    serverCmd("changed", { claimId = 3 })
    local first = lastSent()
    local late
    serverCmd("changed", { claimId = 3 })
    C.refreshList(function(res) late = res end)
    serverCmd("changed", { claimId = 5 })
    check(#T.clientSent == before + 1 and first.command == "list", "送出中再來的 changed 與 refreshList 不另送 list")
    reply(first, { claims = {} })
    check(#T.clientSent == before + 2 and lastSent().command == "list" and late == nil,
        "回覆到了只補送一次；送出中給的 cb 等補送那筆")
    reply(lastSent(), { claims = { { claimId = 9, revision = 1, title = "c", actorRole = "owner", bits = MSH.SHARE_ALL,
        lifecycle = "active" } } })
    check(late ~= nil and late.ok and #late.claims == 1 and #T.clientSent == before + 2 and C.claims.byId[9] ~= nil,
        "補送那筆的結果交給 cb、更新清單，之後不再送")

    -- 伺服器 slots 冷卻 500 ms 內重送就丟、不回覆：名額視窗、建立面板、Economy 推送同一刻各要一次時，只能送一筆，
    -- 上一筆回覆後滿 SLOTS_GAP_MS 才補送一次（2026-10-13 使用者截圖：付款後名額停在 0）
    T.section("Client：名額摘要（slots）同時一筆、間隔滿了才補送")
    local got = {}
    C.on("slots", "test", function(res) got[#got + 1] = res end)
    local function slotsSent()
        local c = 0
        for _, s in ipairs(T.clientSent) do if s.command == "slots" then c = c + 1 end end
        return c
    end
    T.advance(C.SLOTS_GAP_MS)
    local s0 = slotsSent()
    C.refreshSlots()
    local first = lastSent()
    C.refreshSlots()
    C.refreshSlots()
    check(slotsSent() == s0 + 1 and first.command == "slots", "同一刻要三次：只送一筆")
    T.advance(100)
    reply(first, { usable = 0 })
    T.fire("OnTick")
    check(#got == 1 and got[1].usable == 0 and slotsSent() == s0 + 1, "回覆發給 slots 事件；離上一筆回覆不到間隔：先不補送")
    T.advance(C.SLOTS_GAP_MS)
    T.fire("OnTick")
    check(slotsSent() == s0 + 2, "送出中又被要過：間隔滿了補送一次（拿付款後的數字）")
    reply(lastSent(), { usable = 1 })
    T.advance(C.SLOTS_GAP_MS)
    T.fire("OnTick")
    check(#got == 2 and got[2].usable == 1 and slotsSent() == s0 + 2, "補送的結果也發事件；沒人再要就不再送")
    C.refreshSlots()
    T.advance(C.TIMEOUT_MS + 500)
    T.fire("OnTick")
    check(#got == 3 and got[3].code == "NO_REPLY", "沒回覆：10 秒後發 NO_REPLY，下一次照樣能送")
    T.advance(C.SLOTS_GAP_MS)
    C.refreshSlots()
    check(slotsSent() == s0 + 4, "NO_REPLY 之後不卡在送出中")
    C.refreshSlots()
    T.advance(C.SLOTS_GAP_MS + 100)
    T.fire("OnTick")
    check(slotsSent() == s0 + 4, "回覆比間隔慢：前一筆還在路上就不送第二筆")
    -- 伺服器卡頓：前一筆在伺服器排了很久才處理，回覆一到就送下一筆的話，兩筆在伺服器上相隔不到 500 ms、下一筆被丟
    reply(lastSent(), {})
    T.fire("OnTick")
    check(slotsSent() == s0 + 4, "回覆很慢（伺服器卡頓）：回覆一到也不馬上送，間隔從回覆算")
    T.advance(C.SLOTS_GAP_MS)
    T.fire("OnTick")
    check(slotsSent() == s0 + 5, "回覆後滿 SLOTS_GAP_MS：補送被要過的那次")
    reply(lastSent(), {})
    C.off("slots", "test")

    -- 禁建區（使用者 2026-10-16：玩家也看得到）：地面範圍要畫時才查一次 zones，之後靠伺服器推 zonesSync；
    -- 回覆與推送沒有順序保證，rev 比手上舊的丟掉；伺服器 1 秒冷卻，同時一筆、失敗後 ZONES_RETRY_MS 才再送
    T.section("Client：禁建區清單（zones 查詢與 zonesSync 推送）只收不比手上舊的")
    local function zonesSent()
        local c = 0
        for _, s in ipairs(T.clientSent) do if s.command == "zones" then c = c + 1 end end
        return c
    end
    local events = 0
    C.on("zones", "test", function() events = events + 1 end)
    local A = { id = 1, name = "Road", rects = { { x = 10, y = 10, w = 5, h = 5 } } }
    local B = { id = 2, name = "Base", rects = { { x = 50, y = 50, w = 5, h = 5 } } }
    C.zones = { list = nil, rev = -1 }
    local z0 = zonesSent()
    check(C.ensureZones() == nil and zonesSent() == z0 + 1 and lastSent().command == "zones",
        "還沒拿到：回 nil、送一筆 zones")
    local ask = lastSent()
    check(C.ensureZones() == nil and zonesSent() == z0 + 1, "送出中再被要：不重送")
    serverCmd("zonesSync", { zones = { A, B }, rev = 2 })
    check(#C.zones.list == 2 and C.zones.rev == 2 and events == 1, "推送 rev 2 先到：換掉清單、發 zones 事件")
    reply(ask, { zones = { A }, rev = 1 })
    check(#C.zones.list == 2 and C.zones.rev == 2 and events == 1, "晚到的查詢回覆 rev 1：比手上舊，不蓋掉")
    serverCmd("zonesSync", { zones = {}, rev = 1 })
    check(#C.zones.list == 2 and events == 1, "舊 rev 的推送也不蓋掉")
    check(C.ensureZones() == C.zones.list and zonesSent() == z0 + 1, "已經有清單：不再查")
    serverCmd("zonesSync", { zones = { A, { id = 3, name = "bad", rects = { { x = 0, y = 0, w = 0, h = 5 } } } }, rev = 3 })
    check(#C.zones.list == 1 and C.zones.list[1].id == 1 and C.zones.rev == 3 and events == 2,
        "新的 rev 3：換掉；形狀不合法的那個不收")
    serverCmd("zonesSync", { zones = { B }, rev = 3 })
    check(#C.zones.list == 1 and C.zones.list[1].id == 2 and events == 3, "同一個 rev 照收（同一次開服的同一版）")
    serverCmd("zonesSync", { zones = "x", rev = 9 })
    check(C.zones.rev == 3 and events == 3, "格式不對的推送不收")

    T.section("Client：禁建區查詢失敗後 ZONES_RETRY_MS 內不重送")
    C.zones = { list = nil, rev = -1 }
    z0 = zonesSent()
    C.ensureZones()
    reply(lastSent(), { ok = false, code = "NOT_READY" })
    check(zonesSent() == z0 + 1 and C.ensureZones() == nil and zonesSent() == z0 + 1, "回覆失敗：馬上再要也不送")
    T.advance(C.ZONES_RETRY_MS - 1)
    C.ensureZones()
    check(zonesSent() == z0 + 1, "失敗後 10 秒內：不送")
    T.advance(1)
    C.ensureZones()
    check(zonesSent() == z0 + 2, "滿 10 秒：再送")
    T.advance(C.TIMEOUT_MS + 500)
    T.fire("OnTick")
    C.ensureZones()
    check(zonesSent() == z0 + 2 and C.zones.list == nil, "10 秒沒回覆（NO_REPLY）也算失敗：從那時起算，不馬上重送")
    T.advance(C.ZONES_RETRY_MS)
    C.ensureZones()
    reply(lastSent(), { zones = { A }, rev = 0 })
    check(zonesSent() == z0 + 3 and #C.zones.list == 1 and C.zones.rev == 0, "再過 10 秒送出、拿到清單")
    C.off("zones", "test")
end
