-- MinidoracatSafehouse/Vehicles.lua：擋車的伺服器保底（使用者 2026-10-15：車已經進去，就讓人下車傳到屋外、車留原地）。
-- 擋車本身在駕駛的客戶端（VehiclesClient.lua；車的物理只在那裡算，伺服器推不動車）。這裡處理客戶端沒擋到的：
-- 每 tick 看坐在車上的人，所在格是他不能進的安全屋（SafeHouse.isSafehouseAllowTrepass，和走路同一套）→
-- kickUserFromSafehouse：客戶端先下車再傳到那塊的 (x−1, y−1)（SafeHouse.java:832-850、TeleportPacket.processClient:60-79），
-- 車留在原地。原版週期趕人跳過車上的人（SafeHouse.checkTrespass:536-537），走路的照原版。
-- 伺服器上車上的人的位置跟著車（E2E vblock-mp：座位越線後 206–242 ms 傳出）。

if isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Audit"
require "MinidoracatSafehouse/Native"
require "MinidoracatSafehouse/Server"

local MSH = MinidoracatSafehouse
local G = MSH.Vehicles or {}
MSH.Vehicles = G

G.GAP_MS = 2000    -- 同一人兩次傳送的間隔：客戶端下車、傳送要 0.2 秒左右，這段時間伺服器還看到他在車上
G.LOG_MS = 60000   -- 稽核每人每分鐘最多一行
G.sentAt = G.sentAt or {}   -- username → 上次傳送的時間

function G.check(p, now)
    local x, y = math.floor(p:getX()), math.floor(p:getY())
    local sq = getCell():getGridSquare(x, y, 0)
    if sq == nil or SafeHouse.isSafehouseAllowTrepass(sq, p) then return end
    local house = SafeHouse.getSafeHouse(sq)
    local name = p:getUsername()
    local last = G.sentAt[name]
    if house == nil or (last ~= nil and now - last < G.GAP_MS) then return end
    G.sentAt[name] = now
    MSH.Native.revoke(house, name)
    MSH.Audit.throttled("VEHICLE|" .. MSH.logSafe(name), G.LOG_MS, "VEHICLE_TRESPASS",
        { actor = name, claimId = MSH.claimIdOf(house:getOwner()), detail = x .. "," .. y }, now)
end

function G.tick(now)
    if not MSH.Srv.netUp then return end   -- 開服前 getOnlinePlayers 會 NPE（Server.lua S.netUp）
    local list = getOnlinePlayers()
    for i = 0, list:size() - 1 do
        local p = list:get(i)
        if p:getVehicle() ~= nil then G.check(p, now) end
    end
end

MSH.Srv.hook("tick", "vehicles", function(now) MSH.Vehicles.tick(now) end)
