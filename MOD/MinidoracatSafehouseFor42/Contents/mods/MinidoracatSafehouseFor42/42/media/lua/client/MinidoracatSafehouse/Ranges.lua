-- MinidoracatSafehouse/Ranges.lua — 在地面顯示範圍（客戶端）
-- 使用者 2026-10-11：「能不能增加安全屋範圍顯示開關在安全屋面板?這樣就能隨時知道自己的範圍吧」；2026-10-12：「打開就
-- 持續顯示，可以看隊友的，也能看其他玩家的，但是這些管理員面板跟沙盒也要可以設定，預設就開啟自己跟同陣營的，每一種都不同顏色顯示」。
-- 五類各一種顏色：自己的（屋主是我）、分享給我的（我在名單裡）、同陣營的（屋主和我同一個陣營）、其他玩家的，以及管理員設的
--   禁建區（使用者 2026-10-16「那玩家是不是也應該要可以從畫面上看到禁建區?」；清單由 Client.ensureZones 向伺服器要一次，
--   之後伺服器推 zonesSync，Zones.lua）。
-- 伺服器開放哪幾類：自己的、分享給我的與禁建區一定可以；同陣營的、其他玩家的看沙盒 RangesFaction（預設開）、RangesOthers（預設關）。
--   這只是畫面：原版本來就把每一間的範圍傳給所有客戶端（MetaDataPacket、SafehouseSync），改過的客戶端照樣看得到。
-- 玩家自己的開關：總開關（預設開）＋每一類（預設都開；伺服器沒開放的那類照樣不畫）＋整片顯示（RangesFill，預設關＝只畫
--   外緣；使用者 2026-10-16「畫面上顯示的區塊可以整片而不是只有邊框嗎?…或者做成切換開關顯示」）。存在 ModOptions（PZAPI.ModOptions，
--   B42 官方 API：引擎自己存讀 ModOptions.ini，MainOptions.lua:2805-2841、ModOptions.lua:259-333），ESC 選項的「模組」頁
--   也有同樣的開關（套用時 Options:apply，MainOptions.lua:3761-3763）；沒有 PZAPI 時只在這次遊戲有效。
-- 分類：清單快取（Client.claims）的我的、分享給我的先算；其餘原生照屋主：原版或沒接管的直接是 getOwner，
--   managed（@MSH:<id>）用 PublicApi.ownerName（公開的 registry 表，第一次查不到會抓整張表、有節流）；我在原生名單裡＝分享給我的。
--   只有我在陣營裡、而且同陣營或其他玩家那類要畫時（要分出是哪一類）才查 managed 的屋主：不在陣營的人不必為了分類去抓
--   registry。屋主還沒查到的先算其他玩家的。安全屋的四類互不重疊：關掉同陣營的，同陣營的屋不會改用其他玩家的顏色畫出來。
-- 暫停保護（lapsed）沒有原生，不畫。清單、原生、陣營（SyncFaction）、屋主表（OnReceiveGlobalModData）、沙盒（sandboxSync）、
--   禁建區清單（Client 事件 zones）或開關一變就標記重算，重算時才配置。
-- 畫法交給 FloorTint（安全屋在圖層 "ranges"、禁建區在 "rangeZones"，安全屋蓋過禁建區；建立面板的框選與標紅、管理員的
--   禁建區視窗蓋在它們上面）：格子平常是疊色（顏色帶 ov），在屋裡、前方有房子、有玩家站在附近的格子改用同一個顏色的地板
--   染色（FloorTint.lua 檔頭有為什麼）。整片時各塊本身先用較暗的 FILL_COLORS 放、外緣再用 COLORS 放（同一格後放的勝）。
--   每 SCAN_MS，或鏡頭移出 FloorTint 畫的範圍（畫面看得到的格子外加幾格）時，每一筆只走「這一筆的各塊 ∩ 新範圍」與
--   「∩ 舊範圍」的格子（R.light：舊範圍外的放、新範圍外的取消，兩邊都有的不動），不走整塊：禁建區外框可到 ZONE_SIDE，
--   整片時一塊就是一百萬格。整片時畫面看得到的格子最多全部疊色（sh-rangesov-1013d：1,225 格 243.4 FPS）。關掉、重算、
--   換樓層時全部取消。

if not isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Settings"
require "MinidoracatSafehouse/Client"
require "MinidoracatSafehouse/PublicApi"
require "MinidoracatSafehouse/FloorTint"
require "MinidoracatSafehouse/Select"

local MSH = MinidoracatSafehouse
local first = MSH.Ranges == nil
local R = MSH.Ranges or {}
MSH.Ranges = R

R.OPTIONS_ID = "MinidoracatSafehouse"
R.SCAN_MS = 500                                            -- 多久掃一次附近的外緣格
-- 整片顯示時內部的顏色（R.FILL_COLORS，照 R.COLORS 算）：疊色 rgb 乘 FILL_DIM、透明度不變；改染色時往顏色拉的比例
-- FILL_TINT_A。外緣照 R.COLORS。疊色的透明度幾乎沒作用，調不淡（sh-zview-1016b：內部 0.25、0.1、0.05 拍起來一樣，
-- 0.25 和外緣 0.45 也只差一點），所以內部改調暗：sh-zview-1016c 比了 0.6 與 0.35，0.6 內部仍看得出顏色、外緣明顯
R.FILL_DIM = 0.6
R.FILL_TINT_A = 0.6
R.KINDS = { "own", "shared", "faction", "others", "zones" }
-- 每一類兩種畫法的顏色：r, g, b, a 是地板染色用的（a 是往這個顏色拉的比例，Color.tintABGR，Color.java:243-253），
-- ov 是疊色用的（a 是透明度）。疊色照 alpha 混進地面，任何地面上都是同一個色相；截圖量到的比照 alpha 混合算出來的亮
-- （原因沒查），所以 rgb 寫暗一點（sh-overlay-1012a：未調暗時 0.45 的透明度在草地上已經到 255）。使用者 2026-10-12 要「和
-- 面板一樣」「再高亮一點」，2026-10-13 要「有明顯區分，並且面板上的顏色不要差太多」：我的青（和建立面板的框選同一個
-- 色系，Select.FLOOR_OK）、分享給我的藍、同陣營橘、其他玩家洋紅；紅色留給建立面板的標紅與禁建區。禁建區是亮紅疊色
-- （使用者 2026-10-16「顏色可以調亮」：原本 errorText 染色 0.85 在泥土路上是暗紅褐色、和土色分不清，報告
-- safehouse-zones-1016 第 1 段第 4 張）；禁建區視窗與新增禁建區面板也用它。
-- 染色是乘在地板上：草地上青變綠、藍近黑、洋紅變暗紅（sh-tintbright-1012b），只在被擋住或人物蓋著的那幾格看得到。
local OK = MSH.Select.FLOOR_OK
R.COLORS = {
    own = { r = OK.r, g = OK.g, b = OK.b, a = 1.0, ov = { r = 0.0, g = 0.67, b = 0.84, a = 0.45 } },
    shared = { r = 0.35, g = 0.5, b = 1.0, a = 1.0, ov = { r = 0.05, g = 0.27, b = 0.93, a = 0.45 } },
    faction = { r = 1.0, g = 0.55, b = 0.1, a = 1.0, ov = { r = 0.8, g = 0.36, b = 0.02, a = 0.45 } },
    others = { r = 1.0, g = 0.35, b = 0.95, a = 1.0, ov = { r = 0.71, g = 0.05, b = 0.8, a = 0.45 } },
    zones = { r = 1.0, g = 0.3, b = 0.3, a = 1.0, ov = { r = 1.0, g = 0.08, b = 0.08, a = 0.5 } },
}
R.FILL_COLORS = {}
for kind, c in pairs(R.COLORS) do
    R.FILL_COLORS[kind] = { r = c.r, g = c.g, b = c.b, a = R.FILL_TINT_A,
        ov = { r = c.ov.r * R.FILL_DIM, g = c.ov.g * R.FILL_DIM, b = c.ov.b * R.FILL_DIM, a = c.ov.a } }
end
-- 管理視窗 chip 上的色塊是地上實際看到的疊色（使用者 2026-10-12：「按鈕顏色，應該要更接近一點實際顏色，避免誤會」）：
-- sh-rangesov-1013b 白天草地與人行道兩處的中位數平均（四類兩兩的色差在兩種地面上都 ≥ 54）；禁建區是 sh-zones-1016d
-- zn-a02 草地與泥土上的中位數
R.SWATCHES = {
    own = { r = 0.07, g = 0.7, b = 0.82, a = 1 },
    shared = { r = 0.26, g = 0.48, b = 0.98, a = 1 },
    faction = { r = 1.0, g = 0.61, b = 0.2, a = 1 },
    others = { r = 0.81, g = 0.14, b = 0.85, a = 1 },
    zones = { r = 0.94, g = 0.12, b = 0.07, a = 1 },
}
R.OPT_IDS = { own = "ShowOwn", shared = "ShowShared", faction = "ShowFaction", others = "ShowOthers", zones = "ShowZones" }
R.list = R.list or {}
R.allow = R.allow or { own = true, shared = true, faction = true, others = false }
R.allow.zones = true   -- 伺服器不設限
R.session = R.session or { on = true, own = true, shared = true, faction = true, others = true, zones = true, fill = false }
R.walked = 0           -- R.light／R.dim 走過的格子數（harness 看有沒有走整塊）
R.dirty = true

-- 選項在檔案載入時登記：MainOptions 建立時 PZAPI.ModOptions:load 才讀得到存值（MainOptions.lua:2822-2823）
if first and PZAPI and PZAPI.ModOptions then
    local opts = PZAPI.ModOptions:create(R.OPTIONS_ID, "IGUI_MSH_Options_Title")
    R.opt = opts:addTickBox("ShowRanges", "IGUI_MSH_Manager_ShowRanges", true, "IGUI_MSH_Manager_ShowRanges_tooltip")
    R.kindOpt = {}
    for _, k in ipairs(R.KINDS) do
        R.kindOpt[k] = opts:addTickBox(R.OPT_IDS[k], "IGUI_MSH_Options_" .. R.OPT_IDS[k], true, "IGUI_MSH_Ranges_" .. k .. "_tooltip")
    end
    R.fillOpt = opts:addTickBox("RangesFill", "IGUI_MSH_Options_RangesFill", false, "IGUI_MSH_Manager_RangesFill_tooltip")
    opts.apply = function() MSH.Ranges.changed() end
    -- 原版主選單沒有任何 MOD 建選項時按套用，會把整個 ModOptions.ini 清成 0 byte，這一頁的值就全回預設：框架 rev 23 的
    -- ModOptionsBackup 補回（../MinidoracatUIFor42/docs/ARCHITECTURE.md §3.23）。放 OnGameBoot：StoragePanel 的 StorageGrid
    -- 那時也加完了，又早於 MainOptions 建立時的 load（OnMainMenuEnter），補回的值才會被那次 load 套上
    Events.OnGameBoot.Add(function()
        local UI = MSH.Client.ui({ "modOptionsBackup" }, 23)
        local restored = UI and UI.ModOptionsBackup and UI.ModOptionsBackup.protect(opts)
        if type(restored) == "number" and restored > 0 then
            MSH.log("restored " .. restored .. " settings from the backup (ModOptions.ini was wiped)")
        end
    end)
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

-- 整片顯示（關著＝只畫外緣）
function R.isFill()
    if R.fillOpt then return R.fillOpt:getValue() == true end
    return R.session.fill == true
end

function R.setFill(on)
    on = on == true
    if R.fillOpt then
        R.fillOpt:setValue(on)
        save()
    else
        R.session.fill = on
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

-- 一筆要畫的：外緣 areas（扁平 x, y, w, h）、外框 x1..x2、y1..y2（半開）、顏色、圖層；整片時另有 fill（各塊本身）與內部較暗的顏色
local function entry(kind, rects)
    local b = MSH.Rect.bounds(rects)
    local c = { areas = R.outline(rects), x1 = b.x, y1 = b.y, x2 = b.x + b.w, y2 = b.y + b.h,
        color = R.COLORS[kind], kind = kind, layer = kind == "zones" and "rangeZones" or "ranges" }
    if R.isFill() then
        local f = {}
        for i, r in ipairs(rects) do f[i * 4 - 3], f[i * 4 - 2], f[i * 4 - 1], f[i * 4] = r.x, r.y, r.w, r.h end
        c.fill, c.fillColor = f, R.FILL_COLORS[kind]
    end
    return c
end

-- 重算要畫的各間：原生清單（SafeHouse.java:652；getOwner :656、getX/getY/getW/getH :596-626）照標記分組
-- （原版或沒接管的每個原生自成一間），只留要畫的類別；禁建區要畫時每個一筆（清單還沒拿到就先不畫，到了發 zones 事件再重算）
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
        out[#out + 1] = entry(g.kind, g.rects)
    end
    if R.shown("zones") then
        for _, z in ipairs(MSH.Client.ensureZones() or {}) do out[#out + 1] = entry("zones", z.rects) end
    end
    R.list = out
end

-- 每幀只比時間與染色範圍；到了 SCAN_MS、標記重算或鏡頭移出了染色範圍，才把外緣格交給 FloorTint
function R.update()
    local now = getTimestampMs()
    local p = getSpecificPlayer(0)
    local on = p ~= nil and R.isOn()
    local z = on and math.floor(p:getZ()) or nil   -- IsoMovingObject.java:525
    local v = on and MSH.FloorTint.window(z) or nil
    local seq = v and v.seq
    if not R.dirty and now < (R.nextScan or 0) and seq == R.seq then return end
    R.nextScan, R.seq = now + R.SCAN_MS, seq
    if R.dirty then
        R.dimAll()
        R.rebuild()
    end
    if not on then return R.dimAll() end
    -- 禁建區清單還沒拿到（上一次失敗）：每次掃描問一次，Client 自己管間隔
    if MSH.Client.zones.list == nil and R.shown("zones") then MSH.Client.ensureZones() end
    if z ~= R.litZ then
        R.dimAll()
        R.litZ = z
    end
    local list, cell = R.list, getCell()
    for i = 1, #list do
        local c = list[i]
        if c.x2 > v.x0 and c.x1 <= v.x1 and c.y2 > v.y0 and c.y1 <= v.y1 then
            R.light(c, cell, z, v)
        else
            R.dim(c)
        end
    end
end

local NONE = {}

local function act(Tint, cell, layer, x, y, z, col)
    if col then Tint.put(cell, layer, x, y, z, col) else Tint.remove(cell, layer, x, y, z) end
end

-- 扁平矩形 a（x, y, w, h…）在 x0..x1、y0..y1（含）裡的格子，跳過 keep 範圍 kx0..kx1、ky0..ky1（含；kx0 是 nil＝不跳）
-- 裡的：col 有值就交出這個顏色，沒有就取消。只走交集，跳過的那段整段略過；回走過的格子數
local function paint(a, x0, y0, x1, y1, kx0, ky0, kx1, ky1, cell, layer, z, col)
    local Tint, n = MSH.FloorTint, 0
    for k = 1, #a, 4 do
        local ax0, ay0 = math.max(a[k], x0), math.max(a[k + 1], y0)
        local ax1, ay1 = math.min(a[k] + a[k + 2] - 1, x1), math.min(a[k + 1] + a[k + 3] - 1, y1)
        for x = ax0, ax1 do
            local skip = kx0 ~= nil and x >= kx0 and x <= kx1
            local top = skip and math.min(ay1, ky0 - 1) or ay1
            for y = ay0, top do act(Tint, cell, layer, x, y, z, col) end
            if top >= ay0 then n = n + top - ay0 + 1 end
            if skip then
                local from = math.max(ay0, ky1 + 1)
                for y = from, ay1 do act(Tint, cell, layer, x, y, z, col) end
                if ay1 >= from then n = n + ay1 - from + 1 end
            end
        end
    end
    return n
end

-- 這一筆在染色範圍 v 裡的格子交給 FloorTint（c.layer）：上次放到的範圍（c.lx0..c.ly1、c.litZ）裡不在新範圍的取消、新範圍
-- 裡上次沒放的放上（整片時先放各塊的內部顏色、再放外緣），兩邊都有的不動。只走「這一筆 ∩ 範圍」，不走整塊；同一層、同一個
-- 範圍就不跑
function R.light(c, cell, z, v)
    local x0, y0 = math.max(v.x0, c.x1), math.max(v.y0, c.y1)
    local x1, y1 = math.min(v.x1, c.x2 - 1), math.min(v.y1, c.y2 - 1)
    local oz, ox0, oy0, ox1, oy1 = c.litZ, c.lx0, c.ly0, c.lx1, c.ly1
    if oz == z and ox0 == x0 and oy0 == y0 and ox1 == x1 and oy1 == y1 then return end
    local layer, fill, n = c.layer, c.fill or NONE, 0
    local newOk = x0 <= x1 and y0 <= y1
    local oldOk = oz ~= nil and ox0 <= ox1 and oy0 <= oy1
    local same = oz == z and newOk and oldOk
    if oldOk then
        local kx0, ky0, kx1, ky1 = nil, nil, nil, nil
        if same then kx0, ky0, kx1, ky1 = x0, y0, x1, y1 end
        n = paint(fill, ox0, oy0, ox1, oy1, kx0, ky0, kx1, ky1, cell, layer, oz, nil)
            + paint(c.areas, ox0, oy0, ox1, oy1, kx0, ky0, kx1, ky1, cell, layer, oz, nil)
    end
    if newOk then
        local kx0, ky0, kx1, ky1 = nil, nil, nil, nil
        if same then kx0, ky0, kx1, ky1 = ox0, oy0, ox1, oy1 end
        n = n + paint(fill, x0, y0, x1, y1, kx0, ky0, kx1, ky1, cell, layer, z, c.fillColor)
            + paint(c.areas, x0, y0, x1, y1, kx0, ky0, kx1, ky1, cell, layer, z, c.color)
    end
    c.litZ, c.lx0, c.ly0, c.lx1, c.ly1 = z, x0, y0, x1, y1
    R.walked = R.walked + n
end

-- 取消這一筆上次放到的格子（框選蓋在上面的格子照樣是框選的顏色）
function R.dim(c)
    local z = c.litZ
    if z == nil then return end
    c.litZ = nil
    local cell, x0, y0, x1, y1 = getCell(), c.lx0, c.ly0, c.lx1, c.ly1
    R.walked = R.walked + paint(c.fill or NONE, x0, y0, x1, y1, nil, nil, nil, nil, cell, c.layer, z, nil)
        + paint(c.areas, x0, y0, x1, y1, nil, nil, nil, nil, cell, c.layer, z, nil)
end

function R.dimAll()
    MSH.FloorTint.clear("ranges")
    MSH.FloorTint.clear("rangeZones")
    for i = 1, #R.list do R.list[i].litZ = nil end
end

if first then
    MSH.Client.on("claims", "Ranges", function() MSH.Ranges.dirty = true end)
    MSH.Client.on("zones", "Ranges", function() MSH.Ranges.dirty = true end)
    MSH.Client.on("sandbox", "Ranges", function() MSH.Ranges.changed() end)
    Events.OnSafehousesChanged.Add(function() MSH.Ranges.dirty = true end)   -- LuaEventManager.java:775
    Events.SyncFaction.Add(function() MSH.Ranges.dirty = true end)           -- :770；FactionSyncPacket.java:68 等
    -- 屋主表到了（PublicApi 同一事件更新快取）：同陣營的才分得出來（:817）
    Events.OnReceiveGlobalModData.Add(function(tag) if tag == MSH.TAG then MSH.Ranges.dirty = true end end)
    Events.OnPreUIDraw.Add(function() MSH.Ranges.update() end)
end
