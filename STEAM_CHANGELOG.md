[h1]Minidoracat Safehouse for B42 42.22.2-0.15.1[/h1]
[i]2026-11-22[/i]

[b]English summary[/b]
[list]
[*] Fixed: a finished house could be treated as having no roof, so warmth and wind chill were calculated as outdoors, while the indoor check said the roof was missing but could not mark a single tile (or marked tiles that do have a roof), and checking again changed nothing.
[*] The indoor check now notices when the game's record of the house is out of date, asks the game to recalculate, and checks again by itself a moment later. Open the indoor check once after updating and the house is treated as indoors again.
[*] If the record still does not match after recalculating, the panel says it is not a building mistake and shows the coordinates to report to an admin.
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]蓋好的房子被當成沒屋頂，室內檢查卻標不出是哪幾格[/b]（0.5.0 起）：遊戲有時沒把新鋪的地板記下來，或是房子還沒圍好時就先算過屋頂、圍好之後沒有重算。這時房間明明有牆有屋頂，體溫、風寒卻照室外算；室內檢查會說「缺屋頂」或「只有一部分有屋頂」，卻一格都標不出來，或是把紅格標在其實有屋頂的地方，重新檢查也一樣。現在按室內檢查時，伺服器發現遊戲的紀錄和房子現在的樣子對不上，會當場請遊戲重算；面板先寫「遊戲對這棟房子的紀錄過期了，已請遊戲重算」，過一下自己再檢查一次，就會照重算後的結果顯示。重算後還是對不上時，面板會寫明不是你蓋錯，並附上要回報給管理員的座標。
[/list]
