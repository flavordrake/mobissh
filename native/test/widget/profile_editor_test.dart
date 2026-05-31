// Widget tests for [ProfileEditor] (#579).
//
// Asserts:
//   - the editor pre-populates every field from the profile
//   - editing a metadata field + Save upserts the store (values round-trip)
//   - a credential edit writes via secrets_store (correct vault id) and the
//     plaintext secret NEVER lands in shared_preferences (profiles JSON)

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/ui/profile_editor.dart';

/// Read the current text of a [TextField] by key — robust against duplicate
/// `find.text` matches (e.g. a value that also appears as a label/hint).
String _fieldText(WidgetTester tester, String key) {
  final field = tester.widget<TextField>(find.byKey(Key(key)));
  return field.controller?.text ?? '';
}

/// Scroll the Save button into view, then tap it. `ensureVisible` plus a tall
/// test surface (set in [_pump]) guarantees the FilledButton is hit-testable.
Future<void> _tapSave(WidgetTester tester) async {
  final save = find.byKey(const Key('profile-editor-save'));
  await tester.ensureVisible(save);
  await tester.pumpAndSettle();
  await tester.tap(save);
  await tester.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester tester, {
  required ProfilesStore store,
  required SecretsStore secrets,
  required SavedProfile profile,
}) async {
  // The editor is taller than the default 800x600 surface; grow it so every
  // field + the Save button are laid out on-screen and hit-testable.
  tester.view.physicalSize = const Size(1000, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        profilesStoreProvider.overrideWithValue(store),
        secretsStoreProvider.overrideWithValue(secrets),
      ],
      child: MaterialApp(home: ProfileEditor(profile: profile)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProfileEditor', () {
    testWidgets('pre-populates fields from the profile', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = ProfilesStore();
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      final profile = SavedProfile(
        title: 'Home box',
        host: 'home.example',
        port: 2222,
        username: 'me',
        theme: 'solarizedDark',
        color: '#ff8800',
        authType: 'password',
        initialCommand: 'tmux attach',
      );

      await _pump(tester, store: store, secrets: secrets, profile: profile);

      expect(find.byKey(const Key('profile-editor')), findsOneWidget);
      expect(_fieldText(tester, 'profile-editor-title'), 'Home box');
      expect(_fieldText(tester, 'profile-editor-host'), 'home.example');
      expect(_fieldText(tester, 'profile-editor-port'), '2222');
      expect(_fieldText(tester, 'profile-editor-username'), 'me');
      expect(_fieldText(tester, 'profile-editor-theme'), 'solarizedDark');
      expect(_fieldText(tester, 'profile-editor-color'), '#ff8800');
      expect(
        _fieldText(tester, 'profile-editor-initial-command'),
        'tmux attach',
      );
    });

    testWidgets('editing a metadata field + Save upserts the store', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(
          title: 'Old name',
          host: 'home.example',
          port: 22,
          username: 'me',
          authType: 'password',
        ),
      ]);
      final secrets = SecretsStore(backend: InMemorySecretsBackend());

      await _pump(
        tester,
        store: store,
        secrets: secrets,
        profile: (await store.load()).first,
      );

      // Change the title.
      await tester.enterText(
        find.byKey(const Key('profile-editor-title')),
        'New name',
      );
      await _tapSave(tester);

      final list = await store.load();
      expect(list.length, 1);
      expect(list.first.title, 'New name');
      // Identity unchanged → same host/port/user.
      expect(list.first.identityKey, 'home.example:22:me');
    });

    testWidgets('editing host/port/username renames in place (no duplicate)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(
          title: 'Box',
          host: 'old.example',
          port: 22,
          username: 'me',
          authType: 'password',
        ),
      ]);
      final secrets = SecretsStore(backend: InMemorySecretsBackend());

      await _pump(
        tester,
        store: store,
        secrets: secrets,
        profile: (await store.load()).first,
      );

      await tester.enterText(
        find.byKey(const Key('profile-editor-host')),
        'new.example',
      );
      await _tapSave(tester);

      final list = await store.load();
      expect(list.length, 1, reason: 'rename must not create a duplicate');
      expect(list.first.host, 'new.example');
    });

    testWidgets(
      'a credential edit writes via secrets_store and never plaintext',
      (tester) async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final store = ProfilesStore();
        await store.save(<SavedProfile>[
          SavedProfile(
            title: 'Box',
            host: 'home.example',
            port: 22,
            username: 'me',
            authType: 'password',
          ),
        ]);
        final backend = InMemorySecretsBackend();
        final secrets = SecretsStore(backend: backend);

        await _pump(
          tester,
          store: store,
          secrets: secrets,
          profile: (await store.load()).first,
        );

        const secret = 'hunter2-supersecret';
        await tester.enterText(
          find.byKey(const Key('profile-editor-password')),
          secret,
        );
        await tester.tap(find.byKey(const Key('profile-editor-save')));
        await tester.pumpAndSettle();

        // The saved profile must carry a vaultId reference.
        final saved = (await store.load()).first;
        expect(saved.vaultId, isNotNull);

        // The secret is retrievable from the vault under that id.
        final creds = await loadProfileCredentials(secrets, saved);
        expect(creds.password, secret);

        // SECURITY: the plaintext secret must NOT appear in shared_preferences
        // (the profiles JSON). Only the vault (secure storage) holds it.
        final prefs = await SharedPreferences.getInstance();
        final profilesJson = prefs.getString(profilesPrefsKey) ?? '';
        expect(
          profilesJson.contains(secret),
          isFalse,
          reason: 'plaintext credential must never be in profiles JSON',
        );

        // And the secret IS in the secrets backend (encrypted at rest in prod).
        final all = await backend.readAll();
        final anyHoldsSecret = all.values.any((v) => v.contains(secret));
        expect(
          anyHoldsSecret,
          isTrue,
          reason: 'credential must be written through secrets_store',
        );
      },
    );
  });
}
