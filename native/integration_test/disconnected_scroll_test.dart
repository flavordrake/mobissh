// On-emulator DISCONNECTED-SCROLL smoke (#624).
//
// The device bug (build 030596c): after a session drops, (1) there is NO visual
// indication the terminal is dead, and (2) scroll gestures dump literal
// `64;12;19M64;12;19M…` text at the prompt — the SGR mouse-wheel report bodies
// from the #617 WheelFixMouseHandler, landing as input/echo because no live PTY
// in mouse mode consumes them.
//
// This test connects to test-sshd, starts tmux with mouse on (so the
// WheelFixMouseHandler IS in scroll-report mode and WOULD emit wheel SGR on a
// drag), then forces a disconnect WITHOUT closing the session entry
// (`proxy.disconnect()` — the task host tears down the SSHClient and emits a
// disconnected/closed state; the entry stays in the collection, exactly like a
// network drop). It then:
//   (a) asserts the state-driven disconnect banner is present, and
//   (b) drags on the TerminalView and asserts NO mouse-wheel SGR (`64;…M` etc.)
//       reaches the PTY — the scroll input is gated on a live session (#624).
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
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/sessions.dart';

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'while disconnected: indicator shows + scroll emits NO wheel SGR to PTY',
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
        if (find
            .byKey(const Key('session-menu-button'))
            .evaluate()
            .isNotEmpty) {
          connected = true;
          break;
        }
      }
      expect(connected, isTrue, reason: 'never reached the terminal screen');

      final entry = container.read(sessionsProvider).active;
      expect(entry, isNotNull, reason: 'no active session after connect');
      final terminal = entry!.terminal;

      // Tap the PTY-bound onOutput so we can observe exactly what a drag would
      // forward, WITHOUT changing the gating behaviour under test.
      final sentToPty = <int>[];
      final origOnOutput = terminal.onOutput;
      terminal.onOutput = (data) {
        sentToPty.addAll(utf8.encode(data));
        origOnOutput?.call(data);
      };
      addTearDown(() => terminal.onOutput = origOnOutput);

      // Wait for the shell prompt.
      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      for (var i = 0; i < 40 && out.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(out.isNotEmpty, isTrue, reason: 'no shell prompt — dead PTY');

      // Put the terminal into a scroll-reporting mouse mode (tmux mouse on) so
      // the WheelFixMouseHandler WOULD emit wheel SGR on a drag. This is the
      // condition that produced the garbage on device.
      entry.proxy.sendInput(
        Uint8List.fromList(
          utf8.encode(
            "tmux kill-server 2>/dev/null; tmux set -g mouse on \\; new -s t\n",
          ),
        ),
      );
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (terminal.isUsingAltBuffer) break;
      }
      debugPrint(
        'CTRACE624 mouseMode=${terminal.mouseMode} '
        'alt=${terminal.isUsingAltBuffer}',
      );

      // ── FORCE A DISCONNECT, keeping the entry (network-drop analogue). ──────
      // proxy.disconnect() tells the task host to tear down the SSHClient; it
      // emits a disconnected/closed state event. The entry stays in the
      // collection (unlike the Disconnect button which close()s it), so the
      // terminal screen still renders THIS session — exactly the bug scenario.
      entry.proxy.disconnect();
      var dead = false;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        final st = entry.proxy.data.state;
        if (st != SshSessionState.connected &&
            st != SshSessionState.idle &&
            st != SshSessionState.connecting) {
          dead = true;
          break;
        }
      }
      expect(
        dead,
        isTrue,
        reason:
            'session never left the connected state after disconnect '
            '(state=${entry.proxy.data.state})',
      );

      // (a) The state-driven disconnect banner must be present (#624 symptom 1).
      expect(
        find.byKey(const Key('terminal-disconnect-banner')),
        findsOneWidget,
        reason: 'no disconnect indicator while the session is dead (#624)',
      );

      // (b) Drag on the terminal — this is the scroll gesture that dumped raw
      // wheel SGR on device. With the liveness gate, NO bytes (and definitely
      // no `64;…M` SGR) may reach the PTY while disconnected.
      sentToPty.clear();
      final termFinder = find.byKey(Key('terminal-view-${entry.id}'));
      expect(termFinder, findsOneWidget);
      final center = tester.getCenter(termFinder);
      await tester.dragFrom(center, const Offset(0, 300));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      final ascii = utf8
          .decode(sentToPty, allowMalformed: true)
          .replaceAll('\x1b', 'ESC');
      debugPrint('CTRACE624 bytes-sent-on-drag-while-dead=$ascii');

      // No SGR mouse-wheel body may appear in the forwarded bytes.
      expect(
        ascii.contains('64;'),
        isFalse,
        reason: 'wheel-up SGR leaked to PTY while disconnected (#624): $ascii',
      );
      expect(
        ascii.contains('65;'),
        isFalse,
        reason: 'wheel-down SGR leaked to PTY while disconnected (#624)',
      );
      expect(
        ascii.contains('M'),
        isFalse,
        reason: 'SGR report terminator leaked to PTY while disconnected',
      );
      expect(
        sentToPty,
        isEmpty,
        reason:
            'NO terminal output may reach the PTY while disconnected '
            '(#624) — got: $ascii',
      );
    },
  );
}
