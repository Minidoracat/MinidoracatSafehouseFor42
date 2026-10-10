-- MinidoracatSafehouse/PermissionsClient.lua：細分權限的客戶端體驗（計畫 §6.6，契約「M2 細分權限」）。
-- 只是體驗，伺服器才是防線（server/MinidoracatSafehouse/Permissions.lua）：
--   1) 世界右鍵選單：藏掉本地玩家在該格沒有權限的原版選項。OnFillWorldObjectContextMenu 在原版選項建好之後觸發
--      （ISWorldObjectContextMenu.lua:211-214）；以選項的處理函式比對（addGetUpOption 把真正的處理函式放在 param1，
--      ISContextMenu.lua:1038-1044），不比文字，換語系照樣對得上。子選單都登記在根選單的 instanceMap（:1199-1231）。
--   2) 爐子／微波爐設定面板：沒有 USE 時藏掉 OK 鈕並擋 onClick（ISOvenUI.lua:157-171、ISMicrowaveUI.lua:31-37）；
--      開面板的選單項目（onStoveSetting／onMicrowaveSetting）也照 1) 藏。
--   3) 伺服器推 denied：框架 Toast（toast capability），沒有框架就原版 HaloTextHelper.addBadText
--      （characters/HaloTextHelper.java:139；用例 ISWorldObjectContextMenu.lua:1038）。
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
    { "ISWorldObjectContextMenu", BIT.USE, { "onToggleLight", "onToggleStove", "onStoveSetting", "onMicrowaveSetting",
        "onPlugGenerator", "onActivateGenerator", "onTakeWater", "onDrink", "onFluidTransfer" } },   -- :1328, 1189, 1203, 1196, 540, 547, 2050, 2038, 2793
    { "ISRadioAndTvMenu", BIT.USE, { "openTvPanel" } },                                               -- ISRadioAndTvMenu.lua:8（世界上的電視／收音機）
    { "ISDisassembleMenu", BIT.MOVE, { "disassemble" } },                                             -- ISDisassembleMenu.lua:83（ISMoveablesAction scrap）
    { "ISWorldObjectContextMenu", BIT.BUILD, { "onDestroy", "onBarricade", "onUnbarricade", "onUnbarricadeMetal",
        "onUnbarricadeMetalBar" } },                                                                  -- :822, 3046, 2136, 2145, 2153
    { "ISFarmingMenu", BIT.FARM, { "onPlow", "onSeed", "onHarvest", "onWater", "onFliesCure", "onMildewCure",
        "onSlugsCure", "onAphidsCure" } },                                                            -- ISFarmingMenu.lua:1150, 1085, 572, 854, 703, 651, 756, 809
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

-- 回傳移掉的項目數；子選單因此變空時，連父項目一起拿掉（例如燈的開關子選單）
function PC.filterMenu(context, bits)
    local blocked = PC.blockedHandlers(bits)
    if blocked == nil then return 0 end
    local subs = context.instanceMap or {}
    local menus = { context }
    for _, m in pairs(subs) do menus[#menus + 1] = m end
    local n = 0
    for _, m in ipairs(menus) do
        n = n + prune(m, function(o)
            local fn = handlerOf(o)
            return fn ~= nil and blocked[fn] == true
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

function PC.install()
    if PC.installed then return end
    PC.installed = true
    wrapOvenPanel(ISOvenUI)
    wrapOvenPanel(ISMicrowaveUI)
end

PC.BIT_KEYS = { [BIT.USE] = "USE", [BIT.MOVE] = "MOVE", [BIT.BUILD] = "BUILD", [BIT.FARM] = "FARM" }

function PC.deniedText(args)
    local name = PC.BIT_KEYS[args.bit]
    if name == nil then return (MSH.Client.codeText(args.code or MSH.CODE.PERM_DENIED)) end
    return getText("IGUI_MSH_Perm_Denied", getText("IGUI_MSH_Perm_" .. name))
end

function PC.onDenied(args)
    local text = PC.deniedText(args)
    local UI = MSH.Client.ui({ "toast" }, 1)
    if UI ~= nil then
        -- 單行會截掉權限名（2026-10-11 法文實機「Vous n'avez pas la permission « Cu…」）；maxLines 自 rev 5（框架 ARCHITECTURE §3.4）
        UI.Toast.show({ message = text, maxLines = 3 })
        return
    end
    local player = getSpecificPlayer(0)
    if player ~= nil then HaloTextHelper.addBadText(player, text) end
end

MSH.Client.on("denied", "permissions", function(args) MSH.PermissionsClient.onDenied(args) end)

if first then
    Events.OnFillWorldObjectContextMenu.Add(function(playerNum, context, worldobjects, test)
        MSH.PermissionsClient.onFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
    end)
    Events.OnGameStart.Add(function() MSH.PermissionsClient.install() end)
end
