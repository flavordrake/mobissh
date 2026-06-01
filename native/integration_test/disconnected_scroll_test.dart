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
//   (a) asserts the state-driven disconnect banner is present AND the router
//       KEEPS the terminal screen mounted (the v1 bug: the router navigated back
//       to the chooser on `disconnected`, unmounting the banner — #624 root
//       cause, fixed in main.dart), and
//   (b) drags on the TerminalView and asserts NO mouse-wheel SGR (`64;…M` etc.)
//       reaches the PTY — the scroll INPUT is gated on a live session (#624).
//
// MEASUREMENT (v2 fix): the v1 test tapped `terminal.onOutput` and recorded the
// raw bytes the terminal EMITS — but the production gate lives INSIDE that
// closure (sessions.dart: `if (proxy.data.state != connected) return;`). The
// terminal still EMITS the SGR on a drag (the gesture fires); the gate just
// doesn't forward it. So recording terminal emissions measured the wrong layer
// and the test failed on a working gate. v2 spies on the GATEWAY's outgoing
// `input` commands — the bytes that actually reach the PTY — which is the real
// contract under test.
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
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';

import 'support/connect_helpers.dart';

/// Wraps the real [FlutterForegroundSshGateway] and records the decoded bytes of
/// every `input` command sent UI→task. This is the PTY-bound byte stream — the
/// exact layer the #624 liveness gate (sessions.dart `terminal.onOutput`) feeds
/// when, and only when, the session is `connected`. Asserting against these
/// recorded bytes measures what actually reaches the remote shell, NOT what the
/// terminal merely emits (which the gate may drop).
class _InputSpyGateway implements TaskSshGateway {
  _InputSpyGateway(this._delegate);

  final TaskSshGateway _delegate;

  /// Decoded bytes of every `input` command, in send order.
  final List<int> inputBytes = <int>[];

  /// Clear the recorded input (between phases).
  void clear() => inputBytes.clear();

  @override
  void send(Map<String, dynamic> payload) {
    if (payload['kind'] == 'input') {
      final b64 = payload['bytes'] as String?;
      if (b64 != null) inputBytes.addAll(base64Decode(b64));
    }
    _delegate.send(payload);
  }

  @override
  Stream<Map<String, dynamic>> get incoming => _delegate.incoming;

  @override
  void markServiceStopped() => _delegate.markServiceStopped();

  @override
  Future<void> dispose() => _delegate.dispose();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'while disconnected: indicator shows + scroll forwards NO wheel SGR to PTY',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      final spy = _InputSpyGateway(FlutterForegroundSshGateway());
      final container = ProviderContainer(
        overrides: [taskSshGatewayProvider.overrideWithValue(spy)],
      );
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

      // Capture what the terminal EMITS (before the gate), while still
      // delegating to the production onOutput (the gate) so behaviour is
      // unchanged. Comparing emitted-vs-forwarded in both phases proves the
      // gate is the lever: live → emitted AND forwarded; dead → emitted but NOT
      // forwarded. (The gateway spy measures "forwarded"; this tap measures
      // "emitted".)
      final emitted = <int>[];
      final origOnOutput = terminal.onOutput;
      terminal.onOutput = (data) {
        emitted.addAll(utf8.encode(data));
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
      // Fill the alt buffer with real scrollback so a drag DETERMINISTICALLY
      // pages back + emits wheel SGR. An empty tmux session (cursor parked at
      // the bottom with nothing above) intermittently emits NO wheel events on
      // the first drag — the same proven `seq 1 200` lever the tmux-scrollback
      // smoke (tmux_scrollback_test.dart) uses to make the drag reliable.
      entry.proxy.sendInput(Uint8List.fromList(utf8.encode('seq 1 200\n')));
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      debugPrint(
        'CTRACE624 mouseMode=${terminal.mouseMode} '
        'alt=${terminal.isUsingAltBuffer}',
      );

      // ── BASELINE: while CONNECTED, a drag SHOULD forward wheel SGR to the
      // PTY (proves the gesture path is live + the handler emits real SGR, so a
      // later "nothing forwarded" is the GATE working, not a dead gesture). ────
      expect(
        entry.proxy.data.state,
        SshSessionState.connected,
        reason: 'precondition: session must be live before the baseline drag',
      );
      final termFinder = find.byKey(Key('terminal-view-${entry.id}'));
      expect(termFinder, findsOneWidget);
      final center = tester.getCenter(termFinder);
      // Retry the baseline drag until it emits wheel SGR. The FIRST drag right
      // after the alt buffer opens is racy on-device — xterm's scroll-report
      // path occasionally produces no wheel events until the buffer/mouse mode
      // has settled a frame or two. Retrying (bounded) makes the live baseline
      // deterministic without weakening it.
      var liveEmitted = '';
      var liveAscii = '';
      for (var attempt = 0; attempt < 6; attempt++) {
        spy.clear();
        emitted.clear();
        await tester.dragFrom(center, const Offset(0, 300));
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        liveAscii = utf8
            .decode(spy.inputBytes, allowMalformed: true)
            .replaceAll('\x1b', 'ESC');
        liveEmitted = utf8
            .decode(emitted, allowMalformed: true)
            .replaceAll('\x1b', 'ESC');
        if (liveEmitted.contains('64;') || liveEmitted.contains('65;')) break;
      }
      debugPrint('CTRACE624 bytes-forwarded-on-drag-while-LIVE=$liveAscii');
      debugPrint('CTRACE624 bytes-EMITTED-on-drag-while-LIVE=$liveEmitted');
      // The terminal MUST emit wheel SGR on a drag in this mouse mode (the
      // gesture path is live + the #617 handler emits canonical codes) AND the
      // gate MUST forward it while connected. If the terminal emits but the
      // gateway forwards nothing here, the later "dead → nothing forwarded"
      // assertion would be vacuous — so we require both to be true while live.
      expect(
        liveEmitted.contains('64;') || liveEmitted.contains('65;'),
        isTrue,
        reason:
            'precondition: a scroll drag must EMIT wheel SGR in this mouse mode '
            '— the gesture/handler path is the thing the gate later blocks: '
            '$liveEmitted',
      );
      expect(
        liveAscii.contains('64;') || liveAscii.contains('65;'),
        isTrue,
        reason:
            'while connected a scroll drag MUST forward wheel SGR to the PTY — '
            'otherwise the disconnected-case assertion is vacuous: $liveAscii',
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

      // (a1) The router must KEEP the terminal screen mounted for the kept-but-
      // dead entry — the v1 bug was that it navigated back to the chooser on
      // `disconnected`, unmounting the banner (#624 root cause).
      expect(
        find.byKey(const Key('session-menu-button')),
        findsOneWidget,
        reason:
            'router navigated away from the terminal on disconnect — the '
            'kept-but-dead entry must keep the terminal screen mounted (#624)',
      );
      // (a2) The state-driven disconnect banner must be present (#624 symptom 1).
      expect(
        find.byKey(const Key('terminal-disconnect-banner')),
        findsOneWidget,
        reason: 'no disconnect indicator while the session is dead (#624)',
      );

      // (b) Drag on the terminal AGAIN — this is the scroll gesture that dumped
      // raw wheel SGR on device. With the liveness gate, NO input bytes (and
      // definitely no `64;…M` SGR) may be FORWARDED to the PTY while
      // disconnected. We measure the gateway's outgoing input, not the
      // terminal's emission (the terminal still emits; the gate drops it).
      // Retry until the terminal EMITS wheel SGR (same first-drag race as the
      // baseline). The gate must forward NOTHING across every attempt, so the
      // spy accumulates and is asserted empty after the loop — any leak in any
      // attempt fails the test.
      spy.clear();
      var deadEmitted = '';
      for (var attempt = 0; attempt < 6; attempt++) {
        emitted.clear();
        await tester.dragFrom(center, const Offset(0, 300));
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        deadEmitted = utf8
            .decode(emitted, allowMalformed: true)
            .replaceAll('\x1b', 'ESC');
        if (deadEmitted.contains('64;') || deadEmitted.contains('65;')) break;
      }

      final ascii = utf8
          .decode(spy.inputBytes, allowMalformed: true)
          .replaceAll('\x1b', 'ESC');
      debugPrint('CTRACE624 bytes-forwarded-on-drag-while-DEAD=$ascii');
      debugPrint('CTRACE624 bytes-EMITTED-on-drag-while-DEAD=$deadEmitted');

      // The terminal STILL EMITS wheel SGR on the dead drag (the gesture fires
      // + the handler runs — xterm has no idea the PTY is dead). This is what
      // makes the gate the thing under test: the gate, not a dead gesture, is
      // why nothing is forwarded below.
      expect(
        deadEmitted.contains('64;') || deadEmitted.contains('65;'),
        isTrue,
        reason:
            'the drag must still EMIT wheel SGR while dead (gesture fires) so '
            'the "nothing forwarded" assertion proves the GATE, not a dead '
            'gesture: $deadEmitted',
      );

      // No SGR mouse-wheel body may be forwarded to the PTY.
      expect(
        ascii.contains('64;'),
        isFalse,
        reason:
            'wheel-up SGR forwarded to PTY while disconnected (#624): $ascii',
      );
      expect(
        ascii.contains('65;'),
        isFalse,
        reason: 'wheel-down SGR forwarded to PTY while disconnected (#624)',
      );
      expect(
        spy.inputBytes,
        isEmpty,
        reason:
            'NO input may be forwarded to the PTY while disconnected '
            '(#624) — got: $ascii',
      );
    },
  );
}
