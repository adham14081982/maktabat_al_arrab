import 'package:hive/hive.dart';
import '../models/reading_progress.dart';
import '../models/bookmark.dart';
import '../models/reader_settings.dart';
import '../constants/app_constants.dart';

/// Hive-based local storage service for reading progress, bookmarks, and settings.
/// Singleton — call [init] once after opening Hive boxes in main().
class StorageService {
  StorageService._();
  static final StorageService instance = StorageService._();

  late Box _settingsBox;
  late Box _progressBox;
  late Box _bookmarksBox;
  bool _initialized = false;

  /// Initialize with already-opened Hive boxes
  void init() {
    _settingsBox = Hive.box(AppConstants.settingsBox);
    _progressBox = Hive.box(AppConstants.progressBox);
    _bookmarksBox = Hive.box(AppConstants.bookmarksBox);
    _initialized = true;
  }

  void _ensureInit() {
    if (!_initialized) {
      init();
    }
  }

  // ─── Settings ────────────────────────────────────────────────────────────

  ReaderSettings getSettings() {
    _ensureInit();
    return ReaderSettings.fromMap(_settingsBox.toMap());
  }

  Future<void> saveSettings(ReaderSettings settings) async {
    _ensureInit();
    final map = settings.toMap();
    for (final entry in map.entries) {
      await _settingsBox.put(entry.key, entry.value);
    }
  }

  // ─── Reading Progress ────────────────────────────────────────────────────

  ReadingProgress? getProgress(String bookId) {
    _ensureInit();
    final data = _progressBox.get(bookId);
    if (data == null) return null;
    return ReadingProgress.fromMap(data as Map);
  }

  Future<void> saveProgress(ReadingProgress progress) async {
    _ensureInit();
    await _progressBox.put(progress.bookId, progress.toMap());
  }

  /// Get all reading progress entries (for "Continue Reading" section)
  List<ReadingProgress> getAllProgress() {
    _ensureInit();
    final result = <ReadingProgress>[];
    for (final key in _progressBox.keys) {
      final data = _progressBox.get(key);
      if (data != null) {
        result.add(ReadingProgress.fromMap(data as Map));
      }
    }
    result.sort((a, b) => b.lastReadTimestamp.compareTo(a.lastReadTimestamp));
    return result;
  }

  Future<void> clearProgress(String bookId) async {
    _ensureInit();
    await _progressBox.delete(bookId);
  }

  // ─── Bookmarks ───────────────────────────────────────────────────────────

  /// Get all bookmarks for a specific book
  List<Bookmark> getBookmarksForBook(String bookId) {
    _ensureInit();
    final result = <Bookmark>[];
    for (final key in _bookmarksBox.keys) {
      final data = _bookmarksBox.get(key);
      if (data != null) {
        final bookmark = Bookmark.fromMap(data as Map);
        if (bookmark.bookId == bookId) {
          result.add(bookmark);
        }
      }
    }
    result.sort((a, b) => a.pageNumber.compareTo(b.pageNumber));
    return result;
  }

  /// Get all bookmarks across all books
  List<Bookmark> getAllBookmarks() {
    _ensureInit();
    final result = <Bookmark>[];
    for (final key in _bookmarksBox.keys) {
      final data = _bookmarksBox.get(key);
      if (data != null) {
        result.add(Bookmark.fromMap(data as Map));
      }
    }
    result.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return result;
  }

  /// Toggle a bookmark on a page
  Future<void> toggleBookmark(Bookmark bookmark) async {
    _ensureInit();
    final key = '${bookmark.bookId}_${bookmark.pageNumber}';
    final existing = _bookmarksBox.get(key);
    if (existing != null) {
      await _bookmarksBox.delete(key);
    } else {
      await _bookmarksBox.put(key, bookmark.toMap());
    }
  }

  /// Check if a page is bookmarked
  bool isBookmarked(String bookId, int pageNumber) {
    _ensureInit();
    final key = '${bookId}_$pageNumber';
    return _bookmarksBox.containsKey(key);
  }

  Future<void> removeBookmark(String bookId, int pageNumber) async {
    _ensureInit();
    final key = '${bookId}_$pageNumber';
    await _bookmarksBox.delete(key);
  }
}
