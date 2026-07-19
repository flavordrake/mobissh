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
}
