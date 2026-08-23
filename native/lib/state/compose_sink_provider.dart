// Live handle to the VISIBLE compose bar's buffer (#1131).
//
// The keybar and the compose bar are sibling widgets: the keybar sent every key
// straight to `terminal.textInput`, so tapping `/` while composing split the
// user's input across two destinations (character to the remote shell, the rest
// staged locally). This provider is the seam that lets the keybar route
// CHARACTER keys into the compose buffer instead.
//
// It holds a handle, not the text: the compose bar's TextEditingController is
// the single source of truth and MUST stay that way — it carries the IME
// composing region that makes swipe/voice input work at all (the whole reason
// the compose bar exists, #599). Mirroring the text into provider state would
// fight that composing stream.
//
// Lifetime == visibility: `ComposeBar` is built only while
// `composeBarVisibleProvider` is true (terminal_screen.dart), so a non-null
// sink means "the IME preview is up". Registration/clearing is deferred by a
// microtask because mount/unmount happens DURING the rebuild that toggled the
// visibility provider, and mutating a provider mid-build throws (same reason
// as compose_bar's `_captureBeforeClear`).

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Callbacks into the mounted compose bar. Null when the bar is hidden.
class ComposeSink {
  const ComposeSink({
    required this.insertText,
    required this.submit,
    required this.hasText,
  });

  /// Insert [text] at the caret, replacing any selection.
  final void Function(String text) insertText;

  /// Send the staged text followed by Enter, exactly like the bar's ⏎ action.
  final void Function() submit;

  /// Whether the buffer currently holds anything.
  final bool Function() hasText;
}

final composeSinkProvider = StateProvider<ComposeSink?>((ref) => null);
