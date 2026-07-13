// On-emulator #1072: terminal AUTO-write-backs leak as literal input across a
// reconnect/revive.
//
// Owner symptom (recurring): returning to a session shows `?62c` typed at the
// prompt. `?62c` is the printable tail of a Primary Device Attributes REPLY
// (`\x1b[?62c`, conformance level 62). Root: a `\x1b[c` DA REQUEST parsed out of
// the remote output stream makes flterm auto-reply through the SAME channel
// user keystrokes exit on (`onWritePty → _emitOutput → onOutput → sendInput`).
// When the remote (tmux) is mid-reattach it does NOT consume the reply, so its
// tty echoes it back as literal input at the prompt. Same family as #1014
// (stale mouse mode → `[<..M` garbage on revive).
//
// FIX under test: at the revive boundary (`proxy.shellReady`, re-fires on every
// reconnect) the ghostty view arms a short RECONNECT SETTLE window on the
// controller; while it is active, terminal AUTO-replies (DA/DSR/CPR, focus,
// mouse reports) are DROPPED. User keystrokes/text/paste are never gated.
//
// DETERMINISTIC repro (a plain-shell / mid-use fixture FALSE-PASSES — the leak
// is only gated during the post-reconnect settle window, so the injection must
// happen INSIDE that window):
//   1. Dual session mirroring #1014: B (plain shell, 2223) holds the foreground
//      service through A's drop; A (tmux mouse on, 2222) is the victim.
//   2. REAL transport drop of A (kill the sshd behind A's tmux client tty) →
//      held-params reconnect revives A's shell → `proxy.shellReady` fires.
//   3. ON that revive tick (inside the settle window the app just armed) inject
//      a `\x1b[c` DA REQUEST into A's terminal parser. flterm auto-replies.
//        - BUG (no gate): the reply reaches the revived tty, which echoes `?62`
//          back into A's output → RED.
//        - FIXED: the reply is dropped during settle → no `?62` echo → GREEN.
//   4. POSITIVE CONTROL: after the settle window elapses, inject `\x1b[c` again.
//      It MUST now echo `?62` — proving the gate is time-bounded (initial-connect
//      DA detection is untouched) and that the echo mechanism itself works.
//
// Bridge: BRIDGE_PORT2=2223 scripts/native-connect-test.sh \
//     integration_test/reconnect_da_writeback_leak_1072_test.dart

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

  // Primary DA REQUEST (CSI c). flterm answers `\x1b[?62c`; the revived tty
  // echoes `?62c` — the exact owner symptom.
  final daRequest = Uint8List.fromList(utf8.encode('\x1b[c'));

  testWidgets(
    'reconnect settle drops the DA auto-reply: no `?62c` leaks at the revived '
    'prompt, but DA detection still works after the window (#1072)',
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

      // Session B FIRST (plain shell on 2223): holds the foreground service
      // through A's drop, mirroring #1014's multi-session incident.
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
      // LAST so it is the ACTIVE, VISIBLE view for the whole phase.
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

      // Accumulate everything A's remote sends back. The DA request we inject is
      // written to the LOCAL parser (controller.write) and never reaches the
      // remote — so a `?62` here can ONLY be the revived tty echoing flterm's
      // leaked auto-reply.
      final out = <int>[];
      final outSub = entry.proxy.output.listen(out.addAll);
      addTearDown(outSub.cancel);
      String seenFrom(int mark) =>
          utf8.decode(out.sublist(mark), allowMalformed: true);

      // Engage tmux mouse mode on A (the owner environment). The revive itself
      // lands a plain shell (tmux stays detached after the kill), which echoes
      // deterministically.
      send('tmux kill-server 2>/dev/null; tmux set -g mouse on \\; new -s d1072\n');
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
      await settle(8);

      // Inject the DA request on the REVIVE shellReady tick — inside the settle
      // window the app arms there. Guarded so only the post-drop revive fires it
      // (the initial-connect shellReady already fired before we subscribe).
      var armInject = false;
      var injected = false;
      var injectMark = 0;
      final srSub = entry.proxy.shellReady.listen((_) {
        if (!armInject || injected) return;
        injected = true;
        injectMark = out.length;
        // The app's own shellReady listener (registered at initState, BEFORE
        // this one) has just armed the reconnect-settle window synchronously.
        controller.write(daRequest);
      });
      addTearDown(srSub.cancel);

      // REAL transport drop of A only: kill the sshd behind A's tmux client tty
      // over a throwaway EXEC connection (@notty, so it never matches itself).
      armInject = true;
      final killer = SSHClient(
        await SSHSocket.connect('127.0.0.1', 2222),
        username: 'testuser',
        onPasswordRequest: () => 'testpass',
      );
      final killOut = utf8.decode(
        await killer.run(
          r'T=$(tmux display -p -t d1072 "#{client_tty}"); '
          r'pkill -9 -f "sshd: testuser@${T#/dev/}"; '
          r'echo "KILLED_TTY=$T"',
        ),
      );
      debugPrint('#1072 transport kill: $killOut');
      killer.close();

      final dropped = await pumpUntil(
        () => entry.proxy.data.state != SshSessionState.connected,
      );
      expect(dropped, isTrue,
          reason: 'transport kill never dropped session A ($killOut)');

      // Held-params revive (skips backoff — same reconnectNow path).
      entry.proxy.reconnect();
      final revived = await pumpUntil(
        () => entry.proxy.data.state == SshSessionState.connected,
        maxSlices: 80,
      );
      expect(revived, isTrue, reason: 'held-params reconnect never revived A');

      final injectedOk = await pumpUntil(() => injected, maxSlices: 40);
      expect(injectedOk, isTrue,
          reason: 'the revive shellReady never fired — DA request not injected');

      // Let any echo of a LEAKED reply come back (kernel tty echo, ~tens ms).
      await settle(6);

      // THE #1072 ASSERT: during the settle window the DA reply must NOT reach
      // the revived tty, so nothing echoes `?62` at the prompt.
      final leaked = seenFrom(injectMark);
      debugPrint('#1072 post-inject output: ${jsonEncode(leaked)}');
      expect(
        leaked.contains('?62') || leaked.contains('62c'),
        isFalse,
        reason: 'DA AUTO-REPLY LEAK (#1072): flterm answered a DA request during '
            'the reconnect settle window and the revived tty echoed it as literal '
            'input (`?62c`) at the prompt. output=${jsonEncode(leaked)}',
      );

      // POSITIVE CONTROL: past the settle window, DA detection must still work —
      // a fresh DA request now DOES answer and the tty echoes `?62`. This proves
      // the gate is time-bounded (not a blanket drop) AND that this environment
      // echoes the reply, so the assert above is a real discriminator.
      await settle(12); // > the settle window
      final ctrlMark = out.length;
      controller.write(daRequest);
      final echoed = await pumpUntil(
        () => seenFrom(ctrlMark).contains('62'),
        maxSlices: 24,
      );
      expect(
        echoed,
        isTrue,
        reason: 'POSITIVE CONTROL: after the settle window a DA request produced '
            'NO `?62` echo — either DA detection was over-gated (broken) or this '
            'shell does not echo the reply (test harness assumption wrong). '
            'output=${jsonEncode(seenFrom(ctrlMark))}',
      );

      // Isolation: B (never dropped) must survive.
      expect(entryB.proxy.data.state, SshSessionState.connected,
          reason: 'session B must survive A\'s drop/revive');
    },
  );
}
