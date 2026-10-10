-- MinidoracatSafehouse/Identity.lua：玩家身分 principal(player) 與私有綁定表（家族 conventions.md「玩家身分」，計畫 §4.2）。
-- 伺服器上的 getUsername() 是客戶端送來的名字：重生與分割畫面走 ConnectCoopPacket，只擋空字串與在線重名
-- （ConnectCoopPacket.java:72-97），所以授權一律經 principal：
--   getPlayerNum() ~= 0 → nil（分割畫面次玩家沒有身分）；非 Steam 模式 → 名字；
--   Steam 模式：有綁定就比 SteamID，不符 → nil；沒綁定 → 名字（照 VehicleManager，不開嚴格模式）。
-- 綁定寫入來源：伺服器 OnNewGame（CreatePlayerPacket 觸發時名字＝連線登入名，CreatePlayerPacket.java:296-301）、
-- 上線時每秒掃描綁定在線主座位（LOGIN，使用者 2026-10-11）、建立安全屋與對既有安全屋的 mutation（CLAIM，2026-10-10），
-- 後兩者條件照 Economy「第一次看到即綁定」（bindChecked）。

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

-- 綁定的共用條件（Economy「第一次看到即綁定」，家族 conventions「玩家身分」第 1 點第 5 項）：名字與 SteamID 合法、
-- 活著、座位觀察過、沒有改名證據；通過才寫私有檔（先寫檔、成功才改記憶體）並寫 audit BIND（code＝src）。
-- 呼叫端已確認 Steam 模式、名字還沒綁定。回傳 true 或 false, 原因, 改名證據的另一個名字
local function bindChecked(player, now, src)
    local name, sid = player:getUsername(), I.sidOf(player)
    if not MSH.validUsername(name) or not validSid(sid) then return false, "INVALID" end
    if deadNow(player) then return false, "DEAD" end
    local r = I.observe(player, now)
    if r == nil then return false, "NO_SEAT" end
    if r.suspect then return false, "RENAME_EVIDENCE", r.other end
    if not MSH.Registry.setBinding(name, sid, src, now) then return false, "WRITE_FAILED" end
    MSH.Audit.write("BIND", { actor = name, code = src })
    return true
end

-- 建立安全屋與對既有安全屋的 mutation 時綁定 actor（§4.2）。Steam 模式、名字還沒綁定才寫；已綁定同 SteamID 通過。
-- 不通過就拒絕指令；RENAME_EVIDENCE 在這裡寫 audit（其他原因由呼叫端寫）。回傳 true 或 false, 原因
function I.bindForClaim(player, now)
    if not I.steamMode() then return true end
    local name = player:getUsername()
    local b = MSH.Registry.binding(name)
    if b ~= nil then
        if b.sid == I.sidOf(player) then return true end
        return false, "SID_MISMATCH"
    end
    local ok, why, other = bindChecked(player, now, "CLAIM")
    if why == "RENAME_EVIDENCE" then
        MSH.Audit.write("BIND_REFUSED", { actor = name, code = why, detail = tostring(other) })
    end
    return ok, why
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

I.REFUSE_LOG_MS = 3600000   -- 上線綁定被拒：同一名字一小時最多一行 BIND_REFUSED（每秒重試，不灌 log）
I.WRITE_RETRY_MS = 60000    -- 上線綁定寫私有檔失敗：同一名字 60 秒後才再試（不每秒開檔）
I.writeRetryAt = I.writeRetryAt or {}   -- 名字 → 寫檔失敗後下一次可重試的時間

-- 上線綁定（使用者 2026-10-11：中途安裝的伺服器不必等管理員匯入）：在線主座位、還沒綁定的名字，
-- 照 bindChecked 同一組條件綁定，來源 LOGIN。私有檔讀不開時不寫（fail closed，同 onNewGame）。
-- 寫檔失敗退避 WRITE_RETRY_MS；其他拒絕（改名證據等）不寫檔，照樣每秒重試。
local function bindOnLogin(p, now)
    local R = MSH.Registry
    if R.privateUnreadable or R.bindings == nil then return I.observe(p, now) end
    local name = p:getUsername()
    if R.binding(name) ~= nil then return I.observe(p, now) end
    local retry = I.writeRetryAt[name]
    if retry ~= nil and now < retry then return I.observe(p, now) end
    I.writeRetryAt[name] = nil
    local ok, why, other = bindChecked(p, now, "LOGIN")
    if not ok then
        if why == "WRITE_FAILED" then I.writeRetryAt[name] = now + I.WRITE_RETRY_MS end
        MSH.Audit.throttled("BIND_REFUSED|" .. MSH.logSafe(name), I.REFUSE_LOG_MS, "BIND_REFUSED",
            { actor = name, code = why, detail = "LOGIN " .. tostring(other or "-") }, now)
    end
end

-- 每秒：觀察座位與上線綁定（Steam 模式）＋身分異常偵測（主玩家名不合法或以 @MSH: 開頭 → hostile mode，§4.2）。
-- 合法主帳號每次登入都過同一個 isValidUserName（ServerWorldDatabase.java:766-788），同一程序內不可能不合法。
-- 不合法的名字不綁定（bindChecked 的 validUsername 擋掉）。
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
            if steam then bindOnLogin(p, now) end
        end
    end
    MSH.Health.setHostile(hostile, now)
end

if first then
    Events.OnNewGame.Add(function(player) MSH.Identity.onNewGame(player) end)
end
