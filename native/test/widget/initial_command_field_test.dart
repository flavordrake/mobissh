// Widget test: the "Initial command" field lives on the profile editor (#558,
// relocated by #583).
//
// History: this used to assert the inline connect form had an initial-command
// field and that tapping a profile prefilled it. #583 removed the inline form;
// the editor is now the new/ad-hoc connection entry, so the initial-command
// field lives there. These tests lock:
//   1. The editor renders an initial-command field.
//   2. Editing a profile that carries an `initialCommand` prefills it.
//   3. A profile without an `initialCommand` leaves the field empty.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/ui/profile_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _editorApp(SavedProfile profile) {
  return ProviderScope(
    overrides: [
      profilesStoreProvider.overrideWithValue(ProfilesStore()),
      secretsStoreProvider.overrideWithValue(
        SecretsStore(backend: InMemorySecretsBackend()),
      ),
    ],
    child: MaterialApp(home: ProfileEditor(profile: profile)),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('profile editor renders an initial-command field', (
    tester,
  ) async {
    await tester.pumpWidget(_editorApp(blankProfile()));
    await _settle(tester);

    expect(
      find.byKey(const Key('profile-editor-initial-command')),
      findsOneWidget,
    );
  });

  testWidgets('editing a profile prefills its initialCommand', (tester) async {
    final profile = SavedProfile(
      title: 'Box',
      host: 'box.example',
      port: 22,
      username: 'me',
      initialCommand: 'tmux attach || tmux new',
    );
    await tester.pumpWidget(_editorApp(profile));
    await _settle(tester);

    final field = tester.widget<TextField>(
      find.byKey(const Key('profile-editor-initial-command')),
    );
    expect(field.controller?.text, 'tmux attach || tmux new');
  });

  testWidgets('profile without initialCommand leaves the field empty', (
    tester,
  ) async {
    final profile = SavedProfile(
      title: 'Plain',
      host: 'plain.example',
      port: 22,
      username: 'me',
    );
    await tester.pumpWidget(_editorApp(profile));
    await _settle(tester);

    final field = tester.widget<TextField>(
      find.byKey(const Key('profile-editor-initial-command')),
    );
    expect(field.controller?.text, isEmpty);
  });
}
