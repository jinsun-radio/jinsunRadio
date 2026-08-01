import 'package:flutter/material.dart';
import 'package:jinsun_core/jinsun_core.dart';
import 'package:jinsun_ui_kit/jinsun_ui_kit.dart';

import '../app_local.dart';

/// 「即時紀錄」收件匣：把累積的即時通知（跌倒／SOS／派遣狀態）列出來，
/// 讓家屬錯過那張短暫的首頁卡片後，仍能回看「剛剛到底發生什麼」。
/// 開啟即把未讀歸零（首頁鈴鐺紅點消失）。
class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key, required this.local});

  final AppLocal local;

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  @override
  void initState() {
    super.initState();
    // 進頁即視為已讀（下一個 frame 再改，避免 build 期間 notifyListeners）
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => widget.local.markNotificationsRead());
  }

  String _fmt(DateTime t) {
    final now = DateTime.now();
    final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
    final hm =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    if (sameDay) return '今天 $hm';
    return '${t.month}/${t.day} $hm';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('即時紀錄')),
      body: ListenableBuilder(
        listenable: widget.local,
        builder: (context, _) {
          final items = widget.local.notifications;
          if (items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  '目前沒有通知紀錄。\n長輩有狀況或派遣有進度時，會即時出現在這裡。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: JinsunColors.muted, height: 1.6),
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final n = items[i];
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: severityBgColor(n.severity),
                  child: Icon(
                    n.severity == Severity.emergency
                        ? Icons.notifications_active
                        : n.severity == Severity.attention
                            ? Icons.info_outline
                            : Icons.check_circle_outline,
                    color: severityTextColor(n.severity),
                    size: 20,
                  ),
                ),
                title: Text(n.message,
                    style: const TextStyle(
                        fontSize: 14.5, fontWeight: FontWeight.w600)),
                subtitle: Text(_fmt(n.at),
                    style: const TextStyle(
                        fontSize: 12.5, color: JinsunColors.muted)),
              );
            },
          );
        },
      ),
    );
  }
}
