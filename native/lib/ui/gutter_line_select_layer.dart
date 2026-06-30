// gutter_line_select_layer.dart — long-press-drag the right gutter to select &
// copy the VISIBLE lines verbatim (#962).
//
// SCROLL-SAFE: selection starts on a LONG-PRESS (hold) in the right strip, then
// drag. A plain SWIPE — anywhere, including the strip — is NOT claimed, so it
// falls through to the gesture router and SCROLLS normally (the gutter must never
// eat scroll). Quick tap also falls through (raise keyboard).
//
// VISIBLE-VERBATIM: the drag maps a touch Y to VIEWPORT rows (row 0 = top
// visible). The parent copies those exact viewport rows via PointTag.viewport —
// "copy the visible lines I dragged over", with NO scrollback/offset/selection
// machinery (the source of the copy saga). A translucent FULL-WIDTH band over the
// dragged rows is the on-screen highlight (the parent's terminal is untouched).

import 'package:flutter/material.dart';

/// Default width (logical px) of the right-edge long-press strip.
const double kGutterSelectStripWidth = 28.0;

/// Right-edge gutter long-press-to-select surface (#962). On long-press-drag it
/// paints a full-width band over the dragged VIEWPORT rows and, on release,
/// reports the inclusive row range (top ≤ bottom, 0-based from the top of the
/// visible viewport) via [onCommitRows]. A plain swipe is ignored (scrolls).
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

  /// On long-press-drag release: inclusive VIEWPORT row range (top ≤ bottom).
  final void Function(int topViewRow, int bottomViewRow) onCommitRows;

  @override
  State<GutterLineSelectLayer> createState() => _GutterLineSelectLayerState();
}

class _GutterLineSelectLayerState extends State<GutterLineSelectLayer> {
  int? _startRow;
  int? _curRow;

  int _rowFromY(double localY) {
    if (widget.cellHeight <= 0 || widget.rows <= 0) return 0;
    final r = ((localY - widget.padding) / widget.cellHeight).floor();
    return r.clamp(0, widget.rows - 1);
  }

  void _onStart(LongPressStartDetails d) {
    final r = _rowFromY(d.localPosition.dy);
    setState(() {
      _startRow = r;
      _curRow = r;
    });
  }

  void _onMove(LongPressMoveUpdateDetails d) {
    final r = _rowFromY(d.localPosition.dy);
    if (r == _curRow) return;
    setState(() => _curRow = r);
  }

  void _onEnd(LongPressEndDetails d) {
    final s = _startRow;
    final c = _curRow;
    setState(() {
      _startRow = null;
      _curRow = null;
    });
    if (s == null || c == null) return;
    widget.onCommitRows(s < c ? s : c, s < c ? c : s);
  }

  void _onCancel() {
    if (_startRow == null && _curRow == null) return;
    setState(() {
      _startRow = null;
      _curRow = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = _startRow;
    final c = _curRow;
    final dragging = s != null && c != null;
    return Stack(
      children: [
        // Full-width highlight band over the dragged viewport rows (visual only).
        if (dragging) _band(s, c),
        // Long-press capture strip on the right edge. translucent + only
        // long-press handlers → a plain swipe/tap is NOT claimed and scrolls.
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: widget.stripWidth,
          child: GestureDetector(
            key: const Key('gutter-line-select'),
            behavior: HitTestBehavior.translucent,
            onLongPressStart: _onStart,
            onLongPressMoveUpdate: _onMove,
            onLongPressEnd: _onEnd,
            onLongPressCancel: _onCancel,
            child: const SizedBox.expand(),
          ),
        ),
      ],
    );
  }

  Widget _band(int startView, int curView) {
    final topView = startView < curView ? startView : curView;
    final bottomView = startView < curView ? curView : startView;
    final top = widget.padding + topView * widget.cellHeight;
    final height = (bottomView - topView + 1) * widget.cellHeight;
    return Positioned(
      left: 0,
      right: 0,
      top: top,
      height: height,
      child: IgnorePointer(
        child: ColoredBox(color: widget.color.withValues(alpha: 0.30)),
      ),
    );
  }
}
