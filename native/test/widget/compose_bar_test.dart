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
import 'package:mobissh/state/ui_prefs_providers.dart';
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
        // to the header pill row. Assert no rail descendant owns those keys.
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
        expect(
          find.descendant(
            of: find.byKey(const Key('compose-bar-rail')),
            matching: find.byKey(const Key('compose-bar-fix')),
          ),
          findsNothing,
        );
      },
    );

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

  group('#842 — retain in-progress text on dismissal (no silent loss)', () {
    // Mounts the bar under a session-keyed visibility toggle, mirroring
    // terminal_screen (the bar is keyed by session id and only present when
    // `composeBarVisibleProvider` is true). Removing it from the tree — exactly
    // what X tap / IME toggle-off / programmatic close do — disposes the State,
    // which is the universal capture-before-clear point.
    Future<void> pumpToggleable(
      WidgetTester tester,
      ProviderContainer container, {
      String sessionId = 'sess',
    }) async {
      final terminal = Terminal();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  Consumer(
                    builder: (context, ref, _) {
                      final visible = ref.watch(composeBarVisibleProvider);
                      if (!visible) return const SizedBox.shrink();
                      return ComposeBar(
                        key: ValueKey('compose-bar-$sessionId'),
                        terminal: terminal,
                        sessionId: sessionId,
                        onClose: () => ref
                            .read(composeBarVisibleProvider.notifier)
                            .set(false),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    String controllerText(WidgetTester tester) => tester
        .widget<TextField>(find.byKey(const Key('compose-bar-input')))
        .controller!
        .text;

    testWidgets('X tap with non-empty text pushes it to the history ring', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(composeBarVisibleProvider.notifier).set(true);
      await pumpToggleable(tester, container);

      await tester.enterText(
        find.byKey(const Key('compose-bar-input')),
        'the quick brown fox',
      );
      await tester.pump();

      // Tap X — hides the bar, which disposes the State.
      await tester.tap(find.byKey(const Key('compose-bar-close')));
      await tester.pumpAndSettle();

      expect(
        container.read(composeHistoryProvider.notifier).historyOf('sess'),
        ['the quick brown fox'],
        reason: 'X-dismissed text must land in the history ring (#842 floor)',
      );
    });

    testWidgets('dismissing with EMPTY text is a no-op (no blank entry)', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(composeBarVisibleProvider.notifier).set(true);
      await pumpToggleable(tester, container);

      // Nothing typed.
      await tester.tap(find.byKey(const Key('compose-bar-close')));
      await tester.pumpAndSettle();

      expect(
        container.read(composeHistoryProvider.notifier).historyOf('sess'),
        isEmpty,
        reason: 'empty dismissal must not pollute the ring',
      );
      expect(
        container.read(composeDraftProvider.notifier).draftOf('sess'),
        isNull,
      );
    });

    testWidgets('whitespace-only text on dismissal is a no-op', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(composeBarVisibleProvider.notifier).set(true);
      await pumpToggleable(tester, container);

      await tester.enterText(
        find.byKey(const Key('compose-bar-input')),
        '   \n  ',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('compose-bar-close')));
      await tester.pumpAndSettle();

      expect(
        container.read(composeHistoryProvider.notifier).historyOf('sess'),
        isEmpty,
      );
    });

    testWidgets('IME toggle-off (provider set false) captures before clear', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(composeBarVisibleProvider.notifier).set(true);
      await pumpToggleable(tester, container);

      await tester.enterText(
        find.byKey(const Key('compose-bar-input')),
        'half typed command',
      );
      await tester.pump();

      // Toggle the IME off WITHOUT touching the X — same as the session-bar
      // compose toggle (terminal_screen's onToggleCompose → toggle()).
      container.read(composeBarVisibleProvider.notifier).set(false);
      await tester.pumpAndSettle();

      expect(
        container.read(composeHistoryProvider.notifier).historyOf('sess'),
        ['half typed command'],
        reason: 'toggle-off must also capture before clear (#842)',
      );
    });

    testWidgets('a JUST-SENT command is not double-recorded on close', (
      tester,
    ) async {
      // Send (commit) clears the controller AND closes the bar in one shot, so
      // the dispose-time capture sees an empty buffer. The ring must hold the
      // sent command exactly once (no duplicate from the dispose path).
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(composeBarVisibleProvider.notifier).set(true);
      await pumpToggleable(tester, container);

      await tester.enterText(
        find.byKey(const Key('compose-bar-input')),
        'ls -la',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('compose-bar-commit')));
      await tester.pumpAndSettle();

      expect(
        container.read(composeHistoryProvider.notifier).historyOf('sess'),
        ['ls -la'],
        reason: 'sent command recorded once, not duplicated by close-capture',
      );
    });

    testWidgets('reopening the IME restores the dismissed draft (ideal)', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(composeBarVisibleProvider.notifier).set(true);
      await pumpToggleable(tester, container);

      await tester.enterText(
        find.byKey(const Key('compose-bar-input')),
        'restore me exactly',
      );
      await tester.pump();

      // Dismiss (X) then reopen.
      await tester.tap(find.byKey(const Key('compose-bar-close')));
      await tester.pumpAndSettle();
      container.read(composeBarVisibleProvider.notifier).set(true);
      await tester.pumpAndSettle();

      expect(
        controllerText(tester),
        'restore me exactly',
        reason: 'reopen must repopulate the field from the stashed draft (#842)',
      );
    });

    testWidgets('a sent command does NOT come back as a draft on reopen', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(composeBarVisibleProvider.notifier).set(true);
      await pumpToggleable(tester, container);

      await tester.enterText(
        find.byKey(const Key('compose-bar-input')),
        'echo done',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('compose-bar-commit')));
      await tester.pumpAndSettle();

      // Reopen — the sent text must NOT be restored (it was sent, not abandoned).
      container.read(composeBarVisibleProvider.notifier).set(true);
      await tester.pumpAndSettle();

      expect(controllerText(tester), '');
    });

    testWidgets('explicit Clear discards the draft (no restore on reopen)', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(composeBarVisibleProvider.notifier).set(true);
      await pumpToggleable(tester, container);

      await tester.enterText(
        find.byKey(const Key('compose-bar-input')),
        'discard this',
      );
      await tester.pump();
      // Backspace/clear button is a deliberate discard.
      await tester.tap(find.byKey(const Key('compose-bar-clear')));
      await tester.pump();
      // Now dismiss with the field empty.
      await tester.tap(find.byKey(const Key('compose-bar-close')));
      await tester.pumpAndSettle();

      // Reopen — nothing restored, and the cleared text isn't in the ring.
      container.read(composeBarVisibleProvider.notifier).set(true);
      await tester.pumpAndSettle();
      expect(controllerText(tester), '');
      expect(
        container.read(composeHistoryProvider.notifier).historyOf('sess'),
        isEmpty,
      );
    });
  });

  group('#819 — unified Fix/Copy/Paste pills, flush-right on the top border', () {
    testWidgets('Fix, Copy and Paste are the SAME pill widget shape', (
      tester,
    ) async {
      await pumpBar(tester, <String>[]);

      // All three must resolve to the same pill widget type — no _BorderChip,
      // no shape split. Each pill key must be backed by exactly one Pill widget.
      for (final k in [
        'compose-bar-fix',
        'compose-bar-copy',
        'compose-bar-paste',
      ]) {
        expect(
          find.byKey(Key(k)),
          findsOneWidget,
          reason: '$k must exist as a unified pill',
        );
      }
      // Identical visual shape ⇒ identical height (the unified pill's fixed
      // height). Compare the rendered heights of all three.
      final fixH = tester.getRect(find.byKey(const Key('compose-bar-fix'))).height;
      final copyH = tester
          .getRect(find.byKey(const Key('compose-bar-copy')))
          .height;
      final pasteH = tester
          .getRect(find.byKey(const Key('compose-bar-paste')))
          .height;
      expect(copyH, fixH, reason: 'Copy shares Fix pill height (same shape)');
      expect(pasteH, fixH, reason: 'Paste shares Fix pill height (same shape)');
    });

    testWidgets('the three pills sit on the top border row, above the field', (
      tester,
    ) async {
      await pumpBar(tester, <String>[]);

      final field = find.byKey(const Key('compose-bar-input'));
      final fieldBox = tester.getRect(field);

      for (final k in [
        'compose-bar-fix',
        'compose-bar-copy',
        'compose-bar-paste',
      ]) {
        final box = tester.getRect(find.byKey(Key(k)));
        // The pills live on the TOP BORDER row, fully ABOVE the textarea — so
        // the pill's bottom is at or above the field's top edge. No overlap.
        expect(
          box.bottom <= fieldBox.top + 1,
          isTrue,
          reason: '$k must sit above the field top edge (no text overlap)',
        );
      }
    });

    testWidgets('the pills are flush RIGHT on the top border', (
      tester,
    ) async {
      await pumpBar(tester, <String>[]);

      final panelBox = tester.getRect(find.byKey(const Key('compose-bar')));
      final pasteBox = tester.getRect(find.byKey(const Key('compose-bar-paste')));
      // Paste is the right-most pill; its right edge hugs the panel's right edge.
      expect(
        (panelBox.right - pasteBox.right) < 24,
        isTrue,
        reason: 'pills must be flush-right on the top border',
      );

      // Right-to-left order on the border: Paste right-most, then Copy, then Fix.
      final fixBox = tester.getRect(find.byKey(const Key('compose-bar-fix')));
      final copyBox = tester.getRect(find.byKey(const Key('compose-bar-copy')));
      expect(fixBox.right <= copyBox.left + 1, isTrue);
      expect(copyBox.right <= pasteBox.left + 1, isTrue);
    });

    testWidgets('no separate pill band — vertical height is reclaimed', (
      tester,
    ) async {
      await pumpBar(tester, <String>[]);
      // The old standalone pill row band is gone (pills live on the header).
      expect(find.byKey(const Key('compose-bar-pills')), findsNothing);
    });

    testWidgets('the grip stays centered on the top border', (tester) async {
      await pumpBar(tester, <String>[]);
      final panelBox = tester.getRect(find.byKey(const Key('compose-bar')));
      final gripBox = tester.getRect(find.byKey(const Key('compose-bar-grip')));
      // Grip remains horizontally centered (the pills are flush-right, not over it).
      expect(
        (gripBox.center.dx - panelBox.center.dx).abs() < 8,
        isTrue,
        reason: 'grip stays centered while pills are flush-right',
      );
    });

    testWidgets('pills keep an adequate touch target (>=32px tall)', (
      tester,
    ) async {
      await pumpBar(tester, <String>[]);
      for (final k in [
        'compose-bar-fix',
        'compose-bar-copy',
        'compose-bar-paste',
      ]) {
        final box = tester.getRect(find.byKey(Key(k)));
        expect(
          box.height >= 32,
          isTrue,
          reason: '$k must keep a finger-sized hit area',
        );
      }
    });

    testWidgets('Copy still copies the staged text from its pill', (
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
        'border copy',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('compose-bar-copy')));
      await tester.pump();

      expect(clipboardText, 'border copy');
    });
  });

  group('#798 — grip affordance on the drag header', () {
    testWidgets('a clear grab handle renders inside the drag header', (
      tester,
    ) async {
      await pumpBar(tester, <String>[]);
      final grip = find.byKey(const Key('compose-bar-grip'));
      expect(grip, findsOneWidget);
      // The grip lives inside the drag header (the gesture surface).
      expect(
        find.descendant(
          of: find.byKey(const Key('compose-bar-drag')),
          matching: grip,
        ),
        findsOneWidget,
      );
    });
  });

  group('#798 — header gestures: flick-dock + hold-to-position', () {
    Positioned positioned(WidgetTester tester) => tester.widget<Positioned>(
      find.ancestor(
        of: find.byKey(const Key('compose-bar')),
        matching: find.byType(Positioned),
      ),
    );

    testWidgets('flick UP on the header docks the panel to the TOP', (
      tester,
    ) async {
      await pumpBar(tester, <String>[]);
      // Default dock is top; flick down first so the up-flick is observable.
      await tester.fling(
        find.byKey(const Key('compose-bar-drag')),
        const Offset(0, 120),
        1000,
      );
      await tester.pump();
      expect(positioned(tester).top, isNull,
          reason: 'flick down should clear top (bottom dock)');

      await tester.fling(
        find.byKey(const Key('compose-bar-drag')),
        const Offset(0, -120),
        1000,
      );
      await tester.pump();
      final p = positioned(tester);
      expect(p.top, isNotNull, reason: 'flick up docks to TOP');
      expect(p.bottom, isNull);
    });

    testWidgets('flick DOWN on the header docks the panel to the BOTTOM', (
      tester,
    ) async {
      await pumpBar(tester, <String>[]);
      await tester.fling(
        find.byKey(const Key('compose-bar-drag')),
        const Offset(0, 120),
        1000,
      );
      await tester.pump();
      final p = positioned(tester);
      expect(p.bottom, isNotNull, reason: 'flick down docks to BOTTOM');
      expect(p.top, isNull);
    });

    testWidgets('hold-then-drag free-positions the panel (no snap)', (
      tester,
    ) async {
      await pumpBar(tester, <String>[]);
      final grip = find.byKey(const Key('compose-bar-drag'));
      final start = tester.getCenter(grip);

      // Press and HOLD past the long-press threshold so the long-press
      // recognizer wins the arena, THEN drag — this is the free-position path.
      final gesture = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveBy(const Offset(0, 150));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      final p = positioned(tester);
      // Free mode anchors by explicit top offset (no snap to an edge).
      expect(p.top, isNotNull, reason: 'free-position anchors by top offset');
      expect(p.bottom, isNull);
      // The panel followed the finger downward from the default top margin.
      expect(p.top! > 12, isTrue,
          reason: 'panel tracked the hold-drag down the screen');
    });
  });
}
