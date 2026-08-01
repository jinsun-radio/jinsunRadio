
import 'package:flutter/material.dart';
import 'package:jinsun_core/jinsun_core.dart';
import 'package:jinsun_ui_kit/jinsun_ui_kit.dart';

import '../data/mock_history.dart';

/// 接單紀錄（外送員 App 風格）：本週概況 + 訂單卡列表。
/// 資料全部來自資料庫的真實結案派遣單（含歷史對話），點卡片可回看當時家屬↔志工訊息。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.backend, this.volunteerName = ''});

  final BackendClient backend;
  final String volunteerName; // 只看「這位登入志工」自己的接單紀錄

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  String? _monthKey; // null = 全部；否則 'YYYY-MM'

  String _key(DateTime t) => '${t.year}-${t.month.toString().padLeft(2, '0')}';
  String _monthLabel(String k) {
    final p = k.split('-');
    return '${p[0]} 年 ${int.parse(p[1])} 月';
  }

  @override
  Widget build(BuildContext context) {
    final backend = widget.backend;
    final volunteerName = widget.volunteerName;
    // 歷史一律吃資料庫的真實結案單（每筆都有寫入的歷史對話），不用任何假資料。
    return StreamBuilder<List<DispatchTask>>(
      stream: backend.tasks,
      initialData: backend.currentTasks,
      builder: (context, snapshot) {
        Elder? elderOf(String id) {
          final m = backend.currentElders.where((e) => e.id == id);
          return m.isEmpty ? null : m.first;
        }

        // 一律取「這筆單最近一次的動作時間」當排序／顯示時間：結案→到場→出發→開單裡最新的一個。
        // 為什麼不用 resolvedAt：seed／匯入資料偶有 resolved_at 早於 created_at 的髒資料，
        // 只看結案時間會把剛建立的新單排到舊單後面。取 max 保證「最新建立/處理」永遠在最上面。
        DateTime latestTouch(DispatchTask t) {
          var d = t.createdAt;
          for (final x in [t.acceptedAt, t.arrivedAt, t.resolvedAt]) {
            if (x != null && x.isAfter(d)) d = x;
          }
          return d;
        }

        // 真實結案、且「我」接的任務 → ServiceRecord（新到舊）
        final all = (snapshot.data ?? const <DispatchTask>[])
            .where((t) =>
                t.status == DispatchStatus.resolved &&
                t.assigneeName == volunteerName)
            .map((t) {
          final el = elderOf(t.elderId);
          return ServiceRecord(
            time: latestTouch(t),
            elderName: el?.name ?? '長輩',
            address: el?.address ?? '',
            kind: t.kind,
            items: t.items,
            durationMin: (t.etaMinutes ?? 10) + 6,
            note: t.note,
            taskId: t.id, // 真實派遣單→可點進歷史聊天
            photoUrl: t.proofPhotoUrl, // 拍照結單的現場證明照
          );
        }).toList()
          // 新到舊；時間相同再以 taskId 穩定排序，避免每次 rebuild 順序跳動。
          ..sort((a, b) {
            final c = b.time.compareTo(a.time);
            return c != 0 ? c : (b.taskId ?? '').compareTo(a.taskId ?? '');
          });

        // 有紀錄的月份（新到舊）供年月篩選；選到的月份若已無資料 → 回「全部」。
        final months = all.map((r) => _key(r.time)).toSet().toList()
          ..sort((a, b) => b.compareTo(a));
        final active =
            (_monthKey != null && months.contains(_monthKey)) ? _monthKey : null;
        final records = active == null
            ? all
            : all.where((r) => _key(r.time) == active).toList();

        final minutes = records.fold<int>(0, (s, r) => s + r.minutes);

        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          children: [
            const Text('接單紀錄',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            _WeekSummary(
              title: active == null ? '服務概況（全部）' : '${_monthLabel(active)} 概況',
              orders: records.length,
              minutes: minutes,
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                const Text('歷史訂單',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                const SizedBox(width: 8),
                Text('共 ${records.length} 筆',
                    style: const TextStyle(
                        fontSize: 12.5, color: JinsunColors.muted)),
                const Spacer(),
                if (months.isNotEmpty)
                  _MonthPicker(
                    months: months,
                    active: active,
                    labelOf: _monthLabel,
                    onChanged: (k) => setState(() => _monthKey = k),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (records.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(
                  child: Text('這個月沒有接單紀錄',
                      style: TextStyle(color: JinsunColors.muted)),
                ),
              )
            else
              ...records.map((r) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _OrderCard(record: r, backend: backend),
                  )),
            const SizedBox(height: 6),
            const Text('時間銀行時數由完成派遣累積，可兌換物資或折算現金。',
                style: TextStyle(fontSize: 12, color: JinsunColors.muted)),
          ],
        );
      },
    );
  }
}

/// 年月篩選下拉：全部 + 有紀錄的月份（新到舊）。
class _MonthPicker extends StatelessWidget {
  const _MonthPicker(
      {required this.months,
      required this.active,
      required this.labelOf,
      required this.onChanged});

  final List<String> months;
  final String? active;
  final String Function(String) labelOf;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButton<String?>(
      value: active,
      isDense: true,
      borderRadius: BorderRadius.circular(12),
      icon: const Icon(Icons.expand_more, size: 18),
      underline: const SizedBox.shrink(),
      style: const TextStyle(
          fontSize: 13, color: JinsunColors.ink, fontWeight: FontWeight.w600),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('全部月份')),
        for (final m in months)
          DropdownMenuItem<String?>(value: m, child: Text(labelOf(m))),
      ],
      onChanged: onChanged,
    );
  }
}

class _WeekSummary extends StatelessWidget {
  const _WeekSummary({
    this.title = '本週服務概況',
    required this.orders,
    required this.minutes,
  });

  final String title;
  final int orders;
  final int minutes;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      decoration: BoxDecoration(
        // blueDeep(#0E6EA8)：白字對比達 AA，取代 blue(#1B8FD6) 上 white70 的低對比
        color: JinsunColors.blueDeep,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          Row(
            children: [
              _stat('$orders', '完成單數'),
              _divider(),
              _stat(formatServiceMinutes(minutes), '服務時數'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String value, String label) => Expanded(
        child: Column(
          children: [
            Text(value,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(label,
                style: const TextStyle(color: Colors.white, fontSize: 12.5)),
          ],
        ),
      );

  Widget _divider() =>
      Container(width: 1, height: 34, color: Colors.white38);
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.record, required this.backend});

  final ServiceRecord record;
  final BackendClient backend;

  void _openChatHistory(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChatScreen(
        backend: backend,
        taskId: record.taskId!,
        myRole: ChatFromRole.volunteer,
        title: '與 ${record.elderName} 家屬的訊息',
        accent: JinsunColors.blue,
        readOnly: true,
      ),
    ));
  }

  /// 全螢幕檢視結單照片（可縮放）。
  void _viewPhoto(BuildContext context, String url) {
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: const Text('結單現場照'),
        ),
        body: Center(
          child: InteractiveViewer(
            child: Image.network(url,
                errorBuilder: (_, __, ___) => const Text('照片載入失敗',
                    style: TextStyle(color: Colors.white70))),
          ),
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final emergency = record.kind == DispatchKind.emergency;
    final tappable = record.taskId != null;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: tappable ? () => _openChatHistory(context) : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: emergency
                        ? JinsunColors.dangerBg
                        : JinsunColors.okBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    emergency ? Icons.emergency : Icons.shopping_basket,
                    size: 20,
                    color: emergency
                        ? JinsunColors.dangerText
                        : JinsunColors.okText,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${record.elderName}｜${emergency ? '緊急派遣' : '物資代購'}',
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text('📍 ${record.address}',
                          style: const TextStyle(
                              fontSize: 12, color: JinsunColors.muted),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                Text('+${record.minutes} 分',
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: JinsunColors.yellowText)),
              ],
            ),
            if (record.items.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('代購：${record.items.join('、')}',
                    style: const TextStyle(fontSize: 13)),
              ),
            if (record.note != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('「${record.note}」',
                    style: const TextStyle(
                        fontSize: 12.5,
                        color: JinsunColors.muted,
                        fontStyle: FontStyle.italic)),
              ),
            if (record.photoUrl != null && record.photoUrl!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: GestureDetector(
                  onTap: () => _viewPhoto(context, record.photoUrl!),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.network(
                      record.photoUrl!,
                      height: 120,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        height: 120,
                        alignment: Alignment.center,
                        color: const Color(0xFFF1F1F4),
                        child: const Text('結單照片',
                            style: TextStyle(color: JinsunColors.muted)),
                      ),
                    ),
                  ),
                ),
              ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Divider(height: 1, color: JinsunColors.line),
            ),
            Row(
              children: [
                _meta(Icons.schedule, _fmt(record.time)),
                const SizedBox(width: 14),
                _meta(Icons.timer_outlined, '服務 ${record.durationMin} 分'),
                if (tappable) ...[
                  const Spacer(),
                  const Icon(Icons.chat_bubble_outline,
                      size: 14, color: JinsunColors.blueDeep),
                  const SizedBox(width: 3),
                  const Text('查看訊息',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: JinsunColors.blueDeep)),
                  const Icon(Icons.chevron_right,
                      size: 15, color: JinsunColors.blueDeep),
                ],
              ],
            ),
          ],
          ),
        ),
      ),
    );
  }

  Widget _meta(IconData icon, String text) => Row(
        children: [
          Icon(icon, size: 14, color: JinsunColors.muted),
          const SizedBox(width: 3),
          Text(text,
              style: const TextStyle(
                  fontSize: 12,
                  color: JinsunColors.muted,
                  fontFeatures: [FontFeature.tabularFigures()])),
        ],
      );

  String _fmt(DateTime t) =>
      '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
