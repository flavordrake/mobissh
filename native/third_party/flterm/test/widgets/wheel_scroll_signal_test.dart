// Mouse-wheel scroll (desktop mode / DeX / connected mouse). Touch scroll flows
// through the raw gesture drag, but a wheel is a PointerSignal — the
// TerminalGestureDetector Listener had no `onPointerSignal`, so wheel events were
// dropped and wheel scroll did nothing on desktop mode. The fix routes a
// PointerScrollEvent through the controller's `handleScroll`.
//
// On the ALTERNATE screen `handleScroll` always emits (SGR wheel reports when
// mouse-tracking, else cursor up/down keys) — assert that end-to-end wire here.
// The PRIMARY-screen local scrollback scroll drives the attached ScrollController
// and is owner-validated on a real large-screen device (needs a live viewport +
// mouse).

@Tags(['ffi'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mouse wheel → handleScroll (#desktop-mode)', () {
    const metrics = CellMetrics(cellWidth: 8, cellHeight: 16, baseline: 12);

    late TerminalController controller;
    late List<int> out;

    setUp(() {
      controller = TerminalController();
      out = <int>[];
      controller.onOutput = (bytes) => out.addAll(bytes);
      // Enter the alternate screen so handleScroll is active (it no-ops on the
      // primary screen, where scrollback is a local view scroll instead).
      (controller as TerminalViewBinding).terminal.write(
            Uint8List.fromList(utf8.encode('\x1b[?1049h')),
          );
    });

    tearDown(() => controller.dispose());

    Widget harness() => Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: TerminalGestureDetector(
              binding: controller as TerminalViewBinding,
              metrics: metrics,
              settings: const TerminalGestureSettings(),
              visibleRows: 24,
              child: const SizedBox(width: 640, height: 384),
            ),
          ),
        );

    Future<void> wheel(WidgetTester tester, double dy) async {
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      final center = tester.getCenter(find.byType(TerminalGestureDetector));
      await tester.sendEventToBinding(pointer.hover(center));
      await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
      await tester.pump();
    }

    testWidgets('wheel down on the alt screen emits (no longer dropped)', (
      tester,
    ) async {
      await tester.pumpWidget(harness());
      out.clear();
      await wheel(tester, 32); // 2 lines at cellHeight 16
      expect(
        out,
        isNotEmpty,
        reason: 'a wheel PointerSignal must reach handleScroll and emit — '
            'previously it was dropped (no onPointerSignal)',
      );
    });

    testWidgets('wheel up emits a different sequence than wheel down', (
      tester,
    ) async {
      await tester.pumpWidget(harness());
      out.clear();
      await wheel(tester, -32); // up
      final up = List<int>.from(out);
      out.clear();
      await wheel(tester, 32); // down
      final down = List<int>.from(out);
      expect(up, isNotEmpty);
      expect(down, isNotEmpty);
      expect(up, isNot(equals(down)),
          reason: 'wheel up and down must route to different scroll directions');
    });
  });
}
