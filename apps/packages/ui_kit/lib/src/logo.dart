import 'package:flutter/material.dart';

import 'theme.dart';

/// 金孫收音機品牌標誌（logo 方案 4「科技·照護」）：
/// 由「溫暖橘」與「科技藍」兩道圓潤的弧帶交扣成一顆心，中央鏤空成心形負空間，
/// 象徵世代之間相互扶持、科技串聯照護。純 CustomPainter 繪製，任意尺寸皆銳利。
class JinsunLogo extends StatelessWidget {
  const JinsunLogo({super.key, this.size = 48, this.padding = 0});

  final double size;
  final double padding;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Padding(
        padding: EdgeInsets.all(padding),
        child: CustomPaint(painter: _JinsunLogoPainter()),
      ),
    );
  }
}

/// 圓角方底＋logo，適合當 App 圖示／登入頁的品牌圖騰。
class JinsunLogoBadge extends StatelessWidget {
  const JinsunLogoBadge({super.key, this.size = 96, this.radius = 28});

  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFFF6EC), Color(0xFFEFF5FF)],
        ),
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: JinsunColors.orange.withValues(alpha: 0.18),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Center(child: JinsunLogo(size: size * 0.62)),
    );
  }
}

class _JinsunLogoPainter extends CustomPainter {
  /// 標準心形路徑（正規化 0..1，尖端朝下）。
  Path _heart(Size s, double scale, Offset center) {
    double x(double nx) => center.dx + (nx - 0.5) * s.width * scale;
    double y(double ny) => center.dy + (ny - 0.5) * s.height * scale;
    final p = Path()
      ..moveTo(x(0.5), y(0.26))
      ..cubicTo(x(0.42), y(0.06), x(0.03), y(0.10), x(0.05), y(0.40))
      ..cubicTo(x(0.07), y(0.62), x(0.32), y(0.76), x(0.5), y(0.94))
      ..cubicTo(x(0.68), y(0.76), x(0.93), y(0.62), x(0.95), y(0.40))
      ..cubicTo(x(0.97), y(0.10), x(0.58), y(0.06), x(0.5), y(0.26))
      ..close();
    return p;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.52);
    // 外心 − 內心 ＝ 圓潤的心形環帶
    final outer = _heart(size, 0.98, center);
    final inner = _heart(size, 0.44, Offset(center.dx, center.dy + size.height * 0.06));
    final ring = Path.combine(PathOperation.difference, outer, inner);

    final cx = size.width / 2;
    final gap = size.width * 0.045; // 兩色之間的白色縫隙

    // 左半（溫暖橘漸層）
    final leftClip = Rect.fromLTRB(0, 0, cx - gap / 2, size.height);
    canvas.save();
    canvas.clipRect(leftClip);
    final orangePaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFFFB067), JinsunColors.orange],
      ).createShader(Offset.zero & size);
    canvas.drawPath(ring, orangePaint);
    canvas.restore();

    // 右半（科技藍漸層）
    final rightClip = Rect.fromLTRB(cx + gap / 2, 0, size.width, size.height);
    canvas.save();
    canvas.clipRect(rightClip);
    final bluePaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
        colors: [Color(0xFF7CB0FB), JinsunColors.blue],
      ).createShader(Offset.zero & size);
    canvas.drawPath(ring, bluePaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _JinsunLogoPainter oldDelegate) => false;
}
