// Gutter line-select (#962): dragging the right-edge strip reports the WHOLE
// viewport-row range on release (the parent copies those lines, paint-free).
// These assert the gesture→row-range contract (pure UI, deterministic — NOT a
// device-class false green): a vertical drag maps Y→viewport-row via cellHeight,
// normalises a bottom-to-top drag, and a plain tap commits nothing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/gutter_line_select_layer.dart';

Future<Widget> _host({
  required void Function(int, int) onCommitRows,
  VoidCallback? onTapBelow,
  double cellHeight = 20,
  int rows = 10,
}) async {
  // When [onTapBelow] is provided we ALSO mount a tap recognizer BELOW the layer
  // — the production stack has the gesture router there — to prove a tap (no
  // movement) resolves to the router, not a commit. (The flutter_test drag
  // simulation can't cleanly capture a drag's START position when another
  // recognizer competes, so the drag tests omit it; a real finger-drag wins the
  // arena and captures the down position, as those tests model with a clean
  // arena.)
  final layer = GutterLineSelectLayer(
    cellHeight: cellHeight,
    rows: rows,
    padding: 0,
    color: const Color(0xFF8888FF),
    onCommitRows: onCommitRows,
  );
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

  testWidgets('a downward drag commits the dragged rows', (tester) async {
    int? top;
    int? bottom;
    await tester.pumpWidget(
      await _host(onCommitRows: (t, b) {
        top = t;
        bottom = b;
      }),
    );

    // Strip is the right 28px; x=86 is inside it. cellHeight 20, padding 0:
    // y=10 → row 0, y=70 → row 3.
    final g = await tester.startGesture(const Offset(86, 10));
    await tester.pump(const Duration(milliseconds: 16));
    await g.moveTo(const Offset(86, 30));
    await tester.pump();
    await g.moveTo(const Offset(86, 50));
    await tester.pump();
    await g.moveTo(const Offset(86, 70));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();

    expect(top, 0);
    expect(bottom, 3);
  });

  testWidgets('a bottom-to-top drag normalises to top ≤ bottom', (tester) async {
    int? top;
    int? bottom;
    await tester.pumpWidget(
      await _host(onCommitRows: (t, b) {
        top = t;
        bottom = b;
      }),
    );

    final g = await tester.startGesture(const Offset(86, 90)); // row 4
    await tester.pump(const Duration(milliseconds: 16));
    await g.moveTo(const Offset(86, 50));
    await tester.pump();
    await g.moveTo(const Offset(86, 30)); // row 1
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();

    expect(top, 1);
    expect(bottom, 4);
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

    expect(committed, isFalse, reason: 'a tap is not a line-select drag');
    expect(tappedBelow, isTrue, reason: 'the tap resolves to the router below');
  });
}
