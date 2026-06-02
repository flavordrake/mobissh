// Widget tests: per-PROFILE-ROW connect affordance (#660, refining #648).
//
// Owner feedback on build 'f': #648 surfaced a connect FAILURE as a MODAL
// AlertDialog that blocked the whole profile list. The owner wants the connect
// status shown as a LOCAL, PER-ROW affordance instead:
//   - while connecting: an inline spinner / "Connecting…" state ON THAT ROW,
//   - on failure: a compact inline error + a RETRY affordance ON THAT ROW
//     (NOT a blocking AlertDialog), with the full reason still reachable.
//
// This mirrors the PWA (`src/modules/profiles.ts`): each profile row derives
// its connect state from the matching session (connecting/failed), no modal.
//
// ProfileList watches `sessionsProvider`; a row whose profile identityKey
// matches a session's profileKey reflects that session's proxy state. We drive
// state by tapping the row (→ onConnect creates a session entry) and then
// pushing `connecting` / `failed` state events from the task side through the
// in-memory gateway pair — exactly as the real task isolate would.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/ui/profile_list.dart';

Future<void> _pumpFrames(WidgetTester tester, {int count = 12}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Build a ProfileList wired to a fresh in-memory gateway pair. Returns the
/// container + pair so the test can push task-side state events and read the
/// session collection. [onConnect] defaults to the real "create a session
/// entry" path so a row tap behaves like production (proxy created, ready for
/// state events). Override [onConnect] to assert the callback fires.
Future<({ProviderContainer container, InMemoryGatewayPair pair})> _pumpList(
  WidgetTester tester, {
  required ProfilesStore store,
  void Function(SavedProfile profile)? onConnect,
}) async {
  final pair = InMemoryGatewayPair();
  addTearDown(() async {
    await pair.dispose();
  });
  final container = ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      profilesStoreProvider.overrideWithValue(store),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: ProfileList(
            onConnect:
                onConnect ??
                (p) {
                  // Production-ish: create a session entry for the tapped
                  // profile so the row has a proxy whose state we can drive.
                  container
                      .read(sessionsProvider.notifier)
                      .addOrActivate(
                        SshConnectParams(
                          host: p.host,
                          port: p.port,
                          username: p.username,
                          auth: SshAuth.password('pw'),
                        ),
                        title: p.title,
                      );
                },
            onEdit: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (container: container, pair: pair);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets(
    'a profile row whose session is `connecting` shows an inline spinner ON THE ROW',
    (tester) async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(
          title: 'Box',
          host: 'box.example',
          port: 22,
          username: 'alice',
          authType: 'password',
        ),
      ]);

      final wired = await _pumpList(tester, store: store);

      // Tap the row → connect (creates the session entry / proxy).
      await tester.tap(
        find.byKey(const Key('profile-tile-box.example:22:alice')),
      );
      await _pumpFrames(tester);

      final entry = wired.container.read(sessionsProvider).entries.first;

      // Task side reports the connect is in progress.
      wired.pair.taskSide.send(
        SshStateEvent(
          sessionId: entry.id,
          state: SshSessionState.connecting.name,
          host: 'box.example',
          port: 22,
          username: 'alice',
        ).toJson(),
      );
      await _pumpFrames(tester);

      // The row shows an inline connecting indicator — NOT a modal, NOT a
      // global spinner.
      expect(
        find.byKey(const Key('profile-connecting-box.example:22:alice')),
        findsOneWidget,
        reason: 'connecting state must surface inline on the tapped row',
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    },
  );

  testWidgets(
    'a profile row whose session `failed` shows an inline error + retry ON THE ROW, NOT an AlertDialog',
    (tester) async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(
          title: 'Down',
          host: 'down.example',
          port: 22,
          username: 'bob',
          authType: 'password',
        ),
      ]);

      final wired = await _pumpList(tester, store: store);

      await tester.tap(
        find.byKey(const Key('profile-tile-down.example:22:bob')),
      );
      await _pumpFrames(tester);

      final entry = wired.container.read(sessionsProvider).entries.first;

      const reason =
          'No SSH response in 25s — host may be unreachable or asleep';
      wired.pair.taskSide.send(
        SshStateEvent(
          sessionId: entry.id,
          state: SshSessionState.failed.name,
          error: reason,
          host: 'down.example',
          port: 22,
          username: 'bob',
        ).toJson(),
      );
      await _pumpFrames(tester);

      // Inline error state on the row + a retry affordance — and crucially NO
      // blocking modal dialog (the #648 regression the owner reported).
      expect(
        find.byKey(const Key('profile-error-down.example:22:bob')),
        findsOneWidget,
        reason: 'failure must render inline on the row',
      );
      expect(
        find.byKey(const Key('profile-retry-down.example:22:bob')),
        findsOneWidget,
        reason: 'the row must offer a retry affordance',
      );
      expect(
        find.byType(AlertDialog),
        findsNothing,
        reason: 'inline surfacing must REPLACE the #648 blocking modal',
      );
    },
  );

  testWidgets(
    'tapping the row retry affordance re-fires onConnect for that profile',
    (tester) async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(
          title: 'Down',
          host: 'down.example',
          port: 22,
          username: 'bob',
          authType: 'password',
        ),
      ]);

      // Track connect calls; still create the session entry so the failed
      // state has a proxy to attach to.
      final connectCalls = <SavedProfile>[];
      late ProviderContainer container;
      final pair = InMemoryGatewayPair();
      addTearDown(() async {
        await pair.dispose();
      });
      container = ProviderContainer(
        overrides: [
          taskSshGatewayProvider.overrideWithValue(pair.uiSide),
          profilesStoreProvider.overrideWithValue(store),
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
                  connectCalls.add(p);
                  container
                      .read(sessionsProvider.notifier)
                      .addOrActivate(
                        SshConnectParams(
                          host: p.host,
                          port: p.port,
                          username: p.username,
                          auth: SshAuth.password('pw'),
                        ),
                        title: p.title,
                      );
                },
                onEdit: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('profile-tile-down.example:22:bob')),
      );
      await _pumpFrames(tester);
      expect(connectCalls.length, 1);

      final entry = container.read(sessionsProvider).entries.first;
      pair.taskSide.send(
        SshStateEvent(
          sessionId: entry.id,
          state: SshSessionState.failed.name,
          error: 'TCP connect failed: connection refused',
          host: 'down.example',
          port: 22,
          username: 'bob',
        ).toJson(),
      );
      await _pumpFrames(tester);

      await tester.tap(
        find.byKey(const Key('profile-retry-down.example:22:bob')),
      );
      await _pumpFrames(tester);

      expect(
        connectCalls.length,
        2,
        reason: 'retry must re-dispatch connect for the same profile',
      );
      expect(connectCalls.last.host, 'down.example');
    },
  );

  testWidgets(
    'tapping the inline error opens a detail surface with the full reason',
    (tester) async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(
          title: 'Down',
          host: 'down.example',
          port: 22,
          username: 'bob',
          authType: 'password',
        ),
      ]);

      final wired = await _pumpList(tester, store: store);

      await tester.tap(
        find.byKey(const Key('profile-tile-down.example:22:bob')),
      );
      await _pumpFrames(tester);

      final entry = wired.container.read(sessionsProvider).entries.first;
      const reason =
          'Authentication failed: SSHAuthFailError(all auth methods failed)';
      wired.pair.taskSide.send(
        SshStateEvent(
          sessionId: entry.id,
          state: SshSessionState.failed.name,
          error: reason,
          host: 'down.example',
          port: 22,
          username: 'bob',
        ).toJson(),
      );
      await _pumpFrames(tester);

      // Before the tap there's no detail surface — the failure is inline only.
      expect(
        find.byKey(const Key('profile-error-detail-down.example:22:bob')),
        findsNothing,
      );

      // Tap the inline error to see the full reason. This is explicit
      // user-initiated detail — NOT an auto-popped blocking modal.
      await tester.tap(
        find.byKey(const Key('profile-error-down.example:22:bob')),
      );
      await _pumpFrames(tester);

      // The detail surface is now open and carries the full reason.
      final detail = find.byKey(
        const Key('profile-error-detail-down.example:22:bob'),
      );
      expect(detail, findsOneWidget);
      expect(
        find.descendant(
          of: detail,
          matching: find.textContaining('Authentication failed'),
        ),
        findsOneWidget,
      );
    },
  );
}
