// #704 — on app switch-away-and-back the Ghostty (flterm) terminal is NOT
// refreshed AND NOT laid out: `_SessionTerminalBody` renders GhosttyTerminalView
// for the ghostty backend and DELIBERATELY skips the xterm-only resume machinery
// (the #659/#666 fit-burst, the `didChangeMetrics` re-fit). So on
// `AppLifecycleState.resumed` flterm neither re-fits nor repaints — stale/blank
// until a tap/scroll forces a frame, and the PTY (tmux) keeps its backgrounded
// grid.
//
// The fix listens for a lifecycle transition INTO `resumed` and, when connected,
// re-arms the #702 forced-resize burst (re-fit) + nudges a repaint (refresh).
// flterm/libghostty can't render headless (native .so), so this gates the PURE
// decision the resume action uses: WHEN to re-fit + refresh. The real flterm
// re-layout + repaint is OWNER-validated on device (background→foreground:
// terminal is laid out AND shows latest output, no tap needed).

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

void main() {
  group('ghosttyShouldRefreshOnLifecycle — when to re-fit + refresh (#704)', () {
    test('fires on a transition INTO resumed from paused (the fix case)', () {
      // The bug case made concrete: the app was backgrounded (paused) and the
      // user switched back — re-fit + refresh so the terminal lays out and
      // shows the latest output without needing a tap.
      expect(
        ghosttyShouldRefreshOnLifecycle(
          AppLifecycleState.paused,
          AppLifecycleState.resumed,
        ),
        isTrue,
      );
    });

    test('fires on resumed from inactive / hidden / detached', () {
      // Android can route through inactive/hidden, and a cold first-listen can
      // see detached — any non-resumed → resumed is a real resume.
      for (final prev in const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.detached,
      ]) {
        expect(
          ghosttyShouldRefreshOnLifecycle(prev, AppLifecycleState.resumed),
          isTrue,
          reason: 'resume from $prev should re-fit + refresh',
        );
      }
    });

    test('fires on resumed from a null previous (first listen)', () {
      // The lifecycleProvider defaults to resumed and the first `ref.listen`
      // tick can carry a null prev; treat a null→resumed first observation as a
      // resume so a cold-mount-after-background still refreshes.
      expect(
        ghosttyShouldRefreshOnLifecycle(null, AppLifecycleState.resumed),
        isTrue,
      );
    });

    test('does NOT double-fire on resumed → resumed (spurious re-emit)', () {
      // The StateProvider can re-emit the same value; gating on the transition
      // keeps the resume burst single-shot so we never stack resize bursts.
      expect(
        ghosttyShouldRefreshOnLifecycle(
          AppLifecycleState.resumed,
          AppLifecycleState.resumed,
        ),
        isFalse,
      );
    });

    test('does NOT fire on a transition INTO a non-resumed state', () {
      // Going to background (or any non-resumed target) is not a resume — the
      // re-fit + refresh only makes sense when returning to the foreground.
      for (final next in const [
        AppLifecycleState.paused,
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.detached,
      ]) {
        expect(
          ghosttyShouldRefreshOnLifecycle(AppLifecycleState.resumed, next),
          isFalse,
          reason: 'resumed → $next is not a resume',
        );
        expect(
          ghosttyShouldRefreshOnLifecycle(AppLifecycleState.paused, next),
          isFalse,
          reason: 'paused → $next is not a resume',
        );
      }
    });
  });
}
