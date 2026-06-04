// #750 — URL highlight must not float over shifted text while scrolling tmux.
//
// #726 re-detected URLs on a single 120ms debounce for BOTH ordinary output and
// a scroll. During a tmux scroll (a REMOTE full-screen redraw that shifts the
// visible text), the cached underlines kept painting at their old cells for the
// whole debounce window — floating over the now-shifted content. The fix
// discriminates a SCROLL (the flterm `scrollbar.offset` changed) from ordinary
// OUTPUT (offset unchanged): a scroll CLEARS the underlines immediately and
// re-detects on a SHORT settle after the scroll stops; output keeps the existing
// debounce with NO pre-clear (no flicker).
//
// `ghosttyUrlDetectAction` is the pure discrimination (no FFI / no widget), gated
// here. The clear-now + settle-debounce SCHEDULING it selects is wired in
// `_onControllerChanged`; the owner device-validates that underlines vanish
// mid-scroll and reappear on settle.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

void main() {
  group('ghosttyUrlDetectAction — scroll vs output (#750)', () {
    test('scroll offset CHANGED → clear-and-settle', () {
      expect(
        ghosttyUrlDetectAction(prevScrollOffset: 0, nextScrollOffset: 5),
        GhosttyUrlDetectAction.scrollClearAndSettle,
      );
      // Scrolling back DOWN toward the bottom (offset shrinks) is also a scroll.
      expect(
        ghosttyUrlDetectAction(prevScrollOffset: 12, nextScrollOffset: 3),
        GhosttyUrlDetectAction.scrollClearAndSettle,
      );
      // Any non-zero delta, however small, is a scroll.
      expect(
        ghosttyUrlDetectAction(prevScrollOffset: 100, nextScrollOffset: 101),
        GhosttyUrlDetectAction.scrollClearAndSettle,
      );
    });

    test('scroll offset UNCHANGED → output debounce (no pre-clear)', () {
      // Output grew under a PINNED viewport — the visible window didn't move, so
      // the existing underlines are still correct: keep the #726 debounce, no
      // flicker.
      expect(
        ghosttyUrlDetectAction(prevScrollOffset: 0, nextScrollOffset: 0),
        GhosttyUrlDetectAction.outputDebounce,
      );
      expect(
        ghosttyUrlDetectAction(prevScrollOffset: 7, nextScrollOffset: 7),
        GhosttyUrlDetectAction.outputDebounce,
      );
    });

    test('a fast scroll = a BURST of changed offsets, each clear-and-settle', () {
      // A flick produces several offset steps in quick succession; every one is a
      // scroll, so the view clears + RESTARTS the settle timer each tick (the
      // burst coalesces to ONE re-scan once it stops).
      const offsets = [0, 4, 9, 15, 20];
      for (var i = 1; i < offsets.length; i++) {
        expect(
          ghosttyUrlDetectAction(
            prevScrollOffset: offsets[i - 1],
            nextScrollOffset: offsets[i],
          ),
          GhosttyUrlDetectAction.scrollClearAndSettle,
          reason: 'step ${offsets[i - 1]}→${offsets[i]} is a scroll',
        );
      }
      // When the flick STOPS (offset plateaus), the next tick is output again →
      // no further clear, the settle timer fires the re-detect.
      expect(
        ghosttyUrlDetectAction(prevScrollOffset: 20, nextScrollOffset: 20),
        GhosttyUrlDetectAction.outputDebounce,
      );
    });

    test('settle debounce is SHORTER than the output debounce', () {
      // The reappear-after-scroll must feel prompt — shorter than the streaming
      // output coalescing window — while both stay > 0 (always debounced, never
      // a synchronous re-scan per byte/step).
      expect(kGhosttyUrlScrollSettleMs, greaterThan(0));
      expect(kGhosttyUrlOutputDebounceMs, greaterThan(0));
      expect(
        kGhosttyUrlScrollSettleMs,
        lessThan(kGhosttyUrlOutputDebounceMs),
        reason: 'a settled scroll should reapply faster than output coalesces',
      );
    });
  });
}
