// On-emulator host-key persistence: connect → accept → reconnect → NO prompt (#565).
//
// Device bug: HostKeyStore was in-memory only, and each session gets a fresh
// controller (hence a fresh store). So every connect re-prompted "Trust +
// connect". The fix persists accepted fingerprints (SharedPreferences) and
// hydrates them on a new store, so a known host:port never re-prompts.
//
// This is the connect → accept → reconnect → no-prompt STATE TRANSITION:
//   1. First connect: store starts empty → "Trust + connect" prompt appears,
//      we ACCEPT it, reach a live shell.
//   2. Disconnect (removes the session + its controller/store).
//   3. Reconnect to the SAME host: the new store hydrates the persisted trust,
//      so NO "Trust + connect" prompt appears, and it still reaches a live shell.
//
// PASS = first connect prompts+accepts+shell; second connect reaches shell with
// NO prompt observed.
//
// NOTE: run via `scripts/native-connect-test.sh integration_test/hostkey_persist_test.dart`.
// Persisted trust from a prior run would mask the first-connect prompt, so we
// clear SharedPreferences before starting (forces a deterministic fresh state).

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/sessions.dart';

Future<void> _fillForm(WidgetTester tester) async {
  await tester.enterText(find.byKey(const Key('connect-host')), '127.0.0.1');
  await tester.enterText(find.byKey(const Key('connect-port')), '2222');
  await tester.enterText(find.byKey(const Key('connect-username')), 'testuser');
  await tester.enterText(find.byKey(const Key('connect-password')), 'testpass');
  await tester.pump();
}

/// Submit, optionally accept the host-key prompt, and poll until the terminal
/// mounts AND the shell streams bytes. Returns a record:
///   (reachedShell, sawPrompt).
Future<({bool reachedShell, bool sawPrompt})> _connect(
  WidgetTester tester,
  ProviderContainer container, {
  required bool acceptPromptIfShown,
}) async {
  await tester.tap(find.byKey(const Key('connect-submit')));
  var connected = false;
  var sawPrompt = false;
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    final accept = find.text('Trust + connect');
    if (accept.evaluate().isNotEmpty) {
      sawPrompt = true;
      if (acceptPromptIfShown) {
        await tester.tap(accept.first);
        await tester.pump(const Duration(milliseconds: 300));
      }
    }
    if (find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty) {
      connected = true;
      break;
    }
  }
  if (!connected) return (reachedShell: false, sawPrompt: sawPrompt);

  final entry = container.read(sessionsProvider).active;
  if (entry == null) return (reachedShell: false, sawPrompt: sawPrompt);
  final out = <int>[];
  final sub = entry.proxy.output.listen(out.addAll);
  var gotBytes = false;
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (out.isNotEmpty) {
      gotBytes = true;
      break;
    }
  }
  await sub.cancel();
  return (reachedShell: gotBytes, sawPrompt: sawPrompt);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'accept host key once, reconnect to same host shows NO prompt (#565)',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();
      // Force a deterministic fresh state: no persisted trust from prior runs,
      // so the FIRST connect is guaranteed to prompt.
      SharedPreferences.setMockInitialValues(<String, Object>{});

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MobisshApp(),
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      // First connect — empty store → MUST prompt, we accept, reach a shell.
      await _fillForm(tester);
      final first = await _connect(
        tester,
        container,
        acceptPromptIfShown: true,
      );
      expect(
        first.reachedShell,
        isTrue,
        reason: 'first connect did not reach a live shell',
      );
      expect(
        first.sawPrompt,
        isTrue,
        reason: 'first connect to a brand-new host should prompt to trust',
      );

      // Disconnect → removes the session + its controller/store.
      await tester.tap(find.byKey(const Key('terminal-disconnect-button')));
      var backAtForm = false;
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byKey(const Key('connect-submit')).evaluate().isNotEmpty) {
          backAtForm = true;
          break;
        }
      }
      expect(
        backAtForm,
        isTrue,
        reason: 'disconnect did not return to the connect form',
      );

      // Reconnect to the SAME host — the persisted trust must hydrate into the
      // fresh session's store, so NO prompt this time, and still reach a shell.
      await _fillForm(tester);
      final second = await _connect(
        tester,
        container,
        acceptPromptIfShown: false,
      );
      expect(
        second.reachedShell,
        isTrue,
        reason: 'reconnect did not reach a live shell',
      );
      expect(
        second.sawPrompt,
        isFalse,
        reason:
            'RECONNECT re-prompted for an already-trusted host — the '
            '#565 persistence bug',
      );
    },
  );
}
