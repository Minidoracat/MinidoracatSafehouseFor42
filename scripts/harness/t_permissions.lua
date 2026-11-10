-- 細分權限（Permissions.lua、PermissionsClient.lua；計畫 §6.6）：每類位元的拒絕／放行邊界、取水不轉水、
-- Actions.build 拒絕不呼叫原函式、農務指令、爐子面板翻回、denied 推送與 audit、客戶端藏選單判定。
return function(T)
    local check = T.check

    local function mk(MSH, rect, owner, source, grants)
        local R = MSH.Registry
        local rec = R.newRecord({ claimId = R.allocId(), rects = { rect }, title = "t", owner = owner, source = source,
            deedTier = 1, createdAt = T.now, grants = grants })
        local house = MSH.Native.build(rec, {})[1]
        rec.rects[1].created = house:getDatetimeCreated()
        R.put(rec)
        return rec
    end

    T.section("Permissions：伺服器包裝")
    local MSH = T.boot()
    local B = MSH.SHARE
    local MEMBER_ALL = B.MEMBER + B.USE + B.MOVE + B.BUILD + B.FARM
    local rec = mk(MSH, { x = 100, y = 100, w = 10, h = 10 }, "owner", MSH.SOURCE.DEED, {
        { user = "full", bits = MEMBER_ALL },
        { user = "bare", bits = B.MEMBER },
        { user = "farmer", bits = B.MEMBER + B.FARM },
        { user = "mover", bits = B.MEMBER + B.MOVE },
    })
    local legacy = mk(MSH, { x = 200, y = 100, w = 10, h = 10 }, "lord", MSH.SOURCE.LEGACY, {
        { user = "old", bits = MSH.SHARE_LEGACY },
    })
    T.house(300, 100, 10, 10, "carol")   -- foreign 原生屋：不在 registry
    local owner = T.player({ name = "owner" })
    local full = T.player({ name = "full" })
    local bare = T.player({ name = "bare" })
    local farmer = T.player({ name = "farmer" })
    local mover = T.player({ name = "mover" })
    local old = T.player({ name = "old" })
    local stranger = T.player({ name = "stranger" })
    local coop = T.player({ name = "owner2", num = 1 })   -- 分割畫面次玩家：principal 是 nil
    coop.name = "owner"

    -- 每個類別的目標欄位（照各類別 :new）
    local TARGET = {
        ISToggleLightAction = function(x, y) return { object = T.worldObject(x, y) } end,
        ISLightActions = function(x, y) return { mode = "RemoveLightBulb", lightswitch = T.worldObject(x, y) } end,
        ISToggleStoveAction = function(x, y) return { object = T.worldObject(x, y) } end,
        ISRadioAction = function(x, y) return { device = T.worldObject(x, y) } end,
        ISPlugGenerator = function(x, y) return { generator = T.worldObject(x, y) } end,
        ISActivateGenerator = function(x, y) return { generator = T.worldObject(x, y) } end,
        ISAddFuel = function(x, y) return { generator = T.worldObject(x, y) } end,
        ISFixGenerator = function(x, y) return { generator = T.worldObject(x, y) } end,
        ISTakeGenerator = function(x, y) return { generator = T.worldObject(x, y) } end,
        ISFluidTransferAction = function(x, y) return { sourceOwner = T.item("Base.WaterBottle"), targetOwner = T.worldObject(x, y) } end,
        ISMoveablesAction = function(x, y) return { square = T.gridSquare(x, y) } end,
        ISDestroyStuffAction = function(x, y) return { item = T.worldObject(x, y) } end,
        ISDismantleAction = function(x, y) return { thumpable = T.worldObject(x, y) } end,
        ISBarricadeAction = function(x, y) return { item = T.worldObject(x, y) } end,
        ISUnbarricadeAction = function(x, y) return { item = T.worldObject(x, y) } end,
        ISPlowAction = function(x, y) return { gridSquare = T.gridSquare(x, y) } end,
        ISSeedActionNew = function(x, y) return { plant = { x = x, y = y, z = 0 } } end,
        ISHarvestPlantAction = function(x, y) return { plant = { x = x, y = y, z = 0 } } end,
        ISCurePlantAction = function(x, y) return { plant = { x = x, y = y, z = 0 } } end,
        ISWaterPlantAction = function(x, y) return { sq = T.gridSquare(x, y) } end,
        ISShovelAction = function(x, y) return { plant = { x = x, y = y, z = 0 } } end,
        ISFertilizeAction = function(x, y) return { plant = { x = x, y = y, z = 0 } } end,
        ISScything = function(x, y)
            T.plants[x .. "," .. y] = { state = "seeded" }
            return { sq = T.gridSquare(x, y), radius = 1 }
        end,
    }
    local CATEGORY = {
        USE = { "ISToggleLightAction", "ISLightActions", "ISToggleStoveAction", "ISRadioAction", "ISPlugGenerator",
            "ISActivateGenerator", "ISAddFuel", "ISFixGenerator", "ISFluidTransferAction" },
        MOVE = { "ISMoveablesAction", "ISTakeGenerator" },
        BUILD = { "ISDestroyStuffAction", "ISDismantleAction", "ISBarricadeAction", "ISUnbarricadeAction" },
        FARM = { "ISPlowAction", "ISSeedActionNew", "ISHarvestPlantAction", "ISCurePlantAction", "ISWaterPlantAction",
            "ISShovelAction", "ISFertilizeAction", "ISScything" },
    }
    -- 回傳 complete 的回傳值、原函式有沒有跑
    local function run(cls, actor, x, y)
        local fields = TARGET[cls](x, y)
        fields.character = actor
        local before = T.ran[cls .. ".complete"] or 0
        local res = T.action(cls, fields):complete()
        return res, (T.ran[cls .. ".complete"] or 0) > before
    end
    local function deniedOf(p)
        T.outbox[p.name] = {}
        T.tick()
        return T.lastOf(p, "denied")
    end

    for cat, list in pairs(CATEGORY) do
        local bit = B[cat]
        local allRefused, allAllowed, ownerOk, outsideOk, foreignOk, legacyOk, strangerRefused = true, true, true, true, true, true, true
        for _, cls in ipairs(list) do
            local res, ranOrig = run(cls, bare, 105, 105)
            allRefused = allRefused and res == false and not ranOrig
            res, ranOrig = run(cls, full, 105, 105)
            allAllowed = allAllowed and res == true and ranOrig
            res, ranOrig = run(cls, owner, 105, 105)
            ownerOk = ownerOk and ranOrig
            res, ranOrig = run(cls, bare, 50, 50)
            outsideOk = outsideOk and ranOrig
            res, ranOrig = run(cls, bare, 305, 105)
            foreignOk = foreignOk and ranOrig
            res, ranOrig = run(cls, old, 205, 105)
            legacyOk = legacyOk and ranOrig
            res, ranOrig = run(cls, stranger, 205, 105)
            strangerRefused = strangerRefused and res == false and not ranOrig
        end
        check(allRefused, cat .. "：沒有該位元的成員被拒（complete false、原函式沒跑）")
        check(allAllowed, cat .. "：有該位元的成員照原版")
        check(ownerOk, cat .. "：屋主照原版")
        check(outsideOk, cat .. "：managed 範圍外照原版")
        check(foreignOk, cat .. "：foreign 原生屋照原版")
        check(legacyOk, cat .. "：legacy 成員（SHARE_LEGACY）照原版")
        check(strangerRefused, cat .. "：legacy 屋的名單外玩家被拒")
        run(list[1], bare, 105, 105)
        local d = deniedOf(bare)
        check(d ~= nil and d.code == "PERM_DENIED" and d.bit == bit and d.claimId == rec.claimId,
            cat .. "：拒絕後下個 tick 推 denied（code、bit、claimId）")
    end

    -- 熱路徑：安全屋外的每個包裝動作都要查 claim，不能每次配置清單並排序整份 registry
    local R, savedRan = MSH.Registry, T.deepcopy(T.ran)
    local realList, realSort = R.list, MSH.sortSafe
    local lists, sorts = 0, 0
    R.list = function(...) lists = lists + 1; return realList(...) end
    MSH.sortSafe = function(...) sorts = sorts + 1; return realSort(...) end
    for _, list in pairs(CATEGORY) do
        for _, cls in ipairs(list) do run(cls, bare, 50, 50) end
    end
    Actions.build(bare, { x = 50, y = 50, z = 0 })
    SFarmingSystemCommands.seed(bare, { x = 50, y = 50, z = 0 })
    T.action("ISTakeWaterAction", { character = bare, item = { water = 0 }, waterUnit = 1,
        waterObject = T.worldObject(50, 50) }):serverStart()
    R.list, MSH.sortSafe, T.ran = realList, realSort, savedRan
    check(lists == 0 and sorts == 0, "安全屋外的包裝動作：不呼叫 R.list、不排序")

    -- 位元互不相通：只有 FARM 的成員能耕種、不能用電器
    local r1, ran1 = run("ISPlowAction", farmer, 101, 101)
    local r2, ran2 = run("ISToggleLightAction", farmer, 101, 101)
    check(r1 == true and ran1 and r2 == false and not ran2, "只有 FARM：耕種放行、開燈被拒")
    -- 發電機：加油、修理看 USE（和接線、開關同一類），搬走看 MOVE（和搬家具同一類）
    local g1, gran1 = run("ISTakeGenerator", mover, 101, 101)
    local g2, gran2 = run("ISAddFuel", mover, 101, 101)
    local g3, gran3 = run("ISFixGenerator", mover, 101, 101)
    check(g1 == true and gran1 and g2 == false and not gran2 and g3 == false and not gran3,
        "只有 MOVE：搬走發電機放行、加油與修理被拒")
    local r3, ran3 = run("ISToggleLightAction", coop, 101, 101)
    check(r3 == false and not ran3, "分割畫面次玩家（沒有 principal）冒用屋主名字：被拒")
    -- 液體面板兩邊都是物品（自己手上的瓶子）：不是世界目標，照原版
    local fl = T.action("ISFluidTransferAction", { character = bare, sourceOwner = T.item("Base.WaterBottle"),
        targetOwner = T.item("Base.WaterBottle") })
    local before = T.ran["ISFluidTransferAction.complete"] or 0
    check(fl:complete() == true and T.ran["ISFluidTransferAction.complete"] == before + 1, "液體面板兩邊都是物品：照原版")

    -- LAPSED 的屋（原生已移除）不擋
    rec.lifecycle = MSH.LIFECYCLE.LAPSED
    local r4, ran4 = run("ISToggleLightAction", bare, 105, 105)
    check(r4 == true and ran4, "lapsed 的屋照原版")
    rec.lifecycle = MSH.LIFECYCLE.ACTIVE

    T.section("Permissions：取水")
    local function water(actor, x, y)
        local item = { water = 0 }
        local a = T.action("ISTakeWaterAction", { character = actor, item = item, waterUnit = 1, waterObject = T.worldObject(x, y) })
        a:serverStart()
        a:updateUse(0.7)   -- animEvent 分段（ISTakeWaterAction.lua:155-161）
        return a:complete(), item.water
    end
    local res, got = water(bare, 105, 105)
    check(res == false and got == 0 and T.ran["ISTakeWaterAction.serverStart"] == nil, "沒有 USE：一滴都沒轉、serverStart 原函式沒跑、complete false")
    check((deniedOf(bare) or {}).bit == B.USE, "取水被拒：推 denied")
    res, got = water(full, 105, 105)
    check(res == true and got == 1, "有 USE：照原版裝滿")
    res, got = water(bare, 50, 50)
    check(res == true and got == 1, "範圍外：照原版")

    T.section("Permissions：Actions.build 與農務指令")
    Actions.build(bare, { x = 105, y = 105, z = 0 })
    check(T.ran["Actions.build"] == nil, "沒有 BUILD：不呼叫原 Actions.build")
    check((deniedOf(bare) or {}).bit == B.BUILD, "建造被拒：推 denied（客戶端照樣顯示完成，要靠這則說明）")
    Actions.build(full, { x = 105, y = 105, z = 0 })
    Actions.build(bare, { x = 50, y = 50, z = 0 })
    check(T.ran["Actions.build"] == 2, "有 BUILD、範圍外：照原版")
    Actions.build(bare, { x = "105", y = 105, z = 0 })
    Actions.build(full, { x = 105, y = 105, z = 0 / 0 })
    check(T.ran["Actions.build"] == 2, "座標不是有限數：不蓋")
    -- 格子不存在的樓層：照座標判斷
    T.unloaded["105,105"] = true
    Actions.build(bare, { x = 105, y = 105, z = 3 })
    check(T.ran["Actions.build"] == 2, "格子不存在的樓層：沒有 BUILD 照樣被拒")
    Actions.build(full, { x = 105, y = 105, z = 3 })
    check(T.ran["Actions.build"] == 3, "格子不存在的樓層：有 BUILD 照原版")
    T.unloaded["105,105"] = nil

    -- 多格物件：每一格都查（claim 範圍 100..109）。item 照原版類別會用到的欄位與方法
    local function built(actor, item, x, y, north)
        local before = T.ran["Actions.build"] or 0
        Actions.build(actor, { x = x, y = y, z = 0, north = north, item = item })
        return (T.ran["Actions.build"] or 0) > before
    end
    local function tile(sprite, blocking)
        return { getSpriteName = function() return sprite end, isBlocking = function() return blocking end }
    end
    local function entity(tiles, w, h, layers)   -- tiles[zz][yy][xx]；ISBuildIsoEntity 的 face
        local face = { getzLayers = function() return layers end, getWidth = function() return w end,
            getHeight = function() return h end,
            getTileInfo = function(_, xx, yy, zz) local t = tiles[zz + 1][yy + 1]; return t and t[xx + 1] end }
        return { getFace = function() return face end }
    end
    local wide = entity({ { { tile("a"), tile("b") } } }, 2, 1, 1)
    check(not built(bare, wide, 99, 105) and (deniedOf(bare) or {}).bit == B.BUILD, "entity 兩格、第二格在 claim：被拒")
    check(built(full, wide, 99, 105), "entity 兩格、有 BUILD：照原版")
    check(built(bare, entity({ { { tile("a"), tile(nil, false) } } }, 2, 1, 1), 99, 105),
        "entity 第二格沒有圖塊也不擋路：不算佔用（同原版 isValid）")
    check(not built(bare, entity({ { { tile("a"), tile(nil, true) } } }, 2, 1, 1), 99, 105), "entity 第二格只擋路：照樣算佔用")
    check(not built(bare, entity({ { { tile("a") } }, { { tile("b"), tile("c") } } }, 2, 1, 2), 99, 105),
        "entity 上一層多出的格子：照樣算")
    local stairs = {   -- ISWoodenStairs.lua:227-262：西向往 x 減、北向往 y 減，頂端那格在上一層
        getSquare2Pos = function(_, s, n) if n then return s:getX(), s:getY() - 1, s:getZ() end return s:getX() - 1, s:getY(), s:getZ() end,
        getSquare3Pos = function(_, s, n) if n then return s:getX(), s:getY() - 2, s:getZ() end return s:getX() - 2, s:getY(), s:getZ() end,
        getSquareTopPos = function(_, s, n) if n then return s:getX(), s:getY() - 3, s:getZ() + 1 end return s:getX() - 3, s:getY(), s:getZ() + 1 end,
    }
    check(not built(bare, stairs, 112, 105, false), "樓梯西向：頂端那格（x−3）在 claim，被拒")
    check(built(bare, stairs, 112, 105, true), "樓梯北向：四格都在範圍外，照原版（north 決定方向）")
    local door = { getSquare4Pos = function(_, s, n) if n then return s:getX() + 3, s:getY(), s:getZ() end return s:getX(), s:getY() - 3, s:getZ() end }
    check(not built(bare, door, 97, 105, true), "雙開門第 4 格在 claim：被拒")
    check(not built(bare, { def = { name = "hutch", extraSprites = { { sprite = "s", xoffset = 1, yoffset = 0 } } } }, 99, 105),
        "兔籠 extraSprites 的格子在 claim：被拒")
    local ramp = { which = "west20", addRampObject = function() end }   -- ISBuildRampCursor.lua:21-27
    check(not built(bare, ramp, 115, 105) and built(bare, { which = "west20" }, 115, 105),
        "坡道游標 20 格壓到 claim：被拒；沒有坡道方法的同名欄位不算")
    check(built(bare, { getSquare2Pos = function() error("boom") end }, 99, 105), "取範圍的方法丟錯：只剩錨點，錨點在範圍外照原版")
    -- 其他 MOD 的建造物件（Knox Buildworks，KBWBuildingObject.lua:685-696）：getFace 只回 getFaceName，佔用格在 getFootprint。
    -- 丟錯回 nil：0.12.0 在 face 迴圈丟錯，原函式沒跑、也沒有 denied（玩家回報屋主自己也蓋不了）
    local function knox(cells)
        return { getFace = function() return { getFaceName = function() return "s" end } end,
            getFootprint = function() return cells end }
    end
    local function knoxBuilt(actor, item, x, y, north)
        local ok, res = pcall(built, actor, item, x, y, north)
        if ok then return res end
        return nil
    end
    local kA = { dx = 0, dy = 0, dz = 0, sprite = "a", blocks = true }
    local knoxWide = knox({ kA, { dx = 1, dy = 0, dz = 0, sprite = "b", blocks = true } })
    -- pcall 接住的錯照樣在伺服器 log 印堆疊（KahluaThread.flushErrorMessage）：數這兩次建造途中接住了幾個錯
    local realPcall, caught = pcall, 0
    pcall = function(...)
        local r = table.pack(realPcall(...))
        if not r[1] then caught = caught + 1 end
        return table.unpack(r, 1, r.n)
    end
    local ownerIn, bareEdge = knoxBuilt(owner, knox({ kA }), 105, 105), knoxBuilt(bare, knoxWide, 99, 105)
    pcall = realPcall
    check(ownerIn == true, "getFace 不是 FaceScript（Knox）：屋主在自己的 claim 照原版")
    check(bareEdge == false and (deniedOf(bare) or {}).bit == B.BUILD, "Knox 兩格、第二格在 claim：被拒")
    check(caught == 0, "Knox 的物件不靠丟錯略過（接住的錯照樣印進伺服器 log）")
    check(knoxBuilt(full, knoxWide, 99, 105) == true, "Knox 兩格、有 BUILD：照原版")
    check(knoxBuilt(bare, knox({ kA, { dx = 1, dy = 0, dz = 0, empty = true, blocks = false } }), 99, 105) == true,
        "Knox 第二格沒有圖塊也不擋路：不算佔用（create 只補建有 sprite 或 blocks 的格）")
    -- 牆類（雙開門、雙開大門）：footprint 照 nSprite 選面，西向（1）沿 y 四格、北向（2）沿 x 四格。create 先照封包的
    -- north 改 nSprite（KBWBuildingObject.lua:1313-1316），改過的客戶端可以送西向的 direction 配 north＝true
    local gate = { isWallLike = true, nSprite = 1, getFootprint = function(self)
        local cells = {}
        for i = 0, 3 do
            cells[#cells + 1] = self.nSprite == 2 and { dx = i, dy = 0, sprite = "g" } or { dx = 0, dy = i, sprite = "g" }
        end
        return cells
    end }
    check(knoxBuilt(bare, gate, 99, 105, true) == false and (deniedOf(bare) or {}).bit == B.BUILD,
        "Knox 牆類照 north 選面：direction 西向、north＝true 時照北向四格查，壓到 claim 被拒")
    check(knoxBuilt(bare, gate, 99, 105, false) == true, "Knox 牆類西向四格都在範圍外：照原版")
    check(knoxBuilt(bare, gate, 105, 98, false) == false, "Knox 牆類西向沿 y 四格，後兩格壓到 claim：被拒")
    check(knoxBuilt(bare, { getFootprint = function() error("boom") end }, 99, 105) == true,
        "getFootprint 丟錯：只剩錨點，錨點在範圍外照原版")
    -- 一格在自己有 BUILD 的 claim、一格在別人的 claim
    local neighbor = mk(MSH, { x = 110, y = 100, w = 10, h = 10 }, "neighbor", MSH.SOURCE.DEED, {})
    check(not built(full, wide, 109, 105) and (deniedOf(full) or {}).claimId == neighbor.claimId,
        "兩格分屬兩間：沒有 BUILD 的那間擋下（denied 帶那間的 claimId）")
    -- 建造選單的路障（entity_barricade_*）：釘的是面向那一側的門窗，面向那一側的鄰格也查
    local function barricade(face, onCreate)
        local script = { getOnCreate = function() return onCreate or "BuildRecipeCode.barricade.OnCreate" end }
        return { objectInfo = { getScript = function() return script end },
            getFace = function() return { getFaceName = function() return face end } end }
    end
    check(not built(bare, barricade("s"), 105, 99) and (deniedOf(bare) or {}).claimId == rec.claimId,
        "路障建造朝 s：錨點在範圍外、(x, y+1) 在 claim：被拒")
    check(not built(bare, barricade("n"), 105, 110) and not built(bare, barricade("e"), 99, 105)
        and not built(bare, barricade("w"), 120, 105), "路障建造朝 n／e／w：面向那一側的鄰格在 claim：被拒")
    check(built(bare, barricade("s"), 105, 97) and built(bare, barricade("n"), 105, 99) and built(full, barricade("s"), 105, 99),
        "路障建造：面向的鄰格在範圍外、或有 BUILD：照原版")
    check(built(bare, barricade("s", "BuildRecipeCode.other.OnCreate"), 105, 99), "不是路障的 entity：不加鄰格")

    T.section("Permissions：邊上的物件（大鎚、拆解、釘路障、拆路障）")
    -- rec 是 x 100..109、y 100..109，neighbor 是 x 110..119、y 100..109
    local EDGE_FIELD = { ISDestroyStuffAction = "item", ISDismantleAction = "thumpable", ISBarricadeAction = "item",
        ISUnbarricadeAction = "item" }
    local function edgeRun(cls, actor, obj)
        local before = T.ran[cls .. ".complete"] or 0
        local res = T.action(cls, { character = actor, [EDGE_FIELD[cls]] = obj }):complete()
        return res, (T.ran[cls .. ".complete"] or 0) > before
    end
    local function crate(x, y)   -- 木箱也是 IsoThumpable，但不是門、圖塊也沒有邊的屬性
        local o = T.worldObject(x, y)
        o.__class, o.__is = "IsoThumpable", { IsoObject = true }
        o.isDoor = function() return false end
        o.getNorth = function() return false end
        return o
    end
    local function thumpDoor(x, y, north)
        local o = crate(x, y)
        o.isDoor = function() return true end
        o.getNorth = function() return north end
        return o
    end
    local EDGE_DENIED = {   -- 所在格在範圍外、另一側在 claim
        { "朝北的門", function() return T.edgeObject("IsoDoor", 105, 110, true) end },
        { "朝北的窗", function() return T.edgeObject("IsoWindow", 105, 110, true) end },
        { "朝北的窗框", function() return T.edgeObject("IsoWindowFrame", 105, 110, true) end },
        { "朝西的門", function() return T.edgeObject("IsoDoor", 120, 105, false) end },
        { "玩家蓋的門（IsoThumpable isDoor）", function() return thumpDoor(105, 110, true) end },
        { "北牆 cutN", function() return T.worldObject(105, 110, 0, { "cutN" }) end },
        { "西牆 cutW", function() return T.worldObject(120, 105, 0, { "cutW" }) end },
        { "柵欄 collideN", function() return T.worldObject(105, 110, 0, { "collideN" }) end },
        { "柵欄 collideW", function() return T.worldObject(120, 105, 0, { "collideW" }) end },
        { "窗框牆 WindowN", function() return T.worldObject(105, 110, 0, { "WindowN" }) end },
        { "窗框牆 WindowW", function() return T.worldObject(120, 105, 0, { "WindowW" }) end },
        { "轉角牆（北邊那格在 claim）", function() return T.worldObject(115, 110, 0, { "cutN", "cutW" }) end },
        { "轉角牆（西邊那格在 claim）", function() return T.worldObject(120, 105, 0, { "cutN", "cutW" }) end },
    }
    local EDGE_PLAIN = {    -- 照原版：另一側不在 claim，或不是邊上的物件
        { "兩側都在範圍外的門", function() return T.edgeObject("IsoDoor", 105, 99, true) end },
        { "朝西的門、北邊那格才在 claim", function() return T.edgeObject("IsoDoor", 105, 110, false) end },
        { "朝北的門、西邊那格才在 claim", function() return T.edgeObject("IsoDoor", 120, 105, true) end },
        { "西牆、北邊那格才在 claim", function() return T.worldObject(105, 110, 0, { "cutW" }) end },
        { "沒有邊的屬性的物件", function() return T.worldObject(105, 110) end },
        { "木箱（IsoThumpable、不是門）", function() return crate(120, 105) end },
    }
    for cls in pairs(EDGE_FIELD) do
        local bad, good = {}, {}
        for _, c in ipairs(EDGE_DENIED) do
            local res, ranOrig = edgeRun(cls, bare, c[2]())
            if res ~= false or ranOrig then bad[#bad + 1] = c[1] end
            res, ranOrig = edgeRun(cls, stranger, c[2]())
            if res ~= false or ranOrig then bad[#bad + 1] = c[1] .. "（名單外）" end
        end
        for _, c in ipairs(EDGE_PLAIN) do
            local _, ranOrig = edgeRun(cls, bare, c[2]())
            if not ranOrig then good[#good + 1] = c[1] end
        end
        check(#bad == 0, cls .. "：所在格在範圍外、另一側在 claim、沒有 BUILD：被拒" .. (#bad > 0 and "（沒擋：" .. table.concat(bad, "、") .. "）" or ""))
        check(#good == 0, cls .. "：另一側不在 claim、或不是邊上的物件：照原版" .. (#good > 0 and "（誤擋：" .. table.concat(good, "、") .. "）" or ""))
        local _, ranFull = edgeRun(cls, full, T.edgeObject("IsoDoor", 105, 110, true))
        local _, ranOwner = edgeRun(cls, owner, T.edgeObject("IsoDoor", 105, 110, true))
        check(ranFull and ranOwner, cls .. "：有 BUILD 的成員與屋主照原版")
    end
    edgeRun("ISDestroyStuffAction", bare, T.edgeObject("IsoDoor", 105, 110, true))
    local ed = deniedOf(bare)
    check(ed ~= nil and ed.bit == B.BUILD and ed.claimId == rec.claimId, "邊上的物件被拒：推 denied（BUILD、另一側那間的 claimId）")
    local _, ranNb = edgeRun("ISDestroyStuffAction", full, T.edgeObject("IsoDoor", 110, 105, false))
    check(not ranNb and (deniedOf(full) or {}).claimId == neighbor.claimId, "門兩側分屬兩間：沒有 BUILD 的那間擋下")
    -- 路障物件：加它釘的那個門窗的格子（門在範圍外那格、朝北，另一側在 claim）
    local function barricadeOn(target, x, y)
        local o = T.worldObject(x, y)
        o.__class, o.__is = "IsoBarricade", { IsoObject = true }
        o.getBarricadedObject = function() return target end
        return o
    end
    local _, ranB1 = edgeRun("ISDestroyStuffAction", bare, barricadeOn(T.edgeObject("IsoDoor", 105, 110, true), 105, 110))
    local _, ranB2 = edgeRun("ISDestroyStuffAction", bare, barricadeOn(T.edgeObject("IsoDoor", 105, 99, true), 105, 99))
    local _, ranB3 = edgeRun("ISDestroyStuffAction", bare, barricadeOn(nil, 105, 110))
    check(not ranB1 and ranB2 and ranB3, "大鎚拆路障物件：它釘的門窗另一側在 claim 就被拒；門窗兩側都在範圍外、找不到門窗照原版")
    -- 原版會一起拆的物件（樓梯、雙開門、車庫門、墓穴）：每個物件的格子都查
    local inClaim = T.worldObject(105, 105)
    local groupBad = {}
    for _, fn in ipairs({ "getStairObjects", "getDoubleDoorObjects", "getGarageDoorObjects", "getGraveObjects" }) do
        T.group = { [fn] = function() return { inClaim } end }
        local _, ranG = edgeRun("ISDestroyStuffAction", bare, T.worldObject(50, 50))
        if ranG then groupBad[#groupBad + 1] = fn end
    end
    check(#groupBad == 0, "大鎚：一起拆的物件有一個在 claim：被拒" .. (#groupBad > 0 and "（沒擋：" .. table.concat(groupBad, "、") .. "）" or ""))
    T.group = { getStairObjects = function() return { inClaim } end }
    local _, ranD1 = edgeRun("ISDismantleAction", bare, T.worldObject(50, 50))
    T.group = { getGraveObjects = function() return { inClaim } end }
    local _, ranD2 = edgeRun("ISDismantleAction", bare, T.worldObject(50, 50))
    local _, ranD3 = edgeRun("ISBarricadeAction", bare, T.worldObject(50, 50))
    T.group = { getStairObjects = function() return { T.edgeObject("IsoDoor", 105, 110, true) } end }
    local _, ranD4 = edgeRun("ISDestroyStuffAction", bare, T.worldObject(50, 50))
    T.group = {}
    check(not ranD1 and ranD2 and ranD3, "拆解：只有樓梯會一起拆（同原版）；路障動作不看一起拆的物件")
    check(not ranD4, "一起拆的物件在邊上：它的另一側也查")
    local _, ranNil = edgeRun("ISDestroyStuffAction", bare, nil)
    local _, ranItem = edgeRun("ISBarricadeAction", bare, T.item("Base.Plank"))
    check(ranNil and ranItem, "沒有目標、目標不是世界物件：照原版")
    local _, ranNoActor = edgeRun("ISDestroyStuffAction", nil, T.edgeObject("IsoDoor", 105, 110, true))
    check(ranNoActor, "沒有 character：照原版")
    SFarmingSystemCommands.seed(bare, { x = 105, y = 105, z = 0 })
    check(T.ran["farm.seed"] == nil, "沒有 FARM：農務指令不執行")
    SFarmingSystemCommands.seed(farmer, { x = 105, y = 105, z = 0 })
    SFarmingSystemCommands.destroy(nil, { x = 105, y = 105, z = 0 })   -- SFarmingSystem.destroyPlant 自己呼叫
    check(T.ran["farm.seed"] == 1 and T.ran["farm.destroy"] == 1, "有 FARM、伺服器自己呼叫（player nil）：照原版")
    -- 作物用原版的呼叫找（getLuaObjectAt），照找到的那株的座標判定：那格沒載入、z 那層沒有格子、座標帶小數或不是 Lua 數字都一樣
    T.unloaded["105,105"] = true
    local function plantAct(cls, actor, x, y, z)
        local before = T.ran[cls .. ".complete"] or 0
        local res = T.action(cls, { character = actor, plant = { x = x, y = y, z = z } }):complete()
        return res, (T.ran[cls .. ".complete"] or 0) > before
    end
    local p1, pran1 = plantAct("ISHarvestPlantAction", bare, 105, 105, 0)
    local p2, pran2 = plantAct("ISShovelAction", bare, 105.9, 105.2, -0.5)
    local p3, pran3 = plantAct("ISHarvestPlantAction", farmer, 105.9, 105.2, -0.5)
    local _, pran4 = plantAct("ISHarvestPlantAction", bare, 99.9, 105, 0)       -- 截斷後是 99：範圍外
    SFarmingSystemCommands.water(bare, { x = 105, y = 105, z = -0.5 })
    local p5, pran5 = plantAct("ISFertilizeAction", bare, T.boxed(105), T.boxed(105), T.boxed(0))
    local beforeErr = T.ran["ISHarvestPlantAction.complete"]
    local okErr = pcall(plantAct, "ISHarvestPlantAction", bare, "105", 105, 0)
    T.unloaded["105,105"] = nil
    check(p1 == false and not pran1 and p2 == false and not pran2 and T.ran["farm.water"] == nil,
        "作物動作與農務指令：那格沒載入、座標帶小數 → 照找到的作物查，沒有 FARM 被拒")
    check(p3 == true and pran3 and pran4, "作物動作：有 FARM、或找到的作物在範圍外 → 照原版")
    check(p5 == false and not pran5, "作物動作：座標不是 Lua 數字但原版找得到作物 → 照樣查")
    check(okErr == false and T.ran["ISHarvestPlantAction.complete"] == beforeErr, "作物動作：找作物的呼叫丟錯 → 原函式不跑")
    T.noPlant = true
    SFarmingSystemCommands.plow(bare, { x = 105, y = 105, z = 0 })
    T.noPlant = false
    check(T.ran["farm.plow"] == nil, "翻土指令：那格沒有作物 → 照格子查，沒有 FARM 被拒")
    -- 找到的那株：查表的位置（globalObject）與 Lua 欄位的 x, y 都查
    local moved = SFarmingSystem.instance:getLuaObjectAt(106, 106, 0)
    moved.x, moved.y = 50, 50                                  -- 查表的位置在 claim 裡，Lua 欄位在範圍外
    local away = SFarmingSystem.instance:getLuaObjectAt(60, 60, 0)
    away.x, away.y = 107, 107                                  -- 查表的位置在範圍外，Lua 欄位在 claim 裡
    local p7, pran7 = plantAct("ISHarvestPlantAction", bare, 106, 106, 0)
    local p8, pran8 = plantAct("ISHarvestPlantAction", bare, 60, 60, 0)
    SFarmingSystemCommands.harvest(bare, { x = 60, y = 60, z = 0 })
    local _, pran9 = plantAct("ISHarvestPlantAction", farmer, 106, 106, 0)
    check(p7 == false and not pran7 and p8 == false and not pran8 and T.ran["farm.harvest"] == nil,
        "作物：查表的位置或 Lua 欄位的位置任一個在安全屋裡、沒有 FARM → 被拒")
    check(pran9, "作物：兩個位置都查過、有 FARM → 照原版")
    -- 指令的第一個目標單獨驗：查表的位置在 claim 裡、Lua 欄位在範圍外、那格沒載入（格子那一道不會擋）
    T.unloaded["106,106"] = true
    SFarmingSystemCommands.destroy(bare, { x = 106, y = 106, z = 0 })
    T.unloaded["106,106"] = nil
    check(T.ran["farm.destroy"] == 1, "農務指令：作物查表的位置在安全屋裡、那格沒載入、沒有 FARM → 被拒")
    -- cheat 不能改作物的 x, y（不分安全屋內外、有沒有 FARM）；其他欄位照一般農務指令判定
    SFarmingSystemCommands.cheat(bare, { x = 50, y = 50, z = 0, var = "x", count = 1 })
    SFarmingSystemCommands.cheat(farmer, { x = 105, y = 105, z = 0, var = "y", count = 1 })
    check(T.ran["farm.cheat"] == nil, "cheat：var 是 x 或 y → 不執行")
    SFarmingSystemCommands.cheat(bare, { x = 50, y = 50, z = 0, var = "waterLvl", count = 10 })
    SFarmingSystemCommands.cheat(bare, { x = 105, y = 105, z = 0, var = "waterLvl", count = 10 })
    check(T.ran["farm.cheat"] == 1, "cheat：其他欄位 → 範圍外照原版、安全屋裡沒有 FARM 被拒")
    -- 割草：範圍從 sq 往 +x、+y 共 radius 格，有原版會動到的作物（不是 destroyed／harvested／plow）的格子才查（ISScything.lua:42-49, 81）
    local function scythe(actor, x, y, r)
        local before = T.ran["ISScything.complete"] or 0
        local res = T.action("ISScything", { character = actor, sq = T.gridSquare(x, y), radius = r }):complete()
        return res, (T.ran["ISScything.complete"] or 0) > before
    end
    deniedOf(bare)                                           -- 先送掉前面農務指令留下的那則，下面只看割草推的
    T.plants = { ["100,100"] = { state = "seeded" } }        -- 98..100：只有角落那格在 claim
    local s1, sran1 = scythe(bare, 98, 98, 3)
    T.plants["100,100"].state = "harvested"
    local _, sran2 = scythe(bare, 98, 98, 3)
    T.plants = { ["99,99"] = { state = "seeded" } }          -- 範圍跨進 claim，作物在 claim 外
    local _, sran3 = scythe(bare, 98, 98, 3)
    T.plants = { ["101,101"] = { state = "seeded" } }
    local s4, sran4 = scythe(farmer, 100, 100, 3)
    check(s1 == false and not sran1 and (deniedOf(bare) or {}).bit == B.FARM,
        "割草：範圍角落一格有 claim 裡的作物、沒有 FARM → 整個不做、推 denied（FARM）")
    check(sran2 and sran3, "割草：claim 裡的作物已收成、或只有 claim 外的作物 → 照原版（割草本身不看權限）")
    check(s4 == true and sran4, "割草：有 FARM → 照原版")
    T.plants = { ["100,100"] = { state = "seeded" } }
    local s5, sran5 = scythe(bare, 98, 98, "3")
    local s6, sran6 = scythe(farmer, 98, 98, "3")
    local s7, sran7 = scythe(farmer, 98, 98, false)
    check(s5 == false and not sran5 and s6 == true and sran6, "割草：radius 是數字字串 → 照那個數字查範圍（同原版的算術）")
    check(s7 == false and not sran7, "割草：radius 不是數字 → 不做")

    T.section("Permissions：撬棍（42.22 ISForceOpen）")
    -- 門窗：在所在格的北邊（getNorth）或西邊，另一側是 (x, y-1) 或 (x-1, y)。rec 是 100..109，neighbor 是 x 110..119
    local function portal(x, y, north) return T.edgeObject("IsoDoor", x, y, north) end
    -- 回 attempt 的結果、原 attempt 有沒有跑（扣門血、打破窗戶在原 attempt 裡；原 attempt 回 success 才開鎖）
    local function force(actor, obj)
        local before = T.ran["ISForceOpen.attempt"] or 0
        local out = T.action("ISForceOpen", { character = actor, object = obj }):attempt()
        return out, (T.ran["ISForceOpen.attempt"] or 0) > before
    end
    local fo, fran = force(bare, portal(105, 105, false))
    check(fo == "fail" and not fran and (deniedOf(bare) or {}).bit == B.BUILD,
        "撬棍：沒有 BUILD 的成員被拒（回 fail、原 attempt 沒跑＝不開鎖不扣血、推 denied BUILD）")
    fo, fran = force(stranger, portal(105, 105, false))
    check(fo == "fail" and not fran, "撬棍：名單外的人被拒")
    fo, fran = force(bare, portal(105, 110, true))
    check(fo == "fail" and not fran and (deniedOf(bare) or {}).claimId == rec.claimId,
        "撬棍：門窗所在格在範圍外、北側那格在 claim：照樣被拒")
    fo, fran = force(bare, portal(120, 105, false))
    check(fo == "fail" and not fran and (deniedOf(bare) or {}).claimId == neighbor.claimId,
        "撬棍：門窗所在格在範圍外、西側那格在 claim：照樣被拒")
    fo, fran = force(bare, portal(105, 99, true))
    check(fo == "success" and fran, "撬棍：兩側都在範圍外照原版")
    local o1, ran1 = force(full, portal(105, 110, true))
    local o2, ran2 = force(owner, portal(105, 105, false))
    check(o1 == "success" and ran1 and o2 == "success" and ran2, "撬棍：有 BUILD 的成員與屋主照原版")
    fo, fran = force(full, portal(110, 105, false))
    check(fo == "fail" and not fran and (deniedOf(full) or {}).claimId == neighbor.claimId,
        "撬棍：門兩側分屬兩間，沒有 BUILD 的那間擋下（denied 帶那間的 claimId）")
    local nb = T.player({ name = "neighbor" })
    fo, fran = force(nb, portal(110, 105, false))
    check(fo == "fail" and not fran and (deniedOf(nb) or {}).claimId == rec.claimId,
        "撬棍：所在格是自己的屋、西側那格在別人的 claim 沒有 BUILD：照樣被拒（兩側都查）")
    fo, fran = force(bare, T.worldObject(105, 105))
    check(fran, "撬棍：不是門窗的物件交給原 attempt（原版回 fail）")

    T.section("Permissions：爐子面板指令")
    local realGetCell = getCell
    local stove = { __class = "IsoStove", toggles = 0 }
    function stove:Toggle() self.toggles = self.toggles + 1 end
    local plain = { __class = "IsoObject" }
    getCell = function()
        return { getGridSquare = function(_, x, y, z)
            if z ~= z then z = 0 end                           -- fastfloor：NaN 當 0（PZMath.java:272-275）
            local sq = T.gridSquare(x, y, z)
            sq.getObjects = function() return T.javaList(z == 0 and { plain, stove } or { plain }) end
            return sq
        end }
    end
    T.fire("OnClientCommand", "stove", "setOvenParamsAndToggle", bare, { x = 105, y = 105, z = 0, timer = 0, maxTemperature = 200 })
    check(stove.toggles == 1, "沒有 USE：原版開關後再翻回一次")
    T.fire("OnClientCommand", "stove", "setOvenParamsAndToggle", full, { x = 105, y = 105, z = 0, timer = 0, maxTemperature = 200 })
    T.fire("OnClientCommand", "stove", "setOvenParamsAndToggle", bare, { x = 305, y = 105, z = 0, timer = 0, maxTemperature = 200 })
    check(stove.toggles == 1, "有 USE、foreign 屋：不翻")
    T.fire("OnClientCommand", "stove", "setOvenParamsAndToggle", bare, { x = 105, y = 105, z = 0 / 0, timer = 0, maxTemperature = 200 })
    check(stove.toggles == 2, "沒有 USE、座標不是有限數但原版找得到格子：照樣翻回那格的爐子")
    getCell = realGetCell

    T.section("Permissions：audit 聚合")
    MSH.Audit.flush()
    local function logged(label)
        for _, line in ipairs(T.logs) do
            if string.find(line, "^DENY\tbare\t") and string.find(line, "PERM_DENIED", 1, true)
                and string.find(line, label .. "@" .. rec.claimId, 1, true) then return true end
        end
        return false
    end
    check(logged("ISToggleLightAction") and logged("ISMoveablesAction") and logged("ISDestroyStuffAction")
        and logged("ISPlowAction") and logged("ISTakeWaterAction") and logged("Actions.build") and logged("farm:seed")
        and logged("ISForceOpen") and logged("stove:setOvenParamsAndToggle"), "每類拒絕都進 audit（DENY、PERM_DENIED、動作@claimId）")
    local n = 0
    for _, line in ipairs(T.logs) do
        if string.find(line, "ISToggleLightAction@" .. rec.claimId, 1, true) and string.find(line, "^DENY\tbare\t") then n = n + 1 end
    end
    check(n == 1, "同一人同一動作在一分鐘內只寫一行（帶次數）")

    T.section("Permissions：伺服器公開 API v1.denies")
    local v1 = MSH.v1
    check(v1.API_MAJOR == 1 and v1.API_REVISION >= 2 and v1.CAPABILITIES.denies == true and type(v1.denies) == "function",
        "v1：API_MAJOR 1、API_REVISION ≥ 2、CAPABILITIES.denies")
    check(v1.BITS.USE == B.USE and v1.BITS.MOVE == B.MOVE and v1.BITS.BUILD == B.BUILD and v1.BITS.FARM == B.FARM,
        "v1.BITS 就是分享位元")
    local BUILD = v1.BITS.BUILD
    check(v1.denies(bare, 50, 50, 0, BUILD) == false, "無主地：false")
    check(v1.denies(owner, 105, 105, 0, BUILD) == false and v1.denies(full, 105, 105, 0, BUILD) == false,
        "屋主與有 BUILD 的成員：false")
    local d1, c1 = v1.denies(bare, 105, 105, 0, BUILD)
    check(d1 == true and c1 == "PERM_DENIED" and (deniedOf(bare) or {}).bit == B.BUILD, "別人的 claim 沒有 BUILD：true，推 denied")
    T.unloaded["105,105"] = true
    check(v1.denies(bare, 105.5, 105.5, 3, BUILD) == true, "格子不存在的樓層、小數座標：照 claim 判斷")
    T.unloaded["105,105"] = nil
    check(v1.denies(bare, 305, 105, 0, BUILD) == false, "原版安全屋（foreign）不判斷，呼叫端另查")
    check(v1.denies(coop, 101, 101, 0, BUILD) == true, "分割畫面次玩家（沒有 principal）冒用屋主名字：true")
    MSH.Audit.flush()
    local logsBefore = #T.logs
    local pd, pc = v1.denies(stranger, 105, 105, 0, v1.BITS.USE, { preview = true })
    local pushed = deniedOf(stranger)
    MSH.Audit.flush()
    check(pd == true and pc == "PERM_DENIED" and pushed == nil and #T.logs == logsBefore, "preview：照樣判定，不寫稽核、不推送")
    v1.denies(bare, 105, 105, 0, BUILD, { label = "Builder:complete" })
    v1.denies(bare, 105, 105, 0, BUILD, { label = "Builder|x" })
    MSH.Audit.flush()
    check(logged("Builder:complete") and logged("Builder/x"), "opts.label 寫進稽核；裡面的 | 換成 /（稽核聚合鍵的分欄字元）")
    local bad = true
    for _, args in ipairs({ { nil, 105, 105, 0, BUILD }, { bare, "105", 105, 0, BUILD }, { bare, 105, 105, 0 / 0, BUILD },
        { bare, 50, 50, 0, B.MEMBER }, { bare, 50, 50, 0, B.TAKE }, { bare, 50, 50, 0, BUILD, "preview" } }) do
        local d, c = v1.denies(args[1], args[2], args[3], args[4], args[5], args[6])
        bad = bad and d == true and c == "BAD_ARGS"
    end
    check(bad, "參數不對（沒有玩家、座標不是有限數字、不是 USE/MOVE/BUILD/FARM、opts 不是表）：true, BAD_ARGS")

    T.section("Permissions：重新開機後包裝照樣生效")
    MSH = T.boot()
    local again = mk(MSH, { x = 100, y = 100, w = 10, h = 10 }, "owner", MSH.SOURCE.DEED, { { user = "bare", bits = B.MEMBER } })
    bare = T.player({ name = "bare" })
    local a = T.action("ISToggleLightAction", { character = bare, object = T.worldObject(101, 101) })
    check(a:complete() == false and T.ran["ISToggleLightAction.complete"] == nil and again.claimId ~= nil, "新開機：包裝照樣生效")

    T.section("PermissionsClient：藏選單判定")
    MSH = T.bootClient()
    local PC = MSH.PermissionsClient
    check(PC.hides(nil, B.USE) == false, "不在 managed（nil）：不藏")
    check(PC.hides(MSH.SHARE_ALL, B.BUILD) == false, "屋主（全部位元）：不藏")
    check(PC.hides(B.MEMBER + B.USE, B.USE) == false and PC.hides(B.MEMBER + B.USE, B.FARM) == true, "成員：缺哪位藏哪類")
    check(PC.hides(0, B.MOVE) == true, "managed 但不在清單（0）：藏")

    -- 假選單：根選單＋一個子選單（燈的開關），處理函式比對（含 addGetUpOption 的 param1）
    local onToggleLight, onPlow, onShovel, onFertilize, onCompost, onEat =
        function() end, function() end, function() end, function() end, function() end, function() end
    ISWorldObjectContextMenu = { onToggleLight = onToggleLight }
    ISFarmingMenu = { onPlow = onPlow, onShovel = onShovel, onFertilize = onFertilize, onCompost = onCompost }
    ISContextMenu = { onGetUpAndThen = function() end }
    local function menu(opts)
        local m = { options = opts, optionPool = {}, numOptions = #opts + 1, heights = 0 }
        function m:calcHeight() self.heights = self.heights + 1 end
        for i, o in ipairs(opts) do o.id = i end
        return m
    end
    local sub = menu({ { name = "Turn On", onSelect = ISContextMenu.onGetUpAndThen, param1 = onToggleLight } })
    local root = menu({
        { name = "Eat", onSelect = onEat },
        { name = "Light", subOption = 1 },
        { name = "Dig", onSelect = onPlow },
        { name = "Remove", onSelect = onShovel },
        { name = "Fertilize", onSelect = onFertilize },
        { name = "Compost", onSelect = onCompost },
    })
    root.instanceMap = { sub }
    check(PC.filterMenu(root, nil) == 0 and #root.options == 6, "nil：不動選單")
    check(PC.filterMenu(root, B.MEMBER + B.USE) == 4 and #root.options == 2 and root.options[2].name == "Light",
        "缺 FARM：只拿掉耕種項（翻土、移除作物、施肥、堆肥）")
    check(PC.filterMenu(root, B.MEMBER) == 1 and #sub.options == 0 and #root.options == 1 and root.options[1].name == "Eat"
        and root.options[1].id == 1 and root.numOptions == 2, "缺 USE：拿掉 get-up 包裝的開燈項，空掉的子選單父項一起拿掉、id 重排")

    -- 撬開（42.22 onForceOpen）照門窗兩側判斷：點的那格不在 claim（bits 是 nil）、門窗另一側在 claim，照樣藏
    local onForceOpen = function() end
    ISWorldObjectContextMenu.onForceOpen = onForceOpen
    local realBitsAt, edgeBits = MSH.Client.bitsAt, B.MEMBER
    MSH.Client.bitsAt = function(x, y)
        if x >= 100 and x < 110 and y >= 100 and y < 110 then return edgeBits end
        return nil
    end
    local function forceMenu(x, y, north)
        local target = T.edgeObject("IsoDoor", x, y, north)
        local doorSub = menu({ { name = "Force", onSelect = ISContextMenu.onGetUpAndThen, param1 = onForceOpen, param2 = {}, param3 = target },
            { name = "Lock", onSelect = onEat } })
        local r = menu({ { name = "Door", subOption = 1 } })
        r.instanceMap = { doorSub }
        return r, doorSub
    end
    local fr, fs = forceMenu(105, 110, true)
    check(PC.filterMenu(fr, nil) == 1 and #fs.options == 1 and fs.options[1].name == "Lock",
        "撬開：所在格在範圍外、北側那格在 claim、沒有 BUILD：藏（點的格子不在 claim 也照樣判斷）")
    fr, fs = forceMenu(110, 105, false)
    check(PC.filterMenu(fr, nil) == 1 and #fs.options == 1, "撬開：所在格在範圍外、西側那格在 claim、沒有 BUILD：藏")
    fr, fs = forceMenu(105, 100, true)
    check(PC.filterMenu(fr, nil) == 1 and #fs.options == 1, "撬開：所在格在 claim、北側那格在範圍外、沒有 BUILD：藏")
    fr, fs = forceMenu(105, 99, true)
    check(PC.filterMenu(fr, nil) == 0 and #fs.options == 2, "撬開：兩側都在範圍外不藏")
    edgeBits = B.MEMBER + B.BUILD
    fr, fs = forceMenu(105, 110, true)
    check(PC.filterMenu(fr, nil) == 0 and #fs.options == 2, "撬開：有 BUILD 不藏")

    -- 拆路障（三種）照門窗兩側判斷：選項帶的門窗（窗框不是 IForceablePortal，照樣算）
    edgeBits = B.MEMBER
    local unbarBad = {}
    for _, field in ipairs({ "onUnbarricade", "onUnbarricadeMetal", "onUnbarricadeMetalBar" }) do
        local fn = function() end
        ISWorldObjectContextMenu[field] = fn
        local m = menu({ { name = field, onSelect = ISContextMenu.onGetUpAndThen, param1 = fn, param2 = {},
            param3 = T.edgeObject("IsoWindowFrame", 105, 110, true) }, { name = "Keep", onSelect = onEat } })
        local far = menu({ { name = field, onSelect = fn, param1 = T.edgeObject("IsoWindowFrame", 105, 99, true) } })
        if PC.filterMenu(m, nil) ~= 1 or #m.options ~= 1 or PC.filterMenu(far, nil) ~= 0 then unbarBad[#unbarBad + 1] = field end
    end
    check(#unbarBad == 0, "拆路障：窗框所在格在範圍外、北側那格在 claim、沒有 BUILD：藏；兩側都在範圍外不藏"
        .. (#unbarBad > 0 and "（不對：" .. table.concat(unbarBad, "、") .. "）" or ""))
    MSH.Client.bitsAt = realBitsAt

    T.section("PermissionsClient：梯子（42.22）")
    -- 原生安全屋 x 100..109、y 100..109，屋主 host；me 不在名單
    T.houses[#T.houses + 1] = T.house(100, 100, 10, 10, "host")
    local me, host = T.player({ name = "me" }), T.player({ name = "host", num = 1 })
    local function ladder(x, y, prop) return T.worldObject(x, y, 0, { prop }) end
    check(PC.ladderBlocked(me, ladder(105, 110, "ladderN")) == true, "梯子在範圍外、出口（北邊那格）在不能進的安全屋：擋")
    check(PC.ladderBlocked(me, ladder(105, 109, "ladderS")) == true, "梯子在安全屋裡、出口在範圍外（從外面爬下來）：擋")
    check(PC.ladderBlocked(me, ladder(99, 105, "ladderE")) == true and PC.ladderBlocked(me, ladder(110, 105, "ladderW")) == true,
        "東向、西向的梯子：出口在安全屋就擋")
    check(PC.ladderBlocked(me, ladder(105, 110, "ladderS")) == false and PC.ladderBlocked(me, ladder(105, 111, "ladderN")) == false,
        "梯子與出口都在範圍外：不擋")
    check(PC.ladderBlocked(host, ladder(105, 110, "ladderN")) == false, "屋主：不擋")
    T.serverOptions.SafehouseAllowTrepass = "true"
    check(PC.ladderBlocked(me, ladder(105, 110, "ladderN")) == false, "伺服器允許進別人的安全屋：不擋（同走路的判定）")
    T.serverOptions.SafehouseAllowTrepass = "false"
    T.unloaded["105,109"] = true
    check(PC.ladderBlocked(me, ladder(105, 110, "ladderN")) == false, "出口那格還沒載入：不擋（同原版判定收到 nil）")
    T.unloaded["105,109"] = nil
    check(PC.ladderBlocked(me, nil) == false and PC.ladderBlocked(nil, ladder(105, 110, "ladderN")) == false, "沒有梯子、沒有玩家：不擋")
    -- 選單：「爬梯子」是 addGetUpOption(文字, 格子, onClimbLadder, down, playerObj, ladder)
    local climbs, halo = 0, {}
    HaloTextHelper = { addBadText = function(p, text) halo[#halo + 1] = text end }
    ISWorldObjectContextMenu.onClimbLadder = function() climbs = climbs + 1 end
    ISClimbLadderAction = { isValid = function() return "orig" end }
    PC.installed = nil
    PC.install()
    local function climbMenu(l)
        return menu({ { name = "Climb", onSelect = ISContextMenu.onGetUpAndThen, param1 = ISWorldObjectContextMenu.onClimbLadder,
            param2 = T.gridSquare(105, 110), param3 = false, param4 = me, param5 = l }, { name = "Walk", onSelect = onEat } })
    end
    local cm = climbMenu(ladder(105, 110, "ladderN"))
    check(PC.filterMenu(cm, nil) == 1 and #cm.options == 1 and cm.options[1].name == "Walk", "選單：會進到不能進的安全屋就不列「爬梯子」")
    cm = climbMenu(ladder(105, 110, "ladderS"))
    check(PC.filterMenu(cm, nil) == 0 and #cm.options == 2, "選單：不會進到安全屋的梯子照列")
    ISWorldObjectContextMenu.onClimbLadder(T.gridSquare(105, 110), false, me, ladder(105, 110, "ladderN"))
    check(climbs == 0 and #halo == 1 and string.find(halo[1], "IGUI_MSH_Ladder_Blocked", 1, true) ~= nil,
        "選單與互動鍵的入口：擋下時不呼叫原函式、顯示一句原因")
    ISWorldObjectContextMenu.onClimbLadder(T.gridSquare(105, 110), false, me, ladder(105, 110, "ladderS"))
    ISWorldObjectContextMenu.onClimbLadder(T.gridSquare(105, 110), false, host, ladder(105, 110, "ladderN"))
    check(climbs == 2 and #halo == 1, "入口：不擋的梯子、能進的人照原版")
    check(ISClimbLadderAction.isValid({ character = me, ladder = ladder(105, 110, "ladderN") }) == false
        and ISClimbLadderAction.isValid({ character = me, ladder = ladder(105, 110, "ladderS") }) == "orig",
        "爬梯動作 isValid：擋下回 false，其他照原函式")
    halo = {}

    -- denied 推送：沒有框架 → HaloTextHelper
    T.fire("OnServerCommand", MSH.MODULE, "denied", { code = "PERM_DENIED", bit = B.BUILD, claimId = 1 })
    check(#halo == 1 and string.find(halo[1], "IGUI_MSH_Perm_Denied", 1, true) ~= nil, "收到 denied：沒有框架時用 HaloTextHelper 顯示一句")
    ISWorldObjectContextMenu, ISFarmingMenu, ISContextMenu, HaloTextHelper, ISClimbLadderAction = nil, nil, nil, nil, nil
end
