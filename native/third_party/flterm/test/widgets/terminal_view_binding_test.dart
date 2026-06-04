@Tags(['ffi'])
library;

import 'dart:convert';

import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/widgets/terminal_controller_impl.dart';
import 'package:flterm/src/widgets/terminal_view_binding.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart' hide KeyEvent;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TerminalViewBinding', () {
    late TerminalViewBinding binding;
    late TerminalControllerImpl controller;

    setUp(() {
      controller = TerminalControllerImpl();
      binding = controller as TerminalViewBinding;
    });

    tearDown(() => controller.dispose());

    void writeUtf8(Terminal terminal, String text) {
      terminal.write(Uint8List.fromList(utf8.encode(text)));
    }

    void writeNumberedLines(TerminalControllerImpl target, int count) {
      for (var i = 0; i < count; i++) {
        writeUtf8(target.terminal, 'line $i\r\n');
      }
    }

    group('attach and detach', () {
      test('detaches after attach', () {
        final focusNode = FocusNode();
        final scrollController = ScrollController();
        addTearDown(focusNode.dispose);
        addTearDown(scrollController.dispose);

        binding.attach(focusNode, scrollController);

        expect(binding.detach, returnsNormally);
      });

      test('re-attach replaces previous focus node', () {
        final node1 = FocusNode();
        final node2 = FocusNode();
        final scrollController1 = ScrollController();
        final scrollController2 = ScrollController();
        addTearDown(node1.dispose);
        addTearDown(node2.dispose);
        addTearDown(scrollController1.dispose);
        addTearDown(scrollController2.dispose);

        binding.attach(node1, scrollController1);

        expect(() => binding.attach(node2, scrollController2), returnsNormally);
      });
    });

    group('handleResize', () {
      test('fires onResize callback with correct dimensions', () {
        int? reportedCols;
        int? reportedRows;
        controller.onResize = (cols, rows) {
          reportedCols = cols;
          reportedRows = rows;
        };

        binding.handleResize(
          cols: 120,
          rows: 40,
          metrics: const CellMetrics(
            cellWidth: 8,
            cellHeight: 16,
            baseline: 12,
          ),
          padding: EdgeInsets.zero,
          devicePixelRatio: 1.0,
        );

        expect(reportedCols, 120);
        expect(reportedRows, 40);
      });
    });

    group('handleScroll', () {
      test('emits cursor key sequences on alternate screen', () {
        writeUtf8(controller.terminal, '\x1b[?1049h');
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        binding.handleScroll(-3);

        expect(output, hasLength(1));
        expect(output.first.length, greaterThan(0));
      });

      test('emits no output on primary screen', () {
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        binding.handleScroll(-3);

        expect(output, isEmpty);
      });

      test('emits no output for zero lines', () {
        writeUtf8(controller.terminal, '\x1b[?1049h');
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        binding.handleScroll(0);

        expect(output, isEmpty);
      });
    });

    group('updateSelection', () {
      test('creates selection with wide char snapping', () {
        final custom = TerminalControllerImpl(
          config: const TerminalConfig(cols: 20, rows: 5),
        );
        addTearDown(custom.dispose);
        final customBinding = custom as TerminalViewBinding;

        custom.terminal.write(Uint8List.fromList(utf8.encode('AB日CD')));

        customBinding.updateSelection(0, 3, 0, 5, .normal);

        final sel = custom.selection!;
        expect(sel.startCol, 2);
        expect(sel.endCol, 5);
      });
    });

    group('handleKeyEvent', () {
      test('returns handled and emits output for printable key', () {
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        final result = binding.handleKeyEvent(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.keyA,
            logicalKey: LogicalKeyboardKey.keyA,
            character: 'a',
            timeStamp: Duration.zero,
          ),
        );

        expect(result, KeyEventResult.handled);
        expect(output, isNotEmpty);
      });

      test('returns ignored for key release', () {
        final result = binding.handleKeyEvent(
          const KeyUpEvent(
            physicalKey: PhysicalKeyboardKey.keyA,
            logicalKey: LogicalKeyboardKey.keyA,
            timeStamp: Duration.zero,
          ),
        );

        expect(result, KeyEventResult.ignored);
      });

      test('clears selection on typing when enabled', () {
        controller.selection = const TerminalSelection(
          startRow: 0,
          startCol: 0,
          endRow: 0,
          endCol: 5,
        );
        controller.onOutput = (_) {};

        binding.handleKeyEvent(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.keyA,
            logicalKey: LogicalKeyboardKey.keyA,
            character: 'a',
            timeStamp: Duration.zero,
          ),
        );

        expect(controller.selection, isNull);
      });

      test('scrolls to bottom on input', () {
        final custom = TerminalControllerImpl(
          config: const TerminalConfig(cols: 20, rows: 3),
        );
        addTearDown(custom.dispose);
        final sc = ScrollController();
        final focusNode = FocusNode();
        addTearDown(focusNode.dispose);
        addTearDown(sc.dispose);
        final customBinding = custom as TerminalViewBinding;
        customBinding.attach(focusNode, sc);

        writeNumberedLines(custom, 10);
        custom.terminal.scrollViewport(-5);
        expect(
          custom.terminal.scrollbar.offset,
          lessThan(custom.scrollbackRows),
        );

        custom.onOutput = (_) {};
        customBinding.handleKeyEvent(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.keyA,
            logicalKey: LogicalKeyboardKey.keyA,
            character: 'a',
            timeStamp: Duration.zero,
          ),
        );

        expect(custom.terminal.scrollbar.offset, custom.scrollbackRows);
      });
    });

    group('scrollToBottom', () {
      test('restores viewport to bottom after scrolling up', () {
        final custom = TerminalControllerImpl(
          config: const TerminalConfig(cols: 20, rows: 3),
        );
        addTearDown(custom.dispose);

        writeNumberedLines(custom, 10);
        final bottomOffset = custom.terminal.scrollbar.offset;

        custom.terminal.scrollViewport(-5);
        expect(custom.terminal.scrollbar.offset, isNot(bottomOffset));

        custom.scrollToBottom();

        expect(custom.terminal.scrollbar.offset, bottomOffset);
      });
    });

    group('handleMouseEvent', () {
      test('emits encoded output when tracking is enabled', () {
        writeUtf8(controller.terminal, '\x1b[?1000h');
        binding.handleResize(
          cols: 80,
          rows: 24,
          metrics: const CellMetrics(
            cellWidth: 8,
            cellHeight: 16,
            baseline: 12,
          ),
          padding: EdgeInsets.zero,
          devicePixelRatio: 1.0,
        );

        final output = <Uint8List>[];
        controller.onOutput = output.add;

        binding.handleMouseEvent((
          action: .press,
          button: .left,
          pixelX: 10.0,
          pixelY: 10.0,
        ));

        expect(output, isNotEmpty);
      });

      test('does not emit when tracking is off', () {
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        binding.handleMouseEvent((
          action: .press,
          button: .left,
          pixelX: 10.0,
          pixelY: 10.0,
        ));

        expect(output, isEmpty);
      });

      test('scales pixel coordinates by devicePixelRatio', () {
        writeUtf8(controller.terminal, '\x1b[?1000h');
        binding.handleResize(
          cols: 80,
          rows: 24,
          metrics: const CellMetrics(
            cellWidth: 8,
            cellHeight: 16,
            baseline: 12,
          ),
          padding: EdgeInsets.zero,
          devicePixelRatio: 2.0,
        );

        final output = <Uint8List>[];
        controller.onOutput = output.add;

        binding.handleMouseEvent((
          action: .press,
          button: .left,
          pixelX: 8.0,
          pixelY: 16.0,
        ));

        expect(output, hasLength(1));
        expect(output.single, [
          0x1b,
          0x5b,
          0x4d,
          ' '.codeUnitAt(0),
          '!'.codeUnitAt(0) + 1,
          '!'.codeUnitAt(0) + 1,
        ]);
      });
    });

    group('mouseTracking', () {
      test('reflects mode changes', () {
        expect(binding.mouseTracking, MouseTracking.none);

        writeUtf8(controller.terminal, '\x1b[?1000h');

        expect(binding.mouseTracking, MouseTracking.normal);
      });
    });

    group('cursorBlinks', () {
      test('false without focus', () {
        expect(binding.cursorBlinks, isFalse);
      });

      test('stays false without a widget focus context', () {
        final focusNode = FocusNode();
        final sc = ScrollController();
        addTearDown(focusNode.dispose);
        addTearDown(sc.dispose);
        binding.attach(focusNode, sc);

        expect(binding.cursorBlinks, isFalse);
      });
    });

    group('paste', () {
      test('scrolls to bottom on primary screen', () {
        final custom = TerminalControllerImpl(
          config: const TerminalConfig(cols: 20, rows: 3),
        );
        addTearDown(custom.dispose);

        writeNumberedLines(custom, 10);
        custom.terminal.scrollViewport(-5);
        expect(
          custom.terminal.scrollbar.offset,
          lessThan(custom.scrollbackRows),
        );

        custom.onOutput = (_) {};
        custom.paste('hello');

        expect(custom.terminal.scrollbar.offset, custom.scrollbackRows);
      });
    });

    group('primary screen restore', () {
      test('re-applies configured modes', () {
        final focusNode = FocusNode();
        final sc = ScrollController();
        addTearDown(focusNode.dispose);
        addTearDown(sc.dispose);
        binding.attach(focusNode, sc);

        writeUtf8(controller.terminal, '\x1b[?1049h');
        writeUtf8(controller.terminal, '\x1b[?12l');

        writeUtf8(controller.terminal, '\x1b[?1049l');

        expect(
          controller.terminal.modeGet(const TerminalMode.cursorBlinking()),
          isTrue,
        );
      });
    });
  });
}
