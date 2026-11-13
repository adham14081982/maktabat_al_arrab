import 'package:flutter_test/flutter_test.dart';
import 'package:maktabat_al_arrab/core/models/book.dart';
import 'package:maktabat_al_arrab/core/models/bookmark.dart';
import 'package:maktabat_al_arrab/core/models/reader_settings.dart';
import 'package:maktabat_al_arrab/core/services/library_service.dart';
import 'package:maktabat_al_arrab/core/services/text_paginator.dart';

/// Tests for the reading layer added with the OCR work: character-anchored
/// bookmarks, offset-aware pagination, hybrid page alignment and the Arabic
/// folding used by search.
///
/// Run with `flutter test test/reading_layer_test.dart`.
void main() {
  group('TextPagination', () {
    const pagination = TextPagination(
      pages: ['a', 'b', 'c'],
      starts: [0, 100, 250],
    );

    test('pageForOffset maps an offset to the page that contains it', () {
      expect(pagination.pageForOffset(0), 0);
      expect(pagination.pageForOffset(99), 0);
      expect(pagination.pageForOffset(100), 1);
      expect(pagination.pageForOffset(249), 1);
      expect(pagination.pageForOffset(250), 2);
    });

    test('pageForOffset clamps out-of-range offsets instead of throwing', () {
      expect(pagination.pageForOffset(999999), 2);
      expect(pagination.pageForOffset(-5), 0);
    });

    test('empty pagination still answers page 0', () {
      expect(TextPagination.empty.pageForOffset(42), 0);
    });
  });

  group('Bookmark anchor', () {
    test('charOffset survives a toMap/fromMap round trip', () {
      const bookmark = Bookmark(
        bookId: 'book_001',
        bookTitle: 'اختبار',
        pageNumber: 7,
        timestamp: 1234,
        charOffset: 4321,
      );

      final restored = Bookmark.fromMap(bookmark.toMap());
      expect(restored.charOffset, 4321);
      expect(restored.hasAnchor, isTrue);
      expect(restored.pageNumber, 7);
    });

    test('a bookmark saved before anchors existed loads without one', () {
      // Old rows have no `char_offset` key at all.
      final restored = Bookmark.fromMap({
        'book_id': 'book_002',
        'book_title': 'قديم',
        'page_number': 3,
        'timestamp': 99,
      });
      expect(restored.charOffset, -1);
      expect(restored.hasAnchor, isFalse);
    });
  });

  group('Hybrid pagination', () {
    BookDetail hybrid(List<String> texts) => BookDetail(
          id: 'book_test',
          title: 'اختبار',
          originalFilename: 'test.pdf',
          pageCount: texts.length,
          qualityScore: 0.9,
          contentMode: 'hybrid',
          chapters: const [],
          images: const [],
          ocrPages: [
            for (var i = 0; i < texts.length; i++)
              OcrPage(image: '${i.toString().padLeft(4, '0')}.webp', text: texts[i]),
          ],
          series: 'ma_wara_al_tabia',
        );

    test('one text page per image page, even when a page was rejected', () {
      final pages = ContentPaginator.paginateContent(
        bookDetail: hybrid(['الأولى', '', 'الثالثة']),
        screenWidth: 400,
        screenHeight: 800,
        settings: const ReaderSettings(),
      );

      // The rejected page keeps its slot (empty string) so the page index still
      // maps onto the original scan — that is what makes the image/text toggle
      // land on the same page.
      expect(pages.length, 3);
      expect(pages[0], 'الأولى');
      expect(pages[1], isEmpty);
      expect(pages[2], 'الثالثة');
    });
  });

  group('Arabic folding', () {
    test('alef forms and taa marbuta fold to one spelling', () {
      expect(Library.normalizeArabic('أحمد'), 'احمد');
      expect(Library.normalizeArabic('إبراهيم'), 'ابراهيم');
      expect(Library.normalizeArabic('آخر'), 'اخر');
      expect(Library.normalizeArabic('مكتبة'), 'مكتبه');
    });

    test('tashkeel and tatweel are dropped', () {
      expect(Library.normalizeArabic('كَتَبَ'), 'كتب');
      expect(Library.normalizeArabic('مـحـمـد'), 'محمد');
    });

    test('alef maqsura folds to yaa so both spellings match', () {
      expect(
        Library.normalizeArabic('مصطفى'),
        Library.normalizeArabic('مصطفي'),
      );
    });
  });
}
