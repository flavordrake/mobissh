// Widget tests for the #611 Part A home reshape:
//   - The home view is JUST the profile chooser + New + Import. Settings and
//     Diagnostics are NO LONGER inline disclosures on the profile list.
//   - A bottom navigation bar exposes Settings + Diagnostics destinations.
//   - Tapping Settings shows the moved Settings content (keepalive toggle).
//   - Tapping Diagnostics shows the moved Diagnostics content (connect-log tile,
//     the #543 connect-trace viewer).
//
// Sessions are proxy-backed; taskSshGatewayProvider is overridden with an
// in-memory gateway pair so building the chooser doesn't bind to platform
// statics.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/main.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';

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

Future<void> _pumpHome(WidgetTester tester, ProviderContainer container) async {
  // Tall surface so the bottom nav + content are fully laid out.
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ConnectHomePage()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('home profile view has no inline Settings/Diagnostics sections', (
    tester,
  ) async {
    final store = ProfilesStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    final pair = InMemoryGatewayPair();
    addTearDown(() async => pair.dispose());
    final container = _container(store: store, secrets: secrets, pair: pair);
    addTearDown(container.dispose);

    await _pumpHome(tester, container);

    // The profile chooser still has its core affordances.
    expect(find.byKey(const Key('new-connection')), findsOneWidget);
    expect(
      find.byKey(const Key('open-import-profiles-dialog')),
      findsOneWidget,
    );

    // The inline Settings + Diagnostics disclosures are GONE from the profile
    // list (they moved to their own bottom-nav views).
    expect(find.byKey(const ValueKey('settings-section')), findsNothing);
    expect(find.byKey(const ValueKey('diagnostics-section')), findsNothing);
  });

  testWidgets('bottom nav exposes Settings + Diagnostics destinations', (
    tester,
  ) async {
    final store = ProfilesStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    final pair = InMemoryGatewayPair();
    addTearDown(() async => pair.dispose());
    final container = _container(store: store, secrets: secrets, pair: pair);
    addTearDown(container.dispose);

    await _pumpHome(tester, container);

    expect(find.byKey(const Key('home-bottom-nav')), findsOneWidget);
    expect(find.byKey(const Key('home-nav-profiles')), findsOneWidget);
    expect(find.byKey(const Key('home-nav-settings')), findsOneWidget);
    expect(find.byKey(const Key('home-nav-diagnostics')), findsOneWidget);
  });

  testWidgets('tapping Settings shows the moved Settings content', (
    tester,
  ) async {
    final store = ProfilesStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    final pair = InMemoryGatewayPair();
    addTearDown(() async => pair.dispose());
    final container = _container(store: store, secrets: secrets, pair: pair);
    addTearDown(container.dispose);

    await _pumpHome(tester, container);

    await tester.tap(find.byKey(const Key('home-nav-settings')));
    await tester.pumpAndSettle();

    // The Settings section (with the keepalive toggle inside) is now shown.
    expect(find.byKey(const ValueKey('settings-section')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-section')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('keepalive-toggle')), findsOneWidget);
  });

  testWidgets('tapping Diagnostics shows the moved connect-log viewer', (
    tester,
  ) async {
    final store = ProfilesStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    final pair = InMemoryGatewayPair();
    addTearDown(() async => pair.dispose());
    final container = _container(store: store, secrets: secrets, pair: pair);
    addTearDown(container.dispose);

    await _pumpHome(tester, container);

    await tester.tap(find.byKey(const Key('home-nav-diagnostics')));
    await tester.pumpAndSettle();

    // The Diagnostics section is shown; expanding it surfaces the #543
    // connect-log viewer that moved here from the home form.
    expect(find.byKey(const ValueKey('diagnostics-section')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('diagnostics-section')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('connect-log-tile')), findsOneWidget);
  });
}
