// Widget tests for the #611 Part A home reshape, updated for the #897 settings
// reorg:
//   - The home view is JUST the profile chooser + New + Import. Settings and
//     Diagnostics are NO LONGER inline disclosures on the profile list.
//   - A bottom navigation bar exposes Profiles + Settings (#897: the separate
//     Diagnostics tab is GONE — diagnostics fold into the single Settings page).
//   - Tapping Settings shows the FLAT Settings content (keepalive toggle visible
//     with no expander tap) AND the folded-in Diagnostics section (connect-log
//     block, the #543 connect-trace viewer).
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

  testWidgets('bottom nav exposes Profiles + Settings (no Diagnostics tab)', (
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
    // #897: the standalone Diagnostics destination is gone.
    expect(find.byKey(const Key('home-nav-diagnostics')), findsNothing);
  });

  testWidgets('tapping Settings shows the FLAT Settings content (no expander)', (
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

    // #897: the keepalive toggle is a TOP-LEVEL control — visible with NO
    // expander tap (the old self-collapsing ExpansionTile is gone).
    expect(find.byKey(const ValueKey('settings-section')), findsOneWidget);
    expect(find.byKey(const ValueKey('keepalive-toggle')), findsOneWidget);
  });

  testWidgets('Settings page folds in the Diagnostics section', (
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

    // #897: Diagnostics is folded into the single Settings page; its controls are
    // present without any expander tap (may be below the fold — assert presence,
    // not on-screen position). The raw connect-log block was removed (it's
    // captured at Feedback-submit instead) — assert a durable diagnostics control.
    expect(find.byKey(const ValueKey('diagnostics-section')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('connection-audit-button')),
      findsOneWidget,
    );
  });
}
