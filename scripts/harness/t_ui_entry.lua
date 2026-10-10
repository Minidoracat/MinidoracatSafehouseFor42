-- 客戶端入口（Entry.lua，計畫 §10.2、§10.8）：managed 判定、原版安全屋視窗改開管理視窗、區域編輯器控制項隱藏、
-- 原版建立選項移除、User Panel 按鈕版面、Dock 登記與徽章、地契說明的內容與快取。
-- 原版 UI 類別與框架只在本情境用到，假物件放在本檔、結束時還原全域。
return function(T)
    local check = T.check
    local MSH = T.bootClient()
    local E = MSH.Entry
    T.player({ name = "alice" })

    local saved = { getText = getText, ISSafehouseUI = ISSafehouseUI, ISButton = ISButton, UIFont = UIFont,
        getTextManager = getTextManager, MinidoracatUI = MinidoracatUI }
    local opened = {}
    MSH.ManagerWindow = { open = function(opts) opened[#opened + 1] = opts end }

    T.section("Entry：managed 判定")
    local managed = T.house(100, 100, 10, 10, MSH.marker(7))
    local foreign = T.house(300, 300, 10, 10, "bob")
    check(E.managedId(managed) == 7, "owner 是 @MSH:<id> 的原生安全屋回 claimId")
    check(E.managedId(foreign) == nil and E.managedId(T.house(0, 0, 1, 1, "@MSH:x")) == nil, "foreign 與不合法標記回 nil")
    check(E.managedId(nil) == nil and E.managedId({}) == nil, "nil 或沒有 getOwner 的物件回 nil、不丟錯")

    T.section("Entry：原版安全屋視窗 → 管理視窗")
    ISSafehouseUI = {}
    local shown = {}
    local function original(ui) shown[#shown + 1] = ui end
    local ui = { safehouse = managed }
    ISSafehouseUI.instance = ui
    E.safehouseUIAdd(ui, original)
    check(#shown == 0 and #opened == 1 and opened[1].claimId == 7, "managed：不上原版視窗，改開管理視窗並選中那間")
    check(ISSafehouseUI.instance == nil, "清掉指向不會出現的原版面板的 instance")
    local vanilla = { safehouse = foreign }
    E.safehouseUIAdd(vanilla, original)
    check(#shown == 1 and shown[1] == vanilla and #opened == 1, "foreign：照原版開")
    MSH.ManagerWindow = nil
    E.safehouseUIAdd({ safehouse = managed }, original)
    local warned = false
    for _, line in ipairs(T.prints) do
        if string.find(line, "ManagerWindow unavailable", 1, true) then warned = true end
    end
    check(#shown == 1 and warned, "管理視窗模組不在：不開原版、記 log、不丟錯")
    MSH.ManagerWindow = { open = function(opts) opened[#opened + 1] = opts end }

    T.section("Entry：區域編輯器控制項")
    local function control()
        local c = { visible = true }
        function c:setVisible(v) self.visible = v end
        return c
    end
    local function details(house)
        local p = { safehouse = house }
        for _, n in ipairs(E.VANILLA_CONTROLS) do p[n] = control() end
        return p
    end
    local dm, df = details(managed), details(foreign)
    E.hideManagedControls(dm)
    E.hideManagedControls(df)
    local allHidden, noneHidden = true, true
    for _, n in ipairs(E.VANILLA_CONTROLS) do
        allHidden = allHidden and dm[n].visible == false
        noneHidden = noneHidden and df[n].visible == true
    end
    check(allHidden, "managed：改名／移交／放棄／成員／離開／重生全部隱藏")
    check(noneHidden, "foreign：原版控制項不動")
    E.hideManagedControls({ safehouse = nil })
    check(true, "沒選安全屋時不丟錯")

    T.section("Entry：原版建立選項")
    local removed = {}
    local ctx = { removeOptionByName = function(_, name) removed[#removed + 1] = name end }
    E.onFillWorldMenu(0, ctx, {}, false)
    check(#removed == 1 and removed[1] == "ContextMenu_SafehouseClaim", "世界右鍵拿掉原版「建立安全屋」")
    E.onFillWorldMenu(0, ctx, {}, true)
    check(#removed == 1, "test 模式不動選單")

    T.section("Entry：User Panel 按鈕")
    UIFont = { Small = "small" }
    local textW = 60
    getTextManager = function() return { MeasureStringX = function() return textW end } end
    local function element(x, y, w, h)
        local el = { x = x, y = y, width = w, height = h, children = {} }
        function el:getX() return self.x end
        function el:getY() return self.y end
        function el:getWidth() return self.width end
        function el:getHeight() return self.height end
        function el:setWidth(v) self.width = v end
        function el:setHeight(v) self.height = v end
        function el:setY(v) self.y = v end
        function el:initialise() end
        function el:instantiate() end
        function el:addChild(c) self.children[#self.children + 1] = c end
        function el:getChildren() return self.children end
        return el
    end
    ISButton = { new = function(_, x, y, w, h, title, target, onclick)
        local b = element(x, y, w, h)
        b.title, b.target, b.onclick = title, target, onclick
        return b
    end }
    local function panel()
        local p = element(0, 0, 202, 300)
        p.buttonBorderColor = {}
        local other = element(11, 100, 180, 22)
        p.cancel = element(11, 260, 180, 22)
        p:addChild(other)
        p:addChild(p.cancel)
        return p, other
    end
    local p = panel()
    E.addPanelButton(p)
    local btn = p.mshButton
    check(btn ~= nil and btn.y == 260 and p.cancel.y == 260 + 22 + 10 and p.height == 300 + 32,
        "按鈕插在〔關閉〕原位，關閉鈕下移一列、面板加高")
    check(btn.width == 180 and p.width == 202, "標題放得下時沿用既有按鈕寬")
    E.addPanelButton(p)
    check(#p.children == 3 and p.cancel.y == 292, "同一面板不重複加")
    local before = #opened
    btn.onclick(btn.target, btn)
    check(#opened == before + 1 and opened[#opened].claimId == nil, "按下開管理視窗（不指定安全屋，沒有時是 empty state）")
    textW = 300
    local wide, other = panel()
    E.addPanelButton(wide)
    check(wide.mshButton.width == 320 and other.width == 320 and wide.cancel.width == 320 and wide.width == 342,
        "標題比既有按鈕寬：量測後全部按鈕一起加寬、面板跟著變寬")

    T.section("Entry：Dock")
    local registered
    MinidoracatUI = { v1 = { API_MAJOR = 1, API_REVISION = 17, CAPABILITIES = { dock = true },
        Dock = { register = function(spec) registered = spec return true end } } }
    check(E.registerDock() == true and registered.id == "safehouse" and registered.order == 60,
        "有 dock capability：登記 id safehouse、order 60")
    registered.onClick()
    check(opened[#opened].claimId == nil, "Dock 按下開管理視窗")
    check(registered.getBadge() == 0 and registered.getStatus() == nil, "沒有需要處理的安全屋：沒有徽章與狀態")
    MSH.Client.emit("claims", { mine = {
        { claimId = 1, healthSummary = "PROTECTED" },
        { claimId = 2, healthSummary = "LAPSED" },
        { claimId = 3, healthSummary = "REPAIR_PAUSED" },
    }, shared = { { claimId = 4, healthSummary = "LAPSED" } } })
    check(registered.getBadge() == 2 and registered.getStatus() ~= nil, "徽章＝我的安全屋中不是「已保護」的間數（分享給我的不算）")
    MinidoracatUI.v1.CAPABILITIES.dock = nil
    check(E.registerDock() == false, "沒有 dock capability：不登記（User Panel 按鈕仍在）")
    MinidoracatUI.v1.CAPABILITIES.dock = true
    MinidoracatUI.v1.API_REVISION = 12
    check(E.registerDock() == false, "框架 rev 12（沒有 Dock）：不登記")

    T.section("Entry：地契說明")
    getText = function(key, a) if a ~= nil then return key .. "=" .. a end return key end
    local function texts(lines)
        local out = {}
        for i, l in ipairs(lines) do out[i] = l[1] .. (l[2] and "!" or "") end
        return table.concat(out, "|")
    end
    check(E.tipLines(nil) == nil and E.tipLines({ energy = 1 }) == nil, "不是物品（ISEnergyBar／ISFluidBar 的 item）：不加說明、不丟錯")
    check(E.tipLines(T.item("Base.Plank")) == nil and E.tipLines(T.item("MinidoracatSafehouse.Deed9")) == nil,
        "非地契與不存在的等級：不加說明")
    T.sandbox("Tier2Side", 30)
    T.sandbox("Tier2Area", 2000)
    local t2 = E.tipLines(T.item("MinidoracatSafehouse.Deed2"))
    check(t2 ~= nil and texts(t2) == "IGUI_MSH_Deed_MaxSide=30|IGUI_MSH_Deed_MaxArea=900|IGUI_MSH_Deed_Enabled",
        "啟用的等級：最大邊長、最大面積（面積夾到邊長平方，與伺服器套用的上限相同）")
    local t5 = E.tipLines(T.item("MinidoracatSafehouse.Deed5"))
    check(t5 ~= nil and texts(t5) == "IGUI_MSH_Deed_MaxSide=64|IGUI_MSH_Deed_MaxArea=4096|IGUI_MSH_Deed_Disabled!",
        "超過 TiersEnabled 的等級：寫「未啟用」並用警告色")
    T.sandbox("TiersEnabled", 5)
    check(E.tipLines(T.item("MinidoracatSafehouse.Deed5")) == t5, "同一級 1 秒內重用同一份（render 每幀不重讀設定）")
    T.advance(E.TIP_TTL_MS)
    check(texts(E.tipLines(T.item("MinidoracatSafehouse.Deed5"))) == "IGUI_MSH_Deed_MaxSide=64|IGUI_MSH_Deed_MaxArea=4096|IGUI_MSH_Deed_Enabled",
        "sandboxSync 改設定後 1 秒內反映")
    -- 原版 render 畫 0..50 的框（ISToolTipInv.lua:103-104）：說明框要貼在它下面，實例的 drawRect 用完要還原
    local Class = {}
    local draws = {}
    function Class:drawRect(x, y, w, h) draws[#draws + 1] = "rect:" .. y .. ":" .. h end
    function Class:drawRectBorder(x, y, w, h) draws[#draws + 1] = "border:" .. y end
    function Class:drawText(text, x, y, r, g, b) draws[#draws + 1] = "text:" .. text .. (r == MSH.Client.WARNING.r and g == MSH.Client.WARNING.g and "!" or "") end
    Class.__index = Class
    local function tooltipSelf(item)
        return setmetatable({ item = item, x = 10, y = 10, width = 100,
            backgroundColor = { r = 0, g = 0, b = 0, a = 0.5 }, borderColor = { r = 1, g = 1, b = 1, a = 1 },
            tooltip = { getFont = function() return "small" end } }, Class)
    end
    local function vanillaRender(self)
        self:drawRect(0, 0, self.width, 50)
        self:drawRectBorder(0, 0, self.width, 50)
    end
    getTextManager = function()
        return { MeasureStringX = function() return 40 end, getFontHeight = function() return 12 end }
    end
    local savedCore = getCore
    getCore = function() return { getScreenHeight = function() return 1080 end } end
    local deedTip = tooltipSelf(T.item("MinidoracatSafehouse.Deed2"))
    E.renderTooltip(deedTip, vanillaRender)
    check(draws[1] == "rect:0:50" and draws[3] == "rect:49:46" and draws[#draws] == "text:IGUI_MSH_Deed_Enabled",
        "地契：先畫原版，說明框貼在原版框最底下，三行都畫")
    check(rawget(deedTip, "drawRect") == nil and rawget(deedTip, "drawRectBorder") == nil, "量測完還原實例（不留攔截函式）")
    draws = {}
    E.renderTooltip(tooltipSelf(T.item("MinidoracatSafehouse.Deed8")), vanillaRender)
    check(draws[#draws] == "text:IGUI_MSH_Deed_Disabled!", "未啟用的等級用警告色")
    draws = {}
    E.renderTooltip(tooltipSelf(T.item("MinidoracatSafehouse.Deed2")), function() end)
    check(#draws == 0, "原版這一幀沒畫（右鍵選單開著）：說明也不畫")
    draws = {}
    E.renderTooltip(tooltipSelf({ energy = 1 }), vanillaRender)
    check(#draws == 2, "不是地契：只畫原版")
    getCore = savedCore

    for k, v in pairs(saved) do _G[k] = v end
    MSH.ManagerWindow = nil
end
