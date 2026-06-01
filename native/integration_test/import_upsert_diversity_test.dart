// On-emulator import DIVERSITY + upsert-over-stale smoke (#547 follow-up, #595).
//
// Reproduces the device bug the first import_smoke_test missed: a profile that
// ALREADY exists in the store (stale identity-only, authType=null — the
// pre-#510 persisted shape) is re-imported as a KEY profile. The importer
// upserts the store, but if the UI doesn't invalidate `savedProfilesProvider`
// on an upsert (added=0, updated=1), the profile list keeps serving the STALE
// object → opening it shows password mode with no key. That's exactly the
// user report: "fd-dev is a key profile; imported and selected it, password is
// highlighted not key."
//
// Diversity: the envelope carries a KEY profile (the formerly-stale host) AND a
// PASSWORD profile, so we assert each resolves to the correct auth mode.
//
// UI contract (#583 + #595): the inline connect form was removed — a row TAP
// connects directly (no `connect-key`/`connect-password` fields exist anymore).
// The per-profile authType is now surfaced through the profile EDITOR, opened
// via the row's edit pencil (`profile-edit-<identityKey>`). So the on-device
// proof that the upsert refreshed the per-profile authType is: open the editor
// for the formerly-stale row and assert it renders KEY mode (the
// `profile-editor-key` field present, `profile-editor-password` absent), and
// the diversity (password) row renders PASSWORD mode.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
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
    're-import over a STALE identity-only profile shows KEY mode in editor (#547/#595)',
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
      await tester.tap(
        find.byKey(const Key('open-import-profiles-dialog')).first,
      );
      expect(
        await _pump(tester, find.byKey(const Key('import-profiles-dialog'))),
        isTrue,
      );
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
      await tester.tap(find.byKey(const Key('import-profiles-submit')));
      expect(
        await _pump(tester, find.byKey(const Key('import-profiles-password'))),
        isTrue,
      );
      await tester.enterText(
        find.byKey(const Key('import-profiles-password')),
        masterPassword,
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const Key('import-profiles-submit')));

      // Wait for the dialog to fully close — otherwise the (offstage) profile
      // tile behind the closing dialog is "found" immediately and our tap lands
      // on the dialog, not the tile.
      expect(
        await _pumpUntilGone(
          tester,
          find.byKey(const Key('import-profiles-dialog')),
          slices: 40,
        ),
        isTrue,
        reason: 'import dialog never closed after vault submit',
      );

      // 3. Open the formerly-stale KEY profile in the editor (edit pencil). It
      //    MUST render in KEY mode — the bug is the stale list serving the old
      //    identity-only object (authType=null) → editor opens in password mode.
      //    Post-#583 there is no inline `connect-key` field; the editor's auth
      //    SegmentedButton is the per-profile authType surface.
      final keyEdit = find.byKey(
        const Key('profile-edit-127.0.0.1:2222:testuser'),
      );
      expect(
        await _pump(tester, keyEdit, slices: 20),
        isTrue,
        reason: 'key profile row missing after import',
      );
      await tester.tap(keyEdit);
      expect(
        await _pump(tester, find.byKey(const Key('profile-editor'))),
        isTrue,
        reason: 'editor did not open for the key profile',
      );
      final keyField = find.byKey(const Key('profile-editor-key'));
      expect(
        await _pump(tester, keyField, slices: 20),
        isTrue,
        reason:
            'KEY field not shown — editor opened in password mode '
            '(stale authType not refreshed on upsert — the #547 follow-up '
            'bug, #595)',
      );
      // In KEY mode the password field is hidden (the editor swaps fields by
      // authType). Its presence would mean the editor opened in password mode.
      expect(
        find.byKey(const Key('profile-editor-password')),
        findsNothing,
        reason:
            'password field present — editor opened in password mode for '
            'a KEY profile (stale authType)',
      );
      // Back out of the editor before checking the diversity row. The editor
      // is a `fullscreenDialog` route, so on Android its leading affordance is
      // a Material CloseButton (X), NOT a Back/Cupertino button — `pageBack()`
      // looks for a CupertinoNavigationBarBackButton and finds none. Tap the
      // CloseButton (covers fullscreenDialog on every platform); fall back to
      // BackButton / a Back tooltip for non-dialog presentations.
      final keyClose = find.byType(CloseButton);
      if (keyClose.evaluate().isNotEmpty) {
        await tester.tap(keyClose.first);
      } else if (find.byType(BackButton).evaluate().isNotEmpty) {
        await tester.tap(find.byType(BackButton).first);
      } else {
        await tester.tap(find.byTooltip('Back').first);
      }
      expect(
        await _pumpUntilGone(
          tester,
          find.byKey(const Key('profile-editor')),
          slices: 40,
        ),
        isTrue,
        reason: 'editor never closed after backing out of the key profile',
      );

      // 4. Diversity: the OTHER upserted profile is password-auth. Its editor
      //    must render PASSWORD mode (and NOT a key field). Confirms the upsert
      //    refresh is correct per-auth-type.
      final pwEdit = find.byKey(
        const Key('profile-edit-198.51.100.7:22:alice'),
      );
      expect(
        await _pump(tester, pwEdit, slices: 20),
        isTrue,
        reason: 'password profile row missing after import',
      );
      await tester.tap(pwEdit);
      expect(
        await _pump(tester, find.byKey(const Key('profile-editor'))),
        isTrue,
        reason: 'editor did not open for the password profile',
      );
      final pwField = find.byKey(const Key('profile-editor-password'));
      expect(
        await _pump(tester, pwField, slices: 20),
        isTrue,
        reason: 'password field not shown for the password-auth profile',
      );
      expect(
        find.byKey(const Key('profile-editor-key')),
        findsNothing,
        reason: 'key field present for a PASSWORD profile — wrong authType',
      );
    },
  );
}
