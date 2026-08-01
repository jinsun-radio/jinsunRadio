# 金孫收音機 — 提案簡報 deck

2026 AI 創新獎提案簡報，純靜態網頁（HTML + CSS + vanilla JS），無需建置工具。

## 開啟／預覽

直接用瀏覽器打開 `index.html` 即可。若某些瀏覽器擋本機檔案讀取，改用本機伺服器：

```bash
cd deck && python3 -m http.server 8000
```

然後開 <http://localhost:8000>。

## 檔案結構

```
deck/
├── index.html      投影片內容（改文字／新增頁面主要動這裡）
├── style.css       簡報樣式
├── assets/         簡報框架：runtime.js（翻頁）、base.css、fonts.css、animations/
└── img/            所有情境圖與截圖
```

## 一起改的注意事項

- **改內容**：編輯 `index.html` 的各張 slide；改樣式動 `style.css`。`assets/` 是共用框架，非必要不動。
- **加圖**：放進 `img/`，用相對路徑 `img/xxx.png` 引用；請壓到 ~2MB 以下（現況最大約 2.3MB）。
- 簡報內三個 App 連結指向已部署的 CloudFront 網址（家屬／志工／社工後台），非本機資源。
- `.DS_Store` 已被 `.gitignore` 排除，勿手動加入。
