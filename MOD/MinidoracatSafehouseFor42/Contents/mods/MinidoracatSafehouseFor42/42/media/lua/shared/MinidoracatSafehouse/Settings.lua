-- MinidoracatSafehouse/Settings.lua：沙盒選項的單一定義（鍵、型別、預設、範圍）與讀取。
-- 規則存沙盒選項 SandboxVars.MinidoracatSafehouse（使用者 2026-10-10 裁定，計畫 §7.1）。
-- sandbox-options.txt、Sandbox.json 與管理員面板都照這份清單；改鍵名要三處一起改。
-- 讀取時不合法的值夾回範圍並記警告（不進 blocked）；面板送來的變更由 validateChanges 整批檢查。

require "MinidoracatSafehouse/Contract"

local MSH = MinidoracatSafehouse
local S = {}
MSH.Settings = S

S.PAGE = "MinidoracatSafehouse"

S.CREATE = { DEED = 1, FREE = 2 }
S.RULE = { MINIMAP = 1, ROOMS = 2 }
S.CRAFT = { OFF = 1, EASY = 2, STANDARD = 3, STRICT = 4 }
-- 物品搜尋（使用者 2026-10-20）：關閉、只指引（箭頭帶路）、可以遠距拿（站在安全屋裡直接拿進背包，要分享權限 TAKE）
S.STORAGE = { OFF = 1, GUIDE = 2, REMOTE = 3 }
S.ROAD_KINDS = { "main", "street", "gravel", "sidewalk" }

-- 清單型選項的 txt default 留空（ScriptParser 拿逗號當欄位分隔，pitfalls.md「Sandbox 選項」），預設清單寫在這裡
S.DEFAULT_ROAD_KINDS = "main;street"
S.DEFAULT_RESOURCE_CATS = "military;police;gunstore;medical;pharmacy;fire;gas;prison"

-- 各級預設面積（使用者 2026-10-13 採用重新評估的建議表）：邊長 24、32、40、48、56、64、80、96 的正方形格數。1 級圈得下
-- 房子連院子（原版地圖 88%），預設開放的 1–3 級最大 1,600；4,096 以上在城鎮多半圈不成一塊（被路切斷），放到 6 級以上。
-- 外框（整間的外接矩形）上限是同面積正方形邊長的 2 倍、最多 96（使用者 2026-10-12 選「以格數為主，外框放寬成 2 倍」：
-- L、U 形的外框比同面積的正方形大；外框不整個拿掉是因為闖入者會被傳到那一塊的左上角外面、伺服器只載入玩家附近的格子、
-- 細長的範圍能圍住一大片地）。掉落機率每級約除以 3（使用者 2026-10-13：比逐級減半再陡），但 DeedLoot 預設關閉、
-- 開了才照這些機率掉落；製作 1 級標準、其餘不開放（使用者 2026-10-10 裁定 craftdefault）
local TIER_DEFAULT = {
    { side = 48, area = 576, loot = 1.0, craft = 3 },
    { side = 64, area = 1024, loot = 0.3, craft = 1 },
    { side = 80, area = 1600, loot = 0.1, craft = 1 },
    { side = 96, area = 2304, loot = 0.03, craft = 1 },
    { side = 96, area = 3136, loot = 0.01, craft = 1 },
    { side = 96, area = 4096, loot = 0.005, craft = 1 },
    { side = 96, area = 6400, loot = 0.002, craft = 1 },
    { side = 96, area = 9216, loot = 0.001, craft = 1 },
}

-- type: bool | int | double | enum | string；enum 的值是 1..values
local OPTIONS = {
    { key = "CreateMode", type = "enum", values = 2, default = S.CREATE.DEED },
    { key = "FreeMaxArea", type = "int", min = 1, max = 9216, default = 576 },
    { key = "FreeMaxSide", type = "int", min = 1, max = 96, default = 48 },
    { key = "ClaimGap", type = "int", min = 0, max = 16, default = 2 },
    -- 屋主和自己在同一個陣營的安全屋（使用者 2026-10-15：「幫我增加同陣營的間隔設定，預設0」）；0＝可以緊鄰、不能重疊
    { key = "FactionClaimGap", type = "int", min = 0, max = 16, default = 0 },
    -- 一間最多幾塊矩形（使用者 2026-10-12：預設 4，管理員可調高）；每塊一個原生 SafeHouse，登入封包、全服名單額度與
    -- 客戶端切塊的成本都隨它成長，硬上限 LIMIT.MAX_PIECES 由 registry 與校正的容量預算決定
    { key = "MaxPieces", type = "int", min = 1, max = MSH.LIMIT.MAX_PIECES, default = 4 },
    { key = "MaxShares", type = "int", min = 0, max = MSH.LIMIT.MAX_SHARES, default = 8 },
    { key = "AllowFactionShare", type = "bool", default = true },
    { key = "LapseKeepDays", type = "int", min = 0, max = 365, default = 7 },
    -- 閒置收回（使用者 2026-10-14）：屋主或名單上的人多少天沒踩進範圍就收回，0＝不收。IdleDays 管免費與沒有付費名額
    -- 保護的屋、IdleBuyDays 管買斷名額保護的屋；租用名額的屋照租期（Idle.lua）。IdleInsure：玩家能不能花錢買保險延長
    -- （要 Economy 支援一次付多期；每日價格在管理員面板付費頁逐級設定）
    { key = "IdleDays", type = "int", min = 0, max = 365, default = 14 },
    { key = "IdleBuyDays", type = "int", min = 0, max = 365, default = 30 },
    { key = "IdleInsure", type = "bool", default = false },
    { key = "RedrawMinutes", type = "int", min = 0, max = 1440, default = 30 },
    -- 每間在重新框選時限內最多重畫幾次（使用者 2026-10-11 同意改成沙盒選項；每次多一筆 tombstone 與兩次全服廣播）
    { key = "RedrawLimit", type = "int", min = 1, max = 20, default = 5 },
    -- 地面顯示範圍：玩家看得到哪些別人的安全屋（使用者 2026-10-12：預設自己的與同陣營的）；自己的與分享給自己的一定看得到。
    -- 只影響客戶端畫面（Ranges.lua）：原版本來就把每間安全屋的範圍傳給所有客戶端（MetaDataPacket、SafehouseSync）
    { key = "RangesFaction", type = "bool", default = true },
    { key = "RangesOthers", type = "bool", default = false },
    -- 物品搜尋與遠距拿取（使用者 2026-10-20：新伺服器預設只指引）
    { key = "StorageMode", type = "enum", values = 3, default = S.STORAGE.GUIDE },
    -- 遠距拿取可以站在安全屋外幾格內（使用者 2026-10-21：預設 0＝只能站在安全屋裡；拿的東西照樣要在範圍內的容器）
    { key = "StorageReach", type = "int", min = 0, max = 50, default = 0 },
    { key = "AvoidRoads", type = "bool", default = true },
    { key = "RoadMargin", type = "int", min = 0, max = 8, default = 1 },
    { key = "RoadKinds", type = "string", default = "" },
    { key = "AvoidResources", type = "bool", default = true },
    { key = "ResourceRule", type = "enum", values = 2, default = S.RULE.MINIMAP },
    { key = "ResourceCats", type = "string", default = "" },
    { key = "TiersEnabled", type = "int", min = 1, max = 8, default = 3 },
}
for n = 1, MSH.MAX_TIER do
    local d = TIER_DEFAULT[n]
    OPTIONS[#OPTIONS + 1] = { key = "Tier" .. n .. "Area", type = "int", min = 1, max = 9216, default = d.area, tier = n }
    OPTIONS[#OPTIONS + 1] = { key = "Tier" .. n .. "Side", type = "int", min = 1, max = 96, default = d.side, tier = n }
end
-- 名額每一級各自三個數（使用者 2026-10-15 選 B）：免費幾間、每人最多買斷幾個、每人最多租用幾個；這一級每人最多
-- 幾間＝三個相加。0＝這一級不給。免費預設只有 1 級 1 間（和舊版「每人免費 1 間」一樣多）。租用上限 10＝經濟中心每個
-- 帳號每個產品最多 10 張租約（rentalsMax）；買斷上限照經濟中心 permanentLimit 的範圍取 100。
for n = 1, MSH.MAX_TIER do
    OPTIONS[#OPTIONS + 1] = { key = "Tier" .. n .. "FreeSlots", type = "int", min = 0, max = 100,
        default = n == 1 and 1 or 0, tier = n }
    OPTIONS[#OPTIONS + 1] = { key = "Tier" .. n .. "BuySlots", type = "int", min = 0, max = 100, default = 0, tier = n }
    OPTIONS[#OPTIONS + 1] = { key = "Tier" .. n .. "RentSlots", type = "int", min = 0, max = 10, default = 0, tier = n }
end
-- 地契會不會從辦公桌、檔案櫃、保險箱掉出來（使用者 2026-10-13：預設不開）；關著時各級的掉落機率都不生效
OPTIONS[#OPTIONS + 1] = { key = "DeedLoot", type = "bool", default = false }
for n = 1, MSH.MAX_TIER do
    local d = TIER_DEFAULT[n]
    OPTIONS[#OPTIONS + 1] = { key = "Tier" .. n .. "LootChance", type = "double", min = 0, max = 100, default = d.loot, tier = n }
    OPTIONS[#OPTIONS + 1] = { key = "Tier" .. n .. "Craft", type = "enum", values = 4, default = d.craft, tier = n }
end

S.OPTIONS = OPTIONS
S.BY_KEY = {}
for _, o in ipairs(OPTIONS) do S.BY_KEY[o.key] = o end

-- 完整的選項名（getSandboxOptions():set 用）
function S.optionName(key)
    return S.PAGE .. "." .. key
end

local function typeOk(o, v)
    if o.type == "bool" then return type(v) == "boolean" end
    if o.type == "string" then return type(v) == "string" end
    if o.type == "double" then return MSH.isFinite(v) end
    return MSH.isInt(v)
end

local function inRange(o, v)
    if o.type == "bool" or o.type == "string" then return true end
    if o.type == "enum" then return v >= 1 and v <= o.values end
    return v >= o.min and v <= o.max
end

local function clamp(o, v)
    if o.type == "enum" then return o.default end
    if v < o.min then return o.min end
    if v > o.max then return o.max end
    return v
end

-- 分號清單 → 集合；allowed 為 nil 時接受任何 ^[%w_]+$ 的項目
local function parseList(text, allowed)
    local set, bad = {}, nil
    for token in string.gmatch(text, "[^;]+") do
        local t = MSH.trim(token)
        if t ~= "" then
            if string.find(t, "^[%w_]+$") and #t <= 32 and (allowed == nil or allowed[t]) then
                set[t] = true
            else
                bad = t
            end
        end
    end
    return set, bad
end

local ROAD_ALLOWED = {}
for _, k in ipairs(S.ROAD_KINDS) do ROAD_ALLOWED[k] = true end

local function sandboxTable()
    local sb = SandboxVars and SandboxVars.MinidoracatSafehouse
    if type(sb) ~= "table" then return nil end
    return sb
end

function S.readable()
    return sandboxTable() ~= nil
end

-- 只讀一鍵（管理視窗、物品搜尋每次排版都問；伺服器收斂與分享輪檢每間陣營分享都問，不必整份 get）；不合法照預設
-- （bool、enum 和 get 相同；int 超出範圍時 get 夾值、這裡取預設）
local function one(key)
    local sb = sandboxTable()
    local v = sb and sb[key]
    local o = S.BY_KEY[key]
    if not typeOk(o, v) or not inRange(o, v) then return o.default end
    return v
end

function S.storageMode() return one("StorageMode") end
function S.storageReach() return one("StorageReach") end
function S.allowFactionShare() return one("AllowFactionShare") end

-- 讀出整份設定；不合法的值夾回範圍並附警告（每次呼叫都重讀，面板或原版畫面改值後立即生效）
-- 回傳 cfg, warnings（{ "Key" , ... }）
function S.get()
    local sb = sandboxTable() or {}
    local raw, warnings = {}, {}
    for _, o in ipairs(OPTIONS) do
        local v = sb[o.key]
        if v == nil or not typeOk(o, v) then
            if v ~= nil then warnings[#warnings + 1] = o.key end
            v = o.default
        elseif not inRange(o, v) then
            warnings[#warnings + 1] = o.key
            v = clamp(o, v)
        end
        raw[o.key] = v
    end
    local cfg = {
        createMode = raw.CreateMode,
        freeMaxSide = raw.FreeMaxSide,
        freeMaxArea = math.min(raw.FreeMaxArea, raw.FreeMaxSide * raw.FreeMaxSide),
        claimGap = raw.ClaimGap,
        factionClaimGap = raw.FactionClaimGap,
        maxPieces = raw.MaxPieces,
        maxShares = raw.MaxShares,
        allowFactionShare = raw.AllowFactionShare,
        lapseKeepDays = raw.LapseKeepDays,
        idleDays = raw.IdleDays,
        idleBuyDays = raw.IdleBuyDays,
        idleInsure = raw.IdleInsure,
        redrawMinutes = raw.RedrawMinutes,
        rangesFaction = raw.RangesFaction,
        rangesOthers = raw.RangesOthers,
        redrawLimit = raw.RedrawLimit,
        storageMode = raw.StorageMode,
        avoidRoads = raw.AvoidRoads,
        roadMargin = raw.RoadMargin,
        avoidResources = raw.AvoidResources,
        resourceRule = raw.ResourceRule,
        tiersEnabled = raw.TiersEnabled,
        tiers = {},
        raw = raw,
    }
    if raw.FreeMaxArea > cfg.freeMaxArea then warnings[#warnings + 1] = "FreeMaxArea" end
    local kinds = raw.RoadKinds
    if kinds == "" then kinds = S.DEFAULT_ROAD_KINDS end
    local badKind
    cfg.roadKinds, badKind = parseList(kinds, ROAD_ALLOWED)
    if badKind then warnings[#warnings + 1] = "RoadKinds" end
    local cats = raw.ResourceCats
    if cats == "" then cats = S.DEFAULT_RESOURCE_CATS end
    local badCat
    cfg.resourceCats, badCat = parseList(cats, nil)
    if badCat then warnings[#warnings + 1] = "ResourceCats" end
    for n = 1, MSH.MAX_TIER do
        local side = raw["Tier" .. n .. "Side"]
        local area = raw["Tier" .. n .. "Area"]
        if area > side * side then
            warnings[#warnings + 1] = "Tier" .. n .. "Area"
            area = side * side
        end
        cfg.tiers[n] = {
            enabled = n <= raw.TiersEnabled,
            side = side,
            area = area,
            freeSlots = raw["Tier" .. n .. "FreeSlots"],
            buySlots = raw["Tier" .. n .. "BuySlots"],
            rentSlots = raw["Tier" .. n .. "RentSlots"],
            free = raw["Tier" .. n .. "FreeSlots"] > 0,
            buy = raw["Tier" .. n .. "BuySlots"] > 0,
            rent = raw["Tier" .. n .. "RentSlots"] > 0,
            loot = raw["Tier" .. n .. "LootChance"],
            craft = raw["Tier" .. n .. "Craft"],
        }
    end
    return cfg, warnings
end

-- 管理員面板送來的變更：只收已知鍵、型別與範圍嚴格檢查（不夾值），不合就整批拒絕（§7.1）。
-- 跨欄位：合併後每級 Area ≤ Side²、FreeMaxArea ≤ FreeMaxSide²；清單選項的每個項目要合法。
-- 回傳 true 或 false, 鍵名, 原因
function S.validateChanges(changes)
    if type(changes) ~= "table" then return false, nil, "BAD_ARGS" end
    local count = 0
    for k, v in pairs(changes) do
        local o = type(k) == "string" and S.BY_KEY[k] or nil
        if o == nil then return false, tostring(k), "UNKNOWN_KEY" end
        if not typeOk(o, v) or not inRange(o, v) then return false, k, "OUT_OF_RANGE" end
        if o.type == "string" then
            if #v > 512 or MSH.hasControl(v) then return false, k, "OUT_OF_RANGE" end
            local _, bad = parseList(v, k == "RoadKinds" and ROAD_ALLOWED or nil)
            if bad then return false, k, "BAD_LIST" end
        end
        count = count + 1
    end
    if count == 0 then return false, nil, "EMPTY" end
    local sb = sandboxTable() or {}
    local function merged(key)
        local v = changes[key]
        if v == nil then v = sb[key] end
        local o = S.BY_KEY[key]
        if v == nil or not typeOk(o, v) or not inRange(o, v) then v = o.default end
        return v
    end
    if merged("FreeMaxArea") > merged("FreeMaxSide") * merged("FreeMaxSide") then
        return false, "FreeMaxArea", "AREA_OVER_SIDE"
    end
    for n = 1, MSH.MAX_TIER do
        local side = merged("Tier" .. n .. "Side")
        if merged("Tier" .. n .. "Area") > side * side then
            return false, "Tier" .. n .. "Area", "AREA_OVER_SIDE"
        end
    end
    return true
end

-- 目前 SandboxVars 裡本 MOD 每個鍵的原值（sandboxSync 與每分鐘比對用）
function S.snapshot()
    local sb = sandboxTable() or {}
    local out = {}
    for _, o in ipairs(OPTIONS) do out[o.key] = sb[o.key] end
    return out
end

-- 地契等級限制；source 是 free 時用免費上限（§7.1）
function S.sizeLimit(cfg, source, tier)
    if source == MSH.SOURCE.FREE then
        return math.min(cfg.freeMaxSide, MSH.LIMIT.HARD_SIDE), math.min(cfg.freeMaxArea, MSH.LIMIT.HARD_AREA)
    end
    local t = cfg.tiers[tier]
    return math.min(t.side, MSH.LIMIT.HARD_SIDE), math.min(t.area, MSH.LIMIT.HARD_AREA)
end
