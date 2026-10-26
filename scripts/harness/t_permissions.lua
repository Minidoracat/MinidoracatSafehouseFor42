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
    }
    local CATEGORY = {
        USE = { "ISToggleLightAction", "ISLightActions", "ISToggleStoveAction", "ISRadioAction", "ISPlugGenerator",
            "ISActivateGenerator", "ISAddFuel", "ISFixGenerator", "ISFluidTransferAction" },
        MOVE = { "ISMoveablesAction", "ISTakeGenerator" },
        BUILD = { "ISDestroyStuffAction", "ISDismantleAction", "ISBarricadeAction", "ISUnbarricadeAction" },
        FARM = { "ISPlowAction", "ISSeedActionNew", "ISHarvestPlantAction", "ISCurePlantAction", "ISWaterPlantAction" },
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
    check(T.ran["Actions.build"] == 3, "座標不是數字：不判定、照原版")
    -- 格子不存在的樓層：照座標判斷
    T.unloaded["105,105"] = true
    Actions.build(bare, { x = 105, y = 105, z = 3 })
    check(T.ran["Actions.build"] == 3, "格子不存在的樓層：沒有 BUILD 照樣被拒")
    Actions.build(full, { x = 105, y = 105, z = 3 })
    check(T.ran["Actions.build"] == 4, "格子不存在的樓層：有 BUILD 照原版")
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
    -- 一格在自己有 BUILD 的 claim、一格在別人的 claim
    local neighbor = mk(MSH, { x = 110, y = 100, w = 10, h = 10 }, "neighbor", MSH.SOURCE.DEED, {})
    check(not built(full, wide, 109, 105) and (deniedOf(full) or {}).claimId == neighbor.claimId,
        "兩格分屬兩間：沒有 BUILD 的那間擋下（denied 帶那間的 claimId）")
    SFarmingSystemCommands.seed(bare, { x = 105, y = 105, z = 0 })
    check(T.ran["farm.seed"] == nil, "沒有 FARM：農務指令不執行")
    SFarmingSystemCommands.seed(farmer, { x = 105, y = 105, z = 0 })
    SFarmingSystemCommands.destroy(nil, { x = 105, y = 105, z = 0 })   -- SFarmingSystem.destroyPlant 自己呼叫
    check(T.ran["farm.seed"] == 1 and T.ran["farm.destroy"] == 1, "有 FARM、伺服器自己呼叫（player nil）：照原版")

    T.section("Permissions：爐子面板指令")
    local realGetCell = getCell
    local stove = { __class = "IsoStove", toggles = 0 }
    function stove:Toggle() self.toggles = self.toggles + 1 end
    local plain = { __class = "IsoObject" }
    getCell = function()
        return { getGridSquare = function(_, x, y, z)
            local sq = T.gridSquare(x, y, z)
            sq.getObjects = function() return T.javaList({ plain, stove }) end
            return sq
        end }
    end
    T.fire("OnClientCommand", "stove", "setOvenParamsAndToggle", bare, { x = 105, y = 105, z = 0, timer = 0, maxTemperature = 200 })
    check(stove.toggles == 1, "沒有 USE：原版開關後再翻回一次")
    T.fire("OnClientCommand", "stove", "setOvenParamsAndToggle", full, { x = 105, y = 105, z = 0, timer = 0, maxTemperature = 200 })
    T.fire("OnClientCommand", "stove", "setOvenParamsAndToggle", bare, { x = 305, y = 105, z = 0, timer = 0, maxTemperature = 200 })
    check(stove.toggles == 1, "有 USE、foreign 屋：不翻")
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
        and logged("stove:setOvenParamsAndToggle"), "每類拒絕都進 audit（DENY、PERM_DENIED、動作@claimId）")
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
    local onToggleLight, onPlow, onEat = function() end, function() end, function() end
    ISWorldObjectContextMenu = { onToggleLight = onToggleLight }
    ISFarmingMenu = { onPlow = onPlow }
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
    })
    root.instanceMap = { sub }
    check(PC.filterMenu(root, nil) == 0 and #root.options == 3, "nil：不動選單")
    check(PC.filterMenu(root, B.MEMBER + B.USE) == 1 and #root.options == 2 and root.options[2].name == "Light",
        "缺 FARM：只拿掉耕種項")
    check(PC.filterMenu(root, B.MEMBER) == 1 and #sub.options == 0 and #root.options == 1 and root.options[1].name == "Eat"
        and root.options[1].id == 1 and root.numOptions == 2, "缺 USE：拿掉 get-up 包裝的開燈項，空掉的子選單父項一起拿掉、id 重排")

    -- denied 推送：沒有框架 → HaloTextHelper
    local halo = {}
    HaloTextHelper = { addBadText = function(p, text) halo[#halo + 1] = text end }
    T.player({ name = "me" })
    T.fire("OnServerCommand", MSH.MODULE, "denied", { code = "PERM_DENIED", bit = B.BUILD, claimId = 1 })
    check(#halo == 1 and string.find(halo[1], "IGUI_MSH_Perm_Denied", 1, true) ~= nil, "收到 denied：沒有框架時用 HaloTextHelper 顯示一句")
    ISWorldObjectContextMenu, ISFarmingMenu, ISContextMenu, HaloTextHelper = nil, nil, nil, nil
end
