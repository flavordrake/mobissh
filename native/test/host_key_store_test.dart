// Unit tests for HostKeyStore — in-memory trust map + persistence (#565).

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ssh/host_key_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('HostKeyStore', () {
    late HostKeyStore store;

    setUp(() {
      // Isolated in-memory backend per test so the trust map starts empty.
      store = HostKeyStore(backend: InMemoryHostKeyBackend());
    });

    test('isTrusted returns false for unknown host', () {
      expect(store.isTrusted('example.com', 22, 'aa:bb:cc'), isFalse);
    });

    test('trust + isTrusted round-trip', () {
      store.trust('example.com', 22, 'aabbcc');
      expect(store.isTrusted('example.com', 22, 'aabbcc'), isTrue);
    });

    test('isTrusted rejects mismatched fingerprint (key rotation)', () {
      store.trust('example.com', 22, 'aabbcc');
      expect(store.isTrusted('example.com', 22, 'deadbeef'), isFalse);
    });

    test('different ports are scoped separately', () {
      store.trust('example.com', 22, 'aabbcc');
      expect(store.isTrusted('example.com', 2222, 'aabbcc'), isFalse);
    });

    test('forget removes trust', () {
      store.trust('example.com', 22, 'aabbcc');
      store.forget('example.com', 22);
      expect(store.isTrusted('example.com', 22, 'aabbcc'), isFalse);
      expect(store.trustedFingerprint('example.com', 22), isNull);
    });

    test('trust overwrites previous fingerprint', () {
      store.trust('example.com', 22, 'aabbcc');
      store.trust('example.com', 22, 'newkey');
      expect(store.isTrusted('example.com', 22, 'aabbcc'), isFalse);
      expect(store.isTrusted('example.com', 22, 'newkey'), isTrue);
    });

    test('length reflects number of entries', () {
      expect(store.length, 0);
      store.trust('a', 22, 'fp1');
      store.trust('b', 22, 'fp2');
      expect(store.length, 2);
      store.forget('a', 22);
      expect(store.length, 1);
    });
  });

  // -------------------------------------------------------------------------
  // #565 persistence: trust must survive a NEW HostKeyStore instance (the
  // "app relaunch" / new-session-controller transition that was re-prompting).
  // -------------------------------------------------------------------------
  group('HostKeyStore persistence (#565)', () {
    test(
      'trust persists; a NEW store over the same backend hydrates as trusted',
      () async {
        final backend = InMemoryHostKeyBackend();

        // First store (this app session) trusts a host.
        final first = HostKeyStore(backend: backend);
        await first.ready;
        first.trust('example.com', 22, 'aabbcc');
        // Let the fire-and-forget persist land.
        await Future<void>.delayed(Duration.zero);

        // Second store (simulated app relaunch / new session) over the SAME
        // backing store must report the host trusted after hydration — WITHOUT
        // anyone calling trust() on it.
        final second = HostKeyStore(backend: backend);
        await second.ready;
        expect(second.isTrusted('example.com', 22, 'aabbcc'), isTrue);
        expect(second.trustedFingerprint('example.com', 22), 'aabbcc');
        expect(second.length, 1);
      },
    );

    test(
      'forget persists; a NEW store no longer reports the host trusted',
      () async {
        final backend = InMemoryHostKeyBackend();
        final first = HostKeyStore(backend: backend);
        await first.ready;
        first.trust('example.com', 22, 'aabbcc');
        await Future<void>.delayed(Duration.zero);
        first.forget('example.com', 22);
        await Future<void>.delayed(Duration.zero);

        final second = HostKeyStore(backend: backend);
        await second.ready;
        expect(second.isTrusted('example.com', 22, 'aabbcc'), isFalse);
        expect(second.length, 0);
      },
    );

    test(
      'SharedPreferences backend round-trips trust across instances',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});

        final first = HostKeyStore(backend: SharedPrefsHostKeyBackend());
        await first.ready;
        first.trust('host.example', 2222, 'deadbeef');
        await Future<void>.delayed(Duration.zero);

        // A brand-new store + brand-new backend reading the same mock prefs.
        final second = HostKeyStore(backend: SharedPrefsHostKeyBackend());
        await second.ready;
        expect(second.isTrusted('host.example', 2222, 'deadbeef'), isTrue);
      },
    );

    test('corrupt persisted JSON falls back to empty (no crash)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        hostKeysPrefsKey: 'not-json{{{',
      });
      final store = HostKeyStore(backend: SharedPrefsHostKeyBackend());
      await store.ready;
      expect(store.length, 0);
      expect(store.isTrusted('anything', 22, 'x'), isFalse);
    });
  });
}
