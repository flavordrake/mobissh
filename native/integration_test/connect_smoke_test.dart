// On-emulator connect smoke (#539 release gate).
//
// Runs the REAL app on a device/emulator — real foreground-task isolate, real
// platform channels, real dartssh2 socket. This is the only test tier that
// exercises the UI→task-isolate bootstrap; the headless widget tests inject
// an InMemoryGatewayPair where both sides live in one isolate, so they cannot
// see the bootstrap deadlock that shipped in #533 (see #539).
//
// Network: the runner (scripts/native-connect-test.sh) sets up
//   emulator localhost:2222 → (adb reverse) → fd-dev localhost:2222
//                           → (socat)        → test-sshd:22
// so connecting to 127.0.0.1:2222 with testuser/testpass reaches the Alpine
// test sshd container. Host-key is trust-on-first-use; this test accepts it.
//
// PASS = the session reaches the terminal screen (session-menu AppBar button
// appears) within the timeout. FAIL/timeout = the connect never completed —
// the #539 deadlock signature.
//
// NOTE: we pump `MobisshApp` directly rather than calling `app.main()`.
// `main()` wraps everything in `CrashReporter.runGuarded`, which overrides
// `FlutterError.onError` and conflicts with the integration-test binding's
// error capture. We still call `initCommunicationPort()` (which `main()` does)
// so the FFT IPC channel is open.

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('connect to test-sshd reaches connected state', (tester) async {
    // Open the FFT isolate comms port (main() does this before runApp).
    FlutterForegroundTask.initCommunicationPort();

    await tester.pumpWidget(const ProviderScope(child: MobisshApp()));
    await tester.pump(const Duration(seconds: 1));

    // Fill the connect form. Fields are keyed (#539 testability).
    await tester.enterText(find.byKey(const Key('connect-host')), '127.0.0.1');
    await tester.enterText(find.byKey(const Key('connect-port')), '2222');
    await tester.enterText(
        find.byKey(const Key('connect-username')), 'testuser');
    await tester.enterText(
        find.byKey(const Key('connect-password')), 'testpass');
    await tester.pump();

    await tester.tap(find.byKey(const Key('connect-submit')));

    // Poll for up to 30s. Can't pumpAndSettle — the terminal animates + the
    // socket is live, so the tree never settles. Pump 500ms slices and look
    // for the success signal each slice.
    var connected = false;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 500));

      // Accept a host-key prompt if it surfaced (new host, trust on first use).
      // The dialog's confirm button is labelled "Trust + connect"
      // (host_key_dialog.dart) — NOT "Accept".
      final accept = find.text('Trust + connect');
      if (accept.evaluate().isNotEmpty) {
        await tester.tap(accept.first);
        await tester.pump(const Duration(milliseconds: 300));
      }

      // The terminal screen replaces the connect form on connect. Its
      // session-menu AppBar button (#518) only exists on the terminal screen.
      if (find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty) {
        connected = true;
        break;
      }
    }

    expect(connected, isTrue,
        reason: 'session did not reach connected within 30s — '
            'this is the #539 connect-deadlock signature');
  });
}
