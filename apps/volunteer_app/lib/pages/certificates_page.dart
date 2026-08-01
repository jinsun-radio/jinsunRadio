import 'package:flutter/material.dart';
import 'package:jinsun_core/jinsun_core.dart';
import 'package:jinsun_ui_kit/jinsun_ui_kit.dart';

/// 志工證件完整頁：良民證／志工意外險／基礎照護證書。
/// 每種證件顯示狀態、核發／到期日、備註與「即將到期」提醒；
/// 上傳功能尚未開放（點擊顯示提示）。資料來自 volunteers 表（真實，非寫死）。
class CertificatesPage extends StatelessWidget {
  const CertificatesPage(
      {super.key, required this.backend, this.name = '志工'});

  final BackendClient backend;
  final String name;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Scaffold(
      appBar: AppBar(title: const Text('志工認證與保險')),
      body: StreamBuilder<List<Volunteer>>(
        stream: backend.volunteers,
        initialData: backend.currentVolunteers,
        builder: (context, snap) {
          final list = snap.data ?? const <Volunteer>[];
          Volunteer? me;
          for (final v in list) {
            if (v.name == name) {
              me = v;
              break;
            }
          }
          final certs = me?.certificates ?? const <VolunteerCertificate>[];
          // 依三種證件固定順序顯示；缺的以「未上傳」呈現。
          VolunteerCertificate certFor(CertKind k) {
            for (final c in certs) {
              if (c.kind == k) return c;
            }
            return VolunteerCertificate(kind: k);
          }

          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: JinsunColors.blueBg,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.verified_user,
                        size: 20, color: JinsunColors.blueDeep),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text('完成認證的志工才能接緊急派遣，請保持證件在有效期內。',
                          style: TextStyle(
                              fontSize: 13, color: JinsunColors.blueDeep)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              for (final k in CertKind.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _certCard(context, certFor(k), now),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _certCard(
      BuildContext context, VolunteerCertificate cert, DateTime now) {
    final (fg, bg) = _statusColors(cert.status);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(cert.kind.label,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w800)),
                ),
                StatusPill(label: cert.status.label, fg: fg, bg: bg),
              ],
            ),
            if (cert.issuedAt != null || cert.expiresAt != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.event,
                      size: 15, color: JinsunColors.muted),
                  const SizedBox(width: 6),
                  Text(_dateRange(cert.issuedAt, cert.expiresAt),
                      style: const TextStyle(
                          fontSize: 13, color: JinsunColors.muted)),
                ],
              ),
            ],
            if (cert.note != null && cert.note!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(cert.note!,
                  style: const TextStyle(
                      fontSize: 13, color: JinsunColors.muted)),
            ],
            if (cert.expiringSoon(now)) ...[
              const SizedBox(height: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: JinsunColors.warnBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.warning_amber,
                        size: 15, color: JinsunColors.warnText),
                    SizedBox(width: 6),
                    Text('即將到期，請儘早更新',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: JinsunColors.warnText)),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                  foregroundColor: JinsunColors.blueDeep),
              onPressed: () => _submitCert(context, cert.kind),
              icon: const Icon(Icons.upload_file, size: 18),
              label: Text(cert.status == CertStatus.none ? '送出證件審核' : '更新／重新送審'),
            ),
          ],
        ),
      ),
    );
  }

  /// 送出／更新一張證件審核。狀態寫成「審核中」，由社工端核可後才生效——
  /// 不再是假的「開發中」死路；有明確的送出與成功／失敗回饋。
  Future<void> _submitCert(BuildContext context, CertKind kind) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('送出「${kind.label}」審核'),
        content: const Text(
          '正式版可在此拍照上傳證件。送出後狀態為「審核中」，'
          '由社工端核可後才生效；良民證與意外險皆生效後即可承接緊急派遣。',
          style: TextStyle(height: 1.6),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('送出審核')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await backend.submitCertificate(name, kind);
      messenger.showSnackBar(
        SnackBar(content: Text('「${kind.label}」已送出，審核中，通過後即可接緊急派遣')),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('送出失敗，請檢查網路後再試一次')),
      );
    }
  }

  (Color, Color) _statusColors(CertStatus status) => switch (status) {
        CertStatus.valid => (JinsunColors.okText, JinsunColors.okBg),
        CertStatus.pending => (JinsunColors.warnText, JinsunColors.warnBg),
        CertStatus.expired => (JinsunColors.dangerText, JinsunColors.dangerBg),
        CertStatus.none => (JinsunColors.muted, const Color(0xFFEFEFEC)),
      };

  String _dateRange(DateTime? issued, DateTime? expires) {
    String fmt(DateTime d) =>
        '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';
    if (issued != null && expires != null) {
      return '核發 ${fmt(issued)}・有效至 ${fmt(expires)}';
    }
    if (expires != null) return '有效至 ${fmt(expires)}';
    return '核發 ${fmt(issued!)}';
  }
}
