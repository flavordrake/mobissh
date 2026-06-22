@Tags(['ffi'])
library;

// #921 (P0, device 0.1.10+65) — with detect-URLs ON the terminal does NOT
// repaint on the PRIMARY screen; with detection OFF it paints. tmux control
// mode is OFF and irrelevant. This is the FIFTH repaint fix in the flterm
// render-box frame-sync subsystem (#887, #898, #900, #918) — STRUCTURAL, the
// same single-consumption libghostty damage root as #900, now on the PRIMARY
// screen where the #900 fix's `markAllRowsDirty` gate does NOT reach.
//
// CONFIRMED ROOT (same single-consumption damage as #900, now on PRIMARY):
//   `RenderState.update()` "snapshots terminal state and consumes its dirty
//   flag" (libghostty render_state.dart:165/179). Each libghostty `RenderState`
//   handle diffs against ITS OWN last snapshot, so the FIRST `update` after a
//   content change reports the per-row damage and the NEXT `update` (with no new
//   writes between) reports CLEAN. The render box's frame builder uses ONE such
//   handle; the partial-build path (`_build(.partial)`) re-emits ONLY the rows
//   that `update` flagged.
//
//   When DETECTION is ON, the controller maintains live anchors and emits an
//   EXTRA content notify per output change (re-anchor / prune / viewport-wrap
//   reads), which drives a SECOND frame-builder `sync` on the SAME handle for
//   that one change. The first sync consumes the per-row damage; the second sync
//   reads CLEAN and its partial build re-emits NO rows — so the rendered grid
//   stays stale. This is the exact #900 double-consume, but on the PRIMARY
//   screen, where the #900 fix's `markAllRowsDirty` gate does NOT reach
//   (terminal_renderer.dart `if (_terminal.activeScreen == .alternate)`).
//
//   Detection OFF: no extra notify → a single sync per change → the damage is
//   consumed by the sync that PAINTS it → paint works. That is the ON/OFF
//   asymmetry the user reports.
//
// FIX (Option A): widen the `markAllRowsDirty` gate so the PRIMARY screen also
// forces a full VISIBLE-grid re-read on a content change, but ONLY when
// detection is active (the only condition that issues the extra consuming sync).
// `markAllRowsDirty` marks VISIBLE rows only (bounded — no scrollback walk) and
// fires only on a content notify, so #805 throughput is untouched.
//
// This test reproduces the double-consume DETERMINISTICALLY at the pipeline
// level on the PRIMARY screen, exactly as the #900 test does on the alternate
// screen: a content change, then a FIRST `sync` that consumes the damage
// (models detection's extra notify), then the paint `sync`. WITHOUT the fix the
// partial build re-reads NOTHING (stale grid); the fix's action
// (`markAllRowsDirty`) re-reads the full visible grid.

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
    terminal = Terminal(cols: 16, rows: 4);
    atlas = Atlas(config());
    state = TerminalPaintState(TerminalTheme.dark(), metrics)
      ..cols = 16
      ..rows = 4;
    pipeline = TerminalRenderPipeline(
      atlas: atlas,
      state: state,
      onImageReady: () {},
    )..configureGrid(4, 16);
  });

  tearDown(() {
    pipeline.dispose();
    atlas.dispose();
    terminal.dispose();
  });

  // An in-place primary-screen rewrite (addressed cells only): libghostty
  // reports per-row damage for the change — the path a streaming primary-screen
  // line update takes.
  void inPlaceRedraw(String tag) {
    for (var r = 1; r <= 4; r++) {
      writeUtf8(terminal, '\x1b[$r;1Hprimary $tag row $r        ');
    }
  }

  test(
    'PRIMARY screen: a content change whose damage a prior (detection-driven) '
    'sync consumed still re-reads the full grid when markAllRowsDirty is forced '
    '(the #921 fix) — but re-reads NOTHING without it (the detection-ON freeze)',
    () {
      // PRIMARY screen (no \x1b[?1049h) — the exact #921 condition.
      expect(terminal.activeScreen, TerminalScreen.primary,
          reason: 'precondition: on the primary screen (normal shell, not tmux '
              'full-screen)');

      // Content A drawn and painted.
      inPlaceRedraw('A');
      pipeline.sync(terminal, terminalDirty: true);
      expect(pipeline.debugRowsRebuiltLastSync, greaterThan(0),
          reason: 'precondition: the first redraw re-reads rows');

      // New content B: libghostty now holds per-row damage for the change.
      inPlaceRedraw('B');

      // Detection ON drives an EXTRA content notify, so the frame builder syncs
      // the SAME handle once for that change BEFORE the sync that paints. The
      // first sync's `RenderState.update` consumes the per-row damage.
      pipeline.sync(terminal, terminalDirty: true);

      // Now the paint sync runs. libghostty reports CLEAN (no NEW damage since
      // the consuming sync). The #921 fix forces a full re-read via
      // markAllRowsDirty (gated on detectionActive on the primary screen).
      pipeline.markAllRowsDirty();
      pipeline.sync(terminal, terminalDirty: true);

      expect(
        pipeline.debugRowsRebuiltLastSync,
        equals(4),
        reason: 'the #921 fix (markAllRowsDirty when detection is active on the '
            'primary screen) re-reads the FULL visible grid even when libghostty '
            'reports clean because an earlier detection-driven sync consumed the '
            'per-row damage',
      );
    },
  );

  test(
    'PRIMARY screen WITHOUT the fix: a redraw whose damage a prior sync consumed '
    're-reads NO rows (documents the detection-ON freeze root)',
    () {
      expect(terminal.activeScreen, TerminalScreen.primary);

      inPlaceRedraw('A');
      pipeline.sync(terminal, terminalDirty: true);

      inPlaceRedraw('B');
      // First (consuming) sync: detection's extra notify reads + clears the
      // per-row damage.
      pipeline.sync(terminal, terminalDirty: true);
      // Second sync WITHOUT markAllRowsDirty: libghostty has no new damage, so
      // the partial build re-reads nothing. This is the stale grid the user sees
      // with detection ON — the #921 root.
      pipeline.sync(terminal, terminalDirty: true);

      expect(
        pipeline.debugRowsRebuiltLastSync,
        equals(0),
        reason: 'WITHOUT the fix, a redraw whose damage a prior detection-driven '
            'sync consumed re-reads zero rows — the rendered grid stays stale '
            '(the #921 detection-ON paint freeze)',
      );
    },
  );

  test(
    'CONTROL: detection OFF (single sync per change) consumes the damage in the '
    'sync that PAINTS it and re-reads rows — the detection-OFF path works',
    () {
      expect(terminal.activeScreen, TerminalScreen.primary);

      inPlaceRedraw('A');
      pipeline.sync(terminal, terminalDirty: true);

      inPlaceRedraw('B');
      // Detection OFF: NO extra notify, so only ONE sync runs per change — the
      // one that paints consumes the damage. Rows re-read.
      pipeline.sync(terminal, terminalDirty: true);

      expect(
        pipeline.debugRowsRebuiltLastSync,
        greaterThan(0),
        reason: 'with detection OFF only a single sync per change consumes the '
            'damage in the sync that paints it — paint works (the ON/OFF '
            'asymmetry)',
      );
    },
  );
}
