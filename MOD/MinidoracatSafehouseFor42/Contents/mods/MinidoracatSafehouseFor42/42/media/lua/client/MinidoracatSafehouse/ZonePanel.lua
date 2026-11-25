-- MinidoracatSafehouse/ZonePanel.lua：新增區域（管理員）。管理員區域視窗〔新增區域〕開（ZoneList.onAdd：先收起那個視窗，
--   這裡關掉時呼叫 opts.onClosed 開回去）；先選種類（禁建區／道路豁免區，預設禁建區），框選照建立面板的框選階段（Select.lua／
--   Shape.lua：拖曳或走到兩角、加入／挖掉、復原、清除；塊數用硬上限 LIMIT.MAX_PIECES，外框 ≤ LIMIT.ZONE_SIDE），〔儲存禁建區〕／
--   〔儲存道路豁免區〕送 adminAddZone { name, rects, kind }（伺服器照同一套形狀規則再驗、存檔，Zones.lua）。成功就關窗；失敗在
--   面板上寫原因、範圍保留（zones.json 有錯時伺服器回 SAVE_FAILED＋reason FILE，不覆寫手改的檔）。
-- 開著時地上畫既有的區域（FloorTint 圖層 "zones"＝禁建區，Ranges.COLORS.zones 亮紅疊色；"zonesExempt"＝道路豁免區，白色虛線
--   外緣，Z.paintZones），新框的範圍照 Select.draw（青色）蓋在上面。
-- 和建立面板共用 "shape"／"pending" 圖層與 OnMouseDown，一次只開一個（兩邊開的時候都先關掉另一個）。
-- 框架不合（window／controls／focus）時不開（Z.available；區域視窗的〔新增區域〕停用並寫原因），不報錯。
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
-- m = { zones（開窗時的清單）, flat（既有禁建區的扁平 x, y, w, h, ...）, exemptFlat（道路豁免區外緣）, kind, sel, defaultName,
--       onClosed（關窗時呼叫）, busy（nil | "saving" | "waiting"：10 秒沒回覆 | "unknown"：伺服器快取過期）, err, errDetail, rid, closed }

function Z.available()
    return MSH.Client.ui(Z.CAPS) ~= nil
end

function Z.isExempt(z)
    return z.kind == MSH.ZONE_KIND.ROADEXEMPT
end

-- 各區域各塊的扁平 x, y, w, h；第 2 個參數（選填）exempt＝true 只要道路豁免區、false 只要禁建區、沒傳全部。
-- 選填參數從 ... 取：Kahlua 少傳的參數不保證是 nil（家族 pitfalls.md）
function Z.flatZones(zones, ...)
    local exempt = (...)
    local out = {}
    for _, z in ipairs(zones) do
        if exempt == nil or Z.isExempt(z) == exempt then
            for _, r in ipairs(type(z.rects) == "table" and z.rects or {}) do
                if MSH.isInt(r.x) and MSH.isInt(r.y) and MSH.isInt(r.w) and MSH.isInt(r.h) then
                    local n = #out
                    out[n + 1], out[n + 2], out[n + 3], out[n + 4] = r.x, r.y, r.w, r.h
                end
            end
        end
    end
    return out
end

-- 道路豁免區的外緣（Ranges.outline，塊與塊的交界不畫），地上畫成白色虛線（染色的格子是深灰，Ranges.COLORS.roadexempt）
function Z.exemptFlat(zones)
    local out = {}
    for _, z in ipairs(zones) do
        if Z.isExempt(z) and type(z.rects) == "table" and MSH.Rect.shapeError(z.rects) == nil then
            for _, v in ipairs(MSH.Ranges.outline(z.rects)) do out[#out + 1] = v end
        end
    end
    return out
end

-- 地上的既有區域：禁建區亮紅、道路豁免區白色虛線（管理員區域視窗也用）。道路豁免區的染色強度用它自己的 a（往黑色拉，
-- 不能用 ZONE_ALPHAS 的 1.0：那會染成全黑），表只建一次（FloorTint.setRects 用表的同一性判斷有沒有變）
function Z.paintZones(flat, exemptFlat, pz)
    local Tint, C = MSH.FloorTint, MSH.Ranges.COLORS
    Z.EXEMPT_ALPHAS = Z.EXEMPT_ALPHAS or { C.roadexempt.a }
    Tint.setRects("zones", flat, C.zones, Z.ZONE_ALPHAS, pz)
    Tint.setRects("zonesExempt", exemptFlat, C.roadexempt, Z.EXEMPT_ALPHAS, pz, true)
end

-- 這種區域的預設名稱：同種類的個數＋1（「道路豁免區 4」）
function Z.defaultName(zones, kind)
    local exempt, n = kind == MSH.ZONE_KIND.ROADEXEMPT, 1
    for _, z in ipairs(zones) do
        if Z.isExempt(z) == exempt then n = n + 1 end
    end
    return getText(exempt and "IGUI_MSH_Zone_DefaultNameExempt" or "IGUI_MSH_Zone_DefaultName", tostring(n))
end

-- opts = { zones = 目前的區域清單（adminZones）, onClosed = 關窗時呼叫（管理員區域視窗用它開回自己） }
function Z.newModel(opts)
    local zones = type(opts.zones) == "table" and opts.zones or {}
    local CP = MSH.CreatePanel
    local tool = CP ~= nil and CP.defaultTool() or Sel.DRAG
    local kind = MSH.ZONE_KIND.NOBUILD
    return { zones = zones, flat = Z.flatZones(zones, false), exemptFlat = Z.exemptFlat(zones), kind = kind,
        onClosed = type(opts.onClosed) == "function" and opts.onClosed or nil, coord = { "", "", "", "" },
        sel = Sel.new(tool, 0, nil, LIMIT.MAX_PIECES), defaultName = Z.defaultName(zones, kind) }
end

-- 換種類：預設名稱跟著換（名稱框還是舊的預設名稱時，Z.layout 一起換掉）
function Z.setKind(m, kind)
    if m.closed or m.busy ~= nil then return end
    m.kind = kind == MSH.ZONE_KIND.ROADEXEMPT and kind or MSH.ZONE_KIND.NOBUILD
    m.defaultName = Z.defaultName(m.zones, m.kind)
    changed(m)
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

-- ===== 輸入座標（使用者 2026-11-25 核准 plan-zonecoords-1125；玩家建立安全屋不加）=====
-- m.coord＝四格的文字（第一角 X、Y，第二角 X、Y）。兩角照任何順序填，算出左上角與寬高（含頭含尾，同 Rect.fromCorners）

-- shortcut: 「畫面附近」固定用 30 格（預設縮放下大約看得到的地面，沒照解析度與縮放量），有人反映不準再照鏡頭範圍算
Z.FAR = 30
Z.COORD_W = 72

local function coordName(i)
    return getText("IGUI_MSH_Zone_CoordField", getText(i <= 2 and "IGUI_MSH_Zone_Corner1" or "IGUI_MSH_Zone_Corner2"),
        i % 2 == 1 and "X" or "Y")
end

function Z.setCoord(m, i, text)
    m.coord[i] = MSH.trim(text or "")
    changed(m)
end

-- 這一塊：{ x, y, w, h, x1, y1, x2, y2 }；填錯回 nil 與原因（四格都空：nil, nil，不寫原因）。
-- 結果快取到四格、模式或範圍變了（座標輸入模式下走一格就重排，塊數試算不必每次重跑）
function Z.coordPiece(m)
    local s = m.sel
    local key = table.concat(m.coord, ",") .. (s.cut and ",cut" or ",add")
    local c = m.coordCache
    if c ~= nil and c.key == key and c.inside == s.shape.inside then return c.r, c.why end
    local r, why = Z.checkCoords(m)
    m.coordCache = { key = key, inside = s.shape.inside, r = r, why = why }
    return r, why
end

function Z.checkCoords(m)
    local v, missing = {}, {}
    for i = 1, 4 do
        local t = m.coord[i]
        if t == "" then
            missing[#missing + 1] = coordName(i)
        -- 不用 %d：Kahlua 的 %d 是 Character.isDigit，貼上的全形數字會過，tonumber 卻回 nil（貼上不經 onlyNumbers）
        elseif string.match(t, "^%-?[0-9]+$") == nil then
            return nil, getText("IGUI_MSH_Zone_CoordNotInt", coordName(i))
        else
            v[i] = tonumber(t)
        end
    end
    if #missing == 4 then return nil, nil end
    if #missing > 0 then
        return nil, getText("IGUI_MSH_Zone_CoordMissing", table.concat(missing, getText("IGUI_MSH_Admin_ListSep")))
    end
    local r = MSH.Rect.fromCorners(v[1], v[2], v[3], v[4])
    -- 座標範圍同伺服器的 Rect.valid（非負、右下角 < 1,000,000）
    if not MSH.Rect.valid(r) then return nil, getText("IGUI_MSH_Zone_CoordRange", 0, 999999) end
    if r.w > LIMIT.ZONE_SIDE then return nil, getText("IGUI_MSH_Zone_CoordTooWide", LIMIT.ZONE_SIDE, r.w) end
    if r.h > LIMIT.ZONE_SIDE then return nil, getText("IGUI_MSH_Zone_CoordTooTall", LIMIT.ZONE_SIDE, r.h) end
    -- 套上去會超過塊數上限：在形狀的複本上試（Shape.apply 建新表、不改原本的），寫拉好一塊之後同一句；
    -- 加入後合併的外框超過 ZONE_SIDE 也在這裡擋（和 Z.status 同一套算法），不先加入再讓〔儲存〕失敗。
    -- 挖掉不會讓外框變大，不擋（原本就超過時要能挖小）
    local s, Shape = m.sel, MSH.Shape
    local sh = s.shape
    if not (s.cut and Shape.isEmpty(sh)) then
        local try = { xs = sh.xs, ys = sh.ys, inside = sh.inside, history = {}, max = sh.max }
        local ok = Shape.apply(try, r, not s.cut)
        local tr = ok and Shape.result(try) or nil
        if tr == nil or tr.err == "COMPLEX" then
            return nil, getText("IGUI_MSH_Select_Err_COMPLEX", sh.max)
        end
        if not s.cut and tr.err ~= "EMPTY" and (tr.w > LIMIT.ZONE_SIDE or tr.h > LIMIT.ZONE_SIDE) then
            return nil, getText("IGUI_MSH_Zone_CoordTooBig", LIMIT.ZONE_SIDE, tr.w, tr.h)
        end
    end
    r.x1, r.y1, r.x2, r.y2 = v[1], v[2], v[3], v[4]
    return r
end

-- 這塊離玩家所在格多遠（到最近的格，四捨五入）；在 Z.FAR 格內回 nil（地上看得到）
function Z.coordFar(r, px, py)
    local dx = math.max(r.x - px, 0, px - (r.x + r.w - 1))
    local dy = math.max(r.y - py, 0, py - (r.y + r.h - 1))
    local d = math.floor(math.sqrt(dx * dx + dy * dy) + 0.5)
    return d > Z.FAR and d or nil
end

-- 四格清空（畫面上的輸入框也清；TextField:setText 不觸發 onChange）：四格有值＝這塊還沒加入
local function clearCoords(m)
    for i = 1, 4 do m.coord[i] = "" end
    local fields = m.view and m.view.coordFields
    if fields == nil then return end
    for i = 1, 4 do
        if fields[i] ~= nil then fields[i]:setText("") end
    end
end

-- 〔加入這塊〕／〔挖掉這塊〕（輸入座標）：和拉好一塊同一條路（Sel.place → Sel.commit），加入後清空四格
function Z.applyCoords(m)
    if m.closed or m.busy ~= nil then return false end
    local r = Z.coordPiece(m)
    if r == nil then return false end
    local ok = Sel.place(m.sel, r.x1, r.y1, r.x2, r.y2)
    clearCoords(m)
    changed(m)
    return ok
end

-- 〔儲存禁建區〕：走位／手把還沒按〔加入這塊〕的那塊也算進去；輸入座標四格填好還沒加入的那塊也算進去，四格填錯不送
-- （原因寫在四格下面）。形狀有錯、超過外框上限或名稱不合法就不送。
-- 名稱空白＝預設名稱；其餘照 MSH.cleanTitle（伺服器同一套，BAD_TITLE）
function Z.save(m, text)
    if m.closed or m.busy ~= nil then return false end
    if m.sel.tool == Sel.COORDS then
        local r, why = Z.coordPiece(m)
        if why ~= nil then
            changed(m)
            return false
        end
        if r ~= nil then Z.applyCoords(m) end
    end
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
    m.rid = MSH.Client.send("adminAddZone", { name = name, rects = MSH.Rect.copyList(res.rects), kind = m.kind },
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
    -- 區域編號用到上限（zones.json 裡有很大的 id，下一個編號超過 MAX_ZONE_ID）：重開視窗沒用，要把 id 改小
    if m.err == CODE.BAD_ARGS and d.reason == "ID_RANGE" then
        return getText("IGUI_MSH_Zone_IdRange", tostring(LIMIT.MAX_ZONE_ID))
    end
    -- zones.json 有錯：伺服器不覆寫手改的檔
    if m.err == CODE.SAVE_FAILED and d.reason == "FILE" then return getText("IGUI_MSH_Zone_SaveFileBad") end
    local reason, action = MSH.CreatePanel.reasonOf(m.err, d)
    return action and (reason .. " " .. action) or reason
end

-- ===== 畫面 =====

local FONT = UIFont and UIFont.Small

-- 一次只有一顆主要按鈕（client-ui.md）：走位或手把拉到一半、或範圍還空著時是〔設第一角〕／〔加入這塊〕，其餘是〔儲存禁建區〕／〔儲存道路豁免區〕
function Z.layout(v)
    local m, F = v.m, v.flow
    if v.win == nil then return end
    local s = m.sel
    local joy = s.tool == Sel.DRAG and Sel.usingJoypad(s)
    local pending = s.ax ~= nil
    v.corner, v.joy = pending, joy
    F:begin(v.w)
    local exempt = m.kind == MSH.ZONE_KIND.ROADEXEMPT
    local kNo = F:button("kindNo", getText("IGUI_MSH_ZoneKind_nobuild"), m,
        function() Z.setKind(m, MSH.ZONE_KIND.NOBUILD) end, "chip")
    local kEx = F:button("kindEx", getText("IGUI_MSH_ZoneKind_roadexempt"), m,
        function() Z.setKind(m, MSH.ZONE_KIND.ROADEXEMPT) end, "chip")
    kNo:setActive(not exempt)
    kEx:setActive(exempt)
    kNo:setEnabled(m.busy == nil)
    kEx:setEnabled(m.busy == nil)
    F:row({ F:label("kindLabel", getText("IGUI_MSH_Zone_Kind"), "text"), kNo, kEx })
    F:text("hint", getText(exempt and "IGUI_MSH_Zone_HintExempt" or "IGUI_MSH_Zone_Hint"), "textMuted")
    local drag = F:button("drag", getText("IGUI_MSH_Select_Drag"), m, function() Z.setTool(m, Sel.DRAG) end, "chip")
    local walk = F:button("walk", getText("IGUI_MSH_Select_Walk"), m, function() Z.setTool(m, Sel.WALK) end, "chip")
    local coords = F:button("coords", getText("IGUI_MSH_Zone_ToolCoords"), m, function() Z.setTool(m, Sel.COORDS) end, "chip")
    drag:setActive(s.tool == Sel.DRAG)
    walk:setActive(s.tool == Sel.WALK)
    coords:setActive(s.tool == Sel.COORDS)
    F:row({ drag, walk, coords })
    local piece, coordWhy = nil, nil
    if s.tool == Sel.COORDS then
        piece = Z.layoutCoords(v, F)
        coordWhy = select(2, Z.coordPiece(m))
    else
        local hint = "IGUI_MSH_Select_DragHint"
        if s.tool == Sel.WALK then hint = "IGUI_MSH_Select_WalkHint" elseif joy then hint = "IGUI_MSH_Select_DragHintJoypad" end
        F:text("toolHint", getText(hint), "textMuted")
    end
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
    local modeRow = { add, cut }
    local coordApply = nil
    if s.tool == Sel.COORDS then
        coordApply = F:button("coordApply", getText(s.cut and "IGUI_MSH_Select_ApplyCut" or "IGUI_MSH_Select_ApplyAdd"), m,
            function() Z.applyCoords(m) end)
        coordApply:setEnabled(piece ~= nil and m.busy == nil)
        modeRow[3] = coordApply
    end
    F:row(modeRow)
    F:text("nameLabel", getText("IGUI_MSH_Zone_Name"), "text")
    local UI, theme = v.UI, v.theme
    local field = F:get("name", function()
        return UI.TextField.new({ x = 0, y = 0, width = v.w - 2 * K.PAD, theme = theme, text = m.defaultName,
            placeholder = m.defaultName, maxLength = LIMIT.TITLE_CHARS })
    end)
    field:setX(K.PAD)
    -- 換了種類：名稱框還是上一個預設名稱（沒改過）就換成這種的預設名稱
    if v.defaultName ~= nil and v.defaultName ~= m.defaultName and field:getText() == v.defaultName then
        field:setText(m.defaultName)
    end
    v.defaultName = m.defaultName
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
    -- 輸入座標：範圍還空著、這塊填好了時〔加入這塊〕是主要按鈕
    if coordApply ~= nil then
        stepFirst = piece ~= nil and Sel.isEmpty(s)
        coordApply:setStyle(stepFirst and "primary" or "normal")
    end
    local save = F:button("save", getText(exempt and "IGUI_MSH_Zone_SaveExempt" or "IGUI_MSH_Zone_Save"), m,
        function() Z.save(m, v.field:getText()) end)
    save:setStyle(stepFirst and "normal" or "primary")
    -- 輸入座標：四格填好的那塊按〔儲存〕時也算進去；四格填錯時不能存（原因寫在四格下面）
    save:setEnabled(m.busy == nil and coordWhy == nil and ((res.err == nil and not over) or pending or piece ~= nil))
    -- 範圍空著時寫出〔儲存〕為什麼不能按
    if res.err == "EMPTY" and not pending and piece == nil and m.busy == nil then
        F:text("needArea", getText("IGUI_MSH_Zone_SaveNeedArea"), "textMuted")
    end
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

-- 輸入座標那一段：說明（含玩家所在格）、兩個對角的四格、這一塊的大小或填錯的原因；回這一塊（填錯 nil）。
-- 地上預覽這一塊（Sel.setPreview），玩家走動時 Z.frame 重排（距離與所在格跟著變）
function Z.layoutCoords(v, F)
    local m, UI = v.m, v.UI
    local p = player()
    local px, py = 0, 0
    if p ~= nil then px, py = math.floor(p:getX()), math.floor(p:getY()) end
    v.cellX, v.cellY = px, py
    F:text("toolHint", getText("IGUI_MSH_Zone_CoordHint", px, py), "textMuted")
    for corner = 1, 2 do
        local row = { F:label("c" .. corner, getText("IGUI_MSH_Zone_Corner" .. corner), "text") }
        for axis = 1, 2 do
            local i = (corner - 1) * 2 + axis
            local field = F:get("cf" .. i, function()
                return UI.TextField.new({ x = 0, y = 0, width = Z.COORD_W, theme = v.theme, onlyNumbers = true, maxLength = 7,
                    onChange = function(_, text) Z.setCoord(m, i, text) end })
            end)
            row[#row + 1] = F:label("cl" .. i, axis == 1 and "X" or "Y", "textMuted")
            row[#row + 1] = field
            v.coordFields = v.coordFields or {}
            v.coordFields[i] = field
        end
        F:row(row)
    end
    local r, why = Z.coordPiece(m)
    if r ~= nil then
        Sel.setPreview(m.sel, r.x, r.y, r.w, r.h)
        F:text("coordPiece", getText("IGUI_MSH_Zone_CoordPiece", r.w, r.h, r.w * r.h), "text")
        local d = Z.coordFar(r, px, py)
        if d ~= nil then F:text("coordFar", getText("IGUI_MSH_Zone_CoordFar", d), "textMuted") end
    else
        Sel.setPreview(m.sel, nil)
        if why ~= nil then F:text("coordErr", why, "errorText") end
    end
    return r
end

-- 每個 UI 幀（Body:prerender）：拖曳放開的套用與走位終點（形狀或模式變了才重排）、拉到一半那塊的大小、地上的既有禁建區
-- 與新框的範圍（FloorTint 只在變了時動地板）。不配置
function Z.frame(v)
    local m = v.m
    local p = player()
    if p == nil or m.closed then return end
    local s = m.sel
    local moved = s.tool == Sel.COORDS and (math.floor(p:getX()) ~= v.cellX or math.floor(p:getY()) ~= v.cellY)
    if moved or Sel.update(s, p) or (s.ax ~= nil) ~= v.corner or (s.tool == Sel.DRAG and Sel.usingJoypad(s)) ~= v.joy then
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
    Z.paintZones(m.flat, m.exemptFlat, math.floor(p:getZ()))
    Sel.draw(s, p, Sel.FLOOR_OK, v.colors.errorText, v.over)
end

local function clearTint(v)
    if not v.tinted then return end
    v.tinted = false
    local Tint = MSH.FloorTint
    Tint.clear("shape")
    Tint.clear("pending")
    Tint.clear("zones")
    Tint.clear("zonesExempt")
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

-- 地面上的左鍵（沒被任何視窗接走才會觸發，UIManager.java:712-716）：從這格開始拉
function Z.onWorldMouseDown()
    local m = Z.model
    if m ~= nil and not m.closed then Sel.mouseDown(m.sel, player()) end
end

if first then
    Events.OnMouseDown.Add(function() MSH.ZonePanel.onWorldMouseDown() end)
end
