// #1249: host-key trust must not be lost or resurrected across sessions.
//
// Before: every SshSessionController built its OWN HostKeyStore, each hydrated
// a private copy of the one persisted map, and every write overwrote the WHOLE
// map from that copy. Trusting host B in session 2 erased session 1's pin for
// host A (turning a later MITM into a first-contact prompt instead of the #1108
// CHANGED refusal), and any save could bring back a key forgotten via #1235.
// acceptHostKey also ignored a refused compare-and-set and connected anyway.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/ssh/host_key_store.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';

const _shaA = 'SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s';
const _shaB = 'SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU';
const _legacy = '00112233445566778899aabbccddeeff';

Uint8List _fp(String s) => Uint8List.fromList(utf8.encode(s));

SshConnectParams _params(String host) => SshConnectParams(
  host: host,
  port: 22,
  username: 'u',
  auth: const SshAuth.password('p'),
);

Future<void> _drain() => Future<void>.delayed(Duration.zero);

void main() {
  group('persistence is read-modify-write per key (#1249)', () {
    test('two sessions trusting different hosts: BOTH pins persist', () async {
      final backend = InMemoryHostKeyBackend();
      final s1 = HostKeyStore(backend: backend);
      final s2 = HostKeyStore(backend: backend);
      await s1.ready;
      await s2.ready;

      s1.trust('a.example', 22, _shaA);
      await _drain();
      s2.trust('b.example', 22, _shaB);
      await _drain();

      expect(await backend.loadAll(), <String, String>{
        'a.example:22': _shaA,
        'b.example:22': _shaB,
      }, reason: "session 2's save must not erase session 1's pin");
    });

    test('forget in session A is not resurrected by session B trusting '
        'another host', () async {
      final backend = InMemoryHostKeyBackend(<String, String>{
        'a.example:22': _shaA,
      });
      final sA = HostKeyStore(backend: backend);
      final sB = HostKeyStore(backend: backend);
      await sA.ready;
      await sB.ready;

      sA.forget('a.example', 22);
      await _drain();
      sB.trust('b.example', 22, _shaB);
      await _drain();

      expect(await backend.loadAll(), <String, String>{'b.example:22': _shaB});
    });

    test('a forget before hydration still persists, and keeps other pins',
        () async {
      final backend = InMemoryHostKeyBackend(<String, String>{
        'a.example:22': _shaA,
        'b.example:22': _shaB,
      });
      final s = HostKeyStore(backend: backend);
      s.forget('a.example', 22); // #1235: lands before hydration
      await s.ready;
      await _drain();
      expect(s.trustedFingerprint('a.example', 22), isNull);
      expect(await backend.loadAll(), <String, String>{'b.example:22': _shaB});
    });
  });

  group('one shared store in the task isolate (#1249)', () {
    test('the default SessionHost factory hands every controller the SAME '
        'store', () {
      final factory = sharedStoreControllerFactory(
        () => HostKeyStore(backend: InMemoryHostKeyBackend()),
      );
      final c1 = factory();
      final c2 = factory();
      addTearDown(c1.dispose);
      addTearDown(c2.dispose);
      expect(identical(c1.hostKeyStore, c2.hostKeyStore), isTrue);
    });

    test('a pin trusted in session 1 is CHANGED (fail closed) for session 2, '
        'never a first-contact prompt', () async {
      final factory = sharedStoreControllerFactory(
        () => HostKeyStore(backend: InMemoryHostKeyBackend()),
      );
      final c1 = factory();
      final c2 = factory();
      addTearDown(c1.dispose);
      addTearDown(c2.dispose);
      await c1.hostKeyStore.ready;

      final v1 = c1.verifyHostKeyForTest(_params('a.example'), 'ssh-ed25519',
          _fp(_shaA));
      await _drain();
      c1.acceptHostKey();
      expect(await v1, isTrue);

      final ok = await c2.verifyHostKeyForTest(
          _params('a.example'), 'ssh-ed25519', _fp(_shaB));
      expect(ok, isFalse);
      expect(c2.data.state, SshSessionState.failed);
      expect(c2.data.hostKeyMismatch, isNotNull);
    });
  });

  group('acceptHostKey honours the compare-and-set (#1249)', () {
    test('a refused CAS fails the connect', () async {
      final store = HostKeyStore(backend: InMemoryHostKeyBackend());
      await store.ready;
      final c = SshSessionController(hostKeyStore: store);
      addTearDown(c.dispose);

      final verify =
          c.verifyHostKeyForTest(_params('h.example'), 'ssh-ed25519', _fp(_shaA));
      await _drain();
      expect(c.data.state, SshSessionState.awaitingHostKey);

      // While the prompt is open another session pins a DIFFERENT key.
      store.trust('h.example', 22, _shaB);
      c.acceptHostKey();

      expect(await verify, isFalse, reason: 'refused CAS must not connect');
      expect(c.data.state, SshSessionState.failed);
      expect(c.data.error, contains('h.example:22'));
      expect(store.trustedFingerprint('h.example', 22), _shaB,
          reason: 'the other pin is untouched');
    });

    test('the same key trusted concurrently by another session still connects',
        () async {
      final store = HostKeyStore(backend: InMemoryHostKeyBackend());
      await store.ready;
      final c = SshSessionController(hostKeyStore: store);
      addTearDown(c.dispose);

      final verify =
          c.verifyHostKeyForTest(_params('h.example'), 'ssh-ed25519', _fp(_shaA));
      await _drain();
      store.trust('h.example', 22, _shaA);
      c.acceptHostKey();

      expect(await verify, isTrue);
      expect(c.data.state, SshSessionState.authenticating);
    });
  });

  group('format-changed re-confirm carries the stored fingerprint (#1249)', () {
    test('PendingHostKey.storedFingerprint is the legacy MD5', () async {
      final store = HostKeyStore(
        backend: InMemoryHostKeyBackend(<String, String>{
          'legacy.example:22': _legacy,
        }),
      );
      await store.ready;
      final c = SshSessionController(hostKeyStore: store);
      addTearDown(c.dispose);

      // ignore: unawaited_futures
      c.verifyHostKeyForTest(_params('legacy.example'), 'ssh-ed25519',
          _fp(_shaA));
      await _drain();
      final pending = c.data.pendingHostKey!;
      expect(pending.formatChanged, isTrue);
      expect(pending.storedFingerprint, _legacy);
      c.rejectHostKey();
    });

    test('a first-contact prompt has no stored fingerprint', () async {
      final store = HostKeyStore(backend: InMemoryHostKeyBackend());
      await store.ready;
      final c = SshSessionController(hostKeyStore: store);
      addTearDown(c.dispose);

      // ignore: unawaited_futures
      c.verifyHostKeyForTest(_params('new.example'), 'ssh-ed25519', _fp(_shaA));
      await _drain();
      expect(c.data.pendingHostKey!.storedFingerprint, isNull);
      c.rejectHostKey();
    });
  });
}
