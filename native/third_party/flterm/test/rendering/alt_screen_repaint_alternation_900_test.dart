@Tags(['ffi'])
library;

// #900 (P0, device 0.1.10+61) — switching tmux windows repaints the rendered
// grid only on ALTERNATE switches ("works/fails/works/fails"). This is the 4th
// repaint fix in the flterm render-box frame-sync subsystem (#887 cycle1/cycle2,
// #898); per know-when-to-quit it is STRUCTURAL, not another per-trigger patch.
//
// CONFIRMED ROOT (the exact toggle):
//   `TerminalFrameBuilder.sync` re-reads the terminal grid via
//   `RenderState.update`, which CONSUMES (clears) libghostty's per-row damage as
//   it reads it. The partial-build path (`_build(.partial)`) then re-emits ONLY
//   the rows libghostty flagged damaged. The render box fires MULTIPLE paints
//   per tmux window switch (cursor blink, scroll/offset correction, the atlas
//   `onImageReady` repaint, the #803 painted-offset post-frame notify). When an
//   earlier paint's `update` consumes the switch's row damage before the build
//   that reaches the screen — or a second `update` straddles the in-place redraw
//   — the NEXT switch's `update` reads CLEAN (no NEW damage since the consumed
//   one), so its partial build re-emits NO rows and the grid stays on the
//   previous window. Damage is repopulated only every OTHER cycle → the strict
//   A/B/A/B alternation. The defect is single-consumption libghostty damage
//   feeding a partial build with no flterm-side guarantee that the `update` which
//   consumed the damage is the one that paints it.
//
// STRUCTURAL FIX (in `TerminalRenderBox._onTerminalChanged`): on the ALTERNATE
// screen, force `_pipeline.markAllRowsDirty()` on every content-change notify.
// That makes the frame builder's own `_dirtyRows` request a FULL re-read of the
// visible grid from the CURRENT `RenderState` snapshot even when `update`
// returns `.clean` because a prior frame already consumed the per-row damage.
// The alternate screen has NO scrollback, so a full re-read is bounded to the
// visible rows (what a native terminal does for a full-screen-app redraw), and
// the primary-screen streaming-output perf path (#805) is untouched.
//
// This test reproduces the damage double-consume DETERMINISTICALLY at the
// pipeline level: a content change followed by a `terminalDirty` sync that
// CONSUMES the damage without surviving to the screen, then asserts that the
// fix's action (`markAllRowsDirty`) re-reads the full grid on the next sync,
// whereas relying on libghostty damage alone re-reads NOTHING (the stale grid).

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

  // tmux-style in-place rewrite (no \x1b[2J clear): addressed cells only, so
  // libghostty reports DirtyState.partial with per-row damage — the exact path
  // a tmux window switch on the alternate screen takes.
  void inPlaceRedraw(String tag) {
    for (var r = 1; r <= 4; r++) {
      writeUtf8(terminal, '\x1b[$r;1Hwindow $tag row $r        ');
    }
  }

  test(
    'an in-place alt-screen redraw whose damage was consumed by a prior '
    'terminalDirty sync still re-reads the full grid when markAllRowsDirty is '
    'forced (the #900 fix) — but re-reads NOTHING without it (the alternation)',
    () {
      writeUtf8(terminal, '\x1b[?1049h\x1b[2J\x1b[H');
      expect(terminal.activeScreen, TerminalScreen.alternate,
          reason: 'precondition: on the alternate screen (tmux/full-screen app)');

      // Window A drawn and painted.
      inPlaceRedraw('A');
      pipeline.sync(terminal, terminalDirty: true);
      expect(pipeline.debugRowsRebuiltLastSync, greaterThan(0),
          reason: 'precondition: the first redraw re-reads rows');

      // Switch to window B: the in-place redraw writes B's rows. libghostty now
      // holds per-row damage for the change.
      inPlaceRedraw('B');

      // The device fires MULTIPLE paints per switch. Model the EARLIER paint
      // that consumes the damage BEFORE the build that reaches the screen: a
      // `terminalDirty` sync runs `RenderState.update`, which clears libghostty's
      // per-row damage as it reads it.
      pipeline.sync(terminal, terminalDirty: true);

      // Now the SCREEN paint for the switch runs. libghostty reports CLEAN (no
      // NEW damage since the consuming update). WITHOUT the fix the partial
      // build re-reads NOTHING — the grid stays on the previous window (the
      // "fails" half of the alternation). The #900 fix forces a full re-read.
      pipeline.markAllRowsDirty();
      pipeline.sync(terminal, terminalDirty: true);

      expect(
        pipeline.debugRowsRebuiltLastSync,
        equals(4),
        reason: 'the #900 fix (markAllRowsDirty on an alt-screen redraw) re-reads '
            'the FULL visible grid on EVERY switch, immune to single-consumption '
            'libghostty damage — not every other one',
      );
    },
  );

  test(
    '#922 STRUCTURAL: a redraw whose damage was already consumed STILL re-reads '
    'the full grid on the next CLEAN sync WITHOUT any manual markAllRowsDirty — '
    'the carry-forward eliminates the alternation root (was 0 = stale before #922)',
    () {
      writeUtf8(terminal, '\x1b[?1049h\x1b[2J\x1b[H');
      inPlaceRedraw('A');
      pipeline.sync(terminal, terminalDirty: true);

      inPlaceRedraw('B');
      // First (consuming) sync: reads + clears the per-row damage.
      pipeline.sync(terminal, terminalDirty: true);
      // Second (painting) sync reads CLEAN. Before #922 the partial build
      // re-read nothing (the stale half of the A/B/A/B alternation). The #922
      // `_damageUnsettled` carry-forward now forces a full re-read on this clean
      // sync, with NO markAllRowsDirty — the paint handle is authoritative.
      pipeline.sync(terminal, terminalDirty: true);

      expect(
        pipeline.debugRowsRebuiltLastSync,
        equals(4),
        reason: 'after #922, a redraw whose damage a prior frame consumed STILL '
            're-reads the full visible grid on the next clean sync — the '
            'alternation root is structurally gone',
      );
    },
  );
}
