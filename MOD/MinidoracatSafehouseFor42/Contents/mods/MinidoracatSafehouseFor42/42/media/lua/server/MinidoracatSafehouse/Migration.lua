-- MinidoracatSafehouse/Migration.lua：自動接管既有的原版安全屋（計畫 §9；使用者 2026-10-11 決定全自動）。
-- 目標：伺服器中途安裝本 MOD，管理員照 README 改好必要伺服器設定以外不用做任何事；玩家從不被擋。
-- 觸發：第一次檢查時 registry 全新（沒有紀錄、tombstone、遷移狀態）、沒有對不到 imp 行的 @MSH 標記原生，而且有 foreign 原生
--   （owner 不是 @MSH 標記）。已有紀錄的伺服器、或沒有 foreign 原生的全新伺服器，記成 none，之後永不接管（之後才出現的
--   foreign 一律不收）。有對不到 imp 行的標記原生＝registry 遺失（玩家建的屋原生存了、Global ModData 沒存），不是第一次安裝：
--   imp 行能還原的照樣還原，不接管任何 foreign，狀態記 done（有還原）或 none，其餘標記原生交給首輪 reconcile 的 RECOVERED。
-- 前置：Health 沒有 blocked（必要伺服器設定都對）、Better Safehouse 沒啟用。不符就記 waiting＋原因，下次開服再試。
-- 接管（開服 startup hook order 11，在首輪 reconcile order 20 之前）：沒有問題的 foreign 原生依原生建立時間由舊到新接管，
--   屋主、範圍、成員照舊（成員＝SHARE_LEGACY），標題照建立時的規則清理（cleanTitle，40 字）。同一個順序套三個上限：
--   全服 256 間、registry 估算大小 ≤ REGISTRY_BYTES 的 M.REGISTRY_SHARE、原生名單名字總數 ≤ NATIVE_NAMES 的 M.NAMES_SHARE；
--   第一間放不下之後全部 OVER_CAP（不讓較新的小屋插隊）。有問題的（範圍不合法、屋主名不合法、同範圍或同起點有兩間）
--   與超過上限的留在原版、照常受原版保護（§9 第 10 點：不猜、不刪）。
-- 任何 allocId 之前先把 nextClaimId 抬過每一個 @MSH:<id> 標記原生與 completion 檔的 id（claimId 永不重用，§4.2）。
-- completion 檔（與私有檔同目錄的 migration-completion.txt，伺服器私有，append-only，可放名字與座標）：
--   `imp<TAB>代號<TAB>claimId<TAB>x,y,w,h<TAB>原生建立時間<TAB>屋主<TAB>成員(逗號分隔)<TAB>標題`：接管一間寫一行，
--     先寫檔、成功才改原生與 registry（write-then-update）；
--   `skip<TAB>代號<TAB>原因<TAB>x,y,w,h<TAB>屋主<TAB>標題`：留在原版的，給管理員查是哪幾間。
--   代號＝接管當下的「毫秒時間-nextClaimId」，只標示是哪一次接管寫的行。
-- 當機自動修復（每次開服、接管之前）：
--   - 兩邊都沒存：registry 全新、原生還是原本的屋主 → 照觸發條件重新接管（舊行的 claimId 對不到任何標記原生，等於忽略）。
--   - 原生已存（owner 是 @MSH:<id>）、registry 沒存：用 imp 行重建紀錄。對身分用 claimId＋範圍＋原生建立時間三項都相同，
--     不靠代號（代號存在 registry，這時已經跟著回滾）；別的世界留下的舊行建立時間不同，不會誤認。
--   - registry 已存、原生沒存：legacy 紀錄沒有標記原生、同範圍有一間屋主是紀錄屋主而且建立時間相同的 foreign → 重新 setOwner。
--   - 對不上的不在這裡猜：沒有紀錄的標記原生由首輪 reconcile 轉 RECOVERED quarantined、找不到原生的紀錄照 recovery matrix，
--     都在管理員面板「需要處理的安全屋」。
-- md.migration（Global ModData，公開）只放狀態、原因碼與筆數；名字與座標只寫進伺服器本機的 completion 檔（§9 第 11 點）。
-- 字串字面值只用 ASCII：Kahlua 把非 ASCII 字面值截成單 byte（sh-mig-1011a 實踩）。
-- 出處：反編譯 D:/github/pz-decompiled-reference/snapshots/42.21.0-20260928/pz/zombie/（下稱 SafeHouse.java＝iso/areas/SafeHouse.java、
--   LuaManager.java＝Lua/LuaManager.java）。

if isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Audit"
require "MinidoracatSafehouse/Registry"
require "MinidoracatSafehouse/Native"
require "MinidoracatSafehouse/Health"
require "MinidoracatSafehouse/Server"

local MSH = MinidoracatSafehouse
local M = MSH.Migration or {}
MSH.Migration = M

local LC = MSH.LIFECYCLE

M.BSH_MOD_ID = "BetterSafehouse"   -- Workshop 3634569678 的 42.19/mod.info:2（docs/research/better-safehouse-3634569678-analysis.md:18）
M.SKIP_REASONS = { "BAD_RECT", "BAD_OWNER", "DUPLICATE_RECT", "DUPLICATE_ID", "OVER_CAP" }
-- 接管最多用掉的容量比例，其餘留給之後玩家正常建立與分享（從不擋玩家）：
--   registry 一半（128 KiB）：另一半要放 1,024 筆 tombstone（一筆約 60 bytes，約 64 KiB，§4.2）＋之後的新屋與分享；
--     一般舊屋一間約 400 bytes，256 間約 100 KiB，正常伺服器碰不到這條。
--   原生名單名字 3/4（3,072）：留 1,024 個名字給之後的分享與新屋。
M.REGISTRY_SHARE = 0.5
M.NAMES_SHARE = 0.75

-- 與 R.privatePath() 同目錄（<cachedir>/Lua/MinidoracatSafehouse/<server>/）；.txt 在 getFileWriter 允許的副檔名內（LuaManager.java:1035）
function M.manifestPath()
    return (string.gsub(MSH.Registry.privatePath(), "private%.txt$", "migration-completion.txt"))
end

-- getFileWriter(path, createIfNull, append)：LuaManager.java:6727（UTF-8）；writeln：LuaManager.java:12834
local function appendLines(lines)
    local writer
    local opened = pcall(function() writer = getFileWriter(M.manifestPath(), true, true) end)
    if not opened or writer == nil then return false end
    local written = pcall(function()
        for _, line in ipairs(lines) do writer:writeln(line) end
    end)
    local closed = pcall(function() writer:close() end)
    return written and closed
end

-- 回傳行陣列；檔案不存在回 nil；存在卻讀不開回 false
local function readLines()
    local path = M.manifestPath()
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

-- 檔案欄位不能含 tab／換行
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

-- 原生建立時間（毫秒，double）寫成整數字串；兩邊都用它比對，不比浮點數
local function createdText(house)
    local v = house:getDatetimeCreated()   -- SafeHouse.java:681-683
    if not MSH.isFinite(v) then return "-" end
    return string.format("%.0f", v)
end

-- 成員：合法名字、不重複、不含屋主與逗號（檔案以逗號分隔）
local function cleanMembers(owner, list)
    local out, seen = {}, { [owner] = true }
    for _, u in ipairs(list) do
        if MSH.validUsername(u) and not seen[u] and not string.find(u, ",", 1, true) then
            seen[u] = true
            out[#out + 1] = u
        end
    end
    return out
end

-- 舊成員轉 grants（MEMBER＋USE＋MOVE＋BUILD＋FARM，等同原版成員；respawn flags 不保存，§4.4）
local function legacyGrants(members)
    local out = {}
    for _, u in ipairs(members) do out[#out + 1] = { user = u, bits = MSH.SHARE_LEGACY } end
    return out
end

local function legacyRecord(id, rect, owner, title, members, house, now)
    return MSH.Registry.newRecord({ claimId = id, rect = rect, title = title, owner = owner, source = MSH.SOURCE.LEGACY,
        deedTier = 1, grants = legacyGrants(members), createdAt = now, nativeCreatedAt = house:getDatetimeCreated() })
end

-- 標題照建立時的規則（MSH.cleanTitle：去頭尾空白、1–40 字、不含控制字元與 []）；不合格的先去掉那些字元、截 40 字，
-- 還是不行（例如空的）就用屋主名，和建立時沒給標題一樣
local function legacyTitle(raw, owner)
    local t = MSH.cleanTitle(raw)
    if t ~= nil then return t end
    if type(raw) == "string" then
        local s = MSH.trim((string.gsub(raw, "[%c%[%]]", "")))
        t = MSH.cleanTitle(string.sub(s, 1, MSH.LIMIT.TITLE_CHARS))
        if t ~= nil then return t end
    end
    return MSH.cleanTitle(owner) or owner
end

-- setOwner 換成 service-owner（並把標記移出 players，SafeHouse.java:660-663），原屋主改放 players（:292-297）
local function mark(house, id, owner)
    house:setOwner(MSH.marker(id))
    house:addPlayer(owner)
end

-- Better Safehouse 是否啟用：getActivatedMods（LuaManager.java:7458-7462 → ZomboidFileSystem.getModIDs :873，已載入的 MOD id）。
-- ini 的 Mods= 寫成 \ModId，比對前去掉開頭的反斜線
function M.bshActive()
    local ok, found = pcall(function()
        local list = getActivatedMods()
        for i = 0, list:size() - 1 do
            local id = string.gsub(tostring(list:get(i)), "^\\", "")
            if id == M.BSH_MOD_ID then return true end
        end
        return false
    end)
    return ok and found == true
end

-- ===== 當機修復 =====

-- imp 行 → claimId → { rectKey, created, owner, members, title }（同一 claimId 以最後一行為準）
local function parseImports(lines)
    local out = {}
    for _, line in ipairs(lines) do
        local f = split(line)
        if f[1] == "imp" and #f >= 8 then
            local id = tonumber(f[3])
            if MSH.isInt(id) then
                local members = {}
                for u in string.gmatch(f[7], "[^,]+") do members[#members + 1] = u end
                out[id] = { rectKey = f[4], created = f[5], owner = f[6], members = members, title = f[8] }
            end
        end
    end
    return out
end

-- 原生已存、registry 沒存：沒有紀錄也沒有 tombstone 的標記原生，照 imp 行重建紀錄（claimId＋範圍＋建立時間都要相同）
local function restore(idx, imports, now)
    local R = MSH.Registry
    local todo = {}
    for id, list in pairs(idx.byClaim) do
        local it = imports[id]
        if R.md.claims[id] == nil and R.md.tombs[id] == nil and #list == 1 and it ~= nil
            and MSH.Native.rectKey(list[1].rect) == it.rectKey and createdText(list[1].house) == it.created
            and MSH.validUsername(it.owner) then
            todo[#todo + 1] = { id = id, e = list[1], it = it }
        end
    end
    for _, t in ipairs(todo) do
        local members = cleanMembers(t.it.owner, t.it.members)
        R.put(legacyRecord(t.id, t.e.rect, t.it.owner, legacyTitle(t.it.title, t.it.owner), members, t.e.house, now))
        R.raiseNextId(t.id)
        t.e.house:addPlayer(t.it.owner)
        MSH.Audit.write("MIGRATION_RESTORED", { claimId = t.id })
    end
    return #todo
end

-- registry 已存、原生沒存：legacy 紀錄沒有標記原生，同範圍恰好一間屋主相同、建立時間相同（N.matches）的 foreign → 重新接上
local function reattach(idx)
    local N = MSH.Native
    local n = 0
    for _, rec in ipairs(MSH.Registry.list()) do
        if rec.source == MSH.SOURCE.LEGACY and rec.lifecycle == LC.ACTIVE and idx.byClaim[rec.claimId] == nil then
            local hits = {}
            for _, e in ipairs(idx.byRect[N.rectKey(rec.rect)] or {}) do
                if e.claimId == nil and e.owner == rec.owner and N.matches(rec, e) then hits[#hits + 1] = e end
            end
            if #hits == 1 then
                mark(hits[1].house, rec.claimId, rec.owner)
                n = n + 1
                MSH.Audit.write("MIGRATION_REATTACHED", { claimId = rec.claimId })
            end
        end
    end
    return n
end

-- ===== 接管 =====

-- foreign 原生 → 候選 { e, created, problem }；problem 的留在原版
local function candidates(idx)
    local N = MSH.Native
    local out = {}
    for _, e in ipairs(idx.foreign) do
        local c = { e = e, created = e.house:getDatetimeCreated() }
        if not MSH.isFinite(c.created) then c.created = 0 end
        if not MSH.Rect.valid(e.rect) then
            c.problem = "BAD_RECT"
        elseif not MSH.validUsername(e.owner) then
            c.problem = "BAD_OWNER"
        elseif #idx.byRect[N.rectKey(e.rect)] > 1 then
            c.problem = "DUPLICATE_RECT"
        elseif idx.onlineIds[e.onlineId] > 1 then
            c.problem = "DUPLICATE_ID"   -- 同起點：原生封包以 onlineId first-match 找房（SafeHouse.java:577-579、785）
        end
        out[#out + 1] = c
    end
    return out
end

local function skipLine(gen, reason, e)
    local title = e.house:getTitle()   -- SafeHouse.java:727-729
    return table.concat({ "skip", gen, reason, MSH.Native.rectKey(e.rect), field(e.owner), field(title or "") }, "\t")
end

-- 接管一間：先預檢容量（用 nextClaimId 當草稿 id，放不下不消耗 claimId），再寫 imp 行，成功才改原生與 registry。
-- 回傳 "ok"、"cap"（放不下）或 false（寫檔失敗；claimId 照樣用掉、不重用）
local function adoptOne(c, gen, now, budget)
    local R, N = MSH.Registry, MSH.Native
    local e = c.e
    local house, owner = e.house, e.owner
    local title = legacyTitle(house:getTitle(), owner)
    local members = cleanMembers(owner, N.players(house))
    local rec = legacyRecord(R.md.nextClaimId, e.rect, owner, title, members, house, now)
    -- 和 Claims.checkCapacity 同一套：registry 估算大小（含這筆）、全部原生名單名字數
    local names = #N.desiredPlayers(rec)
    if R.estimateBytes(rec) > budget.bytes or budget.names + names > budget.maxNames then return "cap" end
    local id = R.allocId()
    rec.claimId = id
    local line = table.concat({ "imp", gen, tostring(id), N.rectKey(e.rect), createdText(house), owner,
        table.concat(members, ","), field(title) }, "\t")
    if not appendLines({ line }) then return false end
    mark(house, id, owner)
    R.put(rec)
    budget.names = budget.names + names
    MSH.Audit.write("MIGRATED", { actor = owner, claimId = id, code = "LEGACY" })
    return "ok"
end

-- 一輪接管；寫檔失敗或中途丟錯的留在原版，狀態維持 waiting（IMPORT_FAILED），下次開服只會再看到還是 foreign 的那幾間
local function adopt(st, now)
    local R, N = MSH.Registry, MSH.Native
    local gen = tostring(math.floor(now)) .. "-" .. tostring(R.md.nextClaimId)
    local list = candidates(N.index())
    local skipped, failed, skipLines, houses = {}, 0, {}, {}
    local eligible = {}
    for _, c in ipairs(list) do
        if c.problem == nil then
            eligible[#eligible + 1] = c
        else
            skipped[c.problem] = (skipped[c.problem] or 0) + 1
            skipLines[#skipLines + 1] = skipLine(gen, c.problem, c.e)
        end
    end
    MSH.sortSafe(eligible, function(a, b)
        if a.created ~= b.created then return a.created < b.created end
        return N.rectKey(a.e.rect) < N.rectKey(b.e.rect)
    end)
    local room = MSH.LIMIT.MAX_CLAIMS - R.liveCount()
    local budget = { bytes = math.floor(MSH.LIMIT.REGISTRY_BYTES * M.REGISTRY_SHARE),
        maxNames = math.floor(MSH.LIMIT.NATIVE_NAMES * M.NAMES_SHARE), names = 0 }
    for _, r in ipairs(R.list()) do
        if R.isLive(r) then budget.names = budget.names + #N.desiredPlayers(r) end
    end
    local done, full = 0, false
    local res = MSH.Srv.withLock(function()
        for _, c in ipairs(eligible) do
            local got = nil
            if not full and done < room then got = adoptOne(c, gen, now, budget) end
            if got == "ok" then
                done = done + 1
                houses[#houses + 1] = c.e.house
            elseif got == false then
                failed = failed + 1
            else
                full = true
                skipped.OVER_CAP = (skipped.OVER_CAP or 0) + 1
                skipLines[#skipLines + 1] = skipLine(gen, "OVER_CAP", c.e)
            end
        end
        return MSH.Srv.ok()
    end)
    for _, h in ipairs(houses) do N.broadcast(h) end   -- 放鎖後才送（開服首輪 netUp 前不送，登入時整份清單會帶到）
    if not (type(res) == "table" and res.ok) then failed = failed + 1 end
    if #skipLines > 0 then appendLines(skipLines) end
    st.adopted = (st.adopted or 0) + done
    st.skipped = skipped
    st.at = now
    local detail = "adopted=" .. done .. " failed=" .. failed
    for _, reason in ipairs(M.SKIP_REASONS) do
        if skipped[reason] then detail = detail .. " " .. reason .. "=" .. skipped[reason] end
    end
    -- aggregate log 只寫筆數（§9 第 11 點）
    MSH.Audit.write("MIGRATION_ADOPTED", { detail = detail })
    if failed > 0 then
        st.state, st.reason = "waiting", "IMPORT_FAILED"
    else
        st.state, st.reason = "done", nil
    end
end

-- startup hook order 11：首輪 reconcile（order 20）之前
function M.startup(now)
    local R, N = MSH.Registry, MSH.Native
    if not R.ready() then return end
    local md = R.md
    local fresh = md.migration == nil and R.liveCount() == 0 and R.tombstoneCount() == 0
    local lines = readLines()
    if lines == false then MSH.Audit.write("MIGRATION_CHECK", { code = "FILE_UNREADABLE" }) end
    local imports = parseImports(lines or {})
    -- claimId 永不重用：先抬過檔案裡全部的 id（含別的世界、回滾掉的接管）與每一個標記原生（含玩家建的屋，
    -- registry 遺失時它們只剩原生）。必須在任何 allocId 之前（§4.2；recoverOrphans 在 order 20 才抬，太晚）
    for id in pairs(imports) do R.raiseNextId(id) end
    local idx = N.index()
    for id in pairs(idx.byClaim) do R.raiseNextId(id) end
    local fix = MSH.Srv.withLock(function()
        return { restored = restore(idx, imports, now), reattached = reattach(idx) }
    end)
    if type(fix) ~= "table" or fix.restored == nil then fix = { restored = 0, reattached = 0 } end
    M.lastCheck = { restored = fix.restored, reattached = fix.reattached, at = now }
    if fix.restored + fix.reattached > 0 then
        MSH.Audit.write("MIGRATION_REPAIRED", { detail = "restored=" .. fix.restored .. " reattached=" .. fix.reattached })
    end
    local st = md.migration
    if st == nil then
        -- 還原後仍沒有紀錄的標記原生＝registry 遺失：不是第一次安裝，不接管 foreign
        local orphans = 0
        for id in pairs(idx.byClaim) do
            if md.claims[id] == nil and md.tombs[id] == nil then orphans = orphans + 1 end
        end
        if orphans > 0 then
            MSH.Audit.write("MIGRATION_CHECK", { code = "REGISTRY_LOST", detail = "orphans=" .. orphans })
            md.migration = fix.restored > 0 and { state = "done", adopted = fix.restored, at = now } or { state = "none" }
            return
        end
        if not fresh or (#idx.foreign == 0 and fix.restored == 0) then
            md.migration = { state = "none" }
            return
        end
        st = { state = "waiting", adopted = fix.restored }
        md.migration = st
    end
    if st.state ~= "waiting" then return end
    local reason = nil
    if MSH.Health.blocked() then
        reason = "HEALTH_BLOCKED"
    elseif M.bshActive() then
        reason = "BSH_ACTIVE"
    end
    if reason ~= nil then
        st.reason = reason
        MSH.Audit.write("MIGRATION_WAITING", { code = reason })
        return
    end
    adopt(st, now)
end

-- 給管理員面板（§10.6）：狀態、等待原因、接管與略過筆數、這次開服的當機修復筆數；不含名字與座標
function M.status()
    local md = MSH.Registry.md or {}
    local st = md.migration or {}
    local skipped = {}
    for k, v in pairs(st.skipped or {}) do skipped[k] = v end
    local last = M.lastCheck or {}
    return { state = st.state or "none", reason = st.reason, adopted = st.adopted or 0, skipped = skipped, at = st.at,
        restored = last.restored or 0, reattached = last.reattached or 0, file = M.manifestPath() }
end

MSH.Srv.define("adminMigration", { kind = "query", admin = true, fields = {}, run = function()
    return MSH.Srv.ok({ migration = M.status() })
end })

MSH.Srv.hook("startup", "migration", function(now) MSH.Migration.startup(now) end, 11)
