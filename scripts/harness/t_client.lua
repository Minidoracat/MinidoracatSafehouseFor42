-- 客戶端共用核心（Client.lua）：結果照 requestId 配對（冷卻中被伺服器丟掉的查詢不讓後面的回覆錯位）、
-- 10 秒沒回覆的通知、mutation 結果待定後用同一 requestId 重送、晚到的真結果、清單快取與格子權限位元。
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
    C.send("preview", { rect = { x = 1, y = 1, w = 2, h = 2 } }, function(r) got[#got + 1] = "first:" .. tostring(r.code) end)
    local dropped = lastSent()
    C.send("preview", { rect = { x = 1, y = 1, w = 3, h = 3 } }, function(r) got[#got + 1] = "second:" .. tostring(r.code) end)
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
    local rid = C.send("create", { rect = { x = 1, y = 1, w = 2, h = 2 } }, function(r) results[#results + 1] = r end,
        { mutation = true })
    local createSent = lastSent()
    T.advance(10000)
    T.tick(6)
    check(#results == 1 and results[1].code == "NO_REPLY" and results[1].pending == true and C.isPending(rid),
        "mutation 10 秒沒回覆：通知待定、保留這筆")
    local before = #T.clientSent
    check(C.retry(rid) and #T.clientSent == before + 1 and lastSent().args.requestId == rid
        and lastSent().args.rect == createSent.args.rect, "重送：同一 requestId、同一份參數")
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
end
