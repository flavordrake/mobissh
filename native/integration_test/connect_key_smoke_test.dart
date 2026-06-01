// On-emulator KEY-AUTH connect smoke.
//
// The password smoke (connect_smoke_test.dart) only ever exercised password
// auth. Real profiles use PUBLIC-KEY auth, and a device bug surfaced where
// every key profile hangs after the host-key prompt is accepted — login never
// completes. This test reproduces the real path: switch to Key mode, paste a
// known-good private key, connect, ACCEPT the host-key prompt, and assert the
// session reaches the terminal screen.
//
// The key below is the throwaway test fixture committed at
// docker/test-sshd/testuser_id_ed25519 — it is NOT a real secret; it only
// authenticates testuser against the local Alpine test-sshd container. Embedded
// because integration tests run on-device and can't read the repo filesystem.
//
// Network bridge is set up by scripts/native-connect-test.sh exactly as for the
// password smoke (127.0.0.1:2222 → socat → test-sshd:22).
//
// PASS = terminal screen mounts (session-menu-button) within the timeout.
// FAIL/timeout = the key-auth-after-host-key-accept hang.

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;

import 'support/connect_helpers.dart';

const _testKeyPem = '''-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACB85qILD6Ykve+v2FrQWtcrsjW1baL6CXJ4LD5mmiDTdgAAAJgTrJmWE6yZ
lgAAAAtzc2gtZWQyNTUxOQAAACB85qILD6Ykve+v2FrQWtcrsjW1baL6CXJ4LD5mmiDTdg
AAAEBbgsew/IHGlnh7mBUSl/1dndeVjG9AmMGYWl0TNGsVK3zmogsPpiS976/YWtBa1yuy
NbVtovoJcngsPmaaINN2AAAAFXRlc3R1c2VyQG1vYmlzc2gtdGVzdA==
-----END OPENSSH PRIVATE KEY-----''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('key-auth connect to test-sshd reaches connected state', (
    tester,
  ) async {
    FlutterForegroundTask.initCommunicationPort();

    await tester.pumpWidget(const ProviderScope(child: MobisshApp()));
    await tester.pump(const Duration(seconds: 1));

    // #583: connect ad-hoc via "New connection" → editor (Key mode) →
    // "Save & connect".
    await adhocKeyConnect(
      tester,
      host: '127.0.0.1',
      port: '2222',
      user: 'testuser',
      keyPem: _testKeyPem,
    );

    // Poll up to 30s. Accept the host-key prompt when it appears (fresh install
    // → it WILL appear; this is the path the password smoke skipped on a
    // cached fingerprint).
    var connected = false;
    var acceptedHostKey = false;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 500));

      final accept = find.text('Trust + connect');
      if (accept.evaluate().isNotEmpty) {
        await tester.tap(accept.first);
        acceptedHostKey = true;
        await tester.pump(const Duration(milliseconds: 300));
      }

      if (find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty) {
        connected = true;
        break;
      }
    }

    expect(
      acceptedHostKey,
      isTrue,
      reason: 'host-key prompt never appeared — fresh install should prompt',
    );
    expect(
      connected,
      isTrue,
      reason:
          'KEY-AUTH session did not reach connected within 30s after '
          'accepting the host key — the device key-auth hang',
    );
  });
}
