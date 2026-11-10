[h1]Minidoracat Safehouse for B42 42.22.2-0.14.0[/h1]
[i]2026-11-10[/i]

[b]English summary[/b]
[list]
[*] Forcing a door or window open with a crowbar (new in 42.22) in a safehouse now needs the Build permission. Without it, the option isn't in the right-click menu.
[*] Removing crops, fertilizing and composting now need the Farm permission. Scything grass does nothing if it would cut safehouse crops you aren't allowed to farm.
[*] Walls, doors, windows, door frames and fences on the edge of a safehouse are protected when either side is inside it: sledgehammer, dismantling, barricading and removing barricades need Build; picking them up, rotating or disassembling them needs Move furniture.
[*] Objects that take up several tiles (beds, tables, coops, stairs, double doors, garage doors) are protected as a whole when any tile is inside a safehouse.
[*] Disassembling player-built walls, stairs and other structures that can't be picked up now needs both Move furniture and Build. Furniture, including player-made crates, still needs only Move furniture.
[*] You can't climb a ladder (new in 42.22) into a safehouse you aren't allowed to enter.
[/list]

[h3]🔄 變更[/h3]
[list]
[*] [b]在安全屋的門窗上用撬棍「撬開」（Force）要有「建造」權限[/b]：42.22 新增的撬棍「撬開」，在安全屋裡和大鎚、拆除算同一類：屋主一律可以，分享對象要有「建造」權限，其他人都不行。沒有權限的人右鍵選單看不到「撬開」。
[*] [b]移除作物、施肥、堆肥，以及割草割到作物，都要有「農耕」權限[/b]：在安全屋裡移除作物、施肥或堆肥，現在和翻土、播種、收成、澆水、除病一樣要有「農耕」權限，右鍵選單也不列出這三項。用鐮刀割草時，範圍裡有安全屋的作物而沒有「農耕」權限，這次割草整個不做。沒有權限時畫面說明缺少哪個權限。
[*] [b]安全屋邊上的牆、門、窗、門框、柵欄，有一側在安全屋裡就受保護[/b]：用大鎚拆、「拆除」、釘路障、拆路障時，目標在安全屋範圍的邊上、只要其中一側在安全屋裡，就要有「建造」權限，和撬棍「撬開」相同；大鎚與「拆除」會一起拆掉的樓梯、雙開門、車庫門、墓穴也一樣，有一格在安全屋裡就算。用搬家具的方式把邊上的門窗這類物件撿起來、旋轉或「拆解」成材料，則要有「搬家具」權限。沒有權限的人在這些門窗上看不到拆路障的選項。
[*] [b]跨在安全屋邊界上的多格物件，整組受保護[/b]：床、桌子、雞舍這類佔好幾格的物件，只要有一格在安全屋裡，用大鎚拆或「拆除」就要有「建造」權限，用搬家具的方式撿起、放下、旋轉或「拆解」要有「搬家具」權限。用建造選單蓋樓梯時，頂端自動補的那塊平台地板落在安全屋裡，也要有「建造」權限。
[*] [b]用搬家具的「拆解」拆玩家蓋的牆、樓梯，要同時有「搬家具」與「建造」權限[/b]：在安全屋裡把玩家用建造選單蓋的、撿不起來的東西（牆、樓梯、門框這類「拆除」拆得掉的）「拆解」成材料，除了「搬家具」還要有「建造」權限，和「拆除」、大鎚一致。撿起、放下、旋轉、修理，以及拆解家具（包括玩家做的木箱、桌椅這類撿得起來的），照舊只要「搬家具」。缺「建造」的人，右鍵的「拆解」選單不列出這些項目。屋主想讓分享對象拆這些東西，請同時給「建造」。
[*] [b]不能進的安全屋，梯子也爬不進去[/b]：42.22 新增可以爬的梯子。爬上去或爬下來會進到你不能進的安全屋時，右鍵選單不列「爬梯子」，按互動鍵也不會爬，畫面會說明原因。能不能進的規則和走路相同（屋主、名單、管理員、伺服器設定）。
[/list]
