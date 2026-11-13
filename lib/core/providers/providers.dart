import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/storage_service.dart';
import '../services/library_service.dart';
import '../models/reader_settings.dart';
import '../models/reader_palette.dart';
import '../models/reading_progress.dart';
import '../models/bookmark.dart';
import '../models/book.dart';

// ─── Service Providers ──────────────────────────────────────────────────────

final storageServiceProvider = Provider<StorageService>((ref) {
  return StorageService.instance;
});

final libraryServiceProvider = Provider<LibraryService>((ref) {
  return LibraryService();
});

// ─── Library Data ───────────────────────────────────────────────────────────

final libraryProvider = FutureProvider<Library>((ref) async {
  final service = ref.watch(libraryServiceProvider);
  return service.loadLibrary();
});

/// Books in a specific section
final sectionBooksProvider =
    FutureProvider.family<List<Book>, String>((ref, sectionId) async {
  final library = await ref.watch(libraryProvider.future);
  return library.booksInSection(sectionId);
});

/// Search results
final searchQueryProvider = StateProvider<String>((ref) => '');

final searchResultsProvider =
    FutureProvider<List<Book>>((ref) async {
  final query = ref.watch(searchQueryProvider);
  final library = await ref.watch(libraryProvider.future);
  return library.searchBooks(query);
});

/// Full-text matches inside books that carry readable text (hybrid OCR
/// books and chapter-based text books). Only those book JSONs are opened,
/// so the cost stays proportional to the OCR'd subset of the library.
final textSearchResultsProvider =
    FutureProvider<List<TextSearchHit>>((ref) async {
  final query = ref.watch(searchQueryProvider);
  if (query.trim().isEmpty) return const [];
  final library = await ref.watch(libraryProvider.future);
  final service = ref.watch(libraryServiceProvider);
  final candidates = library.books
      .where((b) => b.contentMode == 'hybrid' || b.contentMode == 'text')
      .toList();
  return service.searchInBookTexts(candidates, query);
});

/// Book detail loader
final bookDetailProvider =
    FutureProvider.family<BookDetail?, ({String bookId, String jsonFile})>(
        (ref, params) async {
  final service = ref.watch(libraryServiceProvider);
  return service.loadBookDetail(params.bookId, params.jsonFile);
});

// ─── Settings ───────────────────────────────────────────────────────────────

final readerSettingsProvider =
    StateNotifierProvider<ReaderSettingsNotifier, ReaderSettings>((ref) {
  final storage = ref.watch(storageServiceProvider);
  return ReaderSettingsNotifier(storage);
});

class ReaderSettingsNotifier extends StateNotifier<ReaderSettings> {
  final StorageService _storage;

  ReaderSettingsNotifier(this._storage)
      : super(_storage.getSettings());

  Future<void> updateFontSize(double size) async {
    state = state.copyWith(fontSize: size);
    await _storage.saveSettings(state);
  }

  Future<void> updateFontFamily(String family) async {
    state = state.copyWith(fontFamily: family);
    await _storage.saveSettings(state);
  }

  Future<void> updateLineSpacing(double spacing) async {
    state = state.copyWith(lineSpacing: spacing);
    await _storage.saveSettings(state);
  }

  Future<void> toggleNightMode() async {
    state = state.copyWith(nightMode: !state.nightMode);
    await _storage.saveSettings(state);
  }

  Future<void> togglePageFlipEffect() async {
    state = state.copyWith(pageFlipEffect: !state.pageFlipEffect);
    await _storage.saveSettings(state);
  }

  Future<void> toggleHapticFeedback() async {
    state = state.copyWith(hapticFeedback: !state.hapticFeedback);
    await _storage.saveSettings(state);
  }

  Future<void> togglePageFlipSound() async {
    state = state.copyWith(pageFlipSound: !state.pageFlipSound);
    await _storage.saveSettings(state);
  }

  /// Page-turn direction (horizontal flip / vertical scroll). Used by both
  /// the quick settings sheet and the main settings screen.
  Future<void> updateReadingAxis(ReadingAxis axis) async {
    state = state.copyWith(readingAxis: axis);
    await _storage.saveSettings(state);
  }

  /// Double-page scan splitting policy (image-mode books).
  Future<void> updateSplitMode(DoublePageSplitMode mode) async {
    state = state.copyWith(splitMode: mode);
    await _storage.saveSettings(state);
  }

  /// Night-colour filter for scanned pages (invert + darken).
  Future<void> toggleScanNightFilter() async {
    state = state.copyWith(scanNightFilter: !state.scanNightFilter);
    await _storage.saveSettings(state);
  }

  /// Colour scheme of the reading area (paper / sepia / white / dark).
  Future<void> updatePalette(ReaderPalette palette) async {
    state = state.copyWith(palette: palette);
    await _storage.saveSettings(state);
  }

  /// In-reader dimming; persists so night reading stays dim next time.
  Future<void> updateBrightness(double value) async {
    state = state.copyWith(brightness: value.clamp(0.35, 1.0));
    await _storage.saveSettings(state);
  }
}

/// Theme mode derived from night mode setting
final themeModeProvider = Provider<ThemeMode>((ref) {
  final settings = ref.watch(readerSettingsProvider);
  return settings.nightMode ? ThemeMode.dark : ThemeMode.light;
});

// ─── Reading Progress ───────────────────────────────────────────────────────

final readingProgressProvider =
    StateNotifierProvider<ReadingProgressNotifier, Map<String, ReadingProgress>>(
        (ref) {
  final storage = ref.watch(storageServiceProvider);
  return ReadingProgressNotifier(storage);
});

class ReadingProgressNotifier
    extends StateNotifier<Map<String, ReadingProgress>> {
  final StorageService _storage;

  ReadingProgressNotifier(this._storage) : super({}) {
    _loadAll();
  }

  void _loadAll() {
    final all = _storage.getAllProgress();
    final map = <String, ReadingProgress>{};
    for (final p in all) {
      map[p.bookId] = p;
    }
    state = map;
  }

  ReadingProgress? getProgress(String bookId) {
    return state[bookId];
  }

  List<ReadingProgress> getRecent({int limit = 5}) {
    final list = state.values.toList();
    list.sort((a, b) => b.lastReadTimestamp.compareTo(a.lastReadTimestamp));
    return list.take(limit).toList();
  }

  Future<void> saveProgress(String bookId, int currentPage, int totalPages) async {
    final progress = ReadingProgress(
      bookId: bookId,
      currentPage: currentPage,
      totalPages: totalPages,
      lastReadTimestamp: DateTime.now().millisecondsSinceEpoch,
      progress: totalPages > 0 ? currentPage / totalPages : 0.0,
    );
    await _storage.saveProgress(progress);
    state = {...state, bookId: progress};
  }

  void refresh() {
    _loadAll();
  }
}

/// Get progress for a single book
final bookProgressProvider =
    Provider.family<ReadingProgress?, String>((ref, bookId) {
  final progressMap = ref.watch(readingProgressProvider);
  return progressMap[bookId];
});

/// Continue reading list
final continueReadingProvider = Provider<List<ReadingProgress>>((ref) {
  final progressMap = ref.watch(readingProgressProvider);
  final list = progressMap.values.toList();
  list.sort((a, b) => b.lastReadTimestamp.compareTo(a.lastReadTimestamp));
  return list.take(10).toList();
});

// ─── Bookmarks ──────────────────────────────────────────────────────────────

final bookmarksProvider =
    StateNotifierProvider<BookmarksNotifier, List<Bookmark>>((ref) {
  final storage = ref.watch(storageServiceProvider);
  return BookmarksNotifier(storage);
});

class BookmarksNotifier extends StateNotifier<List<Bookmark>> {
  final StorageService _storage;

  BookmarksNotifier(this._storage) : super([]) {
    _loadAll();
  }

  void _loadAll() {
    state = _storage.getAllBookmarks();
  }

  List<Bookmark> forBook(String bookId) {
    return state.where((b) => b.bookId == bookId).toList()
      ..sort((a, b) => a.pageNumber.compareTo(b.pageNumber));
  }

  bool isBookmarked(String bookId, int pageNumber) {
    return state.any((b) => b.bookId == bookId && b.pageNumber == pageNumber);
  }

  /// Anchor for the bookmarked page, so the mark survives a font change.
  /// `-1` for scanned books, whose pages never reflow.
  Bookmark? anchorFor(String bookId) {
    for (final b in state) {
      if (b.bookId == bookId && b.hasAnchor) return b;
    }
    return null;
  }

  Future<void> toggle(
    String bookId,
    String bookTitle,
    int pageNumber, {
    int charOffset = -1,
  }) async {
    final bookmark = Bookmark(
      bookId: bookId,
      bookTitle: bookTitle,
      pageNumber: pageNumber,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      charOffset: charOffset,
    );

    // Flip the in-memory state first so every listener (the reader's icon, the
    // bookmarks screen) reacts on the same frame as the tap. Persisting is the
    // slow part and callers are not required to await it.
    final alreadyThere =
        state.any((b) => b.bookId == bookId && b.pageNumber == pageNumber);
    state = alreadyThere
        ? state
            .where((b) => !(b.bookId == bookId && b.pageNumber == pageNumber))
            .toList()
        : [...state, bookmark];

    await _storage.toggleBookmark(bookmark);
    _loadAll();
  }

  Future<void> remove(String bookId, int pageNumber) async {
    await _storage.removeBookmark(bookId, pageNumber);
    _loadAll();
  }

  void refresh() {
    _loadAll();
  }
}
