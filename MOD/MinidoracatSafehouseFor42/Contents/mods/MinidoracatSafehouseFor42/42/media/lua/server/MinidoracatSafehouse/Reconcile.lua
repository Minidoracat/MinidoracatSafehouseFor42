-- MinidoracatSafehouse/Reconcile.lua：原生安全屋收斂（desired-state controller，計畫 §6.2）與 tombstone GC（§4.2）。
-- 開服：OnLoadedMapZones 之後跑一次 recovery matrix（§6.2 表；不在 OnInitGlobalModData 判 missing，§6 啟動時序）。
-- 週期：wall-clock 每 SWEEP_MS 掃一次；hostile mode 每 tick 掃（§4.2）；每 tick 只比原生清單長度的 sentinel，
--   變小（有房子被偽造 release 或引擎刪掉）就立刻掃（§4.2 per-tick sentinel）。
-- 收斂只用 addPlayer／removePlayer／setTitle／setOwner，永不對真實玩家 kickUserFromSafehouse、不傳送人；
--   每個有變動的 active claim 每輪最多一次 service-owner 廣播；廣播、remove delta、admin alert 都排進 sends，
--   放鎖之後才送（§6.2 最後一段）。
-- blocked mode（§5）：不重建消失的原生、不把 missing 轉 released、不刪紀錄；名單／標題／owner 收斂、
--   releasing 收尾。恢復後下一輪收斂一次補做重建。lapsed 期滿釋出歸 Economy.lua（只在 READY 時，§1.3 第 61 行）。
-- released 紀錄只剩 md.tombs 的精簡 tombstone（Registry）；收斂與 GC 都看 R.tomb／R.tombList。
-- malformed 紀錄（沒有合法 rect）收斂一律略過，只給管理員 targeted recovery。
-- 可觀測性（§12.4）：Rc.health() 給上次成功 sweep 時間、待修復數、目前最久的 drift 持續時間、干擾數。
-- 出處：反編譯 D:/github/pz-decompiled-reference/snapshots/42.21.0-20260928/pz/zombie/iso/areas/SafeHouse.java（下稱 SafeHouse.java）。

if isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Settings"
require "MinidoracatSafehouse/Audit"
require "MinidoracatSafehouse/Registry"
require "MinidoracatSafehouse/Native"
require "MinidoracatSafehouse/Health"
require "MinidoracatSafehouse/Lifecycle"
require "MinidoracatSafehouse/Server"

local MSH = MinidoracatSafehouse
local Rc = MSH.Reconcile or {}
MSH.Reconcile = Rc

local LC = MSH.LIFECYCLE

Rc.SWEEP_MS = 500              -- 健康 tick 的全掃週期（§6.2：convergence ≤ 500 ms）
Rc.INTERFERE_MAX = 5           -- 同一 (claimId, username) 一分鐘內 re-add 超過 5 次＝成員同步受干擾（§6.2）
Rc.INTERFERE_WINDOW_MS = 60000

Rc.claimFlags = Rc.claimFlags or {}   -- claimId → { interference = true|nil, missing = true|nil }（Claims 的 list／detail 讀）
Rc.readds = Rc.readds or {}           -- "id|user" → 最近最多 6 次 re-add 的時間
Rc.lastReadd = Rc.lastReadd or {}     -- claimId → 最後一次 re-add 的時間（安靜一分鐘後清干擾旗標）
Rc.driftSince = Rc.driftSince or {}  -- claimId → 第一次發現沒收斂的時間（成功的一輪結束時更新；收斂乾淨就清掉）
Rc.longestDriftMs = Rc.longestDriftMs or 0   -- 上次成功的一輪：還沒收斂的 claim 裡最久的 drift 持續時間

-- admin alert 是網路送出：排進 sends，放鎖之後才送（§6.2）
local function queueAlert(st, code, detail)
    st.sends[#st.sends + 1] = function() MSH.Audit.alertAdmins(code, detail) end
end

local function setFlag(id, key, value)
    local f = Rc.claimFlags[id]
    if f == nil then
        if value == nil then return end
        f = {}
        Rc.claimFlags[id] = f
    end
    f[key] = value
    if f.interference == nil and f.missing == nil then Rc.claimFlags[id] = nil end
end

-- 只保留最近 INTERFERE_MAX＋1 次：第一筆還在一分鐘內＝一分鐘內超過 INTERFERE_MAX 次（滾動視窗、記憶體有上限）
local function countReadd(id, user, now, st)
    local key = id .. "|" .. user
    local l = Rc.readds[key] or {}
    l[#l + 1] = now
    if #l > Rc.INTERFERE_MAX + 1 then table.remove(l, 1) end
    Rc.readds[key] = l
    Rc.lastReadd[id] = now
    if #l > Rc.INTERFERE_MAX and now - l[1] < Rc.INTERFERE_WINDOW_MS then
        setFlag(id, "interference", true)
        -- 每個 claim 每分鐘最多一行 audit 與一次 admin alert；成員照樣每輪 re-add（不撤權、不停修）
        if MSH.Audit.throttled("INTERFERENCE|" .. id, Rc.INTERFERE_WINDOW_MS, "INTERFERENCE",
            { actor = user, claimId = id, code = "READD" }, now) then
            queueAlert(st, "INTERFERENCE", tostring(id))
        end
    end
end

local function clearQuietInterference(now)
    for id, at in pairs(Rc.lastReadd) do
        if now - at >= Rc.INTERFERE_WINDOW_MS then
            Rc.lastReadd[id] = nil
            setFlag(id, "interference", nil)
        end
    end
end

-- 走訪 registry 的整數鍵紀錄（不排序：收斂與順序無關，省掉每輪 1,280 筆的排序）。malformed（沒有合法 rect）略過。
-- 走訪中 markReleased 會把 md.claims[id] 設 nil：pairs 走的是開始時的 key 快照，已刪的 key 取值為 nil
-- （反編譯 pz/se/krka/kahlua/j2se/KahluaTableImpl.java:152-180，下面的 type 檢查略過它）。
local function eachRecord(fn)
    for id, rec in pairs(MSH.Registry.md.claims) do
        if MSH.isInt(id) and type(rec) == "table" and rec.claimId == id and not rec.malformed then fn(id, rec) end
    end
end

-- 名單、標題收斂（native 已確認是這筆紀錄的）。回傳是否需要廣播。
-- owner 標記出現在 players（load() 沒有 setOwner，§2.1；或 owner packet 把舊 owner 加回成員）：安靜移除、不算 drift。
local function fixNative(rec, house, now, st)
    local N = MSH.Native
    local marker = MSH.marker(rec.claimId)
    local dirty = false
    -- getTitle／setTitle：SafeHouse.java:727-733
    if house:getTitle() ~= rec.title then
        house:setTitle(rec.title)
        dirty = true
    end
    local want, wanted = N.desiredPlayers(rec), {}
    for _, u in ipairs(want) do wanted[u] = true end
    local have = {}
    -- getPlayers 回 live ArrayList（SafeHouse.java:640-642）：先複製再邊走邊移除
    for _, raw in ipairs(MSH.toArray(house:getPlayers())) do
        local u = tostring(raw)
        if u == marker then
            house:removePlayer(u)   -- SafeHouse.java:299-304：只移除＋清 respawn flag，不廣播、不傳送
        elseif not wanted[u] then
            house:removePlayer(u)
            dirty = true
            -- 非 canonical 成員被收掉要讓 operator 看得到（§9 operator 紅線）。上次由分享套用進去的人（陣營退會、
            -- 關閉陣營分享）不是非 canonical：不記，撤銷與推送由 Sharing 的下一次同步補上（Sharing.wasApplied）
            local shared = MSH.Sharing ~= nil and MSH.Sharing.wasApplied(rec.claimId, u)
            if not shared then
                MSH.Audit.throttled("ROSTER_EXTRA|" .. rec.claimId .. "|" .. u, 60000, "ROSTER_REMOVED",
                    { actor = u, claimId = rec.claimId, code = "NOT_CANONICAL" }, now)
            end
        else
            have[u] = true
        end
    end
    for _, u in ipairs(want) do
        if not have[u] then
            house:addPlayer(u)      -- SafeHouse.java:292-297：沒有對稱的廣播，由下面的 service-owner 廣播同步
            dirty = true
            if not st.startup then countReadd(rec.claimId, u, now, st) end
        end
    end
    return dirty
end

-- owner drift：同 rect＋同建立時間指紋的原生，owner 卻不是標記（例：owner packet，§2.2）→ 換回標記。
-- 先做這步再建索引，換回來的原生在本輪就照一般路徑收斂名單。
-- 只有 active 排廣播：lapsed／releasing 的原生本輪就會被移除，廣播只會讓客戶端把它加回去（只送 remove delta）。
local function fixOwners(idx, now, st)
    local N = MSH.Native
    local fixed = false
    eachRecord(function(id, rec)
        local lc = rec.lifecycle
        if (lc == LC.ACTIVE or lc == LC.LAPSED or lc == LC.RELEASING) and idx.byClaim[id] == nil then
            for _, e in ipairs(idx.byRect[N.rectKey(rec.rect)] or {}) do
                if e.claimId ~= id and N.matches(rec, e) then
                    -- setOwner 也把新 owner 從 players 移除（SafeHouse.java:660-663）
                    e.house:setOwner(MSH.marker(id))
                    if lc == LC.ACTIVE then
                        st.changed[id] = e.house
                        st.drift[id] = true
                    end
                    fixed = true
                    MSH.Audit.throttled("OWNER_DRIFT|" .. id, 60000, "OWNER_DRIFT",
                        { actor = e.owner, claimId = id, code = "RESTORED" }, now)
                    break
                end
            end
        end
    end)
    return fixed
end

local function sendRemove(st, id, rect)
    local r = MSH.Rect.copy(rect)
    st.sends[#st.sends + 1] = function() MSH.Native.sendRemove(id, r) end
end

-- releasing／lapsed：只移除原生、收尾，不重建
local function convergeInactive(id, rec, idx, now, st)
    local N, R, L = MSH.Native, MSH.Registry, MSH.Lifecycle
    local lc = rec.lifecycle
    local e, why = L.findNative(rec, idx)
    if e ~= nil then
        if not N.remove(e.house) then
            R.markQuarantined(rec, "RELEASE_REMOVE_FAILED")
            return
        end
        st.removed = true
        sendRemove(st, id, rec.rect)
        if lc == LC.RELEASING then R.markReleased(rec, "RELEASE_RECOVERED", now) end
    elseif why == "MISSING" then
        if lc == LC.RELEASING then R.markReleased(rec, "RELEASE_RECOVERED", now) end
    else
        R.markQuarantined(rec, "RELEASE_" .. why)
    end
end

-- 同一代原生：rect 與建立時間（getDatetimeCreated，SafeHouse.java:681-683，存檔保存）都和 tombstone 相同。
-- tombstone 沒有建立時間就不算（寧可留著 alert，不刪可能不是我們建的原生）。
local function sameGeneration(t, e)
    return t.rect ~= nil and t.nativeCreatedAt ~= nil and MSH.Rect.equals(t.rect, e.rect)
        and e.house:getDatetimeCreated() == t.nativeCreatedAt
end

-- released（tombstone）：同一代原生重現（例：release 中途 crash 後的舊存檔）→ 移除＋remove delta；
-- 其他標記原生不碰、alert（claimId 不重用，只可能是偽造或 operator 操作，§6.2）。
-- 只看帶標記的原生查 tombstone，不每輪解碼全部 tombstone。
local function convergeTombs(idx, now, st)
    local N, R = MSH.Native, MSH.Registry
    for id, list in pairs(idx.byClaim) do
        local t = R.md.claims[id] == nil and R.tomb(id) or nil
        if t ~= nil then
            for _, e in ipairs(list) do
                if sameGeneration(t, e) then
                    if N.remove(e.house) then
                        st.removed = true
                        sendRemove(st, id, e.rect)
                    end
                elseif MSH.Audit.throttled("RELEASED_NATIVE|" .. id, 3600000, "RELEASED_NATIVE",
                    { claimId = id, code = "FOREIGN_FINGERPRINT" }, now) then
                    queueAlert(st, "RELEASED_NATIVE", tostring(id))
                end
            end
        end
    end
end

local function convergeActive(id, rec, idx, now, st)
    local R, L = MSH.Registry, MSH.Lifecycle
    local e, why = L.findNative(rec, idx)
    if e ~= nil then
        setFlag(id, "missing", nil)
        if fixNative(rec, e.house, now, st) then
            st.changed[id] = e.house
            st.drift[id] = true
        end
        return
    end
    if why ~= "MISSING" then
        R.markQuarantined(rec, why)   -- DUPLICATE（兩個同標記原生）或 MISMATCH：不猜（§6.2）
        return
    end
    st.drift[id] = true               -- 原生不在：重建成功的話下一輪看到乾淨的原生才算收斂
    if st.blocked then
        setFlag(id, "missing", true)  -- 「修復已暫停」：保留紀錄、不重建、不轉 released
        return
    end
    local conflict = L.rebuildConflict(rec, idx)
    if conflict then
        R.markQuarantined(rec, "REBUILD_" .. conflict)
        st.drift[id] = nil            -- 轉 quarantined：算在待修復數，不算 drift
        return
    end
    local house, code = L.rebuild(rec, idx, function(fn) st.sends[#st.sends + 1] = fn end)
    if house == nil then
        setFlag(id, "missing", true)
        MSH.Audit.throttled("REBUILD_FAILED|" .. id, 60000, "REBUILD_FAILED", { claimId = id, code = code }, now)
        return
    end
    setFlag(id, "missing", nil)
end

-- 有標記、沒有紀錄也沒有 tombstone 的原生（registry 晚一步落盤，§6.2 recovery matrix 第 2 列）：
-- 建 quarantined(RECOVERED)，owner 不猜（players 順序沒有所有權語意），名單只當候選；nextClaimId 抬過它。
-- 有 tombstone 的由 convergeTombs 處理（released 不復活）。
local function recoverOrphans(idx, now)
    local N, R = MSH.Native, MSH.Registry
    for id, list in pairs(idx.byClaim) do
        if R.md.claims[id] == nil and R.md.tombs[id] == nil then
            local e = list[1]
            -- getTitle：SafeHouse.java:727-729；getDatetimeCreated：:681-683（存檔有保存，load 後不變）
            local rec = R.newRecord({ claimId = id, lifecycle = LC.QUARANTINED, rect = e.rect,
                title = e.house:getTitle(), owner = nil, source = MSH.SOURCE.DEED, deedTier = 1,
                nativeCreatedAt = e.house:getDatetimeCreated(), createdAt = now })
            rec.quarantineReason = #list > 1 and "RECOVERED_DUPLICATE" or "RECOVERED"
            rec.candidates = N.players(e.house)
            R.put(rec)
            R.raiseNextId(id)
            MSH.Audit.write("QUARANTINE", { claimId = id, code = rec.quarantineReason })
        end
    end
end

-- 一輪收斂；呼叫端持鎖。先移除該移除的（重畫留下的舊原生可能與新 claim 重疊），重建索引後再處理 active。
local function pass(now, st)
    local N = MSH.Native
    local idx = N.index()
    if fixOwners(idx, now, st) then idx = N.index() end
    local first = idx
    convergeTombs(idx, now, st)
    eachRecord(function(id, rec)
        if rec.lifecycle == LC.LAPSED or rec.lifecycle == LC.RELEASING then convergeInactive(id, rec, idx, now, st) end
    end)
    if st.removed then idx = N.index() end
    eachRecord(function(id, rec)
        if rec.lifecycle == LC.ACTIVE then convergeActive(id, rec, idx, now, st) end
    end)
    return first
end

local function newState(startup)
    return { startup = startup, blocked = MSH.Health.blocked(), changed = {}, sends = {}, removed = false, drift = {} }
end

-- 放鎖之後：每個變動的 active claim 一次 service-owner 廣播，再送重建廣播、remove delta、admin alert
local function flush(st)
    for _, house in pairs(st.changed) do MSH.Native.broadcast(house) end
    for _, fn in ipairs(st.sends) do
        local ok, err = pcall(fn)
        if not ok then MSH.log("reconcile send failed: " .. tostring(err)) end
    end
end

-- ok＝這輪 pass 沒丟錯。lastAttempt 失敗也更新（排程用：不在每個 tick 重跑同一個錯、灌 INTERNAL_ERROR audit）；
-- lastSuccessAt 與 drift 只在成功時更新（失敗的一輪 st.drift 不完整，§12.4「沒有錯誤 log 不算修復成功」）。
local function afterPass(now, ok, st)
    Rc.lastAttempt = now
    -- getSafehouseList：SafeHouse.java:652-654（live ArrayList，size() 是 O(1)）
    Rc.expected = SafeHouse.getSafehouseList():size()
    if not ok then return end
    Rc.lastSuccessAt = now
    for id in pairs(Rc.driftSince) do
        if not st.drift[id] then Rc.driftSince[id] = nil end
    end
    local longest = 0
    for id in pairs(st.drift) do
        local since = Rc.driftSince[id] or now
        Rc.driftSince[id] = since
        if now - since > longest then longest = now - since end
    end
    Rc.longestDriftMs = longest
end

-- 開服首輪（startup hook，Server 在 OnLoadedMapZones 後呼叫）
function Rc.startup(now)
    if not MSH.Registry.ready() then return end
    local st = newState(true)
    local ok = MSH.Srv.withLock(function()
        local idx = pass(now, st)
        recoverOrphans(idx, now)
        return true
    end) == true
    afterPass(now, ok, st)
    flush(st)
end

function Rc.sweep(now)
    local S = MSH.Srv
    if not MSH.Registry.ready() or S.locked then return false end
    -- 每輪重讀健康矩陣（§5）；Server 這個 tick 已讀過就不重讀
    if S.lastHealth ~= now then
        MSH.Health.evaluate(now)
        S.lastHealth = now
    end
    local st = newState(false)
    local ok = S.withLock(function()
        pass(now, st)
        return true
    end) == true
    clearQuietInterference(now)
    afterPass(now, ok, st)
    flush(st)
    return ok
end

function Rc.tick(now)
    -- sentinel：getSafehouseList():size()（SafeHouse.java:652-654）O(1)，每 tick 只做這個比較
    if Rc.lastAttempt == nil or MSH.Health.isHostile() or now - Rc.lastAttempt >= Rc.SWEEP_MS
        or SafeHouse.getSafehouseList():size() < (Rc.expected or 0) then
        Rc.sweep(now)
    end
end

-- 給管理員 health detail（§12.4）：lastSuccessAt（上次完整成功 sweep）、pendingRepair（active 但原生缺著
-- ＋quarantined，含 malformed）、longestDriftMs（上次成功那輪還沒收斂的 claim 裡最久的）、interference（受干擾 claim 數）
function Rc.health()
    local R = MSH.Registry
    local pending, interference = 0, 0
    for id, rec in pairs(R.md and R.md.claims or {}) do
        if type(rec) == "table" then
            local f = Rc.claimFlags[id]
            if rec.lifecycle == LC.QUARANTINED or (rec.lifecycle == LC.ACTIVE and f and f.missing) then
                pending = pending + 1
            end
        end
    end
    for _, f in pairs(Rc.claimFlags) do
        if f.interference then interference = interference + 1 end
    end
    return { lastSuccessAt = Rc.lastSuccessAt, pendingRepair = pending, longestDriftMs = Rc.longestDriftMs,
        interference = interference }
end

-- tombstone GC（§4.2）：跨過乾淨 restart（bootSeen < bootSeq）＋沒有該 id 的標記原生，
-- 且 releasedAt 超過 30 天；超過軟上限時再從最舊的開始 pressure-GC（不看天數）。blocked mode 不刪。
function Rc.gc(now)
    local R, S = MSH.Registry, MSH.Srv
    if not R.ready() or MSH.Health.blocked() or S.locked then return end
    S.withLock(function()
        local idx = MSH.Native.index()
        local tombs, eligible, drop = R.tombList(), {}, {}
        for _, t in ipairs(tombs) do
            if MSH.isInt(t.bootSeen) and t.bootSeen < R.md.bootSeq and idx.byClaim[t.claimId] == nil then
                if t.releasedAt ~= nil and now - t.releasedAt > MSH.LIMIT.TOMBSTONE_GC_MS then
                    drop[#drop + 1] = t.claimId
                else
                    eligible[#eligible + 1] = t
                end
            end
        end
        local over = #tombs - #drop - MSH.LIMIT.TOMBSTONE_SOFT
        if over > 0 then
            MSH.sortSafe(eligible, function(a, b) return (a.releasedAt or 0) < (b.releasedAt or 0) end)
            for i = 1, math.min(over, #eligible) do drop[#drop + 1] = eligible[i].claimId end
        end
        for _, id in ipairs(drop) do R.dropTomb(id) end
        if #drop > 0 then MSH.Audit.write("TOMBSTONE_GC", { detail = "removed=" .. #drop .. " pressure=" .. math.max(over, 0) }) end
    end)
    -- 干擾計數只留一分鐘內的
    for key, l in pairs(Rc.readds) do
        if now - l[#l] >= Rc.INTERFERE_WINDOW_MS then Rc.readds[key] = nil end
    end
end

MSH.Srv.hook("startup", "reconcile", function(now) MSH.Reconcile.startup(now) end, 20)
MSH.Srv.hook("tick", "reconcile", function(now) MSH.Reconcile.tick(now) end)
MSH.Srv.hook("minute", "tombstoneGc", function(now) MSH.Reconcile.gc(now) end)
