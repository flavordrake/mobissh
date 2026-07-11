@Tags(['ffi'])
library;

// #898 (P0, device 0.1.10+60, intermittent) — a tmux window switch leaves the
// rendered glyph grid STALE: the cursor moves but the cells don't repaint to
// show the new window's content. The input is a CORRECT SGR-1006 status-bar
// mouse click (not #881's cursor-key fallback); tmux switches the window
// server-side and the server redraws — output comes back — but the glyph grid
// intermittently does not repaint.
//
// CONFIRMED MECHANISM: a tmux window switch is an IN-PLACE ALT-SCREEN full
// redraw — scrollback does NOT grow, the grid size does NOT change.
// `TerminalRenderBox._onTerminalChanged` marks the glyph render box needs-paint
// (`_markFrameDirty`, which also sets `_needsFrameSync` so the next paint
// re-snapshots the cells) for that case — UNLESS the notify arrives while the
// box is mid-`performLayout`. libghostty fires the terminal listener
// SYNCHRONOUSLY from inside `performLayout` (via `Terminal.resize` and
// `_syncScrollLayout`'s viewport scroll). The pre-fix guard
// `if (_paintState.rows == 0 || _performingLayout) return;` DROPPED that notify
// entirely, so `_needsFrameSync` was never set and the new window's glyphs never
// re-synced — only the cursor (read live each paint) moved. An unrelated later
// frame eventually forced a re-sync, which is why it was intermittent.
//
// THE FIX: the glyph dirty-mark is now UNCONDITIONAL on any content change.
// `markNeedsPaint()` is SAFE during `performLayout` (layout runs before paint,
// so the flag is honoured this same frame); only `markNeedsLayout()` is illegal
// then, and it is redundant mid-layout, so it is skipped in that window. The box
// therefore re-syncs and repaints for an in-place redraw whether the notify
// lands at idle OR during a layout pass.
//
// HEADLESS COVERAGE vs DEVICE GATE: the two tests below pin the contract
// headless — (1) an idle in-place redraw marks needs-paint, and (2) an in-place
// redraw whose notify fires DURING `performLayout` does not throw and the frame
// re-syncs/settles (the mid-layout safety the fix must preserve, mirroring the
// #887 cycle-2 prune pin). The AUTHORITATIVE red→green for the intermittent race
// is the on-emulator tmux window-switch confirm the orchestrator runs (a
// status-bar SGR mouse click updates the rendered grid to the new window's
// content), exactly as `prune_during_layout_defers_notify_887_test` defers its
// timing-coincidence baseline to the emulator suite.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/rendering.dart';
import 'package:flterm/src/rendering/terminal_render_cache.dart';
import 'package:flterm/src/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart';

void main() {
  void writeUtf8(Terminal terminal, String s) {
    terminal.write(Uint8List.fromList(utf8.encode(s)));
  }

  // ───────────────────────────────────────────────────────────────────────────
  // (1) The steady (idle) in-place redraw: a tmux window switch rewrites the
  // same alt-screen rows in place — no scrollback growth, no grid resize — and
  // MUST mark the glyph render box needs-paint. Guards the unconditional-marking
  // contract on the in-place trigger (the #887/#898 class).

  testWidgets(
    'an in-place alt-screen redraw at idle (no scrollback growth, no size '
    'change) marks the glyph render box needs-paint (#898)',
    (tester) async {
      final controller = TerminalController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 800,
                height: 480,
                child: TerminalView(controller: controller),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      void write(String s) =>
          controller.write(Uint8List.fromList(utf8.encode(s)));

      write('\x1b[?1049h\x1b[2J\x1b[H');
      for (var r = 1; r <= 20; r++) {
        write('\x1b[$r;1Hwindow A row ${r.toString().padLeft(2, '0')} content');
      }
      await tester.pump();
      await tester.pump();

      final renderBox = tester.renderObject<TerminalRenderBox>(
        find.byType(TerminalRenderer),
      );
      expect(
        controller.activeScreen,
        TerminalScreen.alternate,
        reason: 'precondition: on the alternate screen (tmux/full-screen app)',
      );
      expect(
        renderBox.debugNeedsPaint,
        isFalse,
        reason: 'precondition: the frame painted and settled before the switch',
      );
      final scrollbackBefore = controller.scrollbackRows;

      // tmux switches the window: the SAME alt-screen rows are rewritten IN
      // PLACE with the new window's content. No scrollback growth, no resize.
      for (var r = 1; r <= 20; r++) {
        write('\x1b[$r;1Hwindow B row ${r.toString().padLeft(2, '0')} content');
      }
      expect(
        controller.scrollbackRows,
        scrollbackBefore,
        reason: 'precondition: an in-place alt-screen redraw does NOT grow '
            'scrollback (it takes the in-place branch of _onTerminalChanged)',
      );
      expect(
        renderBox.debugNeedsPaint,
        isTrue,
        reason: 'an in-place alt-screen redraw (tmux window switch) must mark '
            'the glyph render box needs-paint (#898)',
      );
    },
  );

  // ───────────────────────────────────────────────────────────────────────────
  // (2) Mid-layout safety: a content-change notify that fires WHILE the box is
  // inside `performLayout` (the device race — libghostty fires the listener
  // synchronously from layout) must mark needs-paint WITHOUT throwing
  // "markNeedsLayout called during layout", and the frame must re-sync and
  // settle (the new in-place content repaints, the box ends clean — not stuck
  // dirty and not stale). We drive a raw `TerminalRenderer` and write the
  // in-place redraw from its `onResize` hook, which fires synchronously from
  // inside `TerminalRenderBox.performLayout` (`_performingLayout == true`).

  testWidgets(
    'a content-change notify firing DURING performLayout re-syncs and settles '
    'without throwing (the in-place redraw racing a layout pass) (#898)',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetDevicePixelRatio);

      const metrics = CellMetrics(cellWidth: 8, cellHeight: 16, baseline: 12);
      final terminal = Terminal(cols: 80, rows: 24);
      addTearDown(terminal.dispose);

      writeUtf8(terminal, '\x1b[?1049h\x1b[2J\x1b[H');
      for (var r = 1; r <= 20; r++) {
        writeUtf8(terminal,
            '\x1b[$r;1Hwindow A row ${r.toString().padLeft(2, '0')} content');
      }

      final cache = TerminalRenderCache();
      addTearDown(cache.dispose);

      // The onResize hook fires from INSIDE `performLayout`. When armed, write an
      // in-place alt-screen redraw there — its `_onTerminalChanged` fires while
      // `_performingLayout` is true, the exact #898 race. Pre-fix the guard
      // dropped it (silent); the fix marks needs-paint mid-layout, which must NOT
      // throw and must end in a settled repaint.
      var armed = false;
      var ranInLayoutRedraw = false;
      void onResize(int cols, int rows) {
        if (!armed) return;
        armed = false;
        ranInLayoutRedraw = true;
        for (var r = 1; r <= 20; r++) {
          writeUtf8(terminal,
              '\x1b[$r;1Hwindow B row ${r.toString().padLeft(2, '0')} new');
        }
      }

      var width = 640.0;
      late StateSetter setOuter;
      Widget app() {
        return Directionality(
          textDirection: TextDirection.ltr,
          child: StatefulBuilder(
            builder: (context, setState) {
              setOuter = setState;
              return Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: width, maxHeight: 384),
                  child: TerminalRenderer(
                    terminal: terminal,
                    theme: TerminalTheme.dark(),
                    metrics: metrics,
                    offset: ViewportOffset.zero(),
                    renderCache: cache,
                    renderObserver: _TestRenderObserver(),
                    onResize: onResize,
                  ),
                ),
              );
            },
          ),
        );
      }

      await tester.pumpWidget(app());
      await tester.pump();

      final box = tester.renderObject<TerminalRenderBox>(
        find.byType(TerminalRenderer),
      );
      expect(
        box.debugNeedsPaint,
        isFalse,
        reason: 'precondition: settled, clean frame before the layout-race redraw',
      );

      // Arm and shrink the width: `performLayout` runs, `onResize` fires
      // mid-layout, and the in-place redraw's notify lands while
      // `_performingLayout` is true.
      armed = true;
      setOuter(() {
        width = 560.0;
      });
      await tester.pump();

      expect(
        ranInLayoutRedraw,
        isTrue,
        reason: 'precondition: the in-place redraw ran from onResize (mid-layout)',
      );
      // The fix marks needs-paint mid-layout via `markNeedsPaint` (safe — layout
      // precedes paint), NOT `markNeedsLayout` (which would throw during layout).
      expect(
        tester.takeException(),
        isNull,
        reason: 'marking the glyph box dirty mid-layout must not throw '
            '"markNeedsLayout called during layout" (#898)',
      );

      // The in-layout redraw re-syncs and the frame settles: pumping leaves the
      // box clean (the new window content was painted) — not stuck dirty, not
      // stale.
      await tester.pump();
      expect(
        box.debugNeedsPaint,
        isFalse,
        reason: 'the in-layout in-place redraw re-syncs and the frame settles '
            'into a real repaint (#898)',
      );
    },
  );
}

class _TestRenderObserver implements TerminalRenderObserver {
  @override
  TerminalSelection? get selection => null;

  @override
  bool get hasFocus => true;

  @override
  List<HighlightRange> get highlights => const [];

  @override
  void reportPaintedViewportOffset(int offset) {}

  @override
  bool get isScrolling => false;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
