@Tags(['ffi'])
library;

// REPLAY regression for #834 — a visible URL is NOT detected/highlighted in
// scrollback, driven by the OWNER'S REAL captured byte trace (not a synthetic
// grid).
//
// Source: test-results/uploads/2026-06-09T03-48-30-bug-report.byte-trace.json,
// copied into test/fixtures/replay/url_miss_scrollback_58x34.byte-trace.json.
// Host nv-dev, grid 58x34. The capture is a tmux session (status bar on the
// bottom row; the byte stream contains exactly ONE `ESC[?1049h` enter-alt-screen
// with NO matching leave, plus tmux mouse modes `?1000h/?1002h/?1006h`).
//
// THE BUG: #824 suppresses ALL heuristic url/path detection on the ALTERNATE
// screen (vim/less/htop, where incidental paths are noise). But tmux ALSO runs
// full-screen on the alternate screen — and tmux is the user's working shell
// host: its content is real shell output with NAVIGABLE URLs. The blanket
// alt-screen suppression killed detection for the whole tmux session, so the
// wrapped URL `http://nv-dev...:22240/p/daily/comms-digest-2026-06-08` produced
// NO anchor (RED). other content the owner saw highlighted was from before tmux
// took the alt-screen / a different pane.
//
// THE FIX: suppress heuristic patterns on the alt-screen ONLY when mouse tracking
// is OFF (a true full-screen editor). tmux mouse mode (`mouseTracking != none`,
// the exact discriminator the whole #690/#692/#693 gesture stack already trusts)
// means "shell host on the alt-screen" → run detection. The #824 vim fixture has
// NO mouse-mode sequences, so its suppression stays intact.
//
// SCOPE NOTE: the remote (Claude CLI inside tmux) HARD-wrapped this URL at the
// content width — row 21 is NOT marked soft-wrapped to row 22 (`viewportRowWraps`
// is all-false in this capture), so the detector correctly bubbles the on-screen
// portion `…/comms-dige` without gluing the unflagged `st-2026-06-08` line below
// (joining non-wrap-flagged lines is the over-join hazard #767 guards against).
// #834 is "URL not detected/highlighted at all"; that is what these assertions
// pin. The hard-wrap truncation is a separate concern.

import 'package:flterm/flterm.dart';
import 'package:flutter_test/flutter_test.dart';

import 'replay_trace_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const fixture =
      'test/fixtures/replay/url_miss_scrollback_58x34.byte-trace.json';
  // The URL as the remote HARD-wrapped it: row 21 carries `…/comms-dige` (the
  // `st-2026-06-08` tail is on an unflagged continuation line, see SCOPE NOTE).
  const detectedUrl =
      'http://nv-dev.tailbe5094.ts.net:22240/p/daily/comms-dige';

  Future<TerminalController> replay() async {
    final trace = loadByteTrace(fixture);
    final controller = TerminalController(
      config: TerminalConfig(cols: trace.cols, rows: trace.rows),
    );
    // The app registers the SAME three patterns in the SAME order (#767/#778).
    controller.registerTextPattern(TextPattern.osc8());
    controller.registerTextPattern(TextPattern.url());
    controller.registerTextPattern(TextPattern.path());
    await replayTrace(controller, trace);
    return controller;
  }

  group('REPLAY #834 — URL detected in a tmux (alt-screen + mouse-mode) grid',
      () {
    test(
      'precondition: the captured grid sits on the ALTERNATE screen with mouse '
      'tracking ON (a tmux session, not a vim editor)',
      () async {
        final controller = await replay();
        addTearDown(controller.dispose);
        expect(
          controller.activeScreen,
          TerminalScreen.alternate,
          reason: 'the real capture is on the alternate screen (tmux)',
        );
        expect(
          controller.mouseTracking,
          isNot(MouseTracking.none),
          reason: 'tmux enabled mouse mode (?1000/?1002/?1006) — the signal that '
              'distinguishes a shell host from a path-editing TUI',
        );
      },
    );

    test(
      'the visible URL is detected as ONE anchor carrying a NON-EMPTY payload '
      '(the #834 miss — it produced zero anchors before the fix)',
      () async {
        final controller = await replay();
        addTearDown(controller.dispose);

        final hits =
            controller.anchors.where((a) => a.payload == detectedUrl).toList();
        expect(
          hits,
          hasLength(1),
          reason: 'the visible URL must be detected even though tmux is on the '
              'alternate screen — #824 must not suppress detection in a '
              'mouse-mode (tmux) session (#834)',
        );
        expect(
          '${hits.single.payload}'.trim(),
          isNotEmpty,
          reason: 'the anchor carries a real, copyable URL payload',
        );
      },
    );

    test(
      'the URL is hit-testable via matchAt on its visible row (tap-to-copy '
      'routes it)',
      () async {
        final controller = await replay();
        addTearDown(controller.dispose);

        // Scan the grid for a matchAt that resolves the URL — the link is
        // tappable wherever it sits on screen.
        StructuredMatch? found;
        for (var row = 0; row < 34 && found == null; row++) {
          for (var col = 0; col < 58; col++) {
            final m = controller.matchAt(row: row, col: col);
            if (m != null && m.payload == detectedUrl) {
              found = m;
              break;
            }
          }
        }
        expect(
          found,
          isNotNull,
          reason: 'matchAt must resolve the URL at its on-screen cells so '
              'tap-to-copy routes it (#834)',
        );
      },
    );
  });
}
