@Tags(['ffi'])
library;

import 'dart:convert';

import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart' show Terminal;

void main() {
  group('TerminalShortcutScope', () {
    late TerminalControllerImpl controller;

    setUp(() {
      controller = TerminalControllerImpl();
    });

    tearDown(() => controller.dispose());

    void writeUtf8(Terminal terminal, String text) {
      terminal.write(Uint8List.fromList(utf8.encode(text)));
    }

    Widget buildScope(
      Map<ShortcutActivator, Intent> shortcuts, {
      VoidCallback? onPaste,
      bool enableSelectAll = true,
    }) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: TerminalShortcutScope(
          controller: controller,
          shortcuts: shortcuts,
          onPaste: onPaste,
          enableSelectAll: enableSelectAll,
          child: const Focus(autofocus: true, child: SizedBox()),
        ),
      );
    }

    Map<ShortcutActivator, Intent> macShortcuts() {
      return const {
        SingleActivator(.keyC, meta: true): CopyIntent(),
        SingleActivator(.keyV, meta: true): PasteIntent(),
        SingleActivator(.keyA, meta: true): SelectAllIntent(),
        SingleActivator(.keyK, meta: true): ClearIntent(),
      };
    }

    Future<void> sendCmd(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(.meta);
      await tester.sendKeyDownEvent(key);
      await tester.sendKeyUpEvent(key);
      await tester.sendKeyUpEvent(.meta);
    }

    group('copy', () {
      testWidgets('copies selected text to clipboard', (tester) async {
        writeUtf8(controller.terminal, 'hello world');
        controller.selection = const TerminalSelection(
          startRow: 0,
          startCol: 0,
          endRow: 0,
          endCol: 5,
        );

        String? clipboardText;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboardText = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(() {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          );
        });

        await tester.pumpWidget(buildScope(macShortcuts()));
        await tester.pumpAndSettle();

        await sendCmd(tester, .keyC);
        await tester.pump();

        expect(clipboardText, 'hello');
      });

      testWidgets('leaves clipboard unchanged without selection', (
        tester,
      ) async {
        String? clipboardText;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboardText = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(() {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          );
        });

        await tester.pumpWidget(buildScope(macShortcuts()));
        await tester.pumpAndSettle();

        await sendCmd(tester, .keyC);

        expect(clipboardText, isNull);
      });
    });

    group('paste', () {
      testWidgets('invokes onPaste', (tester) async {
        var pasted = false;

        await tester.pumpWidget(
          buildScope(macShortcuts(), onPaste: () => pasted = true),
        );
        await tester.pumpAndSettle();

        await sendCmd(tester, .keyV);

        expect(pasted, isTrue);
      });
    });

    group('selectAll', () {
      testWidgets('selects all terminal content', (tester) async {
        writeUtf8(controller.terminal, 'hello');

        await tester.pumpWidget(buildScope(macShortcuts()));
        await tester.pumpAndSettle();

        await sendCmd(tester, .keyA);

        expect(controller.selection, isNotNull);
        expect(controller.selectedText(), 'hello');
      });

      testWidgets('leaves selection empty when disabled', (tester) async {
        writeUtf8(controller.terminal, 'hello');

        await tester.pumpWidget(
          buildScope(macShortcuts(), enableSelectAll: false),
        );
        await tester.pumpAndSettle();

        await sendCmd(tester, .keyA);

        expect(controller.selection, isNull);
      });
    });

    group('clear', () {
      testWidgets('emits form feed output', (tester) async {
        writeUtf8(controller.terminal, 'hello\r\nworld\r\n');
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        await tester.pumpWidget(buildScope(macShortcuts()));
        await tester.pumpAndSettle();

        await sendCmd(tester, .keyK);

        expect(output.any((bytes) => utf8.decode(bytes) == '\x0c'), isTrue);
      });
    });

    group('custom shortcuts', () {
      testWidgets('invoke custom bindings', (tester) async {
        var pasted = false;

        await tester.pumpWidget(
          buildScope(const {
            SingleActivator(.keyP, control: true): PasteIntent(),
          }, onPaste: () => pasted = true),
        );
        await tester.pumpAndSettle();

        await tester.sendKeyDownEvent(.control);
        await tester.sendKeyDownEvent(.keyP);
        await tester.sendKeyUpEvent(.keyP);
        await tester.sendKeyUpEvent(.control);

        expect(pasted, isTrue);
      });
    });
  });

  group('TerminalShortcuts', () {
    group('defaultsFor', () {
      void expectShortcutSet(
        Map<ShortcutActivator, Intent> shortcuts, {
        required ShortcutActivator copy,
        required ShortcutActivator paste,
        required ShortcutActivator selectAll,
        required ShortcutActivator clear,
      }) {
        expect(shortcuts[copy], isA<CopyIntent>());
        expect(shortcuts[paste], isA<PasteIntent>());
        expect(shortcuts[selectAll], isA<SelectAllIntent>());
        expect(shortcuts[clear], isA<ClearIntent>());
      }

      test('uses command shortcuts on Apple platforms', () {
        expectShortcutSet(
          TerminalShortcuts.defaultsFor(TargetPlatform.macOS),
          copy: const SingleActivator(.keyC, meta: true),
          paste: const SingleActivator(.keyV, meta: true),
          selectAll: const SingleActivator(.keyA, meta: true),
          clear: const SingleActivator(.keyK, meta: true),
        );
        expectShortcutSet(
          TerminalShortcuts.defaultsFor(TargetPlatform.iOS),
          copy: const SingleActivator(.keyC, meta: true),
          paste: const SingleActivator(.keyV, meta: true),
          selectAll: const SingleActivator(.keyA, meta: true),
          clear: const SingleActivator(.keyK, meta: true),
        );
      });

      test('uses control-shift shortcuts on Linux', () {
        expectShortcutSet(
          TerminalShortcuts.defaultsFor(TargetPlatform.linux),
          copy: const SingleActivator(.keyC, control: true, shift: true),
          paste: const SingleActivator(.keyV, control: true, shift: true),
          selectAll: const SingleActivator(.keyA, control: true, shift: true),
          clear: const SingleActivator(.keyK, control: true, shift: true),
        );
      });

      test('uses control shortcuts on Windows and Android', () {
        expectShortcutSet(
          TerminalShortcuts.defaultsFor(TargetPlatform.windows),
          copy: const SingleActivator(.keyC, control: true),
          paste: const SingleActivator(.keyV, control: true),
          selectAll: const SingleActivator(.keyA, control: true),
          clear: const SingleActivator(.keyK, control: true),
        );
        expectShortcutSet(
          TerminalShortcuts.defaultsFor(TargetPlatform.android),
          copy: const SingleActivator(.keyC, control: true),
          paste: const SingleActivator(.keyV, control: true),
          selectAll: const SingleActivator(.keyA, control: true),
          clear: const SingleActivator(.keyK, control: true),
        );
      });
    });
  });
}
