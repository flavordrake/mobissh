import 'package:libghostty/libghostty.dart';

/// Callback for terminal grid resize events.
///
/// Fires when the [TerminalView] layout changes and produces a different
/// number of character [cols] and [rows]. Set on [TerminalController.onResize]
/// to forward size changes to the backend (PTY, SSH, etc.).
///
/// ```dart
/// controller.onResize = (cols, rows) => pty.resize(cols, rows);
/// ```
typedef OnResize = void Function(int cols, int rows);

/// Mouse event data from the gesture detector to the controller.
///
/// Carries the raw pixel coordinates and the semantic action/button so
/// the controller can encode mouse reports for the terminal. Pixel
/// coordinates are relative to the terminal grid origin (after padding).
///
/// ```dart
/// final event = (
///   action: MouseAction.press,
///   button: MouseButton.left,
///   pixelX: offset.dx,
///   pixelY: offset.dy,
/// );
/// controller.handleMouseEvent(event);
/// ```
typedef TerminalMouseEvent = ({
  MouseAction action,
  MouseButton button,
  double pixelX,
  double pixelY,
});
