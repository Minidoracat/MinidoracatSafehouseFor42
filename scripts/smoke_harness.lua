--[[
煙霧測試：用假的 PZ 全域載入**真正的** MOD Lua，跑行為情境並斷言結果。

    lua scripts/smoke_harness.lua        （repo 根目錄執行；標準 Lua 5.x 即可）
    lua scripts/smoke_harness.lua claims （只跑檔名含 claims 的情境）

假環境在 scripts/harness/env.lua，情境在 scripts/harness/t_*.lua（每檔回傳 function(T) ... end）。

為什麼需要（兩類 luac -p 抓不到的錯誤，皆為家族正式服實際事故）：
- 改函式簽章漏改呼叫點：語法完全合法，要等該路徑真的執行才炸
- 邏輯回歸：安全把關（範圍／阻隔／保護規則）被改壞時，「執行到並斷言」是唯一防線

限制（必須誠實面對）：這是標準 Lua，不是遊戲的 Kahlua。
- 標準 Lua 有 next/xpcall，Kahlua 沒有——本 harness **測不出**誤用，由 scripts/verify_mod.py 的靜態掃描負責
- Kahlua 專屬行為（table.sort 遞迴深度、Java instance field 不暴露、rawget 呼叫形式、
  每個 table 都是 LinkedHashMap 的記憶體成本）只能靠反編譯查證與實機測試

寫情境的原則：
- 情境要「執行到會炸的路徑」——刪除後的收尾、跨 tick 的第二輪、聚合輸出，都是重災區
- 安全邊界要有**反面**斷言（範圍外／被阻隔／受保護的對象必須存活），不是只測 happy path
- 新防線寫完先「植入違規證明它會抓」再信任它——測不出來的測試等於沒有測試
]]

local T = dofile("scripts/harness/env.lua")

local SCENARIOS = {
    "t_foundation",
    "t_exclusions",
    "t_claims",
    "t_reconcile",
    "t_migration",
    "t_admin",
    "t_deeds",
    "t_mirror",
    "t_sharing",
    "t_permissions",
    "t_economy",
    "t_client",
    "t_ui_create",
    "t_ui_manager",
    "t_ui_admin",
    "t_ui_entry",
}

local only = arg and arg[1]
local ran = 0
for _, name in ipairs(SCENARIOS) do
    if only == nil or string.find(name, only, 1, true) then
        local chunk = loadfile("scripts/harness/" .. name .. ".lua")
        if chunk then
            ran = ran + 1
            io.write("\n== " .. name .. " ==\n")
            local ok, err = pcall(function() chunk()(T) end)
            if not ok then
                T.check(false, name .. " 執行中丟錯：" .. tostring(err))
            end
        end
    end
end

io.write("\n")
if ran == 0 then
    io.write("沒有可跑的情境\n")
    os.exit(1)
end
if T.failures > 0 then
    io.write(T.failures .. " 項失敗（" .. T.passes .. " 項通過）\n")
    os.exit(1)
end
io.write("全部通過（" .. T.passes .. " 項）\n")
