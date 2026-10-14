-- MinidoracatSafehouse/Respawn.lua：安全屋重生點（使用者 2026-10-14「我們的安全屋可以增加支援安全屋重生嗎?」）。
-- 每人最多一個點 { x, y, z }（整數格），存伺服器私有檔（Registry.setSpawn；玩家的家在哪不公開）。
-- 設點：伺服器設定 SafehouseAllowRespawn 開著、claim ACTIVE、自己在那間有角色（Claims.roleOf），而且伺服器端座標
--   （不是客戶端送的）落在那間的某一塊裡。點＝當時站的那一格。
-- 套用：伺服器 OnNewGame（CreatePlayerPacket.java:301：原版已選好出生點，新角色還沒存進資料庫、也還沒回傳客戶端，
--   :302-307）把新角色放到點上。身分照 Identity.principal（Steam 模式比對綁定的 SteamID；:296-300 先設好名字與
--   SteamID）。點失效（沒有 ACTIVE 的 claim 含這一格、或自己在那間沒有角色）或總開關關著就不動：原版出生點照舊，
--   點保留（之後恢復資格又能用）。只改這個還沒送出的新角色，不移動活著的玩家、不用傳送 API。
--   樓上（或地下）的點：伺服器拿得到那格、而且那格是可站的地板（IsoCell.getGridSquare，IsoCell.java:3190，沒載入回 nil；
--   IsoGridSquare.TreatAsSolidFloor，IsoGridSquare.java:7704-7716：solidfloor 旗標、樓梯或斜面）才用存的 z，
--   否則落到同一個 x, y 的地面 z=0（主代理 2026-10-14）。存的點不改。
--   分割畫面次座位：CreatePlayerPacket 一律用連線登入名、新角色的 playerIndex 也還是 0（IsoPlayer.java:340、973-981），
--   所以次座位重生也會放到主帳號的點（不處理）。
-- 原版旗標（SafeHouse playersRespawn）：原版取 first-match 的那間、以 h/w 對調的中心出生（CreatePlayerPacket.java:268-274），
--   重建原生時旗標也會掉（SafeHouse.java:299-303）。開服時把 managed 原生上原版真的會採用的旗標換成本 MOD 的點
--   （只替私有檔從沒出現過 spawn 行的名字建；清除過的不再匯入），讀回私有檔確認寫進去了才清那個旗標，其餘旗標全清。

if isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Audit"
require "MinidoracatSafehouse/Registry"
require "MinidoracatSafehouse/Native"
require "MinidoracatSafehouse/Health"
require "MinidoracatSafehouse/Server"
require "MinidoracatSafehouse/Claims"

local MSH = MinidoracatSafehouse
local first = MSH.Respawn == nil
local Rs = MSH.Respawn or {}
MSH.Respawn = Rs

local CODE = MSH.CODE
local LC = MSH.LIFECYCLE
local Rect = MSH.Rect
local R = MSH.Registry
local N = MSH.Native
local S = MSH.Srv
local C = MSH.Claims

-- 原版同名選項（ServerOptions.java）當總開關：管理員關掉就和原版一樣不能在安全屋重生
function Rs.allowed()
    return MSH.Health.optionValue("SafehouseAllowRespawn") == "true"
end

-- 點仍有效：某間 ACTIVE 的 claim 有一塊含 (x, y)（任何 Z），而且 who 在那間有角色。回那筆紀錄或 nil。
-- claim 之間不重疊（建立與重畫都擋），所以最多一間含這一格
function Rs.claimOf(who, pt)
    for _, rec in ipairs(R.list()) do
        if rec.lifecycle == LC.ACTIVE and Rect.listContains(rec.rects, pt.x, pt.y) and C.roleOf(rec, who) then
            return rec
        end
    end
    return nil
end

-- 有效的重生點：pt, rec；沒有或失效回 nil
function Rs.validPoint(who)
    local pt = R.spawn(who)
    if pt == nil then return nil end
    local rec = Rs.claimOf(who, pt)
    if rec == nil then return nil end
    return pt, rec
end

-- detail 給自己看的欄位：allowed＝總開關；here＝自己的點在這間的某一塊裡（不論有沒有失效，給〔清除〕用）；
-- elsewhere＝有點、但不在這間
function Rs.view(rec, who)
    local pt = R.spawn(who)
    local here = pt ~= nil and Rect.listContains(rec.rects, pt.x, pt.y)
    return { allowed = Rs.allowed(), here = here and { x = pt.x, y = pt.y, z = pt.z } or nil,
        elsewhere = pt ~= nil and not here }
end

-- setRespawn { claimId, expectedRevision? }：用伺服器端座標驗證站在這間裡（IsoMovingObject.java:491、508）
function Rs.set(ctx)
    if not Rs.allowed() then return S.fail(CODE.RESPAWN_DISABLED) end
    local a = ctx.args
    local rec = R.get(a.claimId)
    local role = nil
    if rec ~= nil and R.isLive(rec) and not rec.malformed then role = C.roleOf(rec, ctx.who) end
    if role == nil then return S.fail(CODE.NOT_FOUND) end
    if rec.lifecycle ~= LC.ACTIVE then return S.fail(CODE.WRONG_LIFECYCLE) end
    if a.expectedRevision ~= nil and a.expectedRevision ~= rec.revision then return S.fail(CODE.STALE_REVISION) end
    local p = ctx.player
    local x, y, z = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
    if not Rect.listContains(rec.rects, x, y) then return S.fail(CODE.NOT_ON_SITE) end
    local bad = C.bindActor(ctx)
    if bad then return S.fail(bad) end
    if not R.setSpawn(ctx.who, { x = x, y = y, z = z }) then return S.fail(CODE.SAVE_FAILED) end
    MSH.Audit.write("RESPAWN_SET", { actor = ctx.who, claimId = rec.claimId })
    return S.ok({ claimId = rec.claimId, x = x, y = y, z = z })
end

-- clearRespawn {}：沒有點也回 OK；有點要刪時照其他 mutation 先綁定 actor（Claims.bindActor，改名跡象就拒絕）
function Rs.clear(ctx)
    if R.spawn(ctx.who) == nil then return S.ok({}) end
    local bad = C.bindActor(ctx)
    if bad then return S.fail(bad) end
    if not R.setSpawn(ctx.who, nil) then return S.fail(CODE.SAVE_FAILED) end
    MSH.Audit.write("RESPAWN_CLEAR", { actor = ctx.who })
    return S.ok({})
end

-- myRespawn {}：自己目前有效的點（客戶端死後重生選單用）；總開關關著或失效時沒有 point
function Rs.mine(ctx)
    local allowed = Rs.allowed()
    local pt, rec = nil, nil
    if allowed then pt, rec = Rs.validPoint(ctx.who) end
    return S.ok({ allowed = allowed, point = pt and { x = pt.x, y = pt.y, z = pt.z } or nil,
        claimId = rec and rec.claimId or nil })
end

-- 樓上（或地下）的點實際站的 z：拿得到那格而且是可站的地板才用存的 z，否則 0（檔頭）
function Rs.standZ(pt)
    if pt.z == 0 then return 0 end
    local sq = getCell():getGridSquare(pt.x, pt.y, pt.z)
    if sq ~= nil and sq:TreatAsSolidFloor() then return pt.z end
    return 0
end

-- 伺服器 OnNewGame（首次進場、重生、分割畫面加入）。這個 player 還不在線上名單（online=false），
-- 不要用 getPlayerByUserName。丟錯會中斷原版建角色，整段包 pcall
function Rs.onNewGame(player)
    if player == nil or not S.enabled or not S.ready or not Rs.allowed() then return end
    local name = MSH.Identity.principal(player)
    if name == nil then return end
    local pt, rec = Rs.validPoint(name)
    if pt == nil then return end
    local z = Rs.standZ(pt)
    -- setX/setY 同時設 next（IsoMovingObject.java:495-520），setZ 同時設 lastZ（:529-535）；last 另外補齊
    player:setX(pt.x + 0.5)
    player:setY(pt.y + 0.5)
    player:setZ(z)
    player:setLastX(pt.x + 0.5)
    player:setLastY(pt.y + 0.5)
    player:setLastZ(z)
    MSH.Audit.write("RESPAWN_APPLY", { actor = name, claimId = rec.claimId, code = z ~= pt.z and "GROUND" or nil })
end

-- 開服（首輪 reconcile 之後）：managed 原生上的原版旗標。原版真的會採用的（SafeHouse.hasSafehouse 的 first-match 就是這塊、
-- 而且這塊有旗標，SafeHouse.java:97-103、769-771）而且名字在 ACTIVE 的那間有角色、私有檔從沒有過他的 spawn 行
-- （Registry.spawnKnown：清除過的人，世界回滾帶回的舊旗標不再匯入）→ 換成那一塊的中心。
-- getFileWriter 的 PrintWriter 寫失敗不丟錯，所以全部寫完後讀回私有檔（Registry.fileSpawns），確認寫進去的才清那個旗標，
-- 沒確認的留著、下次開機再試；其餘旗標全清。稽核只記數量
function Rs.migrateLegacy()
    if not R.ready() or R.privateUnreadable then return end
    local todo, clear = {}, {}
    for claimId, entries in pairs(N.index().byClaim) do
        local rec = R.get(claimId)
        local active = rec ~= nil and rec.lifecycle == LC.ACTIVE
        for _, e in ipairs(entries) do
            local house = e.house
            for _, name in ipairs(MSH.toArray(house:getPlayersRespawn())) do   -- SafeHouse.java:648；先複製，最後才改
                name = tostring(name)
                if active and not R.spawnKnown(name) and C.roleOf(rec, name) and SafeHouse.hasSafehouse(name) == house then
                    local r = e.rect
                    local pt = { x = r.x + math.floor(r.w / 2), y = r.y + math.floor(r.h / 2), z = 0 }
                    todo[#todo + 1] = { house = house, name = name, pt = pt, written = R.setSpawn(name, pt) }
                else
                    clear[#clear + 1] = { house = house, name = name }
                end
            end
        end
    end
    local converted, failed = 0, 0
    local onDisk = #todo > 0 and R.fileSpawns() or nil
    for _, t in ipairs(todo) do
        local d = onDisk and onDisk[t.name]
        if t.written and d and d.x == t.pt.x and d.y == t.pt.y and d.z == t.pt.z then
            converted = converted + 1
            clear[#clear + 1] = t
        else
            failed = failed + 1
        end
    end
    for _, c in ipairs(clear) do c.house:setRespawnInSafehouse(false, c.name) end    -- SafeHouse.java:759-767
    if #clear + failed > 0 then
        MSH.Audit.write("RESPAWN_LEGACY", { code = failed > 0 and "PARTIAL" or "OK",
            detail = "converted=" .. converted .. " cleared=" .. #clear .. " failed=" .. failed })
    end
end

S.define("setRespawn", { kind = "mutation", fields = { claimId = "claimId", expectedRevision = "revision?" },
    run = function(ctx) return MSH.Respawn.set(ctx) end })
S.define("clearRespawn", { kind = "mutation", whenBlocked = true, fields = {},
    run = function(ctx) return MSH.Respawn.clear(ctx) end })
S.define("myRespawn", { kind = "query", fields = {}, run = function(ctx) return MSH.Respawn.mine(ctx) end })

S.hook("startup", "respawnLegacy", function() MSH.Respawn.migrateLegacy() end, 30)

if first then
    Events.OnNewGame.Add(function(player)
        local ok, err = pcall(MSH.Respawn.onNewGame, player)
        if not ok then MSH.log("respawn apply failed: " .. tostring(err)) end
    end)
end
