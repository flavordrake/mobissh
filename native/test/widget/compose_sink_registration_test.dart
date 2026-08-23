// Compose-sink plumbing (#1131): the keybar can only route characters into the
// IME preview if the mounted bar actually PUBLISHES its buffer handle. The
// routing DECISION is covered purely in keybar_compose_routing_test.dart; this
// covers the wiring — registration on mount, insert-at-caret semantics, submit,
// and retraction on dismissal (a stale sink would swallow keys into a bar that
// is no longer on screen).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/compose_sink_provider.dart';
import 'package:mobissh/ui/compose_bar.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpBar(
    WidgetTester tester,
    ProviderContainer c,
    List<String> out, {
    bool visible = true,
  }) async {
    final terminal = Terminal();
    terminal.onOutput = out.add;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                if (visible)
                  ComposeBar(
                    terminal: terminal,
                    sessionId: 'sess',
                    onClose: () {},
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    // Registration/retraction is deferred by a microtask (mount happens during
    // the rebuild that toggled visibility), so settle before asserting.
    await tester.pumpAndSettle();
  }

  testWidgets('a mounted bar publishes a sink; dismissal retracts it',
      (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final out = <String>[];

    await pumpBar(tester, c, out);
    expect(c.read(composeSinkProvider), isNotNull,
        reason: 'mount == the IME preview is up');

    await pumpBar(tester, c, out, visible: false);
    expect(c.read(composeSinkProvider), isNull,
        reason: 'a stale sink would swallow keys into an off-screen bar');
  });

  testWidgets('insertText lands at the caret and sends NOTHING to the terminal',
      (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final out = <String>[];
    await pumpBar(tester, c, out);

    final field = find.byType(TextField);
    await tester.enterText(field, 'ls path');
    await tester.pump();

    // Caret mid-buffer (after "ls"), then the keybar inserts '/'.
    final state = tester.widget<TextField>(field).controller!;
    state.selection = const TextSelection.collapsed(offset: 2);
    c.read(composeSinkProvider)!.insertText('/');
    await tester.pump();

    expect(state.text, 'ls/ path');
    expect(state.selection.baseOffset, 3, reason: 'caret parks after the insert');
    expect(out, isEmpty,
        reason: 'a character key must never reach the terminal while composing');
  });

  testWidgets('submit sends the staged text + CR, like the ⏎ action',
      (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final out = <String>[];
    await pumpBar(tester, c, out);

    await tester.enterText(find.byType(TextField), 'uptime');
    await tester.pump();
    c.read(composeSinkProvider)!.submit();
    await tester.pump();

    expect(out.join(), 'uptime\r');
  });

  testWidgets('hasText reflects the buffer', (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await pumpBar(tester, c, <String>[]);

    expect(c.read(composeSinkProvider)!.hasText(), isFalse);
    await tester.enterText(find.byType(TextField), 'x');
    await tester.pump();
    expect(c.read(composeSinkProvider)!.hasText(), isTrue);
  });
}
