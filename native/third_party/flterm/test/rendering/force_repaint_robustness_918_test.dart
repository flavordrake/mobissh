@Tags(['ffi'])
library;

// #918 — force-repaint robustness layer (the "tap Debug fixes it" mitigation).
//
// The recurring symptom: the rendered grid doesn't repaint until the user taps the
// Debug overlay, which forces a full Flutter frame + grid re-snapshot. The fix layers
// a SAFETY NET on top of the #900 damage-consume fix:
//
//   1. INPUT-DRIVEN: `TerminalRenderBox.forceRepaint()` re-reads the FULL visible grid
//      (markAllRowsDirty + frame-dirty) — the SAME full repaint a Debug-overlay / route
//      push triggers — coalesced to AT MOST ONCE per frame.
//   2. OUTPUT SETTLE TICK ("backend clock"): a PTY-output burst arms a one-shot timer
//      that fires ONCE ~60ms after the burst and forces a frame, even if the normal
//      damage/frame path dropped it. It MUST NOT free-run when idle (no input, no
//      output) — that regresses the #805 battery perf guard. Idle = zero forced frames.
//
// These tests drive the render box directly (a real `TerminalRenderBox` is mounted via
// `TerminalRenderer`, the same harness as terminal_renderer_test.dart) with an INJECTED
// settle-timer factory so the tick is deterministic headless.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/rendering.dart';
import 'package:flterm/src/rendering/terminal_render_cache.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart';

import 'helpers/font_loader.dart';

void main() {
  setUpAll(loadBundledFonts);

  const cols = 16;
  const rows = 4;
  const metrics = CellMetrics(cellWidth: 8, cellHeight: 16, baseline: 12);

  TerminalRenderCache createRenderCache() {
    final cache = TerminalRenderCache();
    addTearDown(cache.dispose);
    return cache;
  }

  void writeUtf8(Terminal terminal, String text) {
    terminal.write(Uint8List.fromList(utf8.encode(text)));
  }

  Widget wrap(Terminal terminal, {TerminalRenderCache? renderCache}) {
    renderCache ??= createRenderCache();
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: cols * metrics.cellWidth,
            maxHeight: rows * metrics.cellHeight,
          ),
          child: TerminalRenderer(
            terminal: terminal,
            theme: TerminalTheme.dark(),
            metrics: metrics,
            offset: ViewportOffset.zero(),
            renderCache: renderCache,
            renderObserver: _TestRenderObserver(),
          ),
        ),
      ),
    );
  }

  late Terminal terminal;

  setUp(() => terminal = Terminal(cols: cols, rows: rows));
  tearDown(() => terminal.dispose());

  group('TerminalRenderBox.forceRepaint (#918 input-driven)', () {
    testWidgets(
      'forceRepaint re-reads the FULL visible grid on the next sync, immune to '
      'consumed libghostty damage (the Debug-tap full repaint)',
      (tester) async {
        await tester.pumpWidget(wrap(terminal));
        final box = tester.renderObject<TerminalRenderBox>(
          find.byType(TerminalRenderer),
        );

        // Draw + paint window A.
        writeUtf8(terminal, '\x1b[?1049h\x1b[2J\x1b[H');
        for (var r = 1; r <= rows; r++) {
          writeUtf8(terminal, '\x1b[$r;1Hwindow A row $r       ');
        }
        await tester.pump();

        // In-place redraw to window B, then a paint that CONSUMES the damage
        // (cursor blink / offset correction) before forceRepaint runs.
        for (var r = 1; r <= rows; r++) {
          writeUtf8(terminal, '\x1b[$r;1Hwindow B row $r       ');
        }
        await tester.pump();

        // forceRepaint must re-read EVERY visible row on the next sync, even if a
        // prior paint already consumed the per-row damage.
        box.forceRepaint();
        await tester.pump();

        expect(
          box.debugRowsRebuiltLastSync,
          rows,
          reason: 'forceRepaint re-reads the full visible grid (markAllRowsDirty)',
        );
      },
    );

    testWidgets(
      'forceRepaint coalesces: many calls within one frame trigger at most one '
      'forced re-snapshot (bounded — never more than once per frame)',
      (tester) async {
        await tester.pumpWidget(wrap(terminal));
        final box = tester.renderObject<TerminalRenderBox>(
          find.byType(TerminalRenderer),
        );
        final before = box.debugForceRepaintCount;

        // Five inputs land within the SAME frame.
        for (var i = 0; i < 5; i++) {
          box.forceRepaint();
        }
        await tester.pump();

        expect(
          box.debugForceRepaintCount - before,
          1,
          reason: 'multiple forceRepaint calls in one frame coalesce to one',
        );
      },
    );
  });

  group('TerminalRenderBox output settle tick (#918 backend clock)', () {
    testWidgets(
      'a PTY-output burst ARMS the one-shot settle tick; firing it forces a full '
      'frame re-read',
      (tester) async {
        final scheduled = <void Function()>[];
        await tester.pumpWidget(wrap(terminal));
        // Let any mount-time settle tick (the initial grid populate) elapse with
        // the real timer, so we assert on a QUIET baseline.
        await tester.pump(const Duration(milliseconds: 200));
        final box = tester.renderObject<TerminalRenderBox>(
          find.byType(TerminalRenderer),
        );
        box.debugSetOutputSettleTickFactory(
          (_, cb) {
            scheduled.add(cb);
            // A no-op timer captured for the box's `_outputSettleTimer` handle;
            // cancel it immediately so it never lands as a pending timer at
            // teardown — the test fires `cb` itself to model the window elapsing.
            return Timer(const Duration(days: 1), () {})..cancel();
          },
        );

        expect(box.debugOutputTickArmed, isFalse,
            reason: 'idle (settled) before any new output: tick not armed');

        // Output burst.
        writeUtf8(terminal, 'streaming output line\r\n');
        await tester.pump();

        expect(box.debugOutputTickArmed, isTrue,
            reason: 'output arms the settle tick');
        expect(scheduled, isNotEmpty,
            reason: 'a timer was scheduled by the output burst');

        final forcedBefore = box.debugForceRepaintCount;
        // Fire the settle timer (simulating the ~60ms window elapsing).
        for (final cb in scheduled) {
          cb();
        }
        await tester.pump();

        expect(box.debugForceRepaintCount, greaterThan(forcedBefore),
            reason: 'the settle tick forces a frame');
        expect(box.debugOutputTickArmed, isFalse,
            reason: 'the tick fires ONCE then disarms (no free-run)');
      },
    );

    testWidgets(
      'PERF GUARD (#805): when idle (no input, no output) the settle tick NEVER '
      'arms or fires — zero forced repaints',
      (tester) async {
        final scheduled = <void Function()>[];
        await tester.pumpWidget(wrap(terminal));
        // Let the mount-time settle tick (initial grid populate) elapse with the
        // real timer, so we measure a QUIET baseline.
        await tester.pump(const Duration(milliseconds: 200));
        final box = tester.renderObject<TerminalRenderBox>(
          find.byType(TerminalRenderer),
        );
        box.debugSetOutputSettleTickFactory(
          (_, cb) {
            scheduled.add(cb);
            return Timer(const Duration(days: 1), () {})..cancel();
          },
        );

        final forcedBefore = box.debugForceRepaintCount;

        // Idle: several frames with NO output and NO input.
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(box.debugOutputTickArmed, isFalse,
            reason: 'idle never arms the tick');
        expect(scheduled, isEmpty,
            reason: 'idle schedules no settle timer (no free-run)');
        expect(box.debugForceRepaintCount, forcedBefore,
            reason: 'idle produces zero forced repaints (#805 battery guard)');
      },
    );
  });
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
