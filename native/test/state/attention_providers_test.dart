// Attention focus router WIRING backfill (#1163, coverage U5).
//
// `attentionFocusRouterProvider` binds three seams into the pure
// [AttentionFocusRouter] — the #857/#870/#885 saga root that was previously
// only device-validated:
//
//   * `resolveLiveSessionForHost` (#857): the MOST-RECENT live session for a
//     host (largest trailing `createdAtMs` of `host:port:user:createdAtMs`).
//   * `_reconnectHostFromProfile` (#885): dead-host tap → resolve the saved
//     profile + vault creds and re-connect through the EXISTING connect flow
//     (key when the profile has a key, password otherwise, null → cancel).
//   * `cancelHostNotification` (#885): a BARE FLN `cancel(id, tag)` for the
//     host's notification slot.
//
// The seams are private closures on the router, so every test drives them the
// way production does — `router.consumePending()` on the provider-built
// router. The provider's bridge is `PendingFocusBridge(FftKeyValueStore())`;
// FFT's data store is SharedPreferences-backed, so `setMockInitialValues`
// makes it live here and the test seeds the pending payload through the very
// same store. Sessions run on the real `sessionsProvider` (in-memory gateway
// pair, no-op keepalive starter); FLN is pinned at the method-channel level
// (android platform + `AndroidFlutterLocalNotificationsPlugin.registerWith`),
// so NO lib seam was needed.
//
// `attentionUiFlnInitProvider` is out of scope (issue: accept).

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/attention_notifier_fln.dart';
import 'package:mobissh/services/session_attention_notification.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_session_proxy.dart';
import 'package:mobissh/state/attention_providers.dart';
import 'package:mobissh/state/keepalive_providers.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

const _flnChannel = MethodChannel('dexterous.com/flutter/local_notifications');

/// Seeded [SessionsNotifier]: `build()` starts from [_seed] so a test can pin
/// EXPLICIT `createdAtMs` nonces (a real `addOrActivate` stamps `now`, and two
/// adds in the same millisecond would tie). Everything else — `setActive`,
/// `close`, the reconnect path's `addOrActivate` — is the real notifier.
class _SeededSessions extends SessionsNotifier {
  _SeededSessions(this._seed);
  final List<SessionEntry> _seed;

  @override
  SessionsState build() =>
      SessionsState(entries: _seed, activeId: _seed.isEmpty ? null : _seed.first.id);
}

SessionEntry _entry(InMemoryGatewayPair pair, String host, String user, int ts) {
  final id = '$host:22:$user:$ts';
  return SessionEntry(
    id: id,
    host: host,
    port: 22,
    username: user,
    proxy: SshSessionProxy(sessionId: id, gateway: pair.uiSide),
    terminal: Terminal(),
  );
}

/// Records every FLN method-channel call. The plugin routes `cancel(id, tag:)`
/// to the Android implementation only when the target platform is android AND
/// `FlutterLocalNotificationsPlatform.instance` is the Android plugin — the
/// same registration `initializeAttentionFln` relies on in production.
List<MethodCall> _mockFln() {
  final calls = <MethodCall>[];
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_flnChannel, (call) async {
    calls.add(call);
    return null;
  });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_flnChannel, null);
    debugDefaultTargetPlatformOverride = null;
  });
  return calls;
}

Future<void> _seedPending(String sessionId) =>
    PendingFocusBridge(const FftKeyValueStore())
        .setPendingFromPayload(jsonEncode({'sessionId': sessionId}));

class _Fixture {
  _Fixture({
    required this.container,
    required this.pair,
    required this.profiles,
    required this.secrets,
    required this.flnCalls,
    required this.taskSeen,
  });
  final ProviderContainer container;
  final InMemoryGatewayPair pair;
  final ProfilesStore profiles;
  final SecretsStore secrets;
  final List<MethodCall> flnCalls;

  /// Commands the task isolate received over the gateway (the reconnect
  /// path's `proxy.connect` lands here as a `connect` command carrying auth).
  final List<Map<String, dynamic>> taskSeen;

  SessionsNotifier get sessions => container.read(sessionsProvider.notifier);
  SessionsState get state => container.read(sessionsProvider);

  Future<String?> consume() =>
      container.read(attentionFocusRouterProvider).consumePending();

  Map<String, dynamic>? connectFor(String host) {
    for (final m in taskSeen) {
      if (m['kind'] == SshTaskCommandKind.connect.name &&
          hostOfSessionId(m['sessionId'] as String) == host) {
        return m;
      }
    }
    return null;
  }
}

Future<_Fixture> _fixture({
  List<SessionEntry> Function(InMemoryGatewayPair pair)? seed,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final profiles = ProfilesStore(prefs: prefs);
  final secrets = SecretsStore(backend: InMemorySecretsBackend());
  final pair = InMemoryGatewayPair();
  addTearDown(() async => pair.dispose());
  final entries = seed?.call(pair) ?? const <SessionEntry>[];
  final container = ProviderContainer(overrides: [
    taskSshGatewayProvider.overrideWithValue(pair.uiSide),
    keepaliveServiceStarterProvider.overrideWithValue(() async {}),
    profilesStoreProvider.overrideWithValue(profiles),
    secretsStoreProvider.overrideWithValue(secrets),
    sessionsProvider.overrideWith(() => _SeededSessions(entries)),
  ]);
  addTearDown(container.dispose);
  final taskSeen = <Map<String, dynamic>>[];
  final sub = pair.taskSide.incoming.listen(taskSeen.add);
  addTearDown(sub.cancel);
  return _Fixture(
    container: container,
    pair: pair,
    profiles: profiles,
    secrets: secrets,
    flnCalls: _mockFln(),
    taskSeen: taskSeen,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('attentionFocusRouterProvider wiring (#1163)', () {
    group('(a) resolveLiveSessionForHost — most-recent live session (#857)', () {
      test('stale payload id, host has 2 live sessions → the NEWER createdAt '
          'wins, even when the older one is the active tab', () async {
        final f = await _fixture(
          seed: (pair) => [
            _entry(pair, 'fddev', 'old', 100), // seeded first → active tab
            _entry(pair, 'other', 'u', 150), // different host, newest overall
            _entry(pair, 'fddev', 'new', 200),
          ],
        );
        await _seedPending('fddev:22:gone:5'); // exact id no longer live

        final focused = await f.consume();

        expect(focused, 'fddev:22:new:200',
            reason: 'host fallback must pick the largest createdAt for fddev');
        expect(f.state.activeId, 'fddev:22:new:200');
        expect(f.flnCalls, isEmpty,
            reason: 'a delivered tap never cancels the notification');
        expect(f.connectFor('fddev'), isNull,
            reason: 'a live host never reconnects');
      });

      test('newer session closes → the OLDER session is the fallback', () async {
        final f = await _fixture(
          seed: (pair) => [
            _entry(pair, 'fddev', 'old', 100),
            _entry(pair, 'fddev', 'new', 200),
          ],
        );
        f.sessions.close('fddev:22:new:200');
        await _seedPending('fddev:22:gone:5');

        final focused = await f.consume();

        expect(focused, 'fddev:22:old:100');
        expect(f.state.activeId, 'fddev:22:old:100');
      });

      test('insertion order does not matter — newest createdAt wins when it is '
          'seeded FIRST', () async {
        final f = await _fixture(
          seed: (pair) => [
            _entry(pair, 'fddev', 'new', 200),
            _entry(pair, 'fddev', 'old', 100),
          ],
        );
        await _seedPending('fddev:22:gone:5');
        expect(await f.consume(), 'fddev:22:new:200');
      });

      test('exact payload id still live → it is focused directly (no fallback), '
          'even when a NEWER session for the host exists', () async {
        final f = await _fixture(
          seed: (pair) => [
            _entry(pair, 'fddev', 'old', 100),
            _entry(pair, 'fddev', 'new', 200),
          ],
        );
        await _seedPending('fddev:22:old:100');
        expect(await f.consume(), 'fddev:22:old:100');
        expect(f.state.activeId, 'fddev:22:old:100');
      });
    });

    group('(b) reconnectHost — profile → credential (#885)', () {
      const pem = '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n'
          '-----END OPENSSH PRIVATE KEY-----\n';

      test('profile with keyVaultId → reconnects with KEY auth (+ passphrase), '
          'focuses the new session, no cancel', () async {
        final f = await _fixture();
        await f.profiles.save([
          SavedProfile(
            title: 'dev',
            host: 'fddev',
            port: 22,
            username: 'me',
            authType: 'key',
            keyVaultId: 'kv-1',
          ),
        ]);
        await f.secrets.write('kv-1', {'data': pem, 'passphrase': 'pp'});
        await _seedPending('fddev:22:me:5');

        final focused = await f.consume();
        await Future<void>.delayed(Duration.zero); // let proxy.connect flush

        expect(focused, isNotNull);
        expect(focused, startsWith('fddev:22:me:'),
            reason: 'the reconnect must create a session for the profile');
        expect(f.state.activeId, focused,
            reason: 'the router focuses the reconnected session');
        expect(f.state.entries.single.title, 'dev',
            reason: 'the profile title carries into the new entry');
        final connect = f.connectFor('fddev');
        expect(connect, isNotNull,
            reason: 'a credentialed connect must reach the task side');
        final auth = connect!['auth'] as Map;
        expect(auth['type'], 'key');
        expect(utf8.decode(base64Decode(auth['pem'] as String)), pem);
        expect(auth['passphrase'], 'pp');
        expect(f.flnCalls, isEmpty);
      });

      test('authType null but a key is stored → still KEY auth; empty '
          'passphrase → null', () async {
        final f = await _fixture();
        await f.profiles.save([
          SavedProfile(
            title: 'dev',
            host: 'fddev',
            port: 22,
            username: 'me',
            keyVaultId: 'kv-1',
          ),
        ]);
        await f.secrets.write('kv-1', {'data': pem, 'passphrase': ''});
        await _seedPending('fddev:22:me:5');

        expect(await f.consume(), isNotNull);
        await Future<void>.delayed(Duration.zero);
        final auth = f.connectFor('fddev')!['auth'] as Map;
        expect(auth['type'], 'key');
        expect(auth.containsKey('passphrase'), isFalse);
      });

      test('password-only profile → reconnects with PASSWORD auth', () async {
        final f = await _fixture();
        await f.profiles.save([
          SavedProfile(
            title: 'dev',
            host: 'fddev',
            port: 2222,
            username: 'me',
            authType: 'password',
            vaultId: 'v-1',
          ),
        ]);
        await f.secrets.write('v-1', {'password': 'sekret'});
        await _seedPending('fddev:22:me:5');

        final focused = await f.consume();
        await Future<void>.delayed(Duration.zero);

        expect(focused, startsWith('fddev:2222:me:'),
            reason: 'the PROFILE port/user are used, not the stale payload');
        final auth = f.connectFor('fddev')!['auth'] as Map;
        expect(auth['type'], 'password');
        expect(auth['password'], 'sekret');
        expect(f.flnCalls, isEmpty);
      });

      test('authType=key but no key stored (only a password) → null → '
          'cancel, no session created', () async {
        final f = await _fixture();
        await f.profiles.save([
          SavedProfile(
            title: 'dev',
            host: 'fddev',
            port: 22,
            username: 'me',
            authType: 'key',
            vaultId: 'v-1',
          ),
        ]);
        await f.secrets.write('v-1', {'password': 'sekret'});
        await _seedPending('fddev:22:me:5');

        expect(await f.consume(), isNull);
        expect(f.state.entries, isEmpty,
            reason: 'no usable credential → no half-built session');
        expect(f.flnCalls.map((c) => c.method), ['cancel']);
      });

      test('profile with NO stored credentials → null → cancel', () async {
        final f = await _fixture();
        await f.profiles.save([
          SavedProfile(title: 'dev', host: 'fddev', port: 22, username: 'me'),
        ]);
        await _seedPending('fddev:22:me:5');

        expect(await f.consume(), isNull);
        expect(f.state.entries, isEmpty);
        expect(f.taskSeen, isEmpty, reason: 'nothing reaches the task side');
        expect(f.flnCalls.map((c) => c.method), ['cancel']);
      });

      test('NO profile for the host → null → cancel', () async {
        final f = await _fixture();
        await f.profiles.save([
          SavedProfile(
            title: 'elsewhere',
            host: 'other',
            port: 22,
            username: 'me',
            authType: 'password',
            vaultId: 'v-1',
          ),
        ]);
        await f.secrets.write('v-1', {'password': 'sekret'});
        await _seedPending('fddev:22:me:5');

        expect(await f.consume(), isNull);
        expect(f.state.entries, isEmpty,
            reason: 'a different host\'s profile must never be reconnected');
        expect(f.flnCalls.map((c) => c.method), ['cancel']);
      });

      test('first profile matching the host wins (by host only, not port/user)',
          () async {
        final f = await _fixture();
        await f.profiles.save([
          SavedProfile(
            title: 'first',
            host: 'fddev',
            port: 22,
            username: 'alice',
            authType: 'password',
            vaultId: 'v-a',
          ),
          SavedProfile(
            title: 'second',
            host: 'fddev',
            port: 22,
            username: 'bob',
            authType: 'password',
            vaultId: 'v-b',
          ),
        ]);
        await f.secrets.write('v-a', {'password': 'a'});
        await f.secrets.write('v-b', {'password': 'b'});
        await _seedPending('fddev:22:bob:5'); // payload names bob…

        final focused = await f.consume();
        expect(focused, startsWith('fddev:22:alice:'),
            reason: 'the seam matches on host only — first profile wins');
      });
    });

    group('(c) cancelHostNotification — bare FLN cancel (#885)', () {
      test('dead host, no profile → exactly one cancel(id, tag) for the '
          'host slot and NO other plugin calls', () async {
        final f = await _fixture();
        await _seedPending('fddev:22:me:5');

        expect(await f.consume(), isNull);

        expect(f.flnCalls, hasLength(1));
        final call = f.flnCalls.single;
        expect(call.method, 'cancel');
        final tag = attentionTagForHost('fddev');
        expect(call.arguments, {'id': attentionIdForTag(tag), 'tag': tag});
      });

      test('cancel addresses the PAYLOAD host, not the active tab\'s host',
          () async {
        final f = await _fixture(
          seed: (pair) => [_entry(pair, 'other', 'u', 100)],
        );
        await _seedPending('fddev:22:me:5');

        expect(await f.consume(), isNull);
        expect(f.state.activeId, 'other:22:u:100',
            reason: 'never route a dead-host tap to a different host (#857)');
        final tag = attentionTagForHost('fddev');
        expect(f.flnCalls.single.arguments,
            {'id': attentionIdForTag(tag), 'tag': tag});
      });

      test('plugin cancel throws → swallowed, tap resolves null', () async {
        final f = await _fixture();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_flnChannel, (call) async {
          f.flnCalls.add(call);
          throw PlatformException(code: 'boom');
        });
        await _seedPending('fddev:22:me:5');

        expect(await f.consume(), isNull);
        expect(f.flnCalls.map((c) => c.method), ['cancel']);
      });
    });

    group('(d) unknown host → no throw', () {
      test('no sessions, no profiles → null, cancel only', () async {
        final f = await _fixture();
        await _seedPending('nowhere:22:me:5');

        expect(await f.consume(), isNull);
        expect(f.state.entries, isEmpty);
        expect(f.taskSeen, isEmpty);
        expect(f.flnCalls.map((c) => c.method), ['cancel']);
      });

      test('bare payload id without colons → host is the whole id; null, '
          'no throw', () async {
        final f = await _fixture(
          seed: (pair) => [_entry(pair, 'fddev', 'me', 100)],
        );
        await _seedPending('opaque-id');

        expect(await f.consume(), isNull);
        expect(f.state.activeId, 'fddev:22:me:100',
            reason: 'an unmatched host must not steal focus');
        final tag = attentionTagForHost('opaque-id');
        expect(f.flnCalls.single.arguments,
            {'id': attentionIdForTag(tag), 'tag': tag});
      });

      test('nothing pending → nothing happens', () async {
        final f = await _fixture(
          seed: (pair) => [_entry(pair, 'fddev', 'me', 100)],
        );
        expect(await f.consume(), isNull);
        expect(f.flnCalls, isEmpty);
        expect(f.taskSeen, isEmpty);
      });
    });
  });
}
