// Unit tests for the multi-session collection (#511, #533).
//
// Covers the SessionsNotifier contract:
//   - addOrActivate creates a new entry with the PWA session-id format
//   - duplicate host:port:user returns the existing entry (dedup)
//   - setActive updates activeSessionId
//   - close removes an entry and picks the next as active
//
// These are pure-state tests — no real SSH connect happens. The notifier
// constructs a per-session [SshSessionProxy] via [taskSshGatewayProvider];
// tests override that with an in-memory gateway pair so commands round-trip
// to a stub `SessionHost` without binding to platform channels (#533).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session_proxy.dart';
import 'package:mobissh/state/keepalive_providers.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

ProviderContainer _makeContainer({void Function()? onStart}) {
  return _makeContainerWithPair(onStart: onStart).$1;
}

/// Like [_makeContainer] but also returns the in-memory gateway pair so a test
/// can observe UI→task commands on `pair.taskSide.incoming` (#817).
///
/// When [profiles] / [secrets] are supplied they back the profiles + secrets
/// providers so the #817 Reconnect revive path can re-resolve credentials
/// deterministically (no platform channels).
(ProviderContainer, InMemoryGatewayPair) _makeContainerWithPair({
  void Function()? onStart,
  ProfilesStore? profiles,
  SecretsStore? secrets,
}) {
  final pair = InMemoryGatewayPair();
  final container = ProviderContainer(overrides: [
    taskSshGatewayProvider.overrideWithValue(pair.uiSide),
    if (onStart != null)
      keepaliveServiceStarterProvider.overrideWithValue(() async {
        onStart();
      }),
    if (profiles != null) profilesStoreProvider.overrideWithValue(profiles),
    if (secrets != null) secretsStoreProvider.overrideWithValue(secrets),
  ]);
  addTearDown(() async {
    await pair.dispose();
  });
  return (container, pair);
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

    test('addOrActivate constructs a SshSessionProxy per entry (#533)', () {
      final c = _makeContainer();
      addTearDown(c.dispose);
      final entry =
          c.read(sessionsProvider.notifier).addOrActivate(_params());
      expect(entry.proxy, isA<SshSessionProxy>());
      expect(entry.proxy.sessionId, entry.id);
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

    // #817 regression: tapping Reconnect on a dropped session must (re)START the
    // foreground task isolate AND re-establish the session. Disconnecting the
    // last session stops the service, tearing down the task isolate + its host
    // session (held params + creds). A bare proxy.reconnect() then (a) buffers
    // against a dead isolate and (b) reaches a FRESH host with no record of the
    // session — a double no-op, so the session never revives (the device-only
    // bug the emulator gate caught). The fix routes Reconnect through the
    // notifier, which restarts the service (idempotent starter) and re-resolves
    // credentials from the saved profile to re-issue a FULL connect — the
    // task-side host rehosts + connects (or routes to reconnectNow when the
    // session survived).
    test('reconnect(id) restarts the service and re-issues a credentialed '
        'connect from the saved profile', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final profilesStore = ProfilesStore(prefs: prefs);
      final secretsStore =
          SecretsStore(backend: InMemorySecretsBackend());
      // Seed a saved profile matching the session identity + its vault secret.
      await profilesStore.save([
        SavedProfile(
          title: 'host',
          host: 'h',
          port: 22,
          username: 'u',
          authType: 'password',
          vaultId: 'vault-1',
        ),
      ]);
      await secretsStore.write('vault-1', {'password': 'sekret'});

      var starts = 0;
      final (c, pair) = _makeContainerWithPair(
        onStart: () => starts++,
        profiles: profilesStore,
        secrets: secretsStore,
      );
      addTearDown(c.dispose);

      // Capture commands the task isolate receives over the gateway.
      final taskSeen = <Map<String, dynamic>>[];
      final taskSub = pair.taskSide.incoming.listen(taskSeen.add);
      addTearDown(taskSub.cancel);

      final entry = c.read(sessionsProvider.notifier).addOrActivate(_params());
      await Future<void>.delayed(Duration.zero);
      final startsAfterConnect = starts;
      expect(startsAfterConnect, greaterThanOrEqualTo(1),
          reason: 'addOrActivate already starts the service once');
      taskSeen.clear();

      c.read(sessionsProvider.notifier).reconnect(entry.id);
      // Settle the starter future + the async profile/secret resolution.
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(starts, greaterThan(startsAfterConnect),
          reason: 'reconnect must (re)start the keepalive service');
      final connect = taskSeen.firstWhere(
        (m) =>
            m['sessionId'] == entry.id &&
            m['kind'] == SshTaskCommandKind.connect.name,
        orElse: () => <String, dynamic>{},
      );
      expect(connect, isNotEmpty,
          reason: 'a credentialed connect must reach the task side on revive');
      // The re-issued connect must carry the re-resolved auth (no user prompt).
      expect(connect['auth'], isNotNull,
          reason: 'revive connect must re-supply auth from the vault');
    });

    // Fallback: an ad-hoc session with no matching saved profile still revives
    // via the held-params reconnect command (no creds to re-resolve).
    test('reconnect(id) with no saved profile falls back to a reconnect '
        'command', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var starts = 0;
      final (c, pair) = _makeContainerWithPair(
        onStart: () => starts++,
        profiles: ProfilesStore(prefs: prefs), // empty store
        secrets: SecretsStore(backend: InMemorySecretsBackend()),
      );
      addTearDown(c.dispose);
      final taskSeen = <Map<String, dynamic>>[];
      final taskSub = pair.taskSide.incoming.listen(taskSeen.add);
      addTearDown(taskSub.cancel);

      final entry = c.read(sessionsProvider.notifier).addOrActivate(_params());
      await Future<void>.delayed(Duration.zero);
      taskSeen.clear();

      c.read(sessionsProvider.notifier).reconnect(entry.id);
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(
        taskSeen.any((m) =>
            m['sessionId'] == entry.id &&
            m['kind'] == SshTaskCommandKind.reconnect.name),
        isTrue,
        reason: 'no saved creds → held-params reconnect command',
      );
    });

    test('reconnect(id) on an unknown id is a no-op', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var starts = 0;
      final (c, pair) = _makeContainerWithPair(
        onStart: () => starts++,
        profiles: ProfilesStore(prefs: prefs),
        secrets: SecretsStore(backend: InMemorySecretsBackend()),
      );
      addTearDown(c.dispose);
      final taskSeen = <Map<String, dynamic>>[];
      final taskSub = pair.taskSide.incoming.listen(taskSeen.add);
      addTearDown(taskSub.cancel);

      c.read(sessionsProvider.notifier).reconnect('does-not-exist');
      await Future<void>.delayed(Duration.zero);
      expect(starts, 0,
          reason: 'unknown id must not start the service');
      expect(taskSeen, isEmpty,
          reason: 'unknown id must not send anything');
    });
  });
}
