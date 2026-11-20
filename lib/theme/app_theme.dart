import 'package:flutter/material.dart';

/// OfficerPath AI — officer-grade theme.
///
/// Deep navy #0B1F3A + gold #C9A227 + clean white. Premium serif for
/// headings (system `serif` family — no font download needed) + clean
/// sans for body. Generous spacing, rounded cards, subtle shadows.
/// Light mode is the default; dark mode is fully supported (follows the
/// device setting).
class AppTheme {
  static const Color navy = Color(0xFF0B1F3A);
  static const Color navyDark = Color(0xFF071426);
  static const Color gold = Color(0xFFC9A227);
  static const Color goldSoft = Color(0xFFF5EED3);
  static const Color paper = Color(0xFFFAF8F2);

  /// Dark-mode twin of [goldSoft]: a deep olive-gold tint that keeps
  /// default (light) body text readable. Never use [goldSoft] as a
  /// background with default text in dark mode — cream + white text
  /// is unreadable. Use [goldTint] instead, everywhere.
  static const Color goldSoftDark = Color(0xFF3A2F10);

  /// Gold-tinted surface that reads in both themes (light cream in
  /// light mode, deep olive-gold in dark mode). Default theme text
  /// colours work on top of it in both modes.
  static Color goldTint(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? goldSoftDark
      : goldSoft;

  /// Status colours, shared so pass/fail/answer states look the same
  /// on every screen (and stay readable in dark mode — never use
  /// `Colors.green.shade800` / `Colors.red.shade800` as text on a
  /// tinted container in dark mode).
  static const Color success = Color(0xFF2E7D32);
  static const Color successBright = Color(0xFF4CAF50);
  static const Color danger = Color(0xFFB3261E);
  static const Color dangerBright = Color(0xFFD64541);
  static const Color warning = Color(0xFFB26A00);

  /// Shared screen padding — every screen's scroll view uses 16.
  static const EdgeInsets screenPadding = EdgeInsets.all(16);

  /// Serif for headings — the "officer" feel. `serif` resolves to the
  /// device's serif font (Noto Serif on Android); body stays sans.
  static const String headingFont = 'serif';

  static ThemeData get light {
    final base = ThemeData.light(useMaterial3: true);
    return base.copyWith(
      colorScheme: ColorScheme.fromSeed(
        seedColor: navy,
        primary: navy,
        secondary: gold,
        surface: Colors.white,
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: paper,
      appBarTheme: const AppBarTheme(
        backgroundColor: navy,
        foregroundColor: Colors.white,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: headingFont,
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
      textTheme: base.textTheme.copyWith(
        headlineSmall: base.textTheme.headlineSmall?.copyWith(
          fontFamily: headingFont,
          fontWeight: FontWeight.bold,
          color: navy,
        ),
        headlineMedium: base.textTheme.headlineMedium?.copyWith(
          fontFamily: headingFont,
          fontWeight: FontWeight.bold,
          color: navy,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontFamily: headingFont,
          fontWeight: FontWeight.bold,
          color: navy,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontFamily: headingFont,
          fontWeight: FontWeight.w700,
          color: navy,
        ),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: 16),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 15),
      ),
      cardTheme: CardThemeData(
        elevation: 2,
        shadowColor: navy.withValues(alpha: 0.15),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        margin: const EdgeInsets.symmetric(vertical: 6),
      ),
      chipTheme: base.chipTheme.copyWith(
        side: BorderSide(color: navy.withValues(alpha: 0.2)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: navy,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: navy,
          side: const BorderSide(color: navy),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: navy),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: gold,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
      ),
      // v1.2: one subtle transition for every screen push — a gentle
      // fade + rise on Android, the native slide on iOS. Light by
      // design (no custom heavy route animations, no jank on low-end
      // phones); the default Material slide is replaced, not layered.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }

  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      colorScheme: ColorScheme.fromSeed(
        seedColor: navy,
        primary: gold,
        secondary: gold,
        surface: const Color(0xFF12294D),
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: navyDark,
      appBarTheme: const AppBarTheme(
        backgroundColor: navyDark,
        foregroundColor: Colors.white,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: headingFont,
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
      textTheme: base.textTheme.copyWith(
        headlineSmall: base.textTheme.headlineSmall?.copyWith(
          fontFamily: headingFont,
          fontWeight: FontWeight.bold,
        ),
        headlineMedium: base.textTheme.headlineMedium?.copyWith(
          fontFamily: headingFont,
          fontWeight: FontWeight.bold,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontFamily: headingFont,
          fontWeight: FontWeight.bold,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontFamily: headingFont,
          fontWeight: FontWeight.w700,
        ),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: 16),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 15),
      ),
      cardTheme: CardThemeData(
        elevation: 2,
        color: const Color(0xFF12294D),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        margin: const EdgeInsets.symmetric(vertical: 6),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: gold,
          foregroundColor: navyDark,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: gold,
          side: const BorderSide(color: gold),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: gold),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: gold,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
      ),
      // v1.2: same subtle transition as light mode (see above).
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }
}
