-- MinidoracatSafehouse/Recipes.lua：地契配方的沙盒閘門（計畫 §7.7）。
-- 24 條 craftRecipe（scripts/MinidoracatSafehouse_Recipes.txt）各有一個 OnTest 與 OnAddToMenu，名稱在這裡用迴圈產生。
-- OnTest = MSH_Recipe.deed<N><Level>：引擎以 LuaManager.getFunctionObject 解析點號路徑（CraftRecipe.java:1020），
--   簽章 (item, character)、對每個候選材料各問一次、拿不到配方本身，所以每條配方要有自己的函式（CraftRecipe.java:1010-1032）；
--   **找不到函式就放行**（:1028-1031），所以本檔放 shared、伺服器也要載入：伺服器在 ISHandcraftAction:complete
--   （media/lua/shared/Entity/TimedActions/ISHandcraftAction.lua:203）→ performRecipe（:221）重新經過 OnTest。
--   character 可能是 nil（CraftRecipeManager.java:398 傳 null），不碰它；做一次就被呼叫上百次，只查沙盒、不印 log。
-- OnAddToMenu = MSH_menuDeed<N><Level>：只在客戶端清單生效，用 callLuaBool(名稱, params) 呼叫
--   （ISRecipeScrollingListBox.lua:344-348、ISTiledIconPanel.lua:193-197），callLuaBool 是 env.rawget(名稱)
--   （LuaManager.java:5745-5746）：只認全域名稱、不解析點號，寫點號整條配方永遠被藏（deeds-mp 實測）。

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Settings"

local MSH = MinidoracatSafehouse
local CRAFT = MSH.Settings.CRAFT

MSH_Recipe = MSH_Recipe or {}

local LEVELS = { Easy = CRAFT.EASY, Standard = CRAFT.STANDARD, Strict = CRAFT.STRICT }

-- 沙盒還沒載入（主選單）時放行，照 AutoDrive MDAD_Recipe.lua；該級超過 TiersEnabled 就擋；其餘看選的是不是這個難度
local function allowed(tier, code)
    local sb = SandboxVars and SandboxVars.MinidoracatSafehouse
    local v = type(sb) == "table" and sb["Tier" .. tier .. "Craft"] or nil
    if v == nil then return true end
    local enabled = sb.TiersEnabled
    if type(enabled) == "number" and tier > enabled then return false end
    return v == code
end

for tier = 1, MSH.MAX_TIER do
    for level, code in pairs(LEVELS) do
        MSH_Recipe["deed" .. tier .. level] = function(item, character) return allowed(tier, code) end
        _G["MSH_menuDeed" .. tier .. level] = function(params) return allowed(tier, code) end
    end
end
