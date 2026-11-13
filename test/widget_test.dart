import 'package:flutter_test/flutter_test.dart';

import 'package:maktabat_al_arrab/core/models/book.dart';
import 'package:maktabat_al_arrab/core/models/section.dart';
import 'package:maktabat_al_arrab/core/models/bookmark.dart';
import 'package:maktabat_al_arrab/core/models/reading_progress.dart';
import 'package:maktabat_al_arrab/core/models/reader_settings.dart';

void main() {
  group('Book Model', () {
    test('fromJson creates Book correctly', () {
      final json = {
        'id': 'book_001',
        'title': 'كتاب تجريبي',
        'series': 'ma_wara_al_tabia',
        'page_count': 200,
        'cover': 'covers/book_001.webp',
        'content_mode': 'text',
        'quality_score': 0.85,
        'json_file': 'book_jsons/book_001.json',
      };

      final book = Book.fromJson(json);

      expect(book.id, 'book_001');
      expect(book.title, 'كتاب تجريبي');
      expect(book.series, 'ma_wara_al_tabia');
      expect(book.pageCount, 200);
      expect(book.cover, 'covers/book_001.webp');
      expect(book.contentMode, 'text');
      expect(book.qualityScore, 0.85);
      expect(book.jsonFile, 'book_jsons/book_001.json');
    });

    test('toJson produces correct map', () {
      const book = Book(
        id: 'book_002',
        title: ' test',
        series: 'fantazia',
        pageCount: 150,
        cover: 'covers/book_002.webp',
        contentMode: 'image',
        qualityScore: 0.30,
        jsonFile: 'book_jsons/book_002.json',
      );

      final json = book.toJson();

      expect(json['id'], 'book_002');
      expect(json['series'], 'fantazia');
      expect(json['page_count'], 150);
      expect(json['content_mode'], 'image');
    });

    test('BookDetail fromJson with chapters', () {
      final json = {
        'id': 'book_003',
        'title': 'كتاب بفصول',
        'original_filename': 'test.pdf',
        'page_count': 50,
        'quality_score': 0.90,
        'content_mode': 'text',
        'series': 'safari',
        'chapters': [
          {'title': 'الفصل الأول', 'text': 'محتوى الفصل الأول'},
          {'title': 'الفصل الثاني', 'text': 'محتوى الفصل الثاني'},
        ],
        'images': [],
      };

      final detail = BookDetail.fromJson(json);

      expect(detail.id, 'book_003');
      expect(detail.chapters.length, 2);
      expect(detail.chapters[0].title, 'الفصل الأول');
      expect(detail.chapters[1].text, 'محتوى الفصل الثاني');
    });
  });

  group('Section Model', () {
    test('fromJson creates Section correctly', () {
      final json = {
        'id': 'ma_wara_al_tabia',
        'title': 'ما وراء الطبيعة',
        'subtitle': 'سلسلة الرعب',
        'color_accent': '#8B1E2D',
        'icon': 'moon',
      };

      final section = Section.fromJson(json);

      expect(section.id, 'ma_wara_al_tabia');
      expect(section.title, 'ما وراء الطبيعة');
      expect(section.subtitle, 'سلسلة الرعب');
      expect(section.colorAccent, '#8B1E2D');
      expect(section.icon, 'moon');
    });
  });

  group('Bookmark Model', () {
    test('fromMap and toMap roundtrip', () {
      const bookmark = Bookmark(
        bookId: 'book_001',
        bookTitle: 'كتاب تجريبي',
        pageNumber: 5,
        timestamp: 1700000000000,
      );

      final map = bookmark.toMap();
      final restored = Bookmark.fromMap(map);

      expect(restored.bookId, 'book_001');
      expect(restored.bookTitle, 'كتاب تجريبي');
      expect(restored.pageNumber, 5);
      expect(restored.timestamp, 1700000000000);
    });
  });

  group('ReadingProgress Model', () {
    test('fromMap and toMap roundtrip', () {
      const progress = ReadingProgress(
        bookId: 'book_001',
        currentPage: 42,
        totalPages: 200,
        lastReadTimestamp: 1700000000000,
        progress: 42 / 200,
      );

      final map = progress.toMap();
      final restored = ReadingProgress.fromMap(map);

      expect(restored.bookId, 'book_001');
      expect(restored.currentPage, 42);
      expect(restored.totalPages, 200);
    });
  });

  group('ReaderSettings Model', () {
    test('defaults are correct', () {
      // Defaults are compile-time constants; assert them (also guards against
      // accidentally making the constructor non-const).
      const settings = ReaderSettings();

      expect(settings.fontSize, 18.0);
      expect(settings.fontFamily, 'Amiri');
      expect(settings.lineSpacing, 1.8);
      expect(settings.nightMode, false);
      expect(settings.pageFlipEffect, true);
      expect(settings.hapticFeedback, true);
      expect(settings.pageFlipSound, false);
    });

    test('copyWith updates only specified fields', () {
      const original = ReaderSettings();
      final updated = original.copyWith(fontSize: 24.0, nightMode: true);

      expect(updated.fontSize, 24.0);
      expect(updated.nightMode, true);
      expect(updated.fontFamily, 'Amiri');
      expect(updated.lineSpacing, 1.8);
    });

    test('fromMap and toMap roundtrip', () {
      const settings = ReaderSettings(
        fontSize: 22.0,
        fontFamily: 'Cairo',
        lineSpacing: 2.0,
        nightMode: true,
      );

      final map = settings.toMap();
      final restored = ReaderSettings.fromMap(map);

      expect(restored.fontSize, 22.0);
      expect(restored.fontFamily, 'Cairo');
      expect(restored.lineSpacing, 2.0);
      expect(restored.nightMode, true);
    });
  });
}
