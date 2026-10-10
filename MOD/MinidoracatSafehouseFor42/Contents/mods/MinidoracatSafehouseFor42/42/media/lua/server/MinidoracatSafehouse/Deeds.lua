-- MinidoracatSafehouse/Deeds.lua：地契掉落（計畫 §7.7）。
-- OnFillContainer（LuaEventManager.java:723）在伺服器填完容器、送給客戶端之前觸發（ItemPickerJava.java:592、600、612），
-- 加進去的物品跟著原本的同步送出，不必另外同步。第三參數可能是分布物件不是容器（ItemPickerJava.java:630
-- 傳 containerDist.bags），索引它就 throw，所以第一個檢查一定是 instanceof（家族 pitfalls.md:74-83）。
-- 只看容器種類 desk／filingcabinet／safe；判斷地契只用 full type（不用自訂 tag，§2.8）；每次都讀當下的 SandboxVars。

if isClient() then return end

require "MinidoracatSafehouse/Contract"

local MSH = MinidoracatSafehouse
local first = MSH.Deeds == nil
local D = MSH.Deeds or {}
MSH.Deeds = D

D.TYPES = { desk = true, filingcabinet = true, safe = true }

-- 戰利品重生會再填一次（LootRespawn.java:158 → ItemPickerJava.fillContainer）：容器裡已有任何地契就不再加
local function hasDeed(container)
    for n = 1, MSH.MAX_TIER do
        -- containsType 帶點號時比 full type（ItemContainer.java:771 → :1197-1200）
        if container:containsType(MSH.deedType(n)) then return true end
    end
    return false
end

function D.onFill(roomName, containerType, container)
    -- instanceof 是 Java isInstance，不經 __index（LuaManager.java:2951-2957）
    if not instanceof(container, "ItemContainer") then return end
    if not D.TYPES[containerType] then return end
    local sb = SandboxVars and SandboxVars.MinidoracatSafehouse
    if type(sb) ~= "table" then return end
    local enabled = sb.TiersEnabled
    if type(enabled) ~= "number" then return end
    if hasDeed(container) then return end
    for n = 1, math.min(enabled, MSH.MAX_TIER) do
        local chance = sb["Tier" .. n .. "LootChance"]
        -- ZombRand(10000) 回 0..9999（LuaManager.java:7064-7069）：機率 0 永不中、100 必中
        if type(chance) == "number" and ZombRand(10000) < chance * 100 then
            container:AddItem(MSH.deedType(n))   -- ItemContainer.java:538
            return
        end
    end
end

if first then
    Events.OnFillContainer.Add(function(roomName, containerType, container)
        MSH.Deeds.onFill(roomName, containerType, container)
    end)
end
