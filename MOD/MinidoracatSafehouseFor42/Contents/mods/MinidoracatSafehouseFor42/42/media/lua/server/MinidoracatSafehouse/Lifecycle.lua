-- MinidoracatSafehouse/Lifecycle.lua：放棄與重建的共用步驟（屋主放棄、管理員代為放棄、收斂、重畫、recovery 都走這裡）。
-- 放棄（§7.4 最後一段）：寫 releasing(opId, revision, {rect, nativeCreatedAt}) → 移除精確的原生安全屋 → 重掃確認不在 →
--   寫 released tombstone → remove delta。移除失敗或衝突就 quarantined，不假成功。
-- 重建（§6.2）：只在沒有重疊、沒有撞號、沒有同標記重複時，以紀錄的 rect＋service-owner 重建；
--   更新 nativeCreatedAt 與 generation，不加 domain revision（manager 的 expectedRevision 不失效）。
-- 呼叫端持全域鎖；網路送出經 defer 排到放鎖之後。

if isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Audit"
require "MinidoracatSafehouse/Registry"
require "MinidoracatSafehouse/Native"

local MSH = MinidoracatSafehouse
local L = MSH.Lifecycle or {}
MSH.Lifecycle = L

local CODE = MSH.CODE
local LC = MSH.LIFECYCLE

-- 這筆紀錄的原生安全屋：以標記找，指紋（rect＋建立時間）相符才算。
-- 回傳 entry 或 nil, 狀態：MISSING（找不到）、DUPLICATE（同標記不只一間）、MISMATCH（有標記但指紋不合）
function L.findNative(rec, idx)
    local list = idx.byClaim[rec.claimId]
    if list == nil or #list == 0 then return nil, "MISSING" end
    if #list > 1 then return nil, "DUPLICATE" end
    if not MSH.Native.matches(rec, list[1]) then return nil, "MISMATCH" end
    return list[1]
end

-- defer(fn)：把網路送出排到放鎖之後；沒有給就立即送（收斂在鎖外呼叫時）
local function send(defer, fn)
    if defer then defer(fn) else fn() end
end

-- 回傳 true 或 false, 結果碼
function L.release(rec, reason, opId, now, defer)
    if not MSH.Rect.valid(rec.rect) then return L.forceRelease(rec, reason, opId, now, defer) end
    local N, R = MSH.Native, MSH.Registry
    local idx = N.index()
    local e, why = L.findNative(rec, idx)
    if e == nil and why ~= "MISSING" then
        R.markQuarantined(rec, "RELEASE_" .. why)
        return false, CODE.RELEASE_FAILED
    end
    local created = e and e.house:getDatetimeCreated() or rec.nativeCreatedAt
    R.markReleasing(rec, opId, created)
    if e ~= nil and not N.remove(e.house) then
        R.markQuarantined(rec, "RELEASE_REMOVE_FAILED")
        return false, CODE.RELEASE_FAILED
    end
    local rect = MSH.Rect.copy(rec.rect)
    local claimId = rec.claimId
    R.markReleased(rec, reason, now)
    send(defer, function() N.sendRemove(claimId, rect) end)
    return true
end

-- targeted recovery 的放棄（§6 狀態圖：quarantined → released）：不看指紋，移除這個標記的全部原生
-- （DUPLICATE、MISMATCH、malformed 都走這裡）；全部確認不在了才寫 released，有一間移不掉就維持 quarantined。
function L.forceRelease(rec, reason, opId, now, defer)
    local N, R = MSH.Native, MSH.Registry
    local list = N.index().byClaim[rec.claimId] or {}
    local rect = MSH.Rect.valid(rec.rect) and MSH.Rect.copy(rec.rect) or (list[1] and list[1].rect) or nil
    R.markReleasing(rec, opId, list[1] and list[1].house:getDatetimeCreated() or rec.nativeCreatedAt)
    for _, e in ipairs(list) do
        if not N.remove(e.house) then
            R.markQuarantined(rec, "RELEASE_REMOVE_FAILED")
            return false, CODE.RELEASE_FAILED
        end
    end
    local claimId = rec.claimId
    R.markReleased(rec, reason, now)
    send(defer, function() N.sendRemove(claimId, rect) end)
    return true
end

-- 與其他原生安全屋（不含自己的標記）重疊或 onlineId 撞號就不重建（§6.2：先檢查無 duplicate／overlap／identity conflict）
function L.rebuildConflict(rec, idx)
    local mine = rec.claimId
    local hits = MSH.Native.overlapping(idx, rec.rect, 0, function(e) return e.claimId == mine end)
    if #hits > 0 then return "OVERLAP" end
    local oid = SafeHouse.getOnlineID(rec.rect.x, rec.rect.y)
    for _, e in ipairs(idx.all) do
        if e.claimId ~= mine and e.onlineId == oid then return "ONLINE_ID" end
    end
    return nil
end

-- 回傳 house 或 nil, 原因
function L.rebuild(rec, idx, defer)
    local N, R = MSH.Native, MSH.Registry
    idx = idx or N.index()
    local conflict = L.rebuildConflict(rec, idx)
    if conflict then return nil, conflict end
    local house, code = N.build(rec)
    if house == nil then return nil, code end
    rec.nativeCreatedAt = house:getDatetimeCreated()
    R.bumpGeneration()
    MSH.Audit.write("REBUILT", { actor = rec.owner, claimId = rec.claimId })
    send(defer, function() N.broadcast(house) end)
    return house
end
