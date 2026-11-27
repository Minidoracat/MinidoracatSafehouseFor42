-- MinidoracatSafehouse/Lifecycle.lua：放棄與重建的共用步驟（屋主放棄、管理員代為放棄、收斂、重畫、recovery 都走這裡）。
-- 一間有幾塊範圍就有幾個原生，共用 @MSH:<id> 標記（使用者 2026-10-11 裁定多塊）。
-- 放棄（§7.4 最後一段）：寫 releasing(opId, revision, 每塊範圍＋指紋) → 移除這間的每個原生 → 重掃確認不在 →
--   寫 released tombstone → remove delta。移除失敗或衝突就 quarantined，不假成功。
-- 重建（§6.2）：只補缺的塊，補之前確認沒有重疊、沒有撞號，以紀錄的範圍＋service-owner 建；
--   更新該塊的指紋與 generation，不加 domain revision（manager 的 expectedRevision 不失效）。
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

-- 這筆紀錄的原生：以標記找，每個原生都要對得上其中一塊（範圍＋建立時間）。
-- 回傳 entries（和 rec.rects 同序，缺的塊是 false）, 狀態：nil（每塊都在）、MISSING（有塊不在，在的都對得上）、
-- DUPLICATE（同一塊有兩個原生）、MISMATCH（有標記但對不上任何一塊）；後兩種 entries 是 nil
-- into：可省，給了就把結果填進這個陣列重用（收斂每輪每間都找一次，用完就丟；呼叫端不得留著它）
local NONE = {}
function L.findNatives(rec, idx, into)
    local N = MSH.Native
    local out, missing = into or {}, false
    local n = #rec.rects
    for i = 1, n do out[i] = false end
    for i = #out, n + 1, -1 do out[i] = nil end
    for _, e in ipairs(idx.byClaim[rec.claimId] or NONE) do
        local i = N.pieceOf(rec, e)
        if i == nil then return nil, "MISMATCH" end
        if out[i] then return nil, "DUPLICATE" end
        out[i] = e
    end
    for i = 1, #out do
        if not out[i] then missing = true end
    end
    return out, missing and "MISSING" or nil
end

-- 換回屋主不是標記的塊：rec 的第 i 塊沒有標記原生，卻有同範圍＋同建立時間指紋、屋主是別人的原生 → setOwner 換回標記。
-- 照標記找原生之後要拆或撤銷的路徑先叫它，每塊都處理到（2026-11-27）。
-- 沒有建立時間的塊不換回：pieceOf 那時只比範圍，認不出是不是自己的。
-- 每次都逐塊比指紋，呼叫端自己決定要不要叫（收斂看標記原生比塊數少、放棄與撤銷看 findNatives 回 MISSING）。
-- 回傳 nil，或換回的 { { i, house, rect, owner＝被改成的屋主 } }；有換回時 idx 已過期，呼叫端重新 N.index()。
-- 客戶端通知照 L.sendReclaimed。
function L.reclaim(rec, idx, now)
    local N = MSH.Native
    local id, rects = rec.claimId, rec.rects
    if rects == nil then return nil end
    local have, took = {}, nil
    for _, e in ipairs(idx.byClaim[id] or NONE) do
        local i = N.pieceOf(rec, e)
        if i then have[i] = true end
    end
    for i, p in ipairs(rects) do
        if not have[i] and p.created ~= nil then
            for _, e in ipairs(idx.byRect[N.rectKey(p)] or NONE) do
                if e.claimId ~= id and N.pieceOf(rec, e) == i then
                    e.house:setOwner(MSH.marker(id))   -- 也把新 owner 從 players 移除（SafeHouse.java:660-663）
                    took = took or {}
                    took[#took + 1] = { i = i, house = e.house, rect = e.rect, owner = e.owner }
                    MSH.Audit.throttled("OWNER_DRIFT|" .. id, 60000, "OWNER_DRIFT",
                        { actor = e.owner, claimId = id, code = "RESTORED" }, now)
                    break
                end
            end
        end
    end
    return took
end

-- defer(fn)：把網路送出排到放鎖之後；沒有給就立即送（收斂在鎖外呼叫時）
local function send(defer, fn)
    if defer then defer(fn) else fn() end
end

-- 換回的塊的客戶端通知（放鎖後送）：客戶端那塊的屋主還是換回前的人，nativeRemove 只認標記。
-- 一律送 foreignRemove（範圍＋換回前的屋主；Mirror.lua 留 tombstone）。伺服器還留著的塊再廣播標記屋主
-- （foreignRemove 刪不到它）；拆掉的塊不廣播：SafehouseSync 不保證順序，會把它加回去。
-- gone：這次拆掉的原生 → true（nil＝全部留著）
function L.sendReclaimed(took, gone)
    for _, t in ipairs(took or NONE) do
        MSH.Foreign.sendRemove(t)   -- Foreign.lua 較晚載入，執行期才取
        if not (gone and gone[t.house]) then MSH.Native.broadcast(t.house) end
    end
end

-- 拆一串原生；拆不掉就隔離，換回的塊照實際拆了哪些通知客戶端（重畫的 defer 只在成功時送出：拆掉的塊由
-- restorePartial 重建時廣播，留著的塊等校正）。回傳拆掉的原生集合，或 nil（失敗）
local function removeAll(rec, list, took, defer)
    local N, gone = MSH.Native, {}
    for _, e in ipairs(list) do
        if e then
            if not N.remove(e.house) then
                MSH.Registry.markQuarantined(rec, "RELEASE_REMOVE_FAILED")
                if took then send(defer, function() L.sendReclaimed(took, gone) end) end
                return nil
            end
            gone[e.house] = true
        end
    end
    return gone
end

-- 回傳 true 或 false, 結果碼
function L.release(rec, reason, opId, now, defer)
    if rec.rects == nil then return L.forceRelease(rec, reason, opId, now, defer) end
    local N, R = MSH.Native, MSH.Registry
    local idx = N.index()
    local entries, why = L.findNatives(rec, idx, nil)
    local took = nil
    if why == "MISSING" then
        took = L.reclaim(rec, idx, now)
        if took then entries, why = L.findNatives(rec, N.index(), nil) end
    end
    if entries == nil then
        R.markQuarantined(rec, "RELEASE_" .. why)
        if took then send(defer, function() L.sendReclaimed(took, nil) end) end
        return false, CODE.RELEASE_FAILED
    end
    -- 沒有指紋的塊記下找到的原生的建立時間：tombstone 才認得出同一代原生重現
    for i, e in ipairs(entries) do
        if e and rec.rects[i].created == nil then rec.rects[i].created = e.house:getDatetimeCreated() end
    end
    R.markReleasing(rec, opId)
    local gone = removeAll(rec, entries, took, defer)
    if gone == nil then return false, CODE.RELEASE_FAILED end
    local claimId = rec.claimId
    R.markReleased(rec, reason, now)
    send(defer, function()
        N.sendRemove(claimId)
        L.sendReclaimed(took, gone)
    end)
    return true
end

-- targeted recovery 的放棄（§6 狀態圖：quarantined → released）：不看指紋，移除這個標記的全部原生
-- （DUPLICATE、MISMATCH、malformed 都走這裡）；全部確認不在了才寫 released，有一間移不掉就維持 quarantined。
function L.forceRelease(rec, reason, opId, now, defer)
    local N, R = MSH.Native, MSH.Registry
    local idx = N.index()
    local took = L.reclaim(rec, idx, now)   -- 隔離中的紀錄沒有收斂換回屋主
    if took then idx = N.index() end
    local list = idx.byClaim[rec.claimId] or {}
    R.markReleasing(rec, opId)
    local gone = removeAll(rec, list, took, defer)
    if gone == nil then return false, CODE.RELEASE_FAILED end
    local claimId = rec.claimId
    R.markReleased(rec, reason, now)
    send(defer, function()
        N.sendRemove(claimId)
        L.sendReclaimed(took, gone)
    end)
    return true
end

-- 要補的塊（entries[i] 不是原生；entries 省略＝每塊都要補）和其他原生（不含自己的標記）重疊或 onlineId 撞號就不重建
-- （§6.2：先檢查無 duplicate／overlap／identity conflict）
function L.rebuildConflict(rec, idx, entries)
    local mine = rec.claimId
    local function skip(e) return e.claimId == mine end
    for i, r in ipairs(rec.rects) do
        if not (entries and entries[i]) then
            if #MSH.Native.overlapping(idx, r, 0, skip) > 0 then return "OVERLAP" end
            local oid = SafeHouse.getOnlineID(r.x, r.y)
            for _, e in ipairs(idx.all) do
                if e.claimId ~= mine and e.onlineId == oid then return "ONLINE_ID" end
            end
        end
    end
    return nil
end

-- 補建缺的塊；回傳 true 或 nil, 原因。有一塊建不起來就把這次建好的拆掉、指紋還原（下一輪整批再試），
-- 免得 admin rebind 失敗時留下半間
function L.rebuild(rec, idx, defer, entries)
    local N, R = MSH.Native, MSH.Registry
    idx = idx or N.index()
    local conflict = L.rebuildConflict(rec, idx, entries)
    if conflict then return nil, conflict end
    local built = {}
    for i, r in ipairs(rec.rects) do
        if not (entries and entries[i]) then
            local house, code = N.buildPiece(rec, r)
            if house == nil then
                for k = #built, 1, -1 do
                    N.remove(built[k].house)
                    rec.rects[built[k].i].created = built[k].prev
                end
                return nil, code
            end
            built[#built + 1] = { i = i, house = house, prev = r.created }
            r.created = house:getDatetimeCreated()
        end
    end
    R.bumpGeneration()
    MSH.Audit.write("REBUILT", { actor = rec.owner, claimId = rec.claimId, detail = tostring(#built) })
    send(defer, function()
        for _, b in ipairs(built) do N.broadcast(b.house) end
    end)
    return true
end
