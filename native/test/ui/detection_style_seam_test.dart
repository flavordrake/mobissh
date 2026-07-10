// #1031 slice 1 — the painters CONSUME the style resolver: GhosttyBubbleLayer
// takes a washColorOf seam (per-pattern effective wash) and GhosttyGutterLayer
// a chipAccentOf seam (per-pattern chip hue). The zero-visual-change
// invariant: a resolver over an EMPTY store paints EXACTLY what the layers
// painted before the seam existed.

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/storage/detection_styles_store.dart';
import 'package:mobissh/ui/detection_style_resolver.dart';
import 'package:mobissh/ui/ghostty_gutter_layer.dart';
import 'package:mobissh/ui/ghostty_terminal_decorators.dart';

const _accent = Color(0x335B9BD5);

StructuredAnchor _anchor(String patternId, String payload, {int row = 2}) =>
    StructuredAnchor(
      patternId: patternId,
      payload: payload,
      ranges: [
        HighlightRange(
          startRow: row,
          startCol: 2,
          endRow: row,
          endCol: 2 + payload.length,
          payload: payload,
        ),
      ],
    );

/// Fake controller for the BUBBLE layer: scripted anchors + real-geometry
/// anchorRects (mirrors ghostty_bubble_layer_test.dart).
class _FakeBubbleController extends ChangeNotifier
    implements TerminalController {
  static const CellMetrics metrics = CellMetrics(
    cellWidth: 8,
    cellHeight: 16,
    baseline: 12,
  );

  List<StructuredAnchor> _anchors = const [];

  void setAnchors(List<StructuredAnchor> value) {
    _anchors = value;
    notifyListeners();
  }

  @override
  List<StructuredAnchor> get anchors => _anchors;

  @override
  bool get isScrolling => false;

  @override
  Listenable get decorationListenable => this;

  @override
  List<Rect> anchorRects(HighlightRange range) => AnchorGeometry.rectsFor(
        range,
        metrics: metrics,
        viewportOffset: 0,
        cols: 50,
        viewportRows: 24,
        origin: const Offset(4, 4),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Fake controller for the GUTTER layer: scripted anchors + anchorGutterRow
/// (mirrors ghostty_gutter_layer_test.dart).
class _FakeGutterController extends ChangeNotifier
    implements TerminalController {
  List<StructuredAnchor> _anchors = const [];

  void setAnchors(List<StructuredAnchor> value) {
    _anchors = value;
    notifyListeners();
  }

  @override
  List<StructuredAnchor> get anchors => _anchors;

  @override
  bool get isScrolling => false;

  @override
  Listenable get decorationListenable => this;

  @override
  int? anchorGutterRow(HighlightRange range) {
    final row = range.topRow;
    if (row < 0 || row >= 24) return null;
    return row;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

GhosttyBubblePainter _painterOf(WidgetTester tester) {
  final paint = tester.widget<CustomPaint>(
    find.byKey(const Key('ghostty-bubble-paint')),
  );
  return paint.painter! as GhosttyBubblePainter;
}

/// The chip Container's fill inside a gutter mark.
Color _chipFillOf(WidgetTester tester, int row) {
  final containers = tester.widgetList<Container>(
    find.descendant(
      of: find.byKey(Key('gutter-mark-$row')),
      matching: find.byType(Container),
    ),
  );
  for (final c in containers) {
    final decoration = c.decoration;
    if (decoration is BoxDecoration && decoration.shape == BoxShape.circle) {
      return decoration.color!;
    }
  }
  fail('no circular chip Container under gutter-mark-$row');
}

void main() {
  group('GhosttyBubbleLayer consumes the resolver (washColorOf seam)', () {
    Future<_FakeBubbleController> pumpBubble(
      WidgetTester tester, {
      Color Function(String patternId, {required bool verified})? washColorOf,
    }) async {
      final controller = _FakeBubbleController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: GhosttyBubbleLayer(
                    controller: controller,
                    color: _accent,
                    backgroundBrightness: Brightness.dark,
                    washColorOf: washColorOf,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      return controller;
    }

    testWidgets('an override wash from the seam is what the painter fills',
        (tester) async {
      const overrideWash = Color(0x4D33AA55);
      final controller = await pumpBubble(
        tester,
        washColorOf: (id, {required bool verified}) =>
            id == kGhosttyUrlPatternId
                ? overrideWash
                : ghosttyBubbleWashColor(
                    _accent,
                    verified: verified,
                    backgroundBrightness: Brightness.dark,
                  ),
      );
      controller.setAnchors([
        _anchor(kGhosttyUrlPatternId, 'https://example.com', row: 2),
        _anchor(kGhosttyPathPatternId, '/etc/hosts', row: 5),
      ]);
      await tester.pump();
      final painter = _painterOf(tester);
      expect(painter.specs, hasLength(2));
      expect(painter.specs[0].washColor, overrideWash);
      expect(
        painter.specs[1].washColor,
        ghosttyBubbleWashColor(
          _accent,
          verified: false,
          backgroundBrightness: Brightness.dark,
        ),
        reason: 'only the overridden pattern changes',
      );
    });

    testWidgets('ZERO CHANGE: an empty-store resolver paints the SAME wash as '
        'no seam at all', (tester) async {
      // Baseline: no seam.
      final bare = await pumpBubble(tester);
      bare.setAnchors([_anchor(kGhosttyUrlPatternId, 'https://example.com')]);
      await tester.pump();
      final baseline = _painterOf(tester).effectiveWashColor(
        _painterOf(tester).specs.single,
      );

      // Resolver-backed seam over an EMPTY store.
      const resolver = DetectionStyleResolver(
        styles: DetectionStyles.empty,
        accent: _accent,
        backgroundBrightness: Brightness.dark,
      );
      final wired = await pumpBubble(
        tester,
        washColorOf: (id, {required bool verified}) =>
            resolver.resolveStyle(id, verified: verified).washColor,
      );
      wired.setAnchors([_anchor(kGhosttyUrlPatternId, 'https://example.com')]);
      await tester.pump();
      final painter = _painterOf(tester);
      expect(
        painter.effectiveWashColor(painter.specs.single),
        baseline,
        reason: 'the resolver with no overrides must be invisible',
      );
    });
  });

  group('GhosttyGutterLayer consumes the resolver (chipAccentOf seam)', () {
    Future<_FakeGutterController> pumpGutter(
      WidgetTester tester, {
      Color Function(String patternId)? chipAccentOf,
    }) async {
      final controller = _FakeGutterController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: GhosttyGutterLayer(
                    controller: controller,
                    registry: GutterPatternRegistry.standard(
                      openPath: (_) async => true,
                    ),
                    color: _accent,
                    cellHeight: 20,
                    chipAccentOf: chipAccentOf,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      return controller;
    }

    testWidgets('a single-pattern row chips in ITS resolved accent',
        (tester) async {
      const pathAccent = Color(0xFF33AA55);
      final controller = await pumpGutter(
        tester,
        chipAccentOf: (id) =>
            id == kGhosttyPathPatternId ? pathAccent : _accent,
      );
      controller.setAnchors([
        _anchor(kGhosttyPathPatternId, '/etc/hosts', row: 4),
        _anchor(kGhosttyUrlPatternId, 'https://example.com', row: 7),
      ]);
      await tester.pump();
      expect(
        _chipFillOf(tester, 4),
        GutterMarkStyle.normal.chipColor(pathAccent),
      );
      expect(
        _chipFillOf(tester, 7),
        GutterMarkStyle.normal.chipColor(_accent),
      );
    });

    testWidgets('a mixed-accent multi-match row keeps the NEUTRAL accent',
        (tester) async {
      const pathAccent = Color(0xFF33AA55);
      final controller = await pumpGutter(
        tester,
        chipAccentOf: (id) =>
            id == kGhosttyPathPatternId ? pathAccent : _accent,
      );
      controller.setAnchors([
        _anchor(kGhosttyPathPatternId, '/etc/hosts', row: 4),
        _anchor(kGhosttyUrlPatternId, 'https://example.com', row: 4),
      ]);
      await tester.pump();
      expect(
        _chipFillOf(tester, 4),
        GutterMarkStyle.normal.chipColor(_accent),
        reason: 'no single override applies to a mixed row',
      );
    });

    testWidgets('url + osc8 on one row share the url family accent',
        (tester) async {
      const urlAccent = Color(0xFFFF8800);
      final controller = await pumpGutter(
        tester,
        chipAccentOf: (id) =>
            (id == kGhosttyUrlPatternId || id == kGhosttyOsc8PatternId)
                ? urlAccent
                : _accent,
      );
      controller.setAnchors([
        _anchor(kGhosttyUrlPatternId, 'https://a.example', row: 4),
        _anchor(kGhosttyOsc8PatternId, 'https://b.example', row: 4),
      ]);
      await tester.pump();
      expect(
        _chipFillOf(tester, 4),
        GutterMarkStyle.normal.chipColor(urlAccent),
        reason: 'both patterns resolve to ONE accent → the row uses it',
      );
    });

    testWidgets('ZERO CHANGE: an empty-store resolver chips the SAME fill as '
        'no seam at all', (tester) async {
      final bare = await pumpGutter(tester);
      bare.setAnchors([_anchor(kGhosttyUrlPatternId, 'https://x.example')]);
      await tester.pump();
      final baseline = _chipFillOf(tester, 2);

      const resolver = DetectionStyleResolver(
        styles: DetectionStyles.empty,
        accent: _accent,
        backgroundBrightness: Brightness.dark,
      );
      final wired = await pumpGutter(
        tester,
        chipAccentOf: (id) =>
            resolver.resolveStyle(id, verified: false).chipAccent,
      );
      wired.setAnchors([_anchor(kGhosttyUrlPatternId, 'https://x.example')]);
      await tester.pump();
      expect(_chipFillOf(tester, 2), baseline);
    });
  });
}
