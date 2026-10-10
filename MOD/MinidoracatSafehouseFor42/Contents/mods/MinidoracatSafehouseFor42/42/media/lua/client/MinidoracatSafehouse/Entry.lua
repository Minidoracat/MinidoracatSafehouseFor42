-- MinidoracatSafehouse/Entry.lua：客戶端入口與原版 cutover（M3；計畫 §10.2、§10.8）。
--   User Panel 永遠多一顆量過寬度的「安全屋管理」→ 管理視窗；條件不讀 SafeHouse.hasSafehouse（沒有安全屋也要能開 empty state）。
--   原版安全屋視窗（User Panel SAFEHOUSEPANEL、世界右鍵「檢視安全屋」、管理員安全屋清單〔檢視〕）遇到 managed house
--   （owner＝@MSH:<id>）改開管理視窗並選中那間；原版「建立安全屋」右鍵選項一律拿掉，管理員區域編輯器對 managed house 的
--   改名／移交／放棄／成員／離開／重生控制項隱藏。這些只讓誠實玩家不誤觸 anti-cheat（decisions.md「原版安全屋封包」），
--   惡意封包靠伺服器收斂（§2、§6.3）。
--   家族工具列 Dock（id safehouse、order 60：UI repo ARCHITECTURE §3.16 登記）；地契物品說明（§10.8）。
-- 原版掛鉤全部在 OnGameStart 才裝（檔案載入時不碰原版 UI 類別與框架；harness 的 bootClient 也會載入本檔）。
-- 包裝一律只裝一次（E.installed），包裝裡經 MSH.Entry 轉呼叫，熱重載本檔換掉的是實作、不會疊一層包裝。

if not isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Settings"
require "MinidoracatSafehouse/Client"

local MSH = MinidoracatSafehouse
local first = MSH.Entry == nil
local E = MSH.Entry or {}
MSH.Entry = E

E.DOCK_ORDER = 60                -- UI repo ARCHITECTURE §3.16（VehicleCapsule 50 之後、DevProfiler 90 之前）
E.DOCK_MIN_REV = 13              -- Dock 在框架 rev 13 加入（ARCHITECTURE §2）
E.TIP_TTL_MS = 1000              -- 地契說明快取：sandboxSync 改值後最多 1 秒反映，不每幀重讀整份設定
E.attention = E.attention or 0   -- 我的安全屋裡狀態不是「已保護」的間數（Dock 徽章）
E.tip = E.tip or { tier = nil, at = nil, lines = nil }

-- ===== 共用 =====

-- managed 原生安全屋的 claimId；不是 managed、或根本不是安全屋物件（沒有 getOwner）回 nil。
-- SafeHouse.getOwner：SafeHouse.java:656。Kahlua 索引不存在的方法回 nil、不丟錯（Cleaner MinidoracatCleaner_Tooltip.lua:53-54）
function E.managedId(house)
    if house == nil or house.getOwner == nil then return nil end
    return MSH.claimIdOf(house:getOwner())
end

-- 管理視窗模組沒載入（載入失敗）時只記 log，不讓原版按鈕丟錯
function E.openManager(claimId)
    local W = MSH.ManagerWindow
    if W == nil or W.open == nil then
        MSH.log("Entry: ManagerWindow unavailable")
        return
    end
    if claimId == nil then W.open({}) else W.open({ claimId = claimId }) end
end

-- ===== User Panel「安全屋管理」=====
local GAP = 10 -- ISUserPanelUI.lua:7 UI_BORDER_SPACING

function E.onPanelButton()
    E.openManager(nil)
end

-- 原版 ISUserPanelUI:create（ISUserPanelUI.lua:24-109）建完後插在〔關閉〕上方：關閉鈕往下移一列、面板加高。
-- 按鈕寬照標題量測（MeasureStringX，同檔 :25）；比既有按鈕寬時全部子元件一起加寬，照同檔 :91-99 的做法。
-- ISButton:new(x, y, w, h, title, target, onclick)：ISButton.lua:479。
function E.addPanelButton(panel)
    local cancel = panel.cancel
    if cancel == nil or panel.mshButton ~= nil then return end
    local title = getText("IGUI_MSH_Entry_Button")
    local h = cancel:getHeight()
    local w = math.max(cancel:getWidth(), getTextManager():MeasureStringX(UIFont.Small, title) + GAP * 2)
    local btn = ISButton:new(cancel:getX(), cancel:getY(), w, h, title, panel, E.onPanelButton)
    btn:initialise()
    btn:instantiate()
    btn.borderColor = panel.buttonBorderColor
    panel:addChild(btn)
    panel.mshButton = btn
    if w > cancel:getWidth() then
        for _, child in pairs(panel:getChildren()) do child:setWidth(w) end
        panel:setWidth(GAP * 2 + 2 + w)
    end
    cancel:setY(cancel:getY() + h + GAP)
    panel:setHeight(panel:getHeight() + h + GAP)
end

-- ===== 原版安全屋視窗 → 管理視窗 =====
-- 三個原版入口都是 ISSafehouseUI:new → initialise → addToUIManager：User Panel ISUserPanelUI.lua:138-145、
-- 世界右鍵 ISWorldObjectContextMenu.lua:526-531（選項由 ISWorldObjectContextMenuLogic.java:1002-1015 加）、
-- 管理員清單 ISSafehousesList.lua:104-109。攔 addToUIManager 是唯一共同點：managed 就不上畫面、改開管理視窗。
-- new 已把 ISSafehouseUI.instance 指向這個不會出現的面板（ISSafehouseUI.lua:380），清掉免得 OnSafehousesChanged 操作它。
function E.safehouseUIAdd(ui, original)
    local id = E.managedId(ui.safehouse)
    if id == nil then return original(ui) end
    if ISSafehouseUI.instance == ui then ISSafehouseUI.instance = nil end
    E.openManager(id)
end

-- 管理員區域編輯器的安全屋細節（MultiplayerZoneEditorMode_Safehouse.lua:200-560）：prerender 對管理員把放棄、移交設回可見
-- （:385-386），render→updateButtons 再設一次（:360-361、:409-410）；子元件畫在 Lua prerender 與 render 之間
-- （UIElement.java:1616-1631），所以兩處之後都要藏：畫面上看不到，兩幀之間處理滑鼠時也點不到。
-- 具 CanSetupSafehouses 的連線原版封包直接放行（decisions.md「AntiCheatSafeHouseOwner.java:13-14」），對本 MOD 全是 drift。
E.VANILLA_CONTROLS = { "changeTitle", "changeOwnership", "releaseSafehouse", "addPlayer", "removePlayer", "quitSafehouse", "respawn" }
function E.hideManagedControls(panel)
    if E.managedId(panel.safehouse) == nil then return end
    local names = E.VANILLA_CONTROLS
    for i = 1, #names do
        local c = panel[names[i]]
        if c ~= nil then c:setVisible(false) end
    end
end

-- 原版「建立安全屋」右鍵選項（ISWorldObjectContextMenuLogic.java:1024-1046）一律拿掉：本 MOD 要求 PlayerSafehouse=false
-- （計畫 §5），原版建立封包在伺服器沒有 Lua 掛鉤（decisions.md），地契、名額、道路規則都管不到。
-- 事件在 Java 建完選項後觸發（ISWorldObjectContextMenu.lua:209-214）；removeOptionByName：ISContextMenu.lua:1016。
function E.onFillWorldMenu(_, context, _, test)
    if test or context == nil then return end
    context:removeOptionByName(getText("ContextMenu_SafehouseClaim"))
end

-- ===== Dock（框架 rev 13；ARCHITECTURE §3.16）=====
-- 回呼每幀在 pcall 裡被呼叫：不建 table、不組字串（徽章文字在清單更新時組好）。
E.dockSpec = {
    id = "safehouse",
    order = E.DOCK_ORDER,
    iconKey = "house",
    label = function() return getText("IGUI_MSH_Entry_Button") end,
    onClick = function() MSH.Entry.openManager(nil) end,
    getBadge = function() return MSH.Entry.attention end,
    getStatus = function() return MSH.Entry.attentionText end,
}

-- 沒有 dock capability 或登記失敗：入口仍是 User Panel 按鈕，不另建浮鈕
function E.registerDock()
    local UI = MSH.Client.ui({ "dock" }, E.DOCK_MIN_REV)
    E.docked = UI ~= nil and UI.Dock ~= nil and UI.Dock.register(E.dockSpec) == true
    return E.docked
end

-- 清單更新（Client.lua claims 事件）時算徽章：我的安全屋中狀態不是「已保護」的（租約停用、修復暫停、成員同步受干擾…，§10.3）
function E.onClaims(claims)
    local n = 0
    for _, row in ipairs(claims.mine or {}) do
        if row.healthSummary ~= nil and row.healthSummary ~= "PROTECTED" then n = n + 1 end
    end
    E.attention = n
    if n > 0 then E.attentionText = getText("IGUI_MSH_Entry_Attention", tostring(n)) else E.attentionText = nil end
end

-- ===== 地契物品說明（§10.8）=====
-- 每行 { 文字, 是否警告色 }。大小照伺服器實際套用的上限（Settings.sizeLimit 含硬上限）；
-- getText 的數字參數先轉字串（pz-family-docs conventions.md「帶參 getText」）。
function E.deedLines(cfg, tier)
    local t = cfg.tiers[tier]
    if t == nil then return nil end
    local side, area = MSH.Settings.sizeLimit(cfg, MSH.SOURCE.DEED, tier)
    local lines = {
        { getText("IGUI_MSH_Deed_MaxSide", tostring(math.floor(side))), false },
        { getText("IGUI_MSH_Deed_MaxArea", tostring(math.floor(area))), false },
    }
    if t.enabled then
        lines[3] = { getText("IGUI_MSH_Deed_Enabled"), false }
    else
        lines[3] = { getText("IGUI_MSH_Deed_Disabled"), true }
    end
    return lines
end

-- self.item 不一定是物品（ISEnergyBar／ISFluidBar 也用 ISToolTipInv，ISToolTipInv.lua:187 原樣存入）：只認有 getFullType 的。
-- 等級只由 full type 決定（Contract tierOfDeed）。同一級 1 秒內重用同一份行陣列（render 每幀呼叫）。
function E.tipLines(item)
    if item == nil or item.getFullType == nil then return nil end
    local tier = MSH.tierOfDeed(item:getFullType())
    if tier == nil then return nil end
    local tip, now = E.tip, getTimestampMs()
    if tip.tier ~= tier or tip.at == nil or now - tip.at >= E.TIP_TTL_MS then
        tip.tier, tip.at, tip.lines = tier, now, E.deedLines(MSH.Settings.get(), tier)
    end
    return tip.lines
end

-- 疊法照家族地圖錶 MinidoracatWatch_Hud.lua:156-219（Cleaner MinidoracatCleaner_Tooltip.lua:174-187 同）：先讓下游
-- （原版與先包的 MOD）畫完，暫時攔 self 實例的 drawRect／drawRectBorder 量它畫到哪，再把自己的框貼在最底下。
-- 量測用模組層級的轉送函式加狀態表，不每幀建 closure。實例欄位要用 pairs 找（Kahlua rawget 會查 metatable，Watch :158）。
local PAD = 5
local measure = { bottom = nil, rect = nil, border = nil }

local function track(y, w, h)
    if w > 0 and h > 0 and (measure.bottom == nil or y + h > measure.bottom) then measure.bottom = y + h end
end
local function trackRect(ui, x, y, w, h, a, r, g, b)
    track(y, w, h)
    return measure.rect(ui, x, y, w, h, a, r, g, b)
end
local function trackBorder(ui, x, y, w, h, a, r, g, b)
    track(y, w, h)
    return measure.border(ui, x, y, w, h, a, r, g, b)
end

local function ownSlots(self)
    local rect, border
    for k, v in pairs(self) do
        if k == "drawRect" then rect = v elseif k == "drawRectBorder" then border = v end
    end
    return rect, border
end

-- 回傳下游畫到的最底 y；nil＝這一幀沒畫（右鍵選單開著時原版整段跳過，ISToolTipInv.lua:45）
function E.renderMeasured(self, original)
    local ownRect, ownBorder = ownSlots(self)
    measure.bottom, measure.rect, measure.border = nil, self.drawRect, self.drawRectBorder
    rawset(self, "drawRect", trackRect)
    rawset(self, "drawRectBorder", trackBorder)
    local ok, err, trace = pcall(original, self)
    rawset(self, "drawRect", ownRect)
    rawset(self, "drawRectBorder", ownBorder)
    if not ok then error(err, trace) end -- Kahlua：第二參數是 stacktrace（BaseLib.java:250-256，Watch :185）
    return measure.bottom
end

-- 框貼在下游最底下；超出螢幕底改貼上方，上方也放不下就不畫（貼的框不參與原版的螢幕夾取 ISToolTipInv.lua:76-81）。
-- ObjectTooltip.getFont：ObjectTooltip.java:67。
function E.appendBox(self, lines, bottom)
    local tm = getTextManager()
    local font = self.tooltip:getFont()
    local lineH = tm:getFontHeight(font)
    local h = PAD * 2 + lineH * #lines
    local w = self.width
    for i = 1, #lines do w = math.max(w, PAD * 2 + tm:MeasureStringX(font, lines[i][1])) end
    local y = bottom - 1
    if self.y + y + h > getCore():getScreenHeight() then
        if self.y - h < 0 then return end
        y = -h + 1
    end
    local bg, bd = self.backgroundColor, self.borderColor
    self:drawRect(0, y, w, h, math.min(1, bg.a + 0.4), bg.r, bg.g, bg.b)
    self:drawRectBorder(0, y, w, h, bd.a, bd.r, bd.g, bd.b)
    local warn = MSH.Client.WARNING
    for i = 1, #lines do
        local ty = y + PAD + (i - 1) * lineH
        if lines[i][2] then
            self:drawText(lines[i][1], PAD, ty, warn.r, warn.g, warn.b, 1, font)
        else
            self:drawText(lines[i][1], PAD, ty, 0.8, 0.8, 0.8, 1, font)
        end
    end
end

function E.renderTooltip(self, original)
    local lines = E.tipLines(self.item)
    if lines == nil then return original(self) end
    local bottom = E.renderMeasured(self, original)
    if bottom then E.appendBox(self, lines, bottom) end
end

-- ===== 安裝（OnGameStart：晚於所有 MOD 的檔案頂層，照地圖錶 MinidoracatWatch_Hud.lua:222 的查證；
-- 地契說明因此包在最外層、畫在最下面，計畫 §10.8 deeds-ui-sp 實測）=====
function E.install()
    if E.installed then return end
    E.installed = true
    if ISUserPanelUI then
        local create = ISUserPanelUI.create -- ISUserPanelUI.lua:24；initialise 內呼叫（:10-13）
        function ISUserPanelUI:create()
            create(self)
            MSH.Entry.addPanelButton(self)
        end
    end
    if ISSafehouseUI then
        local add = ISSafehouseUI.addToUIManager -- 繼承自 ISUIElement.lua:1365
        function ISSafehouseUI:addToUIManager()
            return MSH.Entry.safehouseUIAdd(self, add)
        end
    end
    local Details = MultiplayerZoneEditorMode_Safehouse_Details
    if Details then
        local prerender, render = Details.prerender, Details.render
        function Details:prerender()
            prerender(self)
            MSH.Entry.hideManagedControls(self)
        end
        function Details:render()
            render(self)
            MSH.Entry.hideManagedControls(self)
        end
    end
    if ISToolTipInv then
        local tooltip = ISToolTipInv.render -- ISToolTipInv.lua:43；OnGameStart 時可能已被其他 MOD 包過
        function ISToolTipInv:render()
            return MSH.Entry.renderTooltip(self, tooltip)
        end
    end
    E.registerDock()
end

if first then
    MSH.Client.on("claims", "entry", function(claims) MSH.Entry.onClaims(claims) end)
    Events.OnGameStart.Add(function() MSH.Entry.install() end)
    Events.OnFillWorldObjectContextMenu.Add(function(p, ctx, wo, test) MSH.Entry.onFillWorldMenu(p, ctx, wo, test) end)
end
