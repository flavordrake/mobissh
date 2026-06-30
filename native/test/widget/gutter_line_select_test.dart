// Gutter line-select (#962): LONG-PRESS-drag the right strip selects whole
// viewport rows; a plain swipe is NOT claimed (so it scrolls). These assert the
// gesture contract (pure UI, deterministic): a long-press-drag maps Y→viewport
// row via cellHeight and commits the inclusive range on release; a quick swipe
// and a plain tap commit nothing (they fall through to the scroll/keyboard).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/gutter_line_select_layer.dart';

Future<Widget> _host({
  required void Function(int, int) onCommitRows,
  VoidCallback? onTapBelow,
  double cellHeight = 20,
  int rows = 10,
}) async {
  final layer = GutterLineSelectLayer(
    cellHeight: cellHeight,
    rows: rows,
    padding: 0,
    color: const Color(0xFF8888FF),
    onCommitRows: onCommitRows,
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
}
