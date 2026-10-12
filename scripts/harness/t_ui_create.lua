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
    check(pv.command == "preview" and #pv.args.rects == 1 and pv.args.rects[1].x == 10 and pv.args.rects[1].y == 10
        and pv.args.rects[1].w == 5 and pv.args.rects[1].h == 3 and pv.args.deedType == "MinidoracatSafehouse.Deed2",
        "預檢送出提案範圍（一塊）與地契")
    local before = #sentOf("preview")
    local kept = P.edit(m) and m.phase == P.SELECTING and Sel.result(m.sel).rects
    check(kept and #kept == 1 and kept[1].w == 5 and kept[1].h == 3, "〔修改範圍〕回框選、範圍保留")
    check(P.clear(m) and Sel.isEmpty(m.sel) and m.phase == P.SELECTING, "〔清除〕清空範圍")
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
        and cr.args.rects[1].w == 6 and MSH.Client.isPending(cr.args.requestId), "create 帶 mutation requestId、名稱與地契")
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

    T.section("建立面板：畫面（假框架）—不透明視窗、即時大小、地板上的範圍與問題格")
    local G = { "MinidoracatUI", "ISPanel", "getCore", "getTextManager", "UIFont", "getJoypadData", "getText",
        "getMouseX", "getMouseY", "isMouseButtonDown", "screenToIsoX", "screenToIsoY",
        "wasMouseActiveMoreRecentlyThanJoypad" }
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
    for _, k in ipairs({ "initialise", "addChild", "bringToTop", "drawText", "setTooltip", "setActive",
        "fitWidth", "setInvalid", "removeFromUIManager", "addToUIManager",
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
    function Base:setStyle(s) self.style = s end
    function Base:getText() return "" end
    function Base:contentTop() return 24 end
    function Base:close() self.visible = false end
    ISPanel = class(Base)
    UIFont = { Small = "Small", Medium = "Medium" }
    getCore = function() return { getScreenWidth = function() return 1280 end, getScreenHeight = function() return 720 end } end
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

    -- 地板染色的假世界（env T.tintWorld）：frame() 回這一幀之後玩家這層染著的格子與顏色、強度
    local tw = T.tintWorld()
    local function frame()
        P.View.frame(v)
        return tw.lit(0)
    end
    local function colorOf(c) return c.r .. "/" .. c.g .. "/" .. c.b end
    local function count(cells)
        local n = 0
        for _ in pairs(cells) do n = n + 1 end
        return n
    end
    -- 每幀不配置、範圍沒變時不碰地板：先暖一幀，停掉 GC 量 200 幀的記憶體增量與 setHighlightColor 次數
    local function steady()
        P.View.frame(v)
        local sets = tw.sets
        collectgarbage("collect")
        collectgarbage("stop")
        local kb = collectgarbage("count")
        for _ = 1, 200 do P.View.frame(v) end
        local grown = collectgarbage("count") - kb
        collectgarbage("restart")
        return grown, tw.sets - sets
    end
    -- 面板上的一行字（layout 重建的 v.lines）：回 token
    local function lineTok(text)
        for _, l in ipairs(v.lines) do
            if l.text == text then return l.token end
        end
        return nil
    end
    -- 看得到的主要按鈕（黃色）一次只有一顆，而且是這顆
    local function onlyPrimary(name)
        local found = nil
        for k, b in pairs(v.btn) do
            if b.visible and b.style == "primary" then
                if found ~= nil then return false end
                found = k
            end
        end
        return found == name
    end
    p.x, p.y = 10, 10
    P.startSelect(vm, Sel.WALK)
    check(onlyPrimary("mark"), "走位、範圍還空著：只有〔設第一角〕是主要按鈕")
    Sel.mark(vm.sel, p)
    p.x, p.y = 39, 19
    local c1, k1, a1 = frame()
    check(v.sizeText == "IGUI_MSH_Select_Pending|30,10" and count(c1) == 300 and c1["10,10"] and c1["39,19"]
        and k1["10,10"] == colorOf(colors.accent) and a1["10,10"] == Sel.PENDING_TINT,
        "拉到一半的那塊：每幀寫出大小、整塊地板用 accent 染色")
    check(onlyPrimary("apply"), "拉到一半：只有〔加入這塊〕是主要按鈕")
    check(lineTok("IGUI_MSH_Select_ShapeLimit|40,1600,4") == "textMuted",
        "上限行寫出邊長、面積與塊數上限（2 級 40 × 40、1,600、沙盒預設 4 塊，不是硬上限）")
    p.x, p.y = 41, 19
    local c1b = frame()
    check(c1b["41,19"] and c1b["40,10"] and count(c1b) == 320, "走位終點往外走：拉到一半那塊跟著長大")
    p.x, p.y = 59, 19
    check(P.applyPiece(vm) and Sel.bounds(vm.sel) == nil, "〔加入這塊〕：走到的那塊套用進範圍")
    local c2, k2, a2 = frame()
    check(lineTok("IGUI_MSH_Select_Shape|50,10,500,1") == "errorText" and k2["10,10"] == colorOf(colors.errorText)
        and a2["10,10"] == Sel.PIECE_TINT[1] and c2["59,19"] and k2["59,19"] == colorOf(colors.accent)
        and a2["59,19"] == Sel.CURSOR_TINT,
        "只有邊長超過：範圍行與範圍都變錯誤色；游標（玩家所在格）蓋在上面")
    check(onlyPrimary("done"), "範圍有東西、沒有拉到一半：只有〔完成〕是主要按鈕")
    local gs, ss = steady()
    check(ss == 0 and gs < 1, "框選畫面範圍沒變時每幀不配置、不碰地板（200 幀增加 " .. string.format("%.2f", gs)
        .. " KB、重設 " .. ss .. " 格）")
    check(P.undo(vm) and Sel.isEmpty(vm.sel), "〔復原〕退回上一步：範圍又是空的")
    p.x, p.y = 10, 10
    Sel.mark(vm.sel, p)
    p.x, p.y = 17, 17
    local c2b = frame()
    check(count(c2b) == 64 and c2b["10,10"] and c2b["17,17"] and not c2b["59,19"],
        "〔復原〕後重新拉一塊：退回的範圍與舊游標格都取消染色")
    P.finish(vm, T.now)
    T.tick(7)
    local pvs = lastSent()
    check(pvs.command == "preview" and pvs.args.rects[1].w == 8, "完成後送預檢（走位還沒套用的那塊也算進去）")
    local c3, k3 = frame()
    check(count(c3) == 64 and c3["10,10"] and c3["17,17"] and not c3["18,18"] and k3["10,10"] == colorOf(colors.accent),
        "等預檢時照樣在地板上畫範圍（accent），沒有游標格")
    reply(pvs, { pass = false, checks = {
        { name = "roads", ok = false, code = "ROAD", x = 12, y = 13, kind = "main", areas = { 12, 13, 1, 1, 15, 11, 2, 7 } },
        { name = "resources", ok = false, code = "RESOURCE", cat = "police", x = 5, y = 5, w = 20, h = 30 },
        { name = "overlap", ok = false, code = "TOO_CLOSE", x = 19, y = 10, w = 4, h = 4 },
        { name = "quota", ok = false, code = "QUOTA_FULL", tier = 2 },
        { name = "identity", ok = true } } })
    local c4, k4, a4 = frame()
    local err, acc = colorOf(colors.errorText), colorOf(colors.accent)
    check(k4["12,13"] == err and k4["15,11"] == err and k4["16,17"] == err and k4["5,5"] == err and k4["24,34"] == err
        and k4["22,13"] == err and a4["12,13"] > Sel.PIECE_TINT[1] and not c4["25,5"] and not c4["4,5"]
        and not c4["5,35"] and count(c4) == 20 * 30,
        "沒過的項目：每塊道路格、資源點整棟、相鄰範圍用錯誤色、更深地染，邊界照座標（全落在資源點那棟 20×30 裡）")
    check(k4["13,13"] == err and k4["10,10"] == err, "範圍和資源點整棟重疊的格子顯示錯誤色（標紅蓋過範圍）")
    local gp, sp = steady()
    check(sp == 0 and gp < 1, "預檢畫面每幀不配置、不碰地板（200 幀增加 " .. string.format("%.2f", gp) .. " KB、重設 "
        .. sp .. " 格）")
    P.recheck(vm, T.now)
    T.tick(7)
    reply(lastSent(), { pass = true, checks = { { name = "roads", ok = true } } })
    local c6, k6 = frame()
    check(count(c6) == 64 and k6["12,13"] == acc and k6["10,10"] == acc and not c6["5,5"],
        "預檢通過：只剩範圍，問題格回到範圍的顏色、範圍外的取消")
    P.toConfirm(vm)
    local c7 = frame()
    check(vm.phase == P.CONFIRM and count(c7) == 64, "confirm 照樣畫範圍")
    P.submit(vm, "")
    local c8 = frame()
    check(vm.phase == P.SUBMITTING and count(c8) == 64, "送出中照樣畫範圍")
    reply(lastSent(), { ok = false, code = "ROAD", x = 14, y = 11, kind = "street", areas = { 14, 11, 3, 1 } })
    local _, k9 = frame()
    check(vm.phase == P.PREVIEW and k9["14,11"] == err and k9["16,11"] == err and k9["17,11"] == acc,
        "建立失敗回 preview：失敗結果帶的道路格也標出")
    P.recheck(vm, T.now)
    T.tick(7)
    reply(lastSent(), { pass = false, checks = { { name = "size", ok = false, code = "TOO_BIG", maxSide = 40, maxArea = 1600 } } })
    local c10, k10 = frame()
    check(count(c10) == 64 and k10["10,10"] == err and k10["17,17"] == err, "太大（沒有座標可指）：範圍本身改錯誤色")
    local function anyError(cs)
        for _, c in pairs(cs) do
            if c == err then return true end
        end
        return false
    end
    P.recheck(vm, T.now)
    T.tick(7)
    reply(lastSent(), { pass = false, checks = {
        { name = "size", ok = false, code = "TOO_BIG", maxSide = 40, maxArea = 1600 },
        { name = "roads", ok = false, code = "ROAD", areas = { 12, 13, 1, 1 } } } })
    check(anyError(select(2, frame())), "（對照）修改範圍前地上有紅色")
    local keptV = P.edit(vm) and Sel.result(vm.sel).rects
    check(keptV and #keptV == 1 and keptV[1].w == 8 and vm.phase == P.SELECTING, "〔修改範圍〕回框選、範圍保留")
    check(not anyError(select(2, frame())), "修改範圍：地上不留上一輪的問題格與紅色範圍")
    P.finish(vm, T.now)
    T.tick(7)
    reply(lastSent(), { pass = false, checks = { { name = "roads", ok = false, code = "ROAD", areas = { 12, 13, 1, 1 } } } })
    P.back(vm)
    check(vm.phase == P.IDLE and next((frame())) == nil, "取消回 idle：地上什麼都不染")
    -- 地面顯示範圍（"ranges" 圖層）在框選底下：框選蓋過的格子取消框選後換回範圍的顏色
    local below = { r = 0.9, g = 0.9, b = 0.1, a = 0.7 }
    MSH.FloorTint.put(getCell(), "ranges", 10, 10, 0, below)
    MSH.FloorTint.put(getCell(), "ranges", 30, 30, 0, below)
    check(P.startSelect(vm, Sel.WALK), "（前置）再開始框選")
    p.x, p.y = 10, 10
    Sel.mark(vm.sel, p)
    p.x, p.y = 12, 12
    local _, kb = frame()
    check(kb["10,10"] == acc and kb["30,30"] == colorOf(below), "框選蓋過地面範圍；範圍外的地面範圍照舊")
    P.back(vm)
    local cb, kb2 = frame()
    check(count(cb) == 2 and kb2["10,10"] == colorOf(below), "取消框選：那格換回地面範圍的顏色，不會被一起取消")
    MSH.FloorTint.clear("ranges")
    -- 很長的範圍只染畫面看得到的格子外加 MARGIN 格（假鏡頭 x ±80，env T.tintWorld）；鏡頭移出這個範圍才重切；
    -- 區塊重新載入換了地板，下一輪（FloorTint.tick）補上
    local M = MSH.FloorTint.MARGIN
    check(P.startSelect(vm, Sel.WALK), "（前置）框選一塊比畫面還長的")
    p.x, p.y = 10, 10
    Sel.mark(vm.sel, p)
    p.x, p.y = 109, 10
    local cp = frame()
    check(cp["109,10"] and cp[(109 - 80 - M) .. ",10"] and not cp[(108 - 80 - M) .. ",10"],
        "拉到一半那塊比畫面還長：只染畫面看得到的格子外加 MARGIN 格")
    check(P.applyPiece(vm), "（前置）加入 100×1 的一塊")
    local cf = frame()
    check(cf["109,10"] and cf[(109 - 80 - M) .. ",10"] and not cf[(108 - 80 - M) .. ",10"],
        "很長的範圍只染畫面看得到的格子外加 MARGIN 格")
    p.x = 10
    cf = frame()
    local edge = 10 + 80 + M   -- 這時染到的最右一格
    check(cf["10,10"] and cf[edge .. ",10"] and not cf[(edge + 1) .. ",10"] and not cf["109,10"],
        "鏡頭移到另一頭：染色範圍跟著移")
    p.x = 10 + M - 1
    cf = frame()
    check(cf[edge .. ",10"] and not cf[(edge + 1) .. ",10"], "鏡頭移動不到 MARGIN 格：不重切")
    p.x = 10 + M + 1
    cf = frame()
    check(cf[(edge + 1) .. ",10"] and cf[(p.x + 80 + M) .. ",10"], "鏡頭移出染色範圍：照新的畫面重切")
    tw.floors["12,10,0"] = nil   -- 區塊重新載入：這格換了新的地板物件
    T.advance(MSH.FloorTint.SCAN_MS)
    T.fire("OnPreUIDraw")
    check(tw.floors["12,10,0"] ~= nil and tw.floors["12,10,0"].on, "區塊重新載入：下一輪補上框選的染色")
    P.back(vm)

    T.section("建立面板：滑鼠拖曳；按面板上的按鈕不改到框好的範圍")
    -- 假滑鼠：螢幕座標 ÷ 10 = 格子；isMouseButtonDown 讀 mouse.down
    local mouse = { x = 0, y = 0, down = false }
    getMouseX = function() return mouse.x end
    getMouseY = function() return mouse.y end
    isMouseButtonDown = function(b) return b == 0 and mouse.down end
    screenToIsoX = function(_, sx) return sx / 10 end
    screenToIsoY = function(_, _, sy) return sy / 10 end
    wasMouseActiveMoreRecentlyThanJoypad = function() return true end
    p.x, p.y = 15.5, 15.5
    check(P.startSelect(vm, Sel.DRAG), "選拖曳開始框選")
    mouse.x, mouse.y, mouse.down = 100, 100, true
    T.fire("OnMouseDown", 100, 100)   -- 地面上的點擊：沒有視窗接走才會觸發（UIManager.java:715-719）
    mouse.x, mouse.y = 199, 189
    T.tick(1)
    local x1, y1, w1, h1 = Sel.bounds(vm.sel)
    mouse.down = false
    T.tick(1)
    mouse.x, mouse.y = 500, 500
    T.tick(1)
    local r2 = Sel.result(vm.sel).rects
    check(x1 == 10 and y1 == 10 and w1 == 10 and h1 == 9 and Sel.bounds(vm.sel) == nil
        and r2 and #r2 == 1 and r2[1].x == 10 and r2[1].w == 10 and r2[1].h == 9,
        "按著拖曳：終點跟著游標；放開就套用這一塊，之後再移動滑鼠，範圍不變")
    -- 引擎：視窗裡的按鈕接走點擊後，改呼叫父視窗的 onMouseDownOutside（座標在視窗內，UIElement.java:1094-1110）；
    -- 那一下不觸發 OnMouseDown（UIManager.java:715-719）
    mouse.x, mouse.y, mouse.down = 900, 40, true
    if v.win.onMouseDownOutside then v.win.onMouseDownOutside(v.win, 30, 40) end
    T.tick(1)
    mouse.down = false
    v.btn.done.onClick()
    check(vm.phase == P.PREVIEW and #vm.rects == 1 and vm.rects[1].x == 10 and vm.rects[1].y == 10
        and vm.rects[1].w == 10 and vm.rects[1].h == 9,
        "按〔完成〕：用拖好的範圍（不會變成按鈕底下的 1×1）")
    P.back(vm)
    P.startSelect(vm, Sel.WALK)
    frame()
    check(next((tw.lit(0))) ~= nil, "（前置）框選中地上有範圍")
    P.close(vm)
    check(next((tw.lit(0))) == nil, "關掉面板：地上的框選跟著收掉")
    tw.restore()
    MSH.Client._theme = nil
    for _, k in ipairs(G) do _G[k] = savedG[k] end

    T.section("建立面板：框架不在時不報錯")
    local okOpen = pcall(P.open, { deedType = "MinidoracatSafehouse.Deed2" })
    check(okOpen and P.model == nil, "沒有 UI 框架：open 不丟錯、不留半套狀態（退 fallback）")
end
