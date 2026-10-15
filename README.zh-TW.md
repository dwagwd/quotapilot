# Codex Usage Widget

原生 macOS 桌面用量小卡，顯示方案額度、Codex 帳號 token 速度與重置倒數。使用 AppKit／Swift，不需要瀏覽器執行環境，不透過模型對話輪詢。

[English](README.md) · [MIT 授權](LICENSE) · [隱私](PRIVACY.md) · [其他 agent 連接指南](docs/providers.md)

非官方社群專案，與 OpenAI、Anthropic、Google、Cursor 無隸屬或背書關係。

## 功能

- 主卡 260 × 128 pt；收合為 182 × 32 pt。支援拖曳、記住位置、置頂、選單列與齒輪設定。
- 可以只顯示一個額度，或勾選最多四個額外額度一起顯示；卡片隨選擇增高，各來源分開計算。
- `%/時` 是額度「百分點／小時」的簡寫：一小時由 20% 至 25%，顯示 5%/時，不是相對成長率 25%。
- **依工作分派**：可分別指定需要網路／研究、程式碼審查、規劃、實作與其他工作交給 Codex、Claude 或自動，該 agent 額度不足時自動改派。
- **Orchestrator 模式**（Agent 協作…）：一個 agent 負責規劃與驗收，另一個只負責實作。可選 Claude Code → Codex（`orchestrate-codex`）或 Codex → Claude Code（`orchestrate-claude`），最多三輪修正，並先檢查額度。
- **小卡樣式**（設定）：詳細、精簡（每個 agent 一行，含各額度、速度、Token；標題列顯示全部總用量）或進度條（每個額度一條小進度條）。
- **Agent 協作**（選單列 → Agent 協作…）：可選擇給 Claude Code 加 `codex-review` skill（以 `codex exec` 唯讀獨立審查）、給 Codex 加 `claude-review` skill（以 `claude -p` plan 模式審查），以及另外讓 Codex 透過 MCP 使用 Claude Code 的工具。**額度路由**（自動／Codex 優先／Claude 優先）同時考慮 5 小時與週額度及重置時間；skill 委派前會先查路由，且不會重複往外委派。
- **用量統計** 視窗（選單列 → 用量統計…）：24h／7d／30d 的 Token 總量與每小時用量、各家曲線圖，以及各額度窗口的已用 % 曲線與每小時平均消耗百分點。首次啟動會回填本機紀錄中過去 30 天的資料。
- **全部 agent** 列：從本機紀錄統計 Codex 與 Claude Code（以及透過 Claude Code 使用的 DeepSeek、Kimi、GLM、Qwen）的 Token 總量，提示框列出各家的輸入／快取讀取／快取寫入／輸出／推理。只讀取 Token 數字，可在設定關閉。
- 重置列顯示剩餘額度與倒數（例如 `剩餘 57% · 重置 02:10:00`）。
- 可選的 Codex **自動繼續**（設定中，預設關閉）：額度用滿的窗口重置後，對中斷的 session 執行一次 `codex exec resume`，在原專案資料夾、沿用你的 Codex 設定，會啟動一次模型回合；輸出寫入 `auto-continue.log`。
- **自動連接 agent**（設定 → 自動連接偵測到的 agent，預設開啟）：偵測到 Claude Code、Antigravity 時自動安裝額度橋接；Claude Code 設定為 DeepSeek 或已存金鑰時顯示 DeepSeek 餘額。另可在設定開啟 **登入時自動開啟**。選單列的 **連接 agent…** 顯示狀態並可手動連接：一鍵連接 Claude Code 或 Antigravity 額度，或填入 DeepSeek API 金鑰（存於鑰匙圈）顯示餘額。
- 可選的額度提醒（設定 → 額度提醒，預設關閉）：額度達 90%，或照目前速度會在重置前用完時，每個重置週期發一次系統通知。需使用安裝後的 App。
- 速度預估：滑鼠移到額度速度上，可看到照目前速度在重置時的預估用量，或多久會達 100%。若會在重置前用完，速度文字會變橘色。這是線性外推，不是保證。
- 觀測期間可設 1 分鐘至 30 天；數值以分鐘／小時／天輸入，速度顯示單位獨立設定。
- 繁中、簡中、英文、日文、韓文、西班牙文、法文、德文、巴西葡萄牙文、義大利文與跟隨系統。任務與診斷新增文字目前提供中英文，其他語言會回退為英文。
- 文字與背景 RGB 三原色自訂（0–255），或使用系統外觀。
- 省電模式：每 120 秒讀取 Codex，每 15 秒更新畫面；一般模式為 60 秒／1 秒。隱藏時停止畫面計時，有新資料才重算速度。
- Claude Code 與 Antigravity CLI 官方 status-line 橋接。Cursor Teams 支援額外付費支出上限，並非個人方案額度。接入前請看[連接指南](docs/providers.md)。
- 新增 Codex 與橋接來源診斷、長期帳號用量事件帳本（資料缺口、帳號切換、額度重置與來源更正），以及本機任務起訖、專案／issue、模型／推理強度、重試次數和驗收結果紀錄。沒有 session 直接歸因來源時，任務 Token 用量保持未提供。

## 建置與安裝

需要 macOS 13+、Swift 5.9+／Xcode Command Line Tools、測試用 Python 3，以及已登入 ChatGPT 帳號的 Codex App 或 CLI。Codex 核心小卡不依賴 Python，其他 agent 橋接需要 Python 3。

**快速安裝：**從 [Releases](https://github.com/dwagwd/codex-plugin/releases/latest) 下載 `CodexUsageWidget-<版本>-macos-universal.zip`，解壓後把 **Codex Usage Widget.app** 移到「應用程式」。App 已簽章並經 Apple 公證，開啟時不會出現安全性警告。

**從原始碼建置：**先從 [Releases](https://github.com/dwagwd/codex-plugin/releases/latest) 下載來源 ZIP 並解壓，於資料夾開啟終端機；或先執行 `git clone https://github.com/dwagwd/codex-plugin.git codex-usage-widget`，再 `cd codex-usage-widget`。

```sh
./scripts/check.sh
./scripts/build-install.sh
./scripts/launch.sh
```

安裝於 `~/Applications/Codex Usage Widget.app`。重複啟動只顯示原本的小卡；不設定登入自動啟動。齒輪可調整偏好設定；點標題切换主額度，拖曳空白處移動。滑鼠停在速度上可查看實際觀測長度與定義。

從選單列開啟「資料來源診斷」、開始／結束 Codex 任務紀錄、查看任務／用量事件或分別匯出兩種帳本。額度與帳號 Token 快照會和任務消耗分開保存；詳見[帳本原型說明](docs/task-ledger.md)。

## 數據定義

Codex 額度來自 `account/rateLimits/read`，tokens 來自 `account/usage/read` 的帳號累積回報。兩者獨立計算，不能用固定倍率互換。共享額度無法拆成各模型消耗；Spark 等獨立窗口則分開顯示。Token 回報可能延遲，速度 0 代表未回報增加。

預設觀測最近一小時。暖機需 5 分鐘或所選較短期間；不足完整期間顯示估算。重置、用量下降、帳號或方案切換、時鐘倒退、超過五分鐘中斷均重設基準。Codex 取樣時保留最近最多 31 天；停止時既有檔案會留到下次取樣或手動移除。多日估算需要連續觀測。Bridge 的速度歷史目前保存在記憶體，重開小卡會重新累積。

倒數歸零只表示等待來源確認；缺少資料顯示「—」。Claude／Antigravity 需要 CLI 回報，靜置或退出超過五分鐘會標記過期。其他 agent 的 context window 不被當成累積 token 消耗量。

## 開源準備

採 MIT。包含貢獻、安全回報、隱私、變更記錄、CI、手動打包 workflow 與來源匯出檢查。v0.4.0 起提供以 Developer ID 簽章並經 Apple 公證的通用版 App ZIP（Apple 晶片與 Intel 皆可），另附來源 ZIP 與 SHA-256 校驗碼。Codex 已實測；其他 agent 橋接仍屬實驗性功能，通過資料格式測試但尚未完成真實帳號驗證。

```sh
./scripts/package.sh
```

產出與建置快取預設在 `~/Library/Caches/CodexUsageWidget/`。發布步驟見 [releasing.md](docs/releasing.md)，測試範圍見 [validation.md](docs/validation.md)。

本機採樣在 `~/Library/Application Support/CodexUsageWidget/`，偏好設定屬於 `local.codex.usage-widget`。請勿將這些個人資料推送至 GitHub。移除時先退出 App；如有安裝其他 agent 橋接，依連接指南還原 statusLine 設定，再移除 App、資料及插件。
