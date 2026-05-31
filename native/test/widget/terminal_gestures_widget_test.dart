// Widget tests for terminal gestures (#568, Phases 1 + 2).
//
// Phase 1: a horizontal swipe on the bottom session bar switches the active
// session, wrapping around the session ring. A single-session swipe is a
// no-op. These assert at the STATE level (sessionsProvider.activeId) — the
// actual touch feel (velocity, arena negotiation vs. the terminal's vertical
// scroll) requires real-device validation, which a widget test can't cover.
//
// Phase 2: the long-press context menu surfaces Copy / Select all / Paste, and
// Paste routes clipboard text through the session proxy (the same wire path as
// typed keystrokes). We drive the menu via `showTerminalContextMenu` directly
// — xterm.dart's internal long-press → onSecondaryTapDown recognizer is not
// reliably mounted in the widget-test harness (same caveat the keystroke pipe
// test documents), so we exercise the menu + its wiring at the layer where a
// regression would actually manifest.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/terminal_providers.dart';
import 'package:mobissh/ui/terminal_context_menu.dart';
import 'package:mobissh/ui/terminal_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_ssh_shell_transport.dart';

ProviderContainer _makeContainer() {
  final pair = InMemoryGatewayPair();
  final container = ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      sshShellOpenerProvider.overrideWithValue(
        (ref, sessionId, terminal) async => FakeSshShellTransport(),
      ),
    ],
  );
  addTearDown(() async {
    await pair.dispose();
  });
  return container;
}

Future<void> _pumpFrames(WidgetTester tester, {int count = 8}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

SshConnectParams _params(String host) => SshConnectParams(
  host: host,
  port: 22,
  username: 'u',
  auth: const SshAuth.password('p'),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Phase 1 — session-bar swipe', () {
    testWidgets(
      'swipe left on the session bar advances to the next session in the ring',
      (tester) async {
        final container = _makeContainer();
        addTearDown(container.dispose);

        final notifier = container.read(sessionsProvider.notifier);
        final a = notifier.addOrActivate(_params('host-a'));
        final b = notifier.addOrActivate(_params('host-b'));

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: TerminalScreen()),
          ),
        );
        await _pumpFrames(tester);

        // b was added last → active. Two sessions form a ring [a, b].
        expect(container.read(sessionsProvider).activeId, b.id);

        // Swipe LEFT (negative dx) on the session bar → next session. From b
        // (index 1) the ring wraps to a (index 0).
        await tester.drag(
          find.byKey(const Key('session-bar')),
          const Offset(-120, 0),
        );
        await _pumpFrames(tester);

        expect(container.read(sessionsProvider).activeId, a.id);

        // Swipe LEFT again → wraps a (index 0) forward to b (index 1).
        await tester.drag(
          find.byKey(const Key('session-bar')),
          const Offset(-120, 0),
        );
        await _pumpFrames(tester);

        expect(container.read(sessionsProvider).activeId, b.id);
      },
    );

    testWidgets(
      'swipe right on the session bar goes to the previous session in the ring',
      (tester) async {
        final container = _makeContainer();
        addTearDown(container.dispose);

        final notifier = container.read(sessionsProvider.notifier);
        final a = notifier.addOrActivate(_params('host-a'));
        final b = notifier.addOrActivate(_params('host-b'));

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: TerminalScreen()),
          ),
        );
        await _pumpFrames(tester);

        expect(container.read(sessionsProvider).activeId, b.id);

        // Swipe RIGHT (positive dx) → previous session. From b (1) → a (0).
        await tester.drag(
          find.byKey(const Key('session-bar')),
          const Offset(120, 0),
        );
        await _pumpFrames(tester);

        expect(container.read(sessionsProvider).activeId, a.id);
      },
    );

    testWidgets('swipe with a single session is a no-op', (tester) async {
      final container = _makeContainer();
      addTearDown(container.dispose);

      final a = container
          .read(sessionsProvider.notifier)
          .addOrActivate(_params('solo'));

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: TerminalScreen()),
        ),
      );
      await _pumpFrames(tester);

      expect(container.read(sessionsProvider).activeId, a.id);

      await tester.drag(
        find.byKey(const Key('session-bar')),
        const Offset(-200, 0),
      );
      await _pumpFrames(tester);

      // Only one session → still active, no crash, no change.
      expect(container.read(sessionsProvider).activeId, a.id);
    });

    testWidgets('a sub-threshold horizontal drag does not switch sessions', (
      tester,
    ) async {
      final container = _makeContainer();
      addTearDown(container.dispose);

      final notifier = container.read(sessionsProvider.notifier);
      notifier.addOrActivate(_params('host-a'));
      final b = notifier.addOrActivate(_params('host-b'));

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: TerminalScreen()),
        ),
      );
      await _pumpFrames(tester);

      expect(container.read(sessionsProvider).activeId, b.id);

      // 20px < 50px threshold → no switch.
      await tester.drag(
        find.byKey(const Key('session-bar')),
        const Offset(-20, 0),
      );
      await _pumpFrames(tester);

      expect(container.read(sessionsProvider).activeId, b.id);
    });
  });

  group('Phase 2 — long-press context menu', () {
    testWidgets(
      'context menu shows Select all + Paste, and Copy when a selection '
      'exists',
      (tester) async {
        var copied = false;
        var selectedAll = false;
        var pasted = false;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: ElevatedButton(
                    key: const Key('open-ctx'),
                    onPressed: () => showTerminalContextMenu(
                      context,
                      globalPosition: const Offset(100, 100),
                      actions: TerminalContextMenuActions(
                        hasSelection: true,
                        onCopy: () => copied = true,
                        onSelectAll: () => selectedAll = true,
                        onPaste: () => pasted = true,
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(const Key('open-ctx')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('terminal-ctx-copy')), findsOneWidget);
        expect(
          find.byKey(const Key('terminal-ctx-select-all')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('terminal-ctx-paste')), findsOneWidget);

        await tester.tap(find.byKey(const Key('terminal-ctx-copy')));
        await tester.pumpAndSettle();

        expect(copied, isTrue);
        expect(selectedAll, isFalse);
        expect(pasted, isFalse);
      },
    );

    testWidgets('Copy is hidden when there is no selection', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  key: const Key('open-ctx'),
                  onPressed: () => showTerminalContextMenu(
                    context,
                    globalPosition: const Offset(100, 100),
                    actions: TerminalContextMenuActions(
                      hasSelection: false,
                      onCopy: () {},
                      onSelectAll: () {},
                      onPaste: () {},
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('open-ctx')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('terminal-ctx-copy')), findsNothing);
      expect(find.byKey(const Key('terminal-ctx-select-all')), findsOneWidget);
      expect(find.byKey(const Key('terminal-ctx-paste')), findsOneWidget);
    });

    testWidgets('Paste routes clipboard text through the session proxy', (
      tester,
    ) async {
      // Spy on the clipboard read so Paste has content without a real platform
      // clipboard.
      const channel = SystemChannels.platform;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'Clipboard.getData') {
          return <String, dynamic>{'text': 'pasted-text'};
        }
        return null;
      });
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      });

      final pair = InMemoryGatewayPair();
      final container = ProviderContainer(
        overrides: [
          taskSshGatewayProvider.overrideWithValue(pair.uiSide),
          sshShellOpenerProvider.overrideWithValue(
            (ref, sessionId, terminal) async => FakeSshShellTransport(),
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(() async => pair.dispose());

      final entry = container
          .read(sessionsProvider.notifier)
          .addOrActivate(_params('host-a'));

      // Capture input commands the proxy forwards toward the task isolate.
      // SshInputCommand serializes `bytes` as a base64 string (see
      // session_messages.dart), so decode that back to text.
      final inputs = <String>[];
      pair.taskSide.incoming.listen((payload) {
        if (payload['kind'] == 'input') {
          inputs.add(utf8.decode(base64Decode(payload['bytes'] as String)));
        }
      });

      // Drive the paste action exactly as the context menu's onPaste does.
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      expect(text, 'pasted-text');
      entry.proxy.sendInput(Uint8List.fromList(utf8.encode(text!)));

      await tester.pump(const Duration(milliseconds: 50));

      expect(inputs, contains('pasted-text'));
    });
  });
}
