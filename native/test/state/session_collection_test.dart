// Unit tests for the multi-session collection (#511).
//
// Covers the SessionsNotifier contract:
//   - addOrActivate creates a new entry with the PWA session-id format
//   - duplicate host:port:user returns the existing entry (dedup)
//   - setActive updates activeSessionId
//   - close removes an entry and picks the next as active
//
// These are pure-state tests — no real SSH connect happens. The notifier's
// controller factory is overridden with a stub controller that never
// actually opens a socket.

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/sessions.dart';

SshSessionController _stubController() => SshSessionController(
      // Socket opener that never resolves — keeps the controller parked in
      // idle for the lifetime of the test.
      socketOpener: (host, port, {timeout}) =>
          Future<SSHSocket>.delayed(const Duration(days: 1), () {
        throw Exception('not used in unit tests');
      }),
    );

ProviderContainer _makeContainer() {
  return ProviderContainer(overrides: [
    sshSessionControllerFactoryProvider.overrideWithValue(_stubController),
  ]);
}

SshConnectParams _params({
  String host = 'h',
  int port = 22,
  String username = 'u',
}) {
  return SshConnectParams(
    host: host,
    port: port,
    username: username,
    auth: const SshAuth.password('p'),
  );
}

void main() {
  group('SessionsNotifier', () {
    test('initial state is empty with null activeId', () {
      final c = _makeContainer();
      addTearDown(c.dispose);
      final state = c.read(sessionsProvider);
      expect(state.entries, isEmpty);
      expect(state.activeId, isNull);
      expect(state.isEmpty, isTrue);
    });

    test('addOrActivate creates an entry with host:port:user:ts id format',
        () {
      final c = _makeContainer();
      addTearDown(c.dispose);
      final entry =
          c.read(sessionsProvider.notifier).addOrActivate(_params());
      // PWA format: `host:port:username:createdAtMs`
      expect(entry.id, startsWith('h:22:u:'));
      final parts = entry.id.split(':');
      expect(parts, hasLength(4));
      expect(int.tryParse(parts[3]), isNotNull,
          reason: 'createdAt suffix must be an integer ms timestamp');

      final state = c.read(sessionsProvider);
      expect(state.entries, hasLength(1));
      expect(state.activeId, entry.id);
    });

    test(
        'addOrActivate with duplicate host:port:user returns the existing '
        'entry and sets it active', () {
      final c = _makeContainer();
      addTearDown(c.dispose);
      final notifier = c.read(sessionsProvider.notifier);

      final first = notifier.addOrActivate(_params(host: 'a'));
      final second = notifier.addOrActivate(_params(host: 'b'));
      // Switch active off `b`...
      notifier.setActive(first.id);
      expect(c.read(sessionsProvider).activeId, first.id);

      // ...then reconnecting profile `b` should reactivate the existing
      // session rather than creating a duplicate.
      final dup = notifier.addOrActivate(_params(host: 'b'));
      expect(dup.id, second.id, reason: 'dedup must return existing entry');
      expect(c.read(sessionsProvider).entries, hasLength(2));
      expect(c.read(sessionsProvider).activeId, second.id);
    });

    test('setActive switches the active id', () {
      final c = _makeContainer();
      addTearDown(c.dispose);
      final notifier = c.read(sessionsProvider.notifier);

      final a = notifier.addOrActivate(_params(host: 'a'));
      final b = notifier.addOrActivate(_params(host: 'b'));
      expect(c.read(sessionsProvider).activeId, b.id);

      notifier.setActive(a.id);
      expect(c.read(sessionsProvider).activeId, a.id);
    });

    test('close removes the entry and picks the next as active', () {
      final c = _makeContainer();
      addTearDown(c.dispose);
      final notifier = c.read(sessionsProvider.notifier);

      final a = notifier.addOrActivate(_params(host: 'a'));
      final b = notifier.addOrActivate(_params(host: 'b'));
      expect(c.read(sessionsProvider).activeId, b.id);

      notifier.close(b.id);
      final state = c.read(sessionsProvider);
      expect(state.entries, hasLength(1));
      expect(state.entries.first.id, a.id);
      expect(state.activeId, a.id,
          reason: 'closing the active session must pick a remaining one');
    });

    test('close on the last entry sets activeId to null', () {
      final c = _makeContainer();
      addTearDown(c.dispose);
      final notifier = c.read(sessionsProvider.notifier);

      final a = notifier.addOrActivate(_params());
      notifier.close(a.id);
      expect(c.read(sessionsProvider).entries, isEmpty);
      expect(c.read(sessionsProvider).activeId, isNull);
    });

    test('findByProfile matches on host:port:user', () {
      final c = _makeContainer();
      addTearDown(c.dispose);
      final notifier = c.read(sessionsProvider.notifier);

      final a = notifier.addOrActivate(_params(host: 'a', port: 22));
      notifier.addOrActivate(_params(host: 'b', port: 22));

      final hit = notifier.findByProfile(host: 'a', port: 22, username: 'u');
      expect(hit?.id, a.id);

      final miss =
          notifier.findByProfile(host: 'a', port: 2222, username: 'u');
      expect(miss, isNull);
    });
  });
}
