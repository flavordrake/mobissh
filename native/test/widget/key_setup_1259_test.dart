// #1259 gap 1 (SSH key setup). The Add-key dialog validates the key before
// anything is stored: an invalid key or a wrong passphrase shows a fixed,
// key-free inline error, stores nothing and never says "Key added". The
// profile editor adds a key to the library in place (no trip through
// Settings), preselects the newest library key when switching to key auth,
// and copies the attached key's public line for authorized_keys.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/state/keys_providers.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/storage/keys_store.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/ui/keys_screen.dart';
import 'package:mobissh/ui/profile_editor.dart';

import '../support/test_keys.dart';

const _garbagePem = '-----BEGIN OPENSSH PRIVATE KEY-----\n'
    'c2VjcmV0LW1hdGVyaWFs\n-----END OPENSSH PRIVATE KEY-----';

Future<void> _pump(
  WidgetTester tester,
  Widget home, {
  required KeysStore keysStore,
  required SecretsStore secrets,
  ProfilesStore? profilesStore,
}) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keysStoreProvider.overrideWithValue(keysStore),
        secretsStoreProvider.overrideWithValue(secrets),
        profilesStoreProvider.overrideWithValue(profilesStore ?? ProfilesStore()),
      ],
      child: MaterialApp(home: home),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _fillAddDialog(
  WidgetTester tester, {
  required String name,
  required String pem,
  String? passphrase,
}) async {
  await tester.enterText(find.byKey(const ValueKey('keys-add-name')), name);
  await tester.enterText(find.byKey(const ValueKey('keys-add-pem')), pem);
  if (passphrase != null) {
    await tester.enterText(
      find.byKey(const ValueKey('keys-add-passphrase')),
      passphrase,
    );
  }
  await tester.tap(find.byKey(const ValueKey('keys-add-save')));
  await tester.pumpAndSettle();
}

/// Let the 2s top toast expire so no timer outlives the test.
Future<void> _drainToast(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('Keys screen Add validates (#1259)', () {
    testWidgets('invalid PEM: inline error, nothing stored, no "Key added"',
        (tester) async {
      final keysStore = KeysStore();
      final backend = InMemorySecretsBackend();
      await _pump(tester, const KeysScreen(),
          keysStore: keysStore, secrets: SecretsStore(backend: backend));

      await tester.tap(find.byKey(const ValueKey('keys-add-fab')));
      await tester.pumpAndSettle();
      await _fillAddDialog(tester, name: 'bad', pem: _garbagePem);

      // The dialog stays open with a fixed, key-free error.
      expect(find.byKey(const ValueKey('keys-add-dialog')), findsOneWidget);
      final error = find.byKey(const ValueKey('keys-add-error'));
      expect(error, findsOneWidget);
      final text = tester.widget<Text>(error).data!;
      expect(text, startsWith("Couldn't read the private key"));
      expect(text, isNot(contains('c2VjcmV0')));
      expect(find.text('Key added'), findsNothing);
      expect(await backend.readAll(), isEmpty);
      expect(await keysStore.load(), isEmpty);
    });

    testWidgets('wrong passphrase: passphrase error, nothing stored',
        (tester) async {
      final keysStore = KeysStore();
      final backend = InMemorySecretsBackend();
      await _pump(tester, const KeysScreen(),
          keysStore: keysStore, secrets: SecretsStore(backend: backend));

      await tester.tap(find.byKey(const ValueKey('keys-add-fab')));
      await tester.pumpAndSettle();
      await _fillAddDialog(tester,
          name: 'enc', pem: kTestEncryptedPem, passphrase: 'wrong');

      final error = find.byKey(const ValueKey('keys-add-error'));
      expect(error, findsOneWidget);
      expect(tester.widget<Text>(error).data, contains('passphrase'));
      expect(find.text('Key added'), findsNothing);
      expect(await backend.readAll(), isEmpty);
      expect(await keysStore.load(), isEmpty);
    });

    testWidgets('correct passphrase: stored vault-only and "Key added"',
        (tester) async {
      final keysStore = KeysStore();
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      await _pump(tester, const KeysScreen(),
          keysStore: keysStore, secrets: secrets);

      await tester.tap(find.byKey(const ValueKey('keys-add-fab')));
      await tester.pumpAndSettle();
      await _fillAddDialog(tester,
          name: 'enc',
          pem: kTestEncryptedPem,
          passphrase: kTestEncryptedPassphrase);

      expect(find.byKey(const ValueKey('keys-add-dialog')), findsNothing);
      expect(find.text('Key added'), findsOneWidget);
      final keys = await keysStore.load();
      expect(keys.single.fingerprint, kTestEncryptedFingerprint);
      // The dialog trims the pasted text; the key itself is unchanged.
      expect((await secrets.read(keys.single.vaultId))?['data'],
          kTestEncryptedPem.trim());
      expect(keys.single.toJson().toString(), isNot(contains('PRIVATE')));
      await _drainToast(tester);
    });

    testWidgets('fixing the PEM after an error clears it and adds the key',
        (tester) async {
      final keysStore = KeysStore();
      await _pump(tester, const KeysScreen(),
          keysStore: keysStore,
          secrets: SecretsStore(backend: InMemorySecretsBackend()));

      await tester.tap(find.byKey(const ValueKey('keys-add-fab')));
      await tester.pumpAndSettle();
      await _fillAddDialog(tester, name: 'k', pem: 'not a key');
      expect(find.byKey(const ValueKey('keys-add-error')), findsOneWidget);

      await _fillAddDialog(tester, name: 'k', pem: kTestEd25519Pem);
      expect(find.byKey(const ValueKey('keys-add-dialog')), findsNothing);
      expect(find.text('Key added'), findsOneWidget);
      expect((await keysStore.load()).single.name, 'k');
      await _drainToast(tester);
    });
  });

  group('profile editor key setup (#1259)', () {
    testWidgets(
        'Add key in the editor validates, lands in the library and is '
        'attached on Save', (tester) async {
      final keysStore = KeysStore();
      final backend = InMemorySecretsBackend();
      final secrets = SecretsStore(backend: backend);
      final profiles = ProfilesStore();
      await _pump(
        tester,
        ProfileEditor(profile: blankProfile(), isNew: true),
        keysStore: keysStore,
        secrets: secrets,
        profilesStore: profiles,
      );
      await tester.enterText(
          find.byKey(const Key('profile-editor-host')), 'box.example');
      await tester.enterText(
          find.byKey(const Key('profile-editor-username')), 'me');
      await tester.tap(find.text('Key'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('profile-editor-key-add')));
      await tester.pumpAndSettle();
      // Invalid first: refused in place, nothing stored.
      await _fillAddDialog(tester, name: 'laptop', pem: _garbagePem);
      expect(find.byKey(const ValueKey('keys-add-error')), findsOneWidget);
      expect(await backend.readAll(), isEmpty);

      await _fillAddDialog(tester, name: 'laptop', pem: kTestEd25519Pem);
      expect(find.byKey(const ValueKey('keys-add-dialog')), findsNothing);
      // The new key is selected: the stored-key note replaces the PEM box.
      expect(find.byKey(const Key('profile-editor-stored-key-note')),
          findsOneWidget);
      expect(find.text('Library: laptop'), findsWidgets);

      await tester.tap(find.byKey(const Key('profile-editor-save')));
      await tester.pumpAndSettle();

      final lib = await keysStore.load();
      expect(lib.single.name, 'laptop');
      final saved =
          (await profiles.load()).firstWhere((p) => p.host == 'box.example');
      expect(saved.authType, 'key');
      expect(saved.keyVaultId, lib.single.vaultId);
      // One vault blob: the library key. Nothing else was written.
      expect((await backend.readAll()).length, 1);
      await _drainToast(tester);
    });

    testWidgets(
        'switching a new profile to Key preselects the newest library key',
        (tester) async {
      final keysStore = KeysStore();
      await keysStore.upsert(const SavedKey(id: 'kOld', name: 'old', createdAtMs: 1));
      await keysStore.upsert(const SavedKey(id: 'kNew', name: 'new', createdAtMs: 2));
      final profiles = ProfilesStore();
      await _pump(
        tester,
        ProfileEditor(profile: blankProfile(), isNew: true),
        keysStore: keysStore,
        secrets: SecretsStore(backend: InMemorySecretsBackend()),
        profilesStore: profiles,
      );
      await tester.enterText(
          find.byKey(const Key('profile-editor-host')), 'h.example');
      await tester.enterText(
          find.byKey(const Key('profile-editor-username')), 'me');
      await tester.tap(find.text('Key'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('profile-editor-stored-key-note')),
          findsOneWidget);
      expect(find.byKey(const Key('profile-editor-key')), findsNothing);

      await tester.tap(find.byKey(const Key('profile-editor-save')));
      await tester.pumpAndSettle();
      final saved =
          (await profiles.load()).firstWhere((p) => p.host == 'h.example');
      expect(saved.keyVaultId, keyVaultIdFor('kNew'));
    });

    testWidgets('stored-key note copies the public line (authorized_keys)',
        (tester) async {
      final copied = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('mobissh/clipboard'),
        (call) async {
          if (call.method == 'setText') {
            copied.add((call.arguments as Map)['text'] as String);
            return true;
          }
          return null;
        },
      );
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(
            const MethodChannel('mobissh/clipboard'), null);
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });

      final keysStore = KeysStore();
      await keysStore.upsert(const SavedKey(
        id: 'k1',
        name: 'work',
        publicKey: kTestEd25519PublicLine,
        createdAtMs: 1,
      ));
      await _pump(
        tester,
        ProfileEditor(
          profile: SavedProfile(
            title: 'w',
            host: 'w.example',
            port: 22,
            username: 'me',
            authType: 'key',
            keyVaultId: keyVaultIdFor('k1'),
          ),
        ),
        keysStore: keysStore,
        secrets: SecretsStore(backend: InMemorySecretsBackend()),
      );

      await tester.tap(find.byKey(const Key('profile-editor-stored-key-copy')));
      await tester.pumpAndSettle();
      expect(copied, contains(kTestEd25519PublicLine));
      await _drainToast(tester);
    });
  });
}
