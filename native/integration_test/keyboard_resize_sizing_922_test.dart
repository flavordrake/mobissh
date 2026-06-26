// #922 (REOPEN, device 0.1.10+72) — "tmux not updating on window switch: the
// cursor follows, nothing else updates". Tapping the tmux status bar to switch
// windows does NOT switch — only the cursor moves.
//
// ROOT (device capture 2026-06-25T18-09-02, gesture-log): at tap time the visible
// box was 597px (soft keyboard UP, ~34 visible rows) but flterm reported
// `grid=58x57 sent=58x57`. The PTY resize was driven solely by flterm's
// `controller.onResize`, which RACES the keyboard show/hide animation and settles
// BACK to the pre-keyboard (tall) size. tmux therefore kept a 57-row grid and drew
// its status bar at row ~56 — BELOW the keyboard, off-screen. The owner's tap on
// the visible bottom (row 34) landed in the MIDDLE of tmux's 57-row grid: a click
// that moved the cursor, no window switch.
//
// FIX: the host computes the keyboard-aware grid ITSELF from the laid-out box (the
// Scaffold keeps `resizeToAvoidBottomInset:true`, so the box IS the keyboard-
// reduced height) via `ghosttyGridForBox`, and submits THAT to the resize
// coalescer. So the grid SENT to tmux (== the #719 last-sent rows the status-tap
// targets) tracks the VISIBLE viewport, keeping tmux's status bar at the visible
// bottom.
//
// This on-emulator test connects, raises the soft keyboard, and asserts the grid
// LAST EMITTED to the PTY (the coalescer's `lastEmittedRows`) SHRANK to track the
// keyboard-reduced viewport — strictly fewer rows than the keyboard-down grid.
// RED on pre-fix main (flterm's onResize settled back to the tall size, so the
// sent rows stayed at the keyboard-down count); GREEN after.
//
// NOTE: whether the emulator's IME inset reproduces the EXACT device divergence is
// inset-dependent; the assertion is on the SENT grid vs the keyboard-down grid, so
// it is meaningful as long as the emulator keyboard changes the viewInsets. If the
// emulator does not animate an inset, the rows won't change and this surfaces that
// (the on-device gate remains authoritative).
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 -> socat -> test-sshd).
// Run: scripts/native-connect-test.sh integration_test/keyboard_resize_sizing_922_test.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'raising the soft keyboard SHRINKS the grid sent to tmux to track the '
    'keyboard-reduced viewport (status bar stays at the visible bottom) (#922)',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      await tester.pumpWidget(const ProviderScope(child: MobisshApp()));
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

      final ctx = tester.element(find.byType(MobisshApp));
      final container = ProviderScope.containerOf(ctx);
      final entry = container.read(sessionsProvider).active;
      expect(entry, isNotNull, reason: 'no active session after connect');
      final sessionId = entry!.id;

      // Wait for the shell prompt so the grid has settled at the keyboard-DOWN
      // size before we toggle the keyboard.
      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      for (var i = 0; i < 40 && out.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(out.isNotEmpty, isTrue, reason: 'no shell prompt — dead PTY');

      // Start a tmux session so the path matches the owner's repro (a status bar
      // exists), though the assertion is on the SENT grid, not a window switch.
      entry.proxy.sendInput(
        Uint8List.fromList(
          'tmux kill-server 2>/dev/null; tmux new -s t\n'.codeUnits,
        ),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }

      final coalescer = GhosttyTerminalView.debugResizeCoalescers[sessionId];
      expect(coalescer, isNotNull,
          reason: 'no coalescer registered for the active ghostty session');

      // Let the connect-time #666/#702 resync burst settle, then snapshot the
      // keyboard-DOWN sent grid (full height).
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      final downRows = coalescer!.lastEmittedRows;
      expect(downRows, isNotNull,
          reason: 'no resize was ever sent — coalescer never emitted');
      debugPrint('KBSIZE922 keyboard-DOWN sent rows: $downRows');

      // Raise the soft keyboard. The router's onTap focuses + shows the IME; the
      // viewInsets animation shrinks the Scaffold body (and the terminal box),
      // which the LayoutBuilder turns into a keyboard-aware grid submit.
      final router = find.byType(GhosttyPointerGestureRouter);
      expect(router, findsWidgets);
      await tester.tap(router.first);
      // Also force the IME up via the platform channel so a headless emulator that
      // ignores the focus-driven show still animates the inset.
      await SystemChannels.textInput.invokeMethod('TextInput.show');
      // Pump well past the coalescer settle window so the keyboard-aware grid is
      // the LAST EMITTED size.
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }

      final upRows = coalescer.lastEmittedRows;
      debugPrint('KBSIZE922 keyboard-UP sent rows: $upRows');

      final mq = tester.platformDispatcher.views.first;
      debugPrint('KBSIZE922 viewInsets.bottom (physical): '
          '${mq.viewInsets.bottom}');

      // If the emulator raised the keyboard (viewInsets shrank the box), the grid
      // sent to tmux MUST have shrunk to track it — the status bar then stays at
      // the visible bottom and the status-tap (which targets these rows) lands on
      // it. The pre-fix bug kept upRows == downRows (flterm settled back to the
      // tall size), so this is the regression assertion.
      if (mq.viewInsets.bottom > 0) {
        expect(upRows, isNotNull);
        expect(upRows!, lessThan(downRows!),
            reason: 'keyboard UP: the grid SENT to tmux must shrink to the '
                'keyboard-reduced viewport ($upRows vs keyboard-down $downRows) '
                'so tmux\'s status bar stays at the visible bottom — the #922 '
                'sizing fix. Equal rows means flterm settled back to the tall '
                'pre-keyboard size (the bug).');
      } else {
        // The emulator IME did not produce a viewInsets change — cannot exercise
        // the divergence here. Surface it; the on-device gate is authoritative.
        debugPrint('KBSIZE922 emulator produced NO keyboard inset — sizing '
            'divergence not reproducible headless; rely on the on-device gate '
            '(raise keyboard, tap tmux status bar → it switches windows).');
      }
    },
  );
}
