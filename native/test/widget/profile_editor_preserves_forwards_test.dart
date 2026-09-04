// Profile editor Save must NOT wipe fields it does not edit.
//
// Owner report (rc.4, 2026-09-04): "Forwards are still not persisting from
// session to session." One root: the editor rebuilt `SavedProfile` from its
// own controllers only, so any Save (title tweak, the #1118 "Save & connect"
// migration flow, a key attach) silently dropped `forwards`, `fontSize` and
// `fontFamily`. `ProfilesStore.upsert` replaces the whole entry — callers
// must carry every field.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/ui/profile_editor.dart';

Future<void> _pump(
  WidgetTester tester, {
  required ProfilesStore store,
  required SecretsStore secrets,
  required SavedProfile profile,
}) async {
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

Future<void> _tapSave(WidgetTester tester) async {
  final save = find.byKey(const Key('profile-editor-save'));
  await tester.ensureVisible(save);
  await tester.pumpAndSettle();
  await tester.tap(save);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Save preserves forwards, fontSize and fontFamily', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final store = ProfilesStore();
    await store.save(<SavedProfile>[
      SavedProfile(
        title: 'Box',
        host: 'home.example',
        port: 22,
        username: 'me',
        authType: 'password',
        fontSize: 18,
        fontFamily: 'JetBrainsMono',
        forwards: const [
          ProfileForward(
            localPort: 8080,
            remoteHost: '127.0.0.1',
            remotePort: 80,
          ),
          ProfileForward(
            localPort: 5432,
            remoteHost: 'db.internal',
            remotePort: 5432,
          ),
        ],
      ),
    ]);
    final secrets = SecretsStore(backend: InMemorySecretsBackend());

    await _pump(
      tester,
      store: store,
      secrets: secrets,
      profile: (await store.load()).first,
    );

    // An unrelated edit — exactly the kind of Save that wiped the forwards.
    await tester.enterText(
      find.byKey(const Key('profile-editor-title')),
      'Renamed box',
    );
    await _tapSave(tester);

    final saved = (await store.load()).single;
    expect(saved.title, 'Renamed box');
    expect(saved.fontSize, 18);
    expect(saved.fontFamily, 'JetBrainsMono');
    expect(saved.forwards, hasLength(2));
    expect(saved.forwards[0].localPort, 8080);
    expect(saved.forwards[0].remotePort, 80);
    expect(saved.forwards[1].remoteHost, 'db.internal');
  });
}
