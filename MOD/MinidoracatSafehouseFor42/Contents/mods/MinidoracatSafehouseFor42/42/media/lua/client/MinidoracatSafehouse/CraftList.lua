-- MinidoracatSafehouse/CraftList.lua — 製作視窗只列沙盒開放的地契配方（客戶端）
-- 使用者 2026-10-14：「我們雖然有分製作難度，但是玩家表示製作表全部都看的到，這可能會讓玩家困惑，可以只顯示我們設定的種類嗎?」
-- 原版手作視窗靠 OnAddToMenu 藏（Recipes.lua）。Neat Crafting（Workshop 3502080466）換掉整個視窗、不呼叫 OnAddToMenu；
--   它列清單的路徑全部經過 NC_FilterBar:shouldIncludeRecipe（NC_FilterBar.lua:351、562、608、630），所以只包這一個：
--   被沙盒關掉的地契變體回 false，其餘照原函式。客戶端 Lua 照路徑載入，client/MinidoracatSafehouse 在 client/Neat_Crafting
--   之前，載入時它還不存在，等 OnGameStart 再包；同一張類別表只包一次（熱重載不疊）。
-- 管理員在遊戲中改難度（Mirror sandboxSync → emit "sandbox"）：已開的製作視窗強制重建清單，不必關掉重開。
--   視窗登記在 ISEntityUI.players[玩家].windows[鍵].instance（關掉就清成 nil，ISEntityUI.lua:407、477）；
--   原版 instance.handCraftPanel:refreshRecipeList(true)（ISHandcraftWindow.lua:49、ISHandCraftPanel.lua:176），
--   Neat Crafting instance.HandCraftPanel:updateRecipeDisplay()（NC_HandcraftWindow.lua:321、NC_EntityWindow.lua:219、
--   NC_handcraftPanel.lua:661）。鍵名不寫死，逐個看。

if not isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Recipes"
require "MinidoracatSafehouse/Client"

local MSH = MinidoracatSafehouse
local first = MSH.CraftList == nil
local L = MSH.CraftList or {}
MSH.CraftList = L

function L.wrapNeatCrafting()
    local F = NC_FilterBar
    if type(F) ~= "table" or type(F.shouldIncludeRecipe) ~= "function" or F.mshDeedFilter then return false end
    local orig = F.shouldIncludeRecipe
    F.shouldIncludeRecipe = function(self, recipe)
        if recipe ~= nil and MSH.deedRecipeHidden(recipe:getName()) then return false end
        return orig(self, recipe)
    end
    F.mshDeedFilter = true
    return true
end

function L.refreshOpen()
    for _, p in pairs(ISEntityUI and ISEntityUI.players or {}) do
        for _, w in pairs(p.windows or {}) do
            local inst = w.instance
            if inst ~= nil then
                if inst.HandCraftPanel ~= nil and inst.HandCraftPanel.updateRecipeDisplay then
                    inst.HandCraftPanel:updateRecipeDisplay()
                end
                if inst.handCraftPanel ~= nil and inst.handCraftPanel.refreshRecipeList then
                    inst.handCraftPanel:refreshRecipeList(true)
                end
            end
        end
    end
end

if first then
    Events.OnGameStart.Add(function() MSH.CraftList.wrapNeatCrafting() end)
    MSH.Client.on("sandbox", "CraftList", function() MSH.CraftList.refreshOpen() end)
end
