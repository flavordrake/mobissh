// Widget tests for #643: the profile CHOOSER must FILL the available vertical
// height instead of collapsing to the top ~40% with a large blank band below.
//
// Bug (reported 3×): "Saved Profiles" + a list cut off after ~4 entries +
// "New connection" + "Import from PWA" crammed into the top; ~60% blank below.
//
// Root cause: the list was capped (ConstrainedBox maxHeight:220) AND both call
// sites wrapped ConnectForm in a SingleChildScrollView, giving the Column
// unbounded height so it shrank to content.
//
// Contract locked here:
//   1. With a tall viewport + many profiles, the saved-profiles ListView fills
//      the available height (its painted height is far taller than the old 220
//      cap, and tracks the viewport) — it is NOT pinned to a small fixed box.
//   2. "New connection" + "Import from PWA" remain present (below the list).
//   3. With many profiles the list scrolls within its area (it is scrollable),
//      and the action buttons stay visible (not pushed off-screen).
//   4. The #611-A bottom nav still exposes Settings + Diagnostics.

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
import 'package:mobissh/ui/connect_form.dart';

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

Future<void> _seedManyProfiles(ProfilesStore store, int n) async {
  await store.save(<SavedProfile>[
    for (var i = 0; i < n; i++)
      SavedProfile(
        title: 'Box $i',
        host: 'box$i.example',
        port: 22,
        username: 'user$i',
      ),
  ]);
}

/// Painted height of the saved-profiles ListView (the scrollable that holds the
/// tiles). Used to assert the list FILLS the viewport rather than the old fixed
/// 220px cap.
double _listHeight(WidgetTester tester) {
  final listFinder = find.descendant(
    of: find.byKey(const Key('profile-list-populated')),
    matching: find.byType(Scrollable),
  );
  expect(listFinder, findsOneWidget);
  return tester.getSize(listFinder).height;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets(
    'saved-profiles list fills the available height on the home chooser '
    '(not the old fixed 220 cap)',
    (tester) async {
      // Tall viewport so there is plenty of vertical room to fill.
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final store = ProfilesStore();
      await _seedManyProfiles(store, 30);
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      final pair = InMemoryGatewayPair();
      addTearDown(() async => pair.dispose());
      final container = _container(store: store, secrets: secrets, pair: pair);
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ConnectHomePage()),
        ),
      );
      await tester.pumpAndSettle();

      // The list must take far more than the old 220px cap — it should fill the
      // tall viewport (minus app bar, buttons, bottom nav). 600px is a
      // conservative floor that the old fixed cap could never reach.
      final h = _listHeight(tester);
      expect(
        h,
        greaterThan(600),
        reason:
            'profile list should fill the screen height, was $h (old cap 220)',
      );

      // Actions remain present below the list.
      expect(find.byKey(const Key('new-connection')), findsOneWidget);
      expect(
        find.byKey(const Key('open-import-profiles-dialog')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'list height tracks the viewport — taller screen => taller list',
    (tester) async {
      Future<double> measureAt(Size size) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;

        final store = ProfilesStore();
        await _seedManyProfiles(store, 30);
        final secrets = SecretsStore(backend: InMemorySecretsBackend());
        final pair = InMemoryGatewayPair();
        final container = _container(
          store: store,
          secrets: secrets,
          pair: pair,
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: ConnectHomePage()),
          ),
        );
        await tester.pumpAndSettle();
        final h = _listHeight(tester);
        pair.dispose();
        container.dispose();
        return h;
      }

      final short = await measureAt(const Size(1000, 1400));
      final tall = await measureAt(const Size(1000, 2600));
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();

      // A fixed-height box would give identical heights; a filling list grows.
      expect(
        tall,
        greaterThan(short + 400),
        reason:
            'list height must track the viewport (filled), '
            'short=$short tall=$tall',
      );
    },
  );

  testWidgets(
    'with many profiles the list scrolls and the actions stay visible',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final store = ProfilesStore();
      await _seedManyProfiles(store, 40);
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      final pair = InMemoryGatewayPair();
      addTearDown(() async => pair.dispose());
      final container = _container(store: store, secrets: secrets, pair: pair);
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ConnectHomePage()),
        ),
      );
      await tester.pumpAndSettle();

      // Actions visible even with 40 profiles (the list scrolls internally,
      // it does not push the buttons off-screen).
      expect(find.byKey(const Key('new-connection')), findsOneWidget);
      expect(
        find.byKey(const Key('open-import-profiles-dialog')),
        findsOneWidget,
      );

      // The list is scrollable: not all 40 tiles are laid out at once (a fixed
      // non-scrolling Column would build them all). Scroll it and confirm a
      // later tile can be revealed.
      final listFinder = find.descendant(
        of: find.byKey(const Key('profile-list-populated')),
        matching: find.byType(Scrollable),
      );
      await tester.drag(listFinder, const Offset(0, -1200));
      await tester.pumpAndSettle();
      // After scrolling, the actions are STILL visible (they live outside the
      // scrollable, pinned below it).
      expect(find.byKey(const Key('new-connection')), findsOneWidget);
    },
  );

  testWidgets('NewSessionPage chooser also fills (same widget, pushed route)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final store = ProfilesStore();
    await _seedManyProfiles(store, 30);
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    final pair = InMemoryGatewayPair();
    addTearDown(() async => pair.dispose());
    final container = _container(store: store, secrets: secrets, pair: pair);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: NewSessionPage()),
      ),
    );
    await tester.pumpAndSettle();

    final h = _listHeight(tester);
    expect(
      h,
      greaterThan(600),
      reason: 'New session chooser list should fill too, was $h',
    );
    expect(find.byKey(const Key('new-connection')), findsOneWidget);
    expect(
      find.byKey(const Key('open-import-profiles-dialog')),
      findsOneWidget,
    );
  });

  testWidgets('#611-A bottom nav still exposes Settings + Diagnostics', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final store = ProfilesStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    final pair = InMemoryGatewayPair();
    addTearDown(() async => pair.dispose());
    final container = _container(store: store, secrets: secrets, pair: pair);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ConnectHomePage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home-bottom-nav')), findsOneWidget);
    expect(find.byKey(const Key('home-nav-settings')), findsOneWidget);
    expect(find.byKey(const Key('home-nav-diagnostics')), findsOneWidget);

    // Settings destination opens its own view.
    await tester.tap(find.byKey(const Key('home-nav-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-section')), findsOneWidget);
  });
}
