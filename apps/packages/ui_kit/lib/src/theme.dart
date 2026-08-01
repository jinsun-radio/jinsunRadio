import 'package:flutter/material.dart';
import 'package:jinsun_core/jinsun_core.dart';

/// 品牌色：取自 logo 的鮮明橘／亮藍／黃，走 iOS 原生鮮豔風格。
/// 家屬 App 主色 = 鮮橘，志工 App 主色 = 亮藍，黃作為強調色。
/// 鮮豔的主色 [orange]/[blue] 只用於「按鈕背景＋白字」與大圖示（iOS 慣例，
/// 大字按鈕對比 ≥3:1）；白底上的橘／藍「文字與連結」改用較深的 [orangeDeep]/
/// [blueDeep]（≥4.5:1），兼顧鮮豔外觀與可讀性。
abstract final class JinsunColors {
  // 家屬主色：溫暖橘（品牌 #FB923C）。實心按鈕用稍深的 [orange] 保白字可讀，
  // [orangeBright] 作漸層頂／icon tint／active 高光，讓畫面更鮮活。
  static const Color orange = Color(0xFFF97316); // 按鈕背景＋白字、主色
  static const Color orangeBright = Color(0xFFFB923C); // 品牌亮橘：漸層頂、icon、active
  static const Color orangeDeep = Color(0xFFB4530A); // 白底上的橘文字／連結（≥4.5）
  static const Color orangeBg = Color(0xFFFFF3E6); // 明亮淺橘底

  // 志工／科技主色：科技藍（品牌 #3B82F6）
  static const Color blue = Color(0xFF3B82F6); // 按鈕背景＋白字、主色
  static const Color blueBright = Color(0xFF60A5FA); // 漸層頂／亮藍高光
  static const Color blueDeep = Color(0xFF1D4ED8); // 白底上的藍文字／連結（≥4.5）
  static const Color blueBg = Color(0xFFEAF2FE); // 明亮淺藍底

  // 強調黃
  static const Color yellowText = Color(0xFF8A6100);
  static const Color yellowBg = Color(0xFFFDEFC6);

  // 中性
  static const Color bg = Color(0xFFF5F6F8); // 溫和淺灰畫布
  static const Color ink = Color(0xFF1B1B1F); // 主要文字
  static const Color muted = Color(0xFF6C6C72); // 次要文字（4.9:1）
  static const Color line = Color(0xFFE9E9EF); // 分隔線／卡片邊

  // 狀態（文字 ≥4.4:1、底為明亮淺色）
  static const Color okText = Color(0xFF1E7E34);
  static const Color okBg = Color(0xFFE3F7E8);
  static const Color warnText = Color(0xFF8A5A00);
  static const Color warnBg = Color(0xFFFDF0D5);
  static const Color dangerText = Color(0xFFCD2018);
  static const Color dangerBg = Color(0xFFFDE7E7);

  /// 家屬品牌漸層（亮橘→橘）。純裝飾用（logo 底、無文字 hero），上面別壓白字。
  static const List<Color> orangeGradient = [Color(0xFFFDB365), orange];

  /// 志工品牌漸層（亮藍→藍）。純裝飾用。
  static const List<Color> blueGradient = [blueBright, blue];
}

/// 白底上可讀的品牌深色（outline 文字／連結／nav 選中字，白底 ≥4.5:1）。
/// 鮮豔的 [JinsunColors.orange]/[blue] 當文字壓白底只有 ~3:1，不合 WCAG AA。
Color jinsunBrandOnLight(Color primary) {
  if (primary == JinsunColors.orange || primary == JinsunColors.orangeBright) {
    return JinsunColors.orangeDeep;
  }
  if (primary == JinsunColors.blue || primary == JinsunColors.blueBright) {
    return JinsunColors.blueDeep;
  }
  final h = HSLColor.fromColor(primary);
  return h.withLightness((h.lightness * 0.5).clamp(0.16, 0.34)).toColor();
}

/// 主要實心按鈕的填色（白字過 AA）。仍是暖橘／科技藍，但夠深讓白字 ≥4.6:1。
Color jinsunButtonFill(Color primary) {
  if (primary == JinsunColors.orange || primary == JinsunColors.orangeBright) {
    return const Color(0xFFB85708); // 白字 ≈4.8:1，暖橘
  }
  if (primary == JinsunColors.blue || primary == JinsunColors.blueBright) {
    return JinsunColors.blueDeep; // #1D4ED8 白字 ≈6.4:1
  }
  return jinsunBrandOnLight(primary);
}

/// 主要按鈕的「微微漸層」：上＝[jinsunButtonFill]（已過 AA）、下＝再深一點，
/// 全程白字 ≥4.6:1。刻意做很淡的一階光澤，不是誇張 mesh。
List<Color> jinsunButtonGradient(Color primary) {
  final base = jinsunButtonFill(primary);
  final h = HSLColor.fromColor(base);
  final bottom = h.withLightness((h.lightness - 0.06).clamp(0.0, 1.0)).toColor();
  return [base, bottom];
}

/// 主要 CTA 按鈕：品牌微微漸層＋同色系柔和陰影＋白字（過 WCAG AA）。
/// 語意色按鈕（綠色回報／紅色 SOS）維持各自色塊，不套此漸層。
class JinsunGradientButton extends StatelessWidget {
  const JinsunGradientButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.gradient,
    this.minHeight = 54,
    this.expand = true,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final IconData? icon;
  final List<Color>? gradient;
  final double minHeight;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final g = gradient ?? jinsunButtonGradient(Theme.of(context).colorScheme.primary);
    final disabled = onPressed == null;
    final btn = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: disabled
              ? const [Color(0xFFCFCFD6), Color(0xFFC4C4CB)]
              : g,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: disabled
            ? null
            : [
                BoxShadow(
                  color: g.last.withValues(alpha: 0.30),
                  blurRadius: 16,
                  offset: const Offset(0, 7),
                ),
              ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            constraints: BoxConstraints(minHeight: minHeight),
            padding: const EdgeInsets.symmetric(horizontal: 20),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 20, color: Colors.white),
                  const SizedBox(width: 8),
                ],
                DefaultTextStyle.merge(
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      fontFamily: 'NotoSansTC'),
                  child: child,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return expand ? SizedBox(width: double.infinity, child: btn) : btn;
  }
}

/// 依最後活動時間推導收音機是否在線（預設 30 分鐘內有回報＝在線）。
/// 取代寫死「在線」，讓家屬看得到裝置真實心跳（斷電／離線時能察覺）。
bool elderOnline(DateTime lastActivityAt,
        {Duration within = const Duration(minutes: 30)}) =>
    DateTime.now().difference(lastActivityAt) <= within;

/// 人類可讀的「最後活動」相對時間標籤。
String lastActivityLabel(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return '剛剛';
  if (d.inMinutes < 60) return '${d.inMinutes} 分鐘前';
  if (d.inHours < 24) return '${d.inHours} 小時前';
  return '${d.inDays} 天前';
}

Color severityTextColor(Severity s) => switch (s) {
      Severity.normal => JinsunColors.okText,
      Severity.attention => JinsunColors.warnText,
      Severity.emergency => JinsunColors.dangerText,
    };

Color severityBgColor(Severity s) => switch (s) {
      Severity.normal => JinsunColors.okBg,
      Severity.attention => JinsunColors.warnBg,
      Severity.emergency => JinsunColors.dangerBg,
    };

String severityLabel(Severity s) => switch (s) {
      Severity.normal => '正常',
      Severity.attention => '需要留意',
      Severity.emergency => '緊急處理中',
    };

/// 共用主題：primary 傳 JinsunColors.orange（家屬）或 blue（志工）
ThemeData jinsunTheme(Color primary) {
  final scheme = ColorScheme.fromSeed(
    seedColor: primary,
    brightness: Brightness.light,
    primary: primary,
    surface: Colors.white,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: 'NotoSansTC',
    scaffoldBackgroundColor: JinsunColors.bg,
    appBarTheme: const AppBarTheme(
      backgroundColor: JinsunColors.bg,
      foregroundColor: JinsunColors.ink,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: JinsunColors.ink,
        fontSize: 20,
        fontWeight: FontWeight.w700,
        fontFamily: 'NotoSansTC',
      ),
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      // iOS grouped list 感：大圓角、無硬邊框、極淡陰影讓卡片浮起
      shadowColor: const Color(0x14000000),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
      ),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      // 預設實心按鈕填色改用 [jinsunButtonFill]（白字過 AA）；call site 若自帶
      // backgroundColor（綠色回報／紅色 SOS 等語意色）會覆蓋，不受影響。
      style: FilledButton.styleFrom(
        backgroundColor: jinsunButtonFill(primary),
        foregroundColor: Colors.white,
        minimumSize: const Size(52, 52),
        elevation: 0,
        textStyle: const TextStyle(
            fontSize: 17, fontWeight: FontWeight.w700, fontFamily: 'NotoSansTC'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        // 白底上的外框按鈕文字改用品牌深色（≥4.5:1），外框保留鮮豔品牌色當提示。
        foregroundColor: jinsunBrandOnLight(primary),
        minimumSize: const Size(52, 52),
        side: BorderSide(color: primary.withValues(alpha: 0.55)),
        textStyle: const TextStyle(
            fontSize: 16, fontWeight: FontWeight.w600, fontFamily: 'NotoSansTC'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        textStyle: WidgetStateProperty.all(const TextStyle(
            fontSize: 14, fontWeight: FontWeight.w600, fontFamily: 'NotoSansTC')),
        foregroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? Colors.white : JinsunColors.ink),
        // 選中段填色用 [jinsunButtonFill]（白字過 AA），未選白底黑字。
        backgroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? jinsunButtonFill(primary)
                : Colors.white),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: JinsunColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: JinsunColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: primary, width: 2),
      ),
      labelStyle: const TextStyle(color: JinsunColors.muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      // 選中用「品牌淡色藥丸底＋品牌深色字/icon」：讀得出品牌又過 AA（鮮豔色壓白底只有 ~3:1）。
      indicatorColor: primary.withValues(alpha: 0.16),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? jinsunBrandOnLight(primary)
              : JinsunColors.muted,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? jinsunBrandOnLight(primary)
              : JinsunColors.muted,
        ),
      ),
    ),
    textTheme: const TextTheme(
      bodyMedium: TextStyle(color: JinsunColors.ink, fontSize: 15, height: 1.5),
      titleMedium: TextStyle(
          color: JinsunColors.ink, fontSize: 17, fontWeight: FontWeight.w700),
    ),
  );
}

/// 狀態圓標：文字＋色塊雙重編碼（WCAG 1.4.1 不只靠顏色）
class StatusPill extends StatelessWidget {
  const StatusPill(
      {super.key, required this.label, required this.fg, required this.bg});

  final String label;
  final Color fg;
  final Color bg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text(label,
          style:
              TextStyle(color: fg, fontSize: 13, fontWeight: FontWeight.w700)),
    );
  }
}
