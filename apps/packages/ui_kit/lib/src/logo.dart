import 'package:flutter/material.dart';

import 'theme.dart';

/// 金孫收音機品牌標誌（正式版）：圓角方形徽章，上半溫暖橘、下半科技藍，
/// 兩色以一道波浪相接，中央鏤空成白色心形負空間——象徵世代扶持、科技串聯照護。
/// 幾何直接對應 `docs/assets/jinsun-logo.svg`（viewBox 256），純 CustomPainter 繪製、任意尺寸皆銳利。
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

/// 放大版徽章（含柔和陰影），適合登入頁／App 圖示的品牌圖騰。
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
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: JinsunColors.orange.withValues(alpha: 0.20),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      // 徽章本身已是圓角實心方塊，直接鋪滿容器。
      child: JinsunLogo(size: size),
    );
  }
}

/// 依 `docs/assets/jinsun-logo.svg`（256×256）等比例重繪的品牌徽章。
class _JinsunLogoPainter extends CustomPainter {
  // 品牌色（與 SVG、JinsunColors 一致）
  static const _orange = Color(0xFFFB923C);
  static const _blue = Color(0xFF3B82F6);
  static const _base = Color(0xFFF5F6F8);

  /// 把 SVG（0..256 座標）縮放到實際畫布尺寸。
  Path _scaled(Size size, void Function(Path p, double Function(double), double Function(double)) build) {
    final k = size.width / 256.0;
    double sx(double v) => v * k;
    double sy(double v) => v * (size.height / 256.0);
    final p = Path();
    build(p, sx, sy);
    return p;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 256.0;
    // 圓角方外框：rect(8,8,240,240) rx=60（SVG frame）。
    final frame = RRect.fromRectAndRadius(
      Rect.fromLTWH(8 * k, 8 * k, 240 * k, 240 * (size.height / 256.0)),
      Radius.circular(60 * k),
    );

    canvas.save();
    canvas.clipRRect(frame);

    // 底色（僅防鋸齒邊緣露出；上橘下藍會鋪滿）。
    canvas.drawRRect(frame, Paint()..color = _base);

    // 溫暖橘：上半（波浪為下緣）
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

    // 科技藍：下半（與橘色共用同一條波浪縫）
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

    // 白色心：中央負空間
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
