// Backup payload gathering (#1124, export path). Locks:
// - every section present, with payloadVersion/createdAt/appVersion INSIDE
//   the payload (never the envelope),
// - secrets are referenced-only (an orphan vault entry is NOT exported),
// - an unreadable REFERENCED secret aborts the export with a count and NO
//   payload,
// - the settings section is the typed allowlist only,
// - round trip through encrypt/decryptBackupEnvelope preserves every section.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/ssh/host_key_store.dart';
import 'package:mobissh/state/keepalive_providers.dart';
import 'package:mobissh/state/profile_order_providers.dart';
import 'package:mobissh/state/recent_sessions.dart';
import 'package:mobissh/state/ui_prefs_providers.dart';
import 'package:mobissh/storage/backup.dart';
import 'package:mobissh/storage/backup_payload.dart';
import 'package:mobissh/storage/custom_patterns_store.dart';
import 'package:mobissh/storage/detection_exceptions_store.dart';
import 'package:mobissh/storage/detection_styles_store.dart';
import 'package:mobissh/storage/favorites_store.dart';
import 'package:mobissh/storage/keys_store.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';

// Tiny-but-valid Argon2 params (same pattern as backup_test.dart) so the
// round-trip test stays fast; permissive bounds accept them on read.
const _tinyKdf = BackupKdfParams(mKiB: 64, t: 1, p: 1);
const _testBounds = BackupKdfBounds(
  minMKiB: 8,
  maxMKiB: 65536,
  minT: 1,
  maxT: 6,
  maxP: 1,
);

const _canaryPassword = 'CANARY-password-hunter2';

/// One fully-populated store environment over the mocked SharedPreferences.
class _Env {
  _Env(this.prefs)
      : profiles = ProfilesStore(prefs: prefs),
        keys = KeysStore(prefs: prefs),
        secretsBackend = InMemorySecretsBackend(),
        hostKeys = InMemoryHostKeyBackend({'h1.example:22': 'ff:ee:dd'}),
        recents = RecentSessionsStore(prefs: prefs),
        favorites = FavoritesStore(prefs: prefs),
        detectionExceptions = DetectionExceptionsStore(prefs: prefs),
        customPatterns = CustomPatternsStore(prefs: prefs),
        detectionStyles = DetectionStylesStore(prefs: prefs) {
    secrets = SecretsStore(backend: secretsBackend);
  }

  final SharedPreferences prefs;
  final ProfilesStore profiles;
  final KeysStore keys;
  final InMemorySecretsBackend secretsBackend;
  late final SecretsStore secrets;
  final InMemoryHostKeyBackend hostKeys;
  final RecentSessionsStore recents;
  final FavoritesStore favorites;
  final DetectionExceptionsStore detectionExceptions;
  final CustomPatternsStore customPatterns;
  final DetectionStylesStore detectionStyles;
}

final _fixedNow = DateTime.utc(2026, 8, 22, 12, 0, 0);

Future<_Env> _seededEnv() async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    // Allowlisted settings.
    fontSizePrefKey: 15.0,
    fontFamilyPrefKey: 'FiraCode',
    terminalThemePrefKey: 2,
    composeBarVisiblePrefKey: true,
    keepaliveEnabledPrefKey: false,
    // NOT allowlisted — must never appear in the settings section.
    'mobissh.not.a.backup.setting': 'leak-me-not',
    // Profile display order (read via decodeProfileOrder's schema).
    profileOrderPrefKey: encodeProfileOrder(<String>[
      'h1.example:22:u1',
      'h2.example:2222:u2',
    ]),
  });
  final env = _Env(await SharedPreferences.getInstance());

  await env.profiles.save(<SavedProfile>[
    SavedProfile(
      title: 'One',
      host: 'h1.example',
      port: 22,
      username: 'u1',
      authType: 'password',
      vaultId: 'vault-a',
      initialCommand: 'tmux attach',
      defaultPath: '/srv',
    ),
    SavedProfile(
      title: 'Two',
      host: 'h2.example',
      port: 2222,
      username: 'u2',
      authType: 'key',
      keyVaultId: 'key-lib1',
      forwards: const [
        ProfileForward(localPort: 8080, remoteHost: '127.0.0.1', remotePort: 80),
      ],
    ),
  ]);
  await env.keys.save(<SavedKey>[
    const SavedKey(id: 'lib1', name: 'laptop key', algorithm: 'ed25519'),
  ]);

  // Referenced secrets... plus an ORPHAN nothing points at.
  await env.secrets.write('vault-a', {'password': _canaryPassword});
  await env.secrets.write('key-lib1', {'data': 'PEM-material'});
  await env.secrets.write('orphan-1', {'password': 'orphan-secret'});

  await env.recents.add(
    RecentSessionEntry(title: 'One', host: 'h1.example', port: 22, username: 'u1'),
  );
  await env.favorites.add('h1.example:22:u1', '/srv/media');
  await env.detectionExceptions.add(
    const DetectionException(matchedText: 'not.a.url', patternId: 'url'),
  );
  await env.customPatterns.saveAll(<CustomPattern>[
    const CustomPattern(
      id: 'custom.p1',
      name: 'issue refs',
      source: r'#\d+',
      enabled: true,
      createdTs: 1234,
    ),
  ]);
  await env.detectionStyles.setPatternStyle(
    'url',
    const DetectionPatternStyle(colorHex: '#112233'),
  );
  return env;
}

Future<BackupPayloadResult> _build(_Env env) {
  return buildBackupPayload(
    profiles: env.profiles,
    keys: env.keys,
    secrets: env.secrets,
    hostKeys: env.hostKeys,
    recents: env.recents,
    favorites: env.favorites,
    detectionExceptions: env.detectionExceptions,
    customPatterns: env.customPatterns,
    detectionStyles: env.detectionStyles,
    prefs: env.prefs,
    appVersion: 'test+1',
    now: () => _fixedNow,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every section present, metadata inside the payload', () async {
    final env = await _seededEnv();
    final result = await _build(env);
    expect(result.error, isNull);
    final payload = result.payload!;
    expect(
      payload.keys.toSet(),
      containsAll(<String>{
        'payloadVersion',
        'createdAt',
        'appVersion',
        'profiles',
        'keys',
        'secrets',
        'hostKeys',
        'recents',
        'profileOrder',
        'favorites',
        'detectionExceptions',
        'customPatterns',
        'detectionStyles',
        'settings',
      }),
    );
    expect(payload['payloadVersion'], 1);
    expect(payload['createdAt'], _fixedNow.toIso8601String());
    expect(payload['appVersion'], 'test+1');

    final profiles = payload['profiles'] as List;
    expect(profiles, hasLength(2));
    final p1 = profiles[0] as Map;
    expect(p1['host'], 'h1.example');
    expect(p1['initialCommand'], 'tmux attach');
    expect(p1['defaultPath'], '/srv');
    final p2 = profiles[1] as Map;
    expect((p2['forwards'] as List), hasLength(1));

    final keys = payload['keys'] as List;
    expect(keys, hasLength(1));
    expect((keys[0] as Map)['name'], 'laptop key');

    expect(payload['hostKeys'], {'h1.example:22': 'ff:ee:dd'});
    expect(payload['profileOrder'],
        ['h1.example:22:u1', 'h2.example:2222:u2']);
    expect((payload['recents'] as List), hasLength(1));
    final favorites = payload['favorites'] as Map;
    expect((favorites['h1.example:22:u1'] as List), hasLength(1));
    expect((payload['detectionExceptions'] as List), hasLength(1));
    expect((payload['customPatterns'] as List), hasLength(1));
    final styles = payload['detectionStyles'] as Map;
    expect((styles['url'] as Map)['color'], '#112233');

    expect(result.profileCount, 2);
    expect(result.keyCount, 1);
  });

  test('settings section carries the allowlist ONLY', () async {
    final env = await _seededEnv();
    final result = await _build(env);
    final settings = (result.payload!['settings'] as Map).cast<String, Object?>();
    expect(settings[fontSizePrefKey], 15.0);
    expect(settings[fontFamilyPrefKey], 'FiraCode');
    expect(settings[terminalThemePrefKey], 2);
    expect(settings[composeBarVisiblePrefKey], true);
    expect(settings[keepaliveEnabledPrefKey], false);
    expect(settings.containsKey('mobissh.not.a.backup.setting'), isFalse);
    // Every exported settings key must come from the typed allowlist.
    for (final key in settings.keys) {
      expect(kBackupSettingsAllowlist, contains(key));
    }
  });

  test('secrets: referenced only — orphan vault entry is NOT exported',
      () async {
    final env = await _seededEnv();
    final result = await _build(env);
    final secrets = result.payload!['secrets'] as Map;
    expect(secrets.keys.toSet(), {'vault-a', 'key-lib1'});
    expect((secrets['vault-a'] as Map)['password'], _canaryPassword);
    expect((secrets['key-lib1'] as Map)['data'], 'PEM-material');
  });

  test('unreadable referenced secrets → error result with count, NO payload',
      () async {
    final env = await _seededEnv();
    // Make BOTH referenced secrets unreadable (read → null, per #1118).
    await env.secrets.delete('vault-a');
    await env.secrets.delete('key-lib1');
    final result = await _build(env);
    expect(result.payload, isNull);
    expect(result.error, isNotNull);
    expect(result.error, contains('2'));
    expect(result.unreadableSecretCount, 2);
  });

  test('round trip: build → encrypt → decrypt → per-section equality',
      () async {
    final env = await _seededEnv();
    final payload = (await _build(env)).payload!;
    final envelope = await encryptBackupEnvelope(
      payload: payload,
      passphrase: 'correct horse battery',
      kdf: _tinyKdf,
    );
    // The envelope itself must not leak any payload content.
    expect(envelope, isNot(contains('h1.example')));
    expect(envelope, isNot(contains(_canaryPassword)));
    final out = await decryptBackupEnvelope(
      envelopeJson: envelope,
      passphrase: 'correct horse battery',
      bounds: _testBounds,
    );
    for (final section in payload.keys) {
      expect(out[section], equals(payload[section]),
          reason: 'section $section must survive the round trip');
    }
    expect(out.keys.toSet(), payload.keys.toSet());
  });
}
