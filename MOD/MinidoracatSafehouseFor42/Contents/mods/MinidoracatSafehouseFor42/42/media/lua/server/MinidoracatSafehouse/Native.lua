-- MinidoracatSafehouse/Native.lua：原生 SafeHouse 的轉接層（計畫 §2.1、§2.3、§4.4、§6.3）。
-- 原生安全屋是保護用的原件；owner 固定 @MSH:<claimId>，真實玩家都放 players。
-- 不呼叫 SafeHouse.intersects（逐格 getOrCreateGridSquare，SafeHouse.java:805-815）；重疊一律用矩形比對。

if isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Settings"
require "MinidoracatSafehouse/Audit"

local MSH = MinidoracatSafehouse
local N = MSH.Native or {}
MSH.Native = N

local Rect = MSH.Rect

-- 每次載入（含 /reloadlua）都算新的 boot：客戶端靠 bootId＋seq 判斷 remove delta 有沒有漏（§6.3）
N.bootId = tostring(getTimestampMs())
N.seq = 0

function N.list()
    return MSH.toArray(SafeHouse.getSafehouseList())
end

function N.rectOf(house)
    return { x = house:getX(), y = house:getY(), w = house:getW(), h = house:getH() }
end

function N.rectKey(r)
    return r.x .. "," .. r.y .. "," .. r.w .. "," .. r.h
end

-- 名單（不含 owner 本身；restart 後 load() 會把 owner 也放進 players，§2.1）
function N.players(house)
    local out, owner = {}, house:getOwner()
    local l = house:getPlayers()
    for i = 0, l:size() - 1 do
        local u = tostring(l:get(i))
        if u ~= owner then out[#out + 1] = u end
    end
    return out
end

-- 掃一次原生清單建索引：每輪 reconcile 與每次建立各掃一次（§6.2）
-- entry = { house, rect, owner, claimId（owner 是標記時）, onlineId }
function N.index()
    local idx = { all = {}, byClaim = {}, byRect = {}, foreign = {}, onlineIds = {}, count = 0 }
    for _, house in ipairs(N.list()) do
        local owner = house:getOwner()
        local e = { house = house, rect = N.rectOf(house), owner = owner, claimId = MSH.claimIdOf(owner),
            onlineId = house:getOnlineID() }
        idx.count = idx.count + 1
        idx.all[#idx.all + 1] = e
        idx.onlineIds[e.onlineId] = (idx.onlineIds[e.onlineId] or 0) + 1
        local key = N.rectKey(e.rect)
        local same = idx.byRect[key] or {}
        same[#same + 1] = e
        idx.byRect[key] = same
        if e.claimId then
            local l = idx.byClaim[e.claimId] or {}
            l[#l + 1] = e
            idx.byClaim[e.claimId] = l
        else
            idx.foreign[#idx.foreign + 1] = e
        end
    end
    return idx
end

-- 與 rect（往外擴 gap）相交的原生安全屋；skip(e) 回 true 的略過
function N.overlapping(idx, rect, gap, skip)
    local out = {}
    for _, e in ipairs(idx.all) do
        if not (skip and skip(e)) and Rect.overlaps(rect, e.rect, gap) then out[#out + 1] = e end
    end
    return out
end

-- 陣營分享的 Faction 物件快取（§4.3）：claimId → 上次確認有效的 live Faction，只在記憶體。
-- 照 VM R.factionRefs（MinidoracatVehicleManager_OwnershipSystem.lua:37-38,836）：同一進程內同名陣營重建是新物件，視為不同陣營。
N.factionRefs = N.factionRefs or {}

-- 陣營分享綁定的陣營（§6.5；照 VM boundFaction／factionAllows，OwnershipSystem.lua:779-787,829-838）。
-- 回 f（有效）或 nil, reason：GONE（不存在、改名、同進程同名重建）、LEADER_CHANGED、OWNER_LEFT；
-- 沒有 GRANTED 的分享回 nil, nil。全服開關不在這裡看（關掉只是不投影，見 factionMembers）。
-- Faction.getFaction：characters/Faction.java:140；getOwner :281；isOwner :150；isMember :154
function N.faction(rec)
    local fs = rec.factionShare
    if type(fs) ~= "table" or fs.state ~= "GRANTED" then return nil, nil end
    local f = type(fs.name) == "string" and Faction.getFaction(fs.name) or nil
    local ref = N.factionRefs[rec.claimId]
    if f == nil or (ref ~= nil and ref ~= f) then return nil, "GONE" end
    if f:getOwner() ~= fs.leader then return nil, "LEADER_CHANGED" end
    if type(rec.owner) ~= "string" or not (f:isOwner(rec.owner) or f:isMember(rec.owner)) then return nil, "OWNER_LEFT" end
    N.factionRefs[rec.claimId] = f
    return f, nil
end

-- 陣營分享目前有效時的成員：領袖＋players（Faction.java:241）；分享無效或全服關閉 AllowFactionShare 回 nil
function N.factionMembers(rec)
    local f = N.faction(rec)
    if f == nil or not MSH.Settings.get().allowFactionShare then return nil end
    local leader = f:getOwner()
    local out, seen = { leader }, { [leader] = true }
    for _, raw in ipairs(MSH.toArray(f:getPlayers())) do
        local u = tostring(raw)
        if not seen[u] then
            seen[u] = true
            out[#out + 1] = u
        end
    end
    return out
end

-- 投影進原生名單、也算進 Claims.roleOf 的陣營成員：有效、分享帶 MEMBER、人數 ≤ LIMIT.FACTION_PROJECTION。
-- 超過上限整批不投影（不靜默截斷，§4.2 第 227、238 行；Claims.healthSummary 給 FACTION_TOO_LARGE）
function N.projectedMembers(rec)
    local fs = rec.factionShare
    if type(fs) ~= "table" or not MSH.hasBit(fs.bits, MSH.SHARE.MEMBER) then return nil end
    local members = N.factionMembers(rec)
    if members == nil or #members > MSH.LIMIT.FACTION_PROJECTION then return nil end
    return members
end

-- 這筆紀錄應該在原生名單裡的人：屋主＋帶 MEMBER 的指定玩家＋投影中的陣營成員（§4.4）。
-- Reconcile、Admin 修名單、Sharing 都以它為準，所以收斂與分享同步不會一加一減。
function N.desiredPlayers(rec)
    local out, seen = {}, {}
    local function add(u)
        if type(u) == "string" and u ~= "" and not seen[u] then
            seen[u] = true
            out[#out + 1] = u
        end
    end
    add(rec.owner)
    for _, g in ipairs(rec.grants or {}) do
        if MSH.hasBit(g.bits, MSH.SHARE.MEMBER) then add(g.user) end
    end
    for _, u in ipairs(N.projectedMembers(rec) or {}) do add(u) end
    return out
end

-- 原生物件是否就是這筆紀錄建出來的：rect 相同、建立時間相同（nativeCreatedAt 是能拿到最好的指紋，§4.2）
function N.matches(rec, e)
    if not Rect.valid(rec.rect) or not Rect.equals(rec.rect, e.rect) then return false end
    if rec.nativeCreatedAt == nil then return true end
    return e.house:getDatetimeCreated() == rec.nativeCreatedAt
end

-- 依紀錄建立原生安全屋。addSafeHouse 本身不驗重疊（SafeHouse.java:68-85）；呼叫前由呼叫端驗完。
-- 回傳 house 或 nil, 結果碼
function N.build(rec)
    local r = rec.rect
    local ok, house = pcall(function()
        return SafeHouse.addSafeHouse(r.x, r.y, r.w, r.h, MSH.marker(rec.claimId))
    end)
    if not ok or house == nil then
        MSH.log("addSafeHouse failed for claim " .. tostring(rec.claimId) .. ": " .. tostring(house))
        return nil, MSH.CODE.NATIVE_FAILED
    end
    -- addSafeHouse 以出生區推算 location（setLocation(null)，SafeHouse.java:702-725）；推不出來就不建，
    -- 存檔要寫這個字串（§7.3 最後一條：失敗不消耗地契）
    if house:getLocation() == nil then
        SafeHouse.removeSafeHouse(house)
        return nil, MSH.CODE.NATIVE_FAILED
    end
    house:setTitle(rec.title)
    for _, u in ipairs(N.desiredPlayers(rec)) do house:addPlayer(u) end
    return house
end

-- removeSafeHouse 是 void、不回報（SafeHouse.java:306-320）：移除後重掃確認真的不在了
function N.remove(house)
    SafeHouse.removeSafeHouse(house)
    for _, h in ipairs(N.list()) do
        if h == house then return false end
    end
    return true
end

-- OnServerStarted 之前沒有任何連線，getOnlinePlayers 會 NPE 並回 nil（Server.lua S.netUp）
function N.onlinePlayer(name)
    if not MSH.Srv.netUp then return nil end
    local list = getOnlinePlayers()
    for i = 0, list:size() - 1 do
        local p = list:get(i)
        if p:getUsername() == name then return p end
    end
    return nil
end

-- 原生 upsert 廣播：以 service-owner 呼叫 kickUserFromSafehouse（SafeHouse.java:832-850）。
-- 副作用只有兩個：移除 load() 殘留在 players 的標記、把冒名 @MSH:<id> 站在屋內的人傳出去（§2.3）。
function N.broadcast(house)
    -- 開服首輪（OnLoadedMapZones）還沒有人連得上：玩家登入時 MetaDataPacket 會送整份原生清單（§2.3），不必廣播；
    -- kickUserFromSafehouse 的 sendToAll 這時也會碰到 null 的 udpEngine
    if not MSH.Srv.netUp then return true end
    local owner = house:getOwner()
    if MSH.claimIdOf(owner) ~= nil and N.onlinePlayer(owner) ~= nil then
        -- 有人用 service-owner 的名字在線：身分異常，照樣廣播（會把他傳出屋外），寫 audit（§6.3）
        MSH.Audit.throttled("IMPERSONATE|" .. owner, 60000, "IDENTITY_ANOMALY",
            { actor = owner, code = "SERVICE_OWNER_ONLINE" }, getTimestampMs())
    end
    local ok, err = pcall(function() SafeHouse.kickUserFromSafehouse(house, owner) end)
    if not ok then MSH.log("broadcast failed: " .. tostring(err)) end
    return ok
end

-- 撤銷名單用：先移除再廣播，人在屋內就立即傳出（只給 manager 撤銷用，收斂路徑不得對真實玩家呼叫，§6.2）
function N.revoke(house, username)
    local ok, err = pcall(function() SafeHouse.kickUserFromSafehouse(house, username) end)
    if not ok then MSH.log("revoke failed: " .. tostring(err)) end
    return ok
end

-- 原生沒有伺服器 Lua 可用的 remove 廣播（§2.3）：送自訂 remove delta 給全部客戶端（sendServerCommand 不帶玩家＝廣播）
-- rect 可以是 nil（malformed 紀錄）：客戶端只照 owner 標記移除，rect 只是資訊
function N.sendRemove(claimId, rect)
    if not MSH.Srv.netUp then return end   -- 同 broadcast：開服前沒有客戶端，登入時的清單已經不含它
    N.seq = N.seq + 1
    rect = rect or {}
    sendServerCommand(MSH.MODULE, "nativeRemove", {
        claimId = claimId, x = rect.x, y = rect.y, w = rect.w, h = rect.h, bootId = N.bootId, seq = N.seq,
    })
end
