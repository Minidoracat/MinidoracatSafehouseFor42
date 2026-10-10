-- MinidoracatSafehouse/Calibrate.lua：客戶端 mirror 校正（計畫 §6.3「校正」）。
-- 客戶端（連線後首個 OnTick、seq gap、每 10 分鐘）送本地全部 @MSH: 原生安全屋的 claimId＋rect；
-- 伺服器以「目前應存在的投影」回答：
--   ① 應移除：released、lapsed（native 已移除）、沒有紀錄也沒有這個標記的原生 → remove 清單；
--      quarantined 刻意保留 native，客戶端也保留；沒有紀錄但伺服器上有這個標記的原生（等開服才轉 recovered 的孤兒，
--      伺服器照樣以它判定進出）也保留；
--   ② 客戶端缺少的 active／quarantined（伺服器上有 marker native）→ 對該 claim 觸發原生 upsert 廣播
--      （全服受益；每 claim 10 秒最多一次、每次請求最多 LIMIT.CALIBRATE_UPSERTS 次廣播，放鎖後送）；
--      正常客戶端登入時已從 MetaDataPacket 拿到全部，缺很多間不是正常情況，剩下的留給下一次校正；
--   ③ 一致：不動。不重播歷史 remove。
-- 結果附目前的 bootId／seq，客戶端以它當新的 remove delta 序號基準。

if isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Registry"
require "MinidoracatSafehouse/Native"
require "MinidoracatSafehouse/Server"

local MSH = MinidoracatSafehouse
local C = MSH.Calibrate or {}
MSH.Calibrate = C

local S = MSH.Srv
local LC = MSH.LIFECYCLE

C.BROADCAST_MS = 10000
C.lastBroadcast = C.lastBroadcast or {}   -- claimId → 上次因校正廣播的時間（筆數以有 marker native 的 claim 為上限）

S.define("calibrate", { kind = "query", cooldownMs = 5000, fields = { houses = "houses", bootId = "query?" },
    run = function(ctx)
        local R, N = MSH.Registry, MSH.Native
        local idx = N.index()
        local remove, reported = {}, {}
        for _, e in pairs(ctx.args.houses) do
            local id = e.claimId
            if not reported[id] then
                reported[id] = true
                local rec = R.get(id)
                if (rec == nil and idx.byClaim[id] == nil) or (rec ~= nil and rec.lifecycle == LC.LAPSED) then
                    remove[#remove + 1] = id
                end
            end
        end
        local budget = MSH.LIMIT.CALIBRATE_UPSERTS
        for id, list in pairs(idx.byClaim) do
            if budget <= 0 then break end
            local rec = R.get(id)
            -- 同標記重複的整組一起送（放不下就留給下一次），不送半組
            if rec ~= nil and not reported[id] and #list <= budget
                and (rec.lifecycle == LC.ACTIVE or rec.lifecycle == LC.QUARANTINED) then
                local last = C.lastBroadcast[id]
                if last == nil or ctx.now - last >= C.BROADCAST_MS then
                    C.lastBroadcast[id] = ctx.now
                    budget = budget - #list
                    ctx.defer(function()
                        for _, en in ipairs(list) do N.broadcast(en.house) end
                    end)
                end
            end
        end
        return S.ok({ remove = remove, bootId = N.bootId, seq = N.seq })
    end })
