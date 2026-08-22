// Encrypted-backup IMPORT (#1125, Part C). Covers:
//   - parseImport v2 envelope recognition (exact outer schema, size cap)
//   - full-restore round trip onto fresh stores (the migration case)
//   - wrong passphrase / tamper ⇒ zero writes
//   - #1106-tightened credential-handle filter (missing / malformed /
//     wrong-type / unreferenced orphan)
//   - commands+forwards default-off stripping and opt-in restore
//   - key-id conflict clone + profile reference rewrite
//   - host-key pins add-absent-only
//   - settings typed allowlist (unknown ignored, invalid skipped with count)
//   - user-data merges (recents / profileOrder / favorites / import-wins)
//   - idempotence (same backup twice ⇒ 0 added / M updated)
//
// Fixtures use tiny Argon2 params via the permissive test bounds (same
// pattern as backup_test.dart); production strictness is pinned there.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/ssh/host_key_store.dart';
import 'package:mobissh/state/profile_order_providers.dart';
import 'package:mobissh/state/recent_sessions.dart';
import 'package:mobissh/storage/backup.dart';
import 'package:mobissh/storage/backup_restore.dart';
import 'package:mobissh/storage/custom_patterns_store.dart';
import 'package:mobissh/storage/detection_exceptions_store.dart';
import 'package:mobissh/storage/detection_styles_store.dart';
import 'package:mobissh/storage/favorites_store.dart';
import 'package:mobissh/storage/keys_store.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';

import '../support/test_keys.dart';

const _pass = 'correct horse battery';
const _tinyKdf = BackupKdfParams(mKiB: 64, t: 1, p: 1);
const _testBounds = BackupKdfBounds(
  minMKiB: 8,
  maxMKiB: 65536,
  minT: 1,
  maxT: 6,
  maxP: 1,
);

Future<String> _encryptTiny(Map<String, Object?> payload) =>
    encryptBackupEnvelope(payload: payload, passphrase: _pass, kdf: _tinyKdf);

Future<Map<String, Object?>> _decryptTiny(String envelope, String pass) =>
    decryptBackupEnvelope(
      envelopeJson: envelope,
      passphrase: pass,
      bounds: _testBounds,
    );

Future<SharedPreferences> _freshPrefs([
  Map<String, Object> seed = const <String, Object>{},
]) async {
  SharedPreferences.setMockInitialValues(seed);
  return SharedPreferences.getInstance();
}

/// A payload exercising every section — the migration fixture.
Map<String, Object?> _fullPayload() => <String, Object?>{
      'payloadVersion': 1,
      'createdAt': '2026-08-22T00:00:00Z',
      'appVersion': '0.1.12',
      'profiles': [
        {
          'title': 'Box',
          'host': 'h.example',
          'port': 22,
          'username': 'me',
          'authType': 'password',
          'vaultId': 'profile-h.example:22:me',
          'theme': 'dracula',
          'initialCommand': 'tmux attach',
          'forwards': [
            {'localPort': 8080, 'remoteHost': '127.0.0.1', 'remotePort': 80},
          ],
        },
        {
          'title': 'KeyBox',
          'host': 'k.example',
          'port': 22,
          'username': 'me',
          'authType': 'key',
          'keyVaultId': 'key-k1',
        },
      ],
      'keys': [
        {
          'id': 'k1',
          'name': 'Main key',
          'algorithm': 'ed25519',
          'fingerprint': kTestEd25519Fingerprint,
          'createdAtMs': 1,
        },
      ],
      'secrets': {
        'profile-h.example:22:me': {'password': 'hunter2hunter2'},
        'key-k1': {'data': kTestEd25519Pem},
      },
      'hostKeys': {'h.example:22': 'fp-aaa'},
      'recents': [
        {'title': 'Box', 'host': 'h.example', 'port': 22, 'username': 'me'},
      ],
      'profileOrder': ['k.example:22:me', 'h.example:22:me'],
      'favorites': {
        'h.example:22:me': [
          {'path': '/srv', 'label': 'srv'},
        ],
      },
      'detectionExceptions': [
        {'text': 'notaurl.example', 'pattern': 'url', 'scope': 'global'},
      ],
      'customPatterns': [
        {
          'id': 'custom.p1',
          'name': 'Ticket',
          'source': 'T-[0-9]+',
          'enabled': true,
          'ts': 5,
        },
      ],
      'detectionStyles': {
        'url': {'color': '#ff8800'},
      },
      'settings': {
        'mobissh.ui.fontSize': 18.0,
        'mobissh.ui.fontFamily': 'FiraCode',
        'mobissh.ui.terminalThemeIndex': 2,
        'mobissh.ui.terminalBackend': 'xterm',
        'mobissh.ui.composeBarVisible': true,
        'mobissh.keepalive.enabled': true,
        'mobissh.ui.tmuxControlMode': true,
        'mobissh.files.sort.v1': jsonEncode({
          'version': 1,
          'profiles': {
            'h.example:22:me': {'key': 'size', 'ascending': false},
          },
        }),
        'mobissh.detection.settings': jsonEncode({
          'v': 1,
          'enabled': true,
          'url': false,
          'path': true,
          'command': true,
          'relpath': true,
        }),
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseImport v2 envelope recognition', () {
    test('a v2 envelope is recognized, not treated as v1', () async {
      final envelope = await _encryptTiny(_fullPayload());
      final parsed = ProfilesStore.parseImport(envelope);
      expect(parsed.isEncryptedBackup, isTrue);
      expect(parsed.envelopeJson, envelope);
      expect(parsed.errors, isEmpty);
      expect(parsed.profileEntries, isEmpty);
      expect(parsed.hasVault, isFalse);
    });

    test('mixing v1 markers with the v2 format field is an error', () async {
      final outer =
          jsonDecode(await _encryptTiny(_fullPayload())) as Map<String, dynamic>;
      outer['profiles'] = <Object?>[];
      final parsed = ProfilesStore.parseImport(jsonEncode(outer));
      expect(parsed.isEncryptedBackup, isFalse);
      expect(parsed.errors, isNotEmpty);
    });

    test('an extra unknown outer field is an error (exact schema only)',
        () async {
      final outer =
          jsonDecode(await _encryptTiny(_fullPayload())) as Map<String, dynamic>;
      outer['pad'] = 'x';
      final parsed = ProfilesStore.parseImport(jsonEncode(outer));
      expect(parsed.isEncryptedBackup, isFalse);
      expect(parsed.errors, isNotEmpty);
    });

    test('a missing envelope field is an error (exact schema only)', () async {
      final outer =
          jsonDecode(await _encryptTiny(_fullPayload())) as Map<String, dynamic>;
      outer.remove('kdf');
      final parsed = ProfilesStore.parseImport(jsonEncode(outer));
      expect(parsed.isEncryptedBackup, isFalse);
      expect(parsed.errors, isNotEmpty);
    });

    test('oversized input is rejected before any JSON work', () {
      final big = '{"format":"mobissh-backup","version":2,"pad":"'
          '${'a' * (kBackupMaxEnvelopeBytes + 1)}"}';
      final parsed = ProfilesStore.parseImport(big);
      expect(parsed.isEncryptedBackup, isFalse);
      expect(parsed.errors, isNotEmpty);
      expect(parsed.profileEntries, isEmpty);
    });
  });

  group('full restore onto fresh stores', () {
    test('every section lands with semantic equality', () async {
      final prefs = await _freshPrefs();
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      final envelope = await _encryptTiny(_fullPayload());
      final payload = await _decryptTiny(envelope, _pass);

      final result = await applyBackupPayload(
        payload,
        prefs: prefs,
        secrets: secrets,
        restoreCommands: true,
      );

      expect(result.errors, isEmpty);
      expect(result.added, 2);
      expect(result.updated, 0);
      expect(result.keysImported, 1);
      expect(result.pinsAdded, 1);
      expect(result.pinsConflicting, 0);
      expect(result.settingsApplied, 9);
      expect(result.settingsSkipped, 0);

      // Profiles + trusted handles + commands/forwards (restoreCommands on).
      final profiles = await ProfilesStore(prefs: prefs).load();
      expect(profiles, hasLength(2));
      final box = profiles.firstWhere((p) => p.host == 'h.example');
      expect(box.vaultId, 'profile-h.example:22:me');
      expect(box.authType, 'password');
      expect(box.theme, 'dracula');
      expect(box.initialCommand, 'tmux attach');
      expect(box.forwards, hasLength(1));
      expect(box.forwards.single.localPort, 8080);
      final keyBox = profiles.firstWhere((p) => p.host == 'k.example');
      expect(keyBox.keyVaultId, 'key-k1');

      // Secrets: referenced handles + key material.
      final pw = await secrets.read('profile-h.example:22:me');
      expect(pw, isNotNull);
      expect(pw!['password'], 'hunter2hunter2');
      final keyMat = await secrets.read('key-k1');
      expect(keyMat, isNotNull);
      expect(keyMat!['data'], kTestEd25519Pem);

      // Keys metadata.
      final keys = await KeysStore(prefs: prefs).load();
      expect(keys, hasLength(1));
      expect(keys.single.id, 'k1');
      expect(keys.single.fingerprint, kTestEd25519Fingerprint);

      // Host-key pins.
      final pins =
          await SharedPrefsHostKeyBackend(prefs: prefs).loadAll();
      expect(pins['h.example:22'], 'fp-aaa');

      // Recents.
      final recents = await RecentSessionsStore(prefs: prefs).load();
      expect(recents, hasLength(1));
      expect(recents.single.host, 'h.example');

      // Profile order.
      expect(
        decodeProfileOrder(prefs.getString(profileOrderPrefKey)),
        ['k.example:22:me', 'h.example:22:me'],
      );

      // Favorites.
      final favs = await FavoritesStore(prefs: prefs)
          .favoritesFor('h.example:22:me');
      expect(favs, hasLength(1));
      expect(favs.single.path, '/srv');
      expect(favs.single.label, 'srv');

      // Detection exceptions.
      final exceptions = await DetectionExceptionsStore(prefs: prefs).load();
      expect(exceptions, hasLength(1));
      expect(exceptions.single.matchedText, 'notaurl.example');

      // Custom patterns.
      final patterns = await CustomPatternsStore(prefs: prefs).load();
      expect(patterns, hasLength(1));
      expect(patterns.single.id, 'custom.p1');

      // Detection styles.
      final styles = await DetectionStylesStore(prefs: prefs).load();
      expect(styles.of('url')?.colorHex, '#ff8800');

      // Settings allowlist.
      expect(prefs.getDouble('mobissh.ui.fontSize'), 18.0);
      expect(prefs.getString('mobissh.ui.fontFamily'), 'FiraCode');
      expect(prefs.getInt('mobissh.ui.terminalThemeIndex'), 2);
      expect(prefs.getString('mobissh.ui.terminalBackend'), 'xterm');
      expect(prefs.getBool('mobissh.ui.composeBarVisible'), isTrue);
      expect(prefs.getBool('mobissh.keepalive.enabled'), isTrue);
      expect(prefs.getBool('mobissh.ui.tmuxControlMode'), isTrue);
      expect(prefs.getString('mobissh.files.sort.v1'), isNotNull);
      expect(prefs.getString('mobissh.detection.settings'), isNotNull);
    });

    test('idempotent: same backup twice ⇒ 0 added / M updated, no dupes',
        () async {
      final prefs = await _freshPrefs();
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      final payload = _fullPayload();

      final first = await applyBackupPayload(
        payload,
        prefs: prefs,
        secrets: secrets,
        restoreCommands: true,
      );
      expect(first.added, 2);

      final second = await applyBackupPayload(
        payload,
        prefs: prefs,
        secrets: secrets,
        restoreCommands: true,
      );
      expect(second.errors, isEmpty);
      expect(second.added, 0);
      expect(second.updated, 2);

      expect(await ProfilesStore(prefs: prefs).load(), hasLength(2));
      expect(await KeysStore(prefs: prefs).load(), hasLength(1));
      expect(await RecentSessionsStore(prefs: prefs).load(), hasLength(1));
      expect(
        decodeProfileOrder(prefs.getString(profileOrderPrefKey)),
        ['k.example:22:me', 'h.example:22:me'],
      );
      expect(
        await FavoritesStore(prefs: prefs).favoritesFor('h.example:22:me'),
        hasLength(1),
      );
      expect(await CustomPatternsStore(prefs: prefs).load(), hasLength(1));
    });
  });

  group('zero writes on failure', () {
    test('wrong passphrase / tampered envelope leaves stores untouched',
        () async {
      final prefs = await _freshPrefs();
      final envelope = await _encryptTiny(_fullPayload());

      await expectLater(
        _decryptTiny(envelope, 'not the passphrase'),
        throwsA(isA<BackupException>()),
      );

      // Nothing between parse and the failed decrypt may write.
      expect(prefs.getKeys(), isEmpty);
    });

    test('a wrong-typed section aborts with zero writes', () async {
      final prefs = await _freshPrefs();
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      final result = await applyBackupPayload(
        <String, Object?>{
          'payloadVersion': 1,
          'profiles': 'nope',
          'hostKeys': {'h.example:22': 'fp-aaa'},
        },
        prefs: prefs,
        secrets: secrets,
      );
      expect(result.errors, isNotEmpty);
      expect(prefs.getKeys(), isEmpty,
          reason: 'validation failure must not half-apply (pins untouched)');
    });

    test('unsupported payloadVersion aborts with zero writes', () async {
      final prefs = await _freshPrefs();
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      final result = await applyBackupPayload(
        <String, Object?>{'payloadVersion': 2, 'profiles': <Object?>[]},
        prefs: prefs,
        secrets: secrets,
      );
      expect(result.errors, isNotEmpty);
      expect(prefs.getKeys(), isEmpty);
    });

    test('unknown top-level sections are ignored', () async {
      final prefs = await _freshPrefs();
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      final result = await applyBackupPayload(
        <String, Object?>{
          'payloadVersion': 1,
          'someFutureSection': {'x': 1},
          'profiles': [
            {'host': 'h.example', 'port': 22, 'username': 'me'},
          ],
        },
        prefs: prefs,
        secrets: secrets,
      );
      expect(result.errors, isEmpty);
      expect(result.added, 1);
    });
  });

  group('credential handle filter (#1106 tightened)', () {
    Future<ImportResult> apply(
      Map<String, Object?> secretsSection, {
      SecretsStore? secrets,
      List<Map<String, Object?>>? profiles,
    }) async {
      final prefs = await _freshPrefs();
      return applyBackupPayload(
        <String, Object?>{
          'payloadVersion': 1,
          'profiles': profiles ??
              [
                {
                  'host': 'h.example',
                  'port': 22,
                  'username': 'me',
                  'authType': 'password',
                  'vaultId': 'profile-h.example:22:me',
                  'keyVaultId': 'kv-1',
                },
              ],
          'secrets': secretsSection,
        },
        prefs: prefs,
        secrets: secrets ?? SecretsStore(backend: InMemorySecretsBackend()),
      );
    }

    Future<SavedProfile> loadedProfile() async {
      final prefs = await SharedPreferences.getInstance();
      return (await ProfilesStore(prefs: prefs).load()).single;
    }

    test('missing secret drops the handle', () async {
      await apply(<String, Object?>{});
      final p = await loadedProfile();
      expect(p.vaultId, isNull);
      expect(p.keyVaultId, isNull);
    });

    test('malformed secret entry drops the handle', () async {
      await apply(<String, Object?>{
        'profile-h.example:22:me': 'not-a-map',
        'kv-1': 42,
      });
      final p = await loadedProfile();
      expect(p.vaultId, isNull);
      expect(p.keyVaultId, isNull);
    });

    test('wrong-typed secret drops the handle', () async {
      // password handle without a string password; key handle without
      // string data/privateKey.
      await apply(<String, Object?>{
        'profile-h.example:22:me': {'password': 123},
        'kv-1': {'password': 'not key material'},
      });
      final p = await loadedProfile();
      expect(p.vaultId, isNull);
      expect(p.keyVaultId, isNull);
    });

    test('type-correct referenced handles survive (data or privateKey)',
        () async {
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      await apply(<String, Object?>{
        'profile-h.example:22:me': {'password': 'pw-pw-pw-pw'},
        'kv-1': {'privateKey': 'PEMPEM'},
      }, secrets: secrets);
      final p = await loadedProfile();
      expect(p.vaultId, 'profile-h.example:22:me');
      expect(p.keyVaultId, 'kv-1');
      expect(await secrets.read('profile-h.example:22:me'), isNotNull);
      expect(await secrets.read('kv-1'), isNotNull);
    });

    test('unreferenced orphan secrets are never written', () async {
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      await apply(<String, Object?>{
        'profile-h.example:22:me': {'password': 'pw-pw-pw-pw'},
        'orphan-id': {'password': 'stolen-write'},
      }, secrets: secrets);
      expect(await secrets.read('orphan-id'), isNull);
    });
  });

  group('initialCommand + forwards opt-in', () {
    test('default OFF strips commands and forwards', () async {
      final prefs = await _freshPrefs();
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      await applyBackupPayload(
        _fullPayload(),
        prefs: prefs,
        secrets: secrets,
      );
      final box = (await ProfilesStore(prefs: prefs).load())
          .firstWhere((p) => p.host == 'h.example');
      expect(box.initialCommand, isNull);
      expect(box.forwards, isEmpty);
    });

    test('checkbox ON restores commands and forwards on upsert too', () async {
      final prefs = await _freshPrefs();
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      // Existing profile with no auto-run config.
      await ProfilesStore(prefs: prefs).save([
        SavedProfile(
          title: 'Old Box',
          host: 'h.example',
          port: 22,
          username: 'me',
        ),
      ]);
      final result = await applyBackupPayload(
        _fullPayload(),
        prefs: prefs,
        secrets: secrets,
        restoreCommands: true,
      );
      expect(result.updated, 1);
      final box = (await ProfilesStore(prefs: prefs).load())
          .firstWhere((p) => p.host == 'h.example');
      expect(box.initialCommand, 'tmux attach');
      expect(box.forwards, hasLength(1));
      expect(box.title, 'Old Box', reason: 'upsert preserves the local title');
    });
  });

  group('key-id conflicts', () {
    Map<String, Object?> keyPayload() => <String, Object?>{
          'payloadVersion': 1,
          'profiles': [
            {
              'host': 'k.example',
              'port': 22,
              'username': 'me',
              'authType': 'key',
              'keyVaultId': 'key-k1',
            },
          ],
          'keys': [
            {'id': 'k1', 'name': 'Backup key', 'createdAtMs': 1},
          ],
          'secrets': {
            'key-k1': {'data': kTestEd25519Pem},
          },
        };

    test('same fingerprint ⇒ upsert in place', () async {
      final prefs = await _freshPrefs();
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      await KeysStore(prefs: prefs).save([
        const SavedKey(
          id: 'k1',
          name: 'Local key',
          fingerprint: kTestEd25519Fingerprint,
        ),
      ]);

      final result = await applyBackupPayload(
        keyPayload(),
        prefs: prefs,
        secrets: secrets,
      );
      expect(result.errors, isEmpty);

      final keys = await KeysStore(prefs: prefs).load();
      expect(keys, hasLength(1));
      expect(keys.single.id, 'k1');
      expect(keys.single.name, 'Backup key');
      final mat = await secrets.read('key-k1');
      expect(mat?['data'], kTestEd25519Pem);
      final p = (await ProfilesStore(prefs: prefs).load()).single;
      expect(p.keyVaultId, 'key-k1');
    });

    test('different fingerprint ⇒ clone under a new id + reference rewrite',
        () async {
      final prefs = await _freshPrefs();
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      await KeysStore(prefs: prefs).save([
        const SavedKey(
          id: 'k1',
          name: 'Local key',
          fingerprint: kTestEncryptedFingerprint,
        ),
      ]);
      await secrets.write('key-k1', {'data': 'LOCAL-MATERIAL'});

      final result = await applyBackupPayload(
        keyPayload(),
        prefs: prefs,
        secrets: secrets,
      );
      expect(result.errors, isEmpty);

      final keys = await KeysStore(prefs: prefs).load();
      expect(keys, hasLength(2));
      final local = keys.firstWhere((k) => k.id == 'k1');
      expect(local.name, 'Local key', reason: 'local key left untouched');
      expect(local.fingerprint, kTestEncryptedFingerprint);
      final clone = keys.firstWhere((k) => k.id != 'k1');
      expect(clone.name, 'Backup key');
      expect(clone.vaultId, isNot('key-k1'));

      // Local material untouched; imported material at the NEW vault id.
      expect((await secrets.read('key-k1'))?['data'], 'LOCAL-MATERIAL');
      expect((await secrets.read(clone.vaultId))?['data'], kTestEd25519Pem);

      // The importing profile's reference was rewritten to the clone.
      final p = (await ProfilesStore(prefs: prefs).load()).single;
      expect(p.keyVaultId, clone.vaultId);
    });

    test('unknown-vs-unknown fingerprints are treated as different', () async {
      final prefs = await _freshPrefs();
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      await KeysStore(prefs: prefs).save([
        const SavedKey(id: 'k1', name: 'Local key'),
      ]);
      final payload = keyPayload();
      // No importable material, no fingerprint metadata.
      payload['secrets'] = <String, Object?>{};
      final result = await applyBackupPayload(
        payload,
        prefs: prefs,
        secrets: secrets,
      );
      expect(result.errors, isEmpty);
      expect(await KeysStore(prefs: prefs).load(), hasLength(2));
    });
  });

  group('host-key pins are add-absent-only', () {
    test('conflicting pin keeps local + counts; absent pin is added',
        () async {
      final prefs = await _freshPrefs(<String, Object>{
        hostKeysPrefsKey: jsonEncode({'h.example:22': 'LOCAL-PIN'}),
      });
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      final result = await applyBackupPayload(
        <String, Object?>{
          'payloadVersion': 1,
          'hostKeys': {
            'h.example:22': 'REMOTE-PIN',
            'n.example:22': 'NEW-PIN',
          },
        },
        prefs: prefs,
        secrets: secrets,
      );
      expect(result.errors, isEmpty);
      expect(result.pinsAdded, 1);
      expect(result.pinsConflicting, 1);
      final pins = await SharedPrefsHostKeyBackend(prefs: prefs).loadAll();
      expect(pins['h.example:22'], 'LOCAL-PIN');
      expect(pins['n.example:22'], 'NEW-PIN');
    });
  });

  group('settings allowlist', () {
    test('unknown key ignored; invalid value skipped with count', () async {
      final prefs = await _freshPrefs();
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      final result = await applyBackupPayload(
        <String, Object?>{
          'payloadVersion': 1,
          'settings': {
            'mobissh.unknown.thing': 1,
            'mobissh.ui.fontSize': 'huge',
            'mobissh.ui.fontFamily': 'ComicSans',
            'mobissh.ui.composeBarVisible': true,
          },
        },
        prefs: prefs,
        secrets: secrets,
      );
      expect(result.errors, isEmpty);
      expect(result.settingsApplied, 1);
      expect(result.settingsSkipped, 2);
      expect(prefs.getBool('mobissh.ui.composeBarVisible'), isTrue);
      expect(prefs.containsKey('mobissh.unknown.thing'), isFalse);
      expect(prefs.containsKey('mobissh.ui.fontSize'), isFalse);
      expect(prefs.containsKey('mobissh.ui.fontFamily'), isFalse);
    });
  });

  group('user-data merges', () {
    test('recents keep-newest (local wins), profileOrder retains local-only',
        () async {
      final prefs = await _freshPrefs(<String, Object>{
        recentSessionsPrefsKey: jsonEncode([
          {
            'title': 'Local title',
            'host': 'h.example',
            'port': 22,
            'username': 'me',
          },
        ]),
        profileOrderPrefKey: jsonEncode({
          'version': 1,
          'order': ['h.example:22:me', 'local.only:22:me'],
        }),
      });
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      final result = await applyBackupPayload(
        <String, Object?>{
          'payloadVersion': 1,
          'recents': [
            {
              'title': 'Backup title',
              'host': 'h.example',
              'port': 22,
              'username': 'me',
            },
            {'title': 'Y', 'host': 'y.example', 'port': 22, 'username': 'me'},
          ],
          'profileOrder': ['k.example:22:me', 'h.example:22:me'],
        },
        prefs: prefs,
        secrets: secrets,
      );
      expect(result.errors, isEmpty);

      final recents = await RecentSessionsStore(prefs: prefs).load();
      expect(recents, hasLength(2));
      expect(recents.first.title, 'Local title',
          reason: 'identity collision keeps the newest (local) entry');
      expect(recents.last.host, 'y.example');

      expect(
        decodeProfileOrder(prefs.getString(profileOrderPrefKey)),
        ['k.example:22:me', 'h.example:22:me', 'local.only:22:me'],
      );
    });

    test('favorites / exceptions / patterns / styles: import wins on key',
        () async {
      final prefs = await _freshPrefs(<String, Object>{
        favoritesPrefsKey: jsonEncode({
          'version': 1,
          'profiles': {
            'h.example:22:me': [
              {'path': '/srv', 'label': 'old-label'},
              {'path': '/keep'},
            ],
          },
        }),
        detectionExceptionsPrefsKey: jsonEncode({
          'v': 1,
          'entries': [
            {'text': 'shared.example', 'pattern': 'url', 'host': 'old-host'},
            {'text': 'local-only.example', 'pattern': 'url'},
          ],
        }),
        customPatternsPrefsKey: jsonEncode({
          'v': 1,
          'patterns': [
            {
              'id': 'custom.p1',
              'name': 'Local name',
              'source': 'L-[0-9]+',
              'enabled': false,
              'ts': 1,
            },
          ],
        }),
        detectionStylesPrefsKey: jsonEncode({
          'v': 1,
          'styles': {
            'url': {'color': '#000000'},
            'path': {'color': '#111111'},
          },
        }),
      });
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      final result = await applyBackupPayload(
        <String, Object?>{
          'payloadVersion': 1,
          'favorites': {
            'h.example:22:me': [
              {'path': '/srv', 'label': 'new-label'},
            ],
          },
          'detectionExceptions': [
            {'text': 'shared.example', 'pattern': 'url', 'host': 'new-host'},
          ],
          'customPatterns': [
            {
              'id': 'custom.p1',
              'name': 'Backup name',
              'source': 'B-[0-9]+',
              'enabled': true,
              'ts': 5,
            },
          ],
          'detectionStyles': {
            'url': {'color': '#ff8800'},
          },
        },
        prefs: prefs,
        secrets: secrets,
      );
      expect(result.errors, isEmpty);

      final favs = await FavoritesStore(prefs: prefs)
          .favoritesFor('h.example:22:me');
      expect(favs, hasLength(2));
      expect(
        favs.firstWhere((f) => f.path == '/srv').label,
        'new-label',
        reason: 'import wins on exact-key collision',
      );
      expect(favs.any((f) => f.path == '/keep'), isTrue);

      final exceptions = await DetectionExceptionsStore(prefs: prefs).load();
      expect(exceptions, hasLength(2));
      expect(
        exceptions.firstWhere((e) => e.matchedText == 'shared.example').host,
        'new-host',
      );

      final patterns = await CustomPatternsStore(prefs: prefs).load();
      expect(patterns, hasLength(1));
      expect(patterns.single.name, 'Backup name');
      expect(patterns.single.source, 'B-[0-9]+');

      final styles = await DetectionStylesStore(prefs: prefs).load();
      expect(styles.of('url')?.colorHex, '#ff8800');
      expect(styles.of('path')?.colorHex, '#111111',
          reason: 'untouched local style survives');
    });
  });
}
