[h1]Minidoracat Safehouse for B42 42.22.2-0.16.0[/h1]
[i]2026-11-22[/i]

[b]English summary[/b]
[list]
[*] New: with a higher-tier deed in your inventory, the manager window shows "Upgrade with deed". The safehouse keeps its name, sharing list and respawn point; you can keep the same area or redraw it. The old deed is not returned.
[*] New: lease reminders. You get a notice when a paid slot's lease is about to end, enters its grace period, ends, or when auto-renew could not be paid, and one summary when you log in. After renting a slot, the game asks right away whether to turn on auto-renew.
[*] New: a "Toggle item search" key in the game's key bindings ("Safehouse" group, unbound by default), and a sandbox option "No zombie spawns inside safehouses" (off by default).
[*] New: while drawing an area, the panel tells you how many tiles inside the outline are not selected and therefore not protected.
[*] Changed: digging dirt, gravel or sand inside a safehouse now needs the "Build" permission.
[*] Fixed: road tiles whose surface was changed are now still treated as roads when creating a safehouse (only for surfaces changed after this update).
[/list]

[h3]✨ 新增[/h3]
[list]
[*] [b]用更高級的地契升級安全屋[/b]：想把安全屋換成更高一級，以前只能放棄再重建。現在背包裡有更高級的地契時，管理視窗會多出〔用地契升級〕，直接把這一間升上去：名稱、分享名單、重生點都照舊，範圍可以照舊，也可以順便重新框選。原本的地契不退，舊等級的名額會空出來。升級不算重新框選次數，也不受重新框選的時間限制。只能換更高級，不能換同級或降級。
[*] [b]租約快到期會提醒[/b]：付費名額的租約快到期、進入寬限、已經結束，或自動續租沒有扣款成功時，畫面右上會跳出提醒；開著自動續租的名額在到期前不會打擾你。安全屋因為租約到期進入保留期、或之後恢復時，也會各提醒一次。登入時會整理成一則提醒：保留期中的安全屋有幾間、寬限期中的名額有幾個、快到期又不會自動續租的名額有幾個。
[*] [b]租用名額後直接問要不要開自動續租[/b]：以前租完還要自己記得去打開「到期自動續租」，很多人忘了。現在在名額視窗租用、付款成功後，會直接問要不要開啟，按一下就好；選〔先不要〕之後還是可以隨時在名額視窗打開。
[*] [b]物品搜尋快捷鍵[/b]：遊戲的按鍵設定多了「安全屋」分組，可以替物品搜尋綁一個鍵（預設不綁）。站在自己或分享給你的安全屋裡按，就會打開那一間的物品搜尋，再按一次關閉；不在安全屋裡時，只有一間安全屋就開那一間的，否則打開管理視窗。
[*] [b]沙盒選項〔安全屋範圍內不生成殭屍〕（預設關）[/b]：開啟後，安全屋範圍內不會再重生或冒出殭屍，包含第一次進入的建築裡原本藏著的殭屍。從外面走進來的殭屍、地上屍體起身變成的殭屍不會當場消失，要等那一帶沒有玩家、重新載入後才會清掉；玩家死後屍變的不會清。管理員面板〔規則〕頁可以直接切換。
[*] [b]框選時提示外框裡沒圈到的格子[/b]：受保護的只有圈到（亮起來）的格子。只畫一圈外牆、中間沒圈時，框選、預檢、確認三頁現在會寫出外框裡有幾格沒圈到、不受保護。
[/list]

[h3]🔄 變更[/h3]
[list]
[*] [b]在安全屋範圍內鏟土、鏟碎石、鏟沙要有「建造」權限[/b]：和倒土、建造一樣：屋主一律可以，分享對象要有「建造」權限，其他人會被擋下並看到缺少哪個權限。
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]道路規則的判定更嚴謹[/b]：路面被改過的格子，有些情況下建立安全屋時沒有照道路規則判定。現在這些格子照原本的道路算，伺服器當機重開也不會忘記；自己在草地上倒的碎石不算道路。只對更新後才改動的路面有效；更新前就改過的，管理員可以用禁建區補上。
[*] [b]當機補回的安全屋保留已用掉的重新框選次數[/b]：以前伺服器在存檔前當機、重開後補回的安全屋，重新框選次數會歸零。
[*] [b]送出後結果待定時不再認錯安全屋[/b]：建立、重新框選或升級送出後沒收到結果時，如果清單同時多出好幾間安全屋，或新的那間等級不對，會維持「無法確認」，不再把別間當成這次的結果。
[/list]
