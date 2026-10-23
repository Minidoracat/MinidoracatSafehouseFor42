<!-- 指南網址：https://steamcommunity.com/sharedfiles/filedetails/?id=3819479336 -->
<!-- Steam guide source (English): the full reference for this mod; the Workshop description only summarizes. Format and sync: pz-family-docs/release.md「完整說明：Steam 指南」 -->
<!-- 標題：📖 Safehouse Mod Guide: Deeds, Claiming, Sharing, Paid Slots & Server Setup -->
<!-- 摘要：Illustrated guide to the Minidoracat Safehouse mod: getting deeds, marking your safehouse area, fixing failed checks, sharing and permissions, the manager window, ground outlines, respawn points and the indoor check, item search and remote take, paid slots, idle release and insurance, plus required server settings, the admin panel, sandbox options, taking over existing safehouses and what to know before removing the mod. -->
=== 🚀 Quick start
[b]繁體中文版：[/b][url=https://steamcommunity.com/sharedfiles/filedetails/?id=3819479307]Safehouse MOD 完整說明[/url]

The mod on Steam Workshop:
https://steamcommunity.com/sharedfiles/filedetails/?id=3819478078
{{img:01-overview-en.jpg}}
A safehouse system for dedicated multiplayer servers: use a deed to mark your own safehouse area, which automatically stays off roads and resource sites, then share it with friends or your faction, one permission at a time.
[olist]
[*] [b]Get a deed[/b]: craft one; the server may also sell deeds in the shop, let them drop as loot, or allow free claims without a deed.
[*] [b]Start[/b]: right-click a deed in your inventory → "Use deed", or open [b]Safehouse Manager[/b] and press "Create safehouse".
[*] [b]Mark the area[/b]: drag with the mouse, or walk to two corners.
[*] [b]Check and create[/b]: adjust as the checks tell you, then stand inside the area and press "Create safehouse".
[*] [b]Share[/b]: on "Members & sharing" in the manager window, share it with friends or your faction.
[/olist]
[h3]Requirements[/h3]
[list]
[*] [b]Required[/b]: [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701]Minidoracat UI Library[/url]
[*] [b]Optional[/b]: [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763913359]Minidoracat MiniMap[/url], to keep claims off resource sites.
[*] [b]Optional[/b]: [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3801482125]Minidoracat Economy[/url], to buy or rent extra safehouse slots.
[/list]
[h3]Where it works[/h3]
[list]
[*] [b]Dedicated multiplayer servers only[/b]: single player and self-hosted multiplayer (listen / co-op host) load the mod but can't create or manage safehouses; you'll see "Safehouse management only works on a dedicated server."
[*] [b]Split-screen[/b]: players 2–4 can't create safehouses.
[*] [b]Server admins[/b]: change a few vanilla safehouse settings first; see "Server settings".
[*] [b]Adding mid-save[/b]: safehouses already in the save (vanilla or Better Safehouse) are taken over automatically at server start; see "Taking over existing safehouses".
[*] [b]Protection[/b]: uses vanilla safehouses, so non-members can't enter or take items; a vehicle with anyone aboard who can't enter can't drive in either (see "Vehicles can't drive in"); zombies can still spawn inside.
[/list]
=== 🧰 Deeds
{{img:02-deed-tooltip-en.jpg}}
[h3]Eight tiers[/h3]
Admins choose how many tiers are enabled (3 by default, up to 8) and can change every tier's size. Defaults:
[table]
[tr][th]Deed[/th][th]Max area[/th][th]Same as[/th][th]Outline limit[/th][/tr]
[tr][td]Tier 1[/td][td]576 tiles[/td][td]24 x 24[/td][td]48[/td][/tr]
[tr][td]Tier 2[/td][td]1,024 tiles[/td][td]32 x 32[/td][td]64[/td][/tr]
[tr][td]Tier 3[/td][td]1,600 tiles[/td][td]40 x 40[/td][td]80[/td][/tr]
[tr][td]Tier 4[/td][td]2,304 tiles[/td][td]48 x 48[/td][td]96[/td][/tr]
[tr][td]Tier 5[/td][td]3,136 tiles[/td][td]56 x 56[/td][td]96[/td][/tr]
[tr][td]Tier 6[/td][td]4,096 tiles[/td][td]64 x 64[/td][td]96[/td][/tr]
[tr][td]Tier 7[/td][td]6,400 tiles[/td][td]80 x 80[/td][td]96[/td][/tr]
[tr][td]Tier 8[/td][td]9,216 tiles[/td][td]96 x 96[/td][td]96[/td][/tr]
[/table]
[list]
[*] [b]Area is the main limit[/b]: the area can be any shape as long as the total tiles stay within the max area.
[*] [b]Outline limit[/b]: the rectangle around the whole safehouse can't be wider or longer than this; by default it's twice the side of a square of the same area, and never more than 96 x 96.
[*] [b]How big is tier 1[/b]: about one house with its yard.
[*] [b]Large areas[/b]: town roads cut the land into small plots, so tier 3 and up mostly fit in the countryside.
[*] [b]Slots[/b]: each tier has three numbers, free, buyable and rentable slots; a player's maximum for the tier is the three added together. See "Paid slots".
[*] [b]Icons[/b]: each tier has its own wax seal color, stamped with the tier number.
[*] [b]Hover a deed[/b]: shows that tier's max area and outline limit on this server, and whether it's enabled.
[/list]
[h3]Getting deeds[/h3]
[list]
[*] [b]Crafting[/b]: each tier can be Disabled, Easy, Standard or Strict; by default only tier 1 is craftable, on Standard. The crafting list shows only the enabled difficulty (vanilla crafting window and Neat Crafting alike), and open windows update as soon as an admin changes it.
[*] [b]From an admin[/b]: with the vanilla /additem command.
[*] [b]Shop[/b]: with Economy on the server, admins can list deeds in the shop.
[*] [b]Loot[/b] (off by default): once admins turn on "Deeds drop as loot", deeds can appear when an office desk, filing cabinet or safe generates its items for the first time, using each tier's chance.
[/list]
Default chances once "Deeds drop as loot" is on:
[table]
[tr][th]Deed[/th][th]Chance[/th][/tr]
[tr][td]Tier 1[/td][td]1%[/td][/tr]
[tr][td]Tier 2[/td][td]0.3%[/td][/tr]
[tr][td]Tier 3[/td][td]0.1%[/td][/tr]
[tr][td]Tier 4[/td][td]0.03%[/td][/tr]
[tr][td]Tier 5[/td][td]0.01%[/td][/tr]
[tr][td]Tier 6[/td][td]0.005%[/td][/tr]
[tr][td]Tier 7[/td][td]0.002%[/td][/tr]
[tr][td]Tier 8[/td][td]0.001%[/td][/tr]
[/table]
[h3]Free mode[/h3]
[list]
[*] [b]No deed[/b]: when the server sets "Creation mode" to "Free", you can create a safehouse without a deed.
[*] [b]Size[/b]: up to 576 tiles (24 x 24) with a 48-tile outline by default.
[*] [b]Deeds in your inventory[/b]: can't be used to create in free mode.
[*] [b]Slots[/b]: counted as tier 1.
[/list]
[h3]When an admin removes a tier[/h3]
[list]
[*] [b]Deeds you hold[/b]: they stay, but can't be used, don't drop and can't be crafted; they work again once the tier is added back.
[*] [b]Existing safehouses[/b]: stay protected.
[/list]
=== 🧰 Marking the area
{{img:03-select-en.jpg}}
[h3]Opening the create panel[/h3]
[list]
[*] [b]With a deed[/b]: right-click it in your inventory → "Use deed".
[*] [b]From the manager window[/b]: press "Create safehouse"; the manager window hides and comes back when you close the create panel.
[*] [b]The panel shows[/b]: the deed in use, its limits and your slots for that tier: how many safehouses you have, the maximum, and how many free, bought and rented slots are used.
[*] [b]Panel position[/b]: drag it elsewhere and it reopens there for the rest of this session.
[/list]
[h3]Three ways to mark[/h3]
[list]
[*] [b]Drag[/b]: hold the left mouse button and drag on the ground to mark a piece; release to add it. A click marks one tile.
[*] [b]Walk to two corners[/b]: stand on one corner and press "Set first corner", walk to the opposite corner, then press "Add this piece" or "Cut this piece".
[*] [b]Controller[/b]: move tile by tile with the D-pad, press "Set first corner", move to the opposite corner, then press "Add this piece" or "Cut this piece"; LB / RB switch buttons.
[/list]
[h3]Building a shape[/h3]
[list]
[*] [b]Add and Cut[/b]: switch with "Add" and "Cut", then mark a piece to add it to the area or cut it out.
[*] [b]Pieces[/b]: up to 4 per safehouse by default (admins can set 1–8), for L, U and other shapes.
[*] [b]One piece[/b]: each part must share an edge with another part; touching corners doesn't count.
[*] [b]No holes[/b]: the area can't enclose an unmarked hole.
[*] [b]Too complex[/b]: fill in the notches, or move the cut-outs to the corners.
[*] [b]"Undo" and "Clear"[/b]: step back or start over anytime.
[/list]
[h3]What you see[/h3]
[list]
[*] [b]Cyan[/b]: the marked area is tinted on the floor; characters still stand on top of it, and tall grass isn't tinted, only the ground beneath it.
[*] [b]Live numbers[/b]: the panel shows outline, area, pieces and the deed's limits, with the "same as" size next to tile counts.
[*] [b]Red[/b]: over the limit or breaking the shape rules turns the text and the ground area red.
[/list]
[h3]Finishing and creating[/h3]
[olist]
[*] Press "Done" and the server runs its checks (see "Failed checks").
[*] Failed items say why and how to fix them; "Edit area" takes you back to editing with your area kept.
[*] Once everything passes, press "Create safehouse", enter a name (leave blank to use your username), then press "Create".
[*] Stand inside the area to confirm; the server checks again at that moment.
[/olist]
[h3]Distance to other safehouses[/h3]
[list]
[*] [b]Your own may touch[/b]: safehouses of the same owner only can't overlap.
[*] [b]Your faction may touch by default[/b]: safehouses whose owner is in your faction can touch (not overlap) by default; admins can set a separate gap.
[*] [b]Others need a gap[/b]: at least 2 tiles by default, per the server's setting.
[/list]
=== 🧰 Failed checks
{{img:04-preview-marks-en.jpg}}
The server re-checks every rule when you send the area, and the check page lists each failed rule with what to do.
[list]
[*] [b]What's checked[/b]: Character, Your position, Deed, Size, Distance and overlap, Slots, Name, Other players, No-build zones (only when the server has some), Roads, Resource points.
[*] [b]Red on the ground[/b]: road tiles, resource buildings, no-build zones or other safehouses in the way are marked red.
[*] [b]After fixing[/b]: press "Edit area" to adjust, or "Check again".
[*] [b]No slot left[/b]: while the tier can still be bought or rented, the panel shows "Get a slot", which opens the slots window with that tier selected.
[/list]
[h3]Common messages[/h3]
[table]
[tr][th]Message[/th][th]What to do[/th][/tr]
[tr][td]You need to stand inside the area.[/td][td]Walk into the marked area and try again.[/td][/tr]
[tr][td]No usable deed was found in your inventory.[/td][td]Keep the deed in your inventory and try again.[/td][/tr]
[tr][td]This deed tier is turned off on this server.[/td][td]Use a deed of an enabled tier.[/td][/tr]
[tr][td]The area is larger than this deed allows.[/td][td]Shrink the area to within the size limit.[/td][/tr]
[tr][td]The shape of the area breaks the rules.[/td][td]Press Edit area and adjust it.[/td][/tr]
[tr][td]The area overlaps another safehouse.[/td][td]Move the area away or make it smaller.[/td][/tr]
[tr][td]The area is too close to another player's safehouse: it needs at least an N-tile gap.[/td][td]Move the area farther away or make it smaller.[/td][/tr]
[tr][td]Another player is standing inside the area.[/td][td]Wait until they leave, then try again.[/td][/tr]
[tr][td]The area covers a road that safehouses can't include.[/td][td]Move the area off the road or make it smaller.[/td][/tr]
[tr][td]The area covers a resource site.[/td][td]Move the area off the resource site or make it smaller.[/td][/tr]
[tr][td]The area covers the no-build zone "name" set by an admin.[/td][td]Move the area out of the no-build zone or make it smaller.[/td][/tr]
[tr][td]Part of the area isn't loaded on the server yet.[/td][td]Stay near the area for a moment and try again.[/td][/tr]
[tr][td]Resource site data is still loading.[/td][td]Try again in a moment.[/td][/tr]
[tr][td]You have no slots left for this tier.[/td][td]Get a slot for this tier, or abandon a safehouse you no longer need.[/td][/tr]
[tr][td]You've reached the per-player limit for this tier.[/td][td]Use a deed of another tier, or abandon a safehouse of this tier.[/td][/tr]
[tr][td]You haven't survived long enough on this server to claim a safehouse.[/td][td]Survive a while longer and try again.[/td][/tr]
[tr][td]This name can't be used.[/td][td]Use 1 to 40 characters.[/td][/tr]
[tr][td]This exact position clashes with another safehouse's internal ID.[/td][td]Move the area by one tile and try again.[/td][/tr]
[tr][td]Safehouse changes are paused because the server setup is incomplete.[/td][td]Ask an admin to check the server status in the admin panel.[/td][/tr]
[tr][td]The server has reached its safehouse limit.[/td][td]Tell an admin.[/td][/tr]
[tr][td]The server-wide safehouse member list is full.[/td][td]Tell an admin.[/td][/tr]
[/table]
=== 🧰 Roads and resource sites
[h3]Roads[/h3]
[list]
[*] [b]Tile by tile[/b]: the server looks at the ground of every tile; the area can't include roads.
[*] [b]Roads by default[/b]: main roads, and streets and parking lots.
[*] [b]Not roads by default[/b]: gravel, sidewalks and plazas; admins can add them to "Ground that counts as road".
[*] [b]Margin[/b]: no road within 1 tile outside the area either (adjustable).
[*] [b]Your driveway[/b]: within a few tiles of a home and its detached garage or shed, only main roads and parking lots count, so you can enclose your own driveway.
[*] [b]Inside buildings[/b]: floors inside the rooms of the map's own buildings never count as road (some houses have road asphalt in the garage); rooms that players wall in themselves are still judged by their ground.
[*] [b]Parking data[/b]: comes from MiniMap; without it, only main roads block near homes.
[/list]
[h3]Resource sites (needs MiniMap)[/h3]
[list]
[*] [b]Whole buildings[/b]: by default military, police, gun stores, medical, pharmacies, fire stations, gas stations and prisons can't be claimed.
[*] [b]Checked area[/b]: also looks as many tiles beyond the area as the "Gap to other safehouses" setting.
[*] [b]Detection[/b] (admin's choice):
[list]
[*] MiniMap resources (default): matches the resources players see on the minimap.
[*] Room data: a building counts if any room in it belongs to a chosen category; also covers map mods' buildings, stricter.
[/list]
[*] [b]Without MiniMap[/b]: resource sites aren't checked.
[/list]
[h3]No-build zones (set by admins)[/h3]
[list]
[*] [b]What they are[/b]: places an admin marks in the admin panel where safehouses can't be built, such as dirt roads the road check can't detect.
[*] [b]How they're checked[/b]: if the area covers any tile of one, you can't create or redraw it there. Only touching the edge is fine, and admins are blocked too.
[*] [b]Can I see them?[/b] Yes. The "No-build zones" kind of "Show ranges on the ground" in Safehouse Manager (on by default) draws the zones near you in bright red, and updates right away when an admin adds or deletes one. When a check fails, the covered part is also marked red and the zone's name is shown.
[*] [b]Existing safehouses[/b]: a zone added later doesn't remove them.
[/list]
[h3]This server's rules[/h3]
{{img:05-land-rules-en.jpg}}
[list]
[*] The "Land rules" tab in the manager window lists the gap, road and resource rules.
[*] They apply when creating or redrawing; existing areas aren't taken back when the rules change.
[/list]
=== 🧰 Redrawing and abandoning
[h3]Redraw[/h3]
[list]
[*] [b]Time limit[/b]: within 30 minutes after creating (adjustable, 0 = off).
[*] [b]Count[/b]: up to 5 times per safehouse (adjustable 1–20).
[*] [b]No extra deed[/b]: redrawing doesn't use or refund a deed.
[*] [b]Start from the current shape[/b]: your current safehouse stays until the new area is created.
[*] [b]Button[/b]: "Redraw" in the manager window shows the time and uses left.
[*] [b]Confirm[/b]: after the checks pass, press "Use this area", then "Use new area".
[*] [b]After the time limit[/b]: to move it, abandon it and create a new one.
[*] [b]Taken-over safehouses[/b]: can't be redrawn.
[/list]
[h3]Abandon a safehouse[/h3]
[list]
[*] [b]How[/b]: press "Abandon safehouse..." in the manager window and confirm.
[*] [b]The deed isn't returned[/b]: if you just drew the wrong area, use "Redraw" while it's still available.
[/list]
=== 🧰 Sharing and permissions
{{img:06-share-en.jpg}}
Select a safehouse in the manager window and open "Members & sharing". To add someone new: pick permissions first, then press "Share with player" or "Share with faction".
[table]
[tr][th]Permission[/th][th]Allows[/th][/tr]
[tr][td]Member[/td][td]Entering the safehouse, taking and putting items in containers[/td][/tr]
[tr][td]Use appliances[/td][td]Appliances, including taking water, and wiring, switching, refueling and repairing generators[/td][/tr]
[tr][td]Move furniture[/td][td]Moving furniture, including picking up generators[/td][/tr]
[tr][td]Build[/td][td]Building, including dismantling[/td][/tr]
[tr][td]Farm[/td][td]Farming[/td][/tr]
[tr][td]Remote take[/td][td]When the server allows remote take: standing inside the safehouse, take items from a container elsewhere straight into your inventory[/td][/tr]
[tr][td]Invite[/td][td]Adding players who can't enter yet[/td][/tr]
[tr][td]Manage[/td][td]Changing permissions, stopping shares and inviting, for the owner[/td][/tr]
[/table]
[h3]Invite and Manage[/h3]
[list]
[*] [b]Individual players only[/b]: faction shares go up to Remote take.
[*] [b]Invite[/b]: can only grant permissions the inviter has, and can't change or remove existing members.
[*] [b]Manage[/b]: can only add or remove permissions they have themselves, and can't grant Manage; the member's other permissions stay.
[*] [b]Changing an existing member[/b]: ask the owner or someone with Manage.
[/list]
[h3]Changing members, several at once[/h3]
[list]
[*] [b]One member[/b]: click their row and the permissions switch to what they have now; change them and press "Save changes". Only the permissions you clicked change.
[*] [b]Several members[/b]: tick the box at the start of each row, or Ctrl+click; Shift+click picks a range and Ctrl+A selects everyone; Esc or "Clear selection" clears it. On a controller: D-pad to move, A to tick, B to clear.
[*] [b]Changing them together[/b]: with two or more picked, each permission shows how many have it (for example "Use appliances 2/3"); click it to cycle through give to all, remove from all, no change. "Apply to N players..." first lists who each change applies to and asks you to confirm.
[*] [b]Stopping a share[/b]: pick the players and press "Stop sharing..."; after you confirm, they lose every permission in this safehouse. The faction row's "Stop" also asks first.
[*] [b]Typing someone already on the list[/b]: "Share with player" picks their row instead of replacing their permissions.
[*] [b]Rows you can't change[/b]: yourself and others with Manage can't be ticked; hover the row to see why. When the permissions are cut off, hover the row to see them all.
[/list]
[h3]Entering a player name[/h3]
[list]
[*] [b]Suggestions[/b]: online players and people you've shared with, matching any part of the name regardless of case; click one to fill it in.
[*] [b]Offline players[/b]: only appear once you type the full name (case-sensitive); you can't list every player on the server by keyword.
[*] [b]The server must know them[/b]: online, logged in on a Steam server after this mod was installed, given a personal tier 1 free slot count by an admin, or already an owner or member of some safehouse.
[*] [b]Non-Steam servers[/b]: there are no login records, so the player must be online or already tied to a safehouse.
[*] [b]Player limit[/b]: up to 8 players per safehouse by default (admins can set 0–32).
[/list]
[h3]Faction sharing[/h3]
[list]
[*] [b]Who[/b]: the faction the owner is in now; the server must allow faction sharing (on by default).
[*] [b]Auto-pause[/b]: if the faction disbands, its leader changes or the owner leaves it, the faction share pauses and anyone who only had access through the faction is removed.
[*] [b]Resume[/b]: the owner presses "Resume sharing" on "Members & sharing".
[/list]
[h3]If it's shared with you[/h3]
[list]
[*] [b]Where[/b]: "Shared with me" in the manager window.
[*] [b]Leaving[/b]: press "Leave safehouse..."; the owner has to share it with you again before you can come back.
[*] [b]Missing a permission[/b]: anything you aren't allowed to do is blocked, and a message tells you which permission is missing.
[/list]
{{img:07-denied-en.jpg}}
=== 🧰 Safehouse Manager window
[list]
[*] [b]Open it[/b]: the [b]Safehouse Manager[/b] button in the User Panel, or the family toolbar.
[*] [b]Two lists[/b]: "Mine" and "Shared with me"; with many safehouses the list just scrolls.
[*] [b]Second line in the list[/b]: in "Mine", the status is followed by the slot that safehouse uses: a free or paid slot with its tier, or "Migrated safehouse" for taken-over ones.
[*] [b]Three tabs per safehouse[/b]: "Overview", "Members & sharing", "Land rules".
[*] [b]What you can do[/b]: "Rename" (1–40 characters), check the status, manage sharing, "Set as respawn point", "Redraw", "Abandon safehouse...".
[*] [b]Other buttons[/b]: "Create safehouse", "Indoor check", "Slots"; "Find items" sits next to the safehouse name (see "Item search").
[*] [b]Idle release[/b]: the "Idle release" row on Overview shows how long is left; see "Idle release and insurance".
[*] [b]After creating[/b]: the window opens on the new safehouse.
[*] [b]Small window or large font[/b]: the window grows taller to fit.
[*] [b]Vanilla UI[/b]: the vanilla claim-safehouse right-click option is removed; the vanilla safehouse window opens this manager for this mod's safehouses.
[/list]
[h3]Show ranges on the ground[/h3]
A switch under the list (on by default) marks the safehouses and no-build zones near you on the ground:
[table]
[tr][th]Kind[/th][th]Color[/th][th]Who sees it[/th][/tr]
[tr][td]Mine[/td][td]Cyan[/td][td]Always[/td][/tr]
[tr][td]Shared with me[/td][td]Blue[/td][td]Always[/td][/tr]
[tr][td]Faction[/td][td]Orange[/td][td]If the server allows it (on by default)[/td][/tr]
[tr][td]Other players[/td][td]Magenta[/td][td]If the server allows it (off by default)[/td][/tr]
[tr][td]No-build zones[/td][td]Bright red[/td][td]Always[/td][/tr]
[/table]
[list]
[*] [b]Same color everywhere[/b]: grass and asphalt show the same color, and the swatch next to each switch is what you see on the ground.
[*] [b]Darker tiles[/b]: near characters, and where a building would hide it, the color is tinted into the floor and looks darker; characters still stand on it and buildings still cover it.
[*] [b]Fill areas[/b]: only the edges are drawn by default; with "Fill areas" on (off by default) the whole area gets a darker color and the edge is drawn in a brighter one.
[*] [b]Overlaps[/b]: where a safehouse and a no-build zone overlap, the safehouse's color is shown.
[*] [b]Per kind[/b]: each of the five kinds can be turned on or off.
[*] [b]Stays on[/b]: after you close the window and next time you play; also switchable on the Mods page in Options.
[*] [b]Display only[/b]: the game already sends every safehouse's area to all players, so a server turning a kind off doesn't keep it secret.
[/list]
[h3]Status[/h3]
[table]
[tr][th]Status[/th][th]Meaning[/th][/tr]
[tr][td]Protected[/td][td]Protected normally.[/td][/tr]
[tr][td]Server setup incomplete[/td][td]Creating and changing safehouses is paused. Ask an admin to check the missing settings in the admin panel.[/td][/tr]
[tr][td]Suspended (lease expired)[/td][td]Renew this tier's slot to restore protection. It will be released if not renewed in time.[/td][/tr]
[tr][td]Faction share paused[/td][td]Open Members & sharing to see why and resume it.[/td][/tr]
[tr][td]Member sync disrupted[/td][td]The member list was changed through vanilla actions and is being restored. Tell an admin if this keeps happening.[/td][/tr]
[tr][td]Held for review, Repair paused[/td][td]Ask an admin to handle it by number in the admin panel.[/td][/tr]
[/table]
[h3]Safehouse respawn point[/h3]
[list]
[*] [b]Set it[/b]: stand inside this safehouse (owners and members alike) and press "Set as respawn point" on the Overview tab.
[*] [b]Respawning[/b]: after you die, your next character always starts on the tile you stood on, whatever you pick in the spawn menu; if you die during the same session, the spawn location menu is skipped.
[*] [b]Upper floors[/b]: if the server can't confirm that floor is still there at that moment (the area isn't loaded, or the floor was dismantled or burned), you start on the same tile at ground level.
[*] [b]One per player[/b]: setting it in another safehouse replaces it; you can also press "Clear respawn point".
[*] [b]Paused[/b]: while the safehouse is released or suspended, or you've been removed as a member, you spawn the vanilla way; it works again once you have access back.
[*] [b]Server must allow it[/b]: with the vanilla server option SafehouseAllowRespawn off, it can't be set and isn't used.
[/list]
=== 🧰 Indoor check
{{img:11-indoor-en.jpg}}
Find out whether a house you built counts as indoors on a multiplayer server (warmth, shelter from the wind, body temperature), and where it falls short when it doesn't.
[list]
[*] [b]Open it[/b]: right-click the floor and choose "Check if this counts as indoors" (checks the tile you clicked), or press "Indoor check" in the Safehouse Manager (checks the tile you stand on).
[*] [b]Result[/b]: counts as indoors, gap in the walls, roof isn't finished, only part of it has a roof, only under a roof, or outdoors.
[*] [b]What counts[/b]: the room must be closed in on all sides (walls, door frames, window frames and fences all count, even with a door in a door frame left open or the glass removed; a house garage door only counts while it's closed; a pillar on a tile stops the west-side wall of that tile from counting), and every tile needs a floor on the level right above. With one roof tile missing, body temperature and wind chill follow the outdoors for the whole room.
[/list]
{{img:12-indoor-gap-en.jpg}}
[list]
[*] [b]Finding the cause[/b]: it lists the missing wall and roof tiles and how far away they are; when a door sits in the gap, the row says "Open door" (close it, then press "Check again") or "Door that isn't a wall" (a door that never counts as a wall even when closed, such as a gate or a two-story door: add a wall or door frame inside it; with Knox Pass 0.8.0 or later, its two-story doors and gates can also have "Counts as indoors" ticked on the reader), and when the tile has a pillar it says "Wall with a pillar" (remove the pillar), instead of asking you to build a wall. With "Mark the spots on the ground" on, the floor of the area that was checked turns slightly darker, missing roof tiles turn the floor red and missing walls show as a bright red wall.
[*] [b]Automatic wall corners[/b]: when two walls meet at a corner, the game adds a corner piece on the tile just outside the corner; if you later build a wall on that tile, the corner piece stops the game from counting it. The server removes these leftover corner pieces (when the wall is built, or when someone runs the indoor check there); the row says "Automatic wall corner" and the window checks again by itself. Pillars you built yourself are never removed.
[*] [b]Opening and closing doors[/b]: the game doesn't recheck doors all the time. When you open or close a door from the vanilla right-click menu, the game keeps what it recorded the last time it checked that tile (for example, a door opened by Knox Pass and then closed from the right-click menu is still recorded as a gap). When you run the indoor check and the server finds a closed door the game still records as a gap, it has the game recheck those tiles on the spot: the row says "Outdated door record", and the window checks again by itself a second or so later. The other way round (a door opened from the right-click menu that the game still records as a wall) is left as it is, and the room keeps counting as indoors.
[*] [b]The same building[/b]: the other rooms are listed too; click one to look at it. On the same floor it follows the connected roof, and up and down it follows the floors, so every floor is checked; with more than one floor, each row says which floor, and the marks on the ground move to the floor of the room you're looking at. A flat roof with nothing built on top doesn't count as a floor; a roof that sticks out past the walls, or a porch, shows as "Under the eaves".
[*] [b]Rechecks by itself[/b]: while the window is open, it checks again when walls or floors nearby change; once you close it, nothing is checked in the background.
[*] [b]Limits[/b]: only tiles within 40 tiles of you; up to 12 rooms per building, and for a very large building only the part nearest the checked spot; the map's own buildings count the vanilla way; self-built rooms underground never count as indoors.
[/list]
=== 🧰 Item search
{{img:13-storage-en.jpg}}
Pick a safehouse in the manager window and press "Find items" next to its name to list what is in every container of that safehouse.
[list]
[*] [b]Where it looks[/b]: furniture containers, bags inside containers (one level deep), items on the floor and vehicles parked inside the area; items with the same name share one row. Locked containers (code lock, or a padlock you have no key for) and locked vehicles aren't listed; the panel only says how many there are.
[*] [b]Finding things[/b]: search by name, filter by category and floor, sort by name, count or distance; click a row to see where it is, on which floor and how many tiles away.
[*] [b]List or grid[/b]: the List / Grid switch right of the search box shows the items as a grid of icons, one tile per item with its count, how many places it is in (or its floor, when there is only one) and how many tiles away; hover a tile to read a name that was cut short. Click a tile to pick it, and the nearest place is picked for you; when the item is in several places, they are shown as cards right under the grid, the picked one with a gold frame, and clicking another card picks that one instead. Your last choice is remembered (a list the first time), and the mod options page can switch it too.
[*] [b]Guiding[/b]: pick a place and press "Guide me there" to get an on-screen arrow; on the same floor a ring is drawn on the ground, on another floor the arrow turns into a stairs icon. A second arrow circles your character and always points at the target, so you can see the way even when the target is off screen or behind a window. When you reach it, the loot window switches to that container. Guiding goes on after you close the panel, for up to 10 minutes, or until you press "Stop guiding".
[*] [b]Walk there[/b]: pick a place and press "Walk there", and your character walks next to the container by itself while the arrow stays on; when it gets there, the loot window switches to that container. It takes the stairs and opens closed doors; for vehicles it walks to that storage spot. A locked door, a closed window or no way through stops it: the panel says why, and the arrow stays so you can walk there yourself. Moving or cancelling stops it. It walks the way vanilla does when you click furniture: no running, and it does not go around zombies.
[*] [b]Taking next to a container[/b]: when you stand next to the container (the same distance at which the loot window lists it), press "Take...", enter how many (up to 50 at a time), and the items move into your inventory one by one with the normal vanilla transfer; moving interrupts it, and what you already took stays with you. This works with any admin setting and without the "Remote take" permission. When you are too far away, the button is greyed out with "Stand next to the container to take items." For a bag inside a container, take the bag out first.
[*] [b]What it can see[/b]: only places your game has loaded (about 50–80 tiles around you, more on bigger screens); for places too far away the panel says how many tiles were not loaded, so walk closer and press "Rescan".
[*] [b]Performance[/b]: searching and guiding run in your own game and never ask the server; with the panel closed nothing runs, and opening it scans once, spread over several frames.
[/list]
[h3]Remote take[/h3]
[list]
[*] [b]The server has to allow it[/b]: taking without walking over only works when the admin sets "Item search" to "Remote take"; the default is "Guide only".
[*] [b]Who can[/b]: the owner, and members shared with the "Remote take" permission (a faction share can include it). The sharing page only shows this permission while the server allows remote take.
[*] [b]Where to stand[/b]: anywhere inside any piece of that safehouse; the admin can widen this with "reach outside the safehouse" to a few tiles outside it (default 0). Only where you stand changes: the items still have to be in that safehouse's containers.
[*] [b]How[/b]: pick a place, press "Take...", enter how many (up to 50 at a time), then stand still for the normal transfer time and the items go straight into your inventory; walking away interrupts it and nothing moves. Whatever doesn't fit stays where it was.
[*] [b]Walk over for these[/b]: items in vehicles or worn by mannequins have to be taken in person through the loot window; "Walk there" can take you there.
[/list]
=== 🧰 Vehicles can't drive in
[list]
[*] [b]Who gets stopped[/b]: if anyone in the vehicle can't enter that safehouse (passengers included), the vehicle stops before the edge; a towed trailer is stopped too.
[*] [b]Message[/b]: tells you whether it's you or someone aboard who can't enter.
[*] [b]Already parked inside[/b]: you can drive it out, just not further in.
[*] [b]Still allowed in[/b]: owners, people on the share list and admins. This applies to every safehouse, including ones this mod didn't create.
[/list]
=== 🧰 Paid slots (optional Economy)
[list]
[*] [b]Three numbers per tier[/b]: admins set, for each tier, how many safehouses each player can build for free, how many slots they can buy, and how many they can rent at the same time; a player's maximum for the tier is the three added together.
[*] [b]Free slots[/b]: by default only tier 1 has 1; admins can change the tier 1 number for one player.
[*] [b]Paid slots[/b]: once the free slots are used, each extra safehouse needs a slot of its deed tier, bought outright or rented monthly (30-day periods).
[*] [b]Without Economy[/b]: free slots only; everything else works.
[*] [b]Not sold by default[/b]: admins set each tier's Buy / Rent to 1 or more on the Deeds tab to start selling.
[*] [b]Lowering the numbers[/b]: only blocks new purchases; slots already bought or rented keep working and can still be renewed.
[/list]
Default prices (set per tier by admins):
[table]
[tr][th]Deed[/th][th]Rent per period[/th][th]Buy[/th][/tr]
[tr][td]Tier 1[/td][td]100[/td][td]1,200[/td][/tr]
[tr][td]Tier 2[/td][td]300[/td][td]3,600[/td][/tr]
[tr][td]Tier 3 and up[/td][td]700[/td][td]8,400[/td][/tr]
[/table]
[h3]Slots window[/h3]
{{img:08-slots-en.jpg}}
[list]
[*] [b]Open it[/b]: "Slots" in the manager window; when you're out of slots and the tier can still be bought or rented, "Get a slot" in the create panel opens it with that tier selected.
[*] [b]Each tier[/b]: the heading shows how many safehouses you have and the maximum; the next line shows the free, bought and rented slots used and their limits; with paid slots to spare, it says how many more you can build.
[*] [b]Buy and rent[/b]: the buttons are disabled at the limit, with "This tier is at its limit: you can't buy or rent more." underneath.
[*] [b]Payment results[/b]: shown under the tier you paid for, both while working and when done; a notification also pops up once the payment has a result.
[*] [b]Leases[/b]: expand to see every lease, renew it or toggle "Auto-renew"; the last line reads "Leases are not tied to a specific safehouse. When a lease ends and this tier has fewer paid slots than safehouses using them, the newest one loses protection first and gets it back once you have a slot for it again."
[*] [b]Nothing to show[/b]: it says "This server offers no slots."
[*] [b]Live updates[/b]: after a payment, renewal, expiry, creating or abandoning a safehouse, or an admin changing slot numbers, an open slots window and create panel update themselves.
[/list]
[h3]When a lease ends[/h3]
[list]
[*] [b]Grace[/b]: an expired lease enters grace first; slots in grace can't be used for new safehouses.
[*] [b]Suspended[/b]: if you're still over the limit for that tier after grace, your newest paid-slot safehouses of that tier are suspended (never more than the number of slots that ended): protection pauses and the area is kept for 7 days (adjustable).
[*] [b]Restore[/b]: renewing, or getting a slot back for it, restores protection; the area is released only after the keep period.
[*] [b]Other tiers[/b]: not affected.
[*] [b]Refunds or an admin lowering the numbers (free slots included)[/b]: the excess doesn't suspend anything, it only blocks new safehouses.
[/list]
[h3]When a tier closes or Economy is removed[/h3]
[list]
[*] [b]Admin removes a deed tier[/b]: no new slots for that tier can be bought; existing leases can still be renewed or set to auto-renew in the slots window.
[*] [b]Economy removed from the server[/b]: suspended safehouses are protected again; the excess only blocks new ones.
[*] [b]Unsupported Economy version or a read failure[/b]: nothing changes; nothing is suspended or restored.
[/list]
=== 🧰 Idle release and insurance
Safehouses nobody comes back to for too long are released automatically, freeing the land.
[h3]How it counts[/h3]
[list]
[*] [b]Visits[/b]: the countdown starts over whenever the owner or anyone on the share list (including faction members it's shared with) steps into the area; the game records this about every 20 seconds.
[*] [b]Being online isn't enough[/b]: if you're online but don't go back, the countdown keeps running.
[*] [b]Release[/b]: after 14 days without a visit by default, it's released like an abandon, and the deed isn't returned.
[*] [b]Bought-slot safehouses[/b]: 30 days by default.
[*] [b]Rented-slot safehouses[/b]: follow their lease and are never released for being idle.
[*] [b]Time that doesn't count[/b]: server downtime, and time the server is paused with nobody online.
[*] [b]After the update[/b]: existing safehouses get the full limit, counted from the server's first start after the update.
[*] [b]Losing paid protection[/b]: when a lease ends, a slot is refunded or Economy is removed from the server, that safehouse gets the full limit from that moment.
[*] [b]Admin shortens the limit[/b]: you still get at least the new limit from that moment, so nothing is released right away.
[/list]
[h3]How long is left[/h3]
[list]
[*] [b]Overview[/b]: the "Idle release" row in the manager window shows the countdown, in a warning color under 1 day.
[*] [b]Rules[/b]: hover the row to see this safehouse's limit and the rules.
[/list]
[h3]Idle-release insurance (needs Economy)[/h3]
Players who can't log in for a while can pay to keep their safehouse longer.
[olist]
[*] Select the safehouse in the manager window and press "Extend" on Overview.
[*] Enter how many days to buy (1–365).
[*] The confirmation shows the daily price, total and the date it's kept until; confirm to pay.
[/olist]
[list]
[*] [b]While insured[/b]: it isn't released.
[*] [b]After it ends[/b]: the countdown starts again from the full limit.
[*] [b]Rented-slot safehouses[/b]: don't need insurance and have no button.
[*] [b]Not sold by default[/b]: admins turn on "Sell idle-release insurance" on the Rules tab.
[*] [b]Refunds[/b]: an admin refund takes back the whole purchase.
[/list]
Default insurance per day (set per tier by admins on the Paid slots tab):
[table]
[tr][th]Deed[/th][th]Insurance per day[/th][/tr]
[tr][td]Tier 1[/td][td]10[/td][/tr]
[tr][td]Tier 2[/td][td]30[/td][/tr]
[tr][td]Tier 3 and up[/td][td]70[/td][/tr]
[/table]
=== ⚙️ Server settings
This mod never changes server settings itself. If any vanilla option below is wrong, the server goes into "Server setup incomplete": creating, sharing and other changes stop, while existing safehouses stay protected, members stay in sync, admins can still act, and online admins get a notice.
[h3]Required[/h3]
[table]
[tr][th]Option[/th][th]Must be[/th][th]Why[/th][/tr]
[tr][td]PlayerSafehouse[/td][td]false[/td][td]Vanilla claiming skips every mod check, so deeds, slots, roads and resource sites can't apply[/td][/tr]
[tr][td]AdminSafehouse[/td][td]false[/td][td]Same (the building-safehouse path)[/td][/tr]
[tr][td]SafeHouseRemovalTime[/td][td]0[/td][td]The game deletes safehouses no member has visited for that many real-time hours[/td][/tr]
[tr][td]War[/td][td]false[/td][td]Vanilla war mode deletes safehouses[/td][/tr]
[tr][td]SafehouseAllowTrepass[/td][td]false[/td][td]Non-members must be removed from safehouses[/td][/tr]
[tr][td]SafehouseAllowLoot[/td][td]false[/td][td]Non-members can't take items from safehouses[/td][/tr]
[tr][td]SafehouseAllowFire[/td][td]false[/td][td]No fires in safehouses[/td][/tr]
[tr][td]DisableSafehouseWhenOwnerConnected[/td][td]false[/td][td]Protection can't turn off while the owner is online[/td][/tr]
[tr][td]AntiCheatSafeHouse[/td][td]1, 2 or 3 (3 = log only, recommended)[/td][td]4 turns off the vanilla check on safehouse packets[/td][/tr]
[/table]
[list]
[*] [b]Days survived[/b]: the vanilla days-survived-before-claiming option (SafehouseDaySurvivedToClaim) still applies.
[/list]
[h3]Suggested[/h3]
The admin panel reminds you if these differ; nothing is disabled.
[table]
[tr][th]Option[/th][th]Suggested[/th][th]Why[/th][/tr]
[tr][td]SaveWorldEveryMinutes[/td][td]10–15[/td][td]At 0 (vanilla default) or above 30, a server crash rolls sharing, renames and releases back to the last world save (a just-created safehouse is restored automatically on restart)[/td][/tr]
[tr][td]AllowCoop[/td][td]false[/td][td]Stops split-screen players from typing someone else's name[/td][/tr]
[tr][td]ChatStreams[/td][td]Remove sh[/td][td]Vanilla safehouse chat members don't follow this mod's sharing; factions can use /faction chat[/td][/tr]
[/table]
[h3]Fixing it in game[/h3]
{{img:09-admin-rules-en.jpg}}
[list]
[*] [b]Status table[/b]: the admin panel's Rules tab lists mismatched options as Setting / Current / Suggested / Why.
[*] [b]"Fix server settings"[/b]: admins whose account can change server settings fix every required setting in one press.
[*] [b]"Apply"[/b]: one per suggested row; SaveWorldEveryMinutes is set to 10, and ChatStreams only loses sh, other channels stay.
[*] [b]How it's done[/b]: after you confirm, the game's /changeoption sets it and /reloadoptions applies it for all players, the same as editing in the vanilla server settings window.
[*] [b]Note[/b]: the server rewrites its settings file with the values in effect, so edits made directly to the file while it runs, and not reloaded yet, are overwritten.
[*] [b]Shutting down[/b]: use quit (or a tool that sends quit); don't kill the process.
[/list]
=== ⚙️ Admin panel
[list]
[*] [b]Who can open it[/b]: roles with the vanilla "set up safehouses" capability (CanSetupSafehouses).
[*] [b]Open it[/b]: the "Admin" button in the Safehouse Manager window.
[*] [b]Apply[/b]: press "Apply changes"; changes are written to the server's sandbox settings at once and synced to online players.
[*] [b]Window size[/b]: drag the bottom-right corner to resize.
[/list]
[h3]Six tabs[/h3]
{{img:10-admin-deeds-en.jpg}}
[list]
[*] [b]Rules[/b]: creation mode, gap, max pieces, share limit, keep days, idle release days and "Sell idle-release insurance", faction sharing, redraw time and count, which other safehouses players see on the ground, and item search (Off / Guide only / Remote take, plus how many tiles outside the safehouse remote take still works); also the server settings status, takeover results and safehouses needing attention.
[*] [b]Deeds[/b]: only enabled tiers, with "Add tier N" / "Remove tier N" below the table (up to 8 tiers; takes effect on "Apply changes").
[list]
[*] The master "Deeds drop as loot" switch; the loot column is greyed out while it's off.
[*] Each tier's max area (with its "same as" size, updating as you type), outline limit and loot chance.
[*] Crafting difficulty: hover the Crafting cell to preview the recipe.
[*] The slot columns "Free", "Buy" and "Rent" take numbers (free safehouses per player, max bought, max rented at the same time); "Max/player" shows the three added together.
[*] With a supported Economy, an extra "List in the Economy shop" button.
[/list]
[*] [b]Exclusions[/b]: roads, margin and road kinds; resource detection and categories (hidden without MiniMap, with a note that it needs the MiniMap mod); no-build zones: "Manage no-build zones" hides the panel and opens the no-build zone window on the right side of the screen. Each zone in the list shows its top-left corner, outline and piece count; you can search names, press "Teleport" to go to its center (needs the teleport-to-coordinates permission) and "Delete" (asks first); safehouses already inside a zone are listed under it (they aren't removed, so the admin decides what to do). While the window is open, zones are drawn bright red on the ground and the one you teleported to is yellow. "Add no-build zone" opens the same area tool as creating a safehouse (drag or walk to two corners, add or cut pieces), then you name it and press "Save zone"; saving or canceling brings you back to the zone window. Up to 100 zones; closing the zone window returns to the admin panel.
[*] [b]Players[/b]: server-side paged search (50 per page); "Tier 1 free slots…" changes one player's tier 1 free slots (tier 1 only; leave it empty to use the server default), view, or release on their behalf (logged to the audit log).
[*] [b]Vanilla safehouses[/b]: vanilla safehouses this mod doesn't manage; see "Vanilla safehouses" below.
[*] [b]Paid slots[/b] (with Economy available): buy price, rent per period and insurance per day for each enabled tier, plus shared currency, period, grace, reminder and auto-renew.
[list]
[*] Only currencies enabled in the Economy are listed; you're warned if the current one gets disabled.
[*] How many slots each player can buy or rent is set on the Deeds tab; this tab says "Whether a tier is sold, and how many slots each player can buy or rent, is set by Buy and Rent on the Deeds tab."
[/list]
[/list]
[h3]Safehouses needing attention[/h3]
[list]
[*] [b]Where[/b]: "Claims needing attention" on the Rules tab.
[*] [b]"Rebind"[/b]: rebinds the owner and restores protection.
[*] [b]"Release…"[/b]: protection ends at once and can't be undone.
[/list]
[h3]Vanilla safehouses[/h3]
[list]
[*] [b]Where[/b]: the admin panel's Vanilla safehouses tab lists the vanilla safehouses this mod doesn't manage (left over from the takeover, or created after this mod was installed).
[*] [b]Each row shows[/b]: owner, member count, size, coordinates, how long nobody has gone in (server downtime counts here, unlike idle release), and where it came from; the ones past the idle release days are marked. Up to 20 are listed, longest unvisited first.
[*] [b]"Teleport"[/b]: takes you to its center (needs the teleport-to-coordinates permission).
[*] [b]"Release…"[/b]: removes that safehouse's protection; what's inside stays where it is, and it can't be undone.
[*] [b]Notice[/b]: when new vanilla safehouses show up on the server, online admins get a notice in the top-right corner.
[*] [b]Vanilla safehouse list[/b]: this mod's safehouses show their real owner and member count followed by "(this mod)", one row per piece with the piece number; pressing "View" on someone else's opens the Players tab of this mod's admin panel with that owner expanded.
[/list]
[h3]Don't use vanilla admin commands[/h3]
[list]
[*] [b]Name matching[/b]: /releasesafehouse, /addusertosafehouse and /kickuserfromsafehouse pick the first safehouse with that name, so a duplicate name hits the wrong one.
[*] [b]Added players don't stay[/b]: anyone added to this mod's safehouses that way is removed on the next pass.
[*] [b]Instead[/b]: handle this mod's safehouses in the admin panel.
[/list]
=== ⚙️ Sandbox options and defaults
Everything is on the "Minidoracat Safehouse" sandbox page and can be set before the server starts. After that, change them in the admin panel (applies at once); the vanilla server settings screen also works and syncs to online players within about a minute.
[table]
[tr][th]Option[/th][th]Default[/th][/tr]
[tr][td]Creation mode[/td][td]Deed required (can be Free)[/td][/tr]
[tr][td]Free mode max area / outline limit[/td][td]576 tiles (24 x 24) / 48[/td][/tr]
[tr][td]Gap to other safehouses[/td][td]2 tiles (0–16)[/td][/tr]
[tr][td]Gap to faction safehouses[/td][td]0 tiles (0–16; 0 = may touch)[/td][/tr]
[tr][td]Max pieces per safehouse[/td][td]4 (1–8)[/td][/tr]
[tr][td]Shared players per safehouse[/td][td]8[/td][/tr]
[tr][td]Allow faction sharing[/td][td]On[/td][/tr]
[tr][td]Redraw time limit[/td][td]30 minutes (0 = off)[/td][/tr]
[tr][td]Redraw limit per safehouse[/td][td]5 (1–20)[/td][/tr]
[tr][td]Keep lapsed safehouses[/td][td]7 days[/td][/tr]
[tr][td]Release idle safehouses (days)[/td][td]14 (0 = never, bought-slot safehouses included)[/td][/tr]
[tr][td]Release idle bought-slot safehouses (days)[/td][td]30 (if not longer than the free limit, the free limit applies)[/td][/tr]
[tr][td]Sell idle-release insurance (needs Economy)[/td][td]Off[/td][/tr]
[tr][td]Avoid roads / Road margin[/td][td]On / 1 tile[/td][/tr]
[tr][td]Ground that counts as road[/td][td]Main roads, streets and parking lots[/td][/tr]
[tr][td]Avoid resource sites (needs MiniMap)[/td][td]On[/td][/tr]
[tr][td]Resource site detection[/td][td]MiniMap resources[/td][/tr]
[tr][td]Resource categories to avoid[/td][td]Military, police, gun stores, medical, pharmacies, fire stations, gas stations, prisons[/td][/tr]
[tr][td]Show faction / other players' safehouse ranges[/td][td]On / Off[/td][/tr]
[tr][td]Item search[/td][td]Guide only (Off / Guide only / Remote take)[/td][/tr]
[tr][td]Remote take: reach outside the safehouse[/td][td]0 tiles (0–50; 0 = stand inside the safehouse)[/td][/tr]
[tr][td]Enabled deed tiers[/td][td]3 (1–8)[/td][/tr]
[tr][td]Each tier's max area and outline limit[/td][td]See "Deeds"[/td][/tr]
[tr][td]Each tier's free slots (Tier<N>FreeSlots)[/td][td]Tier 1: 1, others 0 (0–100; how many safehouses of that tier each player can build for free; tier 1 can be changed per player on the admin panel's Players tab)[/td][/tr]
[tr][td]Each tier's buyable slots (Tier<N>BuySlots, needs Economy)[/td][td]0 (0–100; how many each player can buy, 0 = not sold)[/td][/tr]
[tr][td]Each tier's rentable slots (Tier<N>RentSlots, needs Economy)[/td][td]0 (0–10; how many each player can rent at the same time, 0 = not rented)[/td][/tr]
[tr][td]Each tier's deed crafting[/td][td]Tier 1 Standard, tiers 2–8 Disabled[/td][/tr]
[tr][td]Deeds drop as loot[/td][td]Off (chances per tier in "Deeds")[/td][/tr]
[/table]
[list]
[*] [b]Max per player[/b]: a player's maximum for a tier is free + buyable + rentable; the "Max/player" column on the admin panel's Deeds tab works it out for you.
[*] [b]Lowering buyable or rentable[/b]: only blocks new purchases; slots already bought or rented keep working and can still be renewed.
[/list]
[h3]Updating from an older version: set the slots again[/h3]
[list]
[*] [b]Old settings aren't carried over[/b]: the old ClaimsPerPlayer, Tier<N>Free, Tier<N>Buy, Tier<N>Rent and Tier<N>PerPlayer aren't moved to the new settings.
[*] [b]What to do[/b]: after updating, open the admin panel's Deeds tab, set each tier's "Free", "Buy" and "Rent" numbers again, then press "Apply changes".
[*] [b]Until then[/b]: each player only gets 1 free tier 1 safehouse and no new slots can be bought; slots already bought or rented keep working and can still be renewed.
[*] [b]Per-player numbers[/b]: numbers set on the Players tab are kept, and now only count as tier 1 free slots.
[/list]
[h3]Before raising "Max pieces per safehouse"[/h3]
Each piece is a separate vanilla safehouse in the game, so a higher limit means:
[list]
[*] [b]Login data[/b]: more safehouse data for players to download when they join.
[*] [b]Member list capacity[/b]: the server-wide list (each piece counts separately) fills faster; once it's full, no one can create or share safehouses.
[*] [b]Stutter[/b]: with complex shapes, each change while marking the area can briefly stutter.
[*] [b]Slower removal[/b]: a removed member is more likely to land in another piece of the same safehouse and wait one more check before being moved out.
[*] [b]Lowering it[/b]: only affects new safehouses and redraws; existing ones stay as they are.
[/list]
[h3]Removing this mod from Mods= clears these settings[/h3]
[list]
[*] On the next server start, this mod's whole section is deleted from the sandbox file; adding the mod back restores the defaults.
[*] Before removing it temporarily or downgrading, back up the server's <server name>_SandboxVars.lua.
[/list]
=== ⚙️ Taking over existing safehouses
If you install this mod mid-save, the safehouses already in the save (made by Better Safehouse, vanilla or other mods) are taken over automatically at server start: players don't wait, and admins don't review or edit files.
[list]
[*] [b]Only once[/b]: takeover happens only on servers that already had safehouses the first time this mod started; vanilla safehouses that appear later aren't taken over.
[/list]
[h3]Steps[/h3]
[olist]
[*] [b]One restart[/b]: stop the server and back up the whole save folder, the server settings file and Zomboid/Logs. Set the required options from "Server settings", remove Better Safehouse from Mods=, add this mod (after UI Library) and start the server.
[*] [b]Taken over at start[/b]: every safehouse without problems becomes this mod's safehouse, keeping its owner, area, name and members, and players can use it right away. The admin panel's Rules tab shows the migration as "done" with how many were taken over and left as vanilla; the audit log has a MIGRATION_ADOPTED line.
[*] [b]Waiting if something's missing[/b]: if the required settings aren't fixed or Better Safehouse is still in the mod list, nothing is taken over and the panel shows "waiting" with the reason; it happens automatically on the next start after you fix it. Meanwhile old safehouses keep vanilla protection.
[/olist]
[h3]After the takeover[/h3]
[list]
[*] [b]Members[/b]: existing members (including Better Safehouse co-managers) become regular shares with Member, Use appliances, Move furniture, Build and Farm, without Invite or Manage; the owner can adjust them later.
[*] [b]Slots[/b]: taken-over safehouses all count as tier 1 and use the owner's tier 1 free slots first; any beyond that are kept too and need no paid slots, but to build another tier 1 safehouse the owner needs a free slot to open up or a paid slot.
[*] [b]Roads and resource sites[/b]: old safehouses covering them are kept too.
[*] [b]Redraw[/b]: taken-over safehouses can't be redrawn.
[*] [b]Names[/b]: names over 40 characters are shortened.
[*] [b]Respawn points[/b]: a vanilla or Better Safehouse "respawn in safehouse" tick becomes this mod's respawn point (the middle of that safehouse).
[*] [b]Not carried over[/b]: safehouse chat.
[*] [b]Better Safehouse data[/b]: its records in the world data are neither read nor changed.
[*] [b]Better Safehouse deeds[/b]: its own deed items (5 kinds in 3.1.1) disappear from players and containers on the first load after it's removed from Mods=, and don't come back if it's re-added.
[*] [b]Compensation[/b]: if you want to compensate players, hand out this mod's deeds instead; announce it before switching.
[*] [b]Crash after takeover[/b]: if the server crashes before the world saves, it's repaired automatically on the next start. Anything that really doesn't match shows under "Claims needing attention"; press "Rebind" or "Release…".
[/list]
[h3]Left as vanilla safehouses[/h3]
These stay where they are as vanilla safehouses; this mod doesn't manage them or delete them on its own:
[list]
[*] Invalid area or invalid owner name.
[*] Same area or same top-left corner as another safehouse.
[*] Over the server-wide limit of 256.
[*] So many members that taking them over would crowd out future safehouses and shares (taken over oldest first, using at most half of the data space).
[/list]
[list]
[*] [b]List[/b]: the skip lines in Zomboid/Lua/MinidoracatSafehouse/<server name>/migration-completion.txt.
[*] [b]They never expire[/b]: idle reclaim leaves them alone, and the vanilla expiry is off because SafeHouseRemovalTime must be 0, so they never go away on their own; the same goes for vanilla safehouses that appear after this mod is installed.
[*] [b]Handling them[/b]: "Teleport" there to take a look, or "Release…" them, from the admin panel's Vanilla safehouses tab.
[/list]
[h3]Rolling back[/h3]
[list]
[*] [b]To undo the takeover[/b]: stop the server and restore the save, server settings file, mod list and Zomboid/Lua/MinidoracatSafehouse/<server name>/ from the step 1 backup.
[*] [b]Keep migration-completion.txt[/b]: crash repair needs it.
[/list]
=== ⚙️ Before removing this mod
[list]
[*] [b]Deeds disappear[/b]: on the first load after removal, and they don't come back if you reinstall.
[*] [b]Existing safehouses[/b]: stay in the world, members keep vanilla protection and can leave with the vanilla "Quit Safehouse".
[*] [b]No one can manage them[/b]: the owner is this mod's service account, so only vanilla admin tools can handle them.
[*] [b]SafeHouseRemovalTime[/b]: if you later set it above 0, vanilla deletes safehouses no member has entered for that many real-time hours.
[*] [b]Back up the sandbox file[/b]: <server name>_SandboxVars.lua (see "Sandbox options and defaults").
[/list]
=== ⚙️ Where data is stored
Server-side data:
[table]
[tr][th]What[/th][th]Where[/th][/tr]
[tr][td]Safehouse list (area, owner, sharing, status)[/td][td]global_mod_data.bin in the world save (readable by everyone: no Steam accounts or private data)[/td][/tr]
[tr][td]The vanilla safehouses themselves[/td][td]map_meta.bin in the world save[/td][/tr]
[tr][td]Account-to-Steam bindings, personal tier 1 free slots, players' respawn points[/td][td]Zomboid/Lua/MinidoracatSafehouse/<server name>/private.txt[/td][/tr]
[tr][td]Takeover records[/td][td]migration-completion.txt in the same folder[/td][/tr]
[tr][td]Creation records for crash recovery[/td][td]crash-journal.txt in the same folder (cleared at start-up when there's nothing to restore)[/td][/tr]
[tr][td]No-build zones set by admins[/td][td]zones.txt in the same folder[/td][/tr]
[tr][td]Audit log[/td][td]Zomboid/Logs/*_MinidoracatSafehouse.txt (one line per event; refusals summed up once a minute)[/td][/tr]
[/table]
[list]
[*] [b]Backups and restores[/b]: include Zomboid/Lua/MinidoracatSafehouse/<server name>/ whenever you handle the save.
[*] [b]Rules[/b]: live in the server's sandbox file; see "Sandbox options and defaults".
[/list]
=== ⚠️ Known limitations
[list]
[*] [b]Zombies can still spawn inside[/b]: vanilla safehouses don't stop it, and neither does this mod.
[*] [b]Vanilla protection[/b]: the server stops vanilla clients, but modified clients may get around protection that's only checked client-side; the fine-grained permissions (Use appliances, Move furniture, Build, Farm) are only reliable against vanilla clients. Vehicles too: a modified client may drive in, and the server then takes anyone aboard who can't enter out of the vehicle and outside, leaving the vehicle where it is.
[*] [b]No door or window permission[/b]: the server can't stop opening doors with E or toggling windows directly; whether non-members can open doors follows vanilla.
[*] [b]No visitors[/b]: "Member" covers both entering and container access, so there's no "enter but don't take" role.
[*] [b]Safehouse data is public[/b]: vanilla sends every safehouse's area, owner and members to every player who logs in, so modified clients can see it.
[*] [b]Members removing themselves[/b]: a member who removes themselves with vanilla commands is teleported outside; the list is fixed on the next pass, the position isn't.
[*] [b]Multi-piece safehouses[/b]: each piece is a separate vanilla safehouse, so a removed player may first land in another piece and is moved out again within about 20 seconds; the higher the piece limit, the more often.
[*] [b]Server crashes[/b]: changes since the last world save roll back to the save. A just-created safehouse is the exception: it's restored on restart with the area, name and tier it was created with (sharing added later must be set again); released ones aren't restored. If the server crashed within 3½ minutes of creating it, the deed may have gone back to the owner, so it's listed under "Claims needing attention" in the admin panel (marked CRASH_UNCONFIRMED) instead: ask the owner, then press "Release…" if they still have the deed, or "Rebind" it to the original owner if they don't.
[*] [b]Idle release counts visits, not logins[/b]: being online without going back doesn't reset the countdown; stepping into the area resets it within about 20 seconds.
[*] [b]Server-wide limit[/b]: 256 safehouses (taken-over ones included).
[*] [b]What item search can see[/b]: bags lying on the floor, corpses and what players carry are not listed, and bags inside containers are opened one level deep only. The game already sends the contents of nearby containers to every player, so the search reveals nothing new.
[/list]
[h3]Player identity[/h3]
[list]
[*] [b]Automatic binding[/b]: on Steam servers, a player's username is bound to the Steam account they log in with (also when creating a character or a safehouse); after that, a different Steam account can't manage it.
[*] [b]Signs of renaming[/b]: no binding if the same Steam account just made a character under another name, or the previous character in the same slot just died and the name changed.
[*] [b]Names never seen since install[/b]: go by name until that player logs in, so a modified client could claim such a name first.
[*] [b]Split-screen[/b]: vanilla factions and safehouse lists go by name, and split-screen players can type someone else's name; turning off AllowCoop is recommended.
[*] [b]No-steam servers[/b]: renaming on respawn isn't prevented.
[*] [b]Switching Steam accounts[/b]: you're treated as someone else; there's no unbinding yet.
[/list]
[h3]Required versions[/h3]
[list]
[*] [b]MiniMap 42.21.0-0.42.0 or later[/b]: parking lots near homes; older versions only block main roads near homes.
[*] [b]MiniMap 42.21.0-0.43.0 or later[/b]: minimap safehouse labels show the real owner; older ones show the service account @MSH:<number>.
[*] [b]MiniMap 42.21.0-0.43.1 or later[/b]: multi-piece safehouses merge into one outline on the minimap; older ones draw each piece.
[*] [b]Economy[/b]: needs a version that supports safehouse slots; with an older one, paid slots don't work.
[/list]
[h3]Not included[/h3]
[list]
[*] Blocking zombies.
[*] Moving or expanding a safehouse (only redrawing right after creation).
[*] Buying and selling land.
[*] A server-wide map browser or teleporting (only admins can teleport to no-build zones from the zone window, using the vanilla command).
[*] Keeping vanilla safehouse chat in sync.
[*] Adding new deed kinds in game (8 tiers max).
[/list]
=== ❓ FAQ
[h3]Why can't I create one in single player or on my own hosted server?[/h3]
[list]
[*] This mod only supports dedicated multiplayer servers; elsewhere you'll see "Safehouse management only works on a dedicated server."
[/list]
[h3]It keeps saying the area covers a road?[/h3]
[list]
[*] Main roads, streets and parking lots can't be claimed by default, nor anything within 1 tile outside the area.
[*] Near a home and its detached garage or shed only main roads and parking lots block, so your driveway is fine.
[*] Town roads cut land into small plots; large areas mostly fit in the countryside.
[/list]
[h3]I marked the wrong area?[/h3]
[list]
[*] Use "Redraw" within 30 minutes of creating it (per server settings); no extra deed is used.
[*] After that, abandon and create a new one; abandoning doesn't refund the deed.
[/list]
[h3]Sharing says the player isn't known?[/h3]
[list]
[*] The name must match exactly, including case; picking from the suggestions under the box is safest.
[*] The server doesn't know players who never joined; share once they're online.
[/list]
[h3]My safehouse says "Suspended (lease expired)"?[/h3]
[list]
[*] The paid slot's lease ended and the grace period is over.
[*] Renew in the slots window to restore protection; it's released if not renewed within the keep period (7 days by default).
[/list]
[h3]My safehouse was released?[/h3]
[list]
[*] Safehouses nobody visits for too long are released like an abandon, and the deed isn't returned; the "Idle release" row on Overview shows how long is left.
[*] If you can't log in for a while and the server sells it, press "Extend" to buy insurance first.
[/list]
[h3]Why are there zombies inside?[/h3]
[list]
[*] Vanilla safehouses don't stop zombie spawns, and neither does this mod.
[/list]
[h3]Others can open my doors?[/h3]
[list]
[*] Doors and windows have no permission and follow vanilla rules; the server can't stop opening doors with E or toggling windows directly.
[/list]
[h3]Removed, then back inside?[/h3]
[list]
[*] Each piece of a multi-piece safehouse is a separate vanilla safehouse, so a removed player may land in another piece first and is moved out again within about 20 seconds.
[/list]
[h3]Several outlines for one safehouse on the minimap, or an @MSH label?[/h3]
[list]
[*] Update MiniMap to 42.21.0-0.43.1 or later to get one outline and the real owner's name.
[/list]
[h3]Are safehouses kept if the server removes this mod?[/h3]
[list]
[*] Safehouses stay and members keep vanilla protection, but deeds disappear and no one can manage them in game.
[*] Read "Before removing this mod" first.
[/list]
=== 💬 Feedback
[list]
[*] [b][url=https://discord.gg/Gur2V67]Discord[/url][/b] or [b][url=https://github.com/Minidoracat/MinidoracatSafehouseFor42/issues]GitHub Issues[/url][/b]: please include
[list]
[*] the server's mod list and versions
[*] what happened and the steps
[*] any messages or errors on screen
[*] the safehouse's number from the manager window
[/list]
[*] [b]Related[/b]:
[list]
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701]Minidoracat UI Library[/url]
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763913359]Minidoracat MiniMap[/url]
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3801482125]Minidoracat Economy[/url]
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3809297109]Full collection[/url]
[/list]
[/list]
