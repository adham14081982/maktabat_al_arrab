import 'dart:math';

import 'package:flutter/painting.dart';

import '../models/book.dart';
import '../models/reader_settings.dart';

/// The result of paginating a text: the pages, plus where each one starts in
/// the source string.
///
/// The offsets are what make a bookmark survive a font change. A page number
/// means nothing once the text reflows; a character offset still points at the
/// same sentence, so the reader can re-derive the page after repagination.
class TextPagination {
  final List<String> pages;

  /// `starts[i]` is the index in the source text where `pages[i]` begins.
  final List<int> starts;

  const TextPagination({required this.pages, required this.starts});

  static const TextPagination empty =
      TextPagination(pages: [''], starts: [0]);

  /// Which page holds the given character offset.
  int pageForOffset(int offset) {
    if (starts.isEmpty) return 0;
    var lo = 0, hi = starts.length - 1, best = 0;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (starts[mid] <= offset) {
        best = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return best;
  }

  int get length => pages.length;
}

/// Splits book text into pages that actually fit the screen.
///
/// The previous implementation guessed characters-per-line from a font-size
/// multiplier and wrapped with its own word splitter. That diverges from what
/// Flutter really paints — a page could overflow or leave half a screen empty,
/// and the error grew with font size. Here every candidate page is laid out
/// with [TextPainter] at the exact width, so a page is full when the painter
/// says it is full.
class TextPaginator {
  static const double horizontalPadding = 32.0;
  static const double verticalPadding = 24.0;

  /// Upper bound on characters measured per page. Binary search starts from
  /// this, and a real page never needs more.
  static const int _maxPageChars = 6000;

  static TextStyle _styleFor(ReaderSettings settings) => TextStyle(
        fontFamily: settings.fontFamily,
        fontSize: settings.fontSize,
        height: settings.lineSpacing,
        letterSpacing: 0,
      );

  static double _heightOf(String text, double width, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.rtl,
      maxLines: null,
    )..layout(maxWidth: width);
    final h = painter.height;
    painter.dispose();
    return h;
  }

  /// Paginate with real text measurement.
  static TextPagination paginateMeasured({
    required String text,
    required double screenWidth,
    required double screenHeight,
    required ReaderSettings settings,
  }) {
    if (text.trim().isEmpty) return TextPagination.empty;

    final width = max(1.0, screenWidth - horizontalPadding * 2);
    final height = max(1.0, screenHeight - verticalPadding * 2);
    final style = _styleFor(settings);

    final pages = <String>[];
    final starts = <int>[];
    var cursor = 0;

    while (cursor < text.length) {
      // Skip leading whitespace so a page never starts with blank lines.
      while (cursor < text.length && text[cursor].trim().isEmpty) {
        cursor++;
      }
      if (cursor >= text.length) break;

      final remaining = text.length - cursor;
      var lo = 1;
      var hi = min(_maxPageChars, remaining);
      var best = 0;

      // Largest prefix that still fits the page box.
      while (lo <= hi) {
        final mid = (lo + hi) ~/ 2;
        final fits =
            _heightOf(text.substring(cursor, cursor + mid), width, style) <=
                height;
        if (fits) {
          best = mid;
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }

      if (best <= 0) best = 1; // a single glyph taller than the page

      // Never cut a word in half: back off to the last whitespace, but only if
      // that keeps most of the page.
      if (cursor + best < text.length) {
        final window = text.substring(cursor, cursor + best);
        final cut = window.lastIndexOf(RegExp(r'\s'));
        if (cut > window.length * 0.6) best = cut + 1;
      }

      final pageText = text.substring(cursor, cursor + best).trim();
      if (pageText.isNotEmpty) {
        pages.add(pageText);
        starts.add(cursor);
      }
      cursor += best;
    }

    if (pages.isEmpty) return TextPagination.empty;
    return TextPagination(pages: pages, starts: starts);
  }

  /// Backwards-compatible wrapper returning just the page strings.
  static List<String> paginate({
    required String text,
    required double screenWidth,
    required double screenHeight,
    required ReaderSettings settings,
  }) {
    return paginateMeasured(
      text: text,
      screenWidth: screenWidth,
      screenHeight: screenHeight,
      settings: settings,
    ).pages;
  }

  /// Paginate for image-mode books (each image is a page)
  static List<String> paginateImages(List<String> images) {
    return images;
  }
}

/// Combined content paginator that handles both text and image modes
class ContentPaginator {
  /// Paginate book content based on its mode
  static List<String> paginateContent({
    required BookDetail bookDetail,
    required double screenWidth,
    required double screenHeight,
    required ReaderSettings settings,
  }) {
    if (bookDetail.contentMode == 'image') {
      return TextPaginator.paginateImages(bookDetail.images);
    } else if (bookDetail.hasOcrText) {
      // Hybrid books paginate ONE text page per original image page, so the
      // page index stays identical when switching image ⇄ text — the reading
      // position survives the toggle exactly (spec: تقريبي، وهنا تطابق تام).
      // Localised font reflow would break that alignment, so it is reserved
      // for pure text books below.
      final pages = bookDetail.ocrPages
          .map((p) => p.text.trim())
          .toList();
      return pages.isEmpty ? const [''] : pages;
    } else {
      // Combine all chapter texts
      final fullText = bookDetail.chapters
          .map((c) => c.text)
          .join('\n\n');
      return TextPaginator.paginate(
        text: fullText,
        screenWidth: screenWidth,
        screenHeight: screenHeight,
        settings: settings,
      );
    }
  }
}
