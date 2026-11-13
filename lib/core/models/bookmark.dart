/// Represents a bookmark in a book
class Bookmark {
  final String bookId;
  final String bookTitle;
  final int pageNumber;       // 0-indexed page where bookmark is placed
  final String note;          // optional user note
  final int timestamp;        // milliseconds since epoch

  /// Character index in the book's full text where the bookmarked page starts.
  ///
  /// A page number is only meaningful for the layout it was created in: change
  /// the font size and the same sentence lands on a different page. The offset
  /// survives repagination, so the reader re-derives the page from it. `-1`
  /// means "no anchor" (scanned books, or a bookmark from an older version).
  final int charOffset;

  const Bookmark({
    required this.bookId,
    required this.bookTitle,
    required this.pageNumber,
    this.note = '',
    required this.timestamp,
    this.charOffset = -1,
  });

  bool get hasAnchor => charOffset >= 0;

  factory Bookmark.fromMap(Map<dynamic, dynamic> map) {
    return Bookmark(
      bookId: map['book_id'] as String? ?? '',
      bookTitle: map['book_title'] as String? ?? '',
      pageNumber: (map['page_number'] as num?)?.toInt() ?? 0,
      note: map['note'] as String? ?? '',
      timestamp: (map['timestamp'] as num?)?.toInt() ?? 0,
      charOffset: (map['char_offset'] as num?)?.toInt() ?? -1,
    );
  }

  Map<String, dynamic> toMap() => {
        'book_id': bookId,
        'book_title': bookTitle,
        'page_number': pageNumber,
        'note': note,
        'timestamp': timestamp,
        'char_offset': charOffset,
      };
}
