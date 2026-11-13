import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/reading_progress.dart';
import '../../core/providers/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/constants/app_constants.dart';
import '../../widgets/common_widgets.dart';
import '../../widgets/page_transitions.dart';
import '../reader/reader_screen.dart';

class BookDetailScreen extends ConsumerWidget {
  final String bookId;

  const BookDetailScreen({
    super.key,
    required this.bookId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final libraryAsync = ref.watch(libraryProvider);
    final progress = ref.watch(bookProgressProvider(bookId));

    return libraryAsync.when(
      data: (library) {
        final book = library.getBook(bookId);
        if (book == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const EmptyState(
              message: 'الكتاب غير موجود',
              icon: Icons.error_outline,
            ),
          );
        }

        final accentColor = AppTheme.seriesAccent(book.series);
        final hasProgress = progress != null && progress.currentPage > 0;

        return Scaffold(
          body: CustomScrollView(
            slivers: [
              // Cover as expanded header
              SliverAppBar(
                expandedHeight: 320,
                pinned: true,
                flexibleSpace: FlexibleSpaceBar(
                  background: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          accentColor.withValues(alpha: 0.3),
                          Theme.of(context).scaffoldBackgroundColor,
                        ],
                      ),
                    ),
                    child: SafeArea(
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 40),
                          child: BookCover(
                            coverPath: book.cover,
                            title: book.title,
                            width: 180,
                            heroTag: 'cover_${book.id}',
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.pop(context),
                ),
              ),

              // Book info
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      // Title
                      Text(
                        book.title,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              color: accentColor,
                              fontSize: 26,
                            ),
                      ),

                      const SizedBox(height: 12),
                      const OrnamentalDivider(),
                      const SizedBox(height: 20),

                      // Stats row
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _StatChip(
                            icon: Icons.pages_outlined,
                            label: 'الصفحات',
                            value: book.pageCount > 0
                                ? '${book.pageCount}'
                                : '—',
                          ),
                          _StatChip(
                            icon: Icons.category_outlined,
                            label: 'القسم',
                            value: _sectionName(book.series),
                          ),
                          _StatChip(
                            icon: Icons.text_fields,
                            label: 'النوع',
                            value: switch (book.contentMode) {
                              'hybrid' => 'صور + نص',
                              'text' => 'نص',
                              _ => 'صور',
                            },
                          ),
                        ],
                      ),

                      const SizedBox(height: 24),

                      // Progress bar (if reading)
                      // (المعامل غير قابل للفراغ هنا لأن hasProgress تحقق من ذلك)
                      if (hasProgress) ...[
                        _ProgressCard(
                          progress: progress,
                          accentColor: accentColor,
                        ),
                        const SizedBox(height: 16),
                      ],

                      // Action buttons — resume where you left off, or restart.
                      if (hasProgress) ...[
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: () => _openReader(
                              context,
                              bookId: book.id,
                              title: book.title,
                              cover: book.cover,
                            ),
                            icon: const Icon(Icons.play_circle_outline),
                            label: Text(
                              'متابعة من صفحة ${progress.currentPage + 1}',
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () => _openReader(
                              context,
                              bookId: book.id,
                              title: book.title,
                              cover: book.cover,
                              fromStart: true,
                            ),
                            icon: const Icon(Icons.restart_alt),
                            label: const Text('بدء من البداية'),
                          ),
                        ),
                      ] else
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: () => _openReader(
                              context,
                              bookId: book.id,
                              title: book.title,
                              cover: book.cover,
                            ),
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('ابدأ القراءة'),
                          ),
                        ),

                      const SizedBox(height: 24),
                      const OrnamentalDivider(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
      loading: () => Scaffold(
        appBar: AppBar(),
        body: const AntiqueLoader(),
      ),
      error: (error, stack) => Scaffold(
        appBar: AppBar(),
        body: const EmptyState(
          message: 'تعذّر تحميل بيانات الكتاب',
          icon: Icons.error_outline,
        ),
      ),
    );
  }

  /// Opens the reader with the soft fade transition used across the app.
  void _openReader(
    BuildContext context, {
    required String bookId,
    required String title,
    String? cover,
    bool fromStart = false,
  }) {
    Navigator.push(
      context,
      FadeThroughRoute(
        builder: (_) => ReaderScreen(
          bookId: bookId,
          bookTitle: title,
          coverPath: cover,
          startAtBeginning: fromStart,
        ),
      ),
    );
  }

  String _sectionName(String seriesId) {
    switch (seriesId) {
      case 'ma_wara_al_tabia':
        return 'ما وراء الطبيعة';
      case 'fantazia':
        return 'فانتازيا';
      case 'safari':
        return 'سافاري';
      case 'standalone_novels':
        return 'روايات منفردة';
      case 'translations':
        return 'ترجمات';
      default:
        return 'أخرى';
    }
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StatChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const gold = Color(AppConstants.goldHex);

    return Column(
      children: [
        Icon(icon, color: gold, size: 28),
        const SizedBox(height: 6),
        Text(
          value,
          style: theme.textTheme.labelLarge,
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            // Darker than a 50% wash so the label stays readable in daylight.
            color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _ProgressCard extends StatelessWidget {
  final ReadingProgress progress;
  final Color accentColor;

  const _ProgressCard({
    required this.progress,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final progressValue = progress.progress.clamp(0.0, 1.0);
    final currentPage = progress.currentPage;
    final totalPages = progress.totalPages;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accentColor.withValues(alpha: 0.3), width: 1),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'تقدم القراءة',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              Text(
                '${(progressValue * 100).round()}%',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: accentColor,
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: progressValue,
            minHeight: 6,
            backgroundColor: accentColor.withValues(alpha: 0.2),
          ),
          const SizedBox(height: 6),
          Text(
            // currentPage is zero-based; readers count from one.
            'صفحة ${currentPage + 1} من $totalPages',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}
