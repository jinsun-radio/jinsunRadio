import 'package:flutter/material.dart';
import 'package:jinsun_core/jinsun_core.dart';
import 'package:jinsun_ui_kit/jinsun_ui_kit.dart';

// 十大類照護檢核範本（careCategories／CareCategory）已下沉到 jinsun_core，
// 與社工後台共用同一份（志工端所見即後台所見）。此處只保留志工端的呈現 widget。

/// 到場後的照護資訊面板：長輩實際重點置頂，十大類收合、點開才看。
class CareSheet extends StatelessWidget {
  const CareSheet({super.key, required this.elder});

  final Elder elder;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: const [
            Icon(Icons.assignment_ind_outlined,
                size: 18, color: JinsunColors.blueDeep),
            SizedBox(width: 6),
            Text('長輩照護資訊',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: JinsunColors.ink)),
            SizedBox(width: 6),
            Text('點類別展開',
                style: TextStyle(fontSize: 11.5, color: JinsunColors.muted)),
          ],
        ),
        const SizedBox(height: 8),
        // 本位長輩的實際重點（志工注記＋基本資料），一眼先看到
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: JinsunColors.blueBg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (elder.note != null && elder.note!.trim().isNotEmpty) ...[
                Text('📋 本次照護重點：${elder.note}',
                    style: const TextStyle(
                        fontSize: 13.5,
                        height: 1.4,
                        fontWeight: FontWeight.w600,
                        color: JinsunColors.blueDeep)),
                const SizedBox(height: 6),
              ],
              Text(
                  '👤 ${elder.name}（${elder.age} 歲）　🗣️ 慣用${elder.preferredLang.label}'
                  '${elder.phone != null ? '　📞 家中 ${elder.phone}' : ''}',
                  style: const TextStyle(fontSize: 12.5, height: 1.4)),
            ],
          ),
        ),
        const SizedBox(height: 6),
        // 十大類：收合式，點開才看（自製 expander，避開 ExpansionTile 的語意樹 assert）
        for (final cat in careCategories) _ExpandableCategory(cat: cat),
      ],
    );
  }
}

/// 單一照護類別的收合／展開卡（點標題展開項目）。
class _ExpandableCategory extends StatefulWidget {
  const _ExpandableCategory({required this.cat});
  final CareCategory cat;

  @override
  State<_ExpandableCategory> createState() => _ExpandableCategoryState();
}

class _ExpandableCategoryState extends State<_ExpandableCategory> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final cat = widget.cat;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        border: Border.all(color: JinsunColors.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(
                children: [
                  Icon(cat.icon, size: 20, color: JinsunColors.blueDeep),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(cat.title,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700)),
                  ),
                  Icon(_open ? Icons.expand_less : Icons.expand_more,
                      color: JinsunColors.muted),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final item in cat.items)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(top: 6),
                            child: Icon(Icons.circle,
                                size: 5, color: JinsunColors.muted),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(item,
                                style: const TextStyle(
                                    fontSize: 13, height: 1.45)),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
