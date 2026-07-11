// Per-profile default port forwards — persistence round-trip (#1047).
//
// Mirrors profile_default_path_test.dart: the `forwards` field follows the
// schema-in-value conventions (absent field on an OLD profile reads back as
// [], corrupt entries are dropped, no key bump), and `setForwards` upserts the
// list onto the matching identity without materializing ad-hoc profiles.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProfileForward json (#1047)', () {
    test('round-trips all fields', () {
      const fwd = ProfileForward(
        localPort: 18088,
        remoteHost: 'db.internal',
        remotePort: 5432,
      );
      final restored = ProfileForward.fromJson(fwd.toJson());
      expect(restored, isNotNull);
      expect(restored!.localPort, 18088);
      expect(restored.remoteHost, 'db.internal');
      expect(restored.remotePort, 5432);
    });

    test('invalid ports / missing fields yield null (corrupt resilience)', () {
      expect(ProfileForward.fromJson(const {}), isNull);
      expect(
        ProfileForward.fromJson(const {
          'localPort': 0,
          'remoteHost': 'h',
          'remotePort': 80,
        }),
        isNull,
      );
      expect(
        ProfileForward.fromJson(const {
          'localPort': 80,
          'remoteHost': 'h',
          'remotePort': 700000,
        }),
        isNull,
      );
    });

    test('empty remoteHost defaults to 127.0.0.1', () {
      final restored = ProfileForward.fromJson(const {
        'localPort': 18088,
        'remotePort': 8088,
      });
      expect(restored, isNotNull);
      expect(restored!.remoteHost, '127.0.0.1');
    });
  });

  group('SavedProfile.forwards (#1047)', () {
    test('absent field reads back as empty list (legacy profile)', () {
      final p = SavedProfile.fromJson(const {
        'title': 't',
        'host': 'h',
        'port': 22,
        'username': 'u',
      });
      expect(p.forwards, isEmpty);
    });

    test('round-trips through toJson/fromJson', () {
      final p = SavedProfile(
        title: 't',
        host: 'h',
        port: 22,
        username: 'u',
        forwards: const [
          ProfileForward(
            localPort: 18088,
            remoteHost: '127.0.0.1',
            remotePort: 8088,
          ),
        ],
      );
      final restored = SavedProfile.fromJson(p.toJson());
      expect(restored.forwards, hasLength(1));
      expect(restored.forwards.single.localPort, 18088);
      expect(restored.forwards.single.remotePort, 8088);
    });

    test('empty forwards is OMITTED from json (legacy byte-stability)', () {
      final p = SavedProfile(title: 't', host: 'h', port: 22, username: 'u');
      expect(p.toJson().containsKey('forwards'), isFalse);
    });

    test('corrupt entries inside the list are dropped, valid ones kept', () {
      final p = SavedProfile.fromJson(const {
        'title': 't',
        'host': 'h',
        'port': 22,
        'username': 'u',
        'forwards': [
          {'localPort': 18088, 'remoteHost': 'x', 'remotePort': 8088},
          'garbage',
          {'localPort': -1, 'remoteHost': 'x', 'remotePort': 8088},
        ],
      });
      expect(p.forwards, hasLength(1));
      expect(p.forwards.single.localPort, 18088);
    });
  });

  group('ProfilesStore.setForwards (#1047)', () {
    test('persists onto the matching identity, survives reload', () async {
      SharedPreferences.setMockInitialValues({
        profilesPrefsKey: jsonEncode([
          {'title': 'box', 'host': 'h', 'port': 22, 'username': 'u'},
        ]),
      });
      final store = ProfilesStore();
      final ok = await store.setForwards('h:22:u', const [
        ProfileForward(
          localPort: 18088,
          remoteHost: '127.0.0.1',
          remotePort: 8088,
        ),
      ]);
      expect(ok, isTrue);

      final reloaded = await ProfilesStore().load();
      expect(reloaded.single.forwards, hasLength(1));
      expect(reloaded.single.forwards.single.localPort, 18088);
    });

    test('NO-OP (returns false) for an unknown identity — never materializes',
        () async {
      SharedPreferences.setMockInitialValues({});
      final store = ProfilesStore();
      final ok = await store.setForwards('nope:22:u', const [
        ProfileForward(
          localPort: 1,
          remoteHost: 'h',
          remotePort: 2,
        ),
      ]);
      expect(ok, isFalse);
      expect(await store.load(), isEmpty);
    });

    test('setting an empty list clears persisted forwards', () async {
      SharedPreferences.setMockInitialValues({
        profilesPrefsKey: jsonEncode([
          {
            'title': 'box',
            'host': 'h',
            'port': 22,
            'username': 'u',
            'forwards': [
              {'localPort': 18088, 'remoteHost': 'x', 'remotePort': 8088},
            ],
          },
        ]),
      });
      final store = ProfilesStore();
      final ok = await store.setForwards('h:22:u', const []);
      expect(ok, isTrue);
      final reloaded = await ProfilesStore().load();
      expect(reloaded.single.forwards, isEmpty);
    });
  });
}
