-- MinidoracatSafehouse/IndoorPanel.lua：室內檢查面板（使用者 2026-10-15：「判斷自己蓋的房子有沒有算室內，以及方便找出
-- 沒成為室內的原因」；設計稿 temp/plan-indoor-1015，裁定見 decisions.md 2026-10-15）。判定在伺服器（server/…/Indoor.lua），
-- 這裡只顯示結論、列出缺口、在地上標位置。入口：地面右鍵「檢查這裡算不算室內」（點到的那格）、管理視窗上列〔室內檢查〕
-- （站的那格）。
-- 效能（使用者 2026-10-15：「只有需要查的時候才查，平常不用一直掃」）：面板關著時不掛任何事件、不送指令；開著時只在
--   開窗、按〔重新檢查〕、檢查範圍外框 NEAR 格內有物件增減時查（OnObjectAdded／OnObjectAboutToBeRemoved：伺服器改了東西、
--   客戶端收到封包時觸發，AddItemToMapPacket、RemoveItemFromSquarePacket）。物件增減後等 SETTLE_MS（伺服器的 IsoRegions
--   在背景執行緒重算）；同時只送一筆，上一筆回覆後滿 GAP_MS 才送下一筆（伺服器冷卻 1 秒，client-ui.md「冷卻間隔從回覆算」）。
-- 地上標示：缺屋頂的格子用 FloorTint 圖層 "indoor"（地板染色，只染畫面裡的）；缺牆照原版建造游標的畫法，把牆的貼圖用
--   RenderGhostTileColor 半透明疊上（RenderOpaqueObjectsInWorld 裡 renderIsoLine 畫不出來，sh-indoor-1015c），只在玩家
--   站在那一層時畫（疊色不測深度，會蓋過樓上）。
-- 屋簷下（OPEN 而且沒圍起來的邊不少於有牆的邊：比牆多出一圈的屋頂、門廊、車棚）只說結論、不列缺口：那些邊本來就沒要圍。
-- 框架缺席：不開視窗，查完用頭上文字（HaloTextHelper）說結論（AGENTS.md 鐵則：不報錯、不消失）。
-- 載入時不碰 ISPanel、框架或 getPlayer（harness T.bootClient 會載入本檔）；ISPanel 子類在第一次開窗時才建。

if not isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Client"
require "MinidoracatSafehouse/FloorTint"

local MSH = MinidoracatSafehouse
local first = MSH.IndoorPanel == nil
local P = MSH.IndoorPanel or {}
MSH.IndoorPanel = P

P.GAP_MS = 1100       -- 伺服器冷卻 1000 ms＋餘裕，從回覆算
P.SETTLE_MS = 700     -- 物件增減後多久才查（伺服器重算 IsoRegions；送到客戶端實測 101-206 ms，sh-indoor-1015e）
P.NEAR = 4            -- 物件落在檢查範圍外框外幾格內才重查（和伺服器找屋頂的 NEAR 一樣）
P.DIST_MS = 500       -- 多久更新一次「離你 N 格」
P.ROWS, P.ROOM_ROWS = 5, 3   -- 問題、同一個屋頂下的房間各最多同時顯示幾列（再多就捲動）
P.TINT, P.TINT_SEL = 0.75, 1   -- 缺屋頂格子的染色強度（選中的那一組較強；0.45 在草地上只看得出一點褐色，sh-indoor-1015f）
P.GHOST, P.GHOST_SEL = 0.5, 0.9   -- 缺牆的牆影
P.SPRITES = { "walls_exterior_wooden_01_45", "walls_exterior_wooden_01_44" }   -- 牆影：[1]＝北邊、[2]＝西邊（原版木牆）
P.CAPS = { "window", "controls", "virtualList" }
if P.marksOn == nil then P.marksOn = true end   -- 「在地上標出位置」，這次遊戲記住

local PAD, GAP, ICON = 12, 6, 16
local FONT = UIFont and UIFont.Small
local EMPTY = {}
local DX = { 0, -1, 0, 1 }
local DY = { -1, 0, 1, 0 }

-- ===== 純邏輯（harness 測）=====

local function gkey(x, y, side) return (side * 100000 + x) * 100000 + y end
local function ckey(x, y) return x * 100000 + y end

-- 缺牆併成段：同一條牆線上相連的邊（北邊沿 x、西邊沿 y）。回 { kind = "gap", n, flat = { x, y, side, ... } } 的清單
function P.segments(gaps)
    local set, used, rows = {}, {}, {}
    for i = 1, #gaps, 3 do set[gkey(gaps[i], gaps[i + 1], gaps[i + 2])] = true end
    for i = 1, #gaps, 3 do
        local x, y, side = gaps[i], gaps[i + 1], gaps[i + 2]
        if not used[gkey(x, y, side)] then
            local dx, dy = 1, 0
            if side == 2 then dx, dy = 0, 1 end
            while set[gkey(x - dx, y - dy, side)] do x, y = x - dx, y - dy end
            local flat, n = {}, 0
            while set[gkey(x, y, side)] do
                used[gkey(x, y, side)] = true
                flat[3 * n + 1], flat[3 * n + 2], flat[3 * n + 3] = x, y, side
                n = n + 1
                x, y = x + dx, y + dy
            end
            rows[#rows + 1] = { kind = "gap", n = n, flat = flat }
        end
    end
    return rows
end

-- 缺屋頂併成塊（上下左右相連）。回 { kind = "hole", n, flat = { x, y, ... } } 的清單
function P.blobs(holes)
    local set, used, rows = {}, {}, {}
    for i = 1, #holes, 2 do set[ckey(holes[i], holes[i + 1])] = true end
    for i = 1, #holes, 2 do
        local k = ckey(holes[i], holes[i + 1])
        if not used[k] then
            used[k] = true
            local flat, n, qi = { holes[i], holes[i + 1] }, 1, 1
            while qi <= 2 * n do
                local x, y = flat[qi], flat[qi + 1]
                qi = qi + 2
                for d = 1, 4 do
                    local nx, ny = x + DX[d], y + DY[d]
                    local nk = ckey(nx, ny)
                    if set[nk] and not used[nk] then
                        used[nk] = true
                        flat[2 * n + 1], flat[2 * n + 2] = nx, ny
                        n = n + 1
                    end
                end
            end
            rows[#rows + 1] = { kind = "hole", n = n, flat = flat }
        end
    end
    return rows
end

-- 這一組離 (px, py) 最近幾格（棋盤距離；缺牆用存那條邊的格子）
function P.dist(row, px, py)
    local flat, step, best = row.flat, row.kind == "gap" and 3 or 2, nil
    for i = 1, #flat, step do
        local d = math.max(math.abs(flat[i] - px), math.abs(flat[i + 1] - py))
        if best == nil or d < best then best = d end
    end
    return best or 0
end

-- 屋簷下：沒圍起來的邊不少於有牆的邊（比牆多出一圈的屋頂、門廊、車棚、院子裡的棚子）
function P.eaves(room)
    return room ~= nil and (room.verdict == "OPEN" or room.verdict == "PART_ROOF") and room.gapCount >= room.walls
end

-- 這一間要列的問題：缺牆的段、缺屋頂的塊，近的在前；屋簷下（OPEN）不列
function P.issues(room, px, py)
    if room == nil or (room.verdict == "OPEN" and P.eaves(room)) then return {} end
    local rows = P.segments(room.gaps or EMPTY)
    for _, b in ipairs(P.blobs(room.holes or EMPTY)) do rows[#rows + 1] = b end
    for _, row in ipairs(rows) do row.dist = P.dist(row, px, py) end
    MSH.sortSafe(rows, function(a, b) return a.dist < b.dist end)
    return rows
end

-- 結論：標題、說明、顏色 token、圖示、算不算室內。room＝目前看的那間（MAP_ROOM、BASEMENT、OUTSIDE 沒有）
function P.verdict(res, room)
    local v = room and room.verdict or res.verdict
    if v == "OPEN" and P.eaves(room) then v = "CANOPY" end
    local sub
    if v == "NEED_ROOF" then
        sub = getText("IGUI_MSH_Indoor_Sub_NEED_ROOF", room.size - room.roofs)
    else
        sub = getText("IGUI_MSH_Indoor_Sub_" .. v)
    end
    local good = v == "ROOM" or v == "MAP_ROOM"
    local token = good and "text" or (v == "OUTSIDE" and "textMuted" or "errorText")
    return getText("IGUI_MSH_Indoor_Head_" .. v), sub, token, good and "check" or "warning", good
end

function P.room(m)
    return m.res ~= nil and m.res.rooms[m.cur] or nil
end

-- 同一個屋頂下的其他房間（清單列）
function P.others(m)
    local out = {}
    for i, r in ipairs(m.res ~= nil and m.res.rooms or EMPTY) do
        if i ~= m.cur then out[#out + 1] = { kind = "room", index = i, room = r } end
    end
    return out
end

-- ===== 查詢 =====

function P.changed(m)
    if m.view ~= nil then P.layout(m.view) end
end

local function ask(m, delay)
    m.want, m.dueAt = true, getTimestampMs() + delay
end

-- 送查詢：要查、沒有在等回覆、時間到了、上一筆回覆後滿 GAP_MS。玩家離那格超過 INDOOR_REACH 就不送（伺服器也會擋）
function P.pump(m, now)
    if not m.want or m.busy or now < m.dueAt then return false end
    if m.lastAt ~= nil and now - m.lastAt < P.GAP_MS then return false end
    local p = getSpecificPlayer(0)
    if p == nil then return false end
    m.want = false
    local reach = MSH.LIMIT.INDOOR_REACH
    if math.abs(math.floor(p:getX()) - m.x) > reach or math.abs(math.floor(p:getY()) - m.y) > reach then
        m.err = MSH.CODE.TOO_FAR
        P.changed(m)
        if m.view == nil then P.finishHalo(m) end
        return false
    end
    local seq = m.seq
    m.busy = true
    local rid = MSH.Client.send("indoor", { x = m.x, y = m.y, z = m.z }, function(res) P.onReply(m, seq, res) end)
    if rid == nil then m.busy, m.want = false, true end
    P.changed(m)
    return rid ~= nil
end

-- 這一間的問題列、距離、地上標示照目前的結果重算（換了結果或換看別間時）
function P.refresh(m)
    local p = getSpecificPlayer(0)
    m.px, m.py = m.x, m.y
    if p ~= nil then m.px, m.py = math.floor(p:getX()), math.floor(p:getY()) end
    m.issues = P.issues(P.room(m), m.px, m.py)
    m.sel = nil
    P.mark(m)
end

function P.onReply(m, seq, res)
    m.busy, m.lastAt = false, getTimestampMs()
    if m.closed or seq ~= m.seq then return end   -- 關掉了，或已經換查別格
    if res.ok then
        m.res, m.err = res, nil
        if res.rooms[m.cur] == nil then m.cur = 1 end
        P.refresh(m)
    else
        m.err = res.code
        if res.code == "NO_REPLY" and m.view ~= nil then ask(m, 0) end   -- 間隔滿了再試一次
    end
    if m.view == nil then
        P.finishHalo(m)
        return
    end
    P.changed(m)
end

-- 地上要標的：缺屋頂的格子（FloorTint 的矩形與強度）、缺牆（x, y, side, 強度 每 4 個一筆）。選中的那一組較強
function P.mark(m)
    local holes, alphas, walls = {}, {}, {}
    if P.marksOn and m.view ~= nil then
        for i, row in ipairs(m.issues) do
            local f = row.flat
            if row.kind == "hole" then
                local a = i == m.sel and P.TINT_SEL or P.TINT
                for j = 1, #f, 2 do
                    local n = #holes
                    holes[n + 1], holes[n + 2], holes[n + 3], holes[n + 4] = f[j], f[j + 1], 1, 1
                    alphas[#alphas + 1] = a
                end
            else
                local a = i == m.sel and P.GHOST_SEL or P.GHOST
                for j = 1, #f, 3 do
                    local n = #walls
                    walls[n + 1], walls[n + 2], walls[n + 3], walls[n + 4] = f[j], f[j + 1], f[j + 2], a
                end
            end
        end
    end
    m.holeFlat, m.holeAlphas, m.walls = holes, alphas, walls
end

-- 物件增減落在檢查範圍附近（同一層或樓上）：等 SETTLE_MS 再查。地上的物品不算
function P.onObject(obj)
    local m = P.model
    if m == nil or obj == nil or instanceof(obj, "IsoWorldInventoryObject") then return end
    local sq = obj:getSquare()
    if sq == nil or sq:getZ() < m.z then return end
    local x, y, n, res = sq:getX(), sq:getY(), P.NEAR, m.res
    local x0, y0, x1, y1 = m.x, m.y, m.x, m.y
    if res ~= nil then x0, y0, x1, y1 = res.minX, res.minY, res.maxX, res.maxY end
    if x < x0 - n or x > x1 + n or y < y0 - n or y > y1 + n then return end
    local was = m.want
    ask(m, P.SETTLE_MS)
    if not was then P.changed(m) end
end

-- 「離你 N 格」：玩家換了格子才重算，有變才重綁清單列
function P.updateDist(m)
    local p = getSpecificPlayer(0)
    if p == nil then return end
    local px, py = math.floor(p:getX()), math.floor(p:getY())
    if px == m.px and py == m.py then return end
    m.px, m.py = px, py
    local changed = false
    for _, row in ipairs(m.issues) do
        local d = P.dist(row, px, py)
        if d ~= row.dist then row.dist, changed = d, true end
    end
    if changed and m.view ~= nil then m.view.issues:setItems(m.issues) end
end

-- OnTick（只在開著時掛）：送查詢、更新距離、地板染色跟著鏡頭重切（沒變時不配置）
function P.tick()
    local m = P.model
    if m == nil then return end
    local now = getTimestampMs()
    P.pump(m, now)
    local v = m.view
    if v == nil then return end
    if now >= (m.distAt or 0) then
        m.distAt = now + P.DIST_MS
        P.updateDist(m)
    end
    MSH.FloorTint.setRects("indoor", m.holeFlat or EMPTY, v.colors.errorText, m.holeAlphas or EMPTY, m.z)
end

-- RenderOpaqueObjectsInWorld（只在開著時掛）：缺牆的牆影，每幀不配置
function P.render(playerIndex)
    local m = P.model
    if playerIndex ~= 0 or m == nil or m.view == nil then return end
    local l = m.walls
    if l == nil or #l == 0 then return end
    local p = getSpecificPlayer(0)
    if p == nil or math.floor(p:getZ()) ~= m.z then return end
    local c, s = m.view.colors.errorText, P.sprites
    for i = 1, #l, 4 do
        local spr = s[l[i + 2]]
        if spr ~= nil then spr:RenderGhostTileColor(l[i], l[i + 1], m.z, c.r, c.g, c.b, l[i + 3]) end
    end
end

-- 事件只在開著時掛（使用者 2026-10-15：「只有需要查的時候才查，平常不用一直掃」）
P.fnTick = P.fnTick or function() MSH.IndoorPanel.tick() end
P.fnObject = P.fnObject or function(obj) MSH.IndoorPanel.onObject(obj) end
P.fnRender = P.fnRender or function(playerIndex) MSH.IndoorPanel.render(playerIndex) end

local function hook(on)
    if (P.hooked == true) == on then return end
    P.hooked = on
    local f = on and "Add" or "Remove"
    Events.OnTick[f](P.fnTick)
    Events.OnObjectAdded[f](P.fnObject)
    Events.OnObjectAboutToBeRemoved[f](P.fnObject)
    Events.RenderOpaqueObjectsInWorld[f](P.fnRender)
end

-- 框架缺席：結論（或錯誤）寫在頭上，查完就收（HaloTextHelper.java addGoodText／addBadText）
function P.finishHalo(m)
    local p = getSpecificPlayer(0)
    if p ~= nil and HaloTextHelper ~= nil then
        if m.err ~= nil then
            HaloTextHelper.addBadText(p, (MSH.Client.codeText(m.err)))
        else
            local head, _, _, _, good = P.verdict(m.res, P.room(m))
            if good then HaloTextHelper.addGoodText(p, head) else HaloTextHelper.addBadText(p, head) end
        end
    end
    P.close(m)
end

-- ===== 畫面 =====

local V = nil
local function classes()
    if V ~= nil then return V end
    V = {}
    V.Body = ISPanel:derive("MinidoracatSafehouseIndoorBody")
    function V.Body:render() P.draw(self, self.view) end
    -- 清單列：兩行；截斷時 hover 顯示全文（借原版 ISButton:updateTooltip，同 ManagerWindow 的清單列）
    V.Cell = ISPanel:derive("MinidoracatSafehouseIndoorCell")
    function V.Cell:prerender()
        if self.tooltip or self.tooltipUI then ISButton.updateTooltip(self) end
    end
    function V.Cell:render() P.drawCell(self) end
    return V
end

local function wrap(v, text, width)
    if v.wrapOK then return v.UI.Text.wrap(text, width, FONT) end
    return { text }
end

-- 一段文字（換行後逐行記下；只在狀態改變時重建，render 只畫）
local function para(v, text, token, icon, y)
    local indent = icon ~= nil and (ICON + 4) or 0
    for i, line in ipairs(wrap(v, text, v.innerW - indent)) do
        v.lines[#v.lines + 1] = { text = line, token = token, icon = i == 1 and icon or nil, x = PAD + indent, y = y }
        y = y + v.lineH
    end
    return y + 2
end

-- 一列控制項，放不下換行
local function row(v, list, y)
    local x, h = PAD, 0
    for _, b in ipairs(list) do
        if x > PAD and x + b.width > v.w - PAD then x, y, h = PAD, y + h + GAP, 0 end
        b:setX(x)
        b:setY(y)
        b:setVisible(true)
        x, h = x + b.width + GAP, math.max(h, b.height)
    end
    return y + h + GAP
end

local function placeList(v, list, items, rows, sel, y)
    if #items == 0 then
        list:setVisible(false)
        return y
    end
    local h = math.min(#items, rows) * (v.rowH + 2) + 2
    list:setX(PAD)
    list:setY(y)
    if list.width ~= v.innerW or list.height ~= h then list:resize(v.innerW, h) end
    list:setItems(items)
    list:setSelectedIndex(sel)
    list:setVisible(true)
    return y + h + GAP
end

function P.layout(v)
    local m = v.m
    v.lines = {}
    local y = PAD
    local res, room = m.res, P.room(m)
    if res ~= nil then
        local head, sub, token, icon = P.verdict(res, room)
        y = para(v, head, token, icon, y)
        y = para(v, sub, "textMuted", nil, y)
        if room ~= nil and not P.eaves(room) then
            y = para(v, getText("IGUI_MSH_Indoor_RoomLine", room.size, room.roofs, room.size), "textMuted", nil, y + 2)
        end
    end
    y = placeList(v, v.issues, m.issues, P.ROWS, m.sel, y + 2)
    local others = P.others(m)
    if #others > 0 then y = para(v, getText("IGUI_MSH_Indoor_Others"), "text", nil, y) end
    y = placeList(v, v.rooms, others, P.ROOM_ROWS, nil, y)
    y = row(v, { v.marksBox, v.btnRecheck }, y)
    if m.busy or m.want then y = para(v, getText("IGUI_MSH_Indoor_Checking"), "textMuted", nil, y) end
    if m.err ~= nil then
        local reason, action = MSH.Client.codeText(m.err)
        y = para(v, reason, "errorText", "warning", y)
        if action ~= nil then y = para(v, action, "textMuted", nil, y) end
    end
    if res ~= nil and res.partial then y = para(v, getText("IGUI_MSH_Indoor_Partial"), "textMuted", nil, y) end
    y = para(v, getText("IGUI_MSH_Indoor_Note"), "textMuted", nil, y + 2) + PAD - 2
    v.body:setHeight(y)
    v.win:setHeight(v.top + y)
    local Focus = v.UI.Focus
    if Focus ~= nil and Focus.invalidate ~= nil then Focus.invalidate(v.win) end
end

function P.draw(el, v)
    local colors, Icons = v.colors, v.UI.Icons
    for i = 1, #v.lines do
        local l = v.lines[i]
        local c = colors[l.token] or colors.text
        if l.icon ~= nil then Icons.draw(el, l.icon, PAD, l.y + v.iconDY, ICON, c) end
        el:drawText(l.text, l.x, l.y, c.r, c.g, c.b, c.a or 1, FONT)
    end
end

-- 清單列的字在綁定時組好（換資料、捲動、距離變了才綁），render 只畫
function P.bindCell(v, cell, item, index)
    cell.row, cell.index = item, index
    local title, sub
    cell.right, cell.chevron = nil, false
    if item.kind == "room" then
        local r = item.room
        local eaves, good = P.eaves(r), r.verdict == "ROOM"
        if item.index == 1 then
            title = getText("IGUI_MSH_Indoor_ThisRoom", r.size)
        else
            title = getText(eaves and "IGUI_MSH_Indoor_Eaves" or "IGUI_MSH_Indoor_OtherRoom", r.size)
        end
        sub = getText(good and "IGUI_MSH_Indoor_IsIndoor" or (eaves and "IGUI_MSH_Indoor_RoofOnly" or "IGUI_MSH_Indoor_NotIndoor"))
        cell.icon = good and "check" or "warning"
        cell.token = good and "text" or (eaves and "textMuted" or "errorText")
        cell.subToken, cell.chevron = cell.token, true
    else
        local hole = item.kind == "hole"
        title = getText(hole and "IGUI_MSH_Indoor_Hole" or "IGUI_MSH_Indoor_Gap", item.n)
        local room = P.room(v.m)
        local fix = "IGUI_MSH_Indoor_GapFix"
        if hole then
            fix = "IGUI_MSH_Indoor_HoleFix"
        elseif room ~= nil and room.verdict == "PART_ROOF" then
            fix = "IGUI_MSH_Indoor_SplitFix"   -- 圍起來的範圍裡面：隔一道牆就好
        end
        sub = getText(fix)
        cell.right = item.dist <= 1 and getText("IGUI_MSH_Indoor_Here") or getText("IGUI_MSH_Indoor_Dist", item.dist)
        cell.rightW = getTextManager():MeasureStringX(FONT, cell.right)
        cell.icon, cell.token, cell.subToken = "warning", "errorText", "textMuted"
    end
    local textX = 8 + ICON + 6
    local titleW = cell.width - textX - 8 - (cell.right ~= nil and cell.rightW + 6 or ICON + 6)
    local Text = v.UI.Text
    cell.title = Text.fit(title, titleW, FONT)
    cell.sub = Text.fit(sub, cell.width - textX - 8, FONT)
    cell.tooltip = nil
    if cell.sub ~= sub then cell.tooltip = sub elseif cell.title ~= title then cell.tooltip = title end
end

function P.drawCell(cell)
    local item, v = cell.row, cell.view
    if item == nil then return end
    local c, fh = v.colors, v.fh
    if cell.list:isSelected(cell.index) then
        v.theme:fill(cell, 0, 0, cell.width, cell.height, "selected")
    elseif cell:isMouseOver() then
        v.theme:fill(cell, 0, 0, cell.width, cell.height, "hover")
    end
    local ic, t, mu = c[cell.token] or c.text, c.text, c.textMuted
    local textX = 8 + ICON + 6
    v.UI.Icons.draw(cell, cell.icon, 8, 5 + v.iconDY, ICON, ic, 1)
    cell:drawText(cell.title, textX, 5, t.r, t.g, t.b, t.a or 1, FONT)
    if cell.right ~= nil then
        cell:drawText(cell.right, cell.width - 8 - cell.rightW, 5, mu.r, mu.g, mu.b, mu.a or 1, FONT)
    elseif cell.chevron then
        v.UI.Icons.draw(cell, "chevronRight", cell.width - 8 - ICON, 5 + v.iconDY, ICON, mu, 1)
    end
    local s = c[cell.subToken] or mu
    cell:drawText(cell.sub, textX, 7 + fh, s.r, s.g, s.b, s.a or 1, FONT)
end

-- 選中的問題列：地上那一組標得較強
function P.select(m, index)
    if m.sel == index then return end
    m.sel = index
    P.mark(m)
end

-- 換看同一個屋頂下的另一間（資料已經在結果裡，不用再查）
function P.pick(m, index)
    if m.res == nil or m.res.rooms[index] == nil or m.cur == index then return end
    m.cur = index
    P.refresh(m)
    P.changed(m)
end

function P.setMarks(m, on)
    P.marksOn = on == true
    P.mark(m)
end

function P.recheck(m)
    m.err = nil
    ask(m, 0)
    P.changed(m)
end

function P.build(m, UI)
    classes()
    local theme = MSH.Client.theme(UI)
    local fh = getTextManager():getFontHeight(FONT)
    local core = getCore()
    local sw, sh = core:getScreenWidth(), core:getScreenHeight()
    local w = math.max(320, math.min(fh * 24, sw - 40))
    local v = { m = m, UI = UI, theme = theme, colors = theme.colors, w = w, innerW = w - PAD * 2, lines = {},
        lineH = fh + 2, fh = fh, rowH = fh * 2 + 10, wrapOK = UI.CAPABILITIES.textWrap == true and UI.Text.wrap ~= nil }
    v.iconDY = math.floor((fh - ICON) / 2)
    -- 開在右側（不擋住角色附近的地面），這次遊戲拖過就開在上次關掉的位置
    local x, y = math.max(0, sw - w - 60), 120
    local last = P.lastPos
    if last ~= nil then
        x = math.max(0, math.min(last.x, sw - w))
        y = math.max(0, math.min(last.y, sh - 200))
    end
    local win = UI.Window.new(MSH.Client.windowOpts(UI, { x = x, y = y, width = w, height = 200, icon = "house",
        theme = theme, title = getText("IGUI_MSH_Indoor_Title") }))
    win.onEscape = function()
        P.close(m)
        return true
    end
    win.onClose = function() P.close(m) end
    v.win, v.top = win, win:contentTop()
    local body = V.Body:new(0, v.top, w, 100)
    body.background = false
    body.view = v
    body:initialise()
    win:addChild(body)
    v.body = body
    local c = v.colors
    local function list(onSelect, onHighlight)
        local l = UI.VirtualList.new({ x = PAD, y = 0, width = v.innerW, height = v.rowH, rowHeight = v.rowH, padding = 2,
            createCell = function(lst)
                local cell = V.Cell:new(0, 0, 0, 0)
                cell.background = false
                cell.list, cell.view = lst, v
                return cell
            end,
            bindCell = function(_, cell, item, index) P.bindCell(v, cell, item, index) end,
            unbindCell = function(_, cell) cell.row, cell.tooltip = nil, nil end,
            onSelect = onSelect, onHighlight = onHighlight,
            colors = { thumb = c.textMuted, thumbHover = c.text, track = c.hover } })
        l:initialise()
        body:addChild(l)
        l:setVisible(false)
        return l
    end
    local function selectIssue(_, _, index) P.select(m, index) end
    v.issues = list(selectIssue, selectIssue)
    v.rooms = list(function(_, item) if item ~= nil then P.pick(m, item.index) end end, nil)
    v.marksBox = UI.Checkbox.new({ x = PAD, y = 0, label = getText("IGUI_MSH_Indoor_ShowMarks"),
        tooltip = getText("IGUI_MSH_Indoor_ShowMarks_tooltip"), checked = P.marksOn, theme = theme,
        onChange = function(_, on) P.setMarks(m, on) end })
    body:addChild(v.marksBox)
    v.btnRecheck = UI.Button.new({ x = 0, y = 0, title = getText("IGUI_MSH_Indoor_Recheck"), icon = "reload",
        theme = theme, onClick = function() P.recheck(m) end })
    v.btnRecheck:fitWidth()
    body:addChild(v.btnRecheck)
    m.view = v
    P.layout(v)
    win:addToUIManager()
    return v
end

-- ===== 開關 =====

local function openManager()
    local W = MSH.ManagerWindow
    if W == nil or W.open == nil then return end
    local ok, err = pcall(W.open, {})
    if not ok then MSH.log("ManagerWindow.open failed: " .. tostring(err)) end
end

-- 關窗：拿掉事件與地上的標示；從管理視窗開的把管理視窗開回來
function P.close(m)
    m = m or P.model
    if m == nil or m.closed then return end
    m.closed = true
    if P.model == m then P.model = nil end
    hook(false)
    MSH.FloorTint.clear("indoor")
    m.walls = nil
    local v = m.view
    m.view = nil
    if v ~= nil and v.win ~= nil then
        local win = v.win
        v.win = nil
        pcall(function()
            if win:getIsVisible() then win:close() end
            win:removeFromUIManager()
            P.lastPos = { x = win:getX(), y = win:getY() }
        end)
    end
    if m.fromManager then openManager() end
end

local function openUnsafe(opts)
    local x, y, z = opts.x, opts.y, opts.z
    if x == nil then
        local p = getSpecificPlayer(0)
        if p == nil then return nil end
        x, y, z = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
    end
    local m = P.model
    if m ~= nil then
        -- 已經開著：換查這一格（還在等的那筆回來時丟掉）
        m.x, m.y, m.z, m.seq = x, y, z, m.seq + 1
        m.res, m.err, m.cur = nil, nil, 1
        m.fromManager = m.fromManager or opts.fromManager == true
        P.refresh(m)
        ask(m, 0)
        if m.view ~= nil then m.view.win:bringToTop() end
        P.changed(m)
        P.pump(m, getTimestampMs())
        return m
    end
    m = { x = x, y = y, z = z, seq = 0, cur = 1, issues = {}, dueAt = 0, fromManager = opts.fromManager == true }
    P.model = m
    local UI = MSH.Client.ui(P.CAPS)
    if UI ~= nil then
        P.build(m, UI)
    else
        MSH.log("indoor panel: MinidoracatUI missing or too old; answering with halo text")
    end
    P.sprites = P.sprites or { getSprite(P.SPRITES[1]), getSprite(P.SPRITES[2]) }
    hook(true)
    ask(m, 0)
    P.pump(m, getTimestampMs())
    return m
end

-- opts：{ x, y, z }（右鍵點到的那格；沒有＝站的那格）、fromManager。回 model，失敗回 nil（記 log、半建好的收掉）
function P.open(opts)
    local ok, res = pcall(openUnsafe, opts or {})
    if ok then return res end
    MSH.log("indoor panel failed: " .. tostring(res))
    if P.model ~= nil then P.close(P.model) end
    return nil
end

-- 地面右鍵：點到的那格（ISWorldObjectContextMenu.fetchVars.clickedSquare，ISWorldObjectContextMenuLogic.java fetch；
-- 沒有就用第一個物件的格子）。分割畫面次玩家沒有身分，不加（同建立面板）
function P.onWorldMenu(playerNum, context, worldobjects, test)
    if test or playerNum ~= 0 then return end
    local fetch = ISWorldObjectContextMenu and ISWorldObjectContextMenu.fetchVars
    local sq = fetch and fetch.clickedSquare
    if sq == nil and worldobjects ~= nil and worldobjects[1] ~= nil then sq = worldobjects[1]:getSquare() end
    if sq == nil then return end
    context:addOption(getText("IGUI_MSH_Indoor_Menu"), nil, P.onMenu, sq:getX(), sq:getY(), sq:getZ())
end

function P.onMenu(_, x, y, z)
    P.open({ x = x, y = y, z = z })
end

if first then
    Events.OnFillWorldObjectContextMenu.Add(function(playerNum, context, worldobjects, test)
        MSH.IndoorPanel.onWorldMenu(playerNum, context, worldobjects, test)
    end)
end
