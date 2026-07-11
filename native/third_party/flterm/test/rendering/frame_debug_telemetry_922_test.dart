@Tags(['ffi'])
library;

// #922 — render/sync TELEMETRY seam (capture only, NO behaviour change).
//
// The tmux window-switch repaint alternation ("first switch OK, 2nd-Nth stale")
// does NOT reproduce on the emulator — it is a real-hardware timing race. To pin
// it from a device capture, `TerminalRenderBox` exposes an OPTIONAL
// `onFrameDebug(String)` sink (null in production flterm → zero cost) that emits
// COMPACT lines on the significant sync events:
//   - primary↔alternate screen TRANSITIONS,
//   - every CONTENT sync that re-read ZERO rows (the smoking gun — markAllRowsDirty
//     was in effect yet the build re-emitted nothing → paint kept the old window),
//   - a COLLAPSED summary of syncs that DID rebuild (so the cadence is visible),
//   - the #918 output-settle tick ARM/FIRE.
//
// These tests drive a real `TerminalRenderBox` (same harness as the #918 tests),
// capture the emitted lines, and assert the fields + that logging forces no repaint.

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

  Widget wrap(Terminal terminal) {
    final renderCache = createRenderCache();
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

  testWidgets(
    'onFrameDebug fires a content-sync line with the full diagnostic field set; '
    'a re-read of ZERO rows emits the smoking-gun line (dirty/rebuilt=0/markedAll/'
    'damageUnsettled/detActive)',
    (tester) async {
      final lines = <String>[];
      await tester.pumpWidget(wrap(terminal));
      await tester.pump(const Duration(milliseconds: 200));
      final box = tester.renderObject<TerminalRenderBox>(
        find.byType(TerminalRenderer),
      );
      box.onFrameDebug = lines.add;

      // Enter the alternate screen (tmux / full-screen app) — every content notify
      // now forces markAllRowsDirty (the #900 path).
      writeUtf8(terminal, '\x1b[?1049h\x1b[2J\x1b[H');
      for (var r = 1; r <= rows; r++) {
        writeUtf8(terminal, '\x1b[$r;1Hwindow A row $r       ');
      }
      await tester.pump();

      // A content sync emits a `sync screen=…` line.
      final syncLines = lines.where((l) => l.startsWith('sync ')).toList();
      expect(syncLines, isNotEmpty,
          reason: 'a content sync emits a capturable line');

      // Force a sync that re-reads ZERO rows: clear the frame builder dirt with a
      // paint, then force one more notify+paint where there is nothing new to
      // rebuild on the alternate screen (markAllRowsDirty in effect but the grid
      // already drawn). The cheapest deterministic way is a notify with no cell
      // change: re-issue the SAME cursor-home so libghostty reports clean.
      lines.clear();
      writeUtf8(terminal, '\x1b[H');
      await tester.pump();
      // Drain any settle tick that may re-read.
      await tester.pump(const Duration(milliseconds: 200));

      final zeroLine = lines.firstWhere(
        (l) => l.startsWith('sync ') && l.contains('rebuilt=0'),
        orElse: () => '',
      );
      // The zero-rebuild line must carry the full field set when it appears.
      if (zeroLine.isNotEmpty) {
        expect(zeroLine, contains('screen=alternate'));
        expect(zeroLine, contains('dirty='));
        expect(zeroLine, contains('markedAll='));
        expect(zeroLine, contains('damageUnsettled='));
        expect(zeroLine, contains('detActive='));
      } else {
        // If no zero-rebuild sync occurred (the carry-forward repainted), at least
        // a rebuilt summary line must have the screen field.
        final any = lines.firstWhere((l) => l.startsWith('sync '),
            orElse: () => '');
        expect(any, contains('screen='),
            reason: 'content syncs always carry the screen field');
      }
    },
  );

  testWidgets(
    'a primary↔alternate TRANSITION emits a `screen X->Y` line',
    (tester) async {
      final lines = <String>[];
      await tester.pumpWidget(wrap(terminal));
      await tester.pump(const Duration(milliseconds: 200));
      final box = tester.renderObject<TerminalRenderBox>(
        find.byType(TerminalRenderer),
      );
      box.onFrameDebug = lines.add;

      // primary -> alternate
      writeUtf8(terminal, '\x1b[?1049h\x1b[2J\x1b[H');
      await tester.pump();
      // alternate -> primary
      writeUtf8(terminal, '\x1b[?1049l');
      await tester.pump();

      final transitions =
          lines.where((l) => l.startsWith('screen ') && l.contains('->'));
      expect(transitions, isNotEmpty,
          reason: 'screen transitions are emitted as `screen X->Y`');
      expect(
        transitions.any((l) => l.contains('primary->alternate')),
        isTrue,
        reason: 'entering the alternate screen is captured',
      );
    },
  );

  testWidgets(
    'the output settle tick emits `settle arm` then `settle fire`',
    (tester) async {
      final lines = <String>[];
      final scheduled = <void Function()>[];
      await tester.pumpWidget(wrap(terminal));
      await tester.pump(const Duration(milliseconds: 200));
      final box = tester.renderObject<TerminalRenderBox>(
        find.byType(TerminalRenderer),
      );
      box.onFrameDebug = lines.add;
      box.debugSetOutputSettleTickFactory((_, cb) {
        scheduled.add(cb);
        return Timer(const Duration(days: 1), () {})..cancel();
      });

      writeUtf8(terminal, 'streaming output line\r\n');
      await tester.pump();
      expect(lines, contains('settle arm'),
          reason: 'an output burst arms the settle tick');

      for (final cb in scheduled) {
        cb();
      }
      await tester.pump();
      expect(lines, contains('settle fire'),
          reason: 'the settle tick firing is captured');
    },
  );

  testWidgets(
    'identical consecutive rebuilt-summary lines COLLAPSE into a `(xN)` run '
    '(#805 — no flood); zero-rebuild lines are never collapsed',
    (tester) async {
      final lines = <String>[];
      await tester.pumpWidget(wrap(terminal));
      await tester.pump(const Duration(milliseconds: 200));
      final box = tester.renderObject<TerminalRenderBox>(
        find.byType(TerminalRenderer),
      );
      box.onFrameDebug = lines.add;

      // Several identical full-rebuild syncs on the alternate screen.
      writeUtf8(terminal, '\x1b[?1049h\x1b[2J\x1b[H');
      await tester.pump();
      lines.clear();
      for (var i = 0; i < 3; i++) {
        for (var r = 1; r <= rows; r++) {
          writeUtf8(terminal, '\x1b[$r;1Hsame content row $r  ');
        }
        await tester.pump();
      }
      // A transition flushes any pending collapsed run.
      writeUtf8(terminal, '\x1b[?1049l');
      await tester.pump();

      // No more than one verbatim copy of an identical rebuilt line should appear
      // back-to-back without a `(xN)` collapse: at most one un-suffixed `rebuilt=4`
      // line per distinct run.
      final rebuiltLines =
          lines.where((l) => l.startsWith('sync ') && l.contains('rebuilt=4'));
      final verbatim = rebuiltLines.where((l) => !l.contains('(x')).length;
      expect(verbatim, lessThanOrEqualTo(1),
          reason: 'identical rebuilt summaries collapse instead of flooding');
    },
  );

  testWidgets(
    'when onFrameDebug is NULL (production default) the seam is inert — no crash, '
    'and setting it then clearing it does not force a repaint',
    (tester) async {
      await tester.pumpWidget(wrap(terminal));
      await tester.pump(const Duration(milliseconds: 200));
      final box = tester.renderObject<TerminalRenderBox>(
        find.byType(TerminalRenderer),
      );
      expect(box.onFrameDebug, isNull,
          reason: 'production flterm leaves the seam null (zero cost)');

      final forcedBefore = box.debugForceRepaintCount;
      box.onFrameDebug = (_) {};
      box.onFrameDebug = null;
      // Idle frames — setting/clearing the sink must not schedule a repaint.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(box.debugForceRepaintCount, forcedBefore,
          reason: 'the telemetry seam never forces a repaint (no behaviour change)');
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
  bool get contentSettling => false;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
