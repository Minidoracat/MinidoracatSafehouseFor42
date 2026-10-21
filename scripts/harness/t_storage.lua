-- 物品搜尋與遠距拿取（使用者 2026-10-20；server Storage.lua、client StorageScan.lua、StoragePanel.lua）：
-- 伺服器兩段拿取的條件（模式、TAKE、站的位置、那格在範圍內）、原版搬運時間、等待與不動的檢查、三種搬法的同步呼叫、
-- 背包放不下與東西不在；客戶端掃描（容器、背包往裡一層、地上、車、人形模特兒、沒載入、沒開過、樓層、分幀）、篩選與排序；
-- 面板只在開著或帶路時掛 OnTick、不能拿的原因、帶路到了切戰利品視窗、計時動作跑完才送完成。
-- 假世界（格子、物件、車）、假框架、假計時動作只在本檔用到，結束時還原全域。
return function(T)
    local check = T.check
    local NAMES = { "getCell", "getTextOrNull", "CharacterTrait", "getWorldMarkers", "getPlayerLoot", "ISInventoryPage",
        "ISTimedActionQueue", "ISBaseTimedAction", "ISPanel", "ISButton", "getTextManager", "getCore", "UIFont", "MinidoracatUI" }
    local saved = {}
    for _, k in ipairs(NAMES) do saved[k] = _G[k] end
    getTextOrNull = function() return nil end
    CharacterTrait = { DEXTROUS = "dex", ALL_THUMBS = "thumbs" }

    -- ===== 假世界 =====
    local W
    local nextId = 1000
    local function resetWorld(minZ, maxZ)
        W = { sq = {}, unloaded = {}, removed = {}, chunk = {} }
        function W.chunk.getMinLevel() return minZ or 0 end
        function W.chunk.getMaxLevel() return maxZ or 0 end
    end
    local function item(name, w, cat)
        nextId = nextId + 1
        local it = T.item("Base." .. name)
        it.id, it.name, it.w, it.cat = nextId, name, w or 0.1, cat or "Material"
        function it:getID() return self.id end
        function it:getDisplayName() return self.name end
        function it:getActualWeight() return self.w end
        function it:getUnequippedWeight() return self.w end
        function it:getDisplayCategory() return self.cat end
        function it:getCategory() return "Item" end
        function it:getTex() return nil end
        function it:setWorldItem(wo) self.world = wo end
        return it
    end
    local function box(kind, unexplored)
        local c = T.container(kind)
        function c:getCustomName() return nil end
        function c:getDisplayType() return self.kind end
        function c:isExplored() return not unexplored end
        function c:setExplored(on) self.explored = on end
        function c:setHasBeenLooted(on) self.looted = on end
        function c:getParent() return self.parent end
        return c
    end
    -- 容器所在的物件（IsoThumpable）：密碼鎖 code > 0，或掛鎖（keyId）
    local function lockWith(c, code, keyId)
        local o = { __class = "IsoThumpable", code = code or 0, key = keyId }
        function o:getLockedByCode() return self.code end
        function o:isLockedByPadlock() return self.key ~= nil end
        function o:getKeyId() return self.key or -1 end
        c.parent = o
        return o
    end
    local function bag(name, items)
        local b = item(name, 1, "Container")
        b.__class = "InventoryContainer"
        b.inner = box("bag")
        for _, it in ipairs(items) do b.inner:AddItem(it) end
        return b
    end
    local function square(x, y, z)
        local k = x .. "," .. y .. "," .. (z or 0)
        local s = W.sq[k]
        if s ~= nil then return s end
        s = { x = x, y = y, z = z or 0, objs = {}, wos = {} }
        function s:getX() return self.x end
        function s:getY() return self.y end
        function s:getZ() return self.z end
        function s:getChunk() return W.chunk end
        function s:getObjects() return T.javaList(self.objs) end
        function s:getWorldObjects() return T.javaList(self.wos) end
        function s:getVehicleContainer() return self.car end
        function s:transmitRemoveItemFromSquare(wo)
            for i, x in ipairs(self.wos) do if x == wo then table.remove(self.wos, i) break end end
            W.removed[#W.removed + 1] = wo
        end
        W.sq[k] = s
        return s
    end
    getCell = function()
        return { getGridSquare = function(_, x, y, z)
            if W.unloaded[x .. "," .. y] then return nil end
            if (z or 0) == 0 then return square(x, y, 0) end
            return W.sq[x .. "," .. y .. "," .. z]
        end }
    end
    local function furniture(sq, ...)
        local o = { __class = "IsoObject", cs = { ... } }
        function o:getContainerCount() return #self.cs end
        function o:getContainerByIndex(i) return self.cs[i + 1] end
        sq.objs[#sq.objs + 1] = o
        return o
    end
    local function onFloor(sq, it)
        local wo = { __class = "IsoWorldInventoryObject", item = it }
        function wo:getItem() return self.item end
        sq.wos[#sq.wos + 1] = wo
        it.world = wo
        return wo
    end
    local function fill(c, list)
        for _, it in ipairs(list) do c:AddItem(it) end
        return list
    end
    -- 玩家背包的容量（hasRoomFor／getEffectiveCapacity／getCapacityWeight）與特質
    local function carrier(p, max, traits)
        local inv = p:getInventory()
        inv.max, inv.keys = max, {}
        function inv:haveThisKeyId(id) return self.keys[id] end
        function inv:getCapacityWeight()
            local w = 0
            for _, x in ipairs(self.items) do w = w + (x.w or 0) end
            return w
        end
        function inv:getEffectiveCapacity() return self.max end
        function inv:hasRoomFor(_, it) return self:getCapacityWeight() + (it.w or 0) <= self.max end
        p.traits = traits or {}
        function p:hasTrait(t) return self.traits[t] == true end
        function p:isWearingAwkwardGloves() return false end
        return p
    end
    local function holds(c, it)
        for _, x in ipairs(c.items) do if x == it then return true end end
        return false
    end
    local function ids(list)
        local out = {}
        for i, it in ipairs(list) do out[i] = it.id end
        return out
    end

    -- ===== 伺服器 =====
    local MSH, R
    local MEMBER, TAKE = 1, 128
    local function rect(x, y, w, h) return { x = x, y = y, w = w, h = h } end
    local function seed(owner, rects, grants)
        local id = R.allocId()
        local rec = R.newRecord({ claimId = id, rects = rects, title = "t", owner = owner, source = "deed",
            deedTier = 1, createdAt = T.now, grants = grants })
        local houses = MSH.Native.build(rec, {})
        for i, hs in ipairs(houses) do rec.rects[i].created = hs:getDatetimeCreated() end
        R.put(rec)
        return rec
    end
    local function code(res) return res and res.code end

    T.section("遠距拿取：模式、權限、站的位置、那格在範圍內（storageBegin）")
    resetWorld()
    MSH = T.boot({ sandbox = { StorageMode = 3 } })
    R = MSH.Registry
    local rec = seed("alice", { rect(100, 100, 10, 10) }, { { user = "bob", bits = MEMBER + TAKE }, { user = "carl", bits = MEMBER } })
    local crate = box("crate")
    furniture(square(103, 103, 0), crate)
    local nails = fill(crate, { item("Nails", 0.01), item("Nails", 0.01), item("Nails", 0.01) })
    local hammer = crate:AddItem(item("Hammer", 2))
    local bandages = { item("Bandage", 0.1), item("Bandage", 0.1) }
    local school = crate:AddItem(bag("School Bag", bandages))
    local apple = item("Apple", 0.2, "Food")
    onFloor(square(104, 104, 0), apple)
    local alice = carrier(T.player({ name = "alice", x = 101.5, y = 101.5 }), 50)
    local bob = carrier(T.player({ name = "bob", x = 108.5, y = 108.5 }), 50)
    local carl = carrier(T.player({ name = "carl", x = 102.5, y = 102.5 }), 50)
    local eve = carrier(T.player({ name = "eve", x = 102.5, y = 102.5 }), 50)
    local function begin(p, x, y, list, z)
        return T.cmd(p, "storageBegin", { claimId = rec.claimId, x = x, y = y, z = z or 0, ids = ids(list) })
    end
    local function take(p) return T.cmd(p, "storageTake", { claimId = rec.claimId }) end

    T.sandbox("StorageMode", 2)
    check(code(begin(alice, 103, 103, nails)) == "STORAGE_OFF", "沙盒只指引：STORAGE_OFF（伺服器不接受遠距拿）")
    T.sandbox("StorageMode", 3)
    check(code(begin(carl, 103, 103, nails)) == "PERM_DENIED", "成員沒有遠距拿取權限：PERM_DENIED")
    check(code(begin(eve, 103, 103, nails)) == "NOT_FOUND", "在這間沒有角色：NOT_FOUND")
    alice.x = 99.9
    check(code(begin(alice, 103, 103, nails)) == "NOT_ON_SITE", "站在範圍外一格：NOT_ON_SITE")
    T.sandbox("StorageReach", 2)
    alice.x = 98.5
    check(begin(alice, 103, 103, { nails[1] }).ok, "管理員放寬 2 格（StorageReach）：站在左邊外第 2 格也能拿")
    alice.x = 97.9
    check(code(begin(alice, 103, 103, nails)) == "NOT_ON_SITE", "放寬 2 格時外面第 3 格：NOT_ON_SITE")
    alice.x = 111.5
    check(begin(alice, 103, 103, { nails[1] }).ok, "右邊外第 2 格也可以（範圍半開，往外照格數算）")
    alice.x = 101.5
    check(code(begin(alice, 111, 103, nails)) == "BAD_ARGS", "放寬的只有站的位置：外面第 2 格的東西照樣不能拿")
    T.sandbox("StorageReach", 0)
    alice.x = 101.5
    check(code(begin(alice, 120, 103, nails)) == "BAD_ARGS", "要拿的那格不在這間範圍裡：BAD_ARGS")
    check(code(T.cmd(alice, "storageBegin", { claimId = rec.claimId, x = 103, y = 103, z = 0, ids = {} })) == "BAD_ARGS",
        "一件都沒帶：BAD_ARGS")
    local many = {}
    for i = 1, MSH.LIMIT.STORAGE_PICKS + 1 do many[i] = i end
    check(code(T.cmd(alice, "storageBegin", { claimId = rec.claimId, x = 103, y = 103, z = 0, ids = many })) == "BAD_ARGS",
        "超過一次的上限：BAD_ARGS")
    rec.lifecycle = MSH.LIFECYCLE.LAPSED
    check(code(begin(alice, 103, 103, nails)) == "WRONG_LIFECYCLE", "不是 active：WRONG_LIFECYCLE")
    rec.lifecycle = MSH.LIFECYCLE.ACTIVE

    T.section("遠距拿取：原版搬運時間，等夠久、沒走開才搬（storageTake）")
    local res = begin(bob, 103, 103, { nails[1], nails[2], nails[3], hammer })
    check(res.ok and res.n == 4 and res.durMs == 3 * 10 + 2000, "每件 1000 ms × min(重量, 3)：三盒釘子 30 ms＋鐵鎚 2000 ms")
    bob.traits.dex = true
    res = begin(bob, 103, 103, { hammer })
    check(res.ok and res.durMs == 1000, "靈巧：時間減半（Transaction.java:395-397）")
    bob.traits.dex = nil
    check(code(take(bob)) == "TAKE_STOPPED" and holds(crate, hammer), "時間還沒到就送完成：TAKE_STOPPED、東西不動")
    T.advance(5000)
    check(code(take(bob)) == "TAKE_STOPPED" and holds(crate, hammer), "同一次只能送一次完成（中斷後要重新開始）")
    begin(bob, 103, 103, { hammer })
    bob.x = 106.5
    T.advance(2500)
    check(code(take(bob)) == "TAKE_STOPPED" and holds(crate, hammer), "等的時候走開兩格：TAKE_STOPPED")
    bob.x = 108.5
    begin(bob, 103, 103, { hammer })
    T.advance(70000)
    check(code(take(bob)) == "TAKE_STOPPED" and holds(crate, hammer), "等太久（超過時間＋60 秒）：TAKE_STOPPED")
    begin(bob, 103, 103, { hammer })
    T.advance(2100)
    bob.x = 109.4
    T.itemSyncs = {}
    res = take(bob)
    check(res.ok and res.got == 1 and not holds(crate, hammer) and holds(bob:getInventory(), hammer),
        "時間到、只挪了一格內：鐵鎚搬進背包")
    local sy = T.itemSyncs
    check(#sy == 2 and sy[1].op == "remove" and sy[1].container == crate and sy[2].op == "add"
        and sy[2].container == bob:getInventory(), "家具容器：先送移除、再送加進背包（sendRemove／sendAdd）")
    check(T.logged("STORAGE_TAKE"), "寫 audit STORAGE_TAKE")
    check(crate.explored == true and crate.looted == true, "來源容器標成已探索、已被拿過（同原版拿取；戰利品重生看這兩個）")
    local wrench = crate:AddItem(item("Wrench", 1))
    begin(bob, 103, 103, { wrench })
    bob.x = 105.5
    T.advance(300)
    T.tick()
    bob.x = 109.4
    T.advance(1000)
    check(code(take(bob)) == "TAKE_STOPPED" and holds(crate, wrench),
        "等的時候走開再走回原地：TAKE_STOPPED（伺服器邊等邊看，不只看結束那一刻）")

    T.section("遠距拿取：背包裡的整個拿出再放回、地上的走 transmitRemoveItemFromSquare")
    begin(alice, 103, 103, bandages)
    T.advance(1000)
    T.itemSyncs = {}
    res = take(alice)
    sy = T.itemSyncs
    check(res.ok and res.got == 2 and holds(crate, school) and #school.inner.items == 0
        and holds(alice:getInventory(), bandages[1]) and holds(alice:getInventory(), bandages[2]),
        "背包裡的兩件：進背包、書包留在原容器、裡面空了")
    check(#sy == 4 and sy[1].op == "remove" and sy[1].item == school and sy[2].op == "add" and sy[2].item == school
        and sy[2].container == crate and sy[3].item == bandages[1] and sy[4].item == bandages[2],
        "同一個書包只拿出放回一次（sh-storage-1020b：直接從書包拿，客戶端會留下那件）")
    begin(alice, 104, 104, { apple })
    T.advance(1000)
    T.itemSyncs = {}
    res = take(alice)
    check(res.ok and res.got == 1 and #square(104, 104, 0).wos == 0 and #W.removed == 1 and apple.world == nil
        and holds(alice:getInventory(), apple), "地上的：transmitRemoveItemFromSquare＋setWorldItem(nil)、進背包")
    local kit = { item("Bandage", 0.1) }
    local pouch = crate:AddItem(bag("Pouch", kit))
    res = begin(alice, 103, 103, { pouch, kit[1] })
    check(res.ok and res.n == 1 and res.gone == 1, "同一批有背包又有它裡面的：裡面的跟著背包走，不另外搬")
    T.advance(1500)
    res = take(alice)
    check(res.ok and res.got == 1 and holds(alice:getInventory(), pouch) and holds(pouch.inner, kit[1])
        and not holds(crate, pouch), "整個背包進背包、裡面的還在（不會拿出放回把背包留在原處）")

    T.section("遠距拿取：背包放不下、東西已經不在")
    local bricks = fill(crate, { item("Brick", 4), item("Brick", 4), item("Brick", 4) })
    local dave = carrier(T.player({ name = "dave", x = 101.5, y = 101.5 }), 9)
    rec.grants[#rec.grants + 1] = { user = "dave", bits = MEMBER + TAKE }
    res = begin(dave, 103, 103, bricks)
    check(res.ok and res.n == 2 and res.full == 1 and res.durMs == 6000, "背包只放得下兩塊：只算兩塊的時間，第三塊算放不下")
    T.advance(6000)
    crate:Remove(bricks[1])
    res = take(dave)
    check(res.ok and res.got == 1 and res.gone == 1 and holds(dave:getInventory(), bricks[2]),
        "等的時候別人拿走一塊：拿到還在的，另一塊算不在了")
    dave.inv.max = 4.5
    check(code(begin(dave, 103, 103, { bricks[3] })) == "NO_ROOM" and holds(crate, bricks[3]), "一件都放不下：NO_ROOM")
    crate:Remove(bricks[3])
    check(code(begin(dave, 103, 103, { bricks[3] })) == "GONE", "全部都不在了：GONE")

    T.section("遠距拿取：陣營分享可以給遠距拿取，遷移來的成員沒有")
    local fox = carrier(T.player({ name = "fox1", x = 102.5, y = 102.5 }), 50)
    T.faction("Foxes", "alice", { "fox1" })
    res = T.cmd(alice, "shareFaction", { claimId = rec.claimId, expectedRevision = rec.revision, bits = MEMBER + TAKE })
    check(res.ok and begin(fox, 103, 103, { nails[1] }).ok, "陣營分享勾遠距拿取：陣營成員可以遠距拿")
    rec.grants[#rec.grants + 1] = { user = "lee", bits = MSH.SHARE_LEGACY }
    local lee = carrier(T.player({ name = "lee", x = 102.5, y = 102.5 }), 50)
    check(code(begin(lee, 103, 103, { nails[1] })) == "PERM_DENIED", "遷移來的成員（原版成員的權限）沒有遠距拿取")

    T.section("遠距拿取：上了鎖的容器不拿（原版只在戰利品視窗擋，伺服器搬運不查鎖）")
    local safe = box("crate")
    furniture(square(105, 103, 0), safe)
    local gold = fill(safe, { item("Gold", 0.1) })
    local lock = lockWith(safe, 1234)
    check(code(begin(alice, 105, 103, gold)) == "GONE", "密碼鎖：裡面的算不在了（GONE）")
    lock.code, lock.key = 0, 55
    check(code(begin(alice, 105, 103, gold)) == "GONE", "掛鎖、身上沒有鑰匙：不拿")
    alice:getInventory().keys[55] = item("Key", 0.1)
    check(begin(alice, 105, 103, gold).ok, "掛鎖、身上有鑰匙：可以拿（原版打得開的就能拿）")

    -- ===== 客戶端掃描 =====
    T.section("物品搜尋：掃描容器、背包往裡一層、地上、車、人形模特兒；沒載入與沒開過另外數")
    resetWorld(0, 1)
    MSH = T.bootClient()
    local SS = MSH.StorageScan
    local counter, shelves, mannequin, trunk = box("counter"), box("shelves"), box("mannequin"), box("TruckBed")
    furniture(square(201, 201, 0), counter)
    fill(counter, { item("Nails", 0.01), item("Nails", 0.01), bag("Duffel", { item("Nails", 0.01), item("Rope", 0.5) }) })
    W.sq["202,201,1"] = nil
    furniture(square(202, 201, 1), shelves)
    fill(shelves, { item("Nails", 0.01) })
    onFloor(square(203, 202, 0), item("Apple", 0.2, "Food"))
    furniture(square(200, 200, 0), mannequin)
    fill(mannequin, { item("Jacket", 1, "Clothing") })
    furniture(square(200, 202, 0), box("crate", true))
    local car = { __class = "BaseVehicle", parts = {}, locked = false }
    function car:getId() return 7 end
    function car:getKeyId() return 77 end
    function car:isTrunkLocked() return self.locked end
    function car:isAnyDoorLocked() return false end
    function car:getPartCount() return #self.parts end
    function car:getPartByIndex(i) return self.parts[i + 1] end
    car.parts[1] = { getItemContainer = function() return trunk end, getId = function() return "TruckBed" end }
    car.parts[2] = { getItemContainer = function() return nil end, getId = function() return "Engine" end }
    fill(trunk, { item("Gas Can", 2) })
    square(203, 200, 0).car = car
    square(203, 201, 0).car = car
    W.unloaded["200,201"] = true
    local viewer = carrier(T.player({ name = "viewer", offline = true }), 20)
    local job = SS.start({ rect(200, 200, 4, 3) }, viewer)
    local steps = 1
    while not SS.step(job, 0) do steps = steps + 1 end
    local out = job.out
    check(steps == 5, "每 tick 預算用完就停：4 欄分 4 個 tick、第 5 個收尾（實際 " .. steps .. "）")
    check(out.items == 9 and out.containers == 5 and out.unloaded == 1 and out.unexplored == 1,
        "9 件、5 個容器（櫃台、二樓架子、模特兒、空木箱、車的一個零件；背包不算），1 格沒載入，1 個沒人開過（"
        .. out.items .. "/" .. out.containers .. "/" .. out.unloaded .. "/" .. out.unexplored .. "）")
    local byName = {}
    for _, g in ipairs(out.groups) do byName[g.name] = g end
    local ng = byName.Nails
    check(ng ~= nil and ng.n == 4 and #ng.places == 3, "同名併成一組：釘子 4 件、在 3 處（櫃台、櫃台裡的背包、二樓架子）")
    local kinds = {}
    for _, p in ipairs(ng.places) do kinds[#kinds + 1] = p.kind .. "@" .. p.z end
    check(table.concat(kinds, ",") == "box@0,bag@0,box@1", "處的種類與樓層（" .. table.concat(kinds, ",") .. "）")
    check(ng.places[2].title == "IGUI_MSH_Storage_InBag" and ng.places[2].c == counter and #ng.places[2].ids == 1,
        "背包裡的另算一處：標題寫在哪個背包裡、帶裝它的容器（戰利品視窗切過去）")
    check(byName.Jacket.places[1].walk and byName["Gas Can"].places[1].walk and byName["Gas Can"].places[1].kind == "car"
        and not ng.places[1].walk, "人形模特兒身上的、車上的只能指引")
    check(byName.Apple.places[1].kind == "floor" and byName.Apple.places[1].title == "IGUI_ContainerTitle_floor",
        "地上的一格算一處")
    local names = {}
    for i, g in ipairs(out.groups) do names[i] = g.name end
    check(table.concat(names, ",") == "Apple,Duffel,Gas Can,Jacket,Nails,Rope", "掃完依名稱排好（" .. table.concat(names, ",") .. "）")
    local vault = box("crate")
    furniture(square(201, 202, 0), vault)
    fill(vault, { item("Gold", 0.1) })
    lockWith(vault, 1234)
    car.locked = true
    local function scanAll()
        local j = SS.start({ rect(200, 200, 4, 3) }, viewer)
        while not SS.step(j, 0) do end
        return j.out
    end
    local lo = scanAll()
    check(lo.locked == 2 and lo.items == 8 and lo.containers == 6,
        "上了鎖的容器、後車廂鎖著的車：只算容器數與上鎖數，裡面的不列（" .. lo.locked .. "/" .. lo.items .. "/" .. lo.containers .. "）")
    viewer:getInventory().keys[77] = item("Key", 0.1)
    lo = scanAll()
    check(lo.locked == 1 and lo.items == 9, "身上有這台車的鑰匙：車上的照列")
    car.locked = false

    T.section("物品搜尋：關鍵字、分類、樓層、排序與距離")
    SS.measure(out, 203, 202)
    local sorted = SS.sorted(out, "name")
    local v = SS.views(sorted, SS.query("  NAIL "), nil, nil)
    check(#v == 1 and v[1].g == ng and v[1].n == 4 and v[1].dist == 1, "關鍵字不分大小寫、去頭尾空白；最近的那處 1 格")
    v = SS.views(sorted, "nail", nil, 1)
    check(#v == 1 and v[1].n == 1 and #v[1].places == 1 and v[1].places[1].z == 1, "只看 2 樓：件數與處都只算那一層")
    v = SS.views(sorted, "", "Food", nil)
    check(#v == 1 and v[1].g.name == "Apple", "分類只留那一類")
    check(#SS.views(sorted, "screw", nil, nil) == 0, "找不到：空的")
    local byCount = SS.sorted(out, "count")
    check(byCount[1].name == "Nails" and byCount[2].name == "Apple", "依數量：多的在前，同數量照名稱")
    local ga = { name = "A", lname = "a", cat = "x", n = 101, places = { { z = 0, n = 100, dist = 1 }, { z = 1, n = 1, dist = 9 } } }
    local gb = { name = "B", lname = "b", cat = "x", n = 10, places = { { z = 1, n = 10, dist = 2 } } }
    v = SS.views({ ga, gb }, "", nil, 1, "count")
    check(v[1].g == gb and v[2].g == ga, "只看一層、依數量：照那一層的件數排（二樓 10 件的在二樓 1 件的前面）")
    v = SS.views({ ga, gb }, "", nil, 1, "dist")
    check(v[1].g == gb, "只看一層、依距離：照那一層最近的那處排（不看別層的近處）")
    local cats = SS.cats(out)
    local catNames = {}
    for i, c in ipairs(cats) do catNames[i] = c.id .. "=" .. c.n end
    check(#cats == 4 and SS.floors(out)[1] == 0 and SS.floors(out)[2] == 1, "分類與樓層只列這次掃到的（" .. table.concat(catNames, ",") .. "）")
    local rows = SS.rows(SS.views(sorted, "", nil, nil), ng)
    local shape = {}
    for i, r in ipairs(rows) do shape[i] = r.kind == "group" and r.v.g.name or "-" end
    check(table.concat(shape, ",") == "Apple,Duffel,Gas Can,Jacket,Nails,-,-,-,Rope", "展開的那組底下接它的各處，近的在前")

    -- ===== 面板 =====
    T.section("物品搜尋面板：只在開著或帶路時掛 OnTick；不能拿的原因；到了切戰利品視窗；計時動作跑完才送完成")
    local fh, charW = 16, 7
    local function cls(base)
        local c = {}
        c.__index = c
        if base then setmetatable(c, { __index = base }) end
        function c:derive() return cls(self) end
        return c
    end
    local E = cls()
    function E:new(x, y, w, h)
        return setmetatable({ x = x or 0, y = y or 0, width = w or 60, height = h or 20, visible = true, kids = {} }, self)
    end
    for _, k in ipairs({ "initialise", "addToUIManager", "removeFromUIManager", "bringToTop", "setTooltip", "drawText",
        "drawTextureScaledAspect", "setOptions", "fitWidth", "scrollToIndex" }) do
        E[k] = function() end
    end
    function E:addChild(k) self.kids[#self.kids + 1] = k end
    function E:setVisible(on) self.visible = on end
    function E:getIsVisible() return self.visible end
    function E:setX(x) self.x = x end
    function E:setY(y) self.y = y end
    function E:getX() return self.x end
    function E:getY() return self.y end
    function E:setWidth(w) self.width = w end
    function E:setHeight(h) self.height = h end
    function E:resize(w, h) self.width, self.height = w, h end
    function E:setEnabled(on) self.enabled = on ~= false end
    function E:contentTop() return 24 end
    function E:close() self.visible = false if self.onClose then self.onClose(self) end end
    function E:setItems(items) self.items = items end
    function E:setSelected(id) self.selected = id end
    function E:setText(t) self.text = t end
    function E:setSelectedIndex(i) self.selectedIndex = i end
    function E:isSelected(i) return self.selectedIndex == i end
    function E:isMouseOver() return false end
    ISPanel, ISButton = cls(E), cls(E)
    UIFont = { Small = "Small", Medium = "Medium" }
    getTextManager = function()
        return { MeasureStringX = function(_, _, s) return #tostring(s) * charW end, getFontHeight = function() return fh end }
    end
    local core = { getScreenWidth = function() return 1280 end, getScreenHeight = function() return 720 end }
    getCore = function() return core end
    local function make(o)
        local e = E:new(o.x, o.y, o.width or 80, o.height or fh + 10)
        for k, x in pairs(o) do if e[k] == nil then e[k] = x end end
        return e
    end
    local caps = { toast = true }
    for _, c in ipairs(MSH.StoragePanel.CAPS) do caps[c] = true end
    local colors = {}
    for _, t in ipairs({ "text", "textMuted", "warning", "errorText", "hover", "selected", "card" }) do colors[t] = { r = 1, g = 1, b = 1 } end
    -- 畫了什麼：theme:fill／border 記成「fill:card」「border:accent」（卡片底是色票表，其他是 token 名）
    local paint = {}
    local function painter(kind)
        return function(_, _, _, _, _, _, color) paint[#paint + 1] = kind .. ":" .. (color == colors.card and "card" or tostring(color)) end
    end
    local dialogs, toasts = {}, {}
    MinidoracatUI = { v1 = { API_MAJOR = 1, API_REVISION = 20, CAPABILITIES = caps,
        Theme = { defaultPalette = function() return {} end,
            create = function() return { colors = colors, fill = painter("fill"), border = painter("border") } end },
        Skin = { shapeOf = function() return "control" end },
        Text = { fit = function(s) return s end, wrap = function(s) return { s } end },
        Icons = { draw = function() end }, Focus = { invalidate = function() end },
        Window = { new = make }, Button = { new = make }, TextField = { new = make }, VirtualList = { new = make },
        Dropdown = { new = make, close = function() end },
        Dialog = { show = function(o) dialogs[#dialogs + 1] = o end },
        Toast = { show = function(o) toasts[#toasts + 1] = o.message end } } }
    local markers = { arrows = {}, rings = {}, homing = {} }
    getWorldMarkers = function()
        return {
            addDirectionArrow = function(_, p, x, y, z)
                local a = { x = x, y = y, z = z }
                function a:setRenderWidth(w) self.w = w end
                function a:setRenderHeight(h) self.h = h end
                markers.arrows[a] = true
                return a
            end,
            removeDirectionArrow = function(_, a) markers.arrows[a] = nil end,
            addGridSquareMarker = function(_, sq)
                local r = { sq = sq }
                markers.rings[r] = true
                return r
            end,
            removeGridSquareMarker = function(_, r) markers.rings[r] = nil end,
            addPlayerHomingPoint = function(_, p, x, y, tex, r, g, b, a, home)
                local h = { x = x, y = y, home = home, active = true }
                function h:setActive(on) self.active = on end
                function h:setRenderWidth(w) self.w = w end
                function h:setRenderHeight(hh) self.h = hh end
                markers.homing[h] = true
                return h
            end,
            removeHomingPoint = function(_, h) markers.homing[h] = nil end,
        }
    end
    local function count(set)
        local n = 0
        for _ in pairs(set) do n = n + 1 end
        return n
    end
    local loot = { forced = nil, refreshed = 0 }
    function loot:setForceSelectedContainer(c, ms) self.forced, self.ms = c, ms end
    function loot:refreshBackpacks() self.refreshed = self.refreshed + 1 end
    getPlayerLoot = function() return loot end
    ISInventoryPage = { GetFloorContainer = function() return "floor" end }
    local queued, rejectAdd = {}, false
    ISTimedActionQueue = { add = function(a)
        if rejectAdd then return nil end
        queued[#queued + 1] = a
        return {}
    end }
    ISBaseTimedAction = { Type = "ISBaseTimedAction" }
    ISBaseTimedAction.__index = ISBaseTimedAction
    function ISBaseTimedAction:derive(name)
        local c = setmetatable({ Type = name }, { __index = self })
        c.__index = c
        return c
    end
    function ISBaseTimedAction.new(cls0, character)
        local o = setmetatable({}, cls0)
        cls0.__index = cls0
        o.character, o.stopOnWalk, o.maxTime = character, true, -1
        return o
    end
    function ISBaseTimedAction.stop() end
    function ISBaseTimedAction.perform() end
    -- 原版：forceCancel 什麼都不做（ISBaseTimedAction.lua:32-34）；adjustMaxTime 照心情、手傷等加長，這裡當成有一種加成（×2）
    function ISBaseTimedAction.forceCancel() end
    function ISBaseTimedAction:adjustMaxTime(maxTime) return maxTime * 2 end

    local P = MSH.StoragePanel
    local me = carrier(T.player({ name = "zoe", x = 201.5, y = 201.5 }), 20)
    local function hooked()
        local n = 0
        for _, f in ipairs(T.handlers.OnTick or {}) do if f == P.fnTick then n = n + 1 end end
        return n
    end
    local detail = { claimId = 9, title = "home", rects = { rect(200, 200, 4, 3) }, bits = MSH.SHARE_ALL, lifecycle = "active" }
    T.sandbox("StorageMode", 3)
    check(P.available() and hooked() == 0, "沒開面板：不掛 OnTick")
    local m = P.open({ detail = detail })
    check(m ~= nil and hooked() == 1 and m.job ~= nil, "開面板：掛 OnTick、開始掃描")
    for _ = 1, 10 do T.tick() end
    check(m.out ~= nil and m.out.items == 9 and #m.rows == 6, "幾個 tick 內掃完，清單一組一列")
    local nailsRow = nil
    for _, r in ipairs(m.rows) do if r.kind == "group" and r.v.g.name == "Nails" then nailsRow = r end end
    P.pick(m, nailsRow)
    check(m.open == nailsRow.v.g and m.sel == nil and #m.rows == 9, "點有好幾處的組：展開、還沒選處")
    local place = nil
    for _, r in ipairs(m.rows) do if r.kind == "place" and r.p.z == 1 then place = r end end
    P.pick(m, place)
    check(m.sel == place.p and P.takeBlock(m, m.sel) == nil, "選二樓架子那處：屋主站在範圍裡可以拿")
    m.bits = MEMBER
    check(P.takeBlock(m, m.sel) == "IGUI_MSH_Perm_Denied", "沒有遠距拿取權限：寫缺哪個權限")
    m.bits = MSH.SHARE_ALL
    me.x = 199.5
    T.advance(600)
    T.tick()
    check(m.inside == false and P.takeBlock(m, m.sel) == "IGUI_MSH_Storage_StandInside", "走出範圍：寫要站在安全屋裡")
    T.sandbox("StorageReach", 2)
    T.advance(600)
    T.tick()
    check(m.inside == true and P.takeBlock(m, m.sel) == nil, "管理員放寬 2 格：沒走動也重算，外面 1 格可以拿")
    local function hasLine(text)
        for _, l in ipairs(m.view.lines) do if l.text == text then return true end end
        return false
    end
    check(hasLine("IGUI_MSH_Storage_ModeRemoteNear") and not hasLine("IGUI_MSH_Storage_ModeRemote"),
        "放寬 2 格：面板最底下的管理員設定寫出格數（2026-10-21 實機截圖還寫只能站在安全屋裡）")
    me.x = 196.5
    T.advance(600)
    T.tick()
    check(m.inside == false and P.takeBlock(m, m.sel) == "IGUI_MSH_Storage_StandNear", "外面第 4 格：寫要站在安全屋裡或外面幾格內")
    T.sandbox("StorageReach", 0)
    me.x = 201.5
    T.advance(600)
    T.tick()
    check(hasLine("IGUI_MSH_Storage_ModeRemote") and not hasLine("IGUI_MSH_Storage_ModeRemoteNear"),
        "改回 0：管理員設定改回只寫站在安全屋裡")
    local carRow = nil
    for _, r in ipairs(m.rows) do if r.kind == "group" and r.v.g.name == "Gas Can" then carRow = r end end
    P.pick(m, carRow)
    check(m.sel ~= nil and m.sel.kind == "car" and P.takeBlock(m, m.sel) == "IGUI_MSH_Storage_WalkOnly",
        "只有一處的組：點了直接選那處；車上的只能指引")
    check(P.whereText({ z = 1, dist = 0 }, 0) == "IGUI_MSH_Indoor_Floor" and P.whereText({ z = 0, dist = 1 }, 0)
        == "IGUI_MSH_Indoor_Floor" .. "IGUI_MSH_Storage_Sep" .. "IGUI_MSH_Indoor_Here",
        "別層正上下方只寫樓層；同一層 1 格內才寫「就在你旁邊」")

    local carPlace = m.sel
    P.startGuide(m, m.sel)
    local homing = next(markers.homing)
    check(count(markers.arrows) == 1 and count(markers.rings) == 1 and count(markers.homing) == 1 and homing.active
        and homing.x == carPlace.x and homing.y == carPlace.y and homing.home == false,
        "帶路：方向箭頭＋人物旁指向目標的箭頭（不往目標飄）＋同一層的地面圈")
    P.close(m)
    check(P.model == nil and hooked() == 1 and P.guide ~= nil, "關面板：還在帶路就留著 OnTick")
    me.z = 1
    T.advance(300)
    T.tick()
    check(count(markers.rings) == 0 and count(markers.arrows) == 1 and homing.active,
        "走到別層：收掉地面圈（別層畫圈會浮在半空），人物旁的箭頭照樣指")
    me.x, me.y = carPlace.x + 0.5, carPlace.y + 0.5
    T.advance(300)
    T.tick()
    check(P.guide ~= nil and not homing.active, "別層的正上下方：人物旁的箭頭收起來（它不管樓層、沒有方向可指）")
    me.x, me.y = 200.5, 200.5
    T.advance(300)
    T.tick()
    check(homing.active, "離開正上下方：人物旁的箭頭再出現")
    me.x, me.y, me.z = 203.5, 201.5, 0
    T.advance(300)
    T.tick()
    check(P.guide == nil and count(markers.arrows) == 0 and count(markers.homing) == 0 and loot.forced == trunk and hooked() == 0,
        "到了（同一層 1 格內）：收掉標示、戰利品視窗切到那個容器、拿掉 OnTick")
    check(loot.refreshed == 1, "到了馬上重整戰利品視窗（原版只在轉向、換格子時才真的切過去）")
    me.x, me.y = 200.5, 200.5
    P.startGuide(m, carPlace)
    me.dead = true
    T.advance(300)
    T.tick()
    me.dead = false
    check(P.guide == nil and count(markers.arrows) == 0 and count(markers.homing) == 0 and hooked() == 0,
        "帶路途中死了：停止帶路（重生的新角色不會被指著）")
    P.startGuide(m, carPlace)
    T.sandbox("StorageMode", 1)
    MSH.Client.emit("sandbox")
    T.sandbox("StorageMode", 3)
    check(P.guide == nil and count(markers.arrows) == 0 and hooked() == 0,
        "管理員改成關閉：停止帶路（關閉後沒有地方按〔停止指引〕）")
    me.x, me.y = 201.5, 201.5

    local savedClaims = MSH.Client.claims
    m = P.open({ detail = detail })
    MSH.Client.claims = { mine = {}, shared = {}, byId = { [9] = { claimId = 9, lifecycle = "active", bits = MSH.SHARE_ALL } },
        at = T.now }
    T.advance(600)
    T.tick()
    check(P.model == m, "清單裡有這間：照常開著")
    MSH.Client.claims = { mine = {}, shared = {}, byId = {}, at = T.now }
    T.advance(600)
    T.tick()
    check(P.model == nil and hooked() == 0, "被移出名單（看過這間、清單重抓後沒了）：收起面板")
    MSH.Client.claims = savedClaims

    m = P.open({ detail = detail })
    for _ = 1, 10 do T.tick() end
    for _, r in ipairs(m.rows) do if r.kind == "group" and r.v.g.name == "Rope" then P.pick(m, r) end end
    check(m.sel ~= nil and m.sel.kind == "bag", "選背包裡的那處")
    P.askTake(m)
    local dlg = dialogs[#dialogs]
    check(dlg ~= nil and dlg.input.text == "1" and dlg.input.onlyNumbers, "〔拿取...〕：問要拿幾個，預設那處全部（上限 50）")
    T.clientSent = {}
    dlg.onResult(true, "3")
    check(#T.clientSent == 0 and m.msg == "IGUI_MSH_Storage_BadCount", "超過那處有的數量：不送、寫要輸入幾到幾")
    dlg.onResult(true, "1")
    local sent = T.clientSent[#T.clientSent]
    check(sent ~= nil and sent.command == "storageBegin" and sent.args.x == 201 and sent.args.z == 0 and #sent.args.ids == 1
        and P.taking ~= nil and P.takeBlock(m, m.sel) == "", "送 storageBegin（那格、那幾件 id）；等回覆時按鈕停用")
    T.fire("OnServerCommand", MSH.MODULE, "result", { command = "storageBegin", requestId = sent.args.requestId, ok = true,
        code = "OK", durMs = 510, n = 1, full = 0, gone = 0 })
    local act = queued[#queued]
    check(act ~= nil and act.maxTime == 26 and act.stopOnWalk, "開始：排一個只在客戶端的計時動作（510 ms＝26 單位），走動就中斷")
    check(rawget(getmetatable(act), "complete") == nil and act.complete == nil, "計時動作沒有 complete（只在客戶端跑）")
    T.clientSent = {}
    act:stop()
    check(P.taking == nil and #T.clientSent == 0 and m.msg ~= nil, "中斷：不送完成，面板寫拿取中斷")
    local function beginOne()
        P.askTake(m)
        dialogs[#dialogs].onResult(true, "1")
        return T.clientSent[#T.clientSent]
    end
    local function beginOk(s)
        T.fire("OnServerCommand", MSH.MODULE, "result", { command = "storageBegin", requestId = s.args.requestId, ok = true,
            code = "OK", durMs = 510, n = 1, full = 0, gone = 0 })
    end
    beginOk(beginOne())
    m.msg = nil
    queued[#queued]:forceCancel()
    check(P.taking == nil and m.msg ~= nil, "排在別的動作後面、還沒開始就被取消（forceCancel）：一樣收尾，之後還能再拿")
    rejectAdd = true
    local nq = #queued
    m.msg = nil
    beginOk(beginOne())
    rejectAdd = false
    check(#queued == nq and P.taking == nil and m.msg ~= nil, "原版不收這個動作（拖著屍體、睡著）：不會卡在拿取中")
    sent = beginOne()
    T.clientSent = {}
    T.advance(MSH.Client.TIMEOUT_MS + 500)
    MSH.Client.checkTimeouts(T.now)
    check(P.taking ~= nil and #T.clientSent == 1 and T.clientSent[1].args.requestId == sent.args.requestId,
        "10 秒沒回覆：還在等，同一 requestId 重送一次（回覆掉了的話伺服器回快取的結果）")
    beginOk(sent)
    check(queued[#queued]:adjustMaxTime(26) == 26, "計時動作不再乘心情、醉酒與手傷（時間就是伺服器算的，乘了會過期）")
    queued[#queued]:perform()
    sent = T.clientSent[#T.clientSent]
    check(sent ~= nil and sent.command == "storageTake" and sent.args.claimId == 9, "計時動作跑完：送 storageTake")
    T.fire("OnServerCommand", MSH.MODULE, "result", { command = "storageTake", requestId = sent.args.requestId, ok = true,
        code = "OK", got = 1, n = 1, full = 0, gone = 0 })
    check(P.taking == nil and m.msg == "IGUI_MSH_Storage_Got" and m.rescanAt ~= nil, "拿到了：寫結果、稍後重新掃描")
    core.getScreenHeight = function() return 300 end
    P.layout(m.view)
    check(m.view.rows == P.MIN_ROWS, "畫面放不下整個視窗：清單少幾列（最少 " .. P.MIN_ROWS .. " 列，實際 " .. tostring(m.view.rows) .. "）")
    core.getScreenHeight = function() return 720 end
    P.close(m)
    check(hooked() == 0, "關面板、沒在帶路：拿掉 OnTick")

    T.section("物品搜尋面板：清單／網格（框架有 TileGrid 才有）、點一格、網格下面的各處、記住上次選的")
    m = P.open({ detail = detail })
    for _ = 1, 10 do T.tick() end
    check(m.view.viewTabs == nil and m.view.grid == nil and not m.grid and m.view.list.visible,
        "框架沒有 TileGrid：沒有〔清單｜網格〕，只有清單")
    P.close(m)
    local ui = MinidoracatUI.v1
    caps.tileGrid, ui.TileGrid, ui.Tabs = true, { new = make }, { new = make }
    local savedPZ, saves = PZAPI, 0
    PZAPI = { ModOptions = { save = function() saves = saves + 1 end } }
    P.gridOpt = { v = false, getValue = function(s) return s.v end, setValue = function(s, x) s.v = x end }
    m = P.open({ detail = detail })
    for _ = 1, 10 do T.tick() end
    local pv = m.view
    check(pv.viewTabs.selected == "list" and not m.grid and pv.list.visible and not pv.grid.visible
        and pv.search.x + pv.search.width <= pv.viewTabs.x, "第一次是清單；〔清單｜網格〕在搜尋框右邊，不壓到搜尋框")
    local nails = nil
    for _, r in ipairs(m.rows) do if r.kind == "group" and r.v.g.name == "Nails" then nails = r end end
    P.pick(m, nails)
    pv.viewTabs.onSelect(pv.viewTabs.target, "grid", pv.viewTabs)
    check(m.grid and pv.grid.visible and not pv.list.visible and m.job == nil and m.open == nails.v.g
        and P.gridOpt.v == true and saves == 1, "切到網格：不重掃，展開的那組照樣選著；記進 ModOptions 並存檔")
    check(pv.grid.items == m.views and m.views[m.tileIndex].g.name == "Nails" and pv.placeList.visible
        and #pv.placeList.items == 3, "網格一組一格、選的是釘子那格；它放在 3 處，網格下面列出那 3 處")
    local second = pv.placeList.items[2]
    pv.placeList.onSelect(pv.placeList, second, 2)
    check(m.sel == second.p and m.placeIndex == 2 and m.grid, "在下面挑一處：選它（按鈕能按），還在網格")
    pv.grid.onPick(pv.grid.target, m.views[m.tileIndex], m.tileIndex, pv.grid)
    check(m.open == nails.v.g and m.sel == second.p, "再點同一格：不收起，挑好的那處留著")
    local rope = nil
    for i, view in ipairs(m.views) do if view.g.name == "Rope" then rope = i end end
    pv.grid.onPick(pv.grid.target, m.views[rope], rope, pv.grid)
    check(m.sel ~= nil and m.sel.kind == "bag" and m.tileIndex == rope and not pv.placeList.visible,
        "只有一處的那格：直接選那處，下面不列各處")
    local drawn = {}
    local function put(_, s) drawn[#drawn + 1] = s end
    local el = { drawText = put, drawTextCentre = put, drawTextureScaledAspect = function() end }
    local nailsView = nil
    for _, view in ipairs(m.views) do if view.g.name == "Nails" then nailsView = view end end
    pv.grid.drawTile(pv.grid.target, el, nailsView, 0, 0, pv.tileW, pv.tileH, { picked = false, hover = false, index = 5 })
    check(table.concat(drawn, ",") == "IGUI_MSH_Storage_Count,Nails,IGUI_MSH_Storage_Places,IGUI_MSH_Indoor_Here",
        "一格寫件數、名稱、幾處與最近那處多遠（" .. table.concat(drawn, ",") .. "）")
    local far = { places = { { z = 0, dist = 5 }, { z = 1, dist = 9 } }, dist = 5 }
    check(select(2, P.groupWhere(far, 0, false)) == "IGUI_MSH_Storage_Tiles"
        and select(2, P.groupWhere(far, 0, true)) == "IGUI_MSH_Storage_Nearest", "網格一格窄，距離只寫幾格；清單寫最近幾格")
    -- 走到 (203, 200)：釘子那三處（櫃台、櫃台裡的背包、二樓架子）離他 2、2、1 格。各處只在篩選時照距離排（走動不重排），
    -- 最近的那處現在排第三列
    me.x, me.y = 203.5, 200.5
    T.advance(600)
    T.tick()
    local nailsTile = nil
    for i, view in ipairs(m.views) do if view.g.name == "Nails" then nailsTile = i end end
    pv.grid.onPick(pv.grid.target, m.views[nailsTile], nailsTile, pv.grid)
    check(m.placeIndex == 3 and m.sel == m.placeRows[3].p and m.sel.dist == 1 and pv.placeList.selectedIndex == 3
        and pv.btnGuide.enabled, "點放在好幾處的那格：先選好最近的一處（照現在的距離，不是第一列），〔指引我過去〕馬上能按")
    local function lineY(text)
        for _, l in ipairs(m.view.lines) do if l.text == text then return l.y end end
    end
    local head, note = lineY("IGUI_MSH_Storage_PlacesPick"), lineY("IGUI_MSH_Storage_Unexplored")
    check(head ~= nil and note ~= nil and head > pv.grid.y + pv.grid.height and head < pv.placeList.y
        and pv.placeList.y + pv.placeList.height < note,
        "各處緊接在網格下面：先寫「點一處選它」再列各處，「還沒有人打開過」那行排在它們後面")
    local function painted(list, index)
        local cell = list.createCell(list)
        cell.width, cell.height = list.width, pv.rowH
        list.bindCell(list, cell, list.items[index], index)
        paint = {}
        cell:render()
        return table.concat(paint, ",")
    end
    local picked = painted(pv.placeList, 3)
    check(picked == "fill:card,fill:selected,border:accent" and painted(pv.placeList, 1) == "fill:card",
        "各處畫成卡片：選到的那處疊選取色、框金色，其他的只有卡片底（" .. picked .. "）")
    pv.viewTabs.onSelect(pv.viewTabs.target, "list", pv.viewTabs)
    check(not m.grid and pv.list.visible and not pv.grid.visible and not pv.placeList.visible and m.sel ~= nil
        and P.gridOpt.v == false, "切回清單：選的那處留著，記回清單")
    check(painted(pv.list, m.selIndex) == "fill:selected", "清單照舊：選到的那列只換底色，沒有卡片與金框")
    pv.viewTabs.onSelect(pv.viewTabs.target, "grid", pv.viewTabs)
    P.close(m)
    m = P.open({ detail = detail })
    check(m.grid and m.view.viewTabs.selected == "grid" and m.view.grid.visible and not m.view.list.visible,
        "重開面板：照上次選的，直接是網格")
    P.close(m)
    P.gridOpt, PZAPI, me.x, me.y = nil, savedPZ, 201.5, 201.5
    caps.tileGrid, ui.TileGrid, ui.Tabs = nil, nil, nil

    local MW = MSH.ManagerWindow
    check(MW.canSearch(detail), "管理視窗：模式不是關閉、這間 active、框架夠新 → 有〔搜尋物品〕")
    T.sandbox("StorageMode", 1)
    check(not MW.canSearch(detail), "沙盒選關閉：沒有〔搜尋物品〕")
    T.sandbox("StorageMode", 2)
    detail.lifecycle = "lapsed"
    check(not MW.canSearch(detail), "這間不是 active：沒有〔搜尋物品〕")
    caps.dropdown = nil
    detail.lifecycle = "active"
    check(not MW.canSearch(detail) and P.open({ detail = detail }) == nil, "框架沒有下拉選單：不給按鈕、也不開面板")

    for _, k in ipairs(NAMES) do _G[k] = saved[k] end
end
