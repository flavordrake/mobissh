// CROSS-SLICE seam test for the encrypted backup: the export side (#1124,
// buildBackupPayload) and the import side (#1125, applyBackupPayload) were
// written by independent agents against the same spec — this test is the
// proof their payload contracts actually meet: seed stores → build → encrypt
// → decrypt → restore onto FRESH stores → assert the state semantically
// round-trips. This is the owner's migration path end to end.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/ssh/host_key_store.dart';
import 'package:mobissh/state/keepalive_providers.dart';
import 'package:mobissh/state/profile_order_providers.dart';
import 'package:mobissh/state/recent_sessions.dart';
import 'package:mobissh/state/ui_prefs_providers.dart';
import 'package:mobissh/storage/backup.dart';
import 'package:mobissh/storage/backup_payload.dart' hide kBackupPayloadVersion;
import 'package:mobissh/storage/backup_restore.dart';
import 'package:mobissh/storage/custom_patterns_store.dart';
import 'package:mobissh/storage/detection_exceptions_store.dart';
import 'package:mobissh/storage/detection_styles_store.dart';
import 'package:mobissh/storage/favorites_store.dart';
import 'package:mobissh/storage/keys_store.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';

// Tiny-but-valid KDF params (backup_test.dart pattern) — fast suite; the
// permissive bounds accept them on decrypt.
const _tinyKdf = BackupKdfParams(mKiB: 64, t: 1, p: 1);
const _testBounds = BackupKdfBounds(
  minMKiB: 8,
  maxMKiB: 65536,
  minT: 1,
  maxT: 6,
  maxP: 1,
);

const _pass = 'round trip passphrase';
const _canaryPassword = 'CANARY-password-hunter2';
const _canaryPem = '-----BEGIN OPENSSH PRIVATE KEY-----CANARY-----END-----';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('export → encrypt → decrypt → restore round-trips the full state',
      () async {
    // ── Old phone: seed every section ────────────────────────────────────
    SharedPreferences.setMockInitialValues(<String, Object>{
      fontSizePrefKey: 15.0,
      fontFamilyPrefKey: 'FiraCode',
      terminalThemePrefKey: 2,
      composeBarVisiblePrefKey: true,
      keepaliveEnabledPrefKey: false,
      profileOrderPrefKey: encodeProfileOrder(<String>[
        'h1.example:22:u1',
        'h2.example:2222:u2',
      ]),
    });
    final oldPrefs = await SharedPreferences.getInstance();
    final oldProfiles = ProfilesStore(prefs: oldPrefs);
    final oldKeys = KeysStore(prefs: oldPrefs);
    final oldSecrets = SecretsStore(backend: InMemorySecretsBackend());

    await oldProfiles.save(<SavedProfile>[
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
          ProfileForward(
              localPort: 8080, remoteHost: '127.0.0.1', remotePort: 80),
        ],
      ),
    ]);
    await oldKeys.save(<SavedKey>[
      const SavedKey(id: 'lib1', name: 'laptop key', algorithm: 'ed25519'),
    ]);
    await oldSecrets.write('vault-a', {'password': _canaryPassword});
    await oldSecrets.write('key-lib1', {'data': _canaryPem});

    final oldRecents = RecentSessionsStore(prefs: oldPrefs);
    await oldRecents.add(RecentSessionEntry(
        title: 'One', host: 'h1.example', port: 22, username: 'u1'));
    final oldFavorites = FavoritesStore(prefs: oldPrefs);
    await oldFavorites.add('h1.example:22:u1', '/srv/media');
    final oldExceptions = DetectionExceptionsStore(prefs: oldPrefs);
    await oldExceptions.add(
        const DetectionException(matchedText: 'not.a.url', patternId: 'url'));
    final oldPatterns = CustomPatternsStore(prefs: oldPrefs);
    await oldPatterns.saveAll(<CustomPattern>[
      const CustomPattern(
        id: 'custom.p1',
        name: 'issue refs',
        source: r'#\d+',
        enabled: true,
        createdTs: 1234,
      ),
    ]);
    final oldStyles = DetectionStylesStore(prefs: oldPrefs);
    await oldStyles.setPatternStyle(
        'url', const DetectionPatternStyle(colorHex: '#112233'));

    final built = await buildBackupPayload(
      profiles: oldProfiles,
      keys: oldKeys,
      secrets: oldSecrets,
      hostKeys: InMemoryHostKeyBackend({'h1.example:22': 'ff:ee:dd'}),
      recents: oldRecents,
      favorites: oldFavorites,
      detectionExceptions: oldExceptions,
      customPatterns: oldPatterns,
      detectionStyles: oldStyles,
      prefs: oldPrefs,
      appVersion: 'test+1',
    );
    expect(built.error, isNull);

    final envelope = await encryptBackupEnvelope(
      payload: built.payload!,
      passphrase: _pass,
      kdf: _tinyKdf,
    );
    // The file leaks nothing.
    expect(envelope, isNot(contains('CANARY')));
    expect(envelope, isNot(contains('h1.example')));

    // ── New phone: FRESH stores, decrypt + restore ───────────────────────
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final newPrefs = await SharedPreferences.getInstance();
    final newSecrets = SecretsStore(backend: InMemorySecretsBackend());

    final payload = await decryptBackupEnvelope(
      envelopeJson: envelope,
      passphrase: _pass,
      bounds: _testBounds,
    );
    final result = await applyBackupPayload(
      payload,
      secrets: newSecrets,
      prefs: newPrefs,
      restoreCommands: true, // the owner restoring their OWN backup
    );
    expect(result.errors, isEmpty);
    expect(result.added, 2);

    // Profiles round-tripped, including commands/forwards (checkbox on).
    final restored = await ProfilesStore(prefs: newPrefs).load();
    expect(restored.length, 2);
    final one = restored.firstWhere((p) => p.host == 'h1.example');
    final two = restored.firstWhere((p) => p.host == 'h2.example');
    expect(one.authType, 'password');
    expect(one.initialCommand, 'tmux attach');
    expect(one.defaultPath, '/srv');
    expect(two.authType, 'key');
    expect(two.forwards, hasLength(1));
    expect(two.forwards.first.localPort, 8080);

    // Credentials resolve on the NEW device — the whole point.
    final credsOne =
        await loadProfileCredentials(newSecrets, one);
    expect(credsOne.password, _canaryPassword);
    final credsTwo =
        await loadProfileCredentials(newSecrets, two);
    expect(credsTwo.privateKey, _canaryPem);

    // Key library.
    final keys = await KeysStore(prefs: newPrefs).load();
    expect(keys.map((k) => k.id), ['lib1']);

    // Host pin added on the fresh device.
    expect(newPrefs.getString(hostKeysPrefsKey), contains('h1.example:22'));
    expect(newPrefs.getString(hostKeysPrefsKey), contains('ff:ee:dd'));

    // User data.
    final recents = await RecentSessionsStore(prefs: newPrefs).load();
    expect(recents.map((r) => r.host), ['h1.example']);
    expect(
      decodeProfileOrder(newPrefs.getString(profileOrderPrefKey)),
      ['h1.example:22:u1', 'h2.example:2222:u2'],
    );
    expect(newPrefs.getString(favoritesPrefsKey), contains('/srv/media'));
    expect(newPrefs.getString(detectionExceptionsPrefsKey),
        contains('not.a.url'));
    expect(newPrefs.getString(customPatternsPrefsKey), contains('custom.p1'));
    expect(newPrefs.getString(detectionStylesPrefsKey), contains('#112233'));

    // Settings allowlist applied.
    expect(newPrefs.getDouble(fontSizePrefKey), 15.0);
    expect(newPrefs.getString(fontFamilyPrefKey), 'FiraCode');
    expect(newPrefs.getInt(terminalThemePrefKey), 2);
    expect(newPrefs.getBool(composeBarVisiblePrefKey), true);
    expect(newPrefs.getBool(keepaliveEnabledPrefKey), false);
  });

  test('default restore strips commands/forwards (checkbox off)', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final oldPrefs = await SharedPreferences.getInstance();
    final oldProfiles = ProfilesStore(prefs: oldPrefs);
    final oldSecrets = SecretsStore(backend: InMemorySecretsBackend());
    await oldProfiles.save(<SavedProfile>[
      SavedProfile(
        title: 'One',
        host: 'h1.example',
        port: 22,
        username: 'u1',
        authType: 'password',
        vaultId: 'vault-a',
        initialCommand: 'rm -rf /tmp/x',
        forwards: const [
          ProfileForward(
              localPort: 9000, remoteHost: '10.0.0.1', remotePort: 9000),
        ],
      ),
    ]);
    await oldSecrets.write('vault-a', {'password': _canaryPassword});

    final built = await buildBackupPayload(
      profiles: oldProfiles,
      keys: KeysStore(prefs: oldPrefs),
      secrets: oldSecrets,
      hostKeys: InMemoryHostKeyBackend({}),
      recents: RecentSessionsStore(prefs: oldPrefs),
      favorites: FavoritesStore(prefs: oldPrefs),
      detectionExceptions: DetectionExceptionsStore(prefs: oldPrefs),
      customPatterns: CustomPatternsStore(prefs: oldPrefs),
      detectionStyles: DetectionStylesStore(prefs: oldPrefs),
      prefs: oldPrefs,
      appVersion: 'test+1',
    );
    final envelope = await encryptBackupEnvelope(
        payload: built.payload!, passphrase: _pass, kdf: _tinyKdf);

    SharedPreferences.setMockInitialValues(<String, Object>{});
    final newPrefs = await SharedPreferences.getInstance();
    final newSecrets = SecretsStore(backend: InMemorySecretsBackend());
    final payload = await decryptBackupEnvelope(
        envelopeJson: envelope, passphrase: _pass, bounds: _testBounds);
    final result =
        await applyBackupPayload(payload, secrets: newSecrets, prefs: newPrefs);
    expect(result.errors, isEmpty);

    final one = (await ProfilesStore(prefs: newPrefs).load()).single;
    expect(one.initialCommand, isNull,
        reason: 'auto-run commands need the explicit checkbox');
    expect(one.forwards, isEmpty);
    // The credential itself still restores.
    expect((await loadProfileCredentials(newSecrets, one)).password,
        _canaryPassword);
  });
}
