// Unit tests for the persisted saved-profile order (#481).
//
// Covers the pure helpers (applyOrder / reconcileOrder) and the
// ProfileOrderNotifier (moveToTop/Bottom/reorder persist + round-trip via a
// SharedPreferences mock; corrupt value → empty order).

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/profile_order_providers.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

SavedProfile _p(String host, {String user = 'u', int port = 22}) =>
    SavedProfile(title: '$user@$host', host: host, port: port, username: user);

List<String> _keys(List<SavedProfile> ps) =>
    ps.map((p) => p.identityKey).toList();

void main() {
  group('applyOrder (pure)', () {
    final a = _p('a');
    final b = _p('b');
    final c = _p('c');

    test('orders profiles by the given key order', () {
      final out = applyOrder([a, b, c], [c.identityKey, a.identityKey, b.identityKey]);
      expect(_keys(out), [c.identityKey, a.identityKey, b.identityKey]);
    });

    test('unknown profile IDs (not in order) append in original order', () {
      // Only `b` is ordered; a and c are appended in their list order.
      final out = applyOrder([a, b, c], [b.identityKey]);
      expect(_keys(out), [b.identityKey, a.identityKey, c.identityKey]);
    });

    test('order entries with no matching profile are ignored', () {
      final out = applyOrder([a, b], ['z:22:gone', b.identityKey, a.identityKey]);
      expect(_keys(out), [b.identityKey, a.identityKey]);
    });

    test('empty order preserves insertion order', () {
      final out = applyOrder([a, b, c], const []);
      expect(_keys(out), [a.identityKey, b.identityKey, c.identityKey]);
    });

    test('empty profiles yields empty', () {
      expect(applyOrder(const [], [a.identityKey]), isEmpty);
    });
  });

  group('reconcileOrder (pure)', () {
    test('keeps known keys in stored order, drops missing, appends new', () {
      final keys = ['a:22:u', 'c:22:u', 'd:22:u'];
      final stored = ['b:22:u', 'c:22:u', 'a:22:u']; // b gone, d new
      expect(reconcileOrder(keys, stored), ['c:22:u', 'a:22:u', 'd:22:u']);
    });

    test('empty stored order yields profile keys in their order', () {
      expect(reconcileOrder(['a:22:u', 'b:22:u'], const []),
          ['a:22:u', 'b:22:u']);
    });
  });

  group('decode/encode round-trip + corrupt resilience', () {
    test('decode of a fresh encode preserves the list', () {
      final order = ['a:22:u', 'b:2222:me'];
      expect(decodeProfileOrder(encodeProfileOrder(order)), order);
    });

    test('null / empty / garbage / wrong-shape → empty', () {
      expect(decodeProfileOrder(null), isEmpty);
      expect(decodeProfileOrder(''), isEmpty);
      expect(decodeProfileOrder('not json'), isEmpty);
      expect(decodeProfileOrder('[1,2,3]'), isEmpty);
      expect(decodeProfileOrder('{"order":["a"]}'), isEmpty); // no version
    });

    test('unknown schema version → empty', () {
      expect(decodeProfileOrder('{"version":99,"order":["a:22:u"]}'), isEmpty);
    });

    test('drops non-string / blank / duplicate entries', () {
      expect(
        decodeProfileOrder('{"version":1,"order":["a:22:u",2,"","a:22:u","b:22:u"]}'),
        ['a:22:u', 'b:22:u'],
      );
    });
  });

  group('ProfileOrderNotifier — persistence', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('starts empty when nothing stored', () async {
      final prefs = SharedPreferences.getInstance();
      final n = ProfileOrderNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);
      expect(n.state, isEmpty);
    });

    test('sync seeds the order from the live profile set and persists', () async {
      final prefs = SharedPreferences.getInstance();
      final n = ProfileOrderNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);
      await n.sync(['a:22:u', 'b:22:u', 'c:22:u']);
      expect(n.state, ['a:22:u', 'b:22:u', 'c:22:u']);

      // A fresh notifier hydrates the persisted order.
      final n2 = ProfileOrderNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);
      expect(n2.state, ['a:22:u', 'b:22:u', 'c:22:u']);
    });

    test('moveToTop persists + round-trips', () async {
      final prefs = SharedPreferences.getInstance();
      final n = ProfileOrderNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);
      await n.sync(['a:22:u', 'b:22:u', 'c:22:u']);
      await n.moveToTop('c:22:u');
      expect(n.state, ['c:22:u', 'a:22:u', 'b:22:u']);

      final n2 = ProfileOrderNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);
      expect(n2.state, ['c:22:u', 'a:22:u', 'b:22:u']);
    });

    test('moveToBottom persists', () async {
      final prefs = SharedPreferences.getInstance();
      final n = ProfileOrderNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);
      await n.sync(['a:22:u', 'b:22:u', 'c:22:u']);
      await n.moveToBottom('a:22:u');
      expect(n.state, ['b:22:u', 'c:22:u', 'a:22:u']);
    });

    test('reorder moves an item to the post-removal destination index', () async {
      final prefs = SharedPreferences.getInstance();
      final n = ProfileOrderNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);
      await n.sync(['a:22:u', 'b:22:u', 'c:22:u']);
      // onReorderItem contract: drag item 0 to sit after item 1 → newIndex=1
      // (destination after the dragged item is removed).
      await n.reorder(0, 1);
      expect(n.state, ['b:22:u', 'a:22:u', 'c:22:u']);

      // Persisted.
      final n2 = ProfileOrderNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);
      expect(n2.state, ['b:22:u', 'a:22:u', 'c:22:u']);
    });

    test('move/reorder are no-ops for unknown / out-of-range', () async {
      final prefs = SharedPreferences.getInstance();
      final n = ProfileOrderNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);
      await n.sync(['a:22:u', 'b:22:u']);
      await n.moveToTop('gone:22:u');
      await n.reorder(9, 0);
      expect(n.state, ['a:22:u', 'b:22:u']);
    });

    test('sync drops a deleted profile + appends a new one', () async {
      final prefs = SharedPreferences.getInstance();
      final n = ProfileOrderNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);
      await n.sync(['a:22:u', 'b:22:u', 'c:22:u']);
      await n.moveToTop('c:22:u'); // c,a,b
      // b deleted, d added.
      await n.sync(['a:22:u', 'c:22:u', 'd:22:u']);
      expect(n.state, ['c:22:u', 'a:22:u', 'd:22:u']);
    });

    test('corrupt stored value hydrates to empty (no crash)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        profileOrderPrefKey: 'totally not json',
      });
      final prefs = SharedPreferences.getInstance();
      final n = ProfileOrderNotifier(prefs: prefs);
      await Future<void>.delayed(Duration.zero);
      expect(n.state, isEmpty);
    });
  });
}
