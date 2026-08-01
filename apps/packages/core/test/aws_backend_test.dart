import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jinsun_core/jinsun_core.dart';

/// AwsBackend 的行為測試：用假 http client 餵 `/data/version` 與 `/data/snapshot`，
/// 驗「指紋沒變就不抓快照」「快照解析」「通知只對新變化跳」「搶單衝突」四件事。
///
/// 為什麼這四件：它們是 Supabase→AWS 這次換後端時，行為最容易悄悄跑掉的地方——
/// 解析錯了三端只是少顯示一欄、不會報錯；通知去重錯了會在 demo 現場一直洗版；
/// 搶單衝突若被當成一般錯誤，輸家的單會無聲消失。
void main() {
  const base = 'https://test.local';

  Map<String, dynamic> elderRow(String id, String sev) => {
        'id': id,
        'name': id == 'elder-1' ? '林阿春' : '王金火',
        'age': 82,
        'address': '台北市信義區',
        'lat': 25.0358,
        'lng': 121.5665,
        'severity': sev,
        'preferred_lang': 'taigi',
        'device_serial': 'JS-0001',
        'last_activity_at': '2026-08-01T02:00:00+00:00',
      };

  Map<String, dynamic> eventRow(String id, String type, String status) => {
        'id': id,
        'elder_id': 'elder-1',
        'type': type,
        'status': status,
        'severity': 'emergency',
        'occurred_at': '2026-08-01T02:00:00+00:00',
        'transcript': null,
      };

  Map<String, dynamic> taskRow(String id, String status) => {
        'id': id,
        'elder_id': 'elder-1',
        'event_id': 'ev-1',
        'kind': 'emergency',
        'status': status,
        'assignee_name': '阿明',
        'eta_minutes': 8,
        'items': <String>[],
        'created_at': '2026-08-01T02:00:00+00:00',
      };

  /// 可切換內容的假後端。`state` 換掉之後，下一次 version 就會不一樣。
  ({http.Client client, void Function(Map<String, dynamic>) setSnapshot, List<String> calls})
      fakeApi(Map<String, dynamic> initial) {
    var snap = initial;
    final calls = <String>[];
    final client = MockClient((req) async {
      calls.add('${req.method} ${req.url.path}');
      if (req.url.path.endsWith('/version')) {
        // 指紋＝快照內容的 hash，模擬後端的 md5 指紋
        return http.Response(
          jsonEncode({'v': {'all': jsonEncode(snap).hashCode.toString()}}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (req.url.path.endsWith('/snapshot')) {
        return http.Response(jsonEncode(snap), 200,
            headers: {'content-type': 'application/json'});
      }
      if (req.url.path.endsWith('/mutate')) {
        final op = (jsonDecode(req.body) as Map)['op'];
        if (op == 'acceptTask') {
          return http.Response(jsonEncode({'error': '這張單已被其他志工接走'}), 409,
              headers: {'content-type': 'application/json'});
        }
        return http.Response(jsonEncode({'ok': true}), 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('{}', 404);
    });
    return (client: client, setSnapshot: (s) => snap = s, calls: calls);
  }

  Map<String, dynamic> snapshot({
    List<Map<String, dynamic>>? events,
    List<Map<String, dynamic>>? tasks,
    String elderSeverity = 'normal',
  }) =>
      {
        'role': 'worker',
        'elders': [elderRow('elder-1', elderSeverity)],
        'events': events ?? const [],
        'tasks': tasks ?? const [],
        'volunteers': const [],
        'workers': const [],
        'messages': const [],
        'calls': const [],
        'bindings': const [],
        'settings': {'dispatch_tracking': 'simulate'},
      };

  AwsBackend build(http.Client c) => AwsBackend(
        idToken: () async => 'fake-token',
        client: c,
        baseUrl: base,
        pollInterval: const Duration(milliseconds: 20),
      );

  test('快照解析：長輩／事件／派遣單都回到模型，設定也帶回來', () async {
    final api = fakeApi(snapshot(
      events: [eventRow('ev-1', 'sos', 'escalated')],
      tasks: [taskRow('t-1', 'pending')],
    ));
    final b = build(api.client);
    await Future.delayed(const Duration(milliseconds: 80));

    expect(b.currentElders.single.name, '林阿春');
    expect(b.currentElders.single.preferredLang, ElderLang.taigi);
    expect(b.currentEvents.single.type, RadioEventType.sos);
    expect(b.currentTasks.single.status, DispatchStatus.pending);
    expect(b.currentTasks.single.etaMinutes, 8);
    expect(await b.appSetting('dispatch_tracking'), 'simulate');
    b.dispose();
  });

  test('指紋沒變就不再抓快照（輪詢的成本控制點）', () async {
    final api = fakeApi(snapshot());
    final b = build(api.client);
    await Future.delayed(const Duration(milliseconds: 120));
    final snapshots = api.calls.where((c) => c.endsWith('/snapshot')).length;
    // 至少抓過一次（初次載入），但不該每一輪都抓
    expect(snapshots, greaterThanOrEqualTo(1));
    expect(snapshots, lessThan(api.calls.where((c) => c.endsWith('/version')).length));
    b.dispose();
  });

  test('通知：初次載入不跳，之後新事件才跳（避免開 App 就洗版）', () async {
    final api = fakeApi(snapshot(events: [eventRow('ev-1', 'sos', 'escalated')]));
    final b = build(api.client);
    final seen = <String>[];
    b.notifications.listen((n) => seen.add(n.message));

    await Future.delayed(const Duration(milliseconds: 80));
    expect(seen, isEmpty, reason: '初次載入的既有事件不該跳通知');

    api.setSnapshot(snapshot(events: [
      eventRow('ev-2', 'fall_suspected', 'escalated'),
      eventRow('ev-1', 'sos', 'escalated'),
    ]));
    await Future.delayed(const Duration(milliseconds: 120));
    expect(seen.length, 1);
    expect(seen.single, contains('疑似跌倒且無回應'));
    b.dispose();
  });

  test('派遣單狀態變化跳「已接單」通知，狀態沒變則不重複跳', () async {
    final api = fakeApi(snapshot(tasks: [taskRow('t-1', 'pending')]));
    final b = build(api.client);
    final seen = <String>[];
    b.notifications.listen((n) => seen.add(n.message));
    await Future.delayed(const Duration(milliseconds: 80));

    api.setSnapshot(snapshot(tasks: [taskRow('t-1', 'accepted')]));
    await Future.delayed(const Duration(milliseconds: 120));
    expect(seen.where((m) => m.contains('已接單')).length, 1);

    // 只是長輩燈號變了、單子狀態沒變 → 不該再跳一次接單通知
    api.setSnapshot(snapshot(
        tasks: [taskRow('t-1', 'accepted')], elderSeverity: 'emergency'));
    await Future.delayed(const Duration(milliseconds: 120));
    expect(seen.where((m) => m.contains('已接單')).length, 1);
    b.dispose();
  });

  test('搶單衝突（409）丟 StateError，不會被當成一般錯誤吞掉', () async {
    final api = fakeApi(snapshot(tasks: [taskRow('t-1', 'pending')]));
    final b = build(api.client);
    await Future.delayed(const Duration(milliseconds: 40));
    await expectLater(
      b.acceptTask('t-1', etaMinutes: 8, assigneeName: '阿華'),
      throwsA(isA<StateError>()),
    );
    b.dispose();
  });

  test('每個請求都帶 Cognito id token', () async {
    final headers = <String, String>{};
    final client = MockClient((req) async {
      headers.addAll(req.headers);
      if (req.url.path.endsWith('/version')) {
        return http.Response(jsonEncode({'v': {'all': '1'}}), 200);
      }
      return http.Response(jsonEncode(snapshot()), 200);
    });
    final b = build(client);
    await Future.delayed(const Duration(milliseconds: 60));
    expect(headers['authorization'], 'Bearer fake-token');
    b.dispose();
  });
}
