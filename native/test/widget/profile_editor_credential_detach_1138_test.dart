// #1138 — a vault handle is NOT portable across identities.
//
// `ProfileEditor._persist` used to carry `vaultId` / `keyVaultId` forward
// unconditionally, so renaming a profile onto a different host kept the OLD
// host's password attached to the NEW one (and the handle, minted as
// `profile-<old identity>`, stopped matching the profile that named it). The
// next connect would have sent A's password to B.
//
// Behaviour pinned here:
//   - an identity edit (host/port/username) with NO credential re-entry saves
//     `vaultId == null` — and the old secret is STILL in the vault under its
//     old id (detach only; a rename must never destroy a credential),
//   - a LIBRARY key (`key-<id>`, #1088) is reusable across hosts by design and
//     stays attached; a profile-scoped `profile-…` blob detaches,
//   - re-entering the password in the SAME save mints a handle from the NEW
//     identity,
//   - the rename still rebinds other profiles' jump references (#1183 R5) in
//     the same write,
//   - the editor SAYS so, in a persistent inline notice where the action is
//     (Key('profile-editor-detach-notice')) — not a vanishing toast.

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

const _noticeKey = Key('profile-editor-detach-notice');
const _oldPasswordVaultId = 'profile-old.example:22:me';
const _oldKeyVaultId = 'profile-key-old.example:22:me';

Future<void> _tapSave(WidgetTester tester) async {
  final save = find.byKey(const Key('profile-editor-save'));
  await tester.ensureVisible(save);
  await tester.pumpAndSettle();
  await tester.tap(save);
  await tester.pumpAndSettle();
}

Future<void> _setHost(WidgetTester tester, String host) async {
  await tester.enterText(find.byKey(const Key('profile-editor-host')), host);
  await tester.pumpAndSettle();
}

/// Seed [profiles] + [vaultEntries], then open the editor on [editHost].
/// Returns the stores so a test can read back what Save wrote.
Future<({ProfilesStore profiles, SecretsStore secrets, KeysStore keys})> _pump(
  WidgetTester tester, {
  required List<SavedProfile> profiles,
  Map<String, Map<String, Object?>> vaultEntries = const {},
  List<SavedKey> libraryKeys = const [],
  required String editHost,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final store = ProfilesStore();
  await store.save(profiles);
  final secrets = SecretsStore(backend: InMemorySecretsBackend());
  for (final entry in vaultEntries.entries) {
    await secrets.write(entry.key, entry.value);
  }
  final keysStore = KeysStore();
  for (final k in libraryKeys) {
    await keysStore.upsert(k);
  }

  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final loaded = await store.load();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        profilesStoreProvider.overrideWithValue(store),
        secretsStoreProvider.overrideWithValue(secrets),
        keysStoreProvider.overrideWithValue(keysStore),
      ],
      child: MaterialApp(
        home: ProfileEditor(
          profile: loaded.firstWhere((p) => p.host == editHost),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (profiles: store, secrets: secrets, keys: keysStore);
}

SavedProfile _passwordProfile({String host = 'old.example'}) => SavedProfile(
      title: 'Box',
      host: host,
      port: 22,
      username: 'me',
      authType: 'password',
      vaultId: _oldPasswordVaultId,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('#1138 — the password handle does not follow a rename', () {
    testWidgets('an identity edit with no re-entry detaches vaultId',
        (tester) async {
      final stores = await _pump(
        tester,
        profiles: [_passwordProfile()],
        vaultEntries: {
          _oldPasswordVaultId: <String, Object?>{'password': 'old-secret'},
        },
        editHost: 'old.example',
      );

      await _setHost(tester, 'new.example');
      await _tapSave(tester);

      final saved =
          (await stores.profiles.load()).firstWhere((p) => p.host == 'new.example');
      expect(
        saved.vaultId,
        isNull,
        reason: "the OLD host's password must not be sent to the new one",
      );
    });

    testWidgets('the detached secret is NOT deleted from the vault',
        (tester) async {
      final stores = await _pump(
        tester,
        profiles: [_passwordProfile()],
        vaultEntries: {
          _oldPasswordVaultId: <String, Object?>{'password': 'old-secret'},
        },
        editHost: 'old.example',
      );

      await _setHost(tester, 'new.example');
      await _tapSave(tester);

      final blob = await stores.secrets.read(_oldPasswordVaultId);
      expect(
        blob?['password'],
        'old-secret',
        reason: 'detach the handle only — the old identity may still be in '
            'use, and destroying a credential on a rename is a worse bug',
      );
    });

    testWidgets('a save that does NOT touch the identity keeps the handle',
        (tester) async {
      final stores = await _pump(
        tester,
        profiles: [_passwordProfile()],
        vaultEntries: {
          _oldPasswordVaultId: <String, Object?>{'password': 'old-secret'},
        },
        editHost: 'old.example',
      );

      await tester.enterText(
        find.byKey(const Key('profile-editor-title')),
        'Renamed label only',
      );
      await _tapSave(tester);

      final saved = (await stores.profiles.load()).single;
      expect(saved.title, 'Renamed label only');
      expect(
        saved.vaultId,
        _oldPasswordVaultId,
        reason: 'same host/port/user — the credential still belongs here',
      );
    });

    testWidgets('re-entering the password mints a handle for the NEW identity',
        (tester) async {
      final stores = await _pump(
        tester,
        profiles: [_passwordProfile()],
        vaultEntries: {
          _oldPasswordVaultId: <String, Object?>{'password': 'old-secret'},
        },
        editHost: 'old.example',
      );

      await _setHost(tester, 'new.example');
      await tester.enterText(
        find.byKey(const Key('profile-editor-password')),
        'new-secret',
      );
      await _tapSave(tester);

      final saved =
          (await stores.profiles.load()).firstWhere((p) => p.host == 'new.example');
      expect(saved.vaultId, 'profile-new.example:22:me');

      final fresh = await stores.secrets.read('profile-new.example:22:me');
      expect(fresh?['password'], 'new-secret');
      // The old blob is untouched, under its own id.
      final old = await stores.secrets.read(_oldPasswordVaultId);
      expect(old?['password'], 'old-secret');
    });
  });

  group('#1138 — library keys stay, profile-scoped key blobs detach', () {
    testWidgets('a LIBRARY key survives an identity edit', (tester) async {
      const libraryKey = SavedKey(id: 'k1', name: 'work', createdAtMs: 1);
      final stores = await _pump(
        tester,
        profiles: [
          SavedProfile(
            title: 'Box',
            host: 'old.example',
            port: 22,
            username: 'me',
            authType: 'key',
            keyVaultId: libraryKey.vaultId,
          ),
        ],
        vaultEntries: {
          libraryKey.vaultId: <String, Object?>{'data': 'PEM'},
        },
        libraryKeys: const [libraryKey],
        editHost: 'old.example',
      );

      await _setHost(tester, 'new.example');
      await _tapSave(tester);

      final saved =
          (await stores.profiles.load()).firstWhere((p) => p.host == 'new.example');
      expect(
        saved.keyVaultId,
        libraryKey.vaultId,
        reason: 'a library key is reusable across hosts by design (#1088)',
      );
    });

    testWidgets('a profile-scoped key blob detaches but is not deleted',
        (tester) async {
      final stores = await _pump(
        tester,
        profiles: [
          SavedProfile(
            title: 'Box',
            host: 'old.example',
            port: 22,
            username: 'me',
            authType: 'key',
            keyVaultId: _oldKeyVaultId,
          ),
        ],
        vaultEntries: {
          _oldKeyVaultId: <String, Object?>{'data': 'PEM'},
        },
        editHost: 'old.example',
      );

      await _setHost(tester, 'new.example');
      await _tapSave(tester);

      final saved =
          (await stores.profiles.load()).firstWhere((p) => p.host == 'new.example');
      expect(
        saved.keyVaultId,
        isNull,
        reason: 'a `profile-…` handle was minted for ONE identity',
      );
      final blob = await stores.secrets.read(_oldKeyVaultId);
      expect(blob?['data'], 'PEM', reason: 'detach only, never delete');
    });

    testWidgets('re-selecting a key in the same save keeps it attached',
        (tester) async {
      const libraryKey = SavedKey(id: 'k1', name: 'work', createdAtMs: 1);
      final stores = await _pump(
        tester,
        profiles: [
          SavedProfile(
            title: 'Box',
            host: 'old.example',
            port: 22,
            username: 'me',
            authType: 'key',
            keyVaultId: _oldKeyVaultId,
          ),
        ],
        vaultEntries: {
          _oldKeyVaultId: <String, Object?>{'data': 'PEM'},
          libraryKey.vaultId: <String, Object?>{'data': 'LIB-PEM'},
        },
        libraryKeys: const [libraryKey],
        editHost: 'old.example',
      );

      await _setHost(tester, 'new.example');
      // Deliberately pick a key for the new host.
      final picker = find.byKey(const Key('profile-editor-key-source'));
      await tester.ensureVisible(picker);
      await tester.pumpAndSettle();
      await tester.tap(picker);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Library: work').last);
      await tester.pumpAndSettle();
      await _tapSave(tester);

      final saved =
          (await stores.profiles.load()).firstWhere((p) => p.host == 'new.example');
      expect(
        saved.keyVaultId,
        libraryKey.vaultId,
        reason: 'the user re-selected a key in the same save',
      );
    });
  });

  group('#1138 + #1183 R5 — rename rebinds referrers AND detaches', () {
    testWidgets('one save does both', (tester) async {
      final stores = await _pump(
        tester,
        profiles: [
          _passwordProfile(),
          SavedProfile(
            title: 'App',
            host: 'app.example',
            port: 22,
            username: 'me',
            authType: 'password',
            jumpIdentityKey: 'old.example:22:me',
          ),
        ],
        vaultEntries: {
          _oldPasswordVaultId: <String, Object?>{'password': 'old-secret'},
        },
        editHost: 'old.example',
      );

      await _setHost(tester, 'new.example');
      await _tapSave(tester);

      final list = await stores.profiles.load();
      final renamed = list.firstWhere((p) => p.host == 'new.example');
      final referrer = list.firstWhere((p) => p.host == 'app.example');
      expect(
        referrer.jumpIdentityKey,
        'new.example:22:me',
        reason: '#1183 R5 — referrers follow the rename',
      );
      expect(renamed.vaultId, isNull, reason: '#1138 — the credential does not');
      expect(
        (await stores.secrets.read(_oldPasswordVaultId))?['password'],
        'old-secret',
      );
    });
  });

  group('#1138 — the editor says so, persistently, where the action is', () {
    testWidgets('no notice until the identity actually changes', (tester) async {
      await _pump(
        tester,
        profiles: [_passwordProfile()],
        vaultEntries: {
          _oldPasswordVaultId: <String, Object?>{'password': 'old-secret'},
        },
        editHost: 'old.example',
      );

      expect(find.byKey(_noticeKey), findsNothing);

      await tester.enterText(
        find.byKey(const Key('profile-editor-title')),
        'Label only',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(_noticeKey),
        findsNothing,
        reason: 'a metadata edit detaches nothing',
      );
    });

    testWidgets('editing the host shows a notice that PERSISTS', (tester) async {
      await _pump(
        tester,
        profiles: [_passwordProfile()],
        vaultEntries: {
          _oldPasswordVaultId: <String, Object?>{'password': 'old-secret'},
        },
        editHost: 'old.example',
      );

      await _setHost(tester, 'new.example');
      expect(find.byKey(_noticeKey), findsOneWidget);

      // A toast would be gone by now; this guidance must still be readable
      // (feedback_actionable_guidance_not_toast).
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(
        find.byKey(_noticeKey),
        findsOneWidget,
        reason: 'the notice must not vanish on a timer',
      );

      // ...and it survives unrelated edits elsewhere in the form.
      await tester.enterText(
        find.byKey(const Key('profile-editor-title')),
        'Moved box',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(_noticeKey), findsOneWidget);
    });

    testWidgets('re-entering the password clears the notice', (tester) async {
      await _pump(
        tester,
        profiles: [_passwordProfile()],
        vaultEntries: {
          _oldPasswordVaultId: <String, Object?>{'password': 'old-secret'},
        },
        editHost: 'old.example',
      );

      await _setHost(tester, 'new.example');
      expect(find.byKey(_noticeKey), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('profile-editor-password')),
        'new-secret',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(_noticeKey),
        findsNothing,
        reason: 'nothing is detached once a credential is entered for the '
            'new identity',
      );
    });

    testWidgets('a profile with no stored credential gets no notice',
        (tester) async {
      await _pump(
        tester,
        profiles: [
          SavedProfile(
            title: 'Box',
            host: 'old.example',
            port: 22,
            username: 'me',
            authType: 'password',
          ),
        ],
        editHost: 'old.example',
      );

      await _setHost(tester, 'new.example');
      expect(find.byKey(_noticeKey), findsNothing);
    });
  });
}
