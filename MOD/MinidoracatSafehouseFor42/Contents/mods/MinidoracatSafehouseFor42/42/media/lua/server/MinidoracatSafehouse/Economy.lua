-- MinidoracatSafehouse/Economy.lua：Economy 選用整合——按地契等級的付費名額（計畫 §1.3、§7.1、§10.6 付費頁、§10.7）。
-- 偵測與註冊照 VehicleManager（MinidoracatVehicleManager_Economy.lua:29-104）：只在專用伺服器、開服偵測一次；
--   狀態 OFF｜ABSENT｜UNSUPPORTED｜FAILED｜READY。不 require Economy（它不在 mod.info require=）。
-- 一個來源 8 個產品 tier1…tier8（instant：名額只是 ModData 計數）；名額只讀 entitlement.usable，
--   寬限中的租用仍算 usable，但不能拿來建新的（Claims.checkQuota 扣掉）。
-- 停用照 VM RentLock（MinidoracatVehicleManager_RentLock.lua:79-147）改成「只在寬限結束時」：
--   每個租約到期（租約 id＋paidUntil）在第一次看到寬限結束時算一次，記在 Global ModData（重開不重算）；
--   該級停用數＝min(超額, 已停用間數＋這次新結束的名額)，停用該屋主該級最新的付費間
--   （lifecycle＝lapsed，原生移除與 remove delta 交給 Reconcile）；退款與管理員調低（沒有新結束的名額）只擋新增。
--   續租或名額空出 → 由舊到新恢復（Reconcile 重建原生）；
--   lapsedAt＋lapseKeepDays 期滿才釋出。ABSENT：全部恢復、不釋出；UNSUPPORTED／FAILED／查詢失敗：什麼都不改。
-- 觸發：onEntitlementChanged（排到下個 tick 持鎖處理）、每分鐘、開服。
-- Economy 出處（D:/github/MinidoracatEconomyFor42/…/42/media/lua/server/MinidoracatEconomy/，下稱 ECE＝ECEntitlements.lua、
--   ECP＝ECEntitlementPlans.lua、ECI＝ECIntegration.lua）：facade 能力 ECE:1857-1865；registerSource ECI:174-212；
--   registerProduct ECP:180-224；validatePurchase 呼叫 ECE:854-870（報價 :991、付款 :1032、自動續租 :1421）；
--   getEntitlement ECE:688-763（usable＝permanent＋live rental :707）；setPlan／getPlan ECP:253；onEntitlementChanged ECE:1375-1390。

if isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Settings"
require "MinidoracatSafehouse/Audit"
require "MinidoracatSafehouse/Registry"
require "MinidoracatSafehouse/Native"
require "MinidoracatSafehouse/Health"
require "MinidoracatSafehouse/Lifecycle"
require "MinidoracatSafehouse/Server"
require "MinidoracatSafehouse/Claims"

local MSH = MinidoracatSafehouse
-- 熱重載只換函式：S.hook 以名字登記（重載覆寫同一筆）、Economy 拿到的是轉呼叫用的固定函式（下方 validator／listener）
local E = MSH.Economy or { status = "OFF" }
MSH.Economy = E

local S = MSH.Srv
local CODE = MSH.CODE
local LC = MSH.LIFECYCLE
local SRC = MSH.SOURCE
local DAY_MS = 86400000

E.SOURCE = MSH.MOD_ID
E.REASON_CODES = { "entitlement_purchase", "entitlement_renewal", "entitlement_refund" }
E.PLAN_FIELDS = { "permanentEnabled", "permanentCurrency", "permanentPrice", "permanentLimit",
    "rentalEnabled", "rentalCurrency", "rentalPrice", "rentalLimit", "rentalDays",
    "graceHours", "reminderHours", "autoRenewAllowed" }
E.RENT_DEFAULT = { 100, 300, 700 }   -- 月租預設照各級預設面積比例；4–8 級同 3 級（§1.3 第 57 行）

E.currencies = E.currencies or {}
E.pending = E.pending or {}     -- onEntitlementChanged 排隊：owner → { [tier] = true }（下個 tick 持鎖處理）
E.watch = E.watch or {}         -- owner → tier → leaseId → { q, untilMs, key }：看過的寬限租約（RAM）
E.SPENT_TAG = MSH.TAG .. "_EconomySpent"
E.readErrorAt = E.readErrorAt or {}

function E.product(t)
    return "tier" .. tostring(t)
end

function E.tierOf(productId)
    if type(productId) ~= "string" then return nil end
    local n = tonumber(string.match(productId, "^tier(%d)$"))
    if n == nil or n < 1 or n > MSH.MAX_TIER then return nil end
    return n
end

-- 等級可用：TiersEnabled 之內；免費建立模式只有 1 級（§1.3 第 67 行）
function E.tierEnabled(cfg, t)
    return cfg.tiers[t].enabled and (cfg.createMode ~= MSH.Settings.CREATE.FREE or t == 1)
end

-- 世界第一次看到產品時的方案（之後改值全走 setPlan）：兩種販售都關，買斷＝月租 × 12（§1.3 第 57 行）
function E.defaults(t)
    local rent = E.RENT_DEFAULT[t] or E.RENT_DEFAULT[3]
    return {
        permanentEnabled = false, permanentCurrency = "survivor", permanentPrice = rent * 12, permanentLimit = 10,
        rentalEnabled = false, rentalCurrency = "survivor", rentalPrice = rent, rentalLimit = 10, rentalDays = 30,
        graceHours = 24, reminderHours = 24, autoRenewAllowed = true,
    }
end

function E.planOf(p)
    local out = {}
    for _, k in ipairs(E.PLAN_FIELDS) do out[k] = p[k] end
    return out
end

-- ===== 偵測與註冊（VM-Econ:29-104）=====

function E.api()
    local api = MinidoracatEconomy and MinidoracatEconomy.v1
    local caps = api and api.CAPABILITIES
    if api and api.API_MAJOR == 1 and (api.API_REVISION or 0) >= 2 and type(caps) == "table"
        and caps.entitlements == true and caps.subscriptions == true and caps.rentals == true and caps.setPlan == true
        and type(api.registerSource) == "function" then
        return api
    end
    return nil
end

local function failed(err)
    E.status, E.error, E.src = "FAILED", tostring(err), nil
    MSH.log("Economy paid slots unavailable: " .. E.error .. ". Free slots still apply.")
end

-- 熱重載後 Economy 手上的函式仍轉呼叫最新的實作；同一個函式重複加監聽是 idempotent（ECE:1382）
E.validator = E.validator or function(...) return MSH.Economy.validatePurchase(...) end
E.listener = E.listener or function(u, p, snap) MSH.Economy.onChanged(u, p, snap) end

function E.init()
    E.src, E.error, E.currencies = nil, nil, {}
    if MinidoracatEconomy == nil then E.status = "ABSENT" return end
    local api = E.api()
    if api == nil then
        E.status = "UNSUPPORTED"
        MSH.log("Economy found without entitlement API rev 2 (subscriptions, rentals, setPlan): paid slots disabled.")
        return
    end
    local currencies = {}
    for id in pairs(MinidoracatEconomy.CURRENCIES or {}) do
        if type(id) == "string" then currencies[#currencies + 1] = id end
    end
    MSH.sortSafe(currencies, function(a, b) return a < b end)
    E.currencies = currencies
    local ok, src, err = pcall(api.registerSource, { modId = E.SOURCE, nameKey = "IGUI_MSH_SourceName",
        displayName = { EN = "Safehouse" }, currencies = currencies, reasonCodes = E.REASON_CODES })
    if not ok then return failed(src) end
    if type(src) ~= "table" or type(src.registerProduct) ~= "function" or type(src.getEntitlement) ~= "function"
        or type(src.setPlan) ~= "function" or type(src.getPlan) ~= "function" then
        return failed(err or "no_entitlement_methods")
    end
    -- freezeWhenAbsent 要 rev 4＋freeze 能力；舊 Economy 不帶，租約照絕對時間走（§1.3 第 56 行）
    local canFreeze = (api.API_REVISION or 0) >= 4 and api.CAPABILITIES.freeze == true
    for t = 1, MSH.MAX_TIER do
        local okP, res = pcall(src.registerProduct, { id = E.product(t), nameKey = "IGUI_MSH_Product_tier" .. t,
            instant = true, freezeWhenAbsent = canFreeze or nil, defaults = E.defaults(t), validatePurchase = E.validator })
        if not okP then return failed(res) end
        if type(res) ~= "table" or res.ok ~= true then
            return failed(type(res) == "table" and tostring(res.error) .. ":" .. tostring(res.field) or "register_failed")
        end
    end
    if type(src.onEntitlementChanged) == "function" then
        local okC, e = pcall(src.onEntitlementChanged, E.listener)
        if not okC then return failed(e) end
    end
    E.src, E.status = src, "READY"
    MSH.log("Economy paid slots registered (" .. E.SOURCE .. "/tier1-" .. MSH.MAX_TIER .. ").")
end

-- pcall 包住並把非 table 的回覆正規化（VM-PS:241）
function E.call(name, ...)
    if E.src == nil or type(E.src[name]) ~= "function" then return { ok = false, error = "unavailable" } end
    local ok, res = pcall(E.src[name], ...)
    if not ok or type(res) ~= "table" then return { ok = false, error = ok and "invalid_response" or "exception" } end
    return res
end

-- ===== 權益讀取 =====

local function count(v) return MSH.isInt(v) and v >= 0 end

-- 一個等級的 getEntitlement 回覆；只信 usable 是非負整數（VM-Econ:110-127）。失敗回 nil（每產品每分鐘最多一行 log）
function E.read(owner, t)
    if E.status ~= "READY" or type(owner) ~= "string" then return nil end
    local res = E.call("getEntitlement", owner, E.product(t))
    if res.ok == true and type(res.entitlement) == "table" and count(res.entitlement.usable) then return res end
    local now = getTimestampMs()
    if E.readErrorAt[t] == nil or now - E.readErrorAt[t] >= 60000 then
        E.readErrorAt[t] = now
        MSH.log("Economy getEntitlement failed product=" .. E.product(t) .. " owner=" .. MSH.logSafe(owner)
            .. ": " .. tostring(res.error or "invalid_usable"))
    end
    return nil
end

-- 一次到期的識別：租約 id＋paidUntil（續租後再到期是新的一次）。paidUntil 用整數十進位字串，不走 tostring（13 位數會變科學記號）
local function leaseKey(id, paidUntil)
    if MSH.isFinite(paidUntil) and paidUntil >= 0 then return id .. "@" .. MSH.Registry.sidText(math.floor(paidUntil)) end
    return id
end

-- 租約分項（VM-RL:17-35）；任何一筆不合（不是 table、quantity 不是非負整數）回 nil，呼叫端什麼都不改。
-- hold＝有待確認、系統暫停或凍結的租約：結果未定，不據以停用
local function leases(ent)
    if type(ent.rentals) ~= "table" then return nil end
    local l = { grace = 0, expired = 0, hold = false, graceById = {}, stateById = {}, expiredList = {} }
    for i, x in ipairs(ent.rentals) do
        if type(x) ~= "table" or not count(x.quantity) then return nil end
        local id = x.id ~= nil and tostring(x.id) or ("#" .. i)
        l.stateById[id] = x.state
        if x.state == "grace" then
            l.grace = l.grace + x.quantity
            l.graceById[id] = { q = x.quantity, untilMs = MSH.isFinite(x.graceUntil) and x.graceUntil or nil,
                key = leaseKey(id, x.paidUntil) }
        elseif x.state == "expired" then
            l.expired = l.expired + x.quantity
            l.expiredList[#l.expiredList + 1] = { q = x.quantity, key = leaseKey(id, x.paidUntil) }
        elseif x.state == "pending" or x.state == "paused_system" or x.state == "frozen" then
            l.hold = true
        end
    end
    return l
end

-- 這位屋主這一級能拿來建新屋的名額與開著的價格。不是 READY、查詢失敗或租約欄位不合＝0、沒有價格
function E.offer(owner, t, cfg)
    local out = { usable = 0, grace = 0 }
    local res = E.read(owner, t)
    local l = res and leases(res.entitlement)
    if l == nil then return out end
    out.usable, out.grace = res.entitlement.usable, l.grace
    local plan, tc = res.plan, cfg.tiers[t]
    if type(plan) == "table" and E.tierEnabled(cfg, t) then
        if tc.buy and plan.permanentEnabled == true then
            out.buy = { amount = plan.permanentPrice, currency = plan.permanentCurrency }
        end
        if tc.rent and plan.rentalEnabled == true then
            out.rent = { amount = plan.rentalPrice, currency = plan.rentalCurrency, days = plan.rentalDays }
        end
    end
    return out
end

-- ===== validatePurchase（§1.3 第 67 行）=====
-- 等級啟用且該種開關開著 → 放行（不因已用完拒絕加購）。否則只放行付款後總數不超過該級付費間數（含 lapsed）：
-- 既有的屋能續租、能恢復，不能多買。不看 health：設定出錯時不能連自動續租也擋掉。
function E.validatePurchase(username, productId, kind, quantity, projected)
    local t = E.tierOf(productId)
    if t == nil or type(username) ~= "string" then return false, "TIER_DISABLED" end
    local cfg = MSH.Settings.get()
    local tc = cfg.tiers[t]
    local enabled = E.tierEnabled(cfg, t)
    local open = (kind == "permanent" and tc.buy) or (kind == "rental" and tc.rent)
    if enabled and open then return true end
    local p = type(projected) == "table" and projected or {}
    local total = (count(p.permanent) and p.permanent or 0) + (count(p.rental) and p.rental or 0)
    local by = MSH.Claims.paidClaims(username, cfg)
    if total <= #(by[t] or {}) then return true end
    return false, enabled and CODE.KIND_CLOSED or CODE.TIER_DISABLED
end

-- ===== 停用、恢復、釋出 =====

local function notify(rec, sends)
    local id, owner = rec.claimId, rec.owner
    sends[#sends + 1] = function()
        local p = MSH.Native.onlinePlayer(owner)
        if p then sendServerCommand(p, MSH.MODULE, "changed", { claimId = id }) end   -- LuaManager.java:8962-8966
    end
end

local function lapse(rec, now, sends)
    rec.lifecycle, rec.lapsedAt = LC.LAPSED, now
    MSH.Registry.touch(rec)
    MSH.Audit.write("LAPSED", { actor = rec.owner, claimId = rec.claimId, code = "RENT_EXPIRED" })
    notify(rec, sends)
end

local function restore(rec, why, sends)
    rec.lifecycle, rec.lapsedAt = LC.ACTIVE, nil
    MSH.Registry.touch(rec)
    MSH.Audit.write("RESTORED", { actor = rec.owner, claimId = rec.claimId, code = why })
    notify(rec, sends)
end

local function isEmpty(t)
    for _ in pairs(t) do return false end
    return true
end

-- 已算過的到期：Global ModData（GlobalModData.java:112-205），owner → tier → { [leaseKey] = 名額 }
function E.spentOf(owner, t)
    local md = ModData.getOrCreate(E.SPENT_TAG)
    md.owners = md.owners or {}
    local o = md.owners[owner]
    if o == nil then
        o = {}
        md.owners[owner] = o
    end
    local s = o[t]
    if s == nil then
        s = {}
        o[t] = s
    end
    return s, o, md
end

-- 這一輪新結束寬限、還沒算過的名額：現在列為 expired 的，加上看過寬限、寬限截止已過、現在已經不在的
-- （Economy 到期後可能同一次排程就移除，VM-RL:142-143 註解）。寬限截止前消失（退款）不算。
-- 同一次到期只算一次（記在 Global ModData，重開機與 Economy 連續幾輪列著都不重算）；不再列著的租約記錄就刪（每人每級 ≤ 10 張）。
-- hold 時結果未定：不算、不記，看過的寬限租約留到下一輪。
-- ponytail: 看過的寬限租約只記在 RAM；停機期間寬限結束又被 Economy 移除的租約，重開後只擋新增、不停用
local function newlyEnded(owner, t, l, now)
    local w = E.watch[owner] or {}
    E.watch[owner] = w
    local old = w[t] or {}
    if l.hold then
        for id, g in pairs(l.graceById) do old[id] = g end
        w[t] = not isEmpty(old) and old or nil
        return 0
    end
    local spent, o, md = E.spentOf(owner, t)
    local n = 0
    local function take(key, q)
        local used = spent[key] or 0
        if q > used then
            n = n + q - used
            spent[key] = q
        end
    end
    for _, x in ipairs(l.expiredList) do take(x.key, x.q) end
    for id, g in pairs(old) do
        if l.stateById[id] == nil and g.untilMs ~= nil and now >= g.untilMs then take(g.key, g.q) end
    end
    local drop = {}
    for key in pairs(spent) do
        if l.stateById[string.match(key, "^(.-)@") or key] == nil then drop[#drop + 1] = key end
    end
    for _, key in ipairs(drop) do spent[key] = nil end
    if isEmpty(spent) then o[t] = nil end
    if isEmpty(o) then md.owners[owner] = nil end
    w[t] = not isEmpty(l.graceById) and l.graceById or nil
    return n
end

-- 一位屋主一個等級（呼叫端持鎖）。list＝該級付費 claim 由舊到新（含 lapsed；可能是空的：只為了記下結束的名額）。
-- 停用數＝min(超額, 已停用＋新結束)（VM-RL:95-98 的 want，改成相加）；多停用的由舊到新恢復；剩下的停用期滿釋出
function E.evaluateTier(owner, t, list, now, cfg, sends)
    local res = E.read(owner, t)
    local l = res and leases(res.entitlement)
    if l == nil then return end
    local ended = newlyEnded(owner, t, l, now)
    local active, lapsed = {}, {}
    for _, rec in ipairs(list) do
        if rec.lifecycle == LC.LAPSED then lapsed[#lapsed + 1] = rec
        elseif rec.lifecycle == LC.ACTIVE then active[#active + 1] = rec end
    end
    local deficit = #list - res.entitlement.usable
    local want = math.max(0, math.min(deficit, #lapsed + ended))
    local i = #active
    local n = #lapsed
    while n < want and i >= 1 do
        lapse(active[i], now, sends)
        i, n = i - 1, n + 1
    end
    local back = #lapsed - want
    for k = 1, #lapsed do
        local rec = lapsed[k]
        if k <= back then
            restore(rec, "RENEWED", sends)
        elseif MSH.isFinite(rec.lapsedAt) and rec.lapsedAt + cfg.lapseKeepDays * DAY_MS <= now then
            MSH.Lifecycle.release(rec, "LAPSE_EXPIRED", "lapse-" .. rec.claimId, now,
                function(fn) sends[#sends + 1] = fn end)
        end
    end
end

-- 一位屋主；legacy 或已分到免費位的 lapsed 直接恢復（不需要付費名額）。
-- 評估有付費屋的等級、觀察中的等級，以及 extra（通知點名的等級：沒有付費屋也要把結束的名額記下，之後不再算）
function E.evaluate(owner, now, sends, extra)
    local cfg = MSH.Settings.get()
    local by, s = MSH.Claims.paidClaims(owner, cfg)
    for _, rec in ipairs(MSH.Registry.byOwner(owner)) do
        if rec.lifecycle == LC.LAPSED and (rec.source == SRC.LEGACY or s.ids[rec.claimId]) then
            restore(rec, "FREE_SLOT", sends)
        end
    end
    local w = E.watch[owner]
    for t = 1, MSH.MAX_TIER do
        if by[t] or (extra and extra[t]) or (w and w[t]) then E.evaluateTier(owner, t, by[t] or {}, now, cfg, sends) end
    end
    w = E.watch[owner]
    if w and isEmpty(w) then E.watch[owner] = nil end
end

function E.restoreAll(sends)
    for _, rec in ipairs(MSH.Registry.list()) do
        if rec.lifecycle == LC.LAPSED then restore(rec, "ECONOMY_ABSENT", sends) end
    end
end

-- 持全域鎖跑 fn(sends)，放鎖後才送網路。BUSY 回 false（呼叫端下次再來）
function E.locked(fn)
    if not S.ready or not MSH.Registry.ready() then return false end
    local sends = {}
    local res = S.withLock(function()
        fn(sends)
        return S.ok()
    end)
    for _, f in ipairs(sends) do
        local ok, err = pcall(f)
        if not ok then MSH.log("economy send failed: " .. tostring(err)) end
    end
    return res.code ~= CODE.BUSY
end

-- 屋主集合：all＝全部有非 legacy claim 的屋主（開服）；否則只看寬限觀察中與有 lapsed 的
local function owners(all)
    local set, list = {}, {}
    for owner in pairs(E.watch) do set[owner] = true end
    for _, rec in ipairs(MSH.Registry.list()) do
        if rec.owner ~= nil and (rec.lifecycle == LC.LAPSED or (all and rec.source ~= SRC.LEGACY)) then
            set[rec.owner] = true
        end
    end
    for owner in pairs(set) do list[#list + 1] = owner end
    return list
end

function E.sweep(now, all)
    if E.status == "ABSENT" then
        E.locked(function(sends) E.restoreAll(sends) end)
        return
    end
    if E.status ~= "READY" then return end
    local list = owners(all)
    E.locked(function(sends)
        for _, owner in ipairs(list) do E.evaluate(owner, now, sends) end
    end)
end

-- Economy 在權益提交完成後通知（進入寬限、到期、租約移除也會）；在它的 commit 裡，不在這裡改紀錄
function E.onChanged(username, productId)
    local t = E.tierOf(productId)
    if type(username) ~= "string" or t == nil then return end
    local p = type(E.pending[username]) == "table" and E.pending[username] or {}
    p[t] = true
    E.pending[username] = p
    E.dirty = true
end

function E.tick(now)
    if not E.dirty or E.status ~= "READY" then return end
    local list = {}
    for owner, tiers in pairs(E.pending) do list[#list + 1] = { owner = owner, tiers = tiers } end
    local done = E.locked(function(sends)
        for _, x in ipairs(list) do E.evaluate(x.owner, now, sends, x.tiers) end
    end)
    if done then
        E.pending, E.dirty = {}, false
    end
end

-- Tier<N>Buy／Rent 開著而方案那種販售關著 → setPlan 打開（開服與每分鐘；關掉開關不改回，§1.3 第 58 行）
function E.syncSwitches()
    if E.status ~= "READY" then return end
    local cfg = MSH.Settings.get()
    for t = 1, MSH.MAX_TIER do
        local tc = cfg.tiers[t]
        if tc.buy or tc.rent then
            local res = E.call("getPlan", E.product(t))
            local plan = res.ok == true and type(res.plan) == "table" and res.plan or nil
            if plan and ((tc.buy and plan.permanentEnabled ~= true) or (tc.rent and plan.rentalEnabled ~= true)) then
                local values = E.planOf(plan)
                if tc.buy then values.permanentEnabled = true end
                if tc.rent then values.rentalEnabled = true end
                local r = E.call("setPlan", E.product(t), values,
                    { actor = "source", origin = "source", reason = "Tier" .. t .. " Buy/Rent switch" })
                if r.ok == true then
                    MSH.Audit.write("PLAN_SWITCH", { actor = "source", code = E.product(t), detail = tostring(r.revision) })
                else
                    MSH.Audit.throttled("PLAN_SWITCH|" .. t, 3600000, "PLAN_SWITCH_FAILED",
                        { code = E.product(t), detail = tostring(r.error) .. ":" .. tostring(r.field) }, getTimestampMs())
                end
            end
        end
    end
end

-- ===== 給其他模組 =====

-- detail 用：{ paid, tier, lapsedAt?, releaseAt? }；沒有屋主（quarantined 孤兒）回 nil
function E.claimInfo(rec)
    if type(rec) ~= "table" or rec.owner == nil then return nil end
    local cfg = MSH.Settings.get()
    local paid = rec.source ~= SRC.LEGACY and not MSH.Claims.slots(rec.owner, cfg).ids[rec.claimId]
    local out = { paid = paid, tier = rec.deedTier }
    if rec.lifecycle == LC.LAPSED and MSH.isFinite(rec.lapsedAt) then
        out.lapsedAt = rec.lapsedAt
        out.releaseAt = rec.lapsedAt + cfg.lapseKeepDays * DAY_MS
    end
    return out
end

-- ===== 指令 =====

local PLAN_TYPES = {
    permanentEnabled = "boolean", permanentCurrency = "string", permanentPrice = "number", permanentLimit = "number",
    rentalEnabled = "boolean", rentalCurrency = "string", rentalPrice = "number", rentalLimit = "number",
    rentalDays = "number", graceHours = "number", reminderHours = "number", autoRenewAllowed = "boolean",
}

S.TYPES.tier = function(v) return MSH.isInt(v) and v >= 1 and v <= MSH.MAX_TIER end
-- 方案：只收 12 個已知欄位、型別對、數字有限、幣別 ^[%w_]+$ ≤ 32；範圍與缺欄由 Economy 判（invalid_plan＋field）
S.TYPES.plan = function(v)
    if type(v) ~= "table" then return false end
    for k, x in pairs(v) do
        local want = PLAN_TYPES[k]
        if want == nil or type(x) ~= want then return false end
        if want == "number" and not MSH.isFinite(x) then return false end
        if want == "string" and (#x > 32 or string.find(x, "^[%w_]+$") == nil) then return false end
    end
    return true
end
S.TYPES.reason = function(v) return type(v) == "string" and #v >= 1 and #v <= 256 and not MSH.hasControl(v) end

-- 建立面板閒置時先顯示的伺服器閘門（第一個符合的）
local function blockedCode(player)
    if MSH.Registry.readOnly or MSH.Health.blocked() then return CODE.HEALTH_BLOCKED end
    if SafeHouse.hasNotSurvivedEnoughToClaim(player) then return CODE.NOT_SURVIVED end   -- SafeHouse.java:852-859
    return nil
end

function E.slots(ctx)
    local cfg = MSH.Settings.get()
    local by, s = MSH.Claims.paidClaims(ctx.who, cfg)
    local titles = {}
    for _, rec in ipairs(MSH.Registry.byOwner(ctx.who)) do
        if s.ids[rec.claimId] then titles[#titles + 1] = rec.title end
    end
    local tiers = {}
    for t = 1, MSH.MAX_TIER do
        if E.tierEnabled(cfg, t) then
            local tc = cfg.tiers[t]
            local o = E.offer(ctx.who, t, cfg)
            tiers[#tiers + 1] = { tier = t, enabled = true, free = tc.free, buy = tc.buy, rent = tc.rent,
                perPlayer = tc.perPlayer, usable = o.usable, paid = #(by[t] or {}), grace = o.grace,
                buyPrice = o.buy, rentPrice = o.rent }
        end
    end
    return S.ok({ economy = E.status, blocked = blockedCode(ctx.player),
        free = { n = s.free, used = s.used, titles = titles }, tiers = tiers })
end

function E.adminPlans()
    local out = { economy = E.status, currencies = E.currencies, tiers = {} }
    if E.status ~= "READY" then return S.ok(out) end
    for t = 1, MSH.MAX_TIER do
        local res = E.call("getPlan", E.product(t))
        if res.ok ~= true or type(res.plan) ~= "table" then return S.fail(CODE.ECONOMY_UNAVAILABLE) end
        local lc = res.lastChange
        out.tiers[#out.tiers + 1] = { tier = t, plan = E.planOf(res.plan), revision = res.plan.revision,
            provisional = res.plan.provisional == true,
            lastChange = type(lc) == "table" and { actor = lc.actor, origin = lc.origin, at = lc.at, reason = lc.reason,
                revision = lc.revision } or nil }
    end
    return S.ok(out)
end

-- 錯誤對應照 VM-PS:345-351
function E.adminSetPlan(ctx)
    local a = ctx.args
    if E.status ~= "READY" then return S.fail(CODE.ECONOMY_UNAVAILABLE) end
    local res = E.call("setPlan", E.product(a.tier), E.planOf(a.values),
        { actor = ctx.who, origin = "admin", reason = a.reason, expectedRevision = a.expectedRevision })
    if res.ok ~= true then
        if res.error == "stale_revision" then return S.fail(CODE.STALE_REVISION) end
        if res.error == "invalid_plan" or res.error == "unknown_fields" then
            return S.fail(CODE.INVALID_PLAN, { field = res.field })
        end
        return S.fail(CODE.ECONOMY_UNAVAILABLE)
    end
    local changed = type(res.changed) == "table" and res.changed or {}
    MSH.Audit.write("ADMIN_PLAN", { actor = ctx.who, code = E.product(a.tier),
        detail = table.concat(changed, ",") .. " " .. tostring(a.reason or "-") })
    return S.ok({ tier = a.tier, revision = res.revision, changed = changed })
end

S.define("slots", { kind = "query", cooldownMs = 500, fields = {}, run = function(ctx) return MSH.Economy.slots(ctx) end })
S.define("adminPlans", { kind = "query", admin = true, fields = {}, run = function() return MSH.Economy.adminPlans() end })
S.define("adminSetPlan", { kind = "mutation", admin = true, whenBlocked = true,
    fields = { tier = "tier", values = "plan", expectedRevision = "revision", reason = "reason?" },
    run = function(ctx) return MSH.Economy.adminSetPlan(ctx) end })

S.hook("serverStarted", "economy", function()
    local E2 = MSH.Economy
    E2.init()
    E2.syncSwitches()
    E2.sweep(getTimestampMs(), true)
end)
S.hook("tick", "economy", function(now) MSH.Economy.tick(now) end)
S.hook("minute", "economy", function(now)
    MSH.Economy.syncSwitches()
    MSH.Economy.sweep(now, false)
end)
