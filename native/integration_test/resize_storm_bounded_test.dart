// On-emulator RESIZE-STORM bound (#903) — the ROOT of the repaint-fail saga.
//
// Device bug (0.1.10+62, tmux-state-trace, SINGLE client): the app emitted a
// RESIZE STORM. A keyboard show/hide animated the viewport inset over many
// frames; flterm fired `onResize` for each, and the ghostty path sent EVERY
// distinct height straight to the PTY (`58x44→43→42→38→37→35→34` in one second).
// A window switch showed the same shape as a transient `34→36→34` reflow blip.
// Each resize regridded the terminal mid-interaction and raced the redraw → the
// stale/blank repaint the #887/#898/#900 paint patches were chasing at the wrong
// layer. The proxy's #848 IDENTICAL-dims no-op guard didn't help — every
// animation frame is a DISTINCT height.
//
// The fix (#903) coalesces flterm's `onResize` burst into a SINGLE settled PTY
// resize ([GhosttyResizeCoalescer]): intermediate frames only reset the settle
// timer; only the FINAL stable size is sent, and a transient that returns to the
// base emits nothing. The #666/#702 forced resync still flushes immediately.
//
// This test connects to tmux with ≥2 windows, then toggles the keyboard and
// switches windows several times, asserting the number of PTY resizes ACTUALLY
// sent (the coalescer's `sendCount`) is BOUNDED — a handful (one per settled
// size), NOT one-per-animation-frame — AND that the rendered grid updates to each
// new window (content tracks the switch). RED on pre-#903 main (the storm: the
// resize count balloons), GREEN after.
//
// The owner re-validates on device with `scripts/tmux-state-trace.sh watch`
// armed: a keyboard toggle + window switches log only a FEW `client-resized`
// events (final sizes), not a cascade.
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).

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
    'keyboard toggle + window switches send a BOUNDED number of PTY resizes',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      // #727 made ghostty the DEFAULT backend; do NOT override it — this is a
      // ghostty-path bug (flterm's per-frame onResize), so run on flterm.
      await tester.pumpWidget(const MobisshApp());
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
        if (find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty) {
          connected = true;
          break;
        }
      }
      expect(connected, isTrue, reason: 'never reached the terminal screen');

      final entry = activeSession(tester);
      final sessionId = entry.id;

      // Wait for the shell prompt.
      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      for (var i = 0; i < 40 && out.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(out.isNotEmpty, isTrue, reason: 'no shell prompt — dead PTY');

      // Start tmux with TWO windows so a window switch has somewhere to go.
      // Window 0 prints AAAA, window 1 prints BBBB so a grid read can tell them
      // apart after a switch.
      entry.proxy.sendInput(
        Uint8List.fromList(
          'tmux kill-server 2>/dev/null; '
                  'tmux new -s t -n w0 \\; '
                  'send-keys "clear; echo AAAA_WINDOW_ZERO" Enter \\; '
                  'new-window -n w1 \\; '
                  'send-keys "clear; echo BBBB_WINDOW_ONE" Enter \\; '
                  'select-window -t t:0\n'
              .codeUnits,
        ),
      );
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (entry.terminal.isUsingAltBuffer) break;
      }

      // The coalescer is the seam that proves the storm is tamed: `sendCount` is
      // every PTY resize ACTUALLY sent. Snapshot it AFTER connect/tmux settle so
      // the connect-time #666/#702 resync burst isn't counted against the
      // interaction we're measuring.
      final coalescer =
          GhosttyTerminalView.debugResizeCoalescers[sessionId];
      expect(
        coalescer,
        isNotNull,
        reason: 'no coalescer registered for the active ghostty session',
      );
      // Let any connect-time resync burst finish settling.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      final baselineSends = coalescer!.sendCount;

      // ── Interaction: toggle the keyboard and switch windows several times. ──
      // Each keyboard show/hide animates the inset over MANY frames; each window
      // switch is a horizontal swipe (→ tmux next/previous-window) that also
      // reflows the layout transiently. Pre-#903 this drove dozens of resizes;
      // post-#903 each settled size is ONE resize (most are net-zero blips → 0).
      final router = find.byType(GhosttyPointerGestureRouter);
      expect(router, findsWidgets);
      final center = tester.getCenter(router.first);

      for (var round = 0; round < 4; round++) {
        // Raise the keyboard (tap focuses + shows the IME → inset animation).
        await tester.tap(router.first);
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 120));
        }
        // Swipe RIGHT → next-window, then LEFT → previous-window.
        await tester.dragFrom(center, const Offset(140, 0));
        await tester.pump(const Duration(milliseconds: 120));
        await tester.dragFrom(center, const Offset(-140, 0));
        await tester.pump(const Duration(milliseconds: 120));
        // Dismiss the keyboard (another inset animation the other way).
        await SystemChannels.textInput.invokeMethod('TextInput.hide');
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 120));
        }
      }
      // Let the final size settle past the coalescer window.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }

      final delta = coalescer.sendCount - baselineSends;
      debugPrint('CTRACE903 resize sends during interaction: $delta');

      // BOUNDED: 4 rounds × (keyboard up + down) = 8 genuine settled sizes at
      // most; the window-switch blips coalesce to net-zero. A storm (pre-#903)
      // would be DOZENS (per-animation-frame). Allow generous headroom for
      // real settled transitions while still failing the storm by a wide margin.
      expect(
        delta,
        lessThanOrEqualTo(12),
        reason:
            'resize storm NOT tamed — $delta PTY resizes for 4 keyboard '
            'toggles + window switches (expected a handful of settled sizes, '
            'not one-per-animation-frame)',
      );

      // The grid must still track the active window: switch to window 1 and
      // confirm its marker renders (the coalescer must not have starved the
      // terminal of the resizes it legitimately needs).
      entry.proxy.sendInput(
        Uint8List.fromList('tmux select-window -t t:1\n'.codeUnits),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      final controller =
          GhosttyTerminalView.debugControllers[sessionId];
      expect(controller, isNotNull, reason: 'no flterm controller for session');
      final visible = _visibleGridText(controller!);
      debugPrint('CTRACE903 grid after switch to w1:\n$visible');
      expect(
        visible.contains('BBBB_WINDOW_ONE'),
        isTrue,
        reason: 'grid did not update to window 1 — content stale after switch',
      );
    },
  );
}

/// The active session entry (typed accessor so the test reads cleanly).
SessionEntry activeSession(WidgetTester tester) {
  final ctx = tester.element(find.byType(MobisshApp));
  final container = ProviderScope.containerOf(ctx);
  final entry = container.read(sessionsProvider).active;
  expect(entry, isNotNull, reason: 'no active session after connect');
  return entry!;
}

/// Read the flterm controller's visible viewport as plain text so the test can
/// assert which tmux window is rendered. The controller's grid-read surface
/// differs from xterm's, so this is defensive: on any shape mismatch it falls
/// back to `toString` and still yields a diagnostic.
String _visibleGridText(Object controller) {
  try {
    final dynamic c = controller;
    final term = c.terminal;
    final buffer = term.buffer;
    final sb = StringBuffer();
    final int height = term.viewHeight as int;
    for (var y = 0; y < height; y++) {
      sb.writeln(buffer.lines[buffer.height - height + y].toString());
    }
    return sb.toString();
  } catch (_) {
    return controller.toString();
  }
}
