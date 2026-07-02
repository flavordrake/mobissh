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

  ({ProviderContainer container, InMemoryGatewayPair pair}) make() {
    final pair = InMemoryGatewayPair();
    final container = ProviderContainer(
      overrides: [taskSshGatewayProvider.overrideWithValue(pair.uiSide)],
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
      'connected session → Files + ✕, no Reconnect, no status subtitle',
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
        expect(
          find.byKey(Key('session-menu-reconnect-${a.id}')),
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

        // b shows Reconnect; a and c do NOT (no leakage).
        expect(
          find.byKey(Key('session-menu-reconnect-${b.id}')),
          findsOneWidget,
        );
        expect(
          find.byKey(Key('session-menu-reconnect-${a.id}')),
          findsNothing,
        );
        expect(
          find.byKey(Key('session-menu-reconnect-${c.id}')),
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
      },
    );
  });
}
