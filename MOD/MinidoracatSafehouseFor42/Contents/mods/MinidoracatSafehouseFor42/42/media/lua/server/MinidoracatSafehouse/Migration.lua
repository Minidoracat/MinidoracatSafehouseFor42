-- MinidoracatSafehouse/Migration.lua：Better Safehouse 遷移（計畫 §9 第 4、5、7–12 點）。
-- 三次開服：
--   1. 第一次開服（registry 全新、存檔裡有 foreign 原生）：唯讀掃描、寫 candidate report（migration-candidates.txt）、
--      migrationCompleted=false 拒絕所有 client mutation；operator 審核後放 selection manifest（migration-selection.txt）。
--   2. 下一次開服：selection 的快照指紋與每筆 identity hash 全部對得上才照 allow 匯入（importLegacy），寫 completion manifest；
--      對不上整批不匯入、重寫 report、等 operator 重審。
--   3. 再下一次開服：verify 核對這一代的 completion manifest：每個 allow hash 都有紀錄才 migrationCompleted=true；
--      還沒匯入的（寫檔失敗、匯入中途丟錯）留在遷移中，同一次開服只補匯入這些 hash，再下一次開服核對。
-- 沒有 foreign 原生的全新伺服器、或 registry 已經有紀錄的伺服器，第一次檢查就記成不遷移，之後永不進入遷移。
-- 快照綁定與 §9 第 4 點的差異：Lua 讀不到 map_meta.bin 的大小與修改時間（getFileReader 只開 Lua cache 目錄，LuaManager.java:5936），
--   改用「原生總筆數＋全部候選 identity hash 的摘要」；候選的 rect／owner／title／成員任一變動都會讓指紋不同。
-- completion manifest：與私有檔同目錄的 migration-completion.txt，append-only（伺服器私有檔，可放名字與座標）：
--   `want<TAB>代號<TAB>hash<TAB>x,y,w,h<TAB>owner<TAB>成員<TAB>title`：這一代要匯入的 allow 項（匯入前先寫，補匯入照它）；
--   `hash<TAB>claimId<TAB>代號`：匯入一筆（先寫檔、成功才改 registry 與原生，照 Registry 私有檔的 write-then-update）。
-- 代號（與 §9 第 9 點「registry generation」的差異）：registry 的 generation 計數器會跟著崩潰一起回滾、之後再長回同一個值，
--   分不出「回滾掉的那次」與「這次」；改用匯入當下的「毫秒時間-nextClaimId」，與 want 行同時寫進 registry 的 md.migrationGen。
--   verify 只看代號等於 md.migrationGen 的行：崩潰回滾掉的嘗試、同伺服器名的別的世界留下的舊檔一律忽略（只用來抬 nextClaimId）。
--   同一代裡一個 hash 有存活紀錄就不再匯入（open-issues 第 19 條）；換一代（回滾後重匯）從頭來。
-- 檔案存在不等於完成：匯入後的開服逐筆核對，全部吻合才寫 migrationCompleted=true；
--   之後只看這個旗標，legacy claim 的正常 release／GC 不再被當成缺件（§9 第 9 點）。
-- md.migration（Global ModData，公開）只放階段、筆數與結果碼；名字與座標只寫進伺服器本機的檔案（§9 第 11 點）。
-- 字串字面值只用 ASCII：Kahlua 把非 ASCII 字面值截成單 byte（sh-mig-1011a 實踩）。
-- 出處：反編譯 D:/github/pz-decompiled-reference/snapshots/42.21.0-20260928/pz/zombie/（下稱 SafeHouse.java＝iso/areas/SafeHouse.java、
--   LuaManager.java＝Lua/LuaManager.java）。

if isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Audit"
require "MinidoracatSafehouse/Registry"
require "MinidoracatSafehouse/Native"
require "MinidoracatSafehouse/Server"

local MSH = MinidoracatSafehouse
local M = MSH.Migration or {}
MSH.Migration = M

local LC = MSH.LIFECYCLE

-- 與 R.privatePath() 同目錄（<cachedir>/Lua/MinidoracatSafehouse/<server>/）；.txt 在 getFileWriter 允許的副檔名內（LuaManager.java:1035）
local function sibling(name)
    return (string.gsub(MSH.Registry.privatePath(), "private%.txt$", name))
end
function M.manifestPath() return sibling("migration-completion.txt") end
function M.reportPath() return sibling("migration-candidates.txt") end
function M.selectionPath() return sibling("migration-selection.txt") end

-- getFileWriter(path, createIfNull, append)：LuaManager.java:6727（UTF-8）；writeln：LuaManager.java:12834
local function writeLines(path, lines, append)
    local writer
    local opened = pcall(function() writer = getFileWriter(path, true, append) end)
    if not opened or writer == nil then return false end
    local written = pcall(function()
        for _, line in ipairs(lines) do writer:writeln(line) end
    end)
    local closed = pcall(function() writer:close() end)
    return written and closed
end

local function appendLine(line)
    return writeLines(M.manifestPath(), { line }, true)
end

-- 檔案欄位不能含 tab／換行（manifest 以 tab、selection 以空白切欄）
local function field(v)
    return (string.gsub(tostring(v), "%c", " "))
end

-- 一行切成欄位（tab 分隔、保留空欄）
local function split(line)
    local out, pos = {}, 1
    while true do
        local s = string.find(line, "\t", pos, true)
        if s == nil then
            out[#out + 1] = string.sub(line, pos)
            return out
        end
        out[#out + 1] = string.sub(line, pos, s - 1)
        pos = s + 1
    end
end

-- 這一代的代號：「毫秒時間-nextClaimId」。崩潰回滾後 verify 先把 nextClaimId 抬過舊行的 id，所以不會撞到回滾掉的那一代
local function newGen(now)
    return tostring(math.floor(now or getTimestampMs())) .. "-" .. tostring(MSH.Registry.md.nextClaimId)
end

-- 遷移中沿用 md.migrationGen；沒有代號或上一次遷移已完成就開新的一代
local function currentGen(now)
    local md = MSH.Registry.md
    if md.migrationGen == nil or md.migrationCompleted == true then md.migrationGen = newGen(now) end
    return md.migrationGen
end

local function importLine(hash, id, gen)
    return hash .. "\t" .. tostring(id) .. "\t" .. gen
end

-- 回傳行陣列；檔案不存在回 nil；存在卻讀不開回 false（fail closed）
local function readLines(path)
    local reader
    -- getFileReader 吞掉 IOException 回 nil（LuaManager.java:5936；UTF-8）；用 cacheFileExists（LuaManager.java:5544）分辨不存在與讀不開
    local opened = pcall(function() reader = getFileReader(path, false) end)
    if not opened or reader == nil then
        local ok, exists = pcall(cacheFileExists, path)
        if ok and not exists then return nil end
        return false
    end
    local lines = {}
    while #lines < 100000 do
        local line = reader:readLine()
        if line == nil then break end
        lines[#lines + 1] = line
    end
    pcall(function() reader:close() end)
    return lines
end

local function validItem(it)
    return type(it) == "table" and MSH.Rect.valid(it.rect) and MSH.validUsername(it.owner)
        and type(it.title) == "string" and type(it.members) == "table"
        and type(it.hash) == "string" and #it.hash <= 128 and string.find(it.hash, "^[%w%-_]+$") ~= nil
end

-- 舊成員轉 grants（MEMBER＋USE＋MOVE＋BUILD＋FARM，等同原版成員；respawn flags 不保存，§4.4）
local function legacyGrants(it)
    local out, seen = {}, { [it.owner] = true }
    for _, u in ipairs(it.members) do
        if MSH.validUsername(u) and not seen[u] then
            seen[u] = true
            out[#out + 1] = { user = u, bits = MSH.SHARE_LEGACY }
        end
    end
    return out
end

-- items = { { rect = {x,y,w,h}, owner, title, members = {..}, hash } }；呼叫端持全域鎖，網路送出經 defer。
-- 回傳 { imported = { { hash, claimId } }, skipped = { { index, hash, reason } } }。
-- 冪等：同 rect 已經是標記 owner 的原生（先前匯入過）略過，不重複建紀錄。
function M.importLegacy(items, now, defer)
    local gen = nil
    local N, R = MSH.Native, MSH.Registry
    local out = { imported = {}, skipped = {} }
    local function skip(i, it, reason)
        out.skipped[#out.skipped + 1] = { index = i, hash = type(it) == "table" and it.hash or nil, reason = reason }
    end
    if not R.ready() then
        for i, it in ipairs(items) do skip(i, it, "NOT_READY") end
        return out
    end
    local idx = N.index()
    for i, it in ipairs(items) do
        if not validItem(it) then
            skip(i, it, "BAD_ITEM")
        else
            local managed, hits = false, {}
            for _, e in ipairs(idx.byRect[N.rectKey(it.rect)] or {}) do
                if e.claimId ~= nil then managed = true elseif e.owner == it.owner then hits[#hits + 1] = e end
            end
            if managed then
                skip(i, it, "ALREADY_MANAGED")
            elseif #hits == 0 then
                skip(i, it, "NO_NATIVE")
            elseif #hits > 1 then
                skip(i, it, "AMBIGUOUS")   -- 同 rect 同 owner 多間：不猜（§9 第 10 點）
            else
                local house = hits[1].house
                local id = R.allocId()     -- 寫檔失敗也用掉（claimId 不重用）
                gen = gen or currentGen(now)
                if not appendLine(importLine(it.hash, id, gen)) then
                    skip(i, it, "WRITE_FAILED")
                else
                    local rec = R.newRecord({ claimId = id, rect = it.rect, title = it.title, owner = it.owner,
                        source = MSH.SOURCE.LEGACY, deedTier = 1, grants = legacyGrants(it), createdAt = now,
                        nativeCreatedAt = house:getDatetimeCreated() })   -- SafeHouse.java:681-683
                    -- setOwner 換成 service-owner（並把標記移出 players，SafeHouse.java:660-663），原屋主改放 players（:292-297）
                    house:setOwner(MSH.marker(id))
                    house:addPlayer(it.owner)
                    R.put(rec)
                    MSH.Audit.write("MIGRATED", { actor = it.owner, claimId = id, code = "LEGACY" })
                    if defer then defer(function() N.broadcast(house) end) else N.broadcast(house) end
                    out.imported[#out.imported + 1] = { hash = it.hash, claimId = id }
                end
            end
        end
    end
    if #out.imported > 0 then R.md.migrationCompleted = false end
    return out
end

-- want 行 → importLegacy 的 item（成員寫檔前已濾成合法名字，不含逗號）
local function wantItem(f)
    local x, y, w, h = string.match(f[4], "^(%-?%d+),(%-?%d+),(%d+),(%d+)$")
    if x == nil then return nil end
    local members = {}
    for u in string.gmatch(f[6], "[^,]+") do members[#members + 1] = u end
    return { hash = f[3], rect = { x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h) }, owner = f[5],
        members = members, title = f[7] }
end

-- 回傳 { ids＝全部行的 claimId（抬 nextClaimId 用），want／wantOrder＝這一代的 allow 項，got／gotOrder＝這一代 hash → claimId 清單 }
local function parseManifest(lines, gen)
    local m = { ids = {}, want = {}, wantOrder = {}, got = {}, gotOrder = {} }
    for _, line in ipairs(lines) do
        local f = split(line)
        if f[1] == "want" then
            if gen ~= nil and f[2] == gen and #f >= 7 and m.want[f[3]] == nil then
                local it = wantItem(f)
                if it ~= nil then
                    m.want[f[3]] = it
                    m.wantOrder[#m.wantOrder + 1] = f[3]
                end
            end
        else
            local id = tonumber(f[2] or "")
            if MSH.isInt(id) then
                m.ids[#m.ids + 1] = id
                if gen ~= nil and f[3] == gen then
                    local l = m.got[f[1]]
                    if l == nil then
                        l = {}
                        m.got[f[1]] = l
                        m.gotOrder[#m.gotOrder + 1] = f[1]
                    end
                    l[#l + 1] = id
                end
            end
        end
    end
    return m
end

-- 同一代裡一個 hash 的狀態：ok＝有紀錄且原生在，或已正常放棄（released 只剩 tombstone）；
-- missing＝紀錄在、原生不在（該筆 quarantined），或只剩標記原生（首輪 reconcile 會建 RECOVERED）；
-- failed＝寫了行卻沒有紀錄也沒有標記原生：匯入交易沒做完（寫檔後丟錯），可以照 want 重匯
local function hashState(R, idx, ids)
    local rec, orphan = nil, false
    for _, id in ipairs(ids) do
        local r = R.get(id)
        if R.tomb(id) ~= nil or (r ~= nil and idx.byClaim[id] ~= nil) then return "ok" end
        if r ~= nil then rec = r elseif idx.byClaim[id] ~= nil then orphan = true end
    end
    if rec ~= nil then
        if rec.lifecycle ~= LC.QUARANTINED then R.markQuarantined(rec, "MIGRATION_MISSING") end
        return "missing"
    end
    return orphan and "missing" or "failed"
end

-- 核對 completion manifest。開服 startup hook order 10，排在首輪 reconcile 之前（缺件的先 quarantined，reconcile 就不會重建它）；
-- 管理員 targeted recovery 後也會在鎖內重跑（只讀檔、改 registry，不送網路），全部吻合就解除遷移中。
-- 每次都先把 nextClaimId 抬過 manifest 裡全部的 id（含別代、已完成的遷移）：claimId 不重用（§4.2）。
-- 只核對 md.migrationGen 這一代；這一代每個 want hash 都有 ok 才完成。還沒匯入的放 M.pending，同一次開服由 operate 補匯入。
function M.verify(now)
    local R = MSH.Registry
    M.pending = nil
    if not R.ready() then return end
    local md = R.md
    local lines = readLines(M.manifestPath())
    if lines == false then
        if md.migrationCompleted ~= false or md.migrationGen == nil then return end
        MSH.Audit.write("MIGRATION_INCOMPLETE", { code = "MANIFEST_UNREADABLE" })
        return
    end
    local m = parseManifest(lines or {}, md.migrationGen)
    for _, id in ipairs(m.ids) do R.raiseNextId(id) end
    -- 沒在遷移、或還沒開始匯入（等 selection）：舊檔只用來抬 nextClaimId
    if md.migrationCompleted ~= false or md.migrationGen == nil then return end
    if lines == nil then
        MSH.Audit.write("MIGRATION_INCOMPLETE", { code = "MANIFEST_MISSING" })
        return
    end
    local idx = MSH.Native.index()
    local st = md.migration
    local ok, missing, pending = 0, 0, {}
    for _, h in ipairs(m.gotOrder) do
        local s = hashState(R, idx, m.got[h])
        if s == "ok" then
            ok = ok + 1
        elseif s == "failed" and m.want[h] ~= nil then
            pending[#pending + 1] = m.want[h]
        else
            missing = missing + 1
        end
    end
    for _, h in ipairs(m.wantOrder) do
        if m.got[h] == nil then pending[#pending + 1] = m.want[h] end
    end
    -- want 行比 selection 的 allow 少（檔案被截掉或改過）：少的那幾筆沒有資料可補，算缺件
    if st ~= nil and MSH.isInt(st.allowed) and #m.wantOrder < st.allowed then
        missing = missing + st.allowed - #m.wantOrder
    end
    M.pending = pending
    if st ~= nil then st.missing, st.pending = missing, #pending end
    -- aggregate log 只寫筆數（§9 第 11 點）
    if missing == 0 and #pending == 0 then
        md.migrationCompleted = true
        MSH.Audit.write("MIGRATION_COMPLETED", { detail = "verified=" .. ok })
    else
        MSH.Audit.write("MIGRATION_INCOMPLETE", { code = "MISSING",
            detail = "verified=" .. ok .. " missing=" .. missing .. " pending=" .. #pending })
    end
end

-- ===== operator 流程（§9 第 4、5、7、11、12 點）=====

-- 字串摘要：兩組 31 位元多項式雜湊（Kahlua 沒有位元運算；double 乘積 < 2^53 不失準）。
-- ponytail: 不防刻意碰撞；候選之間撞號會標 DUPLICATE_HASH、不能匯入，要防偽造再換密碼學雜湊。
local function digest(s)
    local a, b = 7, 11
    for i = 1, #s do
        local c = string.byte(s, i)
        a = (a * 31 + c) % 2147483629
        b = (b * 131 + c) % 2147483587
    end
    return tostring(math.floor(a)) .. "-" .. tostring(math.floor(b))
end

-- Better Safehouse 的 Global ModData（§9 第 7 點：唯讀）。只用 exists＋get，不用 getOrCreate（會建空表）：
-- ModData.exists／get（world/moddata/ModData.java:16、24 → GlobalModData.java:70、83）。
-- 鍵（BetterSafehouse 3.1.1 42.19/media/lua/）：BetterSafehouseExpansionState 的 baseRects／baseAreas／counts 以 "x:y:w:h"
--   （shared/BetterSafehouse/BetterSafehouse_Expansion_Shared.lua:7,629-640；server/…/BetterSafehouse_Expansion_Server.lua:33-54,150-175）；
--   BetterSafehouse_SubOwners／BetterSafehouse_SubOwnersMembers 以 getDatetimeCreated 的 "%.0f"
--   （shared/…/02_BetterSafehouse_SubOwner_Shared.lua:34,39；server/…/BetterSafehouse_SubOwner_Server.lua:124-143）；
--   BetterSafehouse_PrimaryRespawns[名字] 帶 safeX/Y/W/H（server/…/BetterSafehouse_Server.lua:13,713-735）。
local function rectText(x, y, w, h)
    return string.format("%d:%d:%d:%d", math.floor(tonumber(x) or 0), math.floor(tonumber(y) or 0),
        math.floor(tonumber(w) or 0), math.floor(tonumber(h) or 0))
end

local function foreignTable(tag)
    local ok, t = pcall(function()
        if ModData.exists(tag) then return ModData.get(tag) end
        return nil
    end)
    if ok and type(t) == "table" then return t end
    return nil
end

local function bshIndex()
    local rects, created = {}, {}
    local ex = foreignTable("BetterSafehouseExpansionState")
    if ex ~= nil then
        for _, field in ipairs({ "baseRects", "baseAreas", "counts" }) do
            if type(ex[field]) == "table" then
                for k in pairs(ex[field]) do rects[tostring(k)] = true end
            end
        end
    end
    for _, tag in ipairs({ "BetterSafehouse_SubOwners", "BetterSafehouse_SubOwnersMembers" }) do
        local t = foreignTable(tag)
        if t ~= nil then
            for k in pairs(t) do created[tostring(k)] = true end
        end
    end
    local rs = foreignTable("BetterSafehouse_PrimaryRespawns")
    if rs ~= nil then
        for _, r in pairs(rs) do
            if type(r) == "table" then rects[rectText(r.safeX, r.safeY, r.safeW, r.safeH)] = true end
        end
    end
    return rects, created
end

-- 唯讀掃 foreign 原生（owner 不是 @MSH 標記）。candidate = { rect, owner, title, members（排序）, hash, bsh, problem }；
-- identity hash＝rect＋owner＋title＋成員（§9 第 4 點）；problem 的不能匯入（§9 第 10 點：不猜）。
-- 回傳 { list（照 hash 排序）, byHash, fingerprint }
function M.scan()
    local N = MSH.Native
    local idx = N.index()
    local bRects, bCreated = bshIndex()
    local list, seen = {}, {}
    for _, e in ipairs(idx.foreign) do
        local house, r = e.house, e.rect
        local owner = type(e.owner) == "string" and e.owner or ""
        local title = house:getTitle()   -- SafeHouse.java:727-729
        if type(title) ~= "string" then title = "" end
        local members = N.players(house)
        MSH.sortSafe(members, function(a, b) return a < b end)
        local created = house:getDatetimeCreated()   -- SafeHouse.java:681-683
        local c = { rect = r, owner = owner, title = title, members = members,
            bsh = bRects[rectText(r.x, r.y, r.w, r.h)] == true
                or (MSH.isFinite(created) and bCreated[string.format("%.0f", created)] == true) }
        c.hash = digest(N.rectKey(r) .. "\n" .. owner .. "\n" .. title .. "\n" .. table.concat(members, "\n"))
        if not MSH.Rect.valid(r) then
            c.problem = "BAD_RECT"
        elseif not MSH.validUsername(owner) then
            c.problem = "BAD_OWNER"
        elseif #idx.byRect[N.rectKey(r)] > 1 then
            c.problem = "DUPLICATE_RECT"
        end
        seen[c.hash] = (seen[c.hash] or 0) + 1
        list[#list + 1] = c
    end
    MSH.sortSafe(list, function(a, b) return a.hash < b.hash end)
    local byHash, hashes = {}, {}
    for i, c in ipairs(list) do
        if seen[c.hash] > 1 and c.problem == nil then c.problem = "DUPLICATE_HASH" end
        byHash[c.hash] = c
        hashes[i] = c.hash
    end
    return { list = list, byHash = byHash,
        fingerprint = "n" .. idx.count .. "-c" .. #list .. "-" .. digest(table.concat(hashes, ",")) }
end

-- candidate report＋selection 範本。預填：Better Safehouse 對得上且沒有問題的 allow，其他 deny（來源不明不猜）
-- 檔頭只能用 ASCII：Kahlua 把非 ASCII 字面值截成單 byte，截出的 \r 會讓 readLine 把註解切成壞行（sh-mig-1011a 實踩 BAD_LINE）
local function writeReport(scan)
    local N = MSH.Native
    local lines = {
        "# MinidoracatSafehouse migration candidates. After review, copy this file to migration-selection.txt.",
        "# Set the first column of each row to allow (import) or deny (skip; the vanilla safehouse is left as is). Keep the snapshot row.",
        "# Rows whose problem column is not - cannot be allowed. Columns: decision hash x,y,w,h owner members bsh problem title",
        "snapshot\t" .. scan.fingerprint,
    }
    for _, c in ipairs(scan.list) do
        lines[#lines + 1] = table.concat({ (c.bsh and c.problem == nil) and "allow" or "deny", c.hash, N.rectKey(c.rect),
            field(c.owner), tostring(#c.members), c.bsh and "bsh" or "-", c.problem or "-", field(c.title) }, "\t")
    end
    return writeLines(M.reportPath(), lines, false)
end

-- 解析 selection：每行前兩欄（空白分隔）；# 開頭與空行略過；開頭的 BOM／空白去掉。
-- 指紋要相同、每個 hash 都要是目前的候選、每個候選都要有決定、allow 的不能有問題；任何一項不合整批不匯入。
-- 回傳 items（給 importLegacy）, allowed, denied 或 nil, 結果碼
local function readSelection(scan, lines)
    local snap, decided, rows = nil, {}, {}
    for _, line in ipairs(lines) do
        local body = string.match(line, "^[^%w#]*(.-)%s*$") or ""
        if body ~= "" and string.sub(body, 1, 1) ~= "#" then
            local a, b = string.match(body, "^(%S+)%s+(%S+)")
            if a == "snapshot" and snap == nil then
                snap = b
            elseif a == "allow" or a == "deny" then
                rows[#rows + 1] = { a, b }
            else
                return nil, "BAD_LINE"
            end
        end
    end
    if snap ~= scan.fingerprint then return nil, "SNAPSHOT_MISMATCH" end
    for _, row in ipairs(rows) do
        local c = scan.byHash[row[2]]
        if c == nil then return nil, "UNKNOWN_HASH" end
        if decided[row[2]] ~= nil and decided[row[2]] ~= row[1] then return nil, "DUPLICATE_HASH" end
        if row[1] == "allow" and c.problem ~= nil then return nil, "NOT_ALLOWED" end
        decided[row[2]] = row[1]
    end
    local items, denied = {}, 0
    for _, c in ipairs(scan.list) do
        local d = decided[c.hash]
        if d == nil then return nil, "UNDECIDED" end
        if d == "allow" then
            items[#items + 1] = { rect = c.rect, owner = c.owner, title = c.title, members = c.members, hash = c.hash }
        else
            denied = denied + 1
        end
    end
    return items, #items, denied
end

-- want 行：這一代要匯入的 allow 項（伺服器私有檔）。成員只留合法名字（不含逗號），標題去掉控制字元
local function wantLine(gen, it)
    local members = {}
    for _, u in ipairs(it.members) do
        if MSH.validUsername(u) and not string.find(u, ",", 1, true) then members[#members + 1] = u end
    end
    return table.concat({ "want", gen, it.hash, MSH.Native.rectKey(it.rect), it.owner, table.concat(members, ","),
        field(it.title) }, "\t")
end

-- 補匯入時原生已不在或對不上：建 quarantined 佔位（MIGRATION_MISSING），讓管理員 targeted recovery 處理
-- （rebind 照 rect 重建、release 放棄），處理完 verify 重跑就能完成；照 write-then-update 先寫 manifest 行
local HOLD = { NO_NATIVE = true, AMBIGUOUS = true, ALREADY_MANAGED = true }
local function hold(it, now)
    local R = MSH.Registry
    local id = R.allocId()
    if not appendLine(importLine(it.hash, id, R.md.migrationGen)) then return false end
    local rec = R.newRecord({ claimId = id, lifecycle = LC.QUARANTINED, rect = it.rect, title = it.title, owner = it.owner,
        source = MSH.SOURCE.LEGACY, deedTier = 1, grants = legacyGrants(it), createdAt = now })
    rec.quarantineReason = "MIGRATION_MISSING"
    R.put(rec)
    MSH.Audit.write("QUARANTINE", { claimId = id, code = "MIGRATION_MISSING" })
    return true
end

-- 照 items 匯入（第一次與補匯入共用）；持全域鎖，放鎖後才送原生廣播。importLegacy 中途丟錯時已做完的照樣留著，
-- 下一次開服 verify 以 hash 找出還沒完成的再補
local function runImport(st, items, now)
    local sends, held = {}, 0
    local out = MSH.Srv.withLock(function()
        local res = M.importLegacy(items, now, function(fn) sends[#sends + 1] = fn end)
        for _, s in ipairs(res.skipped) do
            if HOLD[s.reason] and hold(items[s.index], now) then held = held + 1 end
        end
        return res
    end)
    for _, fn in ipairs(sends) do
        local ok, err = pcall(fn)
        if not ok then MSH.log("migration send failed: " .. tostring(err)) end
    end
    if type(out) ~= "table" or out.imported == nil then return "IMPORT_FAILED" end
    st.imported = (st.imported or 0) + #out.imported
    st.skipped = #out.skipped - held
    st.held = (st.held or 0) + held
    local lines = {}
    for _, it in ipairs(out.imported) do lines[#lines + 1] = "# imported " .. it.hash .. " " .. tostring(it.claimId) end
    for _, it in ipairs(out.skipped) do lines[#lines + 1] = "# skipped " .. tostring(it.hash) .. " " .. it.reason end
    writeLines(M.reportPath(), lines, true)
    MSH.Audit.write("MIGRATION_IMPORTED", { detail = "allowed=" .. tostring(st.allowed) .. " denied=" .. tostring(st.denied)
        .. " imported=" .. #out.imported .. " skipped=" .. st.skipped .. (held > 0 and (" held=" .. held) or "") })
    return nil
end

-- 第一次匯入：開新的一代，先把全部 want 行寫進 completion manifest，成功才把代號寫進 registry、轉 imported 階段
local function startImport(st, items, now)
    local R = MSH.Registry
    -- legacy 一律 grandfather（不看每人名額，§9 第 5 點）；全服上限 256 是 registry 大小的 ship gate，超過要 operator 再 deny
    if #items > MSH.LIMIT.MAX_CLAIMS - R.liveCount() then return "TOO_MANY" end
    st.importedAt = now
    if #items == 0 then
        -- 全部 deny：沒有東西要核對，直接完成
        st.phase, st.imported, st.skipped = "imported", 0, 0
        R.md.migrationCompleted = true
        MSH.Audit.write("MIGRATION_IMPORTED", { detail = "allowed=0 denied=" .. tostring(st.denied) .. " imported=0 skipped=0" })
        MSH.Audit.write("MIGRATION_COMPLETED", { detail = "verified=0" })
        return nil
    end
    local gen = newGen(now)
    local lines = {}
    for _, it in ipairs(items) do lines[#lines + 1] = wantLine(gen, it) end
    if not writeLines(M.manifestPath(), lines, true) then return "WRITE_FAILED" end
    R.md.migrationGen = gen
    st.phase = "imported"
    return runImport(st, items, now)
end

-- startup hook order 11：verify（10）之後、首輪 reconcile（20）之前
function M.operate(now)
    local R = MSH.Registry
    if not R.ready() then return end
    local md = R.md
    local st = md.migration or {}
    md.migration = st
    if st.phase == nil then
        -- 只在這份存檔第一次跑本 MOD（registry 沒有紀錄、tombstone、遷移旗標）且有 foreign 原生時進入遷移
        if md.migrationCompleted ~= nil or R.liveCount() > 0 or R.tombstoneCount() > 0
            or #MSH.Native.index().foreign == 0 then
            st.phase = "none"
            return
        end
        st.phase = "select"
        md.migrationCompleted = false
    end
    if md.migrationCompleted ~= false then return end
    if st.phase == "imported" then
        -- 補匯入 verify（同一次開服、order 10）找出的還沒完成的 hash；已有紀錄的不重匯。下一次開服再核對
        local pending = M.pending
        if pending ~= nil and #pending > 0 then
            local abort = runImport(st, pending, now)
            st.abort = abort
            if abort ~= nil then
                MSH.Audit.write("MIGRATION_ABORTED", { code = abort, detail = "pending=" .. #pending })
            end
        end
        return
    end
    if st.phase ~= "select" then return end
    local scan = M.scan()
    local bsh, problems = 0, 0
    for _, c in ipairs(scan.list) do
        if c.bsh then bsh = bsh + 1 end
        if c.problem ~= nil then problems = problems + 1 end
    end
    st.candidates, st.bshMatched, st.problems, st.reportedAt = #scan.list, bsh, problems, now
    st.abort = not writeReport(scan) and "REPORT_WRITE_FAILED" or nil
    MSH.Audit.write("MIGRATION_REPORT", { detail = "candidates=" .. #scan.list .. " bsh=" .. bsh .. " problems=" .. problems })
    local lines = readLines(M.selectionPath())
    if lines == nil then return end
    local abort
    if lines == false then
        abort = "SELECTION_UNREADABLE"
    else
        local items, allowed, denied = readSelection(scan, lines)
        if items == nil then
            abort = allowed
        else
            st.allowed, st.denied = allowed, denied
            abort = startImport(st, items, now)
        end
    end
    st.abort = abort
    if abort ~= nil then
        MSH.Audit.write("MIGRATION_ABORTED", { code = abort, detail = "candidates=" .. #scan.list })
    end
end

-- 給管理員面板（§10.6）：只有階段、筆數、結果碼與檔案位置（相對 Zomboid/Lua/），不含名字與座標
function M.status()
    local md = MSH.Registry.md or {}
    local st = md.migration or {}
    local status = "none"
    if md.migrationCompleted == true then
        status = "completed"
    elseif md.migrationCompleted == false then
        status = st.phase == "select" and "awaitingSelection" or "verifying"
    end
    return { status = status, completed = md.migrationCompleted, candidates = st.candidates, bshMatched = st.bshMatched,
        problems = st.problems, allowed = st.allowed, denied = st.denied, imported = st.imported, skipped = st.skipped,
        missing = st.missing, pending = st.pending, held = st.held, abort = st.abort, reportedAt = st.reportedAt,
        importedAt = st.importedAt,
        files = { report = M.reportPath(), selection = M.selectionPath(), completion = M.manifestPath() } }
end

MSH.Srv.define("adminMigration", { kind = "query", admin = true, fields = {}, run = function()
    return MSH.Srv.ok({ migration = M.status() })
end })

MSH.Srv.hook("startup", "migration", function(now) MSH.Migration.verify(now) end, 10)
MSH.Srv.hook("startup", "migrationOps", function(now) MSH.Migration.operate(now) end, 11)
