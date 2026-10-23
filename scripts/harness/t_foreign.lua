-- 原版安全屋（Foreign.lua，使用者 2026-10-23 設計稿 safehouse-foreign-1023）：管理員查詢（只列 foreign、排序、閒置天數、
-- 接管時留下的原因、遷移等待中）、釋出（指紋三樣都要對上、碰不到本 MOD 的屋、放鎖後推 foreignRemove、移除失敗不推）、
-- 每分鐘提示（開服第一輪不算、連續兩輪才算、只送管理員）；客戶端 Mirror 照範圍＋屋主移除與 tombstone、
-- 管理員提示 alert 的文字、原版安全屋清單本 MOD 列的字、管理員〔檢視〕別人的屋改開玩家頁。
return function(T)
    local check = T.check
    local DAY = 86400000

    local function countLogs(event)
        local n = 0
        for _, line in ipairs(T.logs) do
            if string.find(line, "^" .. event .. "\t") then n = n + 1 end
        end
        return n
    end
    local function alertsOf(p)
        local out = {}
        for _, m in ipairs(T.outbox[p.name] or {}) do
            if m.command == "alert" then out[#out + 1] = m.args end
        end
        return out
    end
    local function rowOf(res, owner)
        for _, r in ipairs(res.list or {}) do
            if r.owner == owner then return r end
        end
        return nil
    end
    local function args(h, created)
        return { rect = { x = h.x, y = h.y, w = h.w, h = h.h }, owner = h.owner, created = created or h.created }
    end

    -- ===== 伺服器 =====
    local MSH = T.boot()
    local F = MSH.Foreign
    local boss = T.player({ name = "boss", admin = true })
    local alice = T.player({ name = "alice" })
    local mark = SafeHouse.addSafeHouse(10600, 9824, 8, 8, MSH.marker(5))   -- 本 MOD 標記的原生（沒有紀錄也不是 foreign）
    local zed = SafeHouse.addSafeHouse(10700, 9824, 8, 8, "zed")
    zed.title, zed.lastVisited = "Zed old base", T.now - 30 * DAY
    local shed = SafeHouse.addSafeHouse(10900, 9750, 6, 6, "x.y")
    shed.title, shed.lastVisited = "Old shed", T.now - 3 * 3600000
    for _, u in ipairs({ "a", "b", "c" }) do shed:addPlayer(u) end
    local amy = SafeHouse.addSafeHouse(10720, 9824, 6, 6, "amy")
    amy.title = "Amy cabin"
    T.files[MSH.Migration.manifestPath()] = { lines = {
        "imp\tg1\t3\t10000,10000,5,5\t1\tbob\t\tBob",
        "skip\tg1\tBAD_OWNER\t10900,9750,6,6\tx.y\tOld shed",
    } }

    T.section("Foreign：查詢")
    local res = T.cmd(alice, "adminForeign", {})
    check(res ~= nil and res.code == "NOT_ADMIN", "非管理員查原版安全屋：NOT_ADMIN")
    res = T.cmd(boss, "adminForeign", {})
    check(res.ok and res.count == 3 and #res.list == 3 and res.more == 0 and rowOf(res, MSH.marker(5)) == nil,
        "管理員查：只列 foreign 三間，本 MOD 標記的原生不列")
    check(res.list[1].owner == "zed" and res.list[2].owner == "x.y" and res.list[3].owner == "amy",
        "最久沒人進去的在前")
    local z = rowOf(res, "zed")
    check(z.rect.x == 10700 and z.rect.w == 8 and z.created == zed.created and z.title == "Zed old base" and z.members == 0
        and z.idleMs >= 30 * DAY and z.idleMs < 30 * DAY + 60000 and z.origin == "later" and z.reason == nil,
        "每間帶範圍、建立時間、標題、成員數（不含屋主）、閒置毫秒、來源")
    local s = rowOf(res, "x.y")
    check(s.origin == "skip" and s.reason == "BAD_OWNER" and s.members == 3, "completion 檔有 skip 行：接管時留下＋原因碼")
    check(res.idleDays == 14 and res.stale == 1, "超過 IdleDays（預設 14）沒人進去的間數")
    T.sandbox("IdleDays", 0)
    res = T.cmd(boss, "adminForeign", {})
    check(res.stale == 0 and res.idleDays == 0, "IdleDays 0（閒置收回關閉）：不算超過")
    T.sandbox("IdleDays", 14)
    local keepMax = F.LIST_MAX
    F.LIST_MAX = 2
    res = T.cmd(boss, "adminForeign", {})
    check(res.count == 3 and #res.list == 2 and res.more == 1 and res.list[1].owner == "zed", "超過 LIST_MAX：只列最久的幾間、其餘給間數")
    F.LIST_MAX = keepMax
    local md = MSH.Registry.md
    local keepMig = md.migration
    md.migration = { state = "waiting", reason = "BSH_ACTIVE" }
    res = T.cmd(boss, "adminForeign", {})
    check(rowOf(res, "zed").origin == "waiting" and rowOf(res, "x.y").origin == "skip", "遷移還在等：沒 skip 行的寫 waiting")
    md.migration = keepMig

    T.section("Foreign：釋出")
    res = T.cmd(alice, "adminForeignRelease", args(zed))
    check(res.code == "NOT_ADMIN" and T.houseOf("zed") ~= nil, "非管理員：NOT_ADMIN、不移除")
    res = T.cmd(boss, "adminForeignRelease", args(zed, zed.created + 1))
    check(res.code == "NOT_FOUND" and T.houseOf("zed") ~= nil, "建立時間對不上：NOT_FOUND、不移除")
    local a = args(zed)
    a.owner = "zedd"
    res = T.cmd(boss, "adminForeignRelease", a)
    check(res.code == "NOT_FOUND" and T.houseOf("zed") ~= nil, "屋主對不上：NOT_FOUND")
    res = T.cmd(boss, "adminForeignRelease", args(mark))
    check(res.code == "NOT_FOUND" and T.houseOf(MSH.marker(5)) ~= nil, "本 MOD 的原生（範圍、標記、建立時間全對）：碰不到")
    a = args(zed)
    a.rect.extra = 1
    res = T.cmd(boss, "adminForeignRelease", a)
    check(res.code == "BAD_ARGS", "範圍多帶欄位：BAD_ARGS")
    local realSend, lockedAt = sendServerCommand, nil
    sendServerCommand = function(p1, p2, p3, p4)
        if p2 == "foreignRemove" then lockedAt = MSH.Srv.locked end
        return realSend(p1, p2, p3, p4)
    end
    local before = #T.broadcastsOf("foreignRemove")
    T.failHouseRemove = true
    res = T.cmd(boss, "adminForeignRelease", args(zed))
    T.failHouseRemove = false
    check(res.code == "RELEASE_FAILED" and #T.broadcastsOf("foreignRemove") == before and countLogs("FOREIGN_RELEASED") == 0,
        "移除後還在：RELEASE_FAILED、不推送、不寫稽核")
    res = T.cmd(boss, "adminForeignRelease", args(zed))
    local pushed = T.broadcastsOf("foreignRemove")
    local last = pushed[#pushed]
    check(res.ok and res.title == "Zed old base" and T.houseOf("zed") == nil and T.houseOf("amy") ~= nil,
        "三樣都對上：移除那一間，回標題")
    check(#pushed == before + 1 and last.x == 10700 and last.y == 9824 and last.w == 8 and last.h == 8 and last.owner == "zed",
        "推 foreignRemove 給全部客戶端（範圍＋屋主）")
    check(lockedAt == false, "推送在放鎖之後")
    check(countLogs("FOREIGN_RELEASED") == 1, "寫稽核 FOREIGN_RELEASED")
    sendServerCommand = realSend
    local big = SafeHouse.addSafeHouse(20000, 20000, 200, 150, "giant")
    res = T.cmd(boss, "adminForeignRelease", args(big))
    check(res.ok and T.houseOf("giant") == nil, "原版屋大過 96 格也指得到（nativeRect 不限邊長）")

    T.section("Foreign：本 MOD 的原生被改掉屋主（收斂換回標記之前）")
    local R = MSH.Registry
    local rec = R.newRecord({ claimId = R.allocId(), rects = { { x = 11200, y = 11200, w = 6, h = 6 } }, title = "home",
        owner = "alice", source = MSH.SOURCE.DEED, deedTier = 1, createdAt = T.now })
    local piece = MSH.Native.build(rec, {})[1]
    rec.rects[1].created = piece:getDatetimeCreated()
    R.put(rec)
    piece:setOwner("mallory")
    res = T.cmd(boss, "adminForeign", {})
    check(res.ok and rowOf(res, "mallory") == nil and res.count == 2, "範圍＋建立時間對得上紀錄的某一塊：不列、不算間數")
    res = T.cmd(boss, "adminForeignRelease", args(piece))
    check(res.code == "NOT_FOUND" and T.houseOf("mallory") ~= nil, "也不能從這裡釋出")

    T.section("Foreign：每分鐘提示")
    F.known, F.prev = nil, nil
    F.watch()
    check(#alertsOf(boss) == 0, "開服第一輪：現有的原版屋不提示")
    local fresh = SafeHouse.addSafeHouse(11000, 11000, 5, 5, "newbie")
    F.watch()
    check(#alertsOf(boss) == 0, "新出現的第一輪先不算（可能是收斂前暫時被改掉屋主的本 MOD 原生）")
    F.watch()
    local got = alertsOf(boss)
    check(#got == 1 and got[1].code == "FOREIGN_APPEARED" and got[1].detail == "1" and #alertsOf(alice) == 0,
        "連續兩輪都在：提示在線管理員（一般玩家收不到）")
    check(countLogs("FOREIGN_APPEARED") == 1, "寫稽核 FOREIGN_APPEARED")
    F.watch()
    check(#alertsOf(boss) == 1, "同一間不重複提示")
    local blip = SafeHouse.addSafeHouse(12000, 12000, 5, 5, "blip")
    F.watch()
    SafeHouse.removeSafeHouse(blip)
    F.watch()
    SafeHouse.addSafeHouse(13000, 13000, 5, 5, MSH.marker(6))
    F.watch()
    F.watch()
    check(#alertsOf(boss) == 1, "只出現一輪的、本 MOD 標記的：都不提示")
    piece:setOwner("mallory2")
    F.watch()
    F.watch()
    check(#alertsOf(boss) == 1, "本 MOD 的原生被改掉屋主、連兩輪都沒換回：不當成多了原版屋")
    SafeHouse.removeSafeHouse(fresh)

    -- ===== 客戶端 =====
    MSH = T.bootClient()
    local M, C, E = MSH.Mirror, MSH.Client, MSH.Entry
    local me = T.player({ name = "boss", admin = true })
    -- 原本是 nil 的全域也要還原（不能放進 table 再 pairs：nil 值的鍵不在 table 裡）
    local G = { "getText", "MinidoracatUI", "ISUIElement", "getTextManager", "ISSafehouseUI" }
    local saved = {}
    for _, k in ipairs(G) do saved[k] = _G[k] end
    local function count(owner, x)
        local n = 0
        for _, h in ipairs(T.houses) do
            if h.owner == owner and (x == nil or h.x == x) then n = n + 1 end
        end
        return n
    end
    local function serverCmd(command, a2) T.fire("OnServerCommand", MSH.MODULE, command, a2) end

    local ok, err = pcall(function()
        T.section("Foreign：客戶端移除（Mirror foreignRemove）")
        SafeHouse.addSafeHouse(10700, 9824, 8, 8, "zed")
        SafeHouse.addSafeHouse(10800, 9824, 8, 8, "zed")         -- 同屋主、別的範圍
        SafeHouse.addSafeHouse(10700, 9824, 8, 8, "amy")         -- 同範圍、別的屋主
        SafeHouse.addSafeHouse(10700, 9824, 8, 8, MSH.marker(1)) -- 同範圍的本 MOD 屋
        serverCmd("foreignRemove", { x = 10700, y = 9824, w = 8, h = 8 })
        check(#T.houses == 4, "缺屋主的推送不動任何一間")
        serverCmd("foreignRemove", { x = 10700, y = 9824, w = 8, h = 8, owner = "zed" })
        check(count("zed", 10700) == 0 and count("zed", 10800) == 1 and count("amy") == 1 and count(MSH.marker(1)) == 1,
            "只移除範圍與屋主都相同的那間")
        T.advance(30000)
        SafeHouse.addSafeHouse(10700, 9824, 8, 8, "zed")         -- 晚到的舊 SafehouseSync
        T.fire("OnSafehousesChanged")
        check(count("zed", 10700) == 0 and count("amy") == 1, "tombstone 期間加回來的被再移除")
        T.advance(31000)
        SafeHouse.addSafeHouse(10700, 9824, 8, 8, "zed")
        T.fire("OnSafehousesChanged")
        local left = 0
        for _ in pairs(M.ftombs) do left = left + 1 end
        check(count("zed", 10700) == 1 and left == 0, "tombstone 過期：不再移除、丟掉紀錄")

        T.section("Foreign：管理員提示（Client alert）")
        local toasts, heard = {}, {}
        MinidoracatUI = { v1 = { API_MAJOR = 1, API_REVISION = 17, CAPABILITIES = { toast = true },
            Toast = { show = function(o) toasts[#toasts + 1] = o end } } }
        local known = { IGUI_MSH_Alert_FOREIGN_APPEARED = true, IGUI_MSH_Alert_Generic = true, IGUI_MSH_Alert_Title = true }
        getText = function(k, ...)
            if not known[k] then return k end
            local t = {}
            for i, v in ipairs({ ... }) do t[i] = tostring(v) end
            return k .. "(" .. table.concat(t, ",") .. ")"
        end
        C.on("alert", "t_foreign", function(a2) heard[#heard + 1] = a2 end)
        serverCmd("alert", { code = "FOREIGN_APPEARED", detail = "2" })
        check(#toasts == 1 and toasts[1].message == "IGUI_MSH_Alert_FOREIGN_APPEARED(2)"
            and toasts[1].title == "IGUI_MSH_Alert_Title()" and toasts[1].maxLines == 5,
            "認得的碼：照碼的句子（帶 detail）、標題、最多 5 行（兩句，3 行在 ES、DE 放不下）")
        check(#heard == 1 and heard[1].code == "FOREIGN_APPEARED", "發 Client 事件 alert（開著的管理員面板重抓）")
        serverCmd("alert", { code = "SOMETHING_NEW" })
        check(#toasts == 2 and toasts[2].message == "IGUI_MSH_Alert_Generic(SOMETHING_NEW)", "不認得的碼：通用句帶碼")
        C.off("alert", "t_foreign")
        getText = saved.getText

        T.section("Foreign：原版安全屋清單的本 MOD 列（Entry）")
        local drawn = {}
        ISUIElement = { drawText = function(self, s, x, y, r) drawn[#drawn + 1] = { s = s, x = x, r = r } end }
        getTextManager = function() return { MeasureStringX = function(_, _, s) return #s * 7 end } end
        getText = function(k, ...)
            local t = {}
            for i, v in ipairs({ ... }) do t[i] = tostring(v) end
            return #t == 0 and k or (k .. "(" .. table.concat(t, ",") .. ")")
        end
        local ListClass = {}
        ListClass.__index = ListClass
        function ListClass:drawText(s, x, y, r) drawn[#drawn + 1] = { s = s, x = x, r = r, vanilla = true } end
        -- 原版 drawDatas 的那一次 drawText（ISSafehousesList.lua:81）
        local function vanillaDraw(self, y, item)
            local h = item.item
            self:drawText(h:getTitle() .. " - " .. getText("IGUI_FactionUI_FactionsListPlayers", h:getPlayers():size() + 1,
                h:getOwner()), 10, y + 2, 1, 1, 1, 0.9, self.font)
            return y + self.itemheight
        end
        local function house(x, owner, title, players)
            local h = T.house(x, 0, 5, 5, owner)
            h.title = title
            for _, u in ipairs(players) do h:addPlayer(u) end
            return h
        end
        local h1 = house(0, MSH.marker(1), "Home", { "test" })
        local h2a = house(10, MSH.marker(2), "L", { "kim", MSH.marker(2) })   -- 重開後 load 留在名單裡的標記
        local h2b = house(20, MSH.marker(2), "L", { "kim" })
        local hz = house(30, "zed", "Zed", {})
        local h3 = house(40, MSH.marker(3), "Amy", { "amy" })
        local list = setmetatable({ font = "NewSmall", itemheight = 20, items = {} }, ListClass)
        for i, h in ipairs({ h1, h2a, h2b, hz, h3 }) do list.items[i] = { item = h, index = i } end
        MSH.PublicApi.names[MSH.marker(1)], MSH.PublicApi.names[MSH.marker(2)] = "test", "kim"
        E.markRows({ datas = list })
        check(list.items[1].mshId == 1 and list.items[4].mshId == false and list.items[2].mshPiece == 1
            and list.items[3].mshPiece == 2 and list.items[3].mshPieces == 2 and list.items[1].mshPieces == 1,
            "重排後標出本 MOD 的列與第幾塊")
        local y = E.listRow(list, 0, list.items[1], false, vanillaDraw)
        check(y == 20 and #drawn == 2 and drawn[1].s == "Home - IGUI_FactionUI_FactionsListPlayers(1,test)"
            and drawn[2].s == "IGUI_MSH_Entry_ListTag" and drawn[2].r == E.MUTED and drawn[2].x == 10 + (#drawn[1].s + 1) * 7,
            "本 MOD 的屋：真正屋主、名單人數（不加 1），後面接淡色的「本 MOD」")
        check(rawget(list, "drawText") == nil, "畫完把清單的 drawText 還原成原版")
        drawn = {}
        E.listRow(list, 20, list.items[2], false, vanillaDraw)
        check(drawn[1].s == "L - IGUI_FactionUI_FactionsListPlayers(1,kim)" and drawn[2].s == "IGUI_MSH_Entry_ListPiece(1,2)",
            "名單裡的服務帳號不算人數；多塊的屋寫第幾塊")
        drawn = {}
        E.listRow(list, 60, list.items[4], false, vanillaDraw)
        check(#drawn == 1 and drawn[1].vanilla and drawn[1].s == "Zed - IGUI_FactionUI_FactionsListPlayers(1,zed)",
            "原版屋照原版畫")
        drawn = {}
        E.listRow(list, 80, list.items[5], false, vanillaDraw)
        check(#drawn == 1 and drawn[1].vanilla and list.items[5].mshText == nil, "屋主名還沒查到：先照原版畫、不存字")
        MSH.PublicApi.names[MSH.marker(3)] = "amy"
        drawn = {}
        E.listRow(list, 80, list.items[5], false, vanillaDraw)
        check(drawn[1].s == "Amy - IGUI_FactionUI_FactionsListPlayers(1,amy)", "查到之後下一次畫就改寫")
        y = E.listRow(list, 0, list.items[1], false, function() error("boom") end)
        check(y == 20 and rawget(list, "drawText") == nil, "原版畫列丟錯：照樣還原 drawText、回下一列的 y")
        MSH.PublicApi.onReceive(MSH.TAG, { claims = { [1] = { claimId = 1, owner = "newowner" },
            [2] = { claimId = 2, owner = "kim" }, [3] = { claimId = 3, owner = "amy" } } })
        drawn = {}
        E.listRow(list, 0, list.items[1], false, vanillaDraw)
        check(drawn[1].s == "Home - IGUI_FactionUI_FactionsListPlayers(1,newowner)",
            "屋主對照換新（例：重新綁定）：下一次畫就換成新屋主")
        local function other(_, s) drawn[#drawn + 1] = { s = s, other = true } end
        list.drawText = other
        drawn = {}
        E.listRow(list, 0, list.items[1], false, vanillaDraw)
        check(rawget(list, "drawText") == other and #drawn == 2 and drawn[1].other and drawn[2].other,
            "其他 MOD 替清單設的 drawText：本 MOD 的字也經過它，畫完還給它")
        list.drawText = nil
        getText = saved.getText

        T.section("Foreign：管理員〔檢視〕別人的屋（Entry.safehouseUIAdd）")
        local opened, apOpened, admin = {}, {}, true
        local realMW, realAP = MSH.ManagerWindow, MSH.AdminPanel
        MSH.ManagerWindow = { open = function(o) opened[#opened + 1] = o end }
        MSH.AdminPanel = { isAdmin = function() return admin end, open = function(o) apOpened[#apOpened + 1] = o end }
        ISSafehouseUI = {}
        local function shown() end
        E.safehouseUIAdd({ safehouse = h2a }, shown)
        check(#apOpened == 1 and apOpened[1].tab == "players" and apOpened[1].player == "kim" and #opened == 0,
            "管理員、名單裡沒有自己：開管理員面板的玩家頁，搜尋屋主")
        h1:addPlayer(me.name)
        E.safehouseUIAdd({ safehouse = h1 }, shown)
        check(#opened == 1 and opened[1].claimId == 1 and #apOpened == 1, "自己在名單裡（屋主或成員）：照舊開管理視窗")
        admin = false
        E.safehouseUIAdd({ safehouse = h2a }, shown)
        check(#opened == 2 and opened[2].claimId == 2 and #apOpened == 1, "不是管理員：照舊開管理視窗")
        admin = true
        E.safehouseUIAdd({ safehouse = house(50, MSH.marker(9), "?", {}) }, shown)
        check(#apOpened == 2 and apOpened[2].player == nil, "屋主名還沒查到：只開玩家頁")
        MSH.ManagerWindow, MSH.AdminPanel = realMW, realAP
    end)
    for _, k in ipairs(G) do _G[k] = saved[k] end
    if not ok then error(err, 0) end
end
