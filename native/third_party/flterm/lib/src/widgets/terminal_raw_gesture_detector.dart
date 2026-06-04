import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart';

/// Gesture detector that recognizes taps (with multi-tap counting), mouse
/// drags, and touch long presses.
///
/// Counts consecutive taps within [kDoubleTapTimeout] and [kDoubleTapSlop]
/// to distinguish single, double, and triple taps. Drag is restricted to
/// mouse devices, long press to touch devices.
///
/// ```dart
/// TerminalRawGestureDetector(
///   onSingleTapDown: (details) => handleTap(details),
///   onDoubleTapDown: (details) => handleDoubleTap(details),
///   onDragStart: (details) => handleDragStart(details),
///   child: Container(),
/// )
/// ```
@internal
class TerminalRawGestureDetector extends StatefulWidget {
  final Widget child;

  /// Single tap (first tap, or after triple-tap reset).
  final GestureTapDownCallback? onSingleTapDown;

  /// Second consecutive tap within [kDoubleTapTimeout].
  final GestureTapDownCallback? onDoubleTapDown;

  /// Third consecutive tap. Resets the tap count afterward.
  final GestureTapDownCallback? onTripleTapDown;

  /// Fires when a mouse drag begins.
  final GestureDragStartCallback? onDragStart;

  /// Fires as the mouse drag continues.
  final GestureDragUpdateCallback? onDragUpdate;

  /// Fires when a mouse drag ends or is cancelled.
  final VoidCallback? onDragEnd;

  /// Fires when a touch long press begins.
  final GestureLongPressStartCallback? onLongPressStart;

  /// Fires as a touch long press moves.
  final GestureLongPressMoveUpdateCallback? onLongPressMoveUpdate;

  /// Fires when a touch long press ends.
  final VoidCallback? onLongPressUp;

  const TerminalRawGestureDetector({
    super.key,
    required this.child,
    this.onSingleTapDown,
    this.onDoubleTapDown,
    this.onTripleTapDown,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onLongPressStart,
    this.onLongPressMoveUpdate,
    this.onLongPressUp,
  });

  @override
  State<TerminalRawGestureDetector> createState() =>
      _TerminalRawGestureDetectorState();
}

class _TerminalRawGestureDetectorState
    extends State<TerminalRawGestureDetector> {
  var _tapCount = 0;
  (DateTime, Offset)? _lastTapUp;

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: <Type, GestureRecognizerFactory>{
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
              () => TapGestureRecognizer(debugOwner: this),
              (instance) => instance
                ..onTapDown = _handleTapDown
                ..onTapUp = _handleTapUp,
            ),
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(
                debugOwner: this,
                supportedDevices: const {PointerDeviceKind.touch},
              ),
              (instance) => instance
                ..onLongPressStart = _handleLongPressStart
                ..onLongPressMoveUpdate = widget.onLongPressMoveUpdate
                ..onLongPressUp = widget.onLongPressUp,
            ),
        PanGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
              () => PanGestureRecognizer(
                debugOwner: this,
                supportedDevices: const {PointerDeviceKind.mouse},
              ),
              (instance) {
                instance
                  ..dragStartBehavior = .down
                  ..onStart = widget.onDragStart
                  ..onUpdate = widget.onDragUpdate
                  ..onEnd = (_) => widget.onDragEnd?.call();
                instance.onCancel = () => widget.onDragEnd?.call();
              },
            ),
      },
      child: widget.child,
    );
  }

  void _countTap(Offset position) {
    if (_lastTapUp case (final time, final pos)
        when DateTime.now().difference(time) < kDoubleTapTimeout &&
            (position - pos).distance < kDoubleTapSlop) {
      _tapCount++;
    } else {
      _tapCount = 1;
    }
  }

  void _handleLongPressStart(LongPressStartDetails details) {
    _tapCount = 0;
    _lastTapUp = null;
    widget.onLongPressStart?.call(details);
  }

  void _handleTapDown(TapDownDetails details) {
    _countTap(details.localPosition);
    switch (_tapCount) {
      case >= 3:
        _tapCount = 0;
        widget.onTripleTapDown?.call(details);
      case 2:
        widget.onDoubleTapDown?.call(details);
      default:
        widget.onSingleTapDown?.call(details);
    }
  }

  void _handleTapUp(TapUpDetails details) {
    _lastTapUp = (DateTime.now(), details.localPosition);
  }
}
