-- 管理員面板與名額視窗的純邏輯（AdminPanel.lua、SlotsWindow.lua）：只送有改動的鍵、逐欄錯誤、玩家分頁的
-- debounce／一次一筆／送出間隔／過期回覆、付費頁只送有改動的等級、報價金額一致才付款、查單只認同一筆。
-- 最小假框架＋原版 ISUIElement／ISPanel／ISButton：只有 AdminPanel、SlotsWindow 用到的方法；元件記住狀態給斷言讀
local function fakeUI()
    local function class(base)
        local c = {}
        c.__index = c
        if base then setmetatable(c, { __index = base }) end
        function c:derive() return class(self) end
        return c
    end
    local Base = class()
    function Base:new(x, y, w, h)
        return setmetatable({ x = x or 0, y = y or 0, width = w or 60, height = h or 20, visible = true, kids = {} }, self)
    end
    function Base:initialise() end
    function Base:addChild(k) self.kids[#self.kids + 1] = k; k.parent = self end
    function Base:setVisible(v) self.visible = v end
    function Base:isVisible() return self.visible end
    function Base:setX(v) self.x = v end
    function Base:setY(v) self.y = v end
    function Base:getX() return self.x end
    function Base:getY() return self.y end
    function Base:setWidth(v) self.width = v end
    function Base:setHeight(v) self.height = v end
    function Base:getWidth() return self.width end
    function Base:getHeight() return self.height end
    function Base:addToUIManager() self.added = true end
    function Base:removeFromUIManager() self.added = false end
    function Base:bringToTop() end
    function Base:drawText() end
    function Base:setEnabled(v) self.enabled = v ~= false end
    function Base:setTooltip(t) self.tooltip = t end
    ISUIElement, ISPanel = Base, class(Base)
    ISButton = class(Base)
    function ISButton:new(x, y, w, h, title, target, onclick)
        local b = Base.new(self, x, y, w, h)
        b.title, b.target, b.onclick = title, target, onclick
        return b
    end
    UIFont = { Small = "Small", Medium = "Medium" }
    -- 量測模型：每字 fw.charW 像素（預設 7；放大字型的情境把它改成 14），字高 fw.charW × 16 / 7
    local fw = { charW = 7 }
    getTextManager = function()
        return { MeasureStringX = function(_, _, s) return #tostring(s) * fw.charW end,
            getFontHeight = function() return math.floor(fw.charW * 16 / 7) end }
    end
    getCore = function() return { getScreenWidth = function() return 1280 end, getScreenHeight = function() return 720 end } end
    local function make(cls, opts, h)
        local e = cls:new(opts.x, opts.y, opts.width or 60, opts.height or h or 20)
        for k, v in pairs(opts) do if e[k] == nil then e[k] = v end end
        e.enabled = true
        return e
    end
    local Button = class(Base)
    function Button:setTitle(t) self.title = t end
    function Button:fitWidth() self.width = #tostring(self.title) * 7 + 20 end
    function Button:setActive(v) self.active = v end
    function Button:isEnabled() return self.enabled end
    local Field = class(Base)
    function Field:getText() return self.text or "" end
    function Field:setText(t) self.text = t end
    function Field:setInvalid(v, m) self.invalid, self.invalidMessage = v, m end
    local Check = class(Base)
    function Check:getChecked() return self.checked == true end
    function Check:setLabel(l) self.label = l end
    function Check:setChecked(v, silent)
        v = v == true
        if v == (self.checked == true) then return end
        self.checked = v
        if not silent and self.onChange then self.onChange(self.target, v, self) end
    end
    local Tabs = class(Base)
    function Tabs:setSelected(id) self.selected = id end
    local Win = class(Base)
    function Win:contentTop() return 24 end
    local Scroll = class(Base)
    function Scroll:contentWidth() return self.width - 12 end
    local colors = {}
    for _, t in ipairs({ "text", "textMuted", "textDisabled", "warning", "errorText" }) do colors[t] = { r = 1, g = 1, b = 1, a = 1 } end
    local caps = {}
    for _, c in ipairs({ "window", "controls", "dialog", "scrollPanel", "textWrap", "textFieldInvalid" }) do caps[c] = true end
    MinidoracatUI = { v1 = { API_MAJOR = 1, API_REVISION = 17, CAPABILITIES = caps,
        Theme = { defaultPalette = function() return {} end, create = function() return { colors = colors } end },
        Text = { fit = function(s) return s end, wrap = function(s) return { s } end },
        Window = { new = function(o) return make(Win, o) end },
        ScrollPanel = { new = function(o) return make(Scroll, o) end },
        Tabs = { new = function(o) return make(Tabs, o, 24) end },
        Button = { new = function(o) return make(Button, o, 26) end },
        TextField = { new = function(o) return make(Field, o, 22) end },
        Checkbox = { new = function(o) return make(Check, o, 20) end },
        Dialog = { show = function(o) fw.dialog = o return o end },
    } }
    function fw.click(b)
        if b.enabled ~= false and b.onClick then b.onClick(b.target, b) end
    end
    return fw
end

return function(T)
    local check = T.check
    local MSH = T.bootClient()
    local AP, SW = MSH.AdminPanel, MSH.SlotsWindow
    check(AP ~= nil and SW ~= nil and type(AP.open) == "function" and type(SW.open) == "function",
        "AdminPanel、SlotsWindow 在客戶端載入（載入時不碰 UI）")
    T.player({ name = "boss", admin = true })

    T.section("AdminPanel：只送有改動的鍵")
    local changes, n = AP.changedKeys({ ClaimGap = 2, MaxShares = 5, AllowFactionShare = true, RoadKinds = "main;street" },
        { ClaimGap = 2, MaxShares = 8, AllowFactionShare = true, RoadKinds = "main;street" })
    check(n == 1 and changes.MaxShares == 5 and changes.ClaimGap == nil, "沒改的鍵不送")
    local def = MSH.Settings.DEFAULT_ROAD_KINDS
    local order = MSH.Settings.ROAD_KINDS
    check(AP.listText(AP.listSet("", def), order) == AP.listText(AP.listSet("street;main", def), order),
        "清單選項：空字串（預設）與同一組項目的規範字串相同，不算改動")
    check(AP.listText({ main = true, foo = true }, order, { "foo" }) == "main;foo", "清單裡面板沒有 chip 的項目原樣保留")
    check(AP.effective({ ClaimGap = "x" }, "ClaimGap") == 2 and AP.effective(nil, "AllowFactionShare") == true,
        "伺服器值缺或型別不符時顯示預設")

    T.section("AdminPanel：逐欄錯誤")
    local errs, bad = AP.localErrors({ ClaimGap = 17, MaxShares = "abc", RedrawMinutes = 10 }, {})
    check(bad == 2 and errs.ClaimGap == "OUT_OF_RANGE" and errs.MaxShares == "OUT_OF_RANGE" and errs.RedrawMinutes == nil,
        "超出範圍、不是數字：標在各自欄位，合法的不標")
    errs, bad = AP.localErrors({ Tier1Area = 800 }, { Tier1Side = 30 })
    check(bad == 0, "跨欄位用面板讀到的伺服器值（邊長 30，面積 800 合法；客戶端 SandboxVars 是預設 24）")
    errs, bad = AP.localErrors({ Tier1Area = 901 }, { Tier1Side = 30 })
    check(bad == 1 and errs.Tier1Area == "AREA_OVER_SIDE", "面積超過邊長²：標在面積欄")
    errs, bad = AP.localErrors({ Tier2Side = 10 }, {})
    check(bad == 1 and errs.Tier2Area == "AREA_OVER_SIDE", "縮小邊長造成面積超過：標在該級面積欄")
    local se = AP.serverErrors({ ok = false, code = "BAD_OPTION", key = "ClaimGap", reason = "OUT_OF_RANGE" })
    check(se ~= nil and se.ClaimGap == "OUT_OF_RANGE", "伺服器 BAD_OPTION { key, reason } 對回欄位")
    check(AP.serverErrors({ ok = false, code = "SAVE_FAILED" }) == nil, "不是欄位錯誤就不標欄位")

    T.section("AdminPanel：這一級沒人建得了")
    check(not AP.nobodyCanBuild(true, false, false, false), "免費開著：建得了")
    check(AP.nobodyCanBuild(false, false, false, true), "三個都關：警告")
    check(AP.nobodyCanBuild(false, true, true, false), "只開買斷／租用而 Economy 不可用：警告")
    check(not AP.nobodyCanBuild(false, false, true, true), "只開租用且 Economy 可用：建得了")

    T.section("AdminPanel：玩家分頁")
    local p = AP.pager()
    local args, key = AP.pagerPump(p, 0)
    check(args ~= nil and args.filter == "all" and args.page == 1 and args.query == nil, "開頁先抓全部玩家第 1 頁")
    check(AP.pagerPump(p, 100) == nil, "一筆在路上：不再送")
    AP.pagerType(p, "  Bo", 200)
    check(AP.pagerReply(p, key, { ok = true, rows = { { name = "x" } }, page = 1, pages = 3, total = 120 }) == true
        and p.shown == AP.pagerKey(p), "回覆對得上目前條件：採用")
    check(AP.pagerPump(p, 700) == nil, "輸入還沒停 650 ms：不送")
    args, key = AP.pagerPump(p, 860)
    check(args ~= nil and args.query == "Bo" and args.page == 1, "停 650 ms 後送出（去頭尾空白）")
    AP.pagerSet(p, "filter", "owners")
    check(AP.pagerReply(p, key, { ok = true, rows = { { name = "Bob" } }, page = 1, pages = 1, total = 1 }) == false
        and p.rows[1].name == "x", "送出後改了篩選：過期回覆丟掉、不蓋畫面")
    check(AP.pagerPump(p, 1000) == nil, "離上次送出不到 650 ms：不送（伺服器 500 ms 內重送會丟）")
    args, key = AP.pagerPump(p, 1520)
    check(args ~= nil and args.filter == "owners" and args.query == "Bo", "間隔到了送新條件")
    AP.pagerSet(p, "page", 9)
    check(AP.pagerReply(p, key, { ok = true, rows = {}, page = 1, pages = 1, total = 0 }) == false, "改了頁碼：舊頁回覆丟掉")
    args, key = AP.pagerPump(p, 2200)
    AP.pagerReply(p, key, { ok = true, rows = { { name = "Bob" } }, page = 2, pages = 2, total = 51 })
    check(p.page == 2 and p.shown == AP.pagerKey(p) and AP.pagerPump(p, 3000) == nil,
        "頁碼超過最後一頁：採用伺服器夾過的頁碼，不再重抓")
    AP.pagerSet(p, "page", 1)
    args, key = AP.pagerPump(p, 3000)
    AP.pagerReply(p, key, { ok = false, code = "NO_REPLY" })
    check(p.error == "NO_REPLY" and AP.pagerPump(p, 9000) == nil, "失敗：顯示原因、不自動重送")
    AP.pagerInvalidate(p)
    check(AP.pagerPump(p, 9000) ~= nil, "重新整理（invalidate）後重抓")
    AP.pagerType(p, "x\1" .. string.rep("a", 40), 9100)
    args = AP.pagerPump(p, 20000)
    check(args == nil and #p.query == MSH.LIMIT.USERNAME_CHARS and not string.find(p.query, "%c"),
        "關鍵字去控制字元並截到伺服器上限")

    T.section("AdminPanel：玩家頁送出（Client.send、requestId 配對）")
    local sentBefore = #T.clientSent
    local laid = 0
    local realLayout = AP.layoutPage
    AP.layoutPage = function() laid = laid + 1 end
    AP.instance = { win = { isVisible = function() return true end }, current = "players", pager = AP.pager() }
    AP.onTick()
    local sent = T.clientSent[#T.clientSent]
    check(#T.clientSent == sentBefore + 1 and sent.command == "adminPlayers" and sent.args.filter == "all"
        and MSH.validRequestId(sent.args.requestId), "玩家頁開著：送 adminPlayers（帶 requestId）")
    AP.onTick()
    check(#T.clientSent == sentBefore + 1, "回覆前不再送")
    T.fire("OnServerCommand", MSH.MODULE, "result", { command = "adminPlayers", requestId = sent.args.requestId, ok = true,
        code = "OK", rows = { { name = "alice", used = 1, free = 1, override = -1, claims = {} } }, page = 1, pages = 1, total = 1 })
    check(AP.instance.pager.rows[1].name == "alice" and laid >= 2, "回覆採用並重排")
    AP.instance.current = "rules"
    AP.pagerInvalidate(AP.instance.pager)
    T.advance(1000)
    AP.onTick()
    check(#T.clientSent == sentBefore + 1, "不在玩家頁：不送")
    AP.layoutPage, AP.instance = realLayout, nil

    T.section("AdminPanel：付費頁只送有改動的等級")
    local plan = { permanentEnabled = false, permanentCurrency = "survivor", permanentPrice = 1200, permanentLimit = 10,
        rentalEnabled = true, rentalCurrency = "survivor", rentalPrice = 100, rentalLimit = 10, rentalDays = 30,
        graceHours = 24, reminderHours = 24, autoRenewAllowed = true }
    local function copy(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end
    local tiers = { { tier = 1, plan = copy(plan), revision = 4 }, { tier = 2, plan = copy(plan), revision = 9 } }
    local list = AP.planChanges(tiers, {}, { [1] = { permanentPrice = 1200, rentalPrice = 100 }, [2] = { rentalPrice = 300 } })
    local fields = 0
    for _ in pairs(list[1] and list[1].values or {}) do fields = fields + 1 end
    check(#list == 1 and list[1].tier == 2 and list[1].expectedRevision == 9 and list[1].values.rentalPrice == 300
        and list[1].values.permanentPrice == 1200 and fields == 12, "只送改了的那一級：完整 12 欄、帶該級 revision")
    list = AP.planChanges(tiers, { rentalDays = 7 }, {})
    check(#list == 2 and list[1].values.rentalDays == 7 and list[2].expectedRevision == 9, "共用欄位改了：每級各送一次")
    check(AP.planFieldError("rentalPrice", 0) == "OUT_OF_RANGE" and AP.planFieldError("rentalPrice", nil) == "OUT_OF_RANGE"
        and AP.planFieldError("graceHours", 0) == nil, "價格最小 1、空白不合法")

    T.section("SlotsWindow：付款流程的判斷")
    check(SW.quoteMatches({ amount = 700, currency = "survivor" }, { amount = 700, currency = "survivor" }),
        "報價與確認頁一致：付款")
    check(not SW.quoteMatches({ amount = 800, currency = "survivor" }, { amount = 700, currency = "survivor" })
        and not SW.quoteMatches({ amount = 700, currency = "gold" }, { amount = 700, currency = "survivor" }),
        "金額或幣別不同：不付款")
    check(SW.purchaseKey({ ok = false, unknown = true, error = "timeout" }) == "IGUI_MSH_Slots_NoAnswer"
        and SW.purchaseKey({ ok = false, error = "insufficient_funds" }) == nil
        and SW.purchaseKey({ ok = true }) == "IGUI_MSH_Slots_PaidDone", "付款逾時＝結果未知（保留付款鎖）；拒絕＝顯示原因")
    local E = { orderOutcome = function(r) return r.outcome end }
    check(SW.orderKey({ ok = true, known = true, order = { orderId = "B" }, outcome = "paid" }, { orderId = "A" }, E) == nil,
        "查回別筆訂單：不解除付款鎖")
    check(SW.orderKey({ ok = true, known = false, order = { orderId = "A" }, outcome = "paid" }, { orderId = "A" }, E) == nil,
        "同一筆但還不知道：不解除")
    check(SW.orderKey({ ok = true, known = true, order = { orderId = "A" }, outcome = "not_paid" }, { orderId = "A" }, E)
        == "IGUI_MSH_Slots_NoOrder", "同一筆、最終沒付款：解除並說明")
    check(SW.blocker(nil, true) == "IGUI_MSH_Slots_Loading" and SW.blocker({ economy = "ABSENT" }, true) == "IGUI_MSH_Slots_Absent"
        and SW.blocker({ economy = "READY" }, false) == "IGUI_MSH_Slots_NoClient" and SW.blocker({ economy = "READY" }, true) == nil,
        "Economy 不可用只給原因（沒有付款鈕）")
    check(SW.autoRenewOn({ autoRenew = true, autoRenewState = "pending_off" }) == false
        and SW.autoRenewOn({ autoRenewState = "pending_on" }) == true, "自動續租：已送出取消算關、送出開啟算開")

    T.section("AdminPanel／SlotsWindow：假框架下整個流程跑得動")
    local G = { "ISUIElement", "ISPanel", "ISButton", "getTextManager", "UIFont", "getCore", "getPlayer", "getScriptManager",
        "ISCraftRecipeTooltip", "ISWidgetTitleHeader", "MinidoracatUI", "MinidoracatEconomy" }
    local saved = {}
    for _, k in ipairs(G) do saved[k] = _G[k] end
    local fw = fakeUI()
    local boss = T.online[1]
    getPlayer = function() return boss end
    local tips = {}
    getScriptManager = function() return { getCraftRecipe = function(_, name) return { name = name } end } end
    ISWidgetTitleHeader = {}
    ISCraftRecipeTooltip = {
        activateToolTipFor = function(parent, player, r) parent.__toolTip = { recipe = r }; tips[#tips + 1] = r.name end,
        deactivateToolTipFor = function(parent) parent.__toolTip = nil end,
    }
    local function lastCmd(command)
        for i = #T.clientSent, 1, -1 do
            if T.clientSent[i].command == command then return T.clientSent[i] end
        end
        return nil
    end
    local function answer(command, fields)
        local s = lastCmd(command)
        local r = { command = command, requestId = s.args.requestId, ok = true, code = "OK" }
        for k, v in pairs(fields or {}) do r[k] = v end
        T.fire("OnServerCommand", MSH.MODULE, "result", r)
        return s
    end
    local values = {}
    for _, o in ipairs(MSH.Settings.OPTIONS) do values[o.key] = o.default end
    local P = AP.open({ tab = "deeds" })
    check(P ~= nil and lastCmd("adminOptions") and lastCmd("adminPlans") and lastCmd("adminClaims") and lastCmd("adminMigration"),
        "開面板：抓選項、付費方案、待處理紀錄、遷移狀態")
    answer("adminOptions", { values = values, health = { blocked = true, blockers = { "PlayerSafehouse" }, warnings = {} },
        settingsWarnings = {}, resourceApi = true, parkingApi = false })
    local planRow = function(tier, rev)
        return { tier = tier, revision = rev, plan = { permanentEnabled = false, permanentCurrency = "survivor",
            permanentPrice = 1200, permanentLimit = 10, rentalEnabled = false, rentalCurrency = "survivor", rentalPrice = 100,
            rentalLimit = 10, rentalDays = 30, graceHours = 24, reminderHours = 24, autoRenewAllowed = true } }
    end
    answer("adminPlans", { economy = "READY", currencies = { "survivor" }, tiers = { planRow(1, 3), planRow(2, 7) } })
    answer("adminClaims", { claims = { { claimId = 9, lifecycle = "quarantined", quarantineReason = "MISSING", owner = "eve" } } })
    answer("adminMigration", { migration = { status = "verifying", completed = false, missing = 1, files = {} } })
    local deeds = P.pages.deeds.flow.pool
    check(deeds["f:Tier1Side"] ~= nil and deeds["f:Tier8Rent"] ~= nil and deeds["warn2#1"] == nil, "地契頁 8 級全部排出、沒有警告")
    check(deeds["f:Tier4Side"].enabled == false and deeds["f:Tier3Side"].enabled ~= false, "未啟用的等級灰階（不能改）")

    deeds["f:Tier1Side"]:setText("30")
    local free2 = deeds["f:Tier2Free"]
    free2:setChecked(false)
    check(deeds["warn2#1"] ~= nil and deeds["warn2#1"]:isVisible(), "2 級免費、買斷、租用都關：該列警告")
    local craft = deeds["f:Tier1Craft"]
    craft:onMouseMove(0, 0)
    check(tips[#tips] == "CraftMinidoracatSafehouseDeed1Standard", "滑鼠移到製作格：預覽選中難度的配方")
    fw.click(craft)
    check(tips[#tips] == "CraftMinidoracatSafehouseDeed1Strict", "換難度後預覽跟著換")
    craft:onMouseMoveOutside(0, 0)
    check(craft.__toolTip == nil, "滑鼠離開收掉提示框")
    local apply = P.barFlow.pool.apply
    fw.click(apply)
    local sent = lastCmd("adminSetOptions")
    local keys = {}
    for k in pairs(sent and sent.args.changes or {}) do keys[#keys + 1] = k end
    check(sent ~= nil and #keys == 3 and sent.args.changes.Tier1Side == 30 and sent.args.changes.Tier2Free == false
        and sent.args.changes.Tier1Craft == 4, "套用：只送地契頁改過的三個鍵（實際 " .. table.concat(keys, ",") .. "）")
    answer("adminSetOptions", { ok = false, code = "BAD_OPTION", key = "Tier1Side", reason = "OUT_OF_RANGE" })
    check(deeds["f:Tier1Side"].invalid == true and P.busy == nil, "伺服器回欄位錯誤：標在那一欄")
    deeds["f:Tier1Side"]:setText("abc")
    local before = #T.clientSent
    fw.click(apply)
    check(#T.clientSent == before and deeds["f:Tier1Side"].invalid == true, "本機檢查不過：不送出")

    AP.select(P, "paid")
    local paid = P.pages.paid.flow.pool
    paid["pl:rentalPrice:2"]:setText("300")
    fw.click(apply)
    sent = lastCmd("adminSetPlan")
    check(sent ~= nil and sent.args.tier == 2 and sent.args.expectedRevision == 7 and sent.args.values.rentalPrice == 300,
        "付費頁：只送改了的 2 級，帶 2 級的 revision")
    answer("adminSetPlan", { ok = false, code = "STALE_REVISION" })
    check(lastCmd("adminPlans") ~= nil and P.pages.paid.tierErrors[2] ~= nil, "逐級回錯，結束後重讀方案")

    AP.select(P, "players")
    T.advance(1000)
    AP.onTick()
    answer("adminPlayers", { rows = { { name = "eve", used = 1, free = 1, override = -1,
        claims = { { claimId = 4, title = "home", revision = 6, lifecycle = "active", tier = 2 } } } }, page = 1, pages = 1, total = 1 })
    local pp = P.pages.players.flow.pool
    fw.click(pp.pv1)
    check(pp["pc1:1r"] ~= nil and pp["pc1:1r"]:isVisible(), "〔查看〕列出該玩家的安全屋")
    fw.click(pp["pc1:1r"])
    check(fw.dialog ~= nil and fw.dialog.danger == true, "代為放棄先開 danger 對話框")
    fw.dialog.onResult(true)
    sent = lastCmd("adminRelease")
    check(sent ~= nil and sent.args.claimId == 4 and sent.args.expectedRevision == 6, "確認後送 adminRelease（帶 revision）")
    answer("adminRelease", { claimId = 4 })
    fw.click(pp.po1)
    fw.dialog.onResult(true, "3")
    sent = lastCmd("adminSetOverride")
    check(sent ~= nil and sent.args.targetUsername == "eve" and sent.args.n == 3, "改個人上限送 adminSetOverride")
    answer("adminSetOverride", {})

    -- 名額視窗：假 Economy 客戶端
    local calls = {}
    local env = { plan = { rentalEnabled = true, autoRenewAllowed = true, rentalPrice = 100, rentalCurrency = "survivor",
        rentalDays = 30, revision = 5 }, entitlement = { revision = 2, rentals = { { id = "L1", quantity = 1, state = "active",
        paidUntil = T.now + 86400000, autoRenew = false } } } }
    local function rec(name) return function(...) calls[#calls + 1] = { name = name, args = { ... } } return "rid" end end
    local E = { requestState = rec("requestState"), quote = rec("quote"), purchase = rec("purchase"), getOrder = rec("getOrder"),
        setAutoRenew = rec("setAutoRenew"), onChanged = function() end, getState = function() return env end,
        errorText = function(c) return c end, currencyName = function(c) return c end, remainingText = function() return "1d" end,
        stateText = function(s) return s end, orderOutcome = function(r) return r.order and r.order.status end }
    MinidoracatEconomy = { v1 = { Client = { API_MAJOR = 1, API_REVISION = 4, CAPABILITIES = { entitlements = true, rentals = true },
        Entitlements = E } } }
    local function lastCall(name)
        for i = #calls, 1, -1 do if calls[i].name == name then return calls[i].args end end
        return nil
    end
    local w = SW.open({ tier = 2 })
    local slotsData = { economy = "READY", free = { n = 1, used = 1, titles = { "home" } }, tiers = {
        { tier = 1, enabled = true, free = true, buy = false, rent = false, usable = 0, paid = 0 },
        { tier = 2, enabled = true, free = false, buy = true, rent = true, usable = 1, paid = 1,
            buyPrice = { amount = 3600, currency = "survivor" }, rentPrice = { amount = 300, currency = "survivor", days = 30 } } } }
    local function countCmd(command)
        local c = 0
        for _, s in ipairs(T.clientSent) do if s.command == command then c = c + 1 end end
        return c
    end
    answer("slots", slotsData)
    local sp = w.flow.pool
    check(sp.buy1 == nil and sp.buy2 ~= nil and sp.rent2 ~= nil, "販售關閉的等級不顯示買斷／租用鈕")
    check(lastCall("requestState") ~= nil and lastCall("requestState")[2] == "tier2", "只對預選（展開）的那一級讀 Economy 狀態")
    fw.click(sp.buy2)
    fw.dialog.onResult(true)
    local q = lastCall("quote")
    check(q ~= nil and q[2] == "tier2" and q[3] == "permanent" and q[4] == 1, "確認後先報價")
    local nSlots = countCmd("slots")
    q[5]({ ok = true, quote = { id = "Q1", orderId = "O1", amount = 4000, currency = "survivor" } })
    check(lastCall("purchase") == nil and countCmd("slots") == nSlots + 1, "報價金額和確認頁不同：不付款、重抓摘要")
    answer("slots", slotsData)
    fw.click(sp.buy2)
    fw.dialog.onResult(true)
    lastCall("quote")[5]({ ok = true, quote = { id = "Q2", orderId = "O2", amount = 3600, currency = "survivor" } })
    local pc = lastCall("purchase")
    check(pc ~= nil and pc[2] == "Q2", "金額一致：用同一張報價付款")
    pc[3]({ ok = false, unknown = true, error = "timeout" })
    check(w.order ~= nil and sp.check ~= nil and sp.check:isVisible() and sp.buy2.enabled == false,
        "付款逾時：保留付款鎖、只給〔查詢購買結果〕")
    fw.click(sp.check)
    local go = lastCall("getOrder")
    check(go ~= nil and go[3] == "O2" and lastCall("purchase") == pc, "查詢只讀同一筆訂單，不重送付款")
    nSlots = countCmd("slots")
    go[4]({ ok = true, known = true, order = { orderId = "O2", status = "paid" } })
    check(w.order == nil and countCmd("slots") == nSlots + 1, "查回最終結果才解除，並重抓摘要")
    answer("slots", slotsData)
    local box = sp["l2:1a"]
    box:setChecked(true)
    check(box:getChecked() == false and fw.dialog ~= nil, "開自動續租：勾選先還原、確認同意條款後才送")
    fw.dialog.onResult(true)
    local ar = lastCall("setAutoRenew")
    check(ar ~= nil and ar[3] == true and ar[4] == 2 and ar[5] == 5 and ar[7] == "L1", "送出該張租約的自動續租（帶版本與條款版本）")

    T.section("SlotsWindow：Economy 通知不造成無限重抓")
    -- 假 Economy 照 adopt() 的行為：每個 requestState 回覆先通知 onChanged（版本相同也通知），再呼叫回呼
    local listeners, waiting, stateReqs = {}, {}, 0
    local env3 = { sourceMod = SW.SRC, productId = "tier2", plan = env.plan,
        entitlement = { revision = 2, usable = 1, rentals = env.entitlement.rentals } }
    local function notify(e) for _, fn in ipairs(listeners) do fn(e) end end
    local E3 = {}
    for k, v in pairs(E) do E3[k] = v end
    E3.onChanged = function(fn) listeners[#listeners + 1] = fn end
    E3.getState = function() return env3 end
    E3.requestState = function(src, product, cb)
        stateReqs = stateReqs + 1
        waiting[#waiting + 1] = cb
        return "rid"
    end
    local function respond()
        local list = waiting
        waiting = {}
        for _, cb in ipairs(list) do
            notify(env3)
            if cb then cb({ ok = true }) end
        end
    end
    local function answerSlots()
        local s = lastCmd("slots")
        if s and MSH.Client.isPending(s.args.requestId) then answer("slots", slotsData) end
    end
    local function rounds(n)
        for _ = 1, n do
            answerSlots()
            respond()
            T.advance(1000)
        end
    end
    MinidoracatEconomy.v1.Client.Entitlements = E3
    SW.instance = nil
    local base = countCmd("slots")
    local w3 = SW.open({ tier = 2 })
    rounds(2)
    local settled = countCmd("slots")
    rounds(8)
    check(settled - base == 1 and countCmd("slots") == settled and #waiting == 0,
        "展開一級：自己的 requestState 回覆不觸發重抓，slots 只送開窗那一次（實際 " .. (countCmd("slots") - base) .. " 次）")
    local reads = stateReqs
    notify(env3)
    rounds(3)
    check(countCmd("slots") == settled and stateReqs == reads, "推送的狀態沒變（同版本、較新的請求）：不重抓")
    env3 = { sourceMod = SW.SRC, productId = "tier2", plan = env.plan,
        entitlement = { revision = 3, usable = 2, rentals = env.entitlement.rentals } }
    notify(env3)
    check(countCmd("slots") == settled + 1, "權益版本變了：重抓一次摘要")
    rounds(6)
    check(countCmd("slots") == settled + 1 and SW.visible(w3), "重抓後又穩定下來")

    T.section("AdminPanel：譯文變長時欄寬、按鈕寬與面板寬跟著量測")
    -- 量測模型：fakeUI 的 MeasureStringX＝字數 × 7。放法文／俄文長度等級的譯文，placeholder 比原本固定欄寬 52 長
    local realGetText = getText
    local long = {
        IGUI_MSH_Admin_Unlimited = "Sans limite du tout", IGUI_MSH_Admin_Col_Tier = "Niveau", IGUI_MSH_Admin_Col_Side = "Cote",
        IGUI_MSH_Admin_Col_Area = "Surface", IGUI_MSH_Admin_Col_PerPlayer = "Par joueur", IGUI_MSH_Admin_Col_Loot = "Chance de butin",
        IGUI_MSH_Admin_Col_Craft = "Fabrication", IGUI_MSH_Admin_Col_Free = "Gratuit", IGUI_MSH_Admin_Col_Buy = "Achat",
        IGUI_MSH_Admin_Col_Rent = "Location", IGUI_MSH_Admin_TierN = "Niveau %1",
        Sandbox_MinidoracatSafehouse_CraftLevel_option1 = "Desactivee", Sandbox_MinidoracatSafehouse_CraftLevel_option2 = "Facile",
        Sandbox_MinidoracatSafehouse_CraftLevel_option3 = "Standard", Sandbox_MinidoracatSafehouse_CraftLevel_option4 = "Stricte",
        IGUI_MSH_Admin_SetLimit = "Limite gratuite par joueur...",
    }
    getText = function(key, a)
        local v = long[key]
        if v == nil then return key end
        return (string.gsub(v, "%%1", tostring(a)))
    end
    local tm = getTextManager()
    local function measure(s) return tm:MeasureStringX(UIFont.Small, s) end
    AP.instance = nil
    local PL = AP.open({ tab = "deeds" })
    answer("adminOptions", { values = values, health = {}, settingsWarnings = {}, resourceApi = false, parkingApi = false })
    local dp = PL.pages.deeds
    local pf = dp.flow.pool["f:Tier1PerPlayer"]
    local xs, right = AP.deedColumns()
    check(pf.width >= measure(long.IGUI_MSH_Admin_Unlimited) + 16 and xs.Loot >= pf.x + pf.width,
        "每人上限輸入框寬 ≥ 量到的「不限」＋內距，且不壓到下一欄（輸入框 " .. pf.width .. "）")
    check(right > AP.PANEL_W - 10 - AP.SCROLL_GUTTER and right + 10 <= dp.sp:contentWidth() and PL.win.width <= 1260,
        "表格比預設寬還寬時面板跟著變寬，表格右緣不超出面板（右緣 " .. right .. "、面板 " .. PL.win.width .. "）")
    local rentBox = dp.flow.pool["f:Tier1Rent"]
    check(rentBox.x + rentBox.width <= dp.sp:contentWidth(), "最右一欄的開關也在面板內")
    AP.select(PL, "players")
    T.advance(1000)
    AP.onTick()
    answer("adminPlayers", { rows = { { name = "eve", used = 0, free = 1, override = -1, claims = {} } }, page = 1, pages = 1, total = 1 })
    local lim = PL.pages.players.flow.pool.po1
    check(lim.width >= measure(long.IGUI_MSH_Admin_SetLimit) and lim.x + lim.width <= PL.pages.players.sp:contentWidth(),
        "玩家列〔免費上限…〕依標籤量寬、不截字（按鈕 " .. lim.width .. "）")
    getText = realGetText
    AP.instance = nil

    T.section("AdminPanel：放大字型時數字框寬依最寬合法值量測")
    -- 繁中 200% 字型：每字寬加倍；標籤用短字（中文標籤短），數字欄的寬度由值決定
    local short = { IGUI_MSH_Admin_Unlimited = "No lim", IGUI_MSH_Admin_TierN = "Lv %1",
        Sandbox_MinidoracatSafehouse_CraftLevel_option1 = "Off", Sandbox_MinidoracatSafehouse_CraftLevel_option2 = "Easy",
        Sandbox_MinidoracatSafehouse_CraftLevel_option3 = "Std", Sandbox_MinidoracatSafehouse_CraftLevel_option4 = "Hard" }
    getText = function(key, a)
        local v = short[key] or (string.find(key, "^IGUI_MSH_Admin_Col_") and "Ab") or nil
        if v == nil then return key end
        return (string.gsub(v, "%%1", tostring(a)))
    end
    fw.charW = 14
    local PB = AP.open({ tab = "deeds" })
    answer("adminOptions", { values = values, health = {}, settingsWarnings = {}, resourceApi = false, parkingApi = false })
    answer("adminPlans", { economy = "READY", currencies = { "survivor" }, tiers = { planRow(1, 3), planRow(2, 7) } })
    local PAD_IN = 16   -- TextField 兩側內距（FIELD_PAD 6＋TEXTBOX_INSET 2，各兩側）
    local function fits(el, widest) return el ~= nil and el.width >= measure(widest) + PAD_IN end
    local deedPool = PB.pages.deeds.flow.pool
    local narrow = {}
    for _, s in ipairs({ { "Tier1Side", "96" }, { "Tier1Area", "9216" }, { "Tier1Area", "9999" }, { "Tier8Area", "9999" },
        { "Tier1PerPlayer", "100" }, { "Tier1LootChance", "100.00" }, { "TiersEnabled", "8" } }) do
        if not fits(deedPool["f:" .. s[1]], s[2]) then narrow[#narrow + 1] = s[1] .. "=" .. tostring(deedPool["f:" .. s[1]] and deedPool["f:" .. s[1]].width) end
    end
    check(#narrow == 0, "地契頁每個數字框寬 ≥ 量到的最寬合法值＋內距（太窄：" .. table.concat(narrow, ",") .. "）")
    local xs2, right2 = AP.deedColumns()
    local area1 = deedPool["f:Tier1Area"]
    check(xs2.PerPlayer >= area1.x + area1.width and right2 + 10 <= PB.pages.deeds.sp:contentWidth()
        and deedPool["f:Tier1Rent"].x + deedPool["f:Tier1Rent"].width <= PB.pages.deeds.sp:contentWidth(),
        "欄寬跟著重算、表格右緣在面板內（右緣 " .. right2 .. "、面板 " .. PB.win.width .. "）")
    narrow = {}
    local rulesPool = PB.pages.rules.flow.pool
    for _, key in ipairs(AP.RULE_KEYS) do
        local o = MSH.Settings.BY_KEY[key]
        if o.type == "int" and not fits(rulesPool["f:" .. key], tostring(o.max)) then narrow[#narrow + 1] = key end
    end
    if not fits(PB.pages.exclusions.flow.pool["f:RoadMargin"], "8") then narrow[#narrow + 1] = "RoadMargin" end
    check(#narrow == 0, "規則頁、排除頁的數字框放得下上限值（太窄：" .. table.concat(narrow, ",") .. "）")
    narrow = {}
    local paidPool = PB.pages.paid.flow.pool
    for _, k in ipairs({ "permanentPrice:1", "rentalPrice:2" }) do
        if not fits(paidPool["pl:" .. k], "1000000000") then narrow[#narrow + 1] = k end
    end
    for _, f in ipairs(AP.PLAN_SHARED) do
        if not fits(paidPool["pl:" .. f], string.rep("9", AP.digits(AP.PLAN_RANGE[f][2]))) then narrow[#narrow + 1] = f end
    end
    check(#narrow == 0, "付費頁價格、租金與共用欄位放得下範圍上限（太窄：" .. table.concat(narrow, ",") .. "）")
    fw.charW = 7
    getText = realGetText
    AP.instance = nil

    MinidoracatEconomy = nil
    local w2 = SW.open({})
    slotsData.economy = "ABSENT"
    answer("slots", slotsData)
    check(w2.flow.pool.buy2 ~= nil and not w2.flow.pool.buy2:isVisible(), "Economy 不可用：只顯示原因、沒有付款鈕")
    local swallowed = {}
    for _, l in ipairs(T.prints) do
        if string.find(l, "failed", 1, true) then swallowed[#swallowed + 1] = l end
    end
    check(#swallowed == 0, "回呼沒有被吞掉的錯誤（" .. table.concat(swallowed, " / ") .. "）")

    MinidoracatUI = nil
    check(pcall(AP.open, {}) and pcall(SW.open, {}), "沒有 UI 框架：退最小 fallback、不報錯")
    AP.instance, SW.instance = nil, nil
    for _, k in ipairs(G) do _G[k] = saved[k] end
end
