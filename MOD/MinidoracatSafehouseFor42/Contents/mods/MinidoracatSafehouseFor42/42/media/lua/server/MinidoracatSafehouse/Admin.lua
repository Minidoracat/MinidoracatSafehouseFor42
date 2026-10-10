-- MinidoracatSafehouse/Admin.lua：管理員指令（計畫 §10.6）與沙盒選項寫回／每分鐘比對（§7.1）。
-- 全部指令 admin = true（分派器以 Capability.CanSetupSafehouses 判斷）；mutation 都標 whenBlocked：
-- blocked mode 照常修設定、代為放棄與 targeted recovery（§5、§6.2）。代為放棄與 recovery 另標 duringMigration：
-- 遷移缺件時伺服器整體停在遷移中，管理員要能在遊戲內處理缺件，處理完立刻重跑 manifest 核對（§9 第 9 點）。
-- 沙盒寫回照 VehicleManager writeSandbox／saveSandbox（MinidoracatVehicleManager_Server.lua:307-331）：
--   全部 set 完只 toLua＋存一次檔；存檔不是 true 就還原舊值、回 SAVE_FAILED；成功才把整份快照 sandboxSync 給在線玩家。
-- 原版伺服器設定畫面直接改 SandboxVars 沒有 Lua 事件（VM :270-273 註解），所以每分鐘比對一次（VM S.watchSandbox :285-305）。
-- 玩家清單（§10.6「玩家」）：名單平時照小寫名字排好，有變動才補插入；查詢只篩選、切頁，不排序。

if isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Settings"
require "MinidoracatSafehouse/Audit"
require "MinidoracatSafehouse/Registry"
require "MinidoracatSafehouse/Native"
require "MinidoracatSafehouse/Health"
require "MinidoracatSafehouse/Lifecycle"
require "MinidoracatSafehouse/Server"
require "MinidoracatSafehouse/Migration"

local MSH = MinidoracatSafehouse
local A = MSH.Admin or {}
MSH.Admin = A

local S = MSH.Srv
local Settings = MSH.Settings
local CODE = MSH.CODE
local LC = MSH.LIFECYCLE

A.PAGE_ROWS = 50          -- 每頁 50 列（Economy Id.LOGINS_PAGE；最壞一頁約 25 KB，§10.6）
A.BULK_INSERT = 64        -- 一次新增超過這麼多名字就整份重排一次，不逐筆二分插入
A.FILTERS = { all = true, owners = true, overrides = true }

-- ===== 沙盒選項 =====

-- 送整份 80 鍵快照給每位在線玩家（getOnlinePlayers LuaManager.java:4457；sendServerCommand(player, ...) :8966-8970）
function A.pushSync(snapshot)
    local list = getOnlinePlayers()
    for i = 0, list:size() - 1 do
        sendServerCommand(list:get(i), MSH.MODULE, "sandboxSync", snapshot)
    end
end

-- SandboxOptions.set（未知選項名或 nil 值丟 IllegalArgumentException，SandboxOptions.java:572-582）→ toLua（:279-285）→
-- saveServerLuaFile（:683-685，I/O 錯誤回 false）；getSandboxOptions LuaManager.java:5809、getServerName :4099
local function writeAll(opts, values)
    for k, v in pairs(values) do opts:set(Settings.optionName(k), v) end
    opts:toLua()
    return opts:saveServerLuaFile(getServerName())
end

-- 兩份快照中值不同的鍵（照 OPTIONS 固定順序，不必排序）
local function changedKeys(old, new)
    local keys = {}
    for _, o in ipairs(Settings.OPTIONS) do
        if old[o.key] ~= new[o.key] then keys[#keys + 1] = o.key end
    end
    return keys
end

-- 每分鐘：原版設定畫面改過就寫 audit 並重送快照（自己的寫入已先更新 seen，不會重複 audit）
function A.sandboxWatch()
    local cur = Settings.snapshot()
    local old = A.seen
    A.seen = cur
    if old == nil then return end
    local keys = changedKeys(old, cur)
    if #keys == 0 then return end
    MSH.Audit.write("SANDBOX_CHANGED", { actor = "SANDBOX", detail = table.concat(keys, ",") })
    A.pushSync(cur)
end

local function exclusionStatus()
    local ex = MSH.Exclusions
    local st = ex and ex.status and ex.status() or {}
    return st.resourceApi == true, st.parkingApi == true
end

-- health detail（§12.4）：收斂健康度（Reconcile.health，有就併入）、被節流壓下的 audit 數、最後一次 recovery
S.define("adminOptions", { kind = "query", admin = true, fields = {}, run = function()
    local H = MSH.Health
    local resourceApi, parkingApi = exclusionStatus()
    local health = { blocked = H.blocked(), blockers = H.state.blockers, warnings = H.state.warnings, hostile = H.isHostile(),
        suppressed = MSH.Audit.suppressed, lastRecovery = A.lastRecovery }
    local Rc = MSH.Reconcile
    if Rc and Rc.health then
        for k, v in pairs(Rc.health()) do health[k] = v end
    end
    return S.ok({
        values = Settings.snapshot(),
        settingsWarnings = H.state.settingsWarnings,
        health = health,
        resourceApi = resourceApi,
        parkingApi = parkingApi,
    })
end })

S.define("adminSetOptions", { kind = "mutation", admin = true, whenBlocked = true, fields = { changes = "changes" },
    run = function(ctx)
        local changes = ctx.args.changes
        local ok, key, reason = Settings.validateChanges(changes)
        if not ok then return S.fail(CODE.BAD_OPTION, { key = key, reason = reason }) end
        local old = Settings.snapshot()
        local opts = getSandboxOptions()
        local wrote, saved = pcall(writeAll, opts, changes)
        if not wrote or saved ~= true then
            local back = {}
            for k in pairs(changes) do back[k] = old[k] end   -- 舊值是 nil 的鍵（選項檔缺）無法 set，只能略過
            local restored = pcall(writeAll, opts, back)
            MSH.log("sandbox save failed: " .. tostring(saved) .. " restored=" .. tostring(restored))
            return S.fail(CODE.SAVE_FAILED)
        end
        local snapshot = Settings.snapshot()
        A.seen = snapshot   -- 先更新比對基準：每分鐘比對不把自己的寫入當成外部改動
        local keys = {}
        for _, o in ipairs(Settings.OPTIONS) do
            if changes[o.key] ~= nil then keys[#keys + 1] = o.key end
        end
        MSH.Audit.write("ADMIN_OPTIONS", { actor = ctx.who, detail = table.concat(keys, ",") })
        ctx.defer(function() A.pushSync(snapshot) end)
        return S.ok({ values = snapshot })
    end })

-- ===== 玩家清單 =====
-- 名單＝bindings ∪ 佔位中 claim 的屋主 ∪ overrides；entry = { name, lower }。
-- R.namesVersion（綁定／上限寫入）或 registry generation（claim 變動）有變才重算；
-- 第一次（或大量新增）用 sortSafe 排一次，之後新名字二分插入，消失的名字原地刪除（保持順序）。
-- owned[name]＝該玩家佔位中的屋（不含 tombstone 與 malformed，照 claimId 小到大），給玩家頁〔查看〕〔代為放棄…〕；
--   全服受 MAX_CLAIMS 限制，一頁 50 列的回覆不會因此變大太多。

A.names = A.names or { list = {}, at = {}, used = {}, owned = {} }

local function before(a, b)
    if a.lower ~= b.lower then return a.lower < b.lower end
    return a.name < b.name
end

local function insertSorted(list, e)
    local lo, hi = 1, #list + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if before(list[mid], e) then lo = mid + 1 else hi = mid end
    end
    table.insert(list, lo, e)
end

function A.refreshNames()
    local R = MSH.Registry
    local ix = A.names
    local ver, gen = R.namesVersion or 0, R.md.generation
    if ix.version == ver and ix.generation == gen and ix.owned ~= nil then return ix end
    local want, used, owned = {}, {}, {}
    for name in pairs(R.bindings) do want[name] = true end
    for name in pairs(R.overrides) do want[name] = true end
    -- 直接走 claims（R.list 會排序；這裡只計數）
    for id, rec in pairs(R.md.claims) do
        if MSH.isInt(id) and type(rec) == "table" and R.isLive(rec) and type(rec.owner) == "string" then
            want[rec.owner] = true
            used[rec.owner] = (used[rec.owner] or 0) + 1
            if MSH.Rect.valid(rec.rect) then
                local list = owned[rec.owner] or {}
                owned[rec.owner] = list
                local row = { claimId = rec.claimId, title = rec.title, revision = rec.revision, lifecycle = rec.lifecycle,
                    tier = rec.deedTier }
                local i = #list
                while i >= 1 and list[i].claimId > row.claimId do list[i + 1] = list[i]; i = i - 1 end
                list[i + 1] = row
            end
        end
    end
    local kept, dropped = {}, false
    for _, e in ipairs(ix.list) do
        if want[e.name] then kept[#kept + 1] = e else dropped = true; ix.at[e.name] = nil end
    end
    if dropped then ix.list = kept end
    local fresh = {}
    for name in pairs(want) do
        if ix.at[name] == nil then fresh[#fresh + 1] = { name = name, lower = string.lower(name) } end
    end
    if #ix.list == 0 or #fresh > A.BULK_INSERT then
        for _, e in ipairs(fresh) do ix.list[#ix.list + 1] = e; ix.at[e.name] = e end
        MSH.sortSafe(ix.list, before)
    else
        for _, e in ipairs(fresh) do insertSorted(ix.list, e); ix.at[e.name] = e end
    end
    ix.used, ix.owned, ix.version, ix.generation = used, owned, ver, gen
    return ix
end

S.define("adminPlayers", { kind = "query", admin = true, cooldownMs = 500,
    fields = { query = "query?", filter = "word?", page = "page?" },
    run = function(ctx)
        local filter = ctx.args.filter or "all"
        if not A.FILTERS[filter] then return S.fail(CODE.BAD_ARGS) end
        local R = MSH.Registry
        local ix = A.refreshNames()
        local q = ctx.args.query
        local needle = (q ~= nil and q ~= "") and string.lower(q) or nil
        local hits = {}
        for _, e in ipairs(ix.list) do
            if (needle == nil or string.find(e.lower, needle, 1, true))
                and (filter == "all" or (filter == "owners" and (ix.used[e.name] or 0) > 0)
                    or (filter == "overrides" and R.overrides[e.name] ~= nil)) then
                hits[#hits + 1] = e
            end
        end
        local total = #hits
        local pages = math.max(1, math.ceil(total / A.PAGE_ROWS))
        local page = math.min(ctx.args.page or 1, pages)
        local cfg = Settings.get()
        local rows = {}
        for i = (page - 1) * A.PAGE_ROWS + 1, math.min(total, page * A.PAGE_ROWS) do
            local e = hits[i]
            local o = R.override(e.name)
            rows[#rows + 1] = { name = e.name, used = ix.used[e.name] or 0, free = o or cfg.claimsPerPlayer, override = o or -1,
                claims = ix.owned[e.name] or {} }
        end
        return S.ok({ rows = rows, page = page, pages = pages, total = total })
    end })

S.define("adminSetOverride", { kind = "mutation", admin = true, whenBlocked = true,
    fields = { targetUsername = "username", n = "count" },
    run = function(ctx)
        local name, n = ctx.args.targetUsername, ctx.args.n
        local value = n >= 0 and n or nil
        if not MSH.Registry.setOverride(name, value) then return S.fail(CODE.SAVE_FAILED) end
        MSH.Audit.write("ADMIN_OVERRIDE", { actor = ctx.who, code = tostring(n), detail = name })
        return S.ok({ targetUsername = name, n = n })
    end })

-- ===== 代為放棄、targeted recovery =====

-- 佔位中的紀錄；已放棄（只剩 tombstone）回 WRONG_LIFECYCLE，從沒有過回 NOT_FOUND
local function liveRecord(id)
    local R = MSH.Registry
    local rec = R.get(id)
    if rec ~= nil then return rec end
    return nil, S.fail(R.tomb(id) ~= nil and CODE.WRONG_LIFECYCLE or CODE.NOT_FOUND)
end

-- 遷移中（migrationCompleted == false）：處理完缺件立刻重新核對 manifest，全部吻合就解除遷移中
local function recheckMigration(now)
    if MSH.Registry.md.migrationCompleted == false then MSH.Migration.verify(now) end
end

S.define("adminRelease", { kind = "mutation", admin = true, whenBlocked = true, duringMigration = true,
    fields = { claimId = "claimId", expectedRevision = "revision?" },
    run = function(ctx)
        local rec, fail = liveRecord(ctx.args.claimId)
        if rec == nil then return fail end
        if rec.lifecycle == LC.RELEASING then return S.fail(CODE.WRONG_LIFECYCLE) end
        if ctx.args.expectedRevision ~= nil and ctx.args.expectedRevision ~= rec.revision then
            return S.fail(CODE.STALE_REVISION, { revision = rec.revision })
        end
        local owner = rec.owner
        local ok, code = MSH.Lifecycle.release(rec, "ADMIN_RELEASE", ctx.args.requestId, ctx.now, ctx.defer)
        if not ok then return S.fail(code, { claimId = rec.claimId }) end
        MSH.Audit.write("ADMIN_RELEASE", { actor = ctx.who, claimId = rec.claimId, detail = owner })
        recheckMigration(ctx.now)
        return S.ok({ claimId = rec.claimId })
    end })

-- 原生名單收斂成紀錄應有的人（不用 kick：收斂路徑不傳送真實玩家，§6.2）；
-- SafeHouse.removePlayer／addPlayer（SafeHouse.java:299、292）
local function fixRoster(house, rec)
    local desired = MSH.Native.desiredPlayers(rec)
    local want = {}
    for _, u in ipairs(desired) do want[u] = true end
    for _, u in ipairs(MSH.Native.players(house)) do
        if not want[u] then house:removePlayer(u) end
    end
    for _, u in ipairs(desired) do house:addPlayer(u) end
end

-- rebind：quarantined → active。有同標記且 rect 相同的原生 → 採用它的建立時間當指紋並修名單；
-- rect 不同或重複 → 留在 quarantined；沒有原生 → 照紀錄重建（重建失敗就還原 owner、不轉 active）。
-- malformed（沒有合法 rect）沒有東西可以對或重建，只能 release。
local function rebind(ctx, rec)
    local N, R = MSH.Native, MSH.Registry
    if not MSH.Rect.valid(rec.rect) then
        return S.fail(CODE.WRONG_LIFECYCLE, { claimId = rec.claimId, reason = "MALFORMED" })
    end
    local owner = ctx.args.targetUsername or rec.owner
    if owner == nil then return S.fail(CODE.BAD_USER, { claimId = rec.claimId }) end
    local idx = N.index()
    local list = idx.byClaim[rec.claimId]
    local entry = nil
    if list ~= nil and #list > 0 then
        if #list > 1 or not MSH.Rect.equals(list[1].rect, rec.rect) then
            return S.fail(CODE.WRONG_LIFECYCLE, { claimId = rec.claimId, reason = "NATIVE_MISMATCH" })
        end
        entry = list[1]
    end
    local oldOwner = rec.owner
    rec.owner = owner
    if entry == nil then
        local house, why = MSH.Lifecycle.rebuild(rec, idx, ctx.defer)
        if house == nil then
            rec.owner = oldOwner
            local code = why == CODE.NATIVE_FAILED and CODE.NATIVE_FAILED or CODE.WRONG_LIFECYCLE
            return S.fail(code, { claimId = rec.claimId, reason = why })
        end
    else
        local house = entry.house
        rec.nativeCreatedAt = house:getDatetimeCreated()   -- SafeHouse.java:681
        fixRoster(house, rec)
        ctx.defer(function() N.broadcast(house) end)
    end
    rec.lifecycle = LC.ACTIVE
    rec.quarantineReason, rec.recovered, rec.candidates = nil, nil, nil
    R.touch(rec)
    return S.ok({ claimId = rec.claimId, revision = rec.revision })
end

-- release 走 forceRelease：不看指紋，連 DUPLICATE／MISMATCH／malformed 的原生一起移除（§6 狀態圖 quarantined → released）
S.define("adminRecover", { kind = "mutation", admin = true, whenBlocked = true, duringMigration = true,
    fields = { claimId = "claimId", action = "word", targetUsername = "username?" },
    run = function(ctx)
        local action = ctx.args.action
        if action ~= "release" and action ~= "rebind" then return S.fail(CODE.BAD_ARGS) end
        local rec, fail = liveRecord(ctx.args.claimId)
        if rec == nil then return fail end
        if rec.lifecycle ~= LC.QUARANTINED then return S.fail(CODE.WRONG_LIFECYCLE) end
        local res
        if action == "release" then
            local ok, code = MSH.Lifecycle.forceRelease(rec, "ADMIN_RECOVER", ctx.args.requestId, ctx.now, ctx.defer)
            res = ok and S.ok({ claimId = rec.claimId }) or S.fail(code, { claimId = rec.claimId })
        else
            res = rebind(ctx, rec)
        end
        A.lastRecovery = { claimId = rec.claimId, action = action, code = res.code, at = ctx.now }
        if res.ok then
            MSH.Audit.write("ADMIN_RECOVER", { actor = ctx.who, claimId = rec.claimId, code = action, detail = rec.owner })
            recheckMigration(ctx.now)
        end
        return res
    end })

-- 不是 active 的紀錄（quarantined 含 malformed／recovered、lapsed、releasing），給 targeted recovery 挑對象；
-- 筆數以 MAX_CLAIMS＋malformed 為上限，不分頁
S.define("adminClaims", { kind = "query", admin = true, fields = {}, run = function()
    local rows = {}
    for _, rec in ipairs(MSH.Registry.listAll()) do
        if rec.lifecycle ~= LC.ACTIVE then
            rows[#rows + 1] = { claimId = rec.claimId, lifecycle = rec.lifecycle, quarantineReason = rec.quarantineReason,
                owner = rec.owner, rect = MSH.Rect.valid(rec.rect) and MSH.Rect.copy(rec.rect) or nil,
                candidates = rec.candidates }
        end
    end
    return S.ok({ claims = rows })
end })

S.hook("startup", "adminSandboxSeen", function() A.seen = Settings.snapshot() end)
S.hook("minute", "sandboxWatch", function() A.sandboxWatch() end)
