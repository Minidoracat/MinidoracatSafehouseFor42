-- Sharing：指定玩家與陣營分享、MANAGE 限制、上限、撤銷、陣營暫停與恢復、round-robin 同步、
-- 清單與詳細的分享欄位、和 Reconcile 收斂不互相拉扯（計畫 §4.2 第 212-213／238 行、§4.4、§6.4、§6.5）。
return function(T)
    local check = T.check
    local MSH, R
    local MEMBER, USE, BUILD, MANAGE = 1, 2, 8, 32

    local function boot(opts)
        MSH = T.boot(opts)
        R = MSH.Registry
        return MSH
    end
    local function rect(x, y, w, h) return { x = x, y = y, w = w, h = h } end
    -- 直接放一筆 active 紀錄＋原生（不經建立指令）
    local function seed(owner, r)
        local id = R.allocId()
        local rec = R.newRecord({ claimId = id, rect = r, title = "t", owner = owner, source = MSH.SOURCE.DEED,
            deedTier = 1, createdAt = T.now })
        local hs = MSH.Native.build(rec)
        rec.nativeCreatedAt = hs:getDatetimeCreated()
        R.put(rec)
        return rec, hs
    end
    local function has(hs, u) return hs.players:contains(u) end
    local function cmd(p, command, rec, args)
        args = args or {}
        args.claimId = rec.claimId
        if args.expectedRevision == nil and command ~= "leave" then args.expectedRevision = rec.revision end
        return T.cmd(p, command, args)
    end
    local function code(res) return res and res.code end
    local function pushed(p, claimId)
        local c = T.lastOf(p, "changed")
        return c ~= nil and c.claimId == claimId
    end
    local function clearBoxes()
        for k in pairs(T.outbox) do T.outbox[k] = {} end
    end
    local function teleported(name)
        for _, t in ipairs(T.teleports) do if t.name == name then return true end end
        return false
    end
    local function listRow(p, claimId)
        local res = T.cmd(p, "list", {})
        for _, row in ipairs(res.claims or {}) do if row.claimId == claimId then return row end end
        return nil
    end
    local function names(n, prefix)
        local out = {}
        for i = 1, n do out[i] = prefix .. i end
        return out
    end

    T.section("指定玩家：屋主分享、revision、名單、changed 推送、放鎖後才廣播")
    boot()
    local alice = T.player({ name = "alice", x = 5, y = 5 })
    local bob = T.player({ name = "bob", x = 500, y = 500 })
    local carol = T.player({ name = "carol", x = 500, y = 500 })
    local dave = T.player({ name = "dave", x = 500, y = 500 })
    local eve = T.player({ name = "eve", x = 500, y = 500 })
    local rec, hs = seed("alice", rect(100, 100, 10, 10))
    local rev0 = rec.revision
    local lockedAt = {}
    local origBroadcast = MSH.Native.broadcast
    MSH.Native.broadcast = function(h)
        lockedAt[#lockedAt + 1] = MSH.Srv.locked
        return origBroadcast(h)
    end
    local res = cmd(alice, "share", rec, { targetUsername = "bob", bits = USE })
    MSH.Native.broadcast = origBroadcast
    check(res.ok and res.revision == rev0 + 1 and rec.revision == rev0 + 1, "分享成功、revision＋1")
    local g = MSH.Claims.grantOf(rec, "bob")
    check(g ~= nil and g.bits == USE + MEMBER, "帶 USE 自動加 MEMBER")
    check(has(hs, "bob"), "原生名單加入 bob")
    check(#lockedAt == 1 and lockedAt[1] == false, "原生廣播在放鎖之後")
    check(pushed(bob, rec.claimId) and pushed(alice, rec.claimId), "changed 推給目標與屋主")
    check(not pushed(eve, rec.claimId), "無關的人不推送")
    check(code(cmd(alice, "share", rec, { targetUsername = "carol", bits = USE, expectedRevision = rev0 }))
        == "STALE_REVISION", "舊 revision：STALE_REVISION")
    check(code(cmd(alice, "share", rec, { targetUsername = "alice", bits = USE })) == "BAD_USER", "分享給屋主自己：BAD_USER")
    check(code(cmd(alice, "share", rec, { targetUsername = "carol", bits = 0 })) == "BAD_ARGS", "位元 0：BAD_ARGS")
    check(code(cmd(alice, "share", rec, { targetUsername = "bad\nname", bits = 1 })) == "BAD_ARGS", "名字含控制字元：BAD_ARGS")
    check(code(cmd(eve, "share", rec, { targetUsername = "carol", bits = 1 })) == "NOT_FOUND", "沒有角色：NOT_FOUND")
    check(code(cmd(bob, "share", rec, { targetUsername = "carol", bits = 1 })) == "NOT_OWNER", "沒有 MANAGE 的成員：NOT_OWNER")
    res = cmd(alice, "share", rec, { targetUsername = "bob", bits = BUILD })
    check(res.ok and MSH.Claims.grantOf(rec, "bob").bits == BUILD + MEMBER and #rec.grants == 1, "既有分享改位元、不重複")
    rec.lifecycle = "lapsed"
    check(code(cmd(alice, "share", rec, { targetUsername = "carol", bits = 1 })) == "WRONG_LIFECYCLE", "不是 active：WRONG_LIFECYCLE")
    rec.lifecycle = "active"

    T.section("MANAGE 成員：不能給 MANAGE、不能動 MANAGE 持有者／屋主／自己")
    check(cmd(alice, "share", rec, { targetUsername = "carol", bits = MANAGE }).ok
        and MSH.Claims.grantOf(rec, "carol").bits == MANAGE + MEMBER, "屋主給 carol MANAGE")
    check(code(cmd(carol, "share", rec, { targetUsername = "dave", bits = USE })) == "NOT_OWNER" and not has(hs, "dave"),
        "MANAGE 成員給自己沒有的位元（USE）：NOT_OWNER")
    check(cmd(carol, "share", rec, { targetUsername = "dave", bits = MEMBER }).ok and has(hs, "dave"),
        "MANAGE 成員給自己有的位元（MEMBER）可以")
    check(cmd(alice, "share", rec, { targetUsername = "carol", bits = MANAGE + USE + BUILD }).ok, "屋主給 carol MANAGE＋USE＋BUILD")
    check(cmd(carol, "share", rec, { targetUsername = "dave", bits = USE + BUILD }).ok
        and MSH.Claims.grantOf(rec, "dave").bits == USE + BUILD + MEMBER, "MANAGE 成員給自己有的 USE＋BUILD 可以")
    check(cmd(carol, "share", rec, { targetUsername = "dave", bits = USE }).ok
        and MSH.Claims.grantOf(rec, "dave").bits == USE + MEMBER, "MANAGE 成員拿掉位元可以")
    check(cmd(alice, "share", rec, { targetUsername = "carol", bits = MANAGE }).ok, "屋主把 carol 降回 MEMBER＋MANAGE")
    check(code(cmd(carol, "share", rec, { targetUsername = "dave", bits = USE })) == "NOT_OWNER",
        "降級後連「維持 USE」也不行（新位元仍須是子集）")
    check(code(cmd(carol, "share", rec, { targetUsername = "dave", bits = MANAGE })) == "NOT_OWNER", "不能給 MANAGE")
    check(cmd(alice, "share", rec, { targetUsername = "erin", bits = MANAGE }).ok, "屋主給 erin MANAGE")
    check(code(cmd(carol, "share", rec, { targetUsername = "erin", bits = USE })) == "NOT_OWNER", "不能改 MANAGE 持有者")
    check(code(cmd(carol, "unshare", rec, { targetUsername = "erin" })) == "NOT_OWNER", "不能移除 MANAGE 持有者")
    check(code(cmd(carol, "unshare", rec, { targetUsername = "alice" })) == "BAD_USER", "不能動屋主")
    check(code(cmd(carol, "unshare", rec, { targetUsername = "carol" })) == "BAD_USER", "不能動自己")
    check(code(cmd(carol, "share", rec, { targetUsername = "carol", bits = USE })) == "BAD_USER", "不能改自己")
    check(code(cmd(carol, "shareFaction", rec, { bits = USE })) == "NOT_OWNER", "MANAGE 成員不能分享給陣營")
    check(code(cmd(alice, "unshare", rec, { targetUsername = "zed" })) == "BAD_USER", "不在名單：BAD_USER")
    check(cmd(carol, "unshare", rec, { targetUsername = "dave" }).ok and not has(hs, "dave"), "MANAGE 成員可移除一般成員")

    T.section("上限：SHARE_FULL、REGISTRY_FULL 預檢、ROSTER_FULL")
    T.sandbox("MaxShares", #rec.grants)
    local before = #rec.grants
    check(code(cmd(alice, "share", rec, { targetUsername = "dave", bits = 1 })) == "SHARE_FULL" and #rec.grants == before,
        "新增後超過 MaxShares：SHARE_FULL、名單不變")
    check(cmd(alice, "share", rec, { targetUsername = "bob", bits = USE }).ok, "滿了仍可改既有分享的位元")
    T.sandbox("MaxShares", 8)
    local saved = MSH.LIMIT.REGISTRY_BYTES
    MSH.LIMIT.REGISTRY_BYTES = R.estimateBytes() + 5
    local revB = rec.revision
    check(code(cmd(alice, "share", rec, { targetUsername = "dave", bits = 1 })) == "REGISTRY_FULL"
        and #rec.grants == before and rec.revision == revB, "寫入後超過 registry 上限：REGISTRY_FULL、沒有寫入")
    MSH.LIMIT.REGISTRY_BYTES = saved
    saved = MSH.LIMIT.NATIVE_NAMES
    MSH.LIMIT.NATIVE_NAMES = #MSH.Native.desiredPlayers(rec)
    check(code(cmd(alice, "share", rec, { targetUsername = "dave", bits = 1 })) == "ROSTER_FULL" and not has(hs, "dave"),
        "原生名字總數超過上限：ROSTER_FULL")
    MSH.LIMIT.NATIVE_NAMES = saved

    T.section("陣營分享：投影成員、位元聯集、清單與詳細")
    boot()
    alice = T.player({ name = "alice", x = 5, y = 5 })
    bob = T.player({ name = "bob", x = 500, y = 500 })
    local fred = T.player({ name = "fred", x = 105, y = 105 })
    local gina = T.player({ name = "gina", x = 500, y = 500 })
    eve = T.player({ name = "eve", x = 500, y = 500 })
    rec, hs = seed("alice", rect(100, 100, 10, 10))
    local wolves = T.faction("Wolves", "gina", { "alice", "bob", "fred" })
    T.sandbox("AllowFactionShare", false)
    check(code(cmd(alice, "shareFaction", rec, { bits = USE })) == "FACTION_DISABLED", "全服關閉：FACTION_DISABLED")
    T.sandbox("AllowFactionShare", true)
    check(code(cmd(eve, "shareFaction", seed("eve", rect(300, 300, 5, 5)), { bits = USE })) == "NO_FACTION",
        "屋主不在任何陣營：NO_FACTION")
    local longName = T.faction(string.rep("x", 65), "eve2", { "eve3" })
    local evHouse = seed("eve3", rect(400, 400, 5, 5))
    check(code(cmd(T.player({ name = "eve3" }), "shareFaction", evHouse, { bits = USE })) == "BAD_FACTION",
        "陣營名稱超過 64 bytes：BAD_FACTION")
    T.disband(longName)
    check(cmd(alice, "share", rec, { targetUsername = "bob", bits = BUILD }).ok, "bob 另有 grant（BUILD）")
    clearBoxes()
    res = cmd(alice, "shareFaction", rec, { bits = USE })
    local fs = rec.factionShare
    check(res.ok and fs.name == "Wolves" and fs.leader == "gina" and fs.bits == USE + MEMBER and fs.state == "GRANTED",
        "綁屋主目前的陣營與當下領袖")
    check(has(hs, "gina") and has(hs, "fred") and has(hs, "bob"), "領袖與成員投影進原生名單")
    check(pushed(fred, rec.claimId) and pushed(gina, rec.claimId), "新取得資格的陣營成員收到 changed")
    local row = listRow(fred, rec.claimId)
    check(row ~= nil and row.actorRole == "member" and row.bits == USE + MEMBER and row.owner == "alice",
        "只靠陣營的人在清單裡（分享給我的）")
    row = listRow(bob, rec.claimId)
    check(row ~= nil and row.bits == BUILD + USE + MEMBER, "grant 與陣營位元取聯集")
    check(listRow(eve, rec.claimId) == nil, "無關的人清單裡沒有")
    local d = T.cmd(alice, "detail", { claimId = rec.claimId })
    check(d.ok and #d.grants == 1 and d.grants[1].user == "bob" and d.factionShare.name == "Wolves"
        and d.factionShare.members == 4 and d.factionShare.projected == true and d.factionShare.state == "GRANTED"
        and d.factionShare.reason == nil, "detail：grants 與 factionShare")
    check(d.grants[1].effBits == BUILD + USE + MEMBER, "detail：grants 每列帶 effBits（grant 與陣營位元的聯集）")
    check(d.actions.canManageShares and d.actions.canShareFaction and not d.actions.canResumeFaction
        and not d.actions.canLeave and d.limits.maxShares == 8 and d.limits.allowFactionShare == true,
        "detail：屋主的 actions 與 limits")
    d = T.cmd(bob, "detail", { claimId = rec.claimId })
    check(d.ok and d.actions.canLeave and not d.actions.canManageShares and not d.actions.canShareFaction,
        "detail：成員可離開、不能管理")
    d = T.cmd(fred, "detail", { claimId = rec.claimId })
    check(d.ok and not d.actions.canLeave, "detail：只靠陣營的人沒有〔離開〕")

    T.section("撤銷只撤銷沒有其他資格的人")
    check(cmd(alice, "unshare", rec, { targetUsername = "bob" }).ok and has(hs, "bob") and not teleported("bob"),
        "移除 bob 的 grant：仍是陣營成員，名單保留")
    check(cmd(alice, "share", rec, { targetUsername = "bob", bits = BUILD }).ok, "bob 的 grant 加回")
    local dave2 = T.player({ name = "dave", x = 103, y = 103 })
    check(cmd(alice, "share", rec, { targetUsername = "dave", bits = USE }).ok and has(hs, "dave"), "dave 只有 grant")
    T.teleports = {}
    local revokeLocked = {}
    local origRevoke = MSH.Native.revoke
    MSH.Native.revoke = function(h, u)
        revokeLocked[#revokeLocked + 1] = MSH.Srv.locked
        return origRevoke(h, u)
    end
    res = cmd(alice, "unshare", rec, { targetUsername = "dave" })
    MSH.Native.revoke = origRevoke
    check(res.ok and not has(hs, "dave") and teleported("dave") and pushed(dave2, rec.claimId),
        "移除只有 grant 的 dave：撤銷、人在屋內傳出、收到 changed")
    check(#revokeLocked == 1 and revokeLocked[1] == false, "撤銷（kick 廣播）在放鎖之後")

    T.section("round-robin 同步：入會、退會（≤ 2 秒）")
    local hank = T.player({ name = "hank", x = 104, y = 104 })
    wolves.players:add("hank")
    T.tick(20)
    check(has(hs, "hank"), "新成員 2 秒內進原生名單")
    wolves.players:remove("hank")
    T.teleports = {}
    clearBoxes()
    T.tick(20)
    check(not has(hs, "hank") and teleported("hank") and pushed(hank, rec.claimId), "退會的人 2 秒內撤銷並傳出屋內")

    T.section("陣營暫停：領袖換人、解散、屋主退出、同進程同名重建")
    local syncs = #T.syncs
    T.teleports = {}
    clearBoxes()
    wolves:setOwner("fred")
    T.tick(20)
    check(fs.state == "SUSPENDED" and fs.reason == "LEADER_CHANGED", "領袖換人 → SUSPENDED、reason LEADER_CHANGED")
    check(not has(hs, "fred") and not has(hs, "gina") and teleported("fred"), "只靠陣營的人撤銷（屋內的傳出）")
    check(has(hs, "bob") and not teleported("bob"), "同時有 grant 的人保留")
    check(pushed(alice, rec.claimId) and pushed(fred, rec.claimId), "暫停後推送屋主與被撤銷的人")
    check(#T.syncs > syncs, "撤銷有廣播")
    d = T.cmd(alice, "detail", { claimId = rec.claimId })
    check(d.factionShare.state == "SUSPENDED" and d.factionShare.reason == "LEADER_CHANGED" and d.actions.canResumeFaction
        and d.factionShare.projected == false, "detail：暫停原因與〔恢復〕")
    check(listRow(fred, rec.claimId) == nil, "暫停後只靠陣營的人清單裡沒有")
    local revS = rec.revision
    T.tick(20)
    check(rec.revision == revS, "暫停只寫一次（不重複 touch）")

    T.section("恢復：重綁目前領袖；不在陣營 NO_FACTION；陣營不在 FACTION_GONE")
    check(code(cmd(bob, "resumeFaction", rec)) == "NOT_OWNER", "成員不能恢復")
    res = cmd(alice, "resumeFaction", rec)
    check(res.ok and fs ~= rec.factionShare and rec.factionShare.state == "GRANTED" and rec.factionShare.leader == "fred"
        and rec.factionShare.bits == USE + MEMBER and rec.factionShare.reason == nil, "恢復：重綁新領袖、位元沿用")
    fs = rec.factionShare
    check(has(hs, "fred") and has(hs, "gina"), "恢復後成員回到原生名單")
    wolves.players:remove("alice")
    T.tick(20)
    check(fs.state == "SUSPENDED" and fs.reason == "OWNER_LEFT" and not has(hs, "fred") and has(hs, "bob"),
        "屋主退出陣營 → OWNER_LEFT、只靠陣營的人撤銷")
    check(code(cmd(alice, "resumeFaction", rec)) == "NO_FACTION", "屋主不在該陣營：NO_FACTION")
    wolves.players:add("alice")
    check(cmd(alice, "resumeFaction", rec).ok, "回到陣營後可恢復")
    fs = rec.factionShare
    T.disband(wolves)
    T.tick(20)
    check(fs.state == "SUSPENDED" and fs.reason == "GONE" and not has(hs, "fred"), "解散 → GONE")
    check(code(cmd(alice, "resumeFaction", rec)) == "FACTION_GONE", "陣營不在：FACTION_GONE")
    wolves = T.faction("Wolves", "fred", { "alice", "gina" })
    check(cmd(alice, "resumeFaction", rec).ok and has(hs, "gina"), "同名陣營重新出現：可恢復")
    fs = rec.factionShare
    T.disband(wolves)
    wolves = T.faction("Wolves", "fred", { "alice", "gina" })
    T.tick(20)
    check(fs.state == "SUSPENDED" and fs.reason == "GONE", "同進程內解散後同名同領袖重建（物件不同）→ GONE")

    T.section("停止陣營分享：MANAGE 成員可以")
    check(cmd(alice, "resumeFaction", rec).ok and has(hs, "gina"), "恢復")
    check(cmd(alice, "share", rec, { targetUsername = "carol", bits = MANAGE }).ok, "carol 有 MANAGE")
    local carol2 = T.player({ name = "carol" })
    T.teleports = {}
    res = cmd(carol2, "unshareFaction", rec)
    check(res.ok and rec.factionShare == nil and not has(hs, "gina") and not has(hs, "fred") and has(hs, "bob"),
        "MANAGE 成員停止陣營分享：只靠陣營的人撤銷、grant 保留")
    check(code(cmd(alice, "unshareFaction", rec)) == "BAD_USER", "沒有陣營分享：BAD_USER")

    T.section("離開")
    T.disband(wolves)                                   -- 一人只在一個陣營
    T.faction("Bears", "alice", { "bob", "ivan" })
    check(cmd(alice, "shareFaction", rec, { bits = USE }).ok and rec.factionShare.name == "Bears", "改分享給 Bears")
    res = cmd(bob, "leave", rec)
    check(res.ok and res.viaFaction == true and MSH.Claims.grantOf(rec, "bob") == nil and has(hs, "bob"),
        "有 grant 也在陣營：移除 grant、viaFaction、名單保留")
    check(code(cmd(bob, "leave", rec)) == "BAD_USER", "只靠陣營：沒有 grant 可離開 BAD_USER")
    check(code(cmd(alice, "leave", rec)) == "BAD_USER", "屋主不能離開")
    check(code(cmd(eve, "leave", rec)) == "NOT_FOUND", "沒有角色：NOT_FOUND")
    local jack = T.player({ name = "jack", x = 106, y = 106 })
    check(cmd(alice, "share", rec, { targetUsername = "jack", bits = USE }).ok, "jack 只有 grant")
    T.teleports = {}
    res = cmd(jack, "leave", rec)
    check(res.ok and res.viaFaction == nil and not has(hs, "jack") and teleported("jack"), "只有 grant：離開即撤銷")

    T.section("陣營 > 64 人：照存、不投影、FACTION_TOO_LARGE")
    boot()
    alice = T.player({ name = "alice", x = 5, y = 5 })
    rec, hs = seed("alice", rect(100, 100, 10, 10))
    local big = names(64, "m")
    big[#big + 1] = "alice"
    local horde = T.faction("Horde", "boss", big)      -- 領袖＋64 人＝66
    res = cmd(alice, "shareFaction", rec, { bits = USE })
    check(res.ok and rec.factionShare.state == "GRANTED", "照存")
    check(not has(hs, "m1") and not has(hs, "boss") and hs.players:size() == 1, "不投影進原生名單（不截斷）")
    check(MSH.Claims.roleOf(rec, "m1") == nil, "沒投影的陣營成員沒有角色")
    check(MSH.Claims.healthSummary(rec) == "FACTION_TOO_LARGE", "healthSummary：FACTION_TOO_LARGE")
    d = T.cmd(alice, "detail", { claimId = rec.claimId })
    check(d.healthSummary == "FACTION_TOO_LARGE" and d.factionShare.members == 66 and d.factionShare.projected == false,
        "detail：人數與未投影")
    horde.players:remove("m1")
    horde.players:remove("m2")
    T.tick(20)
    check(has(hs, "m3") and has(hs, "boss") and MSH.Claims.healthSummary(rec) == "PROTECTED", "降到 64 人：投影")

    T.section("Reconcile 與同步不互相拉扯")
    local adds, removes = 0, 0
    local origAdd, origRemove = hs.addPlayer, hs.removePlayer
    hs.addPlayer = function(self, u) adds = adds + 1 return origAdd(self, u) end
    hs.removePlayer = function(self, u) removes = removes + 1 return origRemove(self, u) end
    horde.players:add("n1")
    horde.players:remove("m3")
    T.tick(20)
    check(has(hs, "n1") and not has(hs, "m3"), "陣營變動後收斂")
    local snapshot = table.concat(hs.players._raw, ",")
    adds, removes = 0, 0
    syncs = #T.syncs
    T.tick(60)
    check(adds == 0 and removes == 0 and #T.syncs == syncs and table.concat(hs.players._raw, ",") == snapshot,
        "之後 6 秒內名單不再增減、不再廣播")
    horde:setOwner("m4")
    T.tick(20)
    adds, removes = 0, 0
    snapshot = table.concat(hs.players._raw, ",")
    T.tick(60)
    check(rec.factionShare.state == "SUSPENDED" and hs.players:size() == 1 and adds == 0 and removes == 0
        and table.concat(hs.players._raw, ",") == snapshot, "暫停後名單穩定")
    check(MSH.Reconcile.claimFlags[rec.claimId] == nil, "沒有干擾旗標")
    T.sandbox("AllowFactionShare", false)
    check(cmd(alice, "resumeFaction", rec).code == "FACTION_DISABLED", "全服關閉時不能恢復")
    T.sandbox("AllowFactionShare", true)
    hs.addPlayer, hs.removePlayer = origAdd, origRemove

    T.section("全服關閉 AllowFactionShare：停止投影但不暫停，重開即恢復")
    check(cmd(alice, "resumeFaction", rec).ok and has(hs, "boss"), "恢復")
    T.sandbox("AllowFactionShare", false)
    T.tick(20)
    check(rec.factionShare.state == "GRANTED" and not has(hs, "boss"), "關閉：不投影、仍是 GRANTED")
    T.sandbox("AllowFactionShare", true)
    T.tick(20)
    check(has(hs, "boss"), "重新開啟：投影回來")

    -- ROSTER_REMOVED 稽核行（Audit.write 以 tab 分欄：事件、actor、claimId、code、detail）
    local function notCanonical(user)
        for _, line in ipairs(T.logs) do
            if string.find(line, "ROSTER_REMOVED\t" .. user .. "\t", 1, true) and string.find(line, "NOT_CANONICAL", 1, true) then
                return true
            end
        end
        return false
    end

    T.section("Reconcile：分享撤掉的人不記 NOT_CANONICAL，原版加進來的陌生人照記")
    boot()
    alice = T.player({ name = "alice", x = 5, y = 5 })
    rec, hs = seed("alice", rect(100, 100, 10, 10))
    local otters = T.faction("Otters", "alice", { "kate", "liam" })
    check(cmd(alice, "shareFaction", rec, { bits = USE }).ok and has(hs, "kate"), "陣營分享投影 kate")
    -- 重現競態：Reconcile 的一輪（500 ms）比 Sharing 的輪檢（1 秒）先看到 desiredPlayers 變了
    otters.players:remove("kate")
    MSH.Reconcile.sweep(T.now)
    T.tick(20)
    check(not has(hs, "kate") and not notCanonical("kate"), "陣營成員退會那輪：撤銷、不記 NOT_CANONICAL")
    T.sandbox("AllowFactionShare", false)
    MSH.Reconcile.sweep(T.now)
    T.tick(20)
    check(not has(hs, "liam") and not notCanonical("liam"), "關閉 AllowFactionShare：撤銷、不記 NOT_CANONICAL")
    T.sandbox("AllowFactionShare", true)
    hs:addPlayer("stranger")                -- 原版成員封包加進來的人
    T.tick(20)
    check(not has(hs, "stranger") and notCanonical("stranger"), "原版加進來的陌生人：收掉並記 NOT_CANONICAL")

    T.section("身分：對既有安全屋的 mutation 才綁定（Steam 模式）")
    boot({ steam = true })
    local SID_A, SID_C, SID_X = 76561198000000001, 76561198000000003, 76561198000000099
    alice = T.player({ name = "alice", x = 5, y = 5, sid = SID_A })
    local carolS = T.player({ name = "carol", x = 500, y = 500, sid = SID_C })
    local mia = T.player({ name = "mia", x = 500, y = 500, sid = 76561198000000004 })
    rec, hs = seed("alice", rect(100, 100, 10, 10))
    rec.grants = { { user = "carol", bits = MEMBER + MANAGE }, { user = "mia", bits = MEMBER } }
    check(R.binding("carol") == nil, "前提：carol 沒綁定")
    check(T.cmd(mia, "list", {}).ok and T.cmd(mia, "detail", { claimId = rec.claimId }).ok
        and T.cmd(carolS, "list", {}).ok and R.binding("mia") == nil and R.binding("carol") == nil,
        "list／detail 不產生綁定")
    res = cmd(carolS, "share", rec, { targetUsername = "dave", bits = MEMBER })
    local b = R.binding("carol")
    check(res.ok and b ~= nil and b.sid == SID_C, "未綁定的 MANAGE 成員第一次 share：綁定")
    local impostor = T.player({ name = "carol", x = 500, y = 500, sid = SID_X })
    local grants = #rec.grants
    res = cmd(impostor, "unshare", rec, { targetUsername = "dave" })
    check(code(res) == "IDENTITY_UNVERIFIED" and #rec.grants == grants, "之後同名不同 SteamID：IDENTITY_UNVERIFIED、沒有改動")
    T.failWrites = true
    local nina = T.player({ name = "nina", x = 500, y = 500, sid = 76561198000000005 })
    rec.grants[#rec.grants + 1] = { user = "nina", bits = MEMBER }
    res = cmd(nina, "leave", rec)
    check(code(res) == "IDENTITY_UNVERIFIED" and MSH.Claims.grantOf(rec, "nina") ~= nil and T.logged("BIND_REFUSED"),
        "綁定寫不進去：IDENTITY_UNVERIFIED、寫 audit、沒有改動")
    T.failWrites = false
    local leo = T.player({ name = "leo", x = 500, y = 500, sid = 76561198000000006 })
    local legacy = seed("leo", rect(300, 300, 5, 5))
    legacy.source = MSH.SOURCE.LEGACY
    check(R.binding("leo") == nil, "前提：legacy 屋主沒綁定")
    res = T.cmd(leo, "preview", { rect = rect(300, 300, 5, 5), claimId = legacy.claimId })
    check(res ~= nil and R.binding("leo") == nil, "preview 帶 claimId（查詢，經過 Claims.owned）不綁定")
    res = T.cmd(leo, "release", { claimId = legacy.claimId, expectedRevision = legacy.revision })
    b = R.binding("leo")
    check(res.ok and b ~= nil and b.sid == 76561198000000006, "legacy 屋主第一次 release：綁定")

    T.section("停止分享後重開：原生存檔比 registry 舊、名單還有他，也不復活（計畫 §12.1 #15）")
    boot()
    local olga = T.player({ name = "olga", x = 5, y = 5 })
    T.player({ name = "pete", x = 500, y = 500 })
    local r15, h15 = seed("olga", rect(400, 400, 8, 8))
    check(cmd(olga, "share", r15, { targetUsername = "pete", bits = MEMBER }).ok and has(h15, "pete"), "分享給 pete")
    T.tick(2)
    check(cmd(olga, "unshare", R.get(r15.claimId), { targetUsername = "pete" }).ok and not has(h15, "pete"),
        "停止分享：原生名單移除")
    T.tick(2)
    h15:addPlayer("pete")   -- 崩潰組合：原生存檔停在停止分享之前，registry 已存下停止分享
    boot({ keepGmd = true, keepFiles = true, keepHouses = true })
    T.advance(1000)
    T.tick(2)
    local back = T.houseOf(MSH.marker(r15.claimId))
    check(back ~= nil and not back.players:contains("pete") and MSH.Claims.grantOf(R.get(r15.claimId), "pete") == nil,
        "重開：registry 沒有 grant，收斂把 pete 從原生名單拿掉、不從原生名單補回 grant")

    T.section("邀請（INVITE）：只能邀新人、位元受限；和管理分開")
    do
        local INVITE, MOVE = MSH.SHARE.INVITE, 4
        boot()
        local al = T.player({ name = "alice", x = 5, y = 5 })
        local ivy = T.player({ name = "ivy", x = 500, y = 500 })
        local max = T.player({ name = "max", x = 500, y = 500 })
        local fox1 = T.player({ name = "fox1", x = 500, y = 500 })
        local r, h = seed("alice", rect(100, 100, 10, 10))
        check(MSH.SHARE_ALL == 127 and INVITE == 64, "INVITE＝64、SHARE_ALL＝127")
        check(cmd(al, "share", r, { targetUsername = "ivy", bits = INVITE + USE }).ok
            and MSH.Claims.grantOf(r, "ivy").bits == INVITE + USE + MEMBER, "INVITE 自動帶 MEMBER")
        check(cmd(al, "share", r, { targetUsername = "bob", bits = MEMBER }).ok, "bob 是一般成員")
        check(cmd(ivy, "share", r, { targetUsername = "nora", bits = USE }).ok and has(h, "nora")
            and MSH.Claims.grantOf(r, "nora").bits == USE + MEMBER, "只有 INVITE：邀新人、給自己有的位元")
        check(code(cmd(ivy, "share", r, { targetUsername = "omar", bits = BUILD })) == "NOT_OWNER"
            and MSH.Claims.grantOf(r, "omar") == nil, "只有 INVITE：給自己沒有的位元被拒")
        check(code(cmd(ivy, "share", r, { targetUsername = "omar", bits = INVITE })) == "NOT_OWNER", "只有 INVITE：不能給 INVITE")
        check(code(cmd(ivy, "share", r, { targetUsername = "omar", bits = MANAGE })) == "NOT_OWNER", "只有 INVITE：不能給 MANAGE")
        check(code(cmd(ivy, "share", r, { targetUsername = "bob", bits = USE })) == "NOT_OWNER"
            and MSH.Claims.grantOf(r, "bob").bits == MEMBER, "只有 INVITE：改既有成員被拒")
        check(code(cmd(ivy, "share", r, { targetUsername = "nora", bits = MEMBER })) == "NOT_OWNER",
            "只有 INVITE：自己邀的人也不能再改")
        check(code(cmd(ivy, "unshare", r, { targetUsername = "bob" })) == "NOT_OWNER" and has(h, "bob"),
            "只有 INVITE：unshare 被拒")
        local foxes = T.faction("Foxes", "alice", { "fox1" })
        check(cmd(al, "shareFaction", r, { bits = USE }).ok, "陣營分享")
        check(code(cmd(ivy, "unshareFaction", r)) == "NOT_OWNER" and r.factionShare ~= nil,
            "只有 INVITE：unshareFaction 被拒")
        check(code(cmd(ivy, "shareFaction", r, { bits = USE })) == "NOT_OWNER", "只有 INVITE：shareFaction 被拒")
        check(cmd(al, "share", r, { targetUsername = "max", bits = MANAGE + USE }).ok, "max 有 MANAGE＋USE（沒有 INVITE）")
        check(cmd(max, "share", r, { targetUsername = "pia", bits = INVITE + USE }).ok
            and MSH.Claims.grantOf(r, "pia").bits == INVITE + USE + MEMBER, "MANAGE 成員能給 INVITE")
        check(cmd(max, "share", r, { targetUsername = "ivy", bits = USE }).ok
            and MSH.Claims.grantOf(r, "ivy").bits == USE + MEMBER, "MANAGE 成員能拿掉別人的 INVITE")
        check(code(cmd(max, "share", r, { targetUsername = "pia", bits = MOVE })) == "NOT_OWNER",
            "MANAGE 成員仍只能給自己有的一般位元")
        check(cmd(al, "share", r, { targetUsername = "quinn", bits = MSH.SHARE_ALL }).ok
            and MSH.Claims.grantOf(r, "quinn").bits == 127, "屋主能給全部位元")
        local pia = T.player({ name = "pia", x = 500, y = 500 })
        check(cmd(pia, "share", r, { targetUsername = "rex", bits = USE }).ok and has(h, "rex"),
            "只有 INVITE：邀沒有任何資格的人可以")
        check(code(cmd(pia, "share", r, { targetUsername = "fox1", bits = USE })) == "NOT_OWNER"
            and MSH.Claims.grantOf(r, "fox1") == nil, "只有 INVITE：不能邀只靠陣營的成員（不替既有成員加權限）")
        local revF = r.revision
        check(code(cmd(al, "shareFaction", r, { bits = USE + INVITE })) == "BAD_ARGS"
            and code(cmd(al, "shareFaction", r, { bits = USE + MANAGE })) == "BAD_ARGS" and r.revision == revF
            and r.factionShare.bits == USE + MEMBER, "陣營分享帶 INVITE／MANAGE：BAD_ARGS、沒有改動")
        r.factionShare.bits = MEMBER + USE + MANAGE + INVITE   -- 舊資料
        local _, foxBits = MSH.Claims.roleOf(r, "fox1")
        check(foxBits == USE + MEMBER, "舊資料裡陣營的 MANAGE／INVITE 不給權限")
        check(code(cmd(fox1, "share", r, { targetUsername = "sam", bits = MEMBER })) == "NOT_OWNER"
            and code(cmd(fox1, "unshare", r, { targetUsername = "rex" })) == "NOT_OWNER", "舊資料：陣營成員不能邀人、不能移除")
        local dv = T.cmd(al, "detail", { claimId = r.claimId })
        check(dv.factionShare.bits == USE + MEMBER, "detail 的陣營位元也遮掉")
        r.factionShare.state = "SUSPENDED"
        check(cmd(al, "resumeFaction", r).ok and r.factionShare.bits == USE + MEMBER, "恢復時遮掉舊資料的 MANAGE／INVITE")
        local want = {}
        for _, u in ipairs(MSH.Native.desiredPlayers(r)) do want[u] = true end
        local same = h.players:size() == #MSH.Native.desiredPlayers(r)
        for _, u in ipairs(h.players._raw) do same = same and want[u] == true end
        check(same and has(h, "fox1") and has(h, "pia") and has(h, "ivy"), "原生名單＝desiredPlayers，INVITE 不改投影")
        T.disband(foxes)
    end

    T.section("身分：上線就綁定（Steam 模式，來源 LOGIN）")
    do
        local function refusals(name)
            local n = 0
            for _, line in ipairs(T.logs) do
                if string.find(line, "BIND_REFUSED\t" .. name .. "\t", 1, true) then n = n + 1 end
            end
            return n
        end
        boot({ steam = true })
        local una = T.player({ name = "una", sid = 76561198000000101 })
        T.tick(15)
        local bu = R.binding("una")
        check(bu ~= nil and bu.sid == 76561198000000101 and bu.src == "LOGIN" and T.logged("BIND\tuna\t-\tLOGIN"),
            "在線未綁定：一次掃描後綁定、來源 LOGIN")
        check(MSH.Identity.principal(una) == "una", "綁定後 principal 照舊回名字")
        -- 改名證據：同一 SteamID 兩分鐘內以別的名字 OnNewGame
        local sidV = 76561198000000102
        T.fire("OnNewGame", T.player({ name = "vera2", sid = sidV, offline = true }))
        T.player({ name = "vera", sid = sidV })
        T.tick(40)
        check(R.binding("vera") == nil and refusals("vera") == 1, "有改名證據：不綁、BIND_REFUSED 只寫一次")
        T.player({ name = "walt", sid = 76561198000000103, dead = true })
        T.player({ name = "xena", sid = 76561198000000104, num = 1 })
        T.tick(15)
        check(R.binding("walt") == nil, "死亡不綁")
        check(R.binding("xena") == nil, "分割畫面次座位不綁")
        R.setBinding("yuri", 76561198000000105, "NEWGAME", T.now)
        T.player({ name = "yuri", sid = 76561198000000105 })
        R.setBinding("zack", 76561198000000106, "NEWGAME", T.now)
        local zack = T.player({ name = "zack", sid = 76561198000000199 })
        T.tick(15)
        check(R.binding("yuri").src == "NEWGAME", "已綁定同 SteamID：不動")
        check(R.binding("zack").sid == 76561198000000106 and MSH.Identity.principal(zack) == nil,
            "已綁定不同 SteamID：不改、principal 回 nil")
        boot()
        T.player({ name = "una", sid = 76561198000000101 })
        T.tick(15)
        check(R.binding("una") == nil, "非 Steam 模式不綁")
        boot({ steam = true })
        local writes = 0
        local origSet = R.setBinding
        R.setBinding = function(...)
            writes = writes + 1
            return origSet(...)
        end
        T.failWrites = true
        T.player({ name = "vic", sid = 76561198000000107 })
        T.tick(15)
        check(writes == 1 and R.binding("vic") == nil, "寫檔失敗：不綁定")
        T.tick(500)                         -- 再 50 秒
        check(writes == 1, "寫檔失敗後 60 秒內不再寫檔")
        T.failWrites = false
        T.tick(150)                         -- 超過 60 秒
        check(writes == 2 and R.binding("vic") ~= nil and R.binding("vic").src == "LOGIN", "60 秒後重試、成功綁定")
        R.setBinding = origSet
    end
end
