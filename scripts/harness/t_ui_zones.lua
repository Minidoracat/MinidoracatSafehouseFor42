-- 禁建區的客戶端：管理員面板排除頁只剩個數與〔管理禁建區〕；禁建區視窗（ZoneList.lua）的清單（名稱、範圍、已經壓到的
-- 安全屋）、搜尋、〔傳送〕（原版 /teleportto、要權限）、刪除先確認、滿了不能新增、地上用疊色畫禁建區與選中的那個、關窗
-- 開回管理員面板；新增禁建區面板（ZonePanel.lua）從禁建區視窗開、拖曳框選、儲存送出的範圍與名稱、成功或取消後開回禁建區
-- 視窗、失敗留在面板、外框上限擋住儲存；和建立面板互斥；結果碼 NO_BUILD 寫出禁建區名稱、建立面板預檢標紅壓到的部分。
-- 假框架同 t_ui_admin（AdminPanel 要的元件）加上建立面板／禁建區面板要的 focus、ISPanel:derive、Window:close。
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
    for _, k in ipairs({ "initialise", "bringToTop", "drawText", "onJoypadDirUp", "onJoypadDirDown", "onJoypadDirLeft",
        "onJoypadDirRight", "onFocusShoulder" }) do
        Base[k] = function() end
    end
    function Base:addChild(k) self.kids[#self.kids + 1] = k; k.parent = self end
    function Base:setVisible(v) self.visible = v end
    function Base:isVisible() return self.visible end
    function Base:getIsVisible() return self.visible end
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
    function Base:setEnabled(v) self.enabled = v ~= false end
    function Base:setTooltip(t) self.tooltip = t end
    ISUIElement, ISPanel = Base, class(Base)
    ISButton = class(Base)
    UIFont = { Small = "Small", Medium = "Medium" }
    getTextManager = function()
        return { MeasureStringX = function(_, _, s) return #tostring(s) * 7 end, getFontHeight = function() return 16 end }
    end
    local function make(cls, opts, h)
        local e = cls:new(opts.x, opts.y, opts.width or 60, opts.height or h or 20)
        for k, v in pairs(opts) do if e[k] == nil then e[k] = v end end
        e.enabled = true
        e._autoWidth = opts.width == nil
        return e
    end
    local Button = class(Base)
    function Button:setTitle(t)
        self.title = t
        if self._autoWidth then self:fitWidth() end
    end
    function Button:fitWidth() self.width = #tostring(self.title) * 7 + 20 end
    function Button:setActive(v) self.active = v end
    function Button:setStyle(s) self.style = s end
    function Button:isEnabled() return self.enabled end
    local Field = class(Base)
    function Field:getText() return self.text or "" end
    function Field:setText(t) self.text = t end
    function Field:setInvalid(v, m) self.invalid, self.invalidMessage = v, m end
    local Check = class(Base)
    function Check:getChecked() return self.checked == true end
    function Check:setLabel(l) self.label = l end
    function Check:setChecked(v) self.checked = v == true end
    local Tabs = class(Base)
    function Tabs:setSelected(id) self.selected = id end
    local Win = class(Base)
    function Win:contentTop() return 24 end
    function Win:close()
        self.visible = false
        if self.onClose then self.onClose(self) end
    end
    local Scroll = class(Base)
    function Scroll:contentWidth() return self.width - 12 end
    local function col(r) return { r = r, g = 0, b = 0, a = 1 } end
    local colors = { text = col(0.1), textMuted = col(0.2), textDisabled = col(0.25), warning = col(0.3), accent = col(0.4),
        errorText = col(0.5) }
    local caps = {}
    for _, c in ipairs({ "window", "controls", "focus", "dialog", "scrollPanel", "textWrap", "textFieldInvalid", "toast",
        "opaqueWindow" }) do
        caps[c] = true
    end
    local fw = { colors = colors, caps = caps }
    MinidoracatUI = { v1 = { API_MAJOR = 1, API_REVISION = 18, CAPABILITIES = caps,
        Theme = { defaultPalette = function() return {} end, create = function() return { colors = colors } end },
        Text = { fit = function(s) return s end, wrap = function(s) return { s } end },
        Window = { new = function(o) return make(Win, o) end },
        ScrollPanel = { new = function(o) return make(Scroll, o) end },
        Tabs = { new = function(o) return make(Tabs, o, 24) end },
        Button = { new = function(o) return make(Button, o, 26) end },
        TextField = { new = function(o) return make(Field, o, 22) end },
        Checkbox = { new = function(o) return make(Check, o, 20) end },
        Dialog = { show = function(o) fw.dialog = o return o end },
        Toast = { show = function() end },
    } }
    function fw.click(b)
        if b.enabled ~= false and b.onClick then b.onClick(b.target, b) end
    end
    return fw
end

return function(T)
    local check = T.check
    local MSH = T.bootClient()
    local Z, ZL, AP, CP, Sel = MSH.ZonePanel, MSH.ZoneList, MSH.AdminPanel, MSH.CreatePanel, MSH.Select
    check(Z ~= nil and type(Z.open) == "function" and ZL ~= nil and type(ZL.open) == "function",
        "ZonePanel、ZoneList 在客戶端載入（載入時不碰 UI）")
    local boss = T.player({ name = "boss", admin = true, x = 20.5, y = 20.5, items = { "MinidoracatSafehouse.Deed2" } })
    local managerOpened = 0
    MSH.ManagerWindow = { open = function() managerOpened = managerOpened + 1 end, isOpen = function() return false end }

    local G = { "ISUIElement", "ISPanel", "ISButton", "getTextManager", "UIFont", "getPlayer", "MinidoracatUI", "getText",
        "getJoypadData", "getMouseX", "getMouseY", "isMouseButtonDown", "wasMouseActiveMoreRecentlyThanJoypad",
        "ISWorldObjectContextMenu", "SendCommandToServer" }
    local saved = {}
    for _, k in ipairs(G) do saved[k] = _G[k] end
    -- getText 照英文譯文（Translator：%1..%9 換成參數，找不到鍵回鍵本身）：結果碼文字靠「找不到＝回鍵」判斷有沒有這句
    local EN = {}
    local f = assert(io.open("MOD/MinidoracatSafehouseFor42/Contents/mods/MinidoracatSafehouseFor42/42/media/lua/shared/"
        .. "Translate/EN/IG_UI.json", "r"))
    for line in f:lines() do
        local k, s = string.match(line, '^%s*"([%w_]+)":%s*"(.*)",?%s*$')
        if k then EN[k] = (string.gsub(s, '\\(.)', '%1')) end
    end
    f:close()
    getText = function(k, ...)
        local a = { ... }
        local s = EN[k]
        if s == nil then return k end
        return (string.gsub(s, "%%(%d)", function(n) return tostring(a[tonumber(n)]) end))
    end
    local tr = getText
    local function has(s, part) return type(s) == "string" and string.find(s, part, 1, true) ~= nil end

    T.section("結果碼 NO_BUILD：寫出壓到的禁建區")
    local r1 = MSH.Client.codeText("NO_BUILD", { zone = "Mall", zoneId = 3 })
    local r2 = MSH.Client.codeText("NO_BUILD", { zoneId = 7 })
    local r3, a3 = MSH.Client.codeText("NO_BUILD")
    check(r1 == tr("IGUI_MSH_Code_NO_BUILD", "Mall") and has(r1, '"Mall"') and r2 == tr("IGUI_MSH_Code_NO_BUILD", "#7")
        and r3 == tr("IGUI_MSH_Code_NO_BUILD", "-") and a3 == tr("IGUI_MSH_CodeAction_NO_BUILD") and a3 ~= "IGUI_MSH_CodeAction_NO_BUILD",
        "名稱優先，沒有名稱寫編號，什麼都沒有也不丟錯；有動作句")
    check(not has(MSH.Client.codeText("ROAD", { zone = "Mall" }), "Mall"), "（對照）別的碼不帶禁建區名稱")

    local fw = fakeUI()
    local colors = fw.colors
    getPlayer = function() return boss end
    getJoypadData = function() return nil end
    wasMouseActiveMoreRecentlyThanJoypad = function() return true end
    ISWorldObjectContextMenu = {}
    local tw = T.tintWorld()
    -- 假滑鼠與鏡頭：螢幕座標 ÷ 10 = 格子（畫面 1280×720 看得到 0..128 × 0..72）
    local mouse = { x = 0, y = 0, down = false }
    getMouseX = function() return mouse.x end
    getMouseY = function() return mouse.y end
    isMouseButtonDown = function(b) return b == 0 and mouse.down end
    screenToIsoX = function(_, sx) return sx / 10 end
    screenToIsoY = function(_, _, sy) return sy / 10 end
    local function colorOf(c) return c.r .. "/" .. c.g .. "/" .. c.b end
    local ERR, OK = colorOf(colors.errorText), colorOf(Sel.FLOOR_OK)

    local function lastCmd(command)
        for i = #T.clientSent, 1, -1 do
            if T.clientSent[i].command == command then return T.clientSent[i] end
        end
        return nil
    end
    local function countCmd(command)
        local c = 0
        for _, s in ipairs(T.clientSent) do if s.command == command then c = c + 1 end end
        return c
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
    local MALL = { id = 1, name = "Mall", rects = { { x = 5, y = 5, w = 4, h = 3 }, { x = 9, y = 5, w = 2, h = 3 } },
        claims = { { claimId = 12, owner = "eve", title = "E" }, { claimId = 15, owner = "bob", title = "B" } } }
    local FARM = { id = 4, name = "Farm", rects = { { x = 40, y = 40, w = 3, h = 3 } }, claims = {} }

    T.section("管理員面板排除頁：只寫個數與〔管理禁建區〕")
    local P = AP.open({ tab = "exclusions" })
    answer("adminOptions", { values = values, health = {}, settingsWarnings = {}, resourceApi = false, parkingApi = false })
    local ex = P.pages.exclusions.flow.pool
    local function shown(pool, key) return pool[key] ~= nil and pool[key]:isVisible() end
    check(lastCmd("adminZones") ~= nil and shown(ex, "zload#1") and shown(ex, "zmanage") and ex.zmanage.enabled,
        "開面板就抓禁建區個數；回覆前寫讀取中，〔管理禁建區〕可以按")
    answer("adminZones", { zones = { MALL, FARM }, max = 100, unreadable = false })
    check(shown(ex, "noMiniMap#1") and shown(ex, "h:zones#1") and not shown(ex, "zload#1")
        and ex["zcount#1"].text == tr("IGUI_MSH_Admin_ZonesCount", 2, 100), "沒有小地圖：資源點那組藏起來，禁建區個數照樣寫「2 / 100」")
    local stray = {}
    for k in pairs(ex) do
        if k == "zadd" or string.match(k, "^z[dtnac]%d") then stray[#stray + 1] = k end
    end
    check(#stray == 0, "排除頁沒有清單、〔傳送〕、〔刪除〕、〔新增禁建區〕（搬到禁建區視窗）：" .. table.concat(stray, ","))

    T.section("禁建區視窗：〔管理禁建區〕開、清單")
    local zonesAsk = countCmd("adminZones")
    fw.click(ex.zmanage)
    local m = ZL.model
    check(m ~= nil and m.fromAdmin and not P.win:isVisible() and countCmd("adminZones") == zonesAsk + 1,
        "〔管理禁建區〕：收起管理員面板，開禁建區視窗並抓清單")
    local v = m.view
    local pool = v.flow.pool
    check(v.win.opaque == true and v.win.title == tr("IGUI_MSH_Admin_ZonesHead") and v.win.width == 460
        and v.win.x == 1280 - 460 - 60 and v.win.y == 60 and v.win.height == 620, "側邊視窗：寬 460、放右側、不透明")
    check(shown(pool, "load#1") and pool["load#1"].text == tr("IGUI_MSH_Admin_Loading") and not shown(pool, "zadd"),
        "回覆前寫讀取中，還沒有〔新增禁建區〕")
    answer("adminZones", { zones = { MALL, FARM }, max = 100, unreadable = false })
    check(pool.zn1.text == "Mall" and pool.zn4.text == "Farm" and shown(pool, "zt1") and shown(pool, "zd1") and shown(pool, "zt4")
        and shown(pool, "zd4") and not shown(pool, "load#1") and pool["count#1"].text == tr("IGUI_MSH_Admin_ZonesCount", 2, 100),
        "每個禁建區一列：鍵用編號（zn1、zn4），名稱＋〔傳送〕＋〔刪除〕；數量寫「2 / 100」")
    check(pool["za1#1"].text == tr("IGUI_MSH_Admin_ZoneArea", 5, 5, 6, 3, 2) and pool["za4#1"].text == tr("IGUI_MSH_Admin_ZoneArea", 40, 40, 3, 3, 1),
        "範圍行：左上角、外框（兩塊合起來 6 × 3）、塊數")
    local cl = pool["zc1#1"]
    check(cl ~= nil and cl:isVisible() and has(cl.text, "eve #12") and has(cl.text, "bob #15") and cl.color == colors.warning,
        "已經壓到這裡的安全屋：屋主 #編號 用 warning 列出")
    check(not shown(pool, "zc4#1"), "沒有安全屋壓到的禁建區：不寫那一行")
    check(pool.zadd.enabled and pool.zd1.enabled and pool.zd1.style == "danger", "〔新增禁建區〕可按；〔刪除〕是 danger 樣式")
    check(not pool.zt1.enabled and not pool.zt4.enabled and shown(pool, "noTp#1")
        and pool["noTp#1"].text == tr("IGUI_MSH_ZoneList_NoTeleport"), "帳號沒有傳送到座標的權限：〔傳送〕停用並寫原因")
    local many = {}
    for j = 1, 20 do many[j] = { claimId = 100 + j, owner = "p" .. j, title = "T" } end
    ZL.load(m)
    answer("adminZones", { zones = { { id = 9, name = "Big", rects = MALL.rects, claims = many, claimCount = 25 },
        { id = 1, name = "Mall", rects = MALL.rects, claims = MALL.claims, claimCount = 2 } }, max = 100, unreadable = false })
    local more = tr("IGUI_MSH_Admin_ZoneClaimsMore", 5)
    check(has(pool["zc9#1"].text, "p20 #120") and has(pool["zc9#1"].text, tr("IGUI_MSH_Admin_ListSep") .. more)
        and not has(pool["zc1#1"].text, more) and not has(pool["zc1#1"].text, tr("IGUI_MSH_Admin_ZoneClaimsMore", 0))
        and not shown(pool, "zn4"),
        "伺服器只列 20 間（claimCount 25）：清單後面寫還有 5 間沒列出；claimCount 等於列出的數量就不寫；清單換了，不在的那列收掉")

    T.section("禁建區視窗：搜尋名稱")
    local PLAZA = { id = 6, name = "中央廣場", rects = { { x = 60, y = 10, w = 4, h = 4 } }, claims = {} }
    ZL.load(m)
    answer("adminZones", { zones = { MALL, FARM, PLAZA }, max = 100, unreadable = false })
    pool.zsearch.onChange(pool.zsearch, "  mALL ")
    check(shown(pool, "zn1") and not shown(pool, "zn4") and not shown(pool, "zn6") and not shown(pool, "zt4")
        and pool["matched#1"].text == tr("IGUI_MSH_ZoneList_Matched", 1) and pool["count#1"].text == tr("IGUI_MSH_Admin_ZonesCount", 3, 100),
        "搜尋框打字就篩選：不分大小寫、去頭尾空白；總數照寫，下一行寫符合的個數")
    ZL.setQuery(m, "廣場")
    check(shown(pool, "zn6") and not shown(pool, "zn1") and not shown(pool, "zn4") and pool["matched#1"].text == tr("IGUI_MSH_ZoneList_Matched", 1),
        "中文名稱的子字串也找得到")
    ZL.setQuery(m, "a")
    check(shown(pool, "zn1") and shown(pool, "zn4") and not shown(pool, "zn6") and pool["matched#1"].text == tr("IGUI_MSH_ZoneList_Matched", 2),
        "子字串比對：Mall、Farm 都有 a")
    ZL.setQuery(m, "zzz")
    check(not shown(pool, "zn1") and not shown(pool, "zn4") and not shown(pool, "zn6") and shown(pool, "noMatch#1")
        and pool["matched#1"].text == tr("IGUI_MSH_ZoneList_Matched", 0) and not shown(pool, "empty#1"),
        "都不符合：寫沒有名稱符合的禁建區（不是「還沒有禁建區」）")
    ZL.setQuery(m, "")
    check(shown(pool, "zn1") and shown(pool, "zn4") and shown(pool, "zn6") and not shown(pool, "matched#1") and not shown(pool, "noMatch#1"),
        "清空搜尋：全部列出，不寫符合幾個")
    ZL.load(m)
    answer("adminZones", { zones = {}, max = 100, unreadable = false })
    check(shown(pool, "empty#1") and not shown(pool, "noMatch#1") and not shown(pool, "zn1"), "一個禁建區都沒有：寫還沒有禁建區")
    ZL.load(m)
    answer("adminZones", { zones = { MALL, FARM }, max = 100, unreadable = false })

    T.section("禁建區視窗：傳送的落點")
    local tx, ty = ZL.target({ rects = { { x = 10, y = 20, w = 5, h = 4 } } })
    check(tx == 12 and ty == 22, "一塊：外框中央那格")
    local lx, ly = ZL.target({ rects = { { x = 0, y = 0, w = 10, h = 2 }, { x = 0, y = 2, w = 2, h = 8 } } })
    check(lx == 5 and ly == 1, "L 形：外框中央 (5, 5) 不在範圍內，改用第一塊的中央")
    local mx, my = ZL.target(MALL)
    check(mx == 8 and my == 6, "兩塊拼成的矩形：外框中央 (8, 6) 在範圍內就用它")

    T.section("禁建區視窗：〔傳送〕")
    local sent = {}
    SendCommandToServer = function(c) sent[#sent + 1] = c end
    local realRole, canTp = boss.getRole, false
    boss.getRole = function(self)
        local r = realRole(self)
        return { hasCapability = function(_, cap)
            return (canTp and cap ~= nil and cap == Capability.TeleportToCoordinates) or r:hasCapability(cap)
        end }
    end
    check(not ZL.canTeleport() and not ZL.teleport(m, 1) and #sent == 0 and m.selected == nil,
        "（直接呼叫）沒有 Capability.TeleportToCoordinates：不送任何指令")
    Capability.TeleportToCoordinates = "TeleportToCoordinates"
    check(not ZL.canTeleport() and not ZL.teleport(m, 1) and #sent == 0, "帳號沒有傳送到座標的權限：不送")
    canTp = true
    ZL.layout(m)
    check(ZL.canTeleport() and pool.zt1.enabled and pool.zt4.enabled and not shown(pool, "noTp#1"), "有權限：〔傳送〕可按、不寫原因")
    fw.click(pool.zt1)
    check(#sent == 1 and sent[1] == "/teleportto 8.5,6.5,0" and m.selected == 1
        and pool["status#1"].text == tr("IGUI_MSH_ZoneList_Teleported", "Mall", 8, 6)
        and pool.zn1.color == colors.accent and pool.zn4.color == colors.text,
        "按〔傳送〕：送原版 /teleportto 到中央那格的中心，狀態列寫送到哪，那一列名稱改 accent")
    local SEL, ZONE = colorOf(ZL.SEL_COLOR.ov), colorOf(Z.ZONE_COLOR.ov)
    ZL.frame(v)
    local oc, ok0, oa = tw.overlay(0)
    local lit0 = tw.lit(0)
    check(ok0["5,5"] == SEL and ok0["10,7"] == SEL and ok0["40,40"] == ZONE and ok0["42,42"] == ZONE
        and oa["40,40"] == Z.ZONE_COLOR.ov.a and oa["5,5"] == ZL.SEL_COLOR.ov.a
        and not oc["4,5"] and not oc["11,5"] and not oc["5,8"] and not lit0["5,5"] and not lit0["40,40"],
        "地上：禁建區是亮紅疊色、傳送過去的那個是黃色疊色（都帶 ov，不是地板染色），邊界照範圍")
    local FT = MSH.FloorTint
    check(FT.cells.zones[FT.key(40, 40, 0)].ov == Z.ZONE_COLOR.ov and FT.cells.zoneSel[FT.key(5, 5, 0)].ov == ZL.SEL_COLOR.ov,
        "zones／zoneSel 圖層的格子顏色帶 ov")
    canTp = false
    ZL.layout(m)
    fw.click(pool.zt4)
    check(not pool.zt4.enabled and not ZL.teleport(m, 4) and #sent == 1 and m.selected == 1,
        "權限拿掉：〔傳送〕停用、直接呼叫也不送")
    canTp = true
    Capability.TeleportToCoordinates = nil
    check(not ZL.canTeleport(), "（對照）帳號有權限但遊戲沒有這個 Capability：當沒有")
    Capability.TeleportToCoordinates = "TeleportToCoordinates"

    T.section("禁建區視窗：刪除先確認")
    local removes = countCmd("adminRemoveZone")
    fw.dialog = nil
    fw.click(pool.zd1)
    check(fw.dialog ~= nil and fw.dialog.danger and fw.dialog.text == tr("IGUI_MSH_Admin_ZoneRemoveAsk", "Mall")
        and countCmd("adminRemoveZone") == removes, "按〔刪除〕：先跳 danger 確認框（寫出名稱），還沒送")
    fw.dialog.onResult(false)
    check(countCmd("adminRemoveZone") == removes and m.busy == nil, "確認框按取消：不送")
    fw.click(pool.zd1)
    fw.dialog.onResult(true)
    local rm = lastCmd("adminRemoveZone")
    check(countCmd("adminRemoveZone") == removes + 1 and rm.args.zoneId == 1 and MSH.Client.isPending(rm.args.requestId)
        and m.busy and not pool.zd4.enabled and not pool.zadd.enabled and pool["status#1"].text == tr("IGUI_MSH_Admin_Busy"),
        "確定才送 adminRemoveZone（那一個的編號，mutation）；送出中〔刪除〕〔新增〕停用")
    answer("adminRemoveZone", { zoneId = 1, zones = { FARM }, max = 100 })
    check(not shown(pool, "zn1") and shown(pool, "zn4") and pool["count#1"].text == tr("IGUI_MSH_Admin_ZonesCount", 1, 100)
        and m.busy == nil and pool.zd4.enabled and m.selected == nil, "刪除成功：用回覆的清單重排；刪掉的是選中的那個就不再選中")
    ZL.frame(v)
    local _, ok1 = tw.overlay(0)
    check(ok1["5,5"] == nil and ok1["40,40"] == ZONE and next(FT.cells.zoneSel) == nil, "地上跟著清單：刪掉的不畫，黃色收掉")
    fw.click(pool.zd4)
    fw.dialog.onResult(true)
    local zonesBefore = countCmd("adminZones")
    answer("adminRemoveZone", { ok = false, code = "NOT_FOUND", zoneId = 4 })
    check(countCmd("adminZones") == zonesBefore + 1 and m.busy == nil, "別的管理員先刪了（NOT_FOUND）：重抓清單")
    answer("adminZones", { zones = { MALL, FARM }, max = 100, unreadable = false })
    fw.click(pool.zd4)
    fw.dialog.onResult(true)
    answer("adminRemoveZone", { ok = false, code = "SAVE_FAILED" })
    check(has(pool["status#1"].text, tr("IGUI_MSH_Code_SAVE_FAILED")) and pool["status#1"].color == colors.errorText
        and shown(pool, "zn4") and pool.zd4.enabled, "其他失敗：狀態列寫原因，清單不動")

    T.section("禁建區視窗：滿了或資料檔讀不到時不能新增")
    ZL.load(m)
    answer("adminZones", { zones = { MALL, FARM }, max = 2, unreadable = false })
    check(not pool.zadd.enabled and pool["block#1"].text == tr("IGUI_MSH_Admin_ZonesFull", 2) and pool.zd1.enabled,
        "到上限：〔新增禁建區〕停用並寫原因，刪除照樣可以")
    local opens = 0
    local realOpen = Z.open
    Z.open = function(o) opens = opens + 1 return realOpen(o) end
    ZL.onAdd(m)
    check(opens == 0 and not m.closed and ZL.model == m, "（直接呼叫）滿了：不開禁建區面板、視窗不收")
    ZL.load(m)
    answer("adminZones", { zones = { MALL }, max = 100, unreadable = true })
    check(not pool.zadd.enabled and not pool.zd1.enabled and not shown(pool, "block#1")
        and pool["unreadable#1"].text == tr("IGUI_MSH_Admin_ZonesUnreadable", tr("IGUI_MSH_Admin_Tab_rules"))
        and pool["unreadable#1"].color == colors.warning,
        "資料檔讀不到：新增、刪除都停用，寫一次原因（指向規則頁的伺服器狀態）")
    ZL.load(m)
    answer("adminZones", { zones = { MALL, FARM }, max = 100, unreadable = false })
    check(pool.zadd.enabled and not shown(pool, "unreadable#1"), "（對照）還沒滿、讀得到：可以新增")

    T.section("新增禁建區：從禁建區視窗開、地上畫既有禁建區、拖曳框選")
    fw.click(pool.zadd)
    local zm = Z.model
    check(opens == 1 and zm ~= nil and m.closed and ZL.model == nil and not v.win:isVisible() and not P.win:isVisible()
        and #zm.zones == 2 and zm.onClosed ~= nil, "〔新增禁建區〕：收起禁建區視窗（不開回管理員面板），開禁建區面板")
    check(next(FT.cells.zoneSel) == nil and next(FT.cells.zones) == nil, "禁建區視窗收起：地上的兩層收掉")
    v = zm.view
    pool = v.flow.pool
    check(v.win.opaque == true and v.field:getText() == tr("IGUI_MSH_Zone_DefaultName", 3), "視窗不透明；名稱預設「禁建區 3」")
    local function frame()
        Z.frame(v)
        return tw.lit(0)
    end
    frame()
    local _, ko = tw.overlay(0)
    check(FT.cells.zones[FT.key(5, 5, 0)].ov == Z.ZONE_COLOR.ov and ko["5,5"] == ZONE and ko["10,7"] == ZONE and ko["42,42"] == ZONE
        and not ko["4,5"] and not ko["11,5"] and not ko["5,8"],
        "禁建區面板也用 ZONE_COLOR（亮紅疊色）畫既有禁建區，邊界照範圍")
    fw.click(pool.drag)
    check(zm.sel.tool == Sel.DRAG and pool.save.style == "primary" and not pool.save.enabled,
        "拖曳、範圍還空著：〔儲存禁建區〕是唯一的主要按鈕但停用")
    mouse.x, mouse.y, mouse.down = 60, 60, true
    T.fire("OnMouseDown", 60, 60)
    mouse.x, mouse.y = 159, 139
    frame()
    check(pool["size"].text == tr("IGUI_MSH_Select_Pending", 10, 8), "拖曳中寫出那一塊的大小")
    mouse.down = false
    local c1, k1 = frame()
    local _, ko1 = tw.overlay(0)
    local res = Sel.result(zm.sel)
    check(res.rects and #res.rects == 1 and res.rects[1].x == 6 and res.rects[1].w == 10 and res.rects[1].h == 8,
        "放開滑鼠：那一塊加進範圍")
    check(k1["6,6"] == OK and k1["15,13"] == OK and ko1["5,5"] == ZONE and not ko1["6,6"] and not c1["16,13"],
        "新框的範圍（青色）蓋在既有禁建區上，旁邊的禁建區照樣紅色")
    check(pool.save.enabled and pool["shape#1"].text == tr("IGUI_MSH_Select_Shape", 10, 8, 80, 1)
        and pool["limit#1"].text == tr("IGUI_MSH_Select_PieceLimit", MSH.LIMIT.MAX_PIECES),
        "範圍行與塊數上限（硬上限，不看沙盒 MaxPieces）；可以儲存")

    T.section("新增禁建區：儲存失敗留在面板、等候中、晚到的成功關窗並開回禁建區視窗")
    v.field:setText("bad[name]")
    local adds = countCmd("adminAddZone")
    fw.click(pool.save)
    check(countCmd("adminAddZone") == adds and zm.err == "BAD_TITLE" and has(pool["fail#1"].text, tr("IGUI_MSH_Code_BAD_TITLE")),
        "名稱有 []：不送，寫原因")
    v.field:setText("  Mall 2  ")
    fw.click(pool.save)
    local add = lastCmd("adminAddZone")
    local ar = add.args.rects
    check(countCmd("adminAddZone") == adds + 1 and add.args.name == "Mall 2" and #ar == 1 and ar[1].x == 6 and ar[1].y == 6
        and ar[1].w == 10 and ar[1].h == 8 and MSH.Client.isPending(add.args.requestId),
        "〔儲存禁建區〕送 adminAddZone：去頭尾空白的名稱與框好的範圍（mutation）")
    check(not pool.save.enabled and pool["busy#1"].text == tr("IGUI_MSH_Create_Waiting"), "等結果時不能再按儲存")
    answer("adminAddZone", { ok = false, code = "SAVE_FAILED" })
    check(Z.model == zm and not zm.closed and has(pool["fail#1"].text, tr("IGUI_MSH_Code_SAVE_FAILED"))
        and #Sel.result(zm.sel).rects == 1 and pool.save.enabled and ZL.model == nil and not P.win:isVisible(),
        "儲存失敗：面板留著、寫原因、範圍保留，禁建區視窗與管理員面板都不開")
    fw.click(pool.save)
    answer("adminAddZone", { ok = false, code = "BAD_ARGS", reason = "FULL", max = 100 })
    check(pool["fail#1"].text == tr("IGUI_MSH_Admin_ZonesFull", 100), "伺服器說滿了：寫「已經有 100 個禁建區」，不寫請求不正確")
    v.field:setText("")
    fw.click(pool.save)
    add = lastCmd("adminAddZone")
    check(add.args.name == tr("IGUI_MSH_Zone_DefaultName", 3), "名稱清空：用預設名稱")
    T.advance(10000)
    T.tick(1)
    check(zm.busy == "waiting" and pool["busy#1"].text == tr("IGUI_MSH_Admin_Waiting") and not pool.save.enabled and not zm.closed,
        "10 秒沒回覆：寫等候中、不能重送、面板留著")
    zonesAsk = countCmd("adminZones")
    answer("adminAddZone", { zoneId = 7, zones = { MALL, FARM }, max = 100 })
    m = ZL.model
    check(zm.closed and Z.model == nil and m ~= nil and not m.closed and m.fromAdmin and not P.win:isVisible()
        and countCmd("adminZones") == zonesAsk + 1, "晚到的成功：關窗，禁建區視窗重新開（記得從管理員面板來）並重抓清單")
    check(next((tw.lit(0))) == nil and next(FT.cells.zones) == nil and ISWorldObjectContextMenu.disableWorldMenu == false,
        "關窗：地上的既有禁建區與框選都收掉、世界選單還原")
    answer("adminZones", { zones = { MALL, FARM }, max = 100, unreadable = false })

    T.section("新增禁建區：取消也開回禁建區視窗")
    local m1 = m
    fw.click(m1.view.flow.pool.zadd)
    zm = Z.model
    fw.click(zm.view.flow.pool.cancel)
    m = ZL.model
    check(zm.closed and m ~= nil and m ~= m1 and m.fromAdmin and not P.win:isVisible(), "〔取消〕：禁建區視窗重新開，fromAdmin 保留")
    answer("adminZones", { zones = { MALL, FARM }, max = 100, unreadable = false })

    T.section("新增禁建區：外框超過上限不能儲存")
    fw.click(m.view.flow.pool.zadd)
    zm = Z.model
    v, pool = zm.view, zm.view.flow.pool
    local side = MSH.LIMIT.ZONE_SIDE
    local function drag(x0, y0, x1, y1)
        mouse.x, mouse.y, mouse.down = x0 * 10, y0 * 10, true
        T.fire("OnMouseDown", mouse.x, mouse.y)
        mouse.x, mouse.y = x1 * 10, y1 * 10
        frame()
        mouse.down = false
        frame()
    end
    drag(0, 0, side, 2)
    adds = countCmd("adminAddZone")
    local _, kb = frame()
    check(pool["big#1"]:isVisible() and pool["big#1"].text == tr("IGUI_MSH_Zone_TooBig", side)
        and pool["shape#1"].color == colors.errorText and not pool.save.enabled and kb["0,0"] == ERR,
        "外框 " .. (side + 1) .. " 格：寫上限、範圍行與地上的範圍變錯誤色、儲存停用")
    check(not Z.save(zm, "x") and countCmd("adminAddZone") == adds, "（直接呼叫）超過上限：不送")
    Z.undo(zm)
    drag(0, 0, side - 1, 2)
    check(not pool["big#1"]:isVisible() and pool.save.enabled,
        "剛好 " .. side .. " 格：可以儲存")
    Z.setTool(zm, Sel.WALK)
    Z.clear(zm)
    check(pool.mark:isVisible() and pool.mark.style == "primary" and pool.save.style == "normal",
        "走位、範圍空著：〔設第一角〕是唯一的主要按鈕")
    local realCore = getCore
    local h0 = v.win:getHeight()
    getCore = function() return { getScreenWidth = function() return 1280 end, getScreenHeight = function() return h0 + 50 end } end
    v.win:setY(120)
    Z.layout(v)
    check(v.win:getY() == 50 and v.win:getHeight() == h0, "畫面太矮、底邊超出：視窗往上推到底邊貼齊畫面，內容不縮")
    v.win:setY(30)
    Z.layout(v)
    check(v.win:getY() == 30, "放得下：留在使用者拖到的位置")
    getCore = realCore

    T.section("禁建區面板與建立面板一次只開一個")
    local DEED2 = "MinidoracatSafehouse.Deed2"
    local cm = CP.open({ deedType = DEED2 })
    check(cm ~= nil and CP.model == cm and zm.closed and Z.model == nil and ZL.model ~= nil and not P.win:isVisible(),
        "開建立面板：禁建區面板關掉（從禁建區視窗開的就開回禁建區視窗）")
    m = ZL.model
    answer("adminZones", { zones = { MALL, FARM }, max = 100, unreadable = false })
    local zm2 = Z.open({ zones = { FARM } })
    check(zm2 ~= nil and Z.model == zm2 and cm.closed and CP.model == nil and managerOpened == 0,
        "開禁建區面板：建立面板關掉（不是從管理視窗開的，不開管理視窗）")
    local reopened = ZL.model
    Z.close(zm2)
    check(ZL.model == reopened and not P.win:isVisible(), "（直接開的）禁建區面板關掉：不另外開視窗")

    T.section("禁建區視窗關掉才開回管理員面板")
    ZL.frame(m.view)
    m.selected = 4
    ZL.frame(m.view)
    check(next(FT.cells.zones) ~= nil and next(FT.cells.zoneSel) ~= nil, "（前置）地上畫著禁建區與選中的那個")
    AP.select(P, "rules")
    m.view.win:close()
    check(m.closed and ZL.model == nil and P.win:isVisible() and P.current == "exclusions",
        "按〔×〕關禁建區視窗：開回管理員面板排除頁")
    check(next(FT.cells.zones) == nil and next(FT.cells.zoneSel) == nil and next((tw.overlay(0))) == nil and next((tw.lit(0))) == nil,
        "關窗：zones、zoneSel 兩層都清空，地上什麼都不畫")
    local realBuild = ZL.build
    ZL.build = function() error("boom") end
    AP.select(P, "rules")
    AP.onZoneManage(P)
    ZL.build = realBuild
    check(ZL.model == nil and P.win:isVisible() and P.current == "exclusions",
        "禁建區視窗開不成（建窗出錯）：不丟錯，管理員面板馬上開回排除頁")

    T.section("建立面板：預檢壓到禁建區")
    local vm = CP.open({ deedType = DEED2 })
    local cv = vm.view
    check(CP.startSelect(vm, Sel.WALK), "（前置）走位框選")
    boss.x, boss.y = 6.5, 6.5
    Sel.mark(vm.sel, boss)
    boss.x, boss.y = 9.5, 9.5
    CP.finish(vm, T.now)
    T.tick(7)
    local pv = lastCmd("preview")
    check(pv ~= nil and pv.args.rects[1].x == 6 and pv.args.rects[1].w == 4, "（前置）送預檢")
    answer("preview", { pass = false, checks = { { name = "identity", ok = true },
        { name = "zones", ok = false, code = "NO_BUILD", zoneId = 1, zone = "Mall", areas = { 6, 6, 2, 2 } } } })
    local line, tok = nil, nil
    for _, l in ipairs(cv.lines) do
        if has(l.text, tr("IGUI_MSH_Create_Check_zones")) then line, tok = l.text, l.token end
    end
    check(line == tr("IGUI_MSH_Create_CheckFail", tr("IGUI_MSH_Create_Check_zones"), tr("IGUI_MSH_Code_NO_BUILD", "Mall"))
        and tok == "errorText",
        "沒過的項目標籤是「禁建區」，原因寫出名稱")
    CP.View.frame(cv)
    local _, kz = tw.lit(0)
    check(kz["6,6"] == ERR and kz["7,7"] == ERR and kz["8,8"] == OK and kz["9,9"] == OK,
        "壓到禁建區的部分（areas）標紅，其餘照範圍的顏色")
    CP.close(vm)

    T.section("框架不合時不開、不丟錯")
    fw.caps.dialog = nil
    MSH.Client._theme = nil
    AP.layoutPage(P, "exclusions")
    local zlOpen, zlGot = pcall(ZL.open, { fromAdmin = true })
    check(not ZL.available() and not ex.zmanage.enabled and ex["zblock#1"].text == tr("IGUI_MSH_Create_NeedFramework")
        and zlOpen and zlGot == nil and ZL.model == nil, "缺 dialog：禁建區視窗不開，管理員面板的〔管理禁建區〕停用並寫原因")
    fw.caps.dialog = true
    fw.caps.focus = nil
    MSH.Client._theme = nil
    local zl = ZL.open({})
    answer("adminZones", { zones = { MALL }, max = 100, unreadable = false })
    local okOpen, got = pcall(Z.open, { zones = {} })
    check(zl ~= nil and not zl.view.flow.pool.zadd.enabled and zl.view.flow.pool["block#1"].text == tr("IGUI_MSH_Create_NeedFramework")
        and okOpen and got == nil and Z.model == nil, "缺 focus：禁建區視窗照開，〔新增禁建區〕停用並寫原因；禁建區面板不開")
    ZL.close(zl)
    fw.caps.focus = true
    Z.open = realOpen
    boss.getRole = realRole
    Capability.TeleportToCoordinates = nil
    AP.instance = nil
    tw.restore()
    MSH.Client._theme = nil
    for _, k in ipairs(G) do _G[k] = saved[k] end
end
