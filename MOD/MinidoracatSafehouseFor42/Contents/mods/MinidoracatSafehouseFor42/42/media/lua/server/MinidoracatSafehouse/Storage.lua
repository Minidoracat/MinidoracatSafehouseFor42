-- MinidoracatSafehouse/Storage.lua：遠距拿取（使用者 2026-10-20；設計稿 temp/plan-storage-1020，裁定見 decisions.md 2026-10-20）。
-- 物品搜尋與指引都在客戶端（client/…/StorageScan.lua、StoragePanel.lua），伺服器只管「拿」，分兩段：
--   storageBegin：沙盒 StorageMode 是「可以遠距拿」、這間 active、自己有 TAKE、人站在這間任一塊裡（或沙盒 StorageReach 放寬的
--     安全屋外幾格內，使用者 2026-10-21）、要拿的那格在範圍內而且
--     載入了；找出那一格上還在的那幾件（家具容器、容器裡的背包往裡一層、地上），背包放得下的照原版搬運時間加總，記下這次
--     （開始時間、站的位置），回總毫秒數。
--   storageTake：同一次、時間到了、人沒離開原地（STAND 格內、同一層）、模式權限位置都還成立，才把還在原處、放得下的搬進背包。
-- 為什麼兩段：計時動作在客戶端跑（類別沒有 complete＝只在客戶端，LuaTimedActionNew.java:78-80），伺服器自己記時間和位置，
--   改過的客戶端也跳不過等待（timed action 的身分不能信，decisions.md）。
-- 搬法（sh-storage-1020b、sh-storperf-1020a 實測）：家具容器 Remove＋sendRemoveItemFromContainer；地上
--   transmitRemoveItemFromSquare＋setWorldItem(nil)；背包裡的直接拿客戶端會留下那件，所以同一個背包整個拿出、拿掉這次的、
--   再放回（一個背包一次）；進背包 AddItem＋sendAddItemToContainer。50 件 1 ms。車與人形模特兒身上的不在這裡（只能指引）。
-- 搬東西與送封包排在放鎖之後（ctx.defer，Server.lua 規則）；件數在 defer 裡填回同一張結果表（回覆在 defer 之後才送）。

if isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Settings"
require "MinidoracatSafehouse/Server"

local MSH = MinidoracatSafehouse
local St = MSH.Storage or {}
MSH.Storage = St

local S = MSH.Srv
local CODE = MSH.CODE

St.pending = St.pending or {}   -- 帳號 → { claimId, x, y, z, ids, startAt, durMs, px, py, pz }
St.EXPIRE_MS = 60000            -- 時間到了之後最多再等多久（計時動作排在別的動作後面、網路慢）
-- 容許提早：伺服器收到兩個封包的間隔可能比客戶端實際等的短一點（客戶端每秒 48 單位、伺服器以每秒 50 單位算，
-- BaseAction.java:107、GameTime.java:986，客戶端本來就會晚 4%）
St.EARLY_RATIO, St.EARLY_MS = 0.9, 300
St.STAND = 1                    -- 等的時候最多離開原地幾格
St.WATCH_MS = 250               -- 多久看一次正在等的人走開了沒有
local EPS = 0.001

-- 原版搬運時間（毫秒）：世界容器或地上 → 自己的背包是 50 × min(重量, 3) 單位，靈巧 ×0.5、笨手笨腳或戴不靈活的手套 ×2，
-- 1 單位 20 ms（Transaction.java:347-441）。地上連拿同種輕物品免時間（:414-428）不照算：只會慢一點
function St.itemMs(player, item)
    local ms = 1000 * math.min(item:getActualWeight(), 3)
    if player:hasTrait(CharacterTrait.DEXTROUS) then ms = ms * 0.5 end
    if player:hasTrait(CharacterTrait.ALL_THUMBS) or player:isWearingAwkwardGloves() then ms = ms * 2 end
    return ms
end

-- 那一格上要找的物品（want：id → true）：id → { item, c（家具容器）, bag（容器裡的背包；nil＝直接在容器裡）, wo（地上）}。
-- 對這個人上了鎖的容器不看（MSH.lockedFor），裡面的算不在了
local function locate(sq, want, player)
    local out = {}
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        for ci = 0, o:getContainerCount() - 1 do
            local c = o:getContainerByIndex(ci)
            if c ~= nil and c:getType() ~= "mannequin" and not MSH.lockedFor(c, player) then
                local items = c:getItems()
                for k = 0, items:size() - 1 do
                    local it = items:get(k)
                    if want[it:getID()] then out[it:getID()] = { item = it, c = c } end
                    if instanceof(it, "InventoryContainer") then
                        local inner = it:getInventory():getItems()
                        for j = 0, inner:size() - 1 do
                            local x = inner:get(j)
                            if want[x:getID()] then out[x:getID()] = { item = x, c = c, bag = it } end
                        end
                    end
                end
            end
        end
    end
    local wos = sq:getWorldObjects()
    for i = 0, wos:size() - 1 do
        local wo = wos:get(i)
        local it = wo:getItem()
        if it ~= nil and want[it:getID()] then out[it:getID()] = { item = it, wo = wo } end
    end
    return out
end

-- 照 ids 的順序挑出還在、背包放得下的（hasRoomFor 管不能放的東西，累計重量管這一批加起來放不放得下）。
-- 同一批裡有背包本身又有它裡面的東西時，裡面的跟著背包走，不另外搬（另外搬會把背包放回原處，2026-10-20 審查）
local function plan(player, sq, ids)
    local want = {}
    for _, id in ipairs(ids) do want[id] = true end
    local found = locate(sq, want, player)
    local whole = {}
    for _, f in pairs(found) do
        if f.bag == nil and f.wo == nil then whole[f.item] = true end
    end
    local inv = player:getInventory()
    local free = inv:getEffectiveCapacity(player) - inv:getCapacityWeight()
    local list, gone, full = {}, 0, 0
    for _, id in ipairs(ids) do
        local f = found[id]
        if f == nil or (f.bag ~= nil and whole[f.bag]) then
            gone = gone + 1
        else
            local w = f.item:getUnequippedWeight()
            if inv:hasRoomFor(player, f.item) and w <= free + EPS then
                free = free - w
                list[#list + 1] = f
            else
                full = full + 1
            end
        end
    end
    return list, gone, full
end

-- 兩段共同的條件；成立回 rec
local function allowed(ctx)
    if MSH.Settings.storageMode() ~= MSH.Settings.STORAGE.REMOTE then return nil, CODE.STORAGE_OFF end
    local R = MSH.Registry
    local rec = R.get(ctx.args.claimId)
    local role, bits = nil, nil
    if rec ~= nil and R.isLive(rec) and not rec.malformed then role, bits = MSH.Claims.roleOf(rec, ctx.who) end
    if role == nil then return nil, CODE.NOT_FOUND end
    if rec.lifecycle ~= MSH.LIFECYCLE.ACTIVE then return nil, CODE.WRONG_LIFECYCLE end
    if not MSH.hasBit(bits, MSH.SHARE.TAKE) then return nil, CODE.PERM_DENIED end
    local p = ctx.player
    if p:isDead() then return nil, CODE.DEAD end
    local reach = MSH.Settings.storageReach()
    if not MSH.Rect.listContains(rec.rects, p:getX(), p:getY(), reach) then return nil, CODE.NOT_ON_SITE end
    return rec
end

-- 一件都拿不了：有找到但放不下＝背包滿了，否則＝東西不在了
local function nothing(gone, full)
    return S.fail(full > 0 and CODE.NO_ROOM or CODE.GONE, { gone = gone, full = full })
end

function St.begin(ctx)
    local a, p = ctx.args, ctx.player
    local rec, code = allowed(ctx)
    if rec == nil then return S.fail(code) end
    if not MSH.Rect.listContains(rec.rects, a.x, a.y) then return S.fail(CODE.BAD_ARGS) end
    local sq = getCell():getGridSquare(a.x, a.y, a.z)
    if sq == nil then return S.fail(CODE.NOT_LOADED) end
    local list, gone, full = plan(p, sq, a.ids)
    if #list == 0 then return nothing(gone, full) end
    local ids, ms = {}, 0
    for i, f in ipairs(list) do
        ids[i] = f.item:getID()
        ms = ms + St.itemMs(p, f.item)
    end
    ms = math.max(1, math.floor(ms + 0.5))
    St.pending[ctx.who] = { claimId = rec.claimId, x = a.x, y = a.y, z = a.z, ids = ids, startAt = ctx.now, durMs = ms,
        px = math.floor(p:getX()), py = math.floor(p:getY()), pz = math.floor(p:getZ()), p = p }
    return S.ok({ durMs = ms, n = #ids, gone = gone, full = full })
end

-- 照計畫搬（放鎖之後）。每處各自 pcall：一處失手不影響其他處；搬成的件數寫回 res.got。
-- 來源容器標成已探索、已被拿過，同原版拿取（Transaction.java:153-160；戰利品重生看這兩個旗標）
function St.move(p, sq, list, res)
    local inv = p:getInventory()
    local bags, order = {}, {}
    for _, f in ipairs(list) do
        if f.bag ~= nil then
            local b = bags[f.bag]
            if b == nil then
                b = { bag = f.bag, c = f.c, items = {} }
                bags[f.bag] = b
                order[#order + 1] = b
            end
            b.items[#b.items + 1] = f.item
        else
            local ok, err = pcall(function()
                if f.wo ~= nil then
                    sq:transmitRemoveItemFromSquare(f.wo)
                    f.item:setWorldItem(nil)
                else
                    f.c:Remove(f.item)
                    f.c:setExplored(true)
                    f.c:setHasBeenLooted(true)
                    sendRemoveItemFromContainer(f.c, f.item)
                end
                inv:AddItem(f.item)
                sendAddItemToContainer(inv, f.item)
            end)
            if ok then res.got = res.got + 1 else MSH.log("storage move failed: " .. tostring(err)) end
        end
    end
    for _, b in ipairs(order) do
        local ok, err = pcall(function()
            b.c:Remove(b.bag)
            b.c:setExplored(true)
            b.c:setHasBeenLooted(true)
            sendRemoveItemFromContainer(b.c, b.bag)
            local bi = b.bag:getInventory()
            for _, it in ipairs(b.items) do bi:Remove(it) end
            b.c:AddItem(b.bag)
            sendAddItemToContainer(b.c, b.bag)
            for _, it in ipairs(b.items) do
                inv:AddItem(it)
                sendAddItemToContainer(inv, it)
            end
        end)
        if ok then res.got = res.got + #b.items else MSH.log("storage bag move failed: " .. tostring(err)) end
    end
end

-- 等的時候離開開始那一格超過 STAND、換了樓層或死了
local function moved(p, pd)
    return p:isDead() or math.floor(p:getZ()) ~= pd.pz or math.abs(math.floor(p:getX()) - pd.px) > St.STAND
        or math.abs(math.floor(p:getY()) - pd.py) > St.STAND
end

function St.take(ctx)
    local p, who = ctx.player, ctx.who
    local pend = St.pending[who]
    St.pending[who] = nil
    if pend == nil or pend.claimId ~= ctx.args.claimId then return S.fail(CODE.TAKE_STOPPED) end
    local waited = ctx.now - pend.startAt
    if waited < pend.durMs * St.EARLY_RATIO - St.EARLY_MS or waited > pend.durMs + St.EXPIRE_MS or moved(p, pend) then
        return S.fail(CODE.TAKE_STOPPED)
    end
    local rec, code = allowed(ctx)
    if rec == nil then return S.fail(code) end
    local sq = getCell():getGridSquare(pend.x, pend.y, pend.z)
    if sq == nil then return S.fail(CODE.NOT_LOADED) end
    local list, gone, full = plan(p, sq, pend.ids)
    if #list == 0 then return nothing(gone, full) end
    local res = S.ok({ got = 0, n = #list, gone = gone, full = full })
    ctx.defer(function() St.move(p, sq, list, res) end)
    MSH.Audit.write("STORAGE_TAKE", { actor = who, claimId = rec.claimId, code = tostring(#list),
        detail = pend.x .. "," .. pend.y .. "," .. pend.z })
    return res
end

-- 沒送完成的（中斷、斷線）過期就丟；等的時候走開過的也丟（只看結束那一刻，走開再走回來就看不出來，2026-10-20 審查）。
-- 每 WATCH_MS 看一次，只走正在等的那幾位；先收集再刪（Kahlua 走訪中不改正在走訪的表）
function St.watch(now)
    if now < (St.watchAt or 0) then return end
    St.watchAt = now + St.WATCH_MS
    local drop = nil
    for who, pd in pairs(St.pending) do
        if now - pd.startAt > pd.durMs + St.EXPIRE_MS or pd.p == nil or moved(pd.p, pd) then
            drop = drop or {}
            drop[#drop + 1] = who
        end
    end
    if drop ~= nil then
        for _, who in ipairs(drop) do St.pending[who] = nil end
    end
end

S.define("storageBegin", { kind = "mutation",
    fields = { claimId = "claimId", x = "int", y = "int", z = "level", ids = "ids" },
    run = function(ctx) return MSH.Storage.begin(ctx) end })
S.define("storageTake", { kind = "mutation", fields = { claimId = "claimId" },
    run = function(ctx) return MSH.Storage.take(ctx) end })
S.hook("tick", "storagePending", function(now) MSH.Storage.watch(now) end)
