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
S.ROAD_KINDS = { "main", "street", "gravel", "sidewalk" }

-- 清單型選項的 txt default 留空（ScriptParser 拿逗號當欄位分隔，pitfalls.md「Sandbox 選項」），預設清單寫在這裡
S.DEFAULT_ROAD_KINDS = "main;street"
S.DEFAULT_RESOURCE_CATS = "military;police;gunstore;medical;pharmacy;fire;gas;prison"

-- 各級預設：1 級 24／576、2 級 40／1,600、3–8 級 64／4,096（§7.1）；掉落 1 級 1%、2 級 0.5%、其餘 0.2%；
-- 製作 1 級標準、其餘不開放（使用者 2026-10-10 裁定 craftdefault）
local TIER_DEFAULT = {
    { side = 24, area = 576, loot = 1.0, craft = 3 },
    { side = 40, area = 1600, loot = 0.5, craft = 1 },
    { side = 64, area = 4096, loot = 0.2, craft = 1 },
}

-- type: bool | int | double | enum | string；enum 的值是 1..values
local OPTIONS = {
    { key = "CreateMode", type = "enum", values = 2, default = S.CREATE.DEED },
    { key = "ClaimsPerPlayer", type = "int", min = 0, max = 100, default = 1 },
    { key = "FreeMaxSide", type = "int", min = 1, max = 96, default = 24 },
    { key = "FreeMaxArea", type = "int", min = 1, max = 9216, default = 576 },
    { key = "ClaimGap", type = "int", min = 0, max = 16, default = 2 },
    { key = "MaxShares", type = "int", min = 0, max = 32, default = 8 },
    { key = "AllowFactionShare", type = "bool", default = true },
    { key = "LapseKeepDays", type = "int", min = 0, max = 365, default = 7 },
    { key = "RedrawMinutes", type = "int", min = 0, max = 1440, default = 30 },
    -- 每間在重新框選時限內最多重畫幾次（使用者 2026-10-11 同意改成沙盒選項；每次多一筆 tombstone 與兩次全服廣播）
    { key = "RedrawLimit", type = "int", min = 1, max = 20, default = 5 },
    { key = "AvoidRoads", type = "bool", default = true },
    { key = "RoadMargin", type = "int", min = 0, max = 8, default = 1 },
    { key = "RoadKinds", type = "string", default = "" },
    { key = "AvoidResources", type = "bool", default = true },
    { key = "ResourceRule", type = "enum", values = 2, default = S.RULE.MINIMAP },
    { key = "ResourceCats", type = "string", default = "" },
    { key = "TiersEnabled", type = "int", min = 1, max = 8, default = 3 },
}
for n = 1, MSH.MAX_TIER do
    local d = TIER_DEFAULT[n] or TIER_DEFAULT[3]
    OPTIONS[#OPTIONS + 1] = { key = "Tier" .. n .. "Side", type = "int", min = 1, max = 96, default = d.side, tier = n }
    OPTIONS[#OPTIONS + 1] = { key = "Tier" .. n .. "Area", type = "int", min = 1, max = 9216, default = d.area, tier = n }
    OPTIONS[#OPTIONS + 1] = { key = "Tier" .. n .. "PerPlayer", type = "int", min = 0, max = 100, default = 0, tier = n }
end
for n = 1, MSH.MAX_TIER do
    OPTIONS[#OPTIONS + 1] = { key = "Tier" .. n .. "Free", type = "bool", default = true, tier = n }
    OPTIONS[#OPTIONS + 1] = { key = "Tier" .. n .. "Buy", type = "bool", default = false, tier = n }
    OPTIONS[#OPTIONS + 1] = { key = "Tier" .. n .. "Rent", type = "bool", default = false, tier = n }
end
for n = 1, MSH.MAX_TIER do
    local d = TIER_DEFAULT[n] or TIER_DEFAULT[3]
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
        claimsPerPlayer = raw.ClaimsPerPlayer,
        freeMaxSide = raw.FreeMaxSide,
        freeMaxArea = math.min(raw.FreeMaxArea, raw.FreeMaxSide * raw.FreeMaxSide),
        claimGap = raw.ClaimGap,
        maxShares = raw.MaxShares,
        allowFactionShare = raw.AllowFactionShare,
        lapseKeepDays = raw.LapseKeepDays,
        redrawMinutes = raw.RedrawMinutes,
        redrawLimit = raw.RedrawLimit,
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
            perPlayer = raw["Tier" .. n .. "PerPlayer"],
            free = raw["Tier" .. n .. "Free"],
            buy = raw["Tier" .. n .. "Buy"],
            rent = raw["Tier" .. n .. "Rent"],
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
