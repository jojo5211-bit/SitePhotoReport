# 建置與發布

本 repository 保存可重建的原始碼與腳本；APK、Windows 安裝檔、工程照片與 API Key 不提交到 GitHub。

## Windows 桌面版

需求：Windows 10／11、Python 3.11+，若要產生安裝檔另需 Inno Setup 6。

```powershell
py -3 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
python -m unittest discover -s tests -v
python -m PyInstaller --noconfirm --clean SitePhotoReport.spec
```

或直接執行：

```powershell
.\build.ps1
```

輸出位置：

- 可攜式程式：`dist\SitePhotoReport\`
- Inno Setup 安裝檔：`installer-output\SitePhotoReport_Setup_0.8.0.exe`

`SitePhotoReport.spec` 會從目前 Python 執行環境尋找 OpenSSL DLL，不含任何開發者電腦的絕對路徑。

## Android 手機版

需求：Flutter SDK（Dart SDK 版本依 `mobile/pubspec.yaml`）。

```powershell
cd mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

Release APK 預設產生於 `mobile\build\app\outputs\flutter-apk\app-release.apk`；此類產物已被忽略，不會污染 Git 歷史。正式簽章請使用本機未提交的 `key.properties` 與 keystore。

## 版本規則

- 桌面版版本需同步更新 `docs/CHANGELOG.md`、`installer.iss` 與 `build.ps1` 的輸出名稱。
- 手機版版本需更新 `mobile/pubspec.yaml` 的 `version`，並在 `docs/MOBILE_CHANGELOG.md` 記錄變更。
- 每個已交付版本使用獨立 tag，例如 `desktop-v0.8.0`、`android-v1.1.0`。
- 不覆蓋既有 release 檔案；同一檔名應由發布流程產生新版本或 `_1`、`_2` 後綴。

## 提交前檢查

1. 執行桌面版 unittest。
2. 執行 `flutter analyze` 與 `flutter test`。
3. 搜尋 API Key、token、私密金鑰與本機絕對路徑。
4. 確認 `.gitignore` 沒有漏掉 build、APK、工程資料與 API 設定。
5. 在乾淨環境測試啟動或安裝。
