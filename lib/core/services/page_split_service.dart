import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/reader_settings.dart';

/// One measured page: aspect ratio plus optional dark-margin crop box.
///
/// Scans are often photographed on a dark desk, so the rendered page is
/// surrounded by wide black borders — cropping them back to the bright page
/// region is what makes the reader's page view look clean and fills the
/// screen with actual content.
class PageAnalysis {
  /// Width / height of the raw page image.
  final double aspect;

  /// Bright-content bounding box as fractions of the image size
  /// (left, top, right, bottom), or null when no crop is needed/detected.
  final Rect? crop;

  /// True when this entry was measured by the *current* crop detector.
  /// Entries restored from a cache written by an older detector version have
  /// this false and are re-measured once so stale bounds never persist.
  final bool cropMeasured;

  const PageAnalysis({
    required this.aspect,
    this.crop,
    this.cropMeasured = true,
  });
}

/// Detection and calibration helpers for landscape "double-page" scans.
///
/// - Measures every page once and remembers the result (in memory and on
///   disk) so a reopened book lays out correctly on the first frame.
/// - Lets the reader cut a spread into two separate full-height tall pages.
class PageSplitService {
  PageSplitService._();

  /// A page rendered wider than this aspect ratio (width / height) is assumed
  /// to be a two-page spread. A single tuned value works because portrait
  /// pages land near 2:3 (≈0.67) and spreads near 4:3 (≈1.33).
  static const double spreadAspectRatio = 1.05;

  /// Analyses learned so far, keyed by page file path. Shared across books
  /// for the lifetime of the app session.
  static final Map<String, PageAnalysis> _analysisCache = {};

  /// Previously measured value for a path, or null when unknown.
  static PageAnalysis? cachedAnalysis(String path) => _analysisCache[path];

  /// Aspect ratio (>1 means landscape). Deprecated — use [analysisOf];
  /// kept because the crop detector piggybacks on the same decode.
  static Future<double> aspectOf(String path) async =>
      (await analysisOf(path)).aspect;

  /// Decodes one page image, measures its aspect ratio AND its bright
  /// content bounds, then disposes the decoded frame — only the summary
  /// stays in memory.
  static Future<PageAnalysis> analysisOf(String path) async {
    final cached = _analysisCache[path];
    // Stale entries (measured by an older, unsafe crop detector) are
    // re-measured; valid ones return instantly.
    if (cached != null && cached.cropMeasured) return cached;

    final bytes = await File(path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes, allowUpscaling: false);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final aspect = image.width / image.height;

    Rect? crop;
    try {
      final raw =
          await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      if (raw != null) {
        crop = detectBrightBounds(raw, image.width, image.height);
      }
    } catch (_) {
      // Cropping is an improvement, never a requirement.
    } finally {
      image.dispose();
      codec.dispose();
    }

    final analysis = PageAnalysis(aspect: aspect, crop: crop);
    _analysisCache[path] = analysis;
    return analysis;
  }

  /// Detects the bright "page" area inside a photographed scan and returns
  /// it as fractions of the image, padded slightly outward so no paper is
  /// shaved away. Returns null when no useful crop can be concluded.
  ///
  /// The threshold is *adaptive*: it is derived from the image's own brightness
  /// histogram (≈40% of the paper's luminance), so dim, unevenly photographed
  /// scans still keep their full paper area. A fixed threshold once shrank the
  /// detected region into the middle of dark photos, rendering pages at 2–3×
  /// zoom with text cut off on both sides — that is exactly what the strict
  /// acceptance gates below prevent.
  static Rect? detectBrightBounds(ByteData raw, int width, int height) {
    // Down-sample while scanning so a 4K page costs a few thousand samples.
    final step = max(1, (width / 220).round());
    final cols = (width / step).floor();
    final rows = (height / step).floor();
    if (cols < 8 || rows < 8) return null;

    final bytes = raw.buffer.asUint8List(raw.offsetInBytes);

    // Pass 1 — luminance histogram of the sampled grid, to find the paper's
    // brightness (97th percentile) and set a relative threshold from it.
    final histogram = Int32List(256);
    final lums = Int32List(cols * rows);
    var sampleIndex = 0;
    for (var ry = 0; ry < rows; ry++) {
      final y = (ry * step).clamp(0, height - 1);
      for (var cx = 0; cx < cols; cx++) {
        final x = (cx * step).clamp(0, width - 1);
        final o = (y * width + x) * 4;
        final lum = (0.299 * bytes[o] + 0.587 * bytes[o + 1] +
                0.114 * bytes[o + 2])
            .round()
            .clamp(0, 255);
        lums[sampleIndex++] = lum;
        histogram[lum]++;
      }
    }
    var cumulative = 0;
    var paperLum = 255;
    for (var v = 0; v < 256; v++) {
      cumulative += histogram[v];
      if (cumulative >= lums.length * 0.97) {
        paperLum = v;
        break;
      }
    }
    /* Selective: paper ≈ 150-250, shadowed paper edges 60-120, desk 0-35. */
    final lumThreshold = (paperLum * 0.40).clamp(20.0, 90.0);
    const contentFraction = 0.06; /* ≥6% of a line bright ⇒ content line */

    final colBright = Uint32List(cols);
    final rowBright = Uint32List(rows);
    double? top, bottom, left, right;

    for (var i = 0; i < lums.length; i++) {
      if (lums[i] > lumThreshold) {
        colBright[i % cols]++;
        rowBright[i ~/ cols]++;
      }
    }
    for (var ry = 0; ry < rows; ry++) {
      if (rowBright[ry] > cols * contentFraction) {
        top ??= (ry * step).toDouble();
        bottom = (ry * step).toDouble();
      }
    }
    for (var cx = 0; cx < cols; cx++) {
      if (colBright[cx] > rows * contentFraction) {
        left ??= (cx * step).toDouble();
        right = (cx * step).toDouble();
      }
    }

    if (top == null || left == null || right == null || bottom == null) {
      return null;
    }

    // Outward padding (~1.2% + one sample) so the threshold never shaves the
    // paper's outermost rows/cols into invisibility.
    final padX = width * 0.012 + step;
    final padY = height * 0.012 + step;
    final fx0 = ((left - padX) / width).clamp(0.0, 1.0).toDouble();
    final fy0 = ((top - padY) / height).clamp(0.0, 1.0).toDouble();
    final fx1 = ((right + padX) / width).clamp(0.0, 1.0).toDouble();
    final fy1 = ((bottom + padY) / height).clamp(0.0, 1.0).toDouble();

    final fw = fx1 - fx0;
    final fh = fy1 - fy0;
    // Conservative acceptance gates — only obvious camera-desk margins are
    // cropped. Anything smaller than 55% on the width or 45% on the height
    // means the detection drifted INTO the page (dark photo, uneven light);
    // showing the whole image instead is always the safe outcome.
    if (fw < 0.55 || fh < 0.45) return null;
    if (fw > 0.995 && fh > 0.995) return null; // already full-bleed
    return Rect.fromLTRB(fx0, fy0, fx1, fy1);
  }

  /// Whether a page with this aspect ratio is a double-page spread.
  static bool isSpread(double aspect) => aspect > spreadAspectRatio;

  /// Whether [splitMode] should cut the page into two halves,
  /// given the analyses measured so far (null = not measured yet).
  ///
  /// - never  : never split.
  /// - auto   : split only pages *known* to be wide (measured > 1.05).
  /// - always : split everything (safety: also split unknown pages, the
  ///   rendering falls back to a fitted whole page until the ratio arrives).
  static bool shouldSplitFile(
    DoublePageSplitMode splitMode,
    PageAnalysis? analysis,
  ) =>
      switch (splitMode) {
        DoublePageSplitMode.never => false,
        DoublePageSplitMode.always =>
          analysis == null || isSpread(analysis.aspect),
        DoublePageSplitMode.auto =>
          analysis != null && isSpread(analysis.aspect),
      };

  /// Aspect ratio of the visible sub-region [frac] (fractions of the full
  /// image) of an image whose raw aspect is [fullAspect].
  static double regionAspect(double fullAspect, Rect frac) =>
      fullAspect * frac.width / frac.height;

  /// The fraction of the full image that lives in a spread's half.
  /// Right half occupies [0.5, 1] on the x axis, left half [0, 0.5].
  static Rect halfRegion(Rect? crop, bool rightHalf) {
    final c = crop ?? const Rect.fromLTRB(0, 0, 1, 1);
    if (rightHalf) {
      final x0 = max(c.left, 0.5);
      return Rect.fromLTRB(x0, c.top, max(c.right, x0 + 0.01), c.bottom);
    }
    final x1 = min(c.right, 0.5);
    return Rect.fromLTRB(min(c.left, x1 - 0.01), c.top, x1, c.bottom);
  }

  /// Cache format version. Bumped to 3 when the crop detector changed from
  /// a fixed brightness threshold to an adaptive one — cached crops written
  /// by older versions are discarded (aspects are kept). Version 3 entries
  /// always carry the `c` key, even when null, so legacy entries can be
  /// told apart and re-measured exactly once.
  static const int _cacheVersion = 3;

  /// Restores previously measured analyses from `<bookDir>/pages.json` so a
  /// reopened book lays out correctly on the first frame. Accepts the
  /// legacy formats (flat path → aspect, or path → {a, c}) and the current
  /// versioned one ({v: 3, pages: {path → {a, c}}}).
  static Future<void> loadPersisted(String bookDir, List<String> files) async {
    try {
      final file = File('$bookDir/pages.json');
      if (!await file.exists()) return;
      final root =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;

      final bool currentVersion = root['v'] == _cacheVersion;
      final Map<String, dynamic> map =
          currentVersion && root['pages'] is Map<String, dynamic>
              ? (root['pages'] as Map<String, dynamic>)
              : root;

      for (final path in files) {
        if (_analysisCache.containsKey(path)) continue;
        final value = map[path];
        if (value is num && value > 0) {
          // Legacy entry: aspect only — crop must be measured fresh.
          _analysisCache[path] = PageAnalysis(
            aspect: value.toDouble(),
            cropMeasured: false,
          );
        } else if (value is Map<String, dynamic>) {
          final a = (value['a'] as num?)?.toDouble() ?? 0;
          if (a <= 0) continue;
          final currentEntry = currentVersion && value.containsKey('c');
          Rect? crop;
          final c = value['c'] as List?;
          if (c != null && c.length == 4) {
            crop = Rect.fromLTRB(
              (c[0] as num).toDouble(),
              (c[1] as num).toDouble(),
              (c[2] as num).toDouble(),
              (c[3] as num).toDouble(),
            );
          }
          _analysisCache[path] = PageAnalysis(
            aspect: a,
            crop: crop,
            // Older, non-versioned entries were produced by the unsafe
            // fixed-threshold detector — mark them stale so they get
            // re-measured with the adaptive one.
            cropMeasured: currentEntry,
          );
        }
      }
    } catch (_) {
      // A damaged cache file is never fatal — the reader re-measures instead.
    }
  }

  /// Saves the measured analyses next to the extracted pages for instant
  /// layout on the next open.
  static Future<void> persist(String bookDir, List<String> files) async {
    try {
      final map = <String, Map<String, dynamic>>{};
      for (final path in files) {
        final a = _analysisCache[path];
        if (a == null) continue;
        map[path] = {
          'a': a.aspect,
          // Always written under the current version — even when the crop is
          // null (full-bleed pages) — so reopening won't re-decode them.
          'c': a.crop == null
              ? null
              : [
                  a.crop!.left,
                  a.crop!.top,
                  a.crop!.right,
                  a.crop!.bottom,
                ],
        };
      }
      if (map.isEmpty) return;
      await File('$bookDir/pages.json').writeAsString(
        jsonEncode({'v': _cacheVersion, 'pages': map}),
        flush: true,
      );
    } catch (_) {
      // Writing the cache is a best-effort optimisation only.
    }
  }
}
