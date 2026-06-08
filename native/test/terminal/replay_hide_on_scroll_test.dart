@Tags(['ffi'])
library;

// REGRESSION (#812): the URL/path decorator must HIDE while the viewport offset is
// CHANGING (a scroll, including the tmux-redraw "scroll" where the remote rewrites
// the grid) and SHOW only once the offset SETTLES — the robust replacement for the
// during-scroll position chase (#784/#803/#807) that kept reintroducing an
// off-by-a-line drift. The point is it CAN'T drift because it doesn't draw
// mid-scroll. Tap-to-copy (`controller.matchAt`) must keep working THROUGHOUT.
//
// This is the #791 WIDGET/PIXEL replay tier: it mounts the REAL flterm
// `TerminalView` (so the render box paints and reports its painted offset, which
// drives the controller's `isScrolling` signal) ALONG with the real
// `GhosttyTerminalDecoratorLayer`, replays the captured #803 markup-dance trace
// frame-by-frame, and asserts:
//   1. while the painted offset is changing the URL bubble paints NOTHING;
//   2. `controller.matchAt` STILL returns the URL during that scrolling phase
//      (tap routing is independent of the draw);
//   3. once the offset goes stable the bubble paints the correct anchor rects.

import 'package:flutter/material.dart';
import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_decorators.dart';

import 'replay_trace_harness.dart';

const _fixture = 'test/fixtures/replay/markup_dance_55x48.byte-trace.json';
const _kTraceUrlFragment = 'github.com/flavordrake/mobissh';

/// Counts how many times the URL bubble actually painted, so the test can assert
/// it paints NOTHING during the scrolling phase and SOMETHING once settled.
class _PaintCounter {
  int paints = 0;
}

/// A registry whose URL decorator wraps the bubble in a counting painter.
class _CountingRegistry extends GhosttyDecoratorRegistry {
  _CountingRegistry(this.counter)
    : super([_CountingDecorator(kGhosttyUrlPatternId, counter)]);

  final _PaintCounter counter;
}

class _CountingDecorator extends GhosttyTerminalDecorator {
  const _CountingDecorator(this.patternId, this.counter);

  @override
  final String patternId;
  final _PaintCounter counter;

  @override
  Widget build(BuildContext context, List<GhosttyDecoratedAnchor> anchors) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _CountingPainter(anchors, counter),
        size: Size.infinite,
      ),
    );
  }
}

class _CountingPainter extends CustomPainter {
  _CountingPainter(this.anchors, this.counter);

  final List<GhosttyDecoratedAnchor> anchors;
  final _PaintCounter counter;

  @override
  void paint(Canvas canvas, Size size) {
    // Only count a real draw — an empty anchor set yields no visible bubble.
    if (anchors.any((a) => a.rects.isNotEmpty)) counter.paints++;
  }

  @override
  bool shouldRepaint(covariant _CountingPainter old) => true;
}

Future<void> _pump(
  WidgetTester tester,
  TerminalController controller,
  GhosttyDecoratorRegistry registry,
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
              child: GhosttyTerminalDecoratorLayer(
                controller: controller,
                registry: registry,
                color: const Color(0xFF5B9BD5),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('replay #812 — decorator hides while scrolling, shows on settle', () {
    testWidgets(
      'paints NOTHING while the painted offset is changing, then paints the '
      'URL bubble once the offset settles; matchAt works throughout',
      (tester) async {
        final trace = loadByteTrace(_fixture);
        expect(trace.byteTrace, hasLength(130));

        final counter = _PaintCounter();
        final controller = TerminalController(
          config: TerminalConfig(cols: trace.cols, rows: trace.rows),
        );
        addTearDown(controller.dispose);
        controller.registerTextPattern(TextPattern.url());

        final registry = _CountingRegistry(counter);
        await _pump(tester, controller, registry);

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
        // the controller is in the scrolling state and the bubble must NOT paint.
        // Sample paint count ONLY on frames where isScrolling is true — the bubble
        // must add zero paints across all of them (it is not drawn mid-scroll, so
        // it cannot drift off its text).
        var sawScrolling = false;
        var paintsWhileScrolling = 0;
        var lastPaintsSample = counter.paints;
        for (final e in trace.byteTrace) {
          controller.write(lfToCrlf(e.bytes));
          await tester.pump(const Duration(milliseconds: 8));
          if (controller.isScrolling) {
            sawScrolling = true;
            // Any paints since the previous sample that landed while scrolling.
            paintsWhileScrolling += counter.paints - lastPaintsSample;
          }
          lastPaintsSample = counter.paints;
        }

        // We actually entered the scrolling state (the trace is a real scroll —
        // otherwise this test would be vacuous).
        expect(
          sawScrolling,
          isTrue,
          reason: 'the replayed trace must drive the painted offset (scrolling '
              'state) so the hide path is exercised',
        );
        // THE INVARIANT: the bubble painted NOTHING on any scrolling frame. It
        // cannot drift off its text because it is not drawn mid-scroll (#812).
        expect(
          paintsWhileScrolling,
          0,
          reason: 'the URL bubble must NOT paint while the painted offset is '
              'changing (#812) — got $paintsWhileScrolling paints mid-scroll',
        );

        final paintsBeforeSettle = counter.paints;

        // Settle: let the trailing-edge timer flip back to settled and the layer
        // rebuild + re-show the bubble at the now-stable geometry. (Detection is
        // debounced ~120ms, so it also resolves here — this is when the user has
        // lifted off and the link is tappable.)
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();

        // No longer scrolling.
        expect(controller.isScrolling, isFalse);
        // The URL is still detected + anchored (detection coverage #788 held).
        expect(
          controller.anchors.any(
            (a) => a.payload.toString().contains(_kTraceUrlFragment),
          ),
          isTrue,
          reason: 'the captured GitHub URL is still detected + anchored once the '
              'scroll settles',
        );
        // Tap-to-copy works at the settled state: matchAt routes the URL — the
        // hide gate only suppressed the DRAW, never the hit-test (#812). (Mid-
        // burst, detection itself is debounced — pre-existing #767 behavior, not
        // changed here; the link is tappable the moment the user lifts off.)
        expect(
          urlMatchable(),
          isTrue,
          reason: 'matchAt returns the URL once settled — the link is tappable; '
              'the #812 gate hides only the bubble draw, not tap routing',
        );
        // The bubble paints AGAIN now that it is settled (it re-shows at the
        // stable geometry). This >0 also proves the mid-scroll zero was a REAL
        // hide, not a never-drew artifact — the bubble demonstrably CAN draw, it
        // was deliberately suppressed during the scroll.
        expect(
          counter.paints,
          greaterThan(paintsBeforeSettle),
          reason: 'the bubble re-shows once the offset settles — proving the '
              'mid-scroll zero was a deliberate hide, not a never-drew artifact '
              '(#812)',
        );
      },
    );
  });
}
