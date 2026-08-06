// Widget tests: Active Sessions UI — state-driven session-menu rows (#817).
//
// Slice 2 of the session-lifecycle fix (#811). A dropped/zombie session must
// never be an invisible or ✕-only tile: each row reads `entry.proxy.data.state`
// (NOT a boolean) and surfaces a status dot + a per-state action:
//   connected → solid dot, [Files][✕]
//   connecting/authenticating/awaitingHostKey → pulsing dot, "Connecting…", [✕]
//   softDisconnected/reconnecting → amber dot, "Reconnecting…", [Reconnect][✕]
//   failed → red dot + reason, [Reconnect][✕]
//   disconnected (user) → grey dot, "Disconnected", [Reconnect][✕]
//
// State is driven exactly as the real task isolate would: push SshStateEvent /
// SshErrorEvent from the task side through the in-memory gateway pair keyed by
// the session id. Reconnect dispatch is asserted by reading the SshReconnect
// command off the task side of the gateway.
//
// Isolation (feedback_feature_scoping_and_isolation_tests): N sessions, drop
// ONE → the others' rows are unchanged; Reconnect/✕ on one never touches
// another.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/keepalive_providers.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/session_menu.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

Future<void> _pumpFrames(WidgetTester tester, {int count = 8}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Let a "Reconnect all" batch (#959) settle. The batch resolves through the
/// REAL event loop (the in-memory gateway + SharedPreferences replies escape
/// `testWidgets`' fake-async clock), so `pump` alone never drains it — give it
/// one real tick, then pump the result into the tree.
Future<void> _settleBatch(WidgetTester tester) async {
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
  await _pumpFrames(tester, count: 4);
}

/// Pump past the batch-summary toast's auto-dismiss (#959) so neither its
/// 2s timer nor its exit animation outlives the test.
Future<void> _drainToast(WidgetTester tester) => _pumpFrames(tester, count: 80);

SessionEntry _add(ProviderContainer c, String host) {
  return c.read(sessionsProvider.notifier).addOrActivate(
        SshConnectParams(
          host: host,
          port: 22,
          username: 'u',
          auth: const SshAuth.password('p'),
        ),
      );
}

/// Push a state event for [entry] from the task side of [pair], as the real
/// `SessionHost` would. `error` carries the failure reason for `failed`.
void _drive(
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

/// The fill color of the row's status dot (the swatch container).
Color _dotColor(WidgetTester tester, SessionEntry entry) {
  final container = tester.widget<Container>(
    find.byKey(Key('session-menu-swatch-${entry.id}')),
  );
  final decoration = container.decoration as BoxDecoration;
  return decoration.color!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  ({ProviderContainer container, InMemoryGatewayPair pair}) make({
    KeepaliveStarter? starter,
  }) {
    final pair = InMemoryGatewayPair();
    final container = ProviderContainer(
      overrides: [
        taskSshGatewayProvider.overrideWithValue(pair.uiSide),
        if (starter != null)
          keepaliveServiceStarterProvider.overrideWithValue(starter),
      ],
    );
    addTearDown(() async {
      await pair.dispose();
    });
    addTearDown(container.dispose);
    return (container: container, pair: pair);
  }

  group('Active Sessions UI — state-driven rows (#817)', () {
    testWidgets(
      'failed session → red dot + reason + Reconnect (Files + ✕ still present)',
      (tester) async {
        final w = make();
        final a = _add(w.container, 'host-a');

        await tester.pumpWidget(_host(container: w.container));
        await tester.tap(find.byKey(const Key('open-menu')));
        await _pumpFrames(tester);

        _drive(w.pair, a, SshSessionState.failed,
            error: 'No SSH response in 25s');
        await _pumpFrames(tester);

        // Status surfaced: dot color = theme error (red), reason text, Reconnect.
        expect(
          find.byKey(Key('session-menu-status-dot-${a.id}')),
          findsOneWidget,
        );
        expect(
          find.byKey(Key('session-menu-reconnect-${a.id}')),
          findsOneWidget,
          reason: 'a failed session must offer Reconnect',
        );
        expect(
          find.text('No SSH response in 25s'),
          findsOneWidget,
          reason: 'the failure reason is shown on the row',
        );
        // The ✕ (forget) and the per-row Files affordance both stay (#649).
        expect(find.byKey(Key('session-menu-close-${a.id}')), findsOneWidget);
        expect(find.byKey(Key('session-menu-files-${a.id}')), findsOneWidget);
        expect(
          _dotColor(tester, a),
          Theme.of(tester.element(find.byKey(Key('session-menu-row-${a.id}'))))
              .colorScheme
              .error,
        );
      },
    );

    testWidgets(
      'reconnecting session → amber dot + "Reconnecting…" + Reconnect',
      (tester) async {
        final w = make();
        final a = _add(w.container, 'host-a');

        await tester.pumpWidget(_host(container: w.container));
        await tester.tap(find.byKey(const Key('open-menu')));
        await _pumpFrames(tester);

        _drive(w.pair, a, SshSessionState.reconnecting);
        await _pumpFrames(tester);

        expect(find.text('Reconnecting…'), findsOneWidget);
        expect(
          find.byKey(Key('session-menu-reconnect-${a.id}')),
          findsOneWidget,
        );
        expect(_dotColor(tester, a), Colors.orange.shade700);
      },
    );

    testWidgets(
      'user-disconnected session → grey dot + Reconnect (not invisible)',
      (tester) async {
        final w = make();
        final a = _add(w.container, 'host-a');

        await tester.pumpWidget(_host(container: w.container));
        await tester.tap(find.byKey(const Key('open-menu')));
        await _pumpFrames(tester);

        _drive(w.pair, a, SshSessionState.disconnected);
        await _pumpFrames(tester);

        expect(find.text('Disconnected'), findsOneWidget);
        expect(
          find.byKey(Key('session-menu-reconnect-${a.id}')),
          findsOneWidget,
          reason: 'a dropped session is reconnectable, not ✕-only',
        );
      },
    );

    testWidgets(
      'connecting session → "Connecting…", NO Reconnect (already trying)',
      (tester) async {
        final w = make();
        final a = _add(w.container, 'host-a');

        await tester.pumpWidget(_host(container: w.container));
        await tester.tap(find.byKey(const Key('open-menu')));
        await _pumpFrames(tester);

        _drive(w.pair, a, SshSessionState.connecting);
        await _pumpFrames(tester);

        expect(find.text('Connecting…'), findsOneWidget);
        expect(
          find.byKey(Key('session-menu-reconnect-${a.id}')),
          findsNothing,
          reason: 'a session already connecting has nothing to reconnect',
        );
      },
    );

    testWidgets(
      'connected session → Files + ✕ + Reconnect (force), no ⊗, no subtitle',
      (tester) async {
        final w = make();
        final a = _add(w.container, 'host-a');

        await tester.pumpWidget(_host(container: w.container));
        await tester.tap(find.byKey(const Key('open-menu')));
        await _pumpFrames(tester);

        _drive(w.pair, a, SshSessionState.connected);
        await _pumpFrames(tester);

        expect(find.byKey(Key('session-menu-files-${a.id}')), findsOneWidget);
        expect(find.byKey(Key('session-menu-close-${a.id}')), findsOneWidget);
        // Owner request: a CONNECTED session now offers Reconnect (force) — e.g.
        // to pick up a control-mode toggle that only applies on reconnect.
        expect(
          find.byKey(Key('session-menu-reconnect-${a.id}')),
          findsOneWidget,
        );
        // The ⊗ exclude-from-Reconnect-all toggle is ONLY for the reconnect
        // group (droppable states); a connected session isn't in it.
        expect(
          find.byKey(Key('session-menu-exclude-reconnect-${a.id}')),
          findsNothing,
        );
        expect(
          find.byKey(Key('session-menu-status-text-${a.id}')),
          findsNothing,
        );
      },
    );

    testWidgets('tapping Reconnect sends a reconnect command for THAT session', (
      tester,
    ) async {
      final w = make();
      final a = _add(w.container, 'host-a');

      // Capture commands arriving on the task side.
      final commands = <Map<String, dynamic>>[];
      final sub = w.pair.taskSide.incoming.listen(commands.add);
      addTearDown(sub.cancel);

      await tester.pumpWidget(_host(container: w.container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      _drive(w.pair, a, SshSessionState.failed, error: 'boom');
      await _pumpFrames(tester);

      await tester.tap(find.byKey(Key('session-menu-reconnect-${a.id}')));
      await _pumpFrames(tester);

      final reconnects = commands
          .where((c) => c['kind'] == SshTaskCommandKind.reconnect.name)
          .toList();
      expect(reconnects.length, 1);
      expect(reconnects.single['sessionId'], a.id);
    });

    testWidgets(
      'isolation: dropping ONE session leaves the others unchanged',
      (tester) async {
        final w = make();
        final a = _add(w.container, 'host-a');
        final b = _add(w.container, 'host-b');
        final c = _add(w.container, 'host-c');

        await tester.pumpWidget(_host(container: w.container));
        await tester.tap(find.byKey(const Key('open-menu')));
        await _pumpFrames(tester);

        // All start connected.
        _drive(w.pair, a, SshSessionState.connected);
        _drive(w.pair, b, SshSessionState.connected);
        _drive(w.pair, c, SshSessionState.connected);
        await _pumpFrames(tester);

        // Drop only b.
        _drive(w.pair, b, SshSessionState.failed, error: 'just b');
        await _pumpFrames(tester);

        // b (dropped) is in the reconnect group → it shows the ⊗ exclude toggle;
        // a and c (still connected) are NOT in the group → no ⊗ (no leakage).
        // Reconnect itself now shows on all three (force on the connected two),
        // so the isolation is read via the group-only ⊗ toggle.
        expect(
          find.byKey(Key('session-menu-reconnect-${b.id}')),
          findsOneWidget,
        );
        expect(
          find.byKey(Key('session-menu-exclude-reconnect-${b.id}')),
          findsOneWidget,
        );
        expect(
          find.byKey(Key('session-menu-exclude-reconnect-${a.id}')),
          findsNothing,
        );
        expect(
          find.byKey(Key('session-menu-exclude-reconnect-${c.id}')),
          findsNothing,
        );
        // a and c keep their Files affordance (still connected).
        expect(find.byKey(Key('session-menu-files-${a.id}')), findsOneWidget);
        expect(find.byKey(Key('session-menu-files-${c.id}')), findsOneWidget);
      },
    );

    testWidgets(
      'isolation: ✕ on one dropped session does not affect a sibling',
      (tester) async {
        final w = make();
        final a = _add(w.container, 'host-a');
        final b = _add(w.container, 'host-b');

        await tester.pumpWidget(_host(container: w.container));
        await tester.tap(find.byKey(const Key('open-menu')));
        await _pumpFrames(tester);

        _drive(w.pair, a, SshSessionState.failed, error: 'a down');
        _drive(w.pair, b, SshSessionState.failed, error: 'b down');
        await _pumpFrames(tester);

        // Forget a.
        await tester.tap(find.byKey(Key('session-menu-close-${a.id}')));
        await _pumpFrames(tester);

        final entries = w.container.read(sessionsProvider).entries;
        expect(entries.length, 1);
        expect(entries.single.id, b.id);
      },
    );

    testWidgets(
      'the ACTIVE session row is visually distinct (standout wrapper)',
      (tester) async {
        final w = make();
        final a = _add(w.container, 'host-a');
        final b = _add(w.container, 'host-b'); // addOrActivate → b is active

        await tester.pumpWidget(_host(container: w.container));
        await tester.tap(find.byKey(const Key('open-menu')));
        await _pumpFrames(tester);

        _drive(w.pair, a, SshSessionState.connected);
        _drive(w.pair, b, SshSessionState.connected);
        await _pumpFrames(tester);

        expect(w.container.read(sessionsProvider).activeId, b.id);

        // Exactly the active row carries the standout; the other does not.
        expect(find.byKey(Key('session-menu-active-${b.id}')), findsOneWidget);
        expect(find.byKey(Key('session-menu-active-${a.id}')), findsNothing);

        // The standout = a primary-tinted fill (the tile's selectedTileColor)
        // + a 4px left accent stripe (the wrapper's border).
        final scheme = Theme.of(
          tester.element(find.byKey(Key('session-menu-row-${b.id}'))),
        ).colorScheme;
        final activeTile = tester.widget<ListTile>(
          find.byKey(Key('session-menu-row-${b.id}')),
        );
        expect(activeTile.selected, isTrue);
        expect(
          activeTile.selectedTileColor,
          scheme.primary.withValues(alpha: 0.10),
        );
        final deco =
            tester
                    .widget<DecoratedBox>(
                      find.byKey(Key('session-menu-active-${b.id}')),
                    )
                    .decoration
                as BoxDecoration;
        expect(deco.color, isNull); // border-only — no bg (hides ListTile ink)
        final border = deco.border! as Border;
        expect(border.left.color, scheme.primary);
        expect(border.left.width, 4);

        // Switching active moves the standout: activate a → a is distinct now.
        w.container.read(sessionsProvider.notifier).setActive(a.id);
        await _pumpFrames(tester);
        expect(find.byKey(Key('session-menu-active-${a.id}')), findsOneWidget);
        expect(find.byKey(Key('session-menu-active-${b.id}')), findsNothing);
      },
    );

    testWidgets(
      'Reconnect all appears when any session is dropped, reconnects each',
      (tester) async {
        final w = make();
        final a = _add(w.container, 'host-a');
        final b = _add(w.container, 'host-b');

        final commands = <Map<String, dynamic>>[];
        final sub = w.pair.taskSide.incoming.listen(commands.add);
        addTearDown(sub.cancel);

        await tester.pumpWidget(_host(container: w.container));
        await tester.tap(find.byKey(const Key('open-menu')));
        await _pumpFrames(tester);

        // Both connected → no Reconnect-all.
        _drive(w.pair, a, SshSessionState.connected);
        _drive(w.pair, b, SshSessionState.connected);
        await _pumpFrames(tester);
        expect(
          find.byKey(const Key('session-menu-reconnect-all')),
          findsNothing,
        );

        // Drop both → Reconnect-all appears.
        _drive(w.pair, a, SshSessionState.failed, error: 'x');
        _drive(w.pair, b, SshSessionState.disconnected);
        await _pumpFrames(tester);
        expect(
          find.byKey(const Key('session-menu-reconnect-all')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('session-menu-reconnect-all')));
        await _pumpFrames(tester);

        final reconnects = commands
            .where((c) => c['kind'] == SshTaskCommandKind.reconnect.name)
            .map((c) => c['sessionId'] as String)
            .toSet();
        expect(reconnects, {a.id, b.id});
        // Owner: reconnect-all FOCUSES the first session so the user lands on a
        // live view instead of hanging on whichever session won't connect.
        expect(
          w.container.read(sessionsProvider).active?.id,
          a.id,
          reason: 'reconnect-all focuses the first session',
        );

        // #959: the batch settles on the per-session state TRANSITIONS, so let
        // both land before the test ends (else the settle timeout outlives it).
        _drive(w.pair, a, SshSessionState.connected);
        _drive(w.pair, b, SshSessionState.connected);
        await _settleBatch(tester);
        await _drainToast(tester);
      },
    );

    testWidgets(
      '⊗ excludes a session from Reconnect all (skipped, kept, still reconnectable)',
      (tester) async {
        final w = make();
        final a = _add(w.container, 'host-a');
        final b = _add(w.container, 'host-b');

        final commands = <Map<String, dynamic>>[];
        final sub = w.pair.taskSide.incoming.listen(commands.add);
        addTearDown(sub.cancel);

        await tester.pumpWidget(_host(container: w.container));
        await tester.tap(find.byKey(const Key('open-menu')));
        await _pumpFrames(tester);

        // Drop both → both are in the reconnect group.
        _drive(w.pair, a, SshSessionState.failed, error: 'x');
        _drive(w.pair, b, SshSessionState.disconnected);
        await _pumpFrames(tester);

        // Exclude a via its ⊗ toggle.
        await tester.tap(
          find.byKey(Key('session-menu-exclude-reconnect-${a.id}')),
        );
        await _pumpFrames(tester);
        // a is KEPT in the list (not closed).
        expect(find.byKey(Key('session-menu-row-${a.id}')), findsOneWidget);

        // Reconnect all now reconnects ONLY b.
        await tester.tap(find.byKey(const Key('session-menu-reconnect-all')));
        await _pumpFrames(tester);
        final reconnects = commands
            .where((c) => c['kind'] == SshTaskCommandKind.reconnect.name)
            .map((c) => c['sessionId'] as String)
            .toSet();
        expect(reconnects, {b.id});

        // a stays individually reconnectable via its own button.
        expect(
          find.byKey(Key('session-menu-reconnect-${a.id}')),
          findsOneWidget,
        );

        // #959: settle b so the batch's timeout doesn't outlive the test.
        _drive(w.pair, b, SshSessionState.connected);
        await _settleBatch(tester);
        await _drainToast(tester);
      },
    );
  });

  // #959 — "Reconnect all" must not fail SILENTLY when one session in the set
  // fails. Two distinct defects: (a) a synchronous throw from one session's
  // reconnect aborted the plain `for` loop, silently SKIPPING every session
  // after it; (b) the batch reported no outcome at all, so the user could not
  // tell what succeeded. Outcomes are asserted from the per-session state
  // TRANSITIONS (feedback_test_state_transitions_not_states), never from the
  // return of the dispatch call.
  group('Reconnect all — batch isolation + honest outcome (#959)', () {
    testWidgets(
      'one session throwing on reconnect does NOT skip the rest of the batch',
      (tester) async {
        // The keepalive starter is the one SYNCHRONOUS throw site inside
        // SessionsNotifier.reconnect. Arm it to blow up on the 2nd session of
        // the batch only: before the fix that throw escaped reconnect(), escaped
        // the row's for-loop, and session C never dispatched at all.
        var armed = false;
        var armedCalls = 0;
        final w = make(
          starter: () {
            if (armed) {
              armedCalls += 1;
              if (armedCalls == 2) {
                throw StateError('keepalive start failed for this session');
              }
            }
            return Future<void>.value();
          },
        );
        final a = _add(w.container, 'host-a');
        final b = _add(w.container, 'host-b');
        final c = _add(w.container, 'host-c');

        final commands = <Map<String, dynamic>>[];
        final sub = w.pair.taskSide.incoming.listen(commands.add);
        addTearDown(sub.cancel);

        await tester.pumpWidget(_host(container: w.container));
        await tester.tap(find.byKey(const Key('open-menu')));
        await _pumpFrames(tester);

        for (final e in [a, b, c]) {
          _drive(w.pair, e, SshSessionState.disconnected);
        }
        await _pumpFrames(tester);

        armed = true;
        await tester.tap(find.byKey(const Key('session-menu-reconnect-all')));
        await _pumpFrames(tester);

        final reconnects = commands
            .where((cmd) => cmd['kind'] == SshTaskCommandKind.reconnect.name)
            .map((cmd) => cmd['sessionId'] as String)
            .toSet();
        expect(
          reconnects,
          {a.id, b.id, c.id},
          reason:
              'every session reconnects independently — one failure must not '
              'abort or mask the others',
        );

        // Settle the batch (b genuinely fails) and let the toast expire.
        _drive(w.pair, a, SshSessionState.connected);
        _drive(w.pair, b, SshSessionState.failed, error: 'auth failed');
        _drive(w.pair, c, SshSessionState.connected);
        await _settleBatch(tester);
        await _drainToast(tester);
      },
    );

    testWidgets(
      'batch summarises the outcome and the failed row keeps its reason',
      (tester) async {
        final w = make();
        final a = _add(w.container, 'host-a');
        final b = _add(w.container, 'host-b');
        final c = _add(w.container, 'host-c');

        await tester.pumpWidget(_host(container: w.container));
        await tester.tap(find.byKey(const Key('open-menu')));
        await _pumpFrames(tester);

        for (final e in [a, b, c]) {
          _drive(w.pair, e, SshSessionState.disconnected);
        }
        await _pumpFrames(tester);

        await tester.tap(find.byKey(const Key('session-menu-reconnect-all')));
        await _pumpFrames(tester);

        // No verdict while the batch is still in flight.
        expect(find.byKey(const Key('top-toast')), findsNothing);

        // B fails, A and C come back.
        _drive(w.pair, a, SshSessionState.connected);
        _drive(w.pair, b, SshSessionState.failed, error: 'auth failed');
        _drive(w.pair, c, SshSessionState.connected);
        await _settleBatch(tester);

        expect(
          find.byKey(const Key('top-toast')),
          findsOneWidget,
          reason: 'the batch outcome must be surfaced, not silent',
        );
        expect(find.text('Reconnected 2, 1 failed'), findsOneWidget);

        // And the per-row signal still carries WHICH one failed + why.
        expect(_dotColor(tester, b), isNot(_dotColor(tester, a)));
        expect(find.text('auth failed'), findsOneWidget);

        await _drainToast(tester);
      },
    );

    testWidgets(
      'batch skips ⊗-excluded and connected sessions (#817 preserved)',
      (tester) async {
        final w = make();
        final a = _add(w.container, 'host-a');
        final b = _add(w.container, 'host-b');
        final c = _add(w.container, 'host-c');

        final commands = <Map<String, dynamic>>[];
        final sub = w.pair.taskSide.incoming.listen(commands.add);
        addTearDown(sub.cancel);

        await tester.pumpWidget(_host(container: w.container));
        await tester.tap(find.byKey(const Key('open-menu')));
        await _pumpFrames(tester);

        // a stays CONNECTED, b + c are dropped; c is ⊗-excluded.
        _drive(w.pair, a, SshSessionState.connected);
        _drive(w.pair, b, SshSessionState.disconnected);
        _drive(w.pair, c, SshSessionState.disconnected);
        await _pumpFrames(tester);
        await tester.tap(
          find.byKey(Key('session-menu-exclude-reconnect-${c.id}')),
        );
        await _pumpFrames(tester);

        await tester.tap(find.byKey(const Key('session-menu-reconnect-all')));
        await _pumpFrames(tester);

        final reconnects = commands
            .where((cmd) => cmd['kind'] == SshTaskCommandKind.reconnect.name)
            .map((cmd) => cmd['sessionId'] as String)
            .toSet();
        expect(reconnects, {b.id});

        _drive(w.pair, b, SshSessionState.connected);
        await _settleBatch(tester);

        // The summary counts only the sessions the batch actually touched.
        expect(find.text('Reconnected 1 session'), findsOneWidget);
        await _drainToast(tester);
      },
    );
  });
}
