import 'dart:ui' show Color;

/// Reading colour schemes for the scanned-page reader.
///
/// Every page is stored as a **greyscale image on white paper**, so one asset
/// can serve every theme: the reader maps black→[ink] and white→[paper] with a
/// single colour matrix ([colorMatrix]). Because the surrounding background is
/// painted with the exact same [paper] colour, the page blends into the screen
/// with no visible white box floating on a beige background — which is what
/// made the old reader look broken.
enum ReaderPalette {
  /// Warm off-white, closest to a printed paperback.
  /// (The enum value is "warm" because a constant can't share its name with
  /// the [paper] field; the persisted [id] remains 'paper'.)
  warm(
    id: 'paper',
    label: 'ورقي',
    paper: Color(0xFFFBF6EC),
    ink: Color(0xFF2B2622),
    chrome: Color(0xFF3B2A1E),
    onChrome: Color(0xFFE8D9BE),
  ),

  /// Classic sepia — the most comfortable for long sessions.
  sepia(
    id: 'sepia',
    label: 'سيبيا',
    paper: Color(0xFFFBF0D9),
    ink: Color(0xFF2C2523),
    chrome: Color(0xFF4A3524),
    onChrome: Color(0xFFEFE0C4),
  ),

  /// Pure white with black text, like a freshly printed page.
  white(
    id: 'white',
    label: 'أبيض',
    paper: Color(0xFFFFFFFF),
    ink: Color(0xFF111111),
    chrome: Color(0xFF262626),
    onChrome: Color(0xFFEDEDED),
  ),

  /// OLED-friendly dark reading: light ink on near-black paper.
  dark(
    id: 'dark',
    label: 'داكن',
    paper: Color(0xFF121212),
    ink: Color(0xFFD9D4CA),
    chrome: Color(0xFF0B0B0B),
    onChrome: Color(0xFFC9C4BA),
  );

  const ReaderPalette({
    required this.id,
    required this.label,
    required this.paper,
    required this.ink,
    required this.chrome,
    required this.onChrome,
  });

  final String id;
  final String label;

  /// Background of the page (and of the reader itself, so they are seamless).
  final Color paper;

  /// Colour that pure black in the scan is mapped to.
  final Color ink;

  /// Background of the floating bars.
  final Color chrome;

  /// Text/icon colour on the floating bars.
  final Color onChrome;

  bool get isDark => paper.computeLuminance() < 0.4;

  /// 4x5 colour matrix that maps greyscale (v, v, v) to the range ink→paper.
  ///
  /// out = ink + (paper - ink) * v  — for the dark palette the coefficient is
  /// negative, which inverts the page so the text turns light.
  List<double> get colorMatrix => <double>[
        paper.r - ink.r, 0, 0, 0, ink.r * 255,
        0, paper.g - ink.g, 0, 0, ink.g * 255,
        0, 0, paper.b - ink.b, 0, ink.b * 255,
        0, 0, 0, 1, 0,
      ];

  static ReaderPalette fromId(String? id) {
    for (final p in ReaderPalette.values) {
      if (p.id == id) return p;
    }
    return ReaderPalette.warm;
  }
}

