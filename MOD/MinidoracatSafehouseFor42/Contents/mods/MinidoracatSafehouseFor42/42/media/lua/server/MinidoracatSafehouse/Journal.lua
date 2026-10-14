-- MinidoracatSafehouse/Journal.lua：當機後自動補回剛建好的安全屋（使用者 2026-10-14：「好，加上重建機制」）。
-- 為什麼：安全屋（原生＋Global ModData）只跟世界存檔落盤，扣掉地契的玩家背包另外存（在線每 180 秒、斷線時；
--   decisions.md「三樣東西各自落盤」）。建好之後、下一次世界存檔之前當機，屋子消失，地契卻可能已經存成扣掉。
-- 記錄：建立、重新框選成功時在伺服器私有的 crash-journal.txt（與 private.txt 同目錄）寫一行；建立滿 INV_DELAY_MS 再補
--   一行「背包已存」：在線玩家的背包每 180 秒入佇列一次（UdpConnection.java:88、NetworkPlayerManager.java:24-28），
--   背景執行緒 0.5 秒內 commit（ServerPlayersVehicles.java:47-55），斷線時立刻存（GameServer.java:3040）。
--   真正的放棄（玩家放棄、代為放棄、到期釋出）再寫一行（Registry.markReleased）；重新框選換掉的舊屋不寫，新屋的 C 行接手。
--   伺服器 Lua 看不到世界存檔（ServerMap.QueuedSaveAll 不發 Lua 事件），不知道哪幾行已經進了存檔，只能在開機時比對 registry。
-- 開機：order 10 讀檔、把 nextClaimId 抬過檔裡每個 claimId 與高水位（Migration order 11 接管時才不會撞號）；
--   order 15（Migration 之後、首輪 Reconcile order 20 之前）逐串比對：
--   - 這一串任何一間在 registry（紀錄或 tombstone）：世界存檔已經有這一串的狀態，不動；
--   - 最後一間已經放棄：不補（放棄本來就不退地契）；
--   - 其餘照最後那一間寫回紀錄。免費建立的、或已有「背包已存」那一行的寫成 active，缺的原生由首輪 Reconcile 補建
--     （範圍被別的原生佔走時它轉 quarantined REBUILD_*）。用地契建立卻沒有那一行的寫成 quarantined CRASH_UNCONFIRMED：
--     當機時背包可能還沒存、地契可能已經回到屋主身上，交給管理員問過屋主再決定（管理員面板「需要處理的安全屋」）。
--     原生已經在存檔裡也不算背包已存：世界存檔先寫原生、才把玩家排進存檔佇列（ServerMap.java:377-379）。
--   - 同一串裡沒補回的那幾間（已放棄、或被重新框選換掉），存檔裡還有它們的原生時寫成 tombstone，首輪 Reconcile 拆掉，
--     不讓它們變成另一筆 RECOVERED。
--   沒有補回任何一串時，檔案清成只剩一行 claimId 高水位；有補回的就整份留著，等之後開機在 registry 看到才一起清
--   （不原地覆寫唯一的一份：覆寫到一半當機會丟掉補回用的資料）。補回之後、存檔之前又當機時會再補一次。
-- 只記建立當下：建立之後到當機之前的分享、改名不會補回。
-- 一串＝同一張地契：建立是根（root），重新框選把同一串接到新的 claimId（重新框選不扣也不退地契，§7.6）。
-- 檔案每行 tab 分隔，照行的順序重播：
--   C<TAB>claimId<TAB>root<TAB>屋主<TAB>等級<TAB>來源<TAB>建立時間<TAB>x,y,w,h,建立時間;…<TAB>標題   建立、重新框選
--   I<TAB>root                                                                                 背包已存
--   X<TAB>claimId                                                                              這一間已放棄或釋出
--   H<TAB>claimId                                                                              清檔時的 claimId 高水位
-- 字串字面值只用 ASCII（Kahlua 把非 ASCII 字面值截成單 byte，server-core.md 已知坑）。

if isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Audit"
require "MinidoracatSafehouse/Registry"
require "MinidoracatSafehouse/Server"
require "MinidoracatSafehouse/Native"

local MSH = MinidoracatSafehouse
local J = MSH.Journal or {}
MSH.Journal = J

local LC = MSH.LIFECYCLE

-- 背包最晚 180 秒＋0.5 秒 commit 一定存過（出處見檔頭），留約 29 秒餘裕
J.INV_DELAY_MS = 210000
J.TICK_MS = 5000
J.MAX_LINES = 100000
J.UNCONFIRMED = "CRASH_UNCONFIRMED"

J.chains = J.chains or {}   -- root → { inv, dueAt }：這次開機建立、等著補 I 的串
J.byId = J.byId or {}       -- claimId → root：檔案裡還沒結束的串（放棄要寫 X、重新框選要接著寫 C）
J.last = J.last or { restored = 0, unconfirmed = 0 }

function J.path()
    return MSH.Registry.privateFile("crash-journal.txt")
end

local function append(lines)
    return MSH.Registry.writeLines(J.path(), lines, true)
end

-- 數字寫成整數字串（毫秒時間是 double，tostring 可能變科學記號）；沒有值寫 -
local function num(v)
    if not MSH.isFinite(v) then return "-" end
    return string.format("%.0f", v)
end

local function encodeRects(rects)
    local parts = {}
    for i, p in ipairs(rects) do
        parts[i] = table.concat({ num(p.x), num(p.y), num(p.w), num(p.h), num(p.created) }, ",")
    end
    return table.concat(parts, ";")
end

local function decodeRects(s)
    local out = {}
    for piece in string.gmatch(s, "[^;]+") do
        local f = {}
        for v in string.gmatch(piece, "[^,]+") do f[#f + 1] = v end
        if #f ~= 5 then return nil end
        local p = { x = tonumber(f[1]), y = tonumber(f[2]), w = tonumber(f[3]), h = tonumber(f[4]) }
        if f[5] ~= "-" then
            p.created = tonumber(f[5])
            if p.created == nil then return nil end
        end
        if not MSH.Rect.valid(p) then return nil end
        out[#out + 1] = p
    end
    if #out == 0 or #out > MSH.LIMIT.MAX_PIECES then return nil end
    return out
end

local function cLine(rec, root)
    local R = MSH.Registry
    return table.concat({ "C", num(rec.claimId), num(root), R.fileField(rec.owner), num(rec.deedTier), rec.source,
        num(rec.createdAt), encodeRects(rec.rects), R.fileField(rec.title or "") }, "\t")
end

local function failed(rec, code)
    MSH.Audit.write("JOURNAL_FAILED", { actor = rec and rec.owner, claimId = rec and rec.claimId, code = code })
end

-- Claims.commitCreate commit 之後。寫不了檔只記 audit：屋子已經建好，不讓建立失敗
function J.created(rec, now)
    if not append({ cLine(rec, rec.claimId) }) then return failed(rec, "CREATE") end
    J.byId[rec.claimId] = rec.claimId
    local deed = rec.source == MSH.SOURCE.DEED
    J.chains[rec.claimId] = { inv = not deed, dueAt = now + J.INV_DELAY_MS }
end

-- Claims.commitRedraw 成功之後：舊的那一間還在檔案裡的串才接著記。不在＝開機時從存檔讀進來的，
-- 當機後它會跟著存檔回來（地契扣在它身上），新的那一間不用補
function J.redrawn(old, rec)
    local root = J.byId[old.claimId]
    if root == nil then return end
    if not append({ cLine(rec, root) }) then return failed(rec, "REDRAW") end
    J.byId[rec.claimId] = root
end

-- Registry.markReleased：真正的放棄寫 X。重新框選換掉的舊屋（REDRAWN）不寫：新屋的 C 行接著同一串、把最後一間換過去，
-- 兩行之間當機時這一串還停在舊屋，照舊補回舊屋；重新框選失敗、舊屋寫回 active（Registry.unrelease）時也不必再寫
function J.released(rec, reason)
    if reason == "REDRAWN" or J.byId[rec.claimId] == nil then return end
    if not append({ "X\t" .. num(rec.claimId) }) then failed(rec, "RELEASE") end
end

-- 每 TICK_MS 看一次：建立滿 INV_DELAY_MS 的串補一行 I；寫不了下次再試
function J.tick(now)
    if J.nextTick ~= nil and now < J.nextTick then return end
    J.nextTick = now + J.TICK_MS
    local due = {}
    for root, ch in pairs(J.chains) do
        if not ch.inv and now >= ch.dueAt then due[#due + 1] = root end
    end
    if #due == 0 then return end
    MSH.sortSafe(due, function(a, b) return a < b end)
    local lines = {}
    for i, root in ipairs(due) do lines[i] = "I\t" .. num(root) end
    if not append(lines) then return end
    for _, root in ipairs(due) do J.chains[root].inv = true end
end

-- 照行的順序重播：每一串的每一間（nodes）、最後一間（head）、是不是已經放棄、背包存了沒；壞行略過並計數
local function parse(lines)
    local out = { chains = {}, ids = {}, high = 0, bad = 0 }
    local rootOf = {}
    local function chain(root)
        local ch = out.chains[root]
        if ch == nil then
            ch = { root = root, nodes = {}, inv = false }
            out.chains[root] = ch
        end
        return ch
    end
    for _, line in ipairs(lines) do
        local f = MSH.Registry.splitTabs(line)
        local id = tonumber(f[2])
        local ok = false
        if f[1] == "C" and #f == 9 and MSH.isInt(id) and MSH.isInt(tonumber(f[3])) then
            local rects, tier, at = decodeRects(f[8]), tonumber(f[5]), tonumber(f[7])
            if rects ~= nil and MSH.isInt(tier) and MSH.isFinite(at) then
                local ch = chain(tonumber(f[3]))
                ch.head = { claimId = id, owner = f[4], tier = tier, source = f[6], createdAt = at, rects = rects,
                    title = f[9] }
                ch.nodes[id] = ch.head
                ch.dead = false
                rootOf[id] = ch.root
                out.ids[id] = true
                ok = true
            end
        elseif f[1] == "I" and #f == 2 and MSH.isInt(id) then
            chain(id).inv = true
            ok = true
        elseif f[1] == "X" and #f == 2 and MSH.isInt(id) then
            local ch = rootOf[id] and out.chains[rootOf[id]]
            if ch and ch.head.claimId == id then ch.dead = true end
            out.ids[id] = true
            ok = true
        elseif f[1] == "H" and #f == 2 and MSH.isInt(id) then
            if id > out.high then out.high = id end
            ok = true
        end
        if not ok and line ~= "" then out.bad = out.bad + 1 end
    end
    return out
end

-- startup order 10：讀檔、抬 nextClaimId（必須在 Migration order 11 的 allocId 之前）。
-- 超過 MAX_LINES 時只讀得到前段，照前段補可能補到後段已經放棄的屋：只抬 claimId，不補也不改檔
function J.load()
    J.parsed = nil
    local R = MSH.Registry
    if not R.ready() then return end
    local lines = R.readLines(J.path(), J.MAX_LINES + 1)
    if lines == false then
        MSH.Audit.write("JOURNAL_CHECK", { code = "FILE_UNREADABLE" })
        return
    end
    lines = lines or {}
    local p = parse(lines)
    for id in pairs(p.ids) do R.raiseNextId(id) end
    R.raiseNextId(p.high)
    if p.bad > 0 then MSH.Audit.write("JOURNAL_CHECK", { code = "BAD_LINES", detail = "n=" .. p.bad }) end
    if #lines > J.MAX_LINES then
        MSH.Audit.write("JOURNAL_CHECK", { code = "TOO_LONG", detail = "max=" .. J.MAX_LINES })
        return
    end
    J.parsed = p
end

-- 存檔裡有這一間的標記原生時，指紋改用原生的建立時間（Native.pieceOf、Reconcile 的同一代判斷才配得上）
local function adoptCreated(rects, entries)
    for _, p in ipairs(rects) do
        for _, e in ipairs(entries or {}) do
            if MSH.Rect.equals(p, e.rect) then p.created = e.house:getDatetimeCreated() end
        end
    end
end

local function newRecord(node, lifecycle)
    return MSH.Registry.newRecord({ claimId = node.claimId, rects = node.rects,
        title = MSH.cleanTitle(node.title) or node.owner, owner = node.owner, source = node.source,
        deedTier = node.tier, createdAt = node.createdAt, lifecycle = lifecycle })
end

-- 照最後那一間寫回紀錄；回傳紀錄與「地契確定扣掉了沒」（不合格回 nil）
local function restoreOne(ch, entries)
    local R = MSH.Registry
    local h = ch.head
    if not MSH.validUsername(h.owner) then return nil end
    adoptCreated(h.rects, entries)
    local sure = h.source ~= MSH.SOURCE.DEED or ch.inv
    local rec = newRecord(h, sure and LC.ACTIVE or LC.QUARANTINED)
    if not sure then
        rec.quarantineReason = J.UNCONFIRMED
        rec.candidates = { h.owner }
    end
    if not R.validRecord(h.claimId, rec) then return nil end
    R.put(rec)
    R.raiseNextId(h.claimId)
    if sure then
        MSH.Audit.write("CRASH_RESTORED", { actor = h.owner, claimId = h.claimId, code = h.source })
    else
        MSH.Audit.write("QUARANTINE", { actor = h.owner, claimId = h.claimId, code = J.UNCONFIRMED })
    end
    return rec, sure
end

-- 同一串沒補回的那幾間（keepId 以外）：存檔裡還有它們的原生（原生寫進了存檔、Global ModData 沒有）就寫 tombstone，
-- 首輪 Reconcile 照同一代拆掉（convergeTombs）
local function retire(ch, idx, now, keepId)
    for id, node in pairs(ch.nodes) do
        local entries = idx.byClaim[id]
        if id ~= keepId and entries ~= nil then
            adoptCreated(node.rects, entries)
            MSH.Registry.markReleased(newRecord(node, LC.ACTIVE), "CRASH_RETIRED", now)
        end
    end
end

-- startup order 15：見檔頭
function J.restore(now)
    local R = MSH.Registry
    local p = J.parsed
    J.parsed = nil
    if p == nil or not R.ready() then return end
    local roots = {}
    for root, ch in pairs(p.chains) do
        if ch.head ~= nil then roots[#roots + 1] = root end
    end
    MSH.sortSafe(roots, function(a, b) return a < b end)
    local kept, alive, restored, unconfirmed = 0, {}, 0, 0
    local res = MSH.Srv.withLock(function()
        local idx = MSH.Native.index()
        for _, root in ipairs(roots) do
            local ch = p.chains[root]
            local saved = false
            for id in pairs(ch.nodes) do
                if R.md.claims[id] ~= nil or R.md.tombs[id] ~= nil then saved = true end
            end
            if saved then
                if not ch.dead then alive[ch.head.claimId] = root end
            elseif ch.dead then
                retire(ch, idx, now, nil)
            else
                local rec, sure = restoreOne(ch, idx.byClaim[ch.head.claimId])
                if rec == nil then
                    MSH.Audit.write("JOURNAL_CHECK", { claimId = ch.head.claimId, code = "BAD_RECORD" })
                else
                    retire(ch, idx, now, rec.claimId)
                    alive[rec.claimId] = root
                    kept = kept + 1
                    if sure then restored = restored + 1 else unconfirmed = unconfirmed + 1 end
                end
            end
        end
        return MSH.Srv.ok()
    end)
    J.last = { restored = restored, unconfirmed = unconfirmed, at = now }
    if restored + unconfirmed > 0 then
        MSH.Audit.write("CRASH_RESTORE", { detail = "restored=" .. restored .. " unconfirmed=" .. unconfirmed })
    end
    if not (type(res) == "table" and res.ok) then return end
    if kept == 0 then
        -- 沒有要等確認的串：清成只剩高水位（之後開機抬 nextClaimId 用）
        if not R.writeLines(J.path(), { "H\t" .. num(R.md.nextClaimId - 1) }, false) then failed(nil, "TRUNCATE") end
        return
    end
    -- 檔案整份留著：裡面還沒結束的串，這次開機放棄時照樣寫 X、重新框選照樣接著寫
    for id, root in pairs(alive) do J.byId[id] = root end
end

-- 給管理員面板（adminClaims）：這次開機補回幾間、幾間要管理員決定
function J.status()
    return { restored = J.last.restored or 0, unconfirmed = J.last.unconfirmed or 0 }
end

MSH.Srv.hook("startup", "journalLoad", function() MSH.Journal.load() end, 10)
MSH.Srv.hook("startup", "journalRestore", function(now) MSH.Journal.restore(now) end, 15)
MSH.Srv.hook("tick", "journal", function(now) MSH.Journal.tick(now) end)
