-- MinidoracatSafehouse/Select.lua：建立面板的兩種框選工具（計畫 §7.2）與多塊範圍的編輯（使用者 2026-10-11 裁定）。
-- 只產生提案範圍，伺服器不看玩家怎麼選。每拉好一塊矩形就照目前的模式「加入」或「挖掉」，疊出的形狀與切塊在 Shape.lua；
--   〔復原〕退回上一步、〔清除〕清空（也能復原）。挖掉只在範圍不是空的時候有意義。
--   拖曳（drag）：照原版動物區工具 media/lua/client/ISUI/Animal/ISAddDesignationAnimalZoneUI.lua——
--     pickSquare 以 screenToIsoX/Y 取格（:296-302）；範圍畫在地板上（FloorTint：原版 addAreaHighlightForPlayer 會蓋住
--     站在範圍裡的人物，2026-10-12 使用者要求畫在人物下層），
--     手把以十字鍵逐格移動游標，〔設第一角〕後改移動終點（:355-398；onClick ADD :332-349），再按〔加入這塊〕。
--     滑鼠放開就照模式套用這一塊；點一下（沒拖）＝一格。
--     滑鼠不照原版用視窗的 onMouseDownOutside（:47-75）：子元件接走點擊後，引擎改呼叫父視窗的 onMouseDownOutside
--     （UIElement.java:1094-1110），按面板上的〔完成〕會變成在按鈕底下的地面重拉一個 1×1（2026-10-11 使用者實機）。
--     改由 Events.OnMouseDown 開始（UIManager.java:715-719：只有沒被任何 UI 接走的點擊才觸發），拖曳中每幀讀
--     isMouseButtonDown(0)（LuaManager.java:8027-8031）更新終點、放開就套用。
--   走位（walk）：照原版管理員安全區工具 media/lua/client/ISUI/AdminPanel/ISAddSafeZoneUI.lua——
--     起點＝按〔設第一角〕時玩家所在格（:176）、終點＝玩家目前位置（:84）、每幀畫範圍（:107），走到對角按〔加入這塊〕。
-- 地上的範圍由建立面板的 prerender 每幀呼叫 Sel.draw，交給 FloorTint：範圍、顏色或位置變了才動地板。
-- 每幀路徑（update／bounds／draw）不配置 table 或 closure（形狀結果在 Shape.result 快取到下一次改動）。
-- 出處：反編譯 D:/github/pz-decompiled-reference/snapshots/42.21.0-20260928/pz/zombie/Lua/LuaManager.java
--   screenToIsoX/Y :3795、:3806；getMouseX/Y :8014、:8046；isMouseButtonDown :8030；wasMouseActiveMoreRecentlyThanJoypad :6421。

if not isClient() then return end

require "MinidoracatSafehouse/Contract"
require "MinidoracatSafehouse/Shape"
require "MinidoracatSafehouse/FloorTint"

local MSH = MinidoracatSafehouse
local S = MSH.Select or {}
MSH.Select = S
local Shape = MSH.Shape

S.DRAG = "drag"
S.WALK = "walk"

-- 地面上框選的顏色與強度（FloorTint：把地板的光照色往顏色拉這個比例）。顏色不用主題的 accent（黃）：草地本來就偏黃綠，
-- 黃色染上去幾乎看不出來（2026-10-12 使用者選「換明顯一點的顏色」）。sh-tintcolor-1012b 在白天的院子草地上量和沒染的
-- 色差（Lab ΔE 中位數）：黃 0.75／1 是 6／7，青 16／19–22，藍、紫、橘也在 13–30，洋紅與紅最大但會和標紅搞混；取青色，
-- 草地變成一眼看得出的鮮綠、柏油路變青。標紅與超過上限仍用主題的 errorText。
-- 同一天使用者要「再高亮一點」：青色調亮成 (0.25, 1, 1)、各塊強度整體加 0.1。染色不會比地面本身亮（地板原色乘上這個
-- 顏色），只能更接近這個顏色：sh-tintbright-1012b 同一片草地，最深那塊和沒染的色差 22 → 24、亮度 L* 24 → 27（沒染 30）。
-- 地面顯示範圍的「我的」也用這個顏色（Ranges.COLORS.own）。
-- 各塊輪流用不同強度（草地上分界不明顯：sh-createtint-1012b）；拉到一半的那塊與游標格最深
S.FLOOR_OK = { r = 0.25, g = 1.0, b = 1.0 }
S.PIECE_TINT = { 0.95, 0.75, 0.88, 0.82 }
S.RAW_TINT = { 0.85 }
S.PENDING_TINT = 1.0
S.CURSOR_TINT = 1.0

-- s = { tool, playerNum, ax, ay（第一角）, bx, by（終點）, cx, cy（手把游標）, dragging, cut（挖掉模式）, shape }
-- rects：重新框選時從現有範圍開始；max：最多幾塊（不傳＝沙盒 MaxPieces，Shape.new；禁建區用硬上限 LIMIT.MAX_PIECES）
function S.new(tool, playerNum, rects, max)
    local s = { tool = tool == S.WALK and S.WALK or S.DRAG, playerNum = playerNum or 0, dragging = false, cut = false,
        shape = Shape.new(max) }
    if rects ~= nil then Shape.load(s.shape, rects) end
    return s
end

-- 玩家所在格（IsoMovingObject getX/getY/getZ；Claims.checkOnSite 用同一個 floor）
local function cellOf(player)
    return math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
end

-- 手把正在操作（原版 highlightSquareAtStartPosition 的判斷，ISAddDesignationAnimalZoneUI.lua:313-314）
function S.usingJoypad(s)
    return getJoypadData(s.playerNum) ~= nil and not wasMouseActiveMoreRecentlyThanJoypad()
end

-- 螢幕座標 → 格子（pickSquare :296-302；回傳 float，取整）
function S.pick(s, sx, sy, z)
    return math.floor(screenToIsoX(s.playerNum, sx, sy, z)), math.floor(screenToIsoY(s.playerNum, sx, sy, z))
end

local function setWorldMenu(disabled)
    -- 拖曳中右鍵不跳世界選單（原版 :58 設、reset :196 還原）
    if ISWorldObjectContextMenu then ISWorldObjectContextMenu.disableWorldMenu = disabled end
end

-- 換工具（拖曳／走位）：拉到一半的那塊取消，範圍與復原紀錄保留
function S.setTool(s, tool)
    s.ax, s.ay, s.bx, s.by, s.dragging = nil, nil, nil, nil, false
    s.tool = tool == S.WALK and S.WALK or S.DRAG
    setWorldMenu(false)
end

function S.result(s)
    return Shape.result(s.shape)
end

function S.isEmpty(s)
    return Shape.isEmpty(s.shape)
end

function S.canUndo(s)
    return s.ax ~= nil or Shape.canUndo(s.shape)
end

-- 模式：true＝挖掉。範圍是空的時候只能加入
function S.setCut(s, cut)
    s.cut = cut == true and not Shape.isEmpty(s.shape)
end

-- 把拉好的一塊照模式加入或挖掉；回 true＝形狀變了。手把游標留在這塊的終點，接著拉下一塊
function S.commit(s)
    if s.ax == nil then return false end
    local rect = MSH.Rect.fromCorners(s.ax, s.ay, s.bx, s.by)
    if s.tool == S.DRAG and s.cx ~= nil then s.cx, s.cy = s.bx, s.by end
    s.ax, s.ay, s.bx, s.by, s.dragging = nil, nil, nil, nil, false
    if s.cut and Shape.isEmpty(s.shape) then return false end
    local applied = Shape.apply(s.shape, rect, not s.cut)   -- 形狀已經太亂（分界線超過上限）時不套用
    if Shape.isEmpty(s.shape) then s.cut = false end
    return applied
end

-- 〔復原〕：先取消拉到一半的那塊，再退回上一步
function S.undo(s)
    if s.ax ~= nil then
        s.ax, s.ay, s.bx, s.by, s.dragging = nil, nil, nil, nil, false
        return true
    end
    local ok = Shape.undo(s.shape)
    if Shape.isEmpty(s.shape) then s.cut = false end
    return ok
end

-- 〔清除〕：清空範圍（可以復原）
function S.clear(s)
    s.ax, s.ay, s.bx, s.by, s.dragging = nil, nil, nil, nil, false
    local ok = Shape.clear(s.shape)
    s.cut = false
    return ok
end

-- ===== 拖曳：滑鼠（只有 0 號玩家有滑鼠，原版每個 handler 第一行 :48、:63、:72）=====
-- 地面上的點擊（Events.OnMouseDown）：按下的格子是這一塊的第一角
function S.mouseDown(s, player)
    if s.tool ~= S.DRAG or s.playerNum ~= 0 or player == nil then return false end
    local _, _, z = cellOf(player)
    local x, y = S.pick(s, getMouseX(), getMouseY(), z)
    s.ax, s.ay, s.bx, s.by, s.dragging = x, y, x, y, true
    setWorldMenu(true)
    return true
end

-- ===== 拖曳：手把十字鍵（onJoypadDir* :367-397）；走位不吃十字鍵 =====
function S.joyDir(s, player, dx, dy)
    if s.tool ~= S.DRAG then return false end
    if s.ax == nil then
        if s.cx == nil then s.cx, s.cy = cellOf(player) end   -- onGainJoypadFocus :358-360
        s.cx, s.cy = s.cx + dx, s.cy + dy
    else
        s.bx, s.by = s.bx + dx, s.by + dy
    end
    return true
end

-- 〔設第一角〕：拖曳＝手把游標（:334-339），走位＝玩家所在格（ISAddSafeZoneUI :176）
function S.mark(s, player)
    if player == nil then return false end
    local x, y
    if s.tool == S.WALK or s.cx == nil then x, y = cellOf(player) else x, y = s.cx, s.cy end
    s.ax, s.ay, s.bx, s.by = x, y, x, y
    if s.tool == S.DRAG then setWorldMenu(true) end
    return true
end

-- 每幀：拖曳中按著左鍵＝終點跟著游標、放開＝照模式套用這一塊（游標經過任何視窗都照算）；
-- 走位的終點跟著玩家（ISAddSafeZoneUI :84）。回 true＝形狀變了
function S.update(s, player)
    if player == nil then return false end
    if s.dragging then
        if isMouseButtonDown(0) then
            local _, _, z = cellOf(player)
            s.bx, s.by = S.pick(s, getMouseX(), getMouseY(), z)
        else
            return S.commit(s)
        end
    elseif s.tool == S.WALK and s.ax ~= nil then
        s.bx, s.by = cellOf(player)
    end
    return false
end

-- 拉到一半的那塊（兩角 inclusive）→ x, y, w, h；沒有回 nil。換算同 MSH.Rect.fromCorners，但不配置 table（每幀用）
function S.bounds(s)
    if s.ax == nil then return nil end
    local x0, x1 = math.min(s.ax, s.bx), math.max(s.ax, s.bx)
    local y0, y1 = math.min(s.ay, s.by), math.max(s.ay, s.by)
    return x0, y0, x1 - x0 + 1, y1 - y0 + 1
end

-- 離開框選（完成、取消、關窗、死亡）：還原世界選單
function S.stop(s)
    s.dragging = false
    setWorldMenu(false)
end

-- 每幀呼叫：範圍的各塊（"shape" 圖層，輪流的強度；形狀不合規則或 over＝超過大小上限時用 bad 色）、拉到一半的那塊
-- （"pending"：加入用 ok 色、挖掉用 bad 色），沒在拉時是游標格（:304-320）。FloorTint 只在範圍、顏色或位置變了時動地板
function S.draw(s, player, ok, bad, over)
    if player == nil then return end
    local px, py, z = cellOf(player)
    local res = Shape.result(s.shape)
    local c = (over or (res.err ~= nil and res.err ~= "EMPTY")) and bad or ok
    local Tint = MSH.FloorTint
    Tint.setRects("shape", res.draw, c, res.rects ~= nil and S.PIECE_TINT or S.RAW_TINT, z)
    local pc = s.cut and bad or ok
    local x, y, w, h = S.bounds(s)
    if x ~= nil then
        Tint.setRect("pending", x, y, w, h, z, Tint.color(pc, S.PENDING_TINT))
        return
    end
    local cx, cy = px, py
    if s.tool == S.DRAG then
        if s.cx ~= nil and S.usingJoypad(s) then
            cx, cy = s.cx, s.cy
        elseif s.playerNum == 0 then
            cx, cy = S.pick(s, getMouseX(), getMouseY(), z)
        end
    end
    Tint.setRect("pending", cx, cy, 1, 1, z, Tint.color(pc, S.CURSOR_TINT))
end
