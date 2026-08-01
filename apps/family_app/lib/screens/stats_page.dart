import 'package:flutter/material.dart';
import 'package:jinsun_core/jinsun_core.dart';
import 'package:jinsun_ui_kit/jinsun_ui_kit.dart';

import '../app_local.dart';
import 'elder_picker.dart';

/// 日／週／月 真實事件統計。
/// 資料全部來自 radio_events（收音機回報的疑似跌倒／SOS／物資需求）＋長輩狀態，
/// 沒有任何假資料；隨事件串流即時更新。
class StatsPage extends StatefulWidget {
  const StatsPage({super.key, required this.local});

  final AppLocal local;

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  StatsRange _range = StatsRange.week;

  @override
  Widget build(BuildContext context) {
    // 綁 local（切換長輩要重繪）＋事件串流（新事件即時重算，反映今日真實資料）。
    return ListenableBuilder(
      listenable: widget.local,
      builder: (context, _) => StreamBuilder<List<RadioEvent>>(
        stream: widget.local.backend.events,
        initialData: widget.local.backend.currentEvents,
        builder: (context, __) => _build(context),
      ),
    );
  }

  Widget _build(BuildContext context) {
    final stats = widget.local.statsFor(_range);
    final today = stats.last; // 清單由舊到新，最後一筆＝今天
    final falls = stats.fold<int>(0, (a, d) => a + d.falls);
    final sos = stats.fold<int>(0, (a, d) => a + d.sos);
    final supply = stats.fold<int>(0, (a, d) => a + d.supply);
    final maxTotal =
        stats.fold<int>(1, (a, d) => d.total > a ? d.total : a); // 圖表正規化上限
    final lastAt = widget.local.lastDetectedActivity;

    final rangeLabel = switch (_range) {
      StatsRange.day => '今日',
      StatsRange.week => '近 7 日',
      StatsRange.month => '近 30 日',
    };

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar:
          AppBar(title: const Text('紀錄統計'), automaticallyImplyLeading: false),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        children: [
          ElderPicker(local: widget.local),
          SegmentedButton<StatsRange>(
            segments: const [
              ButtonSegment(value: StatsRange.day, label: Text('日')),
              ButtonSegment(value: StatsRange.week, label: Text('週')),
              ButtonSegment(value: StatsRange.month, label: Text('月')),
            ],
            selected: {_range},
            onSelectionChanged: (v) => setState(() => _range = v.first),
          ),
          const SizedBox(height: 16),
          Row(children: [
            _KpiTile(
                label: '今日事件',
                value: '${today.total} 件',
                good: today.total == 0),
            const SizedBox(width: 10),
            _KpiTile(
                label: '$rangeLabel疑似跌倒',
                value: '$falls 次',
                good: falls == 0),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            _KpiTile(
                label: '$rangeLabel求助 SOS', value: '$sos 次', good: sos == 0),
            const SizedBox(width: 10),
            _KpiTile(
                label: '$rangeLabel物資需求',
                value: '$supply 次',
                good: true,
                neutral: true),
          ]),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  const Icon(Icons.sensors, size: 18, color: JinsunColors.muted),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      lastAt == null
                          ? '最後偵測到活動：尚無紀錄'
                          : '最後偵測到活動：${_relative(lastAt)}',
                      style: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          _chartCard(
            '$rangeLabel每日事件數',
            _BarChart(
              values: stats.map((d) => d.total / maxTotal).toList(),
              labels: _labelsFor(stats),
              formatValue: (v) => '${(v * maxTotal).round()} 件',
              semanticsPrefix: '$rangeLabel每日事件數',
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFEFEFEC),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text(
              '資料來源：收音機近端回報的真實事件（疑似跌倒／SOS／物資需求），'
              '不拍臉、不上雲。走動量、睡眠等感測指標待長輩端裝置回傳後開放。',
              style: TextStyle(
                  fontSize: 12, height: 1.6, color: Color(0xFF52524E)),
            ),
          ),
        ],
      ),
    );
  }

  String _relative(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '剛剛';
    if (d.inMinutes < 60) return '${d.inMinutes} 分鐘前';
    if (d.inHours < 24) return '${d.inHours} 小時前';
    return '${d.inDays} 天前';
  }

  Widget _chartCard(String title, Widget chart) => Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w800)),
              const SizedBox(height: 14),
              chart,
            ],
          ),
        ),
      );

  List<String> _labelsFor(List<DayStat> stats) {
    const wd = ['一', '二', '三', '四', '五', '六', '日'];
    if (_range == StatsRange.day) return ['今天'];
    if (_range == StatsRange.week) {
      return stats.map((d) => wd[d.day.weekday - 1]).toList();
    }
    return stats.map((d) => d.day.day % 5 == 0 ? '${d.day.day}' : '').toList();
  }
}

class _KpiTile extends StatelessWidget {
  const _KpiTile(
      {required this.label,
      required this.value,
      required this.good,
      this.neutral = false});

  final String label;
  final String value;
  final bool good;
  // 中性指標（如物資需求）：不是警訊、也不需標「正常」，隱藏狀態標籤，別讓買個牛奶
  // 就在儀表板閃「注意」橘字嚇家屬。
  final bool neutral;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 12.5, color: JinsunColors.muted)),
              const SizedBox(height: 4),
              Row(children: [
                Flexible(
                  child: Text(value,
                      style: const TextStyle(
                          fontSize: 19, fontWeight: FontWeight.w800)),
                ),
                if (!neutral) ...[
                  const SizedBox(width: 6),
                  Text(good ? '正常' : '注意',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: good
                              ? JinsunColors.okText
                              : JinsunColors.warnText)),
                ],
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

/// 極簡長條圖（無外部套件），附完整語意描述（WCAG 1.1.1）
class _BarChart extends StatelessWidget {
  const _BarChart({
    required this.values,
    required this.labels,
    required this.formatValue,
    required this.semanticsPrefix,
  });

  final List<double> values; // 0~1
  final List<String> labels;
  final String Function(double) formatValue;
  final String semanticsPrefix;

  @override
  Widget build(BuildContext context) {
    final desc = StringBuffer('$semanticsPrefix：');
    for (var i = 0; i < values.length; i++) {
      if (labels[i].isNotEmpty) {
        desc.write('${labels[i]} ${formatValue(values[i])}，');
      }
    }
    return Semantics(
      label: desc.toString(),
      child: ExcludeSemantics(
        child: SizedBox(
          height: 120,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < values.length; i++) ...[
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Container(
                        height: 90 * values[i].clamp(0.05, 1.0),
                        decoration: BoxDecoration(
                          color: values[i] >= 0.85
                              ? JinsunColors.orange
                              : const Color(0xFFFDB176), // 鮮橘淺版
                          borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(5)),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(labels[i],
                          style: const TextStyle(
                              fontSize: 10.5, color: JinsunColors.muted),
                          maxLines: 1),
                    ],
                  ),
                ),
                if (i != values.length - 1)
                  SizedBox(width: values.length > 10 ? 2 : 6),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
