// On-emulator validation of #828 — Copy honors the active (visible) selection
// even after a tmux mouse-mode REDRAW cleared flterm's LIVE selection.
//
// The device bug (0.1.10+40): the owner long-press-dragged a selection in a tmux
// pane (mouse mode ON). The highlight was VISIBLE in the screenshot, but tapping
// Copy returned "No selection — long-press the terminal, then drag (or tap Select
// all)." Telemetry root cause:
//   - the gesture drove flterm's LOCAL selection (#705), NOT a tmux SGR drag;
//   - the connect-log showed the active tmux session redrawing its status bar
//     every ~1s (continuous `recv output`);
//   - #760's _invalidateSelectionOnRedraw clears the LIVE controller.selection on
//     the FIRST remote output after a selection exists — so ~1s after the
//     deliberate selection the live selection was already null, while the painted
//     highlight from the last frame LINGERED on screen;
//   - Copy read controller.selectedText() == '' → false "No selection".
//
// The fix snapshots the selected TEXT at finalise time and has Copy fall back to
// it (ghosttyEffectiveCopyText). This test reproduces the EXACT sequence over a
// real SSH→tmux→flterm chain: connect, tmux mouse on, print known content,
// long-press-drag to select a line locally, then drive a REMOTE redraw (a tmux
// status refresh — fresh PTY output) so #760 fires, then tap the Copy button and
// assert the clipboard holds the selected text (no "No selection" toast).
//
// Run: scripts/native-connect-test.sh integration_test/selection_copy_after_redraw_test.dart

import 'dart:convert';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/foundation.dart';
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
    'Copy returns the selected text even after a tmux redraw cleared the live '
    'selection (no false "No selection") (#828)',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      // Capture clipboard writes (the device clipboard is system state; on the
      // emulator integration harness the platform channel is mocked, so we
      // intercept Clipboard.setData to read exactly what Copy wrote).
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          if (call.method == 'Clipboard.getData') {
            return <String, dynamic>{'text': copied ?? ''};
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });

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
      expect(out.isNotEmpty, isTrue, reason: 'dead PTY — no shell prompt');

      // Start tmux WITH mouse on — the #828 environment. The long-press-drag
      // selection affordance (#705) is only wired when the overlay is ACTIVE,
      // i.e. under remote mouse tracking; tmux's status bar also redraws on a
      // ~1s timer, the continuous remote output that triggers the #760 clear.
      entry.proxy.sendInput(
        Uint8List.fromList(
          utf8.encode(
            'tmux kill-server 2>/dev/null; tmux set -g mouse on \\; new -s s\n',
          ),
        ),
      );
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (controller.mouseTracking != MouseTracking.none) break;
      }
      expect(
        controller.mouseTracking,
        isNot(MouseTracking.none),
        reason: 'tmux mouse mode never engaged — not the #828 environment',
      );

      // Let the grid/layout settle (the keyboard inset + #723 resize churn) so
      // the marker lands on a stable row before we compute the drag target.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      // Turn tmux's status bar OFF so its ~1s clock redraw does not clear the
      // in-progress selection MID-DRAG (which would null the anchor and leave an
      // empty snapshot — a separate drag-robustness concern). This isolates the
      // #828 race: a selection FINALISES cleanly, THEN a single explicit remote
      // write triggers the #760 clear, and Copy must still honor the snapshot.
      entry.proxy.sendInput(
        Uint8List.fromList(utf8.encode('tmux set -g status off\n')),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      // Print a TALL block of identical marker lines inside tmux so a long-press-
      // drag anywhere in the upper-middle of the pane is guaranteed to land on a
      // marker row (robust to the exact row count after layout settles).
      const marker = 'COPYME828_marker_line_xyz';
      entry.proxy.sendInput(
        Uint8List.fromList(
          utf8.encode("clear; for i in \$(seq 1 60); do echo $marker; done\n"),
        ),
      );
      var markerSeen = false;
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 300));
        if (utf8
            .decode(out, allowMalformed: true)
            .contains('marker_line_xyz')) {
          markerSeen = true;
          break;
        }
      }
      expect(markerSeen, isTrue, reason: 'marker lines never echoed back');
      // Let the marker block render + the grid settle before selecting.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      // Long-press-drag across the marker row (near the TOP after `clear`) to
      // drive flterm's LOCAL selection (#705) — the exact device gesture. The
      // overlay is ACTIVE under tmux mouse mode, so the long-press routes to
      // _onSelectionStart/_onSelectionExtend (which snapshot the text).
      final termFinder = find.byKey(Key('ghostty-terminal-$sessionId'));
      expect(termFinder, findsOneWidget, reason: 'no ghostty terminal view');
      final rect = tester.getRect(termFinder);
      // A DIAGONAL drag spanning MOST of the pane height (the 60-line marker
      // block fills the whole visible grid), from near-top-left to lower-right —
      // guaranteeing the span crosses many marker rows regardless of the exact
      // settled row count / scroll position.
      // Retry the long-press-drag at a few vertical bands until it finalises a
      // selection over a marker row. The 60-line block fills the grid, so any
      // content row works; retrying just absorbs the odd run where the anchor
      // lands on a transient blank/scrolled row. The status bar is OFF, so no
      // redraw races the drag — the only nondeterminism is which row the anchor
      // maps to, which the retry removes.
      var selectedBeforeRedraw = '';
      for (final frac in const [0.15, 0.3, 0.45, 0.6]) {
        final startPt = Offset(rect.left + 8, rect.top + rect.height * frac);
        final endPt = Offset(
          rect.left + 220,
          rect.top + rect.height * (frac + 0.15),
        );
        final gesture = await tester.startGesture(startPt);
        // Hold stationary past the long-press threshold so the gesture is a
        // SELECTION (not a swipe-scroll, #690).
        await tester.pump(const Duration(milliseconds: 700));
        const steps = 16;
        for (var i = 1; i <= steps; i++) {
          final p = Offset.lerp(startPt, endPt, i / steps)!;
          await gesture.moveTo(p);
          await tester.pump(const Duration(milliseconds: 16));
        }
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 300));
        selectedBeforeRedraw = controller.selectedText();
        debugPrint(
          'SEL828 selectedText post-drag(frac=$frac)="$selectedBeforeRedraw"',
        );
        if (selectedBeforeRedraw.contains('marker_line_xyz')) break;
        // Dismiss the (empty) selection before retrying so a fresh long-press
        // starts cleanly.
        controller.clearSelection();
        await tester.pump(const Duration(milliseconds: 100));
      }
      // The selection must have captured the marker BEFORE any redraw — this is
      // the precondition (a real, finalised, visible selection).
      expect(
        selectedBeforeRedraw.contains('marker_line_xyz'),
        isTrue,
        reason:
            'the long-press-drag did not finalise a selection over a marker '
            'row — selected="$selectedBeforeRedraw"',
      );

      // Drive an explicit REMOTE write so the #760 clear is deterministic: fresh
      // remote output while a selection exists fires _invalidateSelectionOnRedraw
      // → the LIVE controller.selection is cleared (the exact race that produced
      // the false "No selection" on device). The finalised-text SNAPSHOT must
      // survive so Copy still returns it (#828).
      entry.proxy.sendInput(
        Uint8List.fromList(utf8.encode("printf 'REDRAW_TICK\\n'\n")),
      );
      var liveCleared = false;
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        if (controller.selection == null) {
          liveCleared = true;
          break;
        }
      }
      debugPrint('SEL828 live selection cleared by remote output=$liveCleared');
      expect(
        liveCleared,
        isTrue,
        reason:
            'the remote write did not clear the live selection — the #828 race '
            'precondition (the #760 invalidation) did not occur',
      );
      // Pump a frame so _syncHasSelection's setState (snapshot keeps it true)
      // has rebuilt the affordance before we look for the Copy button.
      await tester.pump(const Duration(milliseconds: 300));

      // Tap the Copy affordance. With the #828 fix the snapshot is honored even
      // though the live selection may now be null — so Copy writes the selected
      // text to the clipboard instead of toasting "No selection".
      final copyBtn = find.byKey(const Key('ghostty-copy-selection'));
      expect(
        copyBtn,
        findsOneWidget,
        reason:
            'Copy button vanished after the redraw — the affordance must stay '
            'while the snapshot survives (#828)',
      );
      await tester.tap(copyBtn);
      await tester.pump(const Duration(milliseconds: 300));

      debugPrint('SEL828 copied="$copied"');
      // No false "No selection" toast.
      expect(
        find.textContaining('No selection'),
        findsNothing,
        reason:
            'Copy reported "No selection" despite a visible/finalised selection '
            '(the #828 bug)',
      );
      // The clipboard holds the text the user selected (the snapshot), even
      // though the LIVE selection was cleared by the redraw.
      expect(
        copied,
        isNotNull,
        reason: 'Copy wrote nothing to the clipboard',
      );
      expect(
        copied!.trim().isNotEmpty,
        isTrue,
        reason:
            'Copy produced EMPTY clipboard text despite a finalised, visible '
            'selection that a redraw cleared from the live model — the #828 '
            'false "No selection". copied="$copied"',
      );
      // The clipboard holds the text the user actually selected (the snapshot),
      // proving Copy honored the visible selection rather than the cleared live
      // model.
      expect(
        copied,
        contains('marker_line_xyz'),
        reason:
            'Copied text does not contain the selected marker — Copy did not '
            'honor the snapshot of the visible selection (#828). copied="$copied"',
      );
    },
  );
}
