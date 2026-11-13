import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/providers.dart';
import '../../core/services/library_service.dart' show TextSearchHit;
import '../../core/services/library_source.dart';
import '../../core/models/book.dart';
import '../../core/constants/app_constants.dart';
import '../../core/navigation/book_navigation.dart';
import '../../core/theme/app_theme.dart';
import '../../widgets/common_widgets.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(searchQueryProvider);
    final resultsAsync = ref.watch(searchResultsProvider);
    final textAsync = ref.watch(textSearchResultsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('بحث'),
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _controller,
              decoration: InputDecoration(
                hintText: 'ابحث عن كتاب...',
                hintStyle: const TextStyle(fontFamily: 'Cairo'),
                prefixIcon: const Icon(Icons.search,
                    color: Color(AppConstants.goldHex)),
                suffixIcon: query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _controller.clear();
                          ref.read(searchQueryProvider.notifier).state = '';
                        },
                      )
                    : null,
                filled: true,
                fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(
                    color: Color(AppConstants.goldHex),
                    width: 1,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(
                    color: Color(AppConstants.goldHex),
                    width: 2,
                  ),
                ),
              ),
              style: const TextStyle(fontFamily: 'Cairo', fontSize: 16),
              textDirection: TextDirection.rtl,
              onChanged: (value) {
                // Full-text search opens book JSONs — debounce the typing
                // so we don't rescan the whole OCR corpus per keystroke.
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 350), () {
                  if (mounted) {
                    ref.read(searchQueryProvider.notifier).state = value;
                  }
                });
              },
            ),
          ),

          // Results
          Expanded(
            child: query.isEmpty
                ? const EmptyState(
                    message: 'اكتب عنوان الكتاب أو كلمة من النص للبحث',
                    icon: Icons.search_outlined,
                  )
                : resultsAsync.when(
                    data: (titleResults) => textAsync.when(
                      data: (textHits) {
                        final children = <Widget>[];

                        if (titleResults.isNotEmpty) {
                          children.add(const _SectionHeader(label: 'من العناوين'));
                          for (final book in titleResults) {
                            children.add(_SearchResultItem(
                              title: book.title,
                              coverPath: book.cover,
                              sectionName: _sectionName(book.series),
                              accentColor: AppTheme.seriesAccent(book.series),
                              onTap: () =>
                                  BookNavigation.openReader(context, book),
                              onLongPress: () =>
                                  BookNavigation.openDetails(context, book),
                            ));
                          }
                        }

                        if (textHits.isNotEmpty) {
                          children.add(const _SectionHeader(
                              label: 'مطابقات داخل النصوص'));
                          for (final hit in textHits) {
                            children.add(_TextHitCard(hit: hit));
                          }
                        }

                        if (children.isEmpty) {
                          return EmptyState(
                            message: 'لا توجد نتائج لـ "$query"',
                            icon: Icons.search_off_outlined,
                          );
                        }
                        return ListView(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          children: children,
                        );
                      },
                      // Title search still works even if the text layer fails.
                      loading: () => titleResults.isEmpty
                          ? const AntiqueLoader()
                          : _titleOnlyList(context, titleResults),
                      error: (_, __) =>
                          _titleOnlyList(context, titleResults),
                    ),
                    loading: () => const AntiqueLoader(),
                    error: (_, __) => const EmptyState(
                      message: 'تعذّر البحث',
                      icon: Icons.error_outline,
                    ),
                  ),
          ),
        ],
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
        return '';
    }
  }

  Widget _titleOnlyList(BuildContext context, List<Book> results) {
    if (results.isEmpty) {
      return const SizedBox.shrink();
    }
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        const _SectionHeader(label: 'من العناوين'),
        for (final book in results)
          _SearchResultItem(
            title: book.title,
            coverPath: book.cover,
            sectionName: _sectionName(book.series),
            accentColor: AppTheme.seriesAccent(book.series),
            onTap: () => BookNavigation.openReader(context, book),
            onLongPress: () => BookNavigation.openDetails(context, book),
          ),
      ],
    );
  }
}

/// Small antique divider caption between result groups.
class _SectionHeader extends StatelessWidget {
  final String label;

  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
      child: Row(
        children: [
          const Expanded(
            child: Divider(color: Color(AppConstants.goldHex), thickness: 1),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: 'ReemKufi',
                fontSize: 13,
                color: Color(AppConstants.leatherBrownHex),
              ),
            ),
          ),
          const Expanded(
            child: Divider(color: Color(AppConstants.goldHex), thickness: 1),
          ),
        ],
      ),
    );
  }
}

/// A full-text match: book cover + "صفحة N" + the surrounding excerpt.
class _TextHitCard extends StatelessWidget {
  final TextSearchHit hit;

  const _TextHitCard({required this.hit});

  @override
  Widget build(BuildContext context) {
    final accent = AppTheme.seriesAccent(hit.book.series);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: accent.withValues(alpha: 0.45), width: 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => BookNavigation.openReader(
          context,
          hit.book,
          initialPage: hit.pageNumber - 1, // provider pages are 1-based
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 44,
                height: 62,
                child: hit.book.cover != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image(
                          image: LibrarySource.image(hit.book.cover!),
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const Icon(
                            Icons.book_outlined,
                            color: Color(AppConstants.goldHex),
                          ),
                        ),
                      )
                    : const Icon(
                        Icons.book_outlined,
                        color: Color(AppConstants.goldHex),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            hit.book.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'ReemKufi',
                              fontSize: 14,
                              color: Color(AppConstants.leatherBrownHex),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            'صفحة ${hit.pageNumber}',
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 11,
                              color: accent,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      hit.excerpt,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Amiri',
                        fontSize: 14,
                        height: 1.6,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchResultItem extends StatelessWidget {
  final String title;
  final String? coverPath;
  final String sectionName;
  final Color accentColor;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _SearchResultItem({
    required this.title,
    this.coverPath,
    required this.sectionName,
    required this.accentColor,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        leading: BookCover(
          coverPath: coverPath,
          title: title,
          width: 40,
        ),
        title: Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        subtitle: Text(
          sectionName,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: AppTheme.readableAccent(context, accentColor),
                fontWeight: FontWeight.w600,
              ),
        ),
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }
}
