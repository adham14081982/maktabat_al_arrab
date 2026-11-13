/// Represents a reading progress entry for a book
class ReadingProgress {
  final String bookId;
  final int currentPage;     // 0-indexed
  final int totalPages;
  final int lastReadTimestamp; // milliseconds since epoch
  final double progress;     // 0.0 to 1.0

  const ReadingProgress({
    required this.bookId,
    required this.currentPage,
    required this.totalPages,
    required this.lastReadTimestamp,
    required this.progress,
  });

  factory ReadingProgress.fromMap(Map<dynamic, dynamic> map) {
    final currentPage = (map['current_page'] as num?)?.toInt() ?? 0;
    final totalPages = (map['total_pages'] as num?)?.toInt() ?? 1;
    return ReadingProgress(
      bookId: map['book_id'] as String? ?? '',
      currentPage: currentPage,
      totalPages: totalPages,
      lastReadTimestamp: (map['timestamp'] as num?)?.toInt() ?? 0,
      progress: totalPages > 0 ? currentPage / totalPages : 0.0,
    );
  }

  Map<String, dynamic> toMap() => {
        'book_id': bookId,
        'current_page': currentPage,
        'total_pages': totalPages,
        'timestamp': lastReadTimestamp,
      };

  ReadingProgress copyWith({
    String? bookId,
    int? currentPage,
    int? totalPages,
    int? lastReadTimestamp,
    double? progress,
  }) {
    return ReadingProgress(
      bookId: bookId ?? this.bookId,
      currentPage: currentPage ?? this.currentPage,
      totalPages: totalPages ?? this.totalPages,
      lastReadTimestamp: lastReadTimestamp ?? this.lastReadTimestamp,
      progress: progress ?? this.progress,
    );
  }
}
