-- MinidoracatSafehouse/Health.lua：伺服器設定健康矩陣（計畫 §5）與異常狀態。
-- MOD 不呼叫 putOption／changeOption；operator 可在執行期改設定，所以每輪 reconcile 重讀。
-- blocked mode（§5、§6.2）：停一般 mutation 與「native 消失→重建」；照常做名單／標題／owner 收斂、撤銷、放棄、targeted recovery。

if isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Settings"
require "MinidoracatSafehouse/Audit"

local MSH = MinidoracatSafehouse
local H = MSH.Health or {}
MSH.Health = H

-- 原版選項名與預設：ServerOptions.java:41-203（42.21.0）。值一律用 getOption 讀成字串比對。
H.BLOCKERS = {
    { option = "PlayerSafehouse", want = "false" },     -- 原版建立封包沒有 Lua 掛鉤（SafehouseClaimPacket.java:71-75）
    { option = "AdminSafehouse", want = "false" },      -- 建築 claim 路徑沒有可靠的 capability 閘門（SafeHouse.java:379-397）
    { option = "SafeHouseRemovalTime", want = "0" },    -- 引擎到期自動刪屋（SafeHouse.java:861-884）
    { option = "War", want = "false" },                 -- War 打到門檻自動刪屋（SafeHouse.java:818-829）
    { option = "SafehouseAllowTrepass", want = "false" },
    { option = "SafehouseAllowLoot", want = "false" },
    { option = "SafehouseAllowFire", want = "false" },
    { option = "DisableSafehouseWhenOwnerConnected", want = "false" },
    { option = "AntiCheatSafeHouse", anyOf = { ["1"] = true, ["2"] = true, ["3"] = true } }, -- 4＝關閉閘門（§2.2）
}

H.state = H.state or { blocked = false, blockers = {}, warnings = {}, settingsWarnings = {}, key = "" }
H.hostile = H.hostile or { active = false, since = nil, names = {} }

-- 專用伺服器才啟用 dispatcher／reconciler；listen／coop host 與 SP 載入但停用（§1.1 第 11 點）
function H.dedicated()
    return isServer() == true and isClient() ~= true
end

local function optionValue(name)
    local ok, v = pcall(function() return getServerOptions():getOption(name) end)
    if not ok then return nil end
    return v ~= nil and tostring(v) or nil
end

local function warningsList()
    local w = {}
    if optionValue("SafehouseAllowRespawn") == "true" then w[#w + 1] = "SafehouseAllowRespawn" end
    if optionValue("AllowCoop") == "true" then w[#w + 1] = "AllowCoop" end
    local save = tonumber(optionValue("SaveWorldEveryMinutes") or "")
    if save == nil or save == 0 or save > 30 then w[#w + 1] = "SaveWorldEveryMinutes" end
    local chat = optionValue("ChatStreams") or ""
    for token in string.gmatch(chat, "[^,]+") do
        if MSH.trim(token) == "sh" then w[#w + 1] = "ChatStreams" end
    end
    if optionValue("SafehousePreventsLootRespawn") == "true" then w[#w + 1] = "SafehousePreventsLootRespawn" end
    if optionValue("SledgehammerOnlyInSafehouse") == "true" then w[#w + 1] = "SledgehammerOnlyInSafehouse" end
    return w
end

-- 重讀全部設定；blockers 由符合變成不符時當輪就進 blocked（§5）
function H.evaluate(now)
    local blockers = {}
    for _, b in ipairs(H.BLOCKERS) do
        local v = optionValue(b.option)
        local good
        if b.anyOf then good = v ~= nil and b.anyOf[v] == true else good = v == b.want end
        if not good then blockers[#blockers + 1] = b.option end
    end
    if not MSH.Settings.readable() then blockers[#blockers + 1] = "SandboxVars" end
    local R = MSH.Registry
    if R ~= nil and R.readOnly then blockers[#blockers + 1] = "RegistrySchema" end
    if R ~= nil and R.privateUnreadable then blockers[#blockers + 1] = "PrivateStore" end
    local _, settingsWarnings = MSH.Settings.get()
    local st = {
        blocked = #blockers > 0,
        blockers = blockers,
        warnings = warningsList(),
        settingsWarnings = settingsWarnings,
    }
    st.key = table.concat(blockers, ",") .. "|" .. table.concat(st.warnings, ",") .. "|" .. table.concat(settingsWarnings, ",")
    local old = H.state
    H.state = st
    if st.key ~= old.key then
        MSH.Audit.write(st.blocked and "HEALTH_BLOCKED" or "HEALTH", { code = table.concat(blockers, ","),
            detail = "warn=" .. table.concat(st.warnings, ",") .. " settings=" .. table.concat(settingsWarnings, ",") })
        if st.blocked and not old.blocked then MSH.Audit.alertAdmins("HEALTH_BLOCKED", table.concat(blockers, ",")) end
    end
    return st
end

function H.blocked()
    return H.state.blocked == true
end

-- 身分異常（§4.2）：在線主玩家名不合法或以 @MSH: 開頭。由 Identity 每秒掃描後設定。
function H.setHostile(names, now)
    local active = #names > 0
    if active and not H.hostile.active then
        H.hostile = { active = true, since = now, names = names }
        MSH.Audit.write("HOSTILE_MODE", { code = "ON", detail = table.concat(names, ",") })
        MSH.Audit.alertAdmins("HOSTILE_MODE", table.concat(names, ","))
    elseif not active and H.hostile.active then
        MSH.Audit.write("HOSTILE_MODE", { code = "OFF" })
        H.hostile = { active = false, since = nil, names = {} }
    elseif active then
        H.hostile.names = names
    end
end

function H.isHostile()
    return H.hostile.active == true
end
