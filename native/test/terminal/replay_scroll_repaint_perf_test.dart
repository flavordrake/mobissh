@Tags(['ffi'])
library;

// PERF REGRESSION (#805): scrolling a full-repaint tmux TUI feels clunky because
// the remote rewrites all 48 rows via cursor addressing on every scroll step
// (262 KB / 3,763 CUP moves / 130 redraw chunks over ~8.4s). We can't change the
// remote, but we CAN bound what MobiSSH ADDS per redraw during a streaming scroll.
//
// This test replays the real captured #803 markup-dance trace (the same 55x48
// full-repaint capture, reused as the #805 perf fixture) through the WIDGET tier
// — the real flterm TerminalView + the real GhosttyTerminalDecoratorLayer — and
// MEASURES the MobiSSH-added per-redraw overhead:
//
//   1. decorator LAYER REBUILDS — the ListenableBuilder rebuild count (each one
//      re-resolves every anchor's rects via controller.anchorRects).
//   2. anchorRects RESOLUTIONS — the geometry re-resolve count (the dominant
//      MobiSSH-added per-redraw cost: _renderState.update + AnchorGeometry math).
//   3. decorator PAINTS — the CustomPainter.paint count for the URL bubble.
//
// The #805 fix throttles the decorator re-resolve onto a trailing-edge frame
// throttle (it need not re-resolve on EVERY one of ~15 redraw chunks/sec mid-
// fling — only when scroll/output SETTLES), so these counts drop sharply while
// the END STATE (URL still detected + anchored + bubble drawn once settled) is
// unchanged. The assertions PIN that bound so a regression (going back to a
// per-notify re-resolve) fails the gate.

import 'dart:typed_data' show Uint8List;

import 'package:flutter/material.dart';
import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_decorators.dart';

import 'replay_trace_harness.dart';

const _fixture = 'test/fixtures/replay/markup_dance_55x48.byte-trace.json';
const _kTraceUrlFragment = 'github.com/flavordrake/mobissh';

/// Counts how many times the decorator layer rebuilt, how many anchorRects
/// resolutions it issued, and how many times the URL bubble painter painted —
/// the three MobiSSH-added per-redraw overheads the #805 throttle bounds.
class _PerfCounters {
  int layerBuilds = 0;
  int anchorResolves = 0;
  int paints = 0;
  // The number of times the controller's GENERAL notify fired — what the OLD
  // decorator layer (pre-#805) rebuilt on. The narrow decorationListenable
  // fires a strict subset (only decoration-relevant changes), so layerBuilds
  // ≤ generalNotifies proves the coalescing.
  int generalNotifies = 0;
}

/// A registry whose decorators wrap the real ones in a counting painter so the
/// test can observe how many times the bubble actually repaints.
class _CountingRegistry extends GhosttyDecoratorRegistry {
  _CountingRegistry(this.counters)
    : super([_CountingDecorator(kGhosttyUrlPatternId, counters)]);

  final _PerfCounters counters;
}

class _CountingDecorator extends GhosttyTerminalDecorator {
  const _CountingDecorator(this.patternId, this.counters);

  @override
  final String patternId;
  final _PerfCounters counters;

  @override
  Widget build(BuildContext context, List<GhosttyDecoratedAnchor> anchors) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _CountingPainter(anchors, counters),
        size: Size.infinite,
      ),
    );
  }
}

class _CountingPainter extends CustomPainter {
  _CountingPainter(this.anchors, this.counters);

  final List<GhosttyDecoratedAnchor> anchors;
  final _PerfCounters counters;

  @override
  void paint(Canvas canvas, Size size) {
    counters.paints++;
  }

  @override
  bool shouldRepaint(covariant _CountingPainter old) {
    if (old.anchors.length != anchors.length) return true;
    for (var i = 0; i < anchors.length; i++) {
      if (old.anchors[i].rects.length != anchors[i].rects.length) return true;
      for (var j = 0; j < anchors[i].rects.length; j++) {
        if (old.anchors[i].rects[j] != anchors[i].rects[j]) return true;
      }
    }
    return false;
  }
}

/// A decorator layer that delegates to the real [GhosttyTerminalDecoratorLayer]
/// but counts each rebuild and each anchorRects resolution it triggers.
class _CountingLayer extends StatelessWidget {
  const _CountingLayer({
    required this.controller,
    required this.registry,
    required this.counters,
  });

  final TerminalController controller;
  final GhosttyDecoratorRegistry registry;
  final _PerfCounters counters;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller.decorationListenable,
      builder: (context, _) {
        counters.layerBuilds++;
        final byDecorator =
            <GhosttyTerminalDecorator, List<GhosttyDecoratedAnchor>>{};
        for (final anchor in controller.anchors) {
          final decorator = registry.forPattern(anchor.patternId);
          if (decorator == null) continue;
          final rects = <Rect>[];
          for (final range in anchor.ranges) {
            counters.anchorResolves++;
            rects.addAll(controller.anchorRects(range));
          }
          if (rects.isEmpty) continue;
          byDecorator.putIfAbsent(decorator, () => []).add(
                GhosttyDecoratedAnchor(
                  payload: anchor.payload,
                  rects: rects,
                  color: const Color(0xFF5B9BD5),
                ),
              );
        }
        if (byDecorator.isEmpty) return const SizedBox.shrink();
        return Stack(
          fit: StackFit.expand,
          children: [
            for (final entry in byDecorator.entries)
              entry.key.build(context, entry.value),
          ],
        );
      },
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  TerminalController controller,
  GhosttyDecoratorRegistry registry,
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
              child: _CountingLayer(
                controller: controller,
                registry: registry,
                counters: counters,
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

  group('replay #805 — bound MobiSSH per-redraw overhead during tmux scroll', () {
    testWidgets(
      'decorator re-resolves/paints are bounded well below the redraw-chunk '
      'count (throttled to settle), while the URL stays detected + anchored',
      (tester) async {
        final trace = loadByteTrace(_fixture);
        expect(trace.byteTrace, hasLength(130));

        final counters = _PerfCounters();
        final controller = TerminalController(
          config: TerminalConfig(cols: trace.cols, rows: trace.rows),
        );
        addTearDown(controller.dispose);
        controller.registerTextPattern(TextPattern.url());

        // Count the controller's GENERAL notify (the pre-#805 decorator's
        // listenable) so the test can prove the narrow listener fires a subset.
        controller.addListener(() => counters.generalNotifies++);

        final registry = _CountingRegistry(counters);
        await _pump(tester, controller, registry, counters);

        // Replay the captured redraw chunks frame-by-frame at the device cadence
        // (each tmux redraw is its own write + a frame), which is the streaming
        // scroll the per-redraw overhead accumulates over.
        for (final e in trace.byteTrace) {
          controller.write(lfToCrlf(e.bytes));
          await tester.pump(const Duration(milliseconds: 8));
        }
        // Settle the detection debounce + the throttle's trailing edge.
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();

        // CORRECTNESS (unchanged by the throttle): the URL is still detected and
        // anchored once the scroll settles — #788 coverage preserved.
        expect(
          controller.anchors.any(
            (a) => a.payload.toString().contains(_kTraceUrlFragment),
          ),
          isTrue,
          reason: 'the captured GitHub URL is still detected + anchored after '
              'the scroll settles (throttle must not drop final detection)',
        );

        // The controller's GENERAL notify fired many times over the scroll (the
        // pre-#805 decorator listened to THIS and rebuilt on every one). This is
        // the baseline the coalescing improves on — assert it really is large so
        // the comparison below is meaningful and not vacuous.
        expect(
          counters.generalNotifies,
          greaterThan(20),
          reason: 'the controller notifies many times over a streaming scroll — '
              'the pre-#805 per-notify decorator rebuilt on each (got '
              '${counters.generalNotifies})',
        );

        // THE PERF BOUND (#805): the decorator layer rebuilds (each one re-
        // resolves every anchor's rects) must be a SMALL FRACTION of the general
        // notify count. The narrow decorationListenable fires only when the
        // anchor set changes (settled re-scan) or — with anchors present — the
        // painted offset moves; while NO markup is on screen mid-scroll it never
        // wakes the decorator. Pre-fix layerBuilds == generalNotifies (42 == 42);
        // post-fix it collapses to the few settle builds. A regression back to a
        // per-notify rebuild blows past this ceiling.
        expect(
          counters.layerBuilds,
          lessThan(counters.generalNotifies ~/ 2),
          reason: 'the decorator layer must NOT rebuild on every general '
              'controller notify during a scroll — it coalesces onto decoration-'
              'relevant changes only (builds=${counters.layerBuilds}, '
              'generalNotifies=${counters.generalNotifies})',
        );

        // The EXPENSIVE geometry re-resolve is bounded to the decoration-changed
        // builds, never per redraw chunk.
        expect(
          counters.anchorResolves,
          lessThanOrEqualTo(counters.layerBuilds),
          reason: 'anchorRects resolves only inside a decorator rebuild, which is '
              'coalesced (got ${counters.anchorResolves})',
        );

        // The decorator bubble repaints are likewise bounded — a paint per redraw
        // chunk is the clunk this trims.
        expect(
          counters.paints,
          lessThan(10),
          reason: 'the URL bubble must not repaint on every redraw chunk (got '
              '${counters.paints})',
        );
      },
    );

    testWidgets(
      'coalescing does NOT starve a live anchor: once a URL is detected, the '
      'settled re-scan after new output still wakes the decorator (no over-'
      'throttle of the case that actually needs to track)',
      (tester) async {
        final counters = _PerfCounters();
        final controller = TerminalController(
          config: const TerminalConfig(cols: 55, rows: 10),
        );
        addTearDown(controller.dispose);
        controller.registerTextPattern(TextPattern.url());

        final registry = _CountingRegistry(counters);
        await _pump(tester, controller, registry, counters);

        // Put a URL on screen and let the first detection settle.
        controller.write(
          Uint8List.fromList('https://$_kTraceUrlFragment here\r\n'.codeUnits),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();

        // The URL is detected + anchored — the live anchor whose bubble must keep
        // tracking. (#788 coverage preserved by the throttle.)
        expect(
          controller.anchors.any(
            (a) => a.payload.toString().contains(_kTraceUrlFragment),
          ),
          isTrue,
          reason: 'URL detected — there IS a live anchor to track',
        );

        final buildsBeforeOutput = counters.layerBuilds;

        // Stream more output WITH the anchor present: the debounced re-scan
        // settles and wakes the narrow decoration signal, so the decorator
        // re-resolves the URL's rects against the freshly-painted content — the
        // #805 gate suppresses only the NO-anchor case, never this one.
        controller.write(
          Uint8List.fromList('more output appended below\r\n'.codeUnits),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();

        expect(
          counters.layerBuilds,
          greaterThan(buildsBeforeOutput),
          reason: 'with a live anchor on screen, a settled re-scan after new '
              'output must still rebuild the decorator so the bubble tracks the '
              'text — the #805 gate must not over-throttle (builds before='
              '$buildsBeforeOutput, after=${counters.layerBuilds})',
        );

        // Still detected after the additional output — detection coverage intact.
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
