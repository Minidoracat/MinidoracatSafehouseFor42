-- MinidoracatSafehouse/PermissionsClient.lua：細分權限的客戶端體驗（計畫 §6.6，契約「M2 細分權限」）。
-- 只是體驗，伺服器才是防線（server/MinidoracatSafehouse/Permissions.lua）：
--   1) 世界右鍵選單：藏掉本地玩家在該格沒有權限的原版選項。OnFillWorldObjectContextMenu 在原版選項建好之後觸發
--      （ISWorldObjectContextMenu.lua:211-214）；以選項的處理函式比對（addGetUpOption 把真正的處理函式放在 param1，
--      ISContextMenu.lua:1038-1044），不比文字，換語系照樣對得上。子選單都登記在根選單的 instanceMap（:1199-1231）。
--      「撬開」（42.22 onForceOpen）與拆路障照門窗兩側判斷，和伺服器同一份格子清單（MSH.edgeCells、PC.edgeHides）。
--   2) 爐子／微波爐設定面板：沒有 USE 時藏掉 OK 鈕並擋 onClick（ISOvenUI.lua:157-171、ISMicrowaveUI.lua:31-37）；
--      開面板的選單項目（onStoveSetting／onMicrowaveSetting）也照 1) 藏。
--   3) 伺服器推 denied：MSH.Client.toast（框架 Toast，沒有框架就頭上紅字）說缺哪個權限。
--   4) 梯子（42.22）：爬上去或爬下來會進到自己不能進的安全屋時，不列「爬梯子」、按鍵與動作也不啟動（PC.ladderBlocked）。
--      爬梯只在客戶端執行，伺服器看不到；進去之後原版照舊定期把人移出去。
-- 位元來自 MSH.Client.bitsAt(x, y)（nil＝不是 managed → 照原版；只有 0 號玩家有清單）。

if not isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Client"

local MSH = MinidoracatSafehouse
local first = MSH.PermissionsClient == nil
local PC = MSH.PermissionsClient or {}
MSH.PermissionsClient = PC

local BIT = MSH.SHARE

-- 藏不藏：bits 是 bitsAt 的結果；nil＝不在 managed claim
function PC.hides(bits, bit)
    return bits ~= nil and not MSH.hasBit(bits, bit)
end

-- { 全域表名, 位元, { 處理函式欄位 } }：只列伺服器會擋的動作的入口（Permissions.lua 的包裝對象）
PC.HANDLERS = {
    { "ISWorldObjectContextMenu", BIT.USE, { "onToggleLight", "onLightBulb", "onLightModify", "onLightBattery",
        "onToggleStove", "onStoveSetting", "onMicrowaveSetting",
        "onPlugGenerator", "onActivateGenerator", "doAddFuelGenerator", "onFixGenerator", "onTakeWater", "onDrink",
        "onFluidTransfer" } },   -- :1327, 1352, 1364, 1377, 1188, 1202, 1195, 540, 547, 648（加油子選單的每一項）, 554, 2045, 2033, 2829
    { "ISWorldObjectContextMenu", BIT.MOVE, { "onTakeGenerator" } },                                  -- :665
    { "ISRadioAndTvMenu", BIT.USE, { "openTvPanel" } },                                               -- ISRadioAndTvMenu.lua:8（世界上的電視／收音機）
    { "ISDisassembleMenu", BIT.MOVE, { "disassemble" } },                                             -- ISDisassembleMenu.lua:83（ISMoveablesAction scrap）
    { "ISWorldObjectContextMenu", BIT.BUILD, { "onDestroy", "onBarricade", "onUnbarricade", "onUnbarricadeMetal",
        "onUnbarricadeMetalBar" } },                                                                  -- :822, 3082, 2131, 2140, 2148
    { "ISFarmingMenu", BIT.FARM, { "onPlow", "onSeed", "onHarvest", "onWater", "onFliesCure", "onMildewCure",
        "onSlugsCure", "onAphidsCure", "onShovel", "onFertilize", "onCompost" } },                  -- ISFarmingMenu.lua:1257, 1192, 647, 951, 788, 732, 845, 902, 1301, 1316, 1334
}

-- 要藏的處理函式集合 { [fn] = true }；沒有要藏的回 nil。每次開選單才讀全域（原版熱重載後照樣對得上）
function PC.blockedHandlers(bits)
    local out, any = {}, false
    for _, h in ipairs(PC.HANDLERS) do
        local t = _G[h[1]]
        if PC.hides(bits, h[2]) and type(t) == "table" then
            for _, field in ipairs(h[3]) do
                local fn = t[field]
                if fn ~= nil then
                    out[fn] = true
                    any = true
                end
            end
        end
    end
    if any then return out end
    return nil
end

local function handlerOf(o)
    if o.onSelect ~= nil and o.onSelect == ISContextMenu.onGetUpAndThen then return o.param1 end
    return o.onSelect
end

-- 就地移掉符合的項目、重排 id（照 ISContextMenu:removeOptionByName :1016-1036；numOptions＝項目數＋1，:882-883）
local function prune(menu, drop)
    local kept, removed = {}, 0
    for _, o in ipairs(menu.options) do
        if drop(o) then
            removed = removed + 1
            if menu.optionPool then table.insert(menu.optionPool, o) end
        else
            kept[#kept + 1] = o
            o.id = #kept
        end
    end
    if removed == 0 then return 0 end
    local n = #menu.options
    for i = 1, n do menu.options[i] = kept[i] end
    menu.numOptions = menu.numOptions - removed
    menu:calcHeight()
    return removed
end

-- 選項帶的門窗：addGetUpOption 時 param1＝處理函式、param2＝worldobjects、param3＝門窗（ISContextMenu.lua:1038-1043；
-- ISWorldObjectContextMenuLogic.java:1845-1849, 2312-2319, 2452-2456），直接 addOption 時是 param1
local function edgeTarget(o)
    if o.onSelect == ISContextMenu.onGetUpAndThen then return o.param3 end
    return o.param1
end

-- 選項帶著門窗物件、照門窗兩側判斷的處理函式（都要 BUILD）：撬開、拆路障
PC.EDGE_HANDLERS = { "onForceOpen", "onUnbarricade", "onUnbarricadeMetal", "onUnbarricadeMetalBar" }

-- 物件要查的格子（MSH.edgeCells：邊上的物件是兩側）任一格要藏就藏；伺服器 Permissions.lua 用同一份清單
function PC.edgeHides(obj, bit)
    local cells = MSH.edgeCells(obj)
    for i = 1, #cells, 2 do
        if PC.hides((MSH.Client.bitsAt(cells[i], cells[i + 1])), bit) then return true end
    end
    return false
end

-- 梯子（圖塊屬性 ladderN/S/E/W）：往上是從梯子那格爬到上一層、往屬性的方向走出去；往下是從那個出口爬回梯子那格
-- （IsoGridSquare.getLadderUnder，IsoGridSquare.java:11870-11892；ISWorldObjectContextMenu.lua:2188-2195 同一組屬性）。
-- 梯子那格或出口那格在這個人不能進的安全屋裡就擋；判定和走路、擋車同一套（SafeHouse.isSafehouseAllowTrepass，
-- SafeHouse.java:224-243：屋主、名單、管理員能力、伺服器選項），它要一格，取 z＝0 那格（安全屋是平面範圍）。
function PC.ladderBlocked(playerObj, ladder)
    local sq = ladder ~= nil and ladder:getSquare() or nil
    if playerObj == nil or sq == nil then return false end
    local props = ladder:getProperties()
    if props == nil then return false end
    local x, y = sq:getX(), sq:getY()
    local ex, ey = x, y
    if props:has(IsoPropertyType.LADDER_N) then ey = y - 1
    elseif props:has(IsoPropertyType.LADDER_S) then ey = y + 1
    elseif props:has(IsoPropertyType.LADDER_W) then ex = x - 1
    elseif props:has(IsoPropertyType.LADDER_E) then ex = x + 1 end
    local cell = getCell()
    return not SafeHouse.isSafehouseAllowTrepass(cell:getGridSquare(x, y, 0), playerObj)
        or not SafeHouse.isSafehouseAllowTrepass(cell:getGridSquare(ex, ey, 0), playerObj)
end

-- 「爬梯子」選項的玩家與梯子：addGetUpOption(文字, 格子, onClimbLadder, down, playerObj, ladder)
-- （ISWorldObjectContextMenuLogic.java:942-962）→ param4、param5；直接 addOption 時是 param2、param3
local function ladderArgs(o)
    if o.onSelect == ISContextMenu.onGetUpAndThen then return o.param4, o.param5 end
    return o.param2, o.param3
end

-- 回傳移掉的項目數；子選單因此變空時，連父項目一起拿掉（例如燈的開關子選單）。
-- 撬開、拆路障、爬梯子不只看點的那一格，所以點的格子沒有要藏的處理函式也要走一遍
function PC.filterMenu(context, bits)
    local W = ISWorldObjectContextMenu
    if type(W) ~= "table" then return 0 end
    local blocked = PC.blockedHandlers(bits)
    local edge = {}
    for _, field in ipairs(PC.EDGE_HANDLERS) do
        if W[field] ~= nil then edge[W[field]] = true end
    end
    local climb = W.onClimbLadder
    local subs = context.instanceMap or {}
    local menus = { context }
    for _, m in pairs(subs) do menus[#menus + 1] = m end
    local n = 0
    for _, m in ipairs(menus) do
        n = n + prune(m, function(o)
            local fn = handlerOf(o)
            if fn == nil then return false end
            if blocked ~= nil and blocked[fn] == true then return true end
            if edge[fn] == true then return PC.edgeHides(edgeTarget(o), BIT.BUILD) end
            return fn == climb and PC.ladderBlocked(ladderArgs(o))
        end)
    end
    if n > 0 then
        for _, m in ipairs(menus) do
            prune(m, function(o)
                local sub = o.subOption ~= nil and subs[o.subOption] or nil
                return sub ~= nil and #sub.options == 0
            end)
        end
    end
    return n
end

-- 世界物件所在格的權限（IsoObject:getSquare）
function PC.blockedAt(obj, bit)
    local sq = obj ~= nil and obj:getSquare() or nil
    if sq == nil then return false end
    return PC.hides((MSH.Client.bitsAt(sq:getX(), sq:getY())), bit)
end

-- 分割畫面次玩家沒有自己的清單（Client.lua 一律用 0 號玩家），不動他的選單
function PC.onFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
    if test or playerNum ~= 0 or type(worldobjects) ~= "table" or worldobjects[1] == nil then return end
    local sq = worldobjects[1]:getSquare()
    if sq == nil then return end
    PC.filterMenu(context, (MSH.Client.bitsAt(sq:getX(), sq:getY())))
end

-- 面板的 self.oven 是 IsoStove（ISOvenUI.lua:97、ISMicrowaveUI.lua:65）；OK 鈕建立時才取 cls.onClick，所以開局就要包好
local function wrapOvenPanel(cls)
    if type(cls) ~= "table" or type(cls.updateButtons) ~= "function" or type(cls.onClick) ~= "function" then return end
    local oUpdate, oClick = cls.updateButtons, cls.onClick
    cls.updateButtons = function(self)
        oUpdate(self)
        self.ok:setVisible(not PC.blockedAt(self.oven, BIT.USE))
    end
    cls.onClick = function(self, button)
        if button ~= nil and button.internal == "OK" and PC.blockedAt(self.oven, BIT.USE) then return end
        return oClick(self, button)
    end
end

-- 爬梯子的兩個入口：選單與互動鍵都進 onClimbLadder（ISContextualActions.lua:19-24），其他程式直接排的動作經過 isValid
-- （ISClimbLadderAction.lua:5-11）。onClimbLadder 擋下時不走過去，說明原因；isValid 只回 false。
local function wrapLadder()
    local W, A = ISWorldObjectContextMenu, ISClimbLadderAction
    if type(W) == "table" and type(W.onClimbLadder) == "function" then
        local orig = W.onClimbLadder
        W.onClimbLadder = function(square, down, playerObj, ladder)
            if PC.ladderBlocked(playerObj, ladder) then
                MSH.Client.toast(getText("IGUI_MSH_Ladder_Blocked"), playerObj)
                return
            end
            return orig(square, down, playerObj, ladder)
        end
    end
    if type(A) == "table" and type(A.isValid) == "function" then
        local orig = A.isValid
        A.isValid = function(self)
            if PC.ladderBlocked(self.character, self.ladder) then return false end
            return orig(self)
        end
    end
end

function PC.install()
    if PC.installed then return end
    PC.installed = true
    wrapOvenPanel(ISOvenUI)
    wrapOvenPanel(ISMicrowaveUI)
    wrapLadder()
end

PC.BIT_KEYS = { [BIT.USE] = "USE", [BIT.MOVE] = "MOVE", [BIT.BUILD] = "BUILD", [BIT.FARM] = "FARM" }

function PC.deniedText(args)
    local name = PC.BIT_KEYS[args.bit]
    if name == nil then return (MSH.Client.codeText(args.code or MSH.CODE.PERM_DENIED)) end
    -- 權限名用分享頁 chip 的同一個詞（IGUI_MSH_Share_Bit_*），玩家才知道要跟屋主要哪一個
    return getText("IGUI_MSH_Perm_Denied", getText("IGUI_MSH_Share_Bit_" .. name))
end

function PC.onDenied(args)
    MSH.Client.toast(PC.deniedText(args))
end

MSH.Client.on("denied", "permissions", function(args) MSH.PermissionsClient.onDenied(args) end)

if first then
    Events.OnFillWorldObjectContextMenu.Add(function(playerNum, context, worldobjects, test)
        MSH.PermissionsClient.onFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
    end)
    Events.OnGameStart.Add(function() MSH.PermissionsClient.install() end)
end
