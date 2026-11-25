-- MinidoracatSafehouse/Json.lua：zones.json 用的 JSON 解碼（Zones.lua）。
-- 複製自 Economy 的通用解碼路徑（MinidoracatEconomyFor42 ECCore.lua:493-690，不含 decodeCompact；家族第 4 份），補四處：
--   重複鍵算錯誤（不然後面的 "zones":[] 會蓋掉前面的清單，禁建區默默清空）；
--   陣列標上 J.ARRAY 這個 metatable（J.isArray）：{"zones":{"1":{…}}} 或 {"zones":{}} 不能當成清單；
--   開頭的 BOM 先去掉：PUC Lua 讀到 UTF-8 三位元組，Kahlua（getFileReader 用 UTF-8 解碼、Java 不去 BOM）是單一字元 U+FEFF；
--   數字照 JSON 文法（不收前導零、1.、.5）。另有巢狀深度上限 J.MAX_DEPTH（手改的檔不能用深層巢狀把堆疊撐爆）。
-- 失敗回 nil, { pos, line, msg }：pos／line 照去掉 BOM 後的文字算（行號給管理員看，照 Economy ECCodec jsonFailure）。
-- 編碼只有 J.quote：zones.json 的名稱已過 MSH.cleanTitle（沒有控制字元），只要跳脫 " 和 \。

if isClient() then return end

require "MinidoracatSafehouse/Contract"

local MSH = MinidoracatSafehouse
local J = MSH.Json or {}
MSH.Json = J

J.NULL = J.NULL or setmetatable({}, { __tostring = function() return "null" end })
J.ARRAY = J.ARRAY or {}

function J.isArray(v)
    return type(v) == "table" and getmetatable(v) == J.ARRAY
end

local function decodeError(s, pos, msg)
    return nil, { pos = pos, msg = msg .. " at " .. tostring(pos) .. " near '" .. string.sub(s, pos, pos + 12) .. "'" }
end

local function skipSpace(s, pos)
    local _, e = string.find(s, "^[ \t\r\n]*", pos)
    return e + 1
end

J.MAX_DEPTH = 32   -- zones.json 只用到 4 層（物件 → zones 陣列 → 區 → rects 陣列 → 塊）

-- JSON 數字 -?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)? 的結尾後一格；不合文法回 nil
local function numberEnd(s, pos)
    local i = pos
    if string.sub(s, i, i) == "-" then i = i + 1 end
    local c = string.sub(s, i, i)
    if c == "0" then
        i = i + 1
    elseif c ~= "" and string.find("123456789", c, 1, true) then
        local _, e = string.find(s, "^%d+", i)
        i = e + 1
    else
        return nil
    end
    if string.sub(s, i, i) == "." then
        local _, e = string.find(s, "^%d+", i + 1)
        if e == nil then return nil end
        i = e + 1
    end
    c = string.sub(s, i, i)
    if c == "e" or c == "E" then
        local j = i + 1
        c = string.sub(s, j, j)
        if c == "+" or c == "-" then j = j + 1 end
        local _, e = string.find(s, "^%d+", j)
        if e == nil then return nil end
        i = e + 1
    end
    return i
end

local decodeValue

local function unicodeChar(code)
    -- Kahlua 的字串是 UTF-16（StringLib.java:760-768）；離線 Lua 用 UTF-8
    if utf8 and utf8.char then return utf8.char(code) end
    if code < 65536 then return string.char(code) end
    code = code - 65536
    return string.char(55296 + math.floor(code / 1024), 56320 + code % 1024)
end

-- 字串裡的原始控制字元（32 以下）不合法；引號或反斜線之前的整段一次檢查、一次複製
local function decodeString(s, pos)
    local out = {}
    local i = pos + 1
    while true do
        local j = string.find(s, '["\\]', i)
        if not j then return nil, pos end
        if j > i then
            local run = string.sub(s, i, j - 1)
            if string.find(run, "[\1-\31]") or string.find(run, "\0", 1, true) then return nil, i end
            out[#out + 1] = run
        end
        if string.sub(s, j, j) == '"' then return table.concat(out), j + 1 end
        i = j
        local e = string.sub(s, i + 1, i + 1)
        if e == "n" then out[#out + 1] = "\n"
        elseif e == "t" then out[#out + 1] = "\t"
        elseif e == "r" then out[#out + 1] = "\r"
        elseif e == "b" then out[#out + 1] = "\b"
        elseif e == "f" then out[#out + 1] = "\f"
        elseif e == "u" then
            local hex = string.sub(s, i + 2, i + 5)
            if not string.match(hex, "^%x%x%x%x$") then return nil, i end
            local code = tonumber(hex, 16)
            if code >= 55296 and code <= 56319 then
                local lowHex = string.sub(s, i + 8, i + 11)
                if string.sub(s, i + 6, i + 7) ~= "\\u" or not string.match(lowHex, "^%x%x%x%x$") then return nil, i end
                local low = tonumber(lowHex, 16)
                if low < 56320 or low > 57343 then return nil, i end
                code = 65536 + (code - 55296) * 1024 + low - 56320
                i = i + 6
            elseif code >= 56320 and code <= 57343 then
                return nil, i
            end
            out[#out + 1] = unicodeChar(code)
            i = i + 4
        elseif e == '"' or e == "\\" or e == "/" then
            out[#out + 1] = e
        else
            return nil, i
        end
        i = i + 2
    end
end

decodeValue = function(s, pos, depth)
    pos = skipSpace(s, pos)
    local c = string.sub(s, pos, pos)
    if (c == "{" or c == "[") and depth >= J.MAX_DEPTH then return decodeError(s, pos, "nested too deep") end
    if c == "{" then
        local obj = {}
        pos = skipSpace(s, pos + 1)
        if string.sub(s, pos, pos) == "}" then return obj, pos + 1 end
        while true do
            pos = skipSpace(s, pos)
            if string.sub(s, pos, pos) ~= '"' then return decodeError(s, pos, "expected key") end
            local key, np = decodeString(s, pos)
            if not key then return decodeError(s, pos, "bad string") end
            if obj[key] ~= nil then return decodeError(s, pos, "duplicate key") end
            pos = skipSpace(s, np)
            if string.sub(s, pos, pos) ~= ":" then return decodeError(s, pos, "expected ':'") end
            local value, np2 = decodeValue(s, pos + 1, depth + 1)
            if type(np2) ~= "number" then return nil, np2 end
            obj[key] = value
            pos = skipSpace(s, np2)
            local d = string.sub(s, pos, pos)
            if d == "," then pos = pos + 1
            elseif d == "}" then return obj, pos + 1
            else return decodeError(s, pos, "expected ',' or '}'") end
        end
    elseif c == "[" then
        local arr = setmetatable({}, J.ARRAY)
        pos = skipSpace(s, pos + 1)
        if string.sub(s, pos, pos) == "]" then return arr, pos + 1 end
        while true do
            local value, np = decodeValue(s, pos, depth + 1)
            if type(np) ~= "number" then return nil, np end
            arr[#arr + 1] = value
            pos = skipSpace(s, np)
            local d = string.sub(s, pos, pos)
            if d == "," then pos = pos + 1
            elseif d == "]" then return arr, pos + 1
            else return decodeError(s, pos, "expected ',' or ']'") end
        end
    elseif c == '"' then
        local str, np = decodeString(s, pos)
        if not str then return decodeError(s, pos, "unterminated string") end
        return str, np
    elseif string.sub(s, pos, pos + 3) == "true" then return true, pos + 4
    elseif string.sub(s, pos, pos + 4) == "false" then return false, pos + 5
    elseif string.sub(s, pos, pos + 3) == "null" then return J.NULL, pos + 4
    else
        local e = numberEnd(s, pos)
        local num = e and tonumber(string.sub(s, pos, e - 1))
        if not num then return decodeError(s, pos, "unexpected token") end
        return num, e
    end
end

function J.stripBom(s)
    if string.sub(s, 1, 3) == "\239\187\191" then return string.sub(s, 4) end
    if string.byte(s, 1) == 65279 then return string.sub(s, 2) end
    return s
end

-- 回 value；失敗回 nil, { pos, line, msg }
function J.decode(s)
    if type(s) ~= "string" then return nil, { pos = 1, line = 1, msg = "not a string" } end
    s = J.stripBom(s)
    local value, np = decodeValue(s, 1, 0)
    local err
    if type(np) ~= "number" then
        err = np
    else
        np = skipSpace(s, np)
        if np <= #s then
            local _
            _, err = decodeError(s, np, "trailing garbage")
        end
    end
    if err == nil then return value end
    local _, breaks = string.gsub(string.sub(s, 1, err.pos - 1), "\n", "")
    err.line = breaks + 1
    return nil, err
end

function J.quote(s)
    return '"' .. string.gsub(s, '[\\"]', "\\%0") .. '"'
end
