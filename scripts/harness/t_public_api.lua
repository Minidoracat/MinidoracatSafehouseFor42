-- 客戶端公開 API（PublicApi.lua；temp/handoff/minimap-safehouse-owner.md）：MinidoracatSafehouse.v1.ownerName 把
-- @MSH:<claimId> 換成真正屋主；資料來自 Global ModData 的回覆。request 同時一個；沒看過的 owner 查不到隔 30 秒，
-- 清單變過、只為了更新的隔 5 分鐘；回覆只判送出當下要的 owner。
return function(T)
    local check = T.check
    local MSH = T.bootClient()
    local SH = MinidoracatSafehouse.v1
    local savedModData = ModData
    local requests = {}
    local stub = setmetatable({ request = function(tag) requests[#requests + 1] = tag end }, { __index = savedModData })
    ModData = stub
    local function reply(tbl) T.fire("OnReceiveGlobalModData", MSH.TAG, tbl) end
    local function registry(rows)
        local claims = {}
        for id, owner in pairs(rows) do claims[id] = { claimId = id, owner = owner, title = "t", grants = {} } end
        return { schemaVersion = MSH.SCHEMA, claims = claims }
    end

    T.section("PublicApi：查詢與回覆")
    check(SH.ownerName("@MSH:1") == nil and #requests == 1 and requests[1] == MSH.TAG,
        "沒資料：回 nil，向伺服器要一次本 MOD 的表")
    check(SH.ownerName("@MSH:1") == nil and #requests == 1, "回覆還沒到：不再送")
    local data = registry({ [1] = "alice", [2] = "bob" })
    reply(data)
    check(SH.ownerName("@MSH:1") == "alice" and SH.ownerName("@MSH:2") == "bob", "回覆後回真正屋主")
    data.claims[1].owner = "mallory"
    data.claims[3] = { claimId = 3, owner = "eve" }
    check(SH.ownerName("@MSH:1") == "alice", "不保留回覆表的參照：事後改那張表不影響快取")
    check(SH.ownerName("bob") == nil and SH.ownerName("@MSH:x") == nil and SH.ownerName("@MSH:") == nil
        and SH.ownerName(nil) == nil and SH.ownerName(12) == nil, "不是 @MSH:<數字>（含 nil、非字串）回 nil")
    T.fire("OnReceiveGlobalModData", "OtherMod", { claims = { [1] = { claimId = 1, owner = "zed" } } })
    check(SH.ownerName("@MSH:1") == "alice", "收到別的 tag 不影響快取")

    T.section("PublicApi：節流")
    T.advance(1000)
    check(SH.ownerName("@MSH:3") == nil and #requests == 1, "上次送出 30 秒內沒命中：不再送")
    T.advance(30000)
    check(SH.ownerName("@MSH:3") == nil and #requests == 2, "滿 30 秒：再送一次")
    reply(registry({ [1] = "alice", [2] = "bob" }))
    check(SH.ownerName("@MSH:2") == "bob", "整份換新：還在的照樣查得到")
    T.advance(60000)
    check(SH.ownerName("@MSH:3") == nil and #requests == 2, "回覆後仍查不到的記成已知查不到：清單沒變就不再送")

    -- 成員同步被干擾時伺服器每 500 ms 廣播一次原生清單：每個客戶端最多 5 分鐘抓一次整張表
    T.section("PublicApi：清單一直在變")
    for _ = 1, 10 do
        T.advance(1000)
        T.fire("OnSafehousesChanged")
        SH.ownerName("@MSH:1")
        SH.ownerName("@MSH:3")
    end
    check(#requests == 2, "上次送出 5 分鐘內：清單變動加上每幀查詢（命中與已知查不到）都不送")
    T.advance(230000)   -- 距上次送出 300 秒
    check(SH.ownerName("@MSH:1") == "alice" and #requests == 3,
        "滿 5 分鐘：命中的查詢觸發一次更新，回覆前照舊回快取的名字")
    reply(registry({ [1] = "bob", [3] = "carol" }))
    check(SH.ownerName("@MSH:1") == "bob" and SH.ownerName("@MSH:3") == "carol" and SH.ownerName("@MSH:2") == nil,
        "更新後：屋主換人、已知查不到的補上、已放棄的不留名字")
    T.advance(400000)
    SH.ownerName("@MSH:1")
    check(#requests == 3, "清單沒再變：命中不再送")

    -- 回覆可能比新屋的原生同步晚到：送出之後才查的 owner 不在這次回覆裡也不算查不到
    T.section("PublicApi：回覆前才查的新屋")
    SH.ownerName("@MSH:20")
    check(#requests == 4, "沒看過的 owner：送出")
    SH.ownerName("@MSH:21")
    reply(registry({ [1] = "bob", [3] = "carol" }))
    T.advance(30000)
    check(SH.ownerName("@MSH:21") == nil and #requests == 5, "送出後才查的 owner 沒被判成查不到：30 秒後再要一次")
    reply(registry({ [1] = "bob", [3] = "carol", [21] = "dave" }))
    check(SH.ownerName("@MSH:21") == "dave", "下一次回覆查得到")
    T.advance(30000)
    check(SH.ownerName("@MSH:20") == nil and #requests == 5, "送出當下要的、回覆裡沒有的：記成已知查不到")

    T.section("PublicApi：回覆遺失與伺服器沒有表")
    SH.ownerName("@MSH:9")
    check(#requests == 6, "查不到：送出")
    T.advance(30000)
    SH.ownerName("@MSH:9")
    check(#requests == 6, "還在等回覆（未滿遺失時限）：同時只有一個 request")
    T.advance(30000)
    SH.ownerName("@MSH:9")
    check(#requests == 7, "回覆遺失超過 60 秒：不再當作進行中，重送")
    reply(false)
    check(SH.ownerName("@MSH:1") == nil and SH.ownerName("@MSH:9") == nil and #requests == 7,
        "伺服器沒有這張表（false）：清快取、送出當下要的記成已知查不到")

    T.section("PublicApi：ModData 不存在")
    ModData = nil
    T.advance(30000)
    local ok = pcall(SH.ownerName, "@MSH:5")
    check(ok, "ModData 不存在時不丟錯")
    ModData = { request = function() error("boom") end }
    T.advance(30000)
    ok = pcall(SH.ownerName, "@MSH:5")
    check(ok and T.prints[#T.prints] ~= nil and string.find(T.prints[#T.prints], "ModData.request failed", 1, true) ~= nil,
        "request 丟錯：不往外丟、記 log")
    ModData = stub

    T.section("PublicApi：不是 managed")
    T.advance(60000)
    local before = #requests
    SH.ownerName("bob")
    SH.ownerName("@MSH:x")
    check(#requests == before, "節流已過也不為不是 @MSH:<數字> 的查詢送 request")
    SH.ownerName("@MSH:77")
    check(#requests == before + 1, "（對照）同一時間點 managed 的查詢會送")
    ModData = savedModData
end
