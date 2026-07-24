# Bat Scheduler

在網頁輸入 `.bat` 路徑與時間，透過 **Windows 工作排程器** 在指定時刻自動執行。

**系統設計文件：** [docs/DESIGN.md](docs/DESIGN.md)

## 使用方式

1. 雙擊 `start.bat`，或在 PowerShell 執行：

```powershell
powershell -ExecutionPolicy Bypass -File .\server.ps1
```

2. 瀏覽器開啟：http://localhost:8787/

3. 填入：
   - Bat 檔完整路徑（例如 `C:\Scripts\backup.bat`）
   - 執行日期與時間
   - （選填）每天同時間重複、任務名稱

4. 按「建立排程」，或只填路徑後按「立刻執行」立即跑 bat

## 說明

- 排程實際寫入 Windows「工作排程器」，資料夾名稱為 `BatScheduler`
- 伺服器關閉後，已建立的排程仍會依時間執行
- 可在網頁刪除排程，也會一併移除系統工作
- 本機清單保存在 `data/schedules.json`
- 執行紀錄保存在 `data/executions.json`（含成功/失敗、結束代碼、耗時）
- **此功能上線後新建立的排程**才會在自動觸發時寫入紀錄；舊排程請刪除後重建

## 對外網址（Cloudflare Quick Tunnel）

1. 先確保本機伺服器在跑（`start.bat`），或直接用：
2. 雙擊 **`start-tunnel.bat`**（會下載 `tools/cloudflared.exe` 並建立隧道）
3. 終端機會顯示 `https://xxxx.trycloudflare.com`，並寫入 `data/tunnel-url.txt`

關閉隧道視窗即停止對外連線；本機 `8787` 仍可繼續用。Quick Tunnel 網址在重開後會變，且需保持此電腦開機、腳本在跑。

## 登入與使用者

- 首次啟動會建立管理者：`admin` / `3M1234`（密碼以雜湊儲存於 `data/users.json`）
- 未登入會導向 `/login.html`；登入後進入 **`/menu.html` 主選單**
- 主選單可進入 **執行排程**（`scheduler.html`）或 **維護使用者**（`users.html`，僅 admin）

## 注意

- 首次啟動若無法綁定埠號，請用系統管理員執行一次：

```powershell
netsh http add urlacl url=http://localhost:8787/ user="%USERDOMAIN%\%USERNAME%"
```

- 一次性排程的時間必須晚於現在
- 僅接受存在的 `.bat` 檔案
