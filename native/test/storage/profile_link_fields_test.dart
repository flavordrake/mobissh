// #1140 (PR B of #1117): `SavedProfile.linkAlias` / `linkAutoConnect` model,
// store uniqueness, and plain-import posture. Spec: docs/deep-link-intents.md
// §10, R5, R10, R12, R13.
//
// PINNED API (the implementation must match these names exactly):
//   SavedProfile({..., String? linkAlias, bool linkAutoConnect = false})
//   SavedProfile.copyWith({..., String? linkAlias, bool? linkAutoConnect})
//   SavedProfile.linkAlias   — validated on read: `^[A-Za-z0-9_-]{1,32}$`,
//                              anything else reads back as null (no key bump)
//   SavedProfile.linkAutoConnect — non-bool reads back as false
//   toJson: `linkAlias` omitted when null, `linkAutoConnect` omitted when
//           false, so a legacy profile round-trips byte-identical.
//   class LinkAliasConflictException implements Exception {
//     final String alias; final String heldByIdentityKey;
//   }
//   ProfilesStore.upsert throws LinkAliasConflictException (store untouched)
//   when a DIFFERENT identity already holds `profile.linkAlias`.
//
// Import posture (applyParsedImport, plain no-vault path):
//   - linkAutoConnect is NEVER installed by an import (same class as
//     initialCommand/forwards): existing identity keeps its prior value, a
//     new identity gets false — whatever the JSON says.
//   - linkAlias from the import is kept only when unique against the
//     existing list (and earlier entries of the same import); a colliding
//     alias is dropped, the existing holder keeps it.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/storage/profiles_store.dart';

SavedProfile _profile({
  String host = 'h.example',
  int port = 22,
  String username = 'u',
  String? linkAlias,
  bool linkAutoConnect = false,
}) =>
    SavedProfile(
      title: 't',
      host: host,
      port: port,
      username: username,
      linkAlias: linkAlias,
      linkAutoConnect: linkAutoConnect,
    );

Map<String, dynamic> _legacyJson() => <String, dynamic>{
      'title': 'Legacy',
      'host': 'legacy.example',
      'port': 22,
      'username': 'old',
      'theme': 'nord',
    };

/// A plain (no-vault) import envelope carrying one profile entry.
String _importJson(Map<String, dynamic> entry) => jsonEncode(<String, dynamic>{
      'version': 1,
      'profiles': [entry],
    });

Future<ImportResult> _plainImport(ProfilesStore store, String json) =>
    store.applyParsedImport(ProfilesStore.parseImport(json));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('SavedProfile link fields — read/coerce', () {
    test('absent fields read as linkAlias null / linkAutoConnect false', () {
      final p = SavedProfile.fromJson(_legacyJson());
      expect(p.linkAlias, isNull);
      expect(p.linkAutoConnect, isFalse);
    });

    test('valid alias and true flag read back verbatim', () {
      final p = SavedProfile.fromJson(<String, dynamic>{
        ..._legacyJson(),
        'linkAlias': 'a-b_C9',
        'linkAutoConnect': true,
      });
      expect(p.linkAlias, 'a-b_C9');
      expect(p.linkAutoConnect, isTrue);
    });

    test('a 32-char alias is the maximum and is kept', () {
      final alias = 'x' * 32;
      final p = SavedProfile.fromJson(<String, dynamic>{
        ..._legacyJson(),
        'linkAlias': alias,
      });
      expect(p.linkAlias, alias);
    });

    test('non-string linkAlias (42) coerces to null', () {
      final p = SavedProfile.fromJson(<String, dynamic>{
        ..._legacyJson(),
        'linkAlias': 42,
      });
      expect(p.linkAlias, isNull);
    });

    test('alias with disallowed characters ("bad alias!") coerces to null', () {
      final p = SavedProfile.fromJson(<String, dynamic>{
        ..._legacyJson(),
        'linkAlias': 'bad alias!',
      });
      expect(p.linkAlias, isNull);
    });

    test('33-char alias coerces to null', () {
      final p = SavedProfile.fromJson(<String, dynamic>{
        ..._legacyJson(),
        'linkAlias': 'y' * 33,
      });
      expect(p.linkAlias, isNull);
    });

    test('empty-string alias coerces to null', () {
      final p = SavedProfile.fromJson(<String, dynamic>{
        ..._legacyJson(),
        'linkAlias': '',
      });
      expect(p.linkAlias, isNull);
    });

    test('non-bool linkAutoConnect ("yes") coerces to false', () {
      final p = SavedProfile.fromJson(<String, dynamic>{
        ..._legacyJson(),
        'linkAutoConnect': 'yes',
      });
      expect(p.linkAutoConnect, isFalse);
    });

    test('numeric linkAutoConnect (1) coerces to false', () {
      final p = SavedProfile.fromJson(<String, dynamic>{
        ..._legacyJson(),
        'linkAutoConnect': 1,
      });
      expect(p.linkAutoConnect, isFalse);
    });
  });

  group('SavedProfile link fields — toJson', () {
    test('omits linkAlias when null and linkAutoConnect when false', () {
      final json = _profile().toJson();
      expect(json.containsKey('linkAlias'), isFalse);
      expect(json.containsKey('linkAutoConnect'), isFalse);
    });

    test('legacy profile round-trips byte-identical through fromJson/toJson',
        () {
      final legacy = _legacyJson();
      final roundTripped = SavedProfile.fromJson(legacy).toJson();
      expect(jsonEncode(roundTripped), jsonEncode(legacy));
    });

    test('emits both fields when set, and they survive a round trip', () {
      final p = _profile(linkAlias: 'box', linkAutoConnect: true);
      final json = p.toJson();
      expect(json['linkAlias'], 'box');
      expect(json['linkAutoConnect'], isTrue);

      final back = SavedProfile.fromJson(json);
      expect(back.linkAlias, 'box');
      expect(back.linkAutoConnect, isTrue);
    });
  });

  group('SavedProfile.copyWith', () {
    test('carries linkAlias and linkAutoConnect when not overridden', () {
      final p = _profile(linkAlias: 'box', linkAutoConnect: true);
      final copy = p.copyWith(title: 'renamed');
      expect(copy.linkAlias, 'box');
      expect(copy.linkAutoConnect, isTrue);
    });

    test('overrides linkAlias and linkAutoConnect when given', () {
      final p = _profile(linkAlias: 'box', linkAutoConnect: false);
      final copy = p.copyWith(linkAlias: 'other', linkAutoConnect: true);
      expect(copy.linkAlias, 'other');
      expect(copy.linkAutoConnect, isTrue);
    });
  });

  group('ProfilesStore.save/load', () {
    test('persists both link fields', () async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        _profile(linkAlias: 'box', linkAutoConnect: true),
      ]);
      final loaded = (await store.load()).single;
      expect(loaded.linkAlias, 'box');
      expect(loaded.linkAutoConnect, isTrue);
    });
  });

  group('ProfilesStore.upsert — alias uniqueness', () {
    test('refuses an alias already held by a DIFFERENT identity', () async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        _profile(host: 'a.example', linkAlias: 'box'),
      ]);

      await expectLater(
        store.upsert(_profile(host: 'b.example', linkAlias: 'box')),
        throwsA(
          isA<LinkAliasConflictException>()
              .having((e) => e.alias, 'alias', 'box')
              .having(
                (e) => e.heldByIdentityKey,
                'heldByIdentityKey',
                'a.example:22:u',
              ),
        ),
      );

      final list = await store.load();
      expect(list, hasLength(1), reason: 'refused upsert writes nothing');
      expect(list.single.host, 'a.example');
    });

    test('allows re-saving the same identity with its own alias', () async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        _profile(host: 'a.example', linkAlias: 'box'),
      ]);

      await store.upsert(
        SavedProfile(
          title: 'renamed',
          host: 'a.example',
          port: 22,
          username: 'u',
          linkAlias: 'box',
        ),
      );

      final list = await store.load();
      expect(list, hasLength(1));
      expect(list.single.title, 'renamed');
      expect(list.single.linkAlias, 'box');
    });

    test('allows an identity rename to keep its alias (previousIdentityKey)',
        () async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        _profile(host: 'a.example', linkAlias: 'box'),
      ]);

      await store.upsert(
        _profile(host: 'renamed.example', linkAlias: 'box'),
        previousIdentityKey: 'a.example:22:u',
      );

      final list = await store.load();
      expect(list, hasLength(1));
      expect(list.single.host, 'renamed.example');
      expect(list.single.linkAlias, 'box');
    });

    test('null aliases never conflict', () async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[_profile(host: 'a.example')]);
      await store.upsert(_profile(host: 'b.example'));
      expect(await store.load(), hasLength(2));
    });
  });

  group('ProfilesStore.applyParsedImport — linkAutoConnect never installed',
      () {
    test('existing identity with prior true stays true when JSON says false',
        () async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        _profile(host: 'a.example', linkAutoConnect: true),
      ]);

      final result = await _plainImport(
        store,
        _importJson(<String, dynamic>{
          'title': 'Imported',
          'host': 'a.example',
          'port': 22,
          'username': 'u',
          'linkAutoConnect': false,
        }),
      );
      expect(result.updated, 1);
      expect((await store.load()).single.linkAutoConnect, isTrue);
    });

    test('existing identity with prior false stays false when JSON says true',
        () async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[_profile(host: 'a.example')]);

      final result = await _plainImport(
        store,
        _importJson(<String, dynamic>{
          'title': 'Imported',
          'host': 'a.example',
          'port': 22,
          'username': 'u',
          'linkAutoConnect': true,
        }),
      );
      expect(result.updated, 1);
      expect((await store.load()).single.linkAutoConnect, isFalse);
    });

    test('new identity gets false even when JSON says true', () async {
      final store = ProfilesStore();

      final result = await _plainImport(
        store,
        _importJson(<String, dynamic>{
          'title': 'Imported',
          'host': 'new.example',
          'port': 22,
          'username': 'u',
          'linkAutoConnect': true,
        }),
      );
      expect(result.added, 1);
      expect((await store.load()).single.linkAutoConnect, isFalse);
    });
  });

  group('ProfilesStore.applyParsedImport — linkAlias uniqueness', () {
    test('a unique alias is installed on a new identity', () async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        _profile(host: 'a.example', linkAlias: 'box'),
      ]);

      final result = await _plainImport(
        store,
        _importJson(<String, dynamic>{
          'title': 'Imported',
          'host': 'b.example',
          'port': 22,
          'username': 'u',
          'linkAlias': 'other',
        }),
      );
      expect(result.added, 1);
      final imported =
          (await store.load()).firstWhere((p) => p.host == 'b.example');
      expect(imported.linkAlias, 'other');
    });

    test('an alias colliding with an existing profile is dropped; the holder '
        'keeps it', () async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        _profile(host: 'a.example', linkAlias: 'box'),
      ]);

      final result = await _plainImport(
        store,
        _importJson(<String, dynamic>{
          'title': 'Imported',
          'host': 'b.example',
          'port': 22,
          'username': 'u',
          'linkAlias': 'box',
        }),
      );
      expect(result.added, 1);
      final list = await store.load();
      expect(list.firstWhere((p) => p.host == 'a.example').linkAlias, 'box');
      expect(list.firstWhere((p) => p.host == 'b.example').linkAlias, isNull);
    });

    test('re-import over the SAME identity keeps its own alias', () async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        _profile(host: 'a.example', linkAlias: 'box'),
      ]);

      final result = await _plainImport(
        store,
        _importJson(<String, dynamic>{
          'title': 'Imported',
          'host': 'a.example',
          'port': 22,
          'username': 'u',
          'linkAlias': 'box',
        }),
      );
      expect(result.updated, 1);
      expect((await store.load()).single.linkAlias, 'box');
    });

    test('two entries in one import with the same alias: first wins', () async {
      final store = ProfilesStore();

      final json = jsonEncode(<String, dynamic>{
        'version': 1,
        'profiles': [
          {
            'title': 'First',
            'host': 'a.example',
            'port': 22,
            'username': 'u',
            'linkAlias': 'box',
          },
          {
            'title': 'Second',
            'host': 'b.example',
            'port': 22,
            'username': 'u',
            'linkAlias': 'box',
          },
        ],
      });
      final result = await _plainImport(store, json);
      expect(result.added, 2);
      final list = await store.load();
      expect(list.firstWhere((p) => p.host == 'a.example').linkAlias, 'box');
      expect(list.firstWhere((p) => p.host == 'b.example').linkAlias, isNull);
    });
  });
}
