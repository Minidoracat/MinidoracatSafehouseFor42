[h1]Minidoracat Safehouse for B42 42.21.0-0.13.0[/h1]
[i]2026-11-08[/i]

[b]English summary[/b]
[list]
[*] Admins can now set each deed tier's outline limit, and the free mode one, up to 150 tiles, and the max area up to 22,500 tiles (it was 96 × 96). The default settings stay the same.
[*] With Avoid roads on, an outline limit over 96 gets a warning in the admin panel, with the reason and what to do: players must stand in the middle of the area to create safehouses that big, and on lower screen resolutions they may not manage at all.
[*] While you mark an area with an outline over 96, the panel tells you to walk to its middle before you press Done, and to stand there when you press Create.
[*] If part of the area isn't loaded, the check now says why (the server hasn't loaded the map there) and what to do: walk inside the area near its middle, wait a moment, then press Check again.
[*] Fixed: when several fields in the admin panel were wrong at once, the error line had stray "。、" marks between the messages.
[/list]

[h3]✨ 新增[/h3]
[list]
[*] [b]管理員可以把單間安全屋放寬到 150 × 150[/b]：各級地契與免費模式的外框上限最多可以設到 150、最大面積最多 22,500 格（原本最大 96 × 96）。預設值不變，沒改設定的伺服器照舊。開著「避開道路」時外框設超過 96，管理員面板那一級底下會用警告色提醒，表格底下寫出原因與做法：玩家要站在範圍中間才建得起來，螢幕解析度低的玩家可能建不了，超過 144 時連 1920×1080 以上的螢幕也可能建不了，每次檢查的伺服器負擔也比較大；這是遊戲只載入玩家附近地圖的限制，不是 MOD 的錯誤。沙盒選項的說明也寫了同樣的提醒。
[/list]

[h3]🔄 變更[/h3]
[list]
[*] [b]範圍有一部分沒載入時，寫清楚原因和做法[/b]：預檢或建立時，範圍有一部分離你太遠、伺服器還沒載入那裡，原本只寫「在範圍附近待一下再試」。現在寫明伺服器還沒載入那裡的地圖，請走到範圍裡靠近中央的地方，稍等一下再按〔重新預檢〕；外框超過 96 時另外說明站在中間也可能建不了，可以把外框縮小，或分成兩間相鄰的安全屋。框選時外框超過 96，面板也會先提醒：按〔完成〕之前就走到範圍中間，最後按〔建立〕時也站在那裡。
[*] [b]地契無效或範圍超過地契上限時，預檢先不檢查道路、資源點與禁建區[/b]：換成有效的地契、縮小到上限以內再預檢，才會列出這三項的結果。
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]管理員面板好幾欄同時填錯時，底下的錯誤訊息多一個頓號[/b]（0.1.0 起）：例如外框和面積都填超過上限，底下寫成「…須介於 1 到 9216。、3 級外框上限…」。現在每一欄的錯誤各自成句，中間不再多一個頓號。
[/list]
