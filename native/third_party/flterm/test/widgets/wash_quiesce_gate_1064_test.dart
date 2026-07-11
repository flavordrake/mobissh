@Tags(['ffi'])
library;

// #1064 (owner P0) — the detection WASH must be QUIESCE-GATED: visible ONLY when
// the screen is settled. It PAUSES (hides) while the screen is CHURNING — an
// active scroll OR content updating (a live/streaming TUI repaint) — and repaints
// at the fresh positions after a debounce once quiescent.
//
// +140 (#1062/#1063) paused the wash only on SCROLL (isScrolling). The owner's
// live-updating TUI churns content WITHOUT scrolling (isScrolling=false, the grid
// rewritten in place), so +140 left the wash SHOWN at stale spots there — the gap
// this issue closes. The fix ORs a CONTENT-settle term into the render box's
// wash-suppression: washSuppressed = isScrolling || contentSettling, where
// contentSettling is true from a content notify until the rescan debounce settles
// after a quiet gap.
//
// This test drives a REAL TerminalView with an IN-PLACE content churn (no scroll)
// and asserts:
//   * quiescent precondition — a stable screen shows the wash on its token,
//   * during churn — isScrolling is false yet the wash is HIDDEN (contentSettling
//     drives washSuppressed), and the washHiddenForContentChurn telemetry fires,
//   * after churn stops + the settle debounce — the wash RE-SHOWS on its token.
// The settle re-show is the case that needs an explicit wake: the churn ends on
// the SAME matches (the URL never moved), so the equality-gated rescan would not
// notify — _onDetectionSettled must re-show the wash anyway.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _url = 'https://example.com/quiesce/gate';

HighlightStyle? _washResolver(StructuredMatch m) {
  if (m.patternId != 'url') return null;
  return const HighlightStyle(background: Color(0x8800FF00), capsule: true);
}

/// True when a capsule wash currently sits ON its payload's glyph cells at
/// [offset] (the wash is correctly placed and, by construction, would paint).
bool _washOnToken(TerminalController c, int cols, int offset) {
  final visible = c.scrollbar.visible;
  for (final r in c.highlights) {
    if (!r.capsule) continue;
    final payload = '${r.payload}';
    for (var absRow = r.topRow; absRow <= r.bottomRow; absRow++) {
      final viewRow = absRow - offset;
      if (viewRow < 0 || viewRow >= visible) continue;
      final startCol = absRow == r.topRow ? r.topCol : 0;
      final endCol = absRow == r.bottomRow ? r.bottomCol : cols;
      final rowText = c.visibleRowsText(viewRow, viewRow);
      final s = startCol.clamp(0, rowText.length);
      final e = endCol.clamp(0, rowText.length);
      final slice = (e > s ? rowText.substring(s, e) : '').trim();
      if (slice.isNotEmpty &&
          (payload.contains(slice) || slice.contains(payload))) {
        return true;
      }
    }
  }
  return false;
}

void main() {
  testWidgets(
    'the detection wash HIDES during a content churn (isScrolling=false) and '
    're-shows on its token after the settle debounce (#1064 quiesce gate)',
    (tester) async {
      const cols = 62;
      final controller = TerminalController(
        config: const TerminalConfig(cols: cols, rows: 24),
      )
        ..registerTextPattern(TextPattern.url())
        ..detectionHighlightStyleOf = _washResolver;
      addTearDown(controller.dispose);

      final scrollController = TerminalScrollController();
      addTearDown(scrollController.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 700,
              height: 460,
              child: TerminalView(
                controller: controller,
                scrollController: scrollController,
                autofocus: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      void write(String s) =>
          controller.write(Uint8List.fromList(utf8.encode(s)));

      TerminalRenderBox renderBox() => tester.renderObject<TerminalRenderBox>(
            find.byType(TerminalRenderer),
          );

      // A little scrollback, then a URL line the cursor stays on (NO newline) so
      // the churn rewrites THIS line in place — the viewport is already at the
      // bottom, so an in-place rewrite never moves the offset (isScrolling stays
      // false: this exercises the CONTENT gate, not the scroll gate).
      for (var i = 0; i < 10; i++) {
        write('filler ${i.toString().padLeft(4, '0')}\r\n');
      }
      write('note $_url here');
      // Settle output + the detection debounce so the wash appears on the URL.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      // ---- quiescent precondition: wash present, NOT suppressed, on its token.
      expect(controller.isScrolling, isFalse, reason: 'must start at rest');
      expect(controller.contentSettling, isFalse,
          reason: 'content must be settled before the churn');
      expect(renderBox().debugWashSuppressed, isFalse,
          reason: 'a quiescent frame must NOT suppress the wash');
      expect(controller.highlights.any((r) => r.capsule), isTrue,
          reason: 'precondition: a capsule wash is live on the URL');
      expect(_washOnToken(controller, cols, controller.paintedViewportOffset),
          isTrue,
          reason: 'precondition: the settled wash sits on its token');

      // ---- the measured churn: rewrite the SAME line in place every frame, far
      // faster than the ~120ms settle debounce, so the content never quiesces.
      // A trailing counter changes the line (guaranteeing a content notify) while
      // the URL token itself never moves.
      controller.detectionScanStats.reset();
      var sawHiddenDuringChurn = false;
      var sawScrollingDuringChurn = false;
      for (var frame = 1; frame <= 12; frame++) {
        write('\rnote $_url here tick=$frame   ');
        await tester.pump(const Duration(milliseconds: 40));
        if (controller.isScrolling) sawScrollingDuringChurn = true;
        if (renderBox().debugWashSuppressed) sawHiddenDuringChurn = true;
      }

      // The churn must NOT have scrolled — this proves the hide came from the
      // CONTENT gate (contentSettling), the case +140 missed.
      expect(sawScrollingDuringChurn, isFalse,
          reason: 'the in-place churn must not scroll — the hide must be '
              'attributable to content churn, not scroll');
      expect(sawHiddenDuringChurn, isTrue,
          reason: 'the wash must HIDE while content churns (the +140 gap: '
              'isScrolling=false yet the screen is not quiescent)');
      expect(controller.contentSettling, isTrue,
          reason: 'contentSettling must hold true through continuous churn');
      expect(controller.detectionScanStats.washHiddenForContentChurn,
          greaterThan(0),
          reason: 'the washHiddenForContentChurn telemetry must show the '
              'content-pause path fired over live detected content');

      // ---- settle: stop churning, drain the debounce; the wash RE-SHOWS.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(controller.isScrolling, isFalse);
      expect(controller.contentSettling, isFalse,
          reason: 'content must settle once the churn stops');
      expect(renderBox().debugWashSuppressed, isFalse,
          reason: 'the wash must be un-suppressed once content settles — even '
              'though the churn ended on the SAME matches (the equality-gated '
              'rescan would not notify; _onDetectionSettled re-shows it)');
      expect(controller.highlights.any((r) => r.capsule), isTrue,
          reason: 'the wash must re-show after settle (churn must not strand it '
              'hidden)');
      expect(_washOnToken(controller, cols, controller.paintedViewportOffset),
          isTrue,
          reason: 'after settle the wash must sit back on its token');

      debugPrint('WASH1064 churn OK: hiddenDuringChurn=$sawHiddenDuringChurn '
          'washHiddenForContentChurn='
          '${controller.detectionScanStats.washHiddenForContentChurn} '
          'anchorsAfter=${controller.anchors.length}');
    },
  );

  testWidgets(
    'a quiescent screen with detected content keeps the wash VISIBLE — the gate '
    'does not falsely hide when nothing is churning (#1064)',
    (tester) async {
      const cols = 50;
      final controller = TerminalController(
        config: const TerminalConfig(cols: cols, rows: 16),
      )
        ..registerTextPattern(TextPattern.url())
        ..detectionHighlightStyleOf = _washResolver;
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 560,
              height: 320,
              child: TerminalView(controller: controller, autofocus: false),
            ),
          ),
        ),
      );
      await tester.pump();

      controller.write(
        Uint8List.fromList(utf8.encode('visit $_url now\r\n')),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      final renderBox = tester.renderObject<TerminalRenderBox>(
        find.byType(TerminalRenderer),
      );
      expect(controller.contentSettling, isFalse);
      expect(controller.isScrolling, isFalse);
      expect(renderBox.debugWashSuppressed, isFalse,
          reason: 'a settled screen must show the wash');
      expect(_washOnToken(controller, cols, controller.paintedViewportOffset),
          isTrue);
    },
  );
}
