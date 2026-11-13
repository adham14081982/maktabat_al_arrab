import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/providers.dart';
import '../../core/constants/app_constants.dart';
import '../../widgets/common_widgets.dart';
import '../reader/reader_screen.dart';

class BookmarksScreen extends ConsumerWidget {
  const BookmarksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bookmarks = ref.watch(bookmarksProvider);
    final libraryAsync = ref.watch(libraryProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('العلامات المرجعية'),
      ),
      body: bookmarks.isEmpty
          ? const EmptyState(
              message: 'لا توجد علامات مرجعية بعد',
              icon: Icons.bookmark_border_outlined,
            )
          : libraryAsync.when(
              data: (library) {
                // A bookmark outlives the book it points at: the library is
                // rebuilt from source PDFs, and a book can be renamed or
                // dropped between builds. Those orphans used to render as a
                // title with a placeholder cover that opened a dead reader —
                // hide them instead of showing a broken row.
                final visible = bookmarks
                    .where((b) => library.getBook(b.bookId) != null)
                    .toList();

                if (visible.isEmpty) {
                  return const EmptyState(
                    message: 'لا توجد علامات مرجعية بعد',
                    icon: Icons.bookmark_border_outlined,
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: visible.length,
                  itemBuilder: (context, index) {
                    final bookmark = visible[index];
                    final book = library.getBook(bookmark.bookId);

                    return _BookmarkCard(
                      bookTitle: bookmark.bookTitle,
                      pageNumber: bookmark.pageNumber,
                      coverPath: book?.cover,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ReaderScreen(
                              bookId: bookmark.bookId,
                              bookTitle: bookmark.bookTitle,
                              coverPath: book?.cover,
                            ),
                          ),
                        );
                      },
                      onDelete: () {
                        ref.read(bookmarksProvider.notifier).remove(
                              bookmark.bookId,
                              bookmark.pageNumber,
                            );
                      },
                    );
                  },
                );
              },
              loading: () => const AntiqueLoader(),
              error: (_, __) => const EmptyState(
                message: 'تعذّر تحميل العلامات',
                icon: Icons.error_outline,
              ),
            ),
    );
  }
}

class _BookmarkCard extends StatelessWidget {
  final String bookTitle;
  final int pageNumber;
  final String? coverPath;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _BookmarkCard({
    required this.bookTitle,
    required this.pageNumber,
    this.coverPath,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const gold = Color(AppConstants.goldHex);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        contentPadding: const EdgeInsets.all(12),
        leading: BookCover(
          coverPath: coverPath,
          title: bookTitle,
          width: 50,
        ),
        title: Text(
          bookTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall,
        ),
        subtitle: Text(
          'صفحة ${pageNumber + 1}',
          style: theme.textTheme.labelSmall,
        ),
        trailing: IconButton(
          icon: Icon(Icons.delete_outline, color: gold.withValues(alpha: 0.7)),
          onPressed: onDelete,
        ),
        onTap: onTap,
      ),
    );
  }
}
