import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:libghostty/libghostty.dart' hide KeyEvent;

import '../foundation.dart';

/// Internal contract between the controller and the view.
///
/// The controller implements this. The view casts the controller to
/// this type to report user interactions and access internal state.
@internal
abstract interface class TerminalViewBinding {
  /// Sets the theme brightness for color scheme queries and text input.
  set brightness(Brightness value);

  /// Whether the cursor should actively blink right now.
  ///
  /// Combines DEC mode 12, focus state, and viewport scroll position.
  /// True only when the terminal has focus, cursor blinking is enabled,
  /// and the cursor row is visible in the viewport.
  bool get cursorBlinks;

  /// Current IME preedit text that has not been committed to the terminal.
  String get preeditText;

  /// Current mouse tracking mode.
  MouseTracking get mouseTracking;

  /// The terminal instance for the renderer.
  Terminal get terminal;

  /// Active virtual modifier keys.
  Mods get virtualMods;

  /// Subscribes to [focusNode] and [scrollController] for focus and
  /// scroll handling.
  void attach(FocusNode focusNode, ScrollController scrollController);

  /// Clears the current selection.
  void clearSelection();

  /// Unsubscribes focus, detaches text input, cleans up all state.
  void detach();

  /// Handles a keyboard event including selection extension, terminal
  /// encoding, selection clearing, and scroll-to-bottom.
  ///
  /// Returns [KeyEventResult.handled] if the event produced terminal
  /// output or extended a selection, [KeyEventResult.ignored] otherwise.
  KeyEventResult handleKeyEvent(KeyEvent event);

  /// Reports a mouse event. Controller encodes and emits via onOutput.
  void handleMouseEvent(TerminalMouseEvent event);

  /// Reports resize from layout. [metrics] are in logical pixels and
  /// are scaled by [devicePixelRatio] for libghostty's physical-pixel
  /// size reports and Kitty graphics.
  void handleResize({
    required int cols,
    required int rows,
    required CellMetrics metrics,
    required EdgeInsets padding,
    required double devicePixelRatio,
  });

  /// Reports scroll by line count.
  void handleScroll(int lines);

  /// Requests keyboard focus for the attached view.
  void requestFocus();

  /// Reports renderer geometry used to anchor platform IME UI.
  void updateTextInputGeometry({
    required Size editableSize,
    required Matrix4 transform,
    required Rect caretRect,
    required Rect composingRect,
  });

  /// Selects the line at [row], using terminal line-boundary detection.
  /// The [lineSelectMode] controls whether trailing empty cells are included.
  void selectLine(int row, LineSelectMode lineSelectMode);

  /// Selects the word at ([row], [col]), using terminal word-boundary
  /// detection with wide character snapping.
  void selectWord(int row, int col);

  /// Creates a selection from drag coordinates, snapping columns to
  /// wide character boundaries and applying the viewport scroll offset.
  void updateSelection(
    int startRow,
    int startCol,
    int endRow,
    int endCol,
    TerminalSelectionMode mode,
  );
}
