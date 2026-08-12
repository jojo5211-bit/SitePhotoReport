# 工程照片整理器 SitePhoto Report

工程現場照片整理與報告產生工具，包含 Windows 桌面版與 Android 手機版。專案以離線優先為原則：原始照片保留在工程資料夾，旋轉、馬賽克、編號與報告圖片都以非破壞式副本或渲染結果處理。

目前原始碼版本：

- Windows 桌面版：`0.8.0`
- Android 手機版：`1.1.2+13`

## 功能概覽

- 建立工程、工程項目與動態照片欄位。
- 照片批次匯入、未分類整理、日期／檔名排序、拖放分類與多選操作。
- 照片旋轉、馬賽克遮蔽、說明與施工位置編輯。
- API 設定與 AI 視覺分類建議；人工修正永遠優先。
- PDF、Word、Excel 輸出，含多種 PDF 版型與 1／2／4／6 張照片配置。
- 工程資料、版本更新紀錄、使用說明、備份與輸出資料夾管理。

## 專案結構

```text
工程驗收/
├─ app/                    # Windows PySide6 桌面版原始碼
├─ tests/                  # Windows 單元測試
├─ mobile/                 # Flutter Android 手機版原始碼
├─ docs/                   # PRD、資料結構、畫面流程、使用說明、更新紀錄
├─ requirements.txt        # Windows Python 相依套件
├─ build.ps1               # Windows PyInstaller／Inno Setup 建置腳本
├─ SitePhotoReport.spec    # 可跨電腦使用的 PyInstaller spec
└─ installer.iss           # Inno Setup 安裝程式腳本
```

## Windows 桌面版：開發與執行

```powershell
py -3 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
python run.py
```

測試：

```powershell
python -m unittest discover -s tests -v
```

建置：

```powershell
.\build.ps1
```

建置會先執行測試，再產生 `dist\SitePhotoReport`。若安裝 Inno Setup 6，也會產生 `installer-output\SitePhotoReport_Setup_0.8.0.exe`。不需要把 Python 安裝到使用者電腦。

## Android 手機版：開發與建置

```powershell
cd mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

手機版的詳細說明請參考 [mobile/README.md](mobile/README.md)。正式 APK 不放在原始碼 repository；建置產物會被 `.gitignore` 排除。

## 文件

- [使用說明](docs/USER_GUIDE.md)
- [完整功能與使用流程](docs/FEATURES_AND_USAGE.md)
- [手機版使用指南](docs/MOBILE_GUIDE.md)
- [桌面版更新紀錄](docs/CHANGELOG.md)
- [手機版更新紀錄](docs/MOBILE_CHANGELOG.md)
- [資料結構](docs/DATABASE.md)
- [畫面流程](docs/UI_FLOW.md)
- [產品規格](docs/PRD.md)
- [建置與發布](docs/BUILD_AND_RELEASE.md)
- [開發任務與驗收](docs/TASKS.md)

## 介面截圖

以下圖片是以「照片預覽」佔位圖製作的 UI 示意，不含任何使用者工程照片；另外提供桌面版與手機版畫面，方便了解操作配置。

![Windows 桌面版工作區 UI 示意](docs/images/desktop-ui-mockup.svg)

![Android 手機版欄位 UI 示意](docs/images/mobile-ui-mockup.svg)

![Android PDF 預覽 UI 示意](docs/images/mobile-pdf-mockup.svg)

## 工程資料與隱私

工程專案通常是獨立的 `.sprj` 資料夾，包含 SQLite 資料庫、原始照片、縮圖、編輯副本與 `exports`。工程資料、API Key、`local.properties`、簽章檔、APK 與 build 快取不應提交到 GitHub；本 repository 只保存可重建程式所需的原始碼、文件、測試與建置腳本。

使用外部視覺 API 前，請確認業主或工地照片可以上傳至該服務。API 設定僅保存在本機使用者設定檔，不會由本專案提供任何金鑰。

## 授權與使用範圍

本專案採用 [PolyForm Noncommercial License 1.0.0](LICENSE)。允許非商業用途的使用、修改與散布；禁止商業用途。

因為本授權禁止商業使用，嚴格來說本專案屬於「可取得原始碼的非商業授權」（source-available），不是 OSI 定義的 Open Source。若需要商業使用或其他授權安排，請先取得著作權人書面同意。
