-- MinidoracatSafehouse/Idle.lua：閒置收回與保險（使用者 2026-10-14，decisions.md「閒置收回」兩條）。
-- 到訪：原版每塊的 lastVisited。名單上的人站進那塊時引擎約每 20 秒記一次（IsoPlayer.java:2177-2185 →
--   SafeHouse.playerAllowed(String)：名單或屋主，SafeHouse.java:288-290），建立時記當下（SafeHouse.java:71），
--   跟 map_meta.bin 一起存檔。名單＝原生名單（Native.desiredPlayers）；service owner @MSH:<id> 永遠不會站進去。
--   整間的最後到訪取各塊最大值。SafeHouseRemovalTime 是 0（Health 必要設定），原版不會自己刪。
-- 期限：免費、legacy 與沒有付費名額保護的屋看 IdleDays；買斷名額保護的看 IdleBuyDays；租用名額保護的不收（照租期）。
--   付費名額照數量保護同一級裡最久沒人回去的幾間：租用先、買斷其次。不照免費位分配（Claims.slots）：
--   免費那間收走後免費位會轉給下一間，照免費位分會讓下一間的期限跟著縮短。買斷保護不比免費弱
--   （IdleBuyDays 比 IdleDays 短時照免費；IdleDays 是 0＝整個功能關掉，買斷那間也不收）。
-- 保護減弱時重新起算：租用、不收（off）、讀不到（unknown）的屋每次分類都記 held＝當下；種類比上次弱（失去租用或買斷、
--   Economy 不見、IdleBuyDays 改得不比免費長）、或沒有上次的種類（第一次分類、隔離後重新綁回）也記 held。
--   anchor＝max(最後到訪, 保險結束, since[種類], held)：失去保護的屋從那時起有完整期限，讀不到的期間不算。上次的種類
--   與 held 存在狀態表，所以每分鐘的檢查把每一位屋主的每一級都分類一次（不預篩快到期的：預篩會漏掉還沒到期、
--   卻剛失去保護的屋），在同一輪決定收不收之前；同一組一輪只收一間（收掉後付費名額改去保護剩下的，下一輪重新分類）。
-- 停機不算：每分鐘記下檢查時間，兩次相隔超過 DOWNTIME_MS 記一段停機（伺服器沒在跑，或空服暫停時 OnTick 不跑）；
--   閒置時間扣掉 anchor 之後的停機。起算：since[種類]＝這版第一次檢查的時間；那種不收（0）的期間每分鐘更新、
--   天數被改短時也更新（管理員改短不會讓一批屋馬上被收）。
-- 保險：Economy 產品 insure<N>（Economy.lua）；保險期間視同有人到訪，結束後重新倒數。Economy 在到期後移除租約，
--   所以每位屋主每級記 { live＝最後看到的 paidUntil, ended＝自然結束過的最晚時間 }：租約不在而 live 已過＝自然結束、
--   併進 ended；live 還沒到租約就不在＝退款，只丟 live。通知帶的快照照順序套用（noteInsurance）。
-- 讀不到 Economy（READY 時讀失敗、FAILED、租約結果未定）＝unknown：那一級不收、暫停計時。
-- 狀態在 Global ModData（TAG）：跟世界存檔一起回滾，和 Economy 的錢與租約同進退。
-- 收回走 Lifecycle.release（原因 IDLE、地契不退），持全域鎖、每次檢查最多 MAX_PER_SWEEP 間
-- （同一天起算的舊屋會同時到期，一次收太多會連續廣播）。

if isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Settings"
require "MinidoracatSafehouse/Audit"
require "MinidoracatSafehouse/Registry"
require "MinidoracatSafehouse/Native"
require "MinidoracatSafehouse/Health"
require "MinidoracatSafehouse/Lifecycle"
require "MinidoracatSafehouse/Server"
require "MinidoracatSafehouse/Economy"

local MSH = MinidoracatSafehouse
local I = MSH.Idle or {}
MSH.Idle = I

local S = MSH.Srv
local CODE = MSH.CODE
local LC = MSH.LIFECYCLE
local DAY_MS = 86400000

I.TAG = MSH.TAG .. "_Idle"
I.DOWNTIME_MS = 10 * 60000
I.MAX_PER_SWEEP = 5
I.DOWN_MAX = 1000          -- 停機紀錄的保險絲：正常會照最舊的 anchor 清掉
I.insQueue = I.insQueue or {}   -- noteInsurance：{ owner, tier, obs? }，下個 tick 照順序套用

-- 種類的保護強度：數字越大越不會被收；held 只在 3 或比上次弱的時候更新
local RANK = { free = 1, buy = 2, rent = 3, off = 3, unknown = 3 }

local function isEmpty(t)
    for _ in pairs(t) do return false end
    return true
end

-- 狀態表：since = { free, buy }、days = { free, buy }（上次檢查時的有效天數，判斷改短）、at（上次檢查）、
-- down = { { s, e } }（停機）、ins = { owner → { [tier] = { live, ended } } }、kinds = { [claimId] = 種類 }、
-- held = { [claimId] = ms }
function I.state()
    local md = ModData.getOrCreate(I.TAG)
    for _, k in ipairs({ "since", "days", "down", "ins", "kinds", "held" }) do
        if type(md[k]) ~= "table" then md[k] = {} end
    end
    return md
end

-- anchor 之後到 now 的停機毫秒數
function I.downAfter(md, anchor, now)
    local d = 0
    for _, x in ipairs(md.down) do
        if type(x) == "table" and MSH.isFinite(x.s) and MSH.isFinite(x.e) and x.e > anchor then
            d = d + math.min(x.e, now) - math.max(x.s, anchor)
        end
    end
    return d
end

-- 從 anchor 起算、扣掉停機的閒置毫秒數；anchor 在未來（保險中）時是負的
function I.idleMs(md, anchor, now)
    if anchor >= now then return now - anchor end
    return now - anchor - I.downAfter(md, anchor, now)
end

-- 一間的最後到訪：這個標記每個原生的 lastVisited 取最大；沒有原生回 nil
function I.lastVisit(rec, idx)
    local best
    for _, e in ipairs(idx.byClaim[rec.claimId] or {}) do
        local ok, v = pcall(function() return e.house:getLastVisited() end)
        if ok and MSH.isFinite(v) and (best == nil or v > best) then best = v end
    end
    return best
end

-- Economy READY 且有保險產品時讀這位屋主這一級的保險租約；其餘回 nil（只用記錄）
local function liveInsurance(owner, t)
    local E = MSH.Economy
    if E and E.status == "READY" and E.insureReady then return E.insurance(owner, t) end
    return nil
end

-- 付費名額 { rent, buy }。Economy 沒裝或版本不支援＝都 0（鐵則：付費名額＝0；失去保護的屋由 held 給完整期限）；
-- 讀不到或結果未定回 nil
local function coverage(owner, t)
    local E = MSH.Economy
    local st = E and E.status
    if st == "ABSENT" or st == "UNSUPPORTED" then return { rent = 0, buy = 0 } end
    if st ~= "READY" then return nil end
    return E.coverage(owner, t)
end

-- 保險記錄：舊版只存數字的當成 live
local function insRecord(md, owner, t)
    local mine = md.ins[owner]
    local r = type(mine) == "table" and mine[t] or nil
    if MSH.isFinite(r) then return { live = r } end
    if type(r) ~= "table" then return {} end
    return { live = MSH.isFinite(r.live) and r.live or nil, ended = MSH.isFinite(r.ended) and r.ended or nil }
end

local function insEnd(r)
    if r.live == nil then return r.ended end
    if r.ended == nil then return r.live end
    return math.max(r.live, r.ended)
end

-- 套用一次觀察到的保險租約（obs.paidUntil＝nil：沒有租約）；回新的記錄
local function insApply(r, obs, now)
    local out = { live = r.live, ended = r.ended }
    local function endNow(v)
        if out.ended == nil or v > out.ended then out.ended = v end
    end
    if obs.paidUntil ~= nil then
        -- 上一張已自然結束、這是新的一張：上一張的結束時間併進 ended
        if out.live ~= nil and out.live <= now and out.live ~= obs.paidUntil then endNow(out.live) end
        out.live = obs.paidUntil
    elseif out.live ~= nil then
        if out.live <= now then endNow(out.live) end   -- 自然結束、已被 Economy 移除
        out.live = nil                                  -- 還沒到就不在：退款，只丟這一張
    end
    return out
end

local function insStore(md, owner, t, r)
    local mine = type(md.ins[owner]) == "table" and md.ins[owner] or {}
    mine[t] = (r.live ~= nil or r.ended ~= nil) and { live = r.live, ended = r.ended } or nil
    md.ins[owner] = not isEmpty(mine) and mine or nil
end

-- 保險結束時間（可能在未來；nil＝沒有保險）與 known（false＝應該讀得到 Economy 卻讀不到）。
-- live＝E.insurance 的回覆（nil：不讀 Economy，只用記錄）；write＝true 才寫回記錄（detail 查詢不寫）
function I.insuredUntil(md, owner, t, now, live, write)
    local r = insRecord(md, owner, t)
    if live == nil then return insEnd(r), true end
    if not live.ok then return insEnd(r), false end
    local n = insApply(r, live, now)
    if write then insStore(md, owner, t, n) end
    return insEnd(n), true
end

-- 買斷保護的天數：不比免費弱。任一種是 0（不收）就不收；否則取較長的。回天數與種類名（等於免費天數時算 free）
local function buyRule(cfg)
    if cfg.idleDays <= 0 or cfg.idleBuyDays <= 0 then return 0, "off" end
    if cfg.idleBuyDays > cfg.idleDays then return cfg.idleBuyDays, "buy" end
    return cfg.idleDays, "free"
end

-- 一位屋主一級的 active 屋分種類。list＝{ { rec, last } }（last 是 nil：沒有原生，當成剛到訪、標 unknown）。
-- 回傳 claimId → { kind, days?, anchor?, insEnd? }；kind＝free｜buy｜rent｜off｜unknown，只有 free、buy 帶 anchor。
-- write＝true 時記下這次的種類與 held（每分鐘的檢查）；detail 不寫，照同一套規則算
function I.classify(md, owner, t, list, now, cfg, live, write)
    local cov = coverage(owner, t)
    local ins, known = I.insuredUntil(md, owner, t, now, live, write)
    local unknown = cov == nil or not known
    local sorted = {}
    for _, x in ipairs(list) do
        sorted[#sorted + 1] = { rec = x.rec, missing = x.last == nil, raw = math.max(x.last or now, ins or 0) }
    end
    MSH.sortSafe(sorted, function(a, b)
        if a.raw ~= b.raw then return a.raw < b.raw end
        return a.rec.claimId < b.rec.claimId
    end)
    local buyDays, buyKind = buyRule(cfg)
    local out = {}
    for i, x in ipairs(sorted) do
        local kind, days = "free", cfg.idleDays
        if unknown or x.missing then
            kind, days = "unknown", nil
        elseif i <= cov.rent then
            kind, days = "rent", nil
        elseif i <= cov.rent + cov.buy then
            kind, days = buyKind, buyDays
        end
        if days ~= nil and days <= 0 then kind, days = "off", nil end
        local id = x.rec.claimId
        local old, held = md.kinds[id], md.held[id]
        if not MSH.isFinite(held) then held = nil end
        if RANK[kind] >= 3 or RANK[old] == nil or RANK[kind] < RANK[old] then held = now end
        if write then md.kinds[id], md.held[id] = kind, held end
        local c = { kind = kind, insEnd = ins }
        if days ~= nil then
            c.days = days
            -- 買斷不比免費弱：免費那邊重新起算過（IdleDays 改短）也算進來，免費屋升級成買斷時 anchor 不會倒退
            local since = md.since[kind] or now
            if kind == "buy" then since = math.max(since, md.since.free or now) end
            c.anchor = math.max(x.raw, since, held or 0)
        end
        out[id] = c
    end
    return out
end

-- 停機紀錄：結束在 floor 之前的用不到了（floor 不看保險：退款會把 anchor 拉回去）；種類與 held：不再是 active 的刪
-- （回到 active 時第一次分類會重新給完整期限）；保險記錄：屋主那一級已經沒有任何紀錄（含停用、隔離中的）才刪
function I.prune(md, floor, owned, active)
    local keep = {}
    for _, x in ipairs(md.down) do
        if type(x) == "table" and floor ~= nil and MSH.isFinite(x.e) and x.e > floor then keep[#keep + 1] = x end
    end
    while #keep > I.DOWN_MAX do table.remove(keep, 1) end
    md.down = keep
    for _, k in ipairs({ "kinds", "held" }) do
        local drop = {}
        for id in pairs(md[k]) do
            if not active[id] then drop[#drop + 1] = id end
        end
        for _, id in ipairs(drop) do md[k][id] = nil end
    end
    local drop = {}
    for owner, tiers in pairs(md.ins) do
        if type(tiers) ~= "table" then
            drop[#drop + 1] = { owner = owner }
        else
            for t in pairs(tiers) do
                if owned[owner] == nil or owned[owner][t] == nil then drop[#drop + 1] = { owner = owner, tier = t } end
            end
        end
    end
    for _, d in ipairs(drop) do
        local tiers = md.ins[d.owner]
        if d.tier ~= nil and type(tiers) == "table" then tiers[d.tier] = nil end
        if d.tier == nil or (type(tiers) == "table" and isEmpty(tiers)) then md.ins[d.owner] = nil end
    end
end

function I.release(x, now, sends)
    local rec = x.rec
    local id, owner = rec.claimId, rec.owner
    local roster = MSH.Native.desiredPlayers(rec)
    local ok, code = MSH.Lifecycle.release(rec, "IDLE", "idle-" .. id, now, function(fn) sends[#sends + 1] = fn end)
    if not ok then
        MSH.Audit.throttled("IDLE_RELEASE|" .. id, 3600000, "IDLE_RELEASE_FAILED",
            { actor = owner, claimId = id, code = code }, now)
        return false
    end
    MSH.Audit.write("IDLE_RELEASED", { actor = owner, claimId = id, code = string.upper(x.kind),
        detail = tostring(math.floor(x.idle / 3600000)) .. "h" })
    sends[#sends + 1] = function()
        for _, u in ipairs(roster) do
            local p = MSH.Native.onlinePlayer(u)
            if p then sendServerCommand(p, MSH.MODULE, "changed", { claimId = id }) end   -- LuaManager.java:8962-8966
        end
    end
    return true
end

-- 這位屋主這一級的 active 屋與最後到訪（idx：Native.index()）
local function groupOf(owner, t, idx)
    local list = {}
    for _, r in ipairs(MSH.Registry.byOwner(owner)) do
        if r.lifecycle == LC.ACTIVE and r.deedTier == t and r.rects ~= nil then
            list[#list + 1] = { rec = r, last = I.lastVisit(r, idx) }
        end
    end
    return list
end

-- 持鎖：每位屋主的每一級都分類（記下種類與 held）、每組挑最久沒人回去的一間到期屋、收回其中最久的 MAX_PER_SWEEP 間
function I.collect(md, now, cfg, sends)
    local idx = MSH.Native.index()
    local groups, order, active, owned = {}, {}, {}, {}
    for _, rec in ipairs(MSH.Registry.list()) do
        if rec.owner ~= nil then
            local o = owned[rec.owner] or {}
            owned[rec.owner] = o
            o[rec.deedTier] = true
        end
        if rec.lifecycle == LC.ACTIVE and rec.owner ~= nil and rec.rects ~= nil then
            active[rec.claimId] = true
            local byTier = groups[rec.owner] or {}
            groups[rec.owner] = byTier
            local g = byTier[rec.deedTier]
            if g == nil then
                g = { owner = rec.owner, tier = rec.deedTier, list = {} }
                byTier[rec.deedTier] = g
                order[#order + 1] = g
            end
            g.list[#g.list + 1] = { rec = rec, last = I.lastVisit(rec, idx) }
        end
    end
    -- 停機紀錄的水位：之後任何 anchor 都不會早於 max(最後到訪, 兩種 since 較早的, held)（這幾個只會往後）
    local sinceMin = math.min(md.since.free, md.since.buy)
    local due, floor = {}, nil
    for _, g in ipairs(order) do
        local info = I.classify(md, g.owner, g.tier, g.list, now, cfg, liveInsurance(g.owner, g.tier), true)
        local pick
        for _, x in ipairs(g.list) do
            local id = x.rec.claimId
            local held = md.held[id]
            local base = math.max(x.last or now, sinceMin, MSH.isFinite(held) and held or 0)
            if floor == nil or base < floor then floor = base end
            local c = info[id]
            if c and c.anchor ~= nil then
                local idle = I.idleMs(md, c.anchor, now)
                if idle > c.days * DAY_MS and (pick == nil or idle > pick.idle) then
                    pick = { rec = x.rec, kind = c.kind, idle = idle }
                end
            end
        end
        if pick then due[#due + 1] = pick end
    end
    I.prune(md, floor, owned, active)
    MSH.sortSafe(due, function(a, b)
        if a.idle ~= b.idle then return a.idle > b.idle end
        return a.rec.claimId < b.rec.claimId
    end)
    for i = 1, math.min(#due, I.MAX_PER_SWEEP) do I.release(due[i], now, sends) end
end

-- 每分鐘：停機與起算的記帳不看鎖與設定健康；收回要專用伺服器就緒、registry 可寫、設定健康、拿得到鎖
function I.sweep(now)
    local E = MSH.Economy
    if not S.ready or not MSH.Registry.ready() or E == nil or E.status == "OFF" then return end
    local md = I.state()
    if MSH.isFinite(md.at) and now - md.at > I.DOWNTIME_MS then
        md.down[#md.down + 1] = { s = md.at, e = now }
        MSH.log("idle clock: " .. tostring(math.floor((now - md.at) / 60000)) .. " min of downtime not counted")
    end
    md.at = now
    local cfg = MSH.Settings.get()
    local buyDays = buyRule(cfg)
    -- 沒有上一輪的天數（第一次檢查）也當成剛起算
    local was = md.days
    if not MSH.isFinite(md.since.free) or not MSH.isFinite(was.free) or cfg.idleDays <= 0 or cfg.idleDays < was.free then
        md.since.free = now
    end
    if not MSH.isFinite(md.since.buy) or not MSH.isFinite(was.buy) or buyDays <= 0 or buyDays < was.buy then
        md.since.buy = now
    end
    was.free, was.buy = cfg.idleDays, buyDays
    if cfg.idleDays <= 0 then
        md.down = {}
        return
    end
    if MSH.Health.blocked() then return end
    E.locked(function(sends) I.collect(md, now, cfg, sends) end)
end

-- Economy 通知保險有變（購買、退款、到期、移除）：在它的 commit 裡，先排隊；snap 是當下的快照，下個 tick 照順序套用
function I.noteInsurance(owner, t, snap)
    local obs = MSH.Economy and MSH.Economy.insuranceOf(snap) or nil
    I.insQueue[#I.insQueue + 1] = { owner = owner, tier = t, obs = (obs and obs.ok) and obs or nil }
end

function I.tick(now)
    local E = MSH.Economy
    if #I.insQueue == 0 or E == nil or E.status == "OFF" or not MSH.Registry.ready() then return end
    local md = I.state()
    local rest = {}
    for _, q in ipairs(I.insQueue) do
        local obs = q.obs
        if obs == nil and E.status == "READY" and E.insureReady then obs = E.insurance(q.owner, q.tier) end
        if obs ~= nil and obs.ok then
            insStore(md, q.owner, q.tier, insApply(insRecord(md, q.owner, q.tier), obs, now))
        elseif E.status == "READY" and E.insureReady then
            rest[#rest + 1] = q   -- 快照不能用、也讀不到：留到下一次
        end
    end
    I.insQueue = rest
end

-- validatePurchase（Economy.lua）：IdleInsure 開著、保險產品都註冊了、閒置收回有開（IdleDays 不是 0），而且這位玩家
-- 有那一級不是全部由租用名額保護的 active 屋（讀不到名額時放行）
function I.canInsure(username, t, kind)
    local cfg = MSH.Settings.get()
    local E = MSH.Economy
    if kind ~= "rental" or not cfg.idleInsure or not (E and E.insureReady) or cfg.idleDays <= 0 then
        return false, CODE.INSURE_CLOSED
    end
    local n = 0
    for _, rec in ipairs(MSH.Registry.byOwner(username)) do
        if rec.lifecycle == LC.ACTIVE and rec.deedTier == t then n = n + 1 end
    end
    local cov = n > 0 and coverage(username, t) or nil
    if n == 0 or (cov ~= nil and cov.rent >= n) then return false, CODE.NOT_INSURABLE end
    return true
end

-- detail 的 idle（Contract B）：active、有屋主才有；閒置收回整個關著回 nil。查詢不寫狀態
function I.view(rec, who, now)
    if rec.lifecycle ~= LC.ACTIVE or rec.owner == nil or rec.rects == nil then return nil end
    local cfg = MSH.Settings.get()
    if cfg.idleDays <= 0 then return nil end
    local E = MSH.Economy
    if E == nil or E.status == "OFF" then return { kind = "unknown" } end
    local md = I.state()
    local list = groupOf(rec.owner, rec.deedTier, MSH.Native.index())
    local live = liveInsurance(rec.owner, rec.deedTier)
    local c = I.classify(md, rec.owner, rec.deedTier, list, now, cfg, live, false)[rec.claimId]
    if c == nil then return nil end
    local out = { kind = c.kind }
    if c.anchor ~= nil then
        out.days = c.days
        out.remainingMs = math.max(0, math.floor(c.days * DAY_MS - I.idleMs(md, c.anchor, now)))
        if who == rec.owner and live ~= nil then out.insure = E.insureOffer(rec.deedTier, cfg, live) end
    end
    if c.insEnd ~= nil and c.insEnd > now then out.insuredMs = math.floor(c.insEnd - now) end
    return out
end

S.hook("minute", "idle", function(now) MSH.Idle.sweep(now) end)
S.hook("tick", "idle", function(now) MSH.Idle.tick(now) end)
