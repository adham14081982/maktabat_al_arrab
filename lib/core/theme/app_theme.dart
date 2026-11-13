import 'package:flutter/material.dart';
import '../constants/app_constants.dart';

/// Antique library theme for Maktabat Al-Arrab
/// Colors: parchment (#F3E7CF), leather brown (#4A2C1A), gold (#C9A24B), crimson (#8B1E2D)
class AppTheme {
  AppTheme._();

  // ─── Light Theme (Parchment & Leather) ──────────────────────────────────
  static ThemeData get lightTheme {
    const parchment = Color(AppConstants.parchmentHex);
    const leather = Color(AppConstants.leatherBrownHex);
    const gold = Color(AppConstants.goldHex);
    const crimson = Color(AppConstants.crimsonHex);

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,

      // Color scheme
      colorScheme: const ColorScheme.light(
        primary: leather,
        onPrimary: parchment,
        secondary: gold,
        onSecondary: leather,
        tertiary: crimson,
        onTertiary: parchment,
        surface: parchment,
        onSurface: leather,
        surfaceContainerHighest: Color(0xFFE8DBC0),
        onSurfaceVariant: leather,
        outline: gold,
        outlineVariant: Color(0xFFB8A377),
      ),

      // Scaffold
      scaffoldBackgroundColor: parchment,

      // App bar
      appBarTheme: const AppBarTheme(
        backgroundColor: leather,
        foregroundColor: gold,
        elevation: 4,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: 'ReemKufi',
          fontSize: 22,
          fontWeight: FontWeight.bold,
          color: gold,
        ),
      ),

      // Card theme (book covers, shelves)
      cardTheme: CardThemeData(
        color: const Color(0xFFEDE0C7),
        elevation: 6,
        shadowColor: leather.withValues(alpha: 0.4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: gold.withValues(alpha: 0.5), width: 1),
        ),
        margin: const EdgeInsets.all(6),
      ),

      // Text themes — Arabic fonts
      textTheme: const TextTheme(
        // Body text (reader)
        bodyLarge: TextStyle(
          fontFamily: 'Amiri',
          fontSize: 18,
          height: 1.8,
          color: leather,
        ),
        bodyMedium: TextStyle(
          fontFamily: 'Amiri',
          fontSize: 16,
          height: 1.7,
          color: leather,
        ),
        bodySmall: TextStyle(
          fontFamily: 'Amiri',
          fontSize: 14,
          height: 1.6,
          color: leather,
        ),
        // Titles
        titleLarge: TextStyle(
          fontFamily: 'ReemKufi',
          fontSize: 24,
          fontWeight: FontWeight.bold,
          color: leather,
        ),
        titleMedium: TextStyle(
          fontFamily: 'ReemKufi',
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: leather,
        ),
        titleSmall: TextStyle(
          fontFamily: 'ReemKufi',
          fontSize: 16,
          color: leather,
        ),
        // UI elements
        labelLarge: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: leather,
        ),
        labelMedium: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 14,
          color: leather,
        ),
        labelSmall: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 12,
          color: leather,
        ),
      ),

      // Buttons
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: crimson,
          foregroundColor: parchment,
          elevation: 4,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: leather,
          side: const BorderSide(color: gold, width: 2),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),

      // Bottom navigation
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: leather,
        selectedItemColor: gold,
        // Was #8A6F4A — too dim on dark leather at a glance.
        unselectedItemColor: Color(0xFFD3C09B),
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle: TextStyle(fontFamily: 'Cairo', fontSize: 12),
        unselectedLabelStyle: TextStyle(fontFamily: 'Cairo', fontSize: 12),
      ),

      // Divider
      dividerTheme: const DividerThemeData(
        color: gold,
        thickness: 1,
        space: 1,
      ),

      // Icon theme
      iconTheme: const IconThemeData(
        color: leather,
        size: 24,
      ),

      // Progress indicator
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: gold,
        linearTrackColor: Color(0xFFD4C4A0),
      ),

      // Slider (for page navigation in reader)
      sliderTheme: SliderThemeData(
        activeTrackColor: gold,
        inactiveTrackColor: const Color(0xFFD4C4A0),
        thumbColor: crimson,
        overlayColor: crimson.withValues(alpha: 0.2),
        trackHeight: 3,
      ),
    );
  }

  // ─── Dark Theme (Dark Brown & Ivory) ───────────────────────────────────
  static ThemeData get darkTheme {
    const darkBrown = Color(AppConstants.darkBrownHex);
    const ivory = Color(AppConstants.ivoryTextHex);
    const gold = Color(AppConstants.goldHex);
    const crimson = Color(AppConstants.crimsonHex);
    const darkParchment = Color(0xFF1F1510);

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,

      colorScheme: const ColorScheme.dark(
        primary: gold,
        onPrimary: darkBrown,
        secondary: crimson,
        onSecondary: ivory,
        tertiary: gold,
        onTertiary: darkBrown,
        surface: darkParchment,
        onSurface: ivory,
        surfaceContainerHighest: Color(0xFF352518),
        onSurfaceVariant: ivory,
        outline: gold,
        outlineVariant: Color(0xFF6B5538),
      ),

      scaffoldBackgroundColor: darkBrown,

      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF1A0F08),
        foregroundColor: gold,
        elevation: 4,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: 'ReemKufi',
          fontSize: 22,
          fontWeight: FontWeight.bold,
          color: gold,
        ),
      ),

      cardTheme: CardThemeData(
        color: const Color(0xFF352518),
        elevation: 4,
        shadowColor: Colors.black.withValues(alpha: 0.6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: gold.withValues(alpha: 0.3), width: 1),
        ),
        margin: const EdgeInsets.all(6),
      ),

      textTheme: const TextTheme(
        bodyLarge: TextStyle(
          fontFamily: 'Amiri',
          fontSize: 18,
          height: 1.8,
          color: ivory,
        ),
        bodyMedium: TextStyle(
          fontFamily: 'Amiri',
          fontSize: 16,
          height: 1.7,
          color: ivory,
        ),
        bodySmall: TextStyle(
          fontFamily: 'Amiri',
          fontSize: 14,
          height: 1.6,
          color: ivory,
        ),
        titleLarge: TextStyle(
          fontFamily: 'ReemKufi',
          fontSize: 24,
          fontWeight: FontWeight.bold,
          color: gold,
        ),
        titleMedium: TextStyle(
          fontFamily: 'ReemKufi',
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: gold,
        ),
        titleSmall: TextStyle(
          fontFamily: 'ReemKufi',
          fontSize: 16,
          color: ivory,
        ),
        labelLarge: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: ivory,
        ),
        labelMedium: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 14,
          color: ivory,
        ),
        labelSmall: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 12,
          color: ivory,
        ),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: crimson,
          foregroundColor: ivory,
          elevation: 4,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ivory,
          side: const BorderSide(color: gold, width: 2),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),

      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Color(0xFF1A0F08),
        selectedItemColor: gold,
        // Was #6B5538 — nearly invisible against the dark bar.
        unselectedItemColor: Color(0xFFB39B74),
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle: TextStyle(fontFamily: 'Cairo', fontSize: 12),
        unselectedLabelStyle: TextStyle(fontFamily: 'Cairo', fontSize: 12),
      ),

      dividerTheme: const DividerThemeData(
        color: Color(0xFF6B5538),
        thickness: 1,
        space: 1,
      ),

      iconTheme: const IconThemeData(
        color: ivory,
        size: 24,
      ),

      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: gold,
        linearTrackColor: Color(0xFF352518),
      ),

      sliderTheme: SliderThemeData(
        activeTrackColor: gold,
        inactiveTrackColor: const Color(0xFF352518),
        thumbColor: crimson,
        overlayColor: crimson.withValues(alpha: 0.2),
        trackHeight: 3,
      ),
    );
  }

  // ─── Helper: Series accent color ───────────────────────────────────────
  static Color seriesAccent(String seriesId) {
    switch (seriesId) {
      case 'ma_wara_al_tabia':
        return const Color(AppConstants.maWaraAccent);
      case 'fantazia':
        return const Color(AppConstants.fantaziaAccent);
      case 'safari':
        return const Color(AppConstants.safariAccent);
      case 'standalone_novels':
        return const Color(AppConstants.standaloneAccent);
      case 'translations':
        return const Color(AppConstants.translationsAccent);
      default:
        return const Color(AppConstants.goldHex);
    }
  }

  /// Accent colour pushed towards the background's opposite so it stays
  /// readable as TEXT. The raw accents are tuned for large decorative areas,
  /// and on parchment they fall below the WCAG contrast ratio.
  static Color readableAccent(BuildContext context, Color accent) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark
        ? Color.lerp(accent, Colors.white, 0.22)!
        : Color.lerp(accent, Colors.black, 0.30)!;
  }
}
