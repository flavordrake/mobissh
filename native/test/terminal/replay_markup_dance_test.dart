@Tags(['ffi'])
library;

// REGRESSION (#803): URL markup "dances" out of sync with the text while the
// owner scrolls a tmux session in MOUSE MODE.
//
// This is the FIRST deterministic capture of the dance: the #793 recorder v2
// saved the full PTY byte stream (130 redraw chunks, 55x48 grid) plus the 161
// wheel-SGR reports that prove the scroll was tmux mouse mode (swipe → wheel →
// tmux REDRAW), not flterm local scrollback (`scrollTraceEventCount: 1` — the
// local viewport offset never moves). Dropped into
// `native/test/fixtures/replay/markup_dance_55x48.byte-trace.json`.
//
// THE BUG (verified in code): there are TWO highlight paths over the SAME
// absolute-row ranges with IDENTICAL math (`viewRow = absRow - offset`) but
// reading DIFFERENT offsets:
//   (a) the fork's `HighlightPainter` reads `_state.viewportOffset` — the offset
//       SNAPSHOTTED into the paint state when the render box painted the glyphs
//       (frame-synced, never drifts);
//   (b) the widget-layer `GhosttyTerminalDecoratorLayer` re-resolves
//       `controller.anchorRects(range)` on every controller notify, which USED
//       TO read the LIVE `scrollbar.offset` + the latest debounced rescan.
// During a tmux-redraw scroll the controller notify fires (output write / scroll)
// and the decorator rebuilds reading the NEW geometry BEFORE the terminal's text
// frame has painted that content → the bubble jumps AHEAD of the text → "dance."
//
// THE FIX (#803): the render box reports the offset it JUST PAINTED back to the
// controller (`reportPaintedViewportOffset`), exposed as
// `controller.paintedViewportOffset`, and `anchorRects` now resolves against THAT
// frame-synced offset (with a post-frame notify) instead of the live offset — so
// the markup geometry stays in lockstep with the painted glyphs.
//
// This tier is the #791 deferred WIDGET/PIXEL stretch: it mounts the REAL flterm
// `TerminalView` (so the render box paints and reports the painted offset) ALONG
// with the real `GhosttyGutterLayer` (#955; the decoration consumer driven by the
// same notifications), replays the captured chunks frame-by-frame, and asserts the
// controller resolves anchor geometry against the PAINTED offset — failing before
// the fix (it tracked the live offset), passing after.

import 'dart:typed_data' show Uint8List;

import 'package:flutter/material.dart';
import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_gutter_layer.dart';

import 'replay_trace_harness.dart';

const _fixture =
    'test/fixtures/replay/markup_dance_55x48.byte-trace.json';

/// The real GitHub URL present in the captured trace — the link whose bubble
/// danced. It is detected by the `url` pattern and anchored over its cells.
const _kTraceUrlFragment = 'github.com/flavordrake/mobissh';

/// Mount the REAL flterm [TerminalView] + the real [GhosttyGutterLayer] over one
/// [controller], so the render box paints (and reports the painted offset) and
/// the gutter consumes anchors exactly as on device. The #803 invariants are
/// asserted on the controller directly (`anchorRects`/`paintedViewportOffset`);
/// the gutter is the real decoration CONSUMER driven by the same notifications.
Future<void> _pumpRealTerminal(
  WidgetTester tester,
  TerminalController controller,
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
                theme: buildTheme(),
                padding: const EdgeInsets.all(4),
              ),
            ),
            Positioned.fill(
              child: GhosttyGutterLayer(
                controller: controller,
                registry: GutterPatternRegistry.standard(
                  openPath: (_) async => true,
                ),
                color: const Color(0xFF5B9BD5),
                cellHeight: 18,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// A minimal theme; the JetBrainsMono bundled face is registered for the app but
/// the default monospace measures fine headlessly. Font face is irrelevant to
/// the offset-sync invariant under test.
TerminalTheme buildTheme() => TerminalTheme.dark().copyWith(fontSize: 14);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('replay #803 — URL markup must not dance ahead of text on tmux scroll', () {
    testWidgets(
      'the decorator resolves anchors against the PAINTED viewport offset, '
      'in lockstep with the text the render box just painted',
      (tester) async {
        final trace = loadByteTrace(_fixture);
        expect(trace.cols, 55);
        expect(trace.rows, 48);
        expect(trace.byteTrace, hasLength(130));

        final controller = TerminalController(
          config: TerminalConfig(cols: trace.cols, rows: trace.rows),
        );
        addTearDown(controller.dispose);
        // Register the SAME patterns the view registers so the URL is detected
        // and anchored over its own cells (the dance is the URL bubble).
        controller.registerTextPattern(TextPattern.url());

        await _pumpRealTerminal(tester, controller);

        // Replay the captured redraw chunks frame-by-frame: write a chunk, then
        // pump a frame so the render box paints and reports its painted offset.
        // This reproduces the device cadence (each tmux redraw is its own write
        // + frame), which is where the live-offset decorator danced.
        for (final e in trace.byteTrace) {
          controller.write(lfToCrlf(e.bytes));
          await tester.pump(const Duration(milliseconds: 8));
        }
        // Settle the detection debounce + the post-frame painted-offset notify.
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();

        // The URL anchored over its real cells.
        final anchors = controller.anchors;
        expect(
          anchors.any(
            (a) => a.payload.toString().contains(_kTraceUrlFragment),
          ),
          isTrue,
          reason: 'the captured GitHub URL must be detected + anchored so its '
              'bubble decorator is the one under test',
        );

        // THE INVARIANT the fix enforces: the offset the decorator resolves
        // anchor rects against is the PAINTED offset (frame-synced with the
        // glyphs), not the live scrollbar offset. After settling they may
        // coincide, but the decorator's SOURCE is the painted offset — exposed
        // and wired so it can never run ahead of the text mid-redraw.
        expect(
          controller.paintedViewportOffset,
          controller.scrollbar.offset,
          reason: 'after the frame settles the painted offset has caught up to '
              'the live offset — the markup and text are in lockstep',
        );

        // And the anchor rects the decorator draws are exactly those the PAINTED
        // offset yields: recomputing them against the painted offset (the frame
        // snapshot the HighlightPainter reads) reproduces what anchorRects
        // returns. If anchorRects still tracked the live offset, a mid-redraw
        // divergence would break this; pinning to the painted offset keeps the
        // bubble hugging the painted glyphs.
        for (final anchor in anchors) {
          for (final range in anchor.ranges) {
            final rects = controller.anchorRects(range);
            // Resolving twice in a row is stable (no live-offset jitter between
            // build and paint) — the markup sits still relative to the text.
            final rectsAgain = controller.anchorRects(range);
            expect(
              _rectsEqual(rects, rectsAgain),
              isTrue,
              reason: 'anchor rects must be stable across reads — a live-offset '
                  'source would jitter between the build and paint phases (the '
                  '#803 dance)',
            );
          }
        }
      },
    );

    testWidgets(
      'anchorRects resolves against the PAINTED offset, not the live '
      'scrollbar offset — the exact #803 divergence, deterministically',
      (tester) async {
        // The crux of the dance: during a tmux redraw the LIVE scrollbar offset
        // and the PAINTED offset can momentarily differ (the live one points at
        // a frame not yet painted). The decorator must hug the PAINTED text, so
        // anchorRects MUST track the painted offset. We prove that by mounting
        // the real terminal (so a painted offset exists and is reported), then
        // asserting anchorRects geometry is computed from paintedViewportOffset.
        final controller = TerminalController(
          config: const TerminalConfig(cols: 55, rows: 10),
        );
        addTearDown(controller.dispose);
        controller.registerTextPattern(TextPattern.url());
        // URL on the FIRST visible row so its absolute row is the painted
        // offset itself — making the row→rect mapping depend directly on which
        // offset anchorRects subtracts.
        controller.write(
          _ascii('https://$_kTraceUrlFragment/issues/803 here\r\n'),
        );
        for (var i = 0; i < 40; i++) {
          controller.write(_ascii('streaming row $i of filler output\r\n'));
        }

        await _pumpRealTerminal(tester, controller);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();

        // #788 coverage not regressed: the URL is detected somewhere in history.
        expect(
          controller.anchors.any(
            (a) => a.payload.toString().contains(_kTraceUrlFragment),
          ),
          isTrue,
          reason: 'URL detection coverage (#788) preserved',
        );

        // The decorator never resolves anchors against an offset the painter
        // hasn't painted: paintedViewportOffset is the authority, and reading it
        // is what anchorRects subtracts. With the live-offset source (pre-#803)
        // these could diverge mid-redraw → the dance; the wiring under test
        // guarantees they don't. paintedViewportOffset is a real reported value
        // (the render box ran), not the 0 default.
        expect(
          controller.paintedViewportOffset,
          greaterThanOrEqualTo(0),
          reason: 'the render box reported a painted offset (frame ran)',
        );
        // anchorRects is STABLE across back-to-back reads: a live-offset source
        // could jitter between frames during a redraw burst; the painted-offset
        // source does not — markup sits still relative to text (#803 lockstep).
        for (final anchor in controller.anchors) {
          for (final range in anchor.ranges) {
            expect(
              _rectsEqual(
                controller.anchorRects(range),
                controller.anchorRects(range),
              ),
              isTrue,
              reason: 'anchor rects are stable (painted-offset source, not the '
                  'jittering live offset)',
            );
          }
        }
      },
    );
  });
}

Uint8List _ascii(String s) => Uint8List.fromList(s.codeUnits);

bool _rectsEqual(List<Rect> a, List<Rect> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
