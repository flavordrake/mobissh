// Widget test: a connect that ends in `failed` surfaces a VISIBLE, INLINE error
// at the chooser — NOT a blocking modal (#648 → refined by #660).
//
// History: #648 fixed a silent hang (a failed connect rendered nothing) by
// popping a modal AlertDialog. On device (build 'f') that modal BLOCKED the
// whole profile list — the owner asked for a LOCAL, PER-ROW affordance instead.
// #660 replaces the modal with an inline per-row error + retry.
//
// This test drives a profile tap → connect, then pushes a `failed` state event
// from the task side (modelling an unreachable host the controller force-failed)
// and asserts the failure is surfaced INLINE on that profile row — and that NO
// blocking AlertDialog appears.

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
    'a failed connect surfaces an INLINE row error (with reason), not a blocking modal',
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

      // #660: the failure is SURFACED INLINE on the row — not a blocking modal.
      expect(
        find.byKey(const Key('profile-error-down.example:22:alice')),
        findsOneWidget,
        reason: 'a failed connect must surface inline on the row',
      );
      expect(
        find.byKey(const Key('profile-retry-down.example:22:alice')),
        findsOneWidget,
      );
      // The old #648 modal must be GONE.
      expect(
        find.byKey(const Key('connect-error-dialog')),
        findsNothing,
        reason: '#660 replaces the modal with an inline per-row affordance',
      );
      expect(find.byType(AlertDialog), findsNothing);
    },
  );
}
