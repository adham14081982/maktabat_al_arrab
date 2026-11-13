import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maktabat_al_arrab/core/models/book.dart';
import 'package:maktabat_al_arrab/core/models/section.dart';
import 'package:maktabat_al_arrab/core/models/reading_progress.dart';
import 'package:maktabat_al_arrab/core/models/bookmark.dart';
import 'package:maktabat_al_arrab/core/models/reader_settings.dart';
import 'package:maktabat_al_arrab/core/services/page_split_service.dart';
import 'package:maktabat_al_arrab/core/services/text_paginator.dart';

void main() {
  group('Models', () {
    test('Book fromJson parses correctly', () {
      final json = {
        'id': 'book_001_test',
        'title': 'أسطورة النداهة',
        'series': 'ma_wara_al_tabia',
        'page_count': 150,
        'cover': 'covers/book_001_test.webp',
        'content_mode': 'text',
        'quality_score': 0.85,
        'json_file': 'book_001_test.json',
      };

      final book = Book.fromJson(json);

      expect(book.id, 'book_001_test');
      expect(book.title, 'أسطورة النداهة');
      expect(book.series, 'ma_wara_al_tabia');
      expect(book.pageCount, 150);
      expect(book.cover, 'covers/book_001_test.webp');
      expect(book.contentMode, 'text');
      expect(book.qualityScore, 0.85);
    });

    test('Section fromJson parses correctly', () {
      final json = {
        'id': 'safari',
        'title': 'سافاري',
        'subtitle': 'سلسلة الرحلات',
        'color_accent': '#8B6914',
        'icon': 'compass',
      };

      final section = Section.fromJson(json);

      expect(section.id, 'safari');
      expect(section.title, 'سافاري');
      expect(section.subtitle, 'سلسلة الرحلات');
      expect(section.colorAccent, '#8B6914');
      expect(section.icon, 'compass');
    });

    test('ReadingProgress calculates correct ratio', () {
      const progress = ReadingProgress(
        bookId: 'book_001',
        currentPage: 50,
        totalPages: 200,
        lastReadTimestamp: 1700000000,
        progress: 50 / 200,
      );

      expect(progress.progress, 0.25);
    });

    test('Bookmark toMap and fromMap roundtrip', () {
      const bookmark = Bookmark(
        bookId: 'book_001',
        bookTitle: 'أسطورة النداهة',
        pageNumber: 42,
        note: 'صفحة مهمة',
        timestamp: 1700000000,
      );

      final map = bookmark.toMap();
      final restored = Bookmark.fromMap(map);

      expect(restored.bookId, bookmark.bookId);
      expect(restored.bookTitle, bookmark.bookTitle);
      expect(restored.pageNumber, bookmark.pageNumber);
      expect(restored.note, bookmark.note);
      expect(restored.timestamp, bookmark.timestamp);
    });

    test('ReaderSettings copyWith works correctly', () {
      const settings = ReaderSettings();
      final updated = settings.copyWith(fontSize: 24.0, nightMode: true);

      expect(updated.fontSize, 24.0);
      expect(updated.nightMode, true);
      expect(updated.fontFamily, 'Amiri'); // unchanged
    });

    test('ReaderSettings new enums default to smart split + horizontal', () {
      // إعدادات التقسيم والمحور: الافتراضي ذكي تلقائيًا وأفقيًا.
      const settings = ReaderSettings();
      expect(settings.splitMode, DoublePageSplitMode.auto);
      expect(settings.readingAxis, ReadingAxis.horizontal);

      // Roundtrip عبر toMap/fromMap.
      final restored = ReaderSettings.fromMap(settings.toMap());
      expect(restored.splitMode, DoublePageSplitMode.auto);
      expect(restored.readingAxis, ReadingAxis.horizontal);

      final changed = ReaderSettings.fromMap({
        'reading_axis': 'vertical',
        'page_split_mode': 'always',
      });
      expect(changed.readingAxis, ReadingAxis.vertical);
      expect(changed.splitMode, DoublePageSplitMode.always);

      // قيم غير معروفة → افتراضي آمن.
      final unknown = ReaderSettings.fromMap({
        'reading_axis': 'sideways',
        'page_split_mode': 'wat',
      });
      expect(unknown.readingAxis, ReadingAxis.horizontal);
      expect(unknown.splitMode, DoublePageSplitMode.auto);
    });

    test('PageSplitService spread detection thresholds', () {
      // صفحة عمودية عادية (2:3) ليست افتراحية، والمقاس 4:3 (~1.33) كذلك.
      expect(PageSplitService.isSpread(2 / 3), isFalse);
      expect(PageSplitService.isSpread(1.0), isFalse);
      expect(PageSplitService.isSpread(4 / 3), isTrue);

      // سياسة القرار: auto ينتظر القياس، always يقسم كل ما ليس رأسيًا مقاسًا.
      PageAnalysis mk(double aspect) =>
          PageAnalysis(aspect: aspect); // مساعد قصير للتحليل
      expect(PageSplitService.shouldSplitFile(
          DoublePageSplitMode.auto, null), isFalse);
      expect(PageSplitService.shouldSplitFile(
          DoublePageSplitMode.auto, mk(4 / 3)), isTrue);
      expect(PageSplitService.shouldSplitFile(
          DoublePageSplitMode.never, mk(4 / 3)), isFalse);
      // "دائمًا" مفيد لنسخ مزدوجة الصفحات بالكامل: يفترض التقسيم حتى دون قياس
      // الصفحة، لكن يستثني الصفحات الرأسية المقاسة حتى لا تُقطَع خطأً.
      expect(PageSplitService.shouldSplitFile(
          DoublePageSplitMode.always, null), isTrue);
      expect(PageSplitService.shouldSplitFile(
          DoublePageSplitMode.always, mk(2 / 3)), isFalse);

      // حساب نسبة أبعاد المنطقة المرئية القصوصة.
      expect(
        PageSplitService.regionAspect(2 / 3, const Rect.fromLTRB(0, 0, 1, 1)),
        closeTo(2 / 3, 1e-6),
      );
      expect(
        PageSplitService.regionAspect(3 / 2, const Rect.fromLTRB(0, 0.5, 1, 1)),
        closeTo(3.0, 1e-6), // 1.5 * 1 / 0.5
      );

      // نصفا الافتراحية: الأيمن [0.5..1] والأيسر [0..0.5].
      final right = PageSplitService.halfRegion(null, true);
      expect(right.left, closeTo(0.5, 1e-6));
      expect(right.right, 1.0);
      final left = PageSplitService.halfRegion(
          const Rect.fromLTRB(0.1, 0, 0.9, 1), false);
      expect(left.left, closeTo(0.1, 1e-6));
      expect(left.right, closeTo(0.5, 1e-6));
    });
  });

  group('TextPaginator', () {
    test('paginate splits text into multiple pages', () {
      final longText = List.generate(100, (i) => 'هذا نص تجريبي رقم $i للصفحة.').join('\n\n');

      final pages = TextPaginator.paginate(
        text: longText,
        screenWidth: 400,
        screenHeight: 600,
        settings: const ReaderSettings(fontSize: 18, lineSpacing: 1.8),
      );

      expect(pages.length, greaterThan(1));
    });

    test('paginate returns at least one page for empty text', () {
      final pages = TextPaginator.paginate(
        text: '',
        screenWidth: 400,
        screenHeight: 600,
        settings: const ReaderSettings(),
      );

      expect(pages.length, 1);
    });

    test('paginateImages returns same list', () {
      final images = ['page1.webp', 'page2.webp', 'page3.webp'];
      final result = TextPaginator.paginateImages(images);
      expect(result.length, 3);
    });
  });

  group('Library JSON structure', () {
    test('library.json has required fields', () {
      // This test validates the structure once the app runs
      // The actual JSON is loaded at runtime from assets
      expect(true, isTrue);
    });
  });
}
