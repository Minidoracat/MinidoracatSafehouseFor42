[h1]Minidoracat Safehouse for B42 42.22.2-0.18.0[/h1]
[i]2026-11-26[/i]

[b]English summary[/b]
[list]
[*] Admins can now draw road-exempt zones: inside them, roads no longer block claiming a safehouse, so you don't have to turn off "Avoid roads" for one exception. Resource spots, overlap and spacing rules still apply.
[*] Road-exempt zones show on the ground as dashed lines (a new type under "Show ranges on the ground", on by default), and the claim check tells you when roads are skipped.
[*] "Clear zombies inside safehouses while someone is home" now waits until a new safehouse is 24 hours old (real time). Change it with the new sandbox option "Home clearing: wait after creation (hours)"; 0 clears right away.
[*] Admin zones now live in a settings file that server owners can edit by hand; saved changes apply within 5–10 seconds, no restart needed. Existing no-build zones move over automatically on first start.
[*] When adding a zone, admins can type two corner coordinates instead of walking there, and the zone list can be filtered by type and searched by name.
[/list]

[h3]✨ 新增[/h3]
[list]
[*] [b]管理員可以畫「道路豁免區」，准許把那裡的道路圈進安全屋[/b]：不必再為了一處例外關掉「避開道路」。在管理員面板排除頁按〔管理區域〕→〔新增區域〕，先選種類再框出範圍；和禁建區合計最多 100 個。
[list]
[*] 區內不檢查道路，資源點、重疊與間距照樣擋；和禁建區重疊的地方禁建區優先。
[*] 建立或重新框選時，整塊在豁免區內的預檢寫「在道路豁免區內，道路不擋」；只有一部分在內時提醒區外的道路照擋。
[*] 玩家也看得到：「在地面顯示範圍」多一類「道路豁免區」（預設開），用虛線畫，室外白色、室內深灰。
[/list]
[*] [b]新增區域可以按〔輸入座標〕直接填兩個對角[/b]，不必走過去：填好按〔加入這塊〕或〔挖掉這塊〕，也可以直接〔儲存〕；超過範圍上限時寫出原因、不會送出。
[*] [b]區域視窗可以篩種類、搜尋名稱[/b]：每列寫種類、座標、塊數，禁建區列出壓到的安全屋，道路豁免區寫區內有幾間。
[/list]

[h3]🔄 變更[/h3]
[list]
[*] [b]禁建區和道路豁免區改存在一個可以手改的設定檔，存檔後 5～10 秒生效，不必重開伺服器[/b]：區域視窗的〔重新載入〕可以立刻讀檔，在線的玩家地上的範圍跟著更新。
[list]
[*] 從舊版更新：第一次開服時舊的禁建區自動搬過去；搬不過來時暫停建立安全屋，區域視窗寫出原因與恢復方法。
[*] 檔案改壞時沿用上一份能用的內容，線上管理員收到一次通知，區域視窗寫出錯在哪一行；修好前遊戲內不能新增或刪除區域。
[/list]
[*] [b]新建的安全屋要等一段時間，「有人在家時清除安全屋內的殭屍」才會開始清[/b]（0.17.0 起的選項）：預設建立滿 24 小時才清。已經開了這個選項的伺服器更新後，建立不到 24 小時的安全屋會暫時不清，最晚一天後自己恢復。
[list]
[*] 新增沙盒選項「在家清除殭屍：建立後等待（小時）」，照現實時間算，伺服器關機的時間也算；重新框選或用地契升級後重新起算。
[*] 想照 0.17.0 建好馬上清，把時數設成 0。管理員面板〔規則〕頁可以直接改，開關沒勾時這一欄反灰。
[/list]
[/list]
