import 'package:flutter/material.dart';

/// 金孫收音機品牌標誌（正式版）：圓角方形徽章，上半溫暖橘、下半科技藍，
/// 兩色以一道波浪相接，中央鏤空成白色心形負空間。
/// 幾何直接對應 `docs/assets/jinsun-logo.svg`（viewBox 256）。
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
          borderRadius: BorderRadius.circular(radius),
          boxShadow: [
            BoxShadow(
                color: const Color(0xFFFB923C).withValues(alpha: 0.20),
                blurRadius: 22,
                offset: const Offset(0, 10)),
          ],
        ),
        // 徽章本身已是圓角實心方塊，直接鋪滿容器。
        child: JinsunLogo(size: size),
      );
}

/// 依 `docs/assets/jinsun-logo.svg`（256×256）等比例重繪的品牌徽章。
class _JinsunLogoPainter extends CustomPainter {
  static const _orange = Color(0xFFFB923C);
  static const _blue = Color(0xFF3B82F6);
  static const _base = Color(0xFFF5F6F8);

  Path _scaled(Size size,
      void Function(Path p, double Function(double), double Function(double)) build) {
    final k = size.width / 256.0;
    final ky = size.height / 256.0;
    double sx(double v) => v * k;
    double sy(double v) => v * ky;
    final p = Path();
    build(p, sx, sy);
    return p;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 256.0;
    final frame = RRect.fromRectAndRadius(
      Rect.fromLTWH(8 * k, 8 * k, 240 * k, 240 * (size.height / 256.0)),
      Radius.circular(60 * k),
    );

    canvas.save();
    canvas.clipRRect(frame);
    canvas.drawRRect(frame, Paint()..color = _base);

    final orange = _scaled(size, (p, x, y) {
      p
        ..moveTo(x(8), y(8))
        ..lineTo(x(248), y(8))
        ..lineTo(x(248), y(118))
        ..cubicTo(x(210), y(150), x(176), y(124), x(148), y(150))
        ..cubicTo(x(118), y(178), x(70), y(142), x(8), y(164))
        ..close();
    });
    canvas.drawPath(orange, Paint()..color = _orange..isAntiAlias = true);

    final blue = _scaled(size, (p, x, y) {
      p
        ..moveTo(x(8), y(164))
        ..cubicTo(x(70), y(142), x(118), y(178), x(148), y(150))
        ..cubicTo(x(176), y(124), x(210), y(150), x(248), y(118))
        ..lineTo(x(248), y(248))
        ..lineTo(x(8), y(248))
        ..close();
    });
    canvas.drawPath(blue, Paint()..color = _blue..isAntiAlias = true);

    final heart = _scaled(size, (p, x, y) {
      p
        ..moveTo(x(128), y(178))
        ..cubicTo(x(108), y(150), x(78), y(142), x(78), y(112))
        ..cubicTo(x(78), y(92), x(96), y(80), x(112), y(90))
        ..cubicTo(x(120), y(95), x(125), y(103), x(128), y(110))
        ..cubicTo(x(131), y(103), x(136), y(95), x(144), y(90))
        ..cubicTo(x(160), y(80), x(178), y(92), x(178), y(112))
        ..cubicTo(x(178), y(142), x(148), y(150), x(128), y(178))
        ..close();
    });
    canvas.drawPath(heart, Paint()..color = Colors.white..isAntiAlias = true);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _JinsunLogoPainter oldDelegate) => false;
}
