// On-device encrypted backup round trip: export → wipe → restore → connect
// (#1259 gap 3).
//
// The v2 backup (#1124 export / #1125 import) had never run on a device. This
// exercises everything headless tests fake:
//   - the PRODUCTION export seams: readability preflight over the real
//     Keystore-backed secure storage, payload gather, Argon2id + AES-GCM in
//     Isolate.run with the default (OWASP-minimum) KDF;
//   - a real wipe of app data (SharedPreferences + every secure-storage entry);
//   - a tampered copy of the backup is REFUSED with the generic error and
//     writes nothing;
//   - the genuine backup restores through the real import dialog (paste path,
//     production decrypt in Isolate.run), the key + both profiles come back,
//     and the restored KEY profile connects to test-sshd.
//
// Only the SAF "create document" UI is replaced (a capturing BackupSaveAdapter):
// it is system UI the test cannot drive. The bytes it captures are exactly the
// bytes production would hand to the file.
//
// Network: emulator 127.0.0.1:2222 → (adb reverse) → fd-dev → (socat) →
// test-sshd:22, which trusts docker/test-sshd/testuser_id_ed25519.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/storage/backup.dart' show kBackupGenericError;
import 'package:mobissh/storage/keys_store.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/ui/export_backup_dialog.dart';

// The ed25519 private key test-sshd trusts for `testuser`. Mirrors
// docker/test-sshd/testuser_id_ed25519 verbatim — keep in sync if rotated.
const String _testPrivateKeyPem = '''
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACB85qILD6Ykve+v2FrQWtcrsjW1baL6CXJ4LD5mmiDTdgAAAJgTrJmWE6yZ
lgAAAAtzc2gtZWQyNTUxOQAAACB85qILD6Ykve+v2FrQWtcrsjW1baL6CXJ4LD5mmiDTdg
AAAEBbgsew/IHGlnh7mBUSl/1dndeVjG9AmMGYWl0TNGsVK3zmogsPpiS976/YWtBa1yuy
NbVtovoJcngsPmaaINN2AAAAFXRlc3R1c2VyQG1vYmlzc2gtdGVzdA==
-----END OPENSSH PRIVATE KEY-----
''';

const _passphrase = 'round trip horse battery staple';
const _keyId = 'k1259roundtrip';
const _keyName = 'Round-trip key';
const _pwVaultId = 'pw-1259-roundtrip';
const _keyTile = Key('profile-tile-127.0.0.1:2222:testuser');
const _pwTile = Key('profile-tile-localhost:2222:testuser');

class _CapturingSaveAdapter implements BackupSaveAdapter {
  String? fileName;
  Uint8List? bytes;

  @override
  Future<bool> createDocument({
    required String fileName,
    required Uint8List bytes,
  }) async {
    this.fileName = fileName;
    this.bytes = bytes;
    return true;
  }
}

/// Wipe app data the way "Clear storage" would for everything the backup
/// covers: every SharedPreferences key and every secure-storage entry.
Future<void> _wipeAppData() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.clear();
  final secrets = SecretsStore();
  for (final id in await secrets.listVaultIds()) {
    await secrets.delete(id);
  }
}

Future<bool> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  int slices = 120,
  Duration step = const Duration(milliseconds: 500),
}) async {
  for (var i = 0; i < slices; i++) {
    await tester.pump(step);
    if (done()) return true;
  }
  return false;
}

bool _present(Finder f) => f.evaluate().isNotEmpty;

/// Open the import dialog, paste [envelope], enter the passphrase and submit.
Future<void> _importPasted(WidgetTester tester, String envelope) async {
  await tester.tap(find.byKey(const Key('open-import-profiles-dialog')).first);
  expect(
    await _pumpUntil(
      tester,
      () => _present(find.byKey(const Key('import-profiles-dialog'))),
      slices: 20,
    ),
    isTrue,
    reason: 'import dialog did not open',
  );
  final disclosure = find.byKey(const Key('import-profiles-paste-disclosure'));
  if (_present(disclosure)) {
    await tester.tap(disclosure);
    await tester.pump(const Duration(milliseconds: 300));
  }
  await tester.enterText(find.byKey(const Key('import-profiles-input')), envelope);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(find.byKey(const Key('import-profiles-submit')));
  expect(
    await _pumpUntil(
      tester,
      () => _present(find.byKey(const Key('import-profiles-password'))),
      slices: 20,
    ),
    isTrue,
    reason: 'a v2 backup must ask for its passphrase',
  );
  await tester.enterText(
    find.byKey(const Key('import-profiles-password')),
    _passphrase,
  );
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(find.byKey(const Key('import-profiles-submit')));
}

/// Flip one ciphertext byte: GCM must reject it.
String _tamper(String envelope) {
  final outer = jsonDecode(envelope) as Map<String, Object?>;
  final ct = base64Decode(outer['ciphertext']! as String);
  ct[ct.length ~/ 2] ^= 0x01;
  outer['ciphertext'] = base64Encode(ct);
  return jsonEncode(outer);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('v2 backup: export → wipe → tampered refused → restore → '
      'connect (#1259)', (tester) async {
    FlutterForegroundTask.initCommunicationPort();

    // ── Seed: one library key, a KEY profile using it, a PASSWORD profile ──
    await _wipeAppData();
    final prefs = await SharedPreferences.getInstance();
    final secrets = SecretsStore();
    final key = SavedKey(id: _keyId, name: _keyName);
    await secrets.write(key.vaultId, <String, Object?>{
      'data': _testPrivateKeyPem,
    });
    await KeysStore(prefs: prefs).save([key]);
    await secrets.write(_pwVaultId, <String, Object?>{'password': 'testpass'});
    await ProfilesStore(prefs: prefs).save([
      SavedProfile(
        title: 'Restored key box',
        host: '127.0.0.1',
        port: 2222,
        username: 'testuser',
        authType: 'key',
        keyVaultId: key.vaultId,
      ),
      SavedProfile(
        title: 'Restored password box',
        host: 'localhost',
        port: 2222,
        username: 'testuser',
        authType: 'password',
        vaultId: _pwVaultId,
      ),
    ]);

    // ── Export through the production seams (save UI captured) ────────────
    final saver = _CapturingSaveAdapter();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                key: const Key('open-export'),
                onPressed: () =>
                    showExportBackupDialog(context, saveAdapter: saver),
                child: const Text('Export'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open-export')));
    expect(
      await _pumpUntil(
        tester,
        () => _present(find.byKey(const Key('export-backup-preflight-ok'))),
        slices: 40,
      ),
      isTrue,
      reason: 'export preflight must find every stored credential readable',
    );
    await tester.enterText(
      find.byKey(const Key('export-backup-passphrase')),
      _passphrase,
    );
    await tester.enterText(
      find.byKey(const Key('export-backup-confirm')),
      _passphrase,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('export-backup-submit')));
    // Argon2id at 19 MiB on the device, off the UI thread.
    expect(
      await _pumpUntil(tester, () => saver.bytes != null),
      isTrue,
      reason: 'export never reached the save step',
    );
    final envelope = utf8.decode(saver.bytes!);
    expect(saver.fileName, endsWith('.mobissh'));
    expect(envelope, isNot(contains('PRIVATE KEY')), reason: 'ciphertext only');
    expect(envelope, isNot(contains('testpass')), reason: 'ciphertext only');
    await tester.pump(const Duration(seconds: 1));

    // ── Wipe, then restart the app on empty data ──────────────────────────
    await _wipeAppData();
    expect(await ProfilesStore(prefs: prefs).load(), isEmpty);
    await tester.pumpWidget(const ProviderScope(child: MobisshApp()));
    await tester.pump(const Duration(seconds: 1));
    expect(_present(find.byKey(_keyTile)), isFalse);

    // ── A tampered backup: clear error, nothing imported ──────────────────
    await _importPasted(tester, _tamper(envelope));
    expect(
      await _pumpUntil(
        tester,
        () => _present(find.byKey(const Key('import-profiles-error'))),
      ),
      isTrue,
      reason: 'a tampered backup must be refused in-dialog',
    );
    expect(find.text(kBackupGenericError), findsOneWidget);
    expect(await ProfilesStore(prefs: prefs).load(), isEmpty);
    expect(await KeysStore(prefs: prefs).load(), isEmpty);
    expect(await secrets.read(key.vaultId), isNull);
    await tester.tap(find.byKey(const Key('import-profiles-cancel')));
    await tester.pump(const Duration(milliseconds: 500));

    // ── The genuine backup restores everything ────────────────────────────
    await _importPasted(tester, envelope);
    expect(
      await _pumpUntil(
        tester,
        () => _present(find.byKey(_keyTile)) && _present(find.byKey(_pwTile)),
      ),
      isTrue,
      reason: 'restored profile tiles did not appear',
    );
    final keys = await KeysStore(prefs: prefs).load();
    expect(keys.single.name, _keyName);
    expect(
      (await secrets.read(keys.single.vaultId))?['data'],
      _testPrivateKeyPem,
    );
    expect((await secrets.read(_pwVaultId))?['password'], 'testpass');

    // ── And the restored key profile connects ─────────────────────────────
    await tester.pump(const Duration(seconds: 3)); // let the outcome toast go
    await tester.tap(find.byKey(_keyTile));
    var connected = false;
    for (var i = 0; i < 60 && !connected; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      final trust = find.text('Trust + connect');
      if (_present(trust)) {
        await tester.tap(trust.first);
        await tester.pump(const Duration(milliseconds: 300));
      }
      connected = _present(find.byKey(const Key('session-menu-button')));
    }
    expect(
      connected,
      isTrue,
      reason: 'the restored KEY profile did not reach a live terminal',
    );
  });
}
