-- MinidoracatSafehouse/Zones.lua：管理員禁建區（使用者 2026-10-16：「我認為可以增加這項功能，給使用我們 MOD 的人有需要可以使用」）。
-- 起因：原版往軍事基地的必經土路是自然地面，道路判定偵測不到（open-issues.md），玩家在路上圈地就擋住通道。
-- 管理員在遊戲內框出範圍（1–MAX_PIECES 塊、形狀規則同安全屋、外框 ≤ ZONE_SIDE）；建立、重新框選與預檢時任一塊壓到任一
-- 禁建區就回 NO_BUILD { zoneId, zone, areas }（Claims STEPS 的 zones；zone＝名稱，不叫 name：預檢把 detail 攤進檢查項，
-- name 是檢查項的組名；areas＝壓到的部分，扁平 x, y, w, h，客戶端照它標紅）。
-- 存私有目錄的 zones.txt（與 private.txt 同目錄；整份覆寫：刪除要真的拿掉，追加最後一行為準的寫法會讓檔案一直變長）：
--   1<TAB>next<TAB><下一個編號><TAB><禁建區個數>
--   1<TAB>zone<TAB><編號><TAB><x,y,w,h;x,y,w,h…><TAB><名稱>
-- 編號只增不減：刪掉再新增不重用，開著舊清單的管理員刪不到別人新加的那個。
-- 先寫檔、讀回逐行比對過才改記憶體：PrintWriter 吞掉 IOException（LuaManager.java:12823-12840），writeLines 回 true 不代表
-- 寫進去了。新的寫不進去就寫回原本的；原本的也寫不回去＝檔案壞了，標成 Z.unreadable。
-- 檔案只由本 MOD 寫，所以內容對不上（讀到一半出錯、沒有 next 行、有讀不懂的行、zone 行數不等於個數）一律當成讀不開：
-- Z.unreadable，Health 列成 PrivateStore blocker（fail closed：少讀一個禁建區就有人能在那裡建立），新增、刪除回
-- SAVE_FAILED（整份覆寫會蓋掉讀不到的內容）。檔案不存在＝還沒有禁建區。
-- 玩家也看得到禁建區（使用者 2026-10-16「那玩家是不是也應該要可以從畫面上看到禁建區?」；客戶端 Ranges.lua 的 zones 類）：
--   公開查詢 zones（不限管理員、1 秒冷卻）回 { zones = Z.publicView(), rev = Z.rev }，只有編號、名稱、各塊，不含壓到的
--   安全屋（那是管理員面板的 adminZones）。新增、刪除存檔成功後 Z.rev 加一，放鎖後推 zonesSync（同樣的兩欄）給每位在線
--   玩家（getOnlinePlayers LuaManager.java:4457；sendServerCommand(player, ...) :8966-8970；同 Admin.pushSync）。rev 是
--   這次開服內的版本號（開服 0）：查詢回覆與推送沒有順序保證，客戶端只收 rev 不比手上舊的。OnServerStarted 之前不推
--   （S.netUp；那時沒有客戶端，getOnlinePlayers 會 NPE）。

if isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Audit"
require "MinidoracatSafehouse/Registry"
require "MinidoracatSafehouse/Server"

local MSH = MinidoracatSafehouse
local Z = MSH.Zones or {}
MSH.Zones = Z

local S = MSH.Srv
local CODE = MSH.CODE
local LIMIT = MSH.LIMIT
local Rect = MSH.Rect

Z.MAX_AREAS = 64        -- NO_BUILD 回給客戶端標紅的矩形上限（安全屋每塊 × 禁建區每塊壓到的部分）
Z.MAX_LIST_CLAIMS = 20  -- adminZones 每個禁建區最多列幾間壓到它的安全屋
Z.MAX_LINES = 10000

Z.list = Z.list or {}   -- { { id, name, rects } }，照編號由小到大
Z.nextId = Z.nextId or 1
Z.unreadable = Z.unreadable or false
Z.rev = Z.rev or 0     -- 這次開服內禁建區清單的版本，新增、刪除成功各加一

function Z.path()
    return MSH.Registry.privateFile("zones.txt")
end

function Z.any()
    return #Z.list > 0
end

-- 回 nil（合規）或原因：塊數、各塊合法、外框 ≤ ZONE_SIDE、形狀規則（Rect.shapeError：重疊、沒連成一片、洞）
function Z.shapeError(rects)
    local why = Rect.shapeError(rects, LIMIT.MAX_PIECES)
    if why ~= nil then return why end
    local b = Rect.bounds(rects)
    if b.w > LIMIT.ZONE_SIDE or b.h > LIMIT.ZONE_SIDE then return "SIDE" end
    return nil
end

local function int(v) return tostring(math.floor(v)) end

local function rectsText(rects)
    local parts = {}
    for i, r in ipairs(rects) do parts[i] = int(r.x) .. "," .. int(r.y) .. "," .. int(r.w) .. "," .. int(r.h) end
    return table.concat(parts, ";")
end

local function parseRects(text)
    local rects = {}
    for part in string.gmatch(text, "[^;]+") do
        local x, y, w, h = string.match(part, "^(%d+),(%d+),(%d+),(%d+)$")
        if x == nil then return nil end
        rects[#rects + 1] = { x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h) }
    end
    if Z.shapeError(rects) ~= nil then return nil end
    return rects
end

-- 開服讀一次（Server.lua 和 private.txt 一起讀，在首次 Health.evaluate 之前）。先當成讀不開，完整讀完、對得上才解除：
-- 中途出錯（含沒想到的例外）都停在 fail closed
function Z.load()
    Z.list, Z.nextId, Z.unreadable = {}, 1, true
    local R = MSH.Registry
    local lines = R.readLines(Z.path(), Z.MAX_LINES)
    if lines == nil then
        Z.unreadable = false
        return
    end
    if lines == false then
        MSH.log("zone store unreadable: " .. Z.path())
        return
    end
    local list, seen, nextId, declared, bad = {}, {}, 1, nil, 0
    for _, line in ipairs(lines) do
        local f = R.splitTabs(line)
        local ok = false
        if f[1] == "1" and f[2] == "next" and #f == 4 and declared == nil then
            local n, c = tonumber(f[3]), tonumber(f[4])
            if MSH.isInt(n) and n >= 1 and MSH.isInt(c) and c >= 0 then
                if n > nextId then nextId = n end
                declared, ok = c, true
            end
        elseif f[1] == "1" and f[2] == "zone" and #f == 5 then
            local id, rects, name = tonumber(f[3]), parseRects(f[4]), MSH.cleanTitle(f[5])
            if MSH.isInt(id) and id >= 1 and not seen[id] and rects ~= nil and name ~= nil then
                seen[id] = true
                list[#list + 1] = { id = id, name = name, rects = rects }
                if id >= nextId then nextId = id + 1 end
                ok = true
            end
        end
        if not ok then bad = bad + 1 end
    end
    if declared == nil or bad > 0 or declared ~= #list then
        MSH.log("zone store damaged: " .. Z.path() .. " (declared " .. tostring(declared) .. ", read " .. #list
            .. ", bad lines " .. bad .. ")")
        return
    end
    MSH.sortSafe(list, function(a, b) return a.id < b.id end)
    Z.list, Z.nextId, Z.unreadable = list, nextId, false
end

local function fileLines(list, nextId)
    local R = MSH.Registry
    local lines = { table.concat({ "1", "next", int(nextId), int(#list) }, "\t") }
    for _, z in ipairs(list) do
        lines[#lines + 1] = table.concat({ "1", "zone", int(z.id), rectsText(z.rects), R.fileField(z.name) }, "\t")
    end
    return lines
end

-- 檔案現在是不是 lines 這份內容；檔案不存在只在還沒有過任何禁建區時（empty）算對得上：開服讀到的也是「沒有」
local function fileHas(lines, empty)
    local back = MSH.Registry.readLines(Z.path(), Z.MAX_LINES)
    if back == nil then return empty end
    if back == false or #back ~= #lines then return false end
    for i = 1, #lines do
        if back[i] ~= lines[i] then return false end
    end
    return true
end

-- 成功回 true（檔案已是新內容）。沒寫成時檔案要還是原本的內容：開檔就失敗的照舊，截斷了的寫回原本的；
-- 都不行＝檔案壞了，標成讀不開（fail closed）
local function save(list, nextId)
    local R = MSH.Registry
    local new = fileLines(list, nextId)
    if R.writeLines(Z.path(), new, false) and fileHas(new, false) then return true end
    local old, empty = fileLines(Z.list, Z.nextId), Z.nextId == 1
    if fileHas(old, empty) or (R.writeLines(Z.path(), old, false) and fileHas(old, empty)) then return false end
    Z.unreadable = true
    MSH.log("zone store damaged after a failed write: " .. Z.path())
    return false
end

-- 範圍（各塊）壓到禁建區：回 nil 或 NO_BUILD, { zoneId, zone, areas }。zoneId／zone（名稱）是第一個壓到的（照編號），
-- areas 是每個被壓到的部分（相接不算壓到：半開矩形）
function Z.hit(rects)
    local first, areas = nil, nil
    for _, z in ipairs(Z.list) do
        for _, zr in ipairs(z.rects) do
            for _, r in ipairs(rects) do
                if Rect.overlaps(r, zr, 0) then
                    if first == nil then first, areas = z, {} end
                    local n = #areas
                    if n < Z.MAX_AREAS * 4 then
                        local x0, y0 = math.max(r.x, zr.x), math.max(r.y, zr.y)
                        local x1, y1 = math.min(r.x + r.w, zr.x + zr.w), math.min(r.y + r.h, zr.y + zr.h)
                        areas[n + 1], areas[n + 2], areas[n + 3], areas[n + 4] = x0, y0, x1 - x0, y1 - y0
                    end
                end
            end
        end
    end
    if first == nil then return nil end
    return CODE.NO_BUILD, { zoneId = first.id, zone = first.name, areas = areas }
end

local function overlapsZone(rects, z)
    for _, zr in ipairs(z.rects) do
        for _, r in ipairs(rects) do
            if Rect.overlaps(r, zr, 0) then return true end
        end
    end
    return false
end

-- 管理員面板的清單：每個禁建區附上壓到它的安全屋（R.list：放棄以外、有合法範圍的紀錄）。claims 最多 MAX_LIST_CLAIMS 間，
-- claimCount 是全部的間數：面板寫出還有幾間沒列出，不把部分清單當成全部
function Z.view()
    local recs = MSH.Registry.list()
    local out = {}
    for i, z in ipairs(Z.list) do
        local claims, n = {}, 0
        for _, rec in ipairs(recs) do
            if overlapsZone(rec.rects, z) then
                n = n + 1
                if n <= Z.MAX_LIST_CLAIMS then
                    claims[n] = { claimId = rec.claimId, owner = rec.owner, title = rec.title }
                end
            end
        end
        out[i] = { id = z.id, name = z.name, rects = Rect.copyList(z.rects), claims = claims, claimCount = n }
    end
    return out
end

-- 給玩家看的清單：編號、名稱、各塊（複本），不含壓到的安全屋
function Z.publicView()
    local out = {}
    for i, z in ipairs(Z.list) do out[i] = { id = z.id, name = z.name, rects = Rect.copyList(z.rects) } end
    return out
end

-- 推給每位在線玩家（放鎖後由 ctx.defer 呼叫）；開服前不碰連線
function Z.broadcast()
    if not S.netUp then return end
    local args = { zones = Z.publicView(), rev = Z.rev }
    local list = getOnlinePlayers()
    for i = 0, list:size() - 1 do
        sendServerCommand(list:get(i), MSH.MODULE, "zonesSync", args)
    end
end

local function reply(fields)
    fields.zones, fields.max = Z.view(), LIMIT.MAX_ZONES
    return S.ok(fields)
end

S.define("adminZones", { kind = "query", admin = true, fields = {}, run = function()
    return reply({ unreadable = Z.unreadable })
end })

S.define("zones", { kind = "query", cooldownMs = 1000, fields = {}, run = function()
    return S.ok({ zones = Z.publicView(), rev = Z.rev })
end })

S.define("adminAddZone", { kind = "mutation", admin = true, whenBlocked = true,
    fields = { name = "title", rects = "zoneRects" },
    run = function(ctx)
        if Z.unreadable then return S.fail(CODE.SAVE_FAILED) end
        local name = MSH.cleanTitle(ctx.args.name)
        if name == nil then return S.fail(CODE.BAD_TITLE) end
        if #Z.list >= LIMIT.MAX_ZONES then return S.fail(CODE.BAD_ARGS, { reason = "FULL", max = LIMIT.MAX_ZONES }) end
        local rects = Rect.copyList(ctx.args.rects)
        local why = Z.shapeError(rects)
        if why ~= nil then return S.fail(CODE.BAD_SHAPE, { reason = why }) end
        local z = { id = Z.nextId, name = name, rects = rects }
        local list = {}
        for i, e in ipairs(Z.list) do list[i] = e end
        list[#list + 1] = z
        if not save(list, z.id + 1) then return S.fail(CODE.SAVE_FAILED) end
        Z.list, Z.nextId, Z.rev = list, z.id + 1, Z.rev + 1
        ctx.defer(Z.broadcast)
        MSH.Audit.write("ADMIN_ZONE_ADD", { actor = ctx.who, code = int(z.id), detail = name .. " " .. rectsText(rects) })
        return reply({ zoneId = z.id })
    end })

S.define("adminRemoveZone", { kind = "mutation", admin = true, whenBlocked = true,
    fields = { zoneId = "zoneId" },
    run = function(ctx)
        if Z.unreadable then return S.fail(CODE.SAVE_FAILED) end
        local id = ctx.args.zoneId
        local list, gone = {}, nil
        for _, z in ipairs(Z.list) do
            if z.id == id then gone = z else list[#list + 1] = z end
        end
        if gone == nil then return S.fail(CODE.NOT_FOUND, { zoneId = id }) end
        if not save(list, Z.nextId) then return S.fail(CODE.SAVE_FAILED) end
        Z.list, Z.rev = list, Z.rev + 1
        ctx.defer(Z.broadcast)
        MSH.Audit.write("ADMIN_ZONE_REMOVE", { actor = ctx.who, code = int(id), detail = gone.name })
        return reply({ zoneId = id })
    end })
