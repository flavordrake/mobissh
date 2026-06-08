// Compose-bar (IME / swipe / voice surface) semantics (#599, #614, #633, #638).
//
// The byte-level contract — the thing that matters for the owner's swipe+voice
// goal — is what the bar SENDS to the terminal:
//   - Commit (✓): the composed text only, NO trailing Enter.
//   - Submit (⏎): the text THEN a carriage return.
//   - Multi-line text is bracketed-paste wrapped (\x1b[200~ … \x1b[201~) so the
//     remote treats it as one paste, not N Enters.
// #614: BOTH commit AND submit now HIDE the panel (onClose) so the full terminal
//   is readable after composing (owner reversal of the original #614 plan).
// #638 (corrects #634): drag thumb at the TOP edge; Copy/Paste/Fix are inline
//   text-action PILLS — the right rail holds only whole-view actions.
// #633: best-effort — preview field re-focuses on app resume if it was focused
//   at pause (true app-swap focus is device-only).
// We capture `terminal.onOutput` (the exact pipe the keybar + IME use →
// proxy.sendInput → PTY) and assert the bytes.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/compose_history_providers.dart';
import 'package:mobissh/state/lifecycle_providers.dart';
import 'package:mobissh/ui/compose_bar.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ComposeBar is a ConsumerStatefulWidget (it listens to lifecycleProvider for
  // #633), so it must be pumped inside a ProviderScope. Returns the container so
  // tests can drive the lifecycle provider for #633.
  Future<ProviderContainer> pumpBar(
    WidgetTester tester,
    List<String> sink, {
    VoidCallback? onClose,
    String sessionId = 'sess',
    ProviderContainer? container,
  }) async {
    final terminal = Terminal();
    terminal.onOutput = sink.add;
    final c = container ?? ProviderContainer();
    if (container == null) addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(
            // ComposeBar is a floating panel (returns a Positioned), so it must
            // live inside a Stack (#604).
            body: Stack(
              children: [
                ComposeBar(
                  terminal: terminal,
                  sessionId: sessionId,
                  onClose: onClose ?? () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return c;
  }

  group('byte contract', () {
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
  });

  group('#614 — both commit and submit hide the panel', () {
    testWidgets('commit (✓) hides the panel via onClose', (tester) async {
      final sink = <String>[];
      var closed = 0;
      await pumpBar(tester, sink, onClose: () => closed++);

      await tester.enterText(
        find.byKey(const Key('compose-bar-input')),
        'ls -la',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('compose-bar-commit')));
      await tester.pump();

      expect(closed, 1, reason: 'commit must hide the panel (#614 reversal)');
    });

    testWidgets('submit (⏎) hides the panel via onClose', (tester) async {
      final sink = <String>[];
      var closed = 0;
      await pumpBar(tester, sink, onClose: () => closed++);

      await tester.enterText(
        find.byKey(const Key('compose-bar-input')),
        'echo hi',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('compose-bar-submit')));
      await tester.pump();

      expect(closed, 1, reason: 'submit must hide the panel');
    });

    testWidgets('multi-line commit also hides the panel', (tester) async {
      final sink = <String>[];
      var closed = 0;
      await pumpBar(tester, sink, onClose: () => closed++);

      await tester.enterText(
        find.byKey(const Key('compose-bar-input')),
        'line1\nline2',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('compose-bar-commit')));
      await tester.pump();

      expect(closed, 1);
    });

    testWidgets('empty commit does NOT close (nothing to send)', (
      tester,
    ) async {
      final sink = <String>[];
      var closed = 0;
      await pumpBar(tester, sink, onClose: () => closed++);

      // Commit is disabled when empty, so tapping does nothing; but if it were
      // invoked, no send + no close.
      await tester.tap(find.byKey(const Key('compose-bar-commit')));
      await tester.pump();

      expect(closed, 0);
      expect(sink, isEmpty);
    });
  });

  group('#638 — copy/paste/fix are inline pills, NOT in the right rail', () {
    testWidgets('drag thumb renders at the top edge (above the field)', (
      tester,
    ) async {
      await pumpBar(tester, <String>[]);

      final grip = find.byKey(const Key('compose-bar-drag'));
      final field = find.byKey(const Key('compose-bar-input'));
      expect(grip, findsOneWidget);
      expect(field, findsOneWidget);

      final gripBox = tester.getRect(grip);
      final fieldBox = tester.getRect(field);
      expect(
        gripBox.center.dy < fieldBox.top,
        isTrue,
        reason: 'grip must sit above the text field (top dock thumb)',
      );
    });

    testWidgets(
      'right rail keeps ONLY whole-view actions (no copy/paste/fix)',
      (tester) async {
        await pumpBar(tester, <String>[]);

        // The rail must still carry the whole-view actions.
        expect(find.byKey(const Key('compose-bar-close')), findsOneWidget);
        expect(find.byKey(const Key('compose-bar-clear')), findsOneWidget);
        expect(find.byKey(const Key('compose-bar-commit')), findsOneWidget);
        expect(find.byKey(const Key('compose-bar-submit')), findsOneWidget);

        // The text actions must NOT live inside the rail any more — they belong
        // to the pill row. Assert no rail descendant owns those keys.
        expect(
          find.descendant(
            of: find.byKey(const Key('compose-bar-rail')),
            matching: find.byKey(const Key('compose-bar-copy')),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('compose-bar-rail')),
            matching: find.byKey(const Key('compose-bar-paste')),
          ),
          findsNothing,
        );
      },
    );

    testWidgets('inline pill row carries Copy, Paste and Fix', (tester) async {
      await pumpBar(tester, <String>[]);

      final pillRow = find.byKey(const Key('compose-bar-pills'));
      expect(pillRow, findsOneWidget);

      expect(
        find.descendant(
          of: pillRow,
          matching: find.byKey(const Key('compose-bar-copy')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: pillRow,
          matching: find.byKey(const Key('compose-bar-paste')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: pillRow,
          matching: find.byKey(const Key('compose-bar-fix')),
        ),
        findsOneWidget,
      );
    });

    testWidgets('Fix pill collapses terminal soft-wrap into one clean line', (
      tester,
    ) async {
      await pumpBar(tester, <String>[]);

      final controller = tester
          .widget<TextField>(find.byKey(const Key('compose-bar-input')))
          .controller!;
      // A URL hard-wrapped by the terminal (newline + indent mid-token).
      controller.text = 'https://example.com/long/\n    path?q=1';
      await tester.pump();

      await tester.tap(find.byKey(const Key('compose-bar-fix')));
      await tester.pump();

      expect(controller.text, 'https://example.com/long/path?q=1');
    });

    testWidgets('Copy pill copies the current compose text to the clipboard', (
      tester,
    ) async {
      String? clipboardText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText = (call.arguments as Map)['text'] as String?;
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

      await pumpBar(tester, <String>[]);
      await tester.enterText(
        find.byKey(const Key('compose-bar-input')),
        'hello world',
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('compose-bar-copy')));
      await tester.pump();

      expect(clipboardText, 'hello world');
    });

    testWidgets('Paste pill inserts clipboard text at the cursor', (
      tester,
    ) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            return <String, dynamic>{'text': 'PASTED'};
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

      await pumpBar(tester, <String>[]);
      await tester.enterText(
        find.byKey(const Key('compose-bar-input')),
        'abXY',
      );
      await tester.pump();

      // Place cursor between "ab" and "XY".
      final controller = tester
          .widget<TextField>(find.byKey(const Key('compose-bar-input')))
          .controller!;
      controller.selection = const TextSelection.collapsed(offset: 2);
      await tester.pump();

      await tester.tap(find.byKey(const Key('compose-bar-paste')));
      await tester.pumpAndSettle();

      expect(controller.text, 'abPASTEDXY');
    });
  });

  group('#633 — re-focus on resume (best-effort; real swap is device-only)', () {
    testWidgets('field regains focus on resume when it was focused at pause', (
      tester,
    ) async {
      final container = await pumpBar(tester, <String>[]);

      // Field auto-focuses on open. Confirm.
      final focusNode = tester
          .widget<TextField>(find.byKey(const Key('compose-bar-input')))
          .focusNode!;
      expect(focusNode.hasFocus, isTrue);

      // Simulate background: provider goes paused. The bar records hasFocus.
      container.read(lifecycleProvider.notifier).state =
          AppLifecycleState.paused;
      await tester.pump();
      // Drop focus while paused (as the OS would).
      focusNode.unfocus();
      await tester.pump();
      expect(focusNode.hasFocus, isFalse);

      // Resume: the bar must re-request focus (it was focused at pause).
      container.read(lifecycleProvider.notifier).state =
          AppLifecycleState.resumed;
      await tester.pump();
      await tester.pump(); // post-frame callback

      expect(
        focusNode.hasFocus,
        isTrue,
        reason: 'must re-focus on resume when focused at pause (#633)',
      );
    });

    testWidgets('field does NOT grab focus on resume if it was not focused', (
      tester,
    ) async {
      final container = await pumpBar(tester, <String>[]);

      final focusNode = tester
          .widget<TextField>(find.byKey(const Key('compose-bar-input')))
          .focusNode!;
      // Drop focus BEFORE pause so it is unfocused at pause time.
      focusNode.unfocus();
      await tester.pump();
      expect(focusNode.hasFocus, isFalse);

      container.read(lifecycleProvider.notifier).state =
          AppLifecycleState.paused;
      await tester.pump();

      container.read(lifecycleProvider.notifier).state =
          AppLifecycleState.resumed;
      await tester.pump();
      await tester.pump();

      expect(
        focusNode.hasFocus,
        isFalse,
        reason: 'no re-focus when it was not focused at pause (#633)',
      );
    });
  });

  group('#797 — IME compose history ring + ▲/▼ recall (PWA parity)', () {
    // Reads the live controller text out of the compose field.
    String controllerText(WidgetTester tester) => tester
        .widget<TextField>(find.byKey(const Key('compose-bar-input')))
        .controller!
        .text;

    testWidgets('▲/▼ recall buttons exist in the rail', (tester) async {
      await pumpBar(tester, <String>[]);
      expect(find.byKey(const Key('compose-bar-history-up')), findsOneWidget);
      expect(find.byKey(const Key('compose-bar-history-down')), findsOneWidget);
    });

    testWidgets('▲/▼ are disabled when history is empty', (tester) async {
      await pumpBar(tester, <String>[]);
      final up = tester.widget<IconButton>(
        find.byKey(const Key('compose-bar-history-up')),
      );
      final down = tester.widget<IconButton>(
        find.byKey(const Key('compose-bar-history-down')),
      );
      expect(up.onPressed, isNull, reason: '▲ disabled with no history');
      expect(down.onPressed, isNull, reason: '▼ disabled with no history');
    });

    testWidgets(
      'committing a command pushes it to the per-session history',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        await pumpBar(tester, <String>[], container: container);

        await tester.enterText(
          find.byKey(const Key('compose-bar-input')),
          'ls -la',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('compose-bar-commit')));
        await tester.pump();

        expect(
          container.read(composeHistoryProvider.notifier).historyOf('sess'),
          ['ls -la'],
        );
      },
    );

    testWidgets(
      'send A,B,C → ▲ recalls C, ▲ again B, ▼ returns to C (PWA cycle)',
      (tester) async {
        // A single shared container so history survives the bar across sends
        // (the bar would normally close+reopen; here onClose is a no-op so the
        // same State persists, but the durable list lives in the provider).
        final container = ProviderContainer();
        addTearDown(container.dispose);
        await pumpBar(tester, <String>[], container: container);

        for (final cmd in ['A', 'B', 'C']) {
          await tester.enterText(
            find.byKey(const Key('compose-bar-input')),
            cmd,
          );
          await tester.pump();
          await tester.tap(find.byKey(const Key('compose-bar-commit')));
          await tester.pump();
        }
        // After commits the field is cleared.
        expect(controllerText(tester), '');

        // ▲ recalls the newest (C).
        await tester.tap(find.byKey(const Key('compose-bar-history-up')));
        await tester.pump();
        expect(controllerText(tester), 'C');

        // ▲ again → older (B).
        await tester.tap(find.byKey(const Key('compose-bar-history-up')));
        await tester.pump();
        expect(controllerText(tester), 'B');

        // ▼ → back toward newer (C).
        await tester.tap(find.byKey(const Key('compose-bar-history-down')));
        await tester.pump();
        expect(controllerText(tester), 'C');
      },
    );

    testWidgets('recall populates the buffer WITHOUT sending', (tester) async {
      final sink = <String>[];
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await pumpBar(tester, sink, container: container);

      // Seed history directly (a prior session/compose), then clear the sink so
      // we measure only what recall sends.
      container.read(composeHistoryProvider.notifier).push('sess', 'echo hi');
      await tester.pump();
      sink.clear();

      await tester.tap(find.byKey(const Key('compose-bar-history-up')));
      await tester.pump();

      expect(controllerText(tester), 'echo hi');
      expect(sink, isEmpty, reason: 'recall must NOT send to the terminal');
    });

    testWidgets(
      '▼ past the newest restores the stashed unsent input (PWA stash)',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        await pumpBar(tester, <String>[], container: container);

        container.read(composeHistoryProvider.notifier).push('sess', 'old');
        await tester.pump();

        // Type unsent text, then browse up into history (stashes the draft).
        await tester.enterText(
          find.byKey(const Key('compose-bar-input')),
          'draft',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('compose-bar-history-up')));
        await tester.pump();
        expect(controllerText(tester), 'old');

        // ▼ past the newest → the stashed draft comes back (not clobbered).
        await tester.tap(find.byKey(const Key('compose-bar-history-down')));
        await tester.pump();
        expect(controllerText(tester), 'draft');
      },
    );
  });
}
