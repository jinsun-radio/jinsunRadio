import 'package:flutter/material.dart';
import 'package:jinsun_core/jinsun_core.dart';
import 'package:jinsun_ui_kit/jinsun_ui_kit.dart';

import 'certificates_page.dart';

/// 我的：志工個人資料與時間銀行
class ProfilePage extends StatelessWidget {
  const ProfilePage(
      {super.key,
      required this.backend,
      required this.auth,
      this.name = '志工'});

  final BackendClient backend;
  final AuthRepository auth;
  final String name;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        const Text('我的',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                const JinsunLogo(size: 52),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      const Text('社區照護志工｜台北服務區',
                          style: TextStyle(
                              fontSize: 12.5, color: JinsunColors.muted)),
                    ],
                  ),
                ),
                const StatusPill(
                    label: '已認證',
                    fg: JinsunColors.okText,
                    bg: JinsunColors.okBg),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        // 時間銀行時數：以實際持久化的服務總時數為準（timeBankMinutesFor），
        // 而非只存在於本次連線的 session 點數。
        FutureBuilder<int>(
          future: backend.timeBankMinutesFor(name),
          builder: (context, snap) {
            final mins = snap.data;
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  children: [
                    Text(mins == null ? '—' : formatServiceMinutes(mins),
                        style: const TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.w800,
                            color: JinsunColors.yellowText)),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('時間銀行時數',
                              style: TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w700)),
                          Text('付出累積，回饋未來',
                              style: TextStyle(
                                  fontSize: 12.5, color: JinsunColors.muted)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 14),
        Card(
          child: Column(
            children: [
              // 可服務時段：真實資料（volunteers.service_hours），並顯示目前是否可服務。
              StreamBuilder<List<Volunteer>>(
                stream: backend.volunteers,
                initialData: backend.currentVolunteers,
                builder: (context, snap) {
                  final me = _find(snap.data);
                  final hours = me?.serviceHours ?? const <ServiceHourSlot>[];
                  final available = me?.availableAt(DateTime.now()) ?? false;
                  final subtitle = hours.isEmpty
                      ? '尚未設定'
                      : hours.map((s) => s.label).join('、');
                  return ListTile(
                    leading: const Icon(Icons.schedule,
                        color: JinsunColors.muted),
                    title: const Text('可服務時段'),
                    subtitle: Text(subtitle,
                        style: const TextStyle(color: JinsunColors.muted)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (hours.isNotEmpty) _availabilityChip(available),
                        const Icon(Icons.chevron_right,
                            color: JinsunColors.muted),
                      ],
                    ),
                    onTap: () => _showServiceHours(context, hours, available),
                  );
                },
              ),
              const Divider(height: 1, color: JinsunColors.line),
              ListTile(
                leading: const Icon(Icons.notifications_outlined,
                    color: JinsunColors.muted),
                title: const Text('通知設定'),
                subtitle: const Text('緊急派遣：開啟｜物資代購：開啟',
                    style: TextStyle(color: JinsunColors.muted)),
                trailing: const Icon(Icons.chevron_right,
                    color: JinsunColors.muted),
                onTap: () => _showNotificationSettings(context),
              ),
              const Divider(height: 1, color: JinsunColors.line),
              ListTile(
                leading:
                    const Icon(Icons.verified_user, color: JinsunColors.muted),
                title: const Text('志工認證與保險'),
                subtitle: const Text('良民證・意外險・基礎照護證書',
                    style: TextStyle(color: JinsunColors.muted)),
                trailing: const Icon(Icons.chevron_right,
                    color: JinsunColors.muted),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) =>
                      CertificatesPage(backend: backend, name: name),
                )),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        TextButton.icon(
          style: TextButton.styleFrom(foregroundColor: JinsunColors.muted),
          icon: const Icon(Icons.logout, size: 18),
          label: const Text('登出'),
          onPressed: () => auth.signOut(),
        ),
      ],
    );
  }

  /// 從志工清單中找出目前登入者。
  Volunteer? _find(List<Volunteer>? list) {
    for (final v in list ?? const <Volunteer>[]) {
      if (v.name == name) return v;
    }
    return null;
  }

  /// 目前是否可服務的狀態晶片（綠＝現在可服務／灰＝非服務時段）。
  Widget _availabilityChip(bool available) => Padding(
        padding: const EdgeInsets.only(right: 4),
        child: StatusPill(
          label: available ? '現在可服務' : '目前非服務時段',
          fg: available ? JinsunColors.okText : JinsunColors.muted,
          bg: available ? JinsunColors.okBg : const Color(0xFFEFEFEC),
        ),
      );

  static Future<void> _sheet(BuildContext context, String title, Widget body) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
              left: 24,
              right: 24,
              top: 20,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 16),
              body,
            ],
          ),
        ),
      ),
    );
  }

  void _showServiceHours(
      BuildContext context, List<ServiceHourSlot> hours, bool available) {
    _sheet(
      context,
      '可服務時段',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hours.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('尚未設定可服務時段，設定後即可收到對應時段的派遣單。',
                  style: TextStyle(fontSize: 13, color: JinsunColors.muted)),
            )
          else ...[
            Align(
              alignment: Alignment.centerLeft,
              child: _availabilityChip(available),
            ),
            const SizedBox(height: 8),
            for (final s in hours)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading:
                    const Icon(Icons.schedule, color: JinsunColors.blueDeep),
                title: Text(s.label,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            const SizedBox(height: 8),
            const Text('可服務時段決定你會收到哪些時段的派遣單。',
                style: TextStyle(fontSize: 12.5, color: JinsunColors.muted)),
          ],
        ],
      ),
    );
  }

  void _showNotificationSettings(BuildContext context) {
    _sheet(context, '通知設定', _NotificationSwitches());
  }
}

/// 通知設定的開關（本機狀態；正式版寫入使用者偏好）。
class _NotificationSwitches extends StatefulWidget {
  @override
  State<_NotificationSwitches> createState() => _NotificationSwitchesState();
}

class _NotificationSwitchesState extends State<_NotificationSwitches> {
  bool _emergency = true;
  bool _supply = true;
  bool _sound = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('緊急派遣通知'),
          subtitle: const Text('SOS／疑似跌倒即時推播'),
          value: _emergency,
          onChanged: (v) => setState(() => _emergency = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('物資代購通知'),
          value: _supply,
          onChanged: (v) => setState(() => _supply = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('提示音'),
          value: _sound,
          onChanged: (v) => setState(() => _sound = v),
        ),
      ],
    );
  }
}
