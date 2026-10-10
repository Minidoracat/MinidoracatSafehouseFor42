-- 地契：掉落（Deeds.lua）、配方閘門（Recipes.lua）、sandbox-options.txt 與 Settings.OPTIONS 的漂移防線（計畫 §12.1 第 33、34 項）。
return function(T)
    local check = T.check

    local function deeds(c)
        local out = {}
        for _, it in ipairs(c.items) do
            if string.find(it:getFullType(), "^MinidoracatSafehouse%.Deed") then out[#out + 1] = it:getFullType() end
        end
        return out
    end
    local function fill(kind, room)
        local c = T.container(kind)
        T.fire("OnFillContainer", room or "office", kind, c)
        return c
    end

    T.section("掉落：容器種類、分布物件、重複註冊")
    local MSH = T.boot({ sandbox = { Tier1LootChance = 100, Tier2LootChance = 100, Tier3LootChance = 100 } })
    for _, kind in ipairs({ "desk", "filingcabinet", "safe" }) do
        local got = deeds(fill(kind))
        check(#got == 1 and got[1] == "MinidoracatSafehouse.Deed1", kind .. "：機率 100 恰好一張 1 級")
    end
    for _, kind in ipairs({ "fridge", "crate", "counter", "none" }) do
        check(#deeds(fill(kind)) == 0, kind .. "：不是辦公桌／檔案櫃／保險箱就不掉")
    end
    local hostile = setmetatable({}, { __index = function(_, k) error("attempted index: " .. tostring(k) .. " of non-table") end })
    local okHostile = pcall(T.fire, "OnFillContainer", "Zombie Bag", "desk", hostile)
    check(okHostile, "第三參數是分布物件（索引就 throw）：不 throw")
    dofile(T.MEDIA .. "/server/MinidoracatSafehouse/Deeds.lua")
    check(#T.handlers.OnFillContainer == 1, "熱重載不重複註冊 OnFillContainer")
    local c = T.container("desk")
    c:AddItem("MinidoracatSafehouse.Deed3")
    T.fire("OnFillContainer", "office", "desk", c)
    check(#deeds(c) == 1, "容器已有地契就不再加")

    T.section("掉落：啟用等級、機率、即時讀沙盒")
    T.sandbox("TiersEnabled", 1)
    T.sandbox("Tier1LootChance", 0)
    check(#deeds(fill("desk")) == 0, "1 級機率 0、2–3 級未啟用（機率 100）：不掉")
    T.sandbox("Tier1LootChance", 1)
    T.randQueue = { 100 }
    check(#deeds(fill("desk")) == 0, "1 級 1%：擲到 100 不中（< 100 才中）")
    T.randQueue = { 99 }
    check(#deeds(fill("desk")) == 1, "1 級 1%：擲到 99 中")
    T.sandbox("TiersEnabled", 3)
    T.sandbox("Tier2LootChance", 0.5)
    T.sandbox("Tier3LootChance", 0.2)
    T.randQueue = { 9999, 49 }
    local got = deeds(fill("safe"))
    check(#got == 1 and got[1] == "MinidoracatSafehouse.Deed2", "1 級沒中、往上擲 2 級中：放 2 級並停止")
    T.randQueue = { 9999, 50, 9999 }
    check(#deeds(fill("safe")) == 0 and #T.randQueue == 0, "三級都沒中：不掉、每級各擲一次")
    for n = 1, 8 do T.sandbox("Tier" .. n .. "LootChance", 0) end
    T.sandbox("TiersEnabled", 8)
    T.sandbox("Tier8LootChance", 100)
    got = deeds(fill("filingcabinet"))
    check(#got == 1 and got[1] == "MinidoracatSafehouse.Deed8", "改沙盒後下一次填充就用新值（只開 8 級）")
    SandboxVars = nil
    local okSb = pcall(fill, "desk")
    check(okSb, "SandboxVars 為 nil：不 throw")
    T.resetSandbox()
    T.bootClient()
    check(MinidoracatSafehouse.Deeds == nil and (T.handlers.OnFillContainer == nil or #T.handlers.OnFillContainer == 0),
        "客戶端不載入掉落")

    T.section("配方閘門：24 個 OnTest、24 個全域 OnAddToMenu")
    for n = 1, 8 do
        for _, lv in ipairs({ "Easy", "Standard", "Strict" }) do _G["MSH_menuDeed" .. n .. lv] = nil end
    end
    MSH = T.boot()
    local LV = { Easy = 2, Standard = 3, Strict = 4 }
    local missing = {}
    for n = 1, 8 do
        for lv in pairs(LV) do
            if type(MSH_Recipe["deed" .. n .. lv]) ~= "function" then missing[#missing + 1] = "MSH_Recipe.deed" .. n .. lv end
            if type(rawget(_G, "MSH_menuDeed" .. n .. lv)) ~= "function" then missing[#missing + 1] = "MSH_menuDeed" .. n .. lv end
        end
    end
    check(#missing == 0, "48 個函式名都存在（缺：" .. table.concat(missing, ",") .. "）")
    local count = 0
    for _ in pairs(MSH_Recipe) do count = count + 1 end
    check(count == 24, "MSH_Recipe 只有 24 個 OnTest（實際 " .. count .. "）")

    T.section("配方閘門：難度 × 等級 × 啟用")
    T.sandbox("TiersEnabled", 8)
    local wrong = {}
    for n = 1, 8 do
        for code = 1, 4 do
            T.sandbox("Tier" .. n .. "Craft", code)
            for lv, own in pairs(LV) do
                local want = code == own
                if MSH_Recipe["deed" .. n .. lv](nil, nil) ~= want then wrong[#wrong + 1] = "deed" .. n .. lv .. "@" .. code end
                if _G["MSH_menuDeed" .. n .. lv]({}) ~= want then wrong[#wrong + 1] = "menu" .. n .. lv .. "@" .. code end
            end
        end
    end
    check(#wrong == 0, "全部啟用：只有選中的難度放行、1＝不開放全擋（錯：" .. table.concat(wrong, ",") .. "）")
    T.sandbox("TiersEnabled", 3)
    T.sandbox("Tier4Craft", 3)
    T.sandbox("Tier3Craft", 4)
    check(not MSH_Recipe.deed4Standard(nil, nil) and not MSH_menuDeed4Standard({}), "4 級超過 TiersEnabled=3：選中的難度也擋")
    check(MSH_Recipe.deed3Strict(nil, nil) and not MSH_Recipe.deed3Easy(nil, nil), "3 級在 TiersEnabled 內：照難度")
    local okNil = pcall(function() return MSH_Recipe.deed1Standard(nil, nil) end)
    check(okNil, "character 為 nil 不 throw")
    SandboxVars = nil
    check(MSH_Recipe.deed2Strict(nil, nil) and MSH_menuDeed5Easy({}), "SandboxVars 為 nil（主選單）：放行")
    SandboxVars = {}
    check(MSH_Recipe.deed2Strict(nil, nil), "沒有本 MOD 的沙盒表：放行")
    SandboxVars = { MinidoracatSafehouse = { TiersEnabled = 1 } }
    check(MSH_Recipe.deed2Strict(nil, nil), "該級 Craft 鍵是 nil：放行")
    T.resetSandbox()
    check(MSH_Recipe.deed1Standard(nil, nil) and not MSH_Recipe.deed1Easy(nil, nil) and not MSH_Recipe.deed2Standard(nil, nil),
        "預設：1 級標準放行、1 級寬鬆與 2 級不開放")
    T.bootClient()
    check(MSH_Recipe ~= nil and type(MSH_Recipe.deed1Easy) == "function", "客戶端也載入配方閘門（shared）")

    T.section("sandbox-options.txt 與 Settings.OPTIONS 一致（漂移防線）")
    MSH = T.boot()
    local path = string.gsub(T.MEDIA, "/lua$", "") .. "/sandbox-options.txt"
    local fh = io.open(path, "r")
    check(fh ~= nil, "sandbox-options.txt 存在")
    if not fh then return end
    local text = fh:read("a")
    fh:close()
    text = string.gsub(text, "/%*.-%*/", "")
    check(string.find(text, "^%s*VERSION = 1,") ~= nil, "開頭 VERSION = 1,")
    local parsed = {}
    for key, body in string.gmatch(text, "option MinidoracatSafehouse%.(%w+)%s*{(.-)}") do
        local f = {}
        for k, v in string.gmatch(body, "(%w+)%s*=%s*([^,]*),") do f[k] = (string.gsub(v, "%s+$", "")) end
        parsed[#parsed + 1] = { key = key, f = f }
    end
    local TYPE = { int = "integer", double = "double", bool = "boolean", string = "string", enum = "enum" }
    local VT = { CreateMode = "MinidoracatSafehouse_CreateMode", ResourceRule = "MinidoracatSafehouse_ResourceRule" }
    local drift = {}
    local function bad(key, what) drift[#drift + 1] = key .. ":" .. what end
    local function numEq(s, v) return tonumber(s) ~= nil and tonumber(s) == v end
    local opts = MSH.Settings.OPTIONS
    if #parsed ~= #opts then bad("count", #parsed .. "≠" .. #opts) end
    for i, o in ipairs(opts) do
        local p = parsed[i]
        if not p or p.key ~= o.key then
            bad(o.key, "順序（第 " .. i .. " 個是 " .. tostring(p and p.key) .. "）")
        else
            local f = p.f
            if f.type ~= TYPE[o.type] then bad(o.key, "type " .. tostring(f.type)) end
            if f.page ~= "MinidoracatSafehouse" then bad(o.key, "page") end
            if f.translation ~= "MinidoracatSafehouse_" .. o.key then bad(o.key, "translation") end
            if o.type == "int" or o.type == "double" then
                if not numEq(f.min, o.min) then bad(o.key, "min " .. tostring(f.min)) end
                if not numEq(f.max, o.max) then bad(o.key, "max " .. tostring(f.max)) end
                if not numEq(f.default, o.default) then bad(o.key, "default " .. tostring(f.default)) end
            elseif o.type == "enum" then
                if not numEq(f.numValues, o.values) then bad(o.key, "numValues " .. tostring(f.numValues)) end
                if not numEq(f.default, o.default) then bad(o.key, "default " .. tostring(f.default)) end
                if f.valueTranslation ~= (VT[o.key] or "MinidoracatSafehouse_CraftLevel") then bad(o.key, "valueTranslation") end
            elseif o.type == "bool" then
                if f.default ~= tostring(o.default) then bad(o.key, "default " .. tostring(f.default)) end
            elseif f.default ~= o.default then
                bad(o.key, "default " .. tostring(f.default))
            end
        end
    end
    check(#drift == 0, #parsed .. " 個選項與 Settings.OPTIONS 一致（差異：" .. table.concat(drift, "，") .. "）")
end
