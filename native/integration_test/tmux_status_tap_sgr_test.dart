// tmux_status_tap_sgr_test.dart — the #971 REFRAME repro (gesture-tap-sgr).
//
// The bug filed as "tmux window switch does nothing / no repaint" is NOT a paint
// bug. Owner device telemetry (high confidence):
//   - rebuilt=32 on every repaint sync — paint WAS rebuilding rows fine;
//   - sentSgrTraceEventCount: 0 — ZERO mouse SGR reports reached the remote;
//   - all 120 gesture-log events were `longpress-select … by=overlay`.
// A tmux window switch under mouse mode REQUIRES an SGR mouse click on the status
// bar. None was sent, so tmux never switched → the screen correctly shows the
// un-switched window. The TAP meant to switch windows resolved as a long-press-
// selection (the detection/selection overlay ate it) so `onMouseReport` never ran.
//
// Unlike `tmux_window_switch_detection_test.dart` (which switches via
// `tmux select-window` COMMANDS — bypassing the gesture that is the actual bug),
// this test injects a REAL tap on the status-bar window-1 label and asserts BOTH:
//   (1) a sent SGR mouse report was recorded (the tap CLICKED THROUGH to tmux);
//   (2) the rendered viewport switches to window 1's marker.
// Detection is ON (the trigger). It keeps the tmux status bar ON and names the
// two windows so the window list sits at findable cells.
//
// Run: scripts/native-connect-test.sh integration_test/tmux_status_tap_sgr_test.dart

import 'dart:convert';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/diagnostics/gesture_trace.dart';
import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/detection_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'DETECTION ON: a tap on the tmux status bar CLICKS THROUGH (sends SGR) and '
    'switches windows',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      final container = ProviderContainer();
      addTearDown(container.dispose);
      // Detection ON — the trigger. #971 kill switch must be OFF for this to
      // mean anything (the getters no-op when kDetectionDisabled971 is true).
      container.read(detectionSettingsProvider.notifier).setEnabled(true);
      expect(
        const DetectionSettings().detectUrls || const DetectionSettings().detectPaths,
        isTrue,
        reason: 'kDetectionDisabled971 is still true — detection is force-off, '
            'so this repro would be meaningless. Set it to false.',
      );

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
      final sessionId = entry.id;
      TerminalController? ctrlOf() =>
          GhosttyTerminalView.debugControllers[sessionId];
      for (var i = 0; i < 40 && ctrlOf() == null; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      final controller = ctrlOf()!;

      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      for (var i = 0; i < 40 && out.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(out.isNotEmpty, isTrue, reason: 'dead PTY — no shell output');

      void send(String cmd) =>
          entry.proxy.sendInput(Uint8List.fromList(utf8.encode(cmd)));

      // tmux mouse ON (the owner env: detection runs on the alt screen with
      // mouse tracking). KEEP the status bar ON (the window list is what we tap).
      send('tmux kill-server 2>/dev/null; tmux set -g mouse on \\; '
          'set -g status on \\; new -s ws\n');
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (controller.mouseTracking != MouseTracking.none) break;
        if (i % 8 == 7) send('tmux set -g mouse on\n');
      }
      expect(controller.mouseTracking, isNot(MouseTracking.none),
          reason: 'tmux mouse mode never engaged');

      Future<void> settle([int ticks = 14]) async {
        for (var i = 0; i < ticks; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
      }

      int visibleRows() {
        final v = controller.scrollbar.visible;
        return v > 0 ? v : _rowsFallback;
      }

      String rendered() {
        final rows = visibleRows();
        return controller.visibleRowsText(0, rows > 0 ? rows - 1 : 0);
      }

      String statusRowText() {
        final rows = visibleRows();
        final last = rows > 0 ? rows - 1 : 0;
        return controller.visibleRowsText(last, last);
      }

      // Two windows, SHORT distinct names so the status list is findable. Window
      // 0 renders m0; window 1 renders m1. End ON window 0 (the active one).
      const w0Name = 'AAA';
      const w1Name = 'BBB';
      const m0 = 'STAP_WINDOW_ZERO_ZZZ';
      const m1 = 'STAP_WINDOW_ONE_OOO';
      send('tmux rename-window $w0Name\n');
      await settle();
      send('clear; printf "$m0\\n"\n');
      await settle();
      send('tmux new-window -n $w1Name\n');
      await settle();
      send('clear; printf "$m1\\n"\n');
      await settle();
      // Setup switch back to window 0 via a COMMAND (not the gesture under test).
      send('tmux select-window -t 0\n');
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (rendered().contains(m0)) break;
      }
      expect(rendered().contains(m0), isTrue,
          reason: 'setup: never landed back on window 0 ($m0)');

      // Geometry: the terminal Stack render box + the REAL measured cell size.
      final termRect = tester.getRect(
        find.byKey(Key('ghostty-terminal-$sessionId')),
      );
      final cell = GhosttyTerminalView.debugCellSizes[sessionId];
      expect(cell, isNotNull, reason: 'no measured cell size for the session');
      expect(cell!.width > 0 && cell.height > 0, isTrue,
          reason: 'degenerate cell size $cell');

      // Find window 1's label column in the status (last) row: the column index
      // of the "BBB" window name. tmux's clickable window region covers the
      // "#I:#W" segment, so a tap on the name lands in window 1's status range.
      final statusText = statusRowText();
      final labelCol = statusText.indexOf(w1Name);
      debugPrint('STAP status row="$statusText" w1LabelCol=$labelCol '
          'rows=${visibleRows()} cell=$cell termRect=$termRect');
      expect(labelCol, greaterThanOrEqualTo(0),
          reason: 'window-1 label "$w1Name" not found in the status row '
              '"$statusText" — status bar off / wrong row');

      final bottomRow = visibleRows() - 1;
      final tapX = termRect.left +
          kGhosttyTerminalPadding +
          (labelCol + 0.5) * cell.width;
      final tapY = termRect.top +
          kGhosttyTerminalPadding +
          (bottomRow + 0.5) * cell.height;
      final tapAt = Offset(tapX, tapY);

      // Baseline SGR count from the SAME recorder the app writes sent reports to.
      final recorder = GhosttyTerminalView.debugByteRecorders[sessionId];
      expect(recorder, isNotNull, reason: 'no byte recorder for the session');
      final sgrBefore = recorder!.snapshotSentSgrTrace().length;

      // THE GESTURE UNDER TEST: a FIRM tap on window 1's status-bar label. On the
      // device a tap aimed at a small bottom-of-screen target dwells past the
      // long-press deadline, so the router's LongPressGestureRecognizer wins the
      // arena and the press resolves as a `longpress-select` (the device
      // telemetry: 120 longpress-select events, sentSgrTraceEventCount=0). We
      // reproduce that by holding the press past kLongPressTimeout (500ms) before
      // release — a quick tapAt already clicks through (see the sibling test),
      // but the device's real, slightly-dwelling status-bar tap does NOT. A press
      // on the tmux STATUS ROW must still switch windows (there is nothing to
      // text-select on a one-line status bar), so this must CLICK THROUGH.
      final gesture = await tester.startGesture(tapAt);
      await tester.pump(const Duration(milliseconds: 700)); // > long-press dwell
      await gesture.up();
      await settle();

      final sgrAfter = recorder.snapshotSentSgrTrace().length;
      final switched = rendered().contains(m1);

      // Diagnostics — the gesture log tells us WHICH recognizer/flag handled the
      // tap (tap vs longpress-select vs tap-url-copy) and whether an SGR fired.
      final log = gestureLogSnapshot();
      debugPrint('STAP tapAt=$tapAt sgrBefore=$sgrBefore sgrAfter=$sgrAfter '
          'switched=$switched');
      final tail = log.length > 12 ? log.sublist(log.length - 12) : log;
      for (final line in tail) {
        debugPrint('STAP gesture: $line');
      }

      expect(
        sgrAfter,
        greaterThan(sgrBefore),
        reason: '#971: the status-bar TAP forwarded NO SGR mouse report '
            '(before=$sgrBefore after=$sgrAfter) — the tap resolved as a '
            'selection/detection gesture instead of a terminal mouse click, so '
            'tmux never got the click and the window never switches. Gesture '
            'log tail: $tail',
      );
      expect(
        switched,
        isTrue,
        reason: '#971: the status-bar tap sent an SGR but the viewport did not '
            'switch to window 1 ($m1) — tap landed off window 1\'s label or the '
            'switch did not repaint. status="$statusText" labelCol=$labelCol',
      );
    },
  );
}

/// Fallback viewport row count if the controller has not reported a visible
/// scrollback extent yet (defensive; the status-bar row math needs a row count).
const int _rowsFallback = 24;
