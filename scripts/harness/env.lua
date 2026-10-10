--[[
假的 PZ 環境：載入**真正的** MOD Lua，讓情境檔斷言行為（scripts/smoke_harness.lua 逐一執行 t_*.lua）。
這是標準 Lua，不是 Kahlua：next／xpcall／table.sort 的誤用由 verify_mod.py 靜態掃描負責；
Lua 5.4 的 tostring(5.0) 是 "5.0"、Kahlua 是 "5"——情境斷言不要比對由浮點數組出的字串。

假物件只做 MOD 用到的方法，形狀照引擎（出處見各段註解）；新情境缺什麼就在這裡補，不在情境檔各自另做一份。
]]

local T = {}
T.MEDIA = "MOD/MinidoracatSafehouseFor42/Contents/mods/MinidoracatSafehouseFor42/42/media/lua"

-- ===== 結果統計 =====
T.failures, T.passes = 0, 0
function T.check(ok, label)
    if ok then
        T.passes = T.passes + 1
        io.write("  PASS  " .. label .. "\n")
    else
        T.failures = T.failures + 1
        io.write("  FAIL  " .. label .. "\n")
    end
    return ok
end
function T.section(title) io.write(title .. "\n") end

-- ===== 時間、模式、log =====
T.now = 1700000000000
function getTimestampMs() return T.now end
function T.advance(ms) T.now = T.now + ms end

T.mode = "server"
function isServer() return T.mode == "server" end
function isClient() return T.mode == "client" end

T.logs, T.prints = {}, {}
function writeLog(_, text) T.logs[#T.logs + 1] = text end
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    T.prints[#T.prints + 1] = table.concat(parts, " ")
    if T.verbose then io.write("    | " .. T.prints[#T.prints] .. "\n") end
end
function getText(key) return key end
function T.logged(fragment)
    for _, line in ipairs(T.logs) do
        if string.find(line, fragment, 1, true) then return true end
    end
    return false
end

-- ===== java 風格清單（size()/get(i) 0-based；add／remove／contains 照 ArrayList）=====
function T.javaList(items)
    items = items or {}
    local l = { _raw = items }
    function l:size() return #items end
    function l:get(i) return items[i + 1] end
    function l:add(v) items[#items + 1] = v return true end
    function l:contains(v)
        for _, x in ipairs(items) do if x == v then return true end end
        return false
    end
    function l:remove(v)
        for i, x in ipairs(items) do
            if x == v then table.remove(items, i) return true end
        end
        return false
    end
    function l:isEmpty() return #items == 0 end
    return l
end
ArrayList = { new = function() return T.javaList({}) end }

-- instanceof（LuaManager.java:2948-2952 是 Java isInstance，不經 __index）：假物件以 rawget 的 __class 判斷
function instanceof(obj, cls)
    return type(obj) == "table" and rawget(obj, "__class") == cls
end

-- ===== 事件 =====
T.handlers = {}
Events = setmetatable({}, {
    __index = function(_, name)
        return {
            Add = function(fn)
                local l = T.handlers[name] or {}
                l[#l + 1] = fn
                T.handlers[name] = l
            end,
            Remove = function(fn)
                local l = T.handlers[name] or {}
                for i, f in ipairs(l) do if f == fn then table.remove(l, i) break end end
            end,
        }
    end,
})
-- 引擎在 OnServerStarted 之前才建好網路層（GameServer.java:1509 udpEngine、:1533 觸發）：之前伺服器端碰連線記進 T.netEarly
function T.fire(name, ...)
    if name == "OnServerStarted" then T.netUp = true end
    local l = T.handlers[name] or {}
    local copy = {}
    for i, f in ipairs(l) do copy[i] = f end
    for _, fn in ipairs(copy) do fn(...) end
end

-- ===== Global ModData（GlobalModData.java；只做 getOrCreate／get／exists／remove）=====
T.gmd = {}
ModData = {
    getOrCreate = function(tag)
        if T.gmd[tag] == nil then T.gmd[tag] = {} end
        return T.gmd[tag]
    end,
    get = function(tag) return T.gmd[tag] end,
    exists = function(tag) return T.gmd[tag] ~= nil end,
    remove = function(tag) T.gmd[tag] = nil end,
}

-- 深複製（模擬存檔後重開：Global ModData 與檔案留著、Lua 物件全部重建）
function T.deepcopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[T.deepcopy(k)] = T.deepcopy(x) end
    return out
end

-- ===== 檔案（<cachedir>/Lua/ 下；getFileWriter 副檔名限制 LuaManager.java:1034，這裡不模擬）=====
T.files = {}          -- path → { lines }
T.failWrites = false
T.unreadable = {}     -- path → true：檔案存在但讀不開
function getFileWriter(path, createIfNull, append)
    if T.failWrites then return nil end
    local f = T.files[path]
    if f == nil or not append then
        f = { lines = {} }
        T.files[path] = f
    end
    return {
        writeln = function(_, s) f.lines[#f.lines + 1] = s end,
        write = function(_, s) f.lines[#f.lines + 1] = s end,
        close = function() end,
    }
end
function getFileReader(path, createIfNull)
    local f = T.files[path]
    if f == nil or T.unreadable[path] then return nil end
    local i = 0
    return {
        readLine = function() i = i + 1 return f.lines[i] end,
        close = function() end,
    }
end
function cacheFileExists(path) return T.files[path] ~= nil end

-- ===== 伺服器設定（ServerOptions.java；getOption 回字串）=====
T.DEFAULT_OPTIONS = {
    PlayerSafehouse = "false", AdminSafehouse = "false", SafeHouseRemovalTime = "0", War = "false",
    SafehouseAllowTrepass = "false", SafehouseAllowLoot = "false", SafehouseAllowFire = "false",
    DisableSafehouseWhenOwnerConnected = "false", AntiCheatSafeHouse = "3",
    SafehouseAllowRespawn = "false", AllowCoop = "false", SaveWorldEveryMinutes = "10",
    ChatStreams = "s,r,a,w,y,f,all", SafehousePreventsLootRespawn = "false",
    SledgehammerOnlyInSafehouse = "false", SafehouseDaySurvivedToClaim = "0",
}
function getServerOptions()
    return { getOption = function(_, name) return T.serverOptions[name] end }
end
function getServerName() return "servertest" end
T.steam = false
function getSteamModeActive() return T.steam end
-- 已載入的 MOD id（LuaManager.java:7458-7462 → ZomboidFileSystem.getModIDs :873）；opts.mods 覆寫，預設只有本 MOD
T.activeMods = { "MinidoracatSafehouseFor42" }
function getActivatedMods() return T.javaList(T.activeMods) end

-- ServerWorldDatabase.java:766-788（不含髒話過濾）
function isValidUserName(user)
    if type(user) ~= "string" then return false end
    local trimmed = string.gsub(string.gsub(user, "^%s+", ""), "%s+$", "")
    if trimmed == "" or string.find(user, "[;@%$,\\/%.'%?\"]") or #trimmed < 2 or #user > 32 then return false end
    if string.find(user, "%z") then return false end
    if trimmed == "admin" then return true end
    return string.sub(string.lower(trimmed), 1, 5) ~= "admin"
end

Capability = { CanSetupSafehouses = "CanSetupSafehouses" }

-- ===== 沙盒（SandboxOptions.java:572-582 set、279-285 toLua、683-685 saveServerLuaFile）=====
T.sbox = { values = {}, saveOk = true, saves = 0, sets = 0 }
function getSandboxOptions()
    return {
        set = function(_, name, value)
            T.sbox.values[name] = value
            T.sbox.sets = T.sbox.sets + 1
        end,
        toLua = function()
            for name, value in pairs(T.sbox.values) do
                local page, key = string.match(name, "^(.-)%.(.+)$")
                SandboxVars[page] = SandboxVars[page] or {}
                SandboxVars[page][key] = value
            end
        end,
        saveServerLuaFile = function()
            T.sbox.saves = T.sbox.saves + 1
            return T.sbox.saveOk
        end,
    }
end

-- 沙盒填回 Settings 定義的預設值（Settings 要先載入）
function T.resetSandbox()
    SandboxVars = { MinidoracatSafehouse = {} }
    T.sbox = { values = {}, saveOk = true, saves = 0, sets = 0 }
    for _, o in ipairs(MinidoracatSafehouse.Settings.OPTIONS) do
        SandboxVars.MinidoracatSafehouse[o.key] = o.default
    end
end
function T.sandbox(key, value) SandboxVars.MinidoracatSafehouse[key] = value end

-- ===== 物品與容器（ItemContainer.java：AddItem :462、contains :634、getFirstTypeRecurse :1551、Remove :2036）=====
T.failRemove = false   -- Remove 靜默失手（void、miss 不報錯）
function T.item(fullType)
    local it = { __class = "InventoryItem", fullType = fullType, container = nil, inner = nil }
    function it:getFullType() return self.fullType end
    function it:getType() return string.match(self.fullType, "%.(.+)$") end
    function it:getContainer() return self.container end
    function it:getInventory() return self.inner end   -- 只有背包類物品有
    return it
end
function T.container(kind)
    local c = { __class = "ItemContainer", kind = kind or "none", items = {} }
    function c:getType() return self.kind end
    function c:getItems() return T.javaList(self.items) end
    function c:contains(item)
        for _, x in ipairs(self.items) do if x == item then return true end end
        return false
    end
    function c:containsType(t)
        for _, x in ipairs(self.items) do if x:getType() == t or x:getFullType() == t then return true end end
        return false
    end
    function c:AddItem(v)
        local item = type(v) == "string" and T.item(v) or v
        self.items[#self.items + 1] = item
        item.container = self
        return item
    end
    function c:Remove(item)
        if T.failRemove then return end
        for i, x in ipairs(self.items) do
            if x == item then
                table.remove(self.items, i)
                item.container = nil
                return
            end
        end
    end
    -- 深度優先：先自己，再巢狀背包（ItemContainer.java:1551）
    function c:getFirstTypeRecurse(t)
        for _, x in ipairs(self.items) do
            if x:getFullType() == t or x:getType() == t then return x end
        end
        for _, x in ipairs(self.items) do
            if x.inner then
                local hit = x.inner:getFirstTypeRecurse(t)
                if hit then return hit end
            end
        end
        return nil
    end
    function c:getAllTypeRecurse(t)
        local out = T.javaList({})
        local function walk(cc)
            for _, x in ipairs(cc.items) do
                if x:getFullType() == t or x:getType() == t then out:add(x) end
                if x.inner then walk(x.inner) end
            end
        end
        walk(self)
        return out
    end
    return c
end
-- 伺服器改玩家背包後要自己同步給客戶端（LuaManager.java:12370、12418；原版伺服器用例 ISBuildUtil.lua:147-152）
T.itemSyncs = {}
function sendRemoveItemFromContainer(container, item)
    T.itemSyncs[#T.itemSyncs + 1] = { op = "remove", container = container, item = item }
end
function sendAddItemToContainer(container, item)
    T.itemSyncs[#T.itemSyncs + 1] = { op = "add", container = container, item = item }
end
-- 背包：本身是物品，裡面另有容器
function T.bag(fullType)
    local b = T.item(fullType or "Base.Bag_Schoolbag")
    b.inner = T.container("bag")
    return b
end

-- ===== 玩家（IsoPlayer）=====
T.online, T.outbox, T.broadcasts = {}, {}, {}
T.nextOnlineId = 0
function T.player(o)
    o = o or {}
    local p = {
        __class = "IsoPlayer",
        name = o.name or "alice", x = o.x or 0, y = o.y or 0, z = o.z or 0,
        sid = o.sid or 76561198000000000, admin = o.admin or false, dead = o.dead or false,
        num = o.num or 0, hours = o.hours or 1000, asleep = false,
    }
    if o.oid ~= nil then p.oid = o.oid else p.oid = T.nextOnlineId; T.nextOnlineId = T.nextOnlineId + 4 end
    p.inv = T.container("none")
    for _, t in ipairs(o.items or {}) do p.inv:AddItem(t) end
    function p:getUsername() return self.name end
    function p:getPlayerNum() return self.num end
    function p:getSteamID() return self.sid end
    function p:getOnlineID() return self.oid end
    function p:getX() return self.x end
    function p:getY() return self.y end
    function p:getZ() return self.z end
    function p:isDead() return self.dead end
    function p:getHoursSurvived() return self.hours end
    function p:getInventory() return self.inv end
    function p:isAsleep() return self.asleep end
    function p:getRole()
        local admin = self.admin
        return { hasCapability = function(_, cap) return admin and cap == Capability.CanSetupSafehouses end }
    end
    if not o.offline then T.online[#T.online + 1] = p end
    T.outbox[p.name] = T.outbox[p.name] or {}
    return p
end
function T.disconnect(p)
    for i, x in ipairs(T.online) do if x == p then table.remove(T.online, i) break end end
end
local function early(what)
    if T.mode ~= "server" or T.netUp then return false end
    T.netEarly[#T.netEarly + 1] = what
    return true
end
T.netEarly = {}
-- 開服前：引擎印 NPE（GameServer.getPlayers:3600 udpEngine 是 null）並回 nil（2026-10-11 migration-mp boot2）
function getOnlinePlayers()
    if early("getOnlinePlayers") then return nil end
    return T.javaList(T.online)
end
function getSpecificPlayer(i) return T.online[i + 1] end

-- 伺服器：sendServerCommand(player, module, command, args)；不帶 player＝廣播給全部客戶端
function sendServerCommand(a, b, c, d)
    if early("sendServerCommand") then return end
    if type(a) == "string" then
        T.broadcasts[#T.broadcasts + 1] = { module = a, command = b, args = c }
    else
        local box = T.outbox[a.name] or {}
        T.outbox[a.name] = box
        box[#box + 1] = { module = b, command = c, args = d }
    end
end
T.clientSent = {}
function sendClientCommand(player, module, command, args)
    T.clientSent[#T.clientSent + 1] = { player = player, module = module, command = command, args = args }
end

-- ===== 原生 SafeHouse（SafeHouse.java，42.21.0）=====
T.houses = {}
T.syncs = {}          -- kickUserFromSafehouse 觸發的 SafehouseSync 廣播
T.teleports = {}
T.failAdd = false     -- addSafeHouse 回 nil
T.noLocation = false  -- setLocation(null) 推不出 location
T.failHouseRemove = false
local function int32(v)
    v = v % 4294967296
    if v >= 2147483648 then v = v - 4294967296 end
    return v
end
function T.onlineId(x, y)
    local s = int32(x + y)
    local p = int32(s * int32(s + 1))
    local q = p / 2
    q = q >= 0 and math.floor(q) or math.ceil(q)
    return int32(q + x)
end
function T.house(x, y, w, h, owner)
    local hs = { __class = "SafeHouse", x = x, y = y, w = w, h = h, owner = owner, title = "Safehouse",
        players = T.javaList({}), created = T.now, location = "Muldraugh, KY" }
    if T.noLocation then hs.location = nil end
    hs.onlineId = T.onlineId(x, y)
    function hs:getX() return self.x end
    function hs:getY() return self.y end
    function hs:getW() return self.w end
    function hs:getH() return self.h end
    function hs:getOwner() return self.owner end
    -- setOwner 會把新 owner 從 players 移除（SafeHouse.java:660-662）
    function hs:setOwner(o) self.players:remove(o) self.owner = o end
    function hs:getPlayers() return self.players end
    function hs:addPlayer(u) if not self.players:contains(u) then self.players:add(u) end end
    function hs:removePlayer(u) self.players:remove(u) end
    function hs:getTitle() return self.title end
    function hs:setTitle(t) self.title = t end
    function hs:getDatetimeCreated() return self.created end
    function hs:getLocation() return self.location end
    function hs:getOnlineID() return self.onlineId end
    function hs:playerAllowed(u) return self.players:contains(u) or self.owner == u end
    return hs
end
SafeHouse = {
    getSafehouseList = function() return T.javaList(T.houses) end,
    -- 建構子把 owner 放進 players，接著 setOwner 又移掉（SafeHouse.java:68-85、581-590）
    addSafeHouse = function(x, y, w, h, owner)
        if T.failAdd then return nil end
        local hs = T.house(x, y, w, h, owner)
        T.houses[#T.houses + 1] = hs
        return hs
    end,
    removeSafeHouse = function(hs)
        if T.failHouseRemove then return end
        for i, x in ipairs(T.houses) do if x == hs then table.remove(T.houses, i) return end end
    end,
    -- 先移除名單、廣播；SafehouseAllowTrepass=false 時把站在屋內的那個人傳到 (x-1, y-1)（SafeHouse.java:832-850）
    kickUserFromSafehouse = function(hs, username)
        hs:removePlayer(username)
        if early("kickUserFromSafehouse") then error("NullPointerException: GameServer.udpEngine is null") end
        local roster = {}
        for _, u in ipairs(hs.players._raw) do roster[#roster + 1] = u end
        T.syncs[#T.syncs + 1] = { house = hs, owner = hs.owner, title = hs.title, players = roster }
        if T.serverOptions.SafehouseAllowTrepass == "false" then
            for _, p in ipairs(T.online) do
                if p.name == username and math.floor(p.x) >= hs.x and math.floor(p.x) < hs.x + hs.w
                    and math.floor(p.y) >= hs.y and math.floor(p.y) < hs.y + hs.h then
                    p.x, p.y = hs.x - 1, hs.y - 1
                    T.teleports[#T.teleports + 1] = { name = username, house = hs }
                end
            end
        end
    end,
    getSafeHouse = function(x, y, w, h)
        for _, hs in ipairs(T.houses) do
            if hs.x == x and hs.y == y and hs.w == w and hs.h == h then return hs end
        end
        return nil
    end,
    getOnlineID = function(x, y) return T.onlineId(x, y) end,
    -- SafeHouse.java:852-859
    hasNotSurvivedEnoughToClaim = function(p)
        if p.admin then return false end
        local days = tonumber(T.serverOptions.SafehouseDaySurvivedToClaim) or 0
        return days > 0 and p.hours < days * 24
    end,
}

-- ===== 陣營（characters/Faction.java，42.21.0）=====
-- 每次 T.faction 都是新物件：同名重建時物件不同（照真的 Faction；VM factionRefs 靠這點判斷同進程重建）
T.factions = {}
function T.faction(name, owner, members)
    local f = { __class = "Faction", name = name, owner = owner, players = T.javaList(members or {}) }
    function f:getName() return self.name end                     -- :273
    function f:setName(n) self.name = n end
    function f:getOwner() return self.owner end                   -- :281
    function f:isOwner(u) return self.owner == u end              -- :150
    function f:isMember(u) return self.players:contains(u) end    -- :154
    function f:getPlayers() return self.players end               -- :241
    -- :285-295：舊領袖不在 players 時才加回並移除新領袖（否則新領袖照樣留在 players）
    function f:setOwner(u)
        if not self:isMember(self.owner) then
            self.players:add(self.owner)
            self.players:remove(u)
        end
        self.owner = u
    end
    T.factions[#T.factions + 1] = f
    return f
end
-- 解散：只從清單移除（FactionDisbandPacket.java:34-41）
function T.disband(f)
    for i, x in ipairs(T.factions) do if x == f then table.remove(T.factions, i) return end end
end
Faction = {
    getFactions = function() return T.javaList(T.factions) end,    -- :33
    getFaction = function(name)                                    -- :140-148 第一個同名
        for _, f in ipairs(T.factions) do if f.name == name then return f end end
        return nil
    end,
    getPlayerFaction = function(user)                              -- :123-138
        for _, f in ipairs(T.factions) do if f:isOwner(user) or f:isMember(user) then return f end end
        return nil
    end,
}

-- ===== 世界：地板與房間 =====
T.floors = {}            -- "x,y" → 地板 sprite 名
T.unloaded = {}          -- "x,y" → true：該格未載入（getGridSquare 回 nil，IsoCell.java:3190-3192）
function T.floor(x, y, name) T.floors[x .. "," .. y] = name end
function T.fillFloor(x0, y0, w, h, name)
    for x = x0, x0 + w - 1 do for y = y0, y0 + h - 1 do T.floors[x .. "," .. y] = name end end
end
T.squareReads = 0
function getCell()
    return {
        getGridSquare = function(_, x, y, z)
            T.squareReads = T.squareReads + 1
            local key = x .. "," .. y
            if T.unloaded[key] then return nil end
            local name = T.floors[key]
            return {
                getX = function() return x end,
                getY = function() return y end,
                getFloor = function()
                    if name == nil then return nil end
                    return { getSprite = function() return { getName = function() return name end } end }
                end,
            }
        end,
    }
end
-- RoomDef／BuildingDef（RoomDef.java:207-217、BuildingDef.java:98-100,186-204）
T.rooms = {}
function T.building(x, y, w, h, roomNames)
    local b = { __class = "BuildingDef", x = x, y = y, w = w, h = h, rooms = {} }
    function b:getX() return self.x end
    function b:getY() return self.y end
    function b:getW() return self.w end
    function b:getH() return self.h end
    function b:getRooms() return T.javaList(self.rooms) end
    for _, name in ipairs(roomNames or { "bedroom" }) do
        local r = { __class = "RoomDef", name = name, z = 0, building = b, x = x, y = y, w = w, h = h }
        function r:getName() return self.name end
        function r:getZ() return self.z end
        function r:getBuilding() return self.building end
        function r:getX() return self.x end
        function r:getY() return self.y end
        function r:getW() return self.w end
        function r:getH() return self.h end
        b.rooms[#b.rooms + 1] = r
        T.rooms[#T.rooms + 1] = r
    end
    return b
end
function getWorld()
    return {
        getMetaGrid = function()
            return {
                -- IsoMetaGrid.java:430-441：回所有樓層、與矩形相交的房間
                getRoomsIntersecting = function(_, x, y, w, h, list)
                    for _, r in ipairs(T.rooms) do
                        if r.x < x + w and x < r.x + r.w and r.y < y + h and y < r.y + r.h then list:add(r) end
                    end
                    return list
                end,
            }
        end,
    }
end

-- ===== 亂數 =====
T.randQueue = {}
function ZombRand(n)
    local v = table.remove(T.randQueue, 1)
    if v == nil then return 0 end
    return v % n
end

-- ===== 原版 timed action 與伺服器處理器（Permissions 包裝的對象；每次開機重建，包裝不會疊加）=====
-- 原函式被呼叫就在 T.ran["類別.函式"] 加一；實例用 T.action(類別名, 欄位)，metatable 就是類別（ISBaseTimedAction.lua:173-176）。
T.TIMED_ACTIONS = { "ISToggleLightAction", "ISToggleStoveAction", "ISRadioAction", "ISPlugGenerator", "ISActivateGenerator",
    "ISFluidTransferAction", "ISMoveablesAction", "ISDestroyStuffAction", "ISDismantleAction", "ISBarricadeAction",
    "ISUnbarricadeAction", "ISPlowAction", "ISSeedActionNew", "ISHarvestPlantAction", "ISCurePlantAction",
    "ISWaterPlantAction", "ISTakeWaterAction" }
T.ran = {}
local function ran(key) T.ran[key] = (T.ran[key] or 0) + 1 end
function T.resetTimedActions()
    T.ran = {}
    for _, name in ipairs(T.TIMED_ACTIONS) do
        local cls = { Type = name }
        cls.__index = cls
        cls.complete = function() ran(name .. ".complete"); return true end
        _G[name] = cls
    end
    -- 取水：serverStart 排 takeFluid，animEvent 以 updateUse 分段把水轉進 item（ISTakeWaterAction.lua:31-48, 151-161），
    -- complete 補到滿（:130-133）；item.water 是已轉入的量
    local W = ISTakeWaterAction
    W.serverStart = function(self) ran("ISTakeWaterAction.serverStart"); self:updateUse(0.5) end
    W.updateUse = function(self, delta)
        if self.item then self.item.water = math.max(self.item.water or 0, self.waterUnit * delta) end
    end
    W.complete = function(self) ran("ISTakeWaterAction.complete"); self:updateUse(1); return true end
    Actions = { build = function() ran("Actions.build") end }                 -- ActionManager.lua:26
    SFarmingSystemCommands = {}                                               -- farmingCommands.lua:141
    for _, name in ipairs({ "seed", "plow", "harvest", "water", "destroy" }) do
        SFarmingSystemCommands[name] = function() ran("farm." .. name) end
    end
end
function T.action(className, fields)
    return setmetatable(fields or {}, _G[className])
end
-- 世界格子與物件（instanceof 以 __class 判斷，不模擬 Java 繼承）
function T.gridSquare(x, y, z)
    return { __class = "IsoGridSquare", getX = function() return x end, getY = function() return y end,
        getZ = function() return z or 0 end }
end
function T.worldObject(x, y, z)
    local sq = T.gridSquare(x, y, z)
    return { __class = "IsoObject", getSquare = function() return sq end }
end

-- ===== 載入 MOD =====
local loaded = {}
function require(name)
    if loaded[name] then return true end
    for _, dir in ipairs({ "shared", "server", "client" }) do
        local path = T.MEDIA .. "/" .. dir .. "/" .. name .. ".lua"
        local chunk = loadfile(path)
        if chunk then
            loaded[name] = true
            chunk()
            return true
        end
    end
    error("require 找不到: " .. name)
end

T.MODULES = dofile("scripts/harness/modules.lua")

local function loadModules(dirs)
    for _, entry in ipairs(T.MODULES) do
        if dirs[entry.dir] then
            local path = T.MEDIA .. "/" .. entry.dir .. "/" .. entry.name .. ".lua"
            local f = io.open(path, "r")
            if f then
                f:close()
                require(entry.name)
            end
        end
    end
end

local function resetWorld(opts)
    opts = opts or {}
    T.handlers = {}
    T.houses = opts.keepHouses and T.houses or {}
    -- 重開時 SafeHouse.load 會把 owner 也放進 players（建構子 :586，load 沒有 setOwner；計畫 §2.1）
    if opts.keepHouses then
        for _, hs in ipairs(T.houses) do hs:addPlayer(hs.owner) end
    end
    T.online, T.outbox, T.broadcasts, T.syncs, T.teleports, T.clientSent = {}, {}, {}, {}, {}, {}
    T.netUp, T.netEarly = false, {}
    T.itemSyncs = {}
    T.logs, T.prints = {}, {}
    T.serverOptions = {}
    for k, v in pairs(T.DEFAULT_OPTIONS) do T.serverOptions[k] = v end
    if not opts.keepGmd then T.gmd = {} end
    if not opts.keepFiles then T.files = {} end
    T.unreadable = {}
    T.failWrites, T.failRemove, T.failAdd, T.noLocation, T.failHouseRemove = false, false, false, false, false
    T.floors, T.unloaded, T.rooms = {}, {}, {}
    T.randQueue = {}
    T.factions = {}
    T.steam = opts.steam or false
    T.activeMods = opts.mods or { "MinidoracatSafehouseFor42" }
    T.squareReads = 0
    T.nextOnlineId = 0
    MinidoracatMiniMapResourceAPI = nil
    MinidoracatEconomy = nil   -- 假 Economy 由 T.economy 在 beforeStart 裝上
    MinidoracatSafehouse = nil
    MSH_Recipe = nil
    T.resetTimedActions()
    for k in pairs(loaded) do loaded[k] = nil end
end

-- 伺服器開機：載入 shared＋server、填沙盒、OnInitGlobalModData → OnLoadedMapZones（§6 開服時序）。
-- opts.keepGmd／keepFiles／keepHouses：模擬重開（存檔留著、Lua 狀態重建）；opts.sandbox：開機前覆寫的沙盒值；
-- opts.beforeStart(T)：在 OnLoadedMapZones 之前執行（例如擺好原生安全屋）；opts.noStart：只載入不開服。
function T.boot(opts)
    opts = opts or {}
    resetWorld(opts)
    T.mode = "server"
    loadModules({ shared = true, server = true })
    T.resetSandbox()
    for k, v in pairs(opts.sandbox or {}) do SandboxVars.MinidoracatSafehouse[k] = v end
    if opts.beforeStart then opts.beforeStart(T) end
    if not opts.noStart then
        T.fire("OnInitGlobalModData", false)
        T.fire("OnLoadedMapZones")
        T.fire("OnServerStarted")
    end
    return MinidoracatSafehouse
end

-- 客戶端開機：載入 shared＋client（獨立的一份全域，和伺服器不同程序）
function T.bootClient(opts)
    opts = opts or {}
    resetWorld(opts)
    T.mode = "client"
    loadModules({ shared = true, client = true })
    T.resetSandbox()
    return MinidoracatSafehouse
end

function T.tick(n)
    for _ = 1, n or 1 do
        T.advance(100)
        T.fire("OnTick")
    end
end

-- ===== 指令 =====
T.reqSeq = 0
function T.newRequestId()
    T.reqSeq = T.reqSeq + 1
    return string.format("req-%08d", T.reqSeq)
end

-- 送一個指令並回傳這次的 result；mutation 自動補 requestId（requestId=false 表示不帶）
function T.cmd(player, command, args, requestId)
    args = args or {}
    if args.protocol == nil then args.protocol = MinidoracatSafehouse.PROTOCOL end
    if requestId == nil then
        local spec = MinidoracatSafehouse.Srv.commands[command]
        if spec == nil or spec.kind == "mutation" then args.requestId = T.newRequestId() end
    elseif requestId ~= false then
        args.requestId = requestId
    end
    T.advance(300)
    local box = T.outbox[player.name] or {}
    T.outbox[player.name] = box
    local before = #box
    T.fire("OnClientCommand", MinidoracatSafehouse.MODULE, command, player, args)
    for i = #box, before + 1, -1 do
        if box[i].command == "result" then return box[i].args end
    end
    return nil
end

function T.lastOf(player, command)
    local box = T.outbox[player.name] or {}
    for i = #box, 1, -1 do
        if box[i].command == command then return box[i].args end
    end
    return nil
end

function T.broadcastsOf(command)
    local out = {}
    for _, b in ipairs(T.broadcasts) do if b.command == command then out[#out + 1] = b.args end end
    return out
end

-- 找 owner 是某個字串的原生安全屋
function T.houseOf(owner)
    for _, hs in ipairs(T.houses) do if hs.owner == owner then return hs end end
    return nil
end

-- ===== 假 Economy 權益 facade（MinidoracatEconomy.v1，只做 Safehouse 用到的方法；形狀照 local economy-api 摘要：
-- registerSource ECI:174-212、registerProduct ECP:180-224、getEntitlement ECE:688-763、setPlan／getPlan ECP:253）=====
-- opts：revision（預設 4）、caps（整份覆寫能力表）、failSource（registerSource 丟錯）、failRegister（registerProduct 回 ok=false）、
--       keep（沿用上一個假 Economy 的方案與權益：模擬重開）。回傳狀態表 e：products、plans、ents、listeners、failRead、setPlans
T.econ = nil
local PLAN_ORDER = { "permanentEnabled", "permanentCurrency", "permanentPrice", "permanentLimit", "rentalEnabled",
    "rentalCurrency", "rentalPrice", "rentalLimit", "rentalDays", "graceHours", "reminderHours", "autoRenewAllowed" }
local PLAN_RULES = {
    permanentEnabled = "bool", permanentCurrency = "cur", permanentPrice = { 1, 1e9 }, permanentLimit = { 0, 1000 },
    rentalEnabled = "bool", rentalCurrency = "cur", rentalPrice = { 1, 1e9 }, rentalLimit = { 1, 1000 },
    rentalDays = { 1, 365 }, graceHours = { 0, 168 }, reminderHours = { 0, 168 }, autoRenewAllowed = "bool",
}
local ECON_CURRENCIES = { survivor = {}, gold = {} }
local function shallow(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end
local function planError(values)
    for k in pairs(values) do if PLAN_RULES[k] == nil then return "unknown_fields", k end end
    for _, k in ipairs(PLAN_ORDER) do
        local rule, v = PLAN_RULES[k], values[k]
        local ok
        if rule == "bool" then ok = type(v) == "boolean"
        elseif rule == "cur" then ok = ECON_CURRENCIES[v] ~= nil
        else ok = type(v) == "number" and v == math.floor(v) and v >= rule[1] and v <= rule[2] end
        if not ok then return "invalid_plan", k end
    end
    return nil
end
function T.economy(opts)
    opts = opts or {}
    local old = opts.keep and T.econ or nil
    local e = { products = {}, plans = old and old.plans or {}, ents = old and old.ents or {}, listeners = {},
        failRead = {}, setPlans = {}, source = nil }
    T.econ = e
    local h = {}
    function h.registerProduct(spec)
        if opts.failRegister then return { ok = false, error = "invalid_args", field = "instant" } end
        e.products[spec.id] = spec
        if e.plans[spec.id] == nil then
            e.plans[spec.id] = { values = shallow(spec.defaults), revision = 1,
                lastChange = { actor = "source", origin = "defaults", at = T.now, revision = 1 } }
        end
        return { ok = true, product = { sourceMod = e.source.modId, id = spec.id, nameKey = spec.nameKey } }
    end
    function h.getEntitlement(user, product)
        if e.failRead[user] then return { ok = false, error = "exception" } end
        local pl = e.plans[product]
        local ent = e.ents[user .. "|" .. product] or { permanent = 0, rental = 0, usable = 0, rentals = {}, state = "none" }
        return { ok = true, productId = product, plan = pl and shallow(pl.values), entitlement = ent }
    end
    function h.getPlan(product)
        local pl = e.plans[product]
        if pl == nil then return { ok = false, error = "unknown_product" } end
        local plan = shallow(pl.values)
        plan.revision = pl.revision
        return { ok = true, plan = plan, lastChange = shallow(pl.lastChange) }
    end
    function h.setPlan(product, values, o)
        e.setPlans[#e.setPlans + 1] = { product = product, values = values, opts = o }
        local pl = e.plans[product]
        if pl == nil then return { ok = false, error = "unknown_product" } end
        local err, field = planError(values)
        if err then return { ok = false, error = err, field = field } end
        local changed = {}
        for _, k in ipairs(PLAN_ORDER) do if values[k] ~= pl.values[k] then changed[#changed + 1] = k end end
        if #changed == 0 then return { ok = true, updated = false, revision = pl.revision, changed = {} } end
        if o and o.expectedRevision ~= nil and o.expectedRevision ~= pl.revision then
            return { ok = false, error = "stale_revision" }
        end
        pl.values = shallow(values)
        pl.revision = pl.revision + 1
        pl.lastChange = { actor = o and o.actor, origin = o and o.origin, at = T.now, reason = o and o.reason,
            revision = pl.revision }
        return { ok = true, updated = true, revision = pl.revision, changed = changed }
    end
    function h.setPlanSource() return { ok = true } end
    function h.onEntitlementChanged(fn) e.listeners[fn] = true end
    MinidoracatEconomy = {
        CURRENCIES = ECON_CURRENCIES,
        v1 = {
            API_MAJOR = 1,
            API_REVISION = opts.revision or 4,
            CAPABILITIES = opts.caps or { entitlements = true, subscriptions = true, rentals = true, setPlan = true, freeze = true },
            registerSource = function(spec)
                if opts.failSource then error("registerSource boom") end
                e.source = spec
                return h
            end,
        },
    }
    return e
end

-- 設定一位玩家某級的權益並通知監聽者（Economy 在 commit 後才通知）。
-- leases = { { id, quantity, state, graceUntil? } }；usable＝permanent＋active／grace 租約（ECE:707）
function T.econSet(user, tier, permanent, leases)
    local e = T.econ
    local rental = 0
    for _, x in ipairs(leases or {}) do
        if x.state == "active" or x.state == "grace" then rental = rental + x.quantity end
    end
    local product = "tier" .. tier
    e.ents[user .. "|" .. product] = { permanent = permanent or 0, rental = rental, usable = (permanent or 0) + rental,
        rentals = leases or {}, state = "active" }
    for fn in pairs(e.listeners) do fn(user, product, {}) end
end

return T
