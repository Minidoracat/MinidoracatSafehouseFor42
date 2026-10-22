-- 室內檢查（使用者 2026-10-15；server Indoor.lua、client IndoorPanel.lua）：伺服器照引擎的 region 規則判定與找缺口
-- （和 E2E indoor-mp 同一組房子：蓋好、缺屋頂、缺牆、缺牆又缺屋頂、角落缺屋頂、兩間、室外、地圖房間、地下），
-- 查詢指令的距離與參數檢查；客戶端面板只在開著時掛事件、送查詢的節流、地上標示。
-- 假 IsoRegions 與 getCell 只在本情境用到，放在本檔、結束時還原全域。
return function(T)
    local check = T.check
    local WALL_N, WALL_W, FLOOR = 1, 2, 16
    local saved = { getCell = getCell, IsoRegions = IsoRegions, IsoFlagType = IsoFlagType, IsoObjectType = IsoObjectType,
        buildUtil = buildUtil }

    -- 假 IsoRegions（getSquareFlags／getIsoWorldRegion／getChunkRegion）：flags["x,y,z"]＝位元和，沒有＝-1（沒資料）。
    -- region 照引擎：同一層不穿牆相連的格子；有一條走得過去的邊通到沒資料的格子＝不封閉；屋頂數＝正上方一層有地板的格數
    -- props["x,y,z"]＝那格現在的物件真正有的屬性（覆蓋用；沒寫的照記著的位元，見 truth），recalc＝引擎排了重算的格子，
    -- prev＝IsoRegions 共用的 previousFlags（squareChanged 只在算出的位元和它不同時才排工作，IsoRegions.java:309-320）
    local W = { flags = {}, map = {}, doors = {}, regions = nil, objs = {}, westWall = {}, removed = {}, props = {},
        recalc = {}, prev = 0 }
    local function k3(x, y, z) return x .. "," .. y .. "," .. z end
    local function fl(x, y, z) return W.flags[k3(x, y, z)] or -1 end
    local function bit(f, b) return f >= 0 and math.floor(f / b) % 2 == 1 end
    local function setBit(x, y, z, b, on)
        local f = fl(x, y, z)
        if f < 0 then f = 0 end
        if bit(f, b) ~= on then f = on and f + b or f - b end
        W.flags[k3(x, y, z)] = f
        W.regions = nil
    end
    local function ground(x0, y0, x1, y1, z)
        for x = x0, x1 do
            for y = y0, y1 do setBit(x, y, z or 0, FLOOR, true) end
        end
    end
    -- 屋頂＝正上方一層的地板；z 省略＝地面層
    local function roof(x0, y0, x1, y1, z) ground(x0, y0, x1, y1, (z or 0) + 1) end
    local function unroof(x, y, z)
        W.flags[k3(x, y, (z or 0) + 1)] = nil
        W.regions = nil
    end
    local function wall(x, y, b, on, z) setBit(x, y, z or 0, b, on ~= false) end
    -- 圍一圈牆：裡面是 x0..x1, y0..y1
    local function box(x0, y0, x1, y1, z)
        for x = x0, x1 do
            wall(x, y0, WALL_N, true, z)
            wall(x, y1 + 1, WALL_N, true, z)
        end
        for y = y0, y1 do
            wall(x0, y, WALL_W, true, z)
            wall(x1 + 1, y, WALL_W, true, z)
        end
    end
    local DX, DY = { [0] = 0, -1, 0, 1 }, { [0] = -1, 0, 1, 0 }
    local function canMove(x, y, z, d)
        if d == 0 then return not bit(fl(x, y, z), WALL_N) end
        if d == 1 then return not bit(fl(x, y, z), WALL_W) end
        if d == 2 then return not bit(fl(x, y + 1, z), WALL_N) end
        return not bit(fl(x + 1, y, z), WALL_W)
    end
    local nextId = 0
    local function build()
        local by = {}
        for k in pairs(W.flags) do
            if by[k] == nil then
                local x0, y0, z = string.match(k, "^(-?%d+),(-?%d+),(-?%d+)$")
                x0, y0, z = tonumber(x0), tonumber(y0), tonumber(z)
                nextId = nextId + 1
                local r = { id = nextId, size = 0, roofs = 0, enclosed = true }
                function r.getID() return r.id end
                function r.isEnclosed() return r.enclosed end
                function r.getRoofCnt() return r.roofs end
                function r.getSquareSize() return r.size end
                r.chunk = { getIsoWorldRegion = function() return r end }
                by[k] = r
                local q, qi = { x0, y0 }, 1
                while qi <= #q do
                    local x, y = q[qi], q[qi + 1]
                    qi = qi + 2
                    r.size = r.size + 1
                    if bit(fl(x, y, z + 1), FLOOR) then r.roofs = r.roofs + 1 end
                    for d = 0, 3 do
                        if canMove(x, y, z, d) then
                            local nx, ny = x + DX[d], y + DY[d]
                            local nk = k3(nx, ny, z)
                            if fl(nx, ny, z) < 0 then
                                r.enclosed = false
                            elseif by[nk] == nil then
                                by[nk] = r
                                q[#q + 1] = nx
                                q[#q + 1] = ny
                            end
                        end
                    end
                end
            end
        end
        W.regions = by
    end
    local function region(x, y, z)
        if W.regions == nil then build() end
        return W.regions[k3(x, y, z)]
    end
    W.reads = 0
    -- 格子上的柱子（WallSE）與真的西牆（getWall(false) 找得到）：W.objs[k]＝物件清單，W.westWall[k]＝有真的西牆。
    -- 西牆位元照引擎（IsoRegions.java:336）：那格有柱子就不設；拆物件時照同一條重算（RemoveTileObject）
    local function anySE(list)
        for _, o in ipairs(list or {}) do
            if o.isWallSE() then return true end
        end
        return false
    end
    -- 格子現在的屬性：props 有寫的照它，柱子照物件，其他照記著的位元（記錄沒過期的格子）
    local function truth(x, y, z, f)
        local k = k3(x, y, z)
        local p = W.props[k]
        if p ~= nil and p[f] ~= nil then return p[f] end
        if f == "WallSE" then return anySE(W.objs[k]) end
        if f == "solidfloor" then return bit(fl(x, y, z), FLOOR) end
        if f == "cutN" then return bit(fl(x, y, z), WALL_N) end
        if f == "cutW" then return bit(fl(x, y, z), WALL_W) end
        return false
    end
    -- 引擎照格子現在的屬性算的位元（IsoRegions.calculateSquareFlags 的地板、北牆、西牆；柱子讓西牆不算）
    local function calc(x, y, z)
        local f = truth(x, y, z, "solidfloor") and FLOOR or 0
        if truth(x, y, z, "cutN") then f = f + WALL_N end
        if truth(x, y, z, "cutW") and not truth(x, y, z, "WallSE") then f = f + WALL_W end
        return f
    end
    IsoRegions = {
        getSquareFlags = function(x, y, z)
            W.reads = W.reads + 1
            return fl(x, y, z)
        end,
        getIsoWorldRegion = function(x, y, z) return region(x, y, z) end,
        getChunkRegion = function(x, y, z)
            local r = region(x, y, z)
            return r and r.chunk or nil
        end,
        setPreviousFlags = function(sq) W.prev = sq and calc(sq:getX(), sq:getY(), sq:getZ()) or 0 end,
        -- 真的引擎在背景執行緒重算、之後的查詢才看得到；這裡當場改（查詢的回覆在呼叫之前就算好了）
        squareChanged = function(sq)
            local x, y, z = sq:getX(), sq:getY(), sq:getZ()
            local f = calc(x, y, z)
            if f == W.prev then return end
            W.flags[k3(x, y, z)], W.regions, W.prev = f, nil, 0
            W.recalc[#W.recalc + 1] = k3(x, y, z)
        end,
    }
    local function engineW(x, y, z)
        local k = k3(x, y, z)
        setBit(x, y, z, WALL_W, W.westWall[k] == true and not anySE(W.objs[k]))
    end
    local function westWall(x, y)
        W.westWall[k3(x, y, 0)] = true
        engineW(x, y, 0)
    end
    -- 柱子：corner＝蓋牆時自動補的牆角（isCorner），否則是玩家自己蓋的
    local function pillar(x, y, corner)
        local k = k3(x, y, 0)
        local list = W.objs[k] or {}
        W.objs[k] = list
        local o = { __class = "IsoThumpable" }
        function o.isWallSE() return true end
        function o.isCorner() return corner == true end
        list[#list + 1] = o
        engineW(x, y, 0)
        return o
    end
    -- 伺服器的格子：地圖房間（getRoom 不是 nil、不是 user-defined）、缺口上的門（getSpecialObjects）、柱子與西牆
    local NO_OBJECTS = {}
    getCell = function()
        return { getGridSquare = function(_, x, y, z)
            local k = k3(x, y, z)
            local inMap, objs = W.map[k], W.doors[k] or NO_OBJECTS
            return { getX = function() return x end, getY = function() return y end, getZ = function() return z end,
                getRoom = function() return inMap and {} or nil end, isUserDefinedRoom = function() return false end,
                getSpecialObjects = function()
                    return { size = function() return #objs end, get = function(_, i) return objs[i + 1] end }
                end,
                has = function(_, f) return truth(x, y, z, f) end,
                HasStairsNorth = function() return false end,
                HasStairsWest = function() return false end,
                getWall = function(_, north) return (not north and W.westWall[k]) and {} or nil end,
                getObjects = function()
                    local l = W.objs[k] or NO_OBJECTS
                    return { size = function() return #l end, get = function(_, i) return l[i + 1] end }
                end,
                transmitRemoveItemFromSquare = function(_, o)
                    local l = W.objs[k] or {}
                    for i = #l, 1, -1 do
                        if l[i] == o then table.remove(l, i) end
                    end
                    W.removed[#W.removed + 1] = k
                    engineW(x, y, z)
                end }
        end }
    end
    local function fresh()
        W.flags, W.map, W.doors, W.regions = {}, {}, {}, nil
        W.objs, W.westWall, W.removed, W.props, W.recalc = {}, {}, {}, {}, {}
        ground(0, 0, 40, 40, 0)
    end
    -- 在 (x, y) 放一扇門：north＝北邊的門；class 預設 IsoDoor（IsoThumpable 用 isDoor 分辨，isDoor＝false＝不是門的物件）
    local function door(x, y, north, open, class, isDoor)
        local o = { __class = class or "IsoDoor" }
        function o.getNorth() return north end
        function o.IsOpen() return open end
        function o.isDoor() return isDoor ~= false end
        W.doors[k3(x, y, 0)] = { o }
    end
    -- 清單換成集合字串比較："x,y" 或 "x,yN"／"x,yW"（排序後以空白相接）
    local function sorted(list)
        local out = {}
        for i, v in ipairs(list) do out[i] = v end
        table.sort(out)
        return table.concat(out, " ")
    end
    local function holes(r)
        local out = {}
        for i = 1, #r.holes, 2 do out[#out + 1] = r.holes[i] .. "," .. r.holes[i + 1] end
        return sorted(out)
    end
    local function gaps(r)
        local out = {}
        for i = 1, #r.gaps, 3 do out[#out + 1] = r.gaps[i] .. "," .. r.gaps[i + 1] .. (r.gaps[i + 2] == 1 and "N" or "W") end
        return sorted(out)
    end
    local function doors(r)
        local out = {}
        for i = 1, #r.doors, 4 do
            out[#out + 1] = r.doors[i] .. "," .. r.doors[i + 1] .. (r.doors[i + 2] == 1 and "N" or "W") .. r.doors[i + 3]
        end
        return sorted(out)
    end
    local function pillars(r)
        local out = {}
        for i = 1, #r.pillars, 3 do out[#out + 1] = r.pillars[i] .. "," .. r.pillars[i + 1] .. "W" .. r.pillars[i + 2] end
        return sorted(out)
    end
    local function runs(lv)
        local out = {}
        for i = 1, #lv.runs, 3 do out[#out + 1] = lv.runs[i] .. "," .. lv.runs[i + 1] .. "," .. lv.runs[i + 2] end
        return table.concat(out, " ")
    end

    -- 原版 buildUtil.checkCorner（蓋牆、門框、窗框、圍籬放好物件後呼叫；本 MOD 開服時包它）：記呼叫
    -- 旗標用名字當值（假格子的 has 照 truth 查）
    IsoFlagType = { WallSE = "WallSE", solidfloor = "solidfloor", cutN = "cutN", cutW = "cutW", WindowN = "WindowN",
        windowN = "windowN", DoorWallN = "DoorWallN", WindowW = "WindowW", windowW = "windowW", DoorWallW = "DoorWallW" }
    IsoObjectType = { doorFrN = "doorFrN", doorFrW = "doorFrW" }
    local cornerCalls = {}
    buildUtil = { checkCorner = function(x, y, z, north)
        cornerCalls[#cornerCalls + 1] = x .. "," .. y .. "," .. z .. (north and "N" or "W")
    end }
    local MSH = T.boot()
    local I = MSH.Indoor

    T.section("室內檢查：判定（伺服器，照引擎的 region 規則）")
    fresh()
    box(10, 10, 13, 13)
    roof(10, 10, 13, 13)
    local res = I.check(11, 11, 0)
    local r = res.rooms[1]
    check(res.verdict == "ROOM" and #res.rooms == 1 and r.verdict == "ROOM" and r.size == 16 and r.roofs == 16
        and r.holeCount == 0 and r.gapCount == 0 and #r.holes == 0 and #r.gaps == 0,
        "蓋好的 4×4：算室內，沒有缺口；同一個屋頂下沒有別間")
    check(res.minX == 10 and res.minY == 10 and res.maxX == 13 and res.maxY == 13 and res.partial == false,
        "回走過的外框（客戶端照它判斷附近的物件變動）")
    check(#res.levels == 1 and res.levels[1].z == 0 and runs(res.levels[1]) == "10,10,4 10,11,4 10,12,4 10,13,4"
        and r.z == 0 and res.minZ == 0 and res.maxZ == 0,
        "單層房子：只有地面這一層（屋頂就是上面那層的地板，上面沒再蓋不算一層），範圍每列壓成一段")

    unroof(11, 12)
    res = I.check(11, 11, 0)
    r = res.rooms[1]
    check(res.verdict == "NEED_ROOF" and r.size == 16 and r.roofs == 15 and holes(r) == "11,12" and r.gapCount == 0,
        "中間缺一格屋頂：屋頂沒蓋滿 15/16，標出那一格、牆沒有缺口")

    roof(11, 12, 11, 12)
    wall(10, 11, WALL_W, false)
    res = I.check(11, 11, 0)
    r = res.rooms[1]
    check(res.verdict == "OPEN" and r.size == 16 and r.roofs == 16 and gaps(r) == "10,11W" and r.gapCount == 1
        and r.walls == 15 and r.holeCount == 0, "西牆缺一格：牆有缺口，只標那一條邊（其餘 15 條是牆）；外面沒屋頂的格子不算進來")

    unroof(11, 12)
    res = I.check(11, 11, 0)
    r = res.rooms[1]
    check(res.verdict == "OPEN" and gaps(r) == "10,11W" and holes(r) == "11,12" and r.size == 16 and r.roofs == 15,
        "缺牆又缺屋頂：兩種都標；夾在屋頂中間的那格算房子的缺屋頂")

    fresh()
    box(10, 10, 13, 13)
    roof(10, 10, 13, 13)
    unroof(10, 10)
    wall(14, 12, WALL_W, false)
    res = I.check(11, 11, 0)
    r = res.rooms[1]
    check(res.verdict == "OPEN" and holes(r) == "10,10" and gaps(r) == "14,12W",
        "角落缺屋頂（不夾在中間）又有缺牆：外面走不進去的角落也算缺屋頂；東牆缺口記在東邊那格的西邊")

    fresh()
    box(10, 10, 13, 13)
    roof(10, 10, 13, 13)
    wall(10, 11, WALL_W, false)
    unroof(10, 11)
    res = I.check(11, 11, 0)
    r = res.rooms[1]
    check(res.verdict == "OPEN" and holes(r) == "10,11" and gaps(r) == "10,11W",
        "缺口那格頭上也沒屋頂（外面走得進去）：夾在同一欄屋頂中間，算缺屋頂；缺牆照樣標在原來的牆線上")

    fresh()
    box(10, 10, 13, 13)
    wall(10, 12, WALL_N)
    wall(11, 12, WALL_N)
    wall(12, 12, WALL_N)
    wall(13, 12, WALL_N)
    roof(10, 10, 13, 13)
    unroof(11, 13)
    res = I.check(11, 10, 0)
    check(res.verdict == "ROOM" and #res.rooms == 2 and res.rooms[1].size == 8 and res.rooms[1].roofs == 8
        and res.rooms[2].verdict == "NEED_ROOF" and res.rooms[2].size == 8 and res.rooms[2].roofs == 7
        and holes(res.rooms[2]) == "11,13" and holes(res.rooms[1]) == "",
        "同一個屋頂下兩間：站的那間 8/8 算室內，隔壁 7/8 標出缺的那格；缺口不會算到站的那間")
    local other = I.check(11, 13, 0)
    check(other.verdict == "NEED_ROOF" and other.rooms[2] ~= nil and other.rooms[2].verdict == "ROOM",
        "站在缺屋頂那格：起點是缺口也找得到同一個屋頂下的另一間")
    roof(11, 13, 11, 13)
    for x = 10, 13 do unroof(x, 12) end
    other = I.check(11, 13, 0)
    check(other.verdict == "NEED_ROOF" and other.rooms[1].holeCount == 4 and other.rooms[2] ~= nil
        and other.rooms[2].verdict == "ROOM", "一整排缺屋頂把屋頂切開：穿過缺屋頂的格子照樣找到另一間")

    T.section("室內檢查：室外、門口、地圖房間、地下、院子、屋簷")
    res = I.check(30, 30, 0)
    check(res.verdict == "OUTSIDE" and #res.rooms == 0, "空地：室外，沒有房間")
    fresh()
    box(10, 10, 13, 13)
    roof(10, 10, 13, 13)
    wall(10, 11, WALL_W, false)
    res = I.check(8, 11, 0)
    check(res.verdict == "OPEN" and res.rooms[1].x == 10 and res.rooms[1].y == 11 and gaps(res.rooms[1]) == "10,11W",
        "站在缺口外 2 格：4 步內穿過缺口找到屋頂，照那間回牆有缺口")
    res = I.check(4, 11, 0)
    check(res.verdict == "OUTSIDE" and #res.rooms == 0, "離缺口 6 格：超過 4 步，算室外（不會把遠處的房子當成這裡）")
    W.map[k3(5, 5, 0)] = true
    check(I.check(5, 5, 0).verdict == "MAP_ROOM", "地圖原有的房間：照地圖算，不看 IsoRegions")
    check(I.check(11, 11, -1).verdict == "BASEMENT", "地下（z < 0）：不算室內")
    W.map[k3(5, 5, -1)] = true
    check(I.check(5, 5, -1).verdict == "MAP_ROOM", "地圖的地下室有房間：先看地圖房間")

    fresh()
    box(10, 10, 13, 13)
    roof(10, 10, 13, 13)
    roof(14, 10, 17, 13)
    for x = 14, 17 do
        for y = 10, 13 do W.map[k3(x, y, 0)] = true end
    end
    res = I.check(11, 11, 0)
    check(res.verdict == "ROOM" and #res.rooms == 1, "貼著地圖建築：找同一個屋頂下的房間時不進地圖房間")

    fresh()
    box(20, 20, 29, 29)
    roof(20, 20, 22, 22)
    res = I.check(21, 21, 0)
    r = res.rooms[1]
    check(res.verdict == "PART_ROOF" and r.size == 9 and r.walls == 6
        and gaps(r) == "20,23N 21,23N 22,23N 23,20W 23,21W 23,22W",
        "圍籬圍起來的院子（封閉、屋頂不到一半）裡的棚子：只有一部分有屋頂，標出棚子朝院子、可以隔牆的兩邊")
    check(I.check(27, 27, 0).verdict == "OUTSIDE", "院子裡離棚子遠的地方：室外，不會把整個院子標成缺屋頂")

    fresh()
    box(10, 10, 13, 13)
    roof(9, 9, 14, 14)
    res = I.check(11, 11, 0)
    local ring = res.rooms[2]
    check(res.verdict == "ROOM" and #res.rooms == 2 and ring.verdict == "OPEN" and ring.size == 20 and ring.walls == 16
        and ring.gapCount == 24 and ring.holeCount == 0,
        "屋頂比牆多出一圈：屋簷下另算一間（沒圍起來的邊多過有牆的邊，客戶端照這個分辨屋簷下）")

    T.section("室內檢查：缺口上的門（使用者 2026-10-15：正式服開著的車庫門被列成缺牆）")
    fresh()
    box(10, 10, 13, 13)
    roof(10, 10, 13, 13)
    for y = 11, 13 do
        wall(10, y, WALL_W, false)    -- 開著的車庫門片沒有牆的屬性：引擎照缺口算
        door(10, y, false, true)
    end
    wall(12, 10, WALL_N, false)
    door(12, 10, false, false)        -- 西邊的門放在北牆缺口那格：不是這條邊的門
    wall(13, 10, WALL_N, false)
    door(13, 10, true, false, "IsoThumpable", false)   -- 北邊、但不是門（自建的牆之類）
    res = I.check(11, 11, 0)
    r = res.rooms[1]
    check(r.verdict == "OPEN" and r.gapCount == 5 and r.doorCount == 3 and doors(r) == "10,11W1 10,12W1 10,13W1"
        and gaps(r) == "12,10N 13,10N",
        "缺口上有開著的門：另列 doors（開著＝1），gapCount 照算全部；方向不合的門、不是門的物件照缺牆列")
    for y = 11, 13 do door(10, y, false, false, "IsoThumpable") end
    r = I.check(11, 11, 0).rooms[1]
    check(r.doorCount == 3 and doors(r) == "10,11W0 10,12W0 10,13W0",
        "關著也照缺口算的門（Knox Pass 模型門是 IsoThumpable）：關著＝0")
    local marks0 = I.MAX_MARKS
    I.MAX_MARKS = 2
    r = I.check(11, 11, 0).rooms[1]
    check(r.doorCount == 3 and #r.doors == 8 and #r.gaps == 6 and r.gapCount == 5,
        "門與缺牆各自最多 MAX_MARKS 筆，數量照實數")
    I.MAX_MARKS = marks0

    T.section("室內檢查：門關著、紀錄卻是缺口（玩家 2026-10-22 回報；使用者同日同意由伺服器重算）")
    -- x, y, z 三個一組的清單換成排序後的字串
    local function triples(list)
        local out = {}
        for i = 1, #list, 3 do out[#out + 1] = list[i] .. "," .. list[i + 1] .. "," .. list[i + 2] end
        return sorted(out)
    end
    local function printed(fragment)
        for _, line in ipairs(T.prints) do
            if string.find(line, fragment, 1, true) then return true end
        end
        return false
    end
    fresh()
    box(10, 10, 13, 13)
    roof(10, 10, 13, 13)
    for y = 11, 13 do
        wall(10, y, WALL_W, false)                    -- 紀錄停在門開著的時候（原版右鍵關門不通知引擎）
        door(10, y, false, false)
        W.props[k3(10, y, 0)] = { cutW = true }      -- 門片現在關著：格子有西牆的屬性
    end
    wall(12, 10, WALL_N, false)
    door(12, 10, true, false, "IsoThumpable")         -- 關著也沒有牆屬性的門（Knox Pass 閘門、兩層樓的門）
    local skip, fix
    res, skip, fix = I.check(11, 11, 0)
    r = res.rooms[1]
    check(r.verdict == "OPEN" and doors(r) == "10,11W2 10,12W2 10,13W2 12,10N0"
        and triples(fix or {}) == "10,11,0 10,12,0 10,13,0" and #W.recalc == 0 and res.fixed == nil,
        "check 只讀：紀錄過期的門片標 2、要重算的格子另外回；關著也不算牆的門標 0、不重算")
    W.prev = 18   -- 上一次排工作留下的位元剛好等於這幾格該有的：沒先歸 0 就排不進去
    local carl = T.player({ name = "carl", x = 11.5, y = 11.5 })
    res = T.cmd(carl, "indoor", { x = 11, y = 11, z = 0 })
    check(res.ok and res.verdict == "OPEN" and res.fixed == 3 and sorted(W.recalc) == "10,11,0 10,12,0 10,13,0"
        and bit(fl(10, 12, 0), WALL_W) and printed("indoor: recalculated 3 door tile(s)"),
        "查詢：回覆照查的當下、帶 fixed＝3，三格請引擎重算（先把 previousFlags 歸 0），記一行 log")
    T.advance(1000)
    W.recalc = {}
    res = T.cmd(carl, "indoor", { x = 11, y = 11, z = 0 })
    check(res.ok and res.fixed == nil and #W.recalc == 0 and doors(res.rooms[1]) == "12,10N0",
        "再查：紀錄對上了不再重算；只剩關著也不算牆的門")
    fresh()
    box(10, 10, 13, 13)
    roof(10, 10, 13, 13)
    door(10, 11, false, true)
    W.props[k3(10, 11, 0)] = { cutW = false }        -- 門開著、紀錄還是牆（另一個方向，不修）
    T.advance(1000)
    res = T.cmd(carl, "indoor", { x = 11, y = 11, z = 0 })
    check(res.ok and res.verdict == "ROOM" and res.fixed == nil and #W.recalc == 0,
        "門開著、紀錄還是牆：房間照樣算室內，不重算任何格子")
    fresh()
    box(10, 10, 13, 13)
    roof(10, 10, 13, 13)
    for y = 11, 13 do
        wall(10, y, WALL_W, false)
        door(10, y, false, false)
        W.props[k3(10, y, 0)] = { cutW = true }
    end
    I.MAX_MARKS = 2
    res, skip, fix = I.check(11, 11, 0)
    check(#(fix or {}) == 6, "每次查詢最多比對 MAX_MARKS 扇關著的門")
    I.MAX_MARKS = marks0

    T.section("室內檢查：西牆那格有柱子（玩家 2026-10-19 回報「要敲掉木柱才會正常室內」）")
    fresh()
    box(10, 10, 13, 13)
    roof(10, 10, 13, 13)
    for y = 10, 13 do westWall(10, y) end
    pillar(10, 11, false)
    local corners
    res, corners = I.check(11, 11, 0)
    r = res.rooms[1]
    check(not bit(fl(10, 11, 0), WALL_W) and r.verdict == "OPEN" and r.gapCount == 1 and r.pillarCount == 1
        and pillars(r) == "10,11W0" and gaps(r) == "" and #corners == 0,
        "西牆那格有玩家自己蓋的柱子：遊戲不算那面牆，列成有柱子的牆（不叫你補牆），伺服器不動玩家的柱子")
    pillar(10, 12, true)
    res, corners = I.check(11, 11, 0)
    r = res.rooms[1]
    check(pillars(r) == "10,11W0 10,12W1" and table.concat(corners, ",") == "10,12,0" and res.corners == nil,
        "蓋牆時自動補的牆角：標成 1，另外回給查詢交給佇列拆（不放進回覆）")
    pillar(10, 11, true)
    res, corners = I.check(11, 11, 0)
    check(pillars(res.rooms[1]) == "10,11W0 10,12W1" and table.concat(corners, ",") == "10,12,0",
        "同一格有玩家的柱子又有自動牆角：照玩家的柱子列（只拆牆角救不回）")
    fresh()
    box(10, 10, 13, 13)
    roof(10, 10, 13, 13)
    wall(10, 11, WALL_W, false)
    pillar(10, 11, true)
    wall(12, 10, WALL_N, false)
    westWall(12, 10)
    pillar(12, 10, true)
    res, corners = I.check(11, 11, 0)
    r = res.rooms[1]
    check(gaps(r) == "10,11W 12,10N" and r.pillarCount == 0 and #corners == 0,
        "那格沒有真的西牆只有柱子、或缺口在北邊（柱子只擋西牆）：照缺牆列")

    T.section("室內檢查：自動補的牆角由伺服器拆（使用者 2026-10-19 裁定）")
    fresh()
    box(10, 10, 13, 13)
    roof(10, 10, 13, 13)
    for y = 10, 13 do westWall(10, y) end
    pillar(10, 11, false)
    pillar(10, 12, true)
    local bob = T.player({ name = "bob", x = 11.5, y = 11.5 })
    res = T.cmd(bob, "indoor", { x = 11, y = 11, z = 0 })
    check(res ~= nil and res.ok and #W.removed == 0 and res.corners == nil,
        "查詢當下不拆、回覆裡沒有要拆的格子")
    T.tick(1)
    check(#W.removed == 1 and W.removed[1] == k3(10, 12, 0) and bit(fl(10, 12, 0), WALL_W) and #W.objs[k3(10, 11, 0)] == 1,
        "下一個 tick 拆掉自動牆角，那格的西牆算回來；玩家自己蓋的柱子不動")
    T.advance(1000)
    r = T.cmd(bob, "indoor", { x = 11, y = 11, z = 0 }).rooms[1]
    check(pillars(r) == "10,11W0" and r.gapCount == 1, "再查：只剩玩家的柱子那格")
    check(I.dropCorners(getCell():getGridSquare(10, 11, 0)) == 0 and #W.objs[k3(10, 11, 0)] == 1,
        "直接叫 dropCorners：玩家的柱子不拆")

    fresh()
    box(10, 10, 13, 13)
    roof(10, 10, 13, 13)
    for y = 10, 13 do
        if y ~= 12 then westWall(10, y) end
    end
    wall(10, 12, WALL_W, false)
    pillar(10, 12, true)       -- 屋外那面北牆蓋好時，這格還沒有牆：遊戲在這格補了牆角
    westWall(10, 12)           -- 之後在這格補西牆：有柱子，遊戲照樣不算
    check(not bit(fl(10, 12, 0), WALL_W), "（前提）補了西牆、遊戲還是不算")
    local before = #cornerCalls
    buildUtil.checkCorner(10, 12, 0, false, {}, {})
    check(#cornerCalls == before + 1 and cornerCalls[#cornerCalls] == "10,12,0W" and #W.removed == 0,
        "開服後原版 checkCorner 被包起來：照樣呼叫原版，當下不拆")
    T.tick(1)
    check(#W.removed == 1 and bit(fl(10, 12, 0), WALL_W) and I.check(11, 11, 0).verdict == "ROOM",
        "下一個 tick 拆掉那格的自動牆角：西牆算回來，整間算室內")
    buildUtil.checkCorner(11, 10, 0, true, {}, {})
    T.tick(1)
    check(#W.removed == 1, "蓋在沒有柱子的格子：不拆任何東西")
    I.install()
    before = #cornerCalls
    buildUtil.checkCorner(11, 10, 0, true, {}, {})
    check(#cornerCalls == before + 1, "再呼叫一次 install：不重複包（原版只被呼叫一次）")

    T.section("室內檢查：同一棟每一層（使用者 2026-10-15：「每一層都分析」）")
    fresh()
    box(10, 10, 13, 13)
    roof(10, 10, 13, 13)          -- 1 樓的屋頂＝2 樓的地板
    box(10, 10, 13, 13, 1)        -- 2 樓的牆
    roof(10, 10, 13, 13, 1)       -- 2 樓的屋頂
    res = I.check(11, 11, 0)
    check(#res.rooms == 2 and res.rooms[1].z == 0 and res.rooms[1].verdict == "ROOM" and res.rooms[2].z == 1
        and res.rooms[2].verdict == "ROOM" and res.rooms[2].size == 16 and #res.levels == 2 and res.levels[2].z == 1
        and runs(res.levels[2]) == "10,10,4 10,11,4 10,12,4 10,13,4" and res.minZ == 0 and res.maxZ == 1,
        "兩層樓、站在 1 樓查：往上沿樓板找到 2 樓那間，兩層各回範圍")
    unroof(12, 12, 1)
    res = I.check(11, 11, 0)
    check(res.verdict == "ROOM" and res.rooms[2].z == 1 and res.rooms[2].verdict == "NEED_ROOF"
        and holes(res.rooms[2]) == "12,12", "2 樓缺一格屋頂：1 樓照樣算室內，2 樓那間標出缺的那格")
    res = I.check(11, 11, 1)
    check(res.verdict == "NEED_ROOF" and res.rooms[1].z == 1 and res.rooms[2] ~= nil and res.rooms[2].z == 0
        and res.rooms[2].verdict == "ROOM", "站在 2 樓查：先分析 2 樓，再往下找到 1 樓")
    fresh()
    box(10, 10, 13, 13)
    roof(10, 10, 13, 13)
    box(10, 10, 13, 13, 1)        -- 屋頂平台圍了欄杆，上面沒再蓋
    res = I.check(11, 11, 0)
    check(#res.rooms == 1 and #res.levels == 1, "屋頂平台圍了欄杆、上面沒屋頂：不算一層，不列出來")

    T.section("室內檢查：上限")
    local limit, marks = I.LIMIT, I.MAX_MARKS
    I.LIMIT = 10
    res = I.check(11, 11, 0)
    check(res.verdict == "ROOM" and res.partial == true, "走到上限：標 partial，封閉的房間照引擎的數字判定")
    I.LIMIT = limit
    fresh()
    box(10, 10, 13, 13)
    roof(10, 10, 13, 13)
    unroof(10, 11)
    unroof(11, 11)
    unroof(12, 11)
    I.MAX_MARKS = 2
    r = I.check(10, 13, 0).rooms[1]
    check(r.verdict == "NEED_ROOF" and r.holeCount == 3 and #r.holes == 4, "清單最多 MAX_MARKS 筆，數量照實數")
    I.MAX_MARKS = marks

    T.section("室內檢查：查詢指令")
    fresh()
    box(10, 10, 13, 13)
    roof(10, 10, 13, 13)
    local alice = T.player({ name = "alice", x = 11.5, y = 11.5 })
    res = T.cmd(alice, "indoor", { x = 11, y = 11, z = 0 })
    check(res ~= nil and res.ok and res.verdict == "ROOM" and res.rooms[1].size == 16, "站在屋裡查：回結果")
    check(T.cmd(alice, "indoor", { x = 11, y = 11, z = 0 }) == nil, "1 秒內再查：冷卻中直接丟、不回覆")
    T.advance(1000)
    res = T.cmd(alice, "indoor", { x = 11 + MSH.LIMIT.INDOOR_REACH + 1, y = 11, z = 0 })
    check(res ~= nil and res.code == "TOO_FAR", "超過 INDOOR_REACH 格：TOO_FAR，不掃")
    T.advance(1000)
    check(T.cmd(alice, "indoor", { x = 11 + MSH.LIMIT.INDOOR_REACH, y = 11, z = 0 }).ok, "剛好 INDOOR_REACH 格：照查")
    T.advance(1000)
    check(T.cmd(alice, "indoor", { x = 11, y = 11, z = 32 }).code == "BAD_ARGS", "z 超出 -32..31：BAD_ARGS")
    T.advance(1000)
    check(T.cmd(alice, "indoor", { x = 11.5, y = 11, z = 0 }).code == "BAD_ARGS", "座標不是整數：BAD_ARGS")
    T.advance(1000)
    check(T.cmd(alice, "indoor", { x = 11, y = 11 }).code == "BAD_ARGS", "缺 z：BAD_ARGS")

    getCell, IsoRegions = saved.getCell, saved.IsoRegions
    IsoFlagType, IsoObjectType, buildUtil = saved.IsoFlagType, saved.IsoObjectType, saved.buildUtil

    -- ===== 客戶端面板 =====
    local G = { "MinidoracatUI", "ISPanel", "ISButton", "getCore", "getTextManager", "UIFont", "getText", "IsoSprite",
        "HaloTextHelper", "ISWorldObjectContextMenu" }
    local savedG = {}
    for _, k in ipairs(G) do savedG[k] = _G[k] end
    getText = function(k, ...)
        local a = { ... }
        return #a == 0 and k or (k .. "|" .. table.concat(a, ","))
    end
    -- 牆影：面板第一次開時建貼圖（之後 tintWorld 換掉 IsoSprite 也不影響），記「貼圖@x,y,z/透明度」與最後一次的顏色
    local ghosts, ghostColor, quiet = {}, nil, false   -- quiet：量配置時不記（記錄本身會配置字串）
    IsoSprite = { new = function()
        local s = {}
        function s:LoadSingleTexture(path) self.tex = path end
        function s:RenderGhostTileColor(x, y, z, r, g, b, a)
            if quiet then return end
            ghosts[#ghosts + 1] = self.tex .. "@" .. x .. "," .. y .. "," .. z .. "/" .. a
            ghostColor = r .. "/" .. g .. "/" .. b
        end
        return s
    end }
    local halo = {}
    HaloTextHelper = {
        addGoodText = function(_, t) halo[#halo + 1] = "good:" .. t end,
        addBadText = function(_, t) halo[#halo + 1] = "bad:" .. t end,
    }
    local C = T.bootClient()
    local P, Cl = C.IndoorPanel, C.Client
    local me = T.player({ name = "alice", x = 11.5, y = 11.5 })
    local function has(event, fn)
        for _, f in ipairs(T.handlers[event] or {}) do if f == fn then return true end end
        return false
    end
    local function hooked()
        return has("OnTick", P.fnTick) or has("OnObjectAdded", P.fnObject) or has("OnObjectAboutToBeRemoved", P.fnObject)
            or has("RenderOpaqueObjectsInWorld", P.fnRender)
    end
    local function sends()
        local n, last = 0, nil
        for _, s in ipairs(T.clientSent) do
            if s.command == "indoor" then n, last = n + 1, s.args end
        end
        return n, last
    end
    local function reply(fields)
        local _, a = sends()
        fields.command, fields.requestId = "indoor", a.requestId
        if fields.ok == nil then fields.ok = true end
        Cl.onServerCommand(C.MODULE, "result", fields)
    end
    local function obj(x, y, z, class)
        local sq = { getX = function() return x end, getY = function() return y end, getZ = function() return z or 0 end }
        return { __class = class or "IsoObject", getSquare = function() return sq end }
    end
    local RUNS44 = { 10, 10, 4, 10, 11, 4, 10, 12, 4, 10, 13, 4 }
    local ROOM = { verdict = "ROOM", x = 11, y = 11, z = 0, minX = 10, minY = 10, minZ = 0, maxX = 13, maxY = 13, maxZ = 0,
        partial = false, levels = { { z = 0, runs = RUNS44 } },
        rooms = { { verdict = "ROOM", z = 0, x = 11, y = 11, size = 16, roofs = 16, walls = 16, gaps = {}, gapCount = 0,
            holes = {}, holeCount = 0 } } }
    -- 伺服器剛請遊戲重算兩格紀錄過期的門（玩家 2026-10-22 回報）：這筆是重算前的樣子，另有一扇關著也不算牆的門
    local STALE = { verdict = "OPEN", x = 11, y = 11, z = 0, minX = 10, minY = 10, minZ = 0, maxX = 13, maxY = 13, maxZ = 0,
        partial = false, levels = { { z = 0, runs = RUNS44 } }, fixed = 2,
        rooms = { { verdict = "OPEN", z = 0, x = 11, y = 11, size = 16, roofs = 16, walls = 13, gapCount = 3, doorCount = 3,
            holeCount = 0, gaps = {}, holes = {}, doors = { 10, 11, 2, 2, 10, 12, 2, 2, 13, 10, 1, 0 } } } }

    T.section("室內檢查面板：關著時零成本（使用者 2026-10-15：「平常不用一直掃」）")
    check(not hooked(), "沒開面板：OnTick、物件增減、畫牆影的事件都沒掛")
    T.fire("OnObjectAdded", obj(11, 11))
    T.tick(30)
    check(sends() == 0, "沒開面板：附近蓋東西、時間過去都不送查詢")

    T.section("室內檢查面板：框架缺席時用頭上文字回答，查完就收")
    check(P.open({}) ~= nil and hooked(), "開（框架缺席）：一樣掛事件、送查詢")
    local n, a = sends()
    check(n == 1 and a.x == 11 and a.y == 11 and a.z == 0, "沒給格子：查站的那格（取整）")
    reply(ROOM)
    check(halo[#halo] == "good:IGUI_MSH_Indoor_Head_ROOM" and P.model == nil and not hooked(),
        "回覆到了：頭上說結論（算室內用好的顏色），事件拿掉")
    P.open({})
    local halos = #halo
    reply(STALE)
    check(#halo == halos and P.model ~= nil and P.model.want and hooked(),
        "回覆帶 fixed（伺服器剛請遊戲重算）：先不說結論，記著要再查")
    T.advance(P.GAP_MS)
    T.tick(1)
    n = sends()
    reply(ROOM)
    check(n == 3 and halo[#halo] == "good:IGUI_MSH_Indoor_Head_ROOM" and P.model == nil and not hooked(),
        "過了冷卻自己再查一次，那次的結論寫在頭上，事件拿掉")

    T.section("室內檢查面板：節流（同時一筆、回覆後滿 GAP_MS、物件增減等 SETTLE_MS）")
    local function class(base)
        local c = {}
        c.__index = c
        if base then setmetatable(c, { __index = base }) end
        function c:derive() return class(self) end
        return c
    end
    local Base = class()
    function Base:new(x, y, w, h)
        return setmetatable({ x = x or 0, y = y or 0, width = w or 60, height = h or 20, visible = true }, self)
    end
    for _, k in ipairs({ "initialise", "addChild", "bringToTop", "drawText", "addToUIManager", "removeFromUIManager",
        "fitWidth" }) do
        Base[k] = function() end
    end
    function Base:setVisible(b) self.visible = b end
    function Base:getIsVisible() return self.visible end
    function Base:setX(v) self.x = v end
    function Base:setY(v) self.y = v end
    function Base:getX() return self.x end
    function Base:getY() return self.y end
    function Base:setWidth(v) self.width = v end
    function Base:setHeight(v) self.height = v end
    function Base:contentTop() return 24 end
    function Base:close()
        self.visible = false
        if self.onClose then self.onClose(self) end
    end
    ISPanel = class(Base)
    ISButton = { updateTooltip = function() end }
    UIFont = { Small = "Small", Medium = "Medium" }
    getTextManager = function()
        return { getFontHeight = function() return 16 end, MeasureStringX = function(_, _, s) return #s * 7 end }
    end
    local function col(r) return { r = r, g = 0, b = 0, a = 1 } end
    local colors = { text = col(0.1), textMuted = col(0.2), errorText = col(0.5), hover = col(0.6), selected = col(0.7) }
    local function make(o)
        local e = Base.new(Base, o.x, o.y, o.width, o.height or 20)
        for k, x in pairs(o) do e[k] = x end
        return e
    end
    local function vlist(o)
        local l = make(o)
        l.items, l.pool = {}, {}
        function l:setItems(items)
            self.items = items
            for i, it in ipairs(items) do
                local cell = self.pool[i] or o.createCell(self)
                self.pool[i], cell.width = cell, self.width
                o.bindCell(self, cell, it, i)
            end
        end
        function l:setSelectedIndex(i) self.sel = i end
        function l:isSelected(i) return self.sel == i end
        function l:resize(w, h) self.width, self.height = w, h end
        return l
    end
    MinidoracatUI = { v1 = { API_MAJOR = 1, API_REVISION = 19,
        CAPABILITIES = { window = true, controls = true, virtualList = true, textWrap = true },
        Theme = { defaultPalette = function() return {} end, create = function() return { colors = colors } end },
        Window = { new = function(o) return make(o) end },
        Button = { new = function(o) return make(o) end },
        Checkbox = { new = function(o) return make(o) end },
        VirtualList = { new = vlist },
        Text = { wrap = function(s) return { s } end, fit = function(s) return s end },
        Icons = { draw = function() return true end },
    } }
    Cl._theme = nil
    local tw = T.tintWorld()   -- 地板染色的假世界（也換掉 getCore 與鏡頭）
    local base = sends()
    local m = P.open({})
    local v = m and m.view
    check(v ~= nil and hooked() and sends() == base + 1, "開（有框架）：建窗、掛事件、馬上送一筆")
    local function lineOf(text)
        for _, l in ipairs(v.lines) do if l.text == text then return l end end
        return nil
    end
    check(lineOf("IGUI_MSH_Indoor_Checking") ~= nil, "等回覆時寫「檢查中...」")
    P.recheck(m)
    T.tick(5)
    check(sends() == base + 1, "等回覆時再按〔重新檢查〕：不送第二筆，記著")
    reply(ROOM)
    local head = lineOf("IGUI_MSH_Indoor_Head_ROOM")
    check(head ~= nil and head.token == "text" and head.icon == "check" and lineOf("IGUI_MSH_Indoor_Checking") ~= nil,
        "回覆到了：寫結論（打勾）；記著的那次還要查")
    T.tick(10)
    check(sends() == base + 1, "回覆後 1 秒內：不送（伺服器冷卻 1 秒，間隔從回覆算）")
    T.tick(2)
    check(sends() == base + 2, "回覆後滿 GAP_MS：送記著的那一次")
    reply(ROOM)
    T.advance(P.GAP_MS)
    P.onObject(obj(30, 30))
    P.onObject(obj(12, 12, -1))
    P.onObject(obj(12, 12, 0, "IsoWorldInventoryObject"))
    T.tick(10)
    check(sends() == base + 2, "檢查範圍外（外框外超過 NEAR 格）、下面一層、地上的物品：不重查")
    P.onObject(obj(13 + P.NEAR, 12, 1))
    T.tick(6)
    check(sends() == base + 2 and m.want, "範圍附近（樓上的屋頂也算）有物件增減：先等 SETTLE_MS")
    T.tick(2)
    check(sends() == base + 3, "等滿 SETTLE_MS：送一筆")
    reply(ROOM)

    T.section("室內檢查面板：問題列與地上標示")
    -- 缺牆故意從那段中間那條列起（併段要先往回找起點）；屋簷那間帶幾條缺牆（不該列出來）
    local OPEN = { verdict = "OPEN", x = 11, y = 11, z = 0, minX = 9, minY = 9, minZ = 0, maxX = 14, maxY = 14, maxZ = 0,
        partial = false, levels = { { z = 0, runs = { 9, 9, 6, 9, 10, 6, 9, 11, 6, 9, 12, 6, 9, 13, 6, 9, 14, 6 } } },
        rooms = { { verdict = "OPEN", z = 0, x = 11, y = 11, size = 16, roofs = 14, walls = 14, gapCount = 2, holeCount = 2,
            gaps = { 10, 12, 2, 10, 11, 2 }, holes = { 12, 12, 12, 13 } },
            { verdict = "OPEN", z = 0, x = 9, y = 9, size = 20, roofs = 20, walls = 16, gapCount = 24, holeCount = 0,
                gaps = { 9, 9, 1, 10, 9, 1, 11, 9, 1 }, holes = {} } } }
    T.advance(P.GAP_MS)
    P.recheck(m)
    T.tick(1)
    reply(OPEN)
    check(#m.issues == 2 and m.issues[1].kind == "gap" and m.issues[1].n == 2 and m.issues[1].dist == 1
        and m.issues[2].kind == "hole" and m.issues[2].n == 2,
        "缺牆併成一段（同一條牆線相連的 2 格）、缺屋頂併成一塊；近的在前")
    check(lineOf("IGUI_MSH_Indoor_Head_OPEN").token == "errorText" and lineOf("IGUI_MSH_Indoor_RoomLine|16,14,16") ~= nil,
        "結論：牆有缺口（錯誤色）、這個房間 16 格屋頂 14/16")
    local cell = v.issues.pool[1]
    check(cell.title == "IGUI_MSH_Indoor_Gap|2" and cell.right == "IGUI_MSH_Indoor_Here"
        and cell.sub == "IGUI_MSH_Indoor_GapFix", "缺牆那列：格數、就在旁邊、修法")
    local rcell = v.rooms.pool[1]
    check(rcell.title == "IGUI_MSH_Indoor_Eaves|20" and rcell.sub == "IGUI_MSH_Indoor_RoofOnly" and rcell.chevron,
        "同一個屋頂下：沒圍起來的邊多過有牆的邊，列成「屋簷下」")
    T.tick(1)
    local lit, col, alpha = tw.lit(0)
    check(col["12,12"] == "0.5/0/0" and col["12,13"] == "0.5/0/0" and col["11,11"] == "0/0/0"
        and alpha["11,11"] == P.AREA[1] and col["9,14"] == "0/0/0" and not lit["8,8"] and not lit["15,15"],
        "缺屋頂的兩格染紅（圖層 indoor），這一層這次檢查到的範圍壓暗一點（圖層 indoorArea）")
    ghosts = {}
    T.fire("RenderOpaqueObjectsInWorld", 0)
    check(#ghosts == 2 and ghosts[1] == P.GHOST_TEX[2] .. "@10,11,0/" .. P.GHOST and ghostColor == "1/0.12/0.12",
        "缺牆的兩條邊畫亮紅色的牆影（西邊用西邊的牆面貼圖）")
    P.select(m, 1)
    ghosts = {}
    T.fire("RenderOpaqueObjectsInWorld", 0)
    check(ghosts[1] == P.GHOST_TEX[2] .. "@10,11,0/" .. P.GHOST_SEL, "選中那一列：那一組標得較強")
    me.z = 1
    ghosts = {}
    T.fire("RenderOpaqueObjectsInWorld", 0)
    check(#ghosts == 0, "玩家在別層：不畫牆影（疊色不測深度，會蓋過樓上）")
    me.z = 0
    quiet = true
    P.render(0)   -- 先暖一次：選中那列後標示重算，第一個 tick 要把新的格子交給 FloorTint（只在變了的那一次配置）
    P.tick()
    collectgarbage("collect")
    collectgarbage("stop")
    local kb = collectgarbage("count")
    for _ = 1, 200 do
        P.render(0)
        P.tick()
    end
    local grown = collectgarbage("count") - kb
    collectgarbage("restart")
    quiet = false
    check(grown < 1, "每幀畫牆影、每 tick 沒事時不配置（200 次增加 " .. string.format("%.2f", grown) .. " KB）")
    P.setMarks(m, false)
    T.tick(1)
    ghosts = {}
    T.fire("RenderOpaqueObjectsInWorld", 0)
    check(next((tw.lit(0))) == nil and #ghosts == 0, "關掉「在地上標出位置」：染色與牆影都收掉")
    P.setMarks(m, true)
    P.pick(m, 2)
    check(m.cur == 2 and #m.issues == 0 and lineOf("IGUI_MSH_Indoor_Head_CANOPY") ~= nil
        and v.rooms.pool[1].title == "IGUI_MSH_Indoor_ThisRoom|16",
        "換看屋簷下那間：結論是屋簷下、不列缺口；清單裡原本那間寫「你查的那間」")

    T.section("室內檢查面板：同一棟每一層（使用者 2026-10-15）")
    local FLOORS = { verdict = "ROOM", x = 11, y = 11, z = 0, minX = 10, minY = 10, minZ = 0, maxX = 13, maxY = 13, maxZ = 1,
        partial = false, levels = { { z = 0, runs = RUNS44 }, { z = 1, runs = RUNS44 } },
        rooms = { { verdict = "ROOM", z = 0, x = 11, y = 11, size = 16, roofs = 16, walls = 0, gaps = {}, gapCount = 0,
            holes = {}, holeCount = 0 },
            { verdict = "NEED_ROOF", z = 1, x = 10, y = 10, size = 16, roofs = 15, walls = 0, gaps = {}, gapCount = 0,
                holes = { 12, 12 }, holeCount = 1 } } }
    T.advance(P.GAP_MS)
    P.recheck(m)
    T.tick(1)
    reply(FLOORS)
    check(m.cur == 2 and lineOf("IGUI_MSH_Indoor_OnFloor|2,IGUI_MSH_Indoor_RoomLine|16,15,16") ~= nil
        and v.rooms.pool[1].title == "IGUI_MSH_Indoor_OnFloor|1,IGUI_MSH_Indoor_ThisRoom|16",
        "結果有兩層：房間那一行、同一棟的其他房間前面寫第幾樓（還在看第 2 間：2 樓那間）")
    check(v.issues.pool[1].right == "IGUI_MSH_Indoor_Floor|2", "那間不在玩家這一層：問題列右邊寫第幾樓，不寫距離")
    T.tick(1)
    local lit1, col1 = tw.lit(1)
    check(col1["12,12"] == "0.5/0/0" and col1["10,10"] == "0/0/0" and next((tw.lit(0))) == nil,
        "標示跟著那間的樓層：2 樓的缺屋頂與範圍染在 2 樓，1 樓的收掉")
    P.pick(m, 1)
    T.tick(1)
    check(tw.lit(0)["10,10"] and next((tw.lit(1))) == nil, "換看 1 樓那間：範圍改染 1 樓")
    me.z = 1
    P.pick(m, 2)
    check(v.issues.pool[1].right == "IGUI_MSH_Indoor_Here", "玩家走上 2 樓：同一層的照樣寫距離")
    me.z = 0
    P.onObject(obj(12, 12, 2))
    check(m.want, "2 樓的屋頂（第 3 層的地板）有增減：照樣重查")
    m.want = false

    T.section("室內檢查面板：缺口上的門（使用者 2026-10-15：正式服開著的車庫門被列成缺牆）")
    local DOORS = { verdict = "OPEN", x = 11, y = 11, z = 0, minX = 10, minY = 10, minZ = 0, maxX = 13, maxY = 13, maxZ = 0,
        partial = false, levels = { { z = 0, runs = RUNS44 } },
        rooms = { { verdict = "OPEN", z = 0, x = 11, y = 11, size = 16, roofs = 16, walls = 12, gapCount = 4, doorCount = 4,
            holeCount = 0, gaps = {}, holes = {}, doors = { 10, 12, 2, 1, 10, 11, 2, 1, 10, 13, 2, 1, 13, 10, 1, 0 } } } }
    T.advance(P.GAP_MS)
    P.recheck(m)
    T.tick(1)
    reply(DOORS)
    check(m.cur == 1 and #m.issues == 2 and m.issues[1].kind == "door" and m.issues[1].open and m.issues[1].n == 3
        and m.issues[2].kind == "door" and not m.issues[2].open and m.issues[2].n == 1,
        "有門的缺口：開著的、關著的各自併段，不列成缺牆")
    check(v.issues.pool[1].title == "IGUI_MSH_Indoor_DoorOpen|3" and v.issues.pool[1].sub == "IGUI_MSH_Indoor_DoorOpenFix"
        and v.issues.pool[2].title == "IGUI_MSH_Indoor_DoorShut|1" and v.issues.pool[2].sub == "IGUI_MSH_Indoor_DoorShutFix",
        "門那列：開著的叫你關上再查，關著也不算牆的照實說，都不叫你補牆")
    ghosts = {}
    T.fire("RenderOpaqueObjectsInWorld", 0)
    check(#ghosts == 4, "有門的缺口一樣畫牆影")

    T.section("室內檢查面板：門關著、紀錄卻是缺口（玩家 2026-10-22 回報）")
    T.advance(P.GAP_MS)
    P.recheck(m)
    T.tick(1)
    local s0 = sends()
    reply(STALE)
    check(#m.issues == 2 and m.issues[1].stale and m.issues[1].n == 2 and m.issues[2].kind == "door"
        and not m.issues[2].open and not m.issues[2].stale, "紀錄過期的門、關著也不算牆的門各自併段")
    check(v.issues.pool[1].title == "IGUI_MSH_Indoor_DoorStale|2" and v.issues.pool[1].sub == "IGUI_MSH_Indoor_DoorStaleFix"
        and v.issues.pool[2].title == "IGUI_MSH_Indoor_DoorShut|1" and v.issues.pool[2].sub == "IGUI_MSH_Indoor_DoorShutFix",
        "紀錄過期那列說已經更正、稍後再查；不算牆那列說原因與做法")
    T.tick(5)
    check(m.want and sends() == s0 and lineOf("IGUI_MSH_Indoor_Checking") ~= nil, "冷卻內不送，寫「檢查中...」")
    T.advance(P.GAP_MS)
    T.tick(1)
    check(sends() == s0 + 1, "過了冷卻自己再查一次")
    reply(STALE)
    T.advance(P.GAP_MS)
    T.tick(1)
    check(not m.want and sends() == s0 + 1, "連著兩筆都帶 fixed（遊戲沒照算）：不再自動查")

    T.section("室內檢查面板：西牆那格有柱子（玩家 2026-10-19 回報）")
    local PILLARS = { verdict = "OPEN", x = 11, y = 11, z = 0, minX = 10, minY = 10, minZ = 0, maxX = 13, maxY = 13, maxZ = 0,
        partial = false, levels = { { z = 0, runs = RUNS44 } },
        rooms = { { verdict = "OPEN", z = 0, x = 11, y = 11, size = 16, roofs = 16, walls = 13, gapCount = 3, doorCount = 0,
            pillarCount = 3, holeCount = 0, gaps = {}, holes = {}, doors = {}, pillars = { 10, 12, 0, 10, 11, 0, 10, 13, 1 } } } }
    T.advance(P.GAP_MS)
    P.recheck(m)
    T.tick(1)
    reply(PILLARS)
    check(#m.issues == 2 and m.issues[1].kind == "pillar" and m.issues[1].n == 2 and m.issues[2].kind == "corner"
        and m.issues[2].n == 1, "有柱子的缺口：玩家的柱子、自動補的牆角各自併段，不列成缺牆")
    check(v.issues.pool[1].title == "IGUI_MSH_Indoor_Pillar|2" and v.issues.pool[1].sub == "IGUI_MSH_Indoor_PillarFix"
        and v.issues.pool[2].title == "IGUI_MSH_Indoor_Corner|1" and v.issues.pool[2].sub == "IGUI_MSH_Indoor_CornerFix",
        "柱子那列叫你拆柱子、牆角那列說已經拆掉，都不叫你補牆")
    ghosts = {}
    T.fire("RenderOpaqueObjectsInWorld", 0)
    check(#ghosts == 3 and ghosts[1] == P.GHOST_TEX[2] .. "@10,11,0/" .. P.GHOST, "有柱子的缺口一樣在西邊畫牆影")

    T.section("室內檢查面板：太遠、換查別格、關窗")
    T.advance(P.GAP_MS)
    me.x = 11.5 + C.LIMIT.INDOOR_REACH + 1
    local before = sends()
    P.recheck(m)
    T.tick(1)
    -- 假 getText 對沒有譯文的鍵回鍵本身，codeText 會退到 Code_Generic；譯文在 verify_mod 的鍵集檢查
    local far = lineOf("IGUI_MSH_Code_Generic|TOO_FAR")
    check(sends() == before and m.err == "TOO_FAR" and far ~= nil and far.token == "errorText",
        "離那格超過 INDOOR_REACH：不送，寫原因（錯誤色）")
    me.x = 11.5
    P.recheck(m)
    T.tick(1)
    check(sends() == before + 1 and m.busy, "走回來再按〔重新檢查〕：照送")
    P.open({ x = 20, y = 21, z = 0 })
    reply(ROOM)
    check(m.res == nil and m.x == 20 and m.y == 21 and m.want, "等回覆時換查別格：舊的那筆回來時丟掉，換查新的")
    T.advance(P.GAP_MS)
    T.tick(1)
    local _, last = sends()
    check(last.x == 20 and last.y == 21, "間隔滿了送新的那格")
    reply(ROOM)
    T.tick(1)
    check(next((tw.lit(0))) ~= nil, "新的那格回來：這一層的範圍又染上")
    local opened = {}
    C.ManagerWindow = { open = function(o) opened[#opened + 1] = o end }
    m.fromManager = true
    v.win:close()
    check(P.model == nil and not hooked() and next((tw.lit(0))) == nil and #opened == 1,
        "關窗：事件拿掉、地上的標示收掉；從管理視窗開的開回管理視窗")
    local after = sends()
    T.fire("OnObjectAdded", obj(11, 11))
    T.tick(30)
    check(sends() == after, "關窗後：附近蓋東西、時間過去都不再送")

    T.section("室內檢查面板：地面右鍵")
    local added = {}
    local ctx = { addOption = function(_, name, target, fn, x, y, z) added[#added + 1] = { name = name, fn = fn, x = x, y = y, z = z } end }
    ISWorldObjectContextMenu = { fetchVars = { clickedSquare = obj(14, 15, 1):getSquare() } }
    P.onWorldMenu(0, ctx, {}, false)
    check(#added == 1 and added[1].name == "IGUI_MSH_Indoor_Menu" and added[1].x == 14 and added[1].y == 15
        and added[1].z == 1, "右鍵：加「檢查這裡算不算室內」，查點到的那格")
    P.onWorldMenu(1, ctx, {}, false)
    P.onWorldMenu(0, ctx, {}, true)
    check(#added == 1, "分割畫面次玩家、test 模式：不加")
    ISWorldObjectContextMenu = { fetchVars = {} }
    P.onWorldMenu(0, ctx, { obj(3, 4, 0) }, false)
    check(#added == 2 and added[2].x == 3 and added[2].y == 4, "沒有 clickedSquare：用第一個物件的格子")

    tw.restore()
    for _, k in ipairs(G) do _G[k] = savedG[k] end
    C.ManagerWindow = nil
end
