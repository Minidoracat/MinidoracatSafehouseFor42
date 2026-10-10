-- MinidoracatSafehouse/CreatePanel.lua：建立面板（計畫 §10.4 狀態表、§7.2 框選、§7.6 重新框選、§1.1 第 3、11 點）。
-- 入口：MSH.CreatePanel.open(opts)；地契物品右鍵「使用地契」（OnFillInventoryObjectContextMenu）；管理視窗「建立安全屋」。
--   opts = { deedType?, mode = "create" | "redraw", claimId?, revision?, tier?, source?, playerNum? }
--   （source：重新框選時舊屋的來源，決定顯示的大小上限；playerNum：開窗的玩家，分割畫面次玩家不能建）
-- 狀態機（不碰畫面，scripts/harness/t_ui_create.lua 直接測）：
--   idle → selecting → preview → confirm → submitting → 成功（開管理視窗）／失敗（回 preview 顯示原因）／
--   result-pending（10 秒沒結果；〔查詢結果〕＝同一 requestId 重送，伺服器回快取的原結果；快取過期改抓 list，
--   已有新屋就當成功，**過期不解讀為失敗**）；selecting／preview／confirm 時死亡或離線 → idle。
-- 畫面全部照伺服器結果：預檢與 enable／disable 都來自 server structured result code（§10.4 最後一段）；
--   本地只顯示等級、上限（沙盒，sandboxSync 後為最新）與伺服器 slots 查詢回的名額與閘門。
-- 畫面用 UI 框架（MinidoracatUIFor42 rev ≥ 16：window、controls、focus）；能力不合或建窗失敗退最小直角 fallback
--   （vanilla ISPanel／ISButton 一句「需要更新 Minidoracat UI 框架」），不報錯（AGENTS.md 鐵則）。
-- 檔案載入時不碰 ISPanel、框架或玩家（harness T.bootClient 會載入本檔）。

if not isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Settings"
require "MinidoracatSafehouse/Client"
require "MinidoracatSafehouse/Select"

local MSH = MinidoracatSafehouse
local first = MSH.CreatePanel == nil
local P = MSH.CreatePanel or {}
MSH.CreatePanel = P

local CODE = MSH.CODE
local SRC = MSH.SOURCE
local Sel = MSH.Select

P.IDLE, P.SELECTING, P.PREVIEW, P.CONFIRM = "idle", "selecting", "preview", "confirm"
P.SUBMITTING, P.PENDING, P.DONE = "submitting", "result-pending", "done"
-- 預檢伺服器每人 500 ms 一次、冷卻中直接丟不回覆（Claims.lua preview cooldownMs、Server.lua coolingDown）；
-- 兩次之間至少隔這麼久，免得被丟掉後空等 10 秒
P.PREVIEW_GAP_MS = 600
-- 本地閘門碼（不是伺服器結果碼）：文字鍵 IGUI_MSH_Create_Reason_<碼>／IGUI_MSH_Create_Action_<碼>
P.LOCAL_CODES = { SPLIT = true, OFFLINE = true, NO_REPLY = true, UNCONFIRMED = true }

local function player()
    return getSpecificPlayer(0)   -- LuaManager.java:4163-4167；分割畫面次玩家不能建，只看 0 號
end

local function changed(m)
    if m.onChange ~= nil then m.onChange(m) end
end

-- ===== 狀態機 =====

-- 背包（含巢狀容器）持有的地契等級，由低到高（getFirstTypeRecurse ItemContainer.java:1551）
function P.heldTiers(p)
    local out = {}
    if p == nil then return out end
    local inv = p:getInventory()
    for n = 1, MSH.MAX_TIER do
        if inv:getFirstTypeRecurse(MSH.deedType(n)) ~= nil then out[#out + 1] = n end
    end
    return out
end

-- 建立模式選地契：免費模式不帶地契（伺服器以 1 級計名額、帶了反而 BAD_DEED，Claims.checkDeed）；
-- 指定的地契還在背包就用它，否則用持有的最低級；都沒有＝NO_DEED 閘門
function P.pickDeed(m, want)
    local cfg = MSH.Settings.get()
    if cfg.createMode == MSH.Settings.CREATE.FREE then
        m.source, m.tier, m.deedType, m.held = SRC.FREE, 1, nil, {}
        return
    end
    m.source = SRC.DEED
    m.held = P.heldTiers(player())
    local tier = MSH.tierOfDeed(want)
    local has = false
    for _, n in ipairs(m.held) do
        if n == tier then has = true end
    end
    if not has then tier = m.held[1] end
    m.tier = tier
    m.deedType = tier and MSH.deedType(tier) or nil
end

function P.newModel(opts, playerNum)
    opts = opts or {}
    local m = { phase = P.IDLE, playerNum = playerNum or 0, mode = opts.mode == "redraw" and "redraw" or "create" }
    if m.mode == "redraw" then
        -- 等級沿用舊屋、不經過背包（§7.6）
        m.claimId, m.revision, m.tier = opts.claimId, opts.revision, opts.tier
        m.source = opts.source == SRC.FREE and SRC.FREE or SRC.DEED
    else
        P.pickDeed(m, opts.deedType)
    end
    return m
end

-- 換用另一級地契（只在 idle）
function P.chooseTier(m, tier)
    if m.phase ~= P.IDLE or m.source ~= SRC.DEED then return false end
    P.pickDeed(m, MSH.deedType(tier))
    changed(m)
    return m.tier == tier
end

-- 伺服器 slots 回的這一級（只列啟用的等級）
function P.tierSlots(m)
    local s = m.slots
    if type(s) ~= "table" or type(s.tiers) ~= "table" then return nil end
    for _, t in ipairs(s.tiers) do
        if t.tier == m.tier then return t end
    end
    return nil
end

-- 名額已滿：照伺服器 checkQuota 的順序——免費位（該級 TierNFree 開著且已用 < 上限）→ 付費（usable > 已用 paid）。
-- 沒有 slots 資料就不判斷（預檢與建立仍由伺服器把關）
function P.quotaFull(m)
    local s = m.slots
    if m.mode ~= "create" or type(s) ~= "table" or type(s.free) ~= "table" then return false end
    local t = P.tierSlots(m)
    if t == nil then return false end
    local freeLeft = t.free == true and (s.free.used or 0) < (s.free.n or 0)
    local paidLeft = (t.usable or 0) > (t.paid or 0)
    return not freeLeft and not paidLeft
end

-- idle 的閘門：回第一個擋住框選的碼或 nil（§10.4 idle 列）
function P.gate(m)
    if m.playerNum ~= 0 then return "SPLIT" end
    if m.blocked ~= nil then return m.blocked end
    local p = player()
    if p == nil then return "OFFLINE" end
    if p:isDead() then return CODE.DEAD end
    if m.mode == "redraw" then return nil end
    if m.source == SRC.DEED then
        if m.tier == nil then return CODE.NO_DEED end
        if not MSH.Settings.get().tiers[m.tier].enabled then return CODE.TIER_DISABLED end
    end
    if P.quotaFull(m) then return CODE.QUOTA_FULL end
    return nil
end

-- 名額與伺服器閘門（slots：Economy 代理的查詢；blocked＝HEALTH_BLOCKED／NOT_SURVIVED）
function P.refreshSlots(m)
    m.slotsRid = MSH.Client.send("slots", {}, function(res) P.onSlots(m, res) end)
end

function P.onSlots(m, res)
    if res.requestId ~= m.slotsRid then return end
    if res.ok then
        m.slots, m.blocked = res, res.blocked
    elseif res.code == CODE.DEDICATED_ONLY or res.code == CODE.IDENTITY_UNVERIFIED then
        m.blocked = res.code   -- 這兩個擋住所有指令；其他失敗（沒回覆、冷卻）只是沒有名額資料
    end
    changed(m)
end

function P.startSelect(m, tool)
    if m.phase ~= P.IDLE or P.gate(m) ~= nil then return false end
    m.tool = tool == Sel.WALK and Sel.WALK or Sel.DRAG
    P.lastTool = m.tool   -- 下次預設上次用的（§7.2）
    m.sel = Sel.new(m.tool, m.playerNum)
    m.phase, m.notice = P.SELECTING, nil
    changed(m)
    return true
end

local function clearPreview(m)
    m.checks, m.pass, m.failCode, m.failDetail, m.previewWant, m.previewRid = nil, nil, nil, nil, false, nil
end

-- 回 idle（取消、死亡、離線）；notice＝要在 idle 顯示的原因碼
function P.toIdle(m, notice)
    if m.sel ~= nil then Sel.stop(m.sel) end
    m.phase, m.sel, m.rect, m.notice = P.IDLE, nil, nil, notice
    clearPreview(m)
    changed(m)
end

-- 預檢排程：離上一次送出不到 PREVIEW_GAP_MS 就延後（同一位玩家所有面板共用）；過了時間由 pump 送
function P.schedulePreview(m, now)
    now = now or getTimestampMs()
    clearPreview(m)
    local at = now
    if P.lastPreviewAt ~= nil and P.lastPreviewAt + P.PREVIEW_GAP_MS > at then at = P.lastPreviewAt + P.PREVIEW_GAP_MS end
    m.previewWant, m.previewAt = true, at
    P.pump(m, now)
end

function P.pump(m, now)
    if not (m.previewWant and m.phase == P.PREVIEW and now >= m.previewAt) then return end
    m.previewWant = false
    P.lastPreviewAt = now
    local args = { rect = MSH.Rect.copy(m.rect) }
    if m.mode == "redraw" then args.claimId = m.claimId else args.deedType = m.deedType end
    m.previewRid = MSH.Client.send("preview", args, function(res) P.onPreview(m, res) end)
end

-- 〔完成〕：有範圍才進 preview
function P.finish(m, now)
    if m.phase ~= P.SELECTING or m.sel == nil then return false end
    Sel.update(m.sel, player())
    local rect = Sel.rect(m.sel)
    if rect == nil then return false end
    Sel.stop(m.sel)
    m.rect, m.phase = rect, P.PREVIEW
    P.schedulePreview(m, now)
    changed(m)
    return true
end

-- 〔重新框選〕：清掉範圍回 selecting（同一種選法）
function P.reselect(m)
    if m.phase ~= P.SELECTING and m.phase ~= P.PREVIEW and m.phase ~= P.CONFIRM then return false end
    if m.sel == nil then m.sel = Sel.new(m.tool, m.playerNum) end
    Sel.reset(m.sel)
    m.phase, m.rect = P.SELECTING, nil
    clearPreview(m)
    changed(m)
    return true
end

-- 〔重新預檢〕：同一個範圍再問一次（冷卻照排程）
function P.recheck(m, now)
    if m.phase ~= P.PREVIEW or m.rect == nil or m.previewWant or (m.previewRid ~= nil and m.checks == nil) then
        return false
    end
    P.schedulePreview(m, now)
    changed(m)
    return true
end

function P.onPreview(m, res)
    if m.phase ~= P.PREVIEW or res.requestId ~= m.previewRid then return end   -- 舊範圍的晚到結果不收
    if res.ok then
        m.checks, m.pass = res.checks or {}, res.pass == true
    else
        m.checks, m.pass, m.failCode, m.failDetail = {}, false, res.code, res
    end
    changed(m)
end

function P.toConfirm(m)
    if m.phase ~= P.PREVIEW or m.pass ~= true then return false end
    m.phase = P.CONFIRM
    changed(m)
    return true
end

-- 〔取消〕／Esc：confirm 回 preview；selecting／preview 回 idle；其餘回 false（呼叫端關窗，submitting 不理）
function P.back(m)
    if m.phase == P.CONFIRM then
        m.phase = P.PREVIEW
        changed(m)
        return true
    end
    if m.phase == P.SELECTING or m.phase == P.PREVIEW then
        P.toIdle(m, nil)
        return true
    end
    return false
end

-- 〔建立〕：title 空白＝伺服器用帳號名；其餘照 MSH.cleanTitle（1–40 位元組、不含控制字元與 []）
function P.submit(m, titleText)
    if m.phase ~= P.CONFIRM then return false end
    local title = nil
    if m.mode == "create" and type(titleText) == "string" and MSH.trim(titleText) ~= "" then
        title = MSH.cleanTitle(titleText)
        if title == nil then
            m.titleBad = true
            changed(m)
            return false
        end
    end
    m.titleBad = false
    -- 送出當下已知的「我的安全屋」：快取過期後用來認出新屋（清單沒抓過就不能認，只能說無法確認）
    m.known, m.knownValid = {}, MSH.Client.claims.at ~= nil
    for _, row in ipairs(MSH.Client.claims.mine) do m.known[row.claimId] = true end
    local command, args = "create", { rect = MSH.Rect.copy(m.rect) }
    if m.mode == "redraw" then
        command, args.claimId, args.expectedRevision = "redraw", m.claimId, m.revision
    else
        args.deedType, args.title = m.deedType, title
    end
    m.phase, m.failCode, m.failDetail, m.notice, m.expired, m.retried = P.SUBMITTING, nil, nil, nil, false, false
    m.rid = MSH.Client.send(command, args, function(res) P.onSubmit(m, res) end, { mutation = true })
    if m.rid == nil then m.phase, m.notice = P.CONFIRM, "OFFLINE" end
    changed(m)
    return m.rid ~= nil
end

function P.succeed(m, claimId)
    m.phase, m.newClaimId = P.DONE, claimId
    MSH.Client.refreshList()
    if not m.closed then
        P.close(m)
        local W = MSH.ManagerWindow
        if W ~= nil and W.open ~= nil then
            local ok, err = pcall(W.open, { claimId = claimId })
            if not ok then MSH.log("ManagerWindow.open failed: " .. tostring(err)) end
        end
    end
    changed(m)
end

-- 快取過期（或重送已不可能）：抓 authorized projection，有送出時不認得的我的安全屋＝成功；否則維持待定
function P.resolve(m)
    m.resolving, m.notice = true, nil
    MSH.Client.refreshList(function(res)
        m.resolving = false
        if m.phase ~= P.PENDING then return end
        if res.ok and m.knownValid then
            for _, row in ipairs(MSH.Client.claims.mine) do
                if not m.known[row.claimId] then return P.succeed(m, row.claimId) end
            end
        end
        m.notice = "UNCONFIRMED"
        changed(m)
    end)
end

function P.onSubmit(m, res)
    if res.requestId ~= m.rid then return end
    if res.ok then return P.succeed(m, res.claimId) end
    if res.code == "NO_REPLY" then
        if m.phase ~= P.SUBMITTING and m.phase ~= P.PENDING then return end
        m.phase = P.PENDING
        if res.expired then
            m.expired = true
            P.resolve(m)
        end
        changed(m)
        return
    end
    if m.closed then return end
    m.phase, m.failCode, m.failDetail, m.pass = P.PREVIEW, res.code, res, false
    changed(m)
end

-- 〔查詢結果〕：同一 requestId 重送；Client 已放棄這筆（過了伺服器快取時間）就改抓清單
function P.queryResult(m)
    if m.phase ~= P.PENDING or m.resolving then return false end
    m.notice = nil
    if not m.expired and MSH.Client.retry(m.rid) then
        m.retried = true
    else
        m.expired = true
        P.resolve(m)
    end
    changed(m)
    return true
end

-- 每 tick：selecting／preview／confirm 死亡或離線 → idle；走位終點跟著玩家；到時間的預檢送出
function P.update(m, now)
    local p = player()
    if m.phase == P.SELECTING or m.phase == P.PREVIEW or m.phase == P.CONFIRM then
        if p == nil then return P.toIdle(m, "OFFLINE") end
        if p:isDead() then return P.toIdle(m, CODE.DEAD) end
        if m.sel ~= nil then Sel.update(m.sel, p) end
    elseif m.phase == P.IDLE then
        local dead = p == nil or p:isDead()
        if dead ~= m.dead then
            m.dead = dead
            changed(m)
        end
    end
    P.pump(m, now)
end

function P.onTick()
    if P.model ~= nil then P.update(P.model, getTimestampMs()) end
end

-- ===== 畫面 =====

local V = {}
P.View = V
local PAD, GAP, ICON = 12, 6, 16
local W_MIN, W_MAX = 420, 560
local FONT = UIFont and UIFont.Small

-- 原因碼 → 原因、動作（本地碼用自己的鍵，其餘照 Client.codeText）
function P.reasonOf(code)
    if P.LOCAL_CODES[code] then
        local akey = "IGUI_MSH_Create_Action_" .. code
        local action = getText(akey)
        return getText("IGUI_MSH_Create_Reason_" .. code), action ~= akey and action or nil
    end
    return MSH.Client.codeText(code)
end

local function wrap(v, text, width)
    if v.wrapOK then return v.UI.Text.wrap(text, width, FONT) end
    return { text }
end

-- 一段文字（換行後逐行記下；只在狀態改變時重建，render 只畫）
local function para(v, text, token, icon, y)
    local indent = icon ~= nil and (ICON + 4) or 0
    for i, line in ipairs(wrap(v, text, v.innerW - indent)) do
        v.lines[#v.lines + 1] = { text = line, token = token, icon = i == 1 and icon or nil, x = PAD + indent, y = y }
        y = y + v.lineH
    end
    return y + 2
end

local function reasonLines(v, code, token, y)
    local reason, action = P.reasonOf(code)
    y = para(v, reason, token, "warning", y)
    if action ~= nil then y = para(v, action, "textMuted", nil, y) end
    return y
end

-- 名額不足時的價格（detail 來自 QUOTA_FULL；沒有就用 slots 的該級價格）；回 y, 是否有可買的
local function priceLines(v, detail, y)
    local t = P.tierSlots(v.m)
    local buy = type(detail.buy) == "table" and detail.buy or (t and t.buyPrice)
    local rent = type(detail.rent) == "table" and detail.rent or (t and t.rentPrice)
    if type(buy) == "table" then
        y = para(v, getText("IGUI_MSH_Create_PriceBuy", tostring(buy.amount), tostring(buy.currency)), "textMuted", nil, y)
    end
    if type(rent) == "table" then
        y = para(v, getText("IGUI_MSH_Create_PriceRent", tostring(rent.amount), tostring(rent.currency),
            tostring(rent.days)), "textMuted", nil, y)
    end
    return y, type(buy) == "table" or type(rent) == "table"
end

-- 一列控制項，放不下換行
local function row(v, list, y)
    local x, h = PAD, 0
    for _, b in ipairs(list) do
        if x > PAD and x + b.width > v.w - PAD then
            x, y, h = PAD, y + h + GAP, 0
        end
        b:setX(x)
        b:setY(y)
        b:setVisible(true)
        x, h = x + b.width + GAP, math.max(h, b.height)
    end
    return y + h + GAP
end

local function areaLine(v, y)
    local r = v.m.rect
    return para(v, getText("IGUI_MSH_Create_Area", tostring(r.w), tostring(r.h), tostring(r.x), tostring(r.y)), "text", nil, y)
end

function P.defaultTool()
    if P.lastTool ~= nil then return P.lastTool end
    return getJoypadData(0) ~= nil and Sel.WALK or Sel.DRAG   -- 手把玩家預設走位（§7.2）
end

local function layoutIdle(v, y, list)
    local m, b = v.m, v.btn
    if m.mode == "redraw" then
        if m.tier ~= nil then y = para(v, getText("IGUI_MSH_Create_Tier", tostring(m.tier)), "text", nil, y) end
        y = para(v, getText("IGUI_MSH_Create_RedrawHint"), "textMuted", nil, y)
    elseif m.source == SRC.FREE then
        y = para(v, getText("IGUI_MSH_Create_Free"), "text", nil, y)
    elseif m.tier ~= nil then
        y = para(v, getText("IGUI_MSH_Create_Tier", tostring(m.tier)), "text", nil, y)
    end
    if v.maxSide ~= nil then
        y = para(v, getText("IGUI_MSH_Create_Limit", tostring(v.maxSide), tostring(v.maxArea)), "textMuted", nil, y)
    end
    local s, t = m.slots, P.tierSlots(m)
    if m.mode == "create" and type(s) == "table" and type(s.free) == "table" then
        y = para(v, getText("IGUI_MSH_Create_QuotaFree", tostring(s.free.used or 0), tostring(s.free.n or 0)), "textMuted", nil, y)
        if t ~= nil and (t.usable or 0) > 0 then
            y = para(v, getText("IGUI_MSH_Create_QuotaPaid", tostring(m.tier), tostring(t.paid or 0), tostring(t.usable)),
                "textMuted", nil, y)
        end
    end
    if m.source == SRC.DEED and m.mode == "create" and #m.held > 1 then
        y = para(v, getText("IGUI_MSH_Create_ChooseDeed"), "text", nil, y)
        local chips = {}
        for i, n in ipairs(m.held) do
            local c = v.chips[i]
            c.tier = n
            c:setTitle(getText("IGUI_MSH_Create_TierChip", tostring(n)))
            c:fitWidth()
            c:setActive(n == m.tier)
            chips[#chips + 1] = c
        end
        y = row(v, chips, y)
    end
    if m.notice ~= nil then y = reasonLines(v, m.notice, "warning", y) end
    local gate = P.gate(m)
    local pay = false
    if gate ~= nil then
        y = reasonLines(v, gate, "warning", y)
        if gate == CODE.QUOTA_FULL then y, pay = priceLines(v, { tier = m.tier }, y) end
    end
    y = para(v, getText("IGUI_MSH_Create_ChooseTool"), "text", nil, y)
    local walkFirst = P.defaultTool() == Sel.WALK
    b.drag:setStyle(walkFirst and "normal" or "primary")
    b.walk:setStyle(walkFirst and "primary" or "normal")
    b.drag:setEnabled(gate == nil)
    b.walk:setEnabled(gate == nil)
    if walkFirst then list[#list + 1] = b.walk; list[#list + 1] = b.drag
    else list[#list + 1] = b.drag; list[#list + 1] = b.walk end
    if pay and MSH.SlotsWindow ~= nil then list[#list + 1] = b.pay end
    list[#list + 1] = b.close
    return y
end

local function layoutSelecting(v, y, list)
    local m, b, s = v.m, v.btn, v.m.sel
    local joy = s.tool == Sel.DRAG and Sel.usingJoypad(s)
    v.corner, v.joy = s.ax ~= nil, joy
    local hint = "IGUI_MSH_Select_DragHint"
    if s.tool == Sel.WALK then hint = "IGUI_MSH_Select_WalkHint" elseif joy then hint = "IGUI_MSH_Select_DragHintJoypad" end
    y = para(v, getText(hint), "textMuted", nil, y)
    if m.mode == "redraw" then y = para(v, getText("IGUI_MSH_Create_RedrawHint"), "textMuted", nil, y) end
    v.sizeY, v.sizeW = y, nil   -- 即時 w×h＝面積／上限：render 畫這一行（範圍變了才重組字串）
    y = y + v.lineH + 4
    if s.ax == nil then
        if s.tool == Sel.WALK or joy then list[#list + 1] = b.mark end
    else
        list[#list + 1] = b.done
        list[#list + 1] = b.redo
    end
    list[#list + 1] = b.cancel
    return y
end

local function layoutPreview(v, y, list)
    local m, b = v.m, v.btn
    y = areaLine(v, y)
    local pay = false
    if m.failCode ~= nil then
        y = reasonLines(v, m.failCode, "errorText", y)
        if m.failCode == CODE.QUOTA_FULL then y, pay = priceLines(v, m.failDetail or {}, y) end
    end
    if m.checks == nil then
        y = para(v, getText("IGUI_MSH_Create_Checking"), "textMuted", nil, y)
    else
        for _, c in ipairs(m.checks) do
            local label = getText("IGUI_MSH_Create_Check_" .. tostring(c.name))
            if c.ok then
                y = para(v, label, "text", "check", y)
            else
                local reason, action = P.reasonOf(c.code)
                y = para(v, getText("IGUI_MSH_Create_CheckFail", label, reason), "errorText", "warning", y)
                if action ~= nil then y = para(v, action, "textMuted", nil, y) end
                if c.code == CODE.QUOTA_FULL then
                    local more
                    y, more = priceLines(v, c, y)
                    pay = pay or more
                end
            end
        end
        if m.pass then y = para(v, getText("IGUI_MSH_Create_AllPassed"), "textMuted", nil, y) end
    end
    b.create:setEnabled(m.pass == true)
    list[#list + 1] = b.create
    if m.checks ~= nil then list[#list + 1] = b.recheck end
    if pay and MSH.SlotsWindow ~= nil then list[#list + 1] = b.pay end
    list[#list + 1] = b.redo
    list[#list + 1] = b.cancel
    return y
end

local function layoutConfirm(v, y, list, busy)
    local m, b = v.m, v.btn
    y = areaLine(v, y)
    if m.mode == "redraw" then
        y = para(v, getText("IGUI_MSH_Create_RedrawSource"), "text", nil, y)
        y = para(v, getText("IGUI_MSH_Create_RedrawHint"), "textMuted", nil, y)
    elseif m.source == SRC.FREE then
        y = para(v, getText("IGUI_MSH_Create_SourceFree"), "text", nil, y)
    else
        y = para(v, getText("IGUI_MSH_Create_SourceDeed", tostring(m.tier)), "text", nil, y)
    end
    y = para(v, getText("IGUI_MSH_Create_AllPassed"), "textMuted", nil, y)
    if m.notice ~= nil then y = reasonLines(v, m.notice, "warning", y) end
    if m.mode == "create" then
        y = para(v, getText("IGUI_MSH_Create_TitleLabel"), "text", nil, y)
        local f = v.field
        f:setX(PAD)
        f:setY(y)
        f:setWidth(v.innerW)
        f:setVisible(true)
        f:setEnabled(not busy)
        if v.invalidOK then f:setInvalid(m.titleBad == true, m.titleBad and (P.reasonOf(CODE.BAD_TITLE)) or nil) end
        y = y + f.height + GAP
        if m.titleBad then y = reasonLines(v, CODE.BAD_TITLE, "errorText", y) end
    end
    if busy then y = para(v, getText("IGUI_MSH_Create_Waiting"), "warning", nil, y) end
    b.confirm:setEnabled(not busy)
    b.cancel:setEnabled(not busy)
    list[#list + 1] = b.confirm
    list[#list + 1] = b.cancel
    return y
end

local function layoutPending(v, y, list)
    local m, b = v.m, v.btn
    y = para(v, getText("IGUI_MSH_Create_Pending"), "warning", nil, y)
    if m.resolving then
        y = para(v, getText("IGUI_MSH_Create_Checking"), "textMuted", nil, y)
    elseif m.notice ~= nil then
        y = reasonLines(v, m.notice, "warning", y)
    elseif m.retried then
        y = para(v, getText("IGUI_MSH_Create_PendingRetried"), "textMuted", nil, y)
    end
    b.query:setEnabled(not m.resolving)
    list[#list + 1] = b.query
    list[#list + 1] = b.close
    return y
end

-- 狀態改變時重排（不在每幀做）：藏全部控制項 → 依狀態放文字與按鈕 → 調高度 → 焦點框移到有效目標
function V.layout(v)
    local m = v.m
    if v.win == nil or m.phase == P.DONE then return end
    for _, b in pairs(v.btn) do b:setVisible(false) end
    for _, c in ipairs(v.chips) do c:setVisible(false) end
    v.field:setVisible(false)
    v.lines = {}
    v.sizeY = nil
    v.maxSide, v.maxArea = nil, nil
    if m.tier ~= nil then v.maxSide, v.maxArea = MSH.Settings.sizeLimit(MSH.Settings.get(), m.source, m.tier) end
    local list, y = {}, PAD
    if m.phase == P.IDLE then y = layoutIdle(v, y, list)
    elseif m.phase == P.SELECTING then y = layoutSelecting(v, y, list)
    elseif m.phase == P.PREVIEW then y = layoutPreview(v, y, list)
    elseif m.phase == P.CONFIRM then y = layoutConfirm(v, y, list, false)
    elseif m.phase == P.SUBMITTING then y = layoutConfirm(v, y, list, true)
    elseif m.phase == P.PENDING then y = layoutPending(v, y, list) end
    y = row(v, list, y + 4) + PAD - GAP
    v.body:setHeight(y)
    v.win:setHeight(v.top + y)
    local Focus = v.UI.Focus
    if Focus ~= nil and Focus.invalidate ~= nil then Focus.invalidate(v.win) end
end

-- 即時大小行；回是否超過上限（範圍變了才重組字串）
local function sizeLine(v)
    local _, _, w, h = Sel.bounds(v.m.sel)
    if w == nil then w, h = 0, 0 end
    local over = v.maxSide ~= nil and (w > v.maxSide or h > v.maxSide or w * h > v.maxArea)
    if w ~= v.sizeW or h ~= v.sizeH then
        v.sizeW, v.sizeH = w, h
        if v.maxArea ~= nil then
            v.sizeText = getText("IGUI_MSH_Select_Size", tostring(w), tostring(h), tostring(w * h), tostring(v.maxArea))
        else
            v.sizeText = getText("IGUI_MSH_Select_SizeNoLimit", tostring(w), tostring(h), tostring(w * h))
        end
        v.sizeTok = over and "errorText" or "text"
    end
    return over
end

-- 每個 UI 幀（Body:prerender）：走位終點、即時大小、重加範圍高亮（§2.8 只畫一層）
function V.frame(v)
    local m = v.m
    if m.phase ~= P.SELECTING or m.sel == nil then return end
    local p = player()
    if p == nil then return end
    local s = m.sel
    Sel.update(s, p)
    if (s.ax ~= nil) ~= v.corner or (s.tool == Sel.DRAG and Sel.usingJoypad(s)) ~= v.joy then V.layout(v) end
    local c = sizeLine(v) and v.colors.errorText or v.colors.accent
    Sel.draw(s, p, c.r, c.g, c.b, 0.5)
end

function V.draw(el, v)
    local colors = v.colors
    local Icons = v.UI.Icons
    for i = 1, #v.lines do
        local l = v.lines[i]
        local c = colors[l.token] or colors.text
        if l.icon ~= nil then Icons.draw(el, l.icon, PAD, l.y + v.iconDY, ICON, c) end
        el:drawText(l.text, l.x, l.y, c.r, c.g, c.b, c.a or 1, FONT)
    end
    if v.sizeY ~= nil and v.sizeText ~= nil and v.m.phase == P.SELECTING then
        local c = colors[v.sizeTok] or colors.text
        el:drawText(v.sizeText, PAD, v.sizeY, c.r, c.g, c.b, c.a or 1, FONT)
    end
end

local Body = nil   -- 第一次開窗才 derive（harness 載入時沒有 ISPanel）
local function bodyClass()
    if Body == nil then
        Body = ISPanel:derive("MinidoracatSafehouseCreateBody")
        function Body:prerender() V.frame(self.view) end
        function Body:render() V.draw(self, self.view) end
    end
    return Body
end

-- 拖曳中的手把十字鍵屬於游標，按鈕改用 LB／RB 切換
local function joyDragging(m)
    return m.phase == P.SELECTING and m.sel ~= nil and m.sel.tool == Sel.DRAG and Sel.usingJoypad(m.sel)
end

-- Esc／手把 B＝取消：confirm 回 preview、selecting／preview 回 idle、submitting 不理、其餘關窗（不取消建立）
local function escape(m)
    if m.phase == P.SUBMITTING then return true end
    if not P.back(m) then P.close(m) end
    return true
end

-- 視窗的滑鼠與手把：世界上的拖曳收在視窗的 outside 事件（UIElement.java:1001-1035、1262-1280；
-- UIManager.java:673-697 對不在滑鼠下的頂層元件呼叫 outside），原本的拖曳視窗處理照常
local function hookInput(v, win, m)
    win.onMouseDownOutside = function()
        if m.phase == P.SELECTING and m.sel ~= nil then Sel.mouseDown(m.sel, player()) end
    end
    local baseMove, baseUp = win.onMouseMoveOutside, win.onMouseUpOutside
    win.onMouseMoveOutside = function(self, dx, dy)
        local r = baseMove(self, dx, dy)
        if m.phase == P.SELECTING and m.sel ~= nil then Sel.mouseMove(m.sel, player()) end
        return r
    end
    win.onMouseUpOutside = function(self, x, y)
        local r = baseUp(self, x, y)
        if m.sel ~= nil then Sel.mouseUp(m.sel) end
        return r
    end
    local function dir(name, dx, dy)
        local base = win["onJoypadDir" .. name]
        win["onJoypadDir" .. name] = function(self, data)
            if joyDragging(m) then Sel.joyDir(m.sel, player(), dx, dy) else base(self, data) end
        end
    end
    dir("Up", 0, -1)
    dir("Down", 0, 1)
    dir("Left", -1, 0)
    dir("Right", 1, 0)
    local baseShoulder = win.onFocusShoulder
    win.onFocusShoulder = function(self, delta)
        if joyDragging(m) and v.UI.Focus ~= nil then v.UI.Focus.step(self, delta) else baseShoulder(self, delta) end
    end
    win.onEscape = function() return escape(m) end
    win.onClose = function() P.close(m) end
end

local function buildButtons(v, m, UI, theme)
    local function button(key, onClick, style)
        local b = UI.Button.new({ x = 0, y = 0, title = getText(key), style = style, theme = theme, onClick = onClick })
        v.body:addChild(b)
        b:setVisible(false)
        return b
    end
    local function now() return getTimestampMs() end
    v.btn = {
        drag = button("IGUI_MSH_Select_Drag", function() P.startSelect(m, Sel.DRAG) end),
        walk = button("IGUI_MSH_Select_Walk", function() P.startSelect(m, Sel.WALK) end),
        mark = button("IGUI_MSH_Select_Mark", function()
            if m.sel ~= nil and Sel.mark(m.sel, player()) then V.layout(v) end
        end, "primary"),
        done = button("IGUI_MSH_Select_Done", function() P.finish(m, now()) end, "primary"),
        redo = button("IGUI_MSH_Select_Redo", function() P.reselect(m) end),
        cancel = button("UI_Cancel", function() P.back(m) end),
        create = button("IGUI_MSH_Create_CreateBtn", function() P.toConfirm(m) end, "primary"),
        recheck = button("IGUI_MSH_Create_Recheck", function() P.recheck(m, now()) end),
        pay = button("IGUI_MSH_Create_Pay", function()
            local ok, err = pcall(MSH.SlotsWindow.open, { tier = m.tier })
            if not ok then MSH.log("SlotsWindow.open failed: " .. tostring(err)) end
        end),
        confirm = button(m.mode == "redraw" and "IGUI_MSH_Create_ConfirmRedraw" or "IGUI_MSH_Create_Confirm", function()
            P.submit(m, v.field:getText())
        end, "primary"),
        query = button("IGUI_MSH_Create_Query", function() P.queryResult(m) end, "primary"),
        close = button("IGUI_MSH_Create_Close", function() P.close(m) end),
    }
    v.chips = {}
    for i = 1, MSH.MAX_TIER do
        local c
        c = UI.Button.new({ x = 0, y = 0, title = "", style = "chip", theme = theme,
            onClick = function() P.chooseTier(m, c.tier) end })
        v.body:addChild(c)
        c:setVisible(false)
        v.chips[i] = c
    end
    local p = player()
    v.field = UI.TextField.new({ x = PAD, y = 0, width = v.innerW, maxLength = MSH.LIMIT.TITLE_CHARS, theme = theme,
        placeholder = p and p:getUsername() or "" })
    v.body:addChild(v.field)
    v.field:setVisible(false)
end

function V.build(m, UI)
    local theme = MSH.Client.theme(UI)
    local caps = UI.CAPABILITIES or {}
    local tm = getTextManager()
    local sw = getCore():getScreenWidth()
    local w = math.max(W_MIN, math.min(W_MAX, sw - 40))
    local v = { m = m, UI = UI, theme = theme, colors = theme.colors, w = w, innerW = w - PAD * 2, lines = {},
        lineH = tm:getFontHeight(FONT) + 2, wrapOK = caps.textWrap == true and UI.Text ~= nil and UI.Text.wrap ~= nil,
        invalidOK = caps.textFieldInvalid == true }
    v.iconDY = math.floor((v.lineH - 2 - ICON) / 2)
    -- 非 modal、不 alwaysOnTop；放右側，框選時不擋住角色附近的地面
    local win = UI.Window.new({ x = math.max(0, sw - w - 60), y = 120, width = w, height = 200, icon = "house", theme = theme,
        title = getText(m.mode == "redraw" and "IGUI_MSH_Create_RedrawTitle" or "IGUI_MSH_Create_Title") })
    v.win, v.top = win, win:contentTop()
    local body = bodyClass():new(0, v.top, w, 100)
    body.background = false
    body.view = v
    body:initialise()
    win:addChild(body)
    v.body = body
    buildButtons(v, m, UI, theme)
    hookInput(v, win, m)
    m.view = v
    m.onChange = function() V.layout(v) end
    V.layout(v)
    win:addToUIManager()
    return v
end

-- 框架不合或建窗失敗：最小直角 vanilla 面板（ISPanel.lua:96、ISButton.lua:479），只有一句話與〔關閉〕
function P.fallback()
    local ok, err = pcall(function()
        local tm = getTextManager()
        local text = getText("IGUI_MSH_Create_NeedFramework")
        local fh = tm:getFontHeight(UIFont.Small)
        local w = math.max(320, tm:MeasureStringX(UIFont.Small, text) + PAD * 2)
        local h = PAD + fh + PAD + fh + 6 + PAD
        local panel = ISPanel:new(math.floor((getCore():getScreenWidth() - w) / 2),
            math.floor((getCore():getScreenHeight() - h) / 2), w, h)
        panel:initialise()
        panel.render = function(self) self:drawText(text, PAD, PAD, 1, 1, 1, 1, UIFont.Small) end
        local btn = ISButton:new(w - 100 - PAD, h - PAD - fh - 6, 100, fh + 6, getText("IGUI_MSH_Create_Close"), panel,
            function(target)
                target:setVisible(false)
                target:removeFromUIManager()
            end)
        btn:initialise()
        panel:addChild(btn)
        panel:addToUIManager()
        P.fallbackPanel = panel
    end)
    if not ok then MSH.log("create panel fallback failed: " .. tostring(err)) end
end

function P.close(m)
    if m.closed then return end
    m.closed = true
    if m.sel ~= nil then Sel.stop(m.sel) end
    if P.model == m then P.model = nil end
    local v = m.view
    m.view, m.onChange = nil, nil
    if v ~= nil and v.win ~= nil then
        local win = v.win
        v.win = nil
        pcall(function()
            if win:getIsVisible() then win:close() end
            win:removeFromUIManager()
        end)
    end
end

local function openUnsafe(opts)
    if P.model ~= nil then P.close(P.model) end   -- 一次一個；待定中的建立不會因此取消
    local UI = MSH.Client.ui({ "window", "controls", "focus" })
    if UI == nil then
        MSH.log("create panel needs MinidoracatUI rev " .. tostring(MSH.Client.MIN_REV) .. " with window/controls/focus")
        return P.fallback()
    end
    local m = P.newModel(opts, opts.playerNum)
    P.model = m
    V.build(m, UI)
    if m.playerNum == 0 then
        P.refreshSlots(m)
        MSH.Client.refreshList()   -- 送出時要用最新的「我的安全屋」認新屋
    end
    return m
end

function P.open(opts)
    local ok, res = pcall(openUnsafe, opts or {})
    if ok then return res end
    MSH.log("create panel failed: " .. tostring(res))
    if P.model ~= nil then P.close(P.model) end   -- 半建好的視窗一起收掉
    P.fallback()
    return nil
end

-- ===== 地契右鍵「使用地契」=====
-- items：InventoryItem 或疊在一起的 { items = { ... } }（ISInventoryPaneContextMenu.lua:128-137；事件 :935）
function P.onInventoryMenu(playerNum, context, items)
    for _, v in ipairs(items) do
        local item = v
        if not instanceof(v, "InventoryItem") then item = type(v) == "table" and v.items and v.items[1] or nil end
        local ft = item ~= nil and item.getFullType ~= nil and item:getFullType() or nil   -- InventoryItem.java:1657
        if MSH.tierOfDeed(ft) ~= nil then
            -- ISContextMenu:addOption(name, target, onSelect, param1)（ISContextMenu.lua:873）
            local opt = context:addOption(getText("IGUI_MSH_Deed_Use"), ft, P.onUseDeed, playerNum)
            if playerNum ~= 0 and opt ~= nil then
                -- 分割畫面次玩家沒有身分，不能建（§1.1 第 11 點）；不可用選項＋說明照原版 :410-413
                opt.notAvailable = true
                if ISInventoryPaneContextMenu ~= nil and ISInventoryPaneContextMenu.addToolTip ~= nil then
                    local tip = ISInventoryPaneContextMenu.addToolTip()
                    tip.description = getText("IGUI_MSH_Create_Reason_SPLIT")
                    opt.toolTip = tip
                end
            end
            return
        end
    end
end

function P.onUseDeed(fullType, playerNum)
    if playerNum ~= 0 then return end
    P.open({ deedType = fullType, playerNum = playerNum })
end

if first then
    Events.OnTick.Add(function() MSH.CreatePanel.onTick() end)
    Events.OnFillInventoryObjectContextMenu.Add(function(playerNum, context, items)
        MSH.CreatePanel.onInventoryMenu(playerNum, context, items)
    end)
end
