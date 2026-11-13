import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/models/book.dart';
import '../../core/navigation/book_navigation.dart';
import '../../core/providers/providers.dart';
import '../../widgets/common_widgets.dart';

class SectionScreen extends ConsumerWidget {
  final String sectionId;
  final String title;

  const SectionScreen({
    super.key,
    required this.sectionId,
    required this.title,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final booksAsync = ref.watch(sectionBooksProvider(sectionId));

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          // Book count is handy when a series runs to 80+ volumes.
          booksAsync.maybeWhen(
            data: (books) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: Text(
                  '${books.length} كتابًا',
                  // Gold on the dark leather app bar — the default label colour
                  // is dark brown and would be invisible here.
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: const Color(AppConstants.goldHex),
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            ),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: booksAsync.when(
        data: (books) {
          if (books.isEmpty) {
            return const EmptyState(
              message: 'لا توجد كتب في هذا القسم',
              icon: Icons.menu_book_outlined,
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              // 2:3 cover plus a two-line title underneath, with headroom.
              childAspectRatio: 0.52,
              crossAxisSpacing: 12,
              mainAxisSpacing: 16,
            ),
            itemCount: books.length,
            itemBuilder: (context, index) => _BookGridItem(book: books[index]),
          );
        },
        loading: () => const AntiqueLoader(),
        error: (error, stack) => const EmptyState(
          message: 'تعذّر تحميل الكتب',
          icon: Icons.error_outline,
        ),
      ),
    );
  }
}

class _BookGridItem extends StatelessWidget {
  final Book book;

  const _BookGridItem({required this.book});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Tap opens the reader; long-press opens the details screen.
      onTap: () => BookNavigation.openReader(context, book),
      onLongPress: () => BookNavigation.openDetails(context, book),
      child: BookCover(
        coverPath: book.cover,
        title: book.title,
        showLabel: true,
        heroTag: 'cover_${book.id}',
      ),
    );
  }
}
