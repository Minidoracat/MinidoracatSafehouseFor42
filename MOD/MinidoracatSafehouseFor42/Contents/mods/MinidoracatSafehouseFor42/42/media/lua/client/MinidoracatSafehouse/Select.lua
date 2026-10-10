-- MinidoracatSafehouse/Select.lua：建立面板的兩種框選工具（計畫 §7.2）。只產生提案矩形，伺服器不看玩家怎麼選。
--   拖曳（drag）：照原版動物區工具 media/lua/client/ISUI/Animal/ISAddDesignationAnimalZoneUI.lua——
--     滑鼠按下／移動／放開（:47-75）、pickSquare 以 screenToIsoX/Y 取格（:296-302）、addAreaHighlightForPlayer 畫框（:271）、
--     手把以十字鍵逐格移動游標，〔設第一角〕後改移動終點（:355-398；onClick ADD :332-349）。
--   走位（walk）：照原版管理員安全區工具 media/lua/client/ISUI/AdminPanel/ISAddSafeZoneUI.lua——
--     起點＝按〔設第一角〕時玩家所在格（:176）、終點＝玩家目前位置（:84）、每幀畫範圍（:107）。
-- 預覽每個 UI 幀重加、只畫一層（§2.8）：由建立面板的 prerender 呼叫 Sel.draw。
-- 每幀路徑（update／bounds／draw）不配置 table 或 closure。
-- 出處：反編譯 D:/github/pz-decompiled-reference/snapshots/42.21.0-20260928/pz/zombie/Lua/LuaManager.java
--   screenToIsoX/Y :3795、:3806；getMouseX/Y :8014、:8046；wasMouseActiveMoreRecentlyThanJoypad :6421；
--   addAreaHighlightForPlayer(playerIndex, x1, y1, x2, y2, z, r, g, b, a)（x2/y2 不含）:12519。

if not isClient() then return end

require "MinidoracatSafehouse/Contract"

local MSH = MinidoracatSafehouse
local S = MSH.Select or {}
MSH.Select = S

S.DRAG = "drag"
S.WALK = "walk"

-- s = { tool, playerNum, ax, ay（第一角）, bx, by（終點）, cx, cy（手把游標）, dragging }
function S.new(tool, playerNum)
    return { tool = tool == S.WALK and S.WALK or S.DRAG, playerNum = playerNum or 0, dragging = false }
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

-- ===== 拖曳：滑鼠（只有 0 號玩家有滑鼠，原版每個 handler 第一行 :48、:63、:72）=====
function S.mouseDown(s, player)
    if s.tool ~= S.DRAG or s.playerNum ~= 0 or player == nil then return false end
    local _, _, z = cellOf(player)
    local x, y = S.pick(s, getMouseX(), getMouseY(), z)
    s.ax, s.ay, s.bx, s.by, s.dragging = x, y, x, y, true   -- 放開後再按一次＝重新拉一個範圍
    setWorldMenu(true)
    return true
end

function S.mouseMove(s, player)
    if not s.dragging or player == nil then return end
    local _, _, z = cellOf(player)
    s.bx, s.by = S.pick(s, getMouseX(), getMouseY(), z)
end

function S.mouseUp(s)
    s.dragging = false
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

-- 每幀：走位的終點跟著玩家（ISAddSafeZoneUI :84）
function S.update(s, player)
    if s.tool == S.WALK and s.ax ~= nil and player ~= nil then
        s.bx, s.by = cellOf(player)
    end
end

-- 兩角（inclusive）→ x, y, w, h；還沒有第一角回 nil。換算同 MSH.Rect.fromCorners，但不配置 table（每幀用）
function S.bounds(s)
    if s.ax == nil then return nil end
    local x0, x1 = math.min(s.ax, s.bx), math.max(s.ax, s.bx)
    local y0, y1 = math.min(s.ay, s.by), math.max(s.ay, s.by)
    return x0, y0, x1 - x0 + 1, y1 - y0 + 1
end

function S.rect(s)
    if s.ax == nil then return nil end
    return MSH.Rect.fromCorners(s.ax, s.ay, s.bx, s.by)
end

-- 重新框選：清掉兩角，留著手把游標
function S.reset(s)
    s.ax, s.ay, s.bx, s.by, s.dragging = nil, nil, nil, nil, false
end

-- 離開框選（完成、取消、關窗、死亡）：還原世界選單
function S.stop(s)
    s.dragging = false
    setWorldMenu(false)
end

-- 每個 UI 幀重加一次（只畫一層）；有範圍畫範圍，沒有就畫游標格（:304-320）
function S.draw(s, player, r, g, b, a)
    if player == nil then return end
    local px, py, z = cellOf(player)
    local x, y, w, h = S.bounds(s)
    if x ~= nil then
        addAreaHighlightForPlayer(s.playerNum, x, y, x + w, y + h, z, r, g, b, a)
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
    addAreaHighlightForPlayer(s.playerNum, cx, cy, cx + 1, cy + 1, z, r, g, b, 1)
end
