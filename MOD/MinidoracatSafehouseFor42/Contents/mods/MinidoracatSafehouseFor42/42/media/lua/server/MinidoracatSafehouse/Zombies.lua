-- MinidoracatSafehouse/Zombies.lua：安全屋範圍內的殭屍，兩個沙盒選項（都預設關，各自獨立）。刪掉的 onlineId 合成一則廣播。
--
-- NoZombieSpawn：移除在安全屋範圍內（原版安全屋與停用中的屋都算）新建立的殭屍。
-- 只看 OnZombieCreate（只有 VirtualZombieManager.createRealZombieAlways 觸發，:202）：那時殭屍還沒進清單、沒有 onlineId，
-- 位置也可能還要改（ZombiePopulationManager.addZombieStanding 建好後才 setX），所以先排隊，下一個 OnTick 才看所在格。
-- 多數殭屍（重生、族群實體化、未探索房間的室內殭屍、建築故事）在同一幀的 OnTick 之前建立，刪的時候還沒送給客戶端；
-- 但車禍故事（ServerMap.postupdate 的 IsoChunk.update）和排在本 MOD 後面的 OnTick 回呼建的，同一幀就送出去了。
-- removeFromWorld 不送刪除封包（原版的 NetworkZombiePacker.deleteZombie 沒 expose 給 Lua），所以刪掉的 onlineId 一律
-- 廣播 zombiesRemoved，客戶端照原版收到刪除封包的做法移除，並在短時間內擋下比通知晚到的同步（ZombieSync.lua）。
-- 只開這一個時，走進來的不當場刪，屍體起身（IsoDeadBody.reanimate 自己 new IsoZombie）也不觸發這個事件；但那一帶卸載時
-- 引擎把殭屍收回族群、再載入時重建（ZombiePopulationManager.removeChunkFromWorld :368-427 → addZombieStanding），那時就會刪掉
-- （玩家屍變不收回、也不刪）。
--
-- ClearZombiesAtHome：名單上的活人（屋主或成員）站在範圍內時，每 SWEEP_MS 把那間範圍內的活殭屍刪掉，走進來的也算。
-- 「在家」照原生名單（SafeHouse.playerAllowed(String) :288-290，引擎記到訪也用它）：管理員路過、不在名單上的人不算；
-- 名字先過 Identity.principal（分割畫面次座位、SteamID 對不上的不算）。
-- 多塊安全屋每塊同一個 owner 標記（Native.lua），人站在其中一塊就整間一起清；原版屋一間一間算。
-- 刪掉已經有 owner 客戶端的殭屍：removeFromWorld 把它移出 zombieMap、清掉 owner（IsoZombie.java:4335-4349），owner 之後
-- 送上來的同步查不到 id 就丟（NetworkZombiePacker.parseZombie :71-74），不會建回來。
-- 沒人在家時只走一次在線玩家、不碰殭屍清單；選項關著時每秒讀一次鍵。

if isClient() then return end

require "MinidoracatSafehouse/Settings"
require "MinidoracatSafehouse/Server"

local MSH = MinidoracatSafehouse
local first = MSH.Zombies == nil
local Z = MSH.Zombies or {}
MSH.Zombies = Z
Z.queue = Z.queue or {}

Z.SWEEP_MS = 1000   -- shortcut: 一次掃完整份殭屍清單，清單上萬隻、單次超過 5 ms 再分幀

-- 照實際座標找包住它的原生安全屋。不用 getSquare()：伺服器上有 owner 的殭屍，current 是 owner 客戶端送來的
-- 預測／目標點所在格（NetworkZombiePacker.applyZombie :225-233），追人的殭屍還在屋外時那一格就可能在屋內
local function houseAt(o)
    local x, y = math.floor(o:getX()), math.floor(o:getY())
    return SafeHouse.getSafehouseOverlapping(x, y, x + 1, y + 1)
end

-- 能刪就刪，id 收進 Z.out（刪了還沒通知客戶端的）。先讀 id 再刪（removeFromWorld 之後變 -1）。不碰的：
-- onlineId -1（沒拿到 id、已回到物件池 createRealZombieAlways :210-215，或這一幀已被別處移除）；
-- 玩家屍變（照原版 /removezombies 的預設，RemoveZombiesCommand.java:82；拖行中的屍體起身也帶這個旗標）；
-- 已經死亡、還沒變成屍體的（刪了屍體和身上的東西會一起消失）
local function take(z)
    local id = z:getOnlineID()
    if id == -1 or z:isReanimatedPlayer() or z:isDead() then return end
    z:removeFromWorld()
    z:removeFromSquare()
    local out = Z.out or {}
    Z.out = out
    out[#out + 1] = id
end

-- 每隻殭屍都會進來（開服載入、族群實體化一幀可能上百隻）：只讀一鍵，關著什麼都不留
function Z.onCreate(z)
    if not MSH.Srv.enabled or not MSH.Settings.noZombieSpawn() then return end
    Z.queue[#Z.queue + 1] = z
end

function Z.flush()
    local q = Z.queue
    if #q == 0 then return end
    Z.queue = {}
    for i = 1, #q do
        local sq = q[i]:getSquare()
        if sq ~= nil and SafeHouse.getSafeHouse(sq) ~= nil then take(q[i]) end
    end
end

-- 有人在家的屋用什麼認：受管屋每塊同一個 owner 標記，整間一起清；原版屋的 owner 是人名，同一個名字名下
-- 可能不只一間（管理員建的、遷移留下的、其他 MOD 建的），用那間的物件自己（引擎每次回清單裡同一個物件）
local function keyOf(house)
    local owner = house:getOwner()
    if MSH.claimIdOf(owner) ~= nil then return owner end
    return house
end

-- 有人在家的屋（keyOf → true）；沒有就 nil。名字是 owner 標記的不算（playerAllowed 會拿它和 owner 比）
local function homes()
    local home = nil
    local list = getOnlinePlayers()
    for i = 0, list:size() - 1 do
        local p = list:get(i)
        local house = not p:isDead() and houseAt(p) or nil
        local who = house ~= nil and MSH.Identity.principal(p) or nil
        if who ~= nil and MSH.claimIdOf(who) == nil and house:playerAllowed(who) then
            home = home or {}
            home[keyOf(house)] = true
        end
    end
    return home
end

function Z.sweep(now)
    if Z.lastSweep ~= nil and now - Z.lastSweep < Z.SWEEP_MS then return end
    Z.lastSweep = now
    -- 開服前 getOnlinePlayers 會 NPE（Server.lua S.netUp）
    if not MSH.Srv.netUp or not MSH.Settings.clearZombiesAtHome() then return end
    local home = homes()
    if home == nil then return end
    local zl = getCell():getZombieList()
    for i = zl:size() - 1, 0, -1 do   -- removeFromWorld 會把自己移出清單，倒著走
        local z = zl:get(i)
        local house = houseAt(z)
        if house ~= nil and home[keyOf(house)] then take(z) end
    end
end

local function send()
    local ids = Z.out
    if ids == nil then return end
    Z.out = nil
    if MSH.Srv.netUp then sendServerCommand(MSH.MODULE, "zombiesRemoved", { ids = ids }) end
end

-- 兩個選項這一幀刪掉的合成一則。flush／sweep 中途丟錯（hook 記 log）時 Z.out 留著，下一個 OnTick 一開頭就送：
-- 已經刪掉的不能漏（owner 客戶端自己模擬的殭屍沒有 5 秒自清，IsoZombie.java:3300）
function Z.tick(now)
    send()
    Z.flush()
    Z.sweep(now)
    send()
end

MSH.Srv.hook("tick", "zombies", function(now) MSH.Zombies.tick(now) end)

if first then
    Events.OnZombieCreate.Add(function(z) MSH.Zombies.onCreate(z) end)
end
