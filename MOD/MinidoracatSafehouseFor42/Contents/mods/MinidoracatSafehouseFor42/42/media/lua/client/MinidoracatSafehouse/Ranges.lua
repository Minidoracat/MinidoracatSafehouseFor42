-- MinidoracatSafehouse/Ranges.lua — 在地面顯示範圍（客戶端）
-- 使用者 2026-10-11：「能不能增加安全屋範圍顯示開關在安全屋面板?這樣就能隨時知道自己的範圍吧」；2026-10-12：「打開就
-- 持續顯示，可以看隊友的，也能看其他玩家的，但是這些管理員面板跟沙盒也要可以設定，預設就開啟自己跟同陣營的，每一種都不同顏色顯示」。
-- 四類各一種顏色：自己的（屋主是我）、分享給我的（我在名單裡）、同陣營的（屋主和我同一個陣營）、其他玩家的。
-- 伺服器開放哪幾類：自己的與分享給我的一定可以；同陣營的、其他玩家的看沙盒 RangesFaction（預設開）、RangesOthers（預設關）。
--   這只是畫面：原版本來就把每一間的範圍傳給所有客戶端（MetaDataPacket、SafehouseSync），改過的客戶端照樣看得到。
-- 玩家自己的開關：總開關（預設開）＋每一類（預設都開；伺服器沒開放的那類照樣不畫）。存在 ModOptions（PZAPI.ModOptions，
--   B42 官方 API：引擎自己存讀 ModOptions.ini，MainOptions.lua:2805-2841、ModOptions.lua:259-333），ESC 選項的「模組」頁
--   也有同樣的開關（套用時 Options:apply，MainOptions.lua:3761-3763）；沒有 PZAPI 時只在這次遊戲有效。
-- 分類：清單快取（Client.claims）的我的、分享給我的先算；其餘原生照屋主：原版或沒接管的直接是 getOwner，
--   managed（@MSH:<id>）用 PublicApi.ownerName（公開的 registry 表，第一次查不到會抓整張表、有節流）；我在原生名單裡＝分享給我的。
--   只有我在陣營裡、而且同陣營或其他玩家那類要畫時（要分出是哪一類）才查 managed 的屋主：不在陣營的人不必為了分類去抓
--   registry。屋主還沒查到的先算其他玩家的。四類互不重疊：關掉同陣營的，同陣營的屋不會改用其他玩家的顏色畫出來。
-- 暫停保護（lapsed）沒有原生，不畫。清單、原生、陣營（SyncFaction）、屋主表（OnReceiveGlobalModData）、沙盒（sandboxSync）
--   或開關一變就標記重算，重算時才配置；每幀只畫算好的段、不配置。
-- addAreaHighlightForPlayer 每幀要重加：FBORenderAreaHighlights.render 丟掉 renderTimeMs 不是本幀 UI 時間的
-- （FBORenderAreaHighlights.java:61-68；LuaManager.java:12515-12521）。OnPreUIDraw 在設好本幀 UI 時間之後觸發
-- （UIManager.java:273-296）。

if not isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Settings"
require "MinidoracatSafehouse/Client"
require "MinidoracatSafehouse/PublicApi"

local MSH = MinidoracatSafehouse
local first = MSH.Ranges == nil
local R = MSH.Ranges or {}
MSH.Ranges = R

R.OPTIONS_ID = "MinidoracatSafehouse"
R.REACH = 100                                              -- 玩家離外框這麼多格以內才畫
R.KINDS = { "own", "shared", "faction", "others" }
-- 地面的顏色（半透明）；紅色留給建立面板標衝突，其他玩家的用紫色
R.COLORS = {
    own = { r = 1.0, g = 0.85, b = 0.4, a = 0.5 },
    shared = { r = 0.45, g = 0.8, b = 1.0, a = 0.5 },
    faction = { r = 0.5, g = 0.9, b = 0.45, a = 0.5 },
    others = { r = 0.8, g = 0.55, b = 1.0, a = 0.5 },
}
-- 管理視窗 chip 上的色塊（同色、不透明）
R.SWATCHES = {}
for k, c in pairs(R.COLORS) do R.SWATCHES[k] = { r = c.r, g = c.g, b = c.b, a = 1 } end
R.OPT_IDS = { own = "ShowOwn", shared = "ShowShared", faction = "ShowFaction", others = "ShowOthers" }
R.list = R.list or {}
R.allow = R.allow or { own = true, shared = true, faction = true, others = false }
R.session = R.session or { on = true, own = true, shared = true, faction = true, others = true }
R.dirty = true

-- 選項在檔案載入時登記：MainOptions 建立時 PZAPI.ModOptions:load 才讀得到存值（MainOptions.lua:2822-2823）
if first and PZAPI and PZAPI.ModOptions then
    local opts = PZAPI.ModOptions:create(R.OPTIONS_ID, "IGUI_MSH_Options_Title")
    R.opt = opts:addTickBox("ShowRanges", "IGUI_MSH_Manager_ShowRanges", true, "IGUI_MSH_Manager_ShowRanges_tooltip")
    R.kindOpt = {}
    for _, k in ipairs(R.KINDS) do
        R.kindOpt[k] = opts:addTickBox(R.OPT_IDS[k], "IGUI_MSH_Options_" .. R.OPT_IDS[k], true, "IGUI_MSH_Ranges_" .. k .. "_tooltip")
    end
    opts.apply = function() MSH.Ranges.changed() end
end

-- 開關或開放範圍變了：重算，管理視窗跟著重排
function R.changed()
    R.dirty = true
    MSH.Client.emit("ranges")
end

local function save()
    local ok, err = pcall(PZAPI.ModOptions.save, PZAPI.ModOptions)
    if not ok then MSH.log("ModOptions save failed: " .. tostring(err)) end
end

function R.isOn()
    if R.opt then return R.opt:getValue() == true end
    return R.session.on == true
end

-- 管理視窗的開關：寫進 ModOptions 並存檔（setValue 同步 ESC 頁元件，ModOptions.lua:68-73）
function R.setOn(on)
    on = on == true
    if R.opt then
        R.opt:setValue(on)
        save()
    else
        R.session.on = on
    end
    R.changed()
end

-- 玩家要不要看這一類（伺服器開不開放另看 R.allowed）
function R.kindOn(kind)
    local o = R.kindOpt and R.kindOpt[kind]
    if o then return o:getValue() == true end
    return R.session[kind] == true
end

function R.setKind(kind, on)
    on = on == true
    local o = R.kindOpt and R.kindOpt[kind]
    if o then
        o:setValue(on)
        save()
    else
        R.session[kind] = on
    end
    R.changed()
end

-- 伺服器開放的類別（沙盒）。讀 Settings 會配置，只在重算、排版時呼叫
function R.readAllow()
    local cfg = MSH.Settings.get()
    R.allow.faction, R.allow.others = cfg.rangesFaction == true, cfg.rangesOthers == true
end

function R.allowed(kind)
    return R.allow[kind] == true
end

function R.shown(kind)
    return R.isOn() and R.allowed(kind) and R.kindOn(kind)
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

-- 一個原生屬於哪一類（要不要畫由呼叫端照 R.shown 篩）。known＝清單快取（claimId → own｜shared）；me＝我的帳號名；
-- myFaction＝要畫同陣營或其他玩家時我的陣營，否則 nil（這時 managed 的屋主只在我是成員時才查，不為了分類去抓 registry）
-- Faction.getPlayerFaction／isOwner／isMember：Faction.java:123-138、150-160（客戶端的陣營清單由 MetaDataPacket、
-- FactionSyncPacket 同步）；SafeHouse.getPlayers :241
function R.kindOf(sh, id, known, me, myFaction)
    local kind = id and known[id] or nil
    if kind ~= nil or me == nil then return kind end
    local owner = sh:getOwner()
    local member = sh:getPlayers():contains(me)
    local name = nil
    if id == nil then
        name = owner
    elseif member or myFaction ~= nil then
        name = MSH.PublicApi.ownerName(owner)   -- managed 的名單含屋主（Native.desiredPlayers），要分自己的還是分享的
    end
    if name == me then return "own" end
    if member then return "shared" end
    if myFaction ~= nil and name ~= nil and (myFaction:isOwner(name) or myFaction:isMember(name)) then return "faction" end
    return "others"
end

-- 重算要畫的各間：原生清單（SafeHouse.java:652；getOwner :656、getX/getY/getW/getH :596-626）照標記分組
-- （原版或沒接管的每個原生自成一間），只留要畫的類別
function R.rebuild()
    R.dirty = false
    R.readAllow()
    local p = getSpecificPlayer(0)
    local me = p and p:getUsername() or nil
    local known = {}
    local claims = MSH.Client.claims
    for _, row in ipairs(claims.shared or {}) do known[row.claimId] = "shared" end
    for _, row in ipairs(claims.mine or {}) do known[row.claimId] = "own" end
    local myFaction = nil
    if me ~= nil and Faction ~= nil and (R.shown("faction") or R.shown("others")) then
        myFaction = Faction.getPlayerFaction(me)
    end
    local groups, order = {}, {}
    local list = SafeHouse.getSafehouseList()
    for i = 0, list:size() - 1 do
        local sh = list:get(i)
        local id = MSH.claimIdOf(sh:getOwner())
        local kind = R.kindOf(sh, id, known, me, myFaction)
        if kind ~= nil and R.shown(kind) then
            local key = id or sh
            local g = groups[key]
            if g == nil then
                g = { kind = kind, rects = {} }
                groups[key], order[#order + 1] = g, key
            end
            g.rects[#g.rects + 1] = { x = sh:getX(), y = sh:getY(), w = sh:getW(), h = sh:getH() }
        end
    end
    local out = {}
    for _, key in ipairs(order) do
        local g = groups[key]
        local b = MSH.Rect.bounds(g.rects)
        out[#out + 1] = { areas = R.outline(g.rects), x1 = b.x, y1 = b.y, x2 = b.x + b.w, y2 = b.y + b.h,
            color = R.COLORS[g.kind], kind = g.kind }
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
    MSH.Client.on("sandbox", "Ranges", function() MSH.Ranges.changed() end)
    Events.OnSafehousesChanged.Add(function() MSH.Ranges.dirty = true end)   -- LuaEventManager.java:775
    Events.SyncFaction.Add(function() MSH.Ranges.dirty = true end)           -- :770；FactionSyncPacket.java:68 等
    -- 屋主表到了（PublicApi 同一事件更新快取）：同陣營的才分得出來（:817）
    Events.OnReceiveGlobalModData.Add(function(tag) if tag == MSH.TAG then MSH.Ranges.dirty = true end end)
    Events.OnPreUIDraw.Add(function() MSH.Ranges.draw() end)
end
