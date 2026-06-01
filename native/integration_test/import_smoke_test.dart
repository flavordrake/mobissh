// On-emulator import → upsert → connect-in-key-mode smoke (#547).
//
// Exercises the device-only failure that headless tests cannot reach: an
// imported KEY profile whose secret was decrypted from a backup envelope and
// stored in the REAL flutter_secure_storage (Android Keystore), then resolved
// back out by the connect path so the session connects in key mode against the
// test-sshd bridge.
//
// This is the test the #547 device-confirmed bug needed: every imported profile
// showed `authType=null keyVaultId=false pwLen=0 keyLen=0` on hardware while
// headless round-trips passed, because re-import was a no-op for pre-#510
// identity-only profiles AND the secret was never reachable.
//
// Network: scripts/native-connect-test.sh sets up
//   emulator 127.0.0.1:2222 → (adb reverse) → fd-dev → (socat) → test-sshd:22
// so connecting to 127.0.0.1:2222 reaches the Alpine test sshd container, which
// trusts docker/test-sshd/testuser_id_ed25519 for `testuser`.
//
// NOTE: we pump `MobisshApp` directly rather than calling `app.main()`.
// `main()` wraps everything in `CrashReporter.runGuarded`, which overrides
// `FlutterError.onError` and conflicts with the integration-test binding's
// error capture. We still call `initCommunicationPort()` (which `main()` does)
// so the FFT IPC channel is open.
//
// PASS = the session reaches the terminal screen (session-menu AppBar button
// appears). MINIMUM acceptable = the profile applies in key mode with a
// non-empty private key loaded into the form (the connect-form key field is
// populated from the resolved secret) even if the live socket flakes.

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
import 'package:mobissh/storage/vault.dart' show kVaultPbkdf2Iterations;

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

/// Build a backup envelope shaped exactly like the PWA's encrypted export,
/// using the PRODUCTION PBKDF2 iteration count so the in-app default
/// `VaultDecryptor()` (no override) decrypts it. Slow (600k iterations) but run
/// once per test.
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('import KEY profile from backup → tap → connect in key mode (#547)', (
    tester,
  ) async {
    FlutterForegroundTask.initCommunicationPort();

    const masterPassword = 'master';
    const keyVaultId = 'k-testsshd';
    final envelope = await _buildEnvelope(
      password: masterPassword,
      profiles: <Map<String, dynamic>>[
        <String, dynamic>{
          'title': 'Test SSHD',
          'host': '127.0.0.1',
          'port': 2222,
          'username': 'testuser',
          'authType': 'key',
          'keyVaultId': keyVaultId,
        },
      ],
      // PWA key-secret shape: `{data: <PEM>}` under keyVaultId.
      secrets: <String, Map<String, Object?>>{
        keyVaultId: <String, Object?>{'data': _testPrivateKeyPem},
      },
    );

    await tester.pumpWidget(const ProviderScope(child: MobisshApp()));
    await tester.pump(const Duration(seconds: 1));

    // Open the import dialog. The Connect form exposes an import affordance;
    // the dialog itself is keyed `import-profiles-dialog`.
    final importButton = find.byKey(const Key('open-import-profiles-dialog'));
    expect(
      importButton.evaluate(),
      isNotEmpty,
      reason: 'no import affordance found on the connect screen',
    );
    await tester.tap(importButton.first);
    expect(
      await _pump(tester, find.byKey(const Key('import-profiles-dialog'))),
      isTrue,
      reason: 'import dialog did not open',
    );

    // Expand the paste disclosure and paste the envelope JSON.
    final disclosure = find.byKey(
      const Key('import-profiles-paste-disclosure'),
    );
    if (disclosure.evaluate().isNotEmpty) {
      await tester.tap(disclosure);
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.enterText(
      find.byKey(const Key('import-profiles-input')),
      envelope,
    );
    await tester.pump(const Duration(milliseconds: 200));

    // Stage 1 submit → vault detected → password field appears.
    await tester.tap(find.byKey(const Key('import-profiles-submit')));
    expect(
      await _pump(tester, find.byKey(const Key('import-profiles-password'))),
      isTrue,
      reason: 'password stage did not appear for the encrypted envelope',
    );

    await tester.enterText(
      find.byKey(const Key('import-profiles-password')),
      masterPassword,
    );
    await tester.pump(const Duration(milliseconds: 200));

    // Stage 2 submit → decrypt (600k PBKDF2 on device) + persist + close.
    await tester.tap(find.byKey(const Key('import-profiles-submit')));
    final tile = find.byKey(const Key('profile-tile-127.0.0.1:2222:testuser'));
    expect(
      await _pump(tester, tile, slices: 40),
      isTrue,
      reason: 'imported profile tile did not appear after import',
    );

    // #583: tapping the saved profile CONNECTS directly using the resolved
    // secret (no inline form to prefill anymore). The #547 assertion — that the
    // imported key secret actually resolved — is now proven by reaching a live
    // terminal under KEY auth (a failed resolve would hang / fail auth).
    await tester.tap(tile);
    var connected = false;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      final accept = find.text('Trust + connect');
      if (accept.evaluate().isNotEmpty) {
        await tester.tap(accept.first);
        await tester.pump(const Duration(milliseconds: 300));
      }
      if (find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty) {
        connected = true;
        break;
      }
    }

    // FULL acceptance: connect reaches the terminal screen. (If the live socket
    // flakes because the bridge is down, this is the only signal we have now
    // that the form is gone — the import + tile appearance above already
    // proved the profile + its vault reference persisted.)
    expect(
      connected,
      isTrue,
      reason:
          'import → tap-to-connect did not reach the terminal — '
          'the resolved key secret may not have applied (#547 regression)',
    );
  });
}
