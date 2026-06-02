// Widget tests for ConnectForm — the profile chooser/connect view (#505 backfill).
//
// ConnectForm is the decluttered profile CHOOSER (#583): a saved-profile list
// (tap = connect, pencil = edit) plus a one-row "New connection" + "Import"
// affordance (#672). It is NOT an inline host/port/username/password FORM — that
// was removed in #583 (and its absence is locked by profile_chooser_test.dart).
//
// Existing coverage already locks: the chooser render + no-inline-form
// (profile_chooser_test), tap-to-connect (profile_tap_connect_test), inline
// failure (connect_error_surfaced_test), fill/one-row layout
// (profile_chooser_fill_test), and the New-session route (new_session_affordance_test).
//
// This file fills the remaining gaps without duplicating those:
//   1. The saved-profile rows render keyed per host:port:username, so tapping a
//      row dispatches connect for THAT profile (the chooser's primary action).
//   2. The "Import" affordance OPENS the import-from-PWA dialog (the second
//      action on the New/Import row) — previously only asserted as present, not
//      that tapping it opens its flow.
//
// Uses the InMemoryGatewayPair / ProviderContainer harness so the connect path
// runs without binding to platform statics or a real network.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/ui/connect_form.dart';

Future<void> _pumpFrames(WidgetTester tester, {int count = 12}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

ProviderContainer _container({
  required ProfilesStore store,
  required SecretsStore secrets,
  required InMemoryGatewayPair pair,
}) {
  return ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      profilesStoreProvider.overrideWithValue(store),
      secretsStoreProvider.overrideWithValue(secrets),
    ],
  );
}

Future<void> _pumpChooser(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: ConnectForm())),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('renders saved-profile rows + the New/Import action row', (
    tester,
  ) async {
    // Tall surface so the whole action row is laid out.
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final store = ProfilesStore();
    await store.save(<SavedProfile>[
      SavedProfile(
        title: 'Alpha',
        host: 'alpha.example',
        port: 22,
        username: 'a',
      ),
      SavedProfile(
        title: 'Beta',
        host: 'beta.example',
        port: 2200,
        username: 'b',
      ),
    ]);
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    final pair = InMemoryGatewayPair();
    addTearDown(() async => pair.dispose());
    final container = _container(store: store, secrets: secrets, pair: pair);
    addTearDown(container.dispose);

    await _pumpChooser(tester, container);

    // Each saved profile renders a keyed, tappable row.
    expect(
      find.byKey(const Key('profile-tile-alpha.example:22:a')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('profile-tile-beta.example:2200:b')),
      findsOneWidget,
    );

    // The New/Import action row is present below the list.
    expect(find.byKey(const Key('new-connection')), findsOneWidget);
    expect(
      find.byKey(const Key('open-import-profiles-dialog')),
      findsOneWidget,
    );
  });

  testWidgets(
    'tapping a saved-profile row dispatches connect for that profile',
    (tester) async {
      // Seed two profiles (each with stored creds) and confirm tapping the
      // SECOND one connects with the SECOND profile's params — i.e. the row tap
      // dispatches connect for the row it belongs to, not a fixed profile.
      final store = ProfilesStore();
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      await secrets.write('v-a', <String, Object?>{'password': 'pa'});
      await secrets.write('v-b', <String, Object?>{'password': 'pb'});
      await store.save(<SavedProfile>[
        SavedProfile(
          title: 'Alpha',
          host: 'alpha.example',
          port: 22,
          username: 'a',
          authType: 'password',
          vaultId: 'v-a',
        ),
        SavedProfile(
          title: 'Beta',
          host: 'beta.example',
          port: 2200,
          username: 'b',
          authType: 'password',
          vaultId: 'v-b',
        ),
      ]);
      final pair = InMemoryGatewayPair();
      addTearDown(() async => pair.dispose());
      final container = _container(store: store, secrets: secrets, pair: pair);
      addTearDown(container.dispose);

      await _pumpChooser(tester, container);
      expect(container.read(sessionsProvider).entries, isEmpty);

      await tester.tap(
        find.byKey(const Key('profile-tile-beta.example:2200:b')),
      );
      await _pumpFrames(tester, count: 30);

      final entries = container.read(sessionsProvider).entries;
      expect(entries.length, 1);
      // The session carries the TAPPED row's params, not the other profile's.
      expect(entries.first.host, 'beta.example');
      expect(entries.first.port, 2200);
      expect(entries.first.username, 'b');
      expect(entries.first.title, 'Beta');
    },
  );

  testWidgets('tapping "Import" opens the import-from-PWA dialog', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final store = ProfilesStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    final pair = InMemoryGatewayPair();
    addTearDown(() async => pair.dispose());
    final container = _container(store: store, secrets: secrets, pair: pair);
    addTearDown(container.dispose);

    await _pumpChooser(tester, container);

    // No dialog yet.
    expect(find.byKey(const Key('import-profiles-dialog')), findsNothing);

    await tester.tap(find.byKey(const Key('open-import-profiles-dialog')));
    await tester.pumpAndSettle();

    // The import flow opened.
    expect(find.byKey(const Key('import-profiles-dialog')), findsOneWidget);
    expect(find.text('Import profiles from PWA'), findsOneWidget);

    // Cancel to tear down the route cleanly.
    await tester.tap(find.byKey(const Key('import-profiles-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('import-profiles-dialog')), findsNothing);
  });
}
