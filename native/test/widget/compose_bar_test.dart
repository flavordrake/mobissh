// Compose-bar (IME / swipe / voice surface) commit semantics (#599).
//
// The byte-level contract — the thing that matters for the owner's swipe+voice
// goal — is what the bar SENDS to the terminal:
//   - Commit (✓): the composed text only, NO trailing Enter.
//   - Submit (⏎): the text THEN a carriage return.
//   - Multi-line text is bracketed-paste wrapped (\x1b[200~ … \x1b[201~) so the
//     remote treats it as one paste, not N Enters.
//   - The field clears after send (ready for the next phrase).
// We capture `terminal.onOutput` (the exact pipe the keybar + IME use →
// proxy.sendInput → PTY) and assert the bytes.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/compose_bar.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Terminal> pumpBar(WidgetTester tester, List<String> sink) async {
    final terminal = Terminal();
    terminal.onOutput = sink.add;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ComposeBar(terminal: terminal)),
      ),
    );
    await tester.pump();
    return terminal;
  }

  testWidgets('commit (✓) sends text only — no Enter', (tester) async {
    final sink = <String>[];
    await pumpBar(tester, sink);

    await tester.enterText(
      find.byKey(const Key('compose-bar-input')),
      'ls -la',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('compose-bar-commit')));
    await tester.pump();

    expect(sink.join(), 'ls -la');
    expect(sink.join().contains('\r'), isFalse);
    // Field cleared after send.
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('compose-bar-input')))
          .controller
          ?.text,
      isEmpty,
    );
  });

  testWidgets('submit (⏎) sends text then carriage return', (tester) async {
    final sink = <String>[];
    await pumpBar(tester, sink);

    await tester.enterText(
      find.byKey(const Key('compose-bar-input')),
      'echo hi',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('compose-bar-submit')));
    await tester.pump();

    expect(sink.join(), 'echo hi\r');
  });

  testWidgets('swipe-typed words with SPACES land intact', (tester) async {
    // Simulates the owner's case: a multi-word phrase (as swipe/voice deliver
    // it) committed in one go — spaces must survive.
    final sink = <String>[];
    await pumpBar(tester, sink);

    await tester.enterText(
      find.byKey(const Key('compose-bar-input')),
      'the quick brown fox',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('compose-bar-commit')));
    await tester.pump();

    expect(sink.join(), 'the quick brown fox');
  });

  testWidgets('multi-line commit is bracketed-paste wrapped', (tester) async {
    final sink = <String>[];
    await pumpBar(tester, sink);

    await tester.enterText(
      find.byKey(const Key('compose-bar-input')),
      'line1\nline2',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('compose-bar-commit')));
    await tester.pump();

    expect(sink.join(), '\x1b[200~line1\nline2\x1b[201~');
  });

  testWidgets('submit with empty field still sends Enter', (tester) async {
    final sink = <String>[];
    await pumpBar(tester, sink);

    await tester.tap(find.byKey(const Key('compose-bar-submit')));
    await tester.pump();

    expect(sink.join(), '\r');
  });
}
