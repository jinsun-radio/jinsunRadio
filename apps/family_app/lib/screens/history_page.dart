import 'package:flutter/material.dart';
import 'package:jinsun_core/jinsun_core.dart';
import 'package:jinsun_ui_kit/jinsun_ui_kit.dart';

import '../app_local.dart';
import 'elder_picker.dart';

/// 家屬端：生活歷史紀錄。全部是「收音設備」的真實 AI 收音事件，
/// 以「週」為單位分組，每一天一張可展開的 Card，點開看當天完整時間軸。
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key, required this.local});

  final AppLocal local;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('生活歷史紀錄')),
      // 綁 local：切換長輩要重繪成該長輩的歷史。
      body: ListenableBuilder(
        listenable: local,
        builder: (context, _) {
          final elder = local.selectedElder;
          return elder == null
              ? const Center(
                  child: Text('尚未綁定長輩',
                      style: TextStyle(color: JinsunColors.muted)))
              : _build(context, elder);
        },
      ),
    );
  }

  Widget _build(BuildContext context, Elder elder) {
    // 真實資料：已結案派遣單＋AI 對話化解事件（與社工後台、志工歷史同一份 DB 資料），以週分組。
    final events = _historyEvents(local.backend, elder);
    if (events.isEmpty) {
      return const Center(
          child:
              Text('目前還沒有紀錄', style: TextStyle(color: JinsunColors.muted)));
    }

    // 依「週次」分組（新→舊），每週內再依「日」分組。
    final byWeek = <int, List<CareEvent>>{};
    for (final e in events) {
      byWeek.putIfAbsent(isoWeekNumber(e.lastAt), () => []).add(e);
    }
    final weeks = byWeek.keys.toList()..sort((a, b) => b.compareTo(a));

    final items = <Widget>[];
    for (final w in weeks) {
      final evs = byWeek[w]!..sort((a, b) => b.lastAt.compareTo(a.lastAt));
      final dates = evs.map((e) => e.lastAt).toList()..sort();
      final from = dates.first, to = dates.last;
      items.add(_weekHeader(w, from, to));

      // 該週依日分組
      final byDay = <String, List<CareEvent>>{};
      for (final e in evs) {
        final k = '${e.lastAt.month}/${e.lastAt.day}';
        byDay.putIfAbsent(k, () => []).add(e);
      }
      final dayKeys = byDay.keys.toList()
        ..sort((a, b) =>
            byDay[b]!.first.lastAt.compareTo(byDay[a]!.first.lastAt));
      for (final k in dayKeys) {
        items.add(Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _DayCard(day: byDay[k]!),
        ));
      }
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        ElderPicker(local: local),
        Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: JinsunColors.orangeBg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Row(
            children: [
              Icon(Icons.graphic_eq, size: 18, color: JinsunColors.orangeDeep),
              SizedBox(width: 8),
              Expanded(
                child: Text('收音設備 24 小時聆聽守護，以下為 AI 由聲音推論的事件紀錄',
                    style: TextStyle(
                        fontSize: 12.5, color: JinsunColors.orangeDeep)),
              ),
            ],
          ),
        ),
        ...items,
      ],
    );
  }

  Widget _weekHeader(int week, DateTime from, DateTime to) {
    String md(DateTime d) => '${d.month}/${d.day}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 18, 2, 8),
      child: Row(
        children: [
          Text('第 $week 週',
              style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                  color: JinsunColors.ink)),
          const SizedBox(width: 10),
          Text('${md(from)} – ${md(to)}',
              style: const TextStyle(
                  fontSize: 13,
                  color: JinsunColors.muted,
                  fontFeatures: [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}

/// 一天一張可展開的 Card：收合時顯示日期＋當天事件摘要；點開看完整時間軸。
class _DayCard extends StatefulWidget {
  const _DayCard({required this.day});
  final List<CareEvent> day; // 同一天的事件（新→舊）

  @override
  State<_DayCard> createState() => _DayCardState();
}

class _DayCardState extends State<_DayCard> {
  bool _open = false;

  static const _week = ['一', '二', '三', '四', '五', '六', '日'];

  /// 具體「發生什麼事」標題：物資帶出品項，跌倒／SOS 直接講。
  String _titleOf(CareEvent e) => switch (e.trigger) {
        AcousticTrigger.suspectedFall => '疑似跌倒',
        AcousticTrigger.helpKeyword => 'SOS 求救',
        AcousticTrigger.supplyRequest =>
          (e.detail?.isNotEmpty ?? false) ? '物資需求：${e.detail}' : '物資需求',
        _ => e.trigger.label,
      };

  /// 當日單一事件的結果摘要。
  String _outcomeOf(CareEvent e) {
    if (!e.resolved) return '處理中';
    return e.trigger == AcousticTrigger.supplyRequest ? '物資已送達' : '已確認平安';
  }

  @override
  Widget build(BuildContext context) {
    final day = widget.day;
    final d = day.first.lastAt;
    final peak = day.any((e) => e.peakSeverity == Severity.emergency)
        ? Severity.emergency
        : day.any((e) => e.peakSeverity == Severity.attention)
            ? Severity.attention
            : Severity.normal;
    // 「點開前就寫具體什麼事」：挑當日最要緊的一件當標題（物資帶出品項）。
    final primary = day.firstWhere(
        (e) => e.peakSeverity == Severity.emergency,
        orElse: () => day.firstWhere(
            (e) => e.peakSeverity == Severity.attention,
            orElse: () => day.first));
    final summary = day.length == 1
        ? _outcomeOf(primary)
        : '今日共 ${day.length} 件（點開看全部）';

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: severityBgColor(peak),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('${d.month}/${d.day}',
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w900,
                                color: severityTextColor(peak))),
                        Text('週${_week[d.weekday - 1]}',
                            style: TextStyle(
                                fontSize: 10, color: severityTextColor(peak))),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_titleOf(primary),
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w800),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 2),
                        Text(summary,
                            style: const TextStyle(
                                fontSize: 12.5, color: JinsunColors.muted)),
                      ],
                    ),
                  ),
                  Icon(_open ? Icons.expand_less : Icons.expand_more,
                      color: JinsunColors.muted),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                children: [
                  for (final e in day) _EventTimeline(event: e),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 單一事件的完整時間軸（偵測 → AI 確認 → 派遣 → 抵達 → 安全 → 結束）。
class _EventTimeline extends StatelessWidget {
  const _EventTimeline({required this.event});
  final CareEvent event;

  static String _hm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final steps = event.steps;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFAF7F2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: JinsunColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.graphic_eq,
                  size: 15, color: severityTextColor(event.peakSeverity)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(event.trigger.label,
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: severityTextColor(event.peakSeverity))),
              ),
              Text(_hm(event.startedAt),
                  style: const TextStyle(
                      fontSize: 11.5,
                      color: JinsunColors.muted,
                      fontFeatures: [FontFeature.tabularFigures()])),
            ],
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < steps.length; i++)
            _stepRow(steps[i], first: i == 0, last: i == steps.length - 1),
        ],
      ),
    );
  }

  Widget _stepRow(CareStep s, {required bool first, required bool last}) {
    final color = severityTextColor(s.kind.severity);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 時間軸線＋圓點
          Column(
            children: [
              Container(width: 2, height: 4, color: first ? Colors.transparent : JinsunColors.line),
              Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5)),
              ),
              Expanded(
                child: Container(
                    width: 2,
                    color: last ? Colors.transparent : JinsunColors.line),
              ),
            ],
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(s.kind.label,
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                              color: color)),
                      const SizedBox(width: 8),
                      Text(_hm(s.at),
                          style: const TextStyle(
                              fontSize: 11,
                              color: JinsunColors.muted,
                              fontFeatures: [FontFeature.tabularFigures()])),
                    ],
                  ),
                  const SizedBox(height: 1),
                  Text(s.text,
                      style: const TextStyle(fontSize: 13, height: 1.4)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 家屬歷史事件來源：全部為真實資料——已結案派遣單（與社工後台、志工歷史同一份 DB）
/// ＋AI 對話化解、未派工的真實事件。不再有任何假的展示背景，時間新者排在前面。
List<CareEvent> _historyEvents(BackendClient backend, Elder elder) {
  final out = <CareEvent>[];

  RadioEvent? eventById(String id) {
    for (final e in backend.currentEvents) {
      if (e.id == id) return e;
    }
    return null;
  }

  // ① 已結案派遣單 → 合成完整時間軸
  for (final t in backend.currentTasks) {
    if (t.elderId != elder.id || t.status != DispatchStatus.resolved) continue;
    out.add(_careEventFromTask(elder, t, eventById(t.eventId)));
  }
  // ② AI 對話化解（confirmed_ok／closed）且沒有派遣單的真實事件
  for (final e in backend.currentEvents) {
    if (e.elderId != elder.id) continue;
    if (e.status != RadioEventStatus.confirmedOk &&
        e.status != RadioEventStatus.closed) {
      continue;
    }
    final hasTask = backend.currentTasks.any((t) => t.eventId == e.id);
    if (hasTask) continue;
    out.add(_careEventFromEvent(elder, e));
  }
  out.sort((a, b) => b.lastAt.compareTo(a.lastAt));
  return out;
}

AcousticTrigger _triggerOf(RadioEventType? t) => switch (t) {
      RadioEventType.sos => AcousticTrigger.helpKeyword,
      RadioEventType.fallSuspected => AcousticTrigger.suspectedFall,
      RadioEventType.supplyRequest => AcousticTrigger.supplyRequest,
      _ => AcousticTrigger.routineCheckin,
    };

/// 由「已結案派遣單＋其觸發事件」合成一條家屬視角時間軸。
CareEvent _careEventFromTask(Elder elder, DispatchTask t, RadioEvent? ev) {
  final t0 = ev?.occurredAt ?? t.createdAt;
  final done = t.resolvedAt ?? t.createdAt;
  DateTime at(int m) => t0.add(Duration(minutes: m));
  final trig = _triggerOf(ev?.type);
  final isSupply = t.kind == DispatchKind.supply;
  // 物資品項：優先用派遣單解析出的品項，退而用事件語音逐字。
  final items =
      t.items.isNotEmpty ? t.items.join('、') : (ev?.transcript ?? '');
  final steps = <CareStep>[
    // 物資：偵測與 AI 都先「確認到底是什麼物資」；其他才是關心/偵測聲音。
    if (isSupply) ...[
      CareStep(CareStepKind.detected, t0,
          items.isNotEmpty ? '長輩語音提出物資需求：$items' : '長輩語音提出物資需求'),
      CareStep(CareStepKind.aiConfirming, at(0),
          items.isNotEmpty ? 'AI 已確認要買的物資：$items' : 'AI 確認物資需求'),
    ] else ...[
      CareStep(CareStepKind.detected, t0, '收音設備偵測到 ${trig.label}'),
      CareStep(CareStepKind.aiConfirming, at(0), 'AI 主動語音關心長輩'),
    ],
    if (t.assigneeName != null) ...[
      CareStep(CareStepKind.notifiedWorker, at(1), '已就近通知志工'),
      CareStep(CareStepKind.workerAccepted, at(2), '志工 ${t.assigneeName} 接案'),
      CareStep(CareStepKind.workerDeparted, at(2), '志工出發前往'),
      CareStep(CareStepKind.workerArrived, at(3), '志工抵達長輩家'),
    ],
    // 物資單＝送達完成（不用「平安」）；跌倒／SOS 才是「確認安全／平安」。
    if (isSupply)
      CareStep(CareStepKind.eventClosed, done,
          t.note ?? (items.isNotEmpty ? '$items 已送達，任務完成' : '物資已送達，任務完成'))
    else ...[
      CareStep(CareStepKind.confirmedSafe, done, t.note ?? '已確認長輩安全'),
      CareStep(CareStepKind.eventClosed, done, '事件結束，長輩平安'),
    ],
  ];
  return CareEvent(
    id: 'hist-task-${t.id}',
    elderId: elder.id,
    elderName: elder.name,
    trigger: trig,
    peakSeverity: t.kind == DispatchKind.emergency
        ? Severity.emergency
        : Severity.attention,
    steps: steps,
    detail: isSupply && items.isNotEmpty ? items : null,
  );
}

/// 由「AI 對話化解、未派工」的事件合成一條較短的時間軸。
CareEvent _careEventFromEvent(Elder elder, RadioEvent e) {
  final t0 = e.occurredAt;
  DateTime at(int m) => t0.add(Duration(minutes: m));
  final trig = _triggerOf(e.type);
  return CareEvent(
    id: 'hist-ev-${e.id}',
    elderId: elder.id,
    elderName: elder.name,
    trigger: trig,
    peakSeverity: Severity.attention,
    steps: [
      CareStep(CareStepKind.detected, t0, '收音設備偵測到 ${trig.label}'),
      CareStep(CareStepKind.aiConfirming, at(0), 'AI 主動語音關心長輩'),
      CareStep(CareStepKind.elderReplied, at(1), '長輩回應「我沒事」'),
      CareStep(CareStepKind.eventClosed, at(1), 'AI 判定非緊急，事件結束'),
    ],
  );
}
