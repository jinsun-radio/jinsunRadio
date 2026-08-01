import 'package:flutter/material.dart';
import 'package:jinsun_ui_kit/jinsun_ui_kit.dart';

import '../app_local.dart';

/// 多長輩切換器：綁 2 位以上才顯示；選誰，統計／歷史／AI 建議就跟著看誰。
/// 綁一位時回傳空白（不佔版面）。
class ElderPicker extends StatelessWidget {
  const ElderPicker({super.key, required this.local});

  final AppLocal local;

  @override
  Widget build(BuildContext context) {
    final elders = local.boundElders;
    if (elders.length < 2) return const SizedBox.shrink();
    final selId = local.selectedElder?.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final e in elders)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(e.name),
                  selected: e.id == selId,
                  onSelected: (_) => local.selectElder(e.id),
                  selectedColor: JinsunColors.orangeBg,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
