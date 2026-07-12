// #1031 slice 1 — the painters CONSUME the style resolver. #1074 relocated the
// wash to a LIVE widget layer under a transparent terminal (its colour gate is
// in ghostty_wash_style_1045_test.dart's ghosttyWashCapsuleColor group); the
// GUTTER keeps its widget-layer chipAccentOf seam (per-pattern chip hue), pinned
// here. The zero-change invariant: a resolver over an EMPTY store paints EXACTLY
// what the layer painted before the seam existed.

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
