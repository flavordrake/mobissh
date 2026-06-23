// #931 (P0, device 0.1.10+68, detect-URLs ON = DEFAULT) — on a PRIMARY-screen
// in-place cursor-addressed redraw the terminal STOPS repainting on (a) app
// RESUME and (b) TYPING. The RESUME half: `_forceRepaintOnResume` cycled FOCUS
// only, which fires flterm's `_onRenderObserverChanged` → `markNeedsPaint()`
// ONLY — no `_needsFrameSync`, no `markAllRowsDirty()`. With detection ON a prior
// sync already consumed libghostty's per-row damage, so the resume frame-sync
// runs with nothing dirty → the partial build is SKIPPED → the stale buffer
// repaints.
//
// The #931 GAP 1 fix PAIRS the focus cycle with a REAL `forceRepaint()`
// (markAllRowsDirty + frame-dirty, the #918 seam) so resume re-reads the FULL
// visible grid even when the damage was consumed. The force-repaint fires under
// the SAME guard as the focus cycle ([ghosttyShouldCycleFocusForRepaint]): only
// the ACTIVE, connected, focus-RETAINED session view. flterm/libghostty can't
// render headless (native .so), so this gates the PURE decision; the real
// full-grid repaint (switch-to-apps-and-back shows the latest, no tap, keyboard
// down) is OWNER-validated on device. The consumed-damage re-read correctness is
// covered deterministically at the flterm pipeline level in
// third_party/flterm/test/rendering/resume_typing_repaint_931_test.dart.
//
// Structural cure (a non-consuming detection read that removes the damage race
// entirely) is tracked in #922 — this is the tactical fix on existing seams.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

void main() {
  group('#931 GAP 1 — resume force-repaint gate', () {
    test(
      'forces a full-grid repaint on the RETAINED-focus resume (active + '
      'connected + hasFocus) — the unlock/switch-back case the focus cycle '
      'alone left frozen',
      () {
        // The #931 RESUME case made concrete: the visible session, a live shell,
        // focus retained through the background. A plain focus cycle only
        // markNeedsPaints; the fix ALSO forceRepaints under this same gate.
        expect(
          ghosttyShouldCycleFocusForRepaint(
            active: true,
            connected: true,
            hasFocus: true,
          ),
          isTrue,
        );
      },
    );

    test(
      'does NOT force a full-grid repaint on an offstage / disconnected / '
      'focus-lost session (the force-repaint shares the focus-cycle guard)',
      () {
        // Offstage session must not force-repaint (would re-read an offstage
        // grid / steal focus); a dead PTY has nothing to re-read; focus-LOST is
        // already handled by the #718 plain refocus, so no extra force needed.
        expect(
          ghosttyShouldCycleFocusForRepaint(
            active: false,
            connected: true,
            hasFocus: true,
          ),
          isFalse,
          reason: 'offstage session must not force a repaint',
        );
        expect(
          ghosttyShouldCycleFocusForRepaint(
            active: true,
            connected: false,
            hasFocus: true,
          ),
          isFalse,
          reason: 'disconnected session has nothing to re-read',
        );
        expect(
          ghosttyShouldCycleFocusForRepaint(
            active: true,
            connected: true,
            hasFocus: false,
          ),
          isFalse,
          reason: 'focus-lost resume is handled by the plain refocus (#718)',
        );
      },
    );

    test('requires ALL guards — the force-repaint never fires unguarded', () {
      for (final active in [true, false]) {
        for (final connected in [true, false]) {
          for (final hasFocus in [true, false]) {
            final expected = active && connected && hasFocus;
            expect(
              ghosttyShouldCycleFocusForRepaint(
                active: active,
                connected: connected,
                hasFocus: hasFocus,
              ),
              expected,
              reason: 'active=$active connected=$connected hasFocus=$hasFocus',
            );
          }
        }
      }
    });
  });
}
