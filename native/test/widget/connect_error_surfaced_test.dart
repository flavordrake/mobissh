// Widget test: a connect that ends in `failed` SURFACES a visible error (#648).
//
// Bug: connecting to an unreachable host gave no error and no feedback — the
// session reached `SshSessionState.failed` (controller is bounded by the
// readyTimeout / TCP-connect throw) but the chooser never rendered the failure.
// The router keeps the chooser mounted on a never-live `failed` precisely so the
// "connect error renders there", but the chooser only listened for host-key
// prompts.
//
// This test drives a profile tap → connect, then pushes a `failed` state event
// from the task side (modelling an unreachable host the controller force-failed)
// and asserts the connect-error dialog appears with the reason — NOT a silent
// hang.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/ui/connect_form.dart';

Future<void> _pumpFrames(WidgetTester tester, {int count = 12}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets(
    'connect that reaches `failed` surfaces a visible error dialog with the reason',
    (tester) async {
      // Seed a password profile + its vault secret so the tap connects.
      final store = ProfilesStore();
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      await secrets.write('vault-1', <String, Object?>{'password': 'pw'});
      await store.save(<SavedProfile>[
        SavedProfile(
          title: 'Unreachable',
          host: 'down.example',
          port: 22,
          username: 'alice',
          authType: 'password',
          vaultId: 'vault-1',
        ),
      ]);

      final pair = InMemoryGatewayPair();
      addTearDown(() async {
        await pair.dispose();
      });
      final container = ProviderContainer(
        overrides: [
          taskSshGatewayProvider.overrideWithValue(pair.uiSide),
          profilesStoreProvider.overrideWithValue(store),
          secretsStoreProvider.overrideWithValue(secrets),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: ConnectForm())),
        ),
      );
      await tester.pumpAndSettle();

      // Tap the profile row → connect (creates the session entry).
      await tester.tap(
        find.byKey(const Key('profile-tile-down.example:22:alice')),
      );
      await _pumpFrames(tester, count: 20);

      final entry = container.read(sessionsProvider).entries.first;

      // The controller would deterministically force-fail an unreachable host
      // within the readyTimeout. Model that terminal event from the task side.
      const reason =
          'No SSH response in 25s — host may be unreachable or asleep';
      pair.taskSide.send(
        SshStateEvent(
          sessionId: entry.id,
          state: SshSessionState.failed.name,
          error: reason,
          host: 'down.example',
          port: 22,
          username: 'alice',
        ).toJson(),
      );
      await _pumpFrames(tester, count: 20);

      // The failure must be SURFACED — a visible dialog with the reason, not a
      // silent spinner.
      expect(
        find.byKey(const Key('connect-error-dialog')),
        findsOneWidget,
        reason: 'a failed connect must surface a visible error, not hang',
      );
      expect(find.textContaining('unreachable'), findsOneWidget);
    },
  );

  testWidgets(
    'tapping Back on the connect-error dialog dismisses it (no hang)',
    (tester) async {
      final store = ProfilesStore();
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      await secrets.write('vault-1', <String, Object?>{'password': 'pw'});
      await store.save(<SavedProfile>[
        SavedProfile(
          title: 'Refused',
          host: 'refused.example',
          port: 22,
          username: 'bob',
          authType: 'password',
          vaultId: 'vault-1',
        ),
      ]);

      final pair = InMemoryGatewayPair();
      addTearDown(() async {
        await pair.dispose();
      });
      final container = ProviderContainer(
        overrides: [
          taskSshGatewayProvider.overrideWithValue(pair.uiSide),
          profilesStoreProvider.overrideWithValue(store),
          secretsStoreProvider.overrideWithValue(secrets),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: ConnectForm())),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('profile-tile-refused.example:22:bob')),
      );
      await _pumpFrames(tester, count: 20);

      final entry = container.read(sessionsProvider).entries.first;
      pair.taskSide.send(
        SshStateEvent(
          sessionId: entry.id,
          state: SshSessionState.failed.name,
          error: 'TCP connect failed: connection refused',
          host: 'refused.example',
          port: 22,
          username: 'bob',
        ).toJson(),
      );
      await _pumpFrames(tester, count: 20);

      expect(find.byKey(const Key('connect-error-dialog')), findsOneWidget);

      await tester.tap(find.byKey(const Key('connect-error-back')));
      await _pumpFrames(tester, count: 10);

      expect(find.byKey(const Key('connect-error-dialog')), findsNothing);
    },
  );
}
