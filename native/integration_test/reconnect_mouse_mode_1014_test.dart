// On-emulator #1014: stale mouse-reporting mode after reconnect.
//
// Owner telemetry (2026-07-08T18-13-09): a network blip dropped 5 sessions;
// ALL reconnected in ~5s, but the app kept synthesizing SGR mouse reports
// (`mouseMode` still on from the pre-drop tmux) into the revived remote —
// into a plain shell they land as literal `[<65;...M` text at the prompt.
//
// FIX under test: at the revive boundary (`proxy.shellReady`, re-fires on every
// reconnect) the ghostty view writes `ghosttyInputModeResetSequence` (DECRST
// for every synthesized-input-gating DEC private mode) LOCALLY into the
// terminal parser. The remote re-enables the modes through the byte stream if
// its TUI is still alive (tmux attach re-emits DECSET).
//
// Shape mirrors the owner's MULTI-SESSION incident: session B (plain shell,
// port 2223 — requires BRIDGE_PORT2=2223 on native-connect-test.sh) holds the
// foreground service while session A (tmux, mouse on) takes a REAL transport
// drop. A single-session soft drop instead trips a pre-existing keepalive race
// (softDisconnected does not hold the FGS; the 1→0 count stops the service
// mid-reconnect) — that race is a SEPARATE issue, deliberately not exercised.
//
// Device-class transitions validated end-to-end (real tmux on test-sshd, real
// transport drop, real held-params reconnect through the task gateway):
//   1. tmux (mouse on) → controller.mouseTracking engages; a firm TAP forwards
//      an SGR click (existing #693 behavior — the sent-SGR recorder grows).
//   2. kill session A's `sshd: testuser@pts/N` (via a throwaway dartssh2 EXEC
//      connection; exec = @notty so the killer never matches itself) → A goes
//      softDisconnected like the owner's blip → reconnect revives a PLAIN
//      prompt (tmux stays detached) → mouseTracking resets to NONE; a tap
//      forwards NO SGR; no literal `[<` garbage renders; B stays connected.
//   3. `tmux attach` (the TUI was alive all along) → its re-emitted DECSET
//      re-engages mouse tracking with no user action.
//
// Bridge: BRIDGE_PORT2=2223 scripts/native-connect-test.sh \
//     integration_test/reconnect_mouse_mode_1014_test.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'reconnect resets stale mouse mode: no SGR into the revived plain shell; '
    'a live TUI re-enables via bytes (#1014)',
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

      /// Pump in 500ms slices until [test] passes or [maxSlices] elapse,
      /// accepting any host-key trust prompt along the way.
      Future<bool> pumpUntil(bool Function() test, {int maxSlices = 60}) async {
        for (var i = 0; i < maxSlices; i++) {
          await tester.pump(const Duration(milliseconds: 500));
          final trust = find.text('Trust + connect');
          if (trust.evaluate().isNotEmpty) {
            await tester.tap(trust.first);
            await tester.pump(const Duration(milliseconds: 300));
          }
          if (test()) return true;
        }
        return false;
      }

      Future<void> settle([int ticks = 8]) async {
        for (var i = 0; i < ticks; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
      }

      // Session B FIRST (plain shell on the 2223 bridge): holds the foreground
      // service through A's drop, mirroring the owner's multi-session incident.
      await adhocPasswordConnect(
        tester,
        host: '127.0.0.1',
        port: '2223',
        user: 'testuser',
        pass: 'testpass',
      );
      final reachedB = await pumpUntil(
        () => find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty,
      );
      expect(reachedB, isTrue, reason: 'session B never reached the terminal');
      final entryB = container.read(sessionsProvider).active!;
      final connectedB = await pumpUntil(
        () => entryB.proxy.data.state == SshSessionState.connected,
      );
      expect(connectedB, isTrue, reason: 'session B never connected');

      // Session A (the victim, on 2222) via the New-session flow. Connected
      // LAST so it is the ACTIVE, VISIBLE view for the whole gesture phase.
      await tester.tap(find.byKey(const Key('session-menu-button')));
      await settle(4);
      expect(find.byKey(const Key('session-menu-new')), findsOneWidget,
          reason: 'no New-session affordance in the session menu');
      await tester.tap(find.byKey(const Key('session-menu-new')));
      await settle(6);
      await adhocPasswordConnect(
        tester,
        host: '127.0.0.1',
        port: '2222',
        user: 'testuser',
        pass: 'testpass',
      );
      final connectedA = await pumpUntil(() {
        final entries = container.read(sessionsProvider).entries;
        return entries.length == 2 &&
            entries.every(
              (e) => e.proxy.data.state == SshSessionState.connected,
            );
      });
      expect(connectedA, isTrue, reason: 'session A never connected');
      final entry = container.read(sessionsProvider).active!;
      expect(entry.id, isNot(entryB.id),
          reason: 'active session after the 2nd connect must be A');
      final sessionId = entry.id;

      TerminalController? ctrlOf() =>
          GhosttyTerminalView.debugControllers[sessionId];
      final gotController = await pumpUntil(() => ctrlOf() != null);
      expect(gotController, isTrue, reason: 'no ghostty controller for A');
      final controller = ctrlOf()!;

      void send(String cmd) =>
          entry.proxy.sendInput(Uint8List.fromList(utf8.encode(cmd)));

      String rendered() {
        final v = controller.scrollbar.visible;
        final rows = v > 0 ? v : 24;
        return controller.visibleRowsText(0, rows - 1);
      }

      // A firm tap at the terminal center — under mouse mode the #693 overlay
      // forwards it as an SGR click (press+release), recorded by the sent-SGR
      // recorder; with mouse mode off it only focuses (NO SGR by design).
      Future<void> tapTerminalCenter() async {
        final center = tester.getCenter(
          find.byKey(Key('ghostty-terminal-$sessionId')),
        );
        await tester.tapAt(center);
        await settle(4);
      }

      final recorder = GhosttyTerminalView.debugByteRecorders[sessionId];
      expect(recorder, isNotNull, reason: 'no byte recorder for session A');
      int sgrCount() => recorder!.snapshotSentSgrTrace().length;

      // Phase 1 — pre-drop: a mouse-reporting TUI (tmux, mouse on) on A.
      send('tmux kill-server 2>/dev/null; tmux set -g mouse on \\; '
          'new -s m1014\n');
      var engaged = await pumpUntil(
        () => controller.mouseTracking != MouseTracking.none,
        maxSlices: 30,
      );
      if (!engaged) {
        send('tmux set -g mouse on\n');
        engaged = await pumpUntil(
          () => controller.mouseTracking != MouseTracking.none,
          maxSlices: 20,
        );
      }
      expect(engaged, isTrue, reason: 'setup: tmux mouse mode never engaged');

      final sgrBeforeTap = sgrCount();
      await tapTerminalCenter();
      expect(sgrCount(), greaterThan(sgrBeforeTap),
          reason: 'precondition (existing #693 behavior): a tap under mouse '
              'mode must forward an SGR click');

      // Phase 2 — REAL transport drop of A ONLY: kill the sshd process behind
      // the tmux-attached client tty (that is A; B is not attached to tmux).
      // Run over a throwaway dartssh2 EXEC connection: exec allocates no pty
      // (`@notty`), so the pattern can never match the killer itself.
      final killer = SSHClient(
        await SSHSocket.connect('127.0.0.1', 2222),
        username: 'testuser',
        onPasswordRequest: () => 'testpass',
      );
      final killOut = utf8.decode(
        await killer.run(
          r'T=$(tmux display -p -t m1014 "#{client_tty}"); '
          r'pkill -9 -f "sshd: testuser@${T#/dev/}"; '
          r'echo "KILLED_TTY=$T"',
        ),
      );
      debugPrint('#1014 transport kill: $killOut');
      killer.close();

      final dropped = await pumpUntil(
        () => entry.proxy.data.state != SshSessionState.connected,
      );
      expect(dropped, isTrue,
          reason: 'transport kill never dropped session A ($killOut)');

      // Held-params revive (force-now skips the reconnect backoff — the same
      // task-side `reconnectNow()` path the auto-reconnect takes).
      entry.proxy.reconnect();
      final revived = await pumpUntil(
        () => entry.proxy.data.state == SshSessionState.connected,
        maxSlices: 80,
      );
      expect(revived, isTrue, reason: 'held-params reconnect never revived A');

      // THE #1014 ASSERT: the revive boundary must reset the stale mouse mode.
      final resetLanded = await pumpUntil(
        () => controller.mouseTracking == MouseTracking.none,
        maxSlices: 24,
      );
      expect(
        resetLanded,
        isTrue,
        reason: 'STALE MODE (#1014): mouse tracking survived the reconnect '
            '(still ${controller.mouseTracking}) — the app would keep '
            'synthesizing SGR into the revived plain shell',
      );

      // Prove the gesture path is disarmed: a tap forwards NOTHING and no
      // mouse-report garbage renders at the revived prompt.
      await settle(12);
      final sgrBeforeRevivedTap = sgrCount();
      await tapTerminalCenter();
      expect(
        sgrCount(),
        sgrBeforeRevivedTap,
        reason: '#1014: a tap AFTER the plain-shell revive still forwarded an '
            'SGR mouse report — stale mode state kept the synth path armed',
      );
      expect(
        rendered().contains('[<'),
        isFalse,
        reason: '#1014 owner symptom: literal SGR mouse-report text ([<...M) '
            'rendered at the revived prompt',
      );

      // Isolation: B (never in mouse mode, never dropped) must be untouched.
      expect(entryB.proxy.data.state, SshSessionState.connected,
          reason: 'session B must survive A\'s drop/revive');

      // Phase 3 — the TUI was alive all along: re-attach re-emits DECSET
      // through the byte stream and mouse tracking re-engages, no user action.
      send('tmux attach\n');
      final reEngaged = await pumpUntil(
        () => controller.mouseTracking != MouseTracking.none,
        maxSlices: 30,
      );
      expect(reEngaged, isTrue,
          reason: 'a re-attached tmux (mouse on) must re-enable tracking via '
              'its own DECSET bytes — the parser path, no manual re-arm');
    },
  );
}
