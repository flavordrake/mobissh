import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:libghostty/libghostty.dart' show MouseAction, MouseTracking;
import 'package:meta/meta.dart';

import '../foundation.dart';
import 'terminal_raw_gesture_detector.dart';
import 'terminal_view_binding.dart';

/// Interprets gestures as terminal actions: selection, mouse tracking
/// reports, and focus requests.
///
/// Reports all gestures to [TerminalViewBinding] which handles
/// snapping, scroll offset, and encoding.
@internal
class TerminalGestureDetector extends StatefulWidget {
  final Widget child;
  final int visibleRows;
  final CellMetrics metrics;
  final TerminalViewBinding binding;
  final TerminalGestureSettings settings;
  final ScrollController? scrollController;

  const TerminalGestureDetector({
    super.key,
    required this.child,
    this.visibleRows = 0,
    required this.metrics,
    required this.binding,
    this.scrollController,
    this.settings = const TerminalGestureSettings(),
  });

  @override
  State<TerminalGestureDetector> createState() =>
      _TerminalGestureDetectorState();
}

class _DragState {
  int anchorRow;
  final int anchorCol;
  final TerminalSelectionMode baseMode;
  int? lastRow;
  int? lastCol;
  TerminalSelectionMode? lastEmittedMode;

  _DragState(this.anchorRow, this.anchorCol, this.baseMode);
}

class _TerminalGestureDetectorState extends State<TerminalGestureDetector> {
  _DragState? _drag;
  Timer? _autoScrollTimer;
  var _autoScrollDelta = 0;

  TerminalViewBinding get _binding => widget.binding;

  @override
  Widget build(BuildContext context) {
    final tracked = _binding.mouseTracking != MouseTracking.none;

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: tracked ? _handleTrackedDown : null,
      onPointerMove: tracked ? _handleTrackedMove : null,
      onPointerUp: tracked ? _handleTrackedUp : null,
      child: TerminalRawGestureDetector(
        onSingleTapDown: _handleSingleTapDown,
        onDoubleTapDown: _handleDoubleTapDown,
        onTripleTapDown: _handleTripleTapDown,
        onDragStart: _handleDragStart,
        onDragUpdate: _handleDragUpdate,
        onDragEnd: _handleDragEnd,
        onLongPressStart: _handleLongPressStart,
        onLongPressMoveUpdate: _handleLongPressMoveUpdate,
        onLongPressUp: _handleLongPressUp,
        child: widget.child,
      ),
    );
  }

  @override
  void didUpdateWidget(TerminalGestureDetector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.metrics != oldWidget.metrics ||
        widget.binding != oldWidget.binding) {
      _binding.clearSelection();
      if (_drag != null) _endDrag();
    }
  }

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    super.dispose();
  }

  void _autoScrollTick(Timer timer) {
    final scrollController = widget.scrollController;
    if (scrollController == null || !scrollController.hasClients) return;

    final drag = _drag;
    if (drag == null) {
      _stopAutoScroll();
      return;
    }

    final position = scrollController.position;
    final pixelDelta = _autoScrollDelta > 0
        ? widget.metrics.cellHeight
        : -widget.metrics.cellHeight;
    final target = (position.pixels + pixelDelta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );

    if (target == position.pixels) return;
    scrollController.jumpTo(target);

    drag.anchorRow += _autoScrollDelta < 0 ? 1 : -1;

    if (drag.lastRow != null && drag.lastCol != null) {
      _binding.updateSelection(
        drag.anchorRow,
        drag.anchorCol,
        drag.lastRow!,
        drag.lastCol!,
        _isBlockModifierPressed() ? .block : drag.baseMode,
      );
    }
  }

  void _endDrag() {
    _stopAutoScroll();
    _drag = null;
  }

  void _handleDoubleTapDown(TapDownDetails details) {
    _binding.requestFocus();
    if (_isMouseTracked(HardwareKeyboard.instance.isShiftPressed)) return;

    if (_isEnabled(.word)) {
      final (row, col) = widget.metrics.cellAt(details.localPosition);
      _binding.selectWord(row, col);
      return;
    }
    _binding.clearSelection();
  }

  void _handleDragEnd() => _endDrag();

  void _handleDragStart(DragStartDetails details) {
    _binding.requestFocus();
    if (_isMouseTracked(HardwareKeyboard.instance.isShiftPressed)) return;
    if (!_isEnabled(.drag)) return;

    _binding.clearSelection();
    _startDrag(details.localPosition);
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    if (_isMouseTracked(HardwareKeyboard.instance.isShiftPressed)) return;
    if (_drag != null) _updateDrag(details.localPosition);
  }

  void _handleLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    if (_drag != null) _updateDrag(details.localPosition);
  }

  void _handleLongPressStart(LongPressStartDetails details) {
    _binding.requestFocus();
    if (!_isEnabled(.longPress)) return;
    _binding.clearSelection();
    _startDrag(
      details.localPosition,
      mode: widget.settings.longPressSelectionMode,
    );
  }

  void _handleLongPressUp() => _endDrag();

  void _handleSingleTapDown(TapDownDetails details) {
    _binding.requestFocus();
    if (_isMouseTracked(HardwareKeyboard.instance.isShiftPressed)) return;
    _binding.clearSelection();
  }

  void _handleTrackedDown(PointerDownEvent event) {
    final shift =
        event.buttons & kSecondaryButton != 0 ||
        HardwareKeyboard.instance.isShiftPressed;
    if (!_isMouseTracked(shift)) return;
    _sendMouseEvent(.press, event.localPosition);
  }

  void _handleTrackedMove(PointerMoveEvent event) {
    if (!_isMouseTracked(HardwareKeyboard.instance.isShiftPressed)) return;
    _sendMouseEvent(.motion, event.localPosition);
  }

  void _handleTrackedUp(PointerUpEvent event) {
    if (!_isMouseTracked(HardwareKeyboard.instance.isShiftPressed)) return;
    _sendMouseEvent(.release, event.localPosition);
  }

  void _handleTripleTapDown(TapDownDetails details) {
    _binding.requestFocus();
    if (_isMouseTracked(HardwareKeyboard.instance.isShiftPressed)) return;

    if (_isEnabled(.line)) {
      final (row, _) = widget.metrics.cellAt(details.localPosition);
      _binding.selectLine(row, widget.settings.lineSelectMode);
      return;
    }
    _binding.clearSelection();
  }

  bool _isBlockModifierPressed() {
    final modifier = widget.settings.blockSelectionModifier;
    if (modifier == null) return false;
    final keyboard = HardwareKeyboard.instance;
    final mods = _binding.virtualMods;
    return switch (modifier) {
      .alt => keyboard.isAltPressed || mods.hasAlt,
      .meta => keyboard.isMetaPressed || mods.hasSuper,
      .shift => keyboard.isShiftPressed || mods.hasShift,
      .control => keyboard.isControlPressed || mods.hasCtrl,
    };
  }

  bool _isEnabled(SelectionGesture gesture) {
    return widget.settings.enabledSelections.contains(gesture);
  }

  bool _isMouseTracked(bool shift) {
    return _binding.mouseTracking != .none &&
        !shift &&
        !_binding.virtualMods.hasShift;
  }

  void _sendMouseEvent(MouseAction action, Offset position) {
    _binding.handleMouseEvent((
      action: action,
      button: .left,
      pixelX: position.dx,
      pixelY: position.dy,
    ));
  }

  void _startAutoScroll(int delta) {
    _autoScrollDelta = delta;
    if (_autoScrollTimer != null) return;
    _autoScrollTimer = Timer.periodic(
      const Duration(milliseconds: 50),
      _autoScrollTick,
    );
  }

  void _startDrag(Offset position, {TerminalSelectionMode mode = .normal}) {
    final (row, col) = widget.metrics.cellAt(position);
    _drag = _DragState(row, col, mode);
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _autoScrollDelta = 0;
  }

  void _updateDrag(Offset position) {
    final drag = _drag;
    if (drag == null) return;
    final (row, col) = widget.metrics.cellAt(position);

    final visibleRows = widget.visibleRows;
    if (visibleRows > 0) {
      if (row < 0) {
        _startAutoScroll(row);
      } else if (row >= visibleRows) {
        _startAutoScroll(row - visibleRows + 1);
      } else {
        _stopAutoScroll();
      }
    }

    final clampedRow = visibleRows > 0 ? row.clamp(0, visibleRows - 1) : row;
    final mode = _isBlockModifierPressed()
        ? TerminalSelectionMode.block
        : drag.baseMode;
    if (clampedRow == drag.lastRow &&
        col == drag.lastCol &&
        mode == drag.lastEmittedMode) {
      return;
    }
    drag.lastRow = clampedRow;
    drag.lastCol = col;
    drag.lastEmittedMode = mode;

    _binding.updateSelection(
      drag.anchorRow,
      drag.anchorCol,
      clampedRow,
      col,
      mode,
    );
  }
}
