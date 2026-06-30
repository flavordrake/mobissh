// gutter_line_select_layer.dart — drag-to-select-WHOLE-LINES in the right gutter
// (#962).
//
// PAINT-FREE by design (owner: "why are we even doing screen repaint at this
// point?"). The terminal text is NEVER repainted for selection — the ONLY
// feedback is a translucent band drawn in THIS overlay's own right-edge strip
// (it repaints itself, not the terminal). On release the parent copies the
// dragged WHOLE LINES directly from the buffer (no `controller.selection`, no
// flterm selection repaint). Line granularity removes the sub-cell precision
// that drove the selection/repaint saga (#705/#706/#760/#828/#930/#962).
//
// Gesture model: claims VERTICAL drags in the right strip only. A TAP (no
// movement) is NOT claimed (HitTestBehavior.translucent) so it falls through to
// the gesture router below (raise keyboard). Detection marks render ABOVE this
// layer, so a tap on a mark fires its action while a drag here selects lines.

import 'package:flutter/material.dart';

/// Default width (logical px) of the right-edge drag strip — a comfortable drag
/// target. The band is shown only DURING a drag, so it costs no permanent
/// terminal real estate.
const double kGutterSelectStripWidth = 28.0;

/// Right-edge gutter line-select surface (#962). Reports the inclusive VIEWPORT
/// row range on release via [onCommitRows] (top ≤ bottom, 0-based from the top of
/// the viewport). Draws its own band while dragging (no terminal repaint).
class GutterLineSelectLayer extends StatefulWidget {
  const GutterLineSelectLayer({
    super.key,
    required this.cellHeight,
    required this.rows,
    required this.color,
    required this.onSelectRows,
    required this.onCommitRows,
    this.padding = 4.0,
    this.stripWidth = kGutterSelectStripWidth,
  });

  /// The REAL flterm cell height — maps a touch Y to a viewport row exactly as
  /// the painter laid the grid out.
  final double cellHeight;

  /// Number of visible viewport rows, for clamping the dragged row.
  final int rows;

  /// Band colour (the session selection colour).
  final Color color;

  /// The terminal-view padding the grid is offset by.
  final double padding;

  /// Width of the right-edge drag strip.
  final double stripWidth;

  /// Live during the drag (start + each row change): the current inclusive
  /// VIEWPORT row range, so the parent paints the on-screen selection highlight
  /// as the finger moves (the owner needs to SEE what's selected).
  final void Function(int topViewRow, int bottomViewRow) onSelectRows;

  /// On release: the final inclusive VIEWPORT row range (top ≤ bottom).
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

  void _onStart(DragStartDetails d) {
    final r = _rowFromY(d.localPosition.dy);
    setState(() {
      _startRow = r;
      _curRow = r;
    });
    widget.onSelectRows(r, r);
  }

  void _onUpdate(DragUpdateDetails d) {
    final r = _rowFromY(d.localPosition.dy);
    if (r == _curRow) return;
    setState(() => _curRow = r);
    final s = _startRow ?? r;
    widget.onSelectRows(s < r ? s : r, s < r ? r : s);
  }

  void _onEnd(DragEndDetails d) {
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
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: widget.stripWidth,
          child: GestureDetector(
            key: const Key('gutter-line-select'),
            behavior: HitTestBehavior.translucent,
            onVerticalDragStart: _onStart,
            onVerticalDragUpdate: _onUpdate,
            onVerticalDragEnd: _onEnd,
            onVerticalDragCancel: _onCancel,
            child: dragging ? _band(s, c) : const SizedBox.expand(),
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
    return Stack(
      children: [
        Positioned.fill(
          child: ColoredBox(color: widget.color.withValues(alpha: 0.06)),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: top,
          height: height,
          child: ColoredBox(color: widget.color.withValues(alpha: 0.34)),
        ),
      ],
    );
  }
}
