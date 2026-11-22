-- MinidoracatSafehouse/Zombies.lua：沙盒 NoZombieSpawn 開著時，移除在安全屋範圍內（原版安全屋與停用中的屋都算）新建立的殭屍。
-- 只看 OnZombieCreate（只有 VirtualZombieManager.createRealZombieAlways 觸發，:202）：那時殭屍還沒進清單、沒有 onlineId，
-- 位置也可能還要改（ZombiePopulationManager.addZombieStanding 建好後才 setX），所以先排隊，下一個 OnTick 才看所在格。
-- 多數殭屍（重生、族群實體化、未探索房間的室內殭屍、建築故事）在同一幀的 OnTick 之前建立，刪的時候還沒送給客戶端；
-- 但車禍故事（ServerMap.postupdate 的 IsoChunk.update）和排在本 MOD 後面的 OnTick 回呼建的，同一幀就送出去了。
-- removeFromWorld 不送刪除封包（原版的 NetworkZombiePacker.deleteZombie 沒 expose 給 Lua），所以刪掉的 onlineId 一律
-- 廣播 zombiesRemoved，客戶端照原版收到刪除封包的做法移除，並在短時間內擋下比通知晚到的同步（ZombieSync.lua）。
-- 走進來的不當場刪，屍體起身（IsoDeadBody.reanimate 自己 new IsoZombie）也不觸發這個事件；但那一帶卸載時引擎把殭屍
-- 收回族群、再載入時重建（ZombiePopulationManager.removeChunkFromWorld :368-427 → addZombieStanding），那時就會刪掉
-- （玩家屍變不收回、也不刪）。

if isClient() then return end

require "MinidoracatSafehouse/Settings"
require "MinidoracatSafehouse/Server"

local MSH = MinidoracatSafehouse
local first = MSH.Zombies == nil
local Z = MSH.Zombies or {}
MSH.Zombies = Z
Z.queue = Z.queue or {}

-- 每隻殭屍都會進來（開服載入、族群實體化一幀可能上百隻）：只讀一鍵，關著什麼都不留
function Z.onCreate(z)
    if not MSH.Srv.enabled or not MSH.Settings.noZombieSpawn() then return end
    Z.queue[#Z.queue + 1] = z
end

function Z.flush()
    local q = Z.queue
    if #q == 0 then return end
    Z.queue = {}
    local ids = nil
    for i = 1, #q do
        local z = q[i]
        local sq = z:getSquare()
        local id = z:getOnlineID()
        -- onlineId -1：沒拿到 id、已回到物件池（createRealZombieAlways :210-215），或這一幀已被別處移除
        -- 玩家屍變照原版 /removezombies 的預設也不刪（RemoveZombiesCommand.java:82）
        if id ~= -1 and sq ~= nil and not z:isReanimatedPlayer() and SafeHouse.getSafeHouse(sq) ~= nil then
            z:removeFromWorld()
            z:removeFromSquare()
            ids = ids or {}
            ids[#ids + 1] = id
        end
    end
    if ids and MSH.Srv.netUp then sendServerCommand(MSH.MODULE, "zombiesRemoved", { ids = ids }) end
end

MSH.Srv.hook("tick", "zombies", function() MSH.Zombies.flush() end)

if first then
    Events.OnZombieCreate.Add(function(z) MSH.Zombies.onCreate(z) end)
end
