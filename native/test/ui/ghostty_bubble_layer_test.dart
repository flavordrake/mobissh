// #988 — the restored inline URL/path BUBBLE + single-tap copy (wrap-aware),
// rebuilt on the post-#985 painted-offset geometry (no damage-consuming
// RenderState reads; anchorRects/matchAt share ONE offset, #863).
//
// Three layers, all headless (no flterm native .so):
//   1. PURE, end-to-end geometry: the REAL StructuredTextScanner over a fake
//      CellReader holding a GENERATED long URL wrapped across 3 rows behind a
//      space-painted left margin (#925/#928 shape) → per-row ranges →
//      AnchorGeometry.rectsFor → ghosttyBubbleSegments. One segment per row,
//      first-row start col honored, continuation rows exclude the painted
//      margin, capsule ends ONLY on the first/last segments (reads as ONE
//      object across the wrap).
//   2. WIDGET: GhosttyBubbleLayer renders for an on-screen anchor, hides while
//      scrolling (hidden is acceptable, DRIFT is not — #930 guard), re-shows on
//      settle, and renders nothing for an off-screen anchor.
//   3. TAP-COPY: a tap routed by the gesture router at a bubble cell resolves
//      the match and ghosttyTapCopyMatch copies the EXACT wrap-joined URL (no
//      injected whitespace). Since #999 the single TAP routes only URL/OSC-8
//      matches here (path taps NAVIGATE — see ghostty_path_tap_navigate_999);
//      ghosttyTapCopyMatch stays the shared copy HELPER for both kinds.

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_decorators.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

/// A pure, headless [CellReader] built from per-row text. A space cell reads
/// back as a LITERAL ' ' glyph (the #928 space-painted-margin case — the
/// scanner must treat it as blank, not content).
class _SpacePaintedReader implements CellReader {
  _SpacePaintedReader(List<String> rowTexts, {required this.cols})
    : _rows = [
        for (final t in rowTexts)
          List<String>.generate(cols, (c) => c < t.length ? t[c] : ' '),
      ];

  final List<List<String>> _rows;

  @override
  final int cols;

  @override
  int get baseAbsRow => 0;

  @override
  int get rows => _rows.length;

  @override
  String cellContent(int row, int col) => _rows[row][col];

  @override
  bool rowWrap(int row) => false;

  @override
  String? hyperlinkAt(int row, int col) => null;
}

/// Fake controller exposing scripted [anchors] + a real-geometry [anchorRects]
/// (AnchorGeometry over fixed metrics) — the only surface [GhosttyBubbleLayer]
/// reads.
class _FakeController extends ChangeNotifier implements TerminalController {
  static const CellMetrics metrics = CellMetrics(
    cellWidth: 8,
    cellHeight: 16,
    baseline: 12,
  );
  static const Offset origin = Offset(4, 4);

  final int viewportRows = 24;
  final int gridCols = 50;
  int viewportOffset = 0;

  List<StructuredAnchor> _anchors = const [];
  bool _scrolling = false;

  void setAnchors(List<StructuredAnchor> value) {
    _anchors = value;
    notifyListeners();
  }

  void setScrolling(bool value) {
    if (_scrolling == value) return;
    _scrolling = value;
    notifyListeners();
  }

  @override
  List<StructuredAnchor> get anchors => _anchors;

  @override
  bool get isScrolling => _scrolling;

  @override
  Listenable get decorationListenable => this;

  @override
  List<Rect> anchorRects(HighlightRange range) => AnchorGeometry.rectsFor(
    range,
    metrics: metrics,
    viewportOffset: viewportOffset,
    cols: gridCols,
    viewportRows: viewportRows,
    origin: origin,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const scanner = StructuredTextScanner();
  const cols = 50;
  const indent = 2;
  const cellW = 8.0;
  const cellH = 16.0;
  const origin = Offset(4, 4);

  // GENERATED long URL that wraps across exactly 3 rows at a 48-char content
  // width behind a 2-col space-painted margin: 48 + 48 + 20 = 116 chars.
  final url = 'https://example.com/${'x' * 96}';
  List<String> wrappedRows() => [
    '  ${url.substring(0, 48)}',
    '  ${url.substring(48, 96)}',
    '  ${url.substring(96)}',
  ];

  StructuredMatch scanWrapped() {
    final reader = _SpacePaintedReader(wrappedRows(), cols: cols);
    final matches = scanner.scan(reader, [TextPattern.url()]);
    expect(matches, hasLength(1), reason: 'one wrapped URL match expected');
    return matches.single;
  }

  List<Rect> rectsFor(StructuredMatch match) => [
    for (final range in match.ranges)
      ...AnchorGeometry.rectsFor(
        range,
        metrics: _FakeController.metrics,
        viewportOffset: 0,
        cols: cols,
        viewportRows: 24,
        origin: origin,
      ),
  ];

  group('#988 wrap-aware bubble geometry (pure, real scanner)', () {
    test('the joined payload is the EXACT URL — no injected whitespace', () {
      final match = scanWrapped();
      expect(match.payload, url);
      expect('${match.payload}'.contains(' '), isFalse);
      expect(match.ranges, hasLength(3), reason: 'one range per wrapped row');
    });

    test('one rect per wrapped row, hugging content on every row', () {
      final rects = rectsFor(scanWrapped());
      expect(rects, hasLength(3), reason: 'one rect per wrapped row');
      // First row starts at the MATCH's start col (the 2-col indent).
      expect(rects[0].left, origin.dx + indent * cellW);
      // Continuation rows start at CONTENT, not padded col 0 — the painted
      // margin (space glyphs, #928) is excluded.
      expect(rects[1].left, origin.dx + indent * cellW);
      expect(rects[2].left, origin.dx + indent * cellW);
      expect(
        rects[1].left,
        greaterThan(origin.dx),
        reason: 'continuation row must NOT start at padded col 0',
      );
      // Rows stack: one rect per successive row.
      expect(rects[0].top, origin.dy);
      expect(rects[1].top, origin.dy + cellH);
      expect(rects[2].top, origin.dy + 2 * cellH);
      // Full rows end at the wrap col; the last row ends at CONTENT end.
      expect(rects[0].right, origin.dx + cols * cellW);
      expect(rects[2].right, origin.dx + (indent + 20) * cellW);
    });

    test('capsule ends ONLY on the first/last segments (one visual object)', () {
      final segments = ghosttyBubbleSegments(rectsFor(scanWrapped()));
      expect(segments, hasLength(3));
      expect(segments[0].roundLeft, isTrue);
      expect(segments[0].roundRight, isFalse);
      expect(segments[1].roundLeft, isFalse);
      expect(segments[1].roundRight, isFalse);
      expect(segments[2].roundLeft, isFalse);
      expect(segments[2].roundRight, isTrue);
      // Each segment stays on its own row band (hugs its row's cells).
      final rects = rectsFor(scanWrapped());
      for (var i = 0; i < 3; i++) {
        expect(segments[i].rect.center.dy, greaterThan(rects[i].top));
        expect(segments[i].rect.center.dy, lessThan(rects[i].bottom));
        expect(segments[i].rect.left, lessThanOrEqualTo(rects[i].left));
        expect(segments[i].rect.right, greaterThanOrEqualTo(rects[i].right));
      }
    });

    test('a single-row match gets a FULL capsule (both ends rounded)', () {
      final segments = ghosttyBubbleSegments(const [
        Rect.fromLTWH(20, 4, 160, 16),
      ]);
      expect(segments, hasLength(1));
      expect(segments.single.roundLeft, isTrue);
      expect(segments.single.roundRight, isTrue);
    });

    test('degenerate rects are skipped', () {
      final segments = ghosttyBubbleSegments(const [
        Rect.fromLTWH(20, 4, 0, 16),
        Rect.fromLTWH(20, 20, 160, 16),
      ]);
      expect(segments, hasLength(1));
      expect(segments.single.roundLeft, isTrue);
      expect(segments.single.roundRight, isTrue);
    });
  });

  group('#988 GhosttyBubbleLayer widget', () {
    Future<_FakeController> pumpLayer(WidgetTester tester) async {
      final controller = _FakeController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: GhosttyBubbleLayer(
                    controller: controller,
                    color: const Color(0xFF5B9BD5),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      return controller;
    }

    StructuredAnchor urlAnchor({int row = 2}) => StructuredAnchor(
      patternId: kGhosttyUrlPatternId,
      payload: 'https://example.com',
      ranges: [
        HighlightRange(
          startRow: row,
          startCol: 4,
          endRow: row,
          endCol: 23,
          payload: 'https://example.com',
        ),
      ],
    );

    testWidgets('renders the bubble paint for an on-screen anchor', (
      tester,
    ) async {
      final controller = await pumpLayer(tester);
      controller.setAnchors([urlAnchor()]);
      await tester.pump();
      expect(find.byKey(const Key('ghostty-bubble-paint')), findsOneWidget);
    });

    testWidgets('renders nothing when the anchor is fully off-screen', (
      tester,
    ) async {
      final controller = await pumpLayer(tester);
      controller.setAnchors([urlAnchor(row: 99)]);
      await tester.pump();
      expect(find.byKey(const Key('ghostty-bubble-paint')), findsNothing);
    });

    testWidgets('HIDES while scrolling, re-shows on settle (never drifts)', (
      tester,
    ) async {
      final controller = await pumpLayer(tester);
      controller.setAnchors([urlAnchor()]);
      await tester.pump();
      expect(find.byKey(const Key('ghostty-bubble-paint')), findsOneWidget);

      controller.setScrolling(true);
      await tester.pump();
      expect(
        find.byKey(const Key('ghostty-bubble-paint')),
        findsNothing,
        reason: 'mid-scroll the bubble hides — hidden is acceptable, '
            'a drifting bubble is not (#930/#812)',
      );

      controller.setScrolling(false);
      await tester.pump();
      expect(find.byKey(const Key('ghostty-bubble-paint')), findsOneWidget);
    });

    testWidgets('a PATH anchor bubbles too (shared mechanism)', (tester) async {
      final controller = await pumpLayer(tester);
      controller.setAnchors([
        StructuredAnchor(
          patternId: kGhosttyPathPatternId,
          payload: '/etc/hosts',
          ranges: const [
            HighlightRange(startRow: 3, startCol: 0, endRow: 3, endCol: 10),
          ],
        ),
      ]);
      await tester.pump();
      expect(find.byKey(const Key('ghostty-bubble-paint')), findsOneWidget);
    });
  });

  group('#988 single-tap copies the exact anchor text', () {
    test('a URL match copies its exact wrap-joined payload', () async {
      final match = scanWrapped();
      final copied = <String>[];
      final toast = await ghosttyTapCopyMatch(
        match,
        copy: (text) async {
          copied.add(text);
          return true;
        },
      );
      expect(copied, [url], reason: 'the EXACT joined URL, nothing injected');
      expect(toast, 'Copied URL');
    });

    test('the copy HELPER labels a PATH payload (menu copy path, #988/#999)', () async {
      const match = StructuredMatch(
        patternId: kGhosttyPathPatternId,
        payload: '/etc/ssh/sshd_config',
        ranges: [
          HighlightRange(startRow: 2, startCol: 4, endRow: 2, endCol: 24),
        ],
      );
      final copied = <String>[];
      final toast = await ghosttyTapCopyMatch(
        match,
        copy: (text) async {
          copied.add(text);
          return true;
        },
      );
      expect(copied, ['/etc/ssh/sshd_config']);
      expect(toast, 'Copied path');
    });

    test('an empty payload neither copies nor toasts (#810 guard)', () async {
      const match = StructuredMatch(
        patternId: kGhosttyOsc8PatternId,
        payload: '',
        ranges: [
          HighlightRange(startRow: 2, startCol: 4, endRow: 2, endCol: 8),
        ],
      );
      var copyCalls = 0;
      final toast = await ghosttyTapCopyMatch(
        match,
        copy: (_) async {
          copyCalls++;
          return true;
        },
      );
      expect(copyCalls, 0);
      expect(toast, isNull);
    });

    testWidgets(
      'a tap routed at a CONTINUATION-row bubble cell resolves the match and '
      'copies the full URL',
      (tester) async {
        final match = scanWrapped();
        final copied = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 400,
                  height: 400,
                  child: GhosttyPointerGestureRouter(
                    active: false,
                    scrollController: TerminalScrollController(),
                    cols: cols,
                    rows: 24,
                    lastSentCols: cols,
                    lastSentRows: 24,
                    cellWidth: cellW,
                    cellHeight: cellH,
                    mouseTrackingLabel: 'any',
                    onTap: () {},
                    onFocus: () {},
                    onMouseReport: (_) {},
                    onSelectionStart: (_, _) {},
                    onSelectionExtend: (_, _) {},
                    hasSelection: () => false,
                    onSelectionClear: () {},
                    urlAtCell: (col, row) =>
                        match.contains(row, col) ? match : null,
                    onUrlTap: (m) => ghosttyTapCopyMatch(
                      m,
                      copy: (text) async {
                        copied.add(text);
                        return true;
                      },
                    ),
                    onUrlLongPress: (_, _) {},
                  ),
                ),
              ),
            ),
          ),
        );
        // Row 1 (a continuation row), col 10 — inside the wrapped match. The
        // router maps px→cell with cellW=8/cellH=16: (10*8+4, 1*16+8).
        await tester.tapAt(const Offset(84, 24));
        await tester.pumpAndSettle();
        expect(copied, [url], reason: 'tap on a continuation row copies the FULL URL');
      },
    );
  });
}
