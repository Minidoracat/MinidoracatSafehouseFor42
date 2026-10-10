-- MinidoracatSafehouse/SharingPage.lua：管理視窗「成員與分享」頁（M3，計畫 §10.5、§6.5）。
-- 照 VM 車隊視窗「先勾權限，再選對象」（MinidoracatVehicleManager_FleetWindow.lua layoutOwner :1096-1175）：
--   上半「目前分享給」逐列（陣營「名稱」：權限、玩家：權限）各一顆〔停止〕，陣營暫停時寫原因並給〔恢復分享〕；
--   下半先勾權限 chip（後五個自動帶成員），再輸入玩家名稱〔分享給玩家〕或〔分享給陣營〕（屋主目前所在陣營）。
-- 只送提案，畫面以伺服器結果與重抓的 detail 為準（§10.4 最後一段）。MANAGE 成員只能給自己有的位元、不能給 MANAGE、
--   不能動屋主、自己、實際持有 MANAGE 的人與帶 MANAGE 的陣營分享：這裡只是不給按（體驗），伺服器才是防線（契約 M2）。
-- 元件與送出都借管理視窗（host：button／newLines／place／fit／mutate／say），本檔只排版與組指令。

if not isClient() then return end

require "MinidoracatSafehouse/Contract"

local MSH = MinidoracatSafehouse
local SHARE = MSH.SHARE
local SP = MSH.SharingPage or {}
MSH.SharingPage = SP

SP.CHIPS = { "MEMBER", "USE", "MOVE", "BUILD", "FARM", "MANAGE" }
SP.DEFAULT_BITS = SHARE.MEMBER + SHARE.USE   -- 預設勾成員與用電器（§10.5）

-- ===== 純邏輯（t_ui_manager.lua 測）=====

-- 切換一個 chip：其他五個一定要搭配成員（打開就自動加成員）；取消成員＝全部取消（§6.5「其他位元一定要搭配 MEMBER」）
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

-- 能不能停止分享給這位玩家：屋主都可以；MANAGE 成員不能動自己與實際持有 MANAGE 的人（伺服器用 roleOf 判定，
-- 陣營給的 MANAGE 也算：看 effBits＝grant 與有效陣營分享的聯集；舊伺服器沒有這欄時退回 bits）
function SP.canStopGrant(d, grant, me)
    if d.actorRole == "owner" then return true end
    local a = d.actions or {}
    return a.canManageShares == true and grant.user ~= me and not MSH.hasBit(grant.effBits or grant.bits, SHARE.MANAGE)
end

-- 能不能停止陣營分享：屋主可以；MANAGE 成員不能停一個帶 MANAGE 的陣營分享（伺服器回 NOT_OWNER）
function SP.canStopFaction(d)
    local a, fs = d.actions or {}, d.factionShare
    if a.canManageShares ~= true or type(fs) ~= "table" then return false end
    return d.actorRole == "owner" or not MSH.hasBit(fs.bits, SHARE.MANAGE)
end

-- 能勾的 chip：屋主全部；成員只能給自己有的位元（伺服器要求子集），而且不能給 MANAGE
function SP.chipAllowed(d, name)
    if d.actorRole == "owner" then return true end
    return name ~= "MANAGE" and MSH.hasBit(d.bits, SHARE[name])
end

-- 要送出的位元：只留能勾的 chip（換了屋或自己的位元變少時把已勾的收回）
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

-- ===== 頁面 =====
local Page = {}
Page.__index = Page
SP.Page = Page

function SP.new(host, parent)
    local p = setmetatable({ host = host, parent = parent, bits = SP.DEFAULT_BITS, claimId = nil, chips = {},
        rows = {} }, Page)
    p.lines = host:newLines(parent)
    for i, name in ipairs(SP.CHIPS) do
        local b = host:button(parent, getText("IGUI_MSH_Share_Bit_" .. name), Page.onChip, p, "chip")
        b.internal = name
        p.chips[i] = b
    end
    p.user = host.UI.TextField.new({ x = 0, y = 0, width = 180, height = host.ch, theme = host.theme,
        placeholder = getText("IGUI_MSH_Share_UserHint"), maxLength = MSH.LIMIT.USERNAME_CHARS })
    parent:addChild(p.user)
    p.user:setVisible(false)
    p.btnUser = host:button(parent, getText("IGUI_MSH_Share_ToPlayer"), Page.onShareUser, p, "primary")
    p.btnFaction = host:button(parent, getText("IGUI_MSH_Share_ToFaction"), Page.onShareFaction, p)
    p.btnResume = host:button(parent, getText("IGUI_MSH_Share_Resume"), Page.onResume, p, "primary")
    p.btnFactionStop = host:button(parent, getText("IGUI_MSH_Share_Stop"), Page.onStopFaction, p, nil, "close")
    p.fixed = { p.lines, p.user, p.btnUser, p.btnFaction, p.btnResume, p.btnFactionStop }
    return p
end

function Page:hide()
    for _, el in ipairs(self.fixed) do el:setVisible(false) end
    for _, b in ipairs(self.chips) do b:setVisible(false) end
    for _, b in ipairs(self.rows) do b:setVisible(false) end
end

-- 第 i 列玩家的〔停止〕（用到才建，之後重用）
function Page:rowButton(i)
    local b = self.rows[i]
    if b == nil then
        b = self.host:button(self.parent, getText("IGUI_MSH_Share_Stop"), Page.onStopUser, self, nil, "close")
        self.rows[i] = b
    end
    return b
end

-- 依 detail 排版（捲動內容座標 x0, y0 起、寬 w）；回傳內容底部 y
function Page:layout(d, x0, y0, w)
    local host = self.host
    local L, fh, ch, gap = self.lines, host.fh, host.ch, host.GAP
    if d.claimId ~= self.claimId then
        self.claimId, self.bits = d.claimId, SP.DEFAULT_BITS
        self.user:setText("")
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
        L:add(host:fit(getText("IGUI_MSH_Share_FactionRow", fs.name or "", SP.bitsText(fs.bits or 0)), right), 0, y + textDy, "text")
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

    for i, g in ipairs(grants) do
        local b = self:rowButton(i)
        b.internal = g.user
        b:setTooltip(getText("IGUI_MSH_Share_StopTip", g.user))
        b:setEnabled(idle and SP.canStopGrant(d, g, host.me))
        host:place(b, x0 + w - b.width, y0 + y)
        L:add(host:fit(getText("IGUI_MSH_Share_PlayerRow", g.user, SP.bitsText(g.bits)), w - b.width - gap), 0, y + textDy, "text")
        y = y + ch + 2
    end
    for i = #grants + 1, #self.rows do self.rows[i]:setVisible(false) end
    if type(fs) ~= "table" and #grants == 0 then
        L:add(getText("IGUI_MSH_Share_None"), 0, y, "textMuted")
        y = y + fh
    end

    -- 新增分享：先勾權限
    y = y + gap * 3
    L:add(host:fit(getText("IGUI_MSH_Share_Add"), w), 0, y, "text")
    y = y + fh + gap
    local shown = {}
    for i, name in ipairs(SP.CHIPS) do
        local b = self.chips[i]
        b:setVisible(false)
        if SP.chipAllowed(d, name) then
            b:setActive(MSH.hasBit(self.bits, SHARE[name]))
            b:setEnabled(idle)
            shown[#shown + 1] = b
        end
    end
    y = host:flow(shown, x0, y0 + y, w) - y0 + gap

    -- 再選對象：玩家名稱＋〔分享給玩家〕、〔分享給陣營〕（只限屋主、伺服器設定允許）
    self.user:setWidth(math.min(180, w))
    self.user:setEnabled(idle)
    self.btnUser:setEnabled(idle)
    local targets = { self.user, self.btnUser }
    self.btnFaction:setVisible(false)
    if a.canShareFaction and limits.allowFactionShare ~= false then
        self.btnFaction:setEnabled(idle)
        targets[#targets + 1] = self.btnFaction
    end
    y = host:flow(targets, x0, y0 + y, w) - y0
    L:setWidth(w)
    L:setHeight(y)
    return y0 + y
end

-- 只改 chip 外觀（不重排）
function Page:syncChips()
    for i, name in ipairs(SP.CHIPS) do self.chips[i]:setActive(MSH.hasBit(self.bits, SHARE[name])) end
end

function Page.onChip(p, b)
    local name = b.internal
    p.bits = SP.setChip(p.bits, name, not MSH.hasBit(p.bits, SHARE[name]))
    p:syncChips()
end

function Page:reset()
    local d = self.host.detail
    self.bits = d and SP.shareBits(d, SP.DEFAULT_BITS) or SP.DEFAULT_BITS
    self.user:setText("")
    self:syncChips()
end

function Page.onShareUser(p)
    local host, d = p.host, p.host.detail
    if d == nil then return end
    local user = MSH.trim(p.user:getText() or "")
    if not MSH.validUsername(user) then return host:say(getText("IGUI_MSH_Share_NeedUser"), "errorText") end
    local bits = SP.shareBits(d, p.bits)
    if bits <= 0 then return host:say(getText("IGUI_MSH_Share_NeedBits"), "errorText") end
    host:mutate("share", { claimId = d.claimId, expectedRevision = d.revision, targetUsername = user, bits = bits },
        getText("IGUI_MSH_Share_Done", user), function() p:reset() end)
end

function Page.onShareFaction(p)
    local host, d = p.host, p.host.detail
    if d == nil then return end
    local bits = SP.shareBits(d, p.bits)
    if bits <= 0 then return host:say(getText("IGUI_MSH_Share_NeedBits"), "errorText") end
    host:mutate("shareFaction", { claimId = d.claimId, expectedRevision = d.revision, bits = bits },
        getText("IGUI_MSH_Share_FactionDone"), function() p:reset() end)
end

function Page.onStopUser(p, b)
    local host, d = p.host, p.host.detail
    if d == nil then return end
    host:mutate("unshare", { claimId = d.claimId, expectedRevision = d.revision, targetUsername = b.internal },
        getText("IGUI_MSH_Share_Stopped", b.internal))
end

function Page.onStopFaction(p)
    local host, d = p.host, p.host.detail
    if d == nil then return end
    host:mutate("unshareFaction", { claimId = d.claimId, expectedRevision = d.revision },
        getText("IGUI_MSH_Share_FactionStopped"))
end

function Page.onResume(p)
    local host, d = p.host, p.host.detail
    if d == nil then return end
    host:mutate("resumeFaction", { claimId = d.claimId, expectedRevision = d.revision },
        getText("IGUI_MSH_Share_Resumed"))
end
