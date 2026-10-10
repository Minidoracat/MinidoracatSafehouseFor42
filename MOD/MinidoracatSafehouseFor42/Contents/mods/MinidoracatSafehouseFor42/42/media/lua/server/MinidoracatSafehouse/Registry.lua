-- MinidoracatSafehouse/Registry.lua：canonical registry（Global ModData，公開）與伺服器私有儲存（檔案）。
-- registry 是 managed／legacy 安全屋的唯一真相，伺服器是唯一寫入者（計畫 §4.2）：
--   任何已登入的客戶端都能 ModData.request 整張表（GlobalModData.java:180-197），所以只放刻意公開的資料；
--   客戶端 transmit 同 tag 時 Java 只觸發 OnReceiveGlobalModData、不寫回（GlobalModDataPacket.java:45-55），本 MOD 不聽這個事件。
-- 私有資料（個人上限 overrides、身分綁定 bindings）不進 Global ModData 也不進沙盒，
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

-- schema 1 的單筆檢查；不合格的整筆轉 quarantined（不當 foreign、不當 released，§4.2）
function R.validRecord(id, rec)
    if type(rec) ~= "table" then return false end
    if not MSH.isInt(id) or id < 1 or rec.claimId ~= id then return false end
    if not MSH.isInt(rec.revision) or rec.revision < 0 then return false end
    if not VALID_LIFECYCLE[rec.lifecycle] then return false end
    if not Rect.valid(rec.rect) then return false end
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
    if rec.nativeCreatedAt ~= nil and not MSH.isFinite(rec.nativeCreatedAt) then return false end
    if not MSH.isInt(rec.bootSeen) then return false end
    if not MSH.isFinite(rec.createdAt) then return false end
    return true
end

-- 不合格的紀錄：原內容整份搬到 raw（不猜、不刪），本體換成欄位齊全的 quarantined，讓其他模組照常運作；
-- 沒有合法 rect 的標 malformed，不佔範圍、不進 R.list()，只在 R.listAll() 給管理員 targeted recovery（§4.2）
local function quarantineMalformed(md, id, rec)
    if not MSH.isInt(id) or id < 1 then
        MSH.Audit.write("QUARANTINE", { claimId = id, code = "MALFORMED_KEY" })
        return
    end
    local raw = type(rec) == "table" and rec or { value = tostring(rec) }
    local rect = type(rec) == "table" and Rect.valid(rec.rect) and Rect.copy(rec.rect) or nil
    md.claims[id] = {
        claimId = id,
        revision = (type(rec) == "table" and MSH.isInt(rec.revision) and rec.revision >= 0) and rec.revision or 0,
        lifecycle = LC.QUARANTINED,
        quarantineReason = "MALFORMED",
        malformed = rect == nil or nil,
        rect = rect,
        title = "",
        deedTier = 1,
        owner = type(raw.owner) == "string" and raw.owner or nil,
        source = MSH.SOURCE.DEED,
        grants = {},
        nativeCreatedAt = MSH.isFinite(raw.nativeCreatedAt) and raw.nativeCreatedAt or nil,
        bootSeen = md.bootSeq,
        createdAt = MSH.isFinite(raw.createdAt) and raw.createdAt or 0,
        raw = raw,
    }
    MSH.Audit.write("QUARANTINE", { claimId = id, code = "MALFORMED" })
end

-- ===== released tombstone：精簡成一個字串，放 md.tombs[claimId] =====
-- 「x,y,w,h,nativeCreatedAt,bootSeen,releasedAt」，沒有的值寫 -1。一筆約 60 bytes：軟上限 1,024 筆加上 256 間
-- 佔位中的紀錄才放得進 256 KiB（§4.2）；整筆紀錄當 tombstone 一筆約 400 bytes，放不下。
-- tombstone 只用來判斷「同一代原生是否重現」（rect＋建立時間）與 GC（bootSeen、releasedAt），§6.2。
local function num(v)
    if MSH.isFinite(v) then return tostring(v) end
    return "-1"
end

local function encodeTomb(rect, nativeCreatedAt, bootSeen, releasedAt)
    local r = rect or {}
    return table.concat({ num(r.x), num(r.y), num(r.w), num(r.h), num(nativeCreatedAt), num(bootSeen), num(releasedAt) }, ",")
end

local function decodeTomb(id, s)
    if type(s) ~= "string" then return nil end
    local f = {}
    for part in string.gmatch(s, "[^,]+") do f[#f + 1] = tonumber(part) end
    if #f ~= 7 then return nil end
    local rect = { x = f[1], y = f[2], w = f[3], h = f[4] }
    return {
        claimId = id,
        rect = Rect.valid(rect) and rect or nil,
        nativeCreatedAt = f[5] >= 0 and f[5] or nil,
        bootSeen = f[6] >= 0 and f[6] or nil,
        releasedAt = f[7] >= 0 and f[7] or nil,
    }
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
        md.tombs[id] = encodeTomb(rec.rect, rec.nativeCreatedAt, rec.bootSeen, rec.releasedAt)
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
        rect = Rect.copy(f.rect),
        title = f.title or "",
        deedTier = f.deedTier or 1,
        owner = f.owner,
        source = f.source,
        grants = f.grants or {},
        factionShare = f.factionShare,
        nativeCreatedAt = f.nativeCreatedAt,
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

-- 生命週期轉移（放棄與收斂共用；都寫 audit）
function R.markReleasing(rec, opId, nativeCreatedAt)
    rec.lifecycle = LC.RELEASING
    local rect = Rect.valid(rec.rect) and Rect.copy(rec.rect) or nil
    rec.operation = { opId = opId, revision = rec.revision, rect = rect, nativeCreatedAt = nativeCreatedAt }
    R.touch(rec)
end

-- 寫 released：整筆紀錄換成精簡 tombstone（本筆 Lua 物件照樣標 released，呼叫端還拿得到欄位）
function R.markReleased(rec, reason, now)
    rec.lifecycle = LC.RELEASED
    rec.releasedAt = now
    rec.releaseReason = reason
    rec.operation = nil
    rec.revision = rec.revision + 1
    R.md.tombs[rec.claimId] = encodeTomb(rec.rect, rec.nativeCreatedAt, R.md.bootSeq, now)
    R.md.claims[rec.claimId] = nil
    R.bumpGeneration()
    MSH.Audit.write("RELEASED", { actor = rec.owner, claimId = rec.claimId, code = reason })
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
-- 同一名字最後一行為準；壞行略過並計數。

R.bindings = R.bindings or {}
R.overrides = R.overrides or {}

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

local function applyLine(line)
    local f = {}
    for part in string.gmatch(line, "[^\t]+") do f[#f + 1] = part end
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
    end
    return false
end

-- 開服時讀一次；檔案存在卻讀不開就 fail closed（health blocked），不當成全新伺服器
function R.loadPrivate()
    R.bindings, R.overrides = {}, {}
    R.privateUnreadable, R.privateBad = false, 0
    local path = R.privatePath()
    local reader
    local opened = pcall(function() reader = getFileReader(path, false) end)
    if not opened or reader == nil then
        -- getFileReader 吞掉 IOException 回 nil（LuaManager.java:5949-5960）：用 cacheFileExists 分辨不存在與讀不開
        local ok, exists = pcall(cacheFileExists, path)
        if not ok or exists then
            R.privateUnreadable = true
            MSH.log("private store unreadable: " .. path)
        end
        return
    end
    local lines = 0
    while true do
        local line = reader:readLine()
        if line == nil then break end
        lines = lines + 1
        if lines > 200000 then break end
        if not applyLine(line) then R.privateBad = R.privateBad + 1 end
    end
    pcall(function() reader:close() end)
end

local function appendLines(lines)
    local writer
    local opened = pcall(function() writer = getFileWriter(R.privatePath(), true, true) end)
    if not opened or writer == nil then return false end
    local written = pcall(function()
        for _, line in ipairs(lines) do writer:writeln(line) end
    end)
    local closed = pcall(function() writer:close() end)
    return written and closed
end

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
