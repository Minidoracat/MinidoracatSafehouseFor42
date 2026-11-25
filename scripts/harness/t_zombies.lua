-- 安全屋範圍內的殭屍（Zombies.lua，兩個沙盒選項都預設關）。
-- NoZombieSpawn：OnZombieCreate 排隊、下一個 OnTick 看所在格再刪。ClearZombiesAtHome：名單上的活人在家時每秒掃一次。
-- 刪掉的 onlineId 廣播給客戶端（ZombieSync.lua 照原版刪除封包的做法移除）。
return function(T)
    local check = T.check
    local function spawn(...)
        local z = T.zombie(...)
        T.fire("OnZombieCreate", z)
        return z
    end
    local function hookFailed()
        for _, line in ipairs(T.prints) do
            if string.find(line, "tick hook zombies failed", 1, true) then return true end
        end
        return false
    end
    local function notices()
        local out = {}
        for _, a in ipairs(T.broadcastsOf("zombiesRemoved")) do
            for _, id in ipairs(a.ids) do out[#out + 1] = id end
        end
        return out
    end

    T.section("殭屍不重生：選項關著")
    local MSH = T.boot()
    local Z = MSH.Zombies
    -- 不是本 MOD 建的原生安全屋：原版安全屋、停用中的屋都只看原生範圍
    SafeHouse.addSafeHouse(100, 100, 14, 14, "carol")
    local off = spawn(105, 105)
    check(#Z.queue == 0, "預設關：建立時不排隊")
    T.tick()
    check(off.removed == 0 and off.unsquared == 0 and #notices() == 0, "預設關：屋內的殭屍照樣留著，不通知客戶端")
    T.sandbox("NoZombieSpawn", "true")
    spawn(105, 105)
    check(#Z.queue == 0, "沙盒值型別不對（字串）：照預設關，不排隊")

    T.section("殭屍不重生：選項開著")
    T.sandbox("NoZombieSpawn", true)
    local inside = spawn(100, 113)
    local outside = spawn(114, 105)
    local corpse = spawn(105, 105, { reanimated = true })
    local lost = spawn(nil)
    local insideId = inside.id
    check(#Z.queue == 4, "開著：四隻都排進佇列，建立當下不刪（位置可能還會改）")
    check(inside.removed == 0, "建立當下還沒刪")
    T.tick()
    check(inside.removed == 1 and inside.unsquared == 1, "屋內（邊角那格）：removeFromWorld＋removeFromSquare")
    local n = notices()
    check(#n == 1 and n[1] == insideId, "刪掉的那隻（只有它）用刪除前的 onlineId 廣播 zombiesRemoved")
    check(outside.removed == 0, "屋外緊鄰那格：留著")
    check(corpse.removed == 0, "玩家屍變：留著")
    check(lost.removed == 0 and not hookFailed(), "沒有所在格：略過、不報錯")
    check(#Z.queue == 0, "這一幀清空佇列")
    T.tick()
    check(inside.removed == 1 and #notices() == 1, "下一幀不重複處理、不重複通知")

    T.section("殭屍不重生：OnTick 之後才建立的（同一幀已送給客戶端）")
    T.tick()
    local late = spawn(103, 103)
    local lateId = late.id
    check(late.removed == 0, "本幀已清過佇列：之後才建立的留到下一幀")
    T.tick()
    n = notices()
    check(late.removed == 1 and #n == 2 and n[2] == lateId, "下一幀刪掉並通知客戶端（客戶端可能已經收到它）")
    local pooled = spawn(105, 105, { id = -1 })
    T.tick()
    check(pooled.removed == 0 and #notices() == 2, "onlineId -1（沒拿到 id、回到物件池）：不碰、不通知")
    MSH.Srv.netUp = false
    local early = spawn(104, 104)
    T.tick()
    check(early.removed == 1 and #notices() == 2, "開服前（沒有連線）：照刪，不廣播")
    MSH.Srv.netUp = true

    T.section("殭屍不重生：出錯與閘門")
    local bad = T.zombie(105, 105)
    function bad:getSquare() error("boom") end
    T.fire("OnZombieCreate", bad)
    spawn(106, 106)
    T.tick()
    check(hookFailed() and #Z.queue == 0, "所在格丟錯：hook 記 log，佇列照樣清空，不留到下一幀")
    MSH.Srv.enabled = false
    spawn(105, 105)
    check(#Z.queue == 0, "不是專用伺服器（Srv.enabled 照 Health.dedicated）：不排隊")
    MSH.Srv.enabled = true

    T.section("殭屍不重生：客戶端收到 zombiesRemoved")
    local CM = T.bootClient()
    local function handlers(name) return #(T.handlers[name] or {}) end
    local idleTick, idleCreate = handlers("OnTick"), handlers("OnZombieCreate")
    check(idleCreate == 0, "開機沒有待處理的 id：客戶端不掛 OnZombieCreate")
    local a, b, c = T.zombie(105, 105, { id = 7 }), T.zombie(106, 106, { id = 8 }), T.zombie(107, 107, { id = 9 })
    local function server(module, args) T.fire("OnServerCommand", module, "zombiesRemoved", args) end
    server(CM.MODULE, { ids = { 7, 9, 42 } })
    check(a.removed == 1 and a.unsquared == 1 and a.unregistered == 1 and c.removed == 1 and c.unregistered == 1,
        "清單上的 id：停掉聲音、removeFromWorld＋removeFromSquare（同原版刪除封包）")
    check(b.removed == 0 and b.unregistered == 0 and getCell():getZombieList():size() == 1,
        "不在清單上的殭屍不碰；找不到的 id 略過")
    server("OtherMod", { ids = { 8 } })
    server(CM.MODULE, { ids = "8" })
    server(CM.MODULE, { ids = { "8", 8.5 } })
    server(CM.MODULE, nil)
    check(b.removed == 0, "別的 module、ids 不是表、id 不是整數、沒有 args：都不動")
    local function live(z)
        for _, x in ipairs(T.zombies) do if x == z then return true end end
        return false
    end
    check(not live(a) and not live(c), "順序一（殭屍先到、通知後到）：客戶端最後沒有那隻")
    check(handlers("OnTick") == idleTick + 1 and handlers("OnZombieCreate") == 1, "有待處理的 id：才掛 OnTick 與 OnZombieCreate")

    T.section("殭屍不重生：客戶端先收到通知、殭屍同步後到")
    server(CM.MODULE, { ids = { 20 } })
    T.tick()
    -- 原版照同步封包建立：OnZombieCreate 觸發時還沒有 onlineID（NetworkZombieSimulator.java:169-174 之後才設）
    local d = T.zombie(108, 108, { id = -1 })
    T.fire("OnZombieCreate", d)
    d.id = 20
    local e = T.zombie(109, 109, { id = 21 })
    T.fire("OnZombieCreate", e)
    check(d.removed == 0, "建立當下還看不到 id：先記下")
    T.tick()
    check(d.removed == 1 and d.unregistered == 1 and not live(d), "順序二（通知先到、殭屍後到）：下一個 OnTick 拿掉，客戶端最後沒有那隻")
    check(e.removed == 0 and live(e), "同時間建立、id 不在通知裡的不碰")
    T.advance(3000)
    T.tick()
    check(handlers("OnTick") == idleTick and handlers("OnZombieCreate") == 0, "3 秒到期、沒有待處理的 id：OnTick／OnZombieCreate 都拿掉")
    local reuse = T.zombie(110, 110, { id = -1 })
    T.fire("OnZombieCreate", reuse)
    reuse.id = 20
    T.tick()
    check(reuse.removed == 0 and live(reuse), "過期後同一個 id 再出現（id 繞回重用）：不碰")

    do
        T.section("在家清殭屍：選項關著、沒人在家")
        local MSH = T.boot()
        local Z = MSH.Zombies
        local function failures()
            local c = 0
            for _, line in ipairs(T.prints) do
                if string.find(line, "tick hook zombies failed", 1, true) then c = c + 1 end
            end
            return c
        end
        local function sent() return #T.broadcastsOf("zombiesRemoved") end
        local function sweepNow() Z.lastSweep = nil; T.tick() end
        SafeHouse.addSafeHouse(100, 100, 14, 14, "carol")
        local carol = T.player({ name = "carol", x = 105.5, y = 105.5 })
        -- 掃到它就丟錯：用來看這一輪有沒有走殭屍清單
        local bomb = T.zombie(105, 105)
        function bomb:getX() error("boom") end
        local base = failures()
        sweepNow()
        check(failures() == base and sent() == 0, "預設關：屋主在家也不走殭屍清單")
        T.sandbox("ClearZombiesAtHome", "true")
        sweepNow()
        check(failures() == base, "沙盒值型別不對（字串）：照預設關")
        T.sandbox("ClearZombiesAtHome", true)
        T.sandbox("ClearZombiesAfterHours", 0)   -- 屋齡門檻另有一節；這幾節的夾具都是剛建的屋
        carol.x = 114.5
        sweepNow()
        check(failures() == base, "開著、屋主站在屋外緊鄰那格：沒人在家，不走殭屍清單")
        carol.x, carol.dead = 105.5, true
        sweepNow()
        check(failures() == base, "屋主死在屋內：不算在家")
        carol.dead = false
        T.disconnect(carol)
        T.player({ name = "dave", admin = true, x = 105.5, y = 105.5 })
        T.player({ name = "erin", x = 106.5, y = 106.5 })
        local seat2 = T.player({ name = "carol", num = 1, x = 105.5, y = 105.5 })
        sweepNow()
        check(failures() == base, "屋主離線，管理員、不在名單上的人、用屋主名字的分割畫面次座位站在屋內：不算在家")
        T.disconnect(seat2)

        T.section("在家清殭屍：屋主在家")
        T.online[#T.online + 1] = carol
        T.sandbox("NoZombieSpawn", true)
        local early = T.zombie(106, 106)   -- 清單倒著走：比 bomb 晚建立的先掃到
        local queued = spawn(107, 107)     -- 這隻走 flush
        local earlyId, queuedId = early.id, queued.id
        sweepNow()
        check(failures() == base + 1, "屋主在家：走殭屍清單；讀座標丟錯由 hook 記 log")
        check(early.removed == 1 and queued.removed == 1 and sent() == 0, "丟錯之前 flush 和 sweep 各刪了一隻：這一幀還沒通知")
        local bad = spawn(108, 108)
        function bad:getSquare() error("boom2") end
        T.tick()
        local held = T.broadcastsOf("zombiesRemoved")
        check(failures() == base + 2 and #held == 1 and #held[1].ids == 2 and held[1].ids[1] == queuedId
            and held[1].ids[2] == earlyId, "下一幀 flush 也丟錯：上一幀 flush 和 sweep 刪掉的照樣先補送")
        T.tick()
        check(sent() == 1, "補送過的不再送")
        T.sandbox("NoZombieSpawn", false)
        bad:removeFromWorld()
        bomb:removeFromWorld()
        local corner = T.zombie(100, 113)
        local out = T.zombie(114, 105)
        local corpse = T.zombie(105, 105, { reanimated = true })
        local pooled = T.zombie(105, 105, { id = -1 })
        local dying = T.zombie(105, 105, { dead = true })
        local ghost = T.zombie(105, 105, { x = 120.5, y = 105.5 })
        local runner = T.zombie(120, 105, { x = 105.5, y = 105.5 })
        SafeHouse.addSafeHouse(400, 400, 5, 5, "carol")
        local second = T.zombie(402, 402)
        local cornerId, runnerId = corner.id, runner.id
        local before = sent()
        sweepNow()
        check(failures() == base + 2, "上一輪丟錯不影響下一輪")
        check(corner.removed == 1 and corner.unsquared == 1, "屋內（邊角那格）原本就在的：removeFromWorld＋removeFromSquare")
        check(runner.removed == 1, "所在格在屋外、實際座標在屋內（走進來了）：刪")
        check(ghost.removed == 0, "所在格在屋內、實際座標在屋外（客戶端送來的預測格）：留著")
        local all = T.broadcastsOf("zombiesRemoved")
        local ids = all[#all] and all[#all].ids or {}
        check(#all == before + 1 and #ids == 2 and (ids[1] == cornerId or ids[2] == cornerId)
            and (ids[1] == runnerId or ids[2] == runnerId), "這一輪刪掉的用刪除前的 onlineId 合成一則廣播")
        check(out.removed == 0, "屋外緊鄰那格：留著")
        check(second.removed == 0, "同一位屋主名下的另一間原版屋（裡面沒人）：留著")
        check(corpse.removed == 0, "玩家屍變：留著")
        check(pooled.removed == 0, "onlineId -1：不碰")
        check(dying.removed == 0, "已經死亡、還沒變成屍體：留著")
        T.tick()
        check(sent() == before + 1, "下一幀不重複通知")
        Z.lastSweep = T.now
        local late = T.zombie(103, 103)
        T.tick(9)
        check(late.removed == 0, "上一輪之後不到 1 秒：不掃")
        T.tick()
        check(late.removed == 1, "滿 1 秒：掃到剛走進來的")

        T.section("在家清殭屍：成員、多塊安全屋、兩個選項一起開")
        local plot = SafeHouse.addSafeHouse(200, 200, 10, 10, "@MSH:1")
        SafeHouse.addSafeHouse(220, 200, 5, 5, "@MSH:1")
        local svc = T.player({ name = "@MSH:1", x = 205.5, y = 205.5 })
        local guarded = T.zombie(201, 201)
        sweepNow()
        check(guarded.removed == 0, "名字是 owner 標記的人站在屋內：不算在家")
        T.disconnect(svc)
        guarded:removeFromWorld()
        plot:addPlayer("bob")
        SafeHouse.addSafeHouse(300, 300, 10, 10, "frank")
        T.player({ name = "bob", x = 205.5, y = 205.5 })
        carol.x = 500.5
        local inPlot, inOtherPlot, inFrank, inCarol = T.zombie(201, 201), T.zombie(222, 202), T.zombie(305, 305), T.zombie(105, 105)
        sweepNow()
        check(inPlot.removed == 1 and inOtherPlot.removed == 1, "成員站在多塊安全屋的其中一塊：同一個 owner 標記的每一塊一起清")
        check(inFrank.removed == 0 and inCarol.removed == 0, "沒有屋主或成員在裡面的屋不清（管理員還站在 carol 屋內）")
        T.sandbox("NoZombieSpawn", true)
        local born = spawn(202, 202)
        local stillborn = spawn(202, 202, { dead = true })
        local walker = T.zombie(203, 203)
        local bornId, walkerId = born.id, walker.id
        before = sent()
        sweepNow()
        all = T.broadcastsOf("zombiesRemoved")
        ids = all[#all] and all[#all].ids or {}
        check(born.removed == 1 and walker.removed == 1 and #all == before + 1 and #ids == 2
            and ids[1] == bornId and ids[2] == walkerId, "同一幀新建的和走進來的：各刪一次，合成一則廣播")
        check(stillborn.removed == 0, "建立時已經死亡、還沒變成屍體的：兩個選項都不刪")
        -- 起點相同、形狀不同的兩間原版屋（同時建立，SafeHouse.getId 一樣）：不能當成同一間
        SafeHouse.addSafeHouse(600, 600, 10, 2, "gina")
        SafeHouse.addSafeHouse(600, 600, 2, 10, "hank")
        T.player({ name = "gina", x = 608.5, y = 600.5 })
        local inHank = T.zombie(600, 608)
        sweepNow()
        check(inHank.removed == 0, "起點相同的另一間原版屋（屋主不同、裡面沒人）：留著")

        T.section("在家清殭屍：閘門")
        local pre = T.zombie(204, 204)
        MSH.Srv.netUp = false
        sweepNow()
        check(pre.removed == 0, "開服前（沒有連線）：不掃")
        MSH.Srv.netUp = true
        MSH.Srv.enabled = false
        sweepNow()
        check(pre.removed == 0, "不是專用伺服器：不掃")
        MSH.Srv.enabled = true
        sweepNow()
        check(pre.removed == 1, "閘門恢復：照常清")
    end

    do
        T.section("在家清殭屍：Steam 模式的身分")
        local MSH = T.boot({ steam = true })
        local Z = MSH.Zombies
        T.sandbox("ClearZombiesAtHome", true)
        T.sandbox("ClearZombiesAfterHours", 0)
        SafeHouse.addSafeHouse(100, 100, 14, 14, "carol")
        MSH.Registry.setBinding("carol", 76561198000000201, "NEWGAME", T.now)
        local fake = T.player({ name = "carol", sid = 76561198000000299, x = 105.5, y = 105.5 })
        local z = T.zombie(105, 105)
        Z.lastSweep = nil
        T.tick()
        check(z.removed == 0, "同名但 SteamID 和綁定不符：不算在家")
        T.disconnect(fake)
        T.player({ name = "carol", sid = 76561198000000201, x = 105.5, y = 105.5 })
        Z.lastSweep = nil
        T.tick()
        check(z.removed == 1, "SteamID 和綁定相符：照常清")
    end

    do
        T.section("在家清殭屍：屋齡門檻（預設 24 小時）")
        local MSH = T.boot({ sandbox = { Tier1FreeSlots = 5, Tier2FreeSlots = 5 } })
        local Z, R = MSH.Zombies, MSH.Registry
        local H = 3600000
        local D1, D2 = "MinidoracatSafehouse.Deed1", "MinidoracatSafehouse.Deed2"
        local function rect(x, y, w, h) return { x = x, y = y, w = w, h = h } end
        local function sweepNow() Z.lastSweep = nil; T.tick() end
        local function failures()
            local c = 0
            for _, line in ipairs(T.prints) do
                if string.find(line, "tick hook zombies failed", 1, true) then c = c + 1 end
            end
            return c
        end
        T.sandbox("ClearZombiesAtHome", true)
        local young = SafeHouse.addSafeHouse(100, 100, 14, 14, "carol")
        T.player({ name = "carol", x = 105.5, y = 105.5 })
        local bomb = T.zombie(105, 105)
        function bomb:getX() error("boom") end
        local base = failures()
        sweepNow()
        check(failures() == base and bomb.removed == 0, "剛建的原版屋、屋主在家：未滿 24 小時不算在家，不走殭屍清單")
        bomb:removeFromWorld()
        -- T.tick 先前進 100 ms 才掃：建立時間設成 now - 24h + 101，掃的那一刻差 1 ms
        young.created = T.now - 24 * H + 101
        local edge = T.zombie(106, 106)
        sweepNow()
        check(edge.removed == 0, "差 1 ms 滿 24 小時：留著")
        young.created = T.now - 24 * H + 100
        sweepNow()
        check(edge.removed == 1, "剛好滿 24 小時：清掉")

        local fresh = SafeHouse.addSafeHouse(300, 300, 10, 10, "frank")
        T.player({ name = "frank", x = 305.5, y = 305.5 })
        local inOld, inNew = T.zombie(107, 107), T.zombie(305, 305)
        sweepNow()
        check(inOld.removed == 1 and inNew.removed == 0, "老屋和新屋都有屋主在家：只清老屋")
        T.sandbox("ClearZombiesAfterHours", 0)
        sweepNow()
        check(inNew.removed == 1, "設 0：新屋馬上清（和 0.17.0 一樣）")
        fresh.created = T.now + H
        local ahead = T.zombie(306, 306)
        sweepNow()
        check(ahead.removed == 1, "設 0：建立時間在未來（時鐘回撥）也照清")
        T.sandbox("ClearZombiesAfterHours", 24)
        ahead = T.zombie(306, 306)
        sweepNow()
        check(ahead.removed == 0, "設 24：建立時間在未來不清")
        ahead:removeFromWorld()
        fresh.created = T.now - 2 * H
        for _, v in ipairs({ "1", -1, 721, 1.5 }) do
            T.sandbox("ClearZombiesAfterHours", v)
            local z = T.zombie(307, 307)
            sweepNow()
            check(z.removed == 0, "不合法的值（" .. tostring(v) .. "）：照預設 24，建立 2 小時的屋不清")
            z:removeFromWorld()
        end
        T.sandbox("ClearZombiesAfterHours", 1)
        local hour = T.zombie(307, 307)
        sweepNow()
        check(hour.removed == 1, "設 1：建立 2 小時的屋清掉")

        T.section("在家清殭屍：屋齡門檻，升級與重新框選換位置")
        T.sandbox("ClearZombiesAfterHours", 24)
        local ug = T.player({ name = "ug", x = 6505, y = 6505, items = { D1, D2 } })
        local res = T.cmd(ug, "create", { rects = { rect(6500, 6500, 10, 10) }, deedType = D1 })
        T.advance(24 * H)
        local a = T.zombie(6502, 6502)
        sweepNow()
        check(res.ok and a.removed == 1, "地契建立滿 24 小時：屋主在家照清")
        local old = R.get(res.claimId)
        ug.x, ug.y = 7005, 7005
        res = T.cmd(ug, "redraw", { claimId = old.claimId, rects = { rect(7000, 7000, 10, 10) },
            expectedRevision = old.revision, deedType = D2 })
        local nu = res.ok and R.get(res.claimId)
        check(nu and nu.createdAt == old.createdAt, "用地契升級把範圍換到別處（紀錄的建立時間沿用舊的；實際 " .. tostring(res.code) .. "）")
        local b = T.zombie(7002, 7002)
        sweepNow()
        check(b.removed == 0, "升級換位置：新範圍從升級時重新起算，不清")
        T.advance(24 * H)
        sweepNow()
        check(b.removed == 1, "升級後滿 24 小時：清掉")

        T.sandbox("RedrawMinutes", 1440)
        T.sandbox("ClearZombiesAfterHours", 1)
        local rd = T.player({ name = "rd", x = 8005, y = 8005, items = { D1 } })
        res = T.cmd(rd, "create", { rects = { rect(8000, 8000, 10, 10) }, deedType = D1 })
        T.advance(61 * 60000)
        local c = T.zombie(8002, 8002)
        sweepNow()
        check(res.ok and c.removed == 1, "門檻 1 小時、建立 61 分鐘：清掉")
        old = R.get(res.claimId)
        rd.x, rd.y = 8505, 8505
        res = T.cmd(rd, "redraw", { claimId = old.claimId, rects = { rect(8500, 8500, 10, 10) }, expectedRevision = old.revision })
        local d = T.zombie(8502, 8502)
        sweepNow()
        check(res.ok and d.removed == 0, "重新框選到別處：從重畫時重新起算，不清（實際 " .. tostring(res.code) .. "）")
        T.advance(60 * 60000)
        sweepNow()
        check(d.removed == 1, "重畫後滿 1 小時：清掉")

        T.section("在家清殭屍：屋齡門檻，多塊安全屋只有一塊是新的")
        T.sandbox("ClearZombiesAfterHours", 24)
        local b1 = SafeHouse.addSafeHouse(9000, 9000, 10, 10, "@MSH:90")
        local b2 = SafeHouse.addSafeHouse(9020, 9000, 5, 5, "@MSH:90")
        b1.created, b2.created = T.now - 48 * H, T.now
        b1:addPlayer("mia")
        b2:addPlayer("mia")
        local mia = T.player({ name = "mia", x = 9005.5, y = 9005.5 })
        local inB2 = T.zombie(9021, 9001)
        sweepNow()
        check(inB2.removed == 1, "人站在老的那一塊：新補的那一塊（同一間）一起清")
        mia.x, mia.y = 9021.5, 9001.5
        local inB1 = T.zombie(9001, 9001)
        sweepNow()
        check(inB1.removed == 0, "人站在新的那一塊：未滿 24 小時，整間都不清")
    end
end
