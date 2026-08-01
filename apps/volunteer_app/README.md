# volunteer_app（志工 App）

給志工接單、確認長輩需求與到場回報的手機 App。

- **平台**：Flutter（Android／iOS）
- **角色**：志工
- **功能**：查看長輩物資需求並接單採買、緊急派遣單接單、到場回報「已安全」、時間銀行點數

詳見 [`../../docs/architecture.md`](../../docs/architecture.md) 與 [`../../docs/requirements/phase1-mvp.md`](../../docs/requirements/phase1-mvp.md)。

## 啟動方式

```bash
flutter pub get
flutter run -d chrome    # 或 -d macos / 手機模擬器
flutter test
```

## 狀態

Phase 1 薄閉環：任務列表（緊急派遣／物資代購）、接單填 ETA → 到場 → 回報流程、時間銀行點數、demo 面板。資料層為 `jinsun_core` 的 `MockBackend`，無真後端。
