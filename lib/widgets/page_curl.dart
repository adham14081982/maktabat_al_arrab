import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A book-like page turn with a lifted, folding edge.
///
/// Why not [PageView]: a sliding PageView always looks like a carousel. Here the
/// outgoing sheet is *peeled* off the leading edge (the left one — Arabic books
/// bind on the right), a shadow follows the curved fold, and the incoming page
/// is already underneath. Dragging is fully interactive; releasing past a third
/// of the width (or flicking) completes the turn.
///
/// Both directions share one geometry: a turn always paints [_from] on top of
/// [_to] and animates `progress` from 0 (fully [_from]) to 1 (fully [_to]).
/// Going *back* simply runs that same animation in reverse, which is exactly
/// what un-turning a physical page looks like.
class PageCurlView extends StatefulWidget {
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final int initialPage;
  final ValueChanged<int>? onPageChanged;

  /// Set to false while the page is magnified, so a drag pans inside the page
  /// instead of turning it.
  final bool enabled;

  /// Controller used by the slider and by "continue reading" restores.
  final PageCurlController? controller;

  /// When false the sheet turns with a straight edge and no bend shading — a
  /// plain slide, for readers who find the 3D curl distracting. Wired to the
  /// "تأثير قلب الصفحات" switch in Settings.
  final bool curl;

  const PageCurlView({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.initialPage = 0,
    this.onPageChanged,
    this.enabled = true,
    this.controller,
    this.curl = true,
  });

  @override
  State<PageCurlView> createState() => _PageCurlViewState();
}

/// Lets the reader jump to a page from outside (slider, restore, bookmarks).
class PageCurlController extends ChangeNotifier {
  _PageCurlViewState? _view;

  int get page => _view?._index ?? 0;

  void jumpToPage(int page) => _view?._jumpTo(page);

  void _attach(_PageCurlViewState view) => _view = view;

  void _detach(_PageCurlViewState view) {
    if (identical(_view, view)) _view = null;
  }
}

class _PageCurlViewState extends State<PageCurlView>
    with SingleTickerProviderStateMixin {
  late int _index = widget.initialPage;

  /// 0 = fully [_from] on screen, 1 = fully [_to].
  double _progress = 0;

  int _from = 0;
  int _to = 0;

  bool _dragging = false;
  int _direction = 0; // +1 next, -1 previous, 0 idle
  double _dragDx = 0;
  double _width = 1;

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  )..addListener(_onTick);

  double _animFrom = 0;
  double _animTo = 0;
  bool _animCommit = false;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    _from = _to = _index.clamp(0, (widget.itemCount - 1).clamp(0, 1 << 30));
    widget.controller?._attach(this);
  }

  @override
  void didUpdateWidget(covariant PageCurlView old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller?._detach(this);
      widget.controller?._attach(this);
    }
    if (_index >= widget.itemCount) {
      _jumpTo(widget.itemCount - 1);
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _anim.dispose();
    super.dispose();
  }

  void _onTick() {
    setState(() {
      _progress = _animFrom + (_animTo - _animFrom) * _anim.value;
    });
    if (_anim.isCompleted && !_finishing) {
      _finishing = true;
      _finishTurn();
      _finishing = false;
    }
  }

  void _finishTurn() {
    if (_animCommit) {
      _index = _direction > 0 ? _to : _from;
      widget.onPageChanged?.call(_index);
    }
    _resetTurn();
  }

  void _resetTurn() {
    setState(() {
      _progress = 0;
      _direction = 0;
      _from = _to = _index;
    });
  }

  void _jumpTo(int page) {
    if (widget.itemCount == 0) return;
    final target = page.clamp(0, widget.itemCount - 1);
    _anim.stop();
    setState(() {
      _index = target;
      _from = _to = target;
      _progress = 0;
      _direction = 0;
    });
    widget.onPageChanged?.call(target);
  }

  /// Prepares a turn in [dir]; returns false at the ends of the book.
  bool _beginTurn(int dir) {
    if (dir > 0) {
      if (_index >= widget.itemCount - 1) return false;
      _from = _index;
      _to = _index + 1;
    } else {
      if (_index <= 0) return false;
      _from = _index - 1;
      _to = _index;
    }
    return true;
  }

  void _onDragStart(DragStartDetails details) {
    // Let a snap animation finish rather than snapping the geometry under the
    // finger, which would make the page jump.
    if (_anim.isAnimating) return;
    _dragging = true;
    _direction = 0;
    _dragDx = 0;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    _dragDx += details.delta.dx;

    if (_direction == 0) {
      if (_dragDx.abs() < 2) return;
      _direction = _dragDx > 0 ? 1 : -1;
      if (!_beginTurn(_direction)) {
        _direction = 0;
        return;
      }
    }

    final p = _direction > 0
        ? _dragDx / _width
        : 1 + _dragDx / _width;
    setState(() => _progress = p.clamp(0.0, 1.0));
  }

  void _onDragEnd(DragEndDetails details) {
    if (!_dragging) return;
    _dragging = false;
    if (_direction == 0) return;

    final vx = details.velocity.pixelsPerSecond.dx;
    final bool commit;
    if (_direction > 0) {
      commit = _progress > 0.30 || vx > 700;
    } else {
      commit = _progress < 0.70 || vx < -700;
    }
    _animateTo(commit ? (_direction > 0 ? 1.0 : 0.0) : (_direction > 0 ? 0.0 : 1.0),
        commit: commit);
  }

  void _animateTo(double target, {required bool commit}) {
    _animCommit = commit;
    _animFrom = _progress;
    _animTo = target;
    _anim.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.itemCount == 0) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        _width = constraints.maxWidth;
        final h = constraints.maxHeight;
        final turning = _direction != 0 && _progress > 0.001;
        final fold = _progress * _width;
        // The sheet bows mid-turn and is perfectly straight at rest, so the
        // clipping edge never nibbles the page while it is just sitting there.
        final bow = widget.curl
            ? 16 * math.sin(math.pi * _progress.clamp(0.0, 1.0))
            : 0.0;
        // How much paper has already flipped over and shows its back. Zero at
        // the start and end of the turn, widest mid-gesture — the same sine
        // that drives the bow, so the two curves stay in step.
        final backW = widget.curl
            ? math.min(fold, 76 * math.sin(math.pi * _progress.clamp(0.0, 1.0)))
            : 0.0;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: widget.enabled ? _onDragStart : null,
          onHorizontalDragUpdate: widget.enabled ? _onDragUpdate : null,
          onHorizontalDragEnd: widget.enabled ? _onDragEnd : null,
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 1) The page revealed underneath.
                if (turning) widget.itemBuilder(context, _to),

                // 2) The shadow the lifted sheet casts on that page. It goes
                //    under the flipped-back strip, otherwise it would darken
                //    the sheet itself instead of the page it floats above.
                if (turning && widget.curl)
                  ClipPath(
                    clipper: _FoldClipper(
                      fold: fold,
                      bow: bow,
                      width: _width,
                      height: h,
                      keepLeft: true,
                    ),
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: _castShadowGradient(fold, _width),
                        ),
                      ),
                    ),
                  ),

                // 3) The *back* of the lifted sheet: a mirror image of the same
                //    page, folded about the crease. This is what turns a clipped
                //    wipe into something the eye reads as a curled page — the
                //    strip left of the fold shows the paper that has already
                //    flipped over, seen from behind.
                if (turning && widget.curl && backW > 0.5)
                  Positioned(
                    left: fold - backW,
                    top: 0,
                    width: backW,
                    height: h,
                    child: ClipRect(
                      child: Transform(
                        // Mirror about x = fold, i.e. the crease itself.
                        transform: Matrix4.diagonal3Values(-1, 1, 1),
                        origin: Offset(backW, 0),
                        child: OverflowBox(
                          alignment: Alignment.centerRight,
                          maxWidth: _width,
                          minWidth: _width,
                          child: SizedBox(
                            width: _width,
                            height: h,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                widget.itemBuilder(context, _from),
                                // The underside is in shade, deepest at the
                                // crease where the paper bends hardest.
                                const IgnorePointer(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.centerLeft,
                                        end: Alignment.centerRight,
                                        colors: [
                                          Color(0x30000000),
                                          Color(0x8F000000),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                // 4) The part of the outgoing sheet still lying flat, clipped
                //    to the right of the fold and shaded along the crease.
                ClipPath(
                  clipper: _FoldClipper(
                    fold: fold,
                    bow: bow,
                    width: _width,
                    height: h,
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      widget.itemBuilder(context, _from),
                      if (turning && widget.curl)
                        IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: _bendGradient(fold, _width),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Shading on the outgoing sheet, hugging the fold.
  ///
  /// Three stops, not two, because a curled sheet does three things at once:
  /// the physical edge catches the light (a thin bright line), the paper then
  /// falls away from the light source (dark), and finally it flattens out
  /// again toward the spine (transparent). Without the bright edge the turn
  /// reads as a horizontal wipe rather than a lifted page.
  LinearGradient _bendGradient(double fold, double w) {
    final stops = _safeStops3(
      fold / w,
      (fold + 5) / w,
      (fold + 64) / w,
    );
    return LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: const [
        Color(0x8CFFFFFF), // specular edge of the lifted paper
        Color(0x7A000000), // the sheet bending away from the light
        Color(0x00000000), // flattening out toward the spine
      ],
      stops: stops,
    );
  }

  /// Shadow the lifted sheet casts on the revealed page.
  ///
  /// Wider than the flipped-back strip so a band of it stays visible to the
  /// left of the sheet; the strip itself covers the rest.
  LinearGradient _castShadowGradient(double fold, double w) {
    final stops = _safeStops((fold - 110) / w, fold / w);
    return LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: const [Color(0x00000000), Color(0x99000000)],
      stops: stops,
    );
  }

  /// Three strictly-increasing stops inside 0..1.
  static List<double> _safeStops3(double a, double b, double c) {
    var s1 = a.clamp(0.0, 0.998);
    var s2 = b.clamp(0.0, 0.999);
    var s3 = c.clamp(0.0, 1.0);
    if (s2 <= s1) s2 = (s1 + 0.001).clamp(0.0, 0.999);
    if (s3 <= s2) s3 = (s2 + 0.001).clamp(0.0, 1.0);
    if (s3 <= s2) s2 = (s3 - 0.001).clamp(0.0, 0.998);
    if (s2 <= s1) s1 = (s2 - 0.001).clamp(0.0, 0.997);
    return [s1, s2, s3];
  }

  /// Keeps the two stops inside 0..1 and strictly increasing, which the
  /// gradient engine requires at the very ends of a turn.
  static List<double> _safeStops(double a, double b) {
    var s1 = a.clamp(0.0, 1.0);
    var s2 = b.clamp(0.0, 1.0);
    if (s2 <= s1) s2 = (s1 + 0.002).clamp(0.0, 1.0);
    if (s2 <= s1) s1 = (s2 - 0.002).clamp(0.0, 1.0);
    return [s1, s2];
  }
}

/// Keeps the region right (or left) of a gently curved fold line.
///
/// The curve is what separates "a page being peeled" from "a slider handle":
/// the sheet bends, so the fold bows by a few pixels along its height.
class _FoldClipper extends CustomClipper<Path> {
  final double fold;
  final double bow;
  final double width;
  final double height;
  final bool keepLeft;

  const _FoldClipper({
    required this.fold,
    required this.bow,
    required this.width,
    required this.height,
    this.keepLeft = false,
  });

  @override
  Path getClip(Size size) {
    final path = Path();
    if (keepLeft) {
      path.moveTo(0, 0);
      path.lineTo(fold, 0);
    } else {
      path.moveTo(fold, 0);
    }
    path.cubicTo(
      fold + bow, height * 0.33,
      fold - bow, height * 0.66,
      fold, height,
    );
    if (keepLeft) {
      path.lineTo(0, height);
    } else {
      path.lineTo(width, height);
      path.lineTo(width, 0);
    }
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant _FoldClipper old) =>
      old.fold != fold ||
      old.bow != bow ||
      old.width != width ||
      old.height != height;
}
