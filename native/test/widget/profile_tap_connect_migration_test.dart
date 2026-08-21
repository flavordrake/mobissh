// Widget test: tapping a profile whose vault entry is UNREADABLE routes to
// the editor with a migration-specific message — NOT a silent no-op (#1118).
//
// Post-migration state: Android backup restored the profile list and the
// encrypted secret blobs, but not the Keystore master key. Every secure-
// storage read throws a PlatformException. Before #1118 that throw escaped
// SecretsStore.read and killed the tap handler silently (no connect, no
// editor, no toast). This test locks in the recovery: the tap must reach the
// existing no-usable-creds fallback, and because the profile DOES reference a
// vault entry, the toast must say the credential couldn't be read (migration
// signature) rather than the generic "No saved credentials".

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// Simulates the post-migration Keystore: reads throw, writes are accepted.
class _ThrowingSecretsBackend implements SecretsBackend {
  @override
  Future<String?> read(String key) async {
    throw PlatformException(
      code: 'BadDecrypt',
      message: 'Failed to decrypt: Keystore key not found',
    );
  }

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}

  @override
  Future<Map<String, String>> readAll() async {
    throw PlatformException(
      code: 'BadDecrypt',
      message: 'Failed to decrypt: Keystore key not found',
    );
  }
}

Future<void> _pumpFrames(WidgetTester tester, {int count = 20}) async {
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
    'tapping a profile with an unreadable vault opens the editor + migration '
    'toast (not a silent no-op)',
    (tester) async {
      final store = ProfilesStore();
      final secrets = SecretsStore(backend: _ThrowingSecretsBackend());
      await store.save(<SavedProfile>[
        SavedProfile(
          title: 'Migrated',
          host: 'moved.example',
          port: 22,
          username: 'carol',
          authType: 'password',
          // vaultId IS set — a secret was stored on the old phone, but the
          // restored blob can no longer be decrypted on this device.
          vaultId: 'vault-poisoned',
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
            home: Scaffold(body: ConnectForm()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('profile-tile-moved.example:22:carol')),
      );
      await _pumpFrames(tester);

      // No session — creds were unreadable.
      expect(container.read(sessionsProvider).entries, isEmpty);
      // NOT a silent no-op: the editor opened, prefilled with the host.
      expect(find.byKey(const Key('profile-editor')), findsOneWidget,
          reason: 'the tap handler must survive the platform throw and reach '
              'the no-creds fallback');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('profile-editor-host')))
            .controller
            ?.text,
        'moved.example',
      );
      // Migration signature (vault referenced but nothing readable) gets a
      // clearer message than the generic "No saved credentials".
      expect(find.textContaining("couldn't be read"), findsOneWidget);
    },
  );
}
