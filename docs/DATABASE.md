# 資料結構

每個工程是獨立資料夾：

```text
工程名稱.sprj/
├─ project.sqlite
├─ project.json
├─ originals/
├─ thumbnails/
├─ previews/
├─ assets/
└─ exports/
```

SQLite 主要資料表：

- `project`：工程基本資料，單一列。
- `sections`：工程項目及項目排序。
- `slots`：項目內的動態照片欄位及欄位排序。
- `photos`：原始檔名、相對路徑、雜湊、尺寸與拍攝時間。
- `placements`：照片與欄位的關聯、照片順序、說明、輸出狀態及目前欄位照片編號樣式。
- `suggestions`：自動分類建議、信心值與人工審核狀態。

一張照片可有多個 `placements`，因此可以複製到不同項目；移動和複製在資料層是兩個不同操作。原圖不存入 SQLite BLOB。

照片從工程刪除時採軟刪除：placement 會移除，`photos.deleted_at` 會記錄時間，但 `originals/` 原始檔保留。
