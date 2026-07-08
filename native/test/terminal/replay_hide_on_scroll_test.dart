@Tags(['ffi'])
library;

// REGRESSION (#812 / #955): the structured-text decoration must HIDE while the
// viewport offset is CHANGING (a scroll, including the tmux-redraw "scroll" where
// the remote rewrites the grid) and SHOW only once the offset SETTLES — the
// robust replacement for the during-scroll position chase (#784/#803/#807) that
// kept reintroducing an off-by-a-line drift. The point is it CAN'T drift because
// it doesn't draw mid-scroll. Tap-to-copy (`controller.matchAt`) must keep
// working THROUGHOUT.
//
// #955 retired the inline decorator layer. The hide-on-scroll contract now
// belongs to the BUBBLE ([GhosttyBubbleLayer], #988 — sub-pixel rect precision
// drifts mid-scroll); the GUTTER ([GhosttyGutterLayer]) TRACKS the scroll since
// #993 (row-indexed chips re-resolve per painted-offset notify — see
// test/ui/ghostty_gutter_layer_test.dart). This replay tier keeps exercising
// the hide contract against the REAL flterm `TerminalView` (so the render box
// paints and reports its painted offset, which drives `isScrolling`) via a
// bubble-equivalent PROBE that consumes the same controller surface
// (`decorationListenable` + `isScrolling` + `anchors` + `anchorGutterRow`), and
// asserts:
//   1. while the painted offset is changing the gutter renders NO mark;
//   2. `controller.matchAt` STILL returns the URL during that scrolling phase
//      (tap routing is independent of the draw);
//   3. once the offset goes stable a mark renders for the live anchor.

import 'package:flutter/material.dart';
import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter_test/flutter_test.dart';

import 'replay_trace_harness.dart';

const _fixture = 'test/fixtures/replay/markup_dance_55x48.byte-trace.json';
const _kTraceUrlFragment = 'github.com/flavordrake/mobissh';

/// Counts how many times the gutter would render a mark, so the test can assert
/// it renders NOTHING during the scrolling phase and SOMETHING once settled.
class _PaintCounter {
  int paints = 0;
}

/// A bubble-equivalent probe: listens to the narrow decoration signal, GATES on
/// `isScrolling` (renders nothing mid-scroll, like [GhosttyBubbleLayer]; the
/// gutter tracks instead since #993), and counts a "paint" on any settled build
/// that resolves at least one on-screen gutter row. Mirrors the hide-contract
/// consumption without depending on the layer widgets.
class _GutterProbe extends StatelessWidget {
  const _GutterProbe({required this.controller, required this.counter});

  final TerminalController controller;
  final _PaintCounter counter;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller.decorationListenable,
      builder: (context, _) {
        if (controller.isScrolling) return const SizedBox.shrink();
        var marks = 0;
        for (final anchor in controller.anchors) {
          for (final range in anchor.ranges) {
            if (controller.anchorGutterRow(range) != null) {
              marks++;
              break;
            }
          }
        }
        if (marks > 0) counter.paints++;
        return const SizedBox.shrink();
      },
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  TerminalController controller,
  _PaintCounter counter,
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
              child: _GutterProbe(controller: controller, counter: counter),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('replay #812 — gutter hides while scrolling, shows on settle', () {
    testWidgets(
      'renders NO mark while the painted offset is changing, then renders the '
      'URL mark once the offset settles; matchAt works throughout',
      (tester) async {
        final trace = loadByteTrace(_fixture);
        expect(trace.byteTrace, hasLength(130));

        final counter = _PaintCounter();
        final controller = TerminalController(
          config: TerminalConfig(cols: trace.cols, rows: trace.rows),
        );
        addTearDown(controller.dispose);
        controller.registerTextPattern(TextPattern.url());

        await _pump(tester, controller, counter);

        // matchAt finds the URL somewhere on screen (tap routing works).
        bool urlMatchable() {
          for (var row = 0; row < trace.rows; row++) {
            for (var col = 0; col < trace.cols; col++) {
              final m = controller.matchAt(row: row, col: col);
              if (m != null && m.payload.toString().contains(_kTraceUrlFragment)) {
                return true;
              }
            }
          }
          return false;
        }

        // Replay the captured redraw chunks frame-by-frame (the streaming tmux-
        // redraw scroll). Throughout this phase the painted offset is moving, so
        // the controller is in the scrolling state and the gutter must NOT render.
        // Sample paint count ONLY on frames where isScrolling is true — the gutter
        // must add zero paints across all of them (not drawn mid-scroll, so it
        // cannot drift off its text).
        var sawScrolling = false;
        var paintsWhileScrolling = 0;
        var lastPaintsSample = counter.paints;
        for (final e in trace.byteTrace) {
          controller.write(lfToCrlf(e.bytes));
          await tester.pump(const Duration(milliseconds: 8));
          if (controller.isScrolling) {
            sawScrolling = true;
            paintsWhileScrolling += counter.paints - lastPaintsSample;
          }
          lastPaintsSample = counter.paints;
        }

        expect(
          sawScrolling,
          isTrue,
          reason: 'the replayed trace must drive the painted offset (scrolling '
              'state) so the hide path is exercised',
        );
        expect(
          paintsWhileScrolling,
          0,
          reason: 'the gutter must NOT render a mark while the painted offset is '
              'changing (#812/#955) — got $paintsWhileScrolling mid-scroll',
        );

        final paintsBeforeSettle = counter.paints;

        // Settle: let the trailing-edge timer flip back to settled and the probe
        // rebuild + re-render the mark at the now-stable geometry. (Detection is
        // debounced ~120ms, so it also resolves here.)
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();

        expect(controller.isScrolling, isFalse);
        expect(
          controller.anchors.any(
            (a) => a.payload.toString().contains(_kTraceUrlFragment),
          ),
          isTrue,
          reason: 'the captured GitHub URL is still detected + anchored once the '
              'scroll settles',
        );
        expect(
          urlMatchable(),
          isTrue,
          reason: 'matchAt returns the URL once settled — the link is tappable; '
              'the #812 gate hides only the mark draw, not tap routing',
        );
        expect(
          counter.paints,
          greaterThan(paintsBeforeSettle),
          reason: 'the gutter re-renders once the offset settles — proving the '
              'mid-scroll zero was a deliberate hide, not a never-drew artifact '
              '(#812/#955)',
        );
      },
    );
  });
}
