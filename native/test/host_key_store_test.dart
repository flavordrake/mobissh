// Unit tests for HostKeyStore — pure in-memory trust map.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ssh/host_key_store.dart';

void main() {
  group('HostKeyStore', () {
    late HostKeyStore store;

    setUp(() {
      store = HostKeyStore();
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
}
