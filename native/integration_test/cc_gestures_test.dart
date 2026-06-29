// On-emulator tmux control-mode (`-CC`) GESTURE parity — Part C (#911, epic #906).
//
// The deterministic repro that the wrong-row "swipe did nothing / taps sometimes
// work" window-switch bug (#903/#905) is DISSOLVED by control mode. With
// `tmuxControlMode` flipped ON, MobiSSH enters `tmux -CC` automatically (Part B),
// and window switching is driven by REAL tmux control commands over the channel —
// `next-window` / `previous-window` (swipe) and `select-window -t @<id>` (status
// tap) — NOT a synthesised SGR wheel at a guessed status row. The authoritative
// active window is read back from `%session-window-changed` (Part B repaints the
// grid on it). This test asserts, end-to-end over real SSH→tmux(-CC)→host→flterm:
//
//   1. With ≥3 windows, a swipe (next-window/previous-window via the control
//      channel) SWITCHES the active window AND repaints the grid to it.
//   2. A status-bar tap (select-window via the control channel) switches to the
//      tapped window AND repaints.
//   3. Run the switch sequence REPEATEDLY (the old failure was intermittent) — it
//      must be DETERMINISTICALLY green: every step lands on the expected window.
//
// There is NO dependence on a guessed status row: the swipe issues a real
// next/previous command and the tap maps the column to a window from the parsed
// window list — geometry is never guessed.
//
// The orchestrator runs this FLAG-ON; the shipped build keeps the flag OFF.
//
// Run: scripts/native-connect-test.sh integration_test/cc_gestures_test.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/services/session_messages.dart' show TmuxWindowGesture;
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/terminal/tmux_control_mode_flag.dart';

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late bool prevFlag;
  setUp(() => prevFlag = setTmuxControlModeForTest(true));
  tearDown(() => setTmuxControlModeForTest(prevFlag));

  testWidgets(
    '-CC gestures: real next/previous/select-window switch + repaint, '
    'deterministic over repeated switches (#911)',
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

      // Everything the host forwards to the grid (the demuxed ACTIVE window's
      // bytes). When the active window switches, Part B repaints, so a fresh
      // marker echoed in the NEW active window appears here.
      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      String rendered() => utf8.decode(out, allowMalformed: true);

      // Test scaffolding (build windows + echo per-window markers) goes over the
      // RAW stdin path — the same proven-reliable delivery cc_render_test uses. In
      // -CC, a newline-terminated stdin line IS a tmux command. We deliberately do
      // NOT route the scaffolding through `sendControlCommand`: the quoted
      // multi-token `send-keys -t :W "echo X" Enter` marker fragments across the
      // UI→isolate gateway and lands verbatim in the pane shell (the documented
      // Part-C limitation noted in cc_render_test, lines 156-170), which would
      // starve every assertion of its marker. The SWITCH — the actual thing under
      // test — is still issued via `sendTmuxGesture` (a single-token next/previous/
      // select-window command that delivers intact), so this test still proves the
      // gesture switches the active window AND the grid repaints to it.
      void send(String s) =>
          entry.proxy.sendInput(Uint8List.fromList(utf8.encode(s)));

      Future<bool> waitFor(String marker, {int ticks = 40}) async {
        for (var i = 0; i < ticks; i++) {
          await tester.pump(const Duration(milliseconds: 500));
          if (rendered().contains(marker)) return true;
        }
        return false;
      }

      // Wait for the initial control-mode paint.
      var painted = false;
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (out.isNotEmpty) {
          painted = true;
          break;
        }
      }
      expect(painted, isTrue,
          reason: 'control-mode grid received ZERO bytes — %output never demuxed');

      // Build a session with THREE windows (0,1,2). Window 0 already exists.
      // tmux makes the newly-created window active, so after this the active
      // window is window 2 (the last created). Settle so the channel processes
      // both %window-add + %session-window-changed before the first gesture.
      send('new-window -t :1 -n cc_w1\n');
      send('new-window -t :2 -n cc_w2\n');
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }

      // Settle after a gesture BEFORE echoing the target window's marker: the
      // gesture (a `previous-window` / `next-window` / `select-window` control
      // command) and the marker `send-keys` are SEPARATE async IPC envelopes. If
      // the marker echoes before the channel has processed the authoritative
      // `%session-window-changed`, the target window's %output is filtered out as
      // non-active and lost. Pumping between them lets the switch settle first.
      Future<void> settle() async {
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
      }

      // 1) SWIPE-style switch via REAL previous-window: from window 2 step back to
      //    window 1 and confirm the grid repaints to window 1's content.
      out.clear();
      entry.proxy.sendTmuxGesture(TmuxWindowGesture.previousWindow);
      await settle();
      send('send-keys -t :1 "echo CC_GEST_W1_AAA" Enter\n');
      expect(await waitFor('CC_GEST_W1_AAA'), isTrue,
          reason: 'previous-window (swipe) did not repaint to window 1. '
              'Saw: ${rendered()}');

      // 2) SWIPE-style switch via REAL next-window: window 1 → window 2.
      out.clear();
      entry.proxy.sendTmuxGesture(TmuxWindowGesture.nextWindow);
      await settle();
      send('send-keys -t :2 "echo CC_GEST_W2_BBB" Enter\n');
      expect(await waitFor('CC_GEST_W2_BBB'), isTrue,
          reason: 'next-window (swipe) did not repaint to window 2. '
              'Saw: ${rendered()}');

      // 3) STATUS-TAP switch via REAL select-window: tap the LEFT third of the
      //    status line → window 0. The host maps the column to the window from the
      //    parsed window list — no guessed status row.
      out.clear();
      entry.proxy.sendTmuxGesture(
        TmuxWindowGesture.tapStatusCol,
        statusCol: 3,
        statusCols: 90,
      );
      await settle();
      send('send-keys -t :0 "echo CC_GEST_W0_CCC" Enter\n');
      expect(await waitFor('CC_GEST_W0_CCC'), isTrue,
          reason: 'status-tap select-window did not repaint to window 0. '
              'Saw: ${rendered()}');

      // 4) DETERMINISM: run the switch sequence REPEATEDLY (the old bug was
      //    intermittent). Each cycle: select-window 1, 2, 0 and confirm a fresh
      //    per-cycle marker repaints in each. Every cycle must be green.
      for (var cycle = 0; cycle < 3; cycle++) {
        for (final w in [1, 2, 0]) {
          out.clear();
          entry.proxy.sendTmuxGesture(
            TmuxWindowGesture.tapStatusCol,
            // 3 windows over 90 cols: window 0 ~ col 3, window 1 ~ col 45,
            // window 2 ~ col 85. Map the target window to its segment.
            statusCol: w == 0 ? 3 : (w == 1 ? 45 : 85),
            statusCols: 90,
          );
          await settle();
          final marker = 'CC_GEST_CYCLE_${cycle}_W$w';
          send('send-keys -t :$w "echo $marker" Enter\n');
          expect(await waitFor(marker), isTrue,
              reason: 'cycle $cycle: switch to window $w did not repaint '
                  '(intermittent failure — must be deterministic). '
                  'Saw: ${rendered()}');
        }
      }

      // Still connected after the whole gesture storm (the channel survived).
      expect(find.byKey(const Key('session-menu-button')), findsOneWidget,
          reason: 'session torn down during the gesture sequence');

      debugPrint('CC_GESTURES: real next/previous/select-window switching is '
          'deterministic across ${3 * 3} repeated switches');
    },
  );
}
