# Repository 結構

## 桌面版

- `app/`：PySide6 介面、SQLite 儲存、照片匯入、分類與輸出。
- `tests/`：儲存層、介面行為與視覺分類測試。
- `requirements.txt`：Python 相依套件。
- `SitePhotoReport.spec`、`build.ps1`、`installer.iss`：Windows 建置鏈。

## 手機版

- `mobile/lib/`：Flutter 畫面、狀態、資料模型、照片編輯與報告服務。
- `mobile/test/`：編號、日期排序、報告輸出、欄位排序與 Widget 測試。
- `mobile/android/`：Android 專案與 Gradle wrapper；本機 `local.properties` 不提交。
- `mobile/assets/`：報告使用的中文字型資源。

## 不提交的內容

`.sprj` 工程資料夾、`.hermes` 對話資料、`.codex-remote-attachments` 附件、Python／Flutter build 快取、APK／AAB、API Key、keystore 與 Android 本機設定都不屬於可分享原始碼，因此由根目錄 `.gitignore` 排除。

## 資料邊界

桌面版與手機版都保留原始照片，不把照片內容或使用者 API 設定寫入 repository。報告輸出資料夾屬於使用者工程資料；GitHub 只保存程式如何產生報告的邏輯。
