-- MinidoracatSafehouse/Registry.lua：canonical registry（Global ModData，公開）與伺服器私有儲存（檔案）。
-- registry 是 managed／legacy 安全屋的唯一真相，伺服器是唯一寫入者（計畫 §4.2）：
--   任何已登入的客戶端都能 ModData.request 整張表（GlobalModData.java:180-197），所以只放刻意公開的資料；
--   客戶端 transmit 同 tag 時 Java 只觸發 OnReceiveGlobalModData、不寫回（GlobalModDataPacket.java:45-55），本 MOD 不聽這個事件。
-- 私有資料（個人上限 overrides、身分綁定 bindings、重生點 spawns）不進 Global ModData 也不進沙盒，
-- 照 Economy ECIdentity 的做法以 append-only 文字檔存在 <cachedir>/Lua/ 下（getFileWriter 不回報 I/O 錯誤，寫失敗就不改記憶體）。

if isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Audit"

local MSH = MinidoracatSafehouse
local R = MSH.Registry or {}
MSH.Registry = R

local LC = MSH.LIFECYCLE
local Rect = MSH.Rect

local VALID_LIFECYCLE = {}
for _, v in pairs(LC) do VALID_LIFECYCLE[v] = true end
local VALID_SOURCE = {}
for _, v in pairs(MSH.SOURCE) do VALID_SOURCE[v] = true end

-- ===== 公開 registry =====

local function validGrants(g)
    if type(g) ~= "table" then return false end
    for i = 1, #g do
        local e = g[i]
        if type(e) ~= "table" or type(e.user) ~= "string" or not MSH.isInt(e.bits) then return false end
    end
    return true
end

-- 範圍的每一塊 { x, y, w, h, created }：created 是那塊原生的 getDatetimeCreated（指紋，§4.2；沒有就是 nil）
local function validPieces(rects)
    if type(rects) ~= "table" then return false end
    local n = #rects
    if n < 1 or n > MSH.LIMIT.MAX_PIECES then return false end
    for i = 1, n do
        local p = rects[i]
        if not Rect.valid(p) or (p.created ~= nil and not MSH.isFinite(p.created)) then return false end
    end
    return true
end

function R.copyPieces(rects)
    local out = {}
    for i, p in ipairs(rects) do out[i] = { x = p.x, y = p.y, w = p.w, h = p.h, created = p.created } end
    return out
end

-- schema 2 的單筆檢查；不合格的整筆轉 quarantined（不當 foreign、不當 released，§4.2）。
-- malformed（沒有合法範圍）的 quarantined 本身合格：不然每次開機都會被再包一層 raw
function R.validRecord(id, rec)
    if type(rec) ~= "table" then return false end
    if not MSH.isInt(id) or id < 1 or rec.claimId ~= id then return false end
    if not MSH.isInt(rec.revision) or rec.revision < 0 then return false end
    if not VALID_LIFECYCLE[rec.lifecycle] then return false end
    if rec.malformed then
        if rec.lifecycle ~= LC.QUARANTINED or rec.rects ~= nil then return false end
    elseif not validPieces(rec.rects) then
        return false
    end
    if type(rec.title) ~= "string" then return false end
    if not MSH.isInt(rec.deedTier) or rec.deedTier < 1 or rec.deedTier > MSH.MAX_TIER then return false end
    if not VALID_SOURCE[rec.source] then return false end
    if rec.owner == nil then
        if rec.lifecycle ~= LC.QUARANTINED then return false end
    elseif type(rec.owner) ~= "string" then
        return false
    end
    if not validGrants(rec.grants) then return false end
    if rec.factionShare ~= nil and type(rec.factionShare) ~= "table" then return false end
    if rec.operation ~= nil and type(rec.operation) ~= "table" then return false end
    if not MSH.isInt(rec.bootSeen) then return false end
    if not MSH.isFinite(rec.createdAt) then return false end
    return true
end

-- 不合格的紀錄：原內容整份搬到 raw（不猜、不刪），本體換成欄位齊全的 quarantined，讓其他模組照常運作；
-- 沒有合法範圍的標 malformed，不佔範圍、不進 R.list()，只在 R.listAll() 給管理員 targeted recovery（§4.2）
local function quarantineMalformed(md, id, rec)
    if not MSH.isInt(id) or id < 1 then
        MSH.Audit.write("QUARANTINE", { claimId = id, code = "MALFORMED_KEY" })
        return
    end
    local raw = type(rec) == "table" and rec or { value = tostring(rec) }
    local rects = type(rec) == "table" and validPieces(rec.rects) and R.copyPieces(rec.rects) or nil
    md.claims[id] = {
        claimId = id,
        revision = (type(rec) == "table" and MSH.isInt(rec.revision) and rec.revision >= 0) and rec.revision or 0,
        lifecycle = LC.QUARANTINED,
        quarantineReason = "MALFORMED",
        malformed = rects == nil or nil,
        rects = rects,
        title = "",
        deedTier = 1,
        owner = type(raw.owner) == "string" and raw.owner or nil,
        source = MSH.SOURCE.DEED,
        grants = {},
        bootSeen = md.bootSeq,
        createdAt = MSH.isFinite(raw.createdAt) and raw.createdAt or 0,
        raw = raw,
    }
    MSH.Audit.write("QUARANTINE", { claimId = id, code = "MALFORMED" })
end

-- ===== released tombstone：精簡成一個字串，放 md.tombs[claimId] =====
-- 「bootSeen,releasedAt;x,y,w,h,created;x,y,w,h,created…」（每塊一段），沒有的值寫 -1，一塊約 30 bytes。
-- 最壞（每間、每筆都用滿硬上限 LIMIT.MAX_PIECES 塊）1,024 筆加上 256 間佔位中的紀錄約 620 KB，放得進 LIMIT.REGISTRY_BYTES（§4.2）；
-- 整筆紀錄當 tombstone 一筆約 400 bytes，放不下。
-- tombstone 只用來判斷「同一代原生是否重現」（每塊的範圍＋建立時間）與 GC（bootSeen、releasedAt），§6.2。
local function num(v)
    if MSH.isFinite(v) then return tostring(v) end
    return "-1"
end

local function encodeTomb(rects, bootSeen, releasedAt)
    local parts = { num(bootSeen) .. "," .. num(releasedAt) }
    for _, p in ipairs(rects or {}) do
        parts[#parts + 1] = table.concat({ num(p.x), num(p.y), num(p.w), num(p.h), num(p.created) }, ",")
    end
    return table.concat(parts, ";")
end

local function decodeTomb(id, s)
    if type(s) ~= "string" then return nil end
    local head, rects = nil, {}
    for part in string.gmatch(s, "[^;]+") do
        local f = {}
        for v in string.gmatch(part, "[^,]+") do f[#f + 1] = tonumber(v) end
        if head == nil then
            if #f ~= 2 then return nil end
            head = f
        else
            local p = #f == 5 and { x = f[1], y = f[2], w = f[3], h = f[4], created = f[5] >= 0 and f[5] or nil } or nil
            if p == nil or not Rect.valid(p) then return nil end
            rects[#rects + 1] = p
        end
    end
    if head == nil then return nil end
    return {
        claimId = id,
        rects = #rects > 0 and rects or nil,
        bootSeen = head[1] >= 0 and head[1] or nil,
        releasedAt = head[2] >= 0 and head[2] or nil,
    }
end

-- schema 1 → 2（一間多塊）：紀錄的 rect＋nativeCreatedAt 變成 rects 的第一塊，releasing 的 operation 同樣換；
-- 舊 tombstone「x,y,w,h,nativeCreatedAt,bootSeen,releasedAt」換成新格式（沒有範圍的只留 bootSeen,releasedAt）。
-- 換不了的（欄位壞掉）照舊交給後面的檢查：紀錄轉 quarantined、tombstone 丟掉並記 audit
local function upgradeFrom1(md)
    for _, rec in pairs(md.claims) do
        if type(rec) == "table" and rec.rects == nil and type(rec.rect) == "table" then
            local r = rec.rect
            rec.rects = { { x = r.x, y = r.y, w = r.w, h = r.h, created = rec.nativeCreatedAt } }
            rec.rect, rec.nativeCreatedAt = nil, nil
            local op = rec.operation
            if type(op) == "table" and type(op.rect) == "table" then
                local o = op.rect
                op.rects = { { x = o.x, y = o.y, w = o.w, h = o.h, created = op.nativeCreatedAt } }
                op.rect, op.nativeCreatedAt = nil, nil
            end
        end
    end
    for id, s in pairs(md.tombs or {}) do
        if type(s) == "string" and not string.find(s, ";", 1, true) then
            local f = {}
            for part in string.gmatch(s, "[^,]+") do f[#f + 1] = part end
            if #f == 7 then
                local head = f[6] .. "," .. f[7]
                md.tombs[id] = f[1] == "-1" and head or (head .. ";" .. table.concat({ f[1], f[2], f[3], f[4], f[5] }, ","))
            end
        end
    end
    MSH.log("registry upgraded from schema 1")
end

-- OnInitGlobalModData：載入或建立 registry。不在這裡判 native 缺漏（native 還沒載入，§6 啟動時序）。
function R.init()
    local md = ModData.getOrCreate(MSH.TAG)
    R.md = md
    R.readOnly = false
    if md.schemaVersion == nil and md.claims == nil then
        md.schemaVersion = MSH.SCHEMA
        md.protocolVersion = MSH.PROTOCOL
        md.generation = 0
        md.nextClaimId = 1
        md.bootSeq = 0
        md.claims = {}
        md.tombs = {}
    end
    -- 比目前新的 schema：整份唯讀、health blocked、不改寫（fail closed，§4.2）
    if not MSH.isInt(md.schemaVersion) or md.schemaVersion > MSH.SCHEMA or type(md.claims) ~= "table"
        or not MSH.isInt(md.nextClaimId) or not MSH.isInt(md.generation) or not MSH.isInt(md.bootSeq)
        or (md.tombs ~= nil and type(md.tombs) ~= "table") then
        R.readOnly = true
        MSH.Audit.write("REGISTRY_READONLY", { detail = "schema " .. tostring(md.schemaVersion) })
        MSH.log("registry is read-only (schema " .. tostring(md.schemaVersion) .. ")")
        return
    end
    if md.schemaVersion == 1 then upgradeFrom1(md) end
    md.schemaVersion = MSH.SCHEMA
    md.protocolVersion = MSH.PROTOCOL
    md.tombs = md.tombs or {}
    local maxId, bad, released, badTombs = 0, {}, {}, {}
    for id, rec in pairs(md.claims) do
        if MSH.isInt(id) and id > maxId then maxId = id end
        if type(rec) == "table" and rec.lifecycle == LC.RELEASED and MSH.isInt(id) then
            released[#released + 1] = id
        elseif not R.validRecord(id, rec) then
            bad[#bad + 1] = id
        end
    end
    -- 舊格式的 released 整筆紀錄 → 精簡 tombstone
    for _, id in ipairs(released) do
        local rec = md.claims[id]
        md.tombs[id] = encodeTomb(type(rec.rects) == "table" and rec.rects or nil, rec.bootSeen, rec.releasedAt)
        md.claims[id] = nil
    end
    for _, id in ipairs(bad) do quarantineMalformed(md, id, md.claims[id]) end
    for id, s in pairs(md.tombs) do
        if MSH.isInt(id) and id > maxId then maxId = id end
        if not MSH.isInt(id) or decodeTomb(id, s) == nil then badTombs[#badTombs + 1] = id end
    end
    for _, id in ipairs(badTombs) do
        md.tombs[id] = nil
        MSH.Audit.write("TOMBSTONE_DROPPED", { claimId = id, code = "MALFORMED" })
    end
    -- claimId 永不重用：nextClaimId 至少是現有最大 id＋1（含 tombstone）
    if md.nextClaimId <= maxId then md.nextClaimId = maxId + 1 end
end

function R.ready()
    return R.md ~= nil and not R.readOnly
end

function R.get(id)
    if R.md == nil or not MSH.isInt(id) then return nil end
    local rec = R.md.claims[id]
    if type(rec) ~= "table" then return nil end
    return rec
end

-- 依 claimId 由小到大走訪佔位中的紀錄；沒有合法 rect 的 malformed 紀錄不在內（見 listAll）
function R.list()
    local out = {}
    if R.md == nil then return out end
    for id, rec in pairs(R.md.claims) do
        if MSH.isInt(id) and type(rec) == "table" and not rec.malformed then out[#out + 1] = rec end
    end
    MSH.sortSafe(out, function(a, b) return a.claimId < b.claimId end)
    return out
end

-- 全部紀錄（含 malformed），給管理員 targeted recovery 與遷移核對
function R.listAll()
    local out = {}
    if R.md == nil then return out end
    for id, rec in pairs(R.md.claims) do
        if MSH.isInt(id) and type(rec) == "table" then out[#out + 1] = rec end
    end
    MSH.sortSafe(out, function(a, b) return a.claimId < b.claimId end)
    return out
end

-- claimId 單調遞增、不重用；交易失敗也會用掉（§4.2、§7.4）
function R.allocId()
    local id = R.md.nextClaimId
    R.md.nextClaimId = id + 1
    return id
end

-- 高水位回復：看到 native 標記的 id 時把 nextClaimId 抬到它之後（recovery matrix，§6.2）
function R.raiseNextId(id)
    if MSH.isInt(id) and R.md.nextClaimId <= id then R.md.nextClaimId = id + 1 end
end

function R.bumpGeneration()
    R.md.generation = R.md.generation + 1
end

function R.newRecord(f)
    return {
        claimId = f.claimId,
        revision = 1,
        lifecycle = f.lifecycle or LC.ACTIVE,
        rects = R.copyPieces(f.rects),
        title = f.title or "",
        deedTier = f.deedTier or 1,
        owner = f.owner,
        source = f.source,
        grants = f.grants or {},
        factionShare = f.factionShare,
        operation = nil,
        bootSeen = R.md.bootSeq,
        createdAt = f.createdAt,
    }
end

function R.put(rec)
    R.md.claims[rec.claimId] = rec
    R.bumpGeneration()
end

-- 移除剛加入、尚未 commit 的紀錄（交易反序回滾，§7.4 第 6 步）
function R.unput(id)
    R.md.claims[id] = nil
    R.bumpGeneration()
end

-- domain 變更：revision＋1（純 native 重建不加，§4.2）
function R.touch(rec)
    rec.revision = rec.revision + 1
    R.bumpGeneration()
end

function R.isLive(rec)
    return rec.lifecycle ~= LC.RELEASED
end

-- 佔位的紀錄：released 已搬到 tombstone，claims 裡全部佔位（lapsed 照樣擋別人，§1.3）；malformed 也算一筆
function R.liveCount()
    return #R.listAll()
end

function R.tombstoneCount()
    local n = 0
    if R.md == nil then return n end
    for _ in pairs(R.md.tombs) do n = n + 1 end
    return n
end

function R.tomb(id)
    if R.md == nil or not MSH.isInt(id) then return nil end
    return decodeTomb(id, R.md.tombs[id])
end

-- 依 claimId 由小到大的 tombstone 清單（解碼後）
function R.tombList()
    local out = {}
    if R.md == nil then return out end
    for id, s in pairs(R.md.tombs) do
        local t = MSH.isInt(id) and decodeTomb(id, s) or nil
        if t then out[#out + 1] = t end
    end
    MSH.sortSafe(out, function(a, b) return a.claimId < b.claimId end)
    return out
end

function R.dropTomb(id)
    R.md.tombs[id] = nil
    R.bumpGeneration()
end

-- 屋主名下佔位中的 claim，照 createdAt（同時間再照 claimId）由舊到新（名額分配順序，§1.3）
function R.byOwner(owner)
    local out = {}
    for _, rec in ipairs(R.list()) do
        if rec.owner == owner and R.isLive(rec) then out[#out + 1] = rec end
    end
    MSH.sortSafe(out, function(a, b)
        if a.createdAt ~= b.createdAt then return a.createdAt < b.createdAt end
        return a.claimId < b.claimId
    end)
    return out
end

-- 生命週期轉移（放棄與收斂共用；都寫 audit）。operation 記下要移除的每一塊（範圍＋指紋），中途當機時對得上
function R.markReleasing(rec, opId)
    rec.lifecycle = LC.RELEASING
    rec.operation = { opId = opId, revision = rec.revision, rects = rec.rects and R.copyPieces(rec.rects) or nil }
    R.touch(rec)
end

-- 寫 released：整筆紀錄換成精簡 tombstone（本筆 Lua 物件照樣標 released，呼叫端還拿得到欄位）
function R.markReleased(rec, reason, now)
    rec.lifecycle = LC.RELEASED
    rec.releasedAt = now
    rec.releaseReason = reason
    rec.operation = nil
    rec.revision = rec.revision + 1
    R.md.tombs[rec.claimId] = encodeTomb(rec.rects, R.md.bootSeq, now)
    R.md.claims[rec.claimId] = nil
    R.bumpGeneration()
    MSH.Audit.write("RELEASED", { actor = rec.owner, claimId = rec.claimId, code = reason })
    if MSH.Journal then MSH.Journal.released(rec, reason) end   -- 當機補回不復活已放棄的屋（Journal.lua）
end

-- 撤回 released（同一次指令內的反序回滾用，例：重畫的新屋建不起來時把舊屋寫回 active）
function R.unrelease(rec)
    R.md.tombs[rec.claimId] = nil
    rec.lifecycle = LC.ACTIVE
    rec.releasedAt, rec.releaseReason = nil, nil
    R.md.claims[rec.claimId] = rec
    R.touch(rec)
end

function R.markQuarantined(rec, reason)
    rec.lifecycle = LC.QUARANTINED
    rec.quarantineReason = reason
    R.touch(rec)
    MSH.Audit.write("QUARANTINE", { actor = rec.owner, claimId = rec.claimId, code = reason })
end

-- 序列化大小估算，照 KahluaTableImpl.save（se/krka/kahlua/j2se/KahluaTableImpl.java）：
-- table＝4 bytes 筆數＋每筆（鍵型別 1＋鍵）＋（值型別 1＋值）；字串＝2 bytes 長度＋UTF-8；數字 8；布林 1。
-- Kahlua 的 #s 是 UTF-16 單位，含非 ASCII 字元時一律以 3 bytes 計（寧可高估）。registry 上限 256 KiB（§4.2）。
local function estimate(v, depth)
    local t = type(v)
    if t == "string" then
        local n = #v
        if string.find(v, "[^\1-\127]") then n = n * 3 end
        return n + 3
    end
    if t == "number" then return 9 end
    if t == "boolean" then return 2 end
    if t ~= "table" or depth > 8 then return 1 end
    local n = 5
    for k, x in pairs(v) do n = n + estimate(k, depth + 1) + estimate(x, depth + 1) end
    return n
end

function R.estimateBytes(extra)
    return estimate(R.md, 0) + (extra and estimate(extra, 0) or 0)
end

-- ===== 伺服器私有儲存 =====
-- 每行：1<TAB>bind<TAB>名字<TAB>SteamID 十進位<TAB>來源<TAB>毫秒  或  1<TAB>over<TAB>名字<TAB>上限（-1＝刪除）
--   或  1<TAB>spawn<TAB>名字<TAB>x<TAB>y<TAB>z（重生點，整數格）  或  1<TAB>spawn<TAB>名字<TAB>-（刪除重生點）
-- 同一名字最後一行為準；壞行略過並計數。

R.bindings = R.bindings or {}
R.overrides = R.overrides or {}
R.spawns = R.spawns or {}
R.spawnSeen = R.spawnSeen or {}   -- 名字 → true：私有檔出現過這個名字的 spawn 行（含刪除行；Respawn.migrateLegacy 用）

local function serverKey()
    local name = getServerName and getServerName() or nil
    if type(name) ~= "string" or name == "" then name = "default" end
    return (string.gsub(name, "[^%w_%-]", "_"))
end

function R.privatePath()
    return "MinidoracatSafehouse/" .. serverKey() .. "/private.txt"
end

-- SteamID 是 long，進 Lua 變 double（捨入到 16 的倍數）；文字用兩半拼出精確十進位，
-- 不用 tostring／%d（≥1e14 會變科學記號，家族 conventions「玩家身分」第 4 點；Economy Id.sidText）
function R.sidText(v)
    local hi = math.floor(v / 1e9)
    local lo = v - hi * 1e9
    if lo < 0 then hi, lo = hi - 1, lo + 1e9 elseif lo >= 1e9 then hi, lo = hi + 1, lo - 1e9 end
    local low = tostring(math.floor(lo))
    if hi <= 0 then return low end
    return tostring(math.floor(hi)) .. string.rep("0", 9 - #low) .. low
end

local function sidFromText(text)
    if type(text) ~= "string" or #text > 19 or not string.find(text, "^%d+$") then return nil end
    local n = tonumber(text)
    if n == nil or n <= 0 or n ~= n then return nil end
    return n + 0.0
end

-- spawn 行的欄位（已切好的 f）：回 名字, 點 或 名字, false（刪除行）；不合格回 nil
local function parseSpawn(f)
    if f[2] ~= "spawn" or not MSH.validUsername(f[3]) then return nil end
    if #f == 4 then
        if f[4] ~= "-" then return nil end
        return f[3], false
    end
    if #f ~= 6 then return nil end
    local x, y, z = tonumber(f[4]), tonumber(f[5]), tonumber(f[6])
    if not (MSH.isInt(x) and MSH.isInt(y) and MSH.isInt(z)) then return nil end
    return f[3], { x = x, y = y, z = z }
end

local function splitLine(line)
    local f = {}
    for part in string.gmatch(line, "[^\t]+") do f[#f + 1] = part end
    return f
end

local function applyLine(line)
    local f = splitLine(line)
    if f[1] ~= "1" then return false end
    if f[2] == "bind" and #f == 6 and MSH.validUsername(f[3]) then
        local sid, at = sidFromText(f[4]), tonumber(f[6])
        if sid == nil or at == nil then return false end
        R.bindings[f[3]] = { sid = sid, src = f[5], at = at }
        return true
    elseif f[2] == "over" and #f == 4 and MSH.validUsername(f[3]) then
        local n = tonumber(f[4])
        if not MSH.isInt(n) then return false end
        if n < 0 then R.overrides[f[3]] = nil else R.overrides[f[3]] = n end
        return true
    elseif f[2] == "spawn" then
        local name, pt = parseSpawn(f)
        if name == nil then return false end
        R.spawns[name] = pt or nil
        R.spawnSeen[name] = true
        return true
    end
    return false
end

-- 開服時讀一次；檔案存在卻讀不開就 fail closed（health blocked），不當成全新伺服器
function R.loadPrivate()
    R.bindings, R.overrides, R.spawns, R.spawnSeen = {}, {}, {}, {}
    R.privateUnreadable, R.privateBad = false, 0
    local lines = R.readLines(R.privatePath(), 200000)
    if lines == false then
        R.privateUnreadable = true
        MSH.log("private store unreadable: " .. R.privatePath())
        return
    end
    for _, line in ipairs(lines or {}) do
        if not applyLine(line) then R.privateBad = R.privateBad + 1 end
    end
end

local function appendLines(lines) return R.writeLines(R.privatePath(), lines, true) end

function R.binding(name)
    return R.bindings[name]
end

-- 先寫檔、成功才改記憶體
function R.setBinding(name, sid, src, now)
    if not MSH.validUsername(name) or not MSH.isFinite(sid) or sid <= 0 then return false end
    local line = table.concat({ "1", "bind", name, R.sidText(sid), MSH.logSafe(src), tostring(math.floor(now)) }, "\t")
    if not appendLines({ line }) then return false end
    R.bindings[name] = { sid = sid, src = src, at = now }
    R.namesVersion = (R.namesVersion or 0) + 1
    return true
end

function R.override(name)
    return R.overrides[name]
end

-- n＝nil 刪除個人上限（回到全服預設）
function R.setOverride(name, n)
    if not MSH.validUsername(name) then return false end
    if n ~= nil and (not MSH.isInt(n) or n < 0) then return false end
    local line = table.concat({ "1", "over", name, tostring(n or -1) }, "\t")
    if not appendLines({ line }) then return false end
    R.overrides[name] = n
    R.namesVersion = (R.namesVersion or 0) + 1
    return true
end

-- 重生點 { x, y, z }（整數格；Respawn.lua）；沒有回 nil
function R.spawn(name)
    return R.spawns[name]
end

-- 私有檔出現過這個名字的 spawn 行（設過或刪過）
function R.spawnKnown(name)
    return R.spawnSeen[name] == true
end

-- 重新讀私有檔，回 名字 → 點（最後一行為準；刪除後是 false）；讀不到回 nil。只讀不改記憶體：
-- getFileWriter 的 PrintWriter 寫失敗不丟錯（Respawn.migrateLegacy 用它確認真的寫進去了）
function R.fileSpawns()
    local lines = R.readLines(R.privatePath(), 200000)
    if not lines then return nil end
    local out = {}
    for _, line in ipairs(lines) do
        local f = splitLine(line)
        if f[1] == "1" then
            local name, pt = parseSpawn(f)
            if name ~= nil then out[name] = pt end
        end
    end
    return out
end

-- pt＝nil 刪除重生點；先寫檔、成功才改記憶體
function R.setSpawn(name, pt)
    if not MSH.validUsername(name) then return false end
    local fields = { "1", "spawn", name, "-" }
    if pt ~= nil then
        if not (MSH.isInt(pt.x) and MSH.isInt(pt.y) and MSH.isInt(pt.z)) then return false end
        fields = { "1", "spawn", name, tostring(pt.x), tostring(pt.y), tostring(pt.z) }
    end
    if not appendLines({ table.concat(fields, "\t") }) then return false end
    R.spawns[name] = pt and { x = pt.x, y = pt.y, z = pt.z } or nil
    R.spawnSeen[name] = true
    return true
end

-- ===== 私有目錄的檔案讀寫（private.txt，以及同目錄遷移的 migration-completion.txt、當機補回的 crash-journal.txt）=====
-- getFileWriter／getFileReader 只碰 <cachedir>/Lua/ 底下，副檔名要在白名單內（LuaManager.java:1035，.txt 可以）。

function R.privateFile(name)
    return (string.gsub(R.privatePath(), "private%.txt$", name))
end

-- getFileWriter(path, createIfNull, append)：LuaManager.java:6727（UTF-8）；writeln：LuaManager.java:12834。
-- close() 才把內容交給作業系統（沒有 fsync）：伺服器程序當掉時，已 close 的行留在檔案裡
function R.writeLines(path, lines, append)
    local writer
    local opened = pcall(function() writer = getFileWriter(path, true, append) end)
    if not opened or writer == nil then return false end
    local written = pcall(function()
        for _, line in ipairs(lines) do writer:writeln(line) end
    end)
    local closed = pcall(function() writer:close() end)
    return written and closed
end

-- 回傳行陣列（最多 max 行）；檔案不存在回 nil；存在卻讀不開回 false
function R.readLines(path, max)
    local reader
    -- getFileReader 吞掉 IOException 回 nil（LuaManager.java:5936；UTF-8）；用 cacheFileExists（LuaManager.java:5544）分辨不存在與讀不開
    local opened = pcall(function() reader = getFileReader(path, false) end)
    if not opened or reader == nil then
        local ok, exists = pcall(cacheFileExists, path)
        if ok and not exists then return nil end
        return false
    end
    local lines = {}
    -- readLine 也會丟 IOException：讀到一半壞掉一樣回 false（讀不開），不讓例外中斷開服的載入、留下讀了一半當成讀完的資料
    local read = pcall(function()
        while #lines < max do
            local line = reader:readLine()
            if line == nil then break end
            lines[#lines + 1] = line
        end
    end)
    pcall(function() reader:close() end)
    if not read then return false end
    return lines
end

-- 一行切成欄位（tab 分隔、保留空欄）
function R.splitTabs(line)
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

-- 檔案欄位不能含 tab／換行
function R.fileField(v)
    return (string.gsub(tostring(v), "%c", " "))
end
