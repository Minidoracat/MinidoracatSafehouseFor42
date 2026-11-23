-- MinidoracatSafehouse/ZombieSync.lua：伺服器刪掉安全屋範圍內的殭屍後廣播 zombiesRemoved（server Zombies.lua：新建立的，
-- 以及有人在家時範圍內的）。
-- 同一幀已送出的那幾隻，客戶端要自己拿掉，否則留到 5 秒沒更新才清（IsoZombie.java:3450-3453）。
-- 移除照原版收到刪除封包的做法（ZombieDeleteOnClientPacket.parse → VirtualZombieManager.removeZombieFromWorld :69-75）。
-- 殭屍同步走不可靠封包（ZombieSynchronizationUnreliablePacket），可能比通知晚到；查無此 id 時原版會照封包建立
-- （NetworkZombieSimulator.parseZombie :157-175，id 在 createRealZombieAlways 觸發 OnZombieCreate 之後才設），
-- 所以每個 id 記 HOLD_MS：期間新建立的殭屍下一個 OnTick 看 id，對中就拿掉。HOLD_MS 比引擎自清的 5 秒短，
-- 過了就丟：onlineId 是依序配發、會繞回的 short（IsoObjectID.allocateID），不能永久記著。
-- 沒有待處理的 id 時不掛 OnZombieCreate／OnTick。

if not isClient() then return end

require "MinidoracatSafehouse/Contract"

local MSH = MinidoracatSafehouse
local first = MSH.ZombieSync == nil
local ZS = MSH.ZombieSync or {}
MSH.ZombieSync = ZS

ZS.HOLD_MS = 3000
ZS.pending = ZS.pending or {}   -- onlineId → 到期時間（getTimestampMs）
ZS.fresh = ZS.fresh or {}       -- 有待處理 id 時新建立、還沒看過 id 的殭屍
ZS.armed = ZS.armed or false

local function remove(z)
    z:getEmitter():unregister()
    z:removeFromWorld()
    z:removeFromSquare()
end

if first then
    ZS.onCreateFn = function(z) local f = MSH.ZombieSync.fresh; f[#f + 1] = z end
    ZS.onTickFn = function() MSH.ZombieSync.onTick() end
end

function ZS.onServerCommand(module, command, args)
    if module ~= MSH.MODULE or command ~= "zombiesRemoved" or type(args) ~= "table" or type(args.ids) ~= "table" then return end
    local until_, any = getTimestampMs() + ZS.HOLD_MS, false
    for _, id in ipairs(args.ids) do
        if MSH.isInt(id) then ZS.pending[id], any = until_, true end
    end
    if not any then return end
    local zl = getCell():getZombieList()
    for i = zl:size() - 1, 0, -1 do
        local z = zl:get(i)
        if ZS.pending[z:getOnlineID()] then remove(z) end
    end
    if not ZS.armed then
        ZS.armed = true
        Events.OnZombieCreate.Add(ZS.onCreateFn)
        Events.OnTick.Add(ZS.onTickFn)
    end
end

function ZS.onTick()
    local fresh = ZS.fresh
    if #fresh > 0 then
        ZS.fresh = {}
        for i = 1, #fresh do
            if ZS.pending[fresh[i]:getOnlineID()] then remove(fresh[i]) end
        end
    end
    -- 走訪中不改表（Kahlua 的 next 遇到被清掉的 key 不保證能接下去），先收再刪
    local now, done, left = getTimestampMs(), nil, false
    for id, exp in pairs(ZS.pending) do
        if exp <= now then done = done or {}; done[#done + 1] = id else left = true end
    end
    if done then
        for i = 1, #done do ZS.pending[done[i]] = nil end
    end
    if not left then
        ZS.armed = false
        Events.OnZombieCreate.Remove(ZS.onCreateFn)
        Events.OnTick.Remove(ZS.onTickFn)
    end
end

if first then
    Events.OnServerCommand.Add(function(module, command, args) MSH.ZombieSync.onServerCommand(module, command, args) end)
end
