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

  // #594: the action bar (Save & connect / Save) must stay reachable with the
  // soft keyboard UP. The save-semantics tests above use a 1000x2000 surface
  // with NO keyboard inset — that's the false green this group exists to catch.
  // Here we pump at a realistic phone size AND inject a keyboard inset via a
  // MediaQuery override, then assert both action buttons are hit-testable and
  // their centers fall ABOVE the keyboard inset (inside the visible viewport).
  group('ProfileEditor action bar — keyboard safety (#594)', () {
    // Logical phone-ish viewport (dpr 1 for simple px==logical math).
    const screenSize = Size(360, 800);
    // A soft keyboard typically eats ~40% of the height; 360 here is well
    // within that and mirrors the device failure (connect-submit was at dy~794
    // on an ~800-tall screen, i.e. behind the keyboard).
    const keyboardHeight = 360.0;

    Future<void> pumpWithKeyboard(
      WidgetTester tester, {
      required bool isNew,
    }) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = ProfilesStore();
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      final profile = SavedProfile(
        title: 'Box',
        host: 'home.example',
        port: 22,
        username: 'me',
        authType: 'key',
      );

      tester.view.physicalSize = screenSize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            profilesStoreProvider.overrideWithValue(store),
            secretsStoreProvider.overrideWithValue(secrets),
          ],
          child: MaterialApp(
            // Simulate the soft keyboard occupying the lower viewport. This is
            // what the tall-surface tests omitted, producing a false green.
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  viewInsets: const EdgeInsets.only(bottom: keyboardHeight),
                ),
                child: ProfileEditor(profile: profile, isNew: isNew),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    void expectButtonReachable(WidgetTester tester, Key key) {
      final finder = find.byKey(key);
      expect(finder, findsOneWidget, reason: '$key must be present');

      final center = tester.getCenter(finder);
      // Must be on-screen horizontally/vertically...
      expect(
        center.dy,
        greaterThan(0),
        reason: '$key center must be on-screen (dy>0)',
      );
      // ...and ABOVE the keyboard: its center must sit in the visible area, not
      // behind the keyboard inset. This is the exact device failure (#594):
      // connect-submit derived an offset inside the keyboard band → no hit test.
      expect(
        center.dy,
        lessThan(screenSize.height - keyboardHeight),
        reason:
            '$key center (dy=${center.dy}) is behind the keyboard '
            '(visible area ends at ${screenSize.height - keyboardHeight}) — '
            'it would not hit-test on a real device',
      );

      // And it must actually pass a hit test at its center (no occluding
      // widget, not off-screen) — tap should reach the button, not throw.
      final result = tester.hitTestOnBinding(center);
      final hit = result.path.any((entry) => entry.target is RenderBox);
      expect(
        hit,
        isTrue,
        reason: '$key must be hit-testable at its center with the keyboard up',
      );
    }

    testWidgets('connect-submit is reachable above the keyboard (new mode)', (
      tester,
    ) async {
      await pumpWithKeyboard(tester, isNew: true);
      expectButtonReachable(tester, const Key('connect-submit'));
    });

    testWidgets('Save is reachable above the keyboard (edit mode)', (
      tester,
    ) async {
      await pumpWithKeyboard(tester, isNew: false);
      expectButtonReachable(tester, const Key('profile-editor-save'));
    });

    testWidgets('both actions live in the fixed footer above the keyboard', (
      tester,
    ) async {
      await pumpWithKeyboard(tester, isNew: true);
      expect(
        find.byKey(const Key('profile-editor-action-bar')),
        findsOneWidget,
      );
      expectButtonReachable(tester, const Key('connect-submit'));
      expectButtonReachable(tester, const Key('profile-editor-save'));
    });
  });
}
