-- MinidoracatSafehouse/Zones.lua：管理員畫的區域（使用者 2026-10-16：「我認為可以增加這項功能，給使用我們 MOD 的人有需要可以使用」；
-- 道路豁免區 2026-11-25 核准，方案 temp/plan-allowzone-1125/oracle-plan.md）。兩種，存同一張清單、每筆帶 kind：
--   禁建區 nobuild：建立、重新框選與預檢時任一塊壓到就回 NO_BUILD { zoneId, zone, areas }（Claims STEPS 的 zones；zone＝名稱，
--     不叫 name：預檢把 detail 攤進檢查項，name 是檢查項的組名；areas＝壓到的部分，扁平 x, y, w, h，客戶端照它標紅）。
--     起因：原版往軍事基地的必經土路是自然地面，道路判定偵測不到（open-issues.md），玩家在路上圈地就擋住通道。
--   道路豁免區 roadexempt：只豁免道路這一步（Exclusions.roads 的 exempt），範圍是各塊往外擴 RoadMargin：安全屋每一塊都在區內時
--     它要掃的邊界一定落在豁免範圍裡，道路必過；區外的路照擋。豁免格不讀地板（大範圍不會 NOT_LOADED）。禁建區排在道路前面，
--     兩種區重疊時禁建區贏。資源點、重疊、間距照擋。
-- 存私有目錄的 zones.json（與 private.txt 同目錄），管理員可以手改：{ "next": N, "zones": [ {id, kind, name, rects}, … ] }。
--   每筆四欄全必填、未知鍵、重複鍵、重複編號、超過上限一律整檔拒絕（略過一筆禁建區等於那一區開放；JSON 存到一半一定不合法）。
--   名稱與各塊和遊戲內走同一個驗證（MSH.cleanTitle、Z.shapeError）。錯誤碼見 Z.parse。遊戲內寫入整份重寫成一區一行。
-- 手改即時生效：tick 每 WATCH_MS 讀一次、比對整份文字；和採用中的不同且連兩次讀到一樣才解析（擋存到一半的檔）；拒絕過的文字
--   不再解析、不再警示，直到它變。執行中讀到壞檔（或檔案被刪）兩種區都沿用上一份、記 Z.fileError、通知線上管理員一次；
--   開服就壞＝Z.unreadable，Health 列成 ZonesFile blocker（fail closed），修好檔後輪詢採用就解除，不必重開服。
--   adminReloadZones 立即讀檔。通知管理員一律交給 push（ctx.defer 或輪詢），不在鎖裡送網路。
-- 遊戲內新增、刪除先讀磁碟（syncDisk）：和採用中的不同且合規就先採用、再疊上這次修改；磁碟是壞檔回 SAVE_FAILED reason FILE、
--   不覆寫；磁碟沒檔就照記憶體重建。刪除帶選填 rev，不符回 STALE_REVISION：手改後編號可能換到別的區。
-- 先寫檔、讀回比對過才改記憶體：PrintWriter 吞掉 IOException（LuaManager.java:12809-12826），writeLines 回 true 不代表
--   寫進去了。寫之前再讀一次：syncDisk 之後主機又改了檔（不是採用中的也不是沒檔）就不寫，回去採用新版重做一次（最多兩次），
--   不蓋掉主機的修改。寫完讀回不對：讀到的是能解析的第三份（主機剛存的）也回去採用重做；解析不了（我們寫到一半截斷）、
--   讀不開或沒檔才寫回原本的（只會是採用中的那份）；原本的也寫不回去＝檔案壞了，標成 Z.unreadable。
-- 舊的 zones.txt（TSV）：zones.json 不存在時才讀，全部標 nobuild 寫成 JSON、用新的 loader 讀回逐筆比對，對不上 fail closed、
--   錯誤碼 MIGRATE；讀回解析不了或對不上時把 zones.json 改寫成一行說明（Z.MIGRATE_NOTE，不是 JSON）。跨重開的保護靠紀錄檔
--   zones-migration.txt：寫 zones.json 之前先寫 pending（讀回確認），讀回對上才改 done；開服時紀錄不是 done、zones.txt 也在，
--   就把 zones.json 和 zones.txt 逐筆再比一次，一樣才採用（說明行寫不進去時那份對不上的 JSON 不會被採用）。管理員手改後被
--   採用（輪詢、重新載入、寫入前同步）＝照他的意思，紀錄改 done。zones.txt 不動（回滾到舊版還讀得到；副作用是刪掉 zones.json
--   重開服會重新遷移，所以清空要寫 {"zones":[]}）。
-- 編號只增不減：刪掉再新增不重用（Z.nextId 取檔案 next、最大編號＋1 與目前值的最大者）；上限 LIMIT.MAX_ZONE_ID。
-- 玩家也看得到（使用者 2026-10-16「那玩家是不是也應該要可以從畫面上看到禁建區?」；客戶端 Ranges.lua）：
--   公開查詢 zones（不限管理員、1 秒冷卻）回 { zones = Z.publicView(), rev = Z.rev }，只有編號、種類、名稱、各塊，不含壓到的
--   安全屋（那是管理員面板的 adminZones）。清單語意有變（新增、刪除、檔案改了內容）才 Z.rev 加一並推 zonesSync（同樣的兩欄）
--   給每位在線玩家，放鎖後才推（getOnlinePlayers LuaManager.java:4474；sendServerCommand(player, ...) :8902-8906）；只改排版
--   不推。rev 是這次開服內的版本號（開服 0）：查詢回覆與推送沒有順序保證，客戶端只收 rev 不比手上舊的。OnServerStarted 之前
--   不推（S.netUp；那時沒有客戶端，getOnlinePlayers 會 NPE）。

if isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Audit"
require "MinidoracatSafehouse/Registry"
require "MinidoracatSafehouse/Server"
require "MinidoracatSafehouse/Json"

local MSH = MinidoracatSafehouse
local Z = MSH.Zones or {}
MSH.Zones = Z

local S = MSH.Srv
local A = MSH.Audit
local J = MSH.Json
local CODE = MSH.CODE
local LIMIT = MSH.LIMIT
local Rect = MSH.Rect
local KIND = MSH.ZONE_KIND

Z.MAX_AREAS = 64        -- NO_BUILD 回給客戶端標紅的矩形上限（安全屋每塊 × 禁建區每塊壓到的部分）
Z.MAX_LIST_CLAIMS = 20  -- adminZones 每個區域最多列幾間壓到它的安全屋
Z.MAX_LINES = 10000
Z.MAX_CHARS = 1000000  -- 整份文字的字數上限（MOD 自己寫的 100 區約 20 KB）；超過算讀不開
Z.WATCH_MS = 5000       -- 輪詢 zones.json 的間隔；連兩次相同才採用，所以存檔後 5–10 秒生效
Z.AUDIT_IDS = 5         -- ZONES_RELOAD 的 detail 最多列幾個變動的編號
Z.MIGRATE_NOTE = "zones.txt migration failed: the written file did not match. Delete this file and restart the server to retry;"
    .. " zones.txt is unchanged."

-- 磁碟狀態不是文字時的標記（readDisk）：table，不會和任何文字相等
local MISSING, UNREADABLE = { "MISSING" }, { "UNREADABLE" }

Z.list = Z.list or {}   -- { { id, kind, name, rects } }，照編號由小到大
Z.nextId = Z.nextId or 1
Z.unreadable = Z.unreadable or false
Z.rev = Z.rev or 0      -- 這次開服內清單的版本，語意有變各加一
-- Z.text：採用中的那一份在磁碟上的文字（行以 \n 接起來；或 MISSING）；nil＝還沒有任何一份被採用
-- Z.pending：上一輪讀到、還沒採用的文字；Z.rejected：拒絕過的文字（或標記）；Z.fileError：{ code, line?, index?, id?, field?,
-- reason?, max? }
-- Z.appliedAt：採用中的那一份被採用的時間（getTimestampMs）

function Z.path()
    return MSH.Registry.privateFile("zones.json")
end

function Z.legacyPath()
    return MSH.Registry.privateFile("zones.txt")
end

-- 遷移的紀錄（pending／done），和 zones.json 同一個資料夾
function Z.markerPath()
    return MSH.Registry.privateFile("zones-migration.txt")
end

-- 有沒有禁建區（Claims STEPS 的 active：沒有時預檢不列 zones 這一項）；道路豁免區不算
function Z.any()
    for _, z in ipairs(Z.list) do
        if z.kind == KIND.NOBUILD then return true end
    end
    return false
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

-- ===== zones.json 編碼與解析 =====

local function zoneLine(z)
    local parts = {}
    for i, r in ipairs(z.rects) do
        parts[i] = '{"x": ' .. int(r.x) .. ', "y": ' .. int(r.y) .. ', "w": ' .. int(r.w) .. ', "h": ' .. int(r.h) .. "}"
    end
    return '{"id": ' .. int(z.id) .. ', "kind": ' .. J.quote(z.kind) .. ', "name": ' .. J.quote(z.name)
        .. ', "rects": [' .. table.concat(parts, ", ") .. "]}"
end

-- 一區一行
function Z.encode(list, nextId)
    local lines = { "{", '  "next": ' .. int(nextId) .. ",", '  "zones": [' }
    for i, z in ipairs(list) do lines[#lines + 1] = "    " .. zoneLine(z) .. (i < #list and "," or "") end
    lines[#lines + 1] = "  ]"
    lines[#lines + 1] = "}"
    return lines
end

local TOP_KEYS = { next = true, zones = true }
local ZONE_KEYS = { id = true, kind = true, name = true, rects = true }
local RECT_KEYS = { x = true, y = true, w = true, h = true }

local function unknownKey(t, allowed)
    for k in pairs(t) do
        if not allowed[k] then return k end
    end
    return nil
end

-- 回給客戶端的欄位名來自檔案：去控制字元、截到 40 字
local function fieldName(k)
    return string.sub((string.gsub(tostring(k), "%c", "")), 1, 40)
end

local function isObject(v)
    return type(v) == "table" and not J.isArray(v) and v ~= J.NULL
end

-- 回 rects，或 nil, reason，或 nil, nil, 未知鍵
local function parseRects(v)
    if not J.isArray(v) then return nil, "PIECES" end
    local rects = {}
    for i, r in ipairs(v) do
        if not isObject(r) then return nil, "PIECES" end
        local bad = unknownKey(r, RECT_KEYS)
        if bad ~= nil then return nil, nil, bad end
        rects[i] = { x = r.x, y = r.y, w = r.w, h = r.h }
    end
    local why = Z.shapeError(rects)
    if why ~= nil then return nil, why end
    return rects
end

-- 文字（或 MISSING／UNREADABLE）→ list, nextId；不合規回 nil, err（err.code：JSON line?、NO_ZONES、TOO_MANY max、
-- BAD_ID／DUP_ID index id、BAD_KIND／BAD_NAME index、BAD_RECTS index reason、UNKNOWN_FIELD index? field、UNREADABLE、MISSING、
-- MIGRATE（遷移失敗留下的說明））
function Z.parse(text)
    if text == MISSING then return nil, { code = "MISSING" } end
    if type(text) ~= "string" then return nil, { code = "UNREADABLE" } end
    if text == Z.MIGRATE_NOTE then return nil, { code = "MIGRATE" } end
    -- 解碼器的例外（沒想到的輸入）也當成壞檔：不然逃出 take，Z.pending 留著每輪重試、開服時沒有 fileError
    local okDecode, doc, jerr = pcall(J.decode, text)
    if not okDecode then
        MSH.log("zones.json decode error: " .. tostring(doc))
        return nil, { code = "JSON" }
    end
    if doc == nil then return nil, { code = "JSON", line = jerr.line } end
    if not isObject(doc) or not J.isArray(doc.zones) then return nil, { code = "NO_ZONES" } end
    local top = unknownKey(doc, TOP_KEYS)
    if top ~= nil then return nil, { code = "UNKNOWN_FIELD", field = fieldName(top) } end
    local zs = doc.zones
    if #zs > LIMIT.MAX_ZONES then return nil, { code = "TOO_MANY", max = LIMIT.MAX_ZONES } end
    local list, seen, nextId = {}, {}, 1
    for i, e in ipairs(zs) do
        if not isObject(e) then return nil, { code = "BAD_ID", index = i } end
        local bad = unknownKey(e, ZONE_KEYS)
        if bad ~= nil then return nil, { code = "UNKNOWN_FIELD", index = i, field = fieldName(bad) } end
        local id = e.id
        if not (MSH.isInt(id) and id >= 1 and id <= LIMIT.MAX_ZONE_ID) then
            return nil, { code = "BAD_ID", index = i, id = MSH.isFinite(id) and id or nil }
        end
        if seen[id] then return nil, { code = "DUP_ID", index = i, id = id } end
        if e.kind ~= KIND.NOBUILD and e.kind ~= KIND.ROADEXEMPT then return nil, { code = "BAD_KIND", index = i } end
        local name = MSH.cleanTitle(e.name)
        if name == nil then return nil, { code = "BAD_NAME", index = i } end
        local rects, why, field = parseRects(e.rects)
        if field ~= nil then return nil, { code = "UNKNOWN_FIELD", index = i, field = fieldName(field) } end
        if rects == nil then return nil, { code = "BAD_RECTS", index = i, reason = why } end
        seen[id] = true
        list[#list + 1] = { id = id, kind = e.kind, name = name, rects = rects }
        if id >= nextId then nextId = id + 1 end
    end
    -- next 寫錯（不是正整數，或超過上限＋1）當成沒寫：取最大編號＋1 一樣不會撞號
    if MSH.isInt(doc.next) and doc.next > nextId and doc.next <= LIMIT.MAX_ZONE_ID + 1 then nextId = doc.next end
    MSH.sortSafe(list, function(a, b) return a.id < b.id end)
    return list, nextId
end

-- 磁碟上的整份文字（行以 \n 接起來，CRLF／LF 一樣）；不存在回 MISSING，讀不開、超過 MAX_LINES 行或 MAX_CHARS 字回 UNREADABLE
-- （字數超過時 readLines 當場停止讀）
local function readDisk()
    local lines = MSH.Registry.readLines(Z.path(), Z.MAX_LINES + 1, Z.MAX_CHARS)
    if lines == nil then return MISSING end
    if lines == false or #lines > Z.MAX_LINES then return UNREADABLE end
    return table.concat(lines, "\n")
end

local function splitLines(text)
    local out = {}
    for line in string.gmatch(text .. "\n", "(.-)\n") do out[#out + 1] = line end
    return out
end

-- 遷移紀錄的那一行；沒檔回 nil，讀不開或不是一行回 false
local function markerLine()
    local lines = MSH.Registry.readLines(Z.markerPath(), 2)
    if type(lines) ~= "table" then return lines end
    if #lines ~= 1 then return false end
    return lines[1]
end

-- 寫紀錄並讀回確認
local function writeMarker(state)
    return MSH.Registry.writeLines(Z.markerPath(), { state }, false) and markerLine() == state
end

local function sameZone(a, b)
    if a.id ~= b.id or a.kind ~= b.kind or a.name ~= b.name or #a.rects ~= #b.rects then return false end
    for i, r in ipairs(a.rects) do
        if not Rect.equals(r, b.rects[i]) then return false end
    end
    return true
end

-- 新舊清單比對：{ added, removed, changed, ids（變動的編號，最多 AUDIT_IDS 個） }
local function diff(old, new)
    local byId, kept = {}, {}
    for _, z in ipairs(old) do byId[z.id] = z end
    local d = { added = 0, removed = 0, changed = 0, ids = {} }
    local function note(id)
        if #d.ids < Z.AUDIT_IDS then d.ids[#d.ids + 1] = int(id) end
    end
    for _, z in ipairs(new) do
        local o = byId[z.id]
        kept[z.id] = true
        if o == nil then
            d.added = d.added + 1
            note(z.id)
        elseif not sameZone(o, z) then
            d.changed = d.changed + 1
            note(z.id)
        end
    end
    for _, z in ipairs(old) do
        if not kept[z.id] then
            d.removed = d.removed + 1
            note(z.id)
        end
    end
    return d
end

local function errWhere(err)
    if err.line ~= nil then return err.code .. "," .. int(err.line) end
    return err.code
end

local function errDetail(err)
    local parts = {}
    for _, k in ipairs({ "line", "index", "id", "field", "reason", "max" }) do
        if err[k] ~= nil then parts[#parts + 1] = k .. "=" .. tostring(err[k]) end
    end
    return table.concat(parts, " ")
end

-- 讀到和採用中的不同的磁碟內容 text：合規就採用（語意有變才 rev＋1），不合規記錯誤沿用上一份。推送與通知都交給 push
-- （ctx.defer：放鎖後才送）。新的壞檔、套用或解除錯誤各通知線上管理員一次。回 true（採用了）或 false
local function take(text, actor, push)
    local list, nextId = Z.parse(text)
    if list == nil then
        local err = nextId
        local fresh = text ~= Z.rejected
        Z.fileError, Z.rejected, Z.pending = err, text, nil
        if fresh then
            MSH.log("zones.json rejected (" .. errWhere(err) .. "), keeping the zones in use: " .. Z.path())
            A.write("ZONES_FILE", { actor = actor, code = err.code, detail = errDetail(err) })
            -- 開服就讀不開之後檔案被刪：沒有上一份可沿用，不送「沿用上一份」的 MISSING 通知（Health 的 ZonesFile 照舊顯示）
            if not (Z.unreadable and err.code == "MISSING") then
                push(function() A.alertAdmins("ZONES_FILE", errWhere(err)) end)
            end
        end
        return false
    end
    local hadError = Z.fileError ~= nil or Z.unreadable
    local d = diff(Z.list, list)
    local changed = d.added + d.removed + d.changed > 0
    Z.list, Z.nextId, Z.text, Z.unreadable = list, math.max(nextId, Z.nextId), text, false
    Z.fileError, Z.rejected, Z.pending, Z.appliedAt = nil, nil, nil, getTimestampMs()
    -- 遷移紀錄還不是 done：這是管理員手改之後的採用，照他的意思完成遷移（寫不進去只記 log：下次開服再比對 zones.txt）
    local m = markerLine()
    if m ~= nil and m ~= "done" and not writeMarker("done") then
        MSH.log("zones: could not mark the migration done: " .. Z.markerPath())
    end
    if changed then
        Z.rev = Z.rev + 1
        push(Z.broadcast)
    end
    if changed or hadError then
        local counts = int(d.added) .. "," .. int(d.removed) .. "," .. int(d.changed)
        MSH.log("zones.json applied (added,removed,changed " .. counts .. "; " .. #list .. " zones)")
        A.write("ZONES_RELOAD", { actor = actor, code = int(#list), detail = "added=" .. d.added .. " removed=" .. d.removed
            .. " changed=" .. d.changed .. " ids=" .. table.concat(d.ids, ",") })
        push(function() A.alertAdmins("ZONES_RELOADED", counts) end)
    end
    return true
end

local function now(fn) fn() end

-- 輪詢（tick hook）：每 WATCH_MS 讀一次；拿著鎖時這一輪跳過
function Z.watch(t)
    if S.locked then return end
    -- 時鐘往回撥（t < lastWatch）不節流，不然要等到時鐘追回來才會再讀（家族 pitfalls.md:128）
    if Z.lastWatch ~= nil and t >= Z.lastWatch and t - Z.lastWatch < Z.WATCH_MS then return end
    Z.lastWatch = t
    local text = readDisk()
    if text == Z.text then
        Z.pending = nil
        -- 改回採用中的那一份：錯誤解除
        if Z.fileError ~= nil then
            Z.fileError, Z.rejected = nil, nil
            A.alertAdmins("ZONES_RELOADED", "0,0,0")
        end
        return
    end
    if text == Z.rejected then
        Z.pending = nil
        return
    end
    if text ~= Z.pending then
        Z.pending = text
        return
    end
    take(text, "file", now)
end

-- 遊戲內寫入前：回 true 可以寫（磁碟和採用中的相同、剛採用了磁碟上的新版，或磁碟沒檔）；磁碟讀不開、不合規或是拒絕過的
-- 內容回 false（拒絕過的不再解析：遷移讀回對不上的那份是合法 JSON，不能在這裡被採用）
local function syncDisk(ctx)
    local text = readDisk()
    if text == Z.text or text == MISSING then return true end
    if text == Z.rejected then return false end
    return take(text, ctx.who, ctx.defer)
end

-- 回 "OK"（檔案已是新內容）、"CHANGED"（磁碟又變了、沒寫：呼叫端 syncDisk 後重做）或 "FAILED"。沒寫成時檔案要還是原本的
-- 內容：開檔就失敗的照舊；讀回是完整的 JSON（主機剛存的第三份，合不合規都算；不合規的由 syncDisk 記成檔案錯誤）不動它、
-- 回 CHANGED；截斷（不是 JSON）、讀不開或沒檔才寫回原本的（原本沒檔就寫記憶體的清單）；都不行＝檔案壞了，標成讀不開（fail closed）
local function save(list, nextId)
    local R = MSH.Registry
    local before = readDisk()
    -- 只有採用中的那份或沒檔才寫：寫回原本的內容時，原本的一定是已採用的
    if before ~= Z.text and before ~= MISSING then return "CHANGED" end
    local lines = Z.encode(list, nextId)
    local text = table.concat(lines, "\n")
    R.writeLines(Z.path(), lines, false)
    local back = readDisk()
    if back == text then
        Z.text, Z.fileError, Z.rejected, Z.pending, Z.appliedAt = text, nil, nil, nil, getTimestampMs()
        return "OK"
    end
    if back == before then return "FAILED" end
    -- 自己寫一半的檔不會是完整的 JSON（結尾的 ]} 在最後一行），所以能解碼的一定是別人存的
    if type(back) == "string" then
        local okJson, value = pcall(J.decode, back)
        if okJson and value ~= nil then return "CHANGED" end
    end
    local old = before
    if old == MISSING then old = table.concat(Z.encode(Z.list, Z.nextId), "\n") end
    if R.writeLines(Z.path(), splitLines(old), false) and readDisk() == old then
        Z.text = old
        return "FAILED"
    end
    Z.unreadable, Z.text = true, nil
    MSH.log("zone store damaged after a failed write: " .. Z.path())
    return "FAILED"
end

-- ===== 舊 zones.txt（唯讀，只給遷移用）=====
--   1<TAB>next<TAB><下一個編號><TAB><禁建區個數>
--   1<TAB>zone<TAB><編號><TAB><x,y,w,h;x,y,w,h…><TAB><名稱>
-- 內容對不上（讀到一半出錯、沒有 next 行、有讀不懂的行、zone 行數不等於個數）回 nil

local function legacyRects(text)
    local rects = {}
    for part in string.gmatch(text, "[^;]+") do
        local x, y, w, h = string.match(part, "^(%d+),(%d+),(%d+),(%d+)$")
        if x == nil then return nil end
        rects[#rects + 1] = { x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h) }
    end
    if Z.shapeError(rects) ~= nil then return nil end
    return rects
end

local function legacyLoad()
    local R = MSH.Registry
    local lines = R.readLines(Z.legacyPath(), Z.MAX_LINES)
    if not lines then return nil end
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
            local id, rects, name = tonumber(f[3]), legacyRects(f[4]), MSH.cleanTitle(f[5])
            if MSH.isInt(id) and id >= 1 and not seen[id] and rects ~= nil and name ~= nil then
                seen[id] = true
                list[#list + 1] = { id = id, kind = KIND.NOBUILD, name = name, rects = rects }
                if id >= nextId then nextId = id + 1 end
                ok = true
            end
        end
        if not ok then bad = bad + 1 end
    end
    if declared == nil or bad > 0 or declared ~= #list then
        MSH.log("zones.txt damaged: " .. Z.legacyPath() .. " (declared " .. tostring(declared) .. ", read " .. #list
            .. ", bad lines " .. bad .. ")")
        return nil
    end
    MSH.sortSafe(list, function(a, b) return a.id < b.id end)
    return list, nextId
end

-- 遷移失敗：fail closed（Z.unreadable 留著），錯誤碼一律 MIGRATE、原因寫進 log 與稽核；rejected＝磁碟現在的內容，管理員改了
-- zones.json 輪詢才會再讀
local function migrateFailed(why)
    Z.fileError, Z.rejected = { code = "MIGRATE" }, readDisk()
    MSH.log("zones: migrating zones.txt failed (" .. why .. "); zone checks paused, zones.txt kept: " .. Z.legacyPath())
    A.write("ZONES_FILE", { actor = "file", code = "MIGRATE", detail = why })
end

-- zones.json 的文字和 zones.txt 的清單逐筆相同：回 list, nextId；不然 nil, 原因
local function matchLegacy(text, legacy)
    local list, got = Z.parse(text)
    if list == nil then return nil, "zones.json " .. errWhere(got) end
    local same = #list == #legacy
    for i = 1, #legacy do
        same = same and sameZone(list[i], legacy[i])
    end
    if not same then return nil, "zones.json differs from zones.txt" end
    return list, got
end

local function adoptMigrated(list, nextId, text, how)
    Z.list, Z.nextId, Z.unreadable, Z.text, Z.appliedAt = list, nextId, false, text, getTimestampMs()
    A.write("ZONES_MIGRATED", { actor = "file", code = int(#list), detail = Z.legacyPath() .. " -> " .. Z.path() })
    MSH.log("zones: migrated " .. #list .. " zones (" .. how .. "); zones.txt kept")
end

local function migrate()
    local legacy, nextId = legacyLoad()
    if legacy == nil then return migrateFailed("zones.txt unreadable or damaged") end
    MSH.log("zones: zones.json not found, migrating zones.txt (" .. #legacy .. " zones)")
    if #legacy > LIMIT.MAX_ZONES then return migrateFailed("too many zones (" .. #legacy .. ")") end
    -- 先記 pending：寫不進去就不動 zones.json（下次開服還是沒檔、再遷一次）
    if not writeMarker("pending") then return migrateFailed("could not write " .. Z.markerPath()) end
    MSH.Registry.writeLines(Z.path(), Z.encode(legacy, nextId), false)
    local back = readDisk()
    local list, got = matchLegacy(back, legacy)
    if list == nil then
        -- 解析不了（截斷：補上括號就會採用少一截的清單）或對不上：改寫成說明（不是 JSON）；寫不進去由紀錄的 pending 擋下次開服
        MSH.Registry.writeLines(Z.path(), { Z.MIGRATE_NOTE }, false)
        return migrateFailed("read back: " .. got)
    end
    -- 改 done 寫不進去：這次 fail closed；zones.json 內容是對的，下次開服比對 zones.txt 相同就自動完成
    if not writeMarker("done") then return migrateFailed("could not mark the migration done: " .. Z.markerPath()) end
    adoptMigrated(list, math.max(got, nextId), back, "read back OK")
end

-- 開服讀一次（Server.lua 和 private.txt 一起讀，在首次 Health.evaluate 之前）。先當成讀不開，讀到合規的才解除：
-- 中途出錯（含沒想到的例外）都停在 fail closed
function Z.load()
    Z.list, Z.nextId, Z.unreadable = {}, 1, true
    Z.text, Z.pending, Z.rejected, Z.fileError, Z.appliedAt = nil, nil, nil, nil, nil
    Z.lastWatch = getTimestampMs()
    local text = readDisk()
    local hasLegacy = MSH.Registry.readLines(Z.legacyPath(), 1) ~= nil
    if text == MISSING then
        if hasLegacy then return migrate() end
        -- 兩檔都沒有：空清單，寫一份空範本給管理員照著改；寫不成只記 log
        Z.unreadable, Z.text = false, MISSING
        local lines = Z.encode({}, 1)
        if MSH.Registry.writeLines(Z.path(), lines, false) and readDisk() == table.concat(lines, "\n") then
            Z.text, Z.appliedAt = table.concat(lines, "\n"), getTimestampMs()
        else
            MSH.log("zones: could not write an empty zones.json: " .. Z.path())
        end
        return
    end
    -- 上次遷移沒完成（紀錄存在卻不是 done）：zones.json 要和 zones.txt 逐筆相同才採用
    local m = markerLine()
    if hasLegacy and m ~= nil and m ~= "done" then
        local legacy, legacyNext = legacyLoad()
        if legacy == nil then return migrateFailed("zones.txt unreadable or damaged") end
        local list, got = matchLegacy(text, legacy)
        if list == nil then return migrateFailed("unfinished migration: " .. got) end
        if not writeMarker("done") then return migrateFailed("could not mark the migration done: " .. Z.markerPath()) end
        return adoptMigrated(list, math.max(got, legacyNext), text, "finished an earlier migration")
    end
    local list, nextId = Z.parse(text)
    if list == nil then
        Z.fileError, Z.rejected = nextId, text
        MSH.log("zone store unreadable (" .. errWhere(nextId) .. "); zone checks paused until zones.json is fixed: " .. Z.path())
        A.write("ZONES_FILE", { actor = "file", code = nextId.code, detail = errDetail(nextId) })
        return
    end
    Z.list, Z.nextId, Z.unreadable, Z.text, Z.appliedAt = list, nextId, false, text, getTimestampMs()
end

-- ===== 判定 =====

-- 範圍（各塊）壓到禁建區（只看 nobuild）：回 nil 或 NO_BUILD, { zoneId, zone, areas }。zoneId／zone（名稱）是第一個壓到的
-- （照編號），areas 是每個被壓到的部分（相接不算壓到：半開矩形）
function Z.hit(rects)
    local first, areas = nil, nil
    for _, z in ipairs(Z.list) do
        if z.kind == KIND.NOBUILD then
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
    end
    if first == nil then return nil end
    return CODE.NO_BUILD, { zoneId = first.id, zone = first.name, areas = areas }
end

-- 道路豁免（Claims.checkRoads → Exclusions.roads 的 exempt）：道路豁免區（只看 roadexempt）每塊往外擴 margin 的盒，只回和道路
-- 掃描範圍（rects 各塊往外擴 margin）相交的（最壞 100 區 × 8 塊，不逐格全比）。扁平 x0, y0, x1, y1（半開，Exclusions inAny
-- 的格式）；一個都沒有回 nil
function Z.exemptBoxes(rects, margin)
    local scans = {}
    for i, r in ipairs(rects) do scans[i] = Rect.expand(r, margin) end
    local out = nil
    for _, z in ipairs(Z.list) do
        if z.kind == KIND.ROADEXEMPT then
            for _, zr in ipairs(z.rects) do
                local b = Rect.expand(zr, margin)
                for _, s in ipairs(scans) do
                    if Rect.overlaps(s, b, 0) then
                        out = out or {}
                        local n = #out
                        out[n + 1], out[n + 2], out[n + 3], out[n + 4] = b.x, b.y, b.x + b.w, b.y + b.h
                        break
                    end
                end
            end
        end
    end
    return out
end

local function overlapsZone(rects, z)
    for _, zr in ipairs(z.rects) do
        for _, r in ipairs(rects) do
            if Rect.overlaps(r, zr, 0) then return true end
        end
    end
    return false
end

-- 管理員面板的清單：每個區域附上壓到它的安全屋（R.list：放棄以外、有合法範圍的紀錄）。claims 最多 MAX_LIST_CLAIMS 間，
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
        out[i] = { id = z.id, kind = z.kind, name = z.name, rects = Rect.copyList(z.rects), claims = claims, claimCount = n }
    end
    return out
end

-- 給玩家看的清單：編號、種類、名稱、各塊（複本），不含壓到的安全屋與檔案狀態
function Z.publicView()
    local out = {}
    for i, z in ipairs(Z.list) do out[i] = { id = z.id, kind = z.kind, name = z.name, rects = Rect.copyList(z.rects) } end
    return out
end

-- 推給每位在線玩家（放鎖後由 ctx.defer 或輪詢呼叫）；開服前不碰連線
function Z.broadcast()
    if not S.netUp then return end
    local args = { zones = Z.publicView(), rev = Z.rev }
    local list = getOnlinePlayers()
    for i = 0, list:size() - 1 do
        sendServerCommand(list:get(i), MSH.MODULE, "zonesSync", args)
    end
end

-- 管理員回覆共用的欄位（adminZones 同形）：清單、上限、讀不開、版本、檔案狀態
local function listFields(fields)
    fields.zones, fields.max, fields.unreadable, fields.rev = Z.view(), LIMIT.MAX_ZONES, Z.unreadable, Z.rev
    fields.file = { path = Z.path(), appliedAt = Z.appliedAt, error = Z.fileError }
    return fields
end

local function reply(fields)
    return S.ok(listFields(fields))
end

S.hook("tick", "zonesWatch", function(t) MSH.Zones.watch(t) end)

S.define("adminZones", { kind = "query", admin = true, fields = {}, run = function()
    return reply({})
end })

S.define("zones", { kind = "query", cooldownMs = 1000, fields = {}, run = function()
    return S.ok({ zones = Z.publicView(), rev = Z.rev })
end })

-- 〔重新載入〕：立即讀檔（不等連兩次相同）；壞檔照樣回 ok，錯誤在 file.error。拒絕過的內容不再採用（遷移讀回對不上的那份）
S.define("adminReloadZones", { kind = "mutation", admin = true, whenBlocked = true, fields = {}, run = function(ctx)
    local text = readDisk()
    if text ~= Z.text then
        if text ~= Z.rejected then take(text, ctx.who, ctx.defer) end
    elseif Z.fileError ~= nil then
        Z.fileError, Z.rejected, Z.pending = nil, nil, nil
        ctx.defer(function() A.alertAdmins("ZONES_RELOADED", "0,0,0") end)
    end
    return reply({})
end })

-- 新增、刪除共用：syncDisk → work（照目前清單檢查，回 list, nextId 或 nil, 失敗回覆）→ save；寫之前磁碟又變了就重做一次
local function mutate(ctx, work)
    for _ = 1, 2 do
        if not syncDisk(ctx) or Z.unreadable then return nil, S.fail(CODE.SAVE_FAILED, { reason = "FILE" }) end
        local list, nextId = work()
        if list == nil then return nil, nextId end
        local r = save(list, nextId)
        if r == "OK" then
            Z.list, Z.nextId, Z.rev = list, nextId, Z.rev + 1
            ctx.defer(Z.broadcast)
            return true
        end
        if r == "FAILED" then return nil, S.fail(CODE.SAVE_FAILED) end
    end
    return nil, S.fail(CODE.SAVE_FAILED)
end

S.define("adminAddZone", { kind = "mutation", admin = true, whenBlocked = true,
    fields = { name = "title", rects = "zoneRects", kind = "zoneKind?" },
    run = function(ctx)
        local z
        local ok, res = mutate(ctx, function()
            local name = MSH.cleanTitle(ctx.args.name)
            if name == nil then return nil, S.fail(CODE.BAD_TITLE) end
            if #Z.list >= LIMIT.MAX_ZONES then return nil, S.fail(CODE.BAD_ARGS, { reason = "FULL", max = LIMIT.MAX_ZONES }) end
            if Z.nextId > LIMIT.MAX_ZONE_ID then return nil, S.fail(CODE.BAD_ARGS, { reason = "ID_RANGE" }) end
            local rects = Rect.copyList(ctx.args.rects)
            local why = Z.shapeError(rects)
            if why ~= nil then return nil, S.fail(CODE.BAD_SHAPE, { reason = why }) end
            z = { id = Z.nextId, kind = ctx.args.kind or KIND.NOBUILD, name = name, rects = rects }
            local list = {}
            for i, e in ipairs(Z.list) do list[i] = e end
            list[#list + 1] = z
            return list, z.id + 1
        end)
        if not ok then return res end
        A.write("ADMIN_ZONE_ADD", { actor = ctx.who, code = int(z.id), detail = z.kind .. " " .. z.name .. " " .. Rect.listKey(z.rects) })
        return reply({ zoneId = z.id })
    end })

S.define("adminRemoveZone", { kind = "mutation", admin = true, whenBlocked = true,
    fields = { zoneId = "zoneId", rev = "revision?" },
    run = function(ctx)
        local id, gone = ctx.args.zoneId, nil
        local ok, res = mutate(ctx, function()
            if ctx.args.rev ~= nil and ctx.args.rev ~= Z.rev then
                return nil, S.fail(CODE.STALE_REVISION, listFields({ zoneId = id }))
            end
            local list = {}
            gone = nil
            for _, z in ipairs(Z.list) do
                if z.id == id then gone = z else list[#list + 1] = z end
            end
            if gone == nil then return nil, S.fail(CODE.NOT_FOUND, { zoneId = id }) end
            return list, Z.nextId
        end)
        if not ok then return res end
        A.write("ADMIN_ZONE_REMOVE", { actor = ctx.who, code = int(id), detail = gone.kind .. " " .. gone.name })
        return reply({ zoneId = id })
    end })
