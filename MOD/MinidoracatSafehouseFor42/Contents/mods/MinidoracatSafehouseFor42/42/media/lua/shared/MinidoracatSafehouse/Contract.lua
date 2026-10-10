-- MinidoracatSafehouse/Contract.lua：伺服器與客戶端共用的常數、結果碼、矩形與輸入驗證。
-- 設計見 .omc/plans/minidoracat-safehouse-management-plan.md §4（資料模型）、§6.1（指令契約）。
-- Kahlua：不用 next／xpcall／table.sort／os.clock（verify_mod.py 靜態掃描）。

MinidoracatSafehouse = MinidoracatSafehouse or {}
local MSH = MinidoracatSafehouse

MSH.MOD_ID = "MinidoracatSafehouseFor42"
MSH.MODULE = "MinidoracatSafehouse"   -- sendClientCommand／sendServerCommand 的 module
MSH.PROTOCOL = 1                      -- 指令協定版本；不相同就拒絕（§6.1 第 1 點）
MSH.TAG = "MinidoracatSafehouse"      -- Global ModData：公開的 canonical registry（§4.2）
MSH.SCHEMA = 1                        -- registry schemaVersion
MSH.LOG_PREFIX = "[MinidoracatSafehouseFor42] "
MSH.SERVICE_PREFIX = "@MSH:"          -- managed 原生安全屋的 owner：@MSH:<claimId>（§4.2）
MSH.DEED_PREFIX = "MinidoracatSafehouse.Deed"
MSH.MAX_TIER = 8

MSH.LIMIT = {
    HARD_SIDE = 96,                -- 任何等級的邊長上限
    HARD_AREA = 9216,              -- 96 × 96
    MAX_CLAIMS = 256,              -- 全服 managed／legacy（released 以外）筆數上限
    TOMBSTONE_SOFT = 1024,         -- released tombstone 軟上限
    TOMBSTONE_GC_MS = 30 * 24 * 3600 * 1000,
    REGISTRY_BYTES = 256 * 1024,   -- registry 序列化大小上限（估算值）
    NATIVE_NAMES = 4096,           -- 全部 managed 原生名單的名字總數上限
    FACTION_PROJECTION = 64,       -- 陣營分享投影進原生名單的人數上限（M2）
    TITLE_CHARS = 40,
    USERNAME_CHARS = 32,           -- ServerWorldDatabase.java:766-788
    REQUEST_ID_MIN = 8,
    REQUEST_ID_MAX = 64,
    CACHE_TTL_MS = 60000,          -- 同 requestId 結果快取（§4.3）
    CACHE_PER_ACTOR = 64,
    CALIBRATE_MAX = 512,           -- 客戶端校正最多帶幾筆
    CALIBRATE_UPSERTS = 4,         -- 一次校正最多替幾間觸發原生廣播（正常客戶端登入時已拿到全部，§6.3）
    -- 每間在緩衝期內最多重畫幾次：重畫不扣地契、不算名額，每次都多一筆 tombstone 與兩次全服廣播；
    -- ponytail: 固定上限，要給管理員調再改成沙盒選項
    REDRAWS_PER_CLAIM = 5,
}

MSH.LIFECYCLE = {
    ACTIVE = "active",
    LAPSED = "lapsed",
    RELEASING = "releasing",
    RELEASED = "released",
    QUARANTINED = "quarantined",
}

MSH.SOURCE = { FREE = "free", DEED = "deed", LEGACY = "legacy" }

-- 分享權限位元（§6.5）；其他位元一定要搭配 MEMBER
MSH.SHARE = { MEMBER = 1, USE = 2, MOVE = 4, BUILD = 8, FARM = 16, MANAGE = 32 }
MSH.SHARE_ALL = 63
-- 遷移來的成員等同原版成員能做的事（§9 第 4 點）
MSH.SHARE_LEGACY = 1 + 2 + 4 + 8 + 16

-- 結果碼：伺服器只回這些字串；客戶端照碼顯示「原因＋動作」（M3）。
MSH.CODE = {
    OK = "OK",
    -- 指令層
    PROTOCOL_MISMATCH = "PROTOCOL_MISMATCH", UNKNOWN_COMMAND = "UNKNOWN_COMMAND",
    BAD_ARGS = "BAD_ARGS", BAD_REQUEST_ID = "BAD_REQUEST_ID", RATE_LIMITED = "RATE_LIMITED",
    BUSY = "BUSY", NOT_READY = "NOT_READY", DEDICATED_ONLY = "DEDICATED_ONLY",
    IDENTITY_UNVERIFIED = "IDENTITY_UNVERIFIED", NOT_ADMIN = "NOT_ADMIN",
    HEALTH_BLOCKED = "HEALTH_BLOCKED", MIGRATION_IN_PROGRESS = "MIGRATION_IN_PROGRESS",
    INTERNAL_ERROR = "INTERNAL_ERROR",
    -- claim 解析與權限
    NOT_FOUND = "NOT_FOUND", NOT_OWNER = "NOT_OWNER", STALE_REVISION = "STALE_REVISION",
    WRONG_LIFECYCLE = "WRONG_LIFECYCLE",
    -- 建立驗證（§7.3）
    DEAD = "DEAD", NOT_SURVIVED = "NOT_SURVIVED", NOT_ON_SITE = "NOT_ON_SITE",
    BIND_REFUSED = "BIND_REFUSED", NO_DEED = "NO_DEED", BAD_DEED = "BAD_DEED",
    TIER_DISABLED = "TIER_DISABLED", KIND_CLOSED = "KIND_CLOSED", TOO_BIG = "TOO_BIG",
    BAD_RECT = "BAD_RECT", ONLINE_ID_COLLISION = "ONLINE_ID_COLLISION",
    QUOTA_FULL = "QUOTA_FULL", TIER_FULL = "TIER_FULL", SERVER_FULL = "SERVER_FULL",
    REGISTRY_FULL = "REGISTRY_FULL", ROSTER_FULL = "ROSTER_FULL", BAD_TITLE = "BAD_TITLE",
    OVERLAP = "OVERLAP", TOO_CLOSE = "TOO_CLOSE", OCCUPIED = "OCCUPIED",
    ROAD = "ROAD", NOT_LOADED = "NOT_LOADED",
    RESOURCE = "RESOURCE", RESOURCE_PENDING = "RESOURCE_PENDING", RESOURCE_ERROR = "RESOURCE_ERROR",
    NATIVE_FAILED = "NATIVE_FAILED", DEED_REMOVE_FAILED = "DEED_REMOVE_FAILED",
    REDRAW_CLOSED = "REDRAW_CLOSED",
    -- 放棄與收斂
    RELEASE_FAILED = "RELEASE_FAILED",
    -- 管理員
    SAVE_FAILED = "SAVE_FAILED", BAD_OPTION = "BAD_OPTION", BAD_USER = "BAD_USER",
    -- 分享與細分權限（M2，§6.5、§6.6）
    SHARE_FULL = "SHARE_FULL", NO_FACTION = "NO_FACTION", FACTION_DISABLED = "FACTION_DISABLED",
    FACTION_GONE = "FACTION_GONE", BAD_FACTION = "BAD_FACTION", PERM_DENIED = "PERM_DENIED",
    -- Economy（M4，§1.3）
    ECONOMY_UNAVAILABLE = "ECONOMY_UNAVAILABLE", INVALID_PLAN = "INVALID_PLAN",
}

-- ===== 小工具 =====

function MSH.log(msg)
    print(MSH.LOG_PREFIX .. tostring(msg))
end

-- 整數（擋 NaN、±Infinity、小數）：n*0 對 NaN／Inf 不等於 0
function MSH.isInt(n)
    return type(n) == "number" and n * 0 == 0 and n == math.floor(n)
end

function MSH.isFinite(n)
    return type(n) == "number" and n * 0 == 0
end

-- 穩定的由下而上合併排序（Kahlua 的 table.sort 是遞迴 quicksort，已排序的大陣列會爆堆疊）
-- less(a, b) 只在 a 一定排在 b 前面時回 true
function MSH.sortSafe(list, less)
    local n = #list
    if n < 2 then return list end
    local buf, width = {}, 1
    while width < n do
        local i = 1
        while i <= n do
            local midEnd = math.min(i + width - 1, n)
            local hiEnd = math.min(i + width * 2 - 1, n)
            local a, b, k = i, midEnd + 1, i
            while a <= midEnd and b <= hiEnd do
                if less(list[b], list[a]) then buf[k] = list[b]; b = b + 1
                else buf[k] = list[a]; a = a + 1 end
                k = k + 1
            end
            while a <= midEnd do buf[k] = list[a]; a = a + 1; k = k + 1 end
            while b <= hiEnd do buf[k] = list[b]; b = b + 1; k = k + 1 end
            i = i + width * 2
        end
        for j = 1, n do list[j] = buf[j] end
        width = width * 2
    end
    return list
end

-- 權限位元測試（Kahlua 沒有位元運算子）
function MSH.hasBit(bits, bit)
    return MSH.isInt(bits) and bits >= 0 and math.floor(bits / bit) % 2 == 1
end

-- java.util.List 轉 Lua 陣列（0-based size()/get(i)）
function MSH.toArray(list)
    local out = {}
    if list == nil then return out end
    for i = 0, list:size() - 1 do out[#out + 1] = list:get(i) end
    return out
end

-- ===== service-owner 標記（§4.2）=====

function MSH.marker(claimId)
    return MSH.SERVICE_PREFIX .. tostring(claimId)
end

-- "@MSH:12" → 12；不是標記回 nil
function MSH.claimIdOf(owner)
    if type(owner) ~= "string" then return nil end
    local digits = string.match(owner, "^@MSH:(%d+)$")
    if digits == nil or #digits > 9 then return nil end
    return tonumber(digits)
end

-- ===== 地契等級：只由 full type 決定（物品 modData 不可信，§2.8）=====

function MSH.deedType(tier)
    return MSH.DEED_PREFIX .. tostring(tier)
end

function MSH.tierOfDeed(fullType)
    if type(fullType) ~= "string" then return nil end
    local digits = string.match(fullType, "^MinidoracatSafehouse%.Deed(%d)$")
    local tier = digits and tonumber(digits)
    if tier == nil or tier < 1 or tier > MSH.MAX_TIER then return nil end
    return tier
end

-- ===== 矩形：一律用原生的 {x, y, w, h}，半開區間 [x, x+w) × [y, y+h)，跨所有 Z（§4.1）=====

local Rect = {}
MSH.Rect = Rect

-- 框選的兩個角格是 inclusive；只在這裡轉成半開矩形
function Rect.fromCorners(ax, ay, bx, by)
    local x0, x1 = math.min(ax, bx), math.max(ax, bx)
    local y0, y1 = math.min(ay, by), math.max(ay, by)
    return { x = x0, y = y0, w = x1 - x0 + 1, h = y1 - y0 + 1 }
end

function Rect.copy(r)
    return { x = r.x, y = r.y, w = r.w, h = r.h }
end

-- 座標必須是非負整數：原生 onlineId 用 32 位元 int 計算，負座標會撞號（§2.1）
function Rect.valid(r)
    return type(r) == "table" and MSH.isInt(r.x) and MSH.isInt(r.y) and MSH.isInt(r.w) and MSH.isInt(r.h)
        and r.x >= 0 and r.y >= 0 and r.w >= 1 and r.h >= 1
        and r.x + r.w <= 1000000 and r.y + r.h <= 1000000
end

function Rect.area(r)
    return r.w * r.h
end

function Rect.equals(a, b)
    return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h
end

-- a 往外擴 gap 格後與 b 是否相交（半開 AABB）
function Rect.overlaps(a, b, gap)
    gap = gap or 0
    return a.x - gap < b.x + b.w and b.x < a.x + a.w + gap
        and a.y - gap < b.y + b.h and b.y < a.y + a.h + gap
end

-- 玩家所在格 (floor(x), floor(y)) 是否在範圍內（任何 Z）
function Rect.containsPoint(r, x, y)
    local fx, fy = math.floor(x), math.floor(y)
    return fx >= r.x and fx < r.x + r.w and fy >= r.y and fy < r.y + r.h
end

function Rect.expand(r, d)
    return { x = r.x - d, y = r.y - d, w = r.w + d * 2, h = r.h + d * 2 }
end

-- ===== 輸入驗證 =====

-- 名稱與標題都不收控制字元；寫進 log 的欄位另外清 [] 與 tab（pitfalls.md「Log」）
function MSH.hasControl(s)
    return string.find(s, "%c") ~= nil
end

function MSH.trim(s)
    local t = string.gsub(s, "^%s+", "")
    t = string.gsub(t, "%s+$", "")
    return t
end

-- 標題：去頭尾空白、1–40 字、不含控制字元與 []（§4.2）；回傳清理後的字串或 nil
function MSH.cleanTitle(s)
    if type(s) ~= "string" then return nil end
    local t = MSH.trim(s)
    if #t < 1 or #t > MSH.LIMIT.TITLE_CHARS then return nil end
    if MSH.hasControl(t) or string.find(t, "[%[%]]") then return nil end
    return t
end

-- 玩家名：照原版 isValidUserName（伺服器上才有這個全域；客戶端只檢查長度與字元）
function MSH.validUsername(s)
    if type(s) ~= "string" or #s < 1 or #s > MSH.LIMIT.USERNAME_CHARS or MSH.hasControl(s) then
        return false
    end
    if isValidUserName ~= nil then return isValidUserName(s) == true end
    return true
end

function MSH.validRequestId(s)
    return type(s) == "string" and #s >= MSH.LIMIT.REQUEST_ID_MIN and #s <= MSH.LIMIT.REQUEST_ID_MAX
        and string.find(s, "^[%w%-_]+$") ~= nil
end

-- log 欄位：去掉換行、tab 與方括號，避免偽造分欄（pitfalls.md「Log」）
function MSH.logSafe(v)
    local s = tostring(v)
    return (string.gsub(s, "[\r\n\t%[%]]", "_"))
end
