// Gutter line-select (#962): LONG-PRESS-drag the right strip selects whole
// viewport rows; a plain swipe is NOT claimed (so it scrolls). These assert the
// gesture contract (pure UI, deterministic): a long-press-drag maps Y→viewport
// row via cellHeight and commits the inclusive range on release; a quick swipe
// and a plain tap commit nothing (they fall through to the scroll/keyboard).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/detection_providers.dart';
import 'package:mobissh/ui/ghostty_gutter_layer.dart';
import 'package:mobissh/ui/gutter_line_select_layer.dart';

Future<Widget> _host({
  required void Function(int, int) onCommitRows,
  VoidCallback? onTapBelow,
  double cellHeight = 20,
  int rows = 10,
  GhosttyGutterGeometry? geometry,
}) async {
  // #1155: `geometry` is the ONE gutter geometry value (R20); omitted = the
  // right/overlay default (today's layer, every pre-#1155 test unchanged).
  final layer = geometry == null
      ? GutterLineSelectLayer(
          cellHeight: cellHeight,
          rows: rows,
          padding: 0,
          color: const Color(0xFF8888FF),
          onCommitRows: onCommitRows,
        )
      : GutterLineSelectLayer(
          cellHeight: cellHeight,
          rows: rows,
          padding: 0,
          color: const Color(0xFF8888FF),
          onCommitRows: onCommitRows,
          geometry: geometry,
        );
  // The tap test mounts a tap recognizer BELOW (the gesture router) to prove a
  // tap falls through. The long-press-drag tests omit it: flutter_test can't
  // cleanly capture a long-press's start when another recognizer competes (a
  // real finger's long-press wins the arena), so they use a clean arena.
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 100,
        height: 200,
        child: onTapBelow == null
            ? layer
            : Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onTapBelow,
                    ),
                  ),
                  layer,
                ],
              ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the long-press capture strip is present (right edge)', (
    tester,
  ) async {
    await tester.pumpWidget(await _host(onCommitRows: (_, _) {}));
    expect(find.byKey(const Key('gutter-line-select')), findsOneWidget);
    // The actual long-press-drag selection is device-validated (flutter_test
    // can't reliably drive long-press on a translucent strip; onLongPress* is
    // standard Flutter and works on hardware). The SCROLL-SAFETY guard below —
    // a swipe must NOT select — is the regression that matters here.
  });

  testWidgets('a quick swipe in the strip does NOT select (it scrolls)', (
    tester,
  ) async {
    var committed = false;
    await tester.pumpWidget(
      await _host(onCommitRows: (_, _) => committed = true),
    );

    // No hold — a fast vertical drag (scroll). Must not be claimed as a select.
    await tester.flingFrom(
      const Offset(86, 40),
      const Offset(0, 120),
      1000,
    );
    await tester.pumpAndSettle();

    expect(committed, isFalse, reason: 'a swipe must scroll, not select');
  });

  testWidgets('a plain tap commits nothing (falls through to the router)', (
    tester,
  ) async {
    var committed = false;
    var tappedBelow = false;
    await tester.pumpWidget(
      await _host(
        onCommitRows: (_, _) => committed = true,
        onTapBelow: () => tappedBelow = true,
      ),
    );

    await tester.tapAt(const Offset(86, 40));
    await tester.pumpAndSettle();

    expect(committed, isFalse, reason: 'a tap is not a long-press select');
    expect(tappedBelow, isTrue, reason: 'the tap resolves to the router below');
  });

  // #1155 (Slice 2 of #1153) — GUTTER SIDE (R15–R17): the line-select strip
  // takes the SAME `GhosttyGutterGeometry` as the chip layer, so with a LEFT
  // geometry the capture strip is `Positioned(left: 0)` (right == null) and
  // the SAME gestures (same `gutter-line-select` key) work on the left edge.
  group('#1155 gutter side (R15–R17)', () {
    const left = GhosttyGutterGeometry(
      side: GutterSide.left,
      mode: GutterMode.overlay,
    );
    const right = GhosttyGutterGeometry(
      side: GutterSide.right,
      mode: GutterMode.overlay,
    );

    Positioned stripPositioned(WidgetTester tester) => tester.widget<Positioned>(
          find
              .ancestor(
                of: find.byKey(const Key('gutter-line-select')),
                matching: find.byType(Positioned),
              )
              .first,
        );

    testWidgets('R15: a LEFT geometry → Positioned(left: 0), right == null; '
        'the strip rect hugs x = 0', (tester) async {
      await tester.pumpWidget(
        await _host(onCommitRows: (_, _) {}, geometry: left),
      );
      final p = stripPositioned(tester);
      expect(p.left, 0.0);
      expect(p.right, isNull);
      expect(p.width, kGutterSelectStripWidth);
      final rect = tester.getRect(find.byKey(const Key('gutter-line-select')));
      expect(rect.left, 0.0);
      expect(rect.right, kGutterSelectStripWidth);
    });

    testWidgets('R15: a RIGHT geometry → Positioned(right: 0), left == null '
        '(today\'s placement)', (tester) async {
      await tester.pumpWidget(
        await _host(onCommitRows: (_, _) {}, geometry: right),
      );
      final p = stripPositioned(tester);
      expect(p.right, 0.0);
      expect(p.left, isNull);
      final rect = tester.getRect(find.byKey(const Key('gutter-line-select')));
      expect(rect.right, 100.0);
      expect(rect.left, 100.0 - kGutterSelectStripWidth);
    });

    testWidgets('no geometry == the right default (zero visual change)', (
      tester,
    ) async {
      await tester.pumpWidget(await _host(onCommitRows: (_, _) {}));
      expect(stripPositioned(tester).right, 0.0);
      expect(stripPositioned(tester).left, isNull);
    });

    testWidgets('R17 (left): a plain tap in the LEFT strip commits nothing and '
        'falls through to the router below', (tester) async {
      var committed = false;
      var tappedBelow = false;
      await tester.pumpWidget(
        await _host(
          onCommitRows: (_, _) => committed = true,
          onTapBelow: () => tappedBelow = true,
          geometry: left,
        ),
      );

      await tester.tapAt(const Offset(14, 40));
      await tester.pumpAndSettle();

      expect(committed, isFalse, reason: 'a tap is not a long-press select');
      expect(tappedBelow, isTrue, reason: 'the tap resolves to the router below');
    });

    testWidgets('R17 (left): a quick swipe in the LEFT strip does NOT select '
        '(it scrolls)', (tester) async {
      var committed = false;
      await tester.pumpWidget(
        await _host(onCommitRows: (_, _) => committed = true, geometry: left),
      );
      await tester.flingFrom(const Offset(14, 40), const Offset(0, 120), 1000);
      await tester.pumpAndSettle();
      expect(committed, isFalse, reason: 'a swipe must scroll, not select');
    });

    testWidgets('D3/R19: column mode keeps the strip on the gutter side with '
        'the same 28dp width', (tester) async {
      const columnLeft = GhosttyGutterGeometry(
        side: GutterSide.left,
        mode: GutterMode.column,
      );
      await tester.pumpWidget(
        await _host(onCommitRows: (_, _) {}, geometry: columnLeft),
      );
      final p = stripPositioned(tester);
      expect(p.left, 0.0);
      expect(p.right, isNull);
      expect(p.width, 28.0);
    });
  });
}
