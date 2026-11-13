import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../core/theme/app_theme.dart';
import '../core/services/library_source.dart';

/// Decorative antique frame widget with gold corners
class AntiqueFrame extends StatelessWidget {
  final Widget child;
  final Color? borderColor;
  final double borderWidth;

  const AntiqueFrame({
    super.key,
    required this.child,
    this.borderColor,
    this.borderWidth = 2,
  });

  @override
  Widget build(BuildContext context) {
    final gold = borderColor ?? const Color(0xFFC9A24B);

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: gold, width: borderWidth),
        borderRadius: BorderRadius.circular(4),
        boxShadow: [
          BoxShadow(
            color: gold.withValues(alpha: 0.2),
            blurRadius: 4,
            spreadRadius: 1,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: Stack(
          children: [
            child,
            // Corner decorations
            Positioned(
              top: 0,
              right: 0,
              child: CustomPaint(
                size: const Size(12, 12),
                painter: _CornerPainter(gold),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              child: CustomPaint(
                size: const Size(12, 12),
                painter: _CornerPainter(gold),
              ),
            ),
            Positioned(
              bottom: 0,
              right: 0,
              child: CustomPaint(
                size: const Size(12, 12),
                painter: _CornerPainter(gold),
              ),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              child: CustomPaint(
                size: const Size(12, 12),
                painter: _CornerPainter(gold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CornerPainter extends CustomPainter {
  final Color color;
  _CornerPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    // Draw L-shaped corner ornament
    canvas.drawLine(Offset(0, size.height), const Offset(0, 0), paint);
    canvas.drawLine(const Offset(0, 0), Offset(size.width, 0), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Islamic geometric divider
class OrnamentalDivider extends StatelessWidget {
  final Color? color;
  final double height;

  const OrnamentalDivider({
    super.key,
    this.color,
    this.height = 20,
  });

  @override
  Widget build(BuildContext context) {
    final gold = color ?? const Color(0xFFC9A24B);

    return SizedBox(
      height: height,
      child: CustomPaint(
        size: Size.infinite,
        painter: _DividerPainter(gold),
      ),
    );
  }
}

class _DividerPainter extends CustomPainter {
  final Color color;
  _DividerPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    final centerY = size.height / 2;
    final centerX = size.width / 2;

    // Central diamond
    const diamondSize = 6.0;
    final path = Path()
      ..moveTo(centerX, centerY - diamondSize)
      ..lineTo(centerX + diamondSize, centerY)
      ..lineTo(centerX, centerY + diamondSize)
      ..lineTo(centerX - diamondSize, centerY)
      ..close();
    canvas.drawPath(path, paint);

    // Lines on both sides
    final lineLength = (size.width / 2) - diamondSize - 10;
    if (lineLength > 0) {
      canvas.drawLine(
        Offset(centerX + diamondSize + 5, centerY),
        Offset(centerX + diamondSize + 5 + lineLength, centerY),
        paint,
      );
      canvas.drawLine(
        Offset(centerX - diamondSize - 5, centerY),
        Offset(centerX - diamondSize - 5 - lineLength, centerY),
        paint,
      );
    }

    // Small circles at the ends
    for (final dx in [-1, 1]) {
      canvas.drawCircle(
        Offset(centerX + dx * (diamondSize + 5 + lineLength), centerY),
        2,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Section header with decorative styling
class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Color? accentColor;

  /// Optional action aligned with the title (usually a "عرض الكل" button).
  /// Keeping it on the title line — instead of in its own row elsewhere —
  /// saves a whole row of vertical space per section.
  final Widget? trailing;

  /// Set false to drop the tall ornamental divider where the surrounding
  /// layout already provides separation (compact home shelves).
  final bool showDivider;

  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.accentColor,
    this.trailing,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = accentColor ?? const Color(0xFFC9A24B);
    // Darkened/lightened so the heading meets contrast on both themes.
    final accent = AppTheme.readableAccent(context, base);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 4,
                height: 24,
                decoration: BoxDecoration(
                  color: base,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(color: accent),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.78),
                ),
              ),
            ),
          ],
          if (showDivider) ...[
            const SizedBox(height: 4),
            const OrnamentalDivider(height: 18),
          ],
        ],
      ),
    );
  }
}

/// Book cover widget with leather frame and shadow
/// Book cover with a fixed 2:3 aspect ratio, real cover artwork, a shimmer
/// placeholder while the asset decodes, and an elegant fallback tile.
///
/// The app ships the original cover art for every volume, so the tile is only
/// a safety net for a missing or unreadable asset.
class BookCover extends StatelessWidget {
  final String? coverPath;
  final String title;
  final double width;
  final String? heroTag;

  /// Print the title under the artwork. Shelves enable this because many
  /// volumes share near-identical cover designs and the title is the only
  /// way to tell them apart at a glance.
  final bool showLabel;

  const BookCover({
    super.key,
    required this.coverPath,
    required this.title,
    this.width = 120,
    this.heroTag,
    this.showLabel = false,
  });

  /// Standard trade-paperback proportion.
  static const double coverAspect = 2 / 3;

  static const Color _gold = Color(0xFFC9A24B);
  static const Color _leather = Color(0xFF4A2C1A);

  @override
  Widget build(BuildContext context) {
    Widget art = SizedBox(
      width: width,
      child: AspectRatio(aspectRatio: coverAspect, child: _buildArt(context)),
    );

    if (heroTag != null) {
      art = Hero(tag: heroTag!, child: art);
    }

    if (!showLabel) return art;

    return SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          art,
          const SizedBox(height: 6),
          Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 11,
              height: 1.25,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildArt(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 10,
            offset: const Offset(2, 5),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (coverPath != null)
              Image(
                // library.json stores paths relative to the library root
                // ("covers/book_000.webp"). LibrarySource resolves that root,
                // whether it is the asset bundle or the imported folder.
                image: LibrarySource.image(coverPath!),
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                // Shimmer until the first frame of the asset is decoded.
                frameBuilder: (context, child, frame, wasSyncLoaded) {
                  if (wasSyncLoaded || frame != null) return child;
                  return _buildShimmer();
                },
                errorBuilder: (_, __, ___) => _buildFallback(context),
              )
            else
              _buildFallback(context),

            // Thin gold frame sits above the artwork.
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _gold.withValues(alpha: 0.7), width: 1.2),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShimmer() {
    return Shimmer.fromColors(
      baseColor: _leather,
      highlightColor: const Color(0xFF7A5238),
      child: Container(color: _leather),
    );
  }

  Widget _buildFallback(BuildContext context) {
    return Container(
      color: _leather,
      padding: const EdgeInsets.all(10),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.menu_book, color: _gold, size: 30),
          const SizedBox(height: 8),
          Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Amiri',
              fontSize: 12,
              color: Color(0xFFF3E7CF),
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

/// Empty state widget with antique styling
class EmptyState extends StatelessWidget {
  final String message;
  final IconData icon;

  const EmptyState({
    super.key,
    required this.message,
    this.icon = Icons.menu_book_outlined,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const gold = Color(0xFFC9A24B);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: gold.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            const OrnamentalDivider(),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Loading indicator with antique styling
class AntiqueLoader extends StatelessWidget {
  const AntiqueLoader({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: CircularProgressIndicator(
        color: Color(0xFFC9A24B),
        strokeWidth: 2,
      ),
    );
  }
}
