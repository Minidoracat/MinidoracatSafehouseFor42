-- 製作清單（CraftList.lua＋Recipes.lua deedRecipeHidden）：Neat Crafting 的 NC_FilterBar:shouldIncludeRecipe 被包一次，
-- 沙盒關掉的地契變體不列、開放的與別的配方照原函式；管理員改難度（sandboxSync）後已開的製作視窗重建清單。
return function(T)
    local check = T.check
    local saved = { NC_FilterBar = NC_FilterBar, ISEntityUI = ISEntityUI }

    local function recipe(name) return { name = name, getName = function(self) return self.name end } end
    local origCalls = {}
    local F = {}
    function F:shouldIncludeRecipe(r)
        origCalls[#origCalls + 1] = r.name
        return r.name ~= "ForeignBlocked"
    end
    local origFn = F.shouldIncludeRecipe
    NC_FilterBar = F

    local MSH = T.bootClient()
    -- 正式服的沙盒（production-server.md Safehouse 段）
    T.sandbox("TiersEnabled", 3)
    T.sandbox("Tier1Craft", 3)
    T.sandbox("Tier2Craft", 1)
    T.sandbox("Tier3Craft", 1)

    T.section("CraftList：載入時不包，OnGameStart 才包")
    check(F.shouldIncludeRecipe == origFn, "載入時 Neat Crafting 還沒載入：不碰")
    T.fire("OnGameStart")
    check(F.shouldIncludeRecipe ~= origFn and F.mshDeedFilter == true, "OnGameStart：包上")

    local bar = setmetatable({}, { __index = F })
    local function listed()
        local out = {}
        for n = 1, 8 do
            for _, lv in ipairs({ "Easy", "Standard", "Strict" }) do
                local name = "CraftMinidoracatSafehouseDeed" .. n .. lv
                if bar:shouldIncludeRecipe(recipe(name)) then out[#out + 1] = name end
            end
        end
        return table.concat(out, ",")
    end

    T.section("CraftList：只列開放的變體，其餘照原函式")
    origCalls = {}
    check(listed() == "CraftMinidoracatSafehouseDeed1Standard", "24 條只列 1 級標準（實際 " .. listed() .. "）")
    origCalls = {}
    check(bar:shouldIncludeRecipe(recipe("CraftMinidoracatSafehouseDeed1Standard")) == true
        and origCalls[1] == "CraftMinidoracatSafehouseDeed1Standard", "開放的變體交給原函式決定")
    origCalls = {}
    check(bar:shouldIncludeRecipe(recipe("CraftMinidoracatSafehouseDeed1Easy")) == false and #origCalls == 0,
        "關掉的變體直接 false、不問原函式")
    check(bar:shouldIncludeRecipe(recipe("CraftMinidoracatSafehouseDeed4Standard")) == false, "超過 TiersEnabled 的也藏")
    origCalls = {}
    check(bar:shouldIncludeRecipe(recipe("MakeSpear")) == true and bar:shouldIncludeRecipe(recipe("ForeignBlocked")) == false
        and #origCalls == 2, "別的配方：結果照原函式（true／false 都原樣）")
    check(MSH.deedRecipeHidden("MakeSpear") == false and MSH.deedRecipeHidden("CraftMinidoracatSafehouseDeed2Easy") == true,
        "deedRecipeHidden：別的配方 false、關掉的地契 true")

    T.section("CraftList：包兩次不疊")
    local wrapped = F.shouldIncludeRecipe
    check(MSH.CraftList.wrapNeatCrafting() == false and F.shouldIncludeRecipe == wrapped, "第二次包：不動")
    T.fire("OnGameStart")
    origCalls = {}
    bar:shouldIncludeRecipe(recipe("MakeSpear"))
    check(F.shouldIncludeRecipe == wrapped and #origCalls == 1, "再觸發 OnGameStart：原函式只被呼叫一次")

    T.section("CraftList：管理員改難度，已開視窗重建")
    local ncShown, vanillaForce = 0, nil
    ISEntityUI = { players = { [0] = { windows = {
        HandcraftWindow = { instance = { HandCraftPanel = { updateRecipeDisplay = function() ncShown = ncShown + 1 end } } },
        SomeBench = { instance = { handCraftPanel = { refreshRecipeList = function(_, force) vanillaForce = force end } } },
        Closed = { x = 1 },
    } } } }
    T.fire("OnServerCommand", MSH.MODULE, "sandboxSync", { Tier1Craft = 2 })
    check(ncShown == 1 and vanillaForce == true, "Neat Crafting 視窗 updateRecipeDisplay、原版 refreshRecipeList(true)")
    check(listed() == "CraftMinidoracatSafehouseDeed1Easy", "改成寬鬆後只列 1 級寬鬆（實際 " .. listed() .. "）")
    T.fire("OnServerCommand", MSH.MODULE, "sandboxSync", { Tier2Craft = 4 })
    check(listed() == "CraftMinidoracatSafehouseDeed1Easy,CraftMinidoracatSafehouseDeed2Strict", "開 2 級嚴格：多列一條")
    ISEntityUI = nil
    local ok = pcall(function() T.fire("OnServerCommand", MSH.MODULE, "sandboxSync", { Tier3Craft = 3 }) end)
    check(ok and not T.logged("listener sandbox failed"), "沒有 ISEntityUI：不丟錯")

    T.section("CraftList：沒裝 Neat Crafting")
    NC_FilterBar = nil
    MSH = T.bootClient()
    local ok2 = pcall(function() T.fire("OnGameStart") end)
    check(ok2 and MSH.CraftList.wrapNeatCrafting() == false, "NC_FilterBar 不存在：不包、不丟錯")
    SandboxVars = nil
    check(MSH.deedRecipeHidden("CraftMinidoracatSafehouseDeed1Easy") == false, "沙盒還沒載入：不藏（同 OnAddToMenu 放行）")
    T.resetSandbox()

    NC_FilterBar, ISEntityUI = saved.NC_FilterBar, saved.ISEntityUI
end
