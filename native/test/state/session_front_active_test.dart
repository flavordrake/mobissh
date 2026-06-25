// SessionsState front-most active derivation (#936).
//
// The attention-suppression UI→task propagation needs the front-most session's
// id + HOST even when the session is DISCONNECTED / transitioning. Telemetry
// (v0.1.10+70) showed `sessions.active` resolving to null during a disconnect,
// so main.dart propagated activeSessionId=null / activeHost=null and a same-host
// bell escaped suppression while the user was still on that very tab.
//
// SessionEntry.host is always present (it is parsed from the id at construction
// and never cleared by a disconnect), so the front-most entry's host is ALWAYS
// derivable when a tab exists. These tests pin the pure getters that main.dart
// uses to propagate a NON-NULL host whenever a front-most tab exists.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_session_proxy.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:xterm/xterm.dart';

SessionEntry _entry(String host, int port, String user, int ts) {
  final id = '$host:$port:$user:$ts';
  final pair = InMemoryGatewayPair();
  addTearDown(() async => pair.dispose());
  return SessionEntry(
    id: id,
    host: host,
    port: port,
    username: user,
    proxy: SshSessionProxy(sessionId: id, gateway: pair.uiSide),
    terminal: Terminal(),
  );
}

void main() {
  group('SessionsState front-most active', () {
    test('empty collection → null id and host', () {
      const state = SessionsState();
      expect(state.frontActiveId, isNull);
      expect(state.frontActiveHost, isNull);
    });

    test('activeId resolves an entry → its id and host', () {
      final a = _entry('alpha', 22, 'u', 1);
      final b = _entry('beta', 22, 'u', 2);
      final state = SessionsState(entries: [a, b], activeId: b.id);
      expect(state.frontActiveId, b.id);
      expect(state.frontActiveHost, 'beta');
    });

    test(
        'activeId is null but a front-most tab exists → falls back to '
        'entries.first id and host (the #936 disconnected case)', () {
      final a = _entry('alpha', 22, 'u', 1);
      final b = _entry('beta', 22, 'u', 2);
      // activeId null simulates the transient/disconnected state where
      // `active` would resolve null; the front-most tab (entries.first) is
      // still alpha and its host is always derivable.
      final state = SessionsState(entries: [a, b]);
      expect(state.frontActiveId, a.id,
          reason: 'must fall back to the front-most entry id');
      expect(state.frontActiveHost, 'alpha',
          reason: 'host is always derivable from the front-most entry');
    });

    test(
        'activeId references a missing entry → falls back to entries.first '
        '(non-null host)', () {
      final a = _entry('alpha', 22, 'u', 1);
      final state = SessionsState(entries: [a], activeId: 'gone:22:u:99');
      expect(state.frontActiveId, a.id);
      expect(state.frontActiveHost, 'alpha');
    });
  });
}
