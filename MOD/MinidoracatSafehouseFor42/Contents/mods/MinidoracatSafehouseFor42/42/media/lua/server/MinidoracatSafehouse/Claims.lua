-- MinidoracatSafehouse/Claims.lua：玩家的安全屋指令（建立、預檢、放棄、重新框選、改名、清單、詳細）。
-- 驗證照計畫 §7.3（持全域鎖、第一個失敗就停；預檢則收集全部）；交易照 §7.4（原生→地契→紀錄＝local commit，
-- 之後才 defer 物品同步與原生廣播；commit 前丟錯就反序回滾）；名額 §1.3／§7.1；重新框選 §7.6；
-- 清單與詳細 §6.4、狀態優先序 §10.3。付費名額由 Economy.lua 提供（沒裝或不可用＝0）。
-- 驗證管線拆成 C.check* 函式，方便 harness 單獨測（scripts/harness/t_claims.lua）。

if isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Settings"
require "MinidoracatSafehouse/Audit"
require "MinidoracatSafehouse/Registry"
require "MinidoracatSafehouse/Native"
require "MinidoracatSafehouse/Health"
require "MinidoracatSafehouse/Identity"
require "MinidoracatSafehouse/Lifecycle"
require "MinidoracatSafehouse/Server"
require "MinidoracatSafehouse/Journal"

local MSH = MinidoracatSafehouse
local C = MSH.Claims or {}
MSH.Claims = C

local CODE = MSH.CODE
local LC = MSH.LIFECYCLE
local SRC = MSH.SOURCE
local LIMIT = MSH.LIMIT
local Rect = MSH.Rect
local R = MSH.Registry
local N = MSH.Native
local S = MSH.Srv

-- ===== 驗證管線 =====
-- v（一次驗證的上下文）：player, who, now, cfg, rects（範圍的各塊）, deedType, title, idx（原生索引）,
-- roster（可站在範圍內的人）；重新框選另有 old（被取代的紀錄）與 skipId。checkDeed 填 source、tier、item；
-- checkTitle 填 cleanTitle。每個 check 回 nil（通過）或 code, detail。

function C.newCheck(ctx, cfg, rects, deedType, title)
    return { player = ctx.player, who = ctx.who, now = ctx.now, cfg = cfg, rects = rects, deedType = deedType,
        title = title, idx = N.index(), roster = { [ctx.who] = true } }
end

-- 重新框選：等級、來源、標題沿用舊紀錄；舊屋的名單可以站在新範圍內；重疊與撞號略過舊屋自己
function C.useOld(v, old)
    v.old, v.skipId = old, old.claimId
    v.source, v.tier, v.cleanTitle = old.source, old.deedTier, old.title
    for _, u in ipairs(N.desiredPlayers(old)) do v.roster[u] = true end
end

-- 活著、存活天數（原生 SafeHouse.hasNotSurvivedEnoughToClaim，SafeHouse.java:852-859：讀 SafehouseDaySurvivedToClaim、admin 免除）
function C.checkIdentity(v)
    if v.player:isDead() then return CODE.DEAD end                         -- IsoGameCharacter.java:4913
    if SafeHouse.hasNotSurvivedEnoughToClaim(v.player) then return CODE.NOT_SURVIVED end
    return nil
end

-- 人在現場：(floor(x), floor(y)) 在提案範圍的任一塊內，任何 Z（§7.2）；IsoMovingObject.java:491、508
function C.checkOnSite(v)
    if not Rect.listContains(v.rects, v.player:getX(), v.player:getY()) then return CODE.NOT_ON_SITE end
    return nil
end

-- 地契：等級只由 full type 決定；背包含巢狀容器都找（ItemContainer.java:1551，compareType 帶點號時比 full type :1197-1201）
function C.checkDeed(v)
    if v.old then return nil end
    local cfg = v.cfg
    if cfg.createMode == MSH.Settings.CREATE.FREE then
        v.source, v.tier = SRC.FREE, 1      -- 免費模式以 tier1 計名額（§1.3）
        if v.deedType ~= nil then return CODE.BAD_DEED end
        return nil
    end
    if v.deedType == nil then return CODE.NO_DEED end
    v.source, v.tier = SRC.DEED, MSH.tierOfDeed(v.deedType)
    v.item = v.player:getInventory():getFirstTypeRecurse(v.deedType)   -- IsoGameCharacter.java:3322
    if v.item == nil then return CODE.NO_DEED end
    if v.tier > cfg.tiersEnabled then return CODE.TIER_DISABLED, { tier = v.tier } end
    return nil
end

-- 形狀：塊數（沙盒 MaxPieces）、不重疊、連成一片、沒有洞（MSH.Rect.shapeError；客戶端框選工具用同一套規則）。
-- 不合規則時記 v.badShape，預檢略過逐格掃地圖的檢查（C.STEPS needsShape）
function C.checkShape(v)
    local why = Rect.shapeError(v.rects, v.cfg.maxPieces)
    if why then
        v.badShape = true
        return CODE.BAD_SHAPE, { reason = why }
    end
    return nil
end

-- 大小看整間：外框邊長與各塊面積總和（使用者 2026-10-11 裁定：多塊不會比方形拿到更多地）
function C.checkSize(v)
    local maxSide, maxArea = MSH.Settings.sizeLimit(v.cfg, v.source, v.tier)
    local b = Rect.bounds(v.rects)
    if b.w > maxSide or b.h > maxSide or Rect.listArea(v.rects) > maxArea then
        return CODE.TOO_BIG, { maxSide = maxSide, maxArea = maxArea }
    end
    return nil
end

-- 原生封包以 onlineId first-match 找房（§2.1）：每塊都不能和任何既有原生（含 foreign）同號。SafeHouse.java:577-579
-- 同一間的塊互不重疊，左上角不同，彼此不會撞號
function C.checkOnlineId(v)
    for _, p in ipairs(v.rects) do
        local oid = SafeHouse.getOnlineID(p.x, p.y)
        for _, e in ipairs(v.idx.all) do
            if e.onlineId == oid and (v.skipId == nil or e.claimId ~= v.skipId) then return CODE.ONLINE_ID_COLLISION end
        end
    end
    return nil
end

-- 免費名額每一級各自計（§1.3；使用者 2026-10-15 選 B）：這一級 Tier<N>FreeSlots 間，玩家頁的個人上限只改 1 級。
-- legacy 先佔（grandfathered：legacy 都記 1 級，超出也不必付費），其餘照 createdAt 由舊到新、只佔自己那一級的。
-- 回傳 { tiers = { [t] = { n, used } }, ids = { [claimId] = true } }
function C.slots(owner, cfg)
    local out = { tiers = {}, ids = {} }
    for t = 1, MSH.MAX_TIER do out.tiers[t] = { n = cfg.tiers[t].freeSlots, used = 0 } end
    local o = R.override(owner)
    if o ~= nil then out.tiers[1].n = o end
    local mine = R.byOwner(owner)
    for pass = 1, 2 do
        for _, rec in ipairs(mine) do
            local f = out.tiers[rec.deedTier]
            if f ~= nil and (pass == 1) == (rec.source == SRC.LEGACY) and f.used < f.n then
                f.used = f.used + 1
                out.ids[rec.claimId] = true
            end
        end
    end
    return out
end

-- 付費 claim：不是 legacy、沒分到免費位的，照等級分、各自由舊到新（含 lapsed）。回傳 byTier, slots
function C.paidClaims(owner, cfg)
    local s = C.slots(owner, cfg)
    local by = {}
    for _, rec in ipairs(R.byOwner(owner)) do
        if rec.source ~= SRC.LEGACY and not s.ids[rec.claimId] then
            local list = by[rec.deedTier] or {}
            by[rec.deedTier] = list
            list[#list + 1] = rec
        end
    end
    return by, s
end

-- 全服上限 → 免費名額 → 付費名額。付錢也解決不了（可買、可租都到上限）時回 TIER_FULL，免得客戶端顯示〔前往付費〕。
-- 這一級每人最多幾間＝免費＋可買＋可租（使用者 2026-10-15）：沒有另外的間數上限，付費名額本身就封住了；
-- 調低前已經買或租的名額照常可用。tombstone 軟上限重畫也要看：每次重畫都多一筆 tombstone（審查 HIGH：重畫洗滿 registry）
function C.checkQuota(v)
    if R.tombstoneCount() >= LIMIT.TOMBSTONE_SOFT then return CODE.SERVER_FULL end
    if v.old then return nil end
    if R.liveCount() >= LIMIT.MAX_CLAIMS then return CODE.SERVER_FULL end
    local by, s = C.paidClaims(v.who, v.cfg)
    local f = s.tiers[v.tier]
    if f ~= nil and f.used < f.n then return nil end
    -- 付費名額：該級付費間數 < usable − 寬限中（寬限中的租用不能拿來建新的，§1.3 第 59 行）；
    -- QUOTA_FULL 只帶還能買的那種價格（Economy 不可用時兩種都沒有）
    local E = MSH.Economy
    local o = E and E.offer(v.who, v.tier, v.cfg) or { usable = 0, grace = 0 }
    if #(by[v.tier] or {}) < o.usable - o.grace then return nil end
    if o.full then
        -- 上限＝名額視窗的「最多」：調低前已經買、租超過的照實算
        local t = v.cfg.tiers[v.tier]
        return CODE.TIER_FULL, { tier = v.tier,
            limit = (f and f.n or 0) + math.max(t.buySlots, o.bought) + math.max(t.rentSlots, o.rented) }
    end
    return CODE.QUOTA_FULL, { tier = v.tier, buy = o.buy, rent = o.rent }
end

function C.checkTitle(v)
    if v.old then return nil end
    v.cleanTitle = MSH.cleanTitle(v.title or v.who)
    if v.cleanTitle == nil then return CODE.BAD_TITLE end
    return nil
end

-- 重疊：每塊對全部原生（含 foreign）＋全部佔位紀錄的每一塊（含 lapsed、quarantined），半開 AABB；
-- 同一屋主只禁止重疊、不套間距；屋主和我同一個陣營的套 factionClaimGap（使用者 2026-10-15，預設 0＝可以緊鄰），
-- 看檢查當下的陣營；其他人與 foreign 套 claimGap。不呼叫原生 SafeHouse.intersects（§7.3）。
-- detail 是對方那一塊的範圍（客戶端標紅）加上這次要隔的格數 gap（TOO_CLOSE 的原因句照它寫）
function C.checkOverlap(v)
    local cfg = v.cfg
    -- 兩個間距一樣時不必分誰同陣營；身分沒過（預檢照樣跑完每一項）時沒有陣營。
    -- Faction.getPlayerFaction(String)：Faction.java:123-138（一人只在一個陣營）
    local faction = v.who ~= nil and cfg.factionClaimGap ~= cfg.claimGap and Faction.getPlayerFaction(v.who) or nil
    local gaps = {}   -- owner → 要隔的格數（每位屋主只查一次陣營）
    local function gapOf(owner)
        if owner == nil then return cfg.claimGap end
        local g = gaps[owner]
        if g == nil then
            if owner == v.who then
                g = 0
            elseif faction ~= nil and (faction:isOwner(owner) or faction:isMember(owner)) then   -- Faction.java:150、154
                g = cfg.factionClaimGap
            else
                g = cfg.claimGap
            end
            gaps[owner] = g
        end
        return g
    end
    local close, closeGap = nil, nil
    local function hit(rect, owner)
        for _, p in ipairs(v.rects) do
            if Rect.overlaps(p, rect, 0) then return true end
        end
        if close == nil then
            local gap = gapOf(owner)
            if gap > 0 then
                for _, p in ipairs(v.rects) do
                    if Rect.overlaps(p, rect, gap) then
                        close, closeGap = rect, gap
                        break
                    end
                end
            end
        end
        return false
    end
    for _, e in ipairs(v.idx.all) do
        if v.skipId == nil or e.claimId ~= v.skipId then
            local rec = e.claimId and R.get(e.claimId) or nil
            if hit(e.rect, rec and rec.owner or nil) then return CODE.OVERLAP, Rect.copy(e.rect) end
        end
    end
    for _, rec in ipairs(R.list()) do
        if R.isLive(rec) and rec.claimId ~= v.skipId then
            for _, r in ipairs(rec.rects) do
                if hit(r, rec.owner) then return CODE.OVERLAP, Rect.copy(r) end
            end
        end
    end
    if close then
        local d = Rect.copy(close)
        d.gap = closeGap
        return CODE.TOO_CLOSE, d
    end
    return nil
end

-- 在線的其他人站在範圍的任一塊內（任何 Z、含車內）就拒絕；回覆不帶名字（§7.3）。LuaManager.java:4457
function C.checkOccupancy(v)
    local list = getOnlinePlayers()
    for i = 0, list:size() - 1 do
        local p = list:get(i)
        if p ~= v.player and not v.roster[p:getUsername()] and Rect.listContains(v.rects, p:getX(), p:getY()) then
            return CODE.OCCUPIED
        end
    end
    return nil
end

-- 道路與資源點由 Exclusions 判定（§8）；模組不在就不擋
function C.checkRoads(v)
    if MSH.Exclusions == nil then return nil end
    return MSH.Exclusions.roads(v.rects, v.cfg)
end

function C.checkResources(v)
    if MSH.Exclusions == nil then return nil end
    return MSH.Exclusions.resources(v.rects, v.cfg)
end

-- 已重畫次數；手改壞的值當 0
function C.redraws(rec)
    return MSH.isInt(rec.redraws) and rec.redraws or 0
end

-- 新紀錄（交易與容量估算共用）；重畫的新紀錄帶 redraws＝舊的＋1（每間上限沙盒 RedrawLimit）
function C.draft(v, claimId)
    local old = v.old
    local f = { claimId = claimId, rects = v.rects, title = v.cleanTitle, deedTier = v.tier, owner = v.who,
        source = v.source, createdAt = v.now }
    if old then
        f.createdAt = old.createdAt   -- 緩衝期不因重畫延長（§7.6）
        f.grants = {}
        for _, g in ipairs(old.grants or {}) do f.grants[#f.grants + 1] = { user = g.user, bits = g.bits } end
        if old.factionShare then
            f.factionShare = {}
            for k, x in pairs(old.factionShare) do f.factionShare[k] = x end
        end
    end
    local rec = R.newRecord(f)
    if old then rec.redraws = C.redraws(old) + 1 end
    return rec
end

-- registry 序列化大小與全部原生名單名字數（§4.2；每塊的原生各放一份名單，Native.nameCount）
function C.checkCapacity(v)
    local rec = C.draft(v, R.md.nextClaimId)
    if R.estimateBytes(rec) > LIMIT.REGISTRY_BYTES then return CODE.REGISTRY_FULL end
    local names = N.nameCount(rec)
    for _, r in ipairs(R.list()) do
        if R.isLive(r) and r.claimId ~= v.skipId then names = names + N.nameCount(r) end
    end
    if names > LIMIT.NATIVE_NAMES then return CODE.ROSTER_FULL end
    return nil
end

-- 建立的檢查順序；name 是預檢回報的分組（同組只報第一個失敗）；needsTier：等級未知時預檢略過；
-- needsShape：形狀不合規則時略過（逐格掃地圖的道路與資源點：重疊的塊會讓同一片地掃好幾次，
-- 不合規則的預檢不能拿來放大伺服器的工作量，2026-10-11 審查）
C.STEPS = {
    { name = "identity", fn = C.checkIdentity },
    { name = "onsite", fn = C.checkOnSite },
    { name = "deed", fn = C.checkDeed },
    { name = "size", fn = C.checkShape },
    { name = "size", fn = C.checkSize, needsTier = true },
    { name = "overlap", fn = C.checkOnlineId },
    { name = "quota", fn = C.checkQuota, needsTier = true },
    { name = "title", fn = C.checkTitle },
    { name = "overlap", fn = C.checkOverlap },
    { name = "occupancy", fn = C.checkOccupancy },
    { name = "roads", fn = C.checkRoads, needsShape = true },
    { name = "resources", fn = C.checkResources, needsShape = true },
    { name = "quota", fn = C.checkCapacity, needsTier = true },
}

-- collect＝nil：第一個失敗就回 code, detail；collect＝陣列：全部跑完、每組一筆 { name, ok, code, ...detail }
function C.validate(v, collect)
    local byName = {}
    for _, s in ipairs(C.STEPS) do
        if not (s.needsTier and v.tier == nil) and not (s.needsShape and v.badShape) then
            local code, detail = s.fn(v)
            if collect == nil then
                if code then return code, detail end
            else
                local e = byName[s.name]
                if e == nil then
                    e = { name = s.name, ok = true }
                    byName[s.name] = e
                    collect[#collect + 1] = e
                end
                if code and e.ok then
                    for k, x in pairs(detail or {}) do e[k] = x end
                    e.ok, e.code = false, code
                end
            end
        end
    end
    return nil
end

-- ===== 交易（§7.4）=====

-- 原生（每塊一個）→ 地契 → 紀錄；st 記錄做到哪一步，給反序回滾用
local function createBody(v, rec, st)
    st.houses = {}
    local houses, code = N.build(rec, st.houses)
    if houses == nil then return code end
    local item = v.item
    if item ~= nil then
        -- Remove 會清掉 item.container，所以先記容器（ItemContainer.java:2036-2068；void、miss 靜默）
        local c = item:getContainer()                                     -- InventoryItem.java:3840
        st.container = c
        st.removed = true
        c:Remove(item)
        if c:contains(item) or item:getContainer() ~= nil then return CODE.DEED_REMOVE_FAILED end   -- :634
    end
    for i, h in ipairs(houses) do rec.rects[i].created = h:getDatetimeCreated() end
    R.put(rec)
    st.put = true
    return nil
end

-- 反序回滾：紀錄 → 地契（放回原容器；客戶端沒看過移除，不送網路）→ 原生
function C.rollback(rec, st, item)
    if st.put then R.unput(rec.claimId) end
    local c = st.container
    if st.removed and not c:contains(item) then
        c:AddItem(item)                                                   -- ItemContainer.java:462
        if not c:contains(item) or item:getContainer() ~= c then
            MSH.Audit.write("ROLLBACK_ITEM_FAILED", { actor = rec.owner, claimId = rec.claimId })
        end
    end
    for _, h in ipairs(st.houses or {}) do
        if not N.remove(h) then
            -- 留下沒有紀錄的標記原生：sweep 不會收它，要等下次開服 Reconcile startup 才轉 quarantined(recovered)（§6.2），
            -- 在那之前不受管
            MSH.Audit.write("ROLLBACK_NATIVE_FAILED", { actor = rec.owner, claimId = rec.claimId })
        end
    end
end

function C.commitCreate(ctx, v)
    local id = R.allocId()          -- 失敗也用掉（§4.2）
    local rec = C.draft(v, id)
    local item, st = v.item, {}
    local ok, code = pcall(createBody, v, rec, st)
    if not ok or code ~= nil then
        C.rollback(rec, st, item)
        if not ok then
            MSH.log("create rolled back: " .. tostring(code))
            MSH.Audit.write("CREATE_ROLLBACK", { actor = ctx.who, claimId = id, detail = tostring(code) })
            return S.fail(CODE.INTERNAL_ERROR)
        end
        if code == CODE.DEED_REMOVE_FAILED then
            MSH.Audit.write("DEED_REMOVE_FAILED", { actor = ctx.who, claimId = id })
        end
        return S.fail(code)
    end
    local c, houses = st.container, st.houses
    if item ~= nil then
        -- 伺服器改背包要自己同步（LuaManager.java:12418；原版伺服器用例 ISBuildUtil.lua:148-152）
        ctx.defer(function() sendRemoveItemFromContainer(c, item) end)
    end
    ctx.defer(function()
        for _, h in ipairs(houses) do N.broadcast(h) end
    end)
    MSH.Audit.write("CREATE", { actor = ctx.who, claimId = id, code = rec.source, detail = Rect.listKey(rec.rects) })
    MSH.Journal.created(rec, ctx.now)
    return S.ok({ claimId = id, revision = rec.revision, rects = Rect.copyList(rec.rects), title = rec.title,
        deedTier = rec.deedTier })
end

function C.create(ctx)
    local a = ctx.args
    local v = C.newCheck(ctx, MSH.Settings.get(), a.rects, a.deedType, a.title)
    local code, detail = C.validate(v)
    if code then return S.fail(code, detail) end
    local bound, why = MSH.Identity.bindForClaim(ctx.player, ctx.now)
    if not bound then return S.fail(CODE.BIND_REFUSED, { reason = why }) end
    return C.commitCreate(ctx, v)
end

-- ===== 屋主操作 =====

-- 對既有 claim 的 mutation 在 ACL 通過後綁定 actor（Steam 模式；§4.2「建立安全屋時」的同一組安全條件）。
-- 原因：沒綁定的名字（MANAGE 成員、遷移來的 legacy 屋主）原本能對既有安全屋做 mutation，之後同名冒用也通過。
-- 只在 mutation 綁：查詢、calibrate、admin 指令照 VehicleManager 回名字（§4.2），所以看指令的 kind。
-- 共用位置：C.owned（release、rename、redraw）與 Sharing 的 ACL（share、unshare、陣營三個、leave）都呼叫這裡。
-- 回傳 nil（通過或不需要）或 IDENTITY_UNVERIFIED, 原因
function C.bindActor(ctx)
    local spec = S.commands[ctx.command]
    if spec == nil or spec.kind ~= "mutation" then return nil end
    local ok, why = MSH.Identity.bindForClaim(ctx.player, ctx.now)
    if ok then return nil end
    -- RENAME_EVIDENCE 由 bindForClaim 自己寫過 audit
    if why ~= "RENAME_EVIDENCE" then
        MSH.Audit.write("BIND_REFUSED", { actor = ctx.who, claimId = ctx.args.claimId, code = why, detail = ctx.command })
    end
    return CODE.IDENTITY_UNVERIFIED, why
end

-- 找到 actor 自己的紀錄；allowed＝可接受的 lifecycle 集合（nil 不檢查）。mutation 通過後綁定 actor（C.bindActor）
function C.owned(ctx, allowed)
    local a = ctx.args
    local rec = R.get(a.claimId)
    if rec == nil or not R.isLive(rec) then return nil, CODE.NOT_FOUND end
    if rec.owner ~= ctx.who then return nil, CODE.NOT_OWNER end
    if allowed and not allowed[rec.lifecycle] then return nil, CODE.WRONG_LIFECYCLE end
    if a.expectedRevision ~= nil and a.expectedRevision ~= rec.revision then return nil, CODE.STALE_REVISION end
    local bad = C.bindActor(ctx)
    if bad then return nil, bad end
    return rec
end

local RELEASABLE = { [LC.ACTIVE] = true, [LC.LAPSED] = true }
local ACTIVE = { [LC.ACTIVE] = true }

-- 地契一律不退（§7.6）
function C.release(ctx)
    local rec, code = C.owned(ctx, RELEASABLE)
    if rec == nil then return S.fail(code) end
    local ok, why = MSH.Lifecycle.release(rec, "RELEASED", ctx.args.requestId, ctx.now, ctx.defer)
    if not ok then return S.fail(why, { claimId = rec.claimId }) end
    return S.ok({ claimId = rec.claimId })
end

-- 還能重畫幾次：沙盒 RedrawLimit 減已重畫次數；上限改小時已用掉的照算（已 3 次、上限改 2 → 0）
function C.redrawsLeft(rec, cfg)
    return math.max(0, cfg.redrawLimit - C.redraws(rec))
end

-- 重新框選剩多久：不是 active、legacy、RedrawMinutes＝0、次數用完都回 0（客戶端不顯示按鈕）
function C.redrawRemainingMs(rec, cfg, now)
    if rec.lifecycle ~= LC.ACTIVE or rec.source == SRC.LEGACY or cfg.redrawMinutes <= 0
        or C.redrawsLeft(rec, cfg) <= 0 then return 0 end
    return math.max(0, rec.createdAt + cfg.redrawMinutes * 60000 - now)
end

-- 重新框選的對象：自己的、active、不是 legacy、還在 RedrawMinutes 內、重畫次數未滿（§7.6）
function C.redrawTarget(ctx, cfg)
    local rec, code = C.owned(ctx, nil)
    if rec == nil then return nil, code end
    if C.redrawRemainingMs(rec, cfg, ctx.now) <= 0 then return nil, CODE.REDRAW_CLOSED end
    return rec
end

-- 新原生（每塊一個）→ 放棄舊屋（送出先收在 sends）→ 新紀錄
local function redrawBody(ctx, old, rec, st)
    st.houses = {}
    local houses, code = N.build(rec, st.houses)
    if houses == nil then return code end
    st.releasing = true
    local ok, why = MSH.Lifecycle.release(old, "REDRAWN", ctx.args.requestId, ctx.now,
        function(fn) st.sends[#st.sends + 1] = fn end)
    if not ok then return why end
    st.released = true
    for i, h in ipairs(houses) do rec.rects[i].created = h:getDatetimeCreated() end
    R.put(rec)
    st.put = true
    return nil
end

-- 舊屋已寫成 released（搬到 tombstone）之後才丟錯：寫回 active 並重建原生（§7.6「照 §7.4 反序把舊 claim 建回來」）
local function restoreOld(ctx, old)
    R.unrelease(old)
    local ok, why = MSH.Lifecycle.rebuild(old, nil, ctx.defer)
    if not ok then
        MSH.Audit.write("REDRAW_RESTORE_FAILED", { actor = ctx.who, claimId = old.claimId, code = why })
    end
end

-- 拆舊屋拆到一半失敗（Lifecycle.release 已把它轉 quarantined，前面的塊已經拆掉）：新屋拆掉之後只補回舊屋缺的塊、
-- 回 active。同一塊重複或對不上（DUPLICATE／MISMATCH）、補不回來就照樣 quarantined，交給管理員（2026-10-11 審查）
local function restorePartial(ctx, old)
    if old.lifecycle ~= LC.QUARANTINED or old.quarantineReason ~= "RELEASE_REMOVE_FAILED" then return end
    local L, idx = MSH.Lifecycle, N.index()
    local entries = L.findNatives(old, idx)
    if entries == nil then return end
    local ok, why = L.rebuild(old, idx, ctx.defer, entries)
    if not ok then
        MSH.Audit.write("REDRAW_RESTORE_FAILED", { actor = ctx.who, claimId = old.claimId, code = why })
        return
    end
    old.lifecycle, old.quarantineReason, old.operation = LC.ACTIVE, nil, nil
    R.touch(old)
end

function C.commitRedraw(ctx, v, old)
    local id = R.allocId()
    local rec = C.draft(v, id)
    local st = { sends = {} }
    local ok, code = pcall(redrawBody, ctx, old, rec, st)
    if not ok or code ~= nil then
        if st.put then R.unput(id) end
        for _, h in ipairs(st.houses or {}) do
            if not N.remove(h) then MSH.Audit.write("ROLLBACK_NATIVE_FAILED", { actor = ctx.who, claimId = id }) end
        end
        if st.released then restoreOld(ctx, old) elseif st.releasing then restorePartial(ctx, old) end
        if not ok then
            MSH.log("redraw rolled back: " .. tostring(code))
            MSH.Audit.write("REDRAW_ROLLBACK", { actor = ctx.who, claimId = old.claimId, detail = tostring(code) })
            return S.fail(CODE.INTERNAL_ERROR)
        end
        return S.fail(code)
    end
    for _, fn in ipairs(st.sends) do ctx.defer(fn) end
    local houses = st.houses
    ctx.defer(function()
        for _, h in ipairs(houses) do N.broadcast(h) end
    end)
    MSH.Audit.write("REDRAW", { actor = ctx.who, claimId = id,
        detail = "from " .. tostring(old.claimId) .. " " .. Rect.listKey(rec.rects) })
    MSH.Journal.redrawn(old, rec)
    return S.ok({ claimId = id, revision = rec.revision, rects = Rect.copyList(rec.rects), title = rec.title,
        deedTier = rec.deedTier, replaced = old.claimId })
end

function C.redraw(ctx)
    local cfg = MSH.Settings.get()
    local old, code = C.redrawTarget(ctx, cfg)
    if old == nil then return S.fail(code) end
    local v = C.newCheck(ctx, cfg, ctx.args.rects)
    C.useOld(v, old)
    local detail
    code, detail = C.validate(v)
    if code then return S.fail(code, detail) end
    return C.commitRedraw(ctx, v, old)
end

function C.rename(ctx)
    local rec, code = C.owned(ctx, ACTIVE)
    if rec == nil then return S.fail(code) end
    local title = MSH.cleanTitle(ctx.args.title)
    if title == nil then return S.fail(CODE.BAD_TITLE) end
    rec.title = title
    R.touch(rec)
    -- 每一塊的原生都改；不在的塊（等收斂重建）重建時會帶新標題
    local entries = MSH.Lifecycle.findNatives(rec, N.index())
    for _, e in ipairs(entries or {}) do
        if e then
            e.house:setTitle(title)                                       -- SafeHouse.java:731
            local house = e.house
            ctx.defer(function() N.broadcast(house) end)
        end
    end
    MSH.Audit.write("RENAME", { actor = ctx.who, claimId = rec.claimId })
    return S.ok({ claimId = rec.claimId, revision = rec.revision, title = title })
end

-- 預檢：同一套檢查、不寫任何東西（不綁定、不扣地契）；claimId＝預檢該屋的重新框選
function C.preview(ctx)
    local a = ctx.args
    local cfg = MSH.Settings.get()
    local v = C.newCheck(ctx, cfg, a.rects, a.deedType, nil)
    if a.claimId ~= nil then
        local old, code = C.redrawTarget(ctx, cfg)
        if old == nil then return S.fail(code) end
        C.useOld(v, old)
    end
    local checks = {}
    C.validate(v, checks)
    local pass = true
    for _, e in ipairs(checks) do pass = pass and e.ok end
    return S.ok({ pass = pass, checks = checks })
end

-- ===== Manager 投影（§6.4）=====

-- 狀態只回最高優先的一個（§10.3）；Reconcile 的旗標在伺服器記憶體。
-- FACTION_TOO_LARGE：陣營分享有效但人數超過投影上限，沒有投影進原生名單（§4.2 第 227、238 行，不靜默截斷）
function C.healthSummary(rec)
    if MSH.Health.blocked() then return "SERVER_BLOCKED" end
    local flags = MSH.Reconcile and MSH.Reconcile.claimFlags and MSH.Reconcile.claimFlags[rec.claimId] or nil
    if flags and flags.missing then return "REPAIR_PAUSED" end
    if flags and flags.interference then return "INTERFERENCE" end
    if rec.lifecycle == LC.LAPSED then return "LAPSED" end
    if rec.lifecycle == LC.QUARANTINED then return "QUARANTINED" end
    local members = N.factionMembers(rec)
    if members and #members > LIMIT.FACTION_PROJECTION then return "FACTION_TOO_LARGE" end
    return "PROTECTED"
end

-- 位元聯集（Kahlua 沒有位元運算子）
local function unionBits(a, b)
    local out = 0
    for _, bit in pairs(MSH.SHARE) do
        if MSH.hasBit(a, bit) or MSH.hasBit(b, bit) then out = out + bit end
    end
    return out
end

-- 這間的 grant（沒有回 nil）
function C.grantOf(rec, user)
    for i, g in ipairs(rec.grants or {}) do
        if g.user == user then return g, i end
    end
    return nil
end

-- actor 在這間的角色（位元的唯一來源，Permissions 也用它）：owner（全部位元）或 member（帶 MEMBER 的 grant 與
-- 投影中的陣營分享取聯集，§6.4、§6.5）；沒有角色回 nil。陣營超過投影上限時不算（和原生名單一致）。
-- 陣營位元一律遮成 SHARE_FACTION_MAX：舊資料裡的邀請／管理也不生效
function C.roleOf(rec, who)
    if rec.owner == who then return "owner", MSH.SHARE_ALL end
    local g = C.grantOf(rec, who)
    local bits = (g and MSH.hasBit(g.bits, MSH.SHARE.MEMBER)) and g.bits or nil
    for _, u in ipairs(N.projectedMembers(rec) or {}) do
        if u == who then
            bits = unionBits(bits or 0, MSH.maskBits(rec.factionShare.bits, MSH.SHARE_FACTION_MAX))
            break
        end
    end
    if bits then return "member", bits end
    return nil
end

-- 「我的」與「分享給我的」（含只靠陣營的）；分享給我的另帶屋主名字。自己的另帶等級與名額種類（free／paid／legacy），
-- 清單才分得出名稱一樣的幾間（使用者 2026-10-15）
function C.list(ctx)
    local rows = {}
    local mine = nil
    for _, rec in ipairs(R.list()) do
        local role, bits = nil, nil
        if R.isLive(rec) then role, bits = C.roleOf(rec, ctx.who) end
        if role then
            local row = { claimId = rec.claimId, revision = rec.revision, title = rec.title, actorRole = role,
                bits = bits, lifecycle = rec.lifecycle, healthSummary = C.healthSummary(rec),
                owner = role == "member" and rec.owner or nil }
            if role == "owner" then
                mine = mine or C.slots(ctx.who, MSH.Settings.get())
                row.deedTier = rec.deedTier
                row.slot = rec.source == SRC.LEGACY and "legacy" or (mine.ids[rec.claimId] and "free" or "paid")
            end
            rows[#rows + 1] = row
        end
    end
    return S.ok({ claims = rows })
end

-- 陣營分享的投影給 detail：members＝目前有效時的人數（無效 0）、projected＝有沒有投影進原生名單
local function factionView(rec)
    local fs = rec.factionShare
    if type(fs) ~= "table" then return nil end
    local members = N.factionMembers(rec)
    return { name = fs.name, leader = fs.leader, bits = MSH.maskBits(fs.bits, MSH.SHARE_FACTION_MAX), state = fs.state,
        reason = fs.reason, members = members and #members or 0, projected = N.projectedMembers(rec) ~= nil }
end

-- 沒有角色一律 NOT_FOUND（不透露存在與否）；malformed（沒有合法 rect）不給屋主看，和清單一致
function C.detail(ctx)
    local rec = R.get(ctx.args.claimId)
    local role, bits = nil, nil
    if rec ~= nil and R.isLive(rec) and not rec.malformed then role, bits = C.roleOf(rec, ctx.who) end
    if role == nil then return S.fail(CODE.NOT_FOUND) end
    local roster = { { user = rec.owner, role = "owner" } }
    local grants = {}
    for _, g in ipairs(rec.grants or {}) do
        roster[#roster + 1] = { user = g.user, bits = g.bits, role = "member" }
        -- effBits：該成員實際的位元（roleOf：grant 與有效陣營分享的聯集）；客戶端用它判斷對方算不算持有 MANAGE
        local _, eff = C.roleOf(rec, g.user)
        grants[#grants + 1] = { user = g.user, bits = g.bits, effBits = eff or 0 }
    end
    local owner = role == "owner"
    local active = rec.lifecycle == LC.ACTIVE
    local cfg = MSH.Settings.get()
    local faction = factionView(rec)
    return S.ok({
        claimId = rec.claimId, revision = rec.revision, title = rec.title, rects = Rect.copyList(rec.rects),
        deedTier = rec.deedTier, source = rec.source, createdAt = rec.createdAt, lifecycle = rec.lifecycle,
        actorRole = role, bits = bits, roster = roster, healthSummary = C.healthSummary(rec),
        grants = grants, factionShare = faction,
        limits = { maxShares = cfg.maxShares, allowFactionShare = cfg.allowFactionShare },
        economy = MSH.Economy and MSH.Economy.claimInfo and MSH.Economy.claimInfo(rec) or nil,
        -- 閒置收回的倒數與保險（Idle.view；屋主另帶 insure 購買資訊）
        idle = MSH.Idle and MSH.Idle.view(rec, ctx.who, ctx.now) or nil,
        -- 只給自己看的重生點狀態（Respawn.view：總開關、點在不在這間）
        respawn = MSH.Respawn and MSH.Respawn.view(rec, ctx.who) or nil,
        actions = {
            canRelease = owner and RELEASABLE[rec.lifecycle] == true,
            canRename = owner and active,
            redrawRemainingMs = owner and C.redrawRemainingMs(rec, cfg, ctx.now) or 0,
            redrawsLeft = owner and C.redrawsLeft(rec, cfg) or nil,
            -- 和 Sharing 的 ACL 一致：屋主或帶 MANAGE 的成員；陣營分享與恢復只限屋主
            canManageShares = active and (owner or MSH.hasBit(bits, MSH.SHARE.MANAGE)),
            canShareFaction = owner and active and cfg.allowFactionShare,
            canResumeFaction = owner and active and cfg.allowFactionShare and faction ~= nil
                and faction.state == "SUSPENDED",
            canLeave = not owner and C.grantOf(rec, ctx.who) ~= nil,
        },
    })
end

-- ===== 指令登記 =====

S.define("create", { kind = "mutation", fields = { rects = "rects", deedType = "deedType?", title = "title?" },
    run = function(ctx) return MSH.Claims.create(ctx) end })
-- 預檢不持鎖、會掃地圖：每人 500 ms 一次（審查 CRITICAL；外框與每塊邊長已由 S.TYPES.rects 限在 HARD_SIDE）
S.define("preview", { kind = "query", cooldownMs = 500,
    fields = { rects = "rects", deedType = "deedType?", claimId = "claimId?" },
    run = function(ctx) return MSH.Claims.preview(ctx) end })
S.define("release", { kind = "mutation", whenBlocked = true, fields = { claimId = "claimId", expectedRevision = "revision" },
    run = function(ctx) return MSH.Claims.release(ctx) end })
S.define("redraw", { kind = "mutation", fields = { claimId = "claimId", rects = "rects", expectedRevision = "revision" },
    run = function(ctx) return MSH.Claims.redraw(ctx) end })
S.define("rename", { kind = "mutation", fields = { claimId = "claimId", title = "title", expectedRevision = "revision" },
    run = function(ctx) return MSH.Claims.rename(ctx) end })
S.define("list", { kind = "query", fields = {}, run = function(ctx) return MSH.Claims.list(ctx) end })
S.define("detail", { kind = "query", fields = { claimId = "claimId" }, run = function(ctx) return MSH.Claims.detail(ctx) end })
