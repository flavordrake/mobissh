// Unit tests for [ProfilesStore] (#501).
//
// Covers:
//   - load/save round-trip preserves identity + theme/color
//   - importFromJson with the PWA's envelope shape
//   - importFromJson with the legacy bare-array shape (forward-compat)
//   - dedupe on (host:port:username)
//   - invalid JSON / wrong shape returns ImportResult with errors, no crash
//   - rejects unknown export version

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/storage/vault.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // Reset to a clean prefs map for every test. Empty initial values give
    // every test its own SharedPreferences instance.
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('SavedProfile', () {
    test('identityKey is host:port:username', () {
      final p = SavedProfile(
        title: 't', host: 'h.example', port: 2222, username: 'u',
      );
      expect(p.identityKey, 'h.example:2222:u');
    });

    test('toJson omits null theme/color', () {
      final p = SavedProfile(title: 't', host: 'h', port: 22, username: 'u');
      final json = p.toJson();
      expect(json.containsKey('theme'), isFalse);
      expect(json.containsKey('color'), isFalse);
    });

    test('toJson includes theme/color when present', () {
      final p = SavedProfile(
        title: 't', host: 'h', port: 22, username: 'u',
        theme: 'nord', color: '#abcdef',
      );
      expect(p.toJson()['theme'], 'nord');
      expect(p.toJson()['color'], '#abcdef');
    });

    test('fromJson throws FormatException for missing host', () {
      expect(
        () => SavedProfile.fromJson(<String, dynamic>{'username': 'u'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson throws FormatException for missing username', () {
      expect(
        () => SavedProfile.fromJson(<String, dynamic>{'host': 'h'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson defaults port to 22 when missing', () {
      final p = SavedProfile.fromJson(<String, dynamic>{
        'host': 'h.example', 'username': 'u',
      });
      expect(p.port, 22);
    });

    test('fromJson clamps invalid port to 22', () {
      final p = SavedProfile.fromJson(<String, dynamic>{
        'host': 'h', 'username': 'u', 'port': -1,
      });
      expect(p.port, 22);
    });

    test('fromJson synthesizes title from username@host when missing', () {
      final p = SavedProfile.fromJson(<String, dynamic>{
        'host': 'h.example', 'username': 'me', 'port': 22,
      });
      expect(p.title, 'me@h.example');
    });

    test('equality is by identity tuple (host, port, username)', () {
      final a = SavedProfile(
        title: 'A', host: 'h', port: 22, username: 'u', theme: 'dark',
      );
      final b = SavedProfile(
        title: 'B (different)', host: 'h', port: 22, username: 'u',
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });

  group('ProfilesStore.load/save', () {
    test('load returns empty list when storage is empty', () async {
      final store = ProfilesStore();
      final loaded = await store.load();
      expect(loaded, isEmpty);
    });

    test('save+load round-trip preserves all fields', () async {
      final store = ProfilesStore();
      final original = <SavedProfile>[
        SavedProfile(
          title: 'Dev', host: 'dev.example', port: 22, username: 'admin',
          theme: 'dark', color: '#ff8800',
        ),
        SavedProfile(
          title: 'Prod', host: 'prod.example', port: 2222, username: 'deploy',
        ),
      ];
      await store.save(original);

      final loaded = await store.load();
      expect(loaded, hasLength(2));
      expect(loaded[0].title, 'Dev');
      expect(loaded[0].host, 'dev.example');
      expect(loaded[0].port, 22);
      expect(loaded[0].username, 'admin');
      expect(loaded[0].theme, 'dark');
      expect(loaded[0].color, '#ff8800');
      expect(loaded[1].theme, isNull);
      expect(loaded[1].color, isNull);
    });

    test('load is corrupt-resilient — returns [] on malformed JSON',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        profilesPrefsKey: 'not json',
      });
      final store = ProfilesStore();
      final loaded = await store.load();
      expect(loaded, isEmpty);
    });

    test('load tolerates a corrupt entry mixed with valid ones', () async {
      // Pre-seed prefs with one bad + one good entry. The bad entry is
      // missing the required `host` field; the good entry should still
      // appear in the result.
      final raw = jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{'username': 'u'},
        <String, dynamic>{
          'host': 'good.example', 'username': 'u', 'port': 22, 'title': 'OK',
        },
      ]);
      SharedPreferences.setMockInitialValues(<String, Object>{
        profilesPrefsKey: raw,
      });
      final store = ProfilesStore();
      final loaded = await store.load();
      expect(loaded, hasLength(1));
      expect(loaded[0].host, 'good.example');
    });

    test('remove deletes the matching profile', () async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(title: 'A', host: 'a', port: 22, username: 'u1'),
        SavedProfile(title: 'B', host: 'b', port: 22, username: 'u2'),
      ]);
      await store.remove(host: 'a', port: 22, username: 'u1');
      final loaded = await store.load();
      expect(loaded, hasLength(1));
      expect(loaded.first.host, 'b');
    });
  });

  group('ProfilesStore.importFromJson — PWA envelope shape', () {
    // A realistic export captured from the PWA's exportProfilesJson(). The
    // native client MUST parse this without changes; it's the contract.
    const pwaExportFixture = '''
{
  "version": 1,
  "exportedAt": "2026-05-22T13:00:00.000Z",
  "profiles": [
    {
      "title": "Home NAS",
      "host": "nas.tail123.ts.net",
      "port": 22,
      "username": "mfrazier",
      "theme": "dark",
      "color": "#88ccff"
    },
    {
      "title": "Build box",
      "host": "build.tail123.ts.net",
      "port": 2222,
      "username": "ci",
      "theme": "nord"
    }
  ]
}
''';

    test('imports both profiles from a fresh store', () async {
      final store = ProfilesStore();
      final result = await store.importFromJson(pwaExportFixture);
      expect(result.added, 2);
      expect(result.skipped, 0);
      expect(result.errors, isEmpty);

      final loaded = await store.load();
      expect(loaded, hasLength(2));
      expect(loaded[0].title, 'Home NAS');
      expect(loaded[0].color, '#88ccff');
      expect(loaded[1].title, 'Build box');
      expect(loaded[1].theme, 'nord');
    });

    test('upserts existing (host:port:username) when re-importing (#547)',
        () async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(
          title: 'Old Name', host: 'nas.tail123.ts.net',
          port: 22, username: 'mfrazier',
        ),
      ]);
      final result = await store.importFromJson(pwaExportFixture);
      expect(result.added, 1, reason: 'only "Build box" is new');
      expect(result.updated, 1, reason: 'nas already exists → upsert, not skip');
      expect(result.skipped, 0);

      final loaded = await store.load();
      expect(loaded, hasLength(2));
      // Existing profile keeps its original title — import does not clobber it.
      final existing = loaded.firstWhere((p) => p.host == 'nas.tail123.ts.net');
      expect(existing.title, 'Old Name');
      // ...but its visual identity IS refreshed from the import.
      expect(existing.theme, 'dark');
      expect(existing.color, '#88ccff');
    });

    test('rejects unknown export version', () async {
      final store = ProfilesStore();
      const future = '''
{ "version": 99, "exportedAt": "x", "profiles": [] }
''';
      final result = await store.importFromJson(future);
      expect(result.added, 0);
      expect(result.errors, hasLength(1));
      expect(result.errors.first, contains('Unsupported export version'));
    });
  });

  group('ProfilesStore.importFromJson — robustness', () {
    test('accepts a bare-array (legacy #419) export shape', () async {
      // The PWA's pre-#501 `exportProfilesJSON()` emits a bare array.
      // Forward-compat: the native client should accept it.
      const legacy = '''
[
  { "title": "X", "host": "x.example", "port": 22, "username": "u",
    "authType": "password" }
]
''';
      final store = ProfilesStore();
      final result = await store.importFromJson(legacy);
      expect(result.added, 1);
      expect(result.errors, isEmpty);
    });

    test('returns errors (no throw) on invalid JSON', () async {
      final store = ProfilesStore();
      final result = await store.importFromJson('not json at all');
      expect(result.added, 0);
      expect(result.errors, hasLength(1));
      expect(result.errors.first.toLowerCase(), contains('json'));
      // Storage untouched.
      expect(await store.load(), isEmpty);
    });

    test('returns errors on wrong shape (object without profiles array)',
        () async {
      final store = ProfilesStore();
      const wrong = '{ "version": 1, "junk": true }';
      final result = await store.importFromJson(wrong);
      expect(result.added, 0);
      expect(result.errors, hasLength(1));
    });

    test('skips entries missing required fields, collects errors', () async {
      final store = ProfilesStore();
      const mixed = '''
{
  "version": 1,
  "profiles": [
    { "title": "no host", "port": 22, "username": "u" },
    { "host": "ok.example", "port": 22, "username": "u", "title": "OK" }
  ]
}
''';
      final result = await store.importFromJson(mixed);
      expect(result.added, 1);
      expect(result.errors, hasLength(1));
      final loaded = await store.load();
      expect(loaded.single.host, 'ok.example');
    });

    test('ignores plaintext credentials silently — only vaultId is kept',
        () async {
      // Belt-and-braces: even if the PWA export had credentials, the
      // SavedProfile.fromJson factory would not read them and they would
      // never reach storage. (vaultId IS preserved as of #510 because it's
      // a reference, not a secret.)
      final store = ProfilesStore();
      const sneaky = '''
{
  "version": 1,
  "profiles": [
    {
      "title": "Sneaky", "host": "evil.example", "port": 22,
      "username": "u",
      "password": "secret", "privateKey": "PRIVATE", "vaultId": "v-keep"
    }
  ]
}
''';
      final result = await store.importFromJson(sneaky);
      expect(result.added, 1);
      final loaded = await store.load();
      final stored = loaded.single.toJson();
      expect(stored.containsKey('password'), isFalse);
      expect(stored.containsKey('privateKey'), isFalse);
      expect(stored['vaultId'], 'v-keep');
    });
  });

  group('ProfilesStore.parseImport — backup envelope detection', () {
    test('detects vault field with encrypted + meta strings', () {
      const envelope = '''
{
  "version": 1,
  "exportedAt": "2026-05-22T13:00:00.000Z",
  "profiles": [
    { "host": "h.example", "port": 22, "username": "u", "vaultId": "v1" }
  ],
  "vault": {
    "encrypted": "{\\"v1\\":{\\"iv\\":\\"aa\\",\\"ct\\":\\"bb\\"}}",
    "meta": "{\\"salt\\":\\"cc\\"}"
  }
}
''';
      final parsed = ProfilesStore.parseImport(envelope);
      expect(parsed.hasVault, isTrue);
      expect(parsed.profileEntries, hasLength(1));
      expect(parsed.profileEntries.first['vaultId'], 'v1');
    });

    test('hasVault is false when vault.encrypted is missing', () {
      const envelope = '''
{
  "version": 1,
  "profiles": [],
  "vault": { "meta": "{}" }
}
''';
      final parsed = ProfilesStore.parseImport(envelope);
      expect(parsed.hasVault, isFalse);
    });

    test('plain envelope without vault parses to profiles only', () {
      const envelope = '''
{
  "version": 1,
  "profiles": [
    { "host": "h.example", "port": 22, "username": "u" }
  ]
}
''';
      final parsed = ProfilesStore.parseImport(envelope);
      expect(parsed.hasVault, isFalse);
      expect(parsed.profileEntries, hasLength(1));
    });
  });

  group('ProfilesStore.applyParsedImport — backup envelope round-trip', () {
    // Build a backup-envelope-shaped string using the same crypto primitives
    // the PWA emits. Reuses the helper pattern from vault_test.dart with a
    // lower iteration count for speed.
    Future<String> buildBackupEnvelope({
      required String password,
      required List<Map<String, dynamic>> profiles,
      required Map<String, Map<String, Object?>> secrets,
      required Pbkdf2 pbkdf2,
    }) async {
      final random = Random.secure();
      final salt = Uint8List.fromList(
        List<int>.generate(32, (_) => random.nextInt(256)),
      );
      final dekBytes = Uint8List.fromList(
        List<int>.generate(32, (_) => random.nextInt(256)),
      );
      final dek = SecretKey(dekBytes);
      final kek = await pbkdf2.deriveKey(
        secretKey: SecretKey(utf8.encode(password)),
        nonce: salt,
      );
      final aesGcm = AesGcm.with256bits();

      final dekWrapIv = Uint8List.fromList(
        List<int>.generate(12, (_) => random.nextInt(256)),
      );
      final dekWrapBox = await aesGcm.encrypt(
        dekBytes,
        secretKey: kek,
        nonce: dekWrapIv,
      );
      final dekWrapCt = Uint8List.fromList([
        ...dekWrapBox.cipherText,
        ...dekWrapBox.mac.bytes,
      ]);

      final encrypted = <String, Map<String, String>>{};
      for (final entry in secrets.entries) {
        final iv = Uint8List.fromList(
          List<int>.generate(12, (_) => random.nextInt(256)),
        );
        final box = await aesGcm.encrypt(
          utf8.encode(jsonEncode(entry.value)),
          secretKey: dek,
          nonce: iv,
        );
        final ct = Uint8List.fromList([
          ...box.cipherText,
          ...box.mac.bytes,
        ]);
        encrypted[entry.key] = <String, String>{
          'iv': base64Encode(iv),
          'ct': base64Encode(ct),
        };
      }

      return jsonEncode(<String, Object?>{
        'version': 1,
        'exportedAt': '2026-05-22T13:00:00.000Z',
        'profiles': profiles,
        'vault': <String, String>{
          'encrypted': jsonEncode(encrypted),
          'meta': jsonEncode(<String, Object?>{
            'salt': base64Encode(salt),
            'dekPw': <String, String>{
              'iv': base64Encode(dekWrapIv),
              'ct': base64Encode(dekWrapCt),
            },
          }),
        },
      });
    }

    Pbkdf2 fastPbkdf2() => Pbkdf2(
          macAlgorithm: Hmac.sha256(),
          iterations: 1000,
          bits: 256,
        );

    test('applies a backup envelope with the right password', () async {
      final pbkdf2 = fastPbkdf2();
      final envelope = await buildBackupEnvelope(
        password: 'master',
        profiles: <Map<String, dynamic>>[
          <String, dynamic>{
            'title': 'Home NAS',
            'host': 'nas.example',
            'port': 22,
            'username': 'me',
            'authType': 'password',
            'vaultId': 'v-home',
          },
        ],
        secrets: <String, Map<String, Object?>>{
          'v-home': <String, Object?>{'password': 'hunter2'},
        },
        pbkdf2: pbkdf2,
      );

      final store = ProfilesStore();
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      final parsed = ProfilesStore.parseImport(envelope);
      expect(parsed.hasVault, isTrue);

      final result = await store.applyParsedImport(
        parsed,
        password: 'master',
        secrets: secrets,
        decryptor: VaultDecryptor(pbkdf2: pbkdf2),
      );
      expect(result.errors, isEmpty);
      expect(result.added, 1);

      // Profile persisted with vaultId.
      final loaded = await store.load();
      expect(loaded.single.vaultId, 'v-home');
      // Secret available in store.
      final secret = await secrets.read('v-home');
      expect(secret, isNotNull);
      expect(secret!['password'], 'hunter2');
    });

    test(
        're-import over a stale identity-only profile UPDATES authType/'
        'vaultId/keyVaultId AND re-stores vault secrets (#547)', () async {
      // Simulate the device-confirmed bug: a pre-#510 build persisted an
      // identity-only profile (no authType, no vault refs). Re-importing a
      // backup envelope that carries the same identity must upgrade it in
      // place AND land the decrypted secret in the SecretsStore.
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(
          title: 'My Box',
          host: 'box.example',
          port: 22,
          username: 'me',
        ),
      ]);

      final pbkdf2 = fastPbkdf2();
      final envelope = await buildBackupEnvelope(
        password: 'master',
        profiles: <Map<String, dynamic>>[
          <String, dynamic>{
            'title': 'My Box (re-export)',
            'host': 'box.example',
            'port': 22,
            'username': 'me',
            'authType': 'key',
            'vaultId': 'v-box',
            'keyVaultId': 'k-box',
          },
        ],
        secrets: <String, Map<String, Object?>>{
          'v-box': <String, Object?>{'password': 'fallbackpw'},
          'k-box': <String, Object?>{'data': '-----BEGIN KEY-----\\nabc\\n'},
        },
        pbkdf2: pbkdf2,
      );

      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      final parsed = ProfilesStore.parseImport(envelope);
      final result = await store.applyParsedImport(
        parsed,
        password: 'master',
        secrets: secrets,
        decryptor: VaultDecryptor(pbkdf2: pbkdf2),
      );

      expect(result.errors, isEmpty);
      expect(result.added, 0, reason: 'identity already existed');
      expect(result.updated, 1, reason: 'upserted in place');
      expect(result.skipped, 0);

      // Profile upgraded in place — title preserved, refs refreshed.
      final loaded = await store.load();
      expect(loaded, hasLength(1));
      final upserted = loaded.single;
      expect(upserted.title, 'My Box', reason: 'user title not clobbered');
      expect(upserted.authType, 'key');
      expect(upserted.vaultId, 'v-box');
      expect(upserted.keyVaultId, 'k-box');

      // Secrets re-stored for the matched (updated) profile, not just added.
      final keySecret = await secrets.read('k-box');
      expect(keySecret, isNotNull);
      expect(keySecret!['data'], '-----BEGIN KEY-----\\nabc\\n');

      // The credential loader can now resolve a non-empty private key —
      // the connect path will run in key mode rather than re-prompting.
      final creds = await loadProfileCredentials(secrets, upserted);
      expect(creds.privateKey, isNotNull);
      expect(creds.privateKey, isNotEmpty);
    });

    test('wrong password reports clear error and writes no state',
        () async {
      final pbkdf2 = fastPbkdf2();
      final envelope = await buildBackupEnvelope(
        password: 'master',
        profiles: <Map<String, dynamic>>[
          <String, dynamic>{
            'host': 'h.example',
            'port': 22,
            'username': 'u',
            'vaultId': 'v-x',
          },
        ],
        secrets: <String, Map<String, Object?>>{
          'v-x': <String, Object?>{'password': 'secret'},
        },
        pbkdf2: pbkdf2,
      );

      final store = ProfilesStore();
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      final parsed = ProfilesStore.parseImport(envelope);

      final result = await store.applyParsedImport(
        parsed,
        password: 'wrong',
        secrets: secrets,
        decryptor: VaultDecryptor(pbkdf2: pbkdf2),
      );

      expect(result.added, 0);
      expect(result.errors, isNotEmpty);
      // No profile persisted.
      expect(await store.load(), isEmpty);
      // No secret persisted.
      expect(await secrets.read('v-x'), isNull);
    });
  });
}
