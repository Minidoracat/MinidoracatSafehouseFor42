-- 管理視窗與分享頁的純邏輯（ManagerWindow.lua、SharingPage.lua）：狀態優先序（§10.3）、權限 chip 與位元（§10.5、§6.5）、
-- 放棄確認的文案選擇（§10.3、§7.6）、在世界中顯示只畫外框（§10.3），以及框架缺席時的最小 fallback 不報錯（AGENTS.md 鐵則）。
return function(T)
    local check = T.check
    local MSH = T.bootClient()
    local MW, SP = MSH.ManagerWindow, MSH.SharingPage
    local SHARE = MSH.SHARE
    check(type(MW) == "table" and type(MW.open) == "function" and type(SP) == "table" and type(SP.new) == "function",
        "客戶端載入管理視窗與分享頁")

    T.section("ManagerWindow：狀態只顯示最高優先的一個，其餘照序收進詳細")
    local top, rest = MW.statusCodes({ healthSummary = "PROTECTED", lifecycle = "active" })
    check(top == "PROTECTED" and #rest == 0, "沒有問題＝已保護、沒有其他項")
    top, rest = MW.statusCodes({ healthSummary = "INTERFERENCE", lifecycle = "lapsed",
        factionShare = { state = "SUSPENDED" } })
    check(top == "INTERFERENCE" and #rest == 2 and rest[1] == "FACTION_SUSPENDED" and rest[2] == "LAPSED",
        "成員同步受干擾 ＞ 已停用；同級照出現順序")
    top, rest = MW.statusCodes({ healthSummary = "SERVER_BLOCKED", lifecycle = "quarantined" })
    check(top == "SERVER_BLOCKED" and rest[1] == "QUARANTINED", "伺服器設定不完整排最前")
    top, rest = MW.statusCodes({ healthSummary = "LAPSED", lifecycle = "lapsed" })
    check(top == "LAPSED" and #rest == 0, "同一個問題不重複列")
    top = MW.statusCodes({ healthSummary = "SOMETHING_NEW", lifecycle = "active" })
    check(top == "SOMETHING_NEW", "不認得的碼不會被「已保護」蓋掉")
    top, rest = MW.statusCodes({ healthSummary = "SOMETHING_NEW", lifecycle = "lapsed" })
    check(top == "LAPSED" and rest[1] == "SOMETHING_NEW", "不認得的碼排在租約／停用之後")
    top = MW.statusCodes({ healthSummary = "PROTECTED", lifecycle = "active",
        factionShare = { state = "GRANTED", projected = false } })
    check(top == "FACTION_TOO_LARGE", "陣營人數超過投影上限要顯示，不當作已保護")

    T.section("SharingPage：權限 chip 與位元")
    check(SP.DEFAULT_BITS == SHARE.MEMBER + SHARE.USE, "預設勾成員與用電器")
    check(SP.setChip(0, "USE", true) == SHARE.MEMBER + SHARE.USE, "勾其他權限自動帶成員")
    check(SP.setChip(SHARE.MEMBER, "MANAGE", true) == SHARE.MEMBER + SHARE.MANAGE, "勾管理也帶成員（已有成員不重複加）")
    check(SP.setChip(SHARE.MEMBER + SHARE.USE + SHARE.BUILD, "USE", false) == SHARE.MEMBER + SHARE.BUILD, "取消一項只拿掉那一項")
    check(SP.setChip(MSH.SHARE_ALL, "MEMBER", false) == 0, "取消成員＝全部取消（其他權限不能沒有成員）")
    check(SP.setChip(SHARE.MEMBER, "MEMBER", true) == SHARE.MEMBER, "重複勾同一項不變")
    local sep = getText("IGUI_MSH_Share_ListSep")
    local text = SP.bitsText(SHARE.MEMBER + SHARE.FARM)
    check(text == getText("IGUI_MSH_Share_Bit_MEMBER") .. sep .. getText("IGUI_MSH_Share_Bit_FARM"),
        "位元轉回 chip：只列有的、照 chip 順序")

    local ownerView = { actorRole = "owner", actions = { canManageShares = true } }
    local mine = SHARE.MEMBER + SHARE.USE + SHARE.MANAGE
    local managerView = { actorRole = "member", bits = mine, actions = { canManageShares = true } }
    local memberView = { actorRole = "member", actions = { canManageShares = false } }
    local plain = { user = "bob", bits = SHARE.MEMBER + SHARE.USE }
    local mgr = { user = "carol", bits = SHARE.MEMBER + SHARE.MANAGE }
    check(SP.canStopGrant(ownerView, mgr, "alice") and SP.canStopGrant(ownerView, plain, "alice"), "屋主可以停止任何人")
    check(SP.canStopGrant(managerView, plain, "dave"), "管理成員可以停止一般成員")
    check(not SP.canStopGrant(managerView, mgr, "dave"), "管理成員不能動持有管理的人")
    check(not SP.canStopGrant(managerView, { user = "dave", bits = SHARE.MEMBER }, "dave"), "管理成員不能動自己")
    check(not SP.canStopGrant(memberView, plain, "dave"), "一般成員不能停止分享")
    local viaFaction = { user = "erin", bits = SHARE.MEMBER + SHARE.USE, effBits = SHARE.MEMBER + SHARE.USE + SHARE.MANAGE }
    check(not SP.canStopGrant(managerView, viaFaction, "dave") and SP.canStopGrant(ownerView, viaFaction, "alice"),
        "陣營給的管理也算：管理成員不能停止實際持有管理的人（effBits）")
    check(SP.chipAllowed(ownerView, "MANAGE") and not SP.chipAllowed(managerView, "MANAGE"), "只有屋主能給管理")
    check(SP.chipAllowed(managerView, "MEMBER") and SP.chipAllowed(managerView, "USE")
        and not SP.chipAllowed(managerView, "BUILD") and not SP.chipAllowed(managerView, "FARM")
        and not SP.chipAllowed(managerView, "MOVE"), "管理成員只能勾自己有的權限")
    check(SP.chipAllowed(ownerView, "BUILD") and SP.chipAllowed(ownerView, "FARM"), "屋主不受自己位元限制")

    -- 送出路徑：已勾全部，管理成員送出的位元仍是自己位元的子集；屋主照原樣
    local sentArgs
    local function sendShare(d)
        sentArgs = nil
        local host = { detail = d, say = function() end,
            mutate = function(_, command, args) sentArgs = { command = command, args = args } end }
        local p = setmetatable({ host = host, bits = MSH.SHARE_ALL, ac = { getText = function() return "bob" end } },
            SP.Page)
        SP.Page.onShareUser(p)
        return sentArgs and sentArgs.args.bits
    end
    managerView.claimId, managerView.revision = 3, 1
    local sentBits = sendShare(managerView)
    check(sentBits == SHARE.MEMBER + SHARE.USE + SHARE.INVITE and SP.shareBits(managerView, sentBits) == sentBits,
        "管理成員送出的分享只帶自己有的位元與邀請、不帶管理")
    check(sendShare({ claimId = 3, revision = 1, actorRole = "owner", actions = { canManageShares = true } })
        == MSH.SHARE_ALL, "屋主送出照勾的全部")

    managerView.factionShare = { name = "Wolves", bits = SHARE.MEMBER + SHARE.USE, state = "GRANTED" }
    check(SP.canStopFaction(managerView), "管理成員可以停止陣營分享")
    check(SP.canStopFaction({ actorRole = "owner", actions = { canManageShares = true },
        factionShare = { bits = SHARE.MEMBER } }), "屋主可以停止陣營分享")
    check(not SP.canStopFaction({ actorRole = "member", bits = SHARE.MEMBER + SHARE.INVITE,
        actions = { canManageShares = false }, factionShare = { bits = SHARE.MEMBER } }), "只有邀請的成員不能停止陣營分享")
    check(SP.factionBits(MSH.SHARE_ALL) == SHARE.MEMBER + SHARE.USE + SHARE.MOVE + SHARE.BUILD + SHARE.FARM
        and SP.factionBits(SHARE.MEMBER + SHARE.USE) == SHARE.MEMBER + SHARE.USE, "陣營分享的位元一律去掉邀請與管理")
    check(SP.reasonKey({ reason = "LEADER_CHANGED" }) ~= SP.reasonKey({ reason = "GONE" })
        and SP.reasonKey({ reason = "???" }) == SP.reasonKey({}), "暫停原因分三種、其他用一般句")
    check(SP.bitsText(SHARE.MEMBER + SHARE.MANAGE + SHARE.INVITE) == getText("IGUI_MSH_Share_Bit_MEMBER") .. sep
        .. getText("IGUI_MSH_Share_Bit_INVITE") .. sep .. getText("IGUI_MSH_Share_Bit_MANAGE"),
        "名單與角色文字列出邀請（在管理之前）")
    check(SP.roleText(SHARE.MEMBER + SHARE.USE + SHARE.INVITE) == getText("IGUI_MSH_Manager_RoleMember",
        getText("IGUI_MSH_Share_Bit_USE") .. sep .. getText("IGUI_MSH_Share_Bit_INVITE"))
        and SP.roleText(SHARE.MEMBER) == getText("IGUI_MSH_Share_Bit_MEMBER"),
        "概覽的身分欄：括號裡只列成員以外的權限，不再寫「成員（成員、…）」；只有成員就寫「成員」")

    T.section("SharingPage：每種角色的 chip、按鈕與送出的位元（邀請，使用者 2026-10-11）")
    -- 假元件：只記可見、可用、勾選與文字；host 照管理視窗的介面（button／newLines／place／fit／flow／mutate／say）
    local function el(w)
        local e = { width = w or 40, visible = false, enabled = true, active = false, text = "" }
        function e:setVisible(v) self.visible = v end
        function e:getIsVisible() return self.visible end
        function e:setEnabled(v) self.enabled = v end
        function e:isEnabled() return self.enabled end
        function e:setActive(v) self.active = v end
        function e:setTooltip(t) self.tip = t end
        function e:setText(t) self.text = t end
        function e:getText() return self.text end
        function e:setWidth(v) self.width = v end
        function e:setHeight() end
        function e:clear() self.texts = {} end
        function e:add(t) self.texts = self.texts or {}; self.texts[#self.texts + 1] = t end
        return e
    end
    -- 框架 Autocomplete 的替身：記文字、可見、可用、下拉高度上限、交回的結果
    local function fakeAc(opts)
        local ac = { opts = opts, field = el(180), text = "", visible = false, enabled = true }
        function ac:setText(t) self.text = t end
        function ac:getText() return MSH.trim(self.text) end
        function ac:setVisible(v) self.visible = v; self.field.visible = v end
        function ac:setEnabled(v) self.enabled = v end
        function ac:addTo() end
        function ac:anchorList(maxH) self.maxH = maxH end
        function ac:setResults(text, rows) self.results = { text = text, rows = rows } return true end
        function ac:queryFailed(retry) self.failed = retry end
        return ac
    end
    local sent
    local host = { ch = 20, fh = 14, GAP = 6, iconW = 18, me = "dave",
        UI = { Autocomplete = { new = fakeAc } } }
    function host:newLines() return el() end
    function host:button() return el() end
    function host:place(e) e.visible = true end
    function host:fit(s) return s end
    function host:flow(items, x0, y) for _, e in ipairs(items) do e.visible = true end return y + self.ch end
    function host:mutate(command, args) sent = { command = command, args = args } return true end
    local errors = 0
    function host:say(_, token) if token == "errorText" then errors = errors + 1 end end
    local page = SP.new(host, { addChild = function() end, height = 300 })
    local function view(role, bits, lifecycle)
        local manage = role == "owner" or MSH.hasBit(bits, SHARE.MANAGE)
        return { claimId = 9, revision = 2, lifecycle = lifecycle or "active", actorRole = role, bits = bits,
            roster = { { user = "alice", role = "owner" } },
            grants = { { user = "bob", bits = SHARE.MEMBER + SHARE.USE }, { user = "dave", bits = bits } },
            factionShare = { name = "Wolves", bits = SHARE.MEMBER + SHARE.USE, state = "GRANTED", projected = true },
            limits = { maxShares = 8, allowFactionShare = true },
            actions = { canManageShares = manage, canShareFaction = role == "owner", canResumeFaction = false } }
    end
    local function render(d)
        host.detail = d
        page:hide()
        page:layout(d, 0, 0, 400)
        local out = {}
        for i, name in ipairs(SP.CHIPS) do if page.chips[i].visible then out[#out + 1] = name end end
        return table.concat(out, ",")
    end
    local function shareAll(name)   -- 全部勾起來送給玩家（預設新玩家 zed）
        page.bits, sent = MSH.SHARE_ALL, nil
        page.ac:setText(name or "zed")
        SP.Page.onShareUser(page)
        return sent and sent.args.bits
    end
    local function stops() return (page.rows[1].visible and "1" or "-") .. (page.rows[2].visible and "2" or "-") end

    local d = view("owner", MSH.SHARE_ALL)
    local chips = render(d)
    check(SP.CHIPS[6] == "INVITE" and SP.CHIPS[7] == "MANAGE" and chips == table.concat(SP.CHIPS, ","),
        "屋主：七個 chip 全部可勾，順序成員…農耕、邀請、管理")
    check(stops() == "12" and page.btnFactionStop.visible and page.btnFaction.visible, "屋主：每列都有〔停止〕、看得到陣營分享按鈕")
    check(shareAll() == MSH.SHARE_ALL, "屋主：送出照勾的全部（含邀請、管理）")
    page.bits, sent = MSH.SHARE_ALL, nil
    SP.Page.onShareFaction(page)
    check(sent and sent.command == "shareFaction" and sent.args.bits == SP.factionBits(MSH.SHARE_ALL),
        "屋主：分享給陣營時去掉邀請與管理（共用同一排 chip）")
    check(page.btnFaction.tip == getText("IGUI_MSH_Share_FactionNoInvite"), "陣營按鈕附說明：陣營分享不含邀請與管理")
    -- 陣營列的權限文字遮掉邀請與管理（舊資料可能還有）：暫時讓 getText 帶出參數再比對
    d.factionShare.bits = MSH.SHARE_ALL
    local realText = getText
    getText = function(k, a, b) return k .. "|" .. tostring(a) .. "|" .. tostring(b) end
    render(d)
    local want = "IGUI_MSH_Share_FactionRow|Wolves|" .. SP.bitsText(SP.factionBits(MSH.SHARE_ALL))
    local factionText = nil
    for _, t in ipairs(page.lines.texts) do if t == want then factionText = t end end
    getText = realText
    check(factionText ~= nil, "陣營列的權限文字不列邀請與管理（舊資料也一樣）")
    check(shareAll("bob") == MSH.SHARE_ALL, "屋主：輸入既有成員照樣送出（改權限）")

    d = view("member", SHARE.MEMBER + SHARE.USE + SHARE.MANAGE)
    check(render(d) == "MEMBER,USE,INVITE" and SP.canAdd(d), "管理成員：只能勾自己有的，另外可以勾邀請（自己沒有也可以）")
    check(stops() == "12" and page.rows[1].enabled and not page.rows[2].enabled and page.btnFactionStop.visible
        and not page.btnFaction.visible, "管理成員：可停止一般成員、不能停自己；可停止陣營分享、不能分享給陣營")
    check(shareAll() == SHARE.MEMBER + SHARE.USE + SHARE.INVITE, "管理成員：送出的位元 ⊆ 自己的＋邀請，不帶管理")
    check(shareAll("bob") == SHARE.MEMBER + SHARE.USE + SHARE.INVITE, "管理成員：輸入既有成員照樣送出（改權限）")

    d = view("member", SHARE.MEMBER + SHARE.USE + SHARE.BUILD + SHARE.INVITE)
    check(render(d) == "MEMBER,USE,BUILD" and SP.canAdd(d), "只有邀請：看得到分享頁，只能勾自己有的，不能勾邀請與管理")
    check(stops() == "--" and not page.btnFactionStop.visible and not page.btnFaction.visible
        and not page.btnResume.visible and page.ac.field.visible and page.btnUser.visible,
        "只有邀請：名單每列都沒有〔停止〕、看不到陣營分享按鈕，只有分享給玩家那一塊")
    check(shareAll() == SHARE.MEMBER + SHARE.USE + SHARE.BUILD and sent.command == "share",
        "只有邀請：送出的位元 ⊆ 自己的、不帶邀請與管理")
    local before = errors
    check(shareAll("bob") == nil and shareAll("alice") == nil and errors == before + 2,
        "只有邀請：輸入名單上已有的名字（成員或屋主）直接提示、不送出")

    d = view("member", SHARE.MEMBER + SHARE.USE)
    check(render(d) == "" and shareAll() == nil and not SP.canAdd(d), "兩者都沒有：沒有分享頁、一個 chip 都不能勾、送不出去")
    check(not SP.canAdd(view("member", SHARE.MEMBER + SHARE.INVITE, "lapsed"))
        and not SP.canAdd(view("owner", MSH.SHARE_ALL, "lapsed")), "不是 active：沒有分享頁")

    T.section("SharingPage：分享對象的候選（使用者 2026-10-12）")
    local me = T.player({ name = "dave" })
    d = view("owner", MSH.SHARE_ALL)
    render(d)
    local ac = page.ac
    check(ac.visible and ac.field.visible and ac.maxH == 300 - host.ch - 2 * host.GAP,
        "輸入框跟著分享頁顯示；下拉高度不超過捲動區扣掉輸入框")
    check(ac.opts.labelOf({ name = "Bart", online = true }) == "Bart"
        and ac.opts.tagOf({ name = "Bart", online = true }) == "IGUI_MSH_Share_Online"
        and ac.opts.tagOf({ name = "zoe", online = false }) == nil, "候選列：名字；在線的標「在線上」")
    local before = #T.clientSent
    check(ac.opts.onQuery(page, "ba", ac) == true and #T.clientSent == before + 1, "打字：送出候選查詢")
    local q = T.clientSent[#T.clientSent]
    check(q.command == "shareCandidates" and q.args.claimId == 9 and q.args.query == "ba", "查詢帶這間的 claimId 與輸入的字")
    check(ac.opts.onQuery(page, "bar", ac) == false and #T.clientSent == before + 1, "上一筆還沒回：不送（框架下一幀再問）")
    local function reply(fields)
        local r = { command = "shareCandidates", requestId = T.clientSent[#T.clientSent].args.requestId }
        for k, v in pairs(fields) do r[k] = v end
        T.fire("OnServerCommand", MSH.MODULE, "result", r)
    end
    reply({ ok = true, rows = { { name = "Bart", online = true } } })
    check(ac.results ~= nil and ac.results.text == "ba" and ac.results.rows[1].name == "Bart",
        "回覆交給框架，附送出時的字（框架比對目前輸入，過期的丟掉）")
    check(ac.opts.onQuery(page, "bar", ac) == true, "回覆後可以再查")
    reply({ ok = false, code = "NOT_OWNER" })
    check(ac.failed == false, "被拒：安靜收起、不重查")
    ac.opts.onQuery(page, "bart", ac)
    T.advance(MSH.Client.TIMEOUT_MS)
    MSH.Client.checkTimeouts(T.now)
    check(ac.failed == true and ac.opts.onQuery(page, "bart", ac) == true, "逾時：讓框架重新計時再查")
    page.host.detail = nil
    check(ac.opts.onQuery(page, "x", ac) == false, "沒有詳情：不送")
    page.host.detail = d
    page:hide()
    check(not ac.visible, "換分頁：輸入框與下拉收起")
    T.disconnect(me)

    T.section("ManagerWindow：重新框選按鈕顯示剩幾次")
    local realGetText = getText
    getText = function(k, a, b) return k .. "|" .. tostring(a) .. "|" .. tostring(b) end
    check(MW.redrawTitle(125000, 4) == "IGUI_MSH_Manager_RedrawTimes|2:05|4", "有 redrawsLeft：時間與剩幾次一起顯示")
    check(MW.redrawTitle(125000, nil) == "IGUI_MSH_Manager_Redraw|2:05|nil", "舊伺服器沒有 redrawsLeft：只顯示時間")
    check(string.gsub(MW.redrawTitle(125000, 4), "%d", "0") == string.gsub(MW.redrawTitle(9000, 4), "%d", "0"),
        "倒數量寬的字串固定（數字換 0 後每秒都一樣）")
    getText = realGetText

    T.section("ManagerWindow：放棄確認的文案")
    local function has(keys, k)
        for _, x in ipairs(keys) do if x == k then return true end end
        return false
    end
    local keys = MW.releaseKeys({ source = MSH.SOURCE.DEED }, 120000)
    check(keys[1] == "IGUI_MSH_Manager_ReleaseConfirm" and has(keys, "IGUI_MSH_Manager_ReleaseNoRefund")
        and has(keys, "IGUI_MSH_Manager_ReleaseTryRedraw"), "地契建的：寫明不退地契；緩衝期內提示改用重新框選")
    keys = MW.releaseKeys({ source = MSH.SOURCE.FREE }, 0)
    check(#keys == 1 and keys[1] == "IGUI_MSH_Manager_ReleaseConfirm", "免費、緩衝期已過：只有確認句")
    keys = MW.releaseKeys({ source = MSH.SOURCE.LEGACY }, 0)
    check(not has(keys, "IGUI_MSH_Manager_ReleaseNoRefund") and not has(keys, "IGUI_SafehouseUI_Release"),
        "遷移來的不提地契；不用「取消安全屋」那句")
    check(MW.clock(61000) == "1:01" and MW.clock(1) == "0:01" and MW.clock(-5) == "0:00", "倒數 m:ss、秒無條件進位、不出負數")

    T.section("在地面顯示範圍：外緣格疊色（人物附近、屋裡、房子後面改地板染色）、四類四種顏色、伺服器與玩家各自的開關")
    local Rg, FT = MSH.Ranges, MSH.FloorTint
    local function ovOf(kind)
        local c = Rg.COLORS[kind].ov
        return c.r .. "/" .. c.g .. "/" .. c.b
    end
    local function tintOf(kind)
        local c = Rg.COLORS[kind]
        return c.r .. "/" .. c.g .. "/" .. c.b
    end
    local tw = T.tintWorld()
    local world, lit, overlay = tw.floors, tw.lit, tw.overlay
    -- 一輪掃描（過了 SCAN_MS 的下一幀）後畫一幀：z 這層畫出來的格子（疊色與染色合起來）與顏色
    local function shown(z)
        local cells, colors = overlay(z)
        local tc, tcol = lit(z)
        for k in pairs(tc) do cells[k], colors[k] = true, tcol[k] end
        return cells, colors
    end
    -- 一輪掃描（過了 SCAN_MS 的下一幀），再一幀：FloorTint.tick 在 Ranges.update 之前跑，第一次畫到的那層下一幀才看玩家站在哪
    local function drawn(z)
        T.advance(Rg.SCAN_MS)
        T.fire("OnPreUIDraw")
        T.fire("OnPreUIDraw")
        return shown(z or 1)
    end
    local alice = T.player({ name = "alice", x = 105.5, y = 205.5, z = 1.6 })
    -- 我的 L 形兩塊、分享給我的、同陣營 bob 的（managed）、其他玩家 dave 的（managed）與 carol 的（原版）、很遠的我的
    local natives = { SafeHouse.addSafeHouse(100, 200, 4, 10, "@MSH:3"), SafeHouse.addSafeHouse(104, 206, 6, 4, "@MSH:3"),
        SafeHouse.addSafeHouse(120, 200, 5, 5, "@MSH:4"), SafeHouse.addSafeHouse(130, 200, 5, 5, "@MSH:5"),
        SafeHouse.addSafeHouse(140, 200, 5, 5, "@MSH:7"), SafeHouse.addSafeHouse(150, 200, 5, 5, "carol"),
        SafeHouse.addSafeHouse(5000, 5000, 5, 5, "@MSH:6") }
    local owners = { ["@MSH:5"] = "bob", ["@MSH:7"] = "dave" }
    local lookups, realOwnerName = 0, MSH.PublicApi.ownerName
    MSH.PublicApi.ownerName = function(o)
        lookups = lookups + 1
        return owners[o]
    end
    local team = T.faction("Team", "alice", { "bob" })
    local savedClaims = MSH.Client.claims
    MSH.Client.claims = { mine = { { claimId = 3 }, { claimId = 6 } }, shared = { { claimId = 4 } }, byId = {}, at = 1 }
    MSH.Client.emit("claims", MSH.Client.claims)
    local function sync(changes) T.fire("OnServerCommand", MSH.MODULE, "sandboxSync", changes) end
    -- 分享給我的那間東南角外 (125,205) 有一層樓的房子：畫面上在它後面的外緣格被牆與屋頂擋住（前 3 列連左右半格、再往前
    -- 正前方到第 5 列）；同陣營那間的 (134,200) 在屋裡
    tw.buildings["125,205,1"], tw.buildings["134,200,1"] = true, true
    local cells, colors = drawn()
    check(Rg.isOn() and colors["100,200"] == ovOf("own") and colors["121,200"] == ovOf("shared")
        and colors["130,200"] == ovOf("faction") and cells["140,200"] == nil and cells["150,200"] == nil
        and cells["5000,5000"] == nil and lit(1)["100,200"] == nil,
        "預設開著：我的、分享給我的、同陣營的外緣各疊自己的顏色、地板不染；其他玩家的不畫（伺服器預設不開放）、很遠的不畫")
    local tcells, tcolors = lit(1)
    check(tcolors["103,204"] == tintOf("own") and tcolors["103,203"] == tintOf("own") and colors["103,204"] == tintOf("own")
        and tcells["103,205"] == nil and tcells["105,206"] == nil and tcells["100,200"] == nil,
        "alice 站在格子中央：身體在畫面上蓋到的外緣格（身後的 103,203、103,204）改用地板染色，旁邊的照樣疊色")
    check(tcolors["124,204"] == tintOf("shared") and tcolors["124,203"] == tintOf("shared") and tcolors["123,204"] == tintOf("shared")
        and tcolors["120,200"] == tintOf("shared") and tcells["121,200"] == nil and tcolors["134,200"] == tintOf("faction")
        and tcells["130,200"] == nil,
        "前方的房子擋得到（前 3 列連左右半格、一層樓正前方到第 5 列）、在屋裡的外緣格改用地板染色（疊色會畫到牆與屋頂上）")
    local L = { { x = 100, y = 200, w = 4, h = 10 }, { x = 104, y = 206, w = 6, h = 4 } }
    local function edgeOf(rects, x, y)
        local R = MSH.Rect
        return R.listContains(rects, x, y) and not (R.listContains(rects, x - 1, y) and R.listContains(rects, x + 1, y)
            and R.listContains(rects, x, y - 1) and R.listContains(rects, x, y + 1))
    end
    local lOk = true
    for x = 99, 111 do
        for y = 199, 211 do
            if edgeOf(L, x, y) ~= (cells[x .. "," .. y] == true) then lOk = false end
        end
    end
    check(lOk and next((shown(0))) == nil, "我的 L 形兩塊畫成一個外緣、交界不畫、只畫玩家所在樓層")
    local before = tw.ghostCalls
    T.fire("RenderOpaqueObjectsInWorld", 1, 0, 0, 0, nil)
    check(tw.ghostCalls == before, "只畫 0 號玩家的畫面")
    alice.x, alice.y = 110.5, 210.5
    T.fire("OnPreUIDraw")
    cells, colors = shown(1)
    check(colors["103,204"] == ovOf("own") and lit(1)["103,204"] == nil and lit(1)["109,209"] == true
        and lit(1)["108,209"] == true and lit(1)["109,208"] == true,
        "alice 走開：原本身後那幾格換回疊色、不等掃描間隔；新位置身後的外緣改染色")
    alice.x, alice.y = 105.5, 205.5
    T.fire("OnPreUIDraw")
    local bobP = T.player({ name = "bob", x = 101.5, y = 201.5, z = 1 })
    T.advance(FT.NEAR_MS)
    T.fire("OnPreUIDraw")
    check(lit(1)["100,200"] == true and overlay(1)["100,200"] == nil, "別的玩家（bob）站的地方附近也改用染色（每 NEAR_MS 看一次）")
    T.disconnect(bobP)
    T.advance(FT.NEAR_MS)
    T.fire("OnPreUIDraw")
    check(overlay(1)["100,200"] == true and not world["100,200,1"].on, "bob 離開：換回疊色")
    tw.reads = 0
    world["103,204,1"].on = false   -- 別的功能取消了這格的染色
    T.fire("OnPreUIDraw")
    check(tw.reads == 0 and not world["103,204,1"].on, "掃描間隔內每幀只比時間：不讀格子")
    world["103,203,1"] = nil          -- 區塊重新載入：這格換了新的地板物件
    drawn()
    check(world["103,204,1"].on and world["103,203,1"] ~= nil and world["103,203,1"].on,
        "下一輪掃描補上：被取消的、換了新地板的染色格都重新染色")
    sync({ RangesOthers = true })
    cells, colors = drawn()
    local othersC = ovOf("others")
    check(colors["140,200"] == othersC and colors["150,200"] == othersC and othersC ~= ovOf("own")
        and othersC ~= ovOf("shared") and othersC ~= ovOf("faction") and colors["130,200"] == ovOf("faction"),
        "伺服器開放其他玩家的（sandboxSync）：managed 與原版的都用第四種顏色，同陣營的照舊")
    sync({ RangesFaction = false })
    cells = drawn()
    check(cells["130,200"] == nil and cells["134,200"] == nil and cells["140,200"] == true,
        "伺服器關掉同陣營的：bob 的疊色與染色都取消，也不改用其他玩家的顏色")
    sync({ RangesFaction = true })
    Rg.setKind("shared", false)
    cells = drawn()
    check(cells["120,200"] == nil and cells["124,204"] == nil and cells["100,200"] == true and cells["130,200"] == true
        and cells["140,200"] == true, "玩家關掉某一類：只少那一類")
    Rg.setKind("shared", true)
    T.disband(team)
    T.fire("SyncFaction", "Team")
    lookups = 0
    cells, colors = drawn()
    check(colors["130,200"] == othersC and lookups == 0,
        "退出陣營（SyncFaction）：bob 的改算其他玩家的；不在陣營時不為分類去查 managed 的屋主")
    local rebuilds, realRebuild = 0, Rg.rebuild
    Rg.rebuild = function() rebuilds = rebuilds + 1; realRebuild() end
    drawn()
    drawn()
    check(rebuilds == 0, "沒有變動時不重算")
    T.fire("OnSafehousesChanged")
    drawn()
    check(rebuilds == 1, "原生清單變了：下一輪重算一次")
    Rg.rebuild = realRebuild
    alice.z = 0.2
    check(next((drawn(1))) == nil and shown(0)["100,200"] == true, "換樓層：原樓層的取消，改畫玩家所在樓層")
    alice.x = 1000
    check(next((drawn(0))) == nil, "走遠：附近沒有的那幾間都取消")
    alice.x = 105
    drawn(0)
    -- 只畫畫面看得到的格子外加幾格（假鏡頭 x ±80）：鏡頭往東移 81 格，不等掃描間隔、下一幀就照新的畫面重切，
    -- 跨在邊上的那間只畫範圍裡的那一段
    alice.x = 186
    T.fire("OnPreUIDraw")
    local moved = shown(0)
    check(moved["100,200"] == nil and moved["101,200"] == nil and moved["102,200"] == true and moved["150,200"] == true,
        "鏡頭移出畫的範圍：不等掃描間隔，下一幀就照新的畫面重切；跨在邊上的那間只畫範圍裡的那一段")
    alice.x = 105
    drawn(0)
    Rg.setOn(false)
    check(next((drawn(0))) == nil and FT.n == 0 and next((lit(0))) == nil, "總開關關掉：疊色與染過的地板都取消")
    sync({ RangesOthers = false })
    for _, h in ipairs(natives) do SafeHouse.removeSafeHouse(h) end
    MSH.Client.claims = savedClaims
    MSH.PublicApi.ownerName = realOwnerName
    tw.restore()
    Rg.dirty = true

    T.section("ManagerWindow：管理員按鈕")
    check(not MW.isAdmin(), "一般玩家不顯示管理員面板")
    T.disconnect(getSpecificPlayer(0))
    T.player({ name = "root", admin = true })
    check(MW.isAdmin(), "CanSetupSafehouses 才顯示")

    T.section("ManagerWindow：安全屋多、視窗小、字大時，左欄「在地面顯示範圍」與上列按鈕都在視窗裡（使用者 2026-10-12）")
    -- 寬鬆的假框架：每個元件記住位置、大小、可見；字寬 charW、字高 fh 可調（模擬放大字型）
    local fw = { charW = 7, fh = 16, sw = 1280, sh = 720 }
    local savedG = {}
    for _, k in ipairs({ "ISPanel", "ISUIElement", "getTextManager", "getCore", "UIFont", "MinidoracatUI", "getTexture" }) do
        savedG[k] = _G[k]
    end
    local function cls(base)
        local c = {}
        c.__index = c
        if base then setmetatable(c, { __index = base }) end
        function c:derive() return cls(self) end
        return c
    end
    local W0 = cls()
    function W0:new(x, y, w, h)
        return setmetatable({ x = x or 0, y = y or 0, width = w or 60, height = h or 20, visible = true, kids = {} }, self)
    end
    for _, k in ipairs({ "initialise", "bringToTop", "drawText", "drawRect", "drawRectBorder", "drawTextureScaled",
        "setTooltip", "setActive", "setStyle", "setIconColor", "setItemVisible", "setSelected", "setSelectedIndex",
        "scrollTo", "setYScroll", "setCapture", "removeFromUIManager", "setInvalid", "setItemLabel" }) do
        W0[k] = function() end
    end
    function W0:addChild(k) self.kids[#self.kids + 1] = k; k.parent = self end
    function W0:addToUIManager() self.added = true end
    function W0:setVisible(v) self.visible = v end
    function W0:getIsVisible() return self.visible end
    function W0:isVisible() return self.visible end
    function W0:setX(v) self.x = v end
    function W0:setY(v) self.y = v end
    function W0:getX() return self.x end
    function W0:getY() return self.y end
    function W0:setWidth(v) self.width = v end
    function W0:setHeight(v) self.height = v end
    function W0:getWidth() return self.width end
    function W0:getHeight() return self.height end
    function W0:setEnabled(v) self.enabled = v ~= false end
    function W0:isEnabled() return self.enabled ~= false end
    function W0:contentTop() return 24 end
    function W0:contentWidth() return self.width - 12 end
    function W0:close() self.visible = false if self.onClose then self.onClose(self) end end
    function W0:resize(w, h) self.width, self.height = w, h end
    function W0:setItems(rows) self.items = rows end
    function W0:isSelected() return false end
    function W0:setChecked(v) self.checked = v end
    function W0:setLabel(l) self.label = l end
    function W0:setTitle(t) self.title = t if self.autoW then self.width = #tostring(t) * fw.charW + 20 end end
    function W0:setText(t) self.text = t end
    function W0:getText() return self.text or "" end
    function W0:clear() self.rows = {} end
    function W0:add() end
    ISUIElement, ISPanel = W0, cls(W0)
    UIFont = { Small = "Small", Medium = "Medium" }
    getTexture = function() return nil end
    getTextManager = function()
        return { MeasureStringX = function(_, _, s) return #tostring(s) * fw.charW end,
            getFontHeight = function() return fw.fh end }
    end
    local core = { getScreenWidth = function() return fw.sw end, getScreenHeight = function() return fw.sh end }
    getCore = function() return core end
    local function make(opts, h)
        local e = W0:new(opts.x, opts.y, opts.width or 60, opts.height or h or 20)
        for k, v in pairs(opts) do if e[k] == nil then e[k] = v end end
        return e
    end
    local caps = {}
    for _, c in ipairs(MW.CAPS) do caps[c] = true end
    local colors = {}
    for _, t in ipairs({ "text", "textMuted", "textDisabled", "warning", "errorText", "accent", "hover", "selected" }) do
        colors[t] = { r = 1, g = 1, b = 1, a = 1 }
    end
    MinidoracatUI = { v1 = { API_MAJOR = 1, API_REVISION = 18, CAPABILITIES = caps,
        Theme = { defaultPalette = function() return {} end, create = function() return { colors = colors } end },
        Text = {
            fit = function(s) return s end,
            wrap = function(s, w)
                local per = math.max(1, math.floor(w / fw.charW))
                local out = {}
                for i = 1, #s, per do out[#out + 1] = string.sub(s, i, i + per - 1) end
                return #out > 0 and out or { "" }
            end },
        Icons = { draw = function() end },
        Dialog = { show = function(o) return o end },
        Window = { new = function(o) return make(o) end },
        ScrollPanel = { new = function(o) return make(o) end },
        VirtualList = { new = function(o) return make(o) end },
        Tabs = { new = function(o)
            local t = make(o, fw.fh + 10)
            local w = 0
            for _, it in ipairs(o.items or {}) do w = w + #tostring(it.label) * fw.charW + 20 end
            t.width = w
            return t
        end },
        Checkbox = { new = function(o)
            local c = make(o, fw.fh + 4)
            c.width = 24 + #tostring(o.label) * fw.charW
            return c
        end },
        Button = { new = function(o)
            local b = make(o, fw.fh + 10)
            b.autoW = o.width == nil
            if b.autoW then b.width = #tostring(o.title or "") * fw.charW + 20 + (o.icon and 18 or 0) end
            return b
        end },
        Autocomplete = { new = function()
            local ac = { field = W0:new(0, 0, 180, 20), list = W0:new(0, 0, 180, 100), text = "" }
            for _, k in ipairs({ "addTo", "anchorList", "setResults", "queryFailed" }) do ac[k] = function() end end
            function ac:setText(t) self.text = t end
            function ac:getText() return self.text end
            function ac:setVisible(v) self.field.visible = v end
            function ac:setEnabled() end
            function ac:isOpen() return false end
            return ac
        end },
    } }
    -- 開一個新的管理視窗，清單回 n 間（伺服器 list 回覆照真的格式），視窗改成 w×h 後重排
    local function openWith(n, w, h)
        MW.instance, MSH.Client._theme = nil, nil
        local win = MW.open({})
        local sent = T.clientSent[#T.clientSent]
        local claims = {}
        for i = 1, n do
            claims[i] = { claimId = 500 + i, revision = 1, title = "house " .. i, actorRole = "owner", bits = MSH.SHARE_ALL,
                lifecycle = "active", healthSummary = "PROTECTED" }
        end
        T.fire("OnServerCommand", MSH.MODULE, "result", { command = "list", requestId = sent.args.requestId, ok = true,
            code = "OK", claims = claims })
        win.win:setWidth(w)
        win.win:setHeight(h)
        win:layout()
        return win
    end
    -- 左欄與上列都在視窗裡：範圍那塊（開關＋全部 chip）在清單底下、頁尾上面；清單至少兩列；上列按鈕不超出左右邊
    local function fits(win)
        local BW, BH = win.body.width, win.body.height
        local footY = BH - MW.PAD - math.max(win.ch, win.fh * 2)
        local box = win.rangesBox
        local bottom = box.y + box.height
        local allChips = true
        for _, b in ipairs(win.rangeChips) do
            allChips = allChips and b.visible
            bottom = math.max(bottom, b.y + b.height)
        end
        local inRow = true
        for _, b in ipairs({ win.btnRefresh, win.btnSlots, win.btnCreate, win.btnAdmin }) do
            if b.visible and (b.x < 0 or b.x + b.width > BW) then inRow = false end
        end
        local listOk = win.list.visible and win.list.height >= win.rowH * 2 + MW.LIST_PAD * 2
            and win.list.y + win.list.height <= box.y
        return box.visible and allChips and bottom <= footY and listOk and inRow and win.win.height <= fw.sh,
            string.format("win=%dx%d list=%s,%d..%d ranges=%d..%d footY=%d", win.win.width, win.win.height,
                tostring(win.list.visible), win.list.y, win.list.y + win.list.height, box.y, bottom, footY)
    end
    local a = openWith(150, 860, 560)
    local okA, infoA = fits(a)
    check(okA and #a.list.items == 150, "預設大小、150 間：清單會捲，範圍那塊固定在底下（" .. infoA .. "）")
    local b = openWith(150, 300, 280)
    local okB, infoB = fits(b)
    check(okB and b.win.height > 280 and b.win.minHeight == b.win.height,
        "縮到最小 300×280：上列按鈕換行不出界；清單留不到兩列就把視窗長高、最小高度跟著提高（" .. infoB .. "）")
    fw.charW, fw.fh = 16, 40   -- 放大字型（約 2.5x）
    local c = openWith(150, 860, 560)
    local okC, infoC = fits(c)
    check(okC and c.win.height > 560, "字型放大：預設大小放不下兩列清單就長高（" .. infoC .. "）")
    fw.sh = 600
    local d = openWith(150, 300, 280)
    local _, infoD = fits(d)
    check(d.win.height == 600 and d.list.height >= 0 and d.rangesBox.visible,
        "螢幕不夠高（小螢幕配很大的字）：長到螢幕高為止，清單不給負的高度（" .. infoD .. "）")
    fw.charW, fw.fh, fw.sh = 7, 16, 720
    local e = openWith(0, 300, 280)
    local BH = e.body.height
    local footY = BH - MW.PAD - math.max(e.ch, e.fh * 2)
    local eb = e.rangesBox.y + e.rangesBox.height
    for _, k in ipairs(e.rangeChips) do eb = math.max(eb, k.y + k.height) end
    check(e.rangesBox.visible and eb <= footY,
        "沒有安全屋、最小大小：說明與〔建立安全屋〕底下的範圍那塊在頁尾上面（" .. eb .. " ≤ " .. footY .. "）")

    T.section("ManagerWindow：重生點（使用者 2026-10-14）：〔設為重生點〕只在伺服器開放、站在這間裡時可按；點在這間給〔清除重生點〕")
    local rw = openWith(1, 860, 560)
    local me0 = getSpecificPlayer(0)
    local function showRespawn(respawn, lifecycle)
        if rw.selectedId ~= 501 then rw:select(501) end
        rw:loadDetail()
        local req = T.clientSent[#T.clientSent]
        T.fire("OnServerCommand", MSH.MODULE, "result", { command = "detail", requestId = req.args.requestId, ok = true,
            code = "OK", claimId = 501, revision = 3, title = "house 1", rects = { { x = 100, y = 100, w = 10, h = 10 } },
            actorRole = "owner", bits = MSH.SHARE_ALL, lifecycle = lifecycle or "active", healthSummary = "PROTECTED",
            source = "deed", deedTier = 1, actions = {}, respawn = respawn })
    end
    me0.x, me0.y = 50, 50
    showRespawn({ allowed = true })
    check(rw.btnRespawnSet.visible and not rw.btnRespawnSet:isEnabled() and not rw.btnRespawnClear.visible
        and rw.respawnWhy == "IGUI_MSH_Manager_RespawnStandInside", "站在範圍外：〔設為重生點〕停用、寫原因")
    me0.x, me0.y = 105.5, 109.9
    rw.theme.fill = rw.theme.fill or function() end
    rw:prerender(rw.body)
    rw:prerender(rw.body)
    check(rw.btnRespawnSet:isEnabled() and rw.respawnWhy == nil, "走進範圍：下一幀就可以按（不用重開視窗）")
    local sentBefore = #T.clientSent
    rw.btnRespawnSet.onClick(rw)
    local sentSet = T.clientSent[#T.clientSent]
    check(#T.clientSent == sentBefore + 1 and sentSet.command == "setRespawn" and sentSet.args.claimId == 501
        and sentSet.args.expectedRevision == 3 and sentSet.args.x == nil, "按下：送 setRespawn（只帶 claimId 與 revision，不帶座標）")
    rw:finishBusy()
    showRespawn({ allowed = false })
    check(rw.btnRespawnSet.visible and not rw.btnRespawnSet:isEnabled() and rw.respawnWhy == "IGUI_MSH_Manager_RespawnOff",
        "伺服器沒開放：停用、寫原因")
    showRespawn({ allowed = true, here = { x = 105, y = 109, z = 0 } })
    check(rw.btnRespawnClear.visible and rw.btnRespawnClear:isEnabled() and not rw.btnRespawnSet.visible,
        "點在這間：只有〔清除重生點〕")
    rw.btnRespawnClear.onClick(rw)
    check(T.clientSent[#T.clientSent].command == "clearRespawn", "按下：送 clearRespawn")
    rw:finishBusy()
    showRespawn({ allowed = true }, "lapsed")
    check(not rw.btnRespawnSet.visible and not rw.btnRespawnClear.visible, "不是 active、點也不在這間：沒有重生點按鈕")
    showRespawn(nil)
    check(not rw.btnRespawnSet.visible and not rw.btnRespawnClear.visible, "舊伺服器沒有 respawn 欄位：不顯示")

    T.section("ManagerWindow：閒置收回倒數、滑鼠提示與〔延長保留〕（使用者 2026-10-14）")
    local UIv, realGetText2, savedEco = MinidoracatUI.v1, getText, MinidoracatEconomy
    local realShow = UIv.Dialog.show
    local dialogs = {}
    UIv.Dialog.show = function(o) dialogs[#dialogs + 1] = o return o end
    UIv.Date = { fromMs = function(ms) return ms, 1, 1 end, format = function(y) return "D" .. tostring(y) end }
    -- 帶參數的鍵寫成「鍵|參數…」；名額視窗的原因鍵當作有譯文（SW.reasonText 先看鍵在不在）
    getText = function(k, ...)
        local a = { ... }
        for i = 1, #a do a[i] = tostring(a[i]) end
        if #a == 0 and string.find(k, "^IGUI_MSH_Slots_Reason_") then return "R:" .. k end
        return #a == 0 and k or (k .. "|" .. table.concat(a, "|"))
    end
    local DAY, HOUR, MIN = 86400000, 3600000, 60000
    local function showIdle(idle, role)
        if rw.selectedId ~= 501 then rw:select(501) end
        rw:loadDetail()
        local req = T.clientSent[#T.clientSent]
        T.fire("OnServerCommand", MSH.MODULE, "result", { command = "detail", requestId = req.args.requestId, ok = true,
            code = "OK", claimId = 501, revision = 3, title = "house 1", rects = { { x = 100, y = 100, w = 10, h = 10 } },
            actorRole = role or "owner", bits = MSH.SHARE_ALL, lifecycle = "active", healthSummary = "PROTECTED",
            source = "deed", deedTier = 2, actions = {}, idle = idle })
    end
    local function idleRow()
        for _, r in ipairs(rw.lines.rows) do
            if string.find(r.text, "^IGUI_MSH_Manager_Idle") then return r end
        end
        return nil
    end
    local function tip() return rw.idleHover.visible and rw.idleHover.tooltip or "" end
    local function has(s, part) return string.find(s, part, 1, true) ~= nil end
    showIdle({ kind = "free", days = 14, remainingMs = 3 * DAY + 5 * HOUR + 30 * MIN })
    local r = idleRow()
    check(r ~= nil and r.text == "IGUI_MSH_Manager_IdleLeftDays|3|5" and r.token == "text",
        "免費：≥ 1 天寫天＋小時（" .. tostring(r and r.text) .. "）")
    local t = tip()
    check(has(t, "IGUI_MSH_Manager_IdleTipWho") and has(t, "IGUI_MSH_Manager_IdleTipDays|14")
        and has(t, "IGUI_MSH_Manager_IdleTipRelease") and not has(t, "IdleTipInsured") and has(t, " <LINE> "),
        "滑鼠提示：誰進範圍重新計時、這間的天數、歸零收回不退地契；沒保險不寫保險")
    rw.dirty = false
    T.advance(30000)
    rw:prerender(rw.body)
    check(not rw.dirty, "同一分鐘內不重排")
    T.advance(31000)
    rw:prerender(rw.body)
    check(rw.dirty, "顯示的分鐘數變了才重排（最多每分鐘一次）")
    rw:prerender(rw.body)
    check(not rw.dirty and idleRow().text == "IGUI_MSH_Manager_IdleLeftDays|3|5", "重排後照本機倒數")
    showIdle({ kind = "buy", days = 30, remainingMs = 2 * HOUR + 4 * MIN + 1 })
    r = idleRow()
    check(r.text == "IGUI_MSH_Manager_IdleLeftHours|2|5" and r.token == "warning" and has(tip(), "IdleTipDays|30"),
        "買斷：不到 1 天寫小時＋分（分無條件進位）、警告色；天數照 IdleBuyDays")
    showIdle({ kind = "free", days = 14, remainingMs = 0 })
    check(idleRow().text == "IGUI_MSH_Manager_IdleDue", "剩 0：寫到期")
    showIdle({ kind = "rent" })
    check(idleRow().text == "IGUI_MSH_Manager_IdleRent" and tip() == "IGUI_MSH_Manager_IdleTipRent", "租用：照租約，提示寫明")
    showIdle({ kind = "unknown" })
    check(idleRow().text == "IGUI_MSH_Manager_IdleUnknown" and tip() == "IGUI_MSH_Manager_IdleTipUnknown",
        "讀不到 Economy：寫無法確認、期間不收回")
    showIdle({ kind = "off" })
    check(idleRow() == nil and not rw.idleHover.visible, "off：沒有這列")
    showIdle(nil)
    check(idleRow() == nil and not rw.idleHover.visible, "沒有 idle：沒有這列")
    showIdle({ kind = "free", days = 14, remainingMs = 20 * DAY, insuredMs = 6 * DAY })
    check(has(tip(), "IGUI_MSH_Manager_IdleTipInsured|D" .. tostring(T.now + 6 * DAY)), "保險中：提示寫保險到哪天")

    local insure = { product = "insure2", tier = 2, price = 50, currency = "survivor", lease = "L9", maxDays = 365 }
    local function insured(extra)
        local idle = { kind = "free", days = 14, remainingMs = 10 * DAY, insuredMs = 2 * DAY, insure = insure }
        for k, v in pairs(extra or {}) do idle[k] = v end
        return idle
    end
    showIdle(insured())
    check(not rw.btnInsure.visible, "沒有 Economy 客戶端：沒有〔延長保留〕")
    local calls = {}
    local function rec(name) return function(...) calls[#calls + 1] = { name = name, args = { ... } } return "rid" end end
    local E = { quote = rec("quote"), purchase = rec("purchase"), getOrder = rec("getOrder"), requestState = rec("requestState"),
        currencyName = function(c) return c end, errorText = function(c) return "E:" .. tostring(c) end,
        orderOutcome = function(res) return res.order and res.order.status end }
    local caps = { entitlements = true, rentals = true, rentalPeriods = false }
    MinidoracatEconomy = { v1 = { Client = { API_MAJOR = 1, API_REVISION = 6, CAPABILITIES = caps, Entitlements = E } } }
    showIdle(insured())
    check(not rw.btnInsure.visible, "Economy 不能一次付多期（rentalPeriods）：沒有〔延長保留〕")
    caps.rentalPeriods = true
    showIdle(insured(), "member")
    check(not rw.btnInsure.visible, "不是屋主：沒有〔延長保留〕")
    showIdle({ kind = "free", days = 14, remainingMs = 10 * DAY })
    check(not rw.btnInsure.visible, "伺服器沒給 insure（現在不能買）：沒有〔延長保留〕")
    showIdle(insured())
    check(rw.btnInsure.visible and rw.btnInsure:isEnabled(), "屋主、有 insure、Economy 支援：〔延長保留〕可按")
    local function lastCall(name)
        for i = #calls, 1, -1 do if calls[i].name == name then return calls[i].args end end
        return nil
    end
    for _, bad in ipairs({ "0", "366", "abc", "2.5", "" }) do
        rw.btnInsure.onClick(rw)
        dialogs[#dialogs].onResult(true, bad)
    end
    check(lastCall("quote") == nil and #dialogs == 5 and rw.msgToken == "errorText"
        and has(rw.msg, "IGUI_MSH_Manager_InsureBadDays|365"), "天數不是 1..maxDays 的整數：本機擋下、不報價")
    check(has(dialogs[1].text, "IGUI_MSH_Manager_InsureAsk|IGUI_MSH_Slots_Money|50|survivor|365") and dialogs[1].input ~= nil,
        "第一步：每日價格與天數上限、輸入框")
    rw.btnInsure.onClick(rw)
    dialogs[#dialogs].onResult(true, " 3 ")
    local conf = dialogs[#dialogs]
    local est = T.now + MW.insureEstimate(10 * DAY, 2 * DAY, 14, 3)
    check(est == T.now + 19 * DAY and conf.text == "IGUI_MSH_Manager_InsureConfirm|3|IGUI_MSH_Slots_Money|50|survivor|"
        .. "IGUI_MSH_Slots_Money|150|survivor|D" .. tostring(est), "第二步：天數、每日價格、合計＝價格 × 天數、預計保留到（保險剩餘＋天數＋門檻）")
    check(MW.insureEstimate(40 * DAY, nil, 14, 1) == 40 * DAY, "預計剩餘不少於現在的剩餘")
    conf.onResult(true)
    local q = lastCall("quote")
    check(q ~= nil and q[1] == MSH.MOD_ID and q[2] == "insure2" and q[3] == "rental" and q[4] == 1 and q[6] == "L9"
        and q[7] == 3, "確認：報價 insure2、rental、數量 1、續保帶租約、periods＝天數")
    local function details()
        local n = 0
        for _, s in ipairs(T.clientSent) do if s.command == "detail" then n = n + 1 end end
        return n
    end
    local nDetail = details()
    q[5]({ ok = true, quote = { id = "Q1", orderId = "O1", amount = 200, currency = "survivor" } })
    check(lastCall("purchase") == nil and has(rw.msg, "IGUI_MSH_Slots_PriceChanged") and details() == nDetail + 1,
        "報價金額不是價格 × 天數：不付款、說明新價格、重抓詳情")
    showIdle(insured())
    rw.btnInsure.onClick(rw)
    dialogs[#dialogs].onResult(true, "3")
    dialogs[#dialogs].onResult(true)
    lastCall("quote")[5]({ ok = false, error = "INSURE_CLOSED" })
    check(lastCall("purchase") == nil and rw.msg == "R:IGUI_MSH_Slots_Reason_INSURE_CLOSED" and rw.msgToken == "errorText",
        "伺服器拒絕（INSURE_CLOSED）：走名額視窗的原因文字")
    rw.btnInsure.onClick(rw)
    dialogs[#dialogs].onResult(true, "3")
    dialogs[#dialogs].onResult(true)
    lastCall("quote")[5]({ ok = true, quote = { id = "Q2", orderId = "O2", amount = 150, currency = "survivor" } })
    local pc = lastCall("purchase")
    check(pc ~= nil and pc[1] == MSH.MOD_ID and pc[2] == "Q2", "金額一致：用同一張報價付款")
    pc[3]({ ok = false, unknown = true, error = "timeout" })
    check(rw.ins.order ~= nil and rw.btnInsureCheck.visible and not rw.btnInsure:isEnabled()
        and has(rw.msg, "IGUI_MSH_Slots_NoAnswer"), "付款結果未知：保留付款鎖、〔延長保留〕停用、只給〔查詢購買結果〕")
    local nQuote = #calls
    rw.btnInsure.onClick(rw)
    check(#calls == nQuote, "鎖著時按〔延長保留〕不動作")
    rw.btnInsureCheck.onClick(rw)
    local go = lastCall("getOrder")
    check(go ~= nil and go[2] == "insure2" and go[3] == "O2" and lastCall("purchase") == pc, "查詢只讀同一筆訂單（insure2），不重送付款")
    go[4]({ ok = true, known = false, order = { orderId = "O2" } })
    check(rw.ins.order ~= nil and rw.btnInsureCheck.visible, "查回還不知道：鎖照舊")
    rw.btnInsureCheck.onClick(rw)
    nDetail = details()
    lastCall("getOrder")[4]({ ok = true, known = true, order = { orderId = "O2", status = "paid" } })
    check(rw.ins.order == nil and rw.msg == "IGUI_MSH_Manager_InsurePaid" and details() == nDetail + 1
        and not rw.btnInsureCheck.visible, "查回已付款：解除鎖、寫保險已生效、重抓詳情")
    MinidoracatEconomy = savedEco
    UIv.Dialog.show, UIv.Date = realShow, nil
    getText = realGetText2
    MW.instance, MSH.Client._theme = nil, nil
    for k, v in pairs(savedG) do _G[k] = v end

    T.section("ManagerWindow：沒有 UI 框架時退最小 fallback、不報錯")
    -- 原版 ISPanel／ISButton 的最小假物件（只有 fallback 用到的方法）
    local function element(x, y, w, h)
        local e = { x = x, y = y, width = w, height = h, visible = true, kids = {}, texts = {} }
        function e:initialise() end
        function e:addChild(c) self.kids[#self.kids + 1] = c end
        function e:addToUIManager() self.added = true end
        function e:setVisible(v) self.visible = v end
        function e:getIsVisible() return self.visible end
        function e:drawText(s) self.texts[#self.texts + 1] = s end
        return e
    end
    ISPanel = { new = function(_, x, y, w, h) return element(x, y, w, h) end }
    ISButton = { new = function(_, x, y, w, h) return element(x, y, w, h) end }
    getCore = function() return { getScreenWidth = function() return 1280 end, getScreenHeight = function() return 720 end } end
    getTextManager = function() return { getFontHeight = function() return 16 end } end
    UIFont = { Small = "Small", Medium = "Medium" }
    MinidoracatUI = nil
    local before = #T.clientSent
    local ok, f = pcall(MW.open, {})
    check(ok and f ~= nil and f.added and f:getIsVisible() and #T.clientSent == before + 1
        and T.clientSent[#T.clientSent].command == "list", "開啟 fallback 並抓清單")
    local sent = T.clientSent[#T.clientSent]
    T.fire("OnServerCommand", MSH.MODULE, "result", { command = "list", requestId = sent.args.requestId, ok = true,
        code = "OK", claims = { { claimId = 3, revision = 1, title = "home", actorRole = "owner", bits = MSH.SHARE_ALL,
        lifecycle = "active", healthSummary = "PROTECTED" } } })
    f.texts = {}
    MW.renderFallback(f)
    check(#MW.fallbackLines == 1 and #f.texts == 3, "清單更新後 fallback 列出每一間（標題、需要更新框架、每間一列）")
    ISPanel, ISButton, getCore, getTextManager, UIFont = nil, nil, nil, nil, nil
end
