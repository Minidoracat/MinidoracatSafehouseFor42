-- MinidoracatSafehouse/ZonePanel.lua：新增禁建區（管理員）。禁建區視窗〔新增禁建區〕開（ZoneList.onAdd：先收起那個視窗，
--   這裡關掉時呼叫 opts.onClosed 開回去）；框選照建立面板的框選階段（Select.lua／Shape.lua：拖曳或走到兩角、加入／挖掉、復原、
--   清除；塊數用硬上限 LIMIT.MAX_PIECES，外框 ≤ LIMIT.ZONE_SIDE），〔儲存禁建區〕送 adminAddZone { name, rects }
--   （伺服器照同一套形狀規則再驗、存檔，Zones.lua）。成功就關窗；失敗在面板上寫原因、範圍保留。
-- 開著時地上畫既有的禁建區（FloorTint 圖層 "zones"，Ranges.COLORS.zones 亮紅疊色，禁建區視窗、地面範圍同一個顏色），新框的範圍照
--   Select.draw（青色）蓋在上面。
-- 和建立面板共用 "shape"／"pending" 圖層與 OnMouseDown，一次只開一個（兩邊開的時候都先關掉另一個）。
-- 框架不合（window／controls／focus）時不開（Z.available；禁建區視窗的〔新增禁建區〕停用並寫原因），不報錯。
-- 檔案載入時不碰 ISPanel、框架或玩家（harness T.bootClient 會載入本檔）。

if not isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Client"
require "MinidoracatSafehouse/Select"
require "MinidoracatSafehouse/FloorTint"
require "MinidoracatSafehouse/Ranges"
require "MinidoracatSafehouse/SlotsWindow"
require "MinidoracatSafehouse/CreatePanel"
require "MinidoracatSafehouse/AdminPanel"

local MSH = MinidoracatSafehouse
local first = MSH.ZonePanel == nil
local Z = MSH.ZonePanel or {}
MSH.ZonePanel = Z

local K = MSH.SlotsWindow.kit
local Sel = MSH.Select
local CODE = MSH.CODE
local LIMIT = MSH.LIMIT

Z.CAPS = { "window", "controls", "focus" }
-- 既有禁建區的顏色是 Ranges.COLORS.zones（亮紅疊色，來由寫在 Ranges.lua）；新框的各塊（Select.PIECE_TINT）照樣蓋在上面
Z.ZONE_ALPHAS = { 1.0 }
Z.W = 440

local function player()
    return getSpecificPlayer(0)   -- 只有 0 號玩家有身分（Client.send）
end

local function changed(m)
    if m.onChange ~= nil then m.onChange(m) end
end

-- ===== 狀態（不碰畫面，harness t_ui_zones 直接測）=====
-- m = { zones（開窗時的清單）, flat（既有禁建區的扁平 x, y, w, h, ...）, sel, defaultName, onClosed（關窗時呼叫）,
--       busy（nil | "saving" | "waiting"：10 秒沒回覆 | "unknown"：伺服器快取過期）, err, errDetail, rid, closed }

function Z.available()
    return MSH.Client.ui(Z.CAPS) ~= nil
end

function Z.flatZones(zones)
    local out = {}
    for _, z in ipairs(zones) do
        for _, r in ipairs(type(z.rects) == "table" and z.rects or {}) do
            if MSH.isInt(r.x) and MSH.isInt(r.y) and MSH.isInt(r.w) and MSH.isInt(r.h) then
                local n = #out
                out[n + 1], out[n + 2], out[n + 3], out[n + 4] = r.x, r.y, r.w, r.h
            end
        end
    end
    return out
end

-- opts = { zones = 目前的禁建區清單（adminZones）, onClosed = 關窗時呼叫（禁建區視窗用它開回自己） }
function Z.newModel(opts)
    local zones = type(opts.zones) == "table" and opts.zones or {}
    local CP = MSH.CreatePanel
    local tool = CP ~= nil and CP.defaultTool() or Sel.DRAG
    return { zones = zones, flat = Z.flatZones(zones), onClosed = type(opts.onClosed) == "function" and opts.onClosed or nil,
        sel = Sel.new(tool, 0, nil, LIMIT.MAX_PIECES),
        defaultName = getText("IGUI_MSH_Zone_DefaultName", tostring(#zones + 1)) }
end

-- 形狀結果與是否超過外框上限
function Z.status(m)
    local res = Sel.result(m.sel)
    return res, res.err ~= "EMPTY" and (res.w > LIMIT.ZONE_SIDE or res.h > LIMIT.ZONE_SIDE)
end

function Z.setTool(m, tool)
    Sel.setTool(m.sel, tool)
    changed(m)
end

function Z.setCut(m, cut)
    Sel.setCut(m.sel, cut)
    changed(m)
end

function Z.mark(m)
    local ok = Sel.mark(m.sel, player())
    changed(m)
    return ok
end

-- 〔加入這塊〕／〔挖掉這塊〕（走位、手把）
function Z.applyPiece(m)
    Sel.update(m.sel, player())
    local ok = Sel.commit(m.sel)
    changed(m)
    return ok
end

function Z.undo(m)
    local ok = Sel.undo(m.sel)
    changed(m)
    return ok
end

function Z.clear(m)
    local ok = Sel.clear(m.sel)
    changed(m)
    return ok
end

-- 〔儲存禁建區〕：走位／手把還沒按〔加入這塊〕的那塊也算進去；形狀有錯、超過外框上限或名稱不合法就不送。
-- 名稱空白＝預設名稱；其餘照 MSH.cleanTitle（伺服器同一套，BAD_TITLE）
function Z.save(m, text)
    if m.closed or m.busy ~= nil then return false end
    Sel.update(m.sel, player())
    Sel.commit(m.sel)
    m.err, m.errDetail = nil, nil
    local res, over = Z.status(m)
    if res.err ~= nil or over then
        changed(m)
        return false
    end
    local name = MSH.trim(text or "")
    name = MSH.cleanTitle(name ~= "" and name or m.defaultName)
    if name == nil then
        m.err = CODE.BAD_TITLE
        changed(m)
        return false
    end
    m.busy = "saving"
    m.rid = MSH.Client.send("adminAddZone", { name = name, rects = MSH.Rect.copyList(res.rects) },
        function(r) Z.onSaved(m, r) end, { mutation = true })
    if m.rid == nil then m.busy, m.err = nil, "OFFLINE" end
    changed(m)
    return m.rid ~= nil
end

-- 10 秒沒回覆先寫等候中（真結果可能晚到）；伺服器快取過期就是結果未知，不再讓這個面板重送（可能已經存了，重送會多一個）
function Z.onSaved(m, res)
    if m.closed then
        -- 等候中關了窗：晚到的成功讓開著的禁建區視窗（清單）與管理員面板（個數）重抓
        if not res.ok then return end
        local ZL, AP = MSH.ZoneList, MSH.AdminPanel
        if ZL ~= nil and ZL.model ~= nil then ZL.load(ZL.model) end
        if AP ~= nil and AP.visible(AP.instance) then AP.loadZones(AP.instance) end
        return
    end
    if res.code == "NO_REPLY" then
        m.busy = res.expired and "unknown" or "waiting"
        changed(m)
        return
    end
    if res.ok then return Z.close(m) end
    m.busy, m.err, m.errDetail = nil, res.code, res
    changed(m)
end

function Z.errorText(m)
    local d = type(m.errDetail) == "table" and m.errDetail or {}
    if m.err == CODE.BAD_ARGS and d.reason == "FULL" then
        return getText("IGUI_MSH_Admin_ZonesFull", tostring(d.max or LIMIT.MAX_ZONES))
    end
    local reason, action = MSH.CreatePanel.reasonOf(m.err, d)
    return action and (reason .. " " .. action) or reason
end

-- ===== 畫面 =====

local FONT = UIFont and UIFont.Small

-- 一次只有一顆主要按鈕（client-ui.md）：走位或手把拉到一半、或範圍還空著時是〔設第一角〕／〔加入這塊〕，其餘是〔儲存禁建區〕
function Z.layout(v)
    local m, F = v.m, v.flow
    if v.win == nil then return end
    local s = m.sel
    local joy = s.tool == Sel.DRAG and Sel.usingJoypad(s)
    local pending = s.ax ~= nil
    v.corner, v.joy = pending, joy
    F:begin(v.w)
    F:text("hint", getText("IGUI_MSH_Zone_Hint"), "textMuted")
    local drag = F:button("drag", getText("IGUI_MSH_Select_Drag"), m, function() Z.setTool(m, Sel.DRAG) end, "chip")
    local walk = F:button("walk", getText("IGUI_MSH_Select_Walk"), m, function() Z.setTool(m, Sel.WALK) end, "chip")
    drag:setActive(s.tool == Sel.DRAG)
    walk:setActive(s.tool == Sel.WALK)
    F:row({ drag, walk })
    local hint = "IGUI_MSH_Select_DragHint"
    if s.tool == Sel.WALK then hint = "IGUI_MSH_Select_WalkHint" elseif joy then hint = "IGUI_MSH_Select_DragHintJoypad" end
    F:text("toolHint", getText(hint), "textMuted")
    local res, over = Z.status(m)
    local bad = res.err ~= nil and res.err ~= "EMPTY"
    v.over = over
    if res.err ~= "EMPTY" then
        local text = res.rects ~= nil and getText("IGUI_MSH_Select_Shape", res.w, res.h, res.area, #res.rects)
            or getText("IGUI_MSH_Select_ShapeRaw", res.w, res.h, res.area)
        F:text("shape", text, (bad or over) and "errorText" or "text")
    end
    F:text("limit", getText("IGUI_MSH_Select_PieceLimit", s.shape.max), "textMuted")
    if over then F:text("big", getText("IGUI_MSH_Zone_TooBig", LIMIT.ZONE_SIDE), "errorText") end
    if bad then F:text("err", getText("IGUI_MSH_Select_Err_" .. res.err, s.shape.max), "errorText") end
    -- 拉到一半那塊的大小：每幀在 Z.frame 改字（變了才改）
    local size = F:label("size", "", "text")
    size:setX(K.PAD)
    size:setY(F.y)
    v.size, v.sizeW, v.sizeH = size, nil, nil
    F.y = F.y + size.height + K.GAP
    local add = F:button("add", getText("IGUI_MSH_Select_Add"), m, function() Z.setCut(m, false) end, "chip")
    local cut = F:button("cut", getText("IGUI_MSH_Select_Cut"), m, function() Z.setCut(m, true) end, "chip")
    add:setActive(not s.cut)
    cut:setActive(s.cut)
    cut:setEnabled(not Sel.isEmpty(s))
    F:row({ add, cut })
    F:text("nameLabel", getText("IGUI_MSH_Zone_Name"), "text")
    local UI, theme = v.UI, v.theme
    local field = F:get("name", function()
        return UI.TextField.new({ x = 0, y = 0, width = v.w - 2 * K.PAD, theme = theme, text = m.defaultName,
            placeholder = m.defaultName, maxLength = LIMIT.TITLE_CHARS })
    end)
    field:setX(K.PAD)
    field:setY(F.y)
    v.field = field
    F.y = F.y + field.height + K.GAP
    if m.err ~= nil then F:text("fail", Z.errorText(m), "errorText") end
    if m.busy == "saving" then
        F:text("busy", getText("IGUI_MSH_Create_Waiting"), "textMuted")
    elseif m.busy == "waiting" then
        F:text("busy", getText("IGUI_MSH_Admin_Waiting"), "warning")
    elseif m.busy == "unknown" then
        F:text("busy", getText("IGUI_MSH_Admin_Unknown"), "warning")
    end
    local list = {}
    local step = nil
    if s.tool == Sel.WALK or joy then
        if pending then
            step = F:button("apply", getText(s.cut and "IGUI_MSH_Select_ApplyCut" or "IGUI_MSH_Select_ApplyAdd"), m,
                function() Z.applyPiece(m) end)
        else
            step = F:button("mark", getText("IGUI_MSH_Select_Mark"), m, function() Z.mark(m) end)
        end
        list[1] = step
    end
    local stepFirst = step ~= nil and (pending or Sel.isEmpty(s))
    if step ~= nil then step:setStyle(stepFirst and "primary" or "normal") end
    local save = F:button("save", getText("IGUI_MSH_Zone_Save"), m, function() Z.save(m, v.field:getText()) end)
    save:setStyle(stepFirst and "normal" or "primary")
    save:setEnabled(m.busy == nil and ((res.err == nil and not over) or pending))
    local undo = F:button("undo", getText("IGUI_MSH_Select_Undo"), m, function() Z.undo(m) end)
    undo:setEnabled(Sel.canUndo(s))
    local clear = F:button("clear", getText("IGUI_MSH_Select_Clear"), m, function() Z.clear(m) end)
    clear:setEnabled(not Sel.isEmpty(s))
    local cancel = F:button("cancel", getText("UI_Cancel"), m, function() Z.close(m) end)
    list[#list + 1] = save
    list[#list + 1] = undo
    list[#list + 1] = clear
    list[#list + 1] = cancel
    F:row(list)
    F:finish()
    v.body:setHeight(F.y)
    local h, sh = v.top + F.y, getCore():getScreenHeight()
    -- 內容長高、底邊超出畫面就往上推（不縮內容）；放得下就留在使用者拖到的位置
    if v.win:getY() + h > sh then v.win:setY(math.max(0, sh - h)) end
    v.win:setHeight(h)
    local Focus = UI.Focus
    if Focus ~= nil and Focus.invalidate ~= nil then Focus.invalidate(v.win) end
end

-- 每個 UI 幀（Body:prerender）：拖曳放開的套用與走位終點（形狀或模式變了才重排）、拉到一半那塊的大小、地上的既有禁建區
-- 與新框的範圍（FloorTint 只在變了時動地板）。不配置
function Z.frame(v)
    local m = v.m
    local p = player()
    if p == nil or m.closed then return end
    local s = m.sel
    if Sel.update(s, p) or (s.ax ~= nil) ~= v.corner or (s.tool == Sel.DRAG and Sel.usingJoypad(s)) ~= v.joy then
        Z.layout(v)
    end
    local _, _, w, h = Sel.bounds(s)
    if w ~= v.sizeW or h ~= v.sizeH then
        v.sizeW, v.sizeH = w, h
        local l = v.size
        l.text = w ~= nil and getText("IGUI_MSH_Select_Pending", w, h) or ""
        l:setWidth(K.textW(FONT, l.text))
    end
    v.tinted = true
    MSH.FloorTint.setRects("zones", m.flat, MSH.Ranges.COLORS.zones, Z.ZONE_ALPHAS, math.floor(p:getZ()))
    Sel.draw(s, p, Sel.FLOOR_OK, v.colors.errorText, v.over)
end

local function clearTint(v)
    if not v.tinted then return end
    v.tinted = false
    local Tint = MSH.FloorTint
    Tint.clear("shape")
    Tint.clear("pending")
    Tint.clear("zones")
end

local Body = nil   -- 第一次開窗才 derive（harness 載入時沒有 ISPanel）
local function bodyClass()
    if Body == nil then
        Body = ISPanel:derive("MinidoracatSafehouseZoneBody")
        function Body:prerender() Z.frame(self.view) end
    end
    return Body
end

-- 拖曳中的手把十字鍵屬於游標，按鈕改用 LB／RB 切換（同 CreatePanel hookInput）
local function joyDragging(m)
    return m.sel.tool == Sel.DRAG and Sel.usingJoypad(m.sel)
end

local function hookInput(v, win, m)
    local function dir(name, dx, dy)
        local base = win["onJoypadDir" .. name]
        win["onJoypadDir" .. name] = function(self, data)
            if joyDragging(m) then Sel.joyDir(m.sel, player(), dx, dy) else base(self, data) end
        end
    end
    dir("Up", 0, -1)
    dir("Down", 0, 1)
    dir("Left", -1, 0)
    dir("Right", 1, 0)
    local baseShoulder = win.onFocusShoulder
    win.onFocusShoulder = function(self, delta)
        if joyDragging(m) and v.UI.Focus ~= nil then v.UI.Focus.step(self, delta) else baseShoulder(self, delta) end
    end
    win.onEscape = function()
        Z.close(m)
        return true
    end
    win.onClose = function() Z.close(m) end
end

function Z.build(m, UI)
    local theme = MSH.Client.theme(UI)
    local sw = getCore():getScreenWidth()
    local w = math.min(Z.W, sw - 40)
    local v = { m = m, UI = UI, theme = theme, colors = theme.colors, w = w }
    -- 非 modal；放右側，框選時不擋住角色附近的地面（同建立面板）
    local win = UI.Window.new(MSH.Client.windowOpts(UI, { x = math.max(0, sw - w - 60), y = 120, width = w, height = 200,
        theme = theme, title = getText("IGUI_MSH_Zone_Title") }))
    v.win, v.top = win, win:contentTop()
    local body = bodyClass():new(0, v.top, w, 100)
    body.background = false
    body.view = v
    body:initialise()
    win:addChild(body)
    v.body = body
    v.flow = K.flow(body, UI, theme)
    hookInput(v, win, m)
    m.view = v
    m.onChange = function() Z.layout(v) end
    Z.layout(v)
    win:addToUIManager()
    return v
end

-- 關窗（儲存成功、取消、Esc、被建立面板取代）：收掉地上的三層、還原世界選單，最後呼叫 onClosed（禁建區視窗開回自己）
function Z.close(m)
    if m.closed then return end
    m.closed = true
    Sel.stop(m.sel)
    if Z.model == m then Z.model = nil end
    local v = m.view
    m.view, m.onChange = nil, nil
    if v ~= nil then
        clearTint(v)
        local win = v.win
        v.win = nil
        if win ~= nil then
            pcall(function()
                if win:getIsVisible() then win:close() end
                win:removeFromUIManager()
            end)
        end
    end
    local onClosed = m.onClosed
    m.onClosed = nil
    if onClosed ~= nil then
        local ok, err = pcall(onClosed)
        if not ok then MSH.log("zone panel onClosed failed: " .. tostring(err)) end
    end
end

local function openUnsafe(opts)
    if not MSH.AdminPanel.isAdmin() then return nil end
    local UI = MSH.Client.ui(Z.CAPS)
    if UI == nil then
        MSH.log("zone panel needs MinidoracatUI rev " .. tostring(MSH.Client.MIN_REV) .. " with window/controls/focus")
        return nil
    end
    local prev = Z.model
    if prev ~= nil then
        -- 一次一個：關掉時要做的事（開回禁建區視窗）交給新的這個
        opts.onClosed = opts.onClosed or prev.onClosed
        prev.onClosed = nil
        Z.close(prev)
    end
    local CP = MSH.CreatePanel
    if CP ~= nil and CP.model ~= nil then CP.close(CP.model) end
    local m = Z.newModel(opts)
    Z.model = m
    Z.build(m, UI)
    return m
end

-- 回 nil＝沒開成（不是管理員、框架不合、建窗失敗）：呼叫端自己開回原來的視窗（不呼叫 onClosed）
function Z.open(opts)
    local ok, res = pcall(openUnsafe, opts or {})
    if ok then return res end
    MSH.log("zone panel failed: " .. tostring(res))
    local m = Z.model
    if m ~= nil then
        m.onClosed = nil
        Z.close(m)   -- 半建好的視窗一起收掉
    end
    return nil
end

-- 地面上的左鍵（沒被任何視窗接走才會觸發，UIManager.java:715-719）：從這格開始拉
function Z.onWorldMouseDown()
    local m = Z.model
    if m ~= nil and not m.closed then Sel.mouseDown(m.sel, player()) end
end

if first then
    Events.OnMouseDown.Add(function() MSH.ZonePanel.onWorldMouseDown() end)
end
