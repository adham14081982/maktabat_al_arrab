import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart'
    show BackgroundIsolateBinaryMessenger, RootIsolateToken, rootBundle;

import '../models/book.dart';
import '../models/section.dart';
import 'library_source.dart';

/// Library data loaded from library.json
class Library {
  final String version;
  final String appName;
  final String author;
  final List<Section> sections;
  final List<Book> books;

  const Library({
    required this.version,
    required this.appName,
    required this.author,
    required this.sections,
    required this.books,
  });

  factory Library.fromJson(Map<String, dynamic> json) {
    return Library(
      version: json['version'] as String? ?? '1.0.0',
      appName: json['app_name'] as String? ?? '',
      author: json['author'] as String? ?? '',
      sections: (json['sections'] as List?)
              ?.map((s) => Section.fromJson(s as Map<String, dynamic>))
              .toList() ??
          [],
      books: (json['books'] as List?)
              ?.map((b) => Book.fromJson(b as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  /// Get books for a specific section
  List<Book> booksInSection(String sectionId) {
    return books.where((b) => b.series == sectionId).toList();
  }

  /// Search books by title.
  ///
  /// Matching is Arabic-aware: alef variants, taa marbuta, yaa and diacritics
  /// are folded first, so "اسطورة" finds "أسطورة" and "مكتبه" finds "مكتبة".
  List<Book> searchBooks(String query) {
    final q = normalizeArabic(query).trim();
    if (q.isEmpty) return books;
    return books
        .where((b) => normalizeArabic(b.title).contains(q))
        .toList();
  }

  /// Fold Arabic orthographic variants into a single canonical form.
  static String normalizeArabic(String input) {
    final buf = StringBuffer();
    for (final rune in input.runes) {
      // Drop diacritics (tashkeel), tatweel and Quranic marks.
      if ((rune >= 0x064B && rune <= 0x0652) ||
          rune == 0x0670 ||
          rune == 0x0640 ||
          (rune >= 0x06D6 && rune <= 0x06ED)) {
        continue;
      }
      switch (rune) {
        case 0x0622: // آ
        case 0x0623: // أ
        case 0x0625: // إ
        case 0x0671: // ٱ
          buf.writeCharCode(0x0627); // ا
          break;
        case 0x0629: // ة
          buf.writeCharCode(0x0647); // ه
          break;
        case 0x0649: // ى
        case 0x0626: // ئ
          buf.writeCharCode(0x064A); // ي
          break;
        case 0x0624: // ؤ
          buf.writeCharCode(0x0648); // و
          break;
        default:
          buf.writeCharCode(rune);
      }
    }
    return buf.toString().toLowerCase();
  }

  /// Get a book by ID
  Book? getBook(String bookId) {
    try {
      return books.firstWhere((b) => b.id == bookId);
    } catch (_) {
      return null;
    }
  }
}

/// Service to load library data from assets
class LibraryService {
  Library? _library;
  final Map<String, BookDetail> _bookDetailCache = {};

  /// The whole library is ~25 M characters of OCR text once every book is
  /// hybrid. Keeping every parsed `BookDetail` alive would hold tens of MB
  /// for the life of the app, so the cache is a small LRU: a search still
  /// parses each book once, but memory stays flat afterwards.
  static const int _cacheLimit = 24;

  BookDetail? _cacheGet(String bookId) {
    final hit = _bookDetailCache.remove(bookId);
    if (hit != null) _bookDetailCache[bookId] = hit; // re-insert = most recent
    return hit;
  }

  void _cachePut(String bookId, BookDetail detail) {
    _bookDetailCache[bookId] = detail;
    while (_bookDetailCache.length > _cacheLimit) {
      _bookDetailCache.remove(_bookDetailCache.keys.first);
    }
  }

  /// Load library.json from the active library root (bundled assets or the
  /// folder the user imported).
  Future<Library> loadLibrary() async {
    if (_library != null) return _library!;

    try {
      final jsonString = await LibrarySource.readText('library.json');
      final jsonMap = json.decode(jsonString) as Map<String, dynamic>;
      _library = Library.fromJson(jsonMap);
      return _library!;
    } catch (e) {
      // Return empty library on error
      _library = const Library(
        version: '1.0.0',
        appName: 'مكتبة العرّاب',
        author: 'د. أحمد خالد توفيق',
        sections: [],
        books: [],
      );
      return _library!;
    }
  }

  /// Load detailed book data from individual JSON file
  Future<BookDetail?> loadBookDetail(String bookId, String jsonFile) async {
    final cached = _cacheGet(bookId);
    if (cached != null) return cached;

    try {
      final jsonString = await LibrarySource.readText(jsonFile);
      final jsonMap = json.decode(jsonString) as Map<String, dynamic>;
      final detail = BookDetail.fromJson(jsonMap);
      _cachePut(bookId, detail);
      return detail;
    } catch (e) {
      return null;
    }
  }

  /// Full-text search inside books that carry readable text (hybrid OCR
  /// books and chapters-based text books).
  ///
  /// The scan reads ~25 M characters of JSON once the whole library is hybrid.
  /// Doing that on the UI isolate froze the search field for seconds — the
  /// first keystroke after opening search was the worst. The whole scan now
  /// runs in a background isolate and only the hits travel back.
  Future<List<TextSearchHit>> searchInBookTexts(
    Iterable<Book> candidates,
    String query,
  ) async {
    final q = Library.normalizeArabic(query).trim();
    if (q.isEmpty) return const [];

    final books = [
      for (final b in candidates)
        <String, String>{'id': b.id, 'title': b.title, 'json': b.jsonFile},
    ];
    if (books.isEmpty) return const [];

    // A background isolate has no asset bundle of its own unless it is handed
    // a token from the root isolate; `Isolate.run` cannot see `rootBundle`
    // otherwise. Null when the library lives on disk, where plain dart:io
    // works without any of this.
    final token = RootIsolateToken.instance;
    final rootPath = LibrarySource.externalPath;

    final raw = await Isolate.run(
      () => _scanBookTexts(rootPath, token, books, q, 40),
    );

    final byId = {for (final b in candidates) b.id: b};
    return _rank([
      for (final hit in raw)
        if (byId[hit['id']] != null)
          TextSearchHit(
            book: byId[hit['id']]!,
            pageNumber: hit['page'] as int,
            excerpt: hit['excerpt'] as String,
          ),
    ], q);
  }

  /// Title hits first, then per-book page order.
  static List<TextSearchHit> _rank(List<TextSearchHit> hits, String q) {
    hits.sort((a, b) {
      final aTitle = a.book.title.contains(q) ? 0 : 1;
      final bTitle = b.book.title.contains(q) ? 0 : 1;
      if (aTitle != bTitle) return aTitle - bTitle;
      return a.pageNumber.compareTo(b.pageNumber);
    });
    return hits;
  }

  /// Clear cache (useful when settings change)
  void clearCache() {
    _bookDetailCache.clear();
  }
}

/// One full-text result: the book, the matching page and a short excerpt.
class TextSearchHit {
  final Book book;
  final int pageNumber;
  final String excerpt;

  const TextSearchHit({
    required this.book,
    required this.pageNumber,
    required this.excerpt,
  });
}

/// The background half of [LibraryService.searchInBookTexts].
///
/// Top-level and isolate-safe: it touches nothing but its arguments, the file
/// system and (when the library is bundled) the asset bundle. Book JSONs are
/// decoded with plain `json.decode` rather than through [BookDetail] — the
/// scan only needs the text, and skipping the model halves the work.
Future<List<Map<String, Object>>> _scanBookTexts(
  String? rootPath,
  RootIsolateToken? token,
  List<Map<String, String>> books,
  String query,
  int limit,
) async {
  if (token != null) {
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  }

  final hits = <Map<String, Object>>[];
  for (final b in books) {
    final jsonPath = b['json']!;
    String raw;
    try {
      raw = rootPath == null
          ? await rootBundle.loadString('assets/$jsonPath')
          : await File('$rootPath/$jsonPath').readAsString();
    } catch (_) {
      continue;
    }

    final pages = (json.decode(raw) as Map<String, dynamic>)['ocr_pages'];
    if (pages is! List) continue;

    for (var i = 0; i < pages.length; i++) {
      final entry = pages[i];
      final text = entry is Map ? (entry['text'] as String? ?? '') : '';
      if (text.trim().isEmpty) continue;

      final normalized = Library.normalizeArabic(text);
      final idx = normalized.indexOf(query);
      if (idx < 0) continue;

      final start = (idx - 60).clamp(0, text.length);
      final end = (idx + query.length + 90).clamp(0, text.length);
      hits.add({
        'id': b['id']!,
        'page': i + 1,
        'excerpt':
            text.substring(start, end).replaceAll(RegExp(r'\s+'), ' ').trim(),
      });
      if (hits.length >= limit) return hits;
    }
  }
  return hits;
}
