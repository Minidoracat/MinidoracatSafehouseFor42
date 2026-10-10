-- MinidoracatSafehouse/Server.lua：單一指令分派、全域 mutation 鎖、開服時序與週期排程（計畫 §6、§6.1）。
-- 指令契約（§6.1）：協定版本完全相同；actor 只取引擎的 player；mutation 必帶 requestId；
-- 每人限流；同 requestId 已完成就回快取結果；持全域鎖做驗證與 mutation；所有路徑都放鎖；
-- 網路送出（原生廣播、remove delta、結果）排在 mutation 完成、放鎖之後（§6.2 最後一段）。
-- 其他模組用 S.define 登記指令、用 S.hook 登記週期工作；熱重載（/reloadlua）只換函式、不重複註冊事件。

if isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Settings"
require "MinidoracatSafehouse/Audit"
require "MinidoracatSafehouse/Registry"
require "MinidoracatSafehouse/Native"
require "MinidoracatSafehouse/Health"
require "MinidoracatSafehouse/Identity"

local MSH = MinidoracatSafehouse
local first = MSH.Srv == nil
local S = MSH.Srv or {}
MSH.Srv = S

local CODE = MSH.CODE

S.commands = S.commands or {}
S.hooks = S.hooks or { startup = {}, tick = {}, minute = {}, serverStarted = {} }
S.cache = S.cache or {}            -- actor → { map = { key → { at, result } }, order = { key } }
S.rate = S.rate or {}              -- actor → { start, n }
S.cooldown = S.cooldown or {}      -- actor → { [command] = ms }
S.unverified = S.unverified or {}  -- 名字 → 上次回覆 IDENTITY_UNVERIFIED 的時間
S.locked = false
S.RATE_WINDOW_MS, S.RATE_MAX = 5000, 20   -- 照 VehicleManager：每人 5 秒 20 個指令
S.HEALTH_MS = 500

function S.ok(fields)
    local r = fields or {}
    r.ok, r.code = true, CODE.OK
    return r
end

function S.fail(code, fields)
    local r = fields or {}
    r.ok, r.code = false, code
    return r
end

-- spec = { kind = "mutation"|"query", fields = { name = "type" | "type?" }, admin, whenBlocked, cooldownMs, run(ctx) }
function S.define(name, spec)
    S.commands[name] = spec
end

-- kind：startup（開服 OnLoadedMapZones 後依 order 執行）、tick（每 tick）、minute（每分鐘）、serverStarted
function S.hook(kind, name, fn, order)
    S.hooks[kind][name] = { fn = fn, order = order or 50 }
end

local function runHooks(kind, ...)
    local list = {}
    for name, h in pairs(S.hooks[kind]) do list[#list + 1] = { name = name, fn = h.fn, order = h.order } end
    MSH.sortSafe(list, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.name < b.name
    end)
    for _, h in ipairs(list) do
        local ok, err = pcall(h.fn, ...)
        if not ok then
            MSH.Audit.throttled("HOOK|" .. kind .. "|" .. h.name, 60000, "INTERNAL_ERROR",
                { code = kind, detail = h.name .. ": " .. tostring(err) }, getTimestampMs())
            MSH.log(kind .. " hook " .. h.name .. " failed: " .. tostring(err))
        end
    end
end

-- ===== 欄位驗證：只收 bounded scalar；未知欄位、型別錯、NaN／±Infinity、過長字串一律拒絕（§6.1）=====

local function exactKeys(t, allowed)
    for k in pairs(t) do
        if not allowed[k] then return false end
    end
    return true
end

local RECT_KEYS = { x = true, y = true, w = true, h = true }
local HOUSE_KEYS = { claimId = true, x = true, y = true, w = true, h = true }

S.TYPES = {
    int = MSH.isInt,
    claimId = function(v) return MSH.isInt(v) and v >= 1 and v < 1e9 end,
    revision = function(v) return MSH.isInt(v) and v >= 0 and v < 1e12 end,
    -- 邊長在協定層就限 96：預檢與建立會逐格掃地板、查 RoomDef 與 MiniMap，範圍過大的封包能把主執行緒卡住
    rect = function(v)
        return type(v) == "table" and exactKeys(v, RECT_KEYS) and MSH.Rect.valid(v)
            and v.w <= MSH.LIMIT.HARD_SIDE and v.h <= MSH.LIMIT.HARD_SIDE
    end,
    deedType = function(v) return MSH.tierOfDeed(v) ~= nil end,
    title = function(v) return type(v) == "string" and #v <= 120 and not MSH.hasControl(v) end,
    username = function(v) return MSH.validUsername(v) end,
    bits = function(v) return MSH.isInt(v) and v >= 0 and v <= MSH.SHARE_ALL end,
    bool = function(v) return type(v) == "boolean" end,
    page = function(v) return MSH.isInt(v) and v >= 1 and v <= 100000 end,
    query = function(v) return type(v) == "string" and #v <= MSH.LIMIT.USERNAME_CHARS and not MSH.hasControl(v) end,
    word = function(v) return type(v) == "string" and #v <= 32 and string.find(v, "^[%w_]+$") ~= nil end,
    count = function(v) return MSH.isInt(v) and v >= -1 and v <= 1000 end,
    -- 管理員沙盒變更：鍵是字串、值是純量；逐欄範圍由 Settings.validateChanges 檢查
    changes = function(v)
        if type(v) ~= "table" then return false end
        local n = 0
        for k, x in pairs(v) do
            n = n + 1
            if type(k) ~= "string" or #k > 40 or n > #MSH.Settings.OPTIONS then return false end
            local t = type(x)
            if t == "string" then
                if #x > 512 then return false end
            elseif t == "number" then
                if not MSH.isFinite(x) then return false end
            elseif t ~= "boolean" then
                return false
            end
        end
        return true
    end,
    -- 客戶端校正：本地 @MSH: 原生安全屋清單（§6.3）
    houses = function(v)
        if type(v) ~= "table" then return false end
        local n = 0
        for k, e in pairs(v) do
            n = n + 1
            if not MSH.isInt(k) or k < 1 or n > MSH.LIMIT.CALIBRATE_MAX then return false end
            if type(e) ~= "table" or not exactKeys(e, HOUSE_KEYS) or not MSH.isInt(e.claimId) then return false end
            if not MSH.isInt(e.x) or not MSH.isInt(e.y) or not MSH.isInt(e.w) or not MSH.isInt(e.h) then return false end
        end
        return true
    end,
}

local function validate(spec, args)
    if type(args) ~= "table" then return CODE.BAD_ARGS end
    if args.protocol ~= MSH.PROTOCOL then return CODE.PROTOCOL_MISMATCH end
    if spec.kind == "mutation" or args.requestId ~= nil then
        if not MSH.validRequestId(args.requestId) then return CODE.BAD_REQUEST_ID end
    end
    for k, v in pairs(args) do
        if k ~= "protocol" and k ~= "requestId" then
            local t = type(k) == "string" and spec.fields[k] or nil
            if t == nil then return CODE.BAD_ARGS end
            local name = string.gsub(t, "%?$", "")
            local check = S.TYPES[name]
            if check == nil or not check(v) then return CODE.BAD_ARGS end
        end
    end
    for k, t in pairs(spec.fields) do
        if string.sub(t, -1) ~= "?" and args[k] == nil then return CODE.BAD_ARGS end
    end
    return nil
end

-- ===== 限流、結果快取 =====

local function rateLimited(who, now)
    local r = S.rate[who]
    if r == nil or now - r.start >= S.RATE_WINDOW_MS then
        r = { start = now, n = 0 }
        S.rate[who] = r
    end
    r.n = r.n + 1
    return r.n > S.RATE_MAX
end

-- 同一人同一指令 cooldownMs 內重送就丟、不回覆（照 Economy ECServer.lua:517-529；管理員玩家清單 500 ms，§10.6）
local function coolingDown(who, command, ms, now)
    local per = S.cooldown[who]
    if per == nil then
        per = {}
        S.cooldown[who] = per
    end
    local last = per[command]
    if last ~= nil and now - last < ms then return true end
    per[command] = now
    return false
end

local function cacheKey(command, requestId)
    return command .. "|" .. requestId
end

local function cachedResult(who, command, requestId, now)
    local c = S.cache[who]
    if c == nil then return nil end
    local hit = c.map[cacheKey(command, requestId)]
    if hit == nil or now - hit.at > MSH.LIMIT.CACHE_TTL_MS then return nil end
    return hit.result
end

local function storeResult(who, command, requestId, result, now)
    local c = S.cache[who]
    if c == nil then
        c = { map = {}, order = {} }
        S.cache[who] = c
    end
    local key = cacheKey(command, requestId)
    if c.map[key] == nil then c.order[#c.order + 1] = key end
    c.map[key] = { at = now, result = result }
    while #c.order > MSH.LIMIT.CACHE_PER_ACTOR do
        c.map[table.remove(c.order, 1)] = nil
    end
end

local function pruneCaches(now)
    for who, c in pairs(S.cache) do
        local keep = {}
        for _, key in ipairs(c.order) do
            local hit = c.map[key]
            if hit ~= nil and now - hit.at <= MSH.LIMIT.CACHE_TTL_MS then keep[#keep + 1] = key else c.map[key] = nil end
        end
        c.order = keep
        if #keep == 0 then S.cache[who] = nil end
    end
    S.rate, S.cooldown = {}, {}
    for name, at in pairs(S.unverified) do
        if now - at > 60000 then S.unverified[name] = nil end
    end
end

-- ===== 全域鎖 =====

-- 反應時間內不 yield；所有路徑都放鎖。只用 pcall 保證放鎖並把錯誤記成 INTERNAL_ERROR，
-- 不把失敗洗成成功（交易本身另有反序回滾，§7.4）。
function S.withLock(fn)
    if S.locked then return S.fail(CODE.BUSY) end
    S.locked = true
    local ok, res = pcall(fn)
    S.locked = false
    if not ok then
        MSH.log("internal error: " .. tostring(res))
        MSH.Audit.write("INTERNAL_ERROR", { detail = tostring(res) })
        return S.fail(CODE.INTERNAL_ERROR)
    end
    return res
end

function S.isAdmin(player)
    local ok, yes = pcall(function()
        return player:getRole():hasCapability(Capability.CanSetupSafehouses)
    end)
    return ok and yes == true
end

function S.reply(player, command, requestId, result)
    result.command = command
    result.requestId = requestId
    sendServerCommand(player, MSH.MODULE, "result", result)
end

-- 身分未確認：先依宣稱的名字限流（不讓它繞過限流灌 audit），指令名不是已知指令就記成 UNKNOWN_COMMAND
local function unverified(player, command, requestId, now)
    local name = MSH.Identity.claimedName(player)
    if rateLimited("?" .. name, now) then return end
    local key = (type(command) == "string" and S.commands[command] ~= nil) and command or "UNKNOWN_COMMAND"
    MSH.Audit.deny(name, key, CODE.IDENTITY_UNVERIFIED)
    local last = S.unverified[name]
    if last ~= nil and now - last < 60000 then return end
    S.unverified[name] = now
    S.reply(player, key, requestId, S.fail(CODE.IDENTITY_UNVERIFIED))
end

function S.onClientCommand(module, command, player, args)
    if module ~= MSH.MODULE then return end
    local now = getTimestampMs()
    local requestId = type(args) == "table" and MSH.validRequestId(args.requestId) and args.requestId or nil
    if not S.enabled then
        return S.reply(player, command, requestId, S.fail(CODE.DEDICATED_ONLY))
    end
    local who = MSH.Identity.principal(player)
    if who == nil then return unverified(player, command, requestId, now) end
    if rateLimited(who, now) then
        local spec0 = S.commands[command]
        if spec0 ~= nil and spec0.kind == "mutation" then S.reply(player, command, requestId, S.fail(CODE.RATE_LIMITED)) end
        return
    end
    local spec = S.commands[command]
    if spec == nil then
        MSH.Audit.deny(who, "UNKNOWN_COMMAND", CODE.UNKNOWN_COMMAND)
        return S.reply(player, command, requestId, S.fail(CODE.UNKNOWN_COMMAND))
    end
    if spec.cooldownMs and coolingDown(who, command, spec.cooldownMs, now) then return end
    local bad = validate(spec, args)
    if bad then
        MSH.Audit.deny(who, command, bad)
        local res = S.fail(bad)
        if bad == CODE.PROTOCOL_MISMATCH then res.serverProtocol = MSH.PROTOCOL end
        return S.reply(player, command, requestId, res)
    end
    local admin = S.isAdmin(player)
    if spec.admin and not admin then
        MSH.Audit.deny(who, command, CODE.NOT_ADMIN)
        return S.reply(player, command, requestId, S.fail(CODE.NOT_ADMIN))
    end
    local mutation = spec.kind == "mutation"
    if mutation then
        local cached = cachedResult(who, command, requestId, now)
        if cached ~= nil then
            cached.replay = true
            return S.reply(player, command, requestId, cached)
        end
    end
    local result
    if not S.ready then
        result = S.fail(CODE.NOT_READY)
    elseif mutation and MSH.Registry.readOnly then
        result = S.fail(CODE.HEALTH_BLOCKED)
    elseif mutation and MSH.Health.blocked() and not spec.whenBlocked then
        result = S.fail(CODE.HEALTH_BLOCKED)
    end
    local deferred = {}
    if result == nil then
        local ctx = { player = player, who = who, args = args, now = now, admin = admin, command = command,
            defer = function(fn) deferred[#deferred + 1] = fn end }
        if mutation or spec.lock then
            result = S.withLock(function() return spec.run(ctx) end)
        else
            local ok, res = pcall(spec.run, ctx)
            if ok then
                result = res
            else
                MSH.log("query " .. command .. " failed: " .. tostring(res))
                result = S.fail(CODE.INTERNAL_ERROR)
            end
        end
        if type(result) ~= "table" then result = S.fail(CODE.INTERNAL_ERROR) end
    end
    if not result.ok then MSH.Audit.deny(who, command, result.code) end
    if mutation then storeResult(who, command, requestId, result, now) end
    -- 放鎖之後才送網路：原生廣播、remove delta（§6.2、§7.4 第 5 步）；失敗不回滾資產
    for _, fn in ipairs(deferred) do
        local ok, err = pcall(fn)
        if not ok then MSH.log("deferred send failed: " .. tostring(err)) end
    end
    S.reply(player, command, requestId, result)
end

-- ===== 開服時序（§6 sequenceDiagram）=====
-- OnInitGlobalModData：registry 可讀、native 還沒載入；OnLoadedMapZones：native 清單完整 → 首輪 reconcile → 開放 dispatcher。

function S.onInitGlobalModData()
    if not S.enabled then return end
    MSH.Registry.init()
    MSH.Registry.loadPrivate()
end

function S.onLoadedMapZones()
    if not S.enabled then return end
    local R = MSH.Registry
    if R.md == nil then
        R.init()
        R.loadPrivate()
    end
    -- bootSeq 只在正常開服後＋1；崩潰時這次的增量隨 Global ModData 一起沒存，所以「跨乾淨 restart」可用它判斷（§4.2）
    if R.ready() then R.md.bootSeq = R.md.bootSeq + 1 end
    local now = getTimestampMs()
    MSH.Health.evaluate(now)
    S.lastHealth = now
    runHooks("startup", now)
    S.ready = true
    S.lastMinute = now
end

-- 網路層到這時才建好：udpEngine 在 GameServer.java:1509 建立、:1533 才觸發 OnServerStarted；OnLoadedMapZones（IsoWorld.init，
-- :787）那時碰連線會 NPE。netUp 之前 Native／Audit 不送封包、不查在線玩家（2026-10-11 migration-mp boot2 實踩）
function S.onServerStarted()
    S.netUp = true
    if not S.enabled then return end
    runHooks("serverStarted")
end

function S.onTick()
    if not S.enabled or not S.ready then return end
    local now = getTimestampMs()
    if S.lastHealth == nil or now - S.lastHealth >= S.HEALTH_MS then
        S.lastHealth = now
        MSH.Health.evaluate(now)
    end
    MSH.Identity.tick(now)
    runHooks("tick", now)
    if S.lastMinute == nil or now - S.lastMinute >= 60000 then
        S.lastMinute = now
        MSH.Audit.flush()
        pruneCaches(now)
        runHooks("minute", now)
    end
end

S.enabled = MSH.Health.dedicated()

if first then
    Events.OnInitGlobalModData.Add(function(isNewGame) MSH.Srv.onInitGlobalModData(isNewGame) end)
    Events.OnLoadedMapZones.Add(function() MSH.Srv.onLoadedMapZones() end)
    Events.OnServerStarted.Add(function() MSH.Srv.onServerStarted() end)
    Events.OnClientCommand.Add(function(module, command, player, args)
        MSH.Srv.onClientCommand(module, command, player, args)
    end)
    Events.OnTick.Add(function() MSH.Srv.onTick() end)
end
