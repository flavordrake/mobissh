import 'package:flterm/src/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart' show TerminalScreen;

void main() {
  Widget buildScrollable(
    TerminalScrollController controller, {
    double contentHeight = 500,
    double viewportHeight = 200,
  }) {
    return MaterialApp(
      home: SizedBox(
        height: viewportHeight,
        child: ListView(
          controller: controller,
          children: [SizedBox(height: contentHeight)],
        ),
      ),
    );
  }

  group('TerminalScrollController', () {
    late TerminalScrollController controller;

    setUp(() => controller = TerminalScrollController());

    tearDown(() => controller.dispose());

    group('constructor', () {
      test('defaults activeScreen to primary', () {
        expect(controller.activeScreen, TerminalScreen.primary);
      });
    });

    group('createScrollPosition', () {
      testWidgets('returns TerminalScrollPosition', (tester) async {
        await tester.pumpWidget(buildScrollable(controller));

        expect(controller.position, isA<TerminalScrollPosition>());
      });
    });

    group('activeScreen', () {
      testWidgets('propagates to attached positions', (tester) async {
        await tester.pumpWidget(buildScrollable(controller));

        controller.activeScreen = .alternate;

        final position = controller.position as TerminalScrollPosition;
        expect(position.activeScreen, TerminalScreen.alternate);

        controller.activeScreen = .primary;
        expect(position.activeScreen, TerminalScreen.primary);
      });
    });
  });

  group('TerminalScrollPosition', () {
    late TerminalScrollController controller;

    setUp(() => controller = TerminalScrollController());

    tearDown(() => controller.dispose());

    group('content dimensions', () {
      testWidgets('uses finite extents in primary mode', (tester) async {
        await tester.pumpWidget(buildScrollable(controller));

        final position = controller.position;
        expect(position.maxScrollExtent.isFinite, isTrue);
      });

      testWidgets('uses infinite extents in alternate mode', (tester) async {
        await tester.pumpWidget(buildScrollable(controller));

        controller.activeScreen = .alternate;
        await tester.pumpWidget(
          buildScrollable(controller, contentHeight: 501),
        );

        final position = controller.position;
        expect(position.maxScrollExtent, double.infinity);
        expect(position.minScrollExtent, double.negativeInfinity);
      });
    });

    group('activeScreen', () {
      testWidgets('saves and restores pixels on mode switch', (tester) async {
        await tester.pumpWidget(buildScrollable(controller));

        controller.jumpTo(100);
        await tester.pump();
        expect(controller.position.pixels, 100);

        controller.activeScreen = .alternate;
        await tester.pumpWidget(buildScrollable(controller));

        controller.jumpTo(9999);
        await tester.pump();
        expect(controller.position.pixels, 9999);

        controller.activeScreen = .primary;
        await tester.pumpWidget(buildScrollable(controller));

        expect(controller.position.pixels, 100);
      });

      testWidgets('clamps restored pixels to new extents', (tester) async {
        await tester.pumpWidget(buildScrollable(controller));

        final maxExtent = controller.position.maxScrollExtent;
        controller.jumpTo(maxExtent);
        await tester.pump();

        controller.activeScreen = .alternate;
        await tester.pumpWidget(buildScrollable(controller));

        await tester.pumpWidget(
          buildScrollable(controller, contentHeight: 200),
        );

        controller.activeScreen = .primary;
        await tester.pumpWidget(
          buildScrollable(controller, contentHeight: 200),
        );

        expect(controller.position.pixels, 0);
      });
    });

    group('listeners', () {
      testWidgets('notifies on scroll in alternate mode', (tester) async {
        await tester.pumpWidget(buildScrollable(controller));

        controller.activeScreen = .alternate;
        await tester.pumpWidget(buildScrollable(controller));

        var notified = false;
        controller.addListener(() => notified = true);

        controller.jumpTo(50);

        expect(notified, isTrue);
      });
    });
  });
}
