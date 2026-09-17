// Widget tests for the Connection Audit screen (#524 / backfill #1164).
//
// The screen had never been rendered by a test — only its Settings button key
// was asserted. Pins:
//   - (a) empty state when no sessions exist (no list, guidance copy).
//   - (b) one row per session: profile label, `State:` prefers the LIVE
//     `sessionDataProvider` value over the proxy snapshot, falls back to the
//     snapshot state before any live event, `Reconnect attempts:` from the
//     snapshot, `Target:` user@host:port.
//   - (c) `Last reconnect:` age formatting — seconds / minutes / hours.
//
// Sessions are created through `sessionsProvider.notifier.addOrActivate` on
// an `InMemoryGatewayPair` and driven by pushing task-side events — the same
// seam active_sessions_group_test.dart uses. Snapshot counters only reach
// the proxy via `SshSnapshotEvent`; the pair delivers through the REAL event
// loop, hence the `runAsync` tick before each pump.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/connection_audit.dart';

Future<void> _pumpFrames(WidgetTester tester, {int count = 6}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Let the in-memory gateway (real event loop) deliver queued events.
Future<void> _tickRealClock(WidgetTester tester) async {
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
}

({ProviderContainer container, InMemoryGatewayPair pair}) _wire() {
  final pair = InMemoryGatewayPair();
  addTearDown(() async {
    await pair.dispose();
  });
  final container = ProviderContainer(
    overrides: [taskSshGatewayProvider.overrideWithValue(pair.uiSide)],
  );
  addTearDown(container.dispose);
  return (container: container, pair: pair);
}

SessionEntry _addSession(
  ProviderContainer container, {
  String host = 'a.example',
  String user = 'alice',
  int port = 22,
  String? title,
}) {
  return container.read(sessionsProvider.notifier).addOrActivate(
        SshConnectParams(
          host: host,
          port: port,
          username: user,
          auth: const SshAuth.password('pw'),
        ),
        title: title,
      );
}

void _pushState(
  InMemoryGatewayPair pair,
  SessionEntry entry,
  SshSessionState state,
) {
  pair.taskSide.send(
    SshStateEvent(
      sessionId: entry.id,
      state: state.name,
      host: entry.host,
      port: entry.port,
      username: entry.username,
    ).toJson(),
  );
}

void _pushSnapshot(
  InMemoryGatewayPair pair,
  SessionEntry entry, {
  required SshSessionState state,
  int reconnectCount = 0,
  int? lastReconnectAtMs,
}) {
  pair.taskSide.send(
    SshSnapshotEvent(
      sessionId: entry.id,
      state: state.name,
      reconnectCount: reconnectCount,
      lastReconnectAtMs: lastReconnectAtMs,
    ).toJson(),
  );
}

Future<void> _pumpScreen(WidgetTester tester, ProviderContainer container) {
  return tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ConnectionAuditScreen()),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('(a) no sessions → empty-state guidance, no list', (
    tester,
  ) async {
    final wired = _wire();

    await _pumpScreen(tester, wired.container);
    await _pumpFrames(tester);

    expect(find.text('Connection Audit'), findsOneWidget);
    expect(find.byKey(const Key('connection-audit-list')), findsNothing);
    expect(
      find.textContaining('No active sessions.'),
      findsOneWidget,
      reason: 'empty state must tell the user to connect first',
    );
  });

  testWidgets(
    '(b) row shows profile title, LIVE state over snapshot state, reconnect '
    'count and target',
    (tester) async {
      final wired = _wire();
      final entry = _addSession(wired.container, title: 'Prod box');

      // Snapshot says connected with 3 reconnects; the live stream then says
      // disconnected — the live value must win for `State:`.
      _pushSnapshot(
        wired.pair,
        entry,
        state: SshSessionState.connected,
        reconnectCount: 3,
      );
      _pushState(wired.pair, entry, SshSessionState.disconnected);
      await _tickRealClock(tester);

      await _pumpScreen(tester, wired.container);
      await _tickRealClock(tester);
      await _pumpFrames(tester);

      expect(find.byKey(const Key('connection-audit-list')), findsOneWidget);
      expect(find.byKey(Key('audit-row-${entry.id}')), findsOneWidget);
      expect(find.text('Prod box'), findsOneWidget, reason: '#518 label');
      expect(
        find.text('State: disconnected'),
        findsOneWidget,
        reason: 'live sessionDataProvider state must win over the snapshot',
      );
      expect(find.text('State: connected'), findsNothing);
      expect(find.text('Reconnect attempts: 3'), findsOneWidget);
      expect(find.text('Target: alice@a.example:22'), findsOneWidget);
      expect(
        find.byKey(Key('audit-last-reconnect-${entry.id}')),
        findsNothing,
        reason: 'no lastReconnectAtMs → no Last reconnect line',
      );
    },
  );

  testWidgets(
    '(b) ad-hoc session (no title) labels the row user@host:port; snapshot '
    'state shows before any live event',
    (tester) async {
      final wired = _wire();
      final entry = _addSession(
        wired.container,
        host: 'b.example',
        user: 'bob',
        port: 2222,
      );
      _pushSnapshot(
        wired.pair,
        entry,
        state: SshSessionState.reconnecting,
        reconnectCount: 1,
      );
      await _tickRealClock(tester);

      // First frame: the StreamProvider is still loading → snapshot state.
      await _pumpScreen(tester, wired.container);
      expect(
        find.text('State: reconnecting'),
        findsOneWidget,
        reason: 'snapshot state is the fallback while live data is loading',
      );

      // Once the stream yields the proxy's cached data (idle — connect was
      // never dispatched), the live value takes over.
      await _tickRealClock(tester);
      await _pumpFrames(tester);
      expect(find.text('State: idle'), findsOneWidget);
      expect(find.text('State: reconnecting'), findsNothing);

      // Label + target for an ad-hoc connect.
      expect(find.text('bob@b.example:2222'), findsOneWidget);
      expect(find.text('Target: bob@b.example:2222'), findsOneWidget);
      expect(find.text('Reconnect attempts: 1'), findsOneWidget);
    },
  );

  testWidgets('(b) two sessions → one row each, counters isolated', (
    tester,
  ) async {
    final wired = _wire();
    final a = _addSession(wired.container, host: 'a.example', user: 'alice');
    final b = _addSession(wired.container, host: 'b.example', user: 'bob');
    _pushSnapshot(
      wired.pair,
      a,
      state: SshSessionState.connected,
      reconnectCount: 2,
    );
    _pushSnapshot(
      wired.pair,
      b,
      state: SshSessionState.connected,
      reconnectCount: 0,
    );
    await _tickRealClock(tester);

    await _pumpScreen(tester, wired.container);
    await _tickRealClock(tester);
    await _pumpFrames(tester);

    expect(find.byKey(Key('audit-row-${a.id}')), findsOneWidget);
    expect(find.byKey(Key('audit-row-${b.id}')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(Key('audit-row-${a.id}')),
        matching: find.text('Reconnect attempts: 2'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(Key('audit-row-${b.id}')),
        matching: find.text('Reconnect attempts: 0'),
      ),
      findsOneWidget,
    );
  });

  group('(c) Last reconnect age formatting', () {
    Future<void> pumpWithAge(
      WidgetTester tester,
      Duration age,
    ) async {
      final wired = _wire();
      final entry = _addSession(wired.container);
      // Real wall clock: the widget formats against DateTime.now(). The
      // offsets are exact unit boundaries so the few ms that elapse before
      // the build cannot cross a truncation edge.
      final at = DateTime.now().subtract(age).millisecondsSinceEpoch;
      _pushSnapshot(
        wired.pair,
        entry,
        state: SshSessionState.connected,
        reconnectCount: 1,
        lastReconnectAtMs: at,
      );
      await _tickRealClock(tester);
      await _pumpScreen(tester, wired.container);
      await _pumpFrames(tester);
      expect(
        find.byKey(Key('audit-last-reconnect-${entry.id}')),
        findsOneWidget,
      );
    }

    testWidgets('30 seconds → "30s ago"', (tester) async {
      await pumpWithAge(tester, const Duration(seconds: 30));
      expect(find.text('Last reconnect: 30s ago'), findsOneWidget);
    });

    testWidgets('5 minutes → "5m ago"', (tester) async {
      await pumpWithAge(tester, const Duration(minutes: 5));
      expect(find.text('Last reconnect: 5m ago'), findsOneWidget);
    });

    testWidgets('2 hours → "2h ago"', (tester) async {
      await pumpWithAge(tester, const Duration(hours: 2));
      expect(find.text('Last reconnect: 2h ago'), findsOneWidget);
    });
  });
}
