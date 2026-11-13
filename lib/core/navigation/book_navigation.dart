import 'package:flutter/material.dart';

import '../../features/book_detail/book_detail_screen.dart';
import '../../features/reader/reader_screen.dart';
import '../../widgets/page_transitions.dart';
import '../models/book.dart';

/// Navigation entry points shared by the shelf, the section grid and search.
///
/// Tapping a book goes straight into the reader: the library ships no synopsis
/// for most volumes, so an intermediate details screen would only add a tap.
/// Long-pressing opens the details screen for stats and "start from beginning".
class BookNavigation {
  const BookNavigation._();

  /// Jump straight into the reader (resumes at the saved page).
  static Future<void> openReader(
    BuildContext context,
    Book book, {
    bool fromStart = false,
    int? initialPage,
  }) {
    return Navigator.push(
      context,
      FadeThroughRoute(
        builder: (_) => ReaderScreen(
          bookId: book.id,
          bookTitle: book.title,
          coverPath: book.cover,
          startAtBeginning: fromStart,
          initialPage: initialPage,
        ),
      ),
    );
  }

  /// Open the details screen (cover, stats, progress, restart).
  static Future<void> openDetails(BuildContext context, Book book) {
    return Navigator.push(
      context,
      FadeThroughRoute(builder: (_) => BookDetailScreen(bookId: book.id)),
    );
  }
}
