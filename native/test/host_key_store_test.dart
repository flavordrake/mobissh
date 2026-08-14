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

    test('corrupt persisted JSON marks the store UNAVAILABLE (fail closed, '
        'no crash) — #1108', () async {
      // Regression: corrupt data used to silently fall back to an EMPTY map,
      // which downgrades every KNOWN host to "unknown" and re-opens the TOFU
      // accept prompt (fails open). It must fail CLOSED instead.
      SharedPreferences.setMockInitialValues(<String, Object>{
        hostKeysPrefsKey: 'not-json{{{',
      });
      final store = HostKeyStore(backend: SharedPrefsHostKeyBackend());
      await store.ready;
      expect(
        store.status('anything', 22, 'x'),
        HostKeyStatus.storeUnavailable,
        reason: 'corrupt store must not masquerade as a fresh/unknown host',
      );
    });
  });

  // -------------------------------------------------------------------------
  // #1108: a CHANGED host key must be distinguishable from first contact, and
  // must NEVER be trustable through the ordinary accept path.
  // -------------------------------------------------------------------------
  group('HostKeyStore status + trustIfUnknown (#1108)', () {
    test('status: no entry → unknown', () {
      final store = HostKeyStore(backend: InMemoryHostKeyBackend());
      expect(store.status('new.host', 22, 'aabb'), HostKeyStatus.unknown);
    });

    test('status: same fingerprint → match', () async {
      final store = HostKeyStore(
        backend: InMemoryHostKeyBackend(<String, String>{'h:22': 'aabb'}),
      );
      await store.ready;
      expect(store.status('h', 22, 'aabb'), HostKeyStatus.match);
    });

    test('status: DIFFERENT fingerprint → mismatch (NOT unknown)', () async {
      final store = HostKeyStore(
        backend: InMemoryHostKeyBackend(<String, String>{'h:22': 'aabb'}),
      );
      await store.ready;
      final s = store.status('h', 22, 'deadbeef');
      expect(s, HostKeyStatus.mismatch);
      expect(s, isNot(HostKeyStatus.unknown));
    });

    test('trustIfUnknown trusts an unknown host and returns true', () async {
      final store = HostKeyStore(backend: InMemoryHostKeyBackend());
      await store.ready;
      expect(store.trustIfUnknown('h', 22, 'aabb'), isTrue);
      expect(store.status('h', 22, 'aabb'), HostKeyStatus.match);
    });

    test('trustIfUnknown REJECTS a changed key (compare-and-set) and PRESERVES '
        'the stored fingerprint — the MITM evidence survives', () async {
      final store = HostKeyStore(
        backend: InMemoryHostKeyBackend(<String, String>{'h:22': 'aabb'}),
      );
      await store.ready;
      // The ordinary accept path cannot overwrite a differing key.
      expect(store.trustIfUnknown('h', 22, 'deadbeef'), isFalse);
      // The originally-trusted fingerprint is untouched.
      expect(store.trustedFingerprint('h', 22), 'aabb');
      expect(store.status('h', 22, 'deadbeef'), HostKeyStatus.mismatch);
    });

    test('re-trusting a changed key requires an EXPLICIT forget + trust',
        () async {
      final store = HostKeyStore(
        backend: InMemoryHostKeyBackend(<String, String>{'h:22': 'aabb'}),
      );
      await store.ready;
      // Ordinary path refuses.
      expect(store.trustIfUnknown('h', 22, 'deadbeef'), isFalse);
      // Deliberate re-trust affordance: forget, then trust.
      store.forget('h', 22);
      expect(store.status('h', 22, 'deadbeef'), HostKeyStatus.unknown);
      expect(store.trustIfUnknown('h', 22, 'deadbeef'), isTrue);
      expect(store.status('h', 22, 'deadbeef'), HostKeyStatus.match);
    });

    test('store unavailable → status storeUnavailable; a previously-known host '
        'is NOT downgraded to unknown (fail closed)', () async {
      final store = HostKeyStore(backend: _ThrowingBackend());
      await store.ready;
      expect(store.status('known.host', 22, 'aabb'),
          HostKeyStatus.storeUnavailable);
      // And the ordinary accept path cannot trust while unavailable.
      expect(store.trustIfUnknown('known.host', 22, 'aabb'), isFalse);
    });

    test('concurrent trust then forget writes are serialized — a forgotten '
        'entry is not resurrected by an out-of-order write', () async {
      // The first save (trust) resolves SLOWER than the second (forget). With
      // fire-and-forget writes the slow trust would land LAST and resurrect the
      // entry; a serialized write chain preserves call order.
      final backend = _DelayedReorderBackend(<Duration>[
        const Duration(milliseconds: 60),
        const Duration(milliseconds: 10),
      ]);
      final store = HostKeyStore(backend: backend);
      await store.ready;
      store.trust('h', 22, 'aabb');
      store.forget('h', 22);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(backend.store, isEmpty,
          reason: 'forget must win — writes serialize in call order');
    });
  });
}

/// A backend whose [loadAll] always throws — simulates unavailable/corrupt
/// storage so the store must fail closed (storeUnavailable) rather than empty.
class _ThrowingBackend implements HostKeyBackend {
  @override
  Future<Map<String, String>> loadAll() async =>
      throw StateError('backend unavailable');

  @override
  Future<void> saveAll(Map<String, String> map) async {}
}

/// A backend whose saves resolve after per-call delays (in call order). The
/// stored map reflects whichever save COMPLETES last, so a non-serialized
/// writer with a slow-then-fast delay pair resurrects the first write.
class _DelayedReorderBackend implements HostKeyBackend {
  _DelayedReorderBackend(this.delays);

  final List<Duration> delays;
  final Map<String, String> store = <String, String>{};
  int _i = 0;

  @override
  Future<Map<String, String>> loadAll() async => Map<String, String>.from(store);

  @override
  Future<void> saveAll(Map<String, String> map) async {
    final d = _i < delays.length ? delays[_i] : Duration.zero;
    _i++;
    await Future<void>.delayed(d);
    store
      ..clear()
      ..addAll(map);
  }
}
