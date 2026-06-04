import 'package:flutter/foundation.dart';

import 'terminal_selection.dart';

/// Observable selection and focus state for the rendering layer.
///
/// Implemented by [TerminalController] and consumed by painters that need
/// to react to focus changes or selection updates without depending on
/// the full controller API.
///
/// Listeners are notified when [hasFocus] or [selection] changes,
/// triggering repaint of selection highlights and cursor state.
///
/// ```dart
/// void paint(Canvas canvas, TerminalRenderObserver observer) {
///   if (observer.selection case final sel?) {
///     paintSelection(canvas, sel);
///   }
/// }
/// ```
abstract class TerminalRenderObserver implements Listenable {
  /// Whether the terminal view has keyboard focus.
  ///
  /// Painters use this to adjust cursor rendering: a focused terminal
  /// draws a filled cursor, while an unfocused terminal draws a hollow
  /// block outline.
  bool get hasFocus;

  /// The current text selection, or null if nothing is selected.
  ///
  /// Updated by the gesture detector as the user drags, double-clicks,
  /// or triple-clicks. Set to null when the selection is cleared.
  TerminalSelection? get selection;
}
