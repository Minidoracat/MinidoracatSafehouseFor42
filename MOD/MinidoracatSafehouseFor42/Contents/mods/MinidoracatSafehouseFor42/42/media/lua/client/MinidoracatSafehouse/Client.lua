-- MinidoracatSafehouse/Client.lua：客戶端共用核心（M3）。各視窗只透過這裡跟伺服器說話：
--   UI 框架偵測與主題（含 warning 色票退路）、指令送收（一律帶 requestId，照 requestId 配對結果；10 秒沒回覆＝
--   result-pending，可用同一 requestId 重送，伺服器以結果快取回原結果，計畫 §4.3、§10.4）、結果碼的「原因＋動作」文字、
--   自己的安全屋清單快取（manager 投影 list，§6.4）與本地格子的權限位元查詢（客戶端藏選單用，§6.6）。
-- 查詢也帶 requestId：伺服器對冷卻中的請求直接丟、不回覆（Server.lua coolingDown），沒有 requestId 時只能照順序配對，
--   一丟就全部錯位。
-- 出處：反編譯 D:/github/pz-decompiled-reference/snapshots/42.21.0-20260928/pz/zombie/（LuaManager.java＝Lua/LuaManager.java）。

if not isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Settings"

local MSH = MinidoracatSafehouse
local first = MSH.Client == nil
local C = MSH.Client or {}
MSH.Client = C

C.MIN_REV = 16                 -- 計畫 §10.1：ScrollPanel、Text.wrap、Focus、Table、FilterBar、Dock 都在 rev 16 以內
C.TIMEOUT_MS = 10000           -- 送出 10 秒沒有結果（§10.4 result-pending）
C.EXPIRE_MS = 70000            -- 伺服器結果快取 60 秒（LIMIT.CACHE_TTL_MS）＋餘裕；過了就不再等這筆
C.pending = C.pending or {}    -- requestId → { command, args, sentAt, retriedAt, cb, mutation, notified }
C.seq = C.seq or 0
C.listeners = C.listeners or {}
C.claims = C.claims or { mine = {}, shared = {}, byId = {}, at = nil }

-- ===== UI 框架（../MinidoracatUIFor42/AGENTS.md「下游 consumer」；docs/ARCHITECTURE.md §2）=====
-- 讀全域、檢查 API_MAJOR 與版本、逐個檢查 capability；不合回 nil，呼叫端退最小直角 fallback（AGENTS.md 鐵則）。
-- PZ 的 require 回傳值不可靠，一律讀全域。
function C.ui(caps, minRev)
    if not (MinidoracatUI and MinidoracatUI.v1) then pcall(require, "MinidoracatUI/V1") end
    local UI = MinidoracatUI and MinidoracatUI.v1
    if UI == nil or UI.API_MAJOR ~= 1 or (UI.API_REVISION or 0) < (minRev or C.MIN_REV) then return nil end
    local have = UI.CAPABILITIES or {}
    for _, cap in ipairs(caps or {}) do
        if have[cap] ~= true then return nil end
    end
    return UI
end

-- warning 色票：框架 rev 18 起內建（DARK 值與這裡相同，MinidoracatUIFor42 docs/ARCHITECTURE.md §3.2）；舊框架由本 MOD 注入，
-- consumer token 會原樣保留。色相離 accent 18.75°、對深色 surface 9.07:1（計畫 §10.1 的條件；框架 test_rev18.lua 驗）。
C.WARNING = { r = 1.0, g = 0.55, b = 0.2, a = 1 }
function C.theme(UI)
    if C._theme ~= nil and C._themeUI == UI then return C._theme end
    local colors = nil
    local pal = UI.Theme.defaultPalette and UI.Theme.defaultPalette("dark") or nil
    if not (pal and pal.warning) then colors = { warning = C.WARNING } end
    C._theme, C._themeUI = UI.Theme.create({ variant = "dark", colors = colors }), UI
    return C._theme
end

-- ===== 事件（視窗之間互相通知；同一 key 重複登記會覆蓋，熱重載不會疊加）=====
function C.on(event, key, fn)
    local l = C.listeners[event]
    if l == nil then
        l = {}
        C.listeners[event] = l
    end
    l[key] = fn
end

function C.off(event, key)
    if C.listeners[event] then C.listeners[event][key] = nil end
end

function C.emit(event, payload)
    local l = C.listeners[event]
    if l == nil then return end
    local fns = {}
    for _, fn in pairs(l) do fns[#fns + 1] = fn end
    for _, fn in ipairs(fns) do
        local ok, err = pcall(fn, payload)
        if not ok then MSH.log("listener " .. tostring(event) .. " failed: " .. tostring(err)) end
    end
end

-- ===== 指令送收 =====
-- requestId 8–64 字元 [%w-_]（Contract validRequestId）；時間取後 8 位並補零（不補零時餘數小就短於 8 字元、整筆被拒）。
-- Kahlua string.format 支援 0 旗標補位（pz/se/krka/kahlua/stdlib/StringLib.java:151-152、275-278）。
local function newRequestId()
    C.seq = C.seq + 1
    return string.format("msh-%08d-%d", math.floor(getTimestampMs() % 100000000), C.seq)
end

-- 分割畫面次玩家沒有身分（principal 回 nil），一律用 0 號玩家送。getSpecificPlayer LuaManager.java:4163-4167；
-- sendClientCommand(player, module, command, args) :8932-8936。
-- opts.mutation：結果待定時保留這筆、可重送；opts.requestId：重送同一筆。回傳 requestId（沒有玩家回 nil、不呼叫 cb）。
-- cb(result)：result 是伺服器的 { command, requestId, ok, code, ... }；10 秒沒回覆時先呼叫一次
--   { ok = false, code = "NO_REPLY", pending = <是否 mutation> }，mutation 之後收到真結果會再呼叫一次。
function C.send(command, args, cb, opts)
    local player = getSpecificPlayer(0)
    if player == nil then return nil end
    args = args or {}
    args.protocol = MSH.PROTOCOL
    local rid = (opts and opts.requestId) or newRequestId()
    args.requestId = rid
    C.pending[rid] = { command = command, args = args, sentAt = getTimestampMs(), cb = cb,
        mutation = opts ~= nil and opts.mutation == true }
    sendClientCommand(player, MSH.MODULE, command, args)
    return rid
end

-- 結果待定時「查詢結果」：同一 requestId、同一份參數重送；伺服器 60 秒內回快取的原結果，不會再扣一次地契
function C.retry(rid)
    local p = C.pending[rid]
    local player = getSpecificPlayer(0)
    if p == nil or player == nil then return false end
    p.retriedAt, p.notified = getTimestampMs(), false
    sendClientCommand(player, MSH.MODULE, p.command, p.args)
    return true
end

function C.isPending(rid)
    return rid ~= nil and C.pending[rid] ~= nil
end

-- 放棄等待（只關畫面，不取消伺服器上的動作）
function C.forget(rid)
    if rid ~= nil then C.pending[rid] = nil end
end

local function deliver(p, result)
    if p.cb == nil then return end
    local ok, err = pcall(p.cb, result)
    if not ok then MSH.log("callback " .. tostring(p.command) .. " failed: " .. tostring(err)) end
end

function C.onResult(args)
    local rid = args.requestId
    local p = rid ~= nil and C.pending[rid] or nil
    if p == nil or p.command ~= args.command then return end
    C.pending[rid] = nil
    deliver(p, args)
    C.emit("result", args)
end

-- 每 500 ms 檢查逾時；先收集再改表（走訪中不改正在走訪的表）
function C.checkTimeouts(now)
    if C.lastCheck ~= nil and now - C.lastCheck < 500 then return end
    C.lastCheck = now
    local late, gone = {}, {}
    for rid, p in pairs(C.pending) do
        local age = now - (p.retriedAt or p.sentAt)
        if p.mutation and now - p.sentAt >= C.EXPIRE_MS and age >= C.TIMEOUT_MS then
            gone[#gone + 1] = rid
        elseif not p.notified and age >= C.TIMEOUT_MS then
            late[#late + 1] = rid
        end
    end
    for _, rid in ipairs(late) do
        local p = C.pending[rid]
        p.notified = true
        if not p.mutation then C.pending[rid] = nil end
        deliver(p, { ok = false, code = "NO_REPLY", command = p.command, requestId = rid, pending = p.mutation })
    end
    for _, rid in ipairs(gone) do
        local p = C.pending[rid]
        C.pending[rid] = nil
        deliver(p, { ok = false, code = "NO_REPLY", command = p.command, requestId = rid, pending = true, expired = true })
    end
end

-- ===== 結果碼文字（§10.4：每個原因碼都有一句原因加一句動作，12 語同步）=====
-- 鍵：IGUI_MSH_Code_<CODE>（原因）、IGUI_MSH_CodeAction_<CODE>（動作，可沒有）；沒有原因鍵就用 IGUI_MSH_Code_Generic（%1＝碼）。
-- getText 找不到鍵時回傳鍵本身（原版 Translator 行為）。
function C.codeText(code)
    local c = tostring(code)
    local key = "IGUI_MSH_Code_" .. c
    local reason = getText(key)
    if reason == key then reason = getText("IGUI_MSH_Code_Generic", c) end
    local akey = "IGUI_MSH_CodeAction_" .. c
    local action = getText(akey)
    if action == akey then action = nil end
    return reason, action
end

-- ===== 自己的安全屋（manager 投影 list：claimId, revision, title, actorRole, bits, lifecycle, healthSummary）=====
-- 同時只送一筆 list：送出中再被叫（陣營解散一次推來多則 changed）就記下，回覆到了只補送一次；
-- 送出中才給的 cb 等補送那筆的結果（2026-10-11 審查：每則 changed 各送一次 list，佔掉限流額度）
C.listCbs = {}

function C.refreshList(cb)
    if cb then C.listCbs[#C.listCbs + 1] = cb end
    if C.listRid ~= nil and C.pending[C.listRid] ~= nil then
        C.listAgain = true
        return C.listRid
    end
    local cbs = C.listCbs
    C.listCbs, C.listAgain = {}, false
    C.listRid = C.send("list", {}, function(res)
        if res.ok then
            local mine, shared, byId = {}, {}, {}
            for _, row in ipairs(res.claims or {}) do
                byId[row.claimId] = row
                if row.actorRole == "owner" then mine[#mine + 1] = row else shared[#shared + 1] = row end
            end
            C.claims = { mine = mine, shared = shared, byId = byId, at = getTimestampMs() }
            C.emit("claims", C.claims)
        end
        C.listRid = nil
        if C.listAgain then C.refreshList() end
        for _, f in ipairs(cbs) do
            local ok, err = pcall(f, res)
            if not ok then MSH.log("callback list failed: " .. tostring(err)) end
        end
    end)
    return C.listRid
end

-- 這格屬於哪間 managed 安全屋（本地原生清單裡 owner 是 @MSH:<id> 的；SafeHouse.getSafehouseList SafeHouse.java:652、
-- getOwner :656、getX/getY/getW/getH :596-626），回 claimId 或 nil
function C.claimAt(x, y)
    local list = SafeHouse.getSafehouseList()
    for i = 0, list:size() - 1 do
        local h = list:get(i)
        local id = MSH.claimIdOf(h:getOwner())
        if id ~= nil and x >= h:getX() and x < h:getX() + h:getW() and y >= h:getY() and y < h:getY() + h:getH() then
            return id
        end
    end
    return nil
end

-- 自己在 (x, y) 那間的權限位元：不是 managed 回 nil；managed 但清單沒有自己＝0
function C.bitsAt(x, y)
    local id = C.claimAt(x, y)
    if id == nil then return nil end
    local row = C.claims.byId[id]
    return row and row.bits or 0, id
end

-- 伺服器推送：changed（自己相關的安全屋變了，重抓清單）、denied（細分權限拒絕，各視窗或提示自行顯示）
function C.onServerCommand(module, command, args)
    if module ~= MSH.MODULE or type(args) ~= "table" then return end
    if command == "result" then
        C.onResult(args)
    elseif command == "changed" then
        C.emit("changed", args)
        C.refreshList()
    elseif command == "denied" then
        C.emit("denied", args)
    end
end

function C.onTick()
    C.checkTimeouts(getTimestampMs())
end

-- 開局第一個 tick 抓一次清單（OnGameStart 當下送會走錯路徑，pitfalls.md「MP client 不可在 OnGameStart 直接送」）
local function firstTick()
    Events.OnTick.Remove(firstTick)
    C.refreshList()
end

function C.onGameStart()
    Events.OnTick.Add(firstTick)
end

if first then
    Events.OnServerCommand.Add(function(module, command, args) MSH.Client.onServerCommand(module, command, args) end)
    Events.OnTick.Add(function() MSH.Client.onTick() end)
    Events.OnGameStart.Add(function() MSH.Client.onGameStart() end)
end
