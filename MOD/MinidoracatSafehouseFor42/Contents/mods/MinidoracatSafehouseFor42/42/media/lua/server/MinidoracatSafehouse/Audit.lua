-- MinidoracatSafehouse/Audit.lua：稽核紀錄，一個事件一行。
-- writeLog(logger, text) 落在 <cachedir>/Logs/<啟動時間>_MinidoracatSafehouse.txt，每行自動時間戳；
-- 超過 10MB 是截斷不是輪替（ZLogger.java:95-101，pitfalls.md「Log」），所以拒絕類事件聚合後每分鐘寫一次。
-- 欄位以 tab 分隔，寫入前清掉換行、tab 與方括號（PZ 名字允許 [ ]，pitfalls.md「Log」）。

if isClient() then return end

require "MinidoracatSafehouse/Contract"

local MSH = MinidoracatSafehouse
local A = MSH.Audit or {}
MSH.Audit = A

A.LOGGER = "MinidoracatSafehouse"

A.denyAgg = A.denyAgg or {}        -- "actor|command|code" → 次數
A.limited = A.limited or {}        -- 節流事件：key → { at, suppressed }
A.suppressed = A.suppressed or 0   -- 被節流壓下的事件數（health detail 用）

-- event：大寫事件名；f：{ actor, claimId, code, detail }
function A.write(event, f)
    f = f or {}
    local line = table.concat({
        MSH.logSafe(event),
        MSH.logSafe(f.actor or "-"),
        MSH.logSafe(f.claimId or "-"),
        MSH.logSafe(f.code or "-"),
        MSH.logSafe(f.detail or "-"),
    }, "\t")
    writeLog(A.LOGGER, line)
end

-- 拒絕不逐包寫：同一 actor＋指令＋原因每分鐘一行（flush 時帶次數）
function A.deny(actor, command, code)
    local key = MSH.logSafe(actor or "?") .. "|" .. MSH.logSafe(command or "?") .. "|" .. MSH.logSafe(code or "?")
    A.denyAgg[key] = (A.denyAgg[key] or 0) + 1
end

function A.flush()
    local agg = A.denyAgg
    A.denyAgg = {}
    for key, count in pairs(agg) do
        local actor, command, code = string.match(key, "^(.-)|(.-)|(.*)$")
        A.write("DENY", { actor = actor, code = code, detail = command .. " x" .. tostring(count) })
    end
end

-- 每個 key 在 windowMs 內最多寫一行，其餘只計數（例：成員同步受干擾每分鐘一行，§6.2）
function A.throttled(key, windowMs, event, f, now)
    local s = A.limited[key]
    if s ~= nil and now - s.at < windowMs then
        s.suppressed = s.suppressed + 1
        A.suppressed = A.suppressed + 1
        return false
    end
    if s ~= nil and s.suppressed > 0 then
        f = f or {}
        f.detail = tostring(f.detail or "-") .. " suppressed=" .. tostring(s.suppressed)
    end
    A.limited[key] = { at = now, suppressed = 0 }
    A.write(event, f)
    return true
end

-- 給在線管理員的提示（具 CanSetupSafehouses）；只送結果碼，客戶端照碼顯示（M3）
function A.alertAdmins(code, detail)
    if not (MSH.Srv and MSH.Srv.netUp) then return end   -- 開服前沒有管理員在線，getOnlinePlayers 會 NPE（Server.lua S.netUp）
    local list = getOnlinePlayers and getOnlinePlayers() or nil
    if list == nil then return end
    for i = 0, list:size() - 1 do
        local p = list:get(i)
        local ok, admin = pcall(function()
            return p:getRole():hasCapability(Capability.CanSetupSafehouses)
        end)
        if ok and admin then
            sendServerCommand(p, MSH.MODULE, "alert", { code = code, detail = detail })
        end
    end
end
