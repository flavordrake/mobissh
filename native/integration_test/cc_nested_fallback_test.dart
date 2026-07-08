// On-emulator reproduction + fix gate for #982: control mode (`-CC`) must NOT
// BRICK the connection in a NESTED tmux (the owner's real env).
//
// The owner's login auto-attaches a persistent tmux, so MobiSSH's shell channel
// lands INSIDE tmux. The app then types `tmux -CC attach ...` into that inner
// pane, where -CC can NEVER attach (nested) → the control-mode handshake never
// completes. On main this BRICKS the session: the CC parser swallows the real
// terminal bytes and the refresh-client resize commands leak into the pane as
// text — the user "can't ssh in" and must turn control mode OFF.
//
// The fix: if the -CC handshake is not confirmed within a bounded timeout, tear
// down the control-mode channel and FALL BACK to the scrape path so the
// connection WORKS (renders the shell normally, PTY-winsize resize).
//
// This test connects with control mode ON to the NESTED fixture, then types a
// marker command and asserts it RENDERS. On main the marker never appears (CC
// swallows it) → RED. After the fallback fix it appears via scrape → GREEN.
//
// Setup (run FIRST): scripts/cc-nested-setup.sh
// Run: scripts/native-connect-test.sh integration_test/cc_nested_fallback_test.dart
// Teardown (restore plain login): scripts/cc-nested-teardown.sh

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/tmux_control_mode_setting.dart';
import 'package:mobissh/terminal/tmux_control_mode_flag.dart';

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late bool prevFlag;
  setUp(() => prevFlag = setTmuxControlModeForTest(true));
  tearDown(() => setTmuxControlModeForTest(prevFlag));

  testWidgets(
    'control mode ON degrades to scrape in NESTED tmux — no brick (#982)',
    (tester) async {
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

      // Turn control mode ON through the provider (mirrors cc_attach_existing).
      await container.read(tmuxControlModeProvider.notifier).set(true);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(tmuxControlMode, isTrue,
          reason: 'control-mode global must be ON before connect');

      await adhocPasswordConnect(
        tester,
        host: '127.0.0.1',
        port: '2222',
        user: 'testuser',
        pass: 'testpass',
      );

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

      final entry = container.read(sessionsProvider).active!;
      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      String rendered() => utf8.decode(out, allowMalformed: true);

      void send(String s) =>
          entry.proxy.sendInput(Uint8List.fromList(utf8.encode(s)));

      // Let the handshake-gate timeout elapse and control mode FALL BACK to
      // scrape (the fix). On main there is no fallback — the session stays a
      // swallowed -CC stream.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }

      // Type a marker into the (nested) inner shell. Under scrape the echo
      // renders; under a stuck -CC parser it is swallowed. Retry across a
      // generous window so a single dropped keystroke can't flake it.
      var seen = false;
      for (var attempt = 0; attempt < 6 && !seen; attempt++) {
        out.clear();
        send('echo NESTED_OK_982_MARKER\n');
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 500));
          if (rendered().contains('NESTED_OK_982_MARKER')) {
            seen = true;
            break;
          }
        }
      }

      // Hold on-screen for the emu-shot capture point.
      await tester.pump(const Duration(seconds: 2));

      expect(seen, isTrue,
          reason: 'control mode ON in a NESTED tmux BRICKED the connection — '
              'the marker never rendered (the -CC parser swallowed the shell '
              'output and never fell back to scrape). Saw: ${rendered()}');

      // The leaked refresh-client control command must NOT reach the pane as
      // literal text (the handshake gate must hold every -CC write until attach).
      expect(rendered().contains('refresh-client -C'), isFalse,
          reason: 'a refresh-client control command leaked into the shell as '
              'text — the handshake gate did not hold. Saw: ${rendered()}');

      debugPrint('CC_NESTED_FALLBACK: control mode degraded to scrape in a '
          'nested tmux — connection usable, no leaked commands');
    },
  );
}
