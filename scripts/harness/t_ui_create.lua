-- 建立面板的狀態機（CreatePanel.lua，計畫 §10.4）與框選工具（Select.lua，§7.2）：
-- idle 閘門（分割畫面、伺服器閘門、沒地契、等級未啟用、名額已滿）、走位框選、預檢冷卻與舊結果、
-- 送出 → 待定 → 查詢結果 → 成功、失敗 → preview 帶原因、快取過期不當失敗、死亡 → idle、重新框選指令、地契右鍵。
return function(T)
    local check = T.check
    local MSH = T.bootClient()
    local P, Sel = MSH.CreatePanel, MSH.Select
    local p = T.player({ name = "alice", x = 10.5, y = 10.5, items = { "MinidoracatSafehouse.Deed2" } })
    local opened = {}
    MSH.ManagerWindow = { open = function(o) opened[#opened + 1] = o end }

    local function lastSent() return T.clientSent[#T.clientSent] end
    local function sentOf(command)
        local out = {}
        for _, s in ipairs(T.clientSent) do if s.command == command then out[#out + 1] = s end end
        return out
    end
    local function reply(sent, fields)
        local r = { command = sent.command, requestId = sent.args.requestId, ok = true, code = "OK" }
        for k, v in pairs(fields or {}) do r[k] = v end
        T.fire("OnServerCommand", MSH.MODULE, "result", r)
    end
    local function walkRect(m, x1, y1)
        P.model = m   -- OnTick 只推進開著的那一個面板（預檢排程、死亡檢查）
        if m.phase == P.IDLE then check(P.startSelect(m, Sel.WALK), "idle 沒有閘門時可以開始框選") end
        Sel.mark(m.sel, p)
        p.x, p.y = x1, y1
        T.tick(1)
        return P.finish(m, T.now)
    end
    -- 先讓清單快取有一筆舊屋（送出時用來認新屋）
    MSH.Client.refreshList()
    reply(lastSent(), { claims = { { claimId = 3, revision = 1, title = "old", actorRole = "owner", bits = 63 } } })

    T.section("建立面板：idle 閘門")
    local m = P.newModel({ deedType = "MinidoracatSafehouse.Deed2" }, 0)
    check(m.tier == 2 and m.deedType == "MinidoracatSafehouse.Deed2" and P.gate(m) == nil, "用地契開：2 級、沒有閘門")
    local split = P.newModel({ deedType = "MinidoracatSafehouse.Deed2" }, 1)
    check(P.gate(split) == "SPLIT" and not P.startSelect(split, Sel.WALK) and split.phase == P.IDLE,
        "分割畫面次玩家：閘門 SPLIT、不能開始框選")
    check(P.newModel({ deedType = "MinidoracatSafehouse.Deed7" }, 0).tier == 2, "指定的地契不在背包：改用持有的那張")
    p.inv:AddItem("MinidoracatSafehouse.Deed5")
    local t5 = P.newModel({ deedType = "MinidoracatSafehouse.Deed5" }, 0)
    check(t5.tier == 5 and P.gate(t5) == MSH.CODE.TIER_DISABLED, "等級未啟用（預設前 3 級）：TIER_DISABLED")
    local bare = T.player({ name = "bob", offline = true })
    local saved = getSpecificPlayer
    getSpecificPlayer = function() return bare end
    check(P.gate(P.newModel({}, 0)) == MSH.CODE.NO_DEED, "沒有地契：NO_DEED")
    getSpecificPlayer = saved
    T.sandbox("CreateMode", MSH.Settings.CREATE.FREE)
    local free = P.newModel({ deedType = "MinidoracatSafehouse.Deed2" }, 0)
    check(free.source == MSH.SOURCE.FREE and free.deedType == nil and P.gate(free) == nil, "免費模式：不帶地契、以 1 級計")
    T.sandbox("CreateMode", MSH.Settings.CREATE.DEED)

    P.refreshSlots(m)
    reply(lastSent(), { blocked = "HEALTH_BLOCKED", free = { n = 1, used = 0 }, tiers = {} })
    check(P.gate(m) == "HEALTH_BLOCKED" and not P.startSelect(m, Sel.WALK), "伺服器閘門（slots.blocked）擋住框選")
    P.refreshSlots(m)
    reply(lastSent(), { free = { n = 1, used = 1 }, tiers = { { tier = 2, free = true, usable = 1, paid = 1 } } })
    check(P.gate(m) == MSH.CODE.QUOTA_FULL, "免費位與付費位都用完：QUOTA_FULL")
    P.refreshSlots(m)
    reply(lastSent(), { free = { n = 1, used = 1 }, tiers = { { tier = 2, free = true, usable = 2, paid = 1 } } })
    check(P.gate(m) == nil, "還有付費位：可以建")
    P.refreshSlots(m)
    T.fire("OnServerCommand", MSH.MODULE, "result",
        { command = "slots", requestId = lastSent().args.requestId, ok = false, code = "DEDICATED_ONLY" })
    check(P.gate(m) == "DEDICATED_ONLY", "非專用伺服器：DEDICATED_ONLY")
    m.blocked = nil

    T.section("建立面板：走位框選與預檢")
    check(walkRect(m, 14.2, 12.9) and m.phase == P.PREVIEW, "走到對角後〔完成〕進入 preview")
    local pv = lastSent()
    check(pv.command == "preview" and pv.args.rect.x == 10 and pv.args.rect.y == 10 and pv.args.rect.w == 5
        and pv.args.rect.h == 3 and pv.args.deedType == "MinidoracatSafehouse.Deed2", "預檢送出提案矩形與地契")
    local before = #sentOf("preview")
    check(P.reselect(m) and m.phase == P.SELECTING and m.sel.ax == nil, "〔重新框選〕清掉範圍")
    p.x, p.y = 10, 10
    walkRect(m, 15, 15)
    check(#sentOf("preview") == before, "500 ms 冷卻內不送第二次預檢（伺服器會直接丟掉）")
    T.tick(6)
    check(#sentOf("preview") == before + 1, "冷卻過了才送")
    reply(pv, { pass = true, checks = {} })
    check(m.checks == nil, "舊範圍的晚到預檢結果不收")
    reply(lastSent(), { pass = false, checks = { { name = "roads", ok = false, code = "ROAD" },
        { name = "quota", ok = false, code = "QUOTA_FULL", tier = 2, buy = { amount = 100, currency = "USD" } } } })
    check(m.pass == false and #m.checks == 2 and not P.toConfirm(m), "預檢沒過：留在 preview、不能確認")
    check(P.recheck(m, T.now) and m.previewWant and m.previewRid == nil, "〔重新預檢〕照冷卻排程，不立刻送")
    T.tick(6)
    reply(lastSent(), { pass = true, checks = { { name = "roads", ok = true } } })
    check(m.pass == true and P.toConfirm(m) and m.phase == P.CONFIRM, "預檢通過 → confirm")

    T.section("建立面板：送出、待定、查詢結果、成功")
    check(not P.submit(m, "bad[title]") and m.titleBad and m.phase == P.CONFIRM, "不合法的名稱不送出")
    check(not P.submit(m, string.rep("a", 41)), "超過 40 字元的名稱不送出")
    check(P.submit(m, "  Home  ") and m.phase == P.SUBMITTING, "送出 → submitting")
    local cr = lastSent()
    check(cr.command == "create" and cr.args.title == "Home" and cr.args.deedType == "MinidoracatSafehouse.Deed2"
        and cr.args.rect.w == 6 and MSH.Client.isPending(cr.args.requestId), "create 帶 mutation requestId、名稱與地契")
    T.advance(10000)
    T.tick(6)
    check(m.phase == P.PENDING, "10 秒沒結果 → result-pending")
    local n = #T.clientSent
    check(P.queryResult(m) and #T.clientSent == n + 1 and lastSent().args.requestId == cr.args.requestId,
        "〔查詢結果〕用同一 requestId 重送")
    reply(lastSent(), { claimId = 9, revision = 1 })
    check(m.phase == P.DONE and opened[1] and opened[1].claimId == 9, "收到成功 → 開管理視窗並選中新屋")

    T.section("建立面板：失敗回 preview 帶原因")
    local f = P.newModel({ deedType = "MinidoracatSafehouse.Deed2" }, 0)
    p.x, p.y = 10, 10
    walkRect(f, 12, 12)
    T.tick(6)
    reply(lastSent(), { pass = true, checks = {} })
    P.toConfirm(f)
    P.submit(f, "")
    check(lastSent().args.title == nil, "名稱空白＝不帶（伺服器用帳號名）")
    reply(lastSent(), { ok = false, code = "OCCUPIED" })
    check(f.phase == P.PREVIEW and f.failCode == "OCCUPIED" and f.pass == false and not P.toConfirm(f),
        "失敗 → preview 顯示原因、要重新預檢才能再建")

    T.section("建立面板：快取過期不當失敗")
    P.recheck(f, T.now)
    T.tick(6)
    reply(lastSent(), { pass = true, checks = {} })
    P.toConfirm(f)
    P.submit(f, "")
    T.advance(71000)
    T.tick(6)
    local ls = lastSent()
    check(f.phase == P.PENDING and f.expired and ls.command == "list", "過了伺服器快取時間：維持待定、改抓清單")
    reply(ls, { claims = { { claimId = 3, actorRole = "owner" } } })
    check(f.phase == P.PENDING and f.notice == "UNCONFIRMED", "清單沒有新屋：仍是待定（無法確認），不當失敗")
    check(P.queryResult(f) and lastSent().command == "list", "再查詢：重抓清單")
    reply(lastSent(), { claims = { { claimId = 3, actorRole = "owner" }, { claimId = 12, actorRole = "owner" } } })
    check(f.phase == P.DONE and opened[2] and opened[2].claimId == 12, "清單出現新屋 → 當成功")

    T.section("建立面板：死亡 → idle")
    local d = P.newModel({ deedType = "MinidoracatSafehouse.Deed2" }, 0)
    P.model = d
    P.startSelect(d, Sel.WALK)
    Sel.mark(d.sel, p)
    p.dead = true
    T.tick(1)
    check(d.phase == P.IDLE and d.notice == MSH.CODE.DEAD and d.sel == nil, "框選中死亡 → idle")
    check(P.gate(d) == MSH.CODE.DEAD and not P.startSelect(d, Sel.WALK), "死了不能再開始框選")
    p.dead = false
    P.model = nil

    T.section("建立面板：重新框選指令")
    local r = P.newModel({ mode = "redraw", claimId = 3, revision = 4, tier = 2 }, 0)
    p.x, p.y = 30, 30
    T.advance(1000)
    walkRect(r, 33, 34)
    local rp = lastSent()
    check(rp.command == "preview" and rp.args.claimId == 3 and rp.args.deedType == nil, "重新框選的預檢帶 claimId、不帶地契")
    reply(rp, { pass = true, checks = {} })
    P.toConfirm(r)
    P.submit(r, "ignored")
    local rd = lastSent()
    check(rd.command == "redraw" and rd.args.claimId == 3 and rd.args.expectedRevision == 4 and rd.args.title == nil
        and rd.args.deedType == nil, "送 redraw：claimId、expectedRevision、同一等級（不帶地契與名稱）")

    T.section("地契右鍵「使用地契」")
    local function menu(playerNum, items)
        local opts = {}
        local ctx = { addOption = function(_, name, target, fn, param)
            local o = { name = name, target = target, fn = fn, param = param }
            opts[#opts + 1] = o
            return o
        end }
        T.fire("OnFillInventoryObjectContextMenu", playerNum, ctx, items)
        return opts
    end
    local deed = T.item("MinidoracatSafehouse.Deed3")
    local o = menu(0, { { items = { deed, deed } } })
    check(#o == 1 and o[1].target == "MinidoracatSafehouse.Deed3" and o[1].param == 0 and not o[1].notAvailable,
        "疊起來的地契也有「使用地契」")
    check(#menu(0, { T.item("Base.Plank") }) == 0, "不是地契不加選項")
    local o1 = menu(1, { deed })
    check(#o1 == 1 and o1[1].notAvailable == true, "分割畫面次玩家：選項不可用")

    T.section("建立面板：畫面（假框架）—不透明視窗、即時大小、預檢後的範圍與問題格")
    local G = { "MinidoracatUI", "ISPanel", "getCore", "getTextManager", "UIFont", "getJoypadData", "getText",
        "addAreaHighlightForPlayer" }
    local savedG = {}
    for _, k in ipairs(G) do savedG[k] = _G[k] end
    local function class(base)
        local c = {}
        c.__index = c
        if base then setmetatable(c, { __index = base }) end
        function c:derive() return class(self) end
        return c
    end
    local Base = class()
    function Base:new(x, y, w, h)
        return setmetatable({ x = x or 0, y = y or 0, width = w or 60, height = h or 20, visible = true }, self)
    end
    for _, k in ipairs({ "initialise", "addChild", "bringToTop", "drawText", "setTooltip", "setStyle", "setActive",
        "fitWidth", "setInvalid", "removeFromUIManager", "addToUIManager", "onMouseMoveOutside", "onMouseUpOutside",
        "onJoypadDirUp", "onJoypadDirDown", "onJoypadDirLeft", "onJoypadDirRight", "onFocusShoulder" }) do
        Base[k] = function() end
    end
    function Base:setVisible(b) self.visible = b end
    function Base:getIsVisible() return self.visible end
    function Base:setX(n) self.x = n end
    function Base:setY(n) self.y = n end
    function Base:setWidth(n) self.width = n end
    function Base:setHeight(n) self.height = n end
    function Base:setEnabled(b) self.enabled = b end
    function Base:setTitle(t) self.title = t end
    function Base:getText() return "" end
    function Base:contentTop() return 24 end
    function Base:close() self.visible = false end
    ISPanel = class(Base)
    UIFont = { Small = "Small", Medium = "Medium" }
    getCore = function() return { getScreenWidth = function() return 1280 end } end
    getTextManager = function() return { getFontHeight = function() return 16 end } end
    getJoypadData = function() return nil end
    getText = function(k, ...)
        local a = { ... }
        return #a == 0 and k or (k .. "|" .. table.concat(a, ","))
    end
    local function col(r) return { r = r, g = 0, b = 0, a = 1 } end
    local colors = { text = col(0.1), textMuted = col(0.2), warning = col(0.3), accent = col(0.4), errorText = col(0.5) }
    local caps = { window = true, controls = true, focus = true }
    local function make(o) local e = Base.new(Base, o.x, o.y, o.width, o.height or 20) for k, x in pairs(o) do e[k] = x end return e end
    MinidoracatUI = { v1 = { API_MAJOR = 1, API_REVISION = 17, CAPABILITIES = caps,
        Theme = { defaultPalette = function() return {} end, create = function() return { colors = colors } end },
        Window = { new = function(o) return make(o) end },
        Button = { new = function(o) return make(o) end },
        TextField = { new = function(o) return make(o) end },
    } }
    MSH.Client._theme = nil
    P.open({ deedType = "MinidoracatSafehouse.Deed2" })
    local vm = P.model
    local v = vm.view

    local calls = {}
    addAreaHighlightForPlayer = function(pn, x1, y1, x2, y2, z, r, g, b, a)
        calls[#calls + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, r = r, a = a }
    end
    local function frame() calls = {} P.View.frame(v) return calls end
    -- 每幀不配置：先暖一幀，停掉 GC 量 200 幀的記憶體增量（假 addAreaHighlightForPlayer 只累加計數）
    local function grownKB()
        local real, n = addAreaHighlightForPlayer, 0
        addAreaHighlightForPlayer = function() n = n + 1 end
        P.View.frame(v)
        collectgarbage("collect")
        collectgarbage("stop")
        local kb = collectgarbage("count")
        for _ = 1, 200 do P.View.frame(v) end
        local grown = collectgarbage("count") - kb
        collectgarbage("restart")
        addAreaHighlightForPlayer = real
        return grown, n
    end
    p.x, p.y = 10, 10
    P.startSelect(vm, Sel.WALK)
    Sel.mark(vm.sel, p)
    p.x, p.y = 39, 19
    local c1 = frame()
    check(v.sizeText == "IGUI_MSH_Select_SizeLimit|30,10,300,40,1600" and v.sizeTok == "text" and c1[1].r == colors.accent.r,
        "大小行寫出邊長與面積上限（2 級 40 × 40、1,600）")
    p.x, p.y = 59, 19
    local c2 = frame()
    check(v.sizeText == "IGUI_MSH_Select_SizeLimit|50,10,500,40,1600" and v.sizeTok == "errorText"
        and c2[1].r == colors.errorText.r, "只有邊長超過：字與範圍都變錯誤色，上限寫得出原因")
    local gs, ns = grownKB()
    check(ns == 201 and gs < 1, "框選畫面每幀不配置（200 幀增加 " .. string.format("%.2f", gs) .. " KB）")
    p.x, p.y = 17, 17
    frame()
    P.finish(vm, T.now)
    T.tick(7)
    local pvs = lastSent()
    check(pvs.command == "preview" and pvs.args.rect.w == 8, "完成後送預檢")
    local c3 = frame()
    check(#c3 == 1 and c3[1].x1 == 10 and c3[1].x2 == 18 and c3[1].y2 == 18 and c3[1].r == colors.accent.r,
        "等預檢時照樣每幀畫範圍（accent）")
    reply(pvs, { pass = false, checks = {
        { name = "roads", ok = false, code = "ROAD", x = 12, y = 13, kind = "main", areas = { 12, 13, 1, 1, 15, 11, 2, 7 } },
        { name = "resources", ok = false, code = "RESOURCE", cat = "police", x = 5, y = 5, w = 20, h = 30 },
        { name = "overlap", ok = false, code = "TOO_CLOSE", x = 19, y = 10, w = 4, h = 4 },
        { name = "quota", ok = false, code = "QUOTA_FULL", tier = 2 },
        { name = "identity", ok = true } } })
    local c4 = frame()
    check(#c4 == 5 and c4[1].r == colors.accent.r and c4[1].a == P.RANGE_ALPHA, "預檢沒過：範圍仍是 accent")
    check(#c4 == 5 and c4[2].x1 == 12 and c4[2].y1 == 13 and c4[2].x2 == 13 and c4[2].y2 == 14
        and c4[3].x1 == 15 and c4[3].y1 == 11 and c4[3].x2 == 17 and c4[3].y2 == 18
        and c4[4].x1 == 5 and c4[4].x2 == 25 and c4[4].y2 == 35 and c4[5].x1 == 19 and c4[5].x2 == 23
        and c4[2].r == colors.errorText.r and c4[5].r == colors.errorText.r and c4[2].a > P.RANGE_ALPHA,
        "沒過的項目：每塊道路格、資源點整棟、相鄰範圍用錯誤色、更不透明標出；沒座標的不畫")
    local c5 = frame()
    check(#c5 == 5, "每幀重加同一組（只畫一層）")
    local gp, np = grownKB()
    check(np == 201 * 5 and gp < 1, "預檢畫面每幀不配置（200 幀增加 " .. string.format("%.2f", gp) .. " KB）")
    P.recheck(vm, T.now)
    T.tick(7)
    reply(lastSent(), { pass = true, checks = { { name = "roads", ok = true } } })
    local c6 = frame()
    check(#c6 == 1 and c6[1].r == colors.accent.r, "預檢通過：只畫範圍、沒有問題格")
    P.toConfirm(vm)
    local c7 = frame()
    check(vm.phase == P.CONFIRM and #c7 == 1 and c7[1].x1 == 10, "confirm 照樣畫範圍")
    P.submit(vm, "")
    local c8 = frame()
    check(vm.phase == P.SUBMITTING and #c8 == 1, "送出中照樣畫範圍")
    reply(lastSent(), { ok = false, code = "ROAD", x = 14, y = 11, kind = "street", areas = { 14, 11, 3, 1 } })
    local c9 = frame()
    check(vm.phase == P.PREVIEW and #c9 == 2 and c9[2].x1 == 14 and c9[2].x2 == 17 and c9[2].y1 == 11
        and c9[2].r == colors.errorText.r, "建立失敗回 preview：失敗結果帶的道路格也標出")
    P.recheck(vm, T.now)
    T.tick(7)
    reply(lastSent(), { pass = false, checks = { { name = "size", ok = false, code = "TOO_BIG", maxSide = 40, maxArea = 1600 } } })
    local c10 = frame()
    check(#c10 == 1 and c10[1].r == colors.errorText.r, "太大（沒有座標可指）：範圍本身改錯誤色")
    local function anyError(cs)
        for _, c in ipairs(cs) do
            if c.r == colors.errorText.r then return true end
        end
        return false
    end
    P.recheck(vm, T.now)
    T.tick(7)
    reply(lastSent(), { pass = false, checks = {
        { name = "size", ok = false, code = "TOO_BIG", maxSide = 40, maxArea = 1600 },
        { name = "roads", ok = false, code = "ROAD", areas = { 12, 13, 1, 1 } } } })
    check(anyError(frame()), "（對照）重新框選前地上有紅色")
    P.reselect(vm)
    check(not anyError(frame()), "重新框選：地上不留上一輪的問題格與紅色範圍")
    p.x, p.y = 10, 10
    Sel.mark(vm.sel, p)
    p.x, p.y = 17, 17
    frame()
    P.finish(vm, T.now)
    T.tick(7)
    reply(lastSent(), { pass = false, checks = { { name = "roads", ok = false, code = "ROAD", areas = { 12, 13, 1, 1 } } } })
    P.back(vm)
    check(vm.phase == P.IDLE and #frame() == 0, "取消回 idle：地上什麼都不畫")
    P.close(vm)
    MSH.Client._theme = nil
    for _, k in ipairs(G) do _G[k] = savedG[k] end

    T.section("建立面板：框架不在時不報錯")
    local okOpen = pcall(P.open, { deedType = "MinidoracatSafehouse.Deed2" })
    check(okOpen and P.model == nil, "沒有 UI 框架：open 不丟錯、不留半套狀態（退 fallback）")
end
