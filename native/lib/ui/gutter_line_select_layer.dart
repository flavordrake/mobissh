// gutter_line_select_layer.dart — long-press the right gutter to start a line
// selection, then drag up/down to adjust it; copies the VISIBLE lines verbatim
// (#962).
//
// SCROLL-SAFE: the selection ANCHOR is a LONG-PRESS in the right strip. A plain
// swipe is not a long-press, so it's never claimed → it scrolls. Once a
// long-press has started, a passive full-area [Listener] tracks raw pointer
// moves to EXTEND the range (up/down). Using a Listener for the move — instead
// of onLongPressMoveUpdate — makes "drag to adjust" reliable: it sees every
// pointer move regardless of the gesture arena, and being passive it never
// blocks scrolling when no selection is in progress.
//
// VISIBLE-VERBATIM: rows are VIEWPORT rows (row 0 = top visible). The parent
// copies those exact viewport rows via PointTag.viewport — what's on screen,
// no scrollback/offset machinery. A full-width band highlights the range.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Default width (logical px) of the right-edge long-press anchor strip.
const double kGutterSelectStripWidth = 28.0;

/// Right-edge gutter long-press + drag-to-extend line selection (#962). On
/// release reports the inclusive VIEWPORT row range (top ≤ bottom, 0-based from
/// the top of the visible viewport) via [onCommitRows]. A plain swipe scrolls.
class GutterLineSelectLayer extends StatefulWidget {
  const GutterLineSelectLayer({
    super.key,
    required this.cellHeight,
    required this.rows,
    required this.color,
    required this.onCommitRows,
    this.padding = 4.0,
    this.stripWidth = kGutterSelectStripWidth,
  });

  final double cellHeight;
  final int rows;
  final Color color;
  final double padding;
  final double stripWidth;

  /// On release of a long-press-drag: inclusive VIEWPORT row range (top ≤ bottom).
  final void Function(int topViewRow, int bottomViewRow) onCommitRows;

  @override
  State<GutterLineSelectLayer> createState() => _GutterLineSelectLayerState();
}

class _GutterLineSelectLayerState extends State<GutterLineSelectLayer> {
  int? _anchorRow;
  int? _curRow;
  bool _selecting = false;

  int _rowFromY(double localY) {
    if (widget.cellHeight <= 0 || widget.rows <= 0) return 0;
    final r = ((localY - widget.padding) / widget.cellHeight).floor();
    return r.clamp(0, widget.rows - 1);
  }

  // The long-press in the strip is the deliberate ANCHOR (distinguishes from a
  // scroll swipe). localPosition is strip-relative; the strip spans full height,
  // so dy is the viewport Y.
  void _onLongPressStart(LongPressStartDetails d) {
    final r = _rowFromY(d.localPosition.dy);
    // Haptic: SELECT BEGINS. A crisp tick confirms the gutter grabbed the
    // gesture (vs a scroll swipe) the instant the anchor lands.
    HapticFeedback.selectionClick();
    setState(() {
      _anchorRow = r;
      _curRow = r;
      _selecting = true;
    });
  }

  // Raw pointer moves EXTEND the range — but only while a long-press selection
  // is in progress (so a plain swipe is ignored and scrolls). localPosition is
  // relative to the full-area Listener (origin = terminal top-left) = viewport Y.
  void _onPointerMove(PointerMoveEvent e) {
    if (!_selecting) return;
    final r = _rowFromY(e.localPosition.dy);
    if (r == _curRow) return;
    setState(() => _curRow = r);
  }

  void _finish() {
    if (!_selecting) return;
    final a = _anchorRow;
    final c = _curRow;
    setState(() {
      _selecting = false;
      _anchorRow = null;
      _curRow = null;
    });
    if (a == null || c == null) return;
    // Haptic: SELECT ENDS (committed → copied). A heavier tick than the begin
    // click marks "captured", distinct from the engage tick.
    HapticFeedback.mediumImpact();
    widget.onCommitRows(a < c ? a : c, a < c ? c : a);
  }

  void _onPointerUp(PointerUpEvent e) => _finish();
  void _onPointerCancel(PointerCancelEvent e) => _finish();

  @override
  Widget build(BuildContext context) {
    final a = _anchorRow;
    final c = _curRow;
    final showing = _selecting && a != null && c != null;
    return Listener(
      // translucent: observe pointer moves over the whole terminal WITHOUT
      // blocking the gesture router below (scroll still works).
      behavior: HitTestBehavior.translucent,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: Stack(
        children: [
          if (showing) _band(a, c),
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            width: widget.stripWidth,
            child: GestureDetector(
              key: const Key('gutter-line-select'),
              behavior: HitTestBehavior.translucent,
              onLongPressStart: _onLongPressStart,
              // Backups: if the gesture ends via the long-press recognizer
              // rather than a raw up (e.g. cancel), still finish.
              onLongPressEnd: (_) => _finish(),
              onLongPressCancel: _finish,
              child: const SizedBox.expand(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _band(int aRow, int cRow) {
    final topView = aRow < cRow ? aRow : cRow;
    final bottomView = aRow < cRow ? cRow : aRow;
    final top = widget.padding + topView * widget.cellHeight;
    final height = (bottomView - topView + 1) * widget.cellHeight;
    return Positioned(
      left: 0,
      right: 0,
      top: top,
      height: height,
      child: IgnorePointer(
        // Higher-contrast feedback over the terminal: a stronger fill PLUS a
        // crisp full-opacity border box around the selected rows, so the range
        // reads clearly over arbitrary terminal content (text still shows
        // through the translucent fill).
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: 0.42),
            border: Border.all(color: widget.color, width: 2),
          ),
        ),
      ),
    );
  }
}
