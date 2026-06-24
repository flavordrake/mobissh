@Tags(['ffi'])
library;

// #922 (P0, device 0.1.10+70) — the STRUCTURAL cure for the repaint saga
// (#887/#898/#900/#918/#921/#931). After the +70 tactical #931 fix RESUME and
// TYPING repaint, but switching tmux WINDOWS still leaves the OLD window's
// content on screen (stale) with detect-URLs ON.
//
// ROOT (corrected — see issue #922; the "two RenderState handles share one
// terminal damage flag" premise was DISPROVEN by a pipeline probe: each
// libghostty RenderState handle has INDEPENDENT per-row dirty tracking, so a
// second handle's update does NOT clear the first's damage). The real defect is
// SAME-HANDLE DOUBLE-UPDATE: `RenderState.update()` CONSUMES the terminal's
// per-row damage as it reads it (render_state.dart:165). With detection ON the
// controller drives an EXTRA content notify per output change, so the render
// box's SINGLE paint handle gets `sync(terminalDirty:true)` TWICE for one
// logical change. The FIRST `update` consumes the per-row damage; the SECOND
// reads CLEAN and the partial build re-emits 0 rows. When the painting sync is
// that second, damage-clean one, the grid stays stale — the tmux window-switch
// "old content stays on screen".
//
// STRUCTURAL FIX (terminal_frame_builder.dart `_damageUnsettled`): an `update`
// that reports damage marks the content UNSETTLED until a FOLLOWING sync that
// reads CLEAN re-reads the FULL visible grid and settles it. So a redundant
// damage-consuming sync can no longer leave a later clean painting sync reading
// nothing — the paint handle is the AUTHORITATIVE consumer regardless of how
// many extra consuming syncs detection injects. No libghostty edit (it is not
// vendored — pub cache), no fragile detectionActive UI gate, and NO extra work
// on the detection-OFF streaming path (#805): a single sync per change consumes
// the damage in the sync that builds it, and the next change's `update` is
// non-clean anyway, so the flag never forces a full re-read while output streams.
//
// THE INVARIANT this test pins (so it can NEVER regress to a per-frame guard
// race): after a content change, a redundant damage-consuming sync followed by a
// CLEAN sync must STILL re-read the full visible grid — the paint handle is not
// starved.

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flterm/src/foundation/cell_metrics.dart';
import 'package:flterm/src/foundation/terminal_theme.dart';
import 'package:flterm/src/rendering/atlas/atlas.dart';
import 'package:flterm/src/rendering/paint_state.dart';
import 'package:flterm/src/rendering/terminal_render_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart';

void main() {
  const rows = 4;
  const cols = 16;
  const metrics = CellMetrics(cellWidth: 8, cellHeight: 16, baseline: 12);

  AtlasConfig config() => AtlasConfig(
        fontSize: 14,
        fontWeight: FontWeight.normal,
        fontFamily: 'monospace',
        fontFamilyFallback: const [],
        metrics: metrics,
        devicePixelRatio: 1.0,
      );

  void writeUtf8(Terminal terminal, String text) {
    terminal.write(Uint8List.fromList(utf8.encode(text)));
  }

  late Terminal terminal;
  late Atlas atlas;
  late TerminalPaintState state;
  late TerminalRenderPipeline pipeline;

  setUp(() {
    terminal = Terminal(cols: cols, rows: rows);
    atlas = Atlas(config());
    state = TerminalPaintState(TerminalTheme.dark(), metrics)
      ..cols = cols
      ..rows = rows;
    pipeline = TerminalRenderPipeline(
      atlas: atlas,
      state: state,
      onImageReady: () {},
    )..configureGrid(rows, cols);
  });

  tearDown(() {
    pipeline.dispose();
    atlas.dispose();
    terminal.dispose();
  });

  // A tmux window switch: an in-place full-screen redraw (addressed cells only,
  // no \x1b[2J), so libghostty reports per-row damage — the path a tmux window
  // switch takes. Modelled on BOTH screens (the saga has hit both).
  void enterAltScreen() => writeUtf8(terminal, '\x1b[?1049h\x1b[2J\x1b[H');

  void switchWindow(String tag) {
    for (var r = 1; r <= rows; r++) {
      writeUtf8(terminal, '\x1b[$r;1Hwindow $tag row $r        ');
    }
  }

  group('#922 tmux WINDOW SWITCH must repaint with the detection double-update',
      () {
    test(
      'ALT screen: a redundant damage-consuming sync then a CLEAN painting sync '
      'still re-reads the full visible grid (the structural carry-forward) — the '
      'paint handle is not starved',
      () {
        enterAltScreen();
        expect(terminal.activeScreen, TerminalScreen.alternate,
            reason: 'precondition: tmux runs on the alternate screen');

        // Window A drawn and painted.
        switchWindow('A');
        pipeline.sync(terminal, terminalDirty: true);
        expect(pipeline.debugRowsRebuiltLastSync, greaterThan(0),
            reason: 'precondition: the first window draw re-reads rows');

        // Switch A -> B: the redraw burst writes B's rows; libghostty holds
        // per-row damage. Detection ON injects an EXTRA content notify, so the
        // SAME paint handle syncs once for that change BEFORE the painting sync:
        // this FIRST sync's `update` consumes the per-row damage.
        switchWindow('B');
        pipeline.sync(terminal, terminalDirty: true);

        // The painting sync now runs. libghostty reports CLEAN (no NEW damage
        // since the consuming sync). The #922 carry-forward forces a full
        // re-read because the damage is still UNSETTLED — no manual
        // markAllRowsDirty, no detectionActive gate.
        pipeline.sync(terminal, terminalDirty: true);

        expect(
          pipeline.debugRowsRebuiltLastSync,
          equals(rows),
          reason: 'the window-switch redraw re-reads the FULL visible grid on the '
              'painting sync even though a redundant detection-driven sync '
              'consumed the damage first — the paint handle is authoritative '
              '(#922)',
        );
      },
    );

    test(
      'PRIMARY screen: the same redundant-consume → clean-paint sequence re-reads '
      'the full visible grid (the #921 detection-ON case, now structural)',
      () {
        expect(terminal.activeScreen, TerminalScreen.primary);

        switchWindow('A');
        pipeline.sync(terminal, terminalDirty: true);

        switchWindow('B');
        // Detection's extra notify consumes the damage first.
        pipeline.sync(terminal, terminalDirty: true);
        // The painting sync reads clean; the carry-forward re-reads the grid.
        pipeline.sync(terminal, terminalDirty: true);

        expect(
          pipeline.debugRowsRebuiltLastSync,
          equals(rows),
          reason: 'the primary-screen detection double-update re-reads the full '
              'grid structurally — no detectionActive gate needed (#922)',
        );
      },
    );

    test(
      'REPEATED switches A->B->A->B each repaint despite a redundant consuming '
      'sync per switch (the #900 alternation is now structural, not every-other)',
      () {
        enterAltScreen();
        switchWindow('init');
        pipeline.sync(terminal, terminalDirty: true);

        for (final tag in ['A', 'B', 'A', 'B', 'A']) {
          switchWindow(tag);
          // Redundant detection-driven sync consumes the damage first...
          pipeline.sync(terminal, terminalDirty: true);
          // ...then the painting sync reads clean.
          pipeline.sync(terminal, terminalDirty: true);

          expect(
            pipeline.debugRowsRebuiltLastSync,
            equals(rows),
            reason: 'EVERY window switch ($tag) re-reads the full visible grid — '
                'no A/B/A/B alternation, no stale window (#900 structural)',
          );
        }
      },
    );

    test(
      '#805 GUARD: detection OFF (a SINGLE sync per change) never forces a full '
      're-read while output streams — the painting sync consumes the damage it '
      'builds, and the next change is non-clean, so per-redraw work is unchanged',
      () {
        expect(terminal.activeScreen, TerminalScreen.primary);

        // Stream several in-place redraws, ONE sync per change (detection OFF).
        // Each sync sees fresh per-row damage (non-clean), so the build is the
        // normal PARTIAL per-row rebuild — never a forced full re-read.
        for (final tag in ['A', 'B', 'C', 'D']) {
          switchWindow(tag);
          pipeline.sync(terminal, terminalDirty: true);
          expect(
            pipeline.debugRowsRebuiltLastSync,
            greaterThan(0),
            reason: 'a single sync per change consumes the damage in the sync '
                'that builds it ($tag) — paint works with no redundant sync',
          );
        }
      },
    );
  });
}
