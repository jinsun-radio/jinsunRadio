import 'package:flutter/material.dart';
import 'package:jinsun_core/jinsun_core.dart';
import 'package:jinsun_ui_kit/jinsun_ui_kit.dart';

import '../app_local.dart';
import 'bind_screen.dart';
import 'elder_profile_page.dart';
import 'pairing_screen.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.local});

  final AppLocal local;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: local,
      builder: (context, _) => Scaffold(
        backgroundColor: Colors.transparent,
        appBar:
            AppBar(title: const Text('設定'), automaticallyImplyLeading: false),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          children: [
            Card(
              child: ListTile(
                leading: const CircleAvatar(
                  backgroundColor: JinsunColors.orangeBg,
                  child: Icon(Icons.person, color: JinsunColors.orangeDeep),
                ),
                title: Text(local.accountName,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(
                    '家屬帳號${local.accountPhone.isEmpty ? '' : '・${local.accountPhone}'}',
                    style: const TextStyle(color: JinsunColors.muted)),
              ),
            ),
            const SizedBox(height: 14),
            const Text('已綁定的收音機',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            ...local.boundElders.map((e) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Card(
                    child: Column(
                      children: [
                        Builder(builder: (context) {
                          final online = elderOnline(e.lastActivityAt);
                          return ListTile(
                            leading: const Text('📻',
                                style: TextStyle(fontSize: 26)),
                            title: Text(e.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                            subtitle: Text(
                                '${local.serialOf(e)}・最後回報 ${lastActivityLabel(e.lastActivityAt)}',
                                style: const TextStyle(
                                    color: JinsunColors.muted)),
                            trailing: StatusPill(
                                label: online ? '在線' : '離線',
                                fg: online
                                    ? JinsunColors.okText
                                    : JinsunColors.warnText,
                                bg: online
                                    ? JinsunColors.okBg
                                    : JinsunColors.warnBg),
                          );
                        }),
                        const Divider(height: 1),
                        Padding(
                          padding:
                              const EdgeInsets.fromLTRB(16, 10, 16, 14),
                          child: Row(
                            children: [
                              const Icon(Icons.record_voice_over,
                                  size: 18, color: JinsunColors.muted),
                              const SizedBox(width: 8),
                              const Expanded(
                                child: Text('收音機播報語言',
                                    style: TextStyle(
                                        fontWeight: FontWeight.w600)),
                              ),
                              SegmentedButton<ElderLang>(
                                showSelectedIcon: false,
                                segments: const [
                                  ButtonSegment(
                                      value: ElderLang.mandarin,
                                      label: Text('國語')),
                                  ButtonSegment(
                                      value: ElderLang.taigi,
                                      label: Text('台語')),
                                ],
                                selected: {e.preferredLang},
                                onSelectionChanged: (s) => local.backend
                                    .setElderLang(e.id, s.first),
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        // 編輯長輩資料：社工後台與志工派遣單的長輩資訊都來自這裡。
                        Builder(builder: (context) {
                          final incomplete = e.address.trim().isEmpty ||
                              (e.phone ?? '').trim().isEmpty;
                          return ListTile(
                            leading: Icon(Icons.assignment_ind_outlined,
                                color: incomplete
                                    ? JinsunColors.warnText
                                    : JinsunColors.orangeDeep),
                            title: const Text('編輯長輩資料',
                                style: TextStyle(fontWeight: FontWeight.w700)),
                            subtitle: Text(
                              incomplete
                                  ? '資料待補齊，社工與志工才看得到姓名、地址等'
                                  : '姓名・地址・電話・狀況注記',
                              style: TextStyle(
                                  color: incomplete
                                      ? JinsunColors.warnText
                                      : JinsunColors.muted),
                            ),
                            trailing: incomplete
                                ? StatusPill(
                                    label: '待補齊',
                                    fg: JinsunColors.warnText,
                                    bg: JinsunColors.warnBg)
                                : const Icon(Icons.chevron_right),
                            onTap: () =>
                                Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) =>
                                  ElderProfilePage(local: local, elder: e),
                            )),
                          );
                        }),
                      ],
                    ),
                  ),
                )),
            // 新增收音機：直接進藍牙配對十步驟引導流程（家屬隨時可再新增一台）。
            Card(
              child: ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFEFF4FF),
                  child: Icon(Icons.bluetooth_searching, color: Color(0xFF2E6BE6)),
                ),
                title: const Text('新增收音機',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: const Text('用藍牙配對並幫收音機連上 Wi-Fi',
                    style: TextStyle(color: JinsunColors.muted)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => PairingScreen(local: local))),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.qr_code_2),
              label: const Text('改用序號 / QR Code 綁定'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => BindScreen(local: local, canPop: true))),
            ),
            const SizedBox(height: 24),
            TextButton.icon(
              style:
                  TextButton.styleFrom(foregroundColor: JinsunColors.muted),
              icon: const Icon(Icons.logout, size: 18),
              label: const Text('登出'),
              // 誤觸登出會把家屬踢回登入頁、像 App 壞了；先確認一次。
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('要登出嗎？'),
                    content: const Text('登出後需要重新登入才能收到長輩的通知。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(c, false),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () => Navigator.pop(c, true),
                          child: const Text('登出')),
                    ],
                  ),
                );
                if (ok == true) await local.logout();
              },
            ),
          ],
        ),
      ),
    );
  }
}
