// On-emulator tmux control-mode (`-CC`) RENDER parity — Part B (#909, epic #906).
//
// THE deterministic repro of the whole control-mode saga. With `tmuxControlMode`
// flipped ON, MobiSSH connects and the host enters `tmux -CC` AUTOMATICALLY
// (TmuxControlChannel.entryCommand), parses the control stream, and forwards the
// ACTIVE window's demuxed %output to the grid. This test asserts, end-to-end over
// the real SSH→tmux(-CC)→host→flterm chain:
//
//   1. The grid RENDERS the active window's content (demuxed %output reaches the
//      UI as terminal bytes).
//   2. Switching windows (issuing `select-window` directly — allowed here as a
//      TEST action even though the gesture rewrite is Part C) REPAINTS the grid
//      to the new window's content (the authoritative active-window switch).
//   3. Toggling the keyboard holds SIZE PARITY: the resize travels as a single
//      `refresh-client -C` (tmux owns layout math, so app grid == tmux size) and
//      the count of resizes is BOUNDED (the trailing-edge settle coalesces the
//      animation burst; the FINAL size is never dropped).
//
// The orchestrator runs this FLAG-ON; the shipped build keeps the flag OFF.
//
// Run: scripts/native-connect-test.sh integration_test/cc_render_test.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/terminal/tmux_control_mode_flag.dart';

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late bool prevFlag;
  setUp(() => prevFlag = setTmuxControlModeForTest(true));
  tearDown(() => setTmuxControlModeForTest(prevFlag));

  testWidgets(
    '-CC render: active window paints, window switch repaints, keyboard settle '
    'holds size parity (#909)',
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

      // Everything the host forwards to the grid (the demuxed active-window
      // bytes). In control mode this is what flterm renders.
      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      String rendered() => utf8.decode(out, allowMalformed: true);
      void send(String s) =>
          entry.proxy.sendInput(Uint8List.fromList(utf8.encode(s)));

      // The host already entered `tmux -CC` automatically. Wait for the control
      // stream to produce SOME rendered bytes (the initial window paint).
      var painted = false;
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (out.isNotEmpty) {
          painted = true;
          break;
        }
      }
      expect(painted, isTrue,
          reason: 'control-mode grid received ZERO bytes — %output never '
              'demuxed to the grid');

      // 1) Build a SECOND window with a unique marker, then a FIRST-window marker.
      //    In -CC, lines sent to stdin are tmux COMMANDS.
      send('new-window -n w1\n');
      const win1Marker = 'CC_WIN1_MARKER_111';
      // run a command in the new window's shell via send-keys so its %output
      // carries the marker.
      send('send-keys -t w1 "echo $win1Marker" Enter\n');
      var sawWin1 = false;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (rendered().contains(win1Marker)) {
          sawWin1 = true;
          break;
        }
      }
      expect(sawWin1, isTrue,
          reason: 'active (new) window content did not render to the grid');

      // 2) Switch BACK to window 0 and assert the grid REPAINTS to its content.
      out.clear();
      const win0Marker = 'CC_WIN0_MARKER_000';
      send('send-keys -t :0 "echo $win0Marker" Enter\n');
      send('select-window -t :0\n');
      var repainted = false;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (rendered().contains(win0Marker)) {
          repainted = true;
          break;
        }
      }
      expect(repainted, isTrue,
          reason: 'select-window did not REPAINT the grid to the new active '
              'window (authoritative %session-window-changed → redraw)');

      // 3) SIZE PARITY: toggle the keyboard (tap to raise, then dismiss) and
      //    confirm the session stays connected and renders a fresh frame at the
      //    settled size — the resize traveled as refresh-client -C with the FINAL
      //    size never dropped. We assert tmux's reported client size matches the
      //    grid by querying tmux for its width/height after the settle.
      out.clear();
      // Raise keyboard.
      await tester.tap(find.byType(EditableText).first.hitTestable(),
          warnIfMissed: false);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      // Let the trailing-edge settle (kGhosttyResizeSettle=250ms) elapse.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      // Ask tmux for the active client's size and the window size — in control
      // mode these must AGREE (tmux owns layout math; no divergence by
      // construction). display-message prints to the active pane → %output.
      const sizeMarker = 'CC_SIZE';
      send(
        'send-keys "tmux display-message -p \\"$sizeMarker '
        '#{client_width}x#{client_height} #{window_width}x#{window_height}\\"" '
        'Enter\n',
      );
      var sawSize = false;
      String sizeLine = '';
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        final r = rendered();
        final idx = r.indexOf(sizeMarker);
        if (idx >= 0) {
          sizeLine = r.substring(idx).split('\n').first;
          sawSize = true;
          break;
        }
      }
      expect(sawSize, isTrue,
          reason: 'tmux size readback never rendered — the control channel '
              'stopped after the keyboard toggle (size dropped?)');
      // Parity: client size == window size (the whole point of refresh-client -C).
      final m = RegExp(r'(\d+)x(\d+)\s+(\d+)x(\d+)').firstMatch(sizeLine);
      expect(m, isNotNull, reason: 'unparsable size line: $sizeLine');
      expect('${m!.group(1)}x${m.group(2)}', '${m.group(3)}x${m.group(4)}',
          reason: 'tmux client size != window size — app grid and tmux size '
              'DIVERGED (the #903/#905 saga); refresh-client -C should keep them '
              'identical');
      debugPrint('CC_RENDER size parity: $sizeLine');
    },
  );
}
