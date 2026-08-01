import 'package:flutter/material.dart';

/// 金孫收音機品牌標誌（logo 方案 4）：溫暖橘＋科技藍兩道弧帶交扣成心。
/// admin 不依賴 ui_kit，故在此保留一份自足的繪製（品牌色寫死，與 ui_kit 一致）。
class JinsunLogo extends StatelessWidget {
  const JinsunLogo({super.key, this.size = 48});
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _JinsunLogoPainter()),
      );
}

class JinsunLogoBadge extends StatelessWidget {
  const JinsunLogoBadge({super.key, this.size = 96, this.radius = 28});
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
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
                color: const Color(0xFFF97316).withValues(alpha: 0.18),
                blurRadius: 22,
                offset: const Offset(0, 10)),
          ],
        ),
        child: Center(child: JinsunLogo(size: size * 0.62)),
      );
}

class _JinsunLogoPainter extends CustomPainter {
  Path _heart(Size s, double scale, Offset center) {
    double x(double nx) => center.dx + (nx - 0.5) * s.width * scale;
    double y(double ny) => center.dy + (ny - 0.5) * s.height * scale;
    return Path()
      ..moveTo(x(0.5), y(0.26))
      ..cubicTo(x(0.42), y(0.06), x(0.03), y(0.10), x(0.05), y(0.40))
      ..cubicTo(x(0.07), y(0.62), x(0.32), y(0.76), x(0.5), y(0.94))
      ..cubicTo(x(0.68), y(0.76), x(0.93), y(0.62), x(0.95), y(0.40))
      ..cubicTo(x(0.97), y(0.10), x(0.58), y(0.06), x(0.5), y(0.26))
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.52);
    final outer = _heart(size, 0.98, center);
    final inner =
        _heart(size, 0.44, Offset(center.dx, center.dy + size.height * 0.06));
    final ring = Path.combine(PathOperation.difference, outer, inner);
    final cx = size.width / 2;
    final gap = size.width * 0.045;

    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, 0, cx - gap / 2, size.height));
    canvas.drawPath(
        ring,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFFFB067), Color(0xFFF97316)],
          ).createShader(Offset.zero & size));
    canvas.restore();

    canvas.save();
    canvas.clipRect(Rect.fromLTRB(cx + gap / 2, 0, size.width, size.height));
    canvas.drawPath(
        ring,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
            colors: [Color(0xFF7CB0FB), Color(0xFF3B82F6)],
          ).createShader(Offset.zero & size));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _JinsunLogoPainter oldDelegate) => false;
}
