@Tags(['ffi'])
library;

// PERF REGRESSION (#805 / #955): scrolling a full-repaint tmux TUI feels clunky
// because the remote rewrites all 48 rows via cursor addressing on every scroll
// step (262 KB / 3,763 CUP moves / 130 redraw chunks over ~8.4s). We can't change
// the remote, but we CAN bound what MobiSSH ADDS per redraw during a streaming
// scroll.
//
// This test replays the real captured #803 markup-dance trace (the same 55x48
// full-repaint capture, reused as the #805 perf fixture) through the WIDGET tier —
// the real flterm TerminalView + a gutter-equivalent probe — and MEASURES the
// MobiSSH-added per-redraw overhead:
//
//   1. decoration LAYER REBUILDS — the ListenableBuilder rebuild count.
//   2. gutter-row RESOLUTIONS — the geometry re-resolve count (`anchorGutterRow`,
//      the analogue of the old `anchorRects`: _renderState.update + row math).
//   3. mark RENDERS — the count of settled builds that produced a mark.
//
// #955 retired the inline decorator; the right-edge GUTTER ([GhosttyGutterLayer])
// inherits the #805 coalescing (it listens to the narrow `decorationListenable`
// and gates on `isScrolling`). The probe below mirrors that consumption so the
// SAME bound is pinned: a regression back to a per-notify re-resolve fails here.

import 'dart:typed_data' show Uint8List;

import 'package:flutter/material.dart';
import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter_test/flutter_test.dart';

import 'replay_trace_harness.dart';

const _fixture = 'test/fixtures/replay/markup_dance_55x48.byte-trace.json';
const _kTraceUrlFragment = 'github.com/flavordrake/mobissh';

/// Counts the three MobiSSH-added per-redraw overheads the #805 throttle bounds.
class _PerfCounters {
  int layerBuilds = 0;
  int anchorResolves = 0;
  int paints = 0;
  // The number of times the controller's GENERAL notify fired — what a per-notify
  // consumer would rebuild on. The narrow decorationListenable fires a strict
  // subset, so layerBuilds ≤ generalNotifies proves the coalescing.
  int generalNotifies = 0;
}

/// A gutter-equivalent probe: listens to the narrow decoration signal, gates on
/// `isScrolling`, and resolves each anchor's gutter row — counting each rebuild,
/// each row resolve, and each settled build that yields a mark. Mirrors
/// [GhosttyGutterLayer]'s consumption without depending on its widgets.
class _GutterProbe extends StatelessWidget {
  const _GutterProbe({required this.controller, required this.counters});

  final TerminalController controller;
  final _PerfCounters counters;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller.decorationListenable,
      builder: (context, _) {
        counters.layerBuilds++;
        if (controller.isScrolling) return const SizedBox.shrink();
        var marks = 0;
        for (final anchor in controller.anchors) {
          // One geometry resolve per anchor (breaks at the first on-screen row),
          // the analogue of the old per-anchor anchorRects resolve.
          counters.anchorResolves++;
          for (final range in anchor.ranges) {
            if (controller.anchorGutterRow(range) != null) {
              marks++;
              break;
            }
          }
        }
        if (marks > 0) counters.paints++;
        return const SizedBox.shrink();
      },
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  TerminalController controller,
  _PerfCounters counters,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: TerminalView(
                controller: controller,
                autofocus: false,
                theme: TerminalTheme.dark().copyWith(fontSize: 14),
                padding: const EdgeInsets.all(4),
              ),
            ),
            Positioned.fill(
              child: _GutterProbe(controller: controller, counters: counters),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('replay #805 — bound MobiSSH per-redraw overhead during tmux scroll', () {
    testWidgets(
      'gutter re-resolves/renders are bounded well below the redraw-chunk count '
      '(throttled to settle), while the URL stays detected + anchored',
      (tester) async {
        final trace = loadByteTrace(_fixture);
        expect(trace.byteTrace, hasLength(130));

        final counters = _PerfCounters();
        final controller = TerminalController(
          config: TerminalConfig(cols: trace.cols, rows: trace.rows),
        );
        addTearDown(controller.dispose);
        controller.registerTextPattern(TextPattern.url());

        controller.addListener(() => counters.generalNotifies++);

        await _pump(tester, controller, counters);

        for (final e in trace.byteTrace) {
          controller.write(lfToCrlf(e.bytes));
          await tester.pump(const Duration(milliseconds: 8));
        }
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();

        expect(
          controller.anchors.any(
            (a) => a.payload.toString().contains(_kTraceUrlFragment),
          ),
          isTrue,
          reason: 'the captured GitHub URL is still detected + anchored after '
              'the scroll settles (throttle must not drop final detection)',
        );

        expect(
          counters.generalNotifies,
          greaterThan(20),
          reason: 'the controller notifies many times over a streaming scroll '
              '(got ${counters.generalNotifies})',
        );

        expect(
          counters.layerBuilds,
          lessThan(counters.generalNotifies ~/ 2),
          reason: 'the gutter must NOT rebuild on every general controller notify '
              'during a scroll — it coalesces onto decoration-relevant changes '
              'only (builds=${counters.layerBuilds}, '
              'generalNotifies=${counters.generalNotifies})',
        );

        expect(
          counters.anchorResolves,
          lessThanOrEqualTo(counters.layerBuilds),
          reason: 'anchorGutterRow resolves only inside a coalesced rebuild (got '
              '${counters.anchorResolves})',
        );

        expect(
          counters.paints,
          lessThan(10),
          reason: 'the gutter must not render on every redraw chunk (got '
              '${counters.paints})',
        );
      },
    );

    testWidgets(
      'coalescing does NOT starve a live anchor: once a URL is detected, the '
      'settled re-scan after new output still wakes the gutter',
      (tester) async {
        final counters = _PerfCounters();
        final controller = TerminalController(
          config: const TerminalConfig(cols: 55, rows: 10),
        );
        addTearDown(controller.dispose);
        controller.registerTextPattern(TextPattern.url());

        await _pump(tester, controller, counters);

        controller.write(
          Uint8List.fromList('https://$_kTraceUrlFragment here\r\n'.codeUnits),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();

        expect(
          controller.anchors.any(
            (a) => a.payload.toString().contains(_kTraceUrlFragment),
          ),
          isTrue,
          reason: 'URL detected — there IS a live anchor to track',
        );

        final buildsBeforeOutput = counters.layerBuilds;

        // #1044 amendment: output that changes NOTHING decoration-relevant is
        // now correctly INVISIBLE to the gutter (an unchanged reconcile
        // suppresses its notify — the #1046 churn killer). The starvation
        // probe therefore appends output that CHANGES the anchor set: a new
        // URL must wake the gutter once the settled re-scan lands.
        controller.write(
          Uint8List.fromList(
            'and now https://second.example.com/starve too\r\n'.codeUnits,
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(
          controller.anchors.any(
            (a) => a.payload.toString().contains('second.example.com'),
          ),
          isTrue,
          reason: 'the appended URL is detected',
        );
        expect(
          counters.layerBuilds,
          greaterThan(buildsBeforeOutput),
          reason: 'an anchor-set CHANGE after new output must still rebuild '
              'the gutter — the #805 gate must not over-throttle '
              '(before=$buildsBeforeOutput, after=${counters.layerBuilds})',
        );

        expect(
          controller.anchors.any(
            (a) => a.payload.toString().contains(_kTraceUrlFragment),
          ),
          isTrue,
          reason: 'URL still detected after more output (#788 coverage held)',
        );
      },
    );
  });
}
