// Widget test: tapping a saved-profile row CONNECTS immediately (#579).
//
// Locks the tap-to-connect contract: a profile row tap resolves the profile's
// host/port/username + stored vault credentials and routes them through the
// shared connect path (addOrActivate → proxy.connect), creating a session
// entry — NOT merely pre-filling the form (the old behavior).
//
// Sessions are proxy-backed; `taskSshGatewayProvider` is overridden with an
// in-memory gateway pair so addOrActivate + proxy.connect run without binding
// to platform statics. The in-memory gateway never emits `connected`, so we
// assert the session entry was created with the profile's params (which is the
// observable signal that the connect path — not form-fill — ran).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/services/task_ssh_gateway.dart';
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
    'tapping a profile with stored creds creates a session for its params',
    (tester) async {
      // Seed a password profile + its vault secret.
      final store = ProfilesStore();
      final backend = InMemorySecretsBackend();
      final secrets = SecretsStore(backend: backend);
      await secrets.write('vault-1', <String, Object?>{'password': 'pw'});
      await store.save(<SavedProfile>[
        SavedProfile(
          title: 'Box',
          host: 'box.example',
          port: 2200,
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

      expect(container.read(sessionsProvider).entries, isEmpty);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: ConnectForm())),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap the profile row → connect.
      await tester.tap(
        find.byKey(const Key('profile-tile-box.example:2200:alice')),
      );
      await _pumpFrames(tester, count: 30);

      final state = container.read(sessionsProvider);
      expect(
        state.entries.length,
        1,
        reason: 'profile tap must connect, not just fill the form',
      );
      final entry = state.entries.first;
      expect(entry.host, 'box.example');
      expect(entry.port, 2200);
      expect(entry.username, 'alice');
      expect(entry.title, 'Box');
    },
  );

  testWidgets(
    'tapping a profile with NO stored creds falls back to form (no session)',
    (tester) async {
      final store = ProfilesStore();
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      await store.save(<SavedProfile>[
        SavedProfile(
          title: 'NoCreds',
          host: 'bare.example',
          port: 22,
          username: 'bob',
          authType: 'password',
          // No vaultId → no stored credentials.
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
          child: const MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: ConnectForm())),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('profile-tile-bare.example:22:bob')),
      );
      await _pumpFrames(tester, count: 20);

      // No session created — fell back to form-fill.
      expect(container.read(sessionsProvider).entries, isEmpty);
      // The form was prefilled with the profile's host so the user can finish.
      expect(find.text('bare.example'), findsOneWidget);
      // And a snackbar nudged them to enter credentials.
      expect(find.textContaining('No saved credentials'), findsOneWidget);
    },
  );
}
