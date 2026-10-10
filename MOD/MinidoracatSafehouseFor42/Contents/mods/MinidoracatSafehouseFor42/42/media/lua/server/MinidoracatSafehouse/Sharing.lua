-- MinidoracatSafehouse/Sharing.lua：分享指令（指定玩家、陣營）與陣營 round-robin 同步
-- （計畫 §4.2 第 212-213、238 行，§4.3、§4.4、§6.4、§6.5、§10.5 伺服器端）。
-- 位元的唯一來源是 Claims.roleOf；原生名單應有的人是 Native.desiredPlayers。Reconcile 也用 desiredPlayers 收斂，
--   兩邊同一個判定，所以不會一邊加、一邊移。
-- 撤銷（移除、停止分享、陣營暫停、離開、陣營少了人）用 Native.revoke（kickUserFromSafehouse：人在屋內立即傳出，§4.4），
--   只撤銷不再有任何資格的人；新增用 addPlayer＋放鎖後廣播。原生不在（lapsed、等收斂重建）就只改紀錄。
--   陣營少了人沒有事件：Sh.last 記上次套用的名單，同步時比對出要撤銷的人（Reconcile 可能已先安靜移除，撤銷補上傳出）。
-- 陣營有效性照 VM（Native.faction）；失效 → 持久化 SUSPENDED＋reason（GONE／LEADER_CHANGED／OWNER_LEFT）。
--   全服關閉 AllowFactionShare 只停止投影（成員照樣撤銷）、不寫 SUSPENDED，重新開啟就恢復，和 VM 相同。
-- 網路送出一律 defer 到放鎖之後（§6.2 最後一段）。

if isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Settings"
require "MinidoracatSafehouse/Audit"
require "MinidoracatSafehouse/Registry"
require "MinidoracatSafehouse/Native"
require "MinidoracatSafehouse/Lifecycle"
require "MinidoracatSafehouse/Server"
require "MinidoracatSafehouse/Claims"

local MSH = MinidoracatSafehouse
local Sh = MSH.Sharing or {}
MSH.Sharing = Sh

local CODE = MSH.CODE
local LC = MSH.LIFECYCLE
local LIMIT = MSH.LIMIT
local SHARE = MSH.SHARE
local R = MSH.Registry
local N = MSH.Native
local S = MSH.Srv

Sh.CYCLE_MS = 1000        -- 全部陣營分享輪完一次的目標（§6.5 healthy ≤ 2 秒，留一倍餘裕）
-- ponytail: 每 tick 檢查數固定上限；伺服器 tick 很慢又有上百間陣營分享時一輪會超過 2 秒，實測不達標再調
Sh.MAX_PER_TICK = 64
Sh.NAME_BYTES = 64        -- factionShare.name／leader 的 UTF-8 上限（§4.2 第 238 行）

Sh.last = Sh.last or {}   -- claimId → { user = true }：上次套用到原生的應有名單（記憶體；重開後第一次同步當基準）
Sh.queue = Sh.queue or {}
Sh.cursor = Sh.cursor or 1

-- 這個名字是不是上次由分享套用進原生名單的（含陣營投影）。Reconcile 移除這些人時不記 NOT_CANONICAL：
-- 陣營退會、關閉 AllowFactionShare 時 desiredPlayers 立刻變，Reconcile 常比這裡的輪檢先跑；
-- 撤銷（傳出屋內的人、changed 推送）由下一次同步補上（Sh.apply 比對 Sh.last）。
function Sh.wasApplied(id, user)
    local set = Sh.last[id]
    return set ~= nil and set[user] == true
end

local function toSet(list)
    local out = {}
    for _, u in ipairs(list) do out[u] = true end
    return out
end

-- 正規化位元：0 不收；帶 USE／MOVE／BUILD／FARM／MANAGE 任一就自動加 MEMBER（§6.5）
function Sh.normalize(bits)
    if not MSH.isInt(bits) or bits < 1 or bits > MSH.SHARE_ALL then return nil end
    if not MSH.hasBit(bits, SHARE.MEMBER) then bits = bits + SHARE.MEMBER end
    return bits
end

-- 陣營名稱與領袖寫進 canonical 前：非空、無控制字元、UTF-8 ≤ 64 bytes。
-- Kahlua 的 #s 是 UTF-16 單位：含非 ASCII 時以 3 倍估（同 Registry 的大小估算，寧可高估）
function Sh.boundedName(s)
    if type(s) ~= "string" or s == "" or MSH.hasControl(s) then return false end
    local n = #s
    if string.find(s, "[^\1-\127]") then n = n * 3 end
    return n <= Sh.NAME_BYTES
end

-- 使用者目前所在的陣營（一人只在一個陣營）；照 VM S.findFactionOf 走訪 Faction.getFactions()（Faction.java:33）
function Sh.factionOf(user)
    for _, f in ipairs(MSH.toArray(Faction.getFactions())) do
        if f:isOwner(user) or f:isMember(user) then return f end   -- Faction.java:150、154
    end
    return nil
end

-- 全部 managed 原生名單的名字數（同 Claims.checkCapacity 的算法，§4.2）
local function rosterNames()
    local n = 0
    for _, r in ipairs(R.list()) do
        if R.isLive(r) then n = n + #N.desiredPlayers(r) end
    end
    return n
end

-- 受影響且在線的人收到 changed（客戶端重抓 list）；getUsername 只用來找收件人，不做授權
local function pushChanged(id, names, defer)
    defer(function()
        local list = getOnlinePlayers()
        for i = 0, list:size() - 1 do
            local p = list:get(i)
            if names[p:getUsername()] then sendServerCommand(p, MSH.MODULE, "changed", { claimId = id }) end
        end
    end)
end

-- 紀錄改完後讓原生名單跟上。old＝改之前應有的人（同步時 nil）；和 Sh.last 合併後，不在新名單的撤銷、
-- 新名單裡原生沒有的 addPlayer。回傳 affected（被撤銷＋新取得資格的人）, changed（有沒有人變動）。
-- 呼叫端持鎖；撤銷與廣播 defer。idx 可省（指令自己掃一次原生清單）。
function Sh.apply(rec, old, defer, idx)
    local id = rec.claimId
    local after = N.desiredPlayers(rec)
    local want = toSet(after)
    local prev = Sh.last[id]
    Sh.last[id] = want
    local affected, changed = {}, false
    if old == nil and prev == nil then return affected, changed end   -- 沒有基準（重開後第一次）：只記下來
    local base = {}
    for u in pairs(old or {}) do base[u] = true end
    for u in pairs(prev or {}) do base[u] = true end
    local gone = {}
    for u in pairs(base) do
        if not want[u] then gone[#gone + 1] = u end
    end
    for _, u in ipairs(after) do
        if not base[u] then
            affected[u] = true
            changed = true
        end
    end
    for _, u in ipairs(gone) do
        affected[u] = true
        changed = true
    end
    if rec.lifecycle ~= LC.ACTIVE then return affected, changed end
    local e = MSH.Lifecycle.findNative(rec, idx or N.index())
    if e == nil then return affected, changed end
    local house = e.house
    local have = toSet(N.players(house))
    local added = false
    for _, u in ipairs(after) do
        if not have[u] then
            house:addPlayer(u)      -- SafeHouse.java:292-297
            added = true
        end
    end
    for _, u in ipairs(gone) do
        house:removePlayer(u)       -- 鎖內先改名單（SafeHouse.java:299-304）；放鎖後 revoke 廣播並傳出屋內的人
        defer(function() N.revoke(house, u) end)
    end
    -- ponytail: 每撤銷一人就一次 SafehouseSync（kick 是唯一會傳出屋內玩家的 API），陣營暫停最多 64＋maxShares 次
    if added and #gone == 0 then defer(function() N.broadcast(house) end) end
    return affected, changed
end

-- 分享類指令的收尾：套用名單、推送 changed（extra＝另外要通知的人）、audit
local function finish(ctx, rec, old, extra, event, detail)
    local affected = Sh.apply(rec, old, ctx.defer)
    affected[rec.owner] = true
    for u in pairs(extra) do affected[u] = true end
    pushChanged(rec.claimId, affected, ctx.defer)
    MSH.Audit.write(event, { actor = ctx.who, claimId = rec.claimId, detail = detail })
end

-- 指令的目標紀錄：沒有角色 NOT_FOUND；屋主以外要帶 MANAGE（ownerOnly 時只限屋主）→ NOT_OWNER；
-- 只在 active 操作；expectedRevision 要相符；通過後綁定 actor（Claims.bindActor）。
-- 回傳 rec, isOwner, actor 的位元 或 nil, code
local function target(ctx, ownerOnly)
    local a = ctx.args
    local rec = R.get(a.claimId)
    if rec == nil or not R.isLive(rec) or rec.malformed then return nil, CODE.NOT_FOUND end
    local role, bits = MSH.Claims.roleOf(rec, ctx.who)
    if role == nil then return nil, CODE.NOT_FOUND end
    local owner = role == "owner"
    if not owner and (ownerOnly or not MSH.hasBit(bits, SHARE.MANAGE)) then return nil, CODE.NOT_OWNER end
    if rec.lifecycle ~= LC.ACTIVE then return nil, CODE.WRONG_LIFECYCLE end
    if a.expectedRevision ~= rec.revision then return nil, CODE.STALE_REVISION end
    local bad = MSH.Claims.bindActor(ctx)
    if bad then return nil, bad end
    return rec, owner, bits
end

-- 帶 MANAGE 的成員不能動持有 MANAGE 的人（grant 或陣營給的都算）
local function holdsManage(rec, user)
    local _, bits = MSH.Claims.roleOf(rec, user)
    return MSH.hasBit(bits, SHARE.MANAGE)
end

-- bits 的每一位 mine 都有（MANAGE 成員只能給自己有的位元）
local function subsetOf(bits, mine)
    for _, bit in pairs(SHARE) do
        if MSH.hasBit(bits, bit) and not MSH.hasBit(mine, bit) then return false end
    end
    return true
end

-- ===== 指定玩家 =====

-- MANAGE 成員（非屋主）：新位元不能含 MANAGE、必須是自己 roleOf 位元的子集（只拿掉位元的修改也照這條），
-- 不能動持有 MANAGE 的人。保守規則，待使用者裁定（2026-10-10 審查 MEDIUM）
function Sh.share(ctx)
    local a = ctx.args
    local rec, owner, mine = target(ctx, false)
    if rec == nil then return S.fail(owner) end
    local bits = Sh.normalize(a.bits)
    if bits == nil then return S.fail(CODE.BAD_ARGS) end
    local user = a.targetUsername
    if user == rec.owner or user == ctx.who then return S.fail(CODE.BAD_USER) end
    if not owner and (MSH.hasBit(bits, SHARE.MANAGE) or not subsetOf(bits, mine) or holdsManage(rec, user)) then
        return S.fail(CODE.NOT_OWNER)
    end
    local old = toSet(N.desiredPlayers(rec))
    local g = MSH.Claims.grantOf(rec, user)
    if g == nil then
        if #rec.grants + 1 > MSH.Settings.get().maxShares then return S.fail(CODE.SHARE_FULL) end
        local entry = { user = user, bits = bits }
        if R.estimateBytes(entry) > LIMIT.REGISTRY_BYTES then return S.fail(CODE.REGISTRY_FULL) end
        if not old[user] and rosterNames() + 1 > LIMIT.NATIVE_NAMES then return S.fail(CODE.ROSTER_FULL) end
        rec.grants[#rec.grants + 1] = entry
    else
        g.bits = bits
    end
    R.touch(rec)
    finish(ctx, rec, old, { [user] = true }, "SHARE", user .. " " .. tostring(bits))
    return S.ok({ claimId = rec.claimId, revision = rec.revision })
end

function Sh.unshare(ctx)
    local rec, owner = target(ctx, false)
    if rec == nil then return S.fail(owner) end
    local user = ctx.args.targetUsername
    local g, i = MSH.Claims.grantOf(rec, user)
    if user == rec.owner or user == ctx.who or g == nil then return S.fail(CODE.BAD_USER) end
    if not owner and holdsManage(rec, user) then return S.fail(CODE.NOT_OWNER) end
    local old = toSet(N.desiredPlayers(rec))
    table.remove(rec.grants, i)
    R.touch(rec)
    finish(ctx, rec, old, { [user] = true }, "UNSHARE", user)
    return S.ok({ claimId = rec.claimId, revision = rec.revision })
end

-- 成員移除自己的 grant；之後仍靠陣營有資格就帶 viaFaction（原生名單照留）
function Sh.leave(ctx)
    local rec = R.get(ctx.args.claimId)
    if rec == nil or not R.isLive(rec) or rec.malformed then return S.fail(CODE.NOT_FOUND) end
    if rec.owner == ctx.who then return S.fail(CODE.BAD_USER) end
    local g, i = MSH.Claims.grantOf(rec, ctx.who)
    if g == nil then
        return S.fail(MSH.Claims.roleOf(rec, ctx.who) and CODE.BAD_USER or CODE.NOT_FOUND)
    end
    local bad = MSH.Claims.bindActor(ctx)
    if bad then return S.fail(bad) end
    local old = toSet(N.desiredPlayers(rec))
    table.remove(rec.grants, i)
    R.touch(rec)
    finish(ctx, rec, old, { [ctx.who] = true }, "LEAVE", ctx.who)
    local via = MSH.Claims.roleOf(rec, ctx.who) ~= nil
    return S.ok({ claimId = rec.claimId, viaFaction = via or nil })
end

-- ===== 陣營 =====

-- 寫入新的 factionShare（分享或恢復）：大小預檢 → 暫時寫入算原生名字總數，超過就還原。成功回 nil，失敗回結果碼
local function bindFaction(rec, f, bits)
    local name, leader = f:getName(), f:getOwner()             -- Faction.java:273、281
    if not Sh.boundedName(name) or not Sh.boundedName(leader) then return CODE.BAD_FACTION end
    local fs = { name = name, leader = leader, bits = bits, state = "GRANTED" }
    if R.estimateBytes(fs) > LIMIT.REGISTRY_BYTES then return CODE.REGISTRY_FULL end
    local before, beforeRef = rec.factionShare, N.factionRefs[rec.claimId]
    rec.factionShare = fs
    N.factionRefs[rec.claimId] = f
    if rosterNames() > LIMIT.NATIVE_NAMES then
        rec.factionShare, N.factionRefs[rec.claimId] = before, beforeRef
        return CODE.ROSTER_FULL
    end
    return nil
end

-- 綁屋主目前所在的陣營＋當下領袖；已有分享（任何狀態）就換掉。超過投影上限照存、不投影
function Sh.shareFaction(ctx)
    local rec, code = target(ctx, true)
    if rec == nil then return S.fail(code) end
    if not MSH.Settings.get().allowFactionShare then return S.fail(CODE.FACTION_DISABLED) end
    local bits = Sh.normalize(ctx.args.bits)
    if bits == nil then return S.fail(CODE.BAD_ARGS) end
    local f = Sh.factionOf(ctx.who)
    if f == nil then return S.fail(CODE.NO_FACTION) end
    local old = toSet(N.desiredPlayers(rec))
    code = bindFaction(rec, f, bits)
    if code then return S.fail(code) end
    R.touch(rec)
    finish(ctx, rec, old, old, "FACTION_SHARE", rec.factionShare.name .. " " .. tostring(bits))
    return S.ok({ claimId = rec.claimId, revision = rec.revision })
end

-- MANAGE 成員可以停止陣營分享，但分享含 MANAGE 時不行（和「不能動持有 MANAGE 的人」一致）
function Sh.unshareFaction(ctx)
    local rec, code = target(ctx, false)
    if rec == nil then return S.fail(code) end
    local fs = rec.factionShare
    if type(fs) ~= "table" then return S.fail(CODE.BAD_USER) end
    if rec.owner ~= ctx.who and MSH.hasBit(fs.bits, SHARE.MANAGE) then return S.fail(CODE.NOT_OWNER) end
    local old = toSet(N.desiredPlayers(rec))
    rec.factionShare = nil
    N.factionRefs[rec.claimId] = nil
    R.touch(rec)
    finish(ctx, rec, old, old, "FACTION_UNSHARE", nil)
    return S.ok({ claimId = rec.claimId, revision = rec.revision })
end

-- 恢復＝重綁目前同名陣營的領袖（屋主要在那個陣營），位元沿用（§6.5；VM H.restoreFactionShare）
function Sh.resumeFaction(ctx)
    local rec, code = target(ctx, true)
    if rec == nil then return S.fail(code) end
    local fs = rec.factionShare
    if type(fs) ~= "table" then return S.fail(CODE.BAD_USER) end
    if not MSH.Settings.get().allowFactionShare then return S.fail(CODE.FACTION_DISABLED) end
    local f = type(fs.name) == "string" and Faction.getFaction(fs.name) or nil   -- Faction.java:140
    if f == nil then return S.fail(CODE.FACTION_GONE) end
    if not (f:isOwner(ctx.who) or f:isMember(ctx.who)) then return S.fail(CODE.NO_FACTION) end
    local bits = Sh.normalize(fs.bits)
    if bits == nil then return S.fail(CODE.BAD_ARGS) end
    local old = toSet(N.desiredPlayers(rec))
    code = bindFaction(rec, f, bits)
    if code then return S.fail(code) end
    R.touch(rec)
    finish(ctx, rec, old, old, "FACTION_RESUME", rec.factionShare.name)
    return S.ok({ claimId = rec.claimId, revision = rec.revision })
end

-- ===== round-robin 同步 =====

-- 失效的陣營分享寫成 SUSPENDED（持久化、加 revision）；名單由呼叫端 apply
function Sh.suspend(rec, why)
    local fs = rec.factionShare
    fs.state, fs.reason = "SUSPENDED", why
    N.factionRefs[rec.claimId] = nil
    R.touch(rec)
    MSH.Audit.write("FACTION_SUSPENDED", { actor = rec.owner, claimId = rec.claimId, code = why, detail = fs.name })
end

local function sameSet(a, b)
    if b == nil then return false end
    for u in pairs(a) do if not b[u] then return false end end
    for u in pairs(b) do if not a[u] then return false end end
    return true
end

-- 一筆：失效就暫停；應有名單和上次套用的不同才掃原生（idx 每批最多掃一次）
local function syncOne(rec, st)
    local suspended = false
    if rec.factionShare.state == "GRANTED" then
        local f, why = N.faction(rec)
        if f == nil and why ~= nil then
            Sh.suspend(rec, why)
            suspended = true
        end
    end
    if not suspended and sameSet(toSet(N.desiredPlayers(rec)), Sh.last[rec.claimId]) then return end
    st.idx = st.idx or N.index()
    local affected, changed = Sh.apply(rec, nil, st.defer, st.idx)
    if suspended or changed then
        affected[rec.owner] = true
        pushChanged(rec.claimId, affected, st.defer)
    end
end

-- 新一輪：有 factionShare 的紀錄；順便丟掉已不在 registry 的 Sh.last（先收集再改）
function Sh.rebuild(now)
    local q, drop = {}, {}
    for id, rec in pairs(R.md.claims) do
        if MSH.isInt(id) and type(rec) == "table" and type(rec.factionShare) == "table" then q[#q + 1] = id end
    end
    for id in pairs(Sh.last) do
        if R.get(id) == nil then drop[#drop + 1] = id end
    end
    for _, id in ipairs(drop) do Sh.last[id] = nil end
    Sh.queue, Sh.cursor, Sh.cycleAt = q, 1, now
end

-- 每 tick 依經過時間輪檢一部分（全部輪完 ≈ CYCLE_MS）；持全域鎖，放鎖後才送網路。鎖被佔用就等下個 tick
function Sh.tick(now)
    if not R.ready() or S.locked then return end
    local dt = now - (Sh.lastTick or now)
    Sh.lastTick = now
    if Sh.cursor > #Sh.queue then
        if Sh.cycleAt ~= nil and now - Sh.cycleAt < Sh.CYCLE_MS then return end
        Sh.rebuild(now)
    end
    local total = #Sh.queue
    if total == 0 then return end
    local n = math.min(Sh.MAX_PER_TICK, math.max(1, math.ceil(total * dt / Sh.CYCLE_MS)))
    local sends = {}
    local st = { defer = function(fn) sends[#sends + 1] = fn end }
    S.withLock(function()
        for _ = 1, n do
            if Sh.cursor > total then break end
            local rec = R.get(Sh.queue[Sh.cursor])
            Sh.cursor = Sh.cursor + 1
            if rec ~= nil and R.isLive(rec) and not rec.malformed and type(rec.factionShare) == "table" then
                syncOne(rec, st)
            end
        end
        return true
    end)
    for _, fn in ipairs(sends) do
        local ok, err = pcall(fn)
        if not ok then MSH.log("sharing send failed: " .. tostring(err)) end
    end
end

-- ===== 指令登記 =====

S.define("share", { kind = "mutation",
    fields = { claimId = "claimId", expectedRevision = "revision", targetUsername = "username", bits = "bits" },
    run = function(ctx) return MSH.Sharing.share(ctx) end })
S.define("unshare", { kind = "mutation",
    fields = { claimId = "claimId", expectedRevision = "revision", targetUsername = "username" },
    run = function(ctx) return MSH.Sharing.unshare(ctx) end })
S.define("shareFaction", { kind = "mutation",
    fields = { claimId = "claimId", expectedRevision = "revision", bits = "bits" },
    run = function(ctx) return MSH.Sharing.shareFaction(ctx) end })
S.define("unshareFaction", { kind = "mutation", fields = { claimId = "claimId", expectedRevision = "revision" },
    run = function(ctx) return MSH.Sharing.unshareFaction(ctx) end })
S.define("resumeFaction", { kind = "mutation", fields = { claimId = "claimId", expectedRevision = "revision" },
    run = function(ctx) return MSH.Sharing.resumeFaction(ctx) end })
S.define("leave", { kind = "mutation", fields = { claimId = "claimId" },
    run = function(ctx) return MSH.Sharing.leave(ctx) end })

S.hook("tick", "sharing", function(now) MSH.Sharing.tick(now) end)
