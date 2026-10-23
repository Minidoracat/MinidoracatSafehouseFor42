-- MinidoracatSafehouse/Foreign.lua：不歸本 MOD 管的原版安全屋（foreign：owner 不是 @MSH:<id> 標記的原生）。
-- 使用者 2026-10-23（issue #1 之後，設計稿 safehouse-foreign-1023）：管理員面板規則頁列出、可傳送過去看、確認後釋出；
--   不接管、不自動刪（decisions.md 2026-10-23）。多了新的原版屋時提示在線管理員。
-- adminForeign（查詢）：每間的範圍、屋主、標題、成員數（不含屋主）、原版建立時間、多久沒人進去（現在減最後到訪，停機
--   也算：Idle 的停機紀錄只為本 MOD 的屋留著，2026-10-23 審查）、來源（skip＝接管時留下，帶原因碼；waiting＝遷移還在等
--   前置條件；later＝其他）。只回最久沒人進去的 F.LIST_MAX 間，其餘只給間數。
-- adminForeignRelease（mutation）：範圍＋屋主＋原版建立時間三樣都對上的 foreign 才移除；只在 Native.index().foreign 裡找，
--   本 MOD 的屋碰不到。伺服器的 removeSafeHouse 不廣播（Native.sendRemove 同理），放鎖後推 foreignRemove，客戶端 Mirror
--   照範圍＋屋主移除。稽核 FOREIGN_RELEASED。
-- 本 MOD 的原生被改掉屋主時暫時沒有標記（Reconcile fixOwners 換回之前）：範圍＋建立時間對得上紀錄的某一塊就不算 foreign，
--   不列、不提示、不能從這裡釋出（pieceKeys）。
-- 每分鐘比一次 foreign 指紋：開服第一輪只記下；新出現、連續兩輪都在的才算新的（同上，換回標記前的那一塊、紀錄還沒存的
--   新屋都只會出現一下），稽核 FOREIGN_APPEARED 並提示在線管理員（Audit.alertAdmins）。
-- 字串字面值只用 ASCII（server-core.md 已知坑）。

if isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Settings"
require "MinidoracatSafehouse/Audit"
require "MinidoracatSafehouse/Registry"
require "MinidoracatSafehouse/Native"
require "MinidoracatSafehouse/Server"
require "MinidoracatSafehouse/Migration"

local MSH = MinidoracatSafehouse
local F = MSH.Foreign or {}
MSH.Foreign = F

local S = MSH.Srv
local CODE = MSH.CODE

F.LIST_MAX = 20   -- ponytail: 規則頁只列最久沒人進去的 20 間、其餘寫間數；上百間時改另開視窗分頁
F.DAY_MS = 86400000

-- 原版建立時間寫成整數字串（同 Migration createdText：不比浮點數轉成的字串）
local function stamp(v)
    if not MSH.isFinite(v) then return "-" end
    return string.format("%.0f", v)
end

-- 本 MOD 紀錄每一塊的指紋「範圍|建立時間」（沒記建立時間的塊用 *，同 Native.pieceOf）
local function pieceKeys()
    local out, md = {}, MSH.Registry.md
    if md == nil then return out end
    for id, rec in pairs(md.claims) do
        if MSH.isInt(id) and type(rec) == "table" and type(rec.rects) == "table" then
            for _, p in ipairs(rec.rects) do
                if type(p) == "table" then
                    out[MSH.Native.rectKey(p) .. "|" .. (p.created == nil and "*" or stamp(p.created))] = true
                end
            end
        end
    end
    return out
end

local function isPiece(keys, rect, h)
    local k = MSH.Native.rectKey(rect)
    return keys[k .. "|*"] or keys[k .. "|" .. stamp(h:getDatetimeCreated())] or false
end

-- 接管時留下的屋：completion 檔的 skip 行（Migration.lua 檔頭），「範圍<TAB>屋主」→ 原因碼。檔案只在開服的遷移時寫，
-- 讀到一次就留著；讀不開時這次不寫來源、下次再讀
function F.skipped()
    if F.skips ~= nil then return F.skips end
    local R = MSH.Registry
    local lines = R.readLines(MSH.Migration.manifestPath(), 100000)
    if lines == false then return {} end
    local out = {}
    for _, line in ipairs(lines or {}) do
        local f = R.splitTabs(line)
        if f[1] == "skip" and #f >= 5 then out[f[4] .. "\t" .. f[5]] = f[3] end
    end
    F.skips = out
    return out
end

-- 從最後一次有人進去起算；lastVisited 讀不到用建立時間。原版只在名單上的人或屋主站進範圍時刷新 lastVisited（api-sources.md）
local function idleOf(h, now)
    local v = h:getLastVisited()
    if not MSH.isFinite(v) then v = h:getDatetimeCreated() end
    if not MSH.isFinite(v) then return 0 end
    return math.max(0, now - v)
end

-- 全部 foreign，最久沒人進去的在前
function F.rows(now)
    local R, N = MSH.Registry, MSH.Native
    local skips, keys = F.skipped(), pieceKeys()
    local mig = type(R.md) == "table" and R.md.migration or nil
    local waiting = type(mig) == "table" and mig.state == "waiting"
    local out = {}
    for _, e in ipairs(N.index().foreign) do
        local h = e.house
        if not isPiece(keys, e.rect, h) then
            local why = skips[N.rectKey(e.rect) .. "\t" .. R.fileField(e.owner)]
            out[#out + 1] = { rect = MSH.Rect.copy(e.rect), owner = tostring(e.owner), title = tostring(h:getTitle() or ""),
                members = #N.players(h), created = h:getDatetimeCreated(), idleMs = idleOf(h, now),
                origin = why and "skip" or (waiting and "waiting" or "later"), reason = why }
        end
    end
    MSH.sortSafe(out, function(a, b) return a.idleMs > b.idleMs end)
    return out
end

-- 指紋：範圍＋屋主＋原版建立時間三樣都對上的 foreign
function F.find(a)
    local keys = pieceKeys()
    for _, e in ipairs(MSH.Native.index().foreign) do
        if MSH.Rect.equals(e.rect, a.rect) and e.owner == a.owner and e.house:getDatetimeCreated() == a.created
            and not isPiece(keys, e.rect, e.house) then
            return e
        end
    end
    return nil
end

-- 開服前沒有客戶端（Native.sendRemove 同理）；登入時 MetaDataPacket 送的清單已經不含它
function F.sendRemove(a)
    if not S.netUp then return end
    local r = a.rect
    sendServerCommand(MSH.MODULE, "foreignRemove", { x = r.x, y = r.y, w = r.w, h = r.h, owner = a.owner })
end

-- 每分鐘：開服第一輪全部算已知；之後新出現、而且上一輪也在的才算新的
function F.watch()
    local first, known, prev = F.known == nil, F.known or {}, F.prev or {}
    local seen, keep, fresh, keys = {}, {}, 0, pieceKeys()
    for _, h in ipairs(MSH.Native.list()) do
        local owner, rect = h:getOwner(), MSH.Native.rectOf(h)
        if MSH.claimIdOf(owner) == nil and not isPiece(keys, rect, h) then
            local k = MSH.Native.rectKey(rect) .. "|" .. tostring(owner) .. "|" .. stamp(h:getDatetimeCreated())
            seen[k] = true
            if first or known[k] then
                keep[k] = true
            elseif prev[k] then
                keep[k], fresh = true, fresh + 1
            end
        end
    end
    F.known, F.prev = keep, seen
    if fresh > 0 then
        MSH.Audit.write("FOREIGN_APPEARED", { detail = tostring(fresh) })
        MSH.Audit.alertAdmins("FOREIGN_APPEARED", tostring(fresh))
    end
end

S.define("adminForeign", { kind = "query", admin = true, fields = {}, run = function(ctx)
    local rows, days = F.rows(ctx.now), MSH.Settings.get().idleDays
    local stale, list = 0, {}
    for i, r in ipairs(rows) do
        if days > 0 and r.idleMs > days * F.DAY_MS then stale = stale + 1 end
        if i <= F.LIST_MAX then list[i] = r end
    end
    return S.ok({ count = #rows, stale = stale, idleDays = days, list = list, more = math.max(0, #rows - F.LIST_MAX) })
end })

-- owner 用 title 型別：BAD_OWNER 的屋主名本來就不是合法帳號名
S.define("adminForeignRelease", { kind = "mutation", admin = true, whenBlocked = true,
    fields = { rect = "nativeRect", owner = "title", created = "int" },
    run = function(ctx)
        local a = ctx.args
        local e = F.find(a)
        if e == nil then return S.fail(CODE.NOT_FOUND) end
        local title = tostring(e.house:getTitle() or "")
        if not MSH.Native.remove(e.house) then return S.fail(CODE.RELEASE_FAILED) end
        MSH.Audit.write("FOREIGN_RELEASED", { actor = ctx.who, code = a.owner,
            detail = MSH.Native.rectKey(a.rect) .. " " .. title })
        ctx.defer(function() F.sendRemove(a) end)
        return S.ok({ title = title })
    end })

S.hook("minute", "foreign", function() MSH.Foreign.watch() end)
