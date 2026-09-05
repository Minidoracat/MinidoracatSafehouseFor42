# Minidoracat Safehouse for B42

提供分級地契、自訂安全屋區域、陣營成員管理，以及道路與資源點排除的安全屋系統

Project Zomboid Build 42 MOD。

## 開發狀態

目前只建立專案與 MOD 基本骨架，尚未加入遊戲內安全屋功能。

## 規劃功能

- 依地契等級限制可設定的安全屋大小
- 地契可免費取得，或透過 Economy 選用整合使用貨幣換取
- 安全屋可採日租或月租，並透過 Economy 選用整合扣款
- 由玩家自訂安全屋區域
- 排除道路與資源點
- 管理個人及陣營安全屋
- 同陣營成員自動加入安全屋
- 選用整合 `MinidoracatMiniMapFor42` 與 `MinidoracatEconomyFor42`

## 依賴策略

核心 MOD 維持獨立，不強制依賴 MiniMap 或 Economy；整合功能將在實作階段另行設計。

## 安裝

- Steam Workshop：（首次上傳後補上連結）
- 手動安裝：把 `MOD/MinidoracatSafehouseFor42/Contents/mods/MinidoracatSafehouseFor42` 複製到 `%USERPROFILE%\Zomboid\mods\` 並將資料夾改名為 `MinidoracatSafehouseFor42`

## 開發

- `link_workshop.bat`：把 repo 掛載到 `Zomboid\Workshop\` 與 `Zomboid\mods\`（符號連結，repo 改動即時生效）
- `PZ_Test.bat`：啟動測試（客戶端 / 專用伺服器 / 多客戶端組合）

## 版本

版本號格式：`{PZ 版本}-{mod 版本}`（例 `42.20.4-0.1.0`），詳見 [CHANGELOG.md](CHANGELOG.md)。

## 作者

Minidoracat — [Discord](https://discord.gg/Gur2V67) | [Twitch](https://www.twitch.tv/minidoracat)

### 發布到 Workshop

雙擊 `Publish_Workshop.bat`：先確認 Steam 用戶端已以作者帳號登入（未登入會喚起 Steam 並等你登入後重試），
再選擇更新 MOD 內容（含 `STEAM_CHANGELOG.md` 更新說明）／GIF 封面／簡介／全部；提交後回查 Steam，
任一不符即以非零碼結束。設定在 `scripts/workshop_publish.json`（Workshop ID、簡介語言槽來源、GIF 路徑）。

```
uv run --no-project python -B scripts/publish_workshop.py --mode all --yes       # 自動化／AI；或 content / preview / description
uv run --no-project python -B scripts/publish_workshop.py --mode all --dry-run   # 只檢查、顯示計畫
```

退出碼：`0` 成功／`2` 參數或取消／`3` 未登入、帳號不是擁有者／`4` 前置檢查失敗／`5` 提交失敗／`6` 已提交但回查不符。
網頁動態封面放 `MOD/<資料夾>/workshop/preview.gif`（不在 `Contents/`，不會下載給玩家）；遊戲內上傳器仍用 `preview.png`，
且每次會把網頁封面覆回靜態，需要動態封面時一律改用本工具發布。
