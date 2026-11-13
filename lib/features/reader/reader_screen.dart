import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/models/book.dart';
import '../../core/models/reader_palette.dart';
import '../../core/models/reader_settings.dart';
import '../../core/providers/providers.dart';
import '../../core/services/text_paginator.dart';
import '../../core/services/library_source.dart';
import '../../core/constants/app_constants.dart';
import '../../widgets/common_widgets.dart';
import 'in_book_search.dart';
import '../../widgets/page_curl.dart';

/// Full-screen reader.
///
/// Layout rules that fix the "ugly scan" complaints:
///  * the page image is always fitted with [BoxFit.contain] and the surrounding
///    area is painted with the **exact paper colour of the page**, so the page
///    runs edge to edge and no white box floats on a beige background;
///  * every page asset is the same size (see `build_page_library_v2.py`), so the
///    text never jumps scale from one page to the next;
///  * a single colour matrix maps the greyscale scan onto the active palette,
///    which is what makes paper / sepia / dark themes possible at all.
class ReaderScreen extends ConsumerStatefulWidget {
  final String bookId;
  final String bookTitle;
  final String? coverPath;

  /// When true the saved position is ignored and page one is shown.
  final bool startAtBeginning;

  /// Explicit landing page (e.g. from a full-text search hit). Overrides the
  /// saved progress but not a deliberate "start from beginning".
  final int? initialPage;

  const ReaderScreen({
    super.key,
    required this.bookId,
    required this.bookTitle,
    this.coverPath,
    this.startAtBeginning = false,
    this.initialPage,
  });

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  List<String> _pages = [];

  /// Character offsets for reflowable text books. Null for scanned and hybrid
  /// books, whose pages map 1:1 onto images and never move.
  TextPagination? _pagination;

  /// Offset to restore after a repagination triggered by a font change.
  int? _pendingOffset;

  List<String>? _imageFiles; // non-null => scanned (image-mode) book

  /// Hybrid books (image + OCR text): a one-button switch between the original
  /// page scan and its text layer. Default is the ORIGINAL page (spec: the
  /// image mode stays the default for every book until OCR is reviewed).
  bool _showTextMode = false;

  /// True while the reader is holding a text page down to peek at the original
  /// scan underneath it (spec §7). Hybrid pagination is one text page per
  /// image page, so the index maps straight onto `_imageFiles`.
  bool _peeking = false;

  int _currentPage = 0;
  bool _isLoading = true;

  /// Immersive reading: the chrome is shown briefly on open, then slides away
  /// and only comes back on a tap.
  bool _showControls = true;
  Timer? _autoHideTimer;

  bool _isBookmarked = false;

  /// True while the visible page is magnified — page turning is locked then so
  /// a drag pans inside the page instead.
  bool _zoomed = false;

  final PageCurlController _curl = PageCurlController();
  late final PageController _pageController = PageController();

  /// Broadcasts zoom commands to whichever page is currently on screen.
  final ReaderZoomController _zoomController = ReaderZoomController();

  /// Reading-speed estimate for the "time left" label.
  ///
  /// Wall-clock time since the reader opened is a bad signal: the phone can sit
  /// idle for an hour and one page turn would then read as ten minutes a page.
  /// So we only accumulate the *gaps between page turns*, and any gap longer
  /// than [_idleGap] is treated as "the reader walked away" and ignored.
  static const Duration _idleGap = Duration(seconds: 120);
  DateTime? _lastTurnAt;
  double _activeSeconds = 0;
  int _timedTurns = 0;

  int get _totalPages =>
      _imageFiles != null ? _imageFiles!.length : _pages.length;

  @override
  void initState() {
    super.initState();
    _loadBook();
    _applyImmersive(false);
    _autoHideTimer = Timer(const Duration(seconds: 4), _hideControls);
  }

  void _hideControls() {
    if (!mounted || !_showControls) return;
    setState(() => _showControls = false);
    _applyImmersive(true);
  }

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _pageController.dispose();
    _zoomController.dispose();
    _curl.dispose();
    super.dispose();
  }

  /// Hide the Android status/navigation bars while reading.
  void _applyImmersive(bool immersive) {
    SystemChrome.setEnabledSystemUIMode(
      immersive ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    _applyImmersive(!_showControls);

    _autoHideTimer?.cancel();
    if (_showControls) {
      _autoHideTimer = Timer(const Duration(seconds: 4), _hideControls);
    }
  }

  Future<void> _loadBook() async {
    final screenSize = MediaQuery.of(context).size;

    final library = await ref.read(libraryProvider.future);
    final book = library.getBook(widget.bookId);
    if (book == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    final libraryService = ref.read(libraryServiceProvider);
    final detail =
        await libraryService.loadBookDetail(widget.bookId, book.jsonFile);

    if (detail == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    if (detail.contentMode == 'image') {
      await _loadImageBook(detail);
      return;
    }

    // Hybrid books (image + reviewed OCR text): preload BOTH layers — the
    // page-image zip as usual, plus one text page per original image page —
    // then open on the original scan. One button toggles between the two
    // and the page index stays identical, so the position never moves.
    if (detail.contentMode == 'hybrid' && detail.hasOcrText) {
      await _loadImageBook(detail);
      if (!mounted) return;
      final textPages = ContentPaginator.paginateContent(
        bookDetail: detail,
        screenWidth: screenSize.width,
        screenHeight: screenSize.height,
        settings: ref.read(readerSettingsProvider),
      );
      final hasText = textPages.any((p) => p.trim().isNotEmpty);
      if (mounted && hasText) {
        setState(() => _pages = textPages);
      }
      return;
    }

    final settings = ref.read(readerSettingsProvider);
    // Measured pagination, kept so bookmarks can carry a character anchor
    // instead of a page number that a font change invalidates.
    final pagination = TextPaginator.paginateMeasured(
      text: detail.chapters.map((c) => c.text).join('\n\n'),
      screenWidth: screenSize.width,
      screenHeight: screenSize.height,
      settings: settings,
    );
    final pages = pagination.pages;

    final progress = ref.read(bookProgressProvider(widget.bookId));
    int restoredPage = widget.startAtBeginning
        ? 0
        : (widget.initialPage ??
            (progress != null && progress.currentPage < pages.length
                ? progress.currentPage
                : 0));

    // A bookmark created before a font change still points at its sentence:
    // re-derive the page from the character offset it stored.
    final anchor = ref.read(bookmarksProvider.notifier).anchorFor(widget.bookId);
    if (!widget.startAtBeginning &&
        widget.initialPage == null &&
        anchor != null) {
      restoredPage = pagination.pageForOffset(anchor.charOffset);
    }

    // Repagination after a font change outranks both: the offset was captured
    // from the page the reader was actually on.
    final pending = _pendingOffset;
    if (pending != null && pending >= 0) {
      restoredPage = pagination.pageForOffset(pending);
      _pendingOffset = null;
    }

    final bookmarked = ref.read(bookmarksProvider.notifier).isBookmarked(
          widget.bookId,
          restoredPage,
        );

    if (mounted) {
      setState(() {
        _pages = pages;
        _pagination = pagination;
        _currentPage = restoredPage;
        _isLoading = false;
        _isBookmarked = bookmarked;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pageController.hasClients && restoredPage < pages.length) {
          _pageController.jumpToPage(restoredPage);
        }
      });
    }
  }

  /// True when there is prose to search — image-only scans have no text.
  bool get _hasSearchableText => _pages.any((p) => p.trim().isNotEmpty);

  Future<void> _openInBookSearch() async {
    _autoHideTimer?.cancel();
    final palette = ref.read(readerSettingsProvider).palette;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: palette.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => InBookSearchSheet(
        pages: _pages,
        palette: palette,
        onSelect: (page) {
          Navigator.pop(sheetContext);
          // Results are text-page indexes, which for hybrid books are the same
          // indexes as the scans — jumping is safe in either mode.
          _jumpTo(page);
        },
      ),
    );
    _autoHideTimer = Timer(const Duration(seconds: 4), _hideControls);
  }

  /// Switch between the original page scan and the OCR text layer
  /// (hybrid books only).
  ///
  /// The two sides are usually 1:1, but a book whose rejected pages were
  /// dropped can paginate differently. Mapping the *fraction* of the way
  /// through the book keeps the reader where they were; clamping to zero
  /// (the old behaviour) threw them back to the cover.
  void _toggleTextMode() {
    if (!(_imageFiles != null && _pages.isNotEmpty)) return;
    final fromLength = (_showTextMode ? _pages : _imageFiles!).length;
    final toLength = (_showTextMode ? _imageFiles! : _pages).length;
    final progress = fromLength <= 1 ? 0.0 : _currentPage / (fromLength - 1);

    setState(() {
      _showTextMode = !_showTextMode;
      _currentPage =
          (progress * (toLength - 1)).round().clamp(0, toLength - 1);
    });
    _saveProgress();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pageController.hasClients) {
        _pageController.jumpToPage(_currentPage.clamp(0, _totalPages - 1));
      }
    });
  }

  /// Load a scanned book: extract its page zip once, then list the files.
  Future<void> _loadImageBook(BookDetail detail) async {
    try {
      final support = await getApplicationSupportDirectory();
      final pagesRoot = Directory('${support.path}/book_pages');
      final bookDir = Directory('${pagesRoot.path}/${detail.id}');
      final marker = File('${bookDir.path}/.extracted');

      List<String> files;
      if (await marker.exists()) {
        files = _listImages(bookDir);
      } else {
        if (await bookDir.exists()) {
          await bookDir.delete(recursive: true);
        }
        await bookDir.create(recursive: true);

        final zipAsset = detail.zipAsset ?? 'books/${detail.id}.zip';
        final bytes = await LibrarySource.readBytes(zipAsset);
        final archive = ZipDecoder().decodeBytes(bytes);
        for (final f in archive) {
          if (f.isFile) {
            final out = File('${bookDir.path}/${f.name}');
            await out.writeAsBytes(f.content as List<int>);
          }
        }
        await marker.writeAsString('ok');
        files = _listImages(bookDir);
        _purgeOtherBooks(pagesRoot, detail.id);
      }

      final progress = ref.read(bookProgressProvider(widget.bookId));
      final restored = widget.startAtBeginning
          ? 0
          : (widget.initialPage ??
              (progress?.currentPage.clamp(0, (files.length - 1).clamp(0, 1 << 30)) ?? 0));

      if (mounted) {
        setState(() {
          _imageFiles = files;
          _currentPage = restored;
          _isLoading = false;
          _isBookmarked = ref
              .read(bookmarksProvider.notifier)
              .isBookmarked(widget.bookId, restored);
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_curl.page != restored) _curl.jumpToPage(restored);
          if (_pageController.hasClients) _pageController.jumpToPage(restored);
          // Warm the neighbours of the page we actually open on, so the very
          // first turn is as smooth as the rest.
          _precacheNeighbours(restored);
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _imageFiles = [];
        });
      }
    }
  }

  List<String> _listImages(Directory dir) {
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.webp'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return files.map((f) => f.path).toList();
  }

  /// Keep only the currently open book's extracted pages on disk.
  void _purgeOtherBooks(Directory root, String keepId) {
    try {
      for (final e in root.listSync()) {
        if (e is Directory && e.path.split(RegExp(r'[/\\]')).last != keepId) {
          e.delete(recursive: true);
        }
      }
    } catch (_) {
      // Cleanup is best-effort only.
    }
  }

  void _goToPage(int page) {
    if (page < 0 || page >= _totalPages || page == _currentPage) return;
    setState(() {
      _currentPage = page;
      _zoomed = false; // every page opens fitted
    });
    _recordPageTurn();
    _saveProgress();
    _checkBookmark();
    _triggerFeedback();
    _precacheNeighbours(page);
  }

  /// Decode the pages either side of [index] before they are needed.
  ///
  /// Without this the next page is decoded *during* the turn, which shows up
  /// as a hitch in the curl exactly when the animation is at its busiest
  /// (spec §9: preload the two following pages and the previous one).
  void _precacheNeighbours(int index) {
    final files = _imageFiles;
    if (files == null || !mounted) return;
    for (final delta in const [1, 2, -1]) {
      final i = index + delta;
      if (i < 0 || i >= files.length) continue;
      // Fire and forget: a page that fails to decode must not break reading.
      precacheImage(FileImage(File(files[i])), context)
          .catchError((Object _) {});
    }
  }

  void _saveProgress() {
    ref.read(readingProgressProvider.notifier).saveProgress(
          widget.bookId,
          _currentPage,
          _totalPages,
        );
  }

  void _checkBookmark() {
    final bookmarked = ref
        .read(bookmarksProvider.notifier)
        .isBookmarked(widget.bookId, _currentPage);
    if (bookmarked != _isBookmarked) {
      setState(() => _isBookmarked = bookmarked);
    }
  }

  void _toggleBookmark() {
    // The notifier flips its state synchronously and only then persists, so the
    // icon can be read back immediately. (Awaiting the future here used to be
    // the only way, and forgetting it left the icon stuck on "not bookmarked".)
    ref.read(bookmarksProvider.notifier).toggle(
          widget.bookId,
          widget.bookTitle,
          _currentPage,
          charOffset: _anchorForCurrentPage(),
        );
    _checkBookmark();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_isBookmarked ? 'أُضيفت علامة مرجعية' : 'أُزيلت العلامة'),
          duration: const Duration(milliseconds: 900),
          backgroundColor:
              _isBookmarked ? const Color(AppConstants.goldHex) : Colors.grey,
        ),
      );
    }
  }

  /// Character offset of the first character on the current page, or `-1` when
  /// the book has fixed pages (scanned / hybrid) and no anchor is needed.
  int _anchorForCurrentPage() {
    final p = _pagination;
    if (p == null || _currentPage >= p.starts.length) return -1;
    return p.starts[_currentPage];
  }

  void _triggerFeedback() {
    final settings = ref.read(readerSettingsProvider);
    if (settings.hapticFeedback) {
      HapticFeedback.lightImpact();
    }
    // A short system tick stands in for the paper swish; it needs no audio
    // asset and no plugin, and it honours the switch in Settings.
    if (settings.pageFlipSound) {
      SystemSound.play(SystemSoundType.click);
    }
  }

  void _repaginate() async {
    if (_imageFiles != null) return; // scanned books have fixed pages
    // Remember the sentence, not the page number: after a font change the same
    // page index is somewhere else entirely.
    _pendingOffset = _anchorForCurrentPage();
    if (mounted) setState(() => _isLoading = true);
    await _loadBook();
  }

  void _jumpTo(int page) {
    if (_imageFiles != null) {
      _curl.jumpToPage(page);
    } else if (_pageController.hasClients) {
      _pageController.jumpToPage(page);
    }
    _goToPage(page);
  }

  void _setZoomed(bool zoomed) {
    if (zoomed != _zoomed && mounted) setState(() => _zoomed = zoomed);
  }

  // ─── Time-left estimate ───────────────────────────────────────────────────

  /// Called on every page turn; accumulates the gap since the previous turn.
  void _recordPageTurn() {
    final now = DateTime.now();
    final last = _lastTurnAt;
    if (last != null) {
      final gap = now.difference(last);
      if (gap <= _idleGap) {
        _activeSeconds += gap.inMilliseconds / 1000.0;
        _timedTurns++;
      }
    }
    _lastTurnAt = now;
  }

  /// Seconds per page, measured from this session once there is enough data,
  /// otherwise a sane default for a scanned novel page.
  double get _secondsPerPage {
    if (_timedTurns >= 2) {
      return (_activeSeconds / _timedTurns).clamp(6.0, 180.0);
    }
    return 45;
  }

  String get _timeLeftLabel {
    final left = _totalPages - 1 - _currentPage;
    if (left <= 0) return 'آخر صفحة';
    final seconds = (left * _secondsPerPage).round();
    if (seconds < 60) return 'أقل من دقيقة';
    final minutes = seconds ~/ 60;
    if (minutes < 60) return 'متبقٍ $minutes دقيقة';
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return rest == 0 ? 'متبقٍ $hours ساعة' : 'متبقٍ $hours س $rest د';
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        body: Container(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: const AntiqueLoader(),
        ),
      );
    }

    if ((_imageFiles == null && _pages.isEmpty) ||
        (_imageFiles != null && _imageFiles!.isEmpty)) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.bookTitle)),
        body: const EmptyState(
          message: 'تعذّر تحميل محتوى الكتاب',
          icon: Icons.error_outline,
        ),
      );
    }

    final settings = ref.watch(readerSettingsProvider);
    final palette = settings.palette;
    final vertical = settings.readingAxis == ReadingAxis.vertical;

    // Live-apply the reading direction changed inside the sheet.
    ref.listen(readerSettingsProvider, (prev, next) {
      if (prev == null) return;
      if (prev.readingAxis != next.readingAxis && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _pageController.hasClients) {
            _pageController.jumpToPage(_currentPage);
          }
        });
      }
    });

    final Widget pageBody;
    // Text layer wins when the reader switched to it on a hybrid book; pure
    // text books have no page images at all (_imageFiles == null).
    final useTextLayer = _imageFiles == null ||
        (_showTextMode &&
            _pages.isNotEmpty &&
            _pages.any((p) => p.trim().isNotEmpty));
    if (useTextLayer) {
      pageBody = _TextPageView(
        pages: _pages,
        settings: settings,
        controller: _pageController,
        onPageChanged: _goToPage,
        palette: palette,
        imageFiles: _imageFiles,
        // Long-press peeks at the scan this page was OCR'd from. Only
        // meaningful when the book actually has page images behind it.
        onPeekStart: _imageFiles == null
            ? null
            : () => setState(() => _peeking = true),
        onPeekEnd: _imageFiles == null
            ? null
            : () => setState(() => _peeking = false),
      );
    } else if (vertical) {
      pageBody = _ScannedPageView(
        files: _imageFiles!,
        palette: palette,
        controller: _pageController,
        onPageChanged: _goToPage,
        zoomController: _zoomController,
        onZoomChanged: _setZoomed,
        coverPath: widget.coverPath,
        activeIndex: _currentPage,
      );
    } else {
      pageBody = PageCurlView(
        controller: _curl,
        itemCount: _imageFiles!.length,
        initialPage: _currentPage,
        enabled: !_zoomed,
        curl: settings.pageFlipEffect,
        onPageChanged: _goToPage,
        itemBuilder: (context, index) => _ScannedPage(
          key: ValueKey('page_$index'),
          filePath: _imageFiles![index],
          palette: palette,
          isCover: index == 0 && widget.coverPath != null,
          coverPath: widget.coverPath,
          isActive: index == _currentPage,
          zoomController: _zoomController,
          onZoomChanged: _setZoomed,
        ),
      );
    }

    return Scaffold(
      // The reader background IS the paper colour, so the letterboxing above
      // and below the page is invisible instead of looking like a grey gap.
      backgroundColor: palette.paper,
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
              child: pageBody,
            ),
          ),

          // Long-press peek: the original cleaned scan for the page being
          // held, drawn over the text at the same tint so the switch reads as
          // "same page, other layer" rather than a different screen.
          if (_peeking &&
              _imageFiles != null &&
              _currentPage < _imageFiles!.length)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: palette.paper,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 14),
                    child: SizedBox.expand(
                      child: ColorFiltered(
                        colorFilter: ColorFilter.matrix(palette.colorMatrix),
                        child: Image.file(
                          File(_imageFiles![_currentPage]),
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.medium,
                          errorBuilder: (context, _, __) =>
                              const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // Night dimming: a scrim over the page only, so the floating bars
          // keep their own contrast and stay readable.
          if (settings.brightness < 0.999)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: Colors.black
                      .withValues(alpha: (1 - settings.brightness) * 0.72),
                ),
              ),
            ),

          _OverlayBar(
            visible: _showControls,
            isTop: true,
            child: _ReaderTopBar(
              title: widget.bookTitle,
              palette: palette,
              isBookmarked: _isBookmarked,
              onBookmark: _toggleBookmark,
              onToggleMode:
                  (_imageFiles != null && _pages.isNotEmpty) ? _toggleTextMode : null,
              isTextMode: _showTextMode,
              onSearch: _hasSearchableText ? _openInBookSearch : null,
              onClose: () {
                _saveProgress();
                Navigator.pop(context);
              },
            ),
          ),

          _OverlayBar(
            visible: _showControls,
            isTop: false,
            child: _ReaderBottomBar(
              palette: palette,
              currentPage: _currentPage,
              totalPages: _totalPages,
              timeLeft: _timeLeftLabel,
              zoomController: _imageFiles != null ? _zoomController : null,
              onPageChanged: _jumpTo,
              onSettingsPressed: () async {
                _autoHideTimer?.cancel();
                await showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: palette.paper,
                  shape: const RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  builder: (context) => _QuickSettingsSheet(
                    // Font size / spacing only mean something when prose is
                    // on screen: pure text books, or a hybrid book the reader
                    // has switched to its text layer.
                    showTextSettings: _imageFiles == null || _showTextMode,
                  ),
                );
                _repaginate();
                _autoHideTimer =
                    Timer(const Duration(seconds: 4), _hideControls);
              },
            ),
          ),

          // A whisper-thin footer while the chrome is hidden, so the reader
          // always knows where they are without breaking immersion.
          if (!_showControls)
            Positioned(
              left: 0,
              right: 0,
              bottom: 6,
              child: IgnorePointer(
                child: Center(
                  child: Text(
                    '${_currentPage + 1} / $_totalPages',
                    // Forced LTR: inside the RTL app the bidi algorithm flipped
                    // the two numbers, so page 42 of 125 read "125 / 42".
                    textDirection: TextDirection.ltr,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: palette.ink.withValues(alpha: 0.28),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A bar that slides in from its edge and fades, without affecting layout.
class _OverlayBar extends StatelessWidget {
  final bool visible;
  final bool isTop;
  final Widget child;

  const _OverlayBar({
    required this.visible,
    required this.isTop,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      top: isTop ? 0 : null,
      bottom: isTop ? null : 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          offset: visible ? Offset.zero : Offset(0, isTop ? -1 : 1),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 180),
            opacity: visible ? 1 : 0,
            // The bar absorbs taps on its own background. Without this a tap on
            // the padding between two buttons fell through to the page gesture
            // and dismissed the very bar the reader was aiming at.
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              child: SafeArea(top: isTop, bottom: !isTop, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReaderTopBar extends StatelessWidget {
  final String title;
  final ReaderPalette palette;
  final bool isBookmarked;
  final VoidCallback onBookmark;
  final VoidCallback onClose;

  /// Hybrid books only: flip between the original page scan and its OCR
  /// text layer. Null => pure image/text book, no button.
  final VoidCallback? onToggleMode;
  final bool isTextMode;

  /// Null when the book carries no readable text (image-only scans).
  final VoidCallback? onSearch;

  const _ReaderTopBar({
    required this.title,
    required this.palette,
    required this.isBookmarked,
    required this.onBookmark,
    required this.onClose,
    this.onToggleMode,
    this.isTextMode = false,
    this.onSearch,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: palette.chrome.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.close, color: palette.onChrome, size: 20),
            onPressed: onClose,
          ),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'ReemKufi',
                fontSize: 15,
                color: palette.onChrome,
              ),
            ),
          ),
          if (onSearch != null)
            IconButton(
              icon: Icon(Icons.search, color: palette.onChrome, size: 20),
              tooltip: 'بحث داخل الكتاب',
              onPressed: onSearch,
            ),
          if (onToggleMode != null)
            IconButton(
              icon: Icon(
                isTextMode ? Icons.menu_book_outlined : Icons.article_outlined,
                color: palette.onChrome,
                size: 20,
              ),
              tooltip:
                  isTextMode ? 'الصفحة الأصلية' : 'وضع النص',
              onPressed: onToggleMode,
            ),
          IconButton(
            icon: Icon(
              isBookmarked ? Icons.bookmark : Icons.bookmark_border,
              color: isBookmarked
                  ? const Color(AppConstants.goldHex)
                  : palette.onChrome,
              size: 20,
            ),
            onPressed: onBookmark,
          ),
        ],
      ),
    );
  }
}

/// Slim footer: page, percentage, time left, zoom and settings.
class _ReaderBottomBar extends StatelessWidget {
  final ReaderPalette palette;
  final int currentPage;
  final int totalPages;
  final String timeLeft;
  final ValueChanged<int> onPageChanged;
  final VoidCallback onSettingsPressed;
  final ReaderZoomController? zoomController;

  const _ReaderBottomBar({
    required this.palette,
    required this.currentPage,
    required this.totalPages,
    required this.timeLeft,
    required this.onPageChanged,
    required this.onSettingsPressed,
    this.zoomController,
  });

  @override
  Widget build(BuildContext context) {
    final percent =
        totalPages > 1 ? (currentPage / (totalPages - 1) * 100).round() : 100;
    final label = palette.onChrome.withValues(alpha: 0.85);

    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
      decoration: BoxDecoration(
        color: palette.chrome.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 14,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // FittedBox, not plain Text: the three labels together overflow
              // a 360dp phone once the system font scale is turned up, and a
              // clipped page counter is worse than a slightly smaller one.
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    'صفحة ${currentPage + 1} من $totalPages · $percent%',
                    maxLines: 1,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: label,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerEnd,
                  child: Text(
                    timeLeft,
                    maxLines: 1,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 11,
                      color: label.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              if (zoomController != null) ...[
                _BarIcon(
                  icon: Icons.zoom_out,
                  palette: palette,
                  onTap: zoomController!.zoomOut,
                ),
                _BarIcon(
                  icon: Icons.fit_screen_outlined,
                  palette: palette,
                  onTap: zoomController!.resetZoom,
                ),
                _BarIcon(
                  icon: Icons.zoom_in,
                  palette: palette,
                  onTap: zoomController!.zoomIn,
                ),
              ],
              // Slider wrapped in a slim box so its generous touch area cannot
              // swallow taps meant for the icons next to it.
              Expanded(
                child: SizedBox(
                  height: 30,
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 2,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 12),
                      activeTrackColor: const Color(AppConstants.goldHex),
                      inactiveTrackColor:
                          palette.onChrome.withValues(alpha: 0.22),
                      thumbColor: const Color(AppConstants.goldHex),
                    ),
                    child: Slider(
                      value: currentPage
                          .toDouble()
                          .clamp(0, (totalPages - 1).toDouble()),
                      min: 0,
                      max:
                          (totalPages - 1).toDouble().clamp(1, double.infinity),
                      onChanged: (v) => onPageChanged(v.round()),
                    ),
                  ),
                ),
              ),
              _BarIcon(
                icon: Icons.text_fields,
                palette: palette,
                onTap: onSettingsPressed,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BarIcon extends StatelessWidget {
  final IconData icon;
  final ReaderPalette palette;
  final VoidCallback onTap;

  const _BarIcon({
    required this.icon,
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 20,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Icon(icon, size: 19, color: palette.onChrome),
      ),
    );
  }
}

/// Sends zoom commands from the bottom bar to the page that is on screen.
class ReaderZoomController extends ChangeNotifier {
  double? _command;

  void zoomIn() {
    _command = 1.35;
    notifyListeners();
  }

  void zoomOut() {
    _command = 1 / 1.35;
    notifyListeners();
  }

  void resetZoom() {
    _command = 0;
    notifyListeners();
  }

  double? take() {
    final command = _command;
    _command = null;
    return command;
  }
}

/// One scanned page: greyscale asset tinted into the active palette, with
/// pinch / double-tap zoom.
class _ScannedPage extends StatefulWidget {
  final String filePath;
  final ReaderPalette palette;
  final bool isCover;
  final String? coverPath;
  final bool isActive;
  final ReaderZoomController zoomController;
  final ValueChanged<bool> onZoomChanged;

  const _ScannedPage({
    super.key,
    required this.filePath,
    required this.palette,
    required this.isActive,
    required this.zoomController,
    required this.onZoomChanged,
    this.isCover = false,
    this.coverPath,
  });

  @override
  State<_ScannedPage> createState() => _ScannedPageState();
}

class _ScannedPageState extends State<_ScannedPage> {
  final TransformationController _controller = TransformationController();
  Offset _doubleTapPosition = Offset.zero;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTransformChanged);
    widget.zoomController.addListener(_onZoomCommand);
  }

  @override
  void dispose() {
    widget.zoomController.removeListener(_onZoomCommand);
    _controller.removeListener(_onTransformChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onTransformChanged() {
    final zoomed = _controller.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) {
      _zoomed = zoomed;
      if (widget.isActive) widget.onZoomChanged(zoomed);
      if (mounted) setState(() {});
    }
  }

  void _onZoomCommand() {
    if (!widget.isActive) return;
    final command = widget.zoomController.take();
    if (command == null) return;
    if (command == 0) {
      _controller.value = Matrix4.identity();
      return;
    }
    final current = _controller.value.getMaxScaleOnAxis();
    _setScaleAboutCentre((current * command).clamp(1.0, 5.0));
  }

  void _setScaleAboutCentre(double scale) {
    final size = context.size;
    if (size == null) return;
    _controller.value = Matrix4.identity()
      ..translateByDouble(
        size.width / 2 * (1 - scale),
        size.height / 2 * (1 - scale),
        0,
        1,
      )
      ..scaleByDouble(scale, scale, scale, 1);
  }

  void _handleDoubleTap() {
    if (_zoomed) {
      _controller.value = Matrix4.identity();
    } else {
      const double scale = 2.5;
      _controller.value = Matrix4.identity()
        ..translateByDouble(
          -_doubleTapPosition.dx * (scale - 1),
          -_doubleTapPosition.dy * (scale - 1),
          0,
          1,
        )
        ..scaleByDouble(scale, scale, scale, 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;

    Widget page;
    if (widget.isCover && widget.coverPath != null) {
      // The cover is real colour artwork — leave it untinted, and inset it so
      // it reads as a book cover rather than a blown-up background.
      page = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 44),
        child: Image(
          image: LibrarySource.image(widget.coverPath!),
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          errorBuilder: (c, e, s) => const SizedBox.shrink(),
        ),
      );
    } else {
      // One colour matrix turns the greyscale scan into paper + ink for the
      // active palette (and inverts it for the dark one).
      page = SizedBox.expand(
        child: ColorFiltered(
          colorFilter: ColorFilter.matrix(palette.colorMatrix),
          child: Image.file(
            File(widget.filePath),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            filterQuality: FilterQuality.high,
            errorBuilder: (c, e, s) => Center(
              child: Icon(
                Icons.broken_image_outlined,
                size: 40,
                color: palette.ink.withValues(alpha: 0.4),
              ),
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      onDoubleTapDown: (d) => _doubleTapPosition = d.localPosition,
      onDoubleTap: _handleDoubleTap,
      // At 1× the zoomer must not compete with the page turn: single-finger
      // drags belong to the curl. Zooming in (double tap or the bar buttons)
      // re-enables it so panning and pinch work from then on.
      child: IgnorePointer(
        ignoring: !_zoomed,
        child: InteractiveViewer(
          transformationController: _controller,
          minScale: 1.0,
          maxScale: 5.0,
          // Panning only once magnified, so a horizontal drag at 1× still
          // reaches the page-turn gesture instead of being swallowed here.
          panEnabled: _zoomed,
          child: page,
        ),
      ),
    );
  }
}

/// Vertical-scroll variant (kept for readers who prefer it).
class _ScannedPageView extends StatelessWidget {
  final List<String> files;
  final ReaderPalette palette;
  final PageController controller;
  final ValueChanged<int> onPageChanged;
  final ReaderZoomController zoomController;
  final ValueChanged<bool> onZoomChanged;
  final String? coverPath;
  final int activeIndex;

  const _ScannedPageView({
    required this.files,
    required this.palette,
    required this.controller,
    required this.onPageChanged,
    required this.zoomController,
    required this.onZoomChanged,
    required this.activeIndex,
    this.coverPath,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: palette.paper,
      child: PageView.builder(
        reverse: true,
        scrollDirection: Axis.vertical,
        itemCount: files.length,
        controller: controller,
        onPageChanged: onPageChanged,
        itemBuilder: (context, index) => _ScannedPage(
          key: ValueKey('vpage_$index'),
          filePath: files[index],
          palette: palette,
          isCover: index == 0 && coverPath != null,
          coverPath: coverPath,
          isActive: index == activeIndex,
          zoomController: zoomController,
          onZoomChanged: onZoomChanged,
        ),
      ),
    );
  }
}

/// Re-flowed text pages (used by any book that ships with a text layer).
class _TextPageView extends StatelessWidget {
  final List<String> pages;
  final ReaderSettings settings;
  final PageController controller;
  final ValueChanged<int> onPageChanged;

  /// Page images, when the book is hybrid. A page whose text was rejected by
  /// the correction gates carries an empty string, and the spec requires that
  /// page to appear as its cleaned image inside the text flow — so the reader
  /// never sees a blank page or a bad correction.
  final List<String>? imageFiles;
  final ReaderPalette palette;

  /// Long-press peek at the underlying scan (hybrid books only). Null for
  /// pure text books, which have no page images to show.
  final VoidCallback? onPeekStart;
  final VoidCallback? onPeekEnd;

  const _TextPageView({
    required this.pages,
    required this.settings,
    required this.controller,
    required this.onPageChanged,
    required this.palette,
    this.imageFiles,
    this.onPeekStart,
    this.onPeekEnd,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final horizontal = settings.readingAxis == ReadingAxis.horizontal;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            theme.colorScheme.surface,
            theme.colorScheme.surfaceContainerHighest,
            theme.colorScheme.surface,
          ],
          stops: const [0.0, 0.5, 1.0],
        ),
      ),
      child: PageView.builder(
        reverse: horizontal,
        scrollDirection: horizontal ? Axis.horizontal : Axis.vertical,
        pageSnapping: true,
        itemCount: pages.length,
        controller: controller,
        onPageChanged: onPageChanged,
        itemBuilder: (context, index) {
          final text = pages[index];
          final Widget child;
          if (text.trim().isEmpty &&
              imageFiles != null &&
              index < imageFiles!.length) {
            // Rejected page: show the cleaned scan, tinted like every other
            // page so it sits on the same paper.
            child = Container(
              color: palette.paper,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
              child: SizedBox.expand(
                child: ColorFiltered(
                  colorFilter: ColorFilter.matrix(palette.colorMatrix),
                  child: Image.file(
                    File(imageFiles![index]),
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.medium,
                    errorBuilder: (context, _, __) => const SizedBox.shrink(),
                  ),
                ),
              ),
            );
          } else {
            child = _PageContent(
              text: text,
              settings: settings,
              pageNumber: index + 1,
            );
          }

          if (onPeekStart == null) return child;
          // Hold a page down to see the scan it was OCR'd from; release to
          // return to the text. `opaque` keeps the tap-to-show-chrome gesture
          // from firing when the press turns into a long press.
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPressStart: (_) => onPeekStart!(),
            onLongPressEnd: (_) => onPeekEnd?.call(),
            onLongPressCancel: () => onPeekEnd?.call(),
            child: child,
          );
        },
      ),
    );
  }
}

class _PageContent extends StatelessWidget {
  final String text;
  final ReaderSettings settings;
  final int pageNumber;

  const _PageContent({
    required this.text,
    required this.settings,
    required this.pageNumber,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Text(
                text,
                style: TextStyle(
                  fontFamily: settings.fontFamily,
                  fontSize: settings.fontSize,
                  height: settings.lineSpacing,
                  color: theme.colorScheme.onSurface,
                ),
                textAlign: TextAlign.justify,
                textDirection: TextDirection.rtl,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              '$pageNumber',
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 12,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Floating quick-settings sheet: theme, page direction, night filter.
class _QuickSettingsSheet extends ConsumerWidget {
  final bool showTextSettings;

  const _QuickSettingsSheet({this.showTextSettings = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(readerSettingsProvider);
    final theme = Theme.of(context);

    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        padding: const EdgeInsets.fromLTRB(22, 12, 22, 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                'إعدادات القراءة',
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),

              // ── Colour scheme ──
              const _SettingRow(
                label: 'وضع القراءة',
                value: '',
                icon: Icons.palette_outlined,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  for (final p in ReaderPalette.values)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: _PaletteSwatch(
                          palette: p,
                          selected: settings.palette == p,
                          onTap: () => ref
                              .read(readerSettingsProvider.notifier)
                              .updatePalette(p),
                        ),
                      ),
                    ),
                ],
              ),

              const SizedBox(height: 14),

              // ── Brightness (page dimming) ──
              _SettingRow(
                label: 'السطوع',
                value: '${(settings.brightness * 100).round()}%',
                icon: Icons.brightness_6_outlined,
              ),
              Row(
                children: [
                  Icon(
                    Icons.brightness_low,
                    size: 17,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                  Expanded(
                    child: Slider(
                      value: settings.brightness,
                      min: 0.35,
                      max: 1.0,
                      onChanged: (v) => ref
                          .read(readerSettingsProvider.notifier)
                          .updateBrightness(v),
                    ),
                  ),
                  Icon(
                    Icons.brightness_high,
                    size: 17,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ],
              ),

              const SizedBox(height: 18),
              const OrnamentalDivider(),
              const SizedBox(height: 14),

              if (showTextSettings) ...[
                _SettingRow(
                  label: 'حجم الخط',
                  value: settings.fontSize.round().toString(),
                  icon: Icons.text_fields,
                ),
                Slider(
                  value: settings.fontSize,
                  min: 12,
                  max: 28,
                  divisions: 16,
                  onChanged: (v) => ref
                      .read(readerSettingsProvider.notifier)
                      .updateFontSize(v),
                ),
                const SizedBox(height: 8),
                _SettingRow(
                  label: 'تباعد الأسطر',
                  value: settings.lineSpacing.toStringAsFixed(1),
                  icon: Icons.format_line_spacing,
                ),
                Slider(
                  value: settings.lineSpacing,
                  min: 1.0,
                  max: 3.0,
                  divisions: 20,
                  onChanged: (v) => ref
                      .read(readerSettingsProvider.notifier)
                      .updateLineSpacing(v),
                ),
                const SizedBox(height: 8),
                const _SettingRow(
                  label: 'نوع الخط',
                  value: '',
                  icon: Icons.font_download_outlined,
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    _FontChip(
                      label: 'أميري',
                      family: 'Amiri',
                      selected: settings.fontFamily == 'Amiri',
                      onSelect: (fam) => ref
                          .read(readerSettingsProvider.notifier)
                          .updateFontFamily(fam),
                    ),
                    _FontChip(
                      label: 'القاهرة',
                      family: 'Cairo',
                      selected: settings.fontFamily == 'Cairo',
                      onSelect: (fam) => ref
                          .read(readerSettingsProvider.notifier)
                          .updateFontFamily(fam),
                    ),
                    _FontChip(
                      label: 'ريم كوفي',
                      family: 'ReemKufi',
                      selected: settings.fontFamily == 'ReemKufi',
                      onSelect: (fam) => ref
                          .read(readerSettingsProvider.notifier)
                          .updateFontFamily(fam),
                    ),
                  ],
                ),
              ] else
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'هذه نسخة مصوّرة من الطبعة الأصلية، فلا يمكن تغيير الخط. '
                          'اسحب الصفحة لتقليبها، أو قرّب بإصبعين للتكبير.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),

              const SizedBox(height: 18),
              const OrnamentalDivider(),
              const SizedBox(height: 10),

              const _SettingRow(
                label: 'اتجاه تصفح الصفحات',
                value: '',
                icon: Icons.compare_arrows,
              ),
              const SizedBox(height: 8),
              SegmentedButton<ReadingAxis>(
                segments: const [
                  ButtonSegment(
                    value: ReadingAxis.horizontal,
                    label: Text('أفقي'),
                    icon: Icon(Icons.swap_horiz, size: 18),
                  ),
                  ButtonSegment(
                    value: ReadingAxis.vertical,
                    label: Text('رأسي'),
                    icon: Icon(Icons.swap_vert, size: 18),
                  ),
                ],
                selected: {settings.readingAxis},
                onSelectionChanged: (selection) => ref
                    .read(readerSettingsProvider.notifier)
                    .updateReadingAxis(selection.first),
                showSelectedIcon: false,
              ),

              const SizedBox(height: 8),
              _ToggleRow(
                label: 'الوضع الليلي للتطبيق',
                icon: Icons.nights_stay_outlined,
                value: settings.nightMode,
                onChanged: () => ref
                    .read(readerSettingsProvider.notifier)
                    .toggleNightMode(),
              ),
              _ToggleRow(
                label: 'اهتزاز عند القلب',
                icon: Icons.vibration_outlined,
                value: settings.hapticFeedback,
                onChanged: () => ref
                    .read(readerSettingsProvider.notifier)
                    .toggleHapticFeedback(),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tappable theme chip that previews its own paper/ink pair.
class _PaletteSwatch extends StatelessWidget {
  final ReaderPalette palette;
  final bool selected;
  final VoidCallback onTap;

  const _PaletteSwatch({
    required this.palette,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        decoration: BoxDecoration(
          color: palette.paper,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? const Color(AppConstants.goldHex)
                : Colors.black.withValues(alpha: 0.15),
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Text(
              'أبجد',
              style: TextStyle(
                fontFamily: 'Amiri',
                fontSize: 17,
                color: palette.ink,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              palette.label,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: palette.ink.withValues(alpha: 0.75),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _SettingRow({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: const Color(AppConstants.goldHex)),
        const SizedBox(width: 12),
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const Spacer(),
        if (value.isNotEmpty)
          Text(value, style: Theme.of(context).textTheme.labelMedium),
      ],
    );
  }
}

class _FontChip extends StatelessWidget {
  final String label;
  final String family;
  final bool selected;
  final ValueChanged<String> onSelect;

  const _FontChip({
    required this.label,
    required this.family,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label, style: TextStyle(fontFamily: family)),
      selected: selected,
      onSelected: (_) => onSelect(family),
      selectedColor: const Color(AppConstants.goldHex).withValues(alpha: 0.3),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool value;
  final VoidCallback onChanged;

  const _ToggleRow({
    required this.label,
    required this.icon,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: const Color(AppConstants.goldHex)),
      title: Text(label, style: Theme.of(context).textTheme.labelLarge),
      trailing: Switch(
        value: value,
        onChanged: (_) => onChanged(),
        activeTrackColor:
            const Color(AppConstants.goldHex).withValues(alpha: 0.4),
        activeThumbColor: const Color(AppConstants.goldHex),
      ),
    );
  }
}
