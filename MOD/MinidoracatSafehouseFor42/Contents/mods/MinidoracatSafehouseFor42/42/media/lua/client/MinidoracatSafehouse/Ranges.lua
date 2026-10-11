-- MinidoracatSafehouse/Ranges.lua — 在地面顯示範圍（客戶端）
-- 使用者 2026-10-11：「能不能增加安全屋範圍顯示開關在安全屋面板?這樣就能隨時知道自己的範圍吧」。
-- 開著時，把自己的安全屋與分享給自己的安全屋的外緣畫在地上（只畫玩家附近的）；關掉管理視窗、重新進服都照樣顯示。
-- 開關存在 ModOptions（PZAPI.ModOptions，B42 官方 API：引擎自己存讀 ModOptions.ini，MainOptions.lua:2805-2841、
-- ModOptions.lua:259-333），ESC 選項的「模組」頁也有同一個開關；沒有 PZAPI 時只在這次遊戲有效。
-- 範圍：本機原生安全屋清單裡屋主是 @MSH:<id>、而且在清單快取（Client.claims 的我的、分享給我的）裡的各塊；
-- 暫停保護（lapsed）沒有原生，不畫。清單或原生一變就標記重算，重算時才配置；每幀只畫算好的段、不配置。
-- addAreaHighlightForPlayer 每幀要重加：FBORenderAreaHighlights.render 丟掉 renderTimeMs 不是本幀 UI 時間的
-- （FBORenderAreaHighlights.java:61-68；LuaManager.java:12515-12521）。OnPreUIDraw 在設好本幀 UI 時間之後觸發
-- （UIManager.java:273-296）。

if not isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Client"

local MSH = MinidoracatSafehouse
local first = MSH.Ranges == nil
local R = MSH.Ranges or {}
MSH.Ranges = R

R.OPTIONS_ID = "MinidoracatSafehouse"
R.REACH = 100                                              -- 玩家離外框這麼多格以內才畫
R.COLOR_OWNER = { r = 1.0, g = 0.85, b = 0.4, a = 0.5 }    -- 自己的
R.COLOR_MEMBER = { r = 0.45, g = 0.8, b = 1.0, a = 0.5 }   -- 分享給我的
R.list = R.list or {}
R.dirty = true

-- 選項在檔案載入時登記：MainOptions 建立時 PZAPI.ModOptions:load 才讀得到存值（MainOptions.lua:2822-2823）
if first and PZAPI and PZAPI.ModOptions then
    local opts = PZAPI.ModOptions:create(R.OPTIONS_ID, "IGUI_MSH_Options_Title")
    R.opt = opts:addTickBox("ShowRanges", "IGUI_MSH_Manager_ShowRanges", false, "IGUI_MSH_Manager_ShowRanges_tooltip")
end

function R.isOn()
    if R.opt then return R.opt:getValue() == true end
    return R.sessionOn == true
end

-- 管理視窗的開關：寫進 ModOptions 並存檔（setValue 同步 ESC 頁元件，ModOptions.lua:68-73）
function R.setOn(on)
    on = on == true
    if R.opt then
        R.opt:setValue(on)
        local ok, err = pcall(PZAPI.ModOptions.save, PZAPI.ModOptions)
        if not ok then MSH.log("ModOptions save failed: " .. tostring(err)) end
    else
        R.sessionOn = on
    end
    R.dirty = true
end

local function ascending(a, b) return a < b end

-- 各塊拼起來的形狀 1 格寬的外緣（塊與塊的交界不畫）：扁平 x, y, w, h, ...
-- 以每塊的邊與邊 ±1 切座標，每個壓縮格裡每一格「在不在範圍內、上下左右在不在」都一樣，所以只看壓縮格就知道
-- 是不是外緣；成本只隨塊數、不隨範圍大小（接管來的大屋也一樣快，2026-10-11 審查）。同一列連續的併成一段、
-- 和上一列同起點同寬的往下延伸（方形就是四條邊）
function R.outline(rects)
    local Rect = MSH.Rect
    local xs, ys, seenX, seenY = {}, {}, {}, {}
    local function cut(list, seen, a, b)
        for v = a - 1, a + 1 do
            if not seen[v] then seen[v], list[#list + 1] = true, v end
        end
        for v = b - 1, b + 1 do
            if not seen[v] then seen[v], list[#list + 1] = true, v end
        end
    end
    for _, r in ipairs(rects) do
        cut(xs, seenX, r.x, r.x + r.w)
        cut(ys, seenY, r.y, r.y + r.h)
    end
    MSH.sortSafe(xs, ascending)
    MSH.sortSafe(ys, ascending)
    local nx, ny = #xs - 1, #ys - 1
    local inside = {}
    for j = 1, ny do
        local row = {}
        for i = 1, nx do row[i] = Rect.listContains(rects, xs[i], ys[j]) end
        inside[j] = row
    end
    local function at(i, j) return i >= 1 and i <= nx and j >= 1 and j <= ny and inside[j][i] end
    local areas, prev = {}, {}
    for j = 1, ny do
        local cur, run = {}, nil
        for i = 1, nx + 1 do
            local edge = i <= nx and inside[j][i]
                and not (at(i - 1, j) and at(i + 1, j) and at(i, j - 1) and at(i, j + 1))
            if edge then
                run = run or i
            elseif run ~= nil then
                local x0, w, y0, h = xs[run], xs[i] - xs[run], ys[j], ys[j + 1] - ys[j]
                local k = prev[x0]
                if k ~= nil and areas[k + 2] == w and areas[k + 1] + areas[k + 3] == y0 then
                    areas[k + 3] = areas[k + 3] + h
                else
                    k = #areas + 1
                    areas[k], areas[k + 1], areas[k + 2], areas[k + 3] = x0, y0, w, h
                end
                cur[x0] = k
                run = nil
            end
        end
        prev = cur
    end
    return areas
end

-- 重算要畫的各間：原生清單（SafeHouse.java:652；getOwner :656、getX/getY/getW/getH :596-626）照標記分組，
-- 只留清單快取裡我的（屋主色）與分享給我的（成員色）
function R.rebuild()
    R.dirty = false
    local claims = MSH.Client.claims
    local color = {}
    for _, row in ipairs(claims.shared or {}) do color[row.claimId] = R.COLOR_MEMBER end
    for _, row in ipairs(claims.mine or {}) do color[row.claimId] = R.COLOR_OWNER end
    local byId, order = {}, {}
    local list = SafeHouse.getSafehouseList()
    for i = 0, list:size() - 1 do
        local sh = list:get(i)
        local id = MSH.claimIdOf(sh:getOwner())
        if id ~= nil and color[id] ~= nil then
            local rects = byId[id]
            if rects == nil then
                rects = {}
                byId[id], order[#order + 1] = rects, id
            end
            rects[#rects + 1] = { x = sh:getX(), y = sh:getY(), w = sh:getW(), h = sh:getH() }
        end
    end
    local out = {}
    for _, id in ipairs(order) do
        local rects = byId[id]
        local b = MSH.Rect.bounds(rects)
        out[#out + 1] = { areas = R.outline(rects), x1 = b.x, y1 = b.y, x2 = b.x + b.w, y2 = b.y + b.h, color = color[id] }
    end
    R.list = out
end

function R.draw()
    if not R.isOn() then return end
    local p = getSpecificPlayer(0)
    if p == nil then return end
    if R.dirty then R.rebuild() end
    local px, py, z = p:getX(), p:getY(), math.floor(p:getZ())   -- IsoMovingObject.java:525
    local reach, list = R.REACH, R.list
    for i = 1, #list do
        local c = list[i]
        if px >= c.x1 - reach and px <= c.x2 + reach and py >= c.y1 - reach and py <= c.y2 + reach then
            local col, a = c.color, c.areas
            for k = 1, #a, 4 do
                local x, y = a[k], a[k + 1]
                addAreaHighlightForPlayer(0, x, y, x + a[k + 2], y + a[k + 3], z, col.r, col.g, col.b, col.a)
            end
        end
    end
end

if first then
    MSH.Client.on("claims", "Ranges", function() MSH.Ranges.dirty = true end)
    Events.OnSafehousesChanged.Add(function() MSH.Ranges.dirty = true end)   -- LuaEventManager.java:775
    Events.OnPreUIDraw.Add(function() MSH.Ranges.draw() end)
end
