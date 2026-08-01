import 'package:flutter/material.dart';
import 'package:jinsun_ui_kit/jinsun_ui_kit.dart';

import '../app_local.dart';

class RemindersPage extends StatelessWidget {
  const RemindersPage({super.key, required this.local});

  final AppLocal local;

  static String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _edit(BuildContext context, {Reminder? existing}) async {
    final controller = TextEditingController(text: existing?.text ?? '');
    // 編輯中的時間清單（本地暫存，儲存才寫回 AppLocal）
    final times = <TimeOfDay>[...?existing?.times];

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          times.sort((a, b) =>
              (a.hour * 60 + a.minute) - (b.hour * 60 + b.minute));
          final canSave = controller.text.trim().isNotEmpty && times.isNotEmpty;
          return Padding(
            padding: EdgeInsets.fromLTRB(
                20, 18, 20, 18 + MediaQuery.of(ctx).viewInsets.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(existing == null ? '新增提醒' : '編輯提醒',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  autofocus: existing == null,
                  onChanged: (_) => setSheet(() {}),
                  decoration: const InputDecoration(
                    labelText: '提醒內容',
                    hintText: '例：吃藥、量血壓',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 20),
                const Text('提醒時間',
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                if (times.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6),
                    child: Text('尚未新增時間，至少要有一個時間才能儲存。',
                        style:
                            TextStyle(fontSize: 13, color: JinsunColors.muted)),
                  ),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final t in times)
                      InputChip(
                        label: Text(_fmt(t),
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600)),
                        backgroundColor: JinsunColors.orangeBg,
                        deleteIconColor: JinsunColors.orangeDeep,
                        labelStyle:
                            const TextStyle(color: JinsunColors.orangeDeep),
                        onDeleted: () => setSheet(() => times.remove(t)),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 48),
                    foregroundColor: JinsunColors.orangeDeep,
                    side: const BorderSide(color: JinsunColors.orange),
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('新增時間'),
                  onPressed: () async {
                    final picked = await showTimePicker(
                      context: ctx,
                      initialTime: const TimeOfDay(hour: 8, minute: 0),
                      helpText: '選擇提醒時間',
                    );
                    if (picked == null) return;
                    if (!times.any((t) =>
                        t.hour == picked.hour && t.minute == picked.minute)) {
                      setSheet(() => times.add(picked));
                    }
                  },
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 52)),
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('取消'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 52),
                          backgroundColor: JinsunColors.orange,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: canSave
                            ? () {
                                final text = controller.text.trim();
                                if (existing == null) {
                                  local.addReminder(times, text);
                                } else {
                                  local.editReminder(existing, times, text);
                                }
                                Navigator.pop(ctx);
                              }
                            : null,
                        child: Text(existing == null ? '新增' : '儲存'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: local,
      builder: (context, _) => Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
            title: const Text('提醒設定'), automaticallyImplyLeading: false),
        floatingActionButton: FloatingActionButton.extended(
          heroTag: 'add-reminder',
          backgroundColor: JinsunColors.orange,
          foregroundColor: Colors.white,
          icon: const Icon(Icons.add),
          label: const Text('新增提醒'),
          onPressed: () => _edit(context),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 90),
          children: [
            const Text('設定後即時同步到收音機，長輩會聽到語音提醒（斷網也照常播放）。點提醒可編輯。',
                style: TextStyle(fontSize: 13, color: JinsunColors.muted)),
            const SizedBox(height: 14),
            ...local.reminders.map((r) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Card(
                    child: ListTile(
                      onTap: () => _edit(context, existing: r),
                      leading: const CircleAvatar(
                        backgroundColor: JinsunColors.orangeBg,
                        child: Icon(Icons.campaign,
                            color: JinsunColors.orangeDeep, size: 22),
                      ),
                      title: Text(r.text,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            for (final t in r.times)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: JinsunColors.orangeBg,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(_fmt(t),
                                    style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: JinsunColors.orangeDeep)),
                              ),
                          ],
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: '編輯提醒',
                            icon: const Icon(Icons.edit_outlined,
                                color: JinsunColors.muted),
                            onPressed: () => _edit(context, existing: r),
                          ),
                          IconButton(
                            tooltip: '刪除提醒',
                            icon: const Icon(Icons.delete_outline,
                                color: JinsunColors.muted),
                            onPressed: () => local.removeReminder(r),
                          ),
                        ],
                      ),
                    ),
                  ),
                )),
          ],
        ),
      ),
    );
  }
}
