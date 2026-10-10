-- MinidoracatSafehouse/Mirror.lua：客戶端原生安全屋 mirror 的 remove 與校正、沙盒同步（計畫 §6.3、§7.1）。
-- upsert 走原生 SafehouseSync（伺服器 kickUserFromSafehouse 觸發），不需要這裡處理；原生沒有 remove 廣播，
-- 伺服器送自訂 nativeRemove。只移除 owner 恰好等於 @MSH:<claimId> 的本地物件：SafehouseSync（RELIABLE 非 ORDERED）
-- 和自訂指令沒有順序保證，同 rect 可能已是新 claim，所以不比 rect；foreign 一律不動、永不清空整份清單。
-- 晚到的舊 SafehouseSync 會把屋加回來（SafehouseSyncPacket.java:87-89）：每個 remove 保留 60 秒 tombstone，
-- 期間 OnSafehousesChanged 再移除；之後靠校正兜底（native2-mp 2026-10-10 實測）。
-- 校正：首次在 OnGameStart 掛的一次性 OnTick（OnGameStart 當下送會走錯路徑，pitfalls.md「MP client 不可在
-- OnGameStart 直接送 sendClientCommand」）、之後每 10 分鐘、remove seq 有缺號時。

if not isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Settings"

local MSH = MinidoracatSafehouse
local first = MSH.Mirror == nil
local M = MSH.Mirror or {}
MSH.Mirror = M

M.TOMB_MS = 60000
M.PERIOD_MS = 600000
M.RETRY_MS = 5500          -- 伺服器校正 cooldown 5 秒（Calibrate.lua），太快重送會被丟、沒有回覆
M.tombs = M.tombs or {}    -- claimId → tombstone 到期時間
M.purging = false

-- 本地 SafeHouse 清單（SafeHouse.getSafehouseList SafeHouse.java:652、getOwner :656）
local function localHouses()
    return MSH.toArray(SafeHouse.getSafehouseList())
end

-- 先收集再逐一移除（native2-mp removeOwned）。客戶端 removeSafeHouse 會同步觸發 OnSafehousesChanged
-- （SafeHouse.java:306-320），purging 旗標擋掉自己觸發的巢狀事件。
local function removeOwned(claimId)
    local owner = MSH.marker(claimId)
    local hit = {}
    for _, h in ipairs(localHouses()) do
        if h:getOwner() == owner then hit[#hit + 1] = h end
    end
    if #hit == 0 then return 0 end
    M.purging = true
    local ok, err = pcall(function()
        for _, h in ipairs(hit) do SafeHouse.removeSafeHouse(h) end
    end)
    M.purging = false
    if not ok then MSH.log("mirror remove failed: " .. tostring(err)) end
    return #hit
end

local function removeWithTomb(claimId, now)
    M.tombs[claimId] = now + M.TOMB_MS
    removeOwned(claimId)
end

-- remove delta 序號：每次伺服器 boot（含熱重載）一組；換 bootId 就重設基準，同一 boot 有缺號就排校正
local function track(bootId, seq)
    if type(bootId) ~= "string" or not MSH.isInt(seq) then return end
    if bootId ~= M.bootId then
        M.bootId, M.seq = bootId, seq
        return
    end
    if seq > M.seq + 1 then M.want = true end
    if seq > M.seq then M.seq = seq end
end

function M.onNativeRemove(args)
    if not MSH.isInt(args.claimId) then return end
    removeWithTomb(args.claimId, getTimestampMs())
    track(args.bootId, args.seq)
end

-- 校正結果：照 remove 清單移除（同樣留 tombstone），序號基準換成伺服器回覆當下的值
function M.onCalibrated(res)
    if res.ok ~= true or type(res.remove) ~= "table" then return end
    local now = getTimestampMs()
    for _, id in ipairs(res.remove) do
        if MSH.isInt(id) then removeWithTomb(id, now) end
    end
    if type(res.bootId) == "string" and MSH.isInt(res.seq) then
        if res.bootId ~= M.bootId or M.seq == nil or res.seq > M.seq then M.bootId, M.seq = res.bootId, res.seq end
    end
end

local function typeOk(o, v)
    if o.type == "bool" then return type(v) == "boolean" end
    if o.type == "string" then return type(v) == "string" end
    if o.type == "double" then return MSH.isFinite(v) end
    return MSH.isInt(v)
end

-- 伺服器存好沙盒後的快照：本機 SandboxOptions 跟著改再投影到 SandboxVars，否則原版沙盒 UI 存檔會把舊值整份送回
-- （GameServer.java:1694-1708；VM MinidoracatVehicleManager_Client.lua:123-135 同法）。
-- 只收 Settings 認得、型別相符的鍵（set 遇到未知選項名會丟例外，SandboxOptions.java:572-582；toLua :279-285）
function M.onSandboxSync(args)
    local opts, any = getSandboxOptions(), false   -- LuaManager.java:5809
    for k, v in pairs(args) do
        local o = type(k) == "string" and MSH.Settings.BY_KEY[k] or nil
        if o ~= nil and typeOk(o, v) then
            local ok, err = pcall(function() opts:set(MSH.Settings.optionName(k), v) end)
            if ok then any = true else MSH.log("sandboxSync " .. k .. " failed: " .. tostring(err)) end
        end
    end
    if any then opts:toLua() end
end

-- OnServerCommand（GameClient.java:1071）
function M.onServerCommand(module, command, args)
    if module ~= MSH.MODULE or type(args) ~= "table" then return end
    if command == "nativeRemove" then
        M.onNativeRemove(args)
    elseif command == "result" and args.command == "calibrate" then
        M.onCalibrated(args)
    elseif command == "sandboxSync" then
        M.onSandboxSync(args)
    end
end

-- 晚到的舊 SafehouseSync 把已移除的屋加回來時（SafehouseSyncPacket.java:99 觸發）：tombstone 期間再移除；過期的丟掉
function M.onSafehousesChanged()
    if M.purging then return end
    local now = getTimestampMs()
    local expired, live = {}, {}
    for id, exp in pairs(M.tombs) do
        if now >= exp then expired[#expired + 1] = id else live[#live + 1] = id end
    end
    for _, id in ipairs(expired) do M.tombs[id] = nil end
    for _, id in ipairs(live) do removeOwned(id) end
end

-- 送校正：本地 owner 是標記的原生安全屋（最多 CALIBRATE_MAX 筆）；查詢不帶 requestId。
-- sendClientCommand(player, ...)（LuaManager.java:8936-8951）、getSpecificPlayer（:4167）
function M.calibrate(now)
    local player = getSpecificPlayer(0)
    if player == nil then return false end
    local houses = {}
    for _, h in ipairs(localHouses()) do
        local id = MSH.claimIdOf(h:getOwner())
        if id ~= nil and #houses < MSH.LIMIT.CALIBRATE_MAX then
            houses[#houses + 1] = { claimId = id, x = h:getX(), y = h:getY(), w = h:getW(), h = h:getH() }
        end
    end
    local payload = { protocol = MSH.PROTOCOL, houses = houses }
    if M.bootId ~= nil then payload.bootId = M.bootId end
    sendClientCommand(player, MSH.MODULE, "calibrate", payload)
    M.sentAt, M.want = now, false
    return true
end

-- 一次性：OnGameStart 只掛它；第一行先移除自己再送（pitfalls.md 同條的固定形狀）
local function firstTick()
    Events.OnTick.Remove(firstTick)
    M.started = true
    M.calibrate(getTimestampMs())
end

function M.onGameStart()
    Events.OnTick.Add(firstTick)
end

-- 常駐：每 10 分鐘、seq 缺號、首次因沒有玩家沒送成時補送（間隔至少 RETRY_MS）
function M.onTick()
    if not M.started then return end
    local now = getTimestampMs()
    if M.sentAt == nil or now - M.sentAt >= M.PERIOD_MS then M.want = true end
    if M.want and (M.sentAt == nil or now - M.sentAt >= M.RETRY_MS) then M.calibrate(now) end
end

if first then
    Events.OnServerCommand.Add(function(module, command, args) MSH.Mirror.onServerCommand(module, command, args) end)
    Events.OnSafehousesChanged.Add(function() MSH.Mirror.onSafehousesChanged() end)
    Events.OnGameStart.Add(function() MSH.Mirror.onGameStart() end)
    Events.OnTick.Add(function() MSH.Mirror.onTick() end)
end
