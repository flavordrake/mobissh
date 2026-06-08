// Widget tests for the Connect-view Active Sessions group + recents
// reconciliation (#821 Slice 3, closes #809).
//
// PWA parity (`src/modules/profiles.ts` loadProfiles):
//   - ALL sessions (connected + dropped) render in an "Active Sessions" group at
//     the TOP of the Connect view. Connected → Switch, dropped → Reconnect, all
//     → ✕. "Reconnect all" appears when any is non-connected.
//   - Recent Sessions show ONLY on TRUE cold start (zero sessions). A dropped
//     session no longer SUPPRESSES recents invisibly — it lives in the Active
//     group instead (#809: it must not vanish).
//   - Per-session isolation: dropping one session leaves the others' rows
//     unchanged.
//
// We drive proxy state by tapping a profile row (→ creates a session entry) and
// pushing task-side state events through the in-memory gateway pair — the same
// seam profile_list_connect_state_test.dart uses.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/state/recent_sessions.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/ui/profile_list.dart';

Future<void> _pumpFrames(WidgetTester tester, {int count = 12}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

RecentSessionEntry _recent(String host, {String user = 'me'}) {
  return RecentSessionEntry(
    title: '$user@$host',
    host: host,
    port: 22,
    username: user,
  );
}

Future<void> _seedRecents(
  RecentSessionsStore store,
  List<RecentSessionEntry> entries,
) async {
  for (final e in entries.reversed) {
    await store.add(e);
  }
}

/// Pump a ProfileList wired to a fresh in-memory gateway pair. The default
/// onConnect creates a real session entry for the tapped profile so the row has
/// a proxy whose state we can drive. Returns the container + pair.
Future<({ProviderContainer container, InMemoryGatewayPair pair})> _pumpList(
  WidgetTester tester, {
  required ProfilesStore store,
  RecentSessionsStore? recentStore,
}) async {
  final pair = InMemoryGatewayPair();
  addTearDown(() async {
    await pair.dispose();
  });
  final container = ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      profilesStoreProvider.overrideWithValue(store),
      if (recentStore != null)
        recentSessionsStoreProvider.overrideWithValue(recentStore),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: ProfileList(
            onConnect: (p) {
              container.read(sessionsProvider.notifier).addOrActivate(
                    SshConnectParams(
                      host: p.host,
                      port: p.port,
                      username: p.username,
                      auth: const SshAuth.password('pw'),
                    ),
                    title: p.title,
                  );
            },
            onEdit: (_) {},
            onConnectRecent: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (container: container, pair: pair);
}

void _pushState(
  InMemoryGatewayPair pair,
  SessionEntry entry,
  SshSessionState state, {
  String? error,
}) {
  pair.taskSide.send(
    SshStateEvent(
      sessionId: entry.id,
      state: state.name,
      error: error,
      host: entry.host,
      port: entry.port,
      username: entry.username,
    ).toJson(),
  );
}

SavedProfile _profile(String host, {String user = 'me', String? title}) {
  return SavedProfile(
    title: title ?? '$user@$host',
    host: host,
    port: 22,
    username: user,
    authType: 'password',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets(
    '#809: a DROPPED session appears in the Active Sessions group with Reconnect '
    '(not vanished)',
    (tester) async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[_profile('a.example', user: 'alice')]);

      final wired = await _pumpList(tester, store: store);

      // Connect A.
      await tester.tap(
        find.byKey(const Key('profile-tile-a.example:22:alice')),
      );
      await _pumpFrames(tester);
      final entry = wired.container.read(sessionsProvider).entries.first;
      _pushState(wired.pair, entry, SshSessionState.connected);
      await _pumpFrames(tester);

      // Now DROP A — the entry survives (a drop is not a forget).
      _pushState(wired.pair, entry, SshSessionState.disconnected);
      await _pumpFrames(tester);

      // The Active Sessions group renders the dropped session with a Reconnect
      // affordance — it did NOT vanish.
      expect(find.byKey(const Key('active-sessions-group')), findsOneWidget);
      expect(find.text('Active Sessions'), findsOneWidget);
      expect(
        find.byKey(Key('active-session-tile-${entry.id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('active-session-reconnect-${entry.id}')),
        findsOneWidget,
        reason: 'a dropped session must offer Reconnect on the Connect view',
      );
    },
  );

  testWidgets(
    'a CONNECTED session shows a Switch action (not Reconnect)',
    (tester) async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[_profile('a.example', user: 'alice')]);

      final wired = await _pumpList(tester, store: store);
      await tester.tap(
        find.byKey(const Key('profile-tile-a.example:22:alice')),
      );
      await _pumpFrames(tester);
      final entry = wired.container.read(sessionsProvider).entries.first;
      _pushState(wired.pair, entry, SshSessionState.connected);
      await _pumpFrames(tester);

      expect(
        find.byKey(Key('active-session-switch-${entry.id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('active-session-reconnect-${entry.id}')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'recents show at zero sessions and HIDE once any session exists; the '
    'dropped session surfaces in the Active group instead',
    (tester) async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[_profile('a.example', user: 'alice')]);
      final recentStore = RecentSessionsStore();
      await _seedRecents(recentStore, [_recent('a.example', user: 'alice')]);

      final wired = await _pumpList(
        tester,
        store: store,
        recentStore: recentStore,
      );

      // Cold start: Recent Sessions group is present.
      expect(find.text('Recent Sessions'), findsOneWidget);
      expect(find.byKey(const Key('active-sessions-group')), findsNothing);

      // Connect, then drop. Recents must hide (any session present), and the
      // Active group must show the dropped session.
      await tester.tap(
        find.byKey(const Key('profile-tile-a.example:22:alice')),
      );
      await _pumpFrames(tester);
      final entry = wired.container.read(sessionsProvider).entries.first;
      _pushState(wired.pair, entry, SshSessionState.connected);
      await _pumpFrames(tester);
      _pushState(wired.pair, entry, SshSessionState.disconnected);
      await _pumpFrames(tester);

      expect(
        find.text('Recent Sessions'),
        findsNothing,
        reason: 'recents must hide once ANY session exists (PWA parity)',
      );
      expect(find.byKey(const Key('active-sessions-group')), findsOneWidget);
      expect(
        find.byKey(Key('active-session-reconnect-${entry.id}')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'two dropped sessions → Active group shows both + a "Reconnect all"; neither '
    'group vanishes (no mid-loop unmount)',
    (tester) async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        _profile('a.example', user: 'alice'),
        _profile('b.example', user: 'bob'),
      ]);

      final wired = await _pumpList(tester, store: store);

      await tester.tap(
        find.byKey(const Key('profile-tile-a.example:22:alice')),
      );
      await _pumpFrames(tester);
      await tester.tap(
        find.byKey(const Key('profile-tile-b.example:22:bob')),
      );
      await _pumpFrames(tester);

      final entries = wired.container.read(sessionsProvider).entries;
      expect(entries.length, 2);
      for (final e in entries) {
        _pushState(wired.pair, e, SshSessionState.connected);
      }
      await _pumpFrames(tester);
      for (final e in entries) {
        _pushState(wired.pair, e, SshSessionState.disconnected);
      }
      await _pumpFrames(tester);

      // Both rows present, plus the group-level Reconnect-all.
      for (final e in entries) {
        expect(
          find.byKey(Key('active-session-tile-${e.id}')),
          findsOneWidget,
        );
        expect(
          find.byKey(Key('active-session-reconnect-${e.id}')),
          findsOneWidget,
        );
      }
      expect(
        find.byKey(const Key('active-sessions-reconnect-all')),
        findsOneWidget,
      );

      // Tapping Reconnect-all does not unmount the group.
      await tester.tap(
        find.byKey(const Key('active-sessions-reconnect-all')),
      );
      await _pumpFrames(tester);
      expect(find.byKey(const Key('active-sessions-group')), findsOneWidget);
    },
  );

  testWidgets(
    'per-session isolation: dropping ONE of two leaves the other row a Switch',
    (tester) async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        _profile('a.example', user: 'alice'),
        _profile('b.example', user: 'bob'),
      ]);

      final wired = await _pumpList(tester, store: store);
      await tester.tap(
        find.byKey(const Key('profile-tile-a.example:22:alice')),
      );
      await _pumpFrames(tester);
      await tester.tap(
        find.byKey(const Key('profile-tile-b.example:22:bob')),
      );
      await _pumpFrames(tester);

      final entries = wired.container.read(sessionsProvider).entries;
      final a = entries.firstWhere((e) => e.host == 'a.example');
      final b = entries.firstWhere((e) => e.host == 'b.example');
      _pushState(wired.pair, a, SshSessionState.connected);
      _pushState(wired.pair, b, SshSessionState.connected);
      await _pumpFrames(tester);

      // Drop ONLY a.
      _pushState(wired.pair, a, SshSessionState.disconnected);
      await _pumpFrames(tester);

      // a → Reconnect, b → still Switch (unchanged). No leakage.
      expect(
        find.byKey(Key('active-session-reconnect-${a.id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('active-session-switch-${a.id}')),
        findsNothing,
      );
      expect(
        find.byKey(Key('active-session-switch-${b.id}')),
        findsOneWidget,
        reason: 'dropping a must not change b',
      );
      expect(
        find.byKey(Key('active-session-reconnect-${b.id}')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'tapping Reconnect on a dropped row re-enters the connect path for that '
    'session',
    (tester) async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[_profile('a.example', user: 'alice')]);

      final wired = await _pumpList(tester, store: store);
      await tester.tap(
        find.byKey(const Key('profile-tile-a.example:22:alice')),
      );
      await _pumpFrames(tester);
      final entry = wired.container.read(sessionsProvider).entries.first;
      _pushState(wired.pair, entry, SshSessionState.connected);
      await _pumpFrames(tester);
      _pushState(wired.pair, entry, SshSessionState.disconnected);
      await _pumpFrames(tester);

      // Tap Reconnect — the entry must survive (reconnect is not a forget) and
      // the row stays present.
      await tester.tap(
        find.byKey(Key('active-session-reconnect-${entry.id}')),
      );
      await _pumpFrames(tester);

      expect(
        wired.container
            .read(sessionsProvider)
            .entries
            .any((e) => e.id == entry.id),
        isTrue,
        reason: 'reconnect must keep the session entry',
      );
      expect(
        find.byKey(Key('active-session-tile-${entry.id}')),
        findsOneWidget,
      );
    },
  );
}
