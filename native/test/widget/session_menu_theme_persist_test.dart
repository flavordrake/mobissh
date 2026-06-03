// #724 — the session-menu theme PICKER persists the chosen palette onto the
// ACTIVE session's PROFILE (mirrors the #679 font-family picker + #640 font
// stepper). Picking a theme must:
//   - set the in-memory per-session palette (live render), AND
//   - upsert the palette's PWA theme KEY onto the matching saved profile.
// Per-session/per-profile isolation: a sibling profile's stored theme is
// untouched; an ad-hoc connect with no matching saved profile must NOT
// materialize one.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/ui_prefs_providers.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/ui/session_menu.dart';

Widget _host({required ProviderContainer container}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              key: const Key('open-menu'),
              onPressed: () => showSessionMenu(ctx),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

ProviderContainer _makeContainer(ProfilesStore store) {
  final pair = InMemoryGatewayPair();
  final container = ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      profilesStoreProvider.overrideWithValue(store),
    ],
  );
  addTearDown(() async {
    await pair.dispose();
  });
  addTearDown(container.dispose);
  return container;
}

SessionEntry _add(ProviderContainer c, String host, String user) {
  return c
      .read(sessionsProvider.notifier)
      .addOrActivate(
        SshConnectParams(
          host: host,
          port: 22,
          username: user,
          auth: const SshAuth.password('p'),
        ),
      );
}

Future<void> _pumpFrames(WidgetTester tester, {int count = 12}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('picking a theme persists onto the active profile (#724)', (
    tester,
  ) async {
    final store = ProfilesStore();
    await store.save(<SavedProfile>[
      SavedProfile(title: 'A', host: 'host-a', port: 22, username: 'u'),
      SavedProfile(title: 'B', host: 'host-b', port: 22, username: 'u'),
    ]);
    final container = _makeContainer(store);
    final a = _add(container, 'host-a', 'u');
    final b = _add(container, 'host-b', 'u'); // b active

    await tester.pumpWidget(_host(container: container));
    await tester.tap(find.byKey(const Key('open-menu')));
    await _pumpFrames(tester);

    await tester.tap(find.byKey(const Key('session-menu-theme-cycle')));
    await _pumpFrames(tester);
    // Pick palette index 2.
    await tester.tap(find.byKey(const Key('picker-option-2')));
    await _pumpFrames(tester);

    expect(
      container.read(sessionThemeProvider(b.id)),
      2,
      reason: 'active session palette set to the picked one',
    );
    expect(
      container.read(sessionThemeProvider(a.id)),
      terminalThemeDefault,
      reason: 'sibling session palette untouched (per-session isolation)',
    );

    final loaded = await store.load();
    final profA = loaded.firstWhere((p) => p.host == 'host-a');
    final profB = loaded.firstWhere((p) => p.host == 'host-b');
    expect(
      profB.theme,
      terminalPalettes[2].key,
      reason: 'active session theme KEY persisted onto its profile',
    );
    expect(
      profA.theme,
      isNull,
      reason: 'the other profile must be untouched (per-profile isolation)',
    );
  });

  testWidgets(
    'picking a theme on an ad-hoc session creates no profile (#724)',
    (tester) async {
      final store = ProfilesStore(); // empty — no saved profiles
      final container = _makeContainer(store);
      _add(container, 'adhoc.example', 'u'); // active, not saved

      await tester.pumpWidget(_host(container: container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      await tester.tap(find.byKey(const Key('session-menu-theme-cycle')));
      await _pumpFrames(tester);
      await tester.tap(find.byKey(const Key('picker-option-2')));
      await _pumpFrames(tester);

      final loaded = await store.load();
      expect(
        loaded,
        isEmpty,
        reason:
            'picking a theme on an ad-hoc session must not materialize a saved '
            'profile',
      );
    },
  );
}
