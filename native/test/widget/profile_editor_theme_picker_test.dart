// #613 — the profile editor's theme field is a PICKER (dropdown over the full
// palette set), not a raw text field. It shows the palette LABEL and stores the
// PWA theme KEY into SavedProfile.theme. Pre-populates from an existing
// profile.theme.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/state/ui_prefs_providers.dart';
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

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('renders a theme picker (dropdown), not a raw text field', (
    tester,
  ) async {
    final store = ProfilesStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    await _pump(
      tester,
      store: store,
      secrets: secrets,
      profile: SavedProfile(title: 't', host: 'h', port: 22, username: 'u'),
    );

    expect(
      find.byKey(const Key('profile-editor-theme-picker')),
      findsOneWidget,
    );
    expect(
      find.byType(DropdownButton<String>),
      findsWidgets,
      reason: 'theme field must be a dropdown picker',
    );
  });

  testWidgets('pre-populates the picker from an existing profile.theme', (
    tester,
  ) async {
    final store = ProfilesStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    await _pump(
      tester,
      store: store,
      secrets: secrets,
      profile: SavedProfile(
        title: 't',
        host: 'h',
        port: 22,
        username: 'u',
        theme: 'dracula',
      ),
    );

    final dropdown = tester.widget<DropdownButton<String>>(
      find.byKey(const Key('profile-editor-theme-picker')),
    );
    expect(dropdown.value, 'dracula');
  });

  testWidgets('defaults the picker to dark when profile has no theme', (
    tester,
  ) async {
    final store = ProfilesStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    await _pump(
      tester,
      store: store,
      secrets: secrets,
      profile: SavedProfile(title: 't', host: 'h', port: 22, username: 'u'),
    );

    final dropdown = tester.widget<DropdownButton<String>>(
      find.byKey(const Key('profile-editor-theme-picker')),
    );
    expect(dropdown.value, 'dark');
  });

  testWidgets('selecting a theme stores its KEY into the saved profile', (
    tester,
  ) async {
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
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    await _pump(
      tester,
      store: store,
      secrets: secrets,
      profile: (await store.load()).first,
    );

    // Open the dropdown and pick the Nord palette by its label.
    await tester.tap(find.byKey(const Key('profile-editor-theme-picker')));
    await tester.pumpAndSettle();
    final nordLabel = terminalPalettes.firstWhere((p) => p.key == 'nord').label;
    await tester.tap(find.text(nordLabel).last);
    await tester.pumpAndSettle();

    await _tapSave(tester);

    final saved = (await store.load()).first;
    expect(
      saved.theme,
      'nord',
      reason: 'the PWA KEY, not the label, is stored',
    );
  });
}
