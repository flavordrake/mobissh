// tmux_status_tap_kbrace_test.dart — #975 grid single-source-of-truth guard
// across a keyboard toggle (device-class regression for the tmux status tap).
//
// #975 root: flterm's `controller.onResize` fires from its OWN layout, which under
// the soft-keyboard show/hide RACES and can settle BACK to the pre-keyboard tall
// size, CLOBBERING the keyboard-aware `_rows` mirror; once
// `_submitKeyboardAwareGrid`'s guard latched the correct size it could not
// re-correct, leaving `_rows` (gutter-selection clamp + gesture geometry) and the
// status-tap target STALE vs the visible viewport (device "grid=58x34 sent=58x33"
// → the SGR row missed tmux's status row). The fix makes the keyboard-aware grid
// the SINGLE writer of `_cols/_rows` (onResize no longer mirrors them), so the
// live grid mirror stays == the grid SENT to tmux.
//
// This test connects, sets tmux mouse+status on with two short-named windows
// (AAA/BBB), then in BOTH keyboard states (DOWN settled tall, UP settled short):
//   - asserts the live mirror `_rows` == `lastSentRows` (the invariant the clobber
//     broke — read via the #975 `debugGrids` seam), and
//   - firm-taps window 1's status label at the visible bottom and asserts the
//     viewport switches to window 1.
//
// NOTE on the emulator: its IME inset SNAPS (no slide even at
// animator_duration_scale 5) and its flterm onResize tracks the box faithfully,
// so it does NOT exhibit the device's onResize "settle-back" clobber — the mirror
// stays consistent here, so this is a REGRESSION GUARD (green) that also documents
// the invariant. The MID-animation transient (tmux resize is deliberately
// deferred by the #903 coalescer, so the status bar is briefly off-screen) is
// EXPECTED and intentionally NOT asserted. On-device is the authoritative gate for
// the clobber itself.
//
// Run: scripts/native-connect-test.sh
//        integration_test/tmux_status_tap_kbrace_test.dart
//      (scripts/run-kbrace-repro.sh stretches the keyboard slide for manual
//      inspection of the transient; not required for this assertion.)

import 'dart:convert';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/diagnostics/gesture_trace.dart';
import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import 'support/connect_helpers.dart';

const int _rowsFallback = 24;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a firm tmux status-bar tap switches windows with the keyboard DOWN and UP '
    '(settled), and _rows stays == lastSentRows across the toggle (#975)',
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

      // tmux mouse ON, status ON, one session.
      send('tmux kill-server 2>/dev/null; tmux set -g mouse on \\; '
          'set -g status on \\; new -s ws\n');
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (controller.mouseTracking != MouseTracking.none) break;
        if (i % 5 == 4) {
          send('tmux kill-server 2>/dev/null; tmux set -g mouse on \\; '
              'set -g status on \\; new -s ws\n');
        }
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

      List<int> grids() =>
          GhosttyTerminalView.debugGrids[sessionId] ?? const <int>[0, 0, 0, 0];
      final coalescer = GhosttyTerminalView.debugResizeCoalescers[sessionId];

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
      send('tmux select-window -t 0\n');
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (rendered().contains(m0)) break;
      }
      expect(rendered().contains(m0), isTrue,
          reason: 'setup: never landed back on window 0 ($m0)');

      double insetNow() =>
          tester.platformDispatcher.views.first.viewInsets.bottom;

      // A settled-state status tap: land on window 0, then FIRM-tap window 1's
      // status label at the CURRENT visible bottom (a firm status-bar tap dwells
      // past the long-press deadline — the device gesture). Assert the live grid
      // mirror equals the grid SENT to tmux (the #975 single-source-of-truth
      // invariant the clobber violated: device "grid=58x34 sent=58x33"), then
      // report whether the viewport switched to window 1.
      Future<bool> firmTapStatusSwitchesToW1(String phase) async {
        send('tmux select-window -t 0\n');
        for (var i = 0; i < 24; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (rendered().contains(m0)) break;
        }
        // Wait for the resize to fully SETTLE and PROPAGATE: the grid SENT to
        // tmux (coalescer.lastEmittedRows) == the visible viewport AND a rebuild
        // has carried that grid into the widget snapshot (debugGrids g[3]) — so
        // the router the tap hits reads a FRESH lastSentRows, not a value the
        // coalescer's Timer emitted after the last build (debugGrids/router lag
        // _sendResize, which runs off a Timer). Without this the tap can target a
        // stale grid purely from build timing, not the #975 clobber.
        var g = grids();
        var le = coalescer?.lastEmittedRows ?? -1;
        for (var i = 0; i < 60; i++) {
          g = grids();
          le = coalescer?.lastEmittedRows ?? -1;
          if (le > 0 && le == visibleRows() && g.length > 3 && g[3] == le) break;
          await tester.pump(const Duration(milliseconds: 120));
        }
        final vis = visibleRows();
        final status = statusRowText();
        final labelCol = status.indexOf(w1Name);
        debugPrint('KBRACE $phase: visible=$vis grids=$g lastEmitted=$le '
            'inset=${insetNow()} status="$status" w1Col=$labelCol');
        expect(labelCol, greaterThanOrEqualTo(0),
            reason: '$phase: window-1 label "$w1Name" not in the status row '
                '"$status" — tmux status bar off-screen / at the wrong row');
        // #922/#975 sizing: the grid SENT to tmux must track the VISIBLE viewport
        // so tmux keeps its status bar at the visible bottom (where we tap).
        expect(le, vis,
            reason: '$phase: sent grid ($le) != visible viewport ($vis) — the '
                'keyboard-aware grid did not track the box (#922/#975).');
        // #975 single source of truth: the live mirror `_rows` (g[1], consumed by
        // the gutter-select clamp + gesture geometry) MUST equal the grid sent to
        // tmux (g[3] == lastSentRows). flterm's onResize used to clobber the
        // mirror back to a stale grid; the fix keeps them in lockstep.
        expect(g[1], g[3],
            reason: '$phase: _rows(${g[1]}) != lastSentRows(${g[3]}) — flterm '
                'onResize clobbered the keyboard-aware mirror (#975).');

        final rect = tester.getRect(
          find.byKey(Key('ghostty-terminal-$sessionId')),
        );
        final c = GhosttyTerminalView.debugCellSizes[sessionId]!;
        final bottomRow = visibleRows() - 1;
        final tapX =
            rect.left + kGhosttyTerminalPadding + (labelCol + 0.5) * c.width;
        final tapY =
            rect.top + kGhosttyTerminalPadding + (bottomRow + 0.5) * c.height;
        final gesture = await tester.startGesture(Offset(tapX, tapY));
        await tester.pump(const Duration(milliseconds: 700)); // firm dwell
        await gesture.up();
        await settle(10);
        final switched = rendered().contains(m1);
        final log = gestureLogSnapshot();
        final tail = log.length > 8 ? log.sublist(log.length - 8) : log;
        debugPrint('KBRACE $phase result: switched=$switched '
            'gridsNow=${grids()} tail=$tail');
        return switched;
      }

      // Phase 1 — keyboard DOWN (text entry during connect leaves the IME up, so
      // hide it and let the box grow + the sent grid settle tall).
      await SystemChannels.textInput.invokeMethod('TextInput.hide');
      controller.hideKeyboard();
      for (var i = 0; i < 45; i++) {
        await tester.pump(const Duration(milliseconds: 120));
        if (insetNow() == 0 && coalescer?.lastEmittedRows == visibleRows()) break;
      }
      final downSwitched = await firmTapStatusSwitchesToW1('down');

      // Phase 2 — keyboard UP (raise it and let the keyboard-reduced box settle
      // short). The keyboard-aware grid keeps tmux's status bar at the visible
      // bottom; the single-source-of-truth mirror keeps _rows == lastSentRows.
      controller.requestFocus();
      await SystemChannels.textInput.invokeMethod('TextInput.show');
      controller.showKeyboard();
      for (var i = 0; i < 45; i++) {
        await tester.pump(const Duration(milliseconds: 120));
        if (insetNow() > 0 && coalescer?.lastEmittedRows == visibleRows()) break;
      }
      final upSwitched = await firmTapStatusSwitchesToW1('up');

      expect(downSwitched, isTrue,
          reason: '#975/#971: a firm status-bar tap with the keyboard DOWN '
              '(settled) must switch to window 1 — the steady-state tap must land '
              'on tmux\'s real status row.');
      expect(upSwitched, isTrue,
          reason: '#975/#971: a firm status-bar tap with the keyboard UP '
              '(settled, keyboard-reduced viewport) must switch to window 1 — the '
              'keyboard-aware grid keeps tmux\'s status bar at the visible bottom '
              'and _rows==lastSentRows so the SGR lands on it.');
    },
  );
}
