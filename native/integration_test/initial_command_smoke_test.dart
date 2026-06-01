// On-emulator RUN-ON-CONNECT smoke (#619) — proves the configured initial
// command actually executes after connect, WITHOUT the user typing it.
//
// The device bug: the run-on-connect command (#558) reached some hosts but not
// others (the owner's slow "ra-server" dropped it). Root cause: the UI fired
// the command on the bare `connected` state, racing ahead of the async task-
// side PTY shell open — `_handleInput` then dropped the bytes to scrollback.
// The fix gates the send on a task-side shell-ready signal. This smoke connects
// with an initial command of `echo <marker>` and asserts the marker appears in
// the shell output — i.e. the command ran on its own, not via a typed input.
//
// The headless race test (test/services/initial_command_shell_ready_test.dart)
// reproduces the slow-host timing deterministically with a delayed fake shell;
// this device smoke confirms the same on a real PTY. The owner's real failing
// case is ra-server (a genuinely slow host) — flag it for device validation;
// the emulator's test-sshd is a fast host, so this is a regression guard that
// the command fires at all on the new shell-ready path, not a slow-host proof.
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/sessions.dart';

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('configured run-on-connect command executes after connect', (
    tester,
  ) async {
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

    // The marker is emitted ONLY if the initial command ran on its own; the
    // test never types it. A unique token avoids matching the echoed command
    // line itself (the command text contains the marker, but so would the
    // output line — we assert the output count is >= 2 occurrences below).
    const marker = 'MOBISSH_INITCMD_OK_77';

    await adhocPasswordConnect(
      tester,
      host: '127.0.0.1',
      port: '2222',
      user: 'testuser',
      pass: 'testpass',
      initialCommand: 'echo $marker',
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

    // The run-on-connect command fires on shell-ready DURING connect, which can
    // be BEFORE this test gets to subscribe. proxy.output is a broadcast stream
    // (drops events while no one is listening), so a listener attached here
    // races the command's echo and can miss it — flaky under load. Assert
    // against the proxy's cached scrollbackTail instead: it accumulates from
    // session creation (the entry's own terminal subscription is wired then)
    // and is independent of when this test looks. The marker shows up TWICE —
    // once in the echoed command line (`echo MARKER`) and once in its stdout
    // (`MARKER`); a single occurrence would just be the command line with the
    // run-on-connect dropped.
    var ran = false;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      final text = entry!.proxy.snapshot.scrollbackTail;
      if (marker.allMatches(text).length >= 2) {
        ran = true;
        break;
      }
    }
    expect(
      ran,
      isTrue,
      reason:
          'run-on-connect command never executed — its output ($marker) did '
          'not appear in the session scrollback. The command was dropped before '
          'the PTY shell opened (#619).',
    );
  });
}
