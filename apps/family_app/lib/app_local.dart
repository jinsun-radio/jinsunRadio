import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:jinsun_core/jinsun_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 提醒（App 本地設定，正式版同步到收音機 retained config）
/// 一則提醒 = 一個標籤（如「吃藥」）＋多個時間（08:00／12:00／18:00），
/// 而非拆成多則。時間清單依早到晚排序。
class Reminder {
  Reminder({required this.times, required this.text});

  List<TimeOfDay> times;
  String text;
}

/// 單日真實事件統計。來源：radio_events（收音機回報的疑似跌倒／SOS／物資需求）。
/// 走動量、睡眠等感測指標需長輩端裝置回傳，尚未開放，因此本模型只放「真實有來源」
/// 的欄位——不再有任何假資料。
class DayStat {
  DayStat({
    required this.day,
    required this.falls,
    required this.sos,
    required this.supply,
  });

  final DateTime day;
  final int falls; // 疑似跌倒次數
  final int sos; // 求助 SOS 次數
  final int supply; // 物資需求次數

  int get total => falls + sos + supply;
  bool get hasEmergency => falls > 0 || sos > 0;
}

enum StatsRange { day, week, month }

/// AI 綜合照護建議
class CareAdvice {
  CareAdvice({
    required this.summary,
    required this.insights,
    required this.suggestion,
    required this.suggestionReason,
  });

  final String summary;
  final List<String> insights;
  final String suggestion;
  final String suggestionReason;
}

/// 家屬 App 的本地狀態：綁定、提醒、統計與 AI 建議。
/// 登入態由 [AuthRepository] 管理（現為 LocalAuthRepository，正式版換 Cognito）；
/// 事件／派遣即時資料來自 jinsun_core 的 MockBackend（保留模擬功能），
/// 正式版把 MockBackend 換成雲端 BackendClient 即可。
class AppLocal extends ChangeNotifier {
  AppLocal(this.backend, this.auth) {
    // 後端（Supabase）長輩資料是非同步載入的，載到才能過濾出已綁定的長輩
    _elderSub = backend.elders.listen((_) => notifyListeners());
    // 即時通知：累積成歷史（只收綁定長輩），家屬首頁「即時紀錄」呈現、依緊急+時間排序
    _notifSub = backend.notifications.listen((n) {
      final eid = n.elderId;
      if (eid != null && !boundIds.contains(eid)) return;
      notifications.insert(0, n);
      if (notifications.length > 80) notifications.removeLast();
      unreadNotifications++;
      notifyListeners();
    });
    // 登入時載入該帳號的綁定；登出時清空
    _authSub = auth.authStateChanges().listen((user) {
      if (user != null) {
        loadBindings();
      } else {
        boundIds.clear();
        bindingsLoaded = false;
        notifyListeners();
      }
    });
    if (auth.currentUser != null) loadBindings();
    _loadReminders();
  }

  final BackendClient backend;
  final AuthRepository auth;
  StreamSubscription<List<Elder>>? _elderSub;
  StreamSubscription<AuthUser?>? _authSub;
  StreamSubscription<AppNotification>? _notifSub;

  /// 即時通知歷史（最新在前）；家屬首頁「即時紀錄」收件匣呈現
  final List<AppNotification> notifications = [];

  /// 未讀通知數（首頁鈴鐺紅點）；開啟收件匣即歸零
  int unreadNotifications = 0;

  /// 開啟「即時紀錄」收件匣時呼叫：未讀歸零。
  void markNotificationsRead() {
    if (unreadNotifications == 0) return;
    unreadNotifications = 0;
    notifyListeners();
  }

  String get userName {
    final n = auth.currentUser?.name ?? '';
    // 顯示去掉姓氏的稱呼（陳怡君 → 怡君）
    return n.length > 1 ? n.substring(1) : n;
  }

  /// 目前登入帳號全名（如 陳怡君）
  String get accountName => auth.currentUser?.name ?? '家屬';

  /// 目前登入帳號（手機號碼）
  String get accountPhone => auth.currentUser?.username ?? '';

  Future<void> logout() async {
    boundIds.clear();
    notifications.clear();
    unreadNotifications = 0;
    advice = null;
    await auth.signOut();
    notifyListeners();
  }

  @override
  void dispose() {
    _elderSub?.cancel();
    _authSub?.cancel();
    _notifSub?.cancel();
    super.dispose();
  }

  // ---- 綁定（收音機序號 → MockBackend 的長輩） ----
  static const serialToElder = {
    'JS-0001': 'elder-1',
    'JS-0002': 'elder-2',
    'JS-0003': 'elder-3',
  };

  /// 已綁定的長輩 elderId（登入後從 Supabase family_bindings 載入）
  final Set<String> boundIds = {};
  bool bindingsLoaded = false;

  /// 登入後載入這個家屬綁定過的長輩（持久化，之後登入直接進首頁）
  Future<void> loadBindings() async {
    final uid = auth.currentUser?.id;
    boundIds.clear();
    if (uid != null) {
      try {
        final rows = await JinsunSupabase.client
            .from('family_bindings')
            .select('elder_id')
            .eq('family_id', uid);
        for (final r in rows) {
          boundIds.add(r['elder_id'] as String);
        }
      } catch (_) {}
    }
    bindingsLoaded = true;
    notifyListeners();
  }

  /// 綁定收音機（onboarding／設定頁新增）。已綁定則視為成功、不擋流程。
  Future<String?> bindBySerial(String serial) async {
    final code = serial.trim().toUpperCase();
    final elderId = serialToElder[code];
    if (elderId == null) return '找不到裝置 $code，請確認收音機底部的序號';
    final uid = auth.currentUser?.id;
    if (uid != null) {
      try {
        await JinsunSupabase.client.from('family_bindings').upsert(
          {'family_id': uid, 'elder_id': elderId},
          onConflict: 'family_id,elder_id',
        );
      } catch (_) {}
    }
    boundIds.add(elderId);
    notifyListeners();
    return null;
  }

  List<Elder> get boundElders =>
      backend.currentElders.where((e) => boundIds.contains(e.id)).toList();

  Elder? get primaryElder => boundElders.isEmpty ? null : boundElders.first;

  // ---- 多長輩：目前選中的長輩（統計／歷史／AI 建議都跟著選，不再永遠只看第一位）----
  String? _selectedElderId;

  /// 目前選中的長輩；未選或已失效時退回第一位。
  Elder? get selectedElder {
    final list = boundElders;
    if (list.isEmpty) return null;
    if (_selectedElderId != null) {
      for (final e in list) {
        if (e.id == _selectedElderId) return e;
      }
    }
    return list.first;
  }

  void selectElder(String elderId) {
    if (_selectedElderId == elderId) return;
    _selectedElderId = elderId;
    notifyListeners();
  }

  String serialOf(Elder e) => serialToElder.entries
      .firstWhere((kv) => kv.value == e.id, orElse: () => const MapEntry('—', ''))
      .key;

  // ---- 提醒 ----
  // 預設種入兩則常見提醒供 demo（林阿春的家屬）一開啟就看到；提醒會同步到收音機播放
  final List<Reminder> reminders = [
    Reminder(text: '吃藥', times: const [
      TimeOfDay(hour: 8, minute: 0),
      TimeOfDay(hour: 12, minute: 0),
      TimeOfDay(hour: 18, minute: 0),
    ]),
    Reminder(text: '量血壓', times: const [
      TimeOfDay(hour: 9, minute: 0),
      TimeOfDay(hour: 20, minute: 0),
    ]),
  ];

  static int _minutes(TimeOfDay t) => t.hour * 60 + t.minute;

  /// 提醒之間依「最早的時間」排序
  void _sortReminders() => reminders.sort(
      (a, b) => _minutes(a.times.first) - _minutes(b.times.first));

  /// 單則提醒內的時間清單依早到晚排序
  List<TimeOfDay> _sortedTimes(List<TimeOfDay> times) =>
      [...times]..sort((a, b) => _minutes(a) - _minutes(b));

  void addReminder(List<TimeOfDay> times, String text) {
    reminders.add(Reminder(text: text, times: _sortedTimes(times)));
    _sortReminders();
    _saveReminders();
    notifyListeners();
  }

  void editReminder(Reminder r, List<TimeOfDay> times, String text) {
    r.times = _sortedTimes(times);
    r.text = text;
    _sortReminders();
    _saveReminders();
    notifyListeners();
  }

  /// 刪除並回傳它原本的位置，供「復原」用（家屬誤刪吃藥提醒能救回來）。
  int removeReminder(Reminder r) {
    final idx = reminders.indexOf(r);
    reminders.remove(r);
    _saveReminders();
    notifyListeners();
    return idx < 0 ? reminders.length : idx;
  }

  /// 復原剛刪掉的提醒（放回原位）。
  void restoreReminder(int index, Reminder r) {
    final i = index.clamp(0, reminders.length);
    reminders.insert(i, r);
    _sortReminders();
    _saveReminders();
    notifyListeners();
  }

  // ---- 提醒本地持久化（重開 App 不遺失；正式版另同步收音機 retained config）----
  static const _remindersKey = 'jinsun_reminders_v1';

  Future<void> _loadReminders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_remindersKey);
      if (raw == null) return; // 沒存過 → 保留預設種子提醒
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      reminders
        ..clear()
        ..addAll(list.map((m) => Reminder(
              text: m['text'] as String,
              times: (m['times'] as List)
                  .cast<String>()
                  .map((s) {
                    final p = s.split(':');
                    return TimeOfDay(
                        hour: int.parse(p[0]), minute: int.parse(p[1]));
                  })
                  .toList(),
            )));
      _sortReminders();
      notifyListeners();
    } catch (_) {
      // 讀取／解析失敗 → 保留現有提醒，不讓壞資料清空畫面
    }
  }

  Future<void> _saveReminders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = reminders
          .map((r) => {
                'text': r.text,
                'times': r.times
                    .map((t) =>
                        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}')
                    .toList(),
              })
          .toList();
      await prefs.setString(_remindersKey, jsonEncode(data));
    } catch (_) {}
  }

  // ---- 日/週/月統計（真實資料：radio_events 的每日事件計數，只算主要綁定長輩） ----
  List<RadioEvent> get _elderEvents {
    final elder = selectedElder;
    if (elder == null) return const [];
    return backend.currentEvents.where((e) => e.elderId == elder.id).toList();
  }

  List<DayStat> statsFor(StatsRange range) {
    final now = DateTime.now();
    final days = switch (range) {
      StatsRange.day => 1,
      StatsRange.week => 7,
      StatsRange.month => 30,
    };
    final evs = _elderEvents;
    return List.generate(days, (k) {
      final d = now.subtract(Duration(days: days - 1 - k));
      final day0 = DateTime(d.year, d.month, d.day);
      var falls = 0, sos = 0, supply = 0;
      for (final e in evs) {
        final at = e.occurredAt;
        if (at.year == day0.year &&
            at.month == day0.month &&
            at.day == day0.day) {
          switch (e.type) {
            case RadioEventType.fallSuspected:
              falls++;
            case RadioEventType.sos:
              sos++;
            case RadioEventType.supplyRequest:
              supply++;
          }
        }
      }
      return DayStat(day: day0, falls: falls, sos: sos, supply: supply);
    });
  }

  /// 今日真實統計（首頁／建議用）。
  DayStat get todayStat => statsFor(StatsRange.day).first;

  /// 最後偵測到活動的真實時間（radio_events 最新一筆與長輩 lastActivityAt 取較新者）。
  DateTime? get lastDetectedActivity {
    final elder = selectedElder;
    if (elder == null) return null;
    var last = elder.lastActivityAt;
    for (final e in _elderEvents) {
      if (e.occurredAt.isAfter(last)) last = e.occurredAt;
    }
    return last;
  }

  // ---- AI 照護建議（依真實 radio_events 事件與長輩狀態彙整；正式版可換 Bedrock 生成） ----
  CareAdvice? advice;

  void generateAdvice() {
    final elder = selectedElder;
    if (elder == null) return;
    final now = DateTime.now();
    final evs = _elderEvents;
    int within(int days, bool Function(RadioEvent) test) => evs
        .where((e) => now.difference(e.occurredAt).inDays < days && test(e))
        .length;
    final falls7 = within(7, (e) => e.type == RadioEventType.fallSuspected);
    final sos7 = within(7, (e) => e.type == RadioEventType.sos);
    final supply7 = within(7, (e) => e.type == RadioEventType.supplyRequest);
    final falls30 = within(30, (e) => e.type == RadioEventType.fallSuspected);
    final today = todayStat;
    final lastAt = lastDetectedActivity ?? elder.lastActivityAt;

    String rel(DateTime t) {
      final d = now.difference(t);
      if (d.inMinutes < 60) return '${d.inMinutes < 1 ? 1 : d.inMinutes} 分鐘前';
      if (d.inHours < 24) return '${d.inHours} 小時前';
      return '${d.inDays} 天前';
    }

    final calm = falls7 == 0 && sos7 == 0 && elder.severity == Severity.normal;
    final summary = calm
        ? '近 7 日收音機沒有偵測到跌倒、求助或物資事件，${elder.name}狀況平穩。'
        : '近 7 日偵測到 $falls7 次疑似跌倒、$sos7 次求助'
            '${supply7 > 0 ? '、$supply7 次物資需求' : ''}，建議多加留意。';

    final sevText = switch (elder.severity) {
      Severity.normal => '正常',
      Severity.attention => '注意',
      Severity.emergency => '緊急',
    };
    final insights = <String>[
      '今日事件：疑似跌倒 ${today.falls}・求助 ${today.sos}・物資 ${today.supply}',
      '近 7 日：疑似跌倒 $falls7・求助 $sos7・物資需求 $supply7',
      '最後偵測到活動：${rel(lastAt)}',
      '目前狀態：$sevText',
    ];

    final String suggestion, reason;
    if (falls7 >= 2 || falls30 >= 3) {
      suggestion = '近期疑似跌倒偏多，建議安排回診並主動告知醫師。';
      reason = '近 7 日 $falls7 次、近 30 日 $falls30 次疑似跌倒；'
          '跌倒頻率上升可能與肌力、血壓或用藥有關，宜請醫師評估。';
    } else if (sos7 > 0 || elder.severity == Severity.emergency) {
      suggestion = '近期有求助或緊急事件，建議回診時一併告知醫師。';
      reason = '近 7 日 $sos7 次求助；請醫師評估近期身體與情緒狀況。';
    } else if (supply7 >= 3) {
      suggestion = '近期物資需求較多，可留意長輩備貨與外出便利性。';
      reason = '近 7 日 $supply7 次物資需求，或反映採買不便，可安排志工協助。';
    } else {
      suggestion = '目前無異常事件，維持規律作息、定期關心即可。';
      reason = '近 7 日未偵測到跌倒或求助事件，長輩狀況平穩。';
    }

    advice = CareAdvice(
      summary: summary,
      insights: insights,
      suggestion: suggestion,
      suggestionReason: reason,
    );
    notifyListeners();
  }
}
