// R1 model round-trip + A4 store rebinding (#1183, spec docs/jump-host.md
// R1, R2, R5, R6).
//
// `jumpIdentityKey` is a REFERENCE to another profile's `identityKey`
// (`host:port:username`), never an embedded copy of the hop's details (R2) —
// so the store has to keep the reference honest when the referent moves (R5)
// or disappears (R6).
//
// Corrupt-resilience per .claude/rules/code-style.md: an absent field is the
// schema migration (no prefs key bump, no version field), and anything
// unusable reads back as null rather than throwing.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/storage/profiles_store.dart';

SavedProfile _p(
  String host, {
  String? jump,
  int port = 22,
  String user = 'me',
}) => SavedProfile(
  title: host,
  host: host,
  port: port,
  username: user,
  jumpIdentityKey: jump,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('R1 — SavedProfile.jumpIdentityKey round-trip', () {
    test('toJson/fromJson preserves the reference', () {
      final p = _p('target.example', jump: 'bastion.example:2222:jumpuser');
      final back = SavedProfile.fromJson(p.toJson());
      expect(back.jumpIdentityKey, 'bastion.example:2222:jumpuser');
    });

    test('a profile without a jump host omits the key entirely', () {
      // Absent field = the migration signal; legacy profiles stay byte-identical.
      expect(_p('target.example').toJson().containsKey('jumpIdentityKey'), isFalse);
      expect(_p('target.example').jumpIdentityKey, isNull);
    });

    test('an absent field on legacy JSON reads back as null (no key bump)', () {
      final back = SavedProfile.fromJson(<String, dynamic>{
        'title': 'Old',
        'host': 'old.example',
        'port': 22,
        'username': 'me',
      });
      expect(back.jumpIdentityKey, isNull);
    });

    test('a non-String value reads back as null, it does not throw', () {
      for (final bad in <Object?>[42, true, <String>['a'], <String, String>{}]) {
        final back = SavedProfile.fromJson(<String, dynamic>{
          'title': 'X',
          'host': 'x.example',
          'port': 22,
          'username': 'me',
          'jumpIdentityKey': bad,
        });
        expect(back.jumpIdentityKey, isNull, reason: 'corrupt value: $bad');
      }
    });

    test('an empty string reads back as null', () {
      final back = SavedProfile.fromJson(<String, dynamic>{
        'title': 'X',
        'host': 'x.example',
        'port': 22,
        'username': 'me',
        'jumpIdentityKey': '',
      });
      expect(back.jumpIdentityKey, isNull);
    });

    test('copyWith can set and explicitly CLEAR the reference', () {
      final p = _p('target.example', jump: 'bastion.example:22:me');
      expect(p.copyWith(jumpIdentityKey: 'other.example:22:me').jumpIdentityKey,
          'other.example:22:me');
      expect(
        p.copyWith(clearJumpIdentityKey: true).jumpIdentityKey,
        isNull,
        reason: 'a null argument cannot clear through the ?? pattern — the '
            'clear needs its own flag',
      );
    });

    test('an edit of an unrelated field preserves the reference', () {
      // The editor rebuilds the whole entry on save; a dropped field here is
      // the same class of bug as the lost `forwards` (owner report 2026-09-04).
      final p = _p('target.example', jump: 'bastion.example:22:me');
      expect(p.copyWith(title: 'Renamed').jumpIdentityKey, 'bastion.example:22:me');
    });

    test('the prefs key is unchanged (no bump for this field)', () {
      expect(profilesPrefsKey, 'mobissh.profiles.v1');
    });
  });

  group('A4 / R5 — renaming a referent rebinds its referrers in the SAME write', () {
    late ProfilesStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      store = ProfilesStore();
    });

    test('a host change on the bastion rebinds the target that references it',
        () async {
      final bastion = _p('bastion.example');
      final target = _p('target.example', jump: bastion.identityKey);
      await store.save([bastion, target]);

      // The editor renamed the bastion's host.
      final renamed = _p('bastion-new.example');
      await store.upsert(renamed, previousIdentityKey: bastion.identityKey);

      final list = await store.load();
      final reloaded = list.firstWhere((p) => p.host == 'target.example');
      expect(
        reloaded.jumpIdentityKey,
        'bastion-new.example:22:me',
        reason: 'R5 — the reference must follow the identity, not dangle',
      );
    });

    test('a port change rebinds referrers', () async {
      final bastion = _p('bastion.example');
      final target = _p('target.example', jump: bastion.identityKey);
      await store.save([bastion, target]);

      await store.upsert(
        _p('bastion.example', port: 2222),
        previousIdentityKey: bastion.identityKey,
      );

      final list = await store.load();
      expect(
        list.firstWhere((p) => p.host == 'target.example').jumpIdentityKey,
        'bastion.example:2222:me',
      );
    });

    test('a username change rebinds referrers', () async {
      final bastion = _p('bastion.example');
      final target = _p('target.example', jump: bastion.identityKey);
      await store.save([bastion, target]);

      await store.upsert(
        _p('bastion.example', user: 'jumpuser'),
        previousIdentityKey: bastion.identityKey,
      );

      final list = await store.load();
      expect(
        list.firstWhere((p) => p.host == 'target.example').jumpIdentityKey,
        'bastion.example:22:jumpuser',
      );
    });

    test('EVERY referrer is rebound, not just the first', () async {
      final bastion = _p('bastion.example');
      final a = _p('a.example', jump: bastion.identityKey);
      final b = _p('b.example', jump: bastion.identityKey);
      await store.save([bastion, a, b]);

      await store.upsert(
        _p('bastion-new.example'),
        previousIdentityKey: bastion.identityKey,
      );

      final list = await store.load();
      expect(
        list.where((p) => p.jumpIdentityKey == 'bastion-new.example:22:me'),
        hasLength(2),
      );
    });

    test('an identity-preserving save leaves references untouched', () async {
      final bastion = _p('bastion.example');
      final target = _p('target.example', jump: bastion.identityKey);
      await store.save([bastion, target]);

      await store.upsert(
        SavedProfile(
          title: 'Bastion renamed',
          host: 'bastion.example',
          port: 22,
          username: 'me',
        ),
        previousIdentityKey: bastion.identityKey,
      );

      final list = await store.load();
      expect(
        list.firstWhere((p) => p.host == 'target.example').jumpIdentityKey,
        'bastion.example:22:me',
      );
    });

    test('the rebind lands in ONE write — no window with a dangling reference',
        () async {
      // Read back the raw prefs blob: both the renamed bastion and the rebound
      // referrer must be present in the single persisted value.
      final bastion = _p('bastion.example');
      final target = _p('target.example', jump: bastion.identityKey);
      await store.save([bastion, target]);

      await store.upsert(
        _p('bastion-new.example'),
        previousIdentityKey: bastion.identityKey,
      );

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(profilesPrefsKey)!;
      final decoded = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      expect(decoded.any((e) => e['host'] == 'bastion-new.example'), isTrue);
      expect(
        decoded.any((e) => e['jumpIdentityKey'] == 'bastion-new.example:22:me'),
        isTrue,
      );
      expect(
        decoded.any((e) => e['jumpIdentityKey'] == 'bastion.example:22:me'),
        isFalse,
      );
    });
  });

  group('A4 / R6 — deleting a referent names the referrers and clears them', () {
    late ProfilesStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      store = ProfilesStore();
    });

    test('referrersOf names every profile pointing at an identity', () async {
      final bastion = _p('bastion.example');
      final a = _p('a.example', jump: bastion.identityKey);
      final b = _p('b.example', jump: bastion.identityKey);
      final unrelated = _p('c.example');
      await store.save([bastion, a, b, unrelated]);

      final referrers = await store.referrersOf(bastion.identityKey);

      expect(
        referrers.map((p) => p.host).toSet(),
        {'a.example', 'b.example'},
        reason: 'R6 — the confirm dialog must be able to NAME what it breaks',
      );
    });

    test('referrersOf is empty when nothing references the identity', () async {
      await store.save([_p('bastion.example'), _p('a.example')]);
      expect(await store.referrersOf('bastion.example:22:me'), isEmpty);
    });

    test('remove() clears the referrers rather than leaving a dangling id', () async {
      final bastion = _p('bastion.example');
      final a = _p('a.example', jump: bastion.identityKey);
      await store.save([bastion, a]);

      await store.remove(host: 'bastion.example', port: 22, username: 'me');

      final list = await store.load();
      expect(list.map((p) => p.host), ['a.example']);
      expect(
        list.single.jumpIdentityKey,
        isNull,
        reason: 'R6 — confirming the delete clears the link; a dangling id is '
            'an invisible broken connection',
      );
    });

    test('remove() leaves unrelated references alone', () async {
      final bastion = _p('bastion.example');
      final other = _p('other.example');
      final a = _p('a.example', jump: other.identityKey);
      await store.save([bastion, other, a]);

      await store.remove(host: 'bastion.example', port: 22, username: 'me');

      final list = await store.load();
      expect(
        list.firstWhere((p) => p.host == 'a.example').jumpIdentityKey,
        other.identityKey,
      );
    });
  });
}
