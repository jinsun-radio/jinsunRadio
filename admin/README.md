# admin（管理介面後台）

給社工／營運團隊使用的即時 dashboard。

- **平台**：Web（App 亦可，優先做 Web）
- **角色**：社工／管理者
- **功能**：
  - 所有長輩的即時狀態總覽（正常／注意／緊急）
  - 事件關注排序、派遣監控
  - **匯出 Excel**：符合政府申報／稽核需求

詳見 [`../docs/architecture.md`](../docs/architecture.md) 與 [`../docs/requirements/phase1-mvp.md`](../docs/requirements/phase1-mvp.md)。

## 啟動方式

```bash
flutter pub get
flutter run -d chrome
flutter test
```

## 狀態

Phase 1 薄閉環：長輩即時狀態板（緊急→注意→正常排序）、事件紀錄表、派遣監控表、Excel 匯出（`excel` package，web 端點擊即下載 `.xlsx`）、demo 面板。技術棧選型 Flutter web（決策記錄見 `docs/requirements/phase1-mvp.md`）。資料層為 `jinsun_core` 的 `MockBackend`，無真後端。
