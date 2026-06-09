// On-emulator ATTENTION-NOTIFICATION POST test (#840, Slice 2).
//
// Slice 1 proved the scanner detects an OSC 9 over a live session. Slice 2 adds
// the NOTIFICATION layer. This test connects, emits an OSC 9 carrying a
// `(win N)` source-window hint, and asserts the host's POST path ran for that
// session — observed via the task-isolate `clifecycle` ring (forwarded to the
// UI ring, #766), which records `posted notification session <id>` at the
// detection point. We can't read the system tray from an integration test, so
// the lifecycle marker is the test seam (mirrors the Slice-1 measurement style:
// lenient but real — it asserts the poster was INVOKED, not the OS render).
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).

@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/diagnostics/connect_trace.dart';

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('OSC 9 over a live session triggers an attention-notification '
      'post for that session', (tester) async {
    FlutterForegroundTask.initCommunicationPort();

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MobisshApp(),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    await adhocPasswordConnect(
      tester,
      host: '127.0.0.1',
      port: '2222',
      user: 'testuser',
      pass: 'testpass',
    );

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

    final entry = container.read(sessionsProvider).active;
    expect(entry, isNotNull, reason: 'no active session after connect');
    final proxy = entry!.proxy;
    final sid = entry.id;

    final out = <int>[];
    final sub = proxy.output.listen(out.addAll);
    addTearDown(sub.cancel);

    void send(String cmd) =>
        proxy.sendInput(Uint8List.fromList(utf8.encode(cmd)));

    // Wait for the shell prompt (proves the PTY is live).
    for (var i = 0; i < 40 && out.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(out.isNotEmpty, isTrue, reason: 'no shell prompt — dead PTY');

    // Background the app so this active session is NOT suppressed (the test
    // would otherwise be looking right at it). On a backgrounded session the
    // poster always fires.
    proxy.setActive(false, activeSessionId: sid);
    await tester.pump(const Duration(milliseconds: 300));

    final before = lifecycleLogSnapshot().length;

    // Emit an OSC 9 carrying a (win N) hint over the live PTY.
    send("printf '\\033]9;Claude — testwin (win 2)\\007'\n");

    // Give the byte round-trip + scanner + post path time to log.
    var posted = false;
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      final ring = lifecycleLogSnapshot();
      for (var j = before; j < ring.length; j++) {
        final line = ring[j];
        if (line.contains('[attention]') &&
            line.contains('posted notification') &&
            line.contains(sid)) {
          posted = true;
          break;
        }
      }
      if (posted) break;
    }

    final sb = StringBuffer();
    sb.writeln('ATTENTION840S2 ===== POST FINDINGS (#840 Slice 2) =====');
    sb.writeln('ATTENTION840S2 session=$sid posted=$posted');
    for (final line in lifecycleLogSnapshot()) {
      if (line.contains('[attention]')) sb.writeln('ATTENTION840S2 $line');
    }
    debugPrint(sb.toString());

    expect(
      posted,
      isTrue,
      reason: 'no attention-notification post was logged for the session after '
          'an OSC 9 — the Slice-2 poster path is not wired. Findings:\n$sb',
    );
  });
}
