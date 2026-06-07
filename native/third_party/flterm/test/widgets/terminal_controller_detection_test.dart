@Tags(['ffi'])
library;

import 'dart:typed_data';

import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/widgets/terminal_controller_impl.dart';
import 'package:flterm/src/widgets/terminal_scroll_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TerminalController structured-text detection (#767)', () {
    late TerminalControllerImpl controller;

    setUp(() => controller = TerminalControllerImpl());
    tearDown(() => controller.dispose());

    /// Pump the terminal with [text] and flush the detection debounce.
    Future<void> writeAndScan(String text) async {
      controller.write(Uint8List.fromList(text.codeUnits));
      // The re-scan is debounced (~120ms); wait past it.
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    test('registerTextPattern detects a URL and populates highlights', () async {
      controller.registerTextPattern(
        TextPattern.url(
          style: const HighlightStyle(background: Color(0x335B9BD5)),
        ),
      );
      await writeAndScan('see https://example.com here\r\n');

      expect(
        controller.highlights,
        isNotEmpty,
        reason: 'a detected URL should populate controller.highlights',
      );
      // The highlight payload recovers the URL.
      expect(
        controller.highlights.any((r) => r.payload == 'https://example.com'),
        isTrue,
      );
    });

    test('matchAt resolves the URL under a viewport cell', () async {
      controller.registerTextPattern(TextPattern.url());
      await writeAndScan('go https://foo.io now\r\n');

      // 'go ' == 3 chars; the URL starts at viewport col 3 on the row it
      // printed (row 0 — first and only line). matchAt is viewport-relative.
      final match = controller.matchAt(row: 0, col: 5);
      expect(match, isNotNull);
      expect(match!.payload, 'https://foo.io');
    });

    test('matchAt returns null off any match', () async {
      controller.registerTextPattern(TextPattern.url());
      await writeAndScan('go https://foo.io now\r\n');

      // Col 0 ('g') is before the URL.
      expect(controller.matchAt(row: 0, col: 0), isNull);
    });

    test('clearTextPatterns removes detection and clears highlights', () async {
      controller.registerTextPattern(TextPattern.url());
      await writeAndScan('https://bar.org\r\n');
      expect(controller.highlights, isNotEmpty);

      controller.clearTextPatterns();
      expect(controller.highlights, isEmpty);
      expect(controller.matchAt(row: 0, col: 2), isNull);
    });

    test('anchors reflect the detected matches (#767 Slice B)', () async {
      controller.registerTextPattern(TextPattern.url());
      await writeAndScan('see https://example.com here\r\n');

      final anchors = controller.anchors;
      expect(anchors, isNotEmpty);
      expect(
        anchors.any(
          (a) => a.patternId == 'url' && a.payload == 'https://example.com',
        ),
        isTrue,
      );
      // Each anchor carries its per-row highlight ranges.
      expect(anchors.first.ranges, isNotEmpty);
    });

    test('anchors is empty with no detection', () {
      expect(controller.anchors, isEmpty);
    });

    test('clearTextPatterns empties anchors too', () async {
      controller.registerTextPattern(TextPattern.url());
      await writeAndScan('https://bar.org\r\n');
      expect(controller.anchors, isNotEmpty);

      controller.clearTextPatterns();
      expect(controller.anchors, isEmpty);
    });

    test('anchorRects returns a positioned rect once the grid is laid out',
        () async {
      controller.registerTextPattern(TextPattern.url());
      // Seed live cell metrics + padding the resolver needs (the widget does
      // this via the TerminalView layout; do it directly here).
      controller.handleResize(
        cols: 80,
        rows: 24,
        metrics: const CellMetrics(cellWidth: 10, cellHeight: 20, baseline: 16),
        padding: const EdgeInsets.all(4),
        devicePixelRatio: 1,
      );
      await writeAndScan('go https://foo.io now\r\n');

      final anchors = controller.anchors;
      expect(anchors, isNotEmpty);
      final range = anchors.first.ranges.first;
      final rects = controller.anchorRects(range);
      expect(rects, isNotEmpty);
      // Padding origin (4,4) is applied; the rect has a real, positive size.
      expect(rects.first.left, greaterThanOrEqualTo(4));
      expect(rects.first.width, greaterThan(0));
      expect(rects.first.height, 20);
    });

    test('anchorRects is empty before the grid is measured', () async {
      controller.registerTextPattern(TextPattern.url());
      await writeAndScan('go https://foo.io now\r\n');
      // No handleResize → zero metrics → no rects (decorator simply waits).
      final anchors = controller.anchors;
      expect(anchors, isNotEmpty);
      expect(controller.anchorRects(anchors.first.ranges.first), isEmpty);
    });

    test('re-registering a pattern id replaces it (no duplicate)', () async {
      controller.registerTextPattern(
        TextPattern.url(style: const HighlightStyle(background: Color(0xFF000001))),
      );
      await writeAndScan('https://baz.net\r\n');
      // Restyle: clear + re-register (the theme-recolor path).
      controller.clearTextPatterns();
      controller.registerTextPattern(
        TextPattern.url(style: const HighlightStyle(background: Color(0xFF000002))),
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));

      // Exactly one URL, restyled to the new color.
      final urlRanges =
          controller.highlights.where((r) => r.payload == 'https://baz.net');
      expect(urlRanges, isNotEmpty);
      expect(urlRanges.every((r) => r.background == const Color(0xFF000002)),
          isTrue);
    });
  });

  // #784: the structured-text decorator OUTLINE (URL bubble / path underline)
  // drifts off its glyphs WHEN SCROLLED BACK. Root cause: the widget-layer
  // decorator resolves its ABSOLUTE-row anchors to viewport rects against the
  // LIVE `scrollbar.offset` ([anchorRects]) but only RE-resolves when this
  // controller notifies. A scrollback SCROLL moves the viewport via the
  // ScrollController → the render object's `_onScroll` → `terminal.scrollViewport`,
  // which does NOT fire the terminal's listeners — so the controller never
  // re-notified on scroll and the decorator kept rects at the OLD offset while
  // the fork's own painter (offset from the frame snapshot) moved. The contract:
  // a scroll that changes the viewport offset MUST notify so the decorator
  // re-resolves and tracks the glyphs.
  group('TerminalController scroll notify for anchor tracking (#784)', () {
    Widget host(TerminalScrollController scrollController) => MaterialApp(
          home: SizedBox(
            height: 200,
            child: ListView(
              controller: scrollController,
              children: [const SizedBox(height: 2000)],
            ),
          ),
        );

    testWidgets('a scrollback scroll notifies the controller', (tester) async {
      final controller = TerminalControllerImpl();
      addTearDown(controller.dispose);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      final scrollController = TerminalScrollController();
      addTearDown(scrollController.dispose);

      await tester.pumpWidget(host(scrollController));
      // Wire the controller to the focus node + scroll controller exactly as the
      // TerminalView does on mount.
      controller.attach(focusNode, scrollController);

      var notified = false;
      controller.addListener(() => notified = true);

      // A pure scrollback scroll — no terminal output. Before the fix this fired
      // ZERO controller notifies, so the decorator's rects went stale.
      scrollController.jumpTo(120);
      await tester.pump();

      expect(
        notified,
        isTrue,
        reason: 'scrolling must notify so the decorator re-resolves anchorRects '
            'against the live offset (else the outline drifts off its glyphs)',
      );
    });

    testWidgets('detach stops forwarding scroll notifies', (tester) async {
      final controller = TerminalControllerImpl();
      addTearDown(controller.dispose);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      final scrollController = TerminalScrollController();
      addTearDown(scrollController.dispose);

      await tester.pumpWidget(host(scrollController));
      controller.attach(focusNode, scrollController);
      controller.detach();

      var notified = false;
      controller.addListener(() => notified = true);
      scrollController.jumpTo(120);
      await tester.pump();

      expect(
        notified,
        isFalse,
        reason: 'after detach the controller must not react to its old scroll '
            'controller',
      );
    });
  });
}
