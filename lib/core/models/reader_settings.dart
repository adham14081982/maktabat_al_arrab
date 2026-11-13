import 'reader_palette.dart';

/// How the reader moves from page to page.
///
/// [horizontal] keeps the classic book-like left/right page flip with RTL
/// flow, while [vertical] produces a smooth top-to-bottom scroll — some
/// readers find vertical scrolling less tiring for scanned pages.
enum ReadingAxis {
  horizontal,
  vertical;

  static ReadingAxis fromName(String? name) => name == 'vertical'
      ? ReadingAxis.vertical
      : ReadingAxis.horizontal;

  String get name => this == ReadingAxis.vertical ? 'vertical' : 'horizontal';
}

/// How landscape "double-page" scans (a spread holding two printed pages on
/// one image) are handled in the reader.
///
/// - [never]  : show the whole spread fitted to the screen (manual zoom).
/// - [auto]   : detect wide scans by their aspect ratio and split them into
///              two full-height tall pages automatically — the default.
/// - [always] : treat every page image as a spread (for books that are
///              entirely double-page scans).
enum DoublePageSplitMode {
  never,
  auto,
  always;

  static DoublePageSplitMode fromName(String? name) =>
      switch (name) {
        'always' => DoublePageSplitMode.always,
        'never' => DoublePageSplitMode.never,
        _ => DoublePageSplitMode.auto, // ذكي تلقائيًا افتراضيًا
      };

  String get name => switch (this) {
        DoublePageSplitMode.never => 'never',
        DoublePageSplitMode.always => 'always',
        DoublePageSplitMode.auto => 'auto',
      };
}

/// User reading settings
class ReaderSettings {
  final double fontSize;
  final String fontFamily;      // "Amiri", "Cairo", etc.
  final double lineSpacing;     // 1.0 - 3.0
  final bool nightMode;
  final bool pageFlipEffect;    // 3D page curl on/off
  final bool hapticFeedback;    // vibration on page turn
  final bool pageFlipSound;     // sound on page turn

  /// Page-turn direction: horizontal flip or vertical smooth scroll.
  final ReadingAxis readingAxis;

  /// How landscape double-page scans are displayed (image-mode books).
  final DoublePageSplitMode splitMode;

  /// Inverts scanned page colours while in night mode (bright paper → dark
  /// paper). Scans stay glaringly white in the dark otherwise.
  final bool scanNightFilter;

  /// Colour scheme of the page area (paper / sepia / white / dark).
  final ReaderPalette palette;

  /// Screen dimming for night reading, 0.35 (very dim) → 1.0 (full).
  ///
  /// Implemented as a black scrim over the page rather than by changing the
  /// device backlight: it needs no platform permission, it works in the dark
  /// palette too, and it never fights the system brightness the user set.
  final double brightness;

  const ReaderSettings({
    this.fontSize = 18.0,
    this.fontFamily = 'Amiri',
    this.lineSpacing = 1.8,
    this.nightMode = false,
    this.pageFlipEffect = true,
    this.hapticFeedback = true,
    this.pageFlipSound = false,
    this.readingAxis = ReadingAxis.horizontal,
    this.splitMode = DoublePageSplitMode.auto,
    this.scanNightFilter = false,
    this.palette = ReaderPalette.warm,
    this.brightness = 1.0,
  });

  factory ReaderSettings.fromMap(Map<dynamic, dynamic> map) {
    return ReaderSettings(
      fontSize: (map['font_size'] as num?)?.toDouble() ?? 18.0,
      fontFamily: map['font_family'] as String? ?? 'Amiri',
      lineSpacing: (map['line_spacing'] as num?)?.toDouble() ?? 1.8,
      nightMode: map['night_mode'] as bool? ?? false,
      pageFlipEffect: map['page_flip_effect'] as bool? ?? true,
      hapticFeedback: map['haptic_feedback'] as bool? ?? true,
      pageFlipSound: map['page_flip_sound'] as bool? ?? false,
      // إعدادات جديدة: تُشتق بأمان من قيمة محفوظة نصية أو تُرجع الافتراضي
      readingAxis:
          ReadingAxis.fromName(map['reading_axis'] as String?),
      splitMode:
          DoublePageSplitMode.fromName(map['page_split_mode'] as String?),
      scanNightFilter: map['scan_night_filter'] as bool? ?? false,
      palette: ReaderPalette.fromId(map['palette'] as String?),
      brightness: (map['brightness'] as num?)?.toDouble() ?? 1.0,
    );
  }

  Map<String, dynamic> toMap() => {
        'font_size': fontSize,
        'font_family': fontFamily,
        'line_spacing': lineSpacing,
        'night_mode': nightMode,
        'page_flip_effect': pageFlipEffect,
        'haptic_feedback': hapticFeedback,
        'page_flip_sound': pageFlipSound,
        'reading_axis': readingAxis.name,
        'page_split_mode': splitMode.name,
        'scan_night_filter': scanNightFilter,
        'palette': palette.id,
        'brightness': brightness,
      };

  ReaderSettings copyWith({
    double? fontSize,
    String? fontFamily,
    double? lineSpacing,
    bool? nightMode,
    bool? pageFlipEffect,
    bool? hapticFeedback,
    bool? pageFlipSound,
    ReadingAxis? readingAxis,
    DoublePageSplitMode? splitMode,
    bool? scanNightFilter,
    ReaderPalette? palette,
    double? brightness,
  }) {
    return ReaderSettings(
      fontSize: fontSize ?? this.fontSize,
      fontFamily: fontFamily ?? this.fontFamily,
      lineSpacing: lineSpacing ?? this.lineSpacing,
      nightMode: nightMode ?? this.nightMode,
      pageFlipEffect: pageFlipEffect ?? this.pageFlipEffect,
      hapticFeedback: hapticFeedback ?? this.hapticFeedback,
      pageFlipSound: pageFlipSound ?? this.pageFlipSound,
      readingAxis: readingAxis ?? this.readingAxis,
      splitMode: splitMode ?? this.splitMode,
      scanNightFilter: scanNightFilter ?? this.scanNightFilter,
      palette: palette ?? this.palette,
      brightness: brightness ?? this.brightness,
    );
  }
}
