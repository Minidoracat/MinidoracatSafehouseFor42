-- 客戶端 mirror（Mirror.lua）：remove delta 只移除精確標記、tombstone、巢狀事件、校正時機、seq gap、sandboxSync。
return function(T)
    local check = T.check
    local MSH = T.bootClient()
    local M = MSH.Mirror
    T.player({ name = "alice" })

    -- 客戶端 removeSafeHouse 會同步觸發 OnSafehousesChanged（SafeHouse.java:317-319）；假環境只在這個情境模擬，結束還原
    local realRemove, realList = SafeHouse.removeSafeHouse, SafeHouse.getSafehouseList
    local scans = 0
    SafeHouse.removeSafeHouse = function(h)
        realRemove(h)
        T.fire("OnSafehousesChanged")
    end
    SafeHouse.getSafehouseList = function()
        scans = scans + 1
        return realList()
    end

    local function count(owner)
        local n = 0
        for _, h in ipairs(T.houses) do if h.owner == owner then n = n + 1 end end
        return n
    end
    local function serverCmd(command, args) T.fire("OnServerCommand", MSH.MODULE, command, args) end
    local function remove(id, seq, bootId)
        serverCmd("nativeRemove", { claimId = id, x = 10, y = 10, w = 5, h = 5, bootId = bootId or "b1", seq = seq })
    end

    local ok, err = pcall(function()
        T.section("Mirror：remove delta 只移除精確標記")
        SafeHouse.addSafeHouse(10, 10, 5, 5, "@MSH:1")
        SafeHouse.addSafeHouse(10, 10, 5, 5, "@MSH:2")     -- 同 rect 已被新 claim 重建
        SafeHouse.addSafeHouse(10, 10, 5, 5, "bob")        -- foreign
        SafeHouse.addSafeHouse(50, 50, 5, 5, "@MSH:1")     -- 同標記重複（別的 rect）
        SafeHouse.addSafeHouse(60, 60, 5, 5, "@MSH:10")    -- 前綴相同、不同 claim
        scans = 0
        remove(1, 1)
        check(count("@MSH:1") == 0, "owner 恰好等於標記的全部移除（不比 rect）")
        check(count("@MSH:2") == 1 and count("bob") == 1 and count("@MSH:10") == 1 and #T.houses == 3,
            "同 rect 的別的 claim、foreign、前綴相同的標記都留著")
        check(scans == 1, "自己移除觸發的巢狀 OnSafehousesChanged 被擋（掃描 " .. scans .. " 次）")
        SafeHouse.addSafeHouse(70, 70, 5, 5, "@MSH:3")
        serverCmd("nativeRemove", { claimId = 3, bootId = "b1", seq = 2 })   -- malformed 紀錄的 delta：沒有 rect
        check(count("@MSH:3") == 0 and #T.houses == 3 and M.seq == 2, "沒有 rect 的 remove delta 照標記移除、序號照算")

        T.section("Mirror：tombstone")
        T.advance(30000)
        SafeHouse.addSafeHouse(10, 10, 5, 5, "@MSH:1")     -- 晚到的舊 SafehouseSync
        T.fire("OnSafehousesChanged")
        check(count("@MSH:1") == 0 and count("@MSH:2") == 1, "60 秒內晚到的舊屋被再移除")
        T.advance(31000)
        SafeHouse.addSafeHouse(10, 10, 5, 5, "@MSH:1")
        T.fire("OnSafehousesChanged")
        check(count("@MSH:1") == 1 and M.tombs[1] == nil, "tombstone 過期：不再移除、丟掉紀錄")

        T.section("Mirror：sandboxSync")
        serverCmd("sandboxSync", { ClaimGap = 7, Nope = 3, MaxShares = "x", RoadMargin = 1.5, AvoidRoads = false,
            Tier1LootChance = 2.5, RoadKinds = "main" })
        local sb = SandboxVars.MinidoracatSafehouse
        check(sb.ClaimGap == 7 and sb.AvoidRoads == false and sb.Tier1LootChance == 2.5 and sb.RoadKinds == "main",
            "認得、型別相符的鍵寫入 SandboxVars")
        check(sb.MaxShares == 8 and sb.RoadMargin == 1, "型別不符的值略過")
        check(sb.Nope == nil and T.sbox.values["MinidoracatSafehouse.Nope"] == nil, "未知鍵略過")

        T.section("Mirror：校正時機")
        -- Client.lua 開局也會送 list：這段只數校正
        local function calibrates()
            local n, last = 0, nil
            for _, s in ipairs(T.clientSent) do
                if s.command == "calibrate" then n, last = n + 1, s end
            end
            return n, last
        end
        check(#T.clientSent == 0, "OnGameStart 前不送")
        local ticks0 = #(T.handlers.OnTick or {})
        T.fire("OnGameStart")
        check(#T.clientSent == 0, "OnGameStart 當下不送 sendClientCommand")
        T.tick(1)
        local nCal, sent = calibrates()
        check(nCal == 1 and sent.module == MSH.MODULE, "第一個 OnTick 送校正")
        local ids = {}
        for _, e in ipairs(sent.args.houses) do ids[#ids + 1] = e.claimId end
        check(#ids == 3 and sent.args.protocol == MSH.PROTOCOL and sent.args.requestId == nil, "只帶標記屋、帶協定、不帶 requestId")
        T.tick(10)
        check(calibrates() == 1 and #(T.handlers.OnTick or {}) == ticks0, "一次性 OnTick 已移除，不重送")

        T.section("Mirror：校正結果與 seq")
        serverCmd("result", { command = "calibrate", ok = true, code = "OK", remove = { 2 }, bootId = "b1", seq = 5 })
        check(count("@MSH:2") == 0 and M.tombs[2] ~= nil and count("bob") == 1, "校正的 remove 清單照標記移除並留 tombstone")
        check(M.seq == 5, "序號基準換成校正當下的值")
        remove(9, 6)
        T.advance(6000)
        T.tick(1)
        check(calibrates() == 1, "序號連續：不校正")
        remove(9, 8)
        T.tick(1)
        check(calibrates() == 2, "序號缺號：送校正")
        remove(9, 3, "b2")
        T.advance(6000)
        T.tick(1)
        check(calibrates() == 2 and M.bootId == "b2" and M.seq == 3, "換 bootId：重設基準、不當缺號")
        T.advance(600000)
        T.tick(1)
        check(calibrates() == 3, "每 10 分鐘定期校正")
    end)
    SafeHouse.removeSafeHouse, SafeHouse.getSafehouseList = realRemove, realList
    if not ok then error(err, 0) end
end
