import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/navigation/book_navigation.dart';
import '../../core/providers/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/book.dart';
import '../../core/models/reading_progress.dart';
import '../../widgets/common_widgets.dart';
import '../../widgets/page_transitions.dart';
import '../section/section_screen.dart';
import '../bookmarks/bookmarks_screen.dart';
import '../settings/settings_screen.dart';
import '../search/search_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _currentIndex = 0;

  final _pages = const [
    HomeContent(),
    SearchScreen(),
    BookmarksScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home),
            label: 'الرئيسية',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.search_outlined),
            activeIcon: Icon(Icons.search),
            label: 'بحث',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.bookmark_border_outlined),
            activeIcon: Icon(Icons.bookmark),
            label: 'العلامات',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined),
            activeIcon: Icon(Icons.settings),
            label: 'الإعدادات',
          ),
        ],
      ),
    );
  }
}

/// Main home content with wooden shelves
class HomeContent extends ConsumerWidget {
  const HomeContent({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final libraryAsync = ref.watch(libraryProvider);
    final continueReading = ref.watch(continueReadingProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text(AppConstants.appName),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SearchScreen()),
              );
            },
          ),
        ],
      ),
      body: libraryAsync.when(
        data: (library) => CustomScrollView(
          slivers: [
            // Continue Reading section
            if (continueReading.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: _ContinueReadingSection(progress: continueReading),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 16)),
            ],

            // Section shelves
            for (final section in library.sections)
              SliverToBoxAdapter(
                child: _SectionShelf(
                  sectionId: section.id,
                  title: section.title,
                  subtitle: section.subtitle,
                  accentColor: AppTheme.seriesAccent(section.id),
                  books: library.booksInSection(section.id),
                ),
              ),

            // Bottom padding
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
        loading: () => const AntiqueLoader(),
        error: (error, stack) => EmptyState(
          message: 'تعذّر تحميل المكتبة: $error',
          icon: Icons.error_outline,
        ),
      ),
    );
  }
}

/// Continue Reading horizontal carousel
class _ContinueReadingSection extends ConsumerWidget {
  final List<ReadingProgress> progress;

  const _ContinueReadingSection({required this.progress});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(libraryProvider).maybeWhen(
          data: (lib) => lib,
          orElse: () => null,
        );

    if (library == null) return const SizedBox.shrink();

    // Drop entries whose book is no longer in the library (e.g. progress saved
    // by an older build) so the section collapses instead of leaving a gap.
    final valid = progress
        .where((p) => library.getBook(p.bookId) != null)
        .toList();
    if (valid.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(
          title: 'تابع القراءة',
          subtitle: 'أكمل من حيث توقفت',
        ),
        SizedBox(
          height: 180,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: valid.length,
            itemBuilder: (context, index) {
              final p = valid[index];
              final book = library.getBook(p.bookId)!;

              return _ContinueReadingCard(
                book: book,
                progress: p,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ContinueReadingCard extends StatelessWidget {
  final Book book;
  final ReadingProgress progress;

  const _ContinueReadingCard({
    required this.book,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // "Continue reading" resumes in one tap, without a detour.
      onTap: () => BookNavigation.openReader(context, book),
      onLongPress: () => BookNavigation.openDetails(context, book),
      child: Container(
        width: 100,
        margin: const EdgeInsets.only(left: 12),
        child: Column(
          children: [
            BookCover(
              coverPath: book.cover,
              title: book.title,
              width: 80,
              heroTag: 'cover_${book.id}',
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: progress.progress.clamp(0.0, 1.0),
              minHeight: 3,
              backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
            const SizedBox(height: 4),
            Text(
              '${(progress.progress * 100).round()}%',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// Horizontal shelf of book covers for a section
class _SectionShelf extends StatelessWidget {
  final String sectionId;
  final String title;
  final String subtitle;
  final Color accentColor;
  final List<Book> books;

  const _SectionShelf({
    required this.sectionId,
    required this.title,
    required this.subtitle,
    required this.accentColor,
    required this.books,
  });

  @override
  Widget build(BuildContext context) {
    if (books.isEmpty) return const SizedBox.shrink();

    // Show first 10 books on the shelf, rest in section page
    final shelfBooks = books.length > 10 ? books.sublist(0, 10) : books;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: title,
          subtitle: subtitle,
          accentColor: accentColor,
          // "الكل (N)" lives on the title line — no extra row below the shelf.
          trailing: TextButton(
            onPressed: () {
              Navigator.push(
                context,
                FadeThroughRoute(
                  builder: (_) => SectionScreen(
                    sectionId: sectionId,
                    title: title,
                  ),
                ),
              );
            },
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 36),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'الكل (${books.length})',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: AppTheme.readableAccent(context, accentColor),
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.arrow_back,
                  size: 15,
                  color: AppTheme.readableAccent(context, accentColor),
                ),
              ],
            ),
          ),
        ),
        SizedBox(
          height: 216,
          child: Stack(
            children: [
              // Wooden shelf background
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                height: 12,
                child: _WoodenShelf(color: accentColor),
              ),
              // Book covers — tap goes to book detail, not section
              ListView.builder(
                scrollDirection: Axis.horizontal,
                // Bottom padding keeps the title labels above the shelf plank.
                padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
                itemCount: shelfBooks.length,
                itemBuilder: (context, index) {
                  final book = shelfBooks[index];
                  return GestureDetector(
                    // Tap = start reading immediately; long-press = details.
                    onTap: () => BookNavigation.openReader(context, book),
                    onLongPress: () => BookNavigation.openDetails(context, book),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 10),
                      child: BookCover(
                        coverPath: book.cover,
                        title: book.title,
                        width: 110,
                        showLabel: true,
                        heroTag: 'cover_${book.id}',
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

/// Wooden shelf bar
class _WoodenShelf extends StatelessWidget {
  final Color color;

  const _WoodenShelf({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF4A2C1A),
            Color(0xFF3A1F12),
            Color(0xFF2A1508),
          ],
        ),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(2),
          topRight: Radius.circular(2),
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.3),
            blurRadius: 4,
            offset: const Offset(0, -2),
          ),
        ],
      ),
    );
  }
}
