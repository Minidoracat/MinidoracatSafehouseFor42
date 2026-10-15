-- 擋車（VehiclesClient.lua、Vehicles.lua；使用者 2026-10-15）：客戶端預測煞停、穿進去拉回、本來就在裡面只准往外、
-- 乘客與拖車、成員與管理員放行、提示節流；伺服器保底只傳車上不能進的人、間隔、開服前不碰連線。
return function(T)
    local check = T.check
    local function frame(p, ms)
        T.advance(ms or 16)
        T.fire("OnPlayerUpdate", p)
    end

    -- H：x 100–113、y 100–113。車頭朝 +x 從西邊開過去：車長 4.5 → 半長 2.25，加 PAD 0.1，車心 x > 97.65 就碰到；
    -- 16 ms 一幀時預測 0.05 秒（LOOK_MIN），時速 36 公里（10 公尺／秒）往前看 0.5 公尺
    T.section("擋車：客戶端")
    local MSH = T.bootClient()
    local V = MSH.VehiclesClient
    local halo = {}
    HaloTextHelper = { addBadText = function(_, text) halo[#halo + 1] = text end }
    local H = SafeHouse.addSafeHouse(100, 100, 14, 14, "carol")
    local me = T.player({ name = "me" })
    local car = T.car({ x = 97.0, y = 107, fx = 1, fy = 0, vx = 10, driver = me })
    frame(me)
    check(car.brakes == 0 and #car.impulses == 0 and V.state[0].hasGood, "預測還碰不到：不擋，記下合法位置")
    car.x = 97.2
    frame(me)
    check(car.brakes == 1 and #car.impulses == 1 and math.abs(car.impulses[1] - 1000 / 300) < 1e-9 and car.snaps == 0,
        "再兩幀就碰到：強制煞車＋速度一次歸零（mul＝質量 ÷ (0.3 × fudgedMass)），不拉回")
    check(#halo == 1 and halo[1] == "IGUI_MSH_Vehicle_Blocked", "沒有框架：頭上紅字說你不能進")
    frame(me)
    check(car.brakes == 2 and #car.impulses == 1, "速度和上次一樣（物理還沒走）：照樣煞車，不重送歸零（疊兩次會反彈）")
    car.vx = 0.4
    frame(me)
    check(car.brakes == 2, "物理走了一步、速度剩 0.4 公尺／秒：預測碰不到，不擋")
    car.x, car.vx = 98.5, 10
    frame(me, 500)
    check(car.snaps == 1 and car.x == 97.2 and car.brakes == 3 and #car.impulses == 2,
        "卡頓時穿進去 0.85 公尺：拉回上一個合法位置＋煞車＋歸零")
    check(#halo == 1, "提示 5 秒內不重複")
    T.serverOptions.SafehouseAllowTrepass = "true"
    frame(me, V.CACHE_MS)
    car.x = 97.2
    frame(me)
    check(car.brakes == 3, "伺服器 SafehouseAllowTrepass=true：照原版放行")
    T.serverOptions.SafehouseAllowTrepass = "false"
    H:addPlayer("me")
    frame(me, V.CACHE_MS)
    check(car.brakes == 3, "加進名單：最多 CACHE_MS 後放行")
    car.x = 105
    frame(me)
    check(car.brakes == 3 and car.snaps == 1, "成員開進屋裡：不擋也不拉回")

    -- 乘客：車上任何一人不能進就擋（使用者 2026-10-15）
    local guest = T.player({ name = "guest" })
    car = T.car({ x = 97.2, y = 107, fx = 1, fy = 0, vx = 10, driver = me, riders = { guest } })
    T.advance(V.NOTICE_MS)
    frame(me)
    check(car.brakes == 1 and halo[#halo] == "IGUI_MSH_Vehicle_BlockedRider", "駕駛是成員、乘客不是：照樣擋，提示寫車上有人不能進")
    local boss = T.player({ name = "boss", admin = true })
    car = T.car({ x = 97.2, y = 107, fx = 1, fy = 0, vx = 10, driver = boss })
    frame(boss)
    check(car.brakes == 0, "管理員（CanGoInsideSafehouses）自己開：放行")
    car = T.car({ x = 97.2, y = 107, fx = 1, fy = 0, vx = 10, driver = boss, riders = { guest } })
    frame(boss)
    check(car.brakes == 1, "管理員載著不能進的人：擋")
    local other = T.player({ name = "other" })
    car = T.car({ x = 97.2, y = 107, fx = 1, fy = 0, vx = 10, driver = other, riders = { guest } })
    frame(guest)
    check(car.brakes == 0 and V.state[0] == nil, "自己坐乘客座：不動（車由駕駛的客戶端算）")

    -- 本來就壓在裡面（建屋前就停在那、改分享）：沒有合法位置，只擋往裡面走
    local stranger = T.player({ name = "stranger" })
    car = T.car({ x = 101, y = 107, fx = 1, fy = 0, vx = 5, driver = stranger })
    frame(stranger)
    check(car.brakes == 1 and car.snaps == 0, "本來就在裡面、往裡面開：擋，沒有位置可拉回")
    car.vx = -5
    frame(stranger)
    check(car.brakes == 1 and not V.state[0].hasGood, "往外開：照常；還壓在裡面就不記合法位置")
    car.x = 97.0
    frame(stranger)
    check(car.brakes == 1 and V.state[0].hasGood, "開出來之後才記合法位置")
    -- 合法位置之後被新蓋的安全屋包住：拉回去也還在裡面，改照「本來就在裡面」處理
    local dave = SafeHouse.addSafeHouse(90, 100, 10, 14, "dave")
    frame(stranger, V.CACHE_MS)
    check(car.brakes == 2 and car.snaps == 0, "合法位置後來被別人的安全屋包住：不拉回，往裡面開照樣擋")
    car.vx = 5
    frame(stranger)
    check(car.brakes == 2, "往外（往最近的邊）開：照常")
    SafeHouse.removeSafeHouse(dave)

    -- 貼著邊界平行開：車身離邊界 0.45 公尺（E2E 實測 0.55 公尺不誤擋）
    car = T.car({ x = 98.45, y = 90, fx = 0, fy = 1, vy = 20, driver = stranger })
    for i = 1, 60 do
        car.y = 90 + i * 0.32
        frame(stranger)
    end
    check(car.brakes == 0 and car.snaps == 0, "貼著邊界平行開：不擋")

    -- 拖車（使用者 2026-10-15：拖車也擋）：車頭朝西倒車，拖車在車後朝 H；拖車長 3 → 車心 x > 98.4 就碰到
    local hauler = T.car({ x = 93, y = 107, fx = -1, fy = 0, vx = 10, driver = stranger })
    local trailer = T.car({ x = 97.6, y = 107, fx = -1, fy = 0, vx = 10, len = 3 })
    hauler.towing = trailer
    frame(stranger)
    check(hauler.brakes == 0, "拖車預測還碰不到：不擋")
    hauler.x, trailer.x = 93.4, 98.0
    frame(stranger)
    check(hauler.brakes == 1 and #hauler.impulses == 1 and #trailer.impulses == 1,
        "倒車、拖車快碰到：車煞車，車和拖車都歸零")
    hauler.x, trailer.x, hauler.vx, trailer.vx = 94.6, 99.2, 11, 11
    frame(stranger, 500)
    check(hauler.snaps == 1 and trailer.snaps == 1 and hauler.x == 93 and trailer.x == 97.6,
        "拖車穿進去：車和拖車一起拉回同一幀存的位置")
    HaloTextHelper = nil

    T.section("擋車：伺服器保底")
    MSH = T.boot()
    local G = MSH.Vehicles
    H = SafeHouse.addSafeHouse(100, 100, 14, 14, "carol")
    H:addPlayer("member")
    local intruder = T.player({ name = "intruder", x = 105.5, y = 107.5 })
    local member = T.player({ name = "member", x = 105.5, y = 108.5 })
    local admin = T.player({ name = "boss", x = 106.5, y = 106.5, admin = true })
    local walker = T.player({ name = "walker", x = 103.5, y = 103.5 })
    T.car({ x = 105.5, y = 108, driver = member, riders = { intruder, admin } })
    T.tick()
    check(#T.teleports == 1 and T.teleports[1].name == "intruder" and intruder.x == 99 and intruder.y == 99,
        "車上不能進的人：傳到屋外 (x−1, y−1)")
    check(member.x == 105.5 and admin.x == 106.5 and walker.x == 103.5, "成員、管理員與走路進來的人（照原版週期趕人）都不動")
    check(T.logged("VEHICLE_TRESPASS\tintruder\t-\t-\t105,107"), "稽核 VEHICLE_TRESPASS：誰、哪一格")
    intruder.x, intruder.y = 105.5, 107.5
    T.tick()
    check(#T.teleports == 1, "伺服器還看到他在裡面（下車、傳送要 0.2 秒）：間隔內不重送")
    T.advance(G.GAP_MS)
    T.tick()
    local lines = 0
    for _, l in ipairs(T.logs) do
        if string.find(l, "VEHICLE_TRESPASS", 1, true) then lines = lines + 1 end
    end
    check(#T.teleports == 2 and lines == 1, "過了間隔還在裡面：再傳一次；稽核每人每分鐘一行")
    MSH.Srv.netUp, T.netUp = false, false
    local early = #T.netEarly
    check(pcall(G.tick, T.now) and #T.netEarly == early, "開服前：不碰 getOnlinePlayers（會 NPE）")
end
