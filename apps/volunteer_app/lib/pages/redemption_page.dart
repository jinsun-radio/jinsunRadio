import 'package:flutter/material.dart';
import 'package:jinsun_core/jinsun_core.dart';
import 'package:jinsun_ui_kit/jinsun_ui_kit.dart';

/// 時數兌換頁：用時間銀行累積的服務時數，兌換「物資」或「折算現金」。
/// 志工是付出方，兌換的是實質回饋（物資／現金），不是回頭讓別人來服務自己。
/// 餘額取自 [BackendClient.timeBankMinutesFor]（真實帳本加總），
/// 兌換走 [BackendClient.redeemTimeBank]（寫負值帳）。
class RedemptionPage extends StatefulWidget {
  const RedemptionPage({super.key, required this.backend, required this.name});

  final BackendClient backend;
  final String name;

  @override
  State<RedemptionPage> createState() => _RedemptionPageState();
}

enum _Kind { goods, cash }

class _Reward {
  const _Reward(this.icon, this.title, this.desc, this.cost, this.kind);
  final IconData icon;
  final String title;
  final String desc;
  final int cost; // 需要的分鐘數
  final _Kind kind;
}

const _catalog = <_Reward>[
  // 物資：換成實體生活物資
  _Reward(Icons.local_grocery_store, '白米 5 公斤', '合作社福物資站領取', 90,
      _Kind.goods),
  _Reward(Icons.shopping_bag, '生活物資包', '白米、食用油、罐頭等日常物資', 150,
      _Kind.goods),
  _Reward(Icons.inventory_2, '日用品組合', '衛生紙、清潔用品等', 80, _Kind.goods),
  _Reward(Icons.card_giftcard, '超商購物金 NT\$200', '合作超商消費折抵', 100,
      _Kind.goods),
  // 換錢：折算現金（實際匯款於申請後由承辦人核對帳戶撥付）
  _Reward(Icons.payments, '現金回饋 NT\$200', '申請後由承辦人撥付至你的帳戶', 100,
      _Kind.cash),
  _Reward(Icons.account_balance_wallet, '現金回饋 NT\$500', '申請後由承辦人撥付至你的帳戶',
      240, _Kind.cash),
];

class _RedemptionPageState extends State<RedemptionPage> {
  int? _balance;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadBalance();
  }

  Future<void> _loadBalance() async {
    final b = await widget.backend.timeBankMinutesFor(widget.name);
    if (mounted) setState(() => _balance = b);
  }

  Future<void> _redeem(_Reward r) async {
    final bal = _balance ?? 0;
    if (bal < r.cost) {
      _toast('時數不足，還差 ${formatServiceMinutes(r.cost - bal)}');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('確認兌換'),
        content: Text(
            '用 ${formatServiceMinutes(r.cost)} 兌換「${r.title}」？\n\n'
            '兌換後剩餘 ${formatServiceMinutes(bal - r.cost)}。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('確認兌換')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final left =
          await widget.backend.redeemTimeBank(widget.name, r.cost, r.title);
      if (!mounted) return;
      setState(() => _balance = left);
      _toast('已兌換「${r.title}」，剩餘 ${formatServiceMinutes(left)}');
    } catch (e) {
      if (mounted) _toast('兌換失敗：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('時數兌換')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        children: [
          _balanceCard(),
          const SizedBox(height: 18),
          _section('🛒 兌換物資', _Kind.goods),
          const SizedBox(height: 8),
          _section('💵 折算現金', _Kind.cash),
          const SizedBox(height: 10),
          const Text('時間銀行時數由完成派遣累積。志工是付出方，時數可換物資或折算現金匯入帳戶。',
              style: TextStyle(fontSize: 12, color: JinsunColors.muted)),
        ],
      ),
    );
  }

  Widget _section(String title, _Kind kind) {
    final items = _catalog.where((r) => r.kind == kind).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        ...items.map(_rewardCard),
      ],
    );
  }

  Widget _balanceCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: JinsunColors.blueDeep,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('目前可用時數',
              style: TextStyle(color: Colors.white, fontSize: 13.5)),
          const SizedBox(height: 8),
          Text(_balance == null ? '—' : formatServiceMinutes(_balance!),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 34,
                  fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }

  Widget _rewardCard(_Reward r) {
    final enough = (_balance ?? 0) >= r.cost;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: JinsunColors.blueBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(r.icon, color: JinsunColors.blueDeep),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.title,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(r.desc,
                      style: const TextStyle(
                          fontSize: 12.5, color: JinsunColors.muted)),
                  const SizedBox(height: 4),
                  Text('需 ${formatServiceMinutes(r.cost)}',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: JinsunColors.yellowText)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: (_busy || !enough) ? null : () => _redeem(r),
              child: Text(enough ? '兌換' : '時數不足'),
            ),
          ],
        ),
      ),
    );
  }
}
