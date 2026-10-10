-- MinidoracatSafehouse/Identity.lua：玩家身分 principal(player) 與私有綁定表（家族 conventions.md「玩家身分」，計畫 §4.2）。
-- 伺服器上的 getUsername() 是客戶端送來的名字：重生與分割畫面走 ConnectCoopPacket，只擋空字串與在線重名
-- （ConnectCoopPacket.java:72-97），所以授權一律經 principal：
--   getPlayerNum() ~= 0 → nil（分割畫面次玩家沒有身分）；非 Steam 模式 → 名字；
--   Steam 模式：有綁定就比 SteamID，不符 → nil；沒綁定 → 名字（還沒做 whitelist 匯入，照 VehicleManager；匯入在 M3）。
-- 綁定寫入來源：伺服器 OnNewGame（CreatePlayerPacket 觸發時名字＝連線登入名，CreatePlayerPacket.java:296-301），
-- 以及本 MOD 的「建立安全屋時綁定建立者」（使用者 2026-10-10 裁定），條件照 Economy「第一次看到」。

if isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Audit"
require "MinidoracatSafehouse/Registry"
require "MinidoracatSafehouse/Health"

local MSH = MinidoracatSafehouse
local first = MSH.Identity == nil
local I = MSH.Identity or {}
MSH.Identity = I

I.SLOT_GAP_MS = 120000        -- 同一座位前後兩位佔用者的間隔上限（Economy Id.SLOT_GAP_MS）
I.NEWGAME_WINDOW_MS = 120000  -- 同一 SteamID 兩分鐘內以別的名字 OnNewGame＝改名證據
I.SCAN_MS = 1000

-- E2E 在 no-steam 伺服器上覆寫這兩個（conventions「玩家身分」第 6 點）
I.steamMode = I.steamMode or function() return getSteamModeActive() == true end
I.sidOf = I.sidOf or function(player) return player:getSteamID() end

I.slots = I.slots or {}       -- onlineID → { name, sid, seen, obj, suspect, other }
I.newGames = I.newGames or {} -- SteamID（double）→ { name, at }

local function validSid(v)
    return type(v) == "number" and v > 0 and v * 0 == 0 and v == math.floor(v)
end

local function playerNum(player)
    local ok, num = pcall(function() return player:getPlayerNum() end)
    if ok then return num end
    return nil
end

function I.principal(player)
    if player == nil or playerNum(player) ~= 0 then return nil end
    local name = player:getUsername()
    if type(name) ~= "string" or name == "" then return nil end
    if not I.steamMode() then return name end
    local R = MSH.Registry
    if R.privateUnreadable then return nil end
    local b = R.binding(name)
    if b == nil then return name end
    if b.sid ~= I.sidOf(player) then return nil end
    return name
end

-- 只用於 log 與節流鍵，不是身分
function I.claimedName(player)
    local ok, name = pcall(function() return player:getUsername() end)
    if ok and type(name) == "string" then return name end
    return "?"
end

local function seatId(player)
    local ok, id = pcall(function() return player:getOnlineID() end)
    if ok and type(id) == "number" and id >= 0 then return id end
    return nil
end

local function deadNow(obj)
    local ok, dead = pcall(function() return obj:isDead() end)
    return ok and dead == true
end

-- 座位觀察（Economy Id.observe）：同一 onlineID 上一位佔用者同 SteamID、別的名字、而且已死亡，
-- 或同一 SteamID 兩分鐘內由 OnNewGame 建過別的登入名 → 這次佔用有改名證據（suspect，整段佔用期間都算）。
function I.observe(player, now)
    local id = seatId(player)
    if id == nil then return nil end
    local name, sid = player:getUsername(), I.sidOf(player)
    local r = I.slots[id]
    if r ~= nil and r.name == name and r.sid == sid and now - r.seen <= I.SLOT_GAP_MS then
        r.seen, r.obj = now, player
        return r
    end
    local other = nil
    if validSid(sid) then
        local ng = I.newGames[sid]
        local prevDead = r ~= nil and r.obj ~= nil and deadNow(r.obj)
        if prevDead and r.sid == sid and r.name ~= name and now - r.seen <= I.SLOT_GAP_MS then
            other = r.name
        elseif ng ~= nil and ng.name ~= name and now - ng.at <= I.NEWGAME_WINDOW_MS then
            other = ng.name
        end
    end
    r = { name = name, sid = sid, seen = now, obj = player, suspect = other ~= nil, other = other }
    I.slots[id] = r
    return r
end

-- 建立安全屋時綁定建立者（§4.2）。Steam 模式、名字還沒綁定才寫；不通過就拒絕建立並寫 audit。
-- 回傳 true 或 false, 原因
function I.bindForClaim(player, now)
    if not I.steamMode() then return true end
    local R = MSH.Registry
    local name = player:getUsername()
    local sid = I.sidOf(player)
    local b = R.binding(name)
    if b ~= nil then
        if b.sid == sid then return true end
        return false, "SID_MISMATCH"
    end
    if not MSH.validUsername(name) or not validSid(sid) then return false, "INVALID" end
    if deadNow(player) then return false, "DEAD" end
    local r = I.observe(player, now)
    if r == nil then return false, "NO_SEAT" end
    if r.suspect then
        MSH.Audit.write("BIND_REFUSED", { actor = name, code = "RENAME_EVIDENCE", detail = tostring(r.other) })
        return false, "RENAME_EVIDENCE"
    end
    if not R.setBinding(name, sid, "CLAIM", now) then return false, "WRITE_FAILED" end
    MSH.Audit.write("BIND", { actor = name, code = "CLAIM" })
    return true
end

-- 伺服器 OnNewGame：只有 CreatePlayerPacket 觸發（首次進場、重生、分割畫面加入）
function I.onNewGame(player)
    if player == nil or not MSH.Health.dedicated() or not I.steamMode() then return end
    local R = MSH.Registry
    if R.privateUnreadable then return end
    local name, sid = player:getUsername(), I.sidOf(player)
    if not MSH.validUsername(name) or not validSid(sid) then return end
    local now = getTimestampMs()
    I.newGames[sid] = { name = name, at = now }
    local b = R.binding(name)
    if b == nil then
        if R.setBinding(name, sid, "NEWGAME", now) then MSH.Audit.write("BIND", { actor = name, code = "NEWGAME" }) end
    elseif b.sid ~= sid then
        MSH.Audit.write("BIND_CONFLICT", { actor = name, code = "SID_MISMATCH" })
    end
end

-- 每秒：觀察座位（Steam 模式）＋身分異常偵測（主玩家名不合法或以 @MSH: 開頭 → hostile mode，§4.2）。
-- 合法主帳號每次登入都過同一個 isValidUserName（ServerWorldDatabase.java:766-788），同一程序內不可能不合法。
function I.tick(now)
    if I.lastScan ~= nil and now - I.lastScan < I.SCAN_MS then return end
    I.lastScan = now
    local hostile = {}
    local steam = I.steamMode()
    local list = getOnlinePlayers()
    for i = 0, list:size() - 1 do
        local p = list:get(i)
        if playerNum(p) == 0 then
            local name = p:getUsername()
            local bad = type(name) ~= "string" or string.sub(name, 1, #MSH.SERVICE_PREFIX) == MSH.SERVICE_PREFIX
            if not bad and isValidUserName ~= nil and isValidUserName(name) ~= true then bad = true end
            if bad then hostile[#hostile + 1] = MSH.logSafe(name) end
            if steam then I.observe(p, now) end
        end
    end
    MSH.Health.setHostile(hostile, now)
end

if first then
    Events.OnNewGame.Add(function(player) MSH.Identity.onNewGame(player) end)
end
