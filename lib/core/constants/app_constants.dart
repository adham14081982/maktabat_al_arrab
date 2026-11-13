/// Application-wide constants for Maktabat Al-Arrab
class AppConstants {
  AppConstants._();

  // App info
  static const String appName = 'مكتبة العرّاب';
  static const String author = 'د. أحمد خالد توفيق';
  static const String version = '2.3.0';

  // Hive box names
  static const String settingsBox = 'settings';
  static const String progressBox = 'reading_progress';
  static const String bookmarksBox = 'bookmarks';

  // Settings keys
  static const String fontSizeKey = 'font_size';
  static const String fontFamilyKey = 'font_family';
  static const String lineSpacingKey = 'line_spacing';
  static const String nightModeKey = 'night_mode';
  static const String pageFlipEffectKey = 'page_flip_effect';
  static const String hapticFeedbackKey = 'haptic_feedback';
  static const String pageFlipSoundKey = 'page_flip_sound';

  // Default values
  static const double defaultFontSize = 18.0;
  static const double defaultLineSpacing = 1.8;
  static const String defaultFontFamily = 'Amiri';
  static const bool defaultNightMode = false;
  static const bool defaultPageFlipEffect = true;
  static const bool defaultHapticFeedback = true;
  static const bool defaultPageFlipSound = false;

  // Colors (antique library identity)
  static const int parchmentHex = 0xFFF3E7CF;
  static const int leatherBrownHex = 0xFF4A2C1A;
  static const int goldHex = 0xFFC9A24B;
  static const int crimsonHex = 0xFF8B1E2D;

  // Dark mode colors
  static const int darkBrownHex = 0xFF2A1A0F;
  static const int ivoryTextHex = 0xFFE8DCC4;

  // Series accent colors
  static const int maWaraAccent = 0xFF8B1E2D;
  static const int fantaziaAccent = 0xFF4A7C59;
  static const int safariAccent = 0xFF8B6914;
  static const int standaloneAccent = 0xFF6B3FA0;
  static const int translationsAccent = 0xFF2C5F7F;

  // Asset paths
  static const String libraryJsonPath = 'assets/library.json';
  static const String coversPath = 'assets/covers';
  static const String booksPath = 'assets/books';
  static const String decorationsPath = 'assets/decorations';

  // Reader
  static const int pageTurnDurationMs = 400;
  static const double coverAspectRatio = 0.667; // 2:3 ratio typical for book covers
}
