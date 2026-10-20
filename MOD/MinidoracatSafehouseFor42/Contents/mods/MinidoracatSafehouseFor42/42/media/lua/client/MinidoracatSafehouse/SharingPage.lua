-- MinidoracatSafehouse/SharingPage.lua：管理視窗「成員與分享」頁（M3，計畫 §10.5、§6.5）。
-- 上半「目前分享給」：陣營列（權限、〔恢復分享〕〔停止〕）與玩家名單。名單是 VirtualList，可以一次選好幾位（使用者
--   2026-10-20 核准設計稿 temp/plan-bulkshare-1020；照 Economy 商店編輯 ECAdminShop onRow 與原版物品欄
--   ISInventoryPane.lua:1669-1700）：點一列＝只選這一位，點勾選框或 Ctrl＋點＝加選或取消，Shift＋點＝從錨點選一段，
--   Ctrl＋A 全選；鍵盤方向鍵移動、Space／Enter 勾選、Shift＋方向鍵一路選過去；手把十字鍵移動、A 勾選；Esc／手把 B 清除
--   選取（ManagerWindow 的 win.onEscape）。名單底下〔全選〕〔清除選取〕與操作說明：清除不靠快捷鍵。
-- 下半跟著選了幾位換：沒選＝新增分享（先勾權限，再輸入玩家名稱〔分享給玩家〕或〔分享給陣營〕）；選一位＝chip 帶入他
--   目前的權限，改了才能〔儲存變更〕；選兩位以上＝三態 chip（全部有、部分有寫「k/n」、都沒有；點一下依序加給全部、從
--   全部拿掉、不改），〔套用到 N 位...〕先確認。一位與多位都送 shareEdit（只送要加、要拿的位元，伺服器不整組覆蓋）；
--   停止分享先開 danger 確認框再送 unshareMany，陣營的〔停止〕也先確認。
--   玩家名稱是框架的 Autocomplete（rev 11）：打字時向伺服器查候選（shareCandidates，Sharing.candidates）、點選寫進
--   輸入框；伺服器另外檢查新加的名字是不是認得的玩家（UNKNOWN_PLAYER，使用者 2026-10-12）。屋主與管理成員打了名單上
--   的人，改成選到他那一列（使用者 2026-10-20）。
-- 只送提案，畫面以伺服器結果與重抓的 detail 為準（§10.4 最後一段）。這裡只是不給按（體驗），伺服器才是防線（契約 M2）：
--   屋主全部可給、可改；MANAGE 成員只能給、加減自己有的位元（另外可給 INVITE），不能給 MANAGE、不能動自己與實際持有
--   MANAGE 的人；只有 INVITE 的成員只能把新玩家加進來（名單上已有的名字送出前就擋），位元 ⊆ 自己的、不含 INVITE 與
--   MANAGE，名單一列都不能勾、不能動陣營分享（使用者 2026-10-11）。陣營分享一律不帶 INVITE 與 MANAGE（SP.factionBits）。
-- 元件與送出都借管理視窗（host：button／newLines／place／fit／flow／addWrapped／mutate／say／layout），本檔只排版與組指令。

if not isClient() then return end

require "MinidoracatSafehouse/Contract"

local MSH = MinidoracatSafehouse
local SHARE = MSH.SHARE
local SP = MSH.SharingPage or {}
MSH.SharingPage = SP

-- 遠距拿取（使用者 2026-10-20）排在農耕後面：一般權限在前、邀請與管理在最後
SP.CHIPS = { "MEMBER", "USE", "MOVE", "BUILD", "FARM", "TAKE", "INVITE", "MANAGE" }
SP.DEFAULT_BITS = SHARE.MEMBER + SHARE.USE   -- 預設勾成員與用電器（§10.5）
SP.BOX_W = 26      -- 名單列左邊勾選框的點擊寬度（同 VM 車隊 BOX_W）
SP.ROW_GAP = 2     -- 名單列的間距（VirtualList padding）
SP.MIN_ROWS = 3    -- 名單被收短時至少留幾列（Page:layout）

-- ===== 純邏輯（t_ui_manager.lua 測）=====

-- 切換一個 chip：其他權限一定要搭配成員（打開就自動加成員）；取消成員＝全部取消（§6.5「其他位元一定要搭配 MEMBER」）
function SP.setChip(bits, name, on)
    local bit = SHARE[name]
    if name == "MEMBER" and not on then return 0 end
    local has = MSH.hasBit(bits, bit)
    if on and not has then
        bits = bits + bit
    elseif not on and has then
        bits = bits - bit
    end
    if on and not MSH.hasBit(bits, SHARE.MEMBER) then bits = bits + SHARE.MEMBER end
    return bits
end

-- 位元 → 本地化權限名稱（照 CHIPS 順序）
function SP.bitsText(bits)
    local parts = {}
    for _, name in ipairs(SP.CHIPS) do
        if MSH.hasBit(bits, SHARE[name]) then parts[#parts + 1] = getText("IGUI_MSH_Share_Bit_" .. name) end
    end
    return table.concat(parts, getText("IGUI_MSH_Share_ListSep"))
end

-- 概覽的身分欄（成員）：「成員（其他權限）」，括號裡不再列「成員」；只有成員一項時就寫「成員」
-- （2026-10-13 發布前回歸 ui-mp 截圖：「成員（成員、用電器、邀請）」）
function SP.roleText(bits)
    if MSH.hasBit(bits, SHARE.MEMBER) then bits = bits - SHARE.MEMBER end
    local extra = SP.bitsText(bits)
    if extra == "" then return getText("IGUI_MSH_Share_Bit_MEMBER") end
    return getText("IGUI_MSH_Manager_RoleMember", extra)
end

-- 能不能新增分享（「成員與分享」頁是否出現）：active 且是屋主、MANAGE 或 INVITE 成員（SharingServer 的 ACL；
-- detail 沒有專用欄位，從 actorRole／bits／lifecycle 推）
function SP.canAdd(d)
    if d.lifecycle ~= MSH.LIFECYCLE.ACTIVE then return false end
    return d.actorRole == "owner" or MSH.hasBit(d.bits, SHARE.MANAGE) or MSH.hasBit(d.bits, SHARE.INVITE)
end

-- 能不能改既有分享（勾名單、陣營的停止）：屋主或 MANAGE 成員（actions.canManageShares）
function SP.canEdit(d)
    return (d.actions or {}).canManageShares == true
end

-- 名單這一列能不能勾（改權限、停止分享）：能勾回 nil，不能勾回原因的翻譯鍵（滑鼠提示與焦點說明）。屋主都可以；只有
-- INVITE 的成員一列都不能；MANAGE 成員不能動自己與實際持有 MANAGE 的人（伺服器用 roleOf 判定，陣營給的 MANAGE 也算：
-- 看 effBits＝grant 與有效陣營分享的聯集；舊伺服器沒有這欄時退回 bits）
function SP.rowBlock(d, grant, me)
    if d.actorRole == "owner" then return nil end
    if not SP.canEdit(d) then return "IGUI_MSH_Share_RowInviteOnly" end
    if grant.user == me then return "IGUI_MSH_Share_RowSelf" end
    if MSH.hasBit(grant.effBits or grant.bits, SHARE.MANAGE) then return "IGUI_MSH_Share_RowManager" end
    return nil
end

-- 能不能停止陣營分享：屋主或 MANAGE 成員（陣營分享不帶 INVITE／MANAGE，所以不再看陣營分享的位元）
function SP.canStopFaction(d)
    return SP.canEdit(d) and type(d.factionShare) == "table"
end

-- 陣營分享能帶的位元：一律去掉 INVITE 與 MANAGE（主代理裁定 2026-10-11；伺服器收到會回 BAD_ARGS）。
-- 上限取 Contract 的 SHARE_FACTION_MAX；舊 Contract 沒有時用一般位元的和。Kahlua 沒有位元運算子，逐位元取交集
function SP.factionBits(bits)
    local max = MSH.SHARE_FACTION_MAX or (SHARE.MEMBER + SHARE.USE + SHARE.MOVE + SHARE.BUILD + SHARE.FARM)
    local out = 0
    for _, name in ipairs(SP.CHIPS) do
        local bit = SHARE[name]
        if MSH.hasBit(bits, bit) and MSH.hasBit(max, bit) then out = out + bit end
    end
    return out
end

-- 只有 INVITE 的成員只能加新人：輸入的名字已經是屋主或在 grants 裡（屋主與 MANAGE 成員輸入既有名字＝選到那一列，不擋）
function SP.alreadyListed(d, user)
    if d.actorRole == "owner" or SP.canEdit(d) then return false end
    for _, r in ipairs(d.roster or {}) do
        if r.role == "owner" and r.user == user then return true end
    end
    for _, g in ipairs(d.grants or {}) do
        if g.user == user then return true end
    end
    return false
end

-- 能勾的 chip：屋主全部；成員不能給 MANAGE；MANAGE 成員可給 INVITE（自己沒有也可以），其餘只能給自己有的位元
-- （伺服器要求子集）；只有 INVITE 的成員不能給 INVITE；兩者都沒有的成員一個都不能勾
function SP.chipAllowed(d, name)
    if d.actorRole == "owner" then return true end
    if name == "MANAGE" then return false end
    local manager = MSH.hasBit(d.bits, SHARE.MANAGE)
    if not manager and not MSH.hasBit(d.bits, SHARE.INVITE) then return false end
    if name == "INVITE" then return manager end
    return MSH.hasBit(d.bits, SHARE[name])
end

-- 新增分享要送出的位元：只留能勾的 chip（換了屋或自己的位元變少時把已勾的收回）
function SP.shareBits(d, bits)
    local out = 0
    for _, name in ipairs(SP.CHIPS) do
        if MSH.hasBit(bits, SHARE[name]) and SP.chipAllowed(d, name) then out = out + SHARE[name] end
    end
    return out
end

-- 陣營暫停原因（Sharing.lua：GONE／LEADER_CHANGED／OWNER_LEFT；其他用一般句）
function SP.reasonKey(fs)
    local r = fs.reason
    if r == "GONE" or r == "LEADER_CHANGED" or r == "OWNER_LEFT" then return "IGUI_MSH_Share_Suspended_" .. r end
    return "IGUI_MSH_Share_Suspended"
end

-- 選一位時的變更：base 沒有、now 有＝加；反之＝拿（chip 只改得到能勾的位元，其他位元不動）
function SP.diff(base, now)
    local add, remove = 0, 0
    for _, name in ipairs(SP.CHIPS) do
        local bit = SHARE[name]
        local was, is = MSH.hasBit(base, bit), MSH.hasBit(now, bit)
        if is and not was then
            add = add + bit
        elseif was and not is then
            remove = remove + bit
        end
    end
    return add, remove
end

-- 選兩位以上時 chip 點一下的下一個狀態（nil＝不改、"add"＝加給全部、"remove"＝從全部拿掉）；k＝幾位有、n＝選了幾位。
-- 沒作用的跳過：都沒有時只在不改與加給全部之間切換，全部都有時只在不改與拿掉之間切換
function SP.nextMode(mode, k, n)
    if mode == nil then return k < n and "add" or "remove" end
    if mode == "add" and k > 0 then return "remove" end
    return nil
end

-- 選兩位以上：每個 chip 的狀態 → 要加、要拿的位元
function SP.modeBits(modes)
    local add, remove = 0, 0
    for _, name in ipairs(SP.CHIPS) do
        local m = modes[name]
        if m == "add" then
            add = add + SHARE[name]
        elseif m == "remove" then
            remove = remove + SHARE[name]
        end
    end
    return add, remove
end

-- 套用到多位前的確認內文：每個改到的權限一行（「遠距拿取：加給 bob、carl」「邀請：從 carl 拿掉」），只列真的會變的人
function SP.applyText(rows, add, remove)
    local sep, lines = getText("IGUI_MSH_Share_ListSep"), {}
    for _, name in ipairs(SP.CHIPS) do
        local bit = SHARE[name]
        local adding = MSH.hasBit(add, bit)
        if adding or MSH.hasBit(remove, bit) then
            local who = {}
            for _, r in ipairs(rows) do
                if MSH.hasBit(r.bits, bit) ~= adding then who[#who + 1] = r.user end
            end
            if #who > 0 then
                lines[#lines + 1] = getText(adding and "IGUI_MSH_Share_ApplyAdd" or "IGUI_MSH_Share_ApplyRemove",
                    getText("IGUI_MSH_Share_Bit_" .. name), table.concat(who, sep))
            end
        end
    end
    return table.concat(lines, "\n")
end

-- ===== 名單列（VirtualList cell）=====
-- 左邊勾選框（同 VM 車隊 MinidoracatVehicleManager_FleetWindow.lua:484-490）、「帳號：權限」截字；截到字或不能勾時，滑鼠
-- 提示寫全文與原因（借原版 ISButton:updateTooltip，同管理視窗清單）。選中的列整列 selected 底。
-- ISPanel 子類在第一次建列時才建（harness 載入本檔時沒有 ISPanel）
local Row
local function rowClass()
    if Row ~= nil then return Row end
    Row = ISPanel:derive("MSHShareRow")
    function Row:prerender()
        if self.tooltip or self.tooltipUI then ISButton.updateTooltip(self) end
    end
    function Row:render()
        local row = self.row
        if row == nil then return end
        local p = self.page
        local theme = p.host.theme
        local c = theme.colors
        local w, h = self.width, self.height
        local on = p.picked[row.user] == true
        if on then
            theme:fill(self, 0, 0, w, h, "selected")
        elseif row.block == nil and self:isMouseOver() then
            theme:fill(self, 0, 0, w, h, "hover")
        end
        local by = math.floor((h - 14) / 2)
        if row.block ~= nil then
            theme:border(self, 6, by, 14, 14, "textFaint", "rect")
        elseif on then
            theme:fill(self, 6, by, 14, 14, "accent", "rect")
            p.host.UI.Icons.draw(self, "check", 6, by, 14, c.onAccent or c.surface, 1)
        else
            theme:border(self, 6, by, 14, 14, "textMuted", "rect")
        end
        local t = row.block ~= nil and c.textMuted or c.text
        self:drawText(self.text, SP.BOX_W + 2, self.textY, t.r, t.g, t.b, t.a, UIFont.Small)
    end
    return Row
end

-- ===== 頁面 =====
local Page = {}
Page.__index = Page
SP.Page = Page

function SP.new(host, parent)
    local p = setmetatable({ host = host, parent = parent, bits = SP.DEFAULT_BITS, claimId = nil, chips = {}, names = {},
        items = {}, picked = {}, count = 0, editable = 0, modes = {}, have = {} }, Page)
    p.lines = host:newLines(parent)
    local list = host.UI.VirtualList.new({ x = 0, y = 0, width = 100, height = 10, rowHeight = host.ch,
        padding = SP.ROW_GAP,
        createCell = function(l)
            local cell = rowClass():new(0, 0, 0, 0)
            cell.background = false
            cell.list, cell.page = l, p
            return cell
        end,
        bindCell = function(_, cell, row, index) p:bindCell(cell, row, index) end,
        unbindCell = function(_, cell) cell.row, cell.tooltip = nil, nil end,
        onSelect = function(_, _, index) p:toggle(index) end,     -- 鍵盤 Enter／Space、手把 A（滑鼠走下面的 onMouseDown）
        onHighlight = function(_, _, index) p:moved(index) end,  -- 方向鍵移動；Shift 按著時一路選過去
        onKey = function(_, key) return p:onKey(key) end })      -- Ctrl+A 全選
    list:initialise()
    parent:addChild(list)
    list:setVisible(false)
    -- 滑鼠點列自己處理：點勾選框＝加選或取消、Ctrl／Shift 照原版物品欄（同 VM 車隊 :671-681）；onSelect 只留給鍵盤與手把
    local down = list.onMouseDown
    list.onMouseDown = function(l, x, y)
        local i = l:indexAt(x, y)
        if i == nil then return down(l, x, y) end
        l:setSelectedIndex(i)
        p:click(i, x < SP.BOX_W)
        return true
    end
    -- 名單平常不捲（整頁在管理視窗的捲動區裡），滾輪交給外面；名單太長被收短時（Page:layout）才自己捲
    local wheel = list.onMouseWheel
    list.onMouseWheel = function(l, del)
        if l:maxScrollOffset() > 0 then return wheel(l, del) end
        return false
    end
    -- 焦點框只框游標那一列，說明寫那一列的全文與不能勾的原因（框架 rev 12 focusRect、rev 16 focusLabel；每幀呼叫、不配置）。
    -- 游標列捲出收短的名單時回 nil＝框整個名單：框架只看外層捲動區，不回 nil 會把框畫在名單外面、蓋到選取列
    -- （2026-10-20 實機 sh-bulk-de-1020a bs-07）
    list.focusRect = function(l)
        local i = l.selectedIndex
        if i == nil then return nil end
        local y = l.padding + (i - 1) * (l.rowHeight + l.padding) - l.scrollOffset
        if y < 0 or y + l.rowHeight > l.height then return nil end
        return 0, y, l.width, l.rowHeight
    end
    list.focusLabel = function(l)
        local row = l.items[l.selectedIndex or 0]
        return row and row.label or nil
    end
    p.list = list
    for i, name in ipairs(SP.CHIPS) do
        p.names[name] = getText("IGUI_MSH_Share_Bit_" .. name)
        local b = host:button(parent, p.names[name], Page.onChip, p, "chip")
        b.internal = name
        p.chips[i] = b
    end
    p.btnPickAll = host:button(parent, getText("IGUI_MSH_Share_PickAll"), Page.onPickAll, p)
    p.btnPickClear = host:button(parent, getText("IGUI_MSH_Share_PickClear"), Page.onPickClear, p)
    p.btnSave = host:button(parent, getText("IGUI_MSH_Share_Save"), Page.onSave, p, "primary")
    p.btnStop = host:button(parent, getText("IGUI_MSH_Share_StopOne"), Page.onStop, p, "danger")
    p.btnUser = host:button(parent, getText("IGUI_MSH_Share_ToPlayer"), Page.onShareUser, p, "primary")
    p.btnFaction = host:button(parent, getText("IGUI_MSH_Share_ToFaction"), Page.onShareFaction, p)
    p.btnFaction:setTooltip(getText("IGUI_MSH_Share_FactionNoInvite"))   -- 共用同一排 chip：說明陣營分享不含這兩位
    p.btnResume = host:button(parent, getText("IGUI_MSH_Share_Resume"), Page.onResume, p, "primary")
    p.btnFactionStop = host:button(parent, getText("IGUI_MSH_Share_Stop"), Page.onStopFaction, p, nil, "close")
    local online = getText("IGUI_MSH_Share_Online")
    p.ac = host.UI.Autocomplete.new({ width = 180, theme = host.theme, placeholder = getText("IGUI_MSH_Share_UserHint"),
        maxLength = MSH.LIMIT.USERNAME_CHARS, target = p, onQuery = Page.onQuery, onPick = function() end,
        labelOf = function(row) return row.name end, tagOf = function(row) return row.online and online or nil end })
    p.ac:addTo(parent)   -- 下拉最後加：蓋在同一頁其他元件上面
    p.ac:setVisible(false)
    p.fixed = { p.lines, p.list, p.btnPickAll, p.btnPickClear, p.btnSave, p.btnStop, p.btnUser, p.btnFaction, p.btnResume,
        p.btnFactionStop }
    return p
end

-- 換分頁、沒有詳情時收起（同一頁重排不經這裡：每次重排都收起會讓正在打字的輸入框失焦）
function Page:hide()
    for _, el in ipairs(self.fixed) do el:setVisible(false) end
    for _, b in ipairs(self.chips) do b:setVisible(false) end
    self.ac:setVisible(false)
end

-- ===== 選取（帳號 → true；照 Economy 以 id 為鍵：重抓 detail 換了順序也指著同一群人）=====

function Page:mods()
    local F = self.host.UI.Focus
    if F ~= nil and F.modifiers ~= nil then return F.modifiers() end
    return false, false
end

function Page:indexOf(user)
    for i, row in ipairs(self.items) do
        if row.user == user then return i end
    end
    return nil
end

function Page:pickedRows()
    local out = {}
    for _, row in ipairs(self.items) do
        if self.picked[row.user] then out[#out + 1] = row end
    end
    return out
end

-- 選取換成 users（帳號清單）
function Page:set(users)
    self.picked = {}
    for _, u in ipairs(users) do self.picked[u] = true end
end

-- 選取變了：重算人數、多位的 chip 狀態重來，整個管理視窗重排（下半的表單跟著換）
function Page:changed()
    local n = 0
    for _ in pairs(self.picked) do n = n + 1 end
    self.count, self.modes = n, {}
    self.host:layout()
end

-- 滑鼠點一列：點勾選框或 Ctrl＝加選或取消；Shift＝從錨點到這一列（取代原本的選取，同原版物品欄）；其餘＝只選這一位。
-- 不能勾的列只移游標（滑鼠提示寫原因；Shift 選一段時照樣當終點、跳過不能勾的列）。點過之後鍵盤接著用名單
-- （Space、Ctrl+A、方向鍵；不畫焦點框）
function Page:click(index, onBox)
    local F = self.host.UI.Focus
    if F ~= nil and F.focusControl ~= nil then F.focusControl(self.list, false) end
    self.cursor = index
    local row = self.items[index]
    if row == nil then return end
    local ctrl, shift = self:mods()
    if shift and self:indexOf(self.anchor) ~= nil then return self:range(index) end
    if row.block ~= nil then return end
    if ctrl or onBox then return self:toggle(index) end
    self.anchor = row.user
    self:set({ row.user })
    self:changed()
end

-- 加選或取消一列（勾選框、Ctrl＋點、Space／Enter、手把 A）；錨點移到這一列
function Page:toggle(index)
    self.cursor = index
    local row = self.items[index]
    if row == nil or row.block ~= nil then return end
    self.anchor = row.user
    self.picked[row.user] = not self.picked[row.user] or nil
    self:changed()
end

-- 從錨點到 index 這一段，取代原本的選取；錨點不動（不能勾的列由重排時的 syncRows 拿掉）
function Page:range(index)
    local from, to = self:indexOf(self.anchor) or index, index
    if from > to then from, to = to, from end
    local users = {}
    for i = from, to do users[#users + 1] = self.items[i].user end
    self:set(users)
    self:changed()
end

-- 鍵盤／手把移動游標（方向鍵只移游標）；Shift 按著時從錨點選到這一列（沒有錨點就從移動前那一列開始）
function Page:moved(index)
    local prev = self.cursor
    self.cursor = index
    local _, shift = self:mods()
    if not shift then return end
    if self:indexOf(self.anchor) == nil then
        local row = self.items[prev or index]
        self.anchor = row and row.user or nil
    end
    self:range(index)
end

-- 焦點框在名單上的按鍵：Ctrl+A 全選（其餘交回框架：方向鍵移動、Space／Enter 勾選）
function Page:onKey(key)
    if key ~= Keyboard.KEY_A then return false end
    local ctrl = self:mods()
    if not ctrl then return false end
    self:pickAll()
    return true
end

function Page:pickAll()
    local users = {}
    for i, row in ipairs(self.items) do users[i] = row.user end
    self:set(users)
    self:changed()
end

-- 清除選取（〔清除選取〕、Esc、手把 B）；本來就沒有選取回 false（Esc 照框架的預設：收焦點框、關窗）
function Page:clearPicks()
    if self.count == 0 then return false end
    self.picked, self.anchor = {}, nil
    self:changed()
    return true
end

function Page.onPickAll(p) p:pickAll() end

function Page.onPickClear(p) p:clearPicks() end

-- 名單列：每位 grant 一列（帳號、全文、不能勾的原因）。選取只在這裡收斂成還在、還能勾的人（每次選取變了都經 changed
-- 重排到這裡；重抓 detail 後停止分享的人不在了、對方拿到管理等也一樣）
function Page:syncRows(d)
    local items, keep, editable, n = {}, {}, 0, 0
    for i, g in ipairs(d.grants or {}) do
        local text = getText("IGUI_MSH_Share_PlayerRow", g.user, SP.bitsText(g.bits))
        local block = SP.rowBlock(d, g, self.host.me)
        local why = block and getText(block)
        items[i] = { user = g.user, bits = g.bits, block = block, text = text,
            tip = why and (text .. " <LINE> " .. why) or text, label = why and (text .. " " .. why) or text }
        if block == nil then
            editable = editable + 1
            if self.picked[g.user] then
                keep[g.user] = true
                n = n + 1
            end
        end
    end
    self.items, self.picked, self.editable, self.count = items, keep, editable, n
    return items
end

function Page:bindCell(cell, row, index)
    cell.row, cell.index = row, index
    cell.text = self.host:fit(row.text, cell.width - SP.BOX_W - 8)
    cell.textY = math.floor((cell.height - self.host.fh) / 2)
    cell.tooltip = (cell.text ~= row.text or row.block ~= nil) and row.tip or nil
end

-- 選一位：chip 從他目前的權限開始；換了人、或重抓後他的權限變了才重設（改到一半的不會被別的重排洗掉）
function Page:loadEdit(row)
    if self.editUser ~= row.user or self.editBase ~= row.bits then
        self.editUser, self.editBase, self.editBits = row.user, row.bits, row.bits
    end
end

-- 選兩位以上：每個權限有幾位有（chip 寫「k/n」），順便丟掉已經沒作用的狀態（重抓後全部都有了還留著「加上」）
function Page:countHave(rows)
    local n = #rows
    for _, name in ipairs(SP.CHIPS) do
        local k = 0
        for _, r in ipairs(rows) do
            if MSH.hasBit(r.bits, SHARE[name]) then k = k + 1 end
        end
        self.have[name] = k
        local m = self.modes[name]
        if (m == "add" and k == n) or (m == "remove" and k == 0) then self.modes[name] = nil end
    end
end

-- 這次要加、要拿的位元：選一位比對他目前的權限，多位看 chip 狀態
function Page:delta()
    if self.count == 1 then return SP.diff(self.editBase, self.editBits) end
    return SP.modeBits(self.modes)
end

-- 一顆 chip 的字、選中與可按：新增照勾的；選一位照他目前的權限＋改過的；多位寫三態（「+名稱」「-名稱」「名稱 k/n」）。
-- 改既有成員時「成員」鎖住：要移除請按〔停止分享〕
function Page:dressChip(b, name, idle)
    local n, bit = self.count, SHARE[name]
    local title, active, enabled, tip = self.names[name], false, idle, nil
    if n == 0 then
        active = MSH.hasBit(self.bits, bit)
    elseif name == "MEMBER" then
        active, enabled, tip = true, false, getText("IGUI_MSH_Share_MemberLocked")
    elseif n == 1 then
        active = MSH.hasBit(self.editBits, bit)
    else
        local k, mode = self.have[name] or 0, self.modes[name]
        if mode == "add" then
            title, active = getText("IGUI_MSH_Share_ChipAdd", title), true
        elseif mode == "remove" then
            title = getText("IGUI_MSH_Share_ChipRemove", title)
        elseif k == n then
            active = true
        elseif k > 0 then
            title = getText("IGUI_MSH_Share_ChipSome", title, k, n)
        end
    end
    b:setTitle(title)
    b:setActive(active)
    b:setEnabled(enabled)
    b:setTooltip(tip)
end

-- 依 detail 排版（捲動內容座標 x0, y0 起、寬 w）；回傳內容底部 y。名單太長、下面的表單被擠出捲動區時，名單收短成自己捲
-- （至少 SP.MIN_ROWS 列），表單留在看得到的地方（2026-10-20 實機 sh-bulk-en-1020a：英文字型 5 位成員，選了人之後表單整個
-- 在可視區外）。先照全部列排一次，超出捲動區就收短名單再排一次；名單尺寸最後才定（resize 會重建 cell 池）。
-- 收短後有選人、表單還是放不下（sh-bulk-en-1020b：字大、chip 換行），差多少寫在 self.short，管理視窗照它長高（W:grow）
function Page:layout(d, x0, y0, w)
    local bottom = self:layoutWith(d, x0, y0, w, nil)
    local stride = self.host.ch + SP.ROW_GAP
    local fit = self.listH - (bottom - y0 - self.parent.height)
    if fit < self.listH and self.listH > SP.MIN_ROWS * stride + SP.ROW_GAP then
        local rows = math.max(SP.MIN_ROWS, math.floor((fit - SP.ROW_GAP) / stride))
        bottom = self:layoutWith(d, x0, y0, w, rows * stride + SP.ROW_GAP)
    end
    self.short = self.count > 0 and math.max(0, bottom - y0 - self.parent.height) or 0
    local list = self.list
    if self.listH > 0 then
        local resized = list.width ~= w or list.height ~= self.listH
        if resized then list:resize(w, self.listH) end
        list:setItems(self.items)
        -- 名單變矮時游標列可能被擠出可見範圍：捲回來（只在尺寸變了時，不和玩家自己的滾輪搶；sh-bulk-de-1020a bs-07）
        if resized and list.selectedIndex then list:scrollToIndex(list.selectedIndex) end
    end
    return bottom
end

-- 排一次；cap＝名單最多多高（nil＝放下全部列）。self.listH 記這次名單用的高度
function Page:layoutWith(d, x0, y0, w, cap)
    local host = self.host
    local L, fh, ch, gap = self.lines, host.fh, host.ch, host.GAP
    if d.claimId ~= self.claimId then
        self.claimId, self.bits = d.claimId, SP.DEFAULT_BITS
        self.picked, self.anchor, self.cursor, self.editUser, self.modes = {}, nil, nil, nil, {}
        self.ac:setText("")
    end
    self.bits = SP.shareBits(d, self.bits)
    local a, limits, grants, fs = d.actions or {}, d.limits or {}, d.grants or {}, d.factionShare
    local idle = host.busy == nil
    local textDy = math.floor((ch - fh) / 2)
    L:clear()
    host:place(L, x0, y0)
    local y = 0
    L:add(getText("IGUI_MSH_Share_Current", #grants, limits.maxShares or "-"), 0, y, "text")
    y = y + fh + gap

    if type(fs) == "table" then
        local right = w
        local stop = self.btnFactionStop
        stop:setVisible(false)
        if SP.canStopFaction(d) then
            right = right - stop.width
            host:place(stop, x0 + right, y0 + y)
            stop:setEnabled(idle)
            right = right - gap
        end
        local resume = self.btnResume
        resume:setVisible(false)
        if fs.state == "SUSPENDED" and a.canResumeFaction then
            right = right - resume.width
            host:place(resume, x0 + right, y0 + y)
            resume:setEnabled(idle)
            right = right - gap
        end
        L:add(host:fit(getText("IGUI_MSH_Share_FactionRow", fs.name or "", SP.bitsText(SP.factionBits(fs.bits or 0))), right),
            0, y + textDy, "text")
        y = y + ch + 2
        if fs.state == "SUSPENDED" then
            L:add(host:fit(getText(SP.reasonKey(fs)), w - host.iconW), 0, y, "warning", "warning")
            y = y + fh + gap
        elseif fs.projected == false then
            local n = type(fs.members) == "table" and #fs.members or fs.members or "-"
            L:add(host:fit(getText("IGUI_MSH_Share_FactionTooLarge", n), w - host.iconW), 0, y, "warning", "warning")
            y = y + fh + gap
        end
    else
        self.btnFactionStop:setVisible(false)
        self.btnResume:setVisible(false)
    end

    -- 名單：平常高度剛好放下每一列、不捲（整頁在捲動區裡）；cap 收短時名單自己捲
    local rows = self:syncRows(d)
    self.listH = 0
    if #rows > 0 then
        local full = #rows * (ch + SP.ROW_GAP) + SP.ROW_GAP
        self.listH = math.min(full, cap or full)
        host:place(self.list, x0, y0 + y)
        y = y + self.listH
    else
        self.list:setVisible(false)
        if type(fs) ~= "table" then
            L:add(getText("IGUI_MSH_Share_None"), 0, y, "textMuted")
            y = y + fh
        end
    end

    -- 選取列（有能勾的列時）：「已選 N 位」、〔全選〕〔清除選取〕靠右，下一行操作說明（使用者 2026-10-20：勾選框給新手、
    -- Ctrl／Shift 給熟手；清除不靠快捷鍵）。選了兩位以上就不再寫說明（下面的表單另有三態說明，省下的高度給表單）
    local n = self.count
    self.btnPickAll:setVisible(false)
    self.btnPickClear:setVisible(false)
    if self.editable > 0 then
        y = y + gap
        local right = w - self.btnPickClear.width
        host:place(self.btnPickClear, x0 + right, y0 + y)
        right = right - gap - self.btnPickAll.width
        host:place(self.btnPickAll, x0 + right, y0 + y)
        self.btnPickAll:setEnabled(n < self.editable)
        self.btnPickClear:setEnabled(n > 0)
        if n > 0 then L:add(host:fit(getText("IGUI_MSH_Share_Picked", n), right - gap), 0, y + textDy, "text") end
        y = y + ch + gap
        if n < 2 then y = host:addWrapped(L, getText("IGUI_MSH_Share_PickHint"), 0, y, w, "textMuted") end
    end

    -- 表單：沒選＝新增分享；選一位＝改他的權限；選兩位以上＝一起改（使用者 2026-10-20 核准）
    y = y + gap * 3
    local picks = self:pickedRows()
    local head
    if n == 0 then
        head = getText("IGUI_MSH_Share_Add")
    elseif n == 1 then
        head = getText("IGUI_MSH_Share_EditOne", picks[1].user)
        self:loadEdit(picks[1])
    else
        head = getText("IGUI_MSH_Share_EditMany", n)
        self:countHave(picks)
    end
    L:add(host:fit(head, w), 0, y, "text")
    y = y + fh + gap
    -- 遠距拿取的 chip 只在沙盒是「可遠距拿取」時排出（沒開時勾了也沒作用，2026-10-20 審查）；收起來不會洗掉已存的位元
    -- （新增時 shareBits 只看 chipAllowed；改既有成員只送改過的 chip）
    local takeOn = MSH.Settings.storageMode() == MSH.Settings.STORAGE.REMOTE
    local shown = {}
    for i, name in ipairs(SP.CHIPS) do
        local b = self.chips[i]
        b:setVisible(false)
        if SP.chipAllowed(d, name) and (name ~= "TAKE" or takeOn) then
            self:dressChip(b, name, idle)
            shown[#shown + 1] = b
        end
    end
    y = host:flow(shown, x0, y0 + y, w) - y0 + gap

    if n == 0 then
        -- 再選對象：玩家名稱＋〔分享給玩家〕、〔分享給陣營〕（只限屋主、伺服器設定允許）
        self.btnSave:setVisible(false)
        self.btnStop:setVisible(false)
        local field = self.ac.field
        field:setWidth(math.min(180, w))
        self.ac:setVisible(true)
        self.ac:setEnabled(idle)
        self.btnUser:setEnabled(idle)
        local targets = { field, self.btnUser }
        self.btnFaction:setVisible(false)
        if a.canShareFaction and limits.allowFactionShare ~= false then
            self.btnFaction:setEnabled(idle)
            targets[#targets + 1] = self.btnFaction
        end
        y = host:flow(targets, x0, y0 + y, w) - y0
        -- 下拉掛在輸入框下面、高度不超過捲動區扣掉輸入框（管理視窗開著時每幀把它捲進可視區，W:prerender）
        self.ac:anchorList(math.max(0, self.parent.height - host.ch - 2 * gap))
    else
        -- 改既有成員：寫出這次要加、要拿的權限，有變更才能存；停止分享一律先確認
        self.ac:setVisible(false)
        self.btnUser:setVisible(false)
        self.btnFaction:setVisible(false)
        if n > 1 then y = host:addWrapped(L, getText("IGUI_MSH_Share_ManyHint"), 0, y, w, "textMuted") + gap end
        local add, remove = self:delta()
        if add > 0 then y = host:addWrapped(L, getText("IGUI_MSH_Share_Adding", SP.bitsText(add)), 0, y, w, "accent") end
        if remove > 0 then
            y = host:addWrapped(L, getText("IGUI_MSH_Share_Removing", SP.bitsText(remove)), 0, y, w, "errorText")
        end
        if add + remove > 0 then y = y + gap end
        self.btnSave:setTitle(n == 1 and getText("IGUI_MSH_Share_Save") or getText("IGUI_MSH_Share_ApplyMany", n))
        self.btnSave:setEnabled(idle and add + remove > 0)
        self.btnStop:setTitle(n == 1 and getText("IGUI_MSH_Share_StopOne") or getText("IGUI_MSH_Share_StopMany", n))
        self.btnStop:setEnabled(idle)
        y = host:flow({ self.btnSave, self.btnStop }, x0, y0 + y, w) - y0
    end
    L:setWidth(w)
    L:setHeight(y)
    return y0 + y
end

-- 新增分享的 chip 只改外觀（不重排）
function Page:syncChips()
    for i, name in ipairs(SP.CHIPS) do self.chips[i]:setActive(MSH.hasBit(self.bits, SHARE[name])) end
end

-- 點 chip：新增時勾或取消；選一位時改他的權限（成員鎖住）；多位時換下一個狀態（SP.nextMode）。改既有成員要重排變更列
function Page.onChip(p, b)
    local name = b.internal
    local bit = SHARE[name]
    if p.count == 0 then
        p.bits = SP.setChip(p.bits, name, not MSH.hasBit(p.bits, bit))
        return p:syncChips()
    end
    if name == "MEMBER" then return end
    if p.count == 1 then
        p.editBits = SP.setChip(p.editBits, name, not MSH.hasBit(p.editBits, bit))
    else
        p.modes[name] = SP.nextMode(p.modes[name], p.have[name] or 0, p.count)
    end
    p.host:layout()
end

function Page:reset()
    local d = self.host.detail
    self.bits = d and SP.shareBits(d, SP.DEFAULT_BITS) or SP.DEFAULT_BITS
    self.ac:setText("")
    self:syncChips()
end

-- 候選（Autocomplete 的 onQuery）：一次只送一筆，送不出去回 false（框架下一幀再問）。回覆的文字已經不是目前的輸入時
--   框架自己丟掉；逾時重新計時再問，被拒（沒有權限、屋不在）安靜收起（候選只是方便，不是結果）
function Page.onQuery(p, text, ac)
    local d = p.host.detail
    if d == nil or MSH.Client.isPending(p.queryRid) then return false end
    p.queryRid = MSH.Client.send("shareCandidates", { claimId = d.claimId, query = text }, function(res)
        p.queryRid = nil
        if res.ok then ac:setResults(text, res.rows) else ac:queryFailed(res.code == "NO_REPLY") end
    end)
    return p.queryRid ~= nil
end

function Page.onShareUser(p)
    local host, d = p.host, p.host.detail
    if d == nil then return end
    local user = p.ac:getText()
    if not MSH.validUsername(user) then return host:say(getText("IGUI_MSH_Share_NeedUser"), "errorText") end
    if SP.alreadyListed(d, user) then return host:say(getText("IGUI_MSH_Share_AlreadyListed"), "errorText") end
    -- 屋主、管理成員打了名單上的人：選到他那一列、帶入他目前的權限（使用者 2026-10-20 選「改成選到他那一列」：不整組覆蓋）
    local i = p:indexOf(user)
    if i ~= nil then
        local row = p.items[i]
        if row.block ~= nil then return host:say(getText(row.block), "errorText") end
        p.ac:setText("")
        p.anchor, p.cursor = user, i
        p.list:setSelectedIndex(i)
        p:set({ user })
        p:changed()
        return host:say(getText("IGUI_MSH_Share_Existing", user), "text")
    end
    local bits = SP.shareBits(d, p.bits)
    if bits <= 0 then return host:say(getText("IGUI_MSH_Share_NeedBits"), "errorText") end
    host:mutate("share", { claimId = d.claimId, expectedRevision = d.revision, targetUsername = user, bits = bits },
        getText("IGUI_MSH_Share_Done", user), function() p:reset() end)
end

function Page.onShareFaction(p)
    local host, d = p.host, p.host.detail
    if d == nil then return end
    local bits = SP.factionBits(SP.shareBits(d, p.bits))
    if bits <= 0 then return host:say(getText("IGUI_MSH_Share_NeedBits"), "errorText") end
    host:mutate("shareFaction", { claimId = d.claimId, expectedRevision = d.revision, bits = bits },
        getText("IGUI_MSH_Share_FactionDone"), function() p:reset() end)
end

-- 〔儲存變更〕（一位，不確認：下方已寫出變更）／〔套用到 N 位...〕（多位，先確認；使用者 2026-10-20 選「改多位與停止分享」）
function Page.onSave(p)
    local host, d = p.host, p.host.detail
    if d == nil or p.count == 0 then return end
    local add, remove = p:delta()
    if add + remove == 0 then return end
    local rows = p:pickedRows()
    local users = {}
    for i, r in ipairs(rows) do users[i] = r.user end
    local args = { claimId = d.claimId, expectedRevision = d.revision, users = users, add = add, remove = remove }
    -- 成功就清掉這次的變更：重抓的 detail 回來之前按鈕先停用，之後照新的權限顯示
    local function done() p.editUser, p.modes = nil, {} end
    if #users == 1 then
        return host:mutate("shareEdit", args, getText("IGUI_MSH_Share_Saved", users[1]), done)
    end
    host.UI.Dialog.show(MSH.Client.windowOpts(host.UI, { title = getText("IGUI_MSH_Share_ApplyTitle", #users),
        text = SP.applyText(rows, add, remove), theme = host.theme,
        confirmText = getText("IGUI_MSH_Share_ApplyOk", #users), cancelText = getText("UI_Cancel"),
        onResult = function(ok)
            if ok then host:mutate("shareEdit", args, getText("IGUI_MSH_Share_Applied", #users), done) end
        end }))
end

-- 〔停止分享...〕：danger 確認框寫出名字與後果，再送 unshareMany（一位或多位都先確認）
function Page.onStop(p)
    local host, d = p.host, p.host.detail
    if d == nil or p.count == 0 then return end
    local users = {}
    for i, r in ipairs(p:pickedRows()) do users[i] = r.user end
    local one = #users == 1
    host.UI.Dialog.show(MSH.Client.windowOpts(host.UI, {
        title = one and getText("IGUI_MSH_Share_StopTitle", users[1]) or getText("IGUI_MSH_Share_StopTitleMany", #users),
        text = getText("IGUI_MSH_Share_StopText", table.concat(users, getText("IGUI_MSH_Share_ListSep"))),
        theme = host.theme, danger = true, confirmText = getText("IGUI_MSH_Share_StopOk"), cancelText = getText("UI_Cancel"),
        onResult = function(ok)
            if not ok then return end
            host:mutate("unshareMany", { claimId = d.claimId, expectedRevision = d.revision, users = users },
                one and getText("IGUI_MSH_Share_Stopped", users[1]) or getText("IGUI_MSH_Share_StoppedMany", #users))
        end }))
end

-- 陣營的〔停止〕：同樣先確認（只靠陣營進來的人會失去權限；另外分享給個人的不受影響）
function Page.onStopFaction(p)
    local host, d = p.host, p.host.detail
    if d == nil or type(d.factionShare) ~= "table" then return end
    host.UI.Dialog.show(MSH.Client.windowOpts(host.UI, {
        title = getText("IGUI_MSH_Share_FactionStopTitle", d.factionShare.name or ""),
        text = getText("IGUI_MSH_Share_FactionStopText"), theme = host.theme, danger = true,
        confirmText = getText("IGUI_MSH_Share_StopOk"), cancelText = getText("UI_Cancel"),
        onResult = function(ok)
            if not ok then return end
            host:mutate("unshareFaction", { claimId = d.claimId, expectedRevision = d.revision },
                getText("IGUI_MSH_Share_FactionStopped"))
        end }))
end

function Page.onResume(p)
    local host, d = p.host, p.host.detail
    if d == nil then return end
    host:mutate("resumeFaction", { claimId = d.claimId, expectedRevision = d.revision },
        getText("IGUI_MSH_Share_Resumed"))
end
