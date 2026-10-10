-- 細分權限（Permissions.lua、PermissionsClient.lua；計畫 §6.6）：每類位元的拒絕／放行邊界、取水不轉水、
-- Actions.build 拒絕不呼叫原函式、農務指令、爐子面板翻回、denied 推送與 audit、客戶端藏選單判定。
return function(T)
    local check = T.check

    local function mk(MSH, rect, owner, source, grants)
        local R = MSH.Registry
        local rec = R.newRecord({ claimId = R.allocId(), rect = rect, title = "t", owner = owner, source = source,
            deedTier = 1, createdAt = T.now, grants = grants })
        local house = MSH.Native.build(rec)
        rec.nativeCreatedAt = house:getDatetimeCreated()
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
    })
    local legacy = mk(MSH, { x = 200, y = 100, w = 10, h = 10 }, "lord", MSH.SOURCE.LEGACY, {
        { user = "old", bits = MSH.SHARE_LEGACY },
    })
    T.house(300, 100, 10, 10, "carol")   -- foreign 原生屋：不在 registry
    local owner = T.player({ name = "owner" })
    local full = T.player({ name = "full" })
    local bare = T.player({ name = "bare" })
    local farmer = T.player({ name = "farmer" })
    local old = T.player({ name = "old" })
    local stranger = T.player({ name = "stranger" })
    local coop = T.player({ name = "owner2", num = 1 })   -- 分割畫面次玩家：principal 是 nil
    coop.name = "owner"

    -- 每個類別的目標欄位（照各類別 :new）
    local TARGET = {
        ISToggleLightAction = function(x, y) return { object = T.worldObject(x, y) } end,
        ISToggleStoveAction = function(x, y) return { object = T.worldObject(x, y) } end,
        ISRadioAction = function(x, y) return { device = T.worldObject(x, y) } end,
        ISPlugGenerator = function(x, y) return { generator = T.worldObject(x, y) } end,
        ISActivateGenerator = function(x, y) return { generator = T.worldObject(x, y) } end,
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
        USE = { "ISToggleLightAction", "ISToggleStoveAction", "ISRadioAction", "ISPlugGenerator", "ISActivateGenerator",
            "ISFluidTransferAction" },
        MOVE = { "ISMoveablesAction" },
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
