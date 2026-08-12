// Widget tests for the Recent Sessions quick-connect group (#796, PWA #385).
//
// Mirrors the PWA `renderProfiles` recent-sessions block:
//   - seeded recents render a "Recent Sessions" group on cold start
//   - tapping a recent row fires onConnectRecent with that entry (one-tap)
//   - "Reconnect All" appears only when there are >=2 recents
//   - the group is hidden when an active session exists (PWA: allSessions==0)

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/state/recent_sessions.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/ui/profile_list.dart';

Future<void> _seedRecents(
  RecentSessionsStore store,
  List<RecentSessionEntry> entries,
) async {
  // add() unshifts, so add in reverse to get the given order newest-first.
  for (final e in entries.reversed) {
    await store.add(e);
  }
}

RecentSessionEntry _entry(String host, {String user = 'me'}) {
  return RecentSessionEntry(
    title: '$user@$host',
    host: host,
    port: 22,
    username: user,
  );
}

Widget _harness({
  required RecentSessionsStore recentStore,
  required ProfilesStore profilesStore,
  void Function(RecentSessionEntry)? onConnectRecent,
  void Function(List<RecentSessionEntry>)? onReconnectAll,
}) {
  return ProviderScope(
    overrides: [
      recentSessionsStoreProvider.overrideWithValue(recentStore),
      profilesStoreProvider.overrideWithValue(profilesStore),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: ProfileList(
          onConnect: (_) {},
          onEdit: (_) {},
          // Always wire onConnectRecent (a no-op default) so the recents group
          // renders — production (connect_form.dart) always provides it.
          onConnectRecent: onConnectRecent ?? (_) {},
          onReconnectAll: onReconnectAll,
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('renders Recent Sessions group when recents seeded', (
    tester,
  ) async {
    final recentStore = RecentSessionsStore();
    await _seedRecents(recentStore, [_entry('a.example')]);
    final profilesStore = ProfilesStore();

    await tester.pumpWidget(_harness(
      recentStore: recentStore,
      profilesStore: profilesStore,
    ));
    await tester.pumpAndSettle();

    expect(find.text('Recent Sessions'), findsOneWidget);
    expect(find.byKey(const Key('recent-tile-a.example:22:me')),
        findsOneWidget);
  });

  testWidgets('tapping a recent row fires onConnectRecent with that entry', (
    tester,
  ) async {
    final recentStore = RecentSessionsStore();
    await _seedRecents(recentStore, [_entry('a.example'), _entry('b.example')]);
    final profilesStore = ProfilesStore();

    RecentSessionEntry? tapped;
    await tester.pumpWidget(_harness(
      recentStore: recentStore,
      profilesStore: profilesStore,
      onConnectRecent: (e) => tapped = e,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('recent-tile-b.example:22:me')));
    await tester.pump();

    expect(tapped, isNotNull);
    expect(tapped!.host, 'b.example');
  });

  testWidgets('Reconnect All hidden with a single recent', (tester) async {
    final recentStore = RecentSessionsStore();
    await _seedRecents(recentStore, [_entry('a.example')]);
    final profilesStore = ProfilesStore();

    await tester.pumpWidget(_harness(
      recentStore: recentStore,
      profilesStore: profilesStore,
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('reconnect-all-recent')), findsNothing);
  });

  testWidgets('Reconnect All appears with 2+ recents and fires callback', (
    tester,
  ) async {
    final recentStore = RecentSessionsStore();
    await _seedRecents(recentStore, [_entry('a.example'), _entry('b.example')]);
    final profilesStore = ProfilesStore();

    List<RecentSessionEntry>? all;
    await tester.pumpWidget(_harness(
      recentStore: recentStore,
      profilesStore: profilesStore,
      onReconnectAll: (e) => all = e,
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('reconnect-all-recent')), findsOneWidget);
    await tester.tap(find.byKey(const Key('reconnect-all-recent')));
    await tester.pump();
    expect(all, isNotNull);
    expect(all!.length, 2);
  });

  testWidgets('group hidden when an active session exists', (tester) async {
    final recentStore = RecentSessionsStore();
    await _seedRecents(recentStore, [_entry('a.example')]);
    final profilesStore = ProfilesStore();

    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recentSessionsStoreProvider.overrideWithValue(recentStore),
          profilesStoreProvider.overrideWithValue(profilesStore),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            return MaterialApp(
              home: Scaffold(
                body: ProfileList(
                  onConnect: (_) {},
                  onEdit: (_) {},
                  onConnectRecent: (_) {},
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Sanity: group present with no active sessions.
    expect(find.text('Recent Sessions'), findsOneWidget);

    // Create an active session, then re-pump.
    container.read(sessionsProvider.notifier).addOrActivate(
          const SshConnectParams(
            host: 'a.example',
            port: 22,
            username: 'me',
            auth: SshAuth.password('pw'),
          ),
        );
    await tester.pumpAndSettle();

    expect(find.text('Recent Sessions'), findsNothing);
  });

  testWidgets('Clear wipes the recents and the group self-hides', (
    tester,
  ) async {
    final recentStore = RecentSessionsStore();
    await _seedRecents(recentStore, [_entry('a.example'), _entry('b.example')]);

    await tester.pumpWidget(
      _harness(recentStore: recentStore, profilesStore: ProfilesStore()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Recent Sessions'), findsOneWidget);

    await tester.tap(find.byKey(const Key('recent-sessions-clear')));
    await tester.pumpAndSettle();

    // Group self-hides (it returns null on an empty list) …
    expect(find.text('Recent Sessions'), findsNothing);
    // … and the wipe is PERSISTED, not just a UI reset.
    expect(await recentStore.load(), isEmpty);
  });

  testWidgets('Clear leaves saved profiles untouched', (tester) async {
    final recentStore = RecentSessionsStore();
    await _seedRecents(recentStore, [_entry('a.example')]);
    final profilesStore = ProfilesStore();
    await profilesStore.upsert(
      SavedProfile(
        title: 'me@kept.example',
        host: 'kept.example',
        port: 22,
        username: 'me',
      ),
    );

    await tester.pumpWidget(
      _harness(recentStore: recentStore, profilesStore: profilesStore),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('recent-sessions-clear')));
    await tester.pumpAndSettle();

    // Recents are a convenience cache; saved profiles are user data.
    expect(await recentStore.load(), isEmpty);
    expect((await profilesStore.load()).length, 1);
  });
}
