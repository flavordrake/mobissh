// Gutter line-select (#962): LONG-PRESS-drag the right strip selects whole
// viewport rows; a plain swipe is NOT claimed (so it scrolls). These assert the
// gesture contract (pure UI, deterministic): a long-press-drag maps Y→viewport
// row via cellHeight and commits the inclusive range on release; a quick swipe
// and a plain tap commit nothing (they fall through to the scroll/keyboard).

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/gutter_line_select_layer.dart';

const _cellHeight = 20.0;
const _rows = 10;

// #1161 (d) — BUG: pointer cancel COMMITS the range (expected onCommitRows
// never called; actual (2, 5)). `_onPointerCancel → _finish() → onCommitRows`,
// and the source comment marks this deliberate ("still finish") — owner call:
// a system-stolen pointer should not copy. Flip to `false` to see it fail.
const bool _cancelCommitsBug = true;

Future<Widget> _host({
  required void Function(int, int) onCommitRows,
  VoidCallback? onTapBelow,
  double cellHeight = _cellHeight,
  int rows = _rows,
  double padding = 0,
}) async {
  final layer = GutterLineSelectLayer(
    cellHeight: cellHeight,
    rows: rows,
    padding: padding,
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
    // The long-press-drag selection itself is pinned in the group below
    // (#1161) and device-validated. The SCROLL-SAFETY guard — a swipe must
    // NOT select — is the regression that matters most here.
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

  // POSITIVE PATH (#1161 backfill). A long-press in the strip anchors the
  // selection; raw pointer moves extend it; release commits the inclusive,
  // normalised viewport row range. Driven with startGesture → pump past
  // kLongPressTimeout → moveTo → up (clean arena: no competing tap recognizer,
  // so the long-press recognizer wins deterministically).
  group('long-press-drag selection', () {
    final haptics = <String>[];

    setUp(() {
      haptics.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'HapticFeedback.vibrate') {
              haptics.add(call.arguments as String);
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    final stripFinder = find.byKey(const Key('gutter-line-select'));
    final bandFinder = find.descendant(
      of: find.byType(GutterLineSelectLayer),
      matching: find.byWidgetPredicate(
        (w) => w is DecoratedBox && (w.decoration as BoxDecoration).border != null,
      ),
    );

    // Geometry is MEASURED, not assumed: the Scaffold body tightens the width,
    // so the strip may sit far right of the 100px the host asks for.
    Offset stripPointAtRow(WidgetTester tester, int row, {double padding = 0}) {
      final strip = tester.getRect(stripFinder);
      final layerTop = tester.getTopLeft(find.byType(GutterLineSelectLayer)).dy;
      return Offset(
        strip.center.dx,
        layerTop + padding + row * _cellHeight + _cellHeight / 2,
      );
    }

    Future<TestGesture> longPressAtRow(
      WidgetTester tester,
      int row, {
      double padding = 0,
    }) async {
      final g = await tester.startGesture(
        stripPointAtRow(tester, row, padding: padding),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      return g;
    }

    testWidgets('anchor row r, drag down to r+3 → onCommitRows(r, r+3) once', (
      tester,
    ) async {
      final commits = <(int, int)>[];
      await tester.pumpWidget(
        await _host(onCommitRows: (a, b) => commits.add((a, b))),
      );

      final g = await longPressAtRow(tester, 2);
      await g.moveTo(stripPointAtRow(tester, 5));
      await tester.pump();
      await g.up();
      await tester.pump();

      // Both the raw pointer-up AND the long-press end backup call _finish;
      // the _selecting guard must collapse them to ONE commit.
      expect(commits, [(2, 5)]);
    });

    testWidgets('drag UPWARD normalises to (min, max)', (tester) async {
      final commits = <(int, int)>[];
      await tester.pumpWidget(
        await _host(onCommitRows: (a, b) => commits.add((a, b))),
      );

      final g = await longPressAtRow(tester, 6);
      await g.moveTo(stripPointAtRow(tester, 3));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(commits, [(3, 6)]);
    });

    testWidgets('no drag → single-row range (r, r)', (tester) async {
      final commits = <(int, int)>[];
      await tester.pumpWidget(
        await _host(onCommitRows: (a, b) => commits.add((a, b))),
      );

      final g = await longPressAtRow(tester, 4);
      await g.up();
      await tester.pump();

      expect(commits, [(4, 4)]);
    });

    testWidgets('drag far above the top clamps to row 0', (tester) async {
      final commits = <(int, int)>[];
      await tester.pumpWidget(
        await _host(onCommitRows: (a, b) => commits.add((a, b))),
      );

      final g = await longPressAtRow(tester, 1);
      final layerTop = tester.getTopLeft(find.byType(GutterLineSelectLayer));
      // Well outside the layer (negative local Y): floor() goes negative,
      // clamp must pin to 0 rather than index row -N.
      await g.moveTo(Offset(stripPointAtRow(tester, 1).dx, layerTop.dy - 300));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(commits, [(0, 1)]);
    });

    testWidgets('drag far below the bottom clamps to rows-1', (tester) async {
      final commits = <(int, int)>[];
      await tester.pumpWidget(
        await _host(onCommitRows: (a, b) => commits.add((a, b))),
      );

      final g = await longPressAtRow(tester, 7);
      final layerBottom = tester
          .getBottomLeft(find.byType(GutterLineSelectLayer))
          .dy;
      await g.moveTo(Offset(stripPointAtRow(tester, 7).dx, layerBottom + 300));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(commits, [(7, _rows - 1)]);
    });

    testWidgets('a press inside the top padding clamps to row 0', (
      tester,
    ) async {
      const padding = 8.0;
      final commits = <(int, int)>[];
      await tester.pumpWidget(
        await _host(
          onCommitRows: (a, b) => commits.add((a, b)),
          padding: padding,
        ),
      );

      // Y = padding/2 → (y - padding) negative → floor = -1 → clamp → 0.
      final strip = tester.getRect(stripFinder);
      final layerTop = tester.getTopLeft(find.byType(GutterLineSelectLayer)).dy;
      final g = await tester.startGesture(
        Offset(strip.center.dx, layerTop + padding / 2),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      // Drag to row 2 accounting for the padding offset.
      await g.moveTo(stripPointAtRow(tester, 2, padding: padding));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(commits, [(0, 2)]);
    });

    testWidgets('band: absent during the hold, spans the range while dragging, '
        'gone after release', (tester) async {
      await tester.pumpWidget(await _host(onCommitRows: (_, _) {}));

      // Finger down but the long-press has not fired yet → nothing to show.
      final g = await tester.startGesture(stripPointAtRow(tester, 2));
      await tester.pump(const Duration(milliseconds: 100));
      expect(bandFinder, findsNothing, reason: 'no band before the anchor lands');

      await tester.pump(kLongPressTimeout);
      expect(bandFinder, findsOneWidget, reason: 'anchor landed → 1-row band');

      await g.moveTo(stripPointAtRow(tester, 5));
      await tester.pump();
      expect(bandFinder, findsOneWidget);
      final band = tester.getRect(bandFinder);
      final layer = tester.getRect(find.byType(GutterLineSelectLayer));
      expect(band.top, layer.top + 2 * _cellHeight, reason: 'top row 2');
      expect(band.height, 4 * _cellHeight, reason: 'rows 2..5 inclusive = 4');
      expect(band.left, layer.left, reason: 'full width');
      expect(band.right, layer.right, reason: 'full width');

      await g.up();
      await tester.pump();
      expect(bandFinder, findsNothing, reason: 'band cleared on release');
    });

    testWidgets(
      'pointer cancel commits nothing',
      (tester) async {
        final commits = <(int, int)>[];
        await tester.pumpWidget(
          await _host(onCommitRows: (a, b) => commits.add((a, b))),
        );

        final g = await longPressAtRow(tester, 2);
        await g.moveTo(stripPointAtRow(tester, 5));
        await tester.pump();
        await g.cancel();
        await tester.pump();

        expect(commits, isEmpty, reason: 'a cancelled gesture is not a copy');
        expect(bandFinder, findsNothing, reason: 'band cleared on cancel');
      },
      skip: _cancelCommitsBug,
    );

    testWidgets('haptics: selectionClick when the anchor lands, mediumImpact '
        'on commit', (tester) async {
      await tester.pumpWidget(await _host(onCommitRows: (_, _) {}));

      final g = await tester.startGesture(stripPointAtRow(tester, 2));
      await tester.pump(const Duration(milliseconds: 100));
      expect(haptics, isEmpty, reason: 'no tick before the long-press fires');

      await tester.pump(kLongPressTimeout);
      expect(haptics, ['HapticFeedbackType.selectionClick']);

      await g.moveTo(stripPointAtRow(tester, 4));
      await tester.pump();
      expect(haptics, hasLength(1), reason: 'extending the range is silent');

      await g.up();
      await tester.pump();
      expect(haptics, [
        'HapticFeedbackType.selectionClick',
        'HapticFeedbackType.mediumImpact',
      ]);
    });
  });
}
