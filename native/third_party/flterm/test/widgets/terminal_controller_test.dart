@Tags(['ffi'])
library;

import 'dart:convert';

import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/widgets/terminal_controller_impl.dart';
import 'package:flterm/src/widgets/terminal_view_binding.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart' hide KeyEvent;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TerminalController', () {
    late TerminalControllerImpl controller;

    setUp(() {
      controller = TerminalControllerImpl();
    });

    tearDown(() => controller.dispose());

    void replaceController(TerminalConfig config) {
      controller.dispose();
      controller = TerminalControllerImpl(config: config);
    }

    void writeControllerUtf8(TerminalControllerImpl controller, String text) {
      controller.write(Uint8List.fromList(utf8.encode(text)));
    }

    void writeTerminalUtf8(Terminal terminal, String text) {
      terminal.write(Uint8List.fromList(utf8.encode(text)));
    }

    group('constructor', () {
      test('returns a TerminalViewBinding', () {
        expect(controller, isA<TerminalViewBinding>());
      });

      test('starts without selection, selected text, or focus', () {
        expect(controller.selection, isNull);
        expect(controller.selectedText(), '');
        expect(controller.hasFocus, isFalse);
      });
    });

    group('sendText', () {
      test('emits UTF-8 bytes via onOutput', () {
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        controller.sendText('hello');

        expect(output, hasLength(1));
        expect(utf8.decode(output.first), 'hello');
      });

      test('does not emit for empty text', () {
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        controller.sendText('');

        expect(output, isEmpty);
      });
    });

    group('sendKey', () {
      test('encodes key output', () {
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        controller.sendKey(Key.a);

        expect(output, hasLength(1));
        expect(utf8.decode(output.first), 'a');
      });

      test('ignores missing output callback', () {
        expect(() => controller.sendKey(Key.a), returnsNormally);
      });
    });

    group('selection', () {
      test('setter notifies listeners', () {
        var notified = false;
        controller.addListener(() => notified = true);

        controller.selection = const TerminalSelection(
          startRow: 0,
          startCol: 0,
          endRow: 0,
          endCol: 5,
        );

        expect(notified, isTrue);
        expect(controller.selection, isNotNull);
      });

      test('setter skips notification when value is unchanged', () {
        const sel = TerminalSelection(
          startRow: 0,
          startCol: 0,
          endRow: 0,
          endCol: 5,
        );
        controller.selection = sel;

        var notified = false;
        controller.addListener(() => notified = true);

        controller.selection = sel;

        expect(notified, isFalse);
      });

      test('clearSelection notifies only when selection was active', () {
        var notifyCount = 0;
        controller.addListener(() => notifyCount++);

        controller.clearSelection();
        expect(notifyCount, 0);

        controller.selection = const TerminalSelection(
          startRow: 0,
          startCol: 0,
          endRow: 0,
          endCol: 5,
        );
        notifyCount = 0;

        controller.clearSelection();
        expect(notifyCount, 1);
        expect(controller.selection, isNull);
      });
    });

    group('selectAll', () {
      test('selects through the last content column', () {
        writeControllerUtf8(controller, 'hello\r\nworld');

        controller.selectAll();

        final sel = controller.selection!;
        expect(sel.startRow, 0);
        expect(sel.startCol, 0);
        expect(sel.endRow, 1);
        expect(sel.endCol, 5);
      });

      test('leaves selection empty on an empty screen', () {
        controller.selectAll();

        expect(controller.selection, isNull);
      });

      test('selects a single content row', () {
        writeControllerUtf8(controller, 'abc');

        controller.selectAll();

        final sel = controller.selection!;
        expect(sel.startRow, 0);
        expect(sel.startCol, 0);
        expect(sel.endRow, 0);
        expect(sel.endCol, 3);
      });
    });

    group('selectedText', () {
      test('returns selected screen text', () {
        replaceController(const TerminalConfig(cols: 20, rows: 5));
        writeControllerUtf8(controller, 'hello world');

        controller.selection = const TerminalSelection(
          startRow: 0,
          startCol: 0,
          endRow: 0,
          endCol: 5,
        );

        expect(controller.selectedText(), 'hello');
      });

      test('uses the requested formatter', () {
        replaceController(const TerminalConfig(cols: 20, rows: 5));
        writeControllerUtf8(controller, '\x1b[31mhi\x1b[0m');

        controller.selection = const TerminalSelection(
          startRow: 0,
          startCol: 0,
          endRow: 0,
          endCol: 2,
        );

        expect(controller.selectedText(), 'hi');
        expect(
          controller.selectedText(format: FormatterFormat.vt),
          contains('hi'),
        );
        expect(
          controller.selectedText(format: FormatterFormat.html),
          contains('<'),
        );
      });

      test('excludes wide-character spacer tails', () {
        replaceController(const TerminalConfig(cols: 20, rows: 5));
        controller.write(Uint8List.fromList(utf8.encode('日本語')));

        controller.selection = const TerminalSelection(
          startRow: 0,
          startCol: 0,
          endRow: 0,
          endCol: 6,
        );
        expect(controller.selectedText(), '日本語');

        controller.selection = const TerminalSelection(
          startRow: 0,
          startCol: 0,
          endRow: 0,
          endCol: 6,
          mode: TerminalSelectionMode.block,
        );
        expect(controller.selectedText(), '日本語');
      });
    });

    group('scrollback selection', () {
      late TerminalControllerImpl smallController;

      setUp(() {
        smallController = TerminalControllerImpl(
          config: const TerminalConfig(cols: 20, rows: 3),
        );
      });

      tearDown(() => smallController.dispose());

      void writeLines(List<String> lines) {
        writeControllerUtf8(smallController, lines.join('\r\n'));
      }

      test('selectAll includes scrollback rows', () {
        writeLines(['aaa', 'bbb', 'ccc', 'ddd', 'eee']);
        final scrollbackLen = smallController.scrollbackRows;
        expect(scrollbackLen, 2);

        smallController.selectAll();

        final sel = smallController.selection!;
        expect(sel.startRow, 0);
        expect(sel.startCol, 0);
        expect(sel.endRow, scrollbackLen + 2);
        expect(sel.endCol, 3);
      });

      test('selectAll with only scrollback content', () {
        writeLines(['aaa', 'bbb', 'ccc', '']);
        final scrollbackLen = smallController.scrollbackRows;
        expect(scrollbackLen, greaterThan(0));

        smallController.selectAll();

        final sel = smallController.selection!;
        expect(sel.startRow, 0);
      });

      test('selectedText handles selection beyond screen bounds', () {
        writeLines(['aaa', 'bbb', 'ccc']);
        smallController.selection = const TerminalSelection(
          startRow: 0,
          startCol: 0,
          endRow: 99,
          endCol: 20,
        );

        expect(() => smallController.selectedText(), returnsNormally);
        expect(smallController.selectedText(), contains('aaa'));
      });

      test('selectedText extracts from scrollback and screen', () {
        writeLines(['aaa', 'bbb', 'ccc', 'ddd', 'eee']);
        final scrollbackLen = smallController.scrollbackRows;
        expect(scrollbackLen, 2);

        smallController.selectAll();

        final text = smallController.selectedText();
        expect(text, contains('aaa'));
        expect(text, contains('bbb'));
        expect(text, contains('ccc'));
        expect(text, contains('ddd'));
        expect(text, contains('eee'));
      });

      test('selectedText joins wrapped lines without newline', () {
        final wrapController = TerminalControllerImpl(
          config: const TerminalConfig(cols: 5, rows: 3),
        );
        addTearDown(wrapController.dispose);
        writeControllerUtf8(wrapController, 'abcdefgh');

        wrapController.selectAll();

        final text = wrapController.selectedText();
        expect(text, 'abcdefgh');
        expect(text, isNot(contains('\n')));
      });

      test('selectedText with wrapped wide characters', () {
        final wrapController = TerminalControllerImpl(
          config: const TerminalConfig(cols: 5, rows: 3),
        );
        addTearDown(wrapController.dispose);
        wrapController.write(Uint8List.fromList(utf8.encode('A日B日C')));
        wrapController.selectAll();

        expect(wrapController.selectedText(), 'A日B日C');
      });

      test('selectedText in block mode inserts newlines between rows', () {
        writeLines(['aaaa', 'bbbb', 'cccc']);
        smallController.selection = const TerminalSelection(
          startRow: 0,
          startCol: 1,
          endRow: 2,
          endCol: 3,
          mode: TerminalSelectionMode.block,
        );

        final text = smallController.selectedText();
        final lines = text.split('\n');
        expect(lines.length, 3);
        expect(lines[0], 'aa');
        expect(lines[1], 'bb');
        expect(lines[2], 'cc');
      });

      test('selectedText with partial scrollback selection', () {
        writeLines(['aaa', 'bbb', 'ccc', 'ddd']);
        expect(smallController.scrollbackRows, 1);

        smallController.selection = const TerminalSelection(
          startRow: 0,
          startCol: 0,
          endRow: 1,
          endCol: 3,
        );

        final text = smallController.selectedText();
        expect(text, contains('aaa'));
        expect(text, contains('bbb'));
        expect(text, isNot(contains('ccc')));
      });
    });

    group('clear', () {
      test('emits form feed', () {
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        controller.clear();

        expect(output, hasLength(1));
        final decoded = utf8.decode(output.first);
        expect(decoded, '\x0c');
      });

      test('writes erase scrollback to terminal', () {
        writeControllerUtf8(controller, 'hello\r\nworld\r\n');

        controller.clear();

        expect(controller.scrollbackRows, 0);
      });

      test('does nothing on alternate screen', () {
        final output = <Uint8List>[];
        controller.onOutput = output.add;
        writeControllerUtf8(controller, '\x1b[?1049h');

        controller.clear();

        expect(output, isEmpty);
      });

      test('clears selection', () {
        controller.selection = const TerminalSelection(
          startRow: 0,
          startCol: 0,
          endRow: 1,
          endCol: 5,
        );

        controller.clear();

        expect(controller.selection, isNull);
      });
    });

    group('paste', () {
      test('sends text via onOutput', () {
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        controller.paste('hello');

        expect(output, hasLength(1));
        expect(utf8.decode(output.first), 'hello');
      });

      test('wraps with bracketed paste escape when mode is active', () {
        controller.terminal.modeSet(
          const TerminalMode.bracketedPaste(),
          value: true,
        );
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        controller.paste('hello');

        expect(output, hasLength(1));
        final decoded = utf8.decode(output.first);
        expect(decoded, contains('\x1b[200~'));
        expect(decoded, contains('hello'));
        expect(decoded, contains('\x1b[201~'));
      });

      test('empty text does not emit', () {
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        controller.paste('');

        expect(output, isEmpty);
      });
    });

    group('config', () {
      Uint8List transmitRedPixel({int id = 42}) {
        return .fromList('\x1b_Gf=24,s=1,v=1,a=t,i=$id;/wAA\x1b\\'.codeUnits);
      }

      test('getter returns initial config', () {
        final custom = TerminalControllerImpl(
          config: const TerminalConfig(cols: 120, rows: 40),
        );
        addTearDown(custom.dispose);

        expect(custom.config.cols, 120);
        expect(custom.config.rows, 40);
      });

      test('setter updates config', () {
        controller.config = const TerminalConfig(cols: 120, rows: 40);
        expect(controller.config.cols, 120);
      });

      test('initial config applies APC size limits', () {
        final custom = TerminalControllerImpl(
          config: const TerminalConfig(
            kittyImageStorageLimit: 1 << 20,
            apcBufferLimit: 1,
          ),
        );
        addTearDown(custom.dispose);

        custom.write(transmitRedPixel(id: 91));

        expect(KittyGraphics.of(custom.terminal)!.image(91), isNull);
      });

      test('setter applies APC buffer limits', () {
        controller.config = const TerminalConfig(apcBufferLimit: 1);

        controller.write(transmitRedPixel(id: 92));

        expect(KittyGraphics.of(controller.terminal)!.image(92), isNull);
      });
    });

    group('modeGet and modeSet', () {
      test('modeSet enables and modeGet reads back', () {
        controller.modeSet(const TerminalMode.autoWrap(), value: false);
        expect(controller.modeGet(const TerminalMode.autoWrap()), isFalse);

        controller.modeSet(const TerminalMode.autoWrap(), value: true);
        expect(controller.modeGet(const TerminalMode.autoWrap()), isTrue);
      });
    });

    group('activeScreen', () {
      test('defaults to primary', () {
        expect(controller.activeScreen, TerminalScreen.primary);
      });

      test('switches to alternate via escape sequence', () {
        writeTerminalUtf8(controller.terminal, '\x1b[?1049h');
        expect(controller.activeScreen, TerminalScreen.alternate);
      });
    });

    group('title', () {
      test('defaults to empty', () {
        expect(controller.title, isEmpty);
      });

      test('updates via OSC 0 escape sequence', () {
        writeTerminalUtf8(controller.terminal, '\x1b]0;my title\x1b\\');
        expect(controller.title, 'my title');
      });

      test('fires onTitleChanged callback', () {
        var fired = false;
        controller.onTitleChanged = () => fired = true;

        writeTerminalUtf8(controller.terminal, '\x1b]0;new title\x1b\\');

        expect(fired, isTrue);
      });
    });

    group('selectWord', () {
      test('selects word at position', () {
        replaceController(const TerminalConfig(cols: 20, rows: 5));
        writeTerminalUtf8(controller.terminal, 'hello world');

        (controller as TerminalViewBinding).selectWord(0, 1);

        final sel = controller.selection!;
        expect(sel.startCol, 0);
        expect(sel.endCol, 5);
      });
    });

    group('selectLine', () {
      test('selects line content at row', () {
        replaceController(const TerminalConfig(cols: 20, rows: 5));
        writeTerminalUtf8(controller.terminal, 'hello world');

        (controller as TerminalViewBinding).selectLine(0, .content);

        final sel = controller.selection!;
        expect(sel.startCol, 0);
        expect(sel.endCol, 11);
      });

      test('selects full row width in full mode', () {
        replaceController(const TerminalConfig(cols: 20, rows: 5));
        writeTerminalUtf8(controller.terminal, 'hello');

        (controller as TerminalViewBinding).selectLine(0, .full);

        final sel = controller.selection!;
        expect(sel.startCol, 0);
        expect(sel.endCol, 20);
      });
    });

    group('dispose', () {
      test('releases resources', () {
        final disposable = TerminalControllerImpl();

        expect(disposable.dispose, returnsNormally);
      });
    });

    group('virtual mods', () {
      test('toggleMod activates, deactivates, and combines modifiers', () {
        expect(controller.virtualMods, const Mods.none());

        controller.toggleMod(const Mods.ctrl());
        expect(controller.virtualMods.hasCtrl, isTrue);

        controller.toggleMod(const Mods.alt());
        expect(controller.virtualMods.hasCtrl, isTrue);
        expect(controller.virtualMods.hasAlt, isTrue);

        controller.toggleMod(const Mods.ctrl());
        expect(controller.virtualMods.hasCtrl, isFalse);
        expect(controller.virtualMods.hasAlt, isTrue);

        controller.toggleMod(const Mods.alt());
        expect(controller.virtualMods, const Mods.none());
      });

      test('toggleMod notifies listeners', () {
        var notified = false;
        controller.addListener(() => notified = true);

        controller.toggleMod(const Mods.ctrl());

        expect(notified, isTrue);
      });

      test('clearVirtualMods notifies only when mods were active', () {
        var notifyCount = 0;
        controller.addListener(() => notifyCount++);

        controller.clearVirtualMods();
        expect(notifyCount, 0);

        controller.toggleMod(const Mods.ctrl());
        notifyCount = 0;

        controller.clearVirtualMods();
        expect(notifyCount, 1);
        expect(controller.virtualMods, const Mods.none());
      });

      test('sendKey merges virtual mods', () {
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        controller.toggleMod(const Mods.ctrl());
        controller.sendKey(Key.c);

        expect(output, hasLength(1));
        expect(output.first, equals(utf8.encode('\x03')));
      });

      test('sendKey clears virtual mods after encoding', () {
        controller.onOutput = (_) {};

        controller.toggleMod(const Mods.ctrl());
        controller.sendKey(Key.a);

        expect(controller.virtualMods, const Mods.none());
      });

      test('sendKey merges explicit and virtual mods', () {
        final output = <Uint8List>[];
        controller.onOutput = output.add;

        controller.toggleMod(const Mods.ctrl());
        controller.sendKey(Key.c, mods: const Mods.shift());

        expect(output, hasLength(1));
        expect(controller.virtualMods, const Mods.none());
      });

      test('sendText clears virtual mods', () {
        controller.onOutput = (_) {};

        controller.toggleMod(const Mods.ctrl());
        controller.sendText('hello');

        expect(controller.virtualMods, const Mods.none());
      });

      test('sendText does not clear when text is empty', () {
        controller.toggleMod(const Mods.ctrl());
        controller.sendText('');

        expect(controller.virtualMods.hasCtrl, isTrue);
      });
    });
  });
}
