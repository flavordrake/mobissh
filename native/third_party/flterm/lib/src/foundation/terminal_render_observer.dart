import 'package:flutter/foundation.dart';

import 'highlight_range.dart';
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

  /// Additive structured-text highlight ranges (URLs, paths, regex matches).
  ///
  /// Set by the host via `TerminalController.highlights`. Painters draw a
  /// translucent fill over these ranges using the real cell metrics. Empty
  /// when nothing is highlighted.
  List<HighlightRange> get highlights;

  /// Whether the painted viewport offset is currently in flight (a user scroll /
  /// fling or a streaming-output auto-scroll). Exposed as scroll state; the
  /// controller uses it to gate the detection RESCAN for perf (#1044). The
  /// detection wash is NOT gated on it — the wash tracks its token live every
  /// paint via [HighlightPainter] (#1067).
  bool get isScrolling;

  /// Report the viewport offset the render box JUST painted the text with
  /// (#803). The render box calls this at the end of each frame sync, handing
  /// back the SAME `viewportOffset` the [HighlightPainter] read from the frame
  /// snapshot. A widget-layer decorator (`GhosttyTerminalDecoratorLayer`)
  /// resolves its anchor rects against this FRAME-SYNCED offset instead of the
  /// live `scrollbar.offset`, so the decorator geometry matches the painted
  /// glyphs on the same frame and the URL markup no longer "dances" ahead of
  /// the text during a tmux-redraw scroll. Implementations must defer any
  /// resulting `notifyListeners()` to a post-frame callback (the report fires
  /// during paint, where a synchronous notify would mutate the tree mid-frame).
  void reportPaintedViewportOffset(int offset);
}
