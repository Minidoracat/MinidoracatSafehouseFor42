# 公開 API：`MinidoracatSafehouse.v1`

給其他 MOD 用的介面。伺服器與客戶端是不同的 Lua 狀態，各自有一份 `v1`，用 `CAPABILITIES` 判斷有沒有某個功能。

| 版本 | 新增 |
|---|---|
| `API_REVISION` 1 | `ownerName`（客戶端） |
| `API_REVISION` 2 | `denies`、`BITS`（伺服器與客戶端都有） |

```lua
local api = MinidoracatSafehouse and MinidoracatSafehouse.v1
local ok = api ~= nil and api.API_MAJOR == 1 and type(api.CAPABILITIES) == "table" and api.CAPABILITIES.denies == true
```

沒裝本 MOD、或版本不夠時 `ok` 是 false：照你自己的規則處理（通常是只查原版安全屋）。

## `denies(player, x, y, z, bit[, opts])`

問「這位玩家能不能在這一格做這類事」。只回答本 MOD 管的安全屋。兩邊簽名相同；伺服器的答案才是防線，客戶端的只給畫面提示用。

參數：

| 參數 | 內容 |
|---|---|
| `player` | `IsoPlayer`。伺服器用本 MOD 綁定的帳號判斷身分，不看客戶端送來的名字。分割畫面第 2–4 位玩家在本 MOD 的安全屋裡一律被拒（兩邊都是）。 |
| `x`, `y`, `z` | 有限的數字，小數照 `math.floor`。安全屋是平面範圍、每一層都算，所以 `z` 不影響結果；格子不必存在。 |
| `bit` | `v1.BITS.USE`（用電器、水、燈）、`v1.BITS.MOVE`（搬家具）、`v1.BITS.BUILD`（建造、拆、路障）、`v1.BITS.FARM`（農耕）。數值是本 MOD 的分享位元，不要寫死數字。 |
| `opts` | 可省略。表，欄位見下。 |

`opts` 的欄位（只有伺服器看；客戶端的 `denies` 本來就不寫稽核、不推通知）：

| 欄位 | 型別 | 預設 | 內容 |
|---|---|---|---|
| `preview` | boolean | `false` | `true`＝只判定，不寫稽核、不推通知。給伺服器上會一直查的地方用。 |
| `label` | string | `"v1.denies"` | 稽核記錄的動作名。建議寫成 `<你的 MOD>:<動作>`；裡面的直線符號 `\|` 會換成 `/`。 |

回傳：

| 結果 | 意思 |
|---|---|
| `false` | 放行：不在本 MOD 的安全屋、是屋主，或有這個權限 |
| `true, "PERM_DENIED"` | 在本 MOD 的安全屋裡，而且沒有這個權限 |
| `true, "BAD_ARGS"` | 參數不對（沒有玩家、座標不是有限數字、`bit` 不是上面四種、`opts` 不是表）；不丟錯 |

### 伺服器

拒絕而且 `preview` 不是 `true` 時，本 MOD 會：

- 寫稽核：`DENY <帳號> <label>@<安全屋編號> PERM_DENIED`，同一人同一動作每分鐘聚合成一行。
- 下一個 tick 推 `denied` 給這位玩家，本 MOD 的客戶端顯示「你在這間安全屋沒有「○○」權限。」。你不必自己再提示一次。

成本：每次呼叫走一次本 MOD 的安全屋紀錄（最多 256 間），不配置記憶體。一個動作逐格查二、三十格沒問題。

### 客戶端

讀本機的資料：玩家看得到的原生安全屋清單，加上本 MOD 的「我的安全屋」清單（進服第一個 tick 抓、權限有變時伺服器通知後重抓）。所以：

- 屋主剛改權限時，客戶端的答案晚一點才跟上；最後還是伺服器說了算。
- 每次呼叫走一次原生安全屋清單。建議游標換格時才查，不要每幀查。

### 用法範例

| 時機 | 在哪一邊 | 查法 |
|---|---|---|
| 游標預覽（虛影變紅、寫原因） | 客戶端 | 每一格 `denies(player, x, y, z, BITS.BUILD)` |
| 伺服器收到請求、還沒開工的檢查 | 伺服器 | 每一格加 `{ preview = true }`，失敗就拒絕請求 |
| 動作完成、真的要放物件 | 伺服器 | 每一格 `denies(..., BITS.BUILD, { label = "MyMod:build" })`，有一格是 `true` 就整個不做 |
| 按開關 | 伺服器 | 開關那一格查一次 `BITS.USE` |
| 接線 | 伺服器 | 開關格與每盞燈的格各查一次 `BITS.BUILD` |

```lua
-- 伺服器端 timed action 的 complete()：逐格查，一格不行就整個不做
function MyBuildAction:complete()
    local api = MinidoracatSafehouse and MinidoracatSafehouse.v1
    if api and api.API_MAJOR == 1 and api.CAPABILITIES and api.CAPABILITIES.denies then
        for _, c in ipairs(self.cells) do
            if api.denies(self.character, c.x, c.y, c.z, api.BITS.BUILD, { label = "MyMod:build" }) then
                return false
            end
        end
    end
    -- 原版安全屋另外查（見下一節），然後才放物件
    return true
end
```

### 原版安全屋要自己查

`denies` 不看原版安全屋（不歸本 MOD 管的）。原版的判斷照原版：

- 格子存在：`SafeHouse.isSafeHouse(square, username, true)`。
- 照座標查：`SafeHouse.getSafehouseOverlapping(x, y, x + 1, y + 1)`（`SafeHouse.java:181-189`）找出那間，再比屋主與成員。

本 MOD 的安全屋底下也有原版安全屋（屋主是 `@MSH:<編號>`，名單是有成員資格的人），所以原版的檢查也會擋到非成員；細分權限只有 `denies` 判斷得到。

## 客戶端：`ownerName(owner)`

`owner` 是原生 `SafeHouse:getOwner()` 的字串。本 MOD 的安全屋（`@MSH:<編號>`）回真正屋主的帳號名；資料還沒到或不是本 MOD 的安全屋回 nil。不配置記憶體、不丟錯，每幀呼叫也可以（查本機快取）。

資料來自本 MOD 公開的 Global ModData，第一次查不到時才向伺服器要一次，之後節流（細節在 `client/MinidoracatSafehouse/PublicApi.lua` 檔頭）。
