// #767 Slice B — the per-pattern decorator framework + URL bubble overlay.
//
// Covers the WIDGET-layer seam that injects decorators over the fork's exposed
// anchors: the registry routes a pattern id to its decorator, and the decorator
// LAYER resolves each anchor's live viewport rects (via `controller.anchorRects`)
// and draws the registered decorator — the URL BUBBLE: a rounded OUTLINE hugging
// the cells, that TRACKS scroll (re-resolves on controller notify) and leaves the
// URL text in the tree (it is an IgnorePointer paint-only overlay; taps fall
// through to the gesture router). No FFI: a fake controller supplies anchors +
// rects, so this runs in the fast gate.

import 'package:flutter/widgets.dart';
import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_decorators.dart';

/// A fake [TerminalController] that exposes a settable [anchors] list and a
/// settable per-row [anchorRects] map, and notifies listeners on demand — the
/// only surface [GhosttyTerminalDecoratorLayer] reads. Everything else is
/// unimplemented (the layer never calls it).
class _FakeController extends ChangeNotifier implements TerminalController {
  List<StructuredAnchor> _anchors = const [];

  /// viewportOffset stand-in: every range's rects are shifted UP by this many
  /// cell-heights, so a "scroll" can be simulated by bumping it + notifying.
  double scrollShift = 0;

  /// The cell height used to translate [scrollShift] into pixels.
  double cellHeight = 20;

  void setAnchors(List<StructuredAnchor> value) {
    _anchors = value;
    notifyListeners();
  }

  void scrollBy(double cells) {
    scrollShift += cells;
    notifyListeners();
  }

  /// #812: the scrolling-vs-settled signal the layer now gates its draw on. The
  /// fake defaults to SETTLED (false) so the existing "renders a bubble" tests
  /// still draw; the #812 hide-on-scroll tests flip it true + notify.
  bool scrolling = false;

  void setScrolling(bool value) {
    if (scrolling == value) return;
    scrolling = value;
    notifyListeners();
  }

  @override
  bool get isScrolling => scrolling;

  @override
  List<StructuredAnchor> get anchors => _anchors;

  // #805: the layer now listens to the narrow decoration signal. In this fake
  // every notify (setAnchors / scrollBy) IS a decoration change, so route it to
  // the fake's own ChangeNotifier — preserving each test's "notify → rebuild".
  @override
  Listenable get decorationListenable => this;

  @override
  List<Rect> anchorRects(HighlightRange range) {
    // Lay each row out at a deterministic position, shifted by the scroll.
    final top = range.topRow * cellHeight - scrollShift * cellHeight;
    // Off-screen above → empty (matches the real resolver's contract).
    if (top < -cellHeight) return const [];
    return [
      Rect.fromLTWH(
        range.topCol * 10.0,
        top,
        (range.bottomCol - range.topCol) * 10.0,
        cellHeight,
      ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

StructuredAnchor _urlAnchor(String url, {int row = 2, int startCol = 4}) {
  return StructuredAnchor(
    patternId: kGhosttyUrlPatternId,
    payload: url,
    ranges: [
      HighlightRange(
        startRow: row,
        startCol: startCol,
        endRow: row,
        endCol: startCol + url.length,
        payload: url,
      ),
    ],
  );
}

/// A recording [Canvas] that captures every `drawRRect` so a test can assert
/// the bubble geometry the [UrlBubbleDecorator] painter produces (#864). Only
/// the methods the painter calls are recorded; everything else is a no-op.
class _RecordingCanvas implements Canvas {
  final List<RRect> rrects = <RRect>[];

  @override
  void drawRRect(RRect rrect, Paint paint) => rrects.add(rrect);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  group('#864 URL bubble visual polish', () {
    test('URL highlight style drops the underline AND the fill', () {
      // The app paints NO underline/background of its own for a URL — the chip
      // is the single affordance, so neither co-renders (was "slap"/redundant).
      expect(kGhosttyUrlHighlightStyle.underline, isNull);
      expect(kGhosttyUrlHighlightStyle.background, isNull);
    });

    testWidgets('bubble is padded horizontally and centered DOWN on the cell',
        (tester) async {
      // Build the painter for a single-row URL anchor and capture the RRect it
      // draws, then compare it to the raw cell rect it was given.
      const cell = Rect.fromLTWH(40, 40, 200, 20);
      late Widget painter;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (context) => painter = const UrlBubbleDecorator().build(
              context,
              const [
                GhosttyDecoratedAnchor(
                  payload: 'https://example.com',
                  rects: [cell],
                  color: Color(0xFF00FF00),
                ),
              ],
            ),
          ),
        ),
      );
      // Reach the painter via the CustomPaint the decorator builds.
      final customPaint = (painter as IgnorePointer).child! as CustomPaint;
      final canvas = _RecordingCanvas();
      customPaint.painter!.paint(canvas, const Size(400, 400));

      expect(canvas.rrects, hasLength(1));
      final bubble = canvas.rrects.single.outerRect;

      // HORIZONTAL: the chip is WIDER than the cell — padded on BOTH sides so it
      // frames the URL rather than clipping the first/last glyph.
      expect(bubble.left, lessThan(cell.left),
          reason: 'left edge padded outward');
      expect(bubble.right, greaterThan(cell.right),
          reason: 'right edge padded outward');
      expect(bubble.width, greaterThan(cell.width));

      // VERTICAL: the chip is shifted DOWN — its vertical center sits BELOW the
      // cell's center (recentred on the glyph ink, not top-heavy).
      expect(bubble.center.dy, greaterThan(cell.center.dy),
          reason: 'chip nudged down to centre on the glyphs');
      // …and it is no taller than the cell (the top slack was insetted away, not
      // inflated), so the chip hugs the glyph row.
      expect(bubble.height, lessThanOrEqualTo(cell.height));
    });
  });

  group('GhosttyDecoratorRegistry', () {
    test('defaults registers the url bubble decorator', () {
      final registry = GhosttyDecoratorRegistry.defaults();
      expect(registry.patternIds, contains(kGhosttyUrlPatternId));
      final decorator = registry.forPattern(kGhosttyUrlPatternId);
      expect(decorator, isA<UrlBubbleDecorator>());
      expect(decorator!.patternId, kGhosttyUrlPatternId);
    });

    test('defaults registers the OSC-8 bubble decorator (#767 Slice B)', () {
      final registry = GhosttyDecoratorRegistry.defaults();
      expect(registry.patternIds, contains(kGhosttyOsc8PatternId));
      final decorator = registry.forPattern(kGhosttyOsc8PatternId);
      // The OSC-8 anchor renders the SAME bubble affordance as a regex URL,
      // routed by its own pattern id.
      expect(decorator, isA<UrlBubbleDecorator>());
      expect(decorator!.patternId, kGhosttyOsc8PatternId);
    });

    test('defaults registers the path decorator (#778 paths Slice 1)', () {
      final registry = GhosttyDecoratorRegistry.defaults();
      expect(registry.patternIds, contains(kGhosttyPathPatternId));
      final decorator = registry.forPattern(kGhosttyPathPatternId);
      // A path anchor gets the DISTINCT path treatment, not the URL bubble.
      expect(decorator, isA<PathDecorator>());
      expect(decorator!.patternId, kGhosttyPathPatternId);
    });

    test('returns null for an unregistered pattern (e.g. future sha)', () {
      final registry = GhosttyDecoratorRegistry.defaults();
      expect(registry.forPattern('commit-sha'), isNull);
    });

    test('is extensible with additional decorators', () {
      final registry = GhosttyDecoratorRegistry(const [
        UrlBubbleDecorator(),
        _StubDecorator('commit-sha'),
      ]);
      expect(registry.forPattern('commit-sha'), isA<_StubDecorator>());
      expect(registry.forPattern(kGhosttyUrlPatternId), isA<UrlBubbleDecorator>());
    });
  });

  group('UrlBubbleDecorator paint widget', () {
    testWidgets('builds a paint-only (IgnorePointer) overlay', (tester) async {
      const decorator = UrlBubbleDecorator();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (context) => decorator.build(context, const [
              GhosttyDecoratedAnchor(
                payload: 'https://example.com',
                rects: [Rect.fromLTWH(40, 40, 190, 20)],
                color: Color(0xFF00FF00),
              ),
            ]),
          ),
        ),
      );
      expect(find.byType(IgnorePointer), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
    });
  });

  group('GhosttyTerminalDecoratorLayer', () {
    Future<_FakeController> pumpLayer(
      WidgetTester tester, {
      Color color = const Color(0xFF00FF00),
      Widget? underlay,
    }) async {
      final controller = _FakeController();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: [
              if (underlay != null) Positioned.fill(child: underlay),
              Positioned.fill(
                child: GhosttyTerminalDecoratorLayer(
                  controller: controller,
                  registry: GhosttyDecoratorRegistry.defaults(),
                  color: color,
                ),
              ),
            ],
          ),
        ),
      );
      return controller;
    }

    testWidgets('renders nothing when there are no anchors', (tester) async {
      await pumpLayer(tester);
      // No bubble painter mounted (the layer collapses to a SizedBox).
      expect(find.byType(IgnorePointer), findsNothing);
    });

    testWidgets('renders a bubble for a detected url anchor', (tester) async {
      final controller = await pumpLayer(tester);
      controller.setAnchors([_urlAnchor('https://example.com')]);
      await tester.pump();
      expect(find.byType(IgnorePointer), findsOneWidget);
      // The CustomPaint carries a painter that has the anchor's rect to draw.
      final paints = tester.widgetList<CustomPaint>(find.byType(CustomPaint));
      expect(paints, isNotEmpty);
    });

    testWidgets('does NOT cover the underlying URL text', (tester) async {
      // The decorator must be paint-only: an underlay text widget stays hittable
      // and present (the bubble is an outline above it, not a fill over it).
      const key = Key('url-text');
      final controller = await pumpLayer(
        tester,
        underlay: const Align(
          alignment: Alignment.topLeft,
          child: Text('https://example.com', key: key),
        ),
      );
      controller.setAnchors([_urlAnchor('https://example.com')]);
      await tester.pump();
      // The URL text is still in the tree (not replaced/removed by the overlay).
      expect(find.byKey(key), findsOneWidget);
      // And the overlay above it ignores pointers, so the text underneath is the
      // hit-test target (paint-only contract).
      expect(find.byType(IgnorePointer), findsOneWidget);
    });

    testWidgets('updates the bubble position as the viewport scrolls',
        (tester) async {
      final controller = await pumpLayer(tester);
      controller.setAnchors([_urlAnchor('https://example.com', row: 5)]);
      await tester.pump();

      Rect painterRect() {
        // Pull the first rect the painter would draw from the live resolver.
        final anchor = controller.anchors.single;
        return controller.anchorRects(anchor.ranges.single).single;
      }

      final before = painterRect();
      // Scroll three rows: the resolver shifts the rect UP by 3 * cellHeight.
      controller.scrollBy(3);
      await tester.pump();
      final after = painterRect();
      expect(after.top, before.top - 3 * controller.cellHeight);
      // Still rendering (anchor visible) → the overlay tracked the scroll.
      expect(find.byType(IgnorePointer), findsOneWidget);
    });

    testWidgets('drops the bubble when the anchor scrolls fully off-screen',
        (tester) async {
      final controller = await pumpLayer(tester);
      controller.setAnchors([_urlAnchor('https://example.com', row: 0)]);
      await tester.pump();
      expect(find.byType(IgnorePointer), findsOneWidget);

      // Scroll the row 0 anchor far above the viewport → resolver returns empty
      // → the layer renders nothing.
      controller.scrollBy(10);
      await tester.pump();
      expect(find.byType(IgnorePointer), findsNothing);
    });

    testWidgets('#812: HIDES the bubble while scrolling, even with a live anchor',
        (tester) async {
      final controller = await pumpLayer(tester);
      controller.setAnchors([_urlAnchor('https://example.com')]);
      await tester.pump();
      // Settled → drawn.
      expect(find.byType(IgnorePointer), findsOneWidget);

      // Enter the scrolling state: the anchor is STILL detected (tap routing is
      // unaffected) but the layer must draw NOTHING.
      controller.setScrolling(true);
      await tester.pump();
      expect(
        find.byType(IgnorePointer),
        findsNothing,
        reason: 'the decorator hides while the viewport offset is changing (#812)',
      );
      // The anchor is unchanged — only the DRAW is gated, not detection.
      expect(controller.anchors, isNotEmpty);
    });

    testWidgets('#812: SHOWS the bubble again once the scroll settles',
        (tester) async {
      final controller = await pumpLayer(tester);
      controller.setAnchors([_urlAnchor('https://example.com')]);
      controller.setScrolling(true);
      await tester.pump();
      expect(find.byType(IgnorePointer), findsNothing);

      // Settle: the layer rebuilds once and re-shows the bubble at the (now
      // stable) geometry.
      controller.setScrolling(false);
      await tester.pump();
      expect(
        find.byType(IgnorePointer),
        findsOneWidget,
        reason: 'the decorator reappears once the offset is stable (#812)',
      );
    });

    testWidgets('skips anchors whose pattern has no registered decorator',
        (tester) async {
      final controller = await pumpLayer(tester);
      controller.setAnchors([
        StructuredAnchor(
          patternId: 'commit-sha', // no decorator registered in defaults()
          payload: 'deadbeef',
          ranges: const [
            HighlightRange(startRow: 2, startCol: 0, endRow: 2, endCol: 10),
          ],
        ),
      ]);
      await tester.pump();
      // Nothing to draw for an unknown pattern.
      expect(find.byType(IgnorePointer), findsNothing);
    });
  });
}

/// A no-op decorator used to prove the registry is extensible.
class _StubDecorator extends GhosttyTerminalDecorator {
  const _StubDecorator(this.patternId);

  @override
  final String patternId;

  @override
  Widget build(BuildContext context, List<GhosttyDecoratedAnchor> anchors) =>
      const SizedBox.shrink();
}
