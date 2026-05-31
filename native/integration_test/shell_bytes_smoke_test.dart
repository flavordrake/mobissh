// On-emulator SHELL-BYTES smoke — the test that should have existed.
//
// The device bug: every profile reached the terminal SCREEN (cursor) but no
// shell bytes ever arrived — the #533 task-isolate migration never opened the
// PTY shell task-side. connect_smoke_test only asserts the terminal WIDGET
// mounts, which is NOT "logged in." This test proves the real thing: after
// connecting, (1) the shell produces output bytes, and (2) a typed command
// echoes back through the UI proxy.
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/sessions.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('connected session streams shell bytes and echoes input',
      (tester) async {
    FlutterForegroundTask.initCommunicationPort();

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const MobisshApp()),
    );
    await tester.pump(const Duration(seconds: 1));

    await tester.enterText(find.byKey(const Key('connect-host')), '127.0.0.1');
    await tester.enterText(find.byKey(const Key('connect-port')), '2222');
    await tester.enterText(
        find.byKey(const Key('connect-username')), 'testuser');
    await tester.enterText(
        find.byKey(const Key('connect-password')), 'testpass');
    await tester.pump();
    await tester.tap(find.byKey(const Key('connect-submit')));

    // Reach the terminal screen, accepting the host-key prompt if shown.
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
    expect(connected, isTrue, reason: 'never reached the terminal screen');

    // Capture everything the task side streams to the UI terminal.
    final entry = container.read(sessionsProvider).active;
    expect(entry, isNotNull, reason: 'no active session after connect');
    final out = <int>[];
    final sub = entry!.proxy.output.listen(out.addAll);
    addTearDown(sub.cancel);

    // 1) The shell must produce SOME output (a prompt) — proves the PTY opened
    //    and bytes flow. This is the exact thing that was dead on device.
    var gotPrompt = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (out.isNotEmpty) {
        gotPrompt = true;
        break;
      }
    }
    expect(gotPrompt, isTrue,
        reason: 'terminal received ZERO bytes after connect — the dead-shell '
            'hang (no PTY opened task-side)');

    // 2) A typed command must echo back through the proxy round-trip.
    const marker = 'MOBISSH_SHELL_OK_42';
    entry.proxy.sendInput(Uint8List.fromList(utf8.encode('echo $marker\n')));
    var sawMarker = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (utf8.decode(out, allowMalformed: true).contains(marker)) {
        sawMarker = true;
        break;
      }
    }
    expect(sawMarker, isTrue,
        reason: 'typed command never echoed back — input not routed to the PTY');
  });
}
