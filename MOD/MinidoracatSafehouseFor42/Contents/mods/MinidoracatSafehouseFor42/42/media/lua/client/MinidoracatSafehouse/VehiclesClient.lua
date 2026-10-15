-- MinidoracatSafehouse/VehiclesClient.lua：擋車（使用者 2026-10-15）。車上（含拖著的車）有任何一個人不能進的安全屋，
-- 車就開不進去；判定和走路同一套（SafeHouse.isSafehouseAllowTrepass，SafeHouse.java:224-243：屋主、名單、
-- 管理員能力、伺服器選項）。原版只在走路時擋，週期趕人也跳過車上的人（SafeHouse.checkTrespass:536-537）。
-- 車（連同拖車）的物理只在駕駛的客戶端算（BaseVehicle.java:3942-3966、3979-4004），伺服器推不動車，所以擋在這裡；
-- 伺服器 Vehicles.lua 保底（車已經在屋裡：不能進的人下車傳出）。依據與實測：safehouse-dev references/vehicles.md、
-- E2E vblock-mp。
-- 每幀（OnPlayerUpdate：只有本機玩家，在 updateWhileInVehicle 之前，IsoPlayer.java:2286、2339）看本機駕駛的車與它拖的車：
--   車身＝腳本 extents 加重心偏移的矩形（同 BaseVehicle.getClosestPointOnExtents:4971-4997）外加 PAD，
--   對附近每塊不能進的原生安全屋做 SAT：
--   1) 照目前速度再走 LOOK_FRAMES 幀（至少 LOOK_MIN 秒）會碰到 → setForceBrake（1 秒、×13、掛空檔，
--      CarController.updateControls:974-980）＋速度歸零；
--   2) 從外面穿進去（卡頓、被撞），上一個合法位置在每塊外面 → 拉回那裡（setWorldTransform → Bullet.teleportVehicle，
--      BaseVehicle.java:4049-4067）＋強制煞車＋歸零；車和拖車的位置在同一幀存、一起拉回；
--   3) 本來就壓在裡面（車停著之後才建屋、改分享）→ 棘輪：記住最淺的位置，比它深 DEEPER 以上就拉回那裡＋歸零，
--      往外開照常。這裡不強制煞車：煞車會掛空檔 1 秒，貼著邊界的晃動一直重新觸發，車就倒不出去（E2E sh-vblock-1015d）。
--   歸零用 applyImpulseFromHitPlant(車自己, 質量 ÷ (0.3 × fudgedMass))：列表衝量在下一個物理子步 ×30 套用
--   （:3590-3631、5556-5565），relPos 0 沒有力矩，也不佔 addImpulse 的單一槽；速度和上次送的時候完全相同＝
--   物理還沒走，不重送（同一步疊兩次會反彈）。

if not isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Client"

local MSH = MinidoracatSafehouse
local first = MSH.VehiclesClient == nil
local V = MSH.VehiclesClient or {}
MSH.VehiclesClient = V

V.PAD = 0.1          -- 車身外加的餘裕（公尺）：停在邊界外約這麼遠
V.LOOK_FRAMES = 2    -- 預測幾幀：24–600 FPS、500 ms 卡頓都擋得住（E2E vblock-mp）
V.LOOK_MIN = 0.05    -- 預測至少幾秒
V.DEEPER = 0.05      -- 本來就壓在裡面時，比最淺的位置深這麼多（公尺）才拉回：小於它的晃動不算
V.NEAR = 60          -- 只看離車這麼近的安全屋（公尺）
V.CACHE_MS = 500     -- 不能進的安全屋多久重算一次：分享、上下車最多晚這麼久生效
V.NOTICE_MS = 5000   -- 被擋的提示最短間隔
V.state = V.state or {}   -- 本機玩家編號 → 這台車的狀態（換車、接上或解開拖車就重來）

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- 車身矩形寫進 fp：中心 (cx, cy)、前方 (fx, fy)、右方 (rx, ry)、半長 hl、半寬 hw；腳本還沒載好回 false
function V.footprint(v, fp)
    local sc = v:getScript()
    if sc == nil then return false end
    local ext, com = sc:getExtents(), sc:getCenterOfMassOffset()
    V.va = V.va or Vector3f.new()
    V.vb = V.vb or Vector3f.new()
    local a = v:getWorldPos(com:x(), 0, com:z(), V.va)
    local b = v:getWorldPos(com:x(), 0, com:z() + 1, V.vb)
    local fx, fy = b:x() - a:x(), b:y() - a:y()
    local n = math.sqrt(fx * fx + fy * fy)
    if n < 1e-6 then return false end
    fp.cx, fp.cy, fp.fx, fp.fy = a:x(), a:y(), fx / n, fy / n
    fp.rx, fp.ry, fp.hl, fp.hw = -fp.fy, fp.fx, ext:z() / 2, ext:x() / 2
    return true
end

-- SAT：車身中心移到 (cx, cy)、外加 pad，對矩形 r 四軸的重疊量；都 > 0＝重疊，回最小重疊（深度），否則回負的最大分離量
function V.sat(fp, cx, cy, r, pad)
    local hl, hw = fp.hl + pad, fp.hw + pad
    local hx, hy = r.w / 2, r.h / 2
    local dx, dy = cx - (r.x + hx), cy - (r.y + hy)
    local o1 = hx + hl * math.abs(fp.fx) + hw * math.abs(fp.rx) - math.abs(dx)
    local o2 = hy + hl * math.abs(fp.fy) + hw * math.abs(fp.ry) - math.abs(dy)
    local o3 = hl + hx * math.abs(fp.fx) + hy * math.abs(fp.fy) - math.abs(dx * fp.fx + dy * fp.fy)
    local o4 = hw + hx * math.abs(fp.rx) + hy * math.abs(fp.ry) - math.abs(dx * fp.rx + dy * fp.ry)
    if o1 > 0 and o2 > 0 and o3 > 0 and o4 > 0 then return math.min(o1, o2, o3, o4) end
    return -math.max(-o1, -o2, -o3, -o4)
end

-- 車上的人：每個座位（BaseVehicle.getMaxPassengers:1800-1802、getCharacter:1851-1854）
local function addRiders(v, out)
    for i = 0, v:getMaxPassengers() - 1 do
        local c = v:getCharacter(i)
        if c ~= nil and instanceof(c, "IsoPlayer") then out[#out + 1] = c end
    end
end

-- 附近不能進的安全屋（CACHE_MS 重算一次）：車上任何一人 isSafehouseAllowTrepass 為 false 就算。那個函式要一格：
-- 取屋內離車最近的一格（車在附近，那格已經載入；沒載入＝還遠，下次再看）。rider＝擋的是乘客（駕駛自己可以進）。
-- 清單變了（新屋、分享、上下車）就重記「最淺的位置」：多出來的那塊會讓深度變大，拿舊的比會一直拉回
function V.blockers(st, p, v, tr, now)
    if st.cacheAt ~= nil and now - st.cacheAt < V.CACHE_MS then return st.rects end
    local riders = {}
    addRiders(v, riders)
    if tr ~= nil then addRiders(tr, riders) end
    local rects, keys, cx, cy = {}, {}, v:getX(), v:getY()
    local list = SafeHouse.getSafehouseList()
    for i = 0, list:size() - 1 do
        local h = list:get(i)
        local x, y, w, hh = h:getX(), h:getY(), h:getW(), h:getH()
        local dx, dy = math.max(x - cx, 0, cx - (x + w)), math.max(y - cy, 0, cy - (y + hh))
        if dx * dx + dy * dy < V.NEAR * V.NEAR then
            local sq = getCell():getGridSquare(clamp(math.floor(cx), x, x + w - 1), clamp(math.floor(cy), y, y + hh - 1), 0)
            if sq ~= nil then
                for _, r in ipairs(riders) do
                    if not SafeHouse.isSafehouseAllowTrepass(sq, r) then
                        rects[#rects + 1] = { x = x, y = y, w = w, h = hh, rider = r ~= p }
                        keys[#keys + 1] = x .. "," .. y .. "," .. w .. "," .. hh .. (r ~= p and "r" or "")
                        break
                    end
                end
            end
        end
    end
    local key = table.concat(keys, ";")
    if key ~= st.key then st.key, st.inside = key, false end
    st.rects, st.cacheAt = rects, now
    return rects
end

local function stateOf(p, v, tr)
    local num, vid, tid = p:getPlayerNum(), v:getId(), tr ~= nil and tr:getId() or -1
    local st = V.state[num]
    if st == nil or st.vid ~= vid or st.tid ~= tid then
        st = { vid = vid, tid = tid, cars = {}, fp = { {}, {} }, gfp = { {}, {} }, good = {}, lx = {}, lz = {} }
        V.state[num] = st
    end
    return st
end

-- 存位置：車與拖車同一幀（拉回時兩台一起，連接點才對得上）；gfp 留當時的車身，拉回前確認它還在每塊外面
function V.saveGood(st, n)
    for i = 1, n do
        st.good[i] = st.cars[i]:getWorldTransform(st.good[i] or Transform.new())
        local s, d = st.fp[i], st.gfp[i]
        d.cx, d.cy, d.fx, d.fy, d.rx, d.ry, d.hl, d.hw = s.cx, s.cy, s.fx, s.fy, s.rx, s.ry, s.hl, s.hw
        st.lx[i], st.lz[i] = nil, nil
    end
    st.hasGood = true
end

function V.restore(st, n)
    for i = 1, n do st.cars[i]:setWorldTransform(st.good[i]) end
end

-- 速度歸零；速度和上次送的時候完全相同＝物理還沒走，不重送
function V.halt(st, n)
    for i = 1, n do
        local c = st.cars[i]
        local vel = c:getLinearVelocity(V.vel)
        local vx, vz = vel:x(), vel:z()
        if vx * vx + vz * vz > 0.0025 and not (st.lx[i] == vx and st.lz[i] == vz) then
            st.lx[i], st.lz[i] = vx, vz
            c:applyImpulseFromHitPlant(c, c:getMass() / (0.3 * math.max(1, c:getFudgedMass())))
        end
    end
end

-- 車身（fps，移動 look 秒後）和每塊的重疊深度加總（0＝都在外面），以及有沒有一塊是駕駛自己不能進的
function V.overlap(fps, n, rects, look)
    local sum, own = 0, false
    for i = 1, n do
        local fp = fps[i]
        local cx, cy = fp.cx + (fp.vx or 0) * look, fp.cy + (fp.vy or 0) * look
        for _, r in ipairs(rects) do
            local d = V.sat(fp, cx, cy, r, V.PAD)
            if d > 0 then sum, own = sum + d, own or not r.rider end
        end
    end
    return sum, own
end

function V.notify(p, st, now, own)
    if st.noticeAt ~= nil and now - st.noticeAt < V.NOTICE_MS then return end
    st.noticeAt = now
    MSH.Client.toast(getText(own and "IGUI_MSH_Vehicle_Blocked" or "IGUI_MSH_Vehicle_BlockedRider"), p)
end

function V.update(p)
    local v = p:getVehicle()
    if v == nil or not v:isDriver(p) then
        V.state[p:getPlayerNum()] = nil
        return
    end
    local tr = v:getVehicleTowing()
    local st = stateOf(p, v, tr)
    local now = getTimestampMs()
    local dt = st.at ~= nil and clamp((now - st.at) / 1000, 0.004, 0.1) or 0.016
    st.at = now
    local rects = V.blockers(st, p, v, tr, now)
    if #rects == 0 then
        st.hasGood, st.inside = false, false   -- 附近沒有：不存位置（之後出現時車還在 NEAR 外，會先存到新的）
        return
    end
    local n = tr ~= nil and 2 or 1
    st.cars[1], st.cars[2] = v, tr
    V.vel = V.vel or Vector3f.new()
    for i = 1, n do
        local fp = st.fp[i]
        if not V.footprint(st.cars[i], fp) then return end
        local vel = st.cars[i]:getLinearVelocity(V.vel)
        fp.vx, fp.vy = vel:x(), vel:z()
    end
    local depth, own = V.overlap(st.fp, n, rects, 0)
    if depth > 0 then
        if st.hasGood and not st.inside and V.overlap(st.gfp, n, rects, 0) == 0 then
            v:setForceBrake()                    -- 2) 從外面穿進去
            V.restore(st, n)
            V.halt(st, n)
            V.notify(p, st, now, own)
        elseif not st.inside or depth < st.depth then
            st.inside, st.depth = true, depth    -- 3) 本來就在裡面：記住最淺的位置
            V.saveGood(st, n)
        elseif depth > st.depth + V.DEEPER then
            V.restore(st, n)
            V.halt(st, n)
            V.notify(p, st, now, own)
        end
        return
    end
    st.inside = false
    local ahead, ownAhead = V.overlap(st.fp, n, rects, math.max(V.LOOK_MIN, V.LOOK_FRAMES * dt))
    if ahead > 0 then
        v:setForceBrake()                        -- 1) 快碰到
        V.halt(st, n)
        V.notify(p, st, now, ownAhead)
        return
    end
    V.saveGood(st, n)
end

if first then
    Events.OnPlayerUpdate.Add(function(p) MSH.VehiclesClient.update(p) end)
end
