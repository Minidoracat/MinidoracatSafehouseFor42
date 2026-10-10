-- MinidoracatSafehouse/AdminPanel.lua：管理員面板（計畫 §10.6）。UI.Tabs 五頁：規則（含伺服器狀態、遷移狀態與
--   targeted recovery）、地契、排除、玩家、付費。設定頁〔套用變更〕只送有改動的鍵（adminSetOptions），伺服器整批驗證、
--   存檔後回快照；本機先逐欄檢查（Settings.validateChanges 同一套規則）並把錯誤標在欄位上，伺服器回的 BAD_OPTION
--   { key, reason } 也標回該欄。付費頁照等級各送一次 adminSetPlan（帶該級 expectedRevision），逐級回錯、不互相連帶。
-- 玩家頁照 Economy 身分清單（ECAdminIdentity.lua:71 QUERY_DEBOUNCE_MS、:205 loginsKey、:230 pump、:243-247 debounce）：
--   輸入停 650 ms 才送、一次只有一筆在路上、兩次送出至少隔 650 ms（伺服器 500 ms 內重送就丟、不回覆：Server.lua coolingDown）、
--   回覆的 (query, filter, page) 不是目前要的就丟掉，頁碼採用伺服器夾過的值。
-- 只在 Capability.CanSetupSafehouses 時開（客戶端只是體驗，伺服器每個 admin 指令都再檢查，契約「客戶端模組」）。
-- 原版：ISCraftRecipeTooltip.activateToolTipFor／deactivateToolTipFor（client/Entity/ISUI/CraftRecipe/
--   ISCraftRecipeTooltip.lua:214、258）、ISWidgetTitleHeader 沒傳 player 的繞法（計畫 §7.7「預覽」，
--   deeds-ui-sp/E2EScenario.lua:30-43 實測）、getScriptManager():getCraftRecipe（同情境 :154）、
--   getPlayer():getRole():hasCapability(Capability.CanSetupSafehouses)（契約「客戶端模組」）。
-- 他 MOD：MinidoracatEconomy.v1.Client.openAdminShop（Economy ECClient.lua:1339-1364，rev 4、CAPABILITIES.shopAdd）、
--   MinidoracatMiniMapResourceAPI.categories()（MiniMap docs/addon-api.md:863）。

if not isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Settings"
require "MinidoracatSafehouse/Client"
require "MinidoracatSafehouse/SlotsWindow"

local MSH = MinidoracatSafehouse
local first = MSH.AdminPanel == nil
local AP = MSH.AdminPanel or {}
MSH.AdminPanel = AP
local K = MSH.SlotsWindow.kit
local Settings = MSH.Settings

AP.TABS = { "rules", "deeds", "exclusions", "players", "paid" }
AP.QUERY_DEBOUNCE_MS = 650   -- Economy QUERY_DEBOUNCE_MS
AP.GAP_MS = 650              -- 兩次 adminPlayers 至少隔這麼久（伺服器 cooldownMs = 500）
AP.FILTERS = { "all", "owners", "overrides" }
AP.RULE_KEYS = { "CreateMode", "ClaimsPerPlayer", "FreeMaxSide", "FreeMaxArea", "ClaimGap", "MaxShares",
    "AllowFactionShare", "LapseKeepDays", "RedrawMinutes" }
AP.CRAFT_LEVELS = { [2] = "Easy", [3] = "Standard", [4] = "Strict" }
-- Economy 方案 12 欄（entitlements-api.md；ECEntitlementPlans.lua:3-61）與付費頁可改欄位的範圍
AP.PLAN_FIELDS = { "permanentEnabled", "permanentCurrency", "permanentPrice", "permanentLimit", "rentalEnabled",
    "rentalCurrency", "rentalPrice", "rentalLimit", "rentalDays", "graceHours", "reminderHours", "autoRenewAllowed" }
AP.PLAN_SHARED = { "rentalDays", "graceHours", "reminderHours", "permanentLimit", "rentalLimit" }
AP.PLAN_RANGE = { permanentPrice = { 1, 1e9 }, rentalPrice = { 1, 1e9 }, permanentLimit = { 0, 1000 },
    rentalLimit = { 1, 1000 }, rentalDays = { 1, 365 }, graceHours = { 0, 168 }, reminderHours = { 0, 168 } }

-- ===== 純邏輯（harness 測） =====

-- 顯示值：伺服器原值；缺或型別不符用預設（不夾範圍：管理員要看到真正存的值）
function AP.effective(values, key)
    local o = Settings.BY_KEY[key]
    local v = values and values[key]
    local want = (o.type == "bool" and "boolean") or (o.type == "string" and "string") or "number"
    if type(v) ~= want then return o.default end
    return v
end

-- 分號清單 → 集合；空字串＝預設清單（Settings.get 同一規則）
function AP.listSet(text, default)
    if text == nil or text == "" then text = default end
    local set = {}
    for token in string.gmatch(text, "[^;]+") do
        local t = MSH.trim(token)
        if t ~= "" then set[t] = true end
    end
    return set
end

-- 集合 → 規範字串：照 order，order 以外的項目（extras，伺服器上有、面板沒有 chip 的）原樣保留在後面
function AP.listText(set, order, extras)
    local out = {}
    for _, k in ipairs(order) do
        if set[k] then out[#out + 1] = k end
    end
    for _, k in ipairs(extras or {}) do
        if set[k] then out[#out + 1] = k end
    end
    return table.concat(out, ";")
end

-- 有改動的鍵：current 與 base 都是 { key = 值 }，回 changes, 數量
function AP.changedKeys(current, base)
    local changes, n = {}, 0
    for k, v in pairs(current) do
        if v ~= base[k] then
            changes[k] = v
            n = n + 1
        end
    end
    return changes, n
end

-- 本機逐欄檢查：單鍵型別／範圍用 Settings.validateChanges（同伺服器），跨欄位（面積 ≤ 邊長²）用面板讀到的伺服器值合併
-- （客戶端 SandboxVars 可能舊）；回 { key = reason }, 數量
function AP.localErrors(changes, values)
    local errs, n = {}, 0
    for k, v in pairs(changes) do
        local ok, key, reason = Settings.validateChanges({ [k] = v })
        if not ok and reason ~= "AREA_OVER_SIDE" then
            errs[key or k] = reason
            n = n + 1
        end
    end
    if n > 0 then return errs, n end
    local function merged(key)
        local v = changes[key]
        if v == nil then v = AP.effective(values, key) end
        return v
    end
    if merged("FreeMaxArea") > merged("FreeMaxSide") * merged("FreeMaxSide") then
        errs.FreeMaxArea, n = "AREA_OVER_SIDE", n + 1
    end
    for t = 1, MSH.MAX_TIER do
        local side = merged("Tier" .. t .. "Side")
        if merged("Tier" .. t .. "Area") > side * side then
            errs["Tier" .. t .. "Area"], n = "AREA_OVER_SIDE", n + 1
        end
    end
    return errs, n
end

-- 伺服器回的欄位錯誤（adminSetOptions 的 BAD_OPTION { key, reason }）；不是欄位錯誤回 nil
function AP.serverErrors(res)
    if res.code == "BAD_OPTION" and type(res.key) == "string" then return { [res.key] = res.reason or "OUT_OF_RANGE" } end
    return nil
end

-- 這一級有沒有人建得了：免費位關著，而買斷、租用都關，或 Economy 不可用（§10.6 地契頁警告）
function AP.nobodyCanBuild(free, buy, rent, economyReady)
    return not free and (not (buy or rent) or not economyReady)
end

-- 玩家分頁狀態（伺服器分頁；Economy ECAdminIdentity 的做法）
function AP.pager()
    return { query = "", filter = "all", page = 1, typed = "", typedAt = nil, inflight = nil, lastSent = nil,
        shown = nil, failed = nil, error = nil, rows = {}, pages = 1, total = 0 }
end

function AP.pagerKey(p) return p.query .. "\1" .. p.filter .. "\1" .. p.page end

function AP.pagerType(p, text, now)
    if text ~= p.typed then p.typed, p.typedAt = text, now end
end

-- 改篩選或頁碼；換篩選回第 1 頁
function AP.pagerSet(p, field, value)
    p[field] = value
    if field ~= "page" then p.page = 1 end
end

-- 讓目前這組條件重抓（改了上限、代為放棄之後）
function AP.pagerInvalidate(p) p.shown, p.failed = nil, nil end

-- 該送就回 { query?, filter, page }, key；輸入還沒停 650 ms、有一筆在路上、離上次送出不到 650 ms、目前條件已有結果
-- （或剛失敗過，要按重新整理）都回 nil
function AP.pagerPump(p, now)
    if p.typedAt ~= nil then
        if now - p.typedAt < AP.QUERY_DEBOUNCE_MS then return nil end
        p.typedAt = nil
        -- 伺服器 query 上限 USERNAME_CHARS、不收控制字元（Server.lua TYPES.query）
        local q = string.sub(string.gsub(MSH.trim(p.typed), "%c", ""), 1, MSH.LIMIT.USERNAME_CHARS)
        if q ~= p.query then p.query, p.page = q, 1 end
    end
    if p.inflight ~= nil or (p.lastSent ~= nil and now - p.lastSent < AP.GAP_MS) then return nil end
    local key = AP.pagerKey(p)
    if key == p.shown or key == p.failed then return nil end
    p.inflight, p.lastSent = key, now
    return { query = p.query ~= "" and p.query or nil, filter = p.filter, page = p.page }, key
end

-- 回覆：送出後條件變了（過期）就丟掉、回 false；採用時頁碼用伺服器夾過的值
function AP.pagerReply(p, key, res)
    if p.inflight == key then p.inflight = nil end
    if key ~= AP.pagerKey(p) then return false end
    if not res.ok then
        p.failed, p.error = key, res.code
        return true
    end
    p.page = res.page or p.page
    p.rows, p.pages, p.total = res.rows or {}, res.pages or 1, res.total or 0
    p.error, p.failed = nil, nil
    p.shown = AP.pagerKey(p)
    return true
end

-- 整數輸入：空字串或不是整數回 nil
function AP.parseInt(text)
    local n = tonumber(MSH.trim(text or ""))
    if n == nil or n ~= math.floor(n) then return nil end
    return n
end

-- 付費頁：shared＝管理員改過的共用欄位，prices[tier]＝該級改過的價格；只回有改動的等級
-- { { tier, values = 完整 12 欄, expectedRevision } }（Economy setPlan 要求剛好 12 欄）
function AP.planChanges(tiers, shared, prices)
    local out = {}
    for _, t in ipairs(tiers or {}) do
        local plan = type(t.plan) == "table" and t.plan or {}
        local values, changed = {}, false
        for _, f in ipairs(AP.PLAN_FIELDS) do values[f] = plan[f] end
        for f, v in pairs(shared) do
            if values[f] ~= v then values[f], changed = v, true end
        end
        for f, v in pairs(prices[t.tier] or {}) do
            if values[f] ~= v then values[f], changed = v, true end
        end
        if changed then out[#out + 1] = { tier = t.tier, values = values, expectedRevision = t.revision } end
    end
    return out
end

function AP.planFieldError(field, v)
    local r = AP.PLAN_RANGE[field]
    if r and (type(v) ~= "number" or v ~= math.floor(v) or v < r[1] or v > r[2]) then return "OUT_OF_RANGE" end
    return nil
end

-- ===== 文字 =====

function AP.optionLabel(key) return getText("Sandbox_MinidoracatSafehouse_" .. key) end

function AP.codeText(code)
    local reason, action = MSH.Client.codeText(code)
    return action and (reason .. " " .. action) or reason
end

function AP.errorText(key, reason)
    local o = Settings.BY_KEY[key]
    local r = AP.PLAN_RANGE[key]
    if reason == "OUT_OF_RANGE" and (r or (o and o.min)) then
        return getText("IGUI_MSH_Admin_Err_Range", r and r[1] or o.min, r and r[2] or o.max)
    end
    local k = "IGUI_MSH_Admin_Err_" .. tostring(reason)
    local t = getText(k)
    if t ~= k then return t end
    return getText("IGUI_MSH_Admin_Err_OUT_OF_RANGE")
end

function AP.timeText(at)
    if type(at) ~= "number" then return "-" end
    return getText("IGUI_MSH_Admin_MinutesAgo", math.max(0, math.floor((getTimestampMs() - at) / 60000)))
end

-- ===== 開窗 =====

function AP.isAdmin()
    local p = getPlayer()
    local role = p and p:getRole()
    return role ~= nil and role:hasCapability(Capability.CanSetupSafehouses) == true
end

function AP.open(opts)
    opts = opts or {}
    if not AP.isAdmin() then return nil end
    local UI = MSH.Client.ui(MSH.SlotsWindow.CAPS)
    if UI == nil then return K.fallback(getText("IGUI_MSH_Admin_Title"), getText("IGUI_MSH_Admin_NeedFramework")) end
    local P = AP.instance
    if P == nil or P.UI ~= UI then
        P = AP.build(UI)
        AP.instance = P
    end
    P.win:setVisible(true)
    P.win:bringToTop()
    AP.select(P, opts.tab or P.current)
    AP.reload(P)
    return P
end

function AP.build(UI)
    local theme = MSH.Client.theme(UI)
    local x, y, W, H = K.center(AP.panelWidth(), AP.PANEL_H)
    local P = { UI = UI, theme = theme, pages = {}, pager = AP.pager(), current = "rules", tips = {} }
    P.win = UI.Window.new({ x = x, y = y, width = W, height = H, title = getText("IGUI_MSH_Admin_Title"), theme = theme,
        onClose = function() AP.hideTips(P) end })
    local top = P.win:contentTop()
    local items = {}
    for i, id in ipairs(AP.TABS) do items[i] = { id = id, label = getText("IGUI_MSH_Admin_Tab_" .. id) } end
    P.tabs = UI.Tabs.new({ x = K.PAD, y = top + 4, width = W - 2 * K.PAD, items = items, selected = "rules", theme = theme,
        target = P, onSelect = function(target, id) AP.select(target, id) end })
    P.win:addChild(P.tabs)
    local barH = 2 * K.fontH(UIFont.Small) + 44
    local bodyY = P.tabs:getY() + P.tabs:getHeight() + 4
    for _, id in ipairs(AP.TABS) do
        local sp = UI.ScrollPanel.new({ x = 0, y = bodyY, width = W, height = H - bodyY - barH, theme = theme })
        P.win:addChild(sp)
        P.pages[id] = { id = id, sp = sp, flow = K.flow(sp, UI, theme), fields = {}, errors = {}, version = 0 }
    end
    P.bar = ISPanel:new(0, H - barH, W, barH)
    P.bar:initialise()
    P.bar.background = false
    P.win:addChild(P.bar)
    P.barFlow = K.flow(P.bar, UI, theme)
    P.win:addToUIManager()
    return P
end

function AP.visible(P) return P ~= nil and P.win:isVisible() end

function AP.select(P, id)
    if P.pages[id] == nil then id = "rules" end
    P.current = id
    P.tabs:setSelected(id, true)
    AP.hideTips(P)
    for pid, pg in pairs(P.pages) do pg.sp:setVisible(pid == id) end
    AP.layoutPage(P, id)
end

-- 全部重抓：選項（含 health）、付費方案、非 active 的紀錄、遷移狀態；玩家頁重抓目前那一頁
function AP.reload(P)
    MSH.Client.send("adminOptions", {}, function(res)
        if res.ok then
            P.options, P.values, P.loadError = res, res.values or {}, nil
            for _, id in ipairs({ "rules", "deeds", "exclusions" }) do AP.resync(P, id) end
        else
            P.loadError = res.code
        end
        AP.layoutAll(P)
    end)
    MSH.Client.send("adminPlans", {}, function(res)
        P.plans = res.ok and res or { economy = res.code }
        AP.resync(P, "paid")
        AP.layoutAll(P)
    end)
    AP.loadClaims(P)
    MSH.Client.send("adminMigration", {}, function(res)
        P.migration = res.ok and res.migration or nil
        AP.layoutPage(P, "rules")
    end)
    AP.pagerInvalidate(P.pager)
    AP.layoutAll(P)
end

function AP.loadClaims(P)
    MSH.Client.send("adminClaims", {}, function(res)
        P.claims = res.ok and res.claims or nil
        AP.layoutPage(P, "rules")
    end)
end

-- 這一頁的欄位下次排版時改回伺服器值（放棄未套用的編輯）
function AP.resync(P, id)
    local pg = P.pages[id]
    pg.version, pg.errors = pg.version + 1, {}
end

function AP.layoutAll(P)
    for _, id in ipairs(AP.TABS) do AP.layoutPage(P, id) end
end

function AP.layoutPage(P, id)
    local pg = P.pages[id]
    local F = pg.flow
    F:begin(pg.sp:contentWidth())
    if id == "players" then
        AP.layoutPlayers(P, pg)
    elseif id == "paid" then
        AP.layoutPaid(P, pg)
    elseif P.values == nil then
        F:text("load", P.loadError and AP.codeText(P.loadError) or getText("IGUI_MSH_Admin_Loading"),
            P.loadError and "errorText" or "textMuted")
    elseif id == "rules" then
        AP.layoutStatus(P, pg)
        AP.layoutRules(P, pg)
    elseif id == "deeds" then
        AP.layoutDeeds(P, pg)
    else
        AP.layoutExclusions(P, pg)
    end
    F:finish()
    if id == P.current then AP.layoutBar(P) end
end

function AP.say(P, text, token)
    P.message, P.messageToken = text, token or "text"
    AP.layoutBar(P)
end

-- 底列：〔套用變更〕（設定頁與付費頁）、〔重新載入〕、狀態訊息
function AP.layoutBar(P)
    local F = P.barFlow
    F:begin(P.bar:getWidth())
    local ctrls = {}
    if P.current ~= "players" then
        local apply = F:button("apply", getText("IGUI_MSH_Admin_Apply"), P, AP.onApply, "primary")
        apply:setEnabled(P.busy == nil and (P.current ~= "paid" or (P.plans ~= nil and P.plans.economy == "READY")))
        ctrls[1] = apply
    end
    ctrls[#ctrls + 1] = F:button("reload", getText("IGUI_MSH_Admin_Reload"), P, AP.onReload)
    F:row(ctrls)
    if P.busy then
        F:text("msg", P.message or getText("IGUI_MSH_Admin_Busy"), P.message and P.messageToken or "textMuted")
    elseif P.message then
        F:text("msg", P.message, P.messageToken)
    end
    F:finish()
end

function AP.onReload(P)
    if P.busy then return end
    AP.say(P, nil)
    AP.reload(P)
end

-- mutation：一次一筆；10 秒沒回覆先說「等候中」，伺服器結果快取過期還沒回就說結果未知、請重新載入確認
function AP.mutate(P, command, args, done)
    if P.busy then return false end
    P.busy, P.message = command, nil
    AP.layoutBar(P)
    MSH.Client.send(command, args, function(res)
        if res.code == "NO_REPLY" and res.pending and not res.expired then
            return AP.say(P, getText("IGUI_MSH_Admin_Waiting"), "warning")
        end
        P.busy = nil
        if res.code == "NO_REPLY" then return AP.say(P, getText("IGUI_MSH_Admin_Unknown"), "warning") end
        done(res)
        AP.layoutBar(P)
    end, { mutation = true })
    return true
end

-- ===== 欄位（設定頁） =====
-- field = { key, kind = num|bool|enum|list, el | chips, value, set, order, extras, zeroBlank, at（同步到的版本）, gen }

local function field(pg, key, kind)
    local f = pg.fields[key]
    if f == nil then
        f = { key = key, kind = kind }
        pg.fields[key] = f
    end
    f.gen = pg.flow.gen
    return f
end

-- 欄位值改回伺服器值（版本不同時；面板開啟、重新載入、該頁套用成功）
function AP.syncField(P, pg, f)
    if f.at == pg.version then return end
    f.at = pg.version
    local v = AP.effective(P.values, f.key)
    if f.kind == "num" then
        f.el:setText((f.zeroBlank and v == 0) and "" or tostring(v))
    elseif f.kind == "bool" then
        f.el:setChecked(v, true)
    elseif f.kind == "enum" then
        f.value = v
    else
        f.set = AP.listSet(v, f.default)
        f.extras = {}
        local known = {}
        for _, k in ipairs(f.order) do known[k] = true end
        for k in string.gmatch(v == "" and f.default or v, "[^;]+") do
            local t = MSH.trim(k)
            if t ~= "" and not known[t] then f.extras[#f.extras + 1] = t end
        end
    end
end

function AP.numField(P, pg, key, width, onEdit, zeroBlank)
    local f = field(pg, key, "num")
    local UI, theme = P.UI, P.theme
    f.el = pg.flow:get("f:" .. key, function()
        local tf = UI.TextField.new({ x = 0, y = 0, width = width or 70, theme = theme,
            placeholder = zeroBlank and getText("IGUI_MSH_Admin_Unlimited") or nil,
            onChange = function() if onEdit then onEdit(P, pg) end end })
        tf:setTooltip(getText("Sandbox_MinidoracatSafehouse_" .. key .. "_tooltip"))
        return tf
    end)
    if width ~= nil and f.el.width ~= width then f.el:setWidth(width) end
    f.zeroBlank = zeroBlank
    AP.syncField(P, pg, f)
    AP.markError(P, f.el, pg.errors[key] and AP.errorText(key, pg.errors[key]) or nil)
    return f.el
end

function AP.boolField(P, pg, key, label, onEdit)
    local f = field(pg, key, "bool")
    f.el = pg.flow:checkbox("f:" .. key, label or "", P, function()
        if onEdit then onEdit(P, pg) end
    end)
    if f.el.setTooltip then f.el:setTooltip(getText("Sandbox_MinidoracatSafehouse_" .. key .. "_tooltip")) end
    AP.syncField(P, pg, f)
    return f.el
end

-- 單選 chips；labels[i]＝第 i 個值的文字
function AP.enumField(P, pg, key, labels, onEdit)
    local f = field(pg, key, "enum")
    AP.syncField(P, pg, f)
    f.chips = f.chips or {}
    for i, label in ipairs(labels) do
        local b = pg.flow:button("f:" .. key .. ":" .. i, label, P, AP.onEnumChip, "chip")
        b.internal, b.field, b.page, b.onEdit = i, f, pg, onEdit
        b:setActive(f.value == i)
        f.chips[i] = b
    end
    return f.chips
end

function AP.onEnumChip(P, b)
    local f = b.field
    f.value = b.internal
    for _, c in ipairs(f.chips) do c:setActive(c.internal == f.value) end
    if b.onEdit then b.onEdit(P, b.page) end
end

-- 多選 chips；options = { { key, label } }
function AP.listField(P, pg, key, options, default)
    local f = field(pg, key, "list")
    f.default, f.order = default, {}
    for i, o in ipairs(options) do f.order[i] = o.key end
    AP.syncField(P, pg, f)
    local chips = {}
    for _, o in ipairs(options) do
        local b = pg.flow:button("f:" .. key .. ":" .. o.key, o.label, P, AP.onListChip, "chip")
        b.internal, b.field = o.key, f
        b:setActive(f.set[o.key] == true)
        chips[#chips + 1] = b
    end
    return chips
end

function AP.onListChip(P, b)
    local f = b.field
    f.set[b.internal] = not f.set[b.internal] or nil
    b:setActive(f.set[b.internal] == true)
end

-- 欄位錯誤：rev 16 setInvalid（textFieldInvalid）；沒有就放進 tooltip
function AP.markError(P, el, message)
    if el.setInvalid and P.UI.CAPABILITIES.textFieldInvalid then
        el:setInvalid(message ~= nil, message)
    elseif message ~= nil then
        el:setTooltip(message)
    end
end

function AP.fieldValue(f)
    if f.kind == "num" then
        local t = MSH.trim(f.el:getText())
        if t == "" and f.zeroBlank then return 0 end
        return tonumber(t) or t   -- 不是數字原樣送進檢查，回 OUT_OF_RANGE
    elseif f.kind == "bool" then
        return f.el:getChecked()
    elseif f.kind == "enum" then
        return f.value
    end
    return AP.listText(f.set, f.order, f.extras)
end

function AP.baseValue(P, f)
    local v = AP.effective(P.values, f.key)
    if f.kind == "list" then return AP.listText(AP.listSet(v, f.default), f.order, f.extras) end
    return v
end

-- 表單一列：左邊選項名（固定欄寬），右邊控制項
function AP.formRow(pg, key, labelW, ctrls)
    local l = pg.flow:label("l:" .. key, AP.optionLabel(key))
    l:setWidth(labelW)
    local row = { l }
    for _, c in ipairs(ctrls) do row[#row + 1] = c end
    pg.flow:row(row)
end

function AP.labelWidth(keys)
    local w = 0
    for _, k in ipairs(keys) do w = math.max(w, K.textW(UIFont.Small, AP.optionLabel(k))) end
    return w + K.GAP
end

-- ===== 規則頁 =====

function AP.layoutRules(P, pg)
    local F = pg.flow
    F.y = F.y + K.GAP
    F:text("h:rules", getText("IGUI_MSH_Admin_RulesHead"), "text", UIFont.Medium)
    local lw = AP.labelWidth(AP.RULE_KEYS)
    for _, key in ipairs(AP.RULE_KEYS) do
        local o = Settings.BY_KEY[key]
        local ctrls
        if key == "CreateMode" then
            ctrls = AP.enumField(P, pg, key, { getText("Sandbox_MinidoracatSafehouse_CreateMode_option1"),
                getText("Sandbox_MinidoracatSafehouse_CreateMode_option2") })
        elseif o.type == "bool" then
            ctrls = { AP.boolField(P, pg, key) }
        else
            ctrls = { AP.numField(P, pg, key, AP.fieldW(key, 70)) }
        end
        AP.formRow(pg, key, lw, ctrls)
    end
end

-- 伺服器狀態（health detail）、遷移狀態、targeted recovery
function AP.layoutStatus(P, pg)
    local F = pg.flow
    local h = P.options and P.options.health or {}
    F:text("h:health", getText("IGUI_MSH_Admin_HealthHead"), "text", UIFont.Medium)
    local sep = getText("IGUI_MSH_Admin_ListSep")
    if h.blocked then
        F:text("hb", getText("IGUI_MSH_Admin_Blocked", table.concat(h.blockers or {}, sep)), "warning")
    else
        F:text("hb", getText("IGUI_MSH_Admin_Healthy"), "text")
    end
    if type(h.warnings) == "table" and #h.warnings > 0 then
        F:text("hw", getText("IGUI_MSH_Admin_Warnings", table.concat(h.warnings, sep)), "warning")
    end
    local sw = P.options and P.options.settingsWarnings
    if type(sw) == "table" and #sw > 0 then
        F:text("hs", getText("IGUI_MSH_Admin_SettingsWarnings", table.concat(sw, sep)), "warning")
    end
    if h.hostile then F:text("hh", getText("IGUI_MSH_Admin_Hostile"), "warning") end
    F:text("hr", getText("IGUI_MSH_Admin_Reconcile", AP.timeText(h.lastSuccessAt), h.pendingRepair or 0,
        math.floor((h.longestDriftMs or 0) / 1000), h.interference or 0), "textMuted")
    if type(h.suppressed) == "number" and h.suppressed > 0 then
        F:text("hp", getText("IGUI_MSH_Admin_Suppressed", h.suppressed), "textMuted")
    end
    local lr = h.lastRecovery
    if type(lr) == "table" then
        F:text("hl", getText("IGUI_MSH_Admin_LastRecovery", lr.claimId or "-", lr.action or "-", lr.code or "-",
            AP.timeText(lr.at)), "textMuted")
    end
    AP.layoutMigration(P, pg)
    AP.layoutRecovery(P, pg)
end

function AP.layoutMigration(P, pg)
    local m = P.migration
    if type(m) ~= "table" then return end
    local F = pg.flow
    F:text("mg", getText("IGUI_MSH_Admin_Migration", getText("IGUI_MSH_Admin_Mig_" .. tostring(m.status))),
        m.completed == false and "warning" or "textMuted")
    if m.status == "none" then return end
    local function n(v) return v ~= nil and tostring(v) or "-" end
    F:text("mc", getText("IGUI_MSH_Admin_MigCounts", n(m.candidates), n(m.bshMatched), n(m.allowed), n(m.denied),
        n(m.imported), n(m.skipped), n(m.missing)), "textMuted")
    if m.abort ~= nil then F:text("ma", getText("IGUI_MSH_Admin_MigAbort", tostring(m.abort)), "errorText") end
    local files = type(m.files) == "table" and m.files or {}
    F:text("mf", getText("IGUI_MSH_Admin_MigFiles", n(files.report), n(files.selection), n(files.completion)), "textMuted")
end

-- 非 active 的紀錄；quarantined 可重新綁定或釋出（§10.6 targeted recovery，不做地圖瀏覽與傳送）
function AP.layoutRecovery(P, pg)
    local F = pg.flow
    F.y = F.y + K.GAP
    F:text("h:rec", getText("IGUI_MSH_Admin_RecoveryHead"), "text", UIFont.Medium)
    if P.claims == nil then return F:text("rc", getText("IGUI_MSH_Admin_Loading"), "textMuted") end
    if #P.claims == 0 then return F:text("rc", getText("IGUI_MSH_Admin_RecoveryNone"), "textMuted") end
    for i, c in ipairs(P.claims) do
        local l = F:label("rc" .. i, getText("IGUI_MSH_Admin_RecoveryRow", c.claimId, AP.lifeText(c.lifecycle),
            tostring(c.quarantineReason or "-"), tostring(c.owner or "-")))
        local row = { l }
        if c.lifecycle == MSH.LIFECYCLE.QUARANTINED then
            local rb = F:button("rcb" .. i, getText("IGUI_MSH_Admin_Rebind"), P, AP.onRebind)
            local rr = F:button("rcr" .. i, getText("IGUI_MSH_Admin_ForceRelease"), P, AP.onForceRelease, "danger")
            rb.internal, rr.internal = c, c
            rb:setEnabled(P.busy == nil)
            rr:setEnabled(P.busy == nil)
            row[2], row[3] = rb, rr
        end
        F:row(row)
    end
end

function AP.lifeText(lc) return getText("IGUI_MSH_Admin_Life_" .. tostring(lc)) end

function AP.recoverDone(P, res)
    if res.ok then
        AP.say(P, getText("IGUI_MSH_Admin_Recovered", res.claimId or "-"), "text")
    else
        AP.say(P, AP.codeText(res.code), "errorText")
    end
    AP.reload(P)
end

function AP.onRebind(P, b)
    local c = b.internal
    P.UI.Dialog.show({ title = getText("IGUI_MSH_Admin_Rebind"), theme = P.theme,
        text = getText("IGUI_MSH_Admin_RebindText", c.claimId),
        input = { text = c.owner or "", placeholder = getText("IGUI_MSH_Admin_OwnerPlaceholder") },
        confirmText = getText("IGUI_MSH_Admin_Rebind"), cancelText = getText("UI_Cancel"),
        onResult = function(ok, input)
            if not ok then return end
            local who = MSH.trim(input or "")
            local args = { claimId = c.claimId, action = "rebind" }
            if who ~= "" and who ~= c.owner then
                if not MSH.validUsername(who) then return AP.say(P, AP.codeText("BAD_USER"), "errorText") end
                args.targetUsername = who
            end
            AP.mutate(P, "adminRecover", args, function(res) AP.recoverDone(P, res) end)
        end })
end

function AP.onForceRelease(P, b)
    local c = b.internal
    P.UI.Dialog.show({ title = getText("IGUI_MSH_Admin_ForceRelease"), theme = P.theme, danger = true,
        text = getText("IGUI_MSH_Admin_ForceReleaseText", c.claimId, tostring(c.owner or "-")),
        confirmText = getText("IGUI_MSH_Admin_ForceRelease"), cancelText = getText("UI_Cancel"),
        onResult = function(ok)
            if ok then
                AP.mutate(P, "adminRecover", { claimId = c.claimId, action = "release" },
                    function(res) AP.recoverDone(P, res) end)
            end
        end })
end

-- ===== 地契頁 =====

function AP.economyReady(P) return P.plans ~= nil and P.plans.economy == "READY" end

-- 目前輸入的啟用等級數（還在打字、不是數字時用伺服器值）
function AP.currentTiers(P, pg)
    local f = pg.fields.TiersEnabled
    local n = f and AP.parseInt(f.el:getText())
    if n == nil or n < 1 or n > MSH.MAX_TIER then n = AP.effective(P.values, "TiersEnabled") end
    return n
end

function AP.onDeedsEdit(P, pg) AP.layoutPage(P, pg.id) end

AP.DEED_COLS = { "Tier", "Side", "Area", "PerPlayer", "Loot", "Craft", "Free", "Buy", "Rent" }
AP.DEED_MIN_W = { Tier = 40, Side = 56, Area = 64, PerPlayer = 56, Loot = 56, Craft = 70, Free = 40, Buy = 40, Rent = 40 }
AP.DEED_FIELD_W = { Side = 52, Area = 60, PerPlayer = 52, Loot = 52 }   -- 下限；實際寬度見 AP.fieldW
AP.DEED_FIELD_KEY = { Side = "Side", Area = "Area", PerPlayer = "PerPlayer", Loot = "LootChance" }
-- TextField 文字區兩側內距（Controls.lua FIELD_PAD 6＋TEXTBOX_INSET 2，各兩側）再留 4 格餘裕：placeholder 寬＋這個＝不截字
AP.FIELD_CHROME = 20
AP.TOGGLE_W = 48   -- 開關 36＋標籤間距 8＋餘裕（Controls.lua TOGGLE_WIDTH／LABEL_GAP；標籤是空字串）
AP.PANEL_W, AP.PANEL_H = 780, 620
AP.SCROLL_GUTTER = 12   -- ScrollPanel 右側固定保留的捲軸槽（ScrollPanel:contentWidth）

-- 整數上限的位數（不用 tostring：1e9 會印成科學記號）
function AP.digits(max)
    local d, n = 1, math.floor(math.abs(max))
    while n >= 10 do d, n = d + 1, math.floor(n / 10) end
    return d
end

-- 一個數字欄最寬合法值的寬度：整數部分＝上限的位數 × 目前字型最寬的數字（0–9 逐一量，比例字型也不低估），
-- 小數（掉落機率）再加小數點與兩位；下限為負時加負號。用 getTextManager():MeasureStringX 量（同 placeholder 那次），
-- 不猜字型倍率（繁中 200% 字型實機「1600」被裁成「160(」）。只在排版時呼叫，不在 render
function AP.numberTextW(lo, hi, decimals)
    local digitW = 0
    for d = 0, 9 do digitW = math.max(digitW, K.textW(UIFont.Small, tostring(d))) end
    local w = AP.digits(hi) * digitW
    if decimals then w = w + K.textW(UIFont.Small, ".") + decimals * digitW end
    if lo ~= nil and lo < 0 then w = w + K.textW(UIFont.Small, "-") end
    return w
end

-- 數字輸入框寬：最寬合法值＋兩側內距；minW 只當下限
function AP.sampleW(textW, minW)
    return math.max(minW or 0, textW + AP.FIELD_CHROME)
end

-- 沙盒選項的數字框寬；每人上限另外要放得下 placeholder「不限」（法文、俄文實機截字）
function AP.fieldW(key, minW)
    local o = Settings.BY_KEY[key]
    local w = AP.sampleW(AP.numberTextW(o.min, o.max, o.type == "double" and 2 or nil), minW)
    if string.find(key, "PerPlayer$") then
        w = math.max(w, K.textW(UIFont.Small, getText("IGUI_MSH_Admin_Unlimited")) + AP.FIELD_CHROME)
    end
    return w
end

-- 付費頁欄位寬（範圍見 AP.PLAN_RANGE）
function AP.planFieldW(fieldName, minW)
    local r = AP.PLAN_RANGE[fieldName]
    return AP.sampleW(AP.numberTextW(r[1], r[2]), minW)
end

function AP.perPlayerFieldW() return AP.fieldW("Tier1PerPlayer", AP.DEED_FIELD_W.PerPlayer) end

function AP.deedFieldW(c) return AP.fieldW("Tier1" .. AP.DEED_FIELD_KEY[c], AP.DEED_FIELD_W[c]) end

-- 欄位 x 位置與寬度：表頭、該欄控制項（列標「N 級」取 8 級、製作取四個難度名稱最寬者、輸入框、開關）都量進去。
-- 回 xs, 表格右緣, ws
function AP.deedColumns()
    local xs, ws, x = {}, {}, K.PAD
    for _, c in ipairs(AP.DEED_COLS) do
        local w = math.max(AP.DEED_MIN_W[c], K.textW(UIFont.Small, getText("IGUI_MSH_Admin_Col_" .. c)) + 8)
        if c == "Tier" then
            w = math.max(w, K.textW(UIFont.Small, getText("IGUI_MSH_Admin_TierN", MSH.MAX_TIER)) + 8)
        elseif c == "Craft" then
            for i = 1, 4 do
                w = math.max(w, K.textW(UIFont.Small, getText("Sandbox_MinidoracatSafehouse_CraftLevel_option" .. i)) + 24)
            end
        elseif AP.DEED_FIELD_KEY[c] then
            w = math.max(w, AP.deedFieldW(c))
        else
            w = math.max(w, AP.TOGGLE_W)
        end
        xs[c], ws[c] = x, w
        x = x + w + K.GAP
    end
    return xs, x - K.GAP, ws
end

-- 面板寬：預設寬與地契表格需要的寬取大者（譯文變長的部分算進寬度，家族 pitfalls），上限由 K.center 夾到螢幕寬
function AP.panelWidth()
    local _, right = AP.deedColumns()
    return math.max(AP.PANEL_W, right + K.PAD + AP.SCROLL_GUTTER)
end

function AP.layoutDeeds(P, pg)
    local F = pg.flow
    local econ = AP.economyReady(P)
    local head = { F:label("kLabel", AP.optionLabel("TiersEnabled")),
        AP.numField(P, pg, "TiersEnabled", AP.fieldW("TiersEnabled", 48), AP.onDeedsEdit),
        F:label("kOf", getText("IGUI_MSH_Admin_TiersOf", MSH.MAX_TIER), "textMuted") }
    if AP.shopApi() then head[#head + 1] = F:button("shop", getText("IGUI_MSH_Admin_ShopAdd"), P, AP.onShop) end
    F:row(head)
    local k = AP.currentTiers(P, pg)
    local xs = AP.deedColumns()
    local hy = F.y
    for _, c in ipairs(AP.DEED_COLS) do
        local l = F:label("hd:" .. c, getText("IGUI_MSH_Admin_Col_" .. c), "textMuted")
        l:setX(xs[c])
        l:setY(hy)
    end
    F.y = hy + K.fontH(UIFont.Small) + 4
    for n = 1, MSH.MAX_TIER do AP.layoutDeedRow(P, pg, n, n <= k, econ, xs) end
    if not econ then F:text("noEcon", getText("IGUI_MSH_Admin_NoEconomyDeeds"), "textMuted") end
end

function AP.layoutDeedRow(P, pg, n, on, econ, xs)
    local F = pg.flow
    local p = "Tier" .. n
    local tl = F:label("tn" .. n, getText("IGUI_MSH_Admin_TierN", n), on and "text" or "textDisabled")
    local ctrls = {
        Tier = tl,
        Side = AP.numField(P, pg, p .. "Side", AP.deedFieldW("Side")),
        Area = AP.numField(P, pg, p .. "Area", AP.deedFieldW("Area")),
        PerPlayer = AP.numField(P, pg, p .. "PerPlayer", AP.deedFieldW("PerPlayer"), nil, true),
        Loot = AP.numField(P, pg, p .. "LootChance", AP.deedFieldW("Loot")),
        Craft = AP.craftButton(P, pg, n),
        Free = AP.boolField(P, pg, p .. "Free", "", AP.onDeedsEdit),
        Buy = AP.boolField(P, pg, p .. "Buy", "", AP.onDeedsEdit),
        Rent = AP.boolField(P, pg, p .. "Rent", "", AP.onDeedsEdit),
    }
    local rowH = 0
    for _, c in pairs(ctrls) do rowH = math.max(rowH, c.height) end
    for _, c in ipairs(AP.DEED_COLS) do
        local el = ctrls[c]
        el:setX(xs[c])
        el:setY(F.y + math.floor((rowH - el.height) / 2))
        if el ~= tl then el:setEnabled(on and (econ or (c ~= "Buy" and c ~= "Rent"))) end
    end
    F.y = F.y + rowH + 4
    local free, buy, rent = ctrls.Free:getChecked(), ctrls.Buy:getChecked(), ctrls.Rent:getChecked()
    if on and AP.nobodyCanBuild(free, buy, rent, econ) then
        F:text("warn" .. n, getText("IGUI_MSH_Admin_NobodyCanBuild", n), "warning")
    end
end

-- 製作難度：點一下換下一個（不開放→寬鬆→標準→嚴格）；滑鼠移過去預覽選中難度的配方（不開放時預覽標準版，§7.7）
function AP.craftButton(P, pg, n)
    local key = "Tier" .. n .. "Craft"
    local f = field(pg, key, "enum")
    AP.syncField(P, pg, f)
    local UI, theme = P.UI, P.theme
    local b = pg.flow:get("f:" .. key, function()
        local btn = UI.Button.new({ x = 0, y = 0, title = "", theme = theme, target = P, onClick = AP.onCraft })
        local move, out = btn.onMouseMove, btn.onMouseMoveOutside
        btn.onMouseMove = function(self, dx, dy)
            if move then move(self, dx, dy) end
            AP.showTip(P, self)
        end
        btn.onMouseMoveOutside = function(self, dx, dy)
            if out then out(self, dx, dy) end
            AP.hideTip(P, self)
        end
        return btn
    end)
    b.internal, b.field, b.page = n, f, pg
    b:setTitle(getText("Sandbox_MinidoracatSafehouse_CraftLevel_option" .. tostring(f.value)))
    b:setTooltip(getText("Sandbox_MinidoracatSafehouse_" .. key .. "_tooltip"))
    b:setWidth(math.max(AP.DEED_MIN_W.Craft, K.textW(UIFont.Small, b.title) + 20))
    return b
end

function AP.onCraft(P, b)
    local f = b.field
    f.value = f.value % 4 + 1
    b:setTitle(getText("Sandbox_MinidoracatSafehouse_CraftLevel_option" .. tostring(f.value)))
    AP.showTip(P, b)
end

-- 原版配方提示框；標題列建立時沒傳 player，配方要光線時會對 nil 呼叫 tooDarkToRead，
-- 所以建立期間在 ISWidgetTitleHeader 類別上暫放 player、建好寫進實例再還原（deeds-ui-sp 實測）。
-- 每次移動都重新 activate：同一配方會 bringToTop，視窗被點到上層後提示框能回到上面（ISCraftRecipeTooltip.lua:220-224）
function AP.showTip(P, b)
    local level = AP.CRAFT_LEVELS[b.field.value] or "Standard"
    local sm = getScriptManager()
    local recipe = sm and sm:getCraftRecipe("CraftMinidoracatSafehouseDeed" .. b.internal .. level)
    local player = getPlayer()
    if recipe == nil or player == nil or ISCraftRecipeTooltip == nil or ISWidgetTitleHeader == nil then return end
    local prev = rawget(ISWidgetTitleHeader, "player")
    ISWidgetTitleHeader.player = player
    local ok = pcall(ISCraftRecipeTooltip.activateToolTipFor, b, player, recipe, nil, true)
    ISWidgetTitleHeader.player = prev
    local t = b.__toolTip
    if t and t.titleWidget then t.titleWidget.player = player end
    if ok then P.tips[b] = true end
end

function AP.hideTip(P, b)
    if P.tips[b] and ISCraftRecipeTooltip then ISCraftRecipeTooltip.deactivateToolTipFor(b) end
    P.tips[b] = nil
end

function AP.hideTips(P)
    local list = {}
    for b in pairs(P.tips) do list[#list + 1] = b end
    for _, b in ipairs(list) do AP.hideTip(P, b) end
end

-- 到經濟中心上架：Economy 客戶端 rev 4＋shopAdd（計畫 §1.3）
function AP.shopApi()
    local EC = MinidoracatEconomy
    local CL = EC and EC.v1 and EC.v1.Client
    local caps = CL and CL.CAPABILITIES
    if CL and CL.API_MAJOR == 1 and (CL.API_REVISION or 0) >= 4 and type(caps) == "table" and caps.shopAdd == true
        and type(CL.openAdminShop) == "function" then
        return CL
    end
    return nil
end

function AP.onShop(P)
    local CL = AP.shopApi()
    if CL == nil then return end
    local items = {}
    for n = 1, AP.effective(P.values, "TiersEnabled") do items[n] = MSH.DEED_PREFIX .. n end
    local ok, done, err = pcall(CL.openAdminShop, MSH.MOD_ID, items)
    if not ok or done ~= true then
        AP.say(P, getText("IGUI_MSH_Admin_ShopFailed", tostring(ok and err or done)), "errorText")
    end
end

-- ===== 排除頁 =====

function AP.categories()
    local R = MinidoracatMiniMapResourceAPI
    local out = {}
    if type(R) == "table" and type(R.categories) == "function" then
        local ok, list, n = pcall(R.categories)
        if ok and type(list) == "table" then
            for i = 1, n or #list do
                local c = list[i]
                if type(c) == "table" and type(c.key) == "string" then
                    out[#out + 1] = { key = c.key, label = type(c.nameKey) == "string" and getText(c.nameKey) or c.key }
                end
            end
        end
    end
    if #out == 0 then
        for k in string.gmatch(Settings.DEFAULT_RESOURCE_CATS, "[^;]+") do out[#out + 1] = { key = k, label = k } end
    end
    return out
end

function AP.layoutExclusions(P, pg)
    local F = pg.flow
    local keys = { "AvoidRoads", "RoadMargin", "RoadKinds", "AvoidResources", "ResourceRule", "ResourceCats" }
    local lw = AP.labelWidth(keys)
    F:text("h:roads", getText("IGUI_MSH_Admin_RoadsHead"), "text", UIFont.Medium)
    AP.formRow(pg, "AvoidRoads", lw, { AP.boolField(P, pg, "AvoidRoads") })
    AP.formRow(pg, "RoadMargin", lw, { AP.numField(P, pg, "RoadMargin", AP.fieldW("RoadMargin", 52)) })
    local kinds = {}
    for i, k in ipairs(Settings.ROAD_KINDS) do kinds[i] = { key = k, label = getText("IGUI_MSH_Admin_Road_" .. k) } end
    AP.formRow(pg, "RoadKinds", lw, AP.listField(P, pg, "RoadKinds", kinds, Settings.DEFAULT_ROAD_KINDS))
    -- 自家車道放寬用的停車場資料來源（§8.1；MiniMap parkingIn v4 有沒有）
    F:text("parking", getText(P.options and P.options.parkingApi and "IGUI_MSH_Admin_ParkingMiniMap"
        or "IGUI_MSH_Admin_ParkingNone"), "textMuted")
    F.y = F.y + K.GAP
    F:text("h:res", getText("IGUI_MSH_Admin_ResourcesHead"), "text", UIFont.Medium)
    if not (P.options and P.options.resourceApi) then
        return F:text("noMiniMap", getText("IGUI_MSH_Admin_NoMiniMap"), "textMuted")
    end
    AP.formRow(pg, "AvoidResources", lw, { AP.boolField(P, pg, "AvoidResources") })
    AP.formRow(pg, "ResourceRule", lw, AP.enumField(P, pg, "ResourceRule", {
        getText("Sandbox_MinidoracatSafehouse_ResourceRule_option1"), getText("Sandbox_MinidoracatSafehouse_ResourceRule_option2") }))
    F:text("ruleHelp", getText("Sandbox_MinidoracatSafehouse_ResourceRule_tooltip"), "textMuted")
    AP.formRow(pg, "ResourceCats", lw, AP.listField(P, pg, "ResourceCats", AP.categories(), Settings.DEFAULT_RESOURCE_CATS))
end

-- ===== 套用（設定頁） =====

function AP.onApply(P)
    if P.busy then return end
    if P.current == "paid" then return AP.applyPlans(P) end
    local pg = P.pages[P.current]
    if P.values == nil then return end
    local current, base = {}, {}
    for key, f in pairs(pg.fields) do
        if f.gen == pg.flow.gen and (f.el == nil or f.el:isVisible()) then
            current[key], base[key] = AP.fieldValue(f), AP.baseValue(P, f)
        end
    end
    local changes, n = AP.changedKeys(current, base)
    if n == 0 then return AP.say(P, getText("IGUI_MSH_Admin_NoChanges"), "textMuted") end
    local errs, bad = AP.localErrors(changes, P.values)
    if bad > 0 then return AP.showErrors(P, pg, errs) end
    pg.errors = {}
    AP.mutate(P, "adminSetOptions", { changes = changes }, function(res)
        if res.ok then
            P.values = res.values or P.values
            AP.resync(P, pg.id)
            AP.say(P, getText("IGUI_MSH_Admin_Saved", n), "text")
            AP.layoutPage(P, pg.id)
            return
        end
        local se = AP.serverErrors(res)
        if se then return AP.showErrors(P, pg, se) end
        AP.say(P, AP.codeText(res.code), "errorText")
    end)
end

function AP.showErrors(P, pg, errs)
    pg.errors = errs
    local parts = {}
    for _, o in ipairs(Settings.OPTIONS) do
        if errs[o.key] then parts[#parts + 1] = getText("IGUI_MSH_Admin_FieldError", AP.optionLabel(o.key), AP.errorText(o.key, errs[o.key])) end
    end
    AP.layoutPage(P, pg.id)
    AP.say(P, table.concat(parts, getText("IGUI_MSH_Admin_ListSep")), "errorText")
end

-- ===== 玩家頁 =====

function AP.layoutPlayers(P, pg)
    local F, UI, theme, p = pg.flow, P.UI, P.theme, P.pager
    local search = F:get("search", function()
        return UI.TextField.new({ x = 0, y = 0, width = 220, theme = theme, placeholder = getText("IGUI_MSH_Admin_Search"),
            maxLength = MSH.LIMIT.USERNAME_CHARS, onChange = function(_, text) AP.pagerType(P.pager, text, getTimestampMs()) end })
    end)
    local row = { search }
    for _, id in ipairs(AP.FILTERS) do
        local b = F:button("flt:" .. id, getText("IGUI_MSH_Admin_Filter_" .. id), P, AP.onFilter, "chip")
        b.internal = id
        b:setActive(p.filter == id)
        row[#row + 1] = b
    end
    F:row(row)
    local prev = F:button("prev", getText("IGUI_MSH_Admin_Prev"), P, AP.onPage)
    local nxt = F:button("next", getText("IGUI_MSH_Admin_Next"), P, AP.onPage)
    prev.internal, nxt.internal = -1, 1
    prev:setEnabled(p.page > 1)
    nxt:setEnabled(p.page < p.pages)
    F:row({ prev, F:label("pageOf", getText("IGUI_MSH_Admin_PageOf", p.page, p.pages, p.total), "textMuted"), nxt })
    if p.error then
        F:text("perr", AP.codeText(p.error), "errorText")
    elseif p.shown ~= AP.pagerKey(p) then
        F:text("perr", getText("IGUI_MSH_Admin_Loading"), "textMuted")
    elseif #p.rows == 0 then
        F:text("perr", getText("IGUI_MSH_Admin_NoPlayers"), "textMuted")
    end
    local nameW = 0
    for _, r in ipairs(p.rows) do nameW = math.max(nameW, K.textW(UIFont.Small, r.name)) end
    for i, r in ipairs(p.rows) do AP.layoutPlayerRow(P, pg, i, r, nameW + K.GAP) end
end

function AP.layoutPlayerRow(P, pg, i, r, nameW)
    local F = pg.flow
    local name = F:label("pn" .. i, r.name)
    name:setWidth(nameW)
    local usage = getText(r.override >= 0 and "IGUI_MSH_Admin_UsageCustom" or "IGUI_MSH_Admin_Usage", r.used, r.free)
    local lim = F:button("po" .. i, getText("IGUI_MSH_Admin_SetLimit"), P, AP.onOverride)
    local open = P.selected == r.name
    local view = F:button("pv" .. i, getText(open and "IGUI_MSH_Admin_Hide" or "IGUI_MSH_Admin_View"), P, AP.onView)
    lim.internal, view.internal = r, r.name
    lim:setEnabled(P.busy == nil)
    F:row({ name, F:label("pu" .. i, usage, "textMuted"), lim, view })
    if not open then return end
    local claims = type(r.claims) == "table" and r.claims or {}
    if #claims == 0 then return F:text("pc" .. i, getText("IGUI_MSH_Admin_NoClaims"), "textMuted") end
    for j, c in ipairs(claims) do
        local key = "pc" .. i .. ":" .. j
        local l = F:label(key, getText("IGUI_MSH_Admin_ClaimRow", c.claimId, tostring(c.title or ""), c.tier or "-",
            AP.lifeText(c.lifecycle)))
        local rel = F:button(key .. "r", getText("IGUI_MSH_Admin_Release"), P, AP.onRelease, "danger")
        rel.internal, rel.owner = c, r.name
        rel:setEnabled(P.busy == nil and c.lifecycle ~= MSH.LIFECYCLE.RELEASING)
        F:row({ l, rel }, K.PAD + 16)
    end
end

function AP.onFilter(P, b)
    AP.pagerSet(P.pager, "filter", b.internal)
    AP.layoutPage(P, "players")
end

function AP.onPage(P, b)
    local p = P.pager
    AP.pagerSet(p, "page", math.max(1, math.min(p.pages, p.page + b.internal)))
    AP.layoutPage(P, "players")
end

function AP.onView(P, b)
    P.selected = P.selected ~= b.internal and b.internal or nil
    AP.layoutPage(P, "players")
end

function AP.onOverride(P, b)
    local r = b.internal
    local def = AP.effective(P.values, "ClaimsPerPlayer")
    P.UI.Dialog.show({ title = getText("IGUI_MSH_Admin_SetLimit"), theme = P.theme,
        text = getText("IGUI_MSH_Admin_OverrideText", r.name, def),
        input = { text = r.override >= 0 and tostring(r.override) or "", placeholder = getText("IGUI_MSH_Admin_OverridePlaceholder") },
        confirmText = getText("IGUI_MSH_Admin_Save"), cancelText = getText("UI_Cancel"),
        onResult = function(ok, input)
            if not ok then return end
            local t = MSH.trim(input or "")
            local n = t == "" and -1 or AP.parseInt(t)
            if n == nil or n < -1 or n > 1000 then return AP.say(P, getText("IGUI_MSH_Admin_OverrideBad"), "errorText") end
            AP.mutate(P, "adminSetOverride", { targetUsername = r.name, n = n }, function(res)
                if res.ok then
                    AP.say(P, getText("IGUI_MSH_Admin_OverrideSaved", r.name), "text")
                    AP.pagerInvalidate(P.pager)
                else
                    AP.say(P, AP.codeText(res.code), "errorText")
                end
            end)
        end })
end

-- 代為放棄：danger 對話框；帶畫面上那一版的 revision，期間被改過就 STALE_REVISION、不放棄
function AP.onRelease(P, b)
    local c = b.internal
    P.UI.Dialog.show({ title = getText("IGUI_MSH_Admin_Release"), theme = P.theme, danger = true,
        text = getText("IGUI_MSH_Admin_ReleaseText", b.owner, tostring(c.title or ""), c.claimId),
        confirmText = getText("IGUI_MSH_Admin_Release"), cancelText = getText("UI_Cancel"),
        onResult = function(ok)
            if not ok then return end
            AP.mutate(P, "adminRelease", { claimId = c.claimId, expectedRevision = c.revision }, function(res)
                if res.ok then
                    AP.say(P, getText("IGUI_MSH_Admin_Released", c.claimId), "text")
                else
                    AP.say(P, AP.codeText(res.code), "errorText")
                end
                AP.pagerInvalidate(P.pager)
                AP.loadClaims(P)
            end)
        end })
end

-- 每 tick：玩家頁才送分頁請求（debounce、一次一筆、送出間隔都在 pagerPump）
function AP.onTick()
    local P = AP.instance
    if not AP.visible(P) or P.current ~= "players" then return end
    local args, key = AP.pagerPump(P.pager, getTimestampMs())
    if args == nil then return end
    local rid = MSH.Client.send("adminPlayers", args, function(res)
        if AP.pagerReply(P.pager, key, res) then AP.layoutPage(P, "players") end
    end)
    if rid == nil then P.pager.inflight = nil end
    AP.layoutPage(P, "players")
end

-- ===== 付費頁 =====

function AP.planLabel(f) return getText("IGUI_MSH_Admin_Plan_" .. f) end

function AP.planField(P, pg, key, value, width, enabled)
    local UI, theme = P.UI, P.theme
    local tf = pg.flow:get("pl:" .. key, function() return UI.TextField.new({ x = 0, y = 0, width = width, theme = theme }) end)
    if tf.width ~= width then tf:setWidth(width) end
    local st = pg.plan
    if st.at[key] ~= pg.version then
        st.at[key] = pg.version
        tf:setText(value ~= nil and tostring(value) or "")
    end
    tf:setEnabled(enabled ~= false)
    tf.mshEnabled = enabled ~= false
    AP.markError(P, tf, pg.errors[key] and AP.errorText(pg.errors[key].field, pg.errors[key].reason) or nil)
    return tf
end

function AP.layoutPaid(P, pg)
    local F, plans = pg.flow, P.plans
    if plans == nil then return F:text("load", getText("IGUI_MSH_Admin_Loading"), "textMuted") end
    if plans.economy ~= "READY" then
        local why = MSH.SlotsWindow.BLOCKERS[plans.economy]
        return F:text("load", why and getText(why) or AP.codeText(plans.economy), "warning")
    end
    local tiers = plans.tiers or {}
    local base = tiers[1] and tiers[1].plan or {}
    pg.plan = pg.plan or { at = {} }
    local st = pg.plan
    if st.version ~= pg.version then
        st.version, st.currency, st.autoRenew = pg.version, base.permanentCurrency, base.autoRenewAllowed == true
    end
    F:text("h:shared", getText("IGUI_MSH_Admin_PlanShared"), "text", UIFont.Medium)
    local lw = 0
    for _, f in ipairs(AP.PLAN_SHARED) do lw = math.max(lw, K.textW(UIFont.Small, AP.planLabel(f))) end
    lw = math.max(lw, K.textW(UIFont.Small, AP.planLabel("currency"))) + K.GAP
    local cl = F:label("pl:currencyL", AP.planLabel("currency"))
    cl:setWidth(lw)
    local row = { cl }
    local E = MSH.SlotsWindow.api()
    for _, cur in ipairs(plans.currencies or {}) do
        local b = F:button("cur:" .. cur, E and E.currencyName and E.currencyName(cur) or cur, P, AP.onCurrency, "chip")
        b.internal = cur
        b:setActive(st.currency == cur)
        row[#row + 1] = b
    end
    F:row(row)
    for _, f in ipairs(AP.PLAN_SHARED) do
        local l = F:label("pl:" .. f .. "L", AP.planLabel(f))
        l:setWidth(lw)
        F:row({ l, AP.planField(P, pg, f, base[f], AP.planFieldW(f, 70)) })
    end
    local auto = F:checkbox("pl:auto", AP.planLabel("autoRenewAllowed"), P, AP.onPlanAuto)
    auto:setChecked(st.autoRenew, true)
    F:row({ auto })
    F.y = F.y + K.GAP
    F:text("h:tiers", getText("IGUI_MSH_Admin_PlanTiers"), "text", UIFont.Medium)
    F:text("planNote", getText("IGUI_MSH_Admin_PlanNote"), "textMuted")
    local k = AP.effective(P.values, "TiersEnabled")
    local tw = K.textW(UIFont.Small, getText("IGUI_MSH_Admin_TierN", 8)) + K.GAP
    for _, t in ipairs(tiers) do
        local on = t.tier <= k
        local tl = F:label("pt" .. t.tier, getText("IGUI_MSH_Admin_TierN", t.tier), on and "text" or "textDisabled")
        tl:setWidth(tw)
        local plan = t.plan or {}
        F:row({ tl,
            F:label("pp" .. t.tier .. "L", AP.planLabel("permanentPrice"), "textMuted"),
            AP.planField(P, pg, "permanentPrice:" .. t.tier, plan.permanentPrice, AP.planFieldW("permanentPrice", 90), on),
            F:label("pr" .. t.tier .. "L", AP.planLabel("rentalPrice"), "textMuted"),
            AP.planField(P, pg, "rentalPrice:" .. t.tier, plan.rentalPrice, AP.planFieldW("rentalPrice", 90), on) })
        if t.provisional then F:text("pv" .. t.tier, getText("IGUI_MSH_Admin_PlanProvisional"), "warning") end
        local te = pg.tierErrors and pg.tierErrors[t.tier]
        if te then F:text("pe" .. t.tier, te, "errorText") end
    end
end

function AP.onCurrency(P, b)
    P.pages.paid.plan.currency = b.internal
    AP.layoutPage(P, "paid")
end

function AP.onPlanAuto(P, checked)
    P.pages.paid.plan.autoRenew = checked
end

-- 讀出付費頁的輸入：shared（改過的共用欄位）、prices[tier]、errors；共用欄位以第一級的方案當顯示值
function AP.gatherPlans(P, pg)
    local tiers = P.plans.tiers or {}
    local base = tiers[1] and tiers[1].plan or {}
    local st, F = pg.plan, pg.flow
    local shared, prices, errs, bad = {}, {}, {}, 0
    for _, f in ipairs(AP.PLAN_SHARED) do
        local v = AP.parseInt(F.pool["pl:" .. f]:getText())
        local e = AP.planFieldError(f, v)
        if e then
            errs[f], bad = { field = f, reason = e }, bad + 1
        elseif v ~= base[f] then
            shared[f] = v
        end
    end
    if st.currency ~= nil then
        if st.currency ~= base.permanentCurrency then shared.permanentCurrency = st.currency end
        if st.currency ~= base.rentalCurrency then shared.rentalCurrency = st.currency end
    end
    if st.autoRenew ~= (base.autoRenewAllowed == true) then shared.autoRenewAllowed = st.autoRenew end
    for _, t in ipairs(tiers) do
        local p = {}
        for _, f in ipairs({ "permanentPrice", "rentalPrice" }) do
            local key = f .. ":" .. t.tier
            local el = F.pool["pl:" .. key]
            if el ~= nil and el.mshEnabled then
                local v = AP.parseInt(el:getText())
                local e = AP.planFieldError(f, v)
                if e then
                    errs[key], bad = { field = f, reason = e }, bad + 1
                else
                    p[f] = v
                end
            end
        end
        prices[t.tier] = p
    end
    return shared, prices, errs, bad
end

function AP.applyPlans(P)
    local pg = P.pages.paid
    if P.plans == nil or P.plans.economy ~= "READY" or pg.plan == nil then return end
    local shared, prices, errs, bad = AP.gatherPlans(P, pg)
    pg.errors, pg.tierErrors = errs, {}
    if bad > 0 then
        AP.layoutPage(P, "paid")
        return AP.say(P, getText("IGUI_MSH_Admin_PlanFix"), "errorText")
    end
    local list = AP.planChanges(P.plans.tiers, shared, prices)
    if #list == 0 then return AP.say(P, getText("IGUI_MSH_Admin_NoChanges"), "textMuted") end
    AP.sendPlans(P, list, 1, 0)
end

-- 逐級依序送（一次一筆 mutation）；某級失敗不影響其他級，最後重讀方案
function AP.sendPlans(P, list, i, okCount)
    local item = list[i]
    local pg = P.pages.paid
    if item == nil then
        local failed = #list - okCount
        AP.say(P, getText(failed == 0 and "IGUI_MSH_Admin_PlanSaved" or "IGUI_MSH_Admin_PlanPartial", okCount, failed),
            failed == 0 and "text" or "errorText")
        local keep = pg.tierErrors
        MSH.Client.send("adminPlans", {}, function(res)
            P.plans = res.ok and res or { economy = res.code }
            AP.resync(P, "paid")
            pg.tierErrors = keep
            AP.layoutPage(P, "paid")
        end)
        return
    end
    local sent = AP.mutate(P, "adminSetPlan", { tier = item.tier, values = item.values, expectedRevision = item.expectedRevision },
        function(res)
            if res.ok then
                okCount = okCount + 1
            else
                local where = res.field and getText("IGUI_MSH_Admin_PlanField", AP.planLabel(res.field)) or ""
                pg.tierErrors[item.tier] = getText("IGUI_MSH_Admin_PlanTierError", item.tier, AP.codeText(res.code), where)
            end
            AP.sendPlans(P, list, i + 1, okCount)
        end)
    if not sent then return end
end

if first then
    Events.OnTick.Add(function() MSH.AdminPanel.onTick() end)
end
