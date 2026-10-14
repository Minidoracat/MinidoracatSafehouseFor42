-- 安全屋重生點（Respawn.lua，使用者 2026-10-14）：設點的資格與伺服器端座標檢查、清除、私有檔往返、
-- 伺服器 OnNewGame 套用（失效時不動、點保留）、開服時把原版重生旗標換成本 MOD 的點（只收原版真的會採用的）。
return function(T)
    local check = T.check
    local MSH, R
    local MEMBER = 1

    local function boot(opts)
        MSH = T.boot(opts)
        R = MSH.Registry
        T.serverOptions.SafehouseAllowRespawn = "true"
        return MSH
    end
    local function rect(x, y, w, h) return { x = x, y = y, w = w, h = h } end
    -- 直接放一筆 active 紀錄＋每塊一個原生（不經建立指令）
    local function seed(owner, rects, grants)
        local id = R.allocId()
        local rec = R.newRecord({ claimId = id, rects = rects, title = "t", owner = owner, source = MSH.SOURCE.DEED,
            deedTier = 1, createdAt = T.now, grants = grants })
        local houses = MSH.Native.build(rec, {})
        for i, hs in ipairs(houses) do rec.rects[i].created = hs:getDatetimeCreated() end
        R.put(rec)
        return rec, houses
    end
    local function set(p, rec, args)
        args = args or {}
        args.claimId = rec.claimId
        return T.cmd(p, "setRespawn", args)
    end
    local function code(res) return res and res.code end
    local function same(pt, x, y, z) return pt ~= nil and pt.x == x and pt.y == y and pt.z == z end
    local function lastLine()
        local f = T.files[R.privatePath()]
        return f and f.lines[#f.lines]
    end
    -- 伺服器 OnNewGame 的新角色：還不在線上名單（CreatePlayerPacket.java:296-301），位置是原版選的出生點
    local function newChar(name)
        local p = T.player({ name = name, x = 9000.5, y = 9000.5, z = 0, offline = true })
        T.fire("OnNewGame", p)
        return p
    end
    local function moved(p, x, y, z)
        return p.x == x + 0.5 and p.y == y + 0.5 and p.z == z and p.lx == x + 0.5 and p.ly == y + 0.5 and p.lz == z
    end
    local function unmoved(p) return p.x == 9000.5 and p.y == 9000.5 and p.z == 0 and p.lx == nil end

    T.section("設點：站在自己有角色的 ACTIVE 安全屋裡，用伺服器端座標")
    boot()
    local rec = seed("alice", { rect(100, 100, 10, 10), rect(110, 100, 6, 4) }, { { user = "bob", bits = MEMBER } })
    local alice = T.player({ name = "alice", x = 112.7, y = 101.2, z = 1 })
    local bob = T.player({ name = "bob", x = 105.5, y = 105.5 })
    local eve = T.player({ name = "eve", x = 104.5, y = 104.5 })
    local res = set(alice, rec, { expectedRevision = rec.revision })
    check(res.ok and same(R.spawn("alice"), 112, 101, 1) and res.x == 112 and res.y == 101 and res.z == 1,
        "屋主站在第二塊裡（樓上）：點＝當時站的那一格（取整，含 z）")
    check(lastLine() == "1\tspawn\talice\t112\t101\t1", "先寫私有檔：1 spawn 名字 x y z")
    check(T.logged("RESPAWN_SET"), "寫 audit RESPAWN_SET")
    check(set(bob, rec).ok and same(R.spawn("bob"), 105, 105, 0), "成員（grant 帶 MEMBER）也能設")
    alice.x, alice.y = 99.9, 101.2
    check(code(set(alice, rec)) == "NOT_ON_SITE" and same(R.spawn("alice"), 112, 101, 1),
        "站在範圍外（差一格）：NOT_ON_SITE，原本的點不動")
    alice.x, alice.y = 116.0, 101.0
    check(code(set(alice, rec)) == "NOT_ON_SITE", "範圍是半開的：第二塊右緣外那一格不算")
    check(code(set(eve, rec)) == "NOT_FOUND" and R.spawn("eve") == nil, "在這間沒有角色：NOT_FOUND（不透露存在）")
    alice.x, alice.y, alice.z = 101.5, 108.5, 0
    check(code(set(alice, rec, { expectedRevision = rec.revision + 1 })) == "STALE_REVISION", "revision 不符：STALE_REVISION")
    T.serverOptions.SafehouseAllowRespawn = "false"
    check(code(set(alice, rec)) == "RESPAWN_DISABLED" and same(R.spawn("alice"), 112, 101, 1),
        "伺服器沒開 SafehouseAllowRespawn：RESPAWN_DISABLED")
    T.serverOptions.SafehouseAllowRespawn = "true"
    rec.lifecycle = MSH.LIFECYCLE.LAPSED
    check(code(set(alice, rec)) == "WRONG_LIFECYCLE", "安全屋不是 active（停用）：WRONG_LIFECYCLE")
    rec.lifecycle = MSH.LIFECYCLE.ACTIVE
    T.failWrites = true
    check(code(set(alice, rec)) == "SAVE_FAILED" and same(R.spawn("alice"), 112, 101, 1), "寫檔失敗：SAVE_FAILED、記憶體不改")
    T.failWrites = false
    check(set(alice, rec).ok and same(R.spawn("alice"), 101, 108, 0), "再設一次：取代舊的點（每人一個）")
    check(code(T.cmd(alice, "setRespawn", { claimId = rec.claimId, x = 1 })) == "BAD_ARGS", "多帶欄位（客戶端座標）：BAD_ARGS")

    T.section("detail 與 myRespawn：只給自己看")
    local d = T.cmd(alice, "detail", { claimId = rec.claimId })
    check(d.respawn and d.respawn.allowed and same(d.respawn.here, 101, 108, 0) and not d.respawn.elsewhere,
        "detail：自己的點在這間（here）")
    local other = seed("bob", { rect(200, 200, 8, 8) })
    d = T.cmd(alice, "detail", { claimId = rec.claimId })
    local dBob = T.cmd(bob, "detail", { claimId = other.claimId })
    check(dBob.respawn.here == nil and dBob.respawn.elsewhere, "detail：點在別間＝elsewhere、不給座標")
    local mine = T.cmd(alice, "myRespawn", {})
    check(mine.ok and same(mine.point, 101, 108, 0) and mine.claimId == rec.claimId and mine.allowed, "myRespawn：有效的點")
    check(T.cmd(eve, "myRespawn", {}).point == nil, "沒有點：myRespawn 沒有 point")
    T.serverOptions.SafehouseAllowRespawn = "false"
    mine = T.cmd(alice, "myRespawn", {})
    check(mine.ok and mine.point == nil and mine.allowed == false, "總開關關著：myRespawn 不給點")
    T.serverOptions.SafehouseAllowRespawn = "true"

    T.section("清除與私有檔往返")
    check(T.cmd(bob, "clearRespawn", {}).ok and R.spawn("bob") == nil and lastLine() == "1\tspawn\tbob\t-",
        "清除：寫刪除行（-）、記憶體拿掉")
    check(T.cmd(bob, "clearRespawn", {}).ok, "沒有點時清除也回 OK")
    set(bob, rec)
    boot({ keepGmd = true, keepFiles = true, keepHouses = true })
    check(same(R.spawn("alice"), 101, 108, 0) and same(R.spawn("bob"), 105, 105, 0) and R.privateBad == 0,
        "重開：私有檔照最後一行還原（alice 取代後的點、bob 清除後重設）")
    T.files[R.privatePath()].lines[#T.files[R.privatePath()].lines + 1] = "1\tspawn\talice\t1.5\t2\t0"
    T.files[R.privatePath()].lines[#T.files[R.privatePath()].lines + 1] = "1\tspawn\talice\tx"
    boot({ keepGmd = true, keepFiles = true, keepHouses = true })
    check(same(R.spawn("alice"), 101, 108, 0) and R.privateBad == 2, "壞行（小數、刪除欄不是 -）略過並計數")
    bob = T.player({ name = "bob", x = 0, y = 0 })
    T.cmd(bob, "clearRespawn", {})
    boot({ keepGmd = true, keepFiles = true, keepHouses = true })
    check(R.spawn("bob") == nil and same(R.spawn("alice"), 101, 108, 0), "重開：刪除行之後沒有點，別人的不受影響")

    T.section("套用：伺服器 OnNewGame 把新角色放到點上；失效時不動、點保留")
    rec = R.get(rec.claimId)
    local p = newChar("alice")
    check(moved(p, 101, 108, 0), "屋主重生：位置與 last 位置都是點＋0.5（z 照點）")
    check(T.logged("RESPAWN_APPLY"), "寫 audit RESPAWN_APPLY")
    alice = T.player({ name = "alice", x = 113.2, y = 102.9, z = 2 })
    set(alice, rec)
    T.solid["113,102,2"] = true
    check(moved(newChar("alice"), 113, 102, 2), "樓上的點、那格有可站的地板：z 照點")
    T.solid["113,102,2"] = nil
    check(moved(newChar("alice"), 113, 102, 0) and same(R.spawn("alice"), 113, 102, 2)
        and T.logged("RESPAWN_APPLY\talice\t" .. rec.claimId .. "\tGROUND"),
        "樓上那格沒有地板：落到正下方地面 z=0、audit 記 GROUND，存的點不改")
    T.solid["113,102,2"], T.unloaded["113,102"] = true, true
    check(moved(newChar("alice"), 113, 102, 0), "樓上那格沒載入：z=0")
    T.unloaded["113,102"] = nil
    check(unmoved(newChar("eve")), "沒有點：原版出生點照舊")
    T.serverOptions.SafehouseAllowRespawn = "false"
    check(unmoved(newChar("alice")) and R.spawn("alice") ~= nil, "總開關關著：不動、點保留")
    T.serverOptions.SafehouseAllowRespawn = "true"
    bob = T.player({ name = "bob", x = 103.5, y = 103.5 })
    check(set(bob, rec).ok and moved(newChar("bob"), 103, 103, 0), "成員有點：重生到點上")
    rec.grants = {}
    check(unmoved(newChar("bob")) and same(R.spawn("bob"), 103, 103, 0), "成員被移除（沒有角色）：不動、點保留")
    rec.grants = { { user = "bob", bits = MEMBER } }
    check(moved(newChar("bob"), 103, 103, 0), "恢復成員：點又能用")
    rec.lifecycle = MSH.LIFECYCLE.LAPSED
    check(unmoved(newChar("alice")), "安全屋停用（不是 active）：不動")
    rec.lifecycle = MSH.LIFECYCLE.ACTIVE
    local rel = T.cmd(alice, "release", { claimId = rec.claimId, expectedRevision = rec.revision })
    check(rel.ok and unmoved(newChar("alice")) and R.spawn("alice") ~= nil, "安全屋放棄之後：不動（點留著但失效）")
    check(T.cmd(alice, "myRespawn", {}).point == nil, "失效的點：myRespawn 不給")
    -- 丟錯不能中斷原版建角色（OnNewGame 在 CreatePlayerPacket.processServer 裡同步執行）
    local realList = R.list
    R.list = function() error("boom") end
    local okFire = pcall(newChar, "bob")
    R.list = realList
    local printed = false
    for _, line in ipairs(T.prints) do if string.find(line, "respawn apply failed", 1, true) then printed = true end end
    check(okFire and printed, "套用時丟錯：包在 pcall 裡、記 log、不往外丟")

    T.section("身分：套用與清除都照 principal（Steam 模式比對綁定的 SteamID、改名跡象拒絕清除）")
    boot({ steam = true })
    seed("sam", { rect(500, 500, 8, 8) })
    local SID_SAM = 76561198000000301
    R.setBinding("sam", SID_SAM, "NEWGAME", T.now)
    R.setSpawn("sam", { x = 503, y = 504, z = 0 })
    local function steamChar(sid)
        local sp = T.player({ name = "sam", sid = sid, x = 9000.5, y = 9000.5, z = 0, offline = true })
        T.fire("OnNewGame", sp)
        return sp
    end
    check(unmoved(steamChar(76561198000000399)), "登入名相同但 SteamID 和綁定不符：不套用（原版出生點）")
    check(moved(steamChar(SID_SAM), 503, 504, 0), "SteamID 相符：放到點上")
    local sidV = 76561198000000302
    T.fire("OnNewGame", T.player({ name = "vera2", sid = sidV, offline = true }))
    local vera = T.player({ name = "vera", sid = sidV })
    T.tick(40)
    R.setSpawn("vera", { x = 501, y = 501, z = 0 })
    check(T.cmd(vera, "clearRespawn", {}).code == "IDENTITY_UNVERIFIED" and same(R.spawn("vera"), 501, 501, 0),
        "改名跡象下清除：IDENTITY_UNVERIFIED、點還在")
    local samP = T.player({ name = "sam", sid = SID_SAM })
    check(T.cmd(samP, "clearRespawn", {}).ok and R.spawn("sam") == nil, "綁定相符的人清除：OK")

    T.section("開服：原版重生旗標換成本 MOD 的點（只收原版真的會採用的），再清掉 managed 原生的全部旗標")
    boot()
    -- 清單順序就是原生建立順序：hasSafehouse 照這個順序取第一個（SafeHouse.java:97-103）
    local _, hY = seed("yuri", { rect(300, 300, 10, 10) }, { { user = "dan", bits = MEMBER } })
    local recZ, hZ = seed("zoe", { rect(400, 400, 9, 7), rect(409, 400, 4, 4) },
        { { user = "dan", bits = MEMBER }, { user = "erin", bits = MEMBER }, { user = "carol", bits = MEMBER },
          { user = "frank", bits = MEMBER } })
    local foreign = SafeHouse.addSafeHouse(600, 600, 5, 5, "zed")
    foreign:addPlayer("zed2")
    foreign:setRespawnInSafehouse(true, "zed2")
    hZ[1]:setRespawnInSafehouse(true, "carol")      -- 只在 Z：原版會採用 → 換成 Z 第一塊的中心
    hZ[1]:setRespawnInSafehouse(true, "zoe")        -- 屋主也是名單上的人
    hZ[1]:setRespawnInSafehouse(true, "dan")        -- dan 的 first-match 是 Y：原版不會採用 → 只清掉
    hZ[2]:setRespawnInSafehouse(true, "erin")       -- 第二塊：first-match 是第一塊 → 只清掉
    hZ[1]:setRespawnInSafehouse(true, "ghost")      -- 沒有角色 → 只清掉
    hZ[1]:setRespawnInSafehouse(true, "frank")      -- 已有本 MOD 的點 → 點不變、旗標清掉
    hY[1]:setRespawnInSafehouse(true, "yuri")
    R.setSpawn("frank", { x = 401, y = 401, z = 1 })
    boot({ keepGmd = true, keepFiles = true, keepHouses = true })
    check(same(R.spawn("carol"), 404, 403, 0) and same(R.spawn("zoe"), 404, 403, 0),
        "原版會採用的旗標：換成那一塊的中心（x＋⌊w/2⌋、y＋⌊h/2⌋、z＝0），不是原版 h/w 對調的點")
    check(same(R.spawn("yuri"), 305, 305, 0), "別間的屋主旗標也照收")
    check(R.spawn("dan") == nil and R.spawn("erin") == nil and R.spawn("ghost") == nil,
        "first-match 不是這塊（dan 在 Y、erin 的第二塊）或沒有角色：不換")
    check(same(R.spawn("frank"), 401, 401, 1), "已經有點：不覆蓋")
    local flags = 0
    for _, hs in ipairs(T.houses) do
        if MSH.claimIdOf(hs.owner) then flags = flags + hs.respawn:size() end
    end
    check(flags == 0, "managed 原生上的旗標全部清掉")
    check(foreign:isRespawnInSafehouse("zed2"), "原版（foreign）安全屋的旗標不動")
    check(T.logged("converted=3 cleared=7 failed=0"), "audit 只記數量（不寫名字與座標）")
    boot({ keepGmd = true, keepFiles = true, keepHouses = true })
    check(not T.logged("RESPAWN_LEGACY"), "下次開機沒有旗標可轉：不寫 audit")
    -- 清除過（私有檔有過 spawn 行）的人：世界回滾帶回舊旗標，重開也不再建點，只清旗標
    local hz = nil
    for _, hs in ipairs(T.houses) do if hs.owner == MSH.marker(recZ.claimId) and hs.x == 400 then hz = hs end end
    R.setSpawn("carol", nil)
    hz:setRespawnInSafehouse(true, "carol")
    boot({ keepGmd = true, keepFiles = true, keepHouses = true })
    check(R.spawn("carol") == nil and not hz:isRespawnInSafehouse("carol") and T.logged("converted=0 cleared=1 failed=0"),
        "匯入→清除→舊旗標回來→重開：不再建點、旗標清掉")
    -- 寫不進私有檔：開不了檔（getFileWriter 回 nil）與靜默失敗（開得了、不丟錯、沒寫進去）都不換、旗標留著，下次開機再試
    local rz = R.get(recZ.claimId)
    rz.grants[#rz.grants + 1] = { user = "gail", bits = MEMBER }
    rz.grants[#rz.grants + 1] = { user = "hank", bits = MEMBER }
    hz:addPlayer("gail")
    hz:addPlayer("hank")
    hz:setRespawnInSafehouse(true, "gail")
    boot({ keepGmd = true, keepFiles = true, keepHouses = true,
        beforeStart = function(env) env.failWrites = true end })
    check(R.spawn("gail") == nil and hz:isRespawnInSafehouse("gail") and T.logged("failed=1"),
        "開不了私有檔：不換、旗標留著")
    hz:setRespawnInSafehouse(true, "hank")
    boot({ keepGmd = true, keepFiles = true, keepHouses = true,
        beforeStart = function(env) env.silentWrites = true end })
    check(hz:isRespawnInSafehouse("gail") and hz:isRespawnInSafehouse("hank") and T.logged("converted=0 cleared=0 failed=2"),
        "寫入靜默失敗（讀回私有檔沒有那一行）：不算轉換、旗標留著")
    boot({ keepGmd = true, keepFiles = true, keepHouses = true })
    check(same(R.spawn("gail"), 404, 403, 0) and same(R.spawn("hank"), 404, 403, 0) and not hz:isRespawnInSafehouse("gail")
        and not hz:isRespawnInSafehouse("hank"), "下次開機寫得進去：轉換成功、旗標清掉")
end
