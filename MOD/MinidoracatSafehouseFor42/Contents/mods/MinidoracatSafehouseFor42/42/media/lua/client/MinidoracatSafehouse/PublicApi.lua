-- MinidoracatSafehouse/PublicApi.lua：給其他 MOD 用的客戶端公開 API（MinidoracatSafehouse.v1）。
-- 契約：temp/handoff/minimap-safehouse-owner.md（使用者 2026-10-11 裁定小地圖標籤顯示真正屋主）。
--   v1 = { API_MAJOR = 1, API_REVISION = 1, CAPABILITIES = { ownerName = true }, ownerName = fn }
--   ownerName(owner)：owner 是原生 SafeHouse:getOwner() 的字串；managed（@MSH:<claimId>）回真正屋主帳號名，
--     資料還沒到或不是 managed 回 nil。不配置 table、不丟錯，每幀呼叫也可以（查本機快取）。
-- 資料來源：公開的 Global ModData（MSH.TAG，伺服器 registry，claims[claimId].owner）。客戶端 ModData.request 整張表，
--   伺服器只回給要的人（GlobalModData.java:153-200）；回覆觸發 OnReceiveGlobalModData(tag, table|false)
--   （GlobalModDataPacket.java:45-55）。收到時只複製「@MSH:<claimId> → 屋主名」，不留整張表的參照。
-- 節流：同時最多一個 request。沒看過的 owner 查不到時，兩次 request 至少隔 30 秒；回覆後仍查不到的記成「已知查不到」，
--   只在原生安全屋清單變動（OnSafehousesChanged，SafeHouse.java:81、318、SafehouseSyncPacket.java:99）之後才再確認，
--   而且只為了更新（已知查不到、已命中的屋主可能換人）的 request 至少隔 5 分鐘：清單一直在變時（例：成員同步被干擾，
--   每 500 ms 廣播）每個客戶端最多 5 分鐘抓一次整張表。只有送出當下要的 owner 才會被回覆判成查不到（回覆可能比新屋的
--   原生同步晚到）。進場不主動抓，第一次查不到才抓。

if not isClient() then return end

require "MinidoracatSafehouse/Contract"

local MSH = MinidoracatSafehouse
local first = MSH.PublicApi == nil
local P = MSH.PublicApi or {}
MSH.PublicApi = P

P.INTERVAL_MS = 30000          -- 沒看過的 owner 查不到：兩次 request 至少間隔
P.REFRESH_MS = 300000          -- 清單變過、只為了更新：兩次 request 至少間隔
P.LOST_MS = 60000              -- 回覆遺失：超過這麼久沒回就不再當作進行中
P.names = P.names or {}        -- "@MSH:<id>" → 屋主帳號名（最近一次回覆的內容）
P.missing = P.missing or {}    -- 回覆後仍查不到的 owner 字串
P.wanted = P.wanted or {}      -- 查不到、還沒送出 request 的 owner 字串
P.asked = P.asked or {}        -- 送出中的 request 要的 owner 字串（回覆只判這些）
P.sentAt = P.sentAt or nil     -- 上次送出 request 的時間
P.inflight = P.inflight or false
P.stale = P.stale or false     -- 上次送出之後原生清單變過

-- 送出 request（節流在呼叫端判斷）；ModData 不存在或呼叫失敗只記 log，不丟錯。
-- ModData.request：ModData.java:48-50 → GlobalModData.java:153-168（只在 GameClient.client 時送封包）
function P.request(now)
    P.sentAt = now
    if ModData == nil or ModData.request == nil then return end
    local ok, err = pcall(ModData.request, MSH.TAG)
    if ok then
        P.inflight, P.stale = true, false
        P.asked, P.wanted = P.wanted, {}
    else
        MSH.log("PublicApi: ModData.request failed: " .. tostring(err))
    end
end

-- 每幀可呼叫：命中且清單沒變只做一次查表；其餘路徑不建 table、不切字串（string.find 只回位置）
function P.ownerName(owner)
    if type(owner) ~= "string" then return nil end
    local name, gap = P.names[owner], nil
    if name == nil then
        if string.find(owner, "^@MSH:%d+$") == nil then return nil end
        if not P.missing[owner] then
            P.wanted[owner] = true
            gap = P.INTERVAL_MS
        elseif P.stale then
            gap = P.REFRESH_MS
        end
    elseif P.stale then
        gap = P.REFRESH_MS
    end
    if gap ~= nil then
        local now = getTimestampMs()
        if P.inflight and now - P.sentAt >= P.LOST_MS then P.inflight = false end
        if not P.inflight and (P.sentAt == nil or now - P.sentAt >= gap) then P.request(now) end
    end
    return name
end

-- 回覆：只收本 MOD 的 tag；table 是 false（伺服器沒有這張表）時清快取。整份換新（放棄的屋不再留名字）。
-- claimId 用紀錄自己的 claimId（整數），不然用鍵；MSH.marker 組出與原生 owner 相同的字串。
function P.onReceive(tag, data)
    if tag ~= MSH.TAG then return end
    P.inflight = false
    local names = {}
    local claims = type(data) == "table" and data.claims or nil
    if type(claims) == "table" then
        for id, rec in pairs(claims) do
            if type(rec) == "table" and type(rec.owner) == "string" and rec.owner ~= "" then
                local cid = MSH.isInt(rec.claimId) and rec.claimId or id
                if MSH.isInt(cid) and cid >= 1 then names[MSH.marker(cid)] = rec.owner end
            end
        end
    end
    P.names = names
    for owner in pairs(P.asked) do
        if names[owner] == nil then P.missing[owner] = true end
    end
    P.asked = {}
end

-- 原生清單變了（新建、放棄、重建、管理員重新綁定）：已知查不到的可能有了、已命中的屋主可能換人，下次查詢時更新
function P.onSafehousesChanged()
    P.stale = true
end

local v1 = MSH.v1 or {}
MSH.v1 = v1
v1.API_MAJOR = 1
v1.API_REVISION = 1
v1.CAPABILITIES = v1.CAPABILITIES or {}
v1.CAPABILITIES.ownerName = true
v1.ownerName = P.ownerName

if first then
    -- OnReceiveGlobalModData：LuaEventManager.java:817；OnSafehousesChanged：:775
    Events.OnReceiveGlobalModData.Add(function(tag, data) MSH.PublicApi.onReceive(tag, data) end)
    Events.OnSafehousesChanged.Add(function() MSH.PublicApi.onSafehousesChanged() end)
end
