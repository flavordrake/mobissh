// Widget test for #1088 Slice 1c: the profile-editor key-source dropdown lists
// LIBRARY keys ([savedKeysProvider]); selecting one + Save points the profile's
// keyVaultId at that library key's vault id and writes NO new secret (many
// profiles can share one library key).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/state/keys_providers.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/storage/keys_store.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/ui/profile_editor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'selecting a library key sets the profile keyVaultId, writes no new secret',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // A library key already in the store + vault (created via the keys manager).
      final keysStore = KeysStore();
      final key = const SavedKey(id: 'k1', name: 'work', createdAtMs: 1);
      await keysStore.upsert(key);
      final backend = InMemorySecretsBackend();
      final secrets = SecretsStore(backend: backend);
      await secrets.write(key.vaultId, <String, Object?>{
        'data': '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END-----',
      });
      final blobsBefore = (await backend.readAll()).length;

      final store = ProfilesStore();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            profilesStoreProvider.overrideWithValue(store),
            secretsStoreProvider.overrideWithValue(secrets),
            keysStoreProvider.overrideWithValue(keysStore),
          ],
          child: MaterialApp(
            home: ProfileEditor(profile: blankProfile(), isNew: true),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('profile-editor-host')),
        'new.example',
      );
      await tester.enterText(
        find.byKey(const Key('profile-editor-username')),
        'me',
      );
      await tester.tap(find.text('Key'));
      await tester.pumpAndSettle();

      // The dropdown lists the library key labeled "Library: work"; pick it.
      await tester.tap(find.byKey(const Key('profile-editor-key-source')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Library: work').last);
      await tester.pumpAndSettle();

      // Reuse note replaces the PEM field.
      expect(
        find.byKey(const Key('profile-editor-stored-key-note')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('profile-editor-key')), findsNothing);

      await tester.tap(find.byKey(const Key('profile-editor-save')));
      await tester.pumpAndSettle();

      final saved = (await store.load()).firstWhere(
        (p) => p.host == 'new.example',
      );
      expect(saved.authType, 'key');
      expect(
        saved.keyVaultId,
        key.vaultId,
        reason: 'the profile reuses the library key by its vault id',
      );
      // No NEW secret blob written — the vault still holds only the library key.
      expect((await backend.readAll()).length, blobsBefore);
    },
  );

  testWidgets(
    'opening a key profile PRESELECTS its attached key — stored note, not '
    'blank paste (#1121)',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // The key exists in the library (adopted, override vault id) — as after
      // a phone migration, where metadata survives but the vault does not.
      final keysStore = KeysStore();
      const vaultId = 'profile-key-vault.example:22:fam';
      await keysStore.upsert(const SavedKey(
        id: 'kFam',
        name: 'family vault',
        vaultId: vaultId,
        createdAtMs: 1,
      ));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            profilesStoreProvider.overrideWithValue(ProfilesStore()),
            secretsStoreProvider.overrideWithValue(
              SecretsStore(backend: InMemorySecretsBackend()),
            ),
            keysStoreProvider.overrideWithValue(keysStore),
          ],
          child: MaterialApp(
            home: ProfileEditor(
              profile: SavedProfile(
                title: 'family vault',
                host: 'vault.example',
                port: 22,
                username: 'fam',
                authType: 'key',
                keyVaultId: vaultId,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Key auth is selected AND the profile's own key is preselected: the
      // stored-key note identifies it by its library name; no blank PEM box.
      expect(
        find.byKey(const Key('profile-editor-stored-key-note')),
        findsOneWidget,
        reason: 'the editor must open on the attached key, not "paste a new key"',
      );
      // The label shows in the dropdown AND the note subtitle — at least once.
      expect(find.text('Library: family vault'), findsWidgets);
      expect(find.byKey(const Key('profile-editor-key')), findsNothing);
    },
  );

  testWidgets(
    'key profile preselects its key even BEFORE library adoption (#1121)',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // EMPTY library: adoptFromProfiles hasn't run/landed yet. The profile's
      // own keyVaultId must still be a valid, selected dropdown option (a
      // DropdownButton value absent from its items is a construction error).
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            profilesStoreProvider.overrideWithValue(ProfilesStore()),
            secretsStoreProvider.overrideWithValue(
              SecretsStore(backend: InMemorySecretsBackend()),
            ),
            keysStoreProvider.overrideWithValue(KeysStore()),
          ],
          child: MaterialApp(
            home: ProfileEditor(
              profile: SavedProfile(
                title: 'lone',
                host: 'lone.example',
                port: 22,
                username: 'me',
                authType: 'key',
                keyVaultId: 'profile-key-lone.example:22:me',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('profile-editor-stored-key-note')),
        findsOneWidget,
      );
      expect(find.text("This profile's stored key"), findsWidgets);
      expect(find.byKey(const Key('profile-editor-key')), findsNothing);
    },
  );

  testWidgets(
    'stored-key note Re-enter restores material at the SAME vault id (#1121)',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Post-migration state: profile + library metadata survive, vault empty.
      final keysStore = KeysStore();
      const vaultId = 'profile-key-vault.example:22:fam';
      await keysStore.upsert(const SavedKey(
        id: 'kFam',
        name: 'family vault',
        vaultId: vaultId,
        createdAtMs: 1,
      ));
      final backend = InMemorySecretsBackend();
      final secrets = SecretsStore(backend: backend);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            profilesStoreProvider.overrideWithValue(ProfilesStore()),
            secretsStoreProvider.overrideWithValue(secrets),
            keysStoreProvider.overrideWithValue(keysStore),
          ],
          child: MaterialApp(
            home: ProfileEditor(
              profile: SavedProfile(
                title: 'family vault',
                host: 'vault.example',
                port: 22,
                username: 'fam',
                authType: 'key',
                keyVaultId: vaultId,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The fill-in affordance lives ON the stored-key note — the migration
      // banner lands the user here, not in Settings → SSH keys.
      await tester.tap(
        find.byKey(const Key('profile-editor-stored-key-reenter')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('keys-reenter-pem')),
        '-----BEGIN OPENSSH PRIVATE KEY-----\nrestored\n-----END-----',
      );
      await tester.tap(find.byKey(const Key('keys-reenter-save')));
      await tester.pumpAndSettle();

      final entry = await secrets.read(vaultId);
      expect(entry?['data'], contains('restored'),
          reason: 'material restored under the SAME vault id the profile '
              '(and any sibling profiles) point at');
    },
  );

  testWidgets(
    'pasting a NEW key + Save creates a library key; profile points at it (#1088)',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final keysStore = KeysStore();
      final backend = InMemorySecretsBackend();
      final secrets = SecretsStore(backend: backend);
      final store = ProfilesStore();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            profilesStoreProvider.overrideWithValue(store),
            secretsStoreProvider.overrideWithValue(secrets),
            keysStoreProvider.overrideWithValue(keysStore),
          ],
          child: MaterialApp(
            home: ProfileEditor(profile: blankProfile(), isNew: true),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('profile-editor-title')),
        'prod box',
      );
      await tester.enterText(
        find.byKey(const Key('profile-editor-host')),
        'prod.example',
      );
      await tester.enterText(
        find.byKey(const Key('profile-editor-username')),
        'deploy',
      );
      await tester.tap(find.text('Key'));
      await tester.pumpAndSettle();

      // Paste a NEW key into the PEM field (default pasted source).
      const pem = '-----BEGIN OPENSSH PRIVATE KEY-----\nnewkey\n-----END-----';
      await tester.enterText(find.byKey(const Key('profile-editor-key')), pem);
      await tester.tap(find.byKey(const Key('profile-editor-save')));
      await tester.pumpAndSettle();

      // A library key was created (manageable from the Keys screen).
      final lib = await keysStore.load();
      expect(lib.length, 1);
      final libraryKey = lib.single;
      expect(libraryKey.name, 'prod box key');

      // The profile points at that library key's vault id.
      final saved =
          (await store.load()).firstWhere((p) => p.host == 'prod.example');
      expect(saved.authType, 'key');
      expect(saved.keyVaultId, libraryKey.vaultId);

      // The PEM lives in the vault under that id — NOT a one-off profile-key blob.
      final blob = await secrets.read(libraryKey.vaultId);
      expect(blob?['data'], pem);
      expect(saved.keyVaultId, isNot(startsWith('profile-key-')));
    },
  );
}
