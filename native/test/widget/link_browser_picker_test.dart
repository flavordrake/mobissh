// #1197 (slice 2 of #1195) — the two browser PICKERS. Spec:
// `docs/link-browser-routing.md` R6/R7/R13, test A8.
//
// PINNED KEYS / STRINGS:
//   Key('settings-link-browser')       — the GLOBAL default picker (Settings →
//       Detection). DropdownButton<String?>; null = 'System default'.
//   Key('profile-editor-link-browser') — the per-profile override, on the
//       Details tab with the other behaviour fields. DropdownButton<String?>;
//       null = 'Use the global default'.
//
// A8: both list every ENUMERATED browser plus the right "default" option, and
// an EMPTY enumeration hides the control ENTIRELY — no dead affordance (the
// rule slice 1 of #1153 followed).
//
// KNOWN COVERAGE LIMIT: the fleet emulator image ships exactly ONE browser, so
// multi-entry picker behaviour cannot be proven on device. It is proven here
// against slice 1's `FakeBrowserTargets`.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/services/browser_targets.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/ui/profile_editor.dart';
import 'package:mobissh/ui/settings_panel.dart';

const _settingsKey = Key('settings-link-browser');
const _profileKey = Key('profile-editor-link-browser');

const _chrome = BrowserTarget(
  package: 'com.android.chrome',
  label: 'Chrome',
  isDefault: true,
);
const _prisma = BrowserTarget(package: 'com.work.prisma', label: 'Prisma');

List<String?> _optionValues(WidgetTester tester, Key key) =>
    tester.widget<DropdownButton<String?>>(find.byKey(key))
        .items!
        .map((i) => i.value)
        .toList();

Future<void> _pumpSettings(
  WidgetTester tester,
  List<BrowserTarget> targets,
) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  tester.view.physicalSize = const Size(1000, 3600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        browserTargetsProvider.overrideWithValue(
          FakeBrowserTargets(targets: targets),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SettingsPanel(versionResolver: () async => 'test+0'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<ProfilesStore> _pumpEditor(
  WidgetTester tester,
  List<BrowserTarget> targets, {
  String? stored,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final store = ProfilesStore();
  await store.save([
    SavedProfile(
      title: 'work',
      host: 'work.example',
      port: 22,
      username: 'me',
      authType: 'password',
      linkBrowserPackage: stored,
    ),
  ]);
  final secrets = SecretsStore(backend: InMemorySecretsBackend());

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
        browserTargetsProvider.overrideWithValue(
          FakeBrowserTargets(targets: targets),
        ),
      ],
      child: MaterialApp(home: ProfileEditor(profile: loaded.single)),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('A8 — the GLOBAL picker (R6)', () {
    testWidgets('lists every enumerated browser plus "System default"',
        (tester) async {
      await _pumpSettings(tester, const [_chrome, _prisma]);

      expect(find.byKey(_settingsKey), findsOneWidget);
      expect(
        _optionValues(tester, _settingsKey),
        [null, 'com.android.chrome', 'com.work.prisma'],
      );
      expect(find.text('System default'), findsWidgets);
    });

    testWidgets('an EMPTY enumeration hides the control entirely',
        (tester) async {
      await _pumpSettings(tester, const []);
      expect(find.byKey(_settingsKey), findsNothing);
    });

    testWidgets('choosing a browser persists it', (tester) async {
      await _pumpSettings(tester, const [_chrome, _prisma]);

      await tester.ensureVisible(find.byKey(_settingsKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_settingsKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prisma').last);
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('mobissh.detection.settings'),
        contains('com.work.prisma'),
      );
    });
  });

  group('A8 — the PER-PROFILE picker (R7/R13)', () {
    testWidgets('lists every enumerated browser plus the global-default option',
        (tester) async {
      await _pumpEditor(tester, const [_chrome, _prisma]);

      expect(find.byKey(_profileKey), findsOneWidget);
      expect(
        _optionValues(tester, _profileKey),
        [null, 'com.android.chrome', 'com.work.prisma'],
      );
      expect(find.text('Use the global default'), findsWidgets);
    });

    testWidgets('an EMPTY enumeration hides the control entirely',
        (tester) async {
      await _pumpEditor(tester, const []);
      expect(find.byKey(_profileKey), findsNothing);
    });

    testWidgets('seeds its value from the stored package', (tester) async {
      await _pumpEditor(
        tester,
        const [_chrome, _prisma],
        stored: 'com.work.prisma',
      );
      expect(
        tester.widget<DropdownButton<String?>>(find.byKey(_profileKey)).value,
        'com.work.prisma',
      );
    });

    testWidgets('R13: a profile on the global default shows no extra chrome',
        (tester) async {
      await _pumpEditor(tester, const [_chrome, _prisma]);
      expect(
        tester.widget<DropdownButton<String?>>(find.byKey(_profileKey)).value,
        isNull,
      );
    });

    testWidgets('choosing a browser saves the PACKAGE, never the label',
        (tester) async {
      final store = await _pumpEditor(tester, const [_chrome, _prisma]);

      await tester.ensureVisible(find.byKey(_profileKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_profileKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prisma').last);
      await tester.pumpAndSettle();

      final save = find.byKey(const Key('profile-editor-save'));
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect((await store.load()).single.linkBrowserPackage, 'com.work.prisma');
    });

    testWidgets(
      'R12: a stored package that is NOT installed stays selected and saved',
      (tester) async {
        final store = await _pumpEditor(
          tester,
          const [_chrome],
          stored: 'com.uninstalled.browser',
        );
        // The picker cannot show a value it has no item for — but the editor
        // must NOT silently rewrite the profile. Saving without touching the
        // picker leaves the stored package intact.
        final save = find.byKey(const Key('profile-editor-save'));
        await tester.ensureVisible(save);
        await tester.pumpAndSettle();
        await tester.tap(save);
        await tester.pumpAndSettle();

        expect(
          (await store.load()).single.linkBrowserPackage,
          'com.uninstalled.browser',
        );
      },
    );
  });
}
