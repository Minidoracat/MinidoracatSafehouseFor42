# Minidoracat Safehouse for B42

提供分級地契、自訂安全屋區域、陣營成員管理，以及道路與資源點排除的安全屋系統

Project Zomboid Build 42 MOD。

## 開發狀態

目前只建立專案與 MOD 基本骨架，尚未加入遊戲內安全屋功能。

## 規劃功能

- 依地契等級限制可設定的安全屋大小
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
