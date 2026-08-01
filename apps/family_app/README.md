# family_app（家屬 App）

給家屬掌握長輩即時狀態的手機 App。

- **平台**：Flutter（Android／iOS）
- **角色**：家屬
- **功能**：安心日報／週報、緊急通知推播、事件與派遣進度即時更新

詳見 [`../../docs/architecture.md`](../../docs/architecture.md) 與 [`../../docs/requirements/phase1-mvp.md`](../../docs/requirements/phase1-mvp.md)。

## 啟動方式

```bash
flutter pub get
flutter run -d chrome    # 或 -d macos / 手機模擬器
flutter test
```

## 狀態

Phase 1 薄閉環：長輩狀態卡、通知 feed、派遣進度（虛擬志工自動接單）、demo 面板（模擬疑似跌倒／SOS／回應沒事）。資料層為 `jinsun_core` 的 `MockBackend`，無真後端。
