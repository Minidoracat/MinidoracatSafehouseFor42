-- MinidoracatSafehouse/Sharing.lua：分享指令（指定玩家、陣營）與陣營 round-robin 同步
-- （計畫 §4.2 第 212-213、238 行，§4.3、§4.4、§6.4、§6.5、§10.5 伺服器端）。
-- 指定玩家三個指令（使用者 2026-10-20 核准批量修改）：share 只新增、shareEdit 對一位或多位只加減有變的位元、
--   unshareMany 停止分享給一位或多位；不再有整組覆蓋既有成員權限的路徑。
-- 位元的唯一來源是 Claims.roleOf；原生名單應有的人是 Native.desiredPlayers。Reconcile 也用 desiredPlayers 收斂，
--   兩邊同一個判定，所以不會一邊加、一邊移。
-- 撤銷（移除、停止分享、陣營暫停、離開、陣營少了人）用 Native.revoke（kickUserFromSafehouse：人在屋內立即傳出，§4.4），
--   只撤銷不再有任何資格的人；新增用 addPlayer＋放鎖後廣播。一間的每一塊（每個原生）都照同一份名單改；
--   原生不在（lapsed、等收斂重建）就只改紀錄。
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
Sh.CANDIDATES = 20        -- 分享對象候選最多幾位（同 Economy transfer.recipients）

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

-- 全部 managed 原生名單的名字數（同 Claims.checkCapacity 的算法：每塊各一份，§4.2）
local function rosterNames()
    local n = 0
    for _, r in ipairs(R.list()) do
        if R.isLive(r) then n = n + N.nameCount(r) end
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
    local houses = {}
    for _, e in ipairs(MSH.Lifecycle.findNatives(rec, idx or N.index()) or {}) do
        if e then houses[#houses + 1] = e.house end
    end
    for _, house in ipairs(houses) do
        local have = toSet(N.players(house))
        local added = false
        for _, u in ipairs(after) do
            if not have[u] then
                house:addPlayer(u)  -- SafeHouse.java:292-297
                added = true
            end
        end
        -- 鎖內先把要撤銷的人從每一塊移除（SafeHouse.java:299-304）：放鎖後逐塊 revoke 時，被傳出一塊的人
        -- 若落在同一間的另一塊，那塊也已經不收他，下一次越界檢查就再傳出（不會留在屋裡）
        for _, u in ipairs(gone) do house:removePlayer(u) end
        if added and #gone == 0 then defer(function() N.broadcast(house) end) end
    end
    -- ponytail: 每撤銷一人、每一塊就一次 SafehouseSync（kick 是唯一會傳出屋內玩家的 API），陣營暫停最多（64＋maxShares）×塊數次
    if #houses > 0 then
        for _, u in ipairs(gone) do
            defer(function()
                for _, house in ipairs(houses) do N.revoke(house, u) end
            end)
        end
    end
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

-- 指令的目標紀錄：沒有角色 NOT_FOUND；need 決定屋主以外要什麼位元 → 不符 NOT_OWNER：
--   "owner"＝只限屋主；"manage"＝MANAGE；"invite"＝MANAGE 或 INVITE（邀請新人，share 再細分）。
-- 只在 active 操作；expectedRevision 要相符；通過後綁定 actor（Claims.bindActor）。
-- 回傳 rec, isOwner, actor 的位元 或 nil, code
local function target(ctx, need)
    local a = ctx.args
    local rec = R.get(a.claimId)
    if rec == nil or not R.isLive(rec) or rec.malformed then return nil, CODE.NOT_FOUND end
    local role, bits = MSH.Claims.roleOf(rec, ctx.who)
    if role == nil then return nil, CODE.NOT_FOUND end
    local owner = role == "owner"
    local allowed = owner or (need ~= "owner" and MSH.hasBit(bits, SHARE.MANAGE))
        or (need == "invite" and MSH.hasBit(bits, SHARE.INVITE))
    if not allowed then return nil, CODE.NOT_OWNER end
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

-- bits 的每一位 mine 都有（成員只能給自己有的位元）
local function subsetOf(bits, mine)
    for _, bit in pairs(SHARE) do
        if MSH.hasBit(bits, bit) and not MSH.hasBit(mine, bit) then return false end
    end
    return true
end

-- MANAGE 成員能給、能加減的位元：自己 roleOf 的位元＋INVITE（MANAGE 含邀請能力，自己沒有 INVITE 位元也能給），不含 MANAGE
-- （2026-10-10 審查 MEDIUM；INVITE 使用者 2026-10-11）
local function manageCap(mine)
    local cap = MSH.hasBit(mine, SHARE.INVITE) and mine or mine + SHARE.INVITE
    return MSH.hasBit(cap, SHARE.MANAGE) and cap - SHARE.MANAGE or cap
end

-- 非屋主新增分享（對象還沒有 grant）。MANAGE 成員：位元 ⊆ manageCap。
-- 只有 INVITE：對象必須沒有任何資格（不是屋主、也不靠陣營；否則等於替既有成員加權限，而且陣營撤銷後這個 grant 還留著），
--   位元 ⊆ 自己的位元且不含 INVITE（陣營成員 2026-10-11 審查 MEDIUM）
local function memberMayAdd(rec, user, bits, mine)
    if MSH.hasBit(mine, SHARE.MANAGE) then return subsetOf(bits, manageCap(mine)) end
    return MSH.Claims.roleOf(rec, user) == nil and not MSH.hasBit(bits, SHARE.INVITE) and subsetOf(bits, mine)
end

-- 改既有成員（shareEdit、unshareMany）的對象：每位都要有 grant、不是自己；非屋主不能動持有 MANAGE 的人（grant 或陣營給的）。
-- 回傳照 users 順序的 grants，或 nil, code
local function grantsOf(ctx, rec, owner)
    local out = {}
    for i, user in ipairs(ctx.args.users) do
        local g = MSH.Claims.grantOf(rec, user)
        if g == nil or user == ctx.who then return nil, CODE.BAD_USER end
        if not owner and holdsManage(rec, user) then return nil, CODE.NOT_OWNER end
        out[i] = g
    end
    return out
end

-- ===== 分享對象：存在檢查與候選 =====

-- 伺服器認得的玩家：在線、Steam 模式登入過（bindings，Identity.bindOnLogin）、管理員設過個人名額（overrides）、
--   某一間的屋主或成員。原版帳號資料庫 Lua 讀不到（ServerWorldDatabase 沒有 expose）；非 Steam 伺服器沒有 bindings，
--   要對方在線或已經和某一間安全屋有關
function Sh.known(name)
    if R.binding(name) ~= nil or R.override(name) ~= nil or N.onlinePlayer(name) ~= nil then return true end
    for id, rec in pairs(R.md.claims) do
        if MSH.isInt(id) and type(rec) == "table" and not rec.malformed
            and (rec.owner == name or MSH.Claims.grantOf(rec, name) ~= nil) then
            return true
        end
    end
    return false
end

local function lowerFirst(a, b)
    local al, bl = string.lower(a), string.lower(b)
    if al ~= bl then return al < bl end
    return a < b
end

-- 分享對象候選（「成員與分享」頁輸入框的下拉）：照 Economy transfer.recipients（ECTransfer.lua:269-306）的順序——
--   名字完全相符（分大小寫）的已知玩家、自己的安全屋分享過的人、名字含關鍵字（不分大小寫）的在線玩家，
--   最多 Sh.CANDIDATES 位，rows＝{ name, online }。離線的已知玩家只在完全相符時列出，不能用關鍵字列舉全服玩家。
--   不列自己與屋主；只有 INVITE 的成員不列這間已經有資格的人（伺服器不讓他動既有成員，memberMayShare）。
--   只有能在這間新增分享的人能查（同 share 的 target(ctx, "invite")，但不比 revision、不綁定）
function Sh.candidates(ctx)
    local rec = R.get(ctx.args.claimId)
    if rec == nil or not R.isLive(rec) or rec.malformed then return S.fail(CODE.NOT_FOUND) end
    local role, mine = MSH.Claims.roleOf(rec, ctx.who)
    if role == nil then return S.fail(CODE.NOT_FOUND) end
    local inviteOnly = role ~= "owner" and not MSH.hasBit(mine, SHARE.MANAGE)
    if inviteOnly and not MSH.hasBit(mine, SHARE.INVITE) then return S.fail(CODE.NOT_OWNER) end
    local query = MSH.trim(ctx.args.query)
    local needle = string.lower(query)
    local online = {}
    if S.netUp then
        local list = getOnlinePlayers()
        for i = 0, list:size() - 1 do
            local name = list:get(i):getUsername()
            if MSH.validUsername(name) then online[name] = true end
        end
    end
    local rows, seen = {}, { [ctx.who] = true, [rec.owner] = true }
    local function add(name)
        if #rows >= Sh.CANDIDATES or seen[name] then return end
        seen[name] = true
        if inviteOnly and MSH.Claims.roleOf(rec, name) ~= nil then return end
        rows[#rows + 1] = { name = name, online = online[name] == true }
    end
    local function matches(name) return string.find(string.lower(name), needle, 1, true) ~= nil end
    if query ~= "" and Sh.known(query) then add(query) end
    for _, r in ipairs(R.list()) do
        if r.owner == ctx.who then
            for _, g in ipairs(r.grants) do
                if matches(g.user) then add(g.user) end
            end
        end
    end
    local names = {}
    for name in pairs(online) do
        if matches(name) then names[#names + 1] = name end
    end
    MSH.sortSafe(names, lowerFirst)
    for _, name in ipairs(names) do add(name) end
    return S.ok({ rows = rows })
end

-- ===== 指定玩家 =====

-- 新增分享：對象還不能有 grant。改既有成員的權限走 shareEdit（使用者 2026-10-20 核准批量修改：不再整組覆蓋）
function Sh.share(ctx)
    local a = ctx.args
    local rec, owner, mine = target(ctx, "invite")
    if rec == nil then return S.fail(owner) end
    local bits = Sh.normalize(a.bits)
    if bits == nil then return S.fail(CODE.BAD_ARGS) end
    local user = a.targetUsername
    if user == rec.owner or user == ctx.who or MSH.Claims.grantOf(rec, user) ~= nil then return S.fail(CODE.BAD_USER) end
    if not owner and not memberMayAdd(rec, user, bits, mine) then return S.fail(CODE.NOT_OWNER) end
    -- 新加的人要是伺服器認得的玩家：打錯字不會變成一筆沒人用的分享（使用者 2026-10-12）
    if not Sh.known(user) then return S.fail(CODE.UNKNOWN_PLAYER) end
    if #rec.grants + 1 > MSH.Settings.get().maxShares then return S.fail(CODE.SHARE_FULL) end
    local entry = { user = user, bits = bits }
    if R.estimateBytes(entry) > LIMIT.REGISTRY_BYTES then return S.fail(CODE.REGISTRY_FULL) end
    local old = toSet(N.desiredPlayers(rec))
    -- 新名字在這間的每一塊各佔一個
    if not old[user] and rosterNames() + #rec.rects > LIMIT.NATIVE_NAMES then return S.fail(CODE.ROSTER_FULL) end
    rec.grants[#rec.grants + 1] = entry
    R.touch(rec)
    finish(ctx, rec, old, { [user] = true }, "SHARE", user .. " " .. tostring(bits))
    return S.ok({ claimId = rec.claimId, revision = rec.revision })
end

-- 改既有成員的權限（一位或多位，使用者 2026-10-20 核准批量修改）：每位只加 add、只拿 remove，其他位元不動。
-- add、remove 不重疊、不能都是 0；remove 不含 MEMBER（移除成員走 unshareMany）。屋主或 MANAGE 成員；MANAGE 成員只能
-- 加減 manageCap 內的位元，對方比自己多的權限照留。整批一起成功或一起失敗；一次寫入、一次同步、一行稽核
function Sh.edit(ctx)
    local a = ctx.args
    local rec, owner, mine = target(ctx, "manage")
    if rec == nil then return S.fail(owner) end
    local add, remove = a.add, a.remove
    if add + remove == 0 or MSH.maskBits(add, remove) ~= 0 or MSH.hasBit(remove, SHARE.MEMBER) then
        return S.fail(CODE.BAD_ARGS)
    end
    if not owner and not subsetOf(add + remove, manageCap(mine)) then return S.fail(CODE.NOT_OWNER) end
    local grants, code = grantsOf(ctx, rec, owner)
    if grants == nil then return S.fail(code) end
    local old = toSet(N.desiredPlayers(rec))
    for _, g in ipairs(grants) do
        local bits = g.bits - MSH.maskBits(g.bits, remove)
        g.bits = bits + add - MSH.maskBits(bits, add)
    end
    R.touch(rec)
    finish(ctx, rec, old, toSet(a.users), "SHARE_EDIT",
        table.concat(a.users, ",") .. " +" .. tostring(add) .. " -" .. tostring(remove))
    return S.ok({ claimId = rec.claimId, revision = rec.revision })
end

-- 停止分享給 users（一位或多位都走這裡，使用者 2026-10-20）：對象規則同 shareEdit。只撤銷不再有任何資格的人（陣營成員
-- 照留在原生名單）；整批一起成功或一起失敗，一次寫入、一次同步、一行稽核
function Sh.unshareMany(ctx)
    local rec, owner = target(ctx, "manage")
    if rec == nil then return S.fail(owner) end
    local _, code = grantsOf(ctx, rec, owner)
    if code then return S.fail(code) end
    local drop = toSet(ctx.args.users)
    local old = toSet(N.desiredPlayers(rec))
    for i = #rec.grants, 1, -1 do
        if drop[rec.grants[i].user] then table.remove(rec.grants, i) end
    end
    R.touch(rec)
    finish(ctx, rec, old, drop, "UNSHARE", table.concat(ctx.args.users, ","))
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

-- 綁屋主目前所在的陣營＋當下領袖；已有分享（任何狀態）就換掉。超過投影上限照存、不投影。
-- 位元不能超出 SHARE_FACTION_MAX（不給邀請、管理）→ BAD_ARGS
function Sh.shareFaction(ctx)
    local rec, code = target(ctx, "owner")
    if rec == nil then return S.fail(code) end
    if not MSH.Settings.get().allowFactionShare then return S.fail(CODE.FACTION_DISABLED) end
    local bits = Sh.normalize(ctx.args.bits)
    if bits == nil or MSH.maskBits(bits, MSH.SHARE_FACTION_MAX) ~= bits then return S.fail(CODE.BAD_ARGS) end
    local f = Sh.factionOf(ctx.who)
    if f == nil then return S.fail(CODE.NO_FACTION) end
    local old = toSet(N.desiredPlayers(rec))
    code = bindFaction(rec, f, bits)
    if code then return S.fail(code) end
    R.touch(rec)
    finish(ctx, rec, old, old, "FACTION_SHARE", rec.factionShare.name .. " " .. tostring(bits))
    return S.ok({ claimId = rec.claimId, revision = rec.revision })
end

-- MANAGE 成員也可以停止陣營分享（陣營分享不會帶管理，見 SHARE_FACTION_MAX）
function Sh.unshareFaction(ctx)
    local rec, code = target(ctx, "manage")
    if rec == nil then return S.fail(code) end
    if type(rec.factionShare) ~= "table" then return S.fail(CODE.BAD_USER) end
    local old = toSet(N.desiredPlayers(rec))
    rec.factionShare = nil
    N.factionRefs[rec.claimId] = nil
    R.touch(rec)
    finish(ctx, rec, old, old, "FACTION_UNSHARE", nil)
    return S.ok({ claimId = rec.claimId, revision = rec.revision })
end

-- 恢復＝重綁目前同名陣營的領袖（屋主要在那個陣營），位元沿用（§6.5；VM H.restoreFactionShare）；
-- 舊資料裡的邀請／管理在這裡遮掉
function Sh.resumeFaction(ctx)
    local rec, code = target(ctx, "owner")
    if rec == nil then return S.fail(code) end
    local fs = rec.factionShare
    if type(fs) ~= "table" then return S.fail(CODE.BAD_USER) end
    if not MSH.Settings.get().allowFactionShare then return S.fail(CODE.FACTION_DISABLED) end
    local f = type(fs.name) == "string" and Faction.getFaction(fs.name) or nil   -- Faction.java:140
    if f == nil then return S.fail(CODE.FACTION_GONE) end
    if not (f:isOwner(ctx.who) or f:isMember(ctx.who)) then return S.fail(CODE.NO_FACTION) end
    local bits = Sh.normalize(fs.bits)
    if bits == nil then return S.fail(CODE.BAD_ARGS) end
    bits = MSH.maskBits(bits, MSH.SHARE_FACTION_MAX)
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
S.define("shareCandidates", { kind = "query", fields = { claimId = "claimId", query = "query" },
    run = function(ctx) return MSH.Sharing.candidates(ctx) end })
S.define("shareEdit", { kind = "mutation",
    fields = { claimId = "claimId", expectedRevision = "revision", users = "users", add = "bits", remove = "bits" },
    run = function(ctx) return MSH.Sharing.edit(ctx) end })
S.define("unshareMany", { kind = "mutation", fields = { claimId = "claimId", expectedRevision = "revision", users = "users" },
    run = function(ctx) return MSH.Sharing.unshareMany(ctx) end })
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
