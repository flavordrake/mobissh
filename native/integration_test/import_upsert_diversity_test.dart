// On-emulator import DIVERSITY + upsert-over-stale smoke (#547 follow-up).
//
// Reproduces the device bug the first import_smoke_test missed: a profile that
// ALREADY exists in the store (stale identity-only, authType=null — the
// pre-#510 persisted shape) is re-imported as a KEY profile. The importer
// upserts the store, but if the UI doesn't invalidate `savedProfilesProvider`
// on an upsert (added=0, updated=1), the profile list keeps serving the STALE
// object → tapping it shows password mode with no key. That's exactly the
// user report: "fd-dev is a key profile; imported and selected it, password is
// highlighted not key."
//
// Diversity: the envelope carries a KEY profile (the formerly-stale host) AND a
// PASSWORD profile, so we assert each resolves to the correct auth mode.
//
// Network: scripts/native-connect-test.sh sets up the test-sshd bridge on
// 127.0.0.1:2222.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/vault.dart' show kVaultPbkdf2Iterations;

const String _testPrivateKeyPem = '''
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACB85qILD6Ykve+v2FrQWtcrsjW1baL6CXJ4LD5mmiDTdgAAAJgTrJmWE6yZ
lgAAAAtzc2gtZWQyNTUxOQAAACB85qILD6Ykve+v2FrQWtcrsjW1baL6CXJ4LD5mmiDTdg
AAAEBbgsew/IHGlnh7mBUSl/1dndeVjG9AmMGYWl0TNGsVK3zmogsPpiS976/YWtBa1yuy
NbVtovoJcngsPmaaINN2AAAAFXRlc3R1c2VyQG1vYmlzc2gtdGVzdA==
-----END OPENSSH PRIVATE KEY-----
''';

Future<String> _buildEnvelope({
  required String password,
  required List<Map<String, dynamic>> profiles,
  required Map<String, Map<String, Object?>> secrets,
}) async {
  final pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: kVaultPbkdf2Iterations,
    bits: 256,
  );
  final random = Random.secure();
  final salt =
      Uint8List.fromList(List<int>.generate(32, (_) => random.nextInt(256)));
  final dekBytes =
      Uint8List.fromList(List<int>.generate(32, (_) => random.nextInt(256)));
  final dek = SecretKey(dekBytes);
  final kek = await pbkdf2.deriveKey(
    secretKey: SecretKey(utf8.encode(password)),
    nonce: salt,
  );
  final aesGcm = AesGcm.with256bits();
  final dekWrapIv =
      Uint8List.fromList(List<int>.generate(12, (_) => random.nextInt(256)));
  final dekWrapBox =
      await aesGcm.encrypt(dekBytes, secretKey: kek, nonce: dekWrapIv);
  final dekWrapCt =
      Uint8List.fromList([...dekWrapBox.cipherText, ...dekWrapBox.mac.bytes]);

  final encrypted = <String, Map<String, String>>{};
  for (final entry in secrets.entries) {
    final iv =
        Uint8List.fromList(List<int>.generate(12, (_) => random.nextInt(256)));
    final box = await aesGcm.encrypt(
      utf8.encode(jsonEncode(entry.value)),
      secretKey: dek,
      nonce: iv,
    );
    final ct = Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
    encrypted[entry.key] = <String, String>{
      'iv': base64Encode(iv),
      'ct': base64Encode(ct),
    };
  }

  return jsonEncode(<String, Object?>{
    'version': 1,
    'exportedAt': '2026-05-26T00:00:00.000Z',
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

Future<bool> _pump(
  WidgetTester tester,
  Finder finder, {
  int slices = 30,
  Duration step = const Duration(milliseconds: 500),
}) async {
  for (var i = 0; i < slices; i++) {
    await tester.pump(step);
    if (finder.evaluate().isNotEmpty) return true;
  }
  return false;
}

/// Pump until [finder] matches NOTHING (e.g. waiting for the import dialog to
/// finish closing). Without this, an offstage widget behind the closing dialog
/// is "found" immediately and a tap lands on the dialog instead.
Future<bool> _pumpUntilGone(
  WidgetTester tester,
  Finder finder, {
  int slices = 30,
  Duration step = const Duration(milliseconds: 500),
}) async {
  for (var i = 0; i < slices; i++) {
    await tester.pump(step);
    if (finder.evaluate().isEmpty) return true;
  }
  return false;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      're-import over a STALE identity-only profile shows KEY mode on tap (#547)',
      (tester) async {
    FlutterForegroundTask.initCommunicationPort();

    // 1. Pre-seed the REAL store so BOTH imported identities already exist as
    //    stale identity-only profiles (the pre-#510 persisted shape: no
    //    authType, no vaultId/keyVaultId). This mirrors the user's device,
    //    where all 7 profiles were imported by an old build and persist across
    //    reinstalls. Because both already exist, the re-import is
    //    added=0/updated=2 — exactly the case the buggy `if (added > 0)`
    //    invalidate condition fails to refresh.
    final store = ProfilesStore();
    await store.save([
      SavedProfile(
        title: 'fd-dev (stale)',
        host: '127.0.0.1',
        port: 2222,
        username: 'testuser',
      ),
      SavedProfile(
        title: 'pw-host (stale)',
        host: '198.51.100.7',
        port: 22,
        username: 'alice',
      ),
    ]);

    const masterPassword = 'master';
    const keyVaultId = 'k-testsshd';
    const pwVaultId = 'v-pwhost';
    final envelope = await _buildEnvelope(
      password: masterPassword,
      profiles: <Map<String, dynamic>>[
        // Same identity as the stale profile, now KEY auth.
        <String, dynamic>{
          'title': 'fd-dev',
          'host': '127.0.0.1',
          'port': 2222,
          'username': 'testuser',
          'authType': 'key',
          'keyVaultId': keyVaultId,
        },
        // A second, password-auth profile for diversity.
        <String, dynamic>{
          'title': 'pw-host',
          'host': '198.51.100.7',
          'port': 22,
          'username': 'alice',
          'authType': 'password',
          'vaultId': pwVaultId,
        },
      ],
      secrets: <String, Map<String, Object?>>{
        keyVaultId: <String, Object?>{'data': _testPrivateKeyPem},
        pwVaultId: <String, Object?>{'password': 'hunter2'},
      },
    );

    await tester.pumpWidget(const ProviderScope(child: MobisshApp()));
    await tester.pump(const Duration(seconds: 1));

    // 2. Import the diverse envelope (upserts the stale profile to key auth).
    await tester.tap(find.byKey(const Key('open-import-profiles-dialog')).first);
    expect(await _pump(tester, find.byKey(const Key('import-profiles-dialog'))),
        isTrue);
    final disclosure = find.byKey(const Key('import-profiles-paste-disclosure'));
    if (disclosure.evaluate().isNotEmpty) {
      await tester.tap(disclosure);
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.enterText(
        find.byKey(const Key('import-profiles-input')), envelope);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const Key('import-profiles-submit')));
    expect(
        await _pump(tester, find.byKey(const Key('import-profiles-password'))),
        isTrue);
    await tester.enterText(
        find.byKey(const Key('import-profiles-password')), masterPassword);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const Key('import-profiles-submit')));

    // Wait for the dialog to fully close — otherwise the (offstage) profile
    // tile behind the closing dialog is "found" immediately and our tap lands
    // on the dialog, not the tile.
    expect(
        await _pumpUntilGone(
            tester, find.byKey(const Key('import-profiles-dialog')),
            slices: 40),
        isTrue,
        reason: 'import dialog never closed after vault submit');

    // 3. Tap the formerly-stale KEY profile. It MUST apply in KEY mode with the
    //    resolved private key — the bug is the stale list serving the old
    //    identity-only object (authType=null) → password mode, no key.
    final keyTile =
        find.byKey(const Key('profile-tile-127.0.0.1:2222:testuser'));
    expect(await _pump(tester, keyTile, slices: 20), isTrue,
        reason: 'key profile tile missing after import');
    await tester.tap(keyTile);
    final keyField = find.byKey(const Key('connect-key'));
    expect(await _pump(tester, keyField, slices: 20), isTrue,
        reason: 'KEY field not shown — profile applied in password mode '
            '(stale list not refreshed on upsert — the #547 follow-up bug)');
    // Credential resolution is async; let it land before reading the field.
    await tester.pump(const Duration(seconds: 1));
    final keyWidget = tester.widget<TextField>(keyField);
    expect(keyWidget.controller?.text ?? '', isNotEmpty,
        reason: 'key field empty — secret not resolved for upserted profile');

    // 4. Diversity: the OTHER upserted profile is password-auth. Tapping it
    //    must apply PASSWORD mode with the resolved password (and NOT show a
    //    key field). Confirms the upsert refresh is correct per-auth-type.
    final pwTile = find.byKey(const Key('profile-tile-198.51.100.7:22:alice'));
    expect(await _pump(tester, pwTile, slices: 20), isTrue,
        reason: 'password profile tile missing after import');
    await tester.tap(pwTile);
    final pwField = find.byKey(const Key('connect-password'));
    expect(await _pump(tester, pwField, slices: 20), isTrue,
        reason: 'password field not shown for the password-auth profile');
    await tester.pump(const Duration(seconds: 1));
    final pwWidget = tester.widget<TextField>(pwField);
    expect(pwWidget.controller?.text ?? '', isNotEmpty,
        reason: 'password field empty — secret not resolved for upserted '
            'password profile');
  });
}
