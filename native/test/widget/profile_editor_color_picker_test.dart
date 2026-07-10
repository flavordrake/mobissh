// Profile editor ↔ shared color picker wiring (#1030).
//
// The editor's color section replaces the bare hex TextField with:
//   - one-tap preset chips (the shared quick swatches)
//   - a custom-color affordance opening the shared picker sheet
//   - the hex field retained (same 'profile-editor-color' key) as the
//     backing value the save path already persists (SavedProfile.color)
//
// Asserts the full persistence loop: preset tap → save → store colorHex, and
// picker Apply → save → store colorHex. No storage change — same _colorCtrl
// path as before.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/ui/color_picker_sheet.dart';
import 'package:mobissh/ui/profile_editor.dart';

Future<ProfilesStore> _pump(
  WidgetTester tester, {
  String? color,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final store = ProfilesStore();
  await store.save(<SavedProfile>[
    SavedProfile(
      title: 'Box',
      host: 'home.example',
      port: 22,
      username: 'me',
      authType: 'password',
      color: color,
    ),
  ]);
  final secrets = SecretsStore(backend: InMemorySecretsBackend());

  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        profilesStoreProvider.overrideWithValue(store),
        secretsStoreProvider.overrideWithValue(secrets),
      ],
      child: MaterialApp(home: ProfileEditor(profile: (await store.load()).first)),
    ),
  );
  await tester.pumpAndSettle();
  return store;
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

  group('ProfileEditor color section (#1030)', () {
    testWidgets('renders one-tap preset chips for the shared swatches', (
      tester,
    ) async {
      await _pump(tester, color: '#ff8800');
      expect(
        find.byKey(const Key('profile-editor-color-presets')),
        findsOneWidget,
      );
      for (final preset in colorPickerPresets) {
        expect(
          find.byKey(
            Key('profile-editor-color-preset-${hexFromColor(preset)}'),
          ),
          findsOneWidget,
        );
      }
    });

    testWidgets('preset chip tap fills the hex field and Save persists it', (
      tester,
    ) async {
      final store = await _pump(tester, color: '#ff8800');

      final preset = colorPickerPresets.first;
      final hex = hexFromColor(preset);
      final chip = find.byKey(Key('profile-editor-color-preset-$hex'));
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.byKey(const Key('profile-editor-color')),
      );
      expect(field.controller?.text, hex);

      await _tapSave(tester);
      expect((await store.load()).first.color, hex);
    });

    testWidgets('custom picker Apply fills the hex field and Save persists', (
      tester,
    ) async {
      final store = await _pump(tester, color: '#ff8800');

      final custom = find.byKey(const Key('profile-editor-color-custom'));
      await tester.ensureVisible(custom);
      await tester.pumpAndSettle();
      await tester.tap(custom);
      await tester.pumpAndSettle();

      // Shared picker opens, seeded from the profile color.
      expect(find.byKey(const Key('color-picker-panel')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('color-picker-hex')))
            .controller
            ?.text,
        '#ff8800',
      );

      await tester.enterText(
        find.byKey(const Key('color-picker-hex')),
        '#123456',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('color-picker-apply')));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.byKey(const Key('profile-editor-color')),
      );
      expect(field.controller?.text, '#123456');

      await _tapSave(tester);
      expect((await store.load()).first.color, '#123456');
    });

    testWidgets('picker Clear empties the color (falls back to theme accent)', (
      tester,
    ) async {
      final store = await _pump(tester, color: '#ff8800');

      final custom = find.byKey(const Key('profile-editor-color-custom'));
      await tester.ensureVisible(custom);
      await tester.pumpAndSettle();
      await tester.tap(custom);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('color-picker-clear')));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.byKey(const Key('profile-editor-color')),
      );
      expect(field.controller?.text, isEmpty);

      await _tapSave(tester);
      expect((await store.load()).first.color, isNull);
    });
  });
}
