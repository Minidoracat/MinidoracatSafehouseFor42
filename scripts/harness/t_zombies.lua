-- 安全屋範圍內不生成殭屍（Zombies.lua；沙盒 NoZombieSpawn，預設關）：OnZombieCreate 排隊、下一個 OnTick 看所在格再刪，
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
end
