[h1]Minidoracat Safehouse for B42 42.22.2-0.15.0[/h1]
[i]2026-11-16[/i]

[b]English summary[/b]
[list]
[*] When a paid slot's lease ends and your newest safehouse of that tier is kept (7 days by default), it now stays protected the whole time: people on the list come and go as usual, everyone else is kept out. Renew to restore it; it is only released when the keep period runs out. While kept, renew first to change sharing, set a respawn point, use item search, rename or redraw.
[*] If an admin changes the rent or period, your auto-renew waits for you to agree to the new terms. The slots window used to keep showing auto-renew as on; it now says "paused", shows the old and new terms, and Agree turns it back on.
[*] Paid slots: worlds connecting to the economy for the first time now get 72 hours of grace by default (worlds already connected keep their setting; change it on the admin panel's Paid page). A lease with 0 grace hours now puts your newest safehouse of that tier into the keep period like any other, and a refund during grace is no longer mistaken for an ended lease.
[/list]

[h3]🔄 變更[/h3]
[list]
[*] [b]租約到期的安全屋在保留期內照樣受保護[/b]：付費名額的租約到期、寬限也結束後，那一級最新建的安全屋會進入保留期（預設 7 天）。以前保留期一開始保護就暫停，別人可以走進去、開走裡面的車；現在保留期內照樣受保護，名單上的人照常進出，別人進不去。續租或補回名額就恢復，保留期滿才解除保護並釋出。保留期內要先續租，才能改分享、設重生點、搜尋物品（含遠距拿取）、改名或重新框選。
[*] [b]付費名額的預設寬限從 24 小時改成 3 天（72 小時）[/b]：只影響第一次接上經濟系統的世界（新世界，或之前沒裝經濟系統）。已經接上過經濟系統的世界照原本的值（之前的預設是 24 小時），就算從沒改過付費頁也一樣；要改請到管理面板的「付費」頁改寬限。改寬限不會暫停玩家的自動續租，已經在跑的那一期照購買當時的寬限，下一期才換新值。
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]自動續租因為租金改變而暫停時，名額視窗會說清楚[/b]：管理員改了租金或每期天數後，原本開著的自動續租要你同意新條款才會繼續扣款。以前名額視窗照樣顯示「自動續租」開著，到期沒扣款、寬限結束後安全屋就停用。現在開關會寫「暫停」，下面寫出新舊租金與天數，按〔同意〕確認新條款後就恢復自動續租。
[*] [b]寬限設成 0 小時的付費名額到期時，安全屋照常進入保留期[/b]（0.1.0 起）：管理員把某一級租用的寬限小時設成 0 時，租約一到期就被移除。以前這時安全屋不會進入保留期，超出名額的那間一直照常使用；現在和有寬限時一樣，那一級最新建的安全屋進入保留期。
[*] [b]寬限中被退款的付費名額，可能在寬限結束後被誤判為到期[/b]（0.1.0 起）：寬限期間退款後，如果伺服器一直讀不到經濟系統，或同一級還有一筆待確認的租用，拖過原本的寬限結束時間，那一級最新建的安全屋會被誤判進入保留期，保留期滿後被釋出。現在退款當下就記下，不會再誤判。
[/list]
