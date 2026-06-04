@Tags(['ffi'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart' show Mods, MouseTracking, Terminal;

void main() {
  group('TerminalGestureDetector', () {
    const defaultMetrics = CellMetrics(
      cellWidth: 8,
      cellHeight: 16,
      baseline: 12,
    );
    final enableNormalMouse = Uint8List.fromList(utf8.encode('\x1b[?1000h'));
    final enableX10Mouse = Uint8List.fromList(utf8.encode('\x1b[?9h'));

    TerminalViewBinding bindingFor(TerminalController controller) {
      return controller as TerminalViewBinding;
    }

    Terminal terminalFor(TerminalController controller) {
      return bindingFor(controller).terminal;
    }

    void writeToTerminal(TerminalController controller, String text) {
      terminalFor(controller).write(Uint8List.fromList(utf8.encode(text)));
    }

    Widget buildHandler({
      required TerminalController controller,
      CellMetrics metrics = defaultMetrics,
      TerminalGestureSettings gestureSettings = const TerminalGestureSettings(),
      ScrollController? scrollController,
      int visibleRows = 24,
    }) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: TerminalGestureDetector(
            binding: controller as TerminalViewBinding,
            metrics: metrics,
            settings: gestureSettings,
            scrollController: scrollController,
            visibleRows: visibleRows,
            child: const SizedBox(width: 640, height: 384),
          ),
        ),
      );
    }

    void enableMouseTracking(
      TerminalController controller, {
      MouseTracking mode = .normal,
    }) {
      final seq = switch (mode) {
        .normal => enableNormalMouse,
        .x10 => enableX10Mouse,
        _ => enableNormalMouse,
      };
      final viewBinding = bindingFor(controller);
      viewBinding.terminal.write(seq);
      viewBinding.handleResize(
        cols: 80,
        rows: 24,
        metrics: defaultMetrics,
        padding: EdgeInsets.zero,
        devicePixelRatio: 1.0,
      );
    }

    Future<TestGesture> mouseDown(
      WidgetTester tester,
      Offset pos, {
      int buttons = kPrimaryButton,
    }) {
      return tester.startGesture(pos, kind: .mouse, buttons: buttons);
    }

    late TerminalController controller;

    setUp(() => controller = TerminalController());

    tearDown(() => controller.dispose());

    Future<void> tapMouse(
      WidgetTester tester,
      Offset position, {
      int count = 1,
    }) async {
      for (var i = 0; i < count; i++) {
        final gesture = await mouseDown(tester, position);
        await gesture.up();
      }
    }

    testWidgets('tap leaves selection empty', (tester) async {
      await tester.pumpWidget(buildHandler(controller: controller));

      await tapMouse(tester, const Offset(40, 16));

      expect(controller.selection, isNull);
    });

    testWidgets('drag creates selection with correct cells', (tester) async {
      await tester.pumpWidget(buildHandler(controller: controller));

      final gesture = await mouseDown(tester, const Offset(8, 0));
      await gesture.moveTo(const Offset(40, 16));
      await gesture.up();

      final selection = controller.selection!;
      expect(selection.startRow, 0);
      expect(selection.startCol, 1);
      expect(selection.endRow, 1);
      expect(selection.endCol, 5);
      expect(selection.mode, TerminalSelectionMode.normal);
    });

    testWidgets('mouse up ends selection drag', (tester) async {
      await tester.pumpWidget(buildHandler(controller: controller));

      final gesture = await mouseDown(tester, Offset.zero);
      await gesture.moveTo(const Offset(80, 32));
      await gesture.up();

      final selection = controller.selection!;
      expect(selection.startRow, 0);
      expect(selection.endRow, 2);
    });

    testWidgets('drag to same cell does not change selection', (tester) async {
      await tester.pumpWidget(buildHandler(controller: controller));

      final gesture = await mouseDown(tester, const Offset(8, 0));
      await gesture.moveTo(const Offset(40, 16));
      final selAfterFirst = controller.selection;

      await gesture.moveTo(const Offset(41, 17));
      final selAfterSecond = controller.selection;

      expect(selAfterFirst, selAfterSecond);

      await gesture.up();
    });

    testWidgets('double click selects word', (tester) async {
      writeToTerminal(controller, 'hello world');

      await tester.pumpWidget(buildHandler(controller: controller));

      await tapMouse(tester, const Offset(8, 0), count: 2);

      final selection = controller.selection!;
      expect(selection.startRow, 0);
      expect(selection.startCol, 0);
      expect(selection.endCol, 5);
    });

    testWidgets('double click on second word selects it', (tester) async {
      writeToTerminal(controller, 'hello world');

      await tester.pumpWidget(buildHandler(controller: controller));

      await tapMouse(tester, const Offset(56, 0), count: 2);

      final selection = controller.selection!;
      expect(selection.startCol, 6);
      expect(selection.endCol, 11);
    });

    testWidgets('triple click selects line content only', (tester) async {
      writeToTerminal(controller, 'Hello');

      await tester.pumpWidget(buildHandler(controller: controller));

      await tapMouse(tester, const Offset(40, 0), count: 3);

      final selection = controller.selection!;
      expect(selection.startCol, 0);
      expect(selection.endCol, 5);
    });

    testWidgets('triple click on wrapped line selects full terminal line', (
      tester,
    ) async {
      final narrowController = TerminalController(
        config: const TerminalConfig(cols: 10, rows: 5),
      );
      addTearDown(narrowController.dispose);

      writeToTerminal(narrowController, 'ABCDEFGHIJKLMNO');

      await tester.pumpWidget(buildHandler(controller: narrowController));

      await tapMouse(tester, const Offset(8, 16), count: 3);

      final selection = narrowController.selection!;
      expect(selection.startRow, 0);
      expect(selection.startCol, 0);
      expect(selection.endRow, 1);
      expect(selection.endCol, 5);
    });

    testWidgets('triple click with fullRow mode selects entire row width', (
      tester,
    ) async {
      final wideController = TerminalController(
        config: const TerminalConfig(cols: 20, rows: 5),
      );
      addTearDown(wideController.dispose);

      writeToTerminal(wideController, 'Hello');

      await tester.pumpWidget(
        buildHandler(
          controller: wideController,
          gestureSettings: const TerminalGestureSettings(lineSelectMode: .full),
        ),
      );

      await tapMouse(tester, const Offset(8, 0), count: 3);

      final selection = wideController.selection!;
      expect(selection.endCol, 20);
    });

    testWidgets('tap counting resets on distant clicks', (tester) async {
      await tester.pumpWidget(buildHandler(controller: controller));

      await tapMouse(tester, const Offset(40, 16));
      await tapMouse(tester, const Offset(200, 200));

      expect(controller.selection, isNull);
    });

    testWidgets('touch long press starts normal selection by default', (
      tester,
    ) async {
      await tester.pumpWidget(buildHandler(controller: controller));

      final gesture = await tester.startGesture(const Offset(40, 16));

      await tester.pump(const Duration(milliseconds: 550));

      expect(controller.selection, isNull);

      await gesture.moveTo(const Offset(80, 32));
      final sel = controller.selection!;
      expect(sel.mode, TerminalSelectionMode.normal);

      await gesture.up();
    });

    testWidgets('touch move cancels long press if distance exceeds threshold', (
      tester,
    ) async {
      await tester.pumpWidget(buildHandler(controller: controller));

      final gesture = await tester.startGesture(const Offset(40, 16));
      await gesture.moveTo(const Offset(80, 16));

      await tester.pump(const Duration(milliseconds: 550));

      await gesture.moveTo(const Offset(120, 16));
      expect(controller.selection, isNull);

      await gesture.up();
    });

    testWidgets('new click clears existing selection', (tester) async {
      await tester.pumpWidget(buildHandler(controller: controller));

      final gesture = await mouseDown(tester, Offset.zero);
      await gesture.moveTo(const Offset(80, 32));
      await gesture.up();

      expect(controller.selection, isNotNull);

      final gesture2 = await mouseDown(tester, const Offset(40, 16));
      await gesture2.up();

      expect(controller.selection, isNull);
    });

    testWidgets('click without existing selection keeps selection null', (
      tester,
    ) async {
      await tester.pumpWidget(buildHandler(controller: controller));

      final gesture = await mouseDown(tester, const Offset(40, 16));
      await gesture.up();

      expect(controller.selection, isNull);
    });

    group('gesture settings', () {
      testWidgets('empty enabledSelections prevents drag selection', (
        tester,
      ) async {
        await tester.pumpWidget(
          buildHandler(
            controller: controller,
            gestureSettings: const TerminalGestureSettings(
              enabledSelections: {},
            ),
          ),
        );

        final gesture = await mouseDown(tester, const Offset(8, 0));
        await gesture.moveTo(const Offset(80, 32));
        await gesture.up();

        expect(controller.selection, isNull);
      });

      testWidgets('empty enabledSelections prevents long press selection', (
        tester,
      ) async {
        await tester.pumpWidget(
          buildHandler(
            controller: controller,
            gestureSettings: const TerminalGestureSettings(
              enabledSelections: {},
            ),
          ),
        );

        final gesture = await tester.startGesture(const Offset(40, 16));
        await tester.pump(const Duration(milliseconds: 550));
        await gesture.moveTo(const Offset(80, 32));
        await gesture.up();

        expect(controller.selection, isNull);
      });

      testWidgets('drag disabled independently of other gestures', (
        tester,
      ) async {
        writeToTerminal(controller, 'hello world');

        await tester.pumpWidget(
          buildHandler(
            controller: controller,
            gestureSettings: const TerminalGestureSettings(
              enabledSelections: {.word},
            ),
          ),
        );

        final gesture = await mouseDown(tester, const Offset(8, 0));
        await gesture.moveTo(const Offset(80, 32));
        await gesture.up();
        expect(controller.selection, isNull);

        await tapMouse(tester, const Offset(8, 0), count: 2);

        expect(controller.selection, isNotNull);
      });

      testWidgets('word disabled prevents double-tap word select', (
        tester,
      ) async {
        writeToTerminal(controller, 'hello world');

        await tester.pumpWidget(
          buildHandler(
            controller: controller,
            gestureSettings: const TerminalGestureSettings(
              enabledSelections: {.drag, .line, .longPress},
            ),
          ),
        );

        await tapMouse(tester, const Offset(8, 0), count: 2);

        expect(controller.selection, isNull);
      });

      testWidgets('line disabled prevents triple-tap line select', (
        tester,
      ) async {
        await tester.pumpWidget(
          buildHandler(
            controller: controller,
            gestureSettings: const TerminalGestureSettings(
              enabledSelections: {.drag},
            ),
          ),
        );

        await tapMouse(tester, const Offset(40, 16), count: 3);

        expect(controller.selection, isNull);
      });

      testWidgets('tap count resets at triple even when line disabled', (
        tester,
      ) async {
        writeToTerminal(controller, 'hello world');

        await tester.pumpWidget(
          buildHandler(
            controller: controller,
            gestureSettings: const TerminalGestureSettings(
              enabledSelections: {.word},
            ),
          ),
        );

        var selectionCount = 0;
        controller.addListener(() {
          if (controller.selection != null) selectionCount++;
        });

        await tapMouse(tester, const Offset(8, 0), count: 5);

        expect(selectionCount, 2);
      });

      testWidgets('longPressSelectionMode block uses block mode', (
        tester,
      ) async {
        await tester.pumpWidget(
          buildHandler(
            controller: controller,
            gestureSettings: const TerminalGestureSettings(
              longPressSelectionMode: .block,
            ),
          ),
        );

        final gesture = await tester.startGesture(const Offset(40, 16));
        await tester.pump(const Duration(milliseconds: 550));
        await gesture.moveTo(const Offset(80, 32));
        await gesture.up();

        final selection = controller.selection!;
        expect(selection.mode, TerminalSelectionMode.block);
      });

      testWidgets('empty enabledSelections still allows tap', (tester) async {
        await tester.pumpWidget(
          buildHandler(
            controller: controller,
            gestureSettings: const TerminalGestureSettings(
              enabledSelections: {},
            ),
          ),
        );

        final gesture = await mouseDown(tester, const Offset(40, 16));
        await gesture.up();

        expect(controller.selection, isNull);
      });

      testWidgets(
        'empty enabledSelections still allows mouse tracking output',
        (tester) async {
          enableMouseTracking(controller);

          await tester.pumpWidget(
            buildHandler(
              controller: controller,
              gestureSettings: const TerminalGestureSettings(
                enabledSelections: {},
              ),
            ),
          );

          final events = <Uint8List>[];
          controller.onOutput = events.add;

          final gesture = await mouseDown(tester, const Offset(24, 16));
          await gesture.up();

          expect(events, isNotEmpty);
        },
      );
    });

    group('virtual mods', () {
      testWidgets('virtual alt triggers block selection on drag', (
        tester,
      ) async {
        controller.toggleMod(const Mods.alt());

        await tester.pumpWidget(buildHandler(controller: controller));

        final gesture = await mouseDown(tester, const Offset(8, 0));
        await gesture.moveTo(const Offset(80, 32));
        await gesture.up();

        final selection = controller.selection!;
        expect(selection.mode, TerminalSelectionMode.block);
      });

      testWidgets('virtual alt triggers block selection on long press', (
        tester,
      ) async {
        controller.toggleMod(const Mods.alt());

        await tester.pumpWidget(buildHandler(controller: controller));

        final gesture = await tester.startGesture(const Offset(40, 16));
        await tester.pump(const Duration(milliseconds: 550));
        await gesture.moveTo(const Offset(80, 32));
        await gesture.up();

        final selection = controller.selection!;
        expect(selection.mode, TerminalSelectionMode.block);
      });

      testWidgets('toggling alt mid-drag switches selection mode', (
        tester,
      ) async {
        await tester.pumpWidget(buildHandler(controller: controller));

        final gesture = await mouseDown(tester, const Offset(8, 0));
        await gesture.moveTo(const Offset(80, 32));
        expect(controller.selection!.mode, TerminalSelectionMode.normal);

        controller.toggleMod(const Mods.alt());
        await gesture.moveTo(const Offset(80, 48));
        expect(controller.selection!.mode, TerminalSelectionMode.block);

        controller.toggleMod(const Mods.alt());
        await gesture.moveTo(const Offset(80, 64));
        expect(controller.selection!.mode, TerminalSelectionMode.normal);

        await gesture.up();
      });

      testWidgets('virtual shift bypasses mouse tracking', (tester) async {
        controller.toggleMod(const Mods.shift());
        enableMouseTracking(controller);

        final events = <Uint8List>[];
        controller.onOutput = events.add;

        await tester.pumpWidget(buildHandler(controller: controller));

        final gesture = await mouseDown(tester, const Offset(24, 16));
        await gesture.up();

        expect(events, isEmpty);
      });
    });

    group('wide character selection snapping', () {
      setUp(() {
        terminalFor(controller).write(Uint8List.fromList(utf8.encode('AB日CD')));
      });

      testWidgets('drag from spacer snaps anchor inclusive', (tester) async {
        await tester.pumpWidget(buildHandler(controller: controller));

        final gesture = await mouseDown(tester, const Offset(24, 0));
        await gesture.moveTo(const Offset(40, 0));
        await gesture.up();

        final selection = controller.selection!;
        expect(selection.startCol, 2);
        expect(selection.endCol, 5);
      });

      testWidgets('drag ending on wide char snaps end exclusive', (
        tester,
      ) async {
        await tester.pumpWidget(buildHandler(controller: controller));

        final gesture = await mouseDown(tester, Offset.zero);
        await gesture.moveTo(const Offset(24, 0));
        expect(controller.selection!.endCol, 4);

        await gesture.moveTo(const Offset(16, 0));
        expect(controller.selection!.endCol, 4);

        await gesture.up();
      });

      testWidgets('leftward drag from spacer snaps anchor exclusive', (
        tester,
      ) async {
        await tester.pumpWidget(buildHandler(controller: controller));

        final gesture = await mouseDown(tester, const Offset(24, 0));
        await gesture.moveTo(Offset.zero);
        await gesture.up();

        final selection = controller.selection!;
        expect(selection.startCol, 4);
        expect(selection.endCol, 0);
      });

      testWidgets('narrow cells pass through unaffected', (tester) async {
        await tester.pumpWidget(buildHandler(controller: controller));

        final gesture = await mouseDown(tester, Offset.zero);
        await gesture.moveTo(const Offset(8, 0));
        await gesture.up();

        final selection = controller.selection!;
        expect(selection.startCol, 0);
        expect(selection.endCol, 1);
      });

      testWidgets('double click on spacer selects wide char', (tester) async {
        await tester.pumpWidget(buildHandler(controller: controller));

        await tapMouse(tester, const Offset(24, 0), count: 2);

        final selection = controller.selection!;
        expect(selection.startCol, 2);
        expect(selection.endCol, 4);
      });
    });

    group('mouse tracking', () {
      testWidgets('click fires press and release when mode is normal', (
        tester,
      ) async {
        enableMouseTracking(controller);

        final events = <Uint8List>[];
        controller.onOutput = events.add;

        await tester.pumpWidget(buildHandler(controller: controller));

        final gesture = await mouseDown(tester, const Offset(24, 16));
        await gesture.up();

        expect(events.length, 2);
      });

      testWidgets('click fires press only when mode is x10', (tester) async {
        enableMouseTracking(controller, mode: .x10);

        final events = <Uint8List>[];
        controller.onOutput = events.add;

        await tester.pumpWidget(buildHandler(controller: controller));

        final gesture = await mouseDown(tester, const Offset(24, 16));
        await gesture.up();

        expect(events.length, 1);
      });

      testWidgets('no events when mode is none', (tester) async {
        final events = <Uint8List>[];
        controller.onOutput = events.add;

        await tester.pumpWidget(buildHandler(controller: controller));

        final gesture = await mouseDown(tester, const Offset(24, 16));
        await gesture.up();

        expect(events, isEmpty);
      });
    });
  });
}
