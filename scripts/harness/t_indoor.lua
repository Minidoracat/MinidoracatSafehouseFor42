-- 室內檢查（使用者 2026-10-15；server Indoor.lua、client IndoorPanel.lua）：伺服器照引擎的 region 規則判定與找缺口
-- （和 E2E indoor-mp 同一組房子：蓋好、缺屋頂、缺牆、缺牆又缺屋頂、角落缺屋頂、兩間、室外、地圖房間、地下），
-- 查詢指令的距離與參數檢查；客戶端面板只在開著時掛事件、送查詢的節流、地上標示。
-- 假 IsoRegions 與 getCell 只在本情境用到，放在本檔、結束時還原全域。
return function(T)
    local check = T.check
    local WALL_N, WALL_W, FLOOR = 1, 2, 16
    local saved = { getCell = getCell, IsoRegions = IsoRegions }

    -- 假 IsoRegions（getSquareFlags／getIsoWorldRegion／getChunkRegion）：flags["x,y,z"]＝位元和，沒有＝-1（沒資料）。
    -- region 照引擎：同一層不穿牆相連的格子；有一條走得過去的邊通到沒資料的格子＝不封閉；屋頂數＝正上方一層有地板的格數
    local W = { flags = {}, map = {}, regions = nil }
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
    local function roof(x0, y0, x1, y1) ground(x0, y0, x1, y1, 1) end
    local function unroof(x, y)
        W.flags[k3(x, y, 1)] = nil
        W.regions = nil
    end
    local function wall(x, y, b, on) setBit(x, y, 0, b, on ~= false) end
    -- 圍一圈牆：裡面是 x0..x1, y0..y1
    local function box(x0, y0, x1, y1)
        for x = x0, x1 do
            wall(x, y0, WALL_N)
            wall(x, y1 + 1, WALL_N)
        end
        for y = y0, y1 do
            wall(x0, y, WALL_W)
            wall(x1 + 1, y, WALL_W)
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
    }
    -- 伺服器的格子：只用到地圖房間（getRoom 不是 nil、不是 user-defined）
    getCell = function()
        return { getGridSquare = function(_, x, y, z)
            local inMap = W.map[k3(x, y, z)]
            return { getRoom = function() return inMap and {} or nil end, isUserDefinedRoom = function() return false end }
        end }
    end
    local function fresh()
        W.flags, W.map, W.regions = {}, {}, nil
        ground(0, 0, 40, 40, 0)
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

    -- ===== 客戶端面板 =====
    local G = { "MinidoracatUI", "ISPanel", "ISButton", "getCore", "getTextManager", "UIFont", "getText", "getSprite",
        "HaloTextHelper", "ISWorldObjectContextMenu" }
    local savedG = {}
    for _, k in ipairs(G) do savedG[k] = _G[k] end
    getText = function(k, ...)
        local a = { ... }
        return #a == 0 and k or (k .. "|" .. table.concat(a, ","))
    end
    local ghosts, quiet = {}, false   -- quiet：量配置時不記（記錄本身會配置字串）
    getSprite = function(name)
        return { RenderGhostTileColor = function(_, x, y, z, r, g, b, a)
            if not quiet then ghosts[#ghosts + 1] = name .. "@" .. x .. "," .. y .. "," .. z .. "/" .. a end
        end }
    end
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
    local ROOM = { verdict = "ROOM", x = 11, y = 11, z = 0, minX = 10, minY = 10, maxX = 13, maxY = 13, partial = false,
        rooms = { { verdict = "ROOM", x = 11, y = 11, size = 16, roofs = 16, walls = 16, gaps = {}, gapCount = 0, holes = {},
            holeCount = 0 } } }

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
    local m = P.open({})
    local v = m and m.view
    check(v ~= nil and hooked() and sends() == 2, "開（有框架）：建窗、掛事件、馬上送一筆")
    local function lineOf(text)
        for _, l in ipairs(v.lines) do if l.text == text then return l end end
        return nil
    end
    check(lineOf("IGUI_MSH_Indoor_Checking") ~= nil, "等回覆時寫「檢查中...」")
    P.recheck(m)
    T.tick(5)
    check(sends() == 2, "等回覆時再按〔重新檢查〕：不送第二筆，記著")
    reply(ROOM)
    local head = lineOf("IGUI_MSH_Indoor_Head_ROOM")
    check(head ~= nil and head.token == "text" and head.icon == "check" and lineOf("IGUI_MSH_Indoor_Checking") ~= nil,
        "回覆到了：寫結論（打勾）；記著的那次還要查")
    T.tick(10)
    check(sends() == 2, "回覆後 1 秒內：不送（伺服器冷卻 1 秒，間隔從回覆算）")
    T.tick(2)
    check(sends() == 3, "回覆後滿 GAP_MS：送記著的那一次")
    reply(ROOM)
    T.advance(P.GAP_MS)
    P.onObject(obj(30, 30))
    P.onObject(obj(12, 12, -1))
    P.onObject(obj(12, 12, 0, "IsoWorldInventoryObject"))
    T.tick(10)
    check(sends() == 3, "檢查範圍外（外框外超過 NEAR 格）、下面一層、地上的物品：不重查")
    P.onObject(obj(13 + P.NEAR, 12, 1))
    T.tick(6)
    check(sends() == 3 and m.want, "範圍附近（樓上的屋頂也算）有物件增減：先等 SETTLE_MS")
    T.tick(2)
    check(sends() == 4, "等滿 SETTLE_MS：送一筆")
    reply(ROOM)

    T.section("室內檢查面板：問題列與地上標示")
    -- 缺牆故意從那段中間那條列起（併段要先往回找起點）；屋簷那間帶幾條缺牆（不該列出來）
    local OPEN = { verdict = "OPEN", x = 11, y = 11, z = 0, minX = 10, minY = 10, maxX = 13, maxY = 13, partial = false,
        rooms = { { verdict = "OPEN", x = 11, y = 11, size = 16, roofs = 14, walls = 14, gapCount = 2, holeCount = 2,
            gaps = { 10, 12, 2, 10, 11, 2 }, holes = { 12, 12, 12, 13 } },
            { verdict = "OPEN", x = 9, y = 9, size = 20, roofs = 20, walls = 16, gapCount = 24, holeCount = 0,
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
    local lit = tw.lit(0)
    check(lit["12,12"] and lit["12,13"] and not lit["11,11"], "缺屋頂的兩格染色（FloorTint 圖層 indoor）")
    ghosts = {}
    T.fire("RenderOpaqueObjectsInWorld", 0)
    check(#ghosts == 2 and ghosts[1] == P.SPRITES[2] .. "@10,11,0/" .. P.GHOST, "缺牆的兩條邊畫牆影（西邊用西牆貼圖）")
    P.select(m, 1)
    ghosts = {}
    T.fire("RenderOpaqueObjectsInWorld", 0)
    check(ghosts[1] == P.SPRITES[2] .. "@10,11,0/" .. P.GHOST_SEL, "選中那一列：那一組標得較強")
    me.z = 1
    ghosts = {}
    T.fire("RenderOpaqueObjectsInWorld", 0)
    check(#ghosts == 0, "玩家在別層：不畫牆影（疊色不測深度，會蓋過樓上）")
    me.z = 0
    quiet = true
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
