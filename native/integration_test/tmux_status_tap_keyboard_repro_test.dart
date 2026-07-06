// tmux_status_tap_keyboard_repro_test.dart — the +112 device repro, second
// attempt. The prior A/B (tmux_status_tap_detection_ab_test.dart) switched fine
// in BOTH detection states and could NOT reproduce. Its analysis:
//   (a) the gutter did NOT shift the tap column (sentSgrCol == intendedCol+1),
//   (b) detection never anchored the tmux STATUS row (anchors=0),
//   (c) telemetry is self-consistent ONLY IF the click COLUMN/ROW lands on the
//       wrong cell — a layout/sizing problem, not detection tap-routing.
// The harness LACKED the two device factors this test ADDS:
//   1. a RAISED soft keyboard (so the visible box shrinks and the grid row count
//      can diverge from what tmux was last told — the #903/#922 sizing state),
//   2. REAL URLs/paths in the terminal BODY (so detection actually anchors,
//      `controller.anchors` > 0 — matching why the device user runs detection ON).
//
// It taps window 1's status-bar label at the VISIBLE BOTTOM of the (possibly
// keyboard-shrunk) terminal box — exactly where the device user taps the status
// bar — in FOUR phases: {detection OFF, ON} × {keyboard DOWN, UP}. For each it
// logs the MECHANISM:
//   - intended window-1 label COLUMN vs the SENT SGR press COLUMN and ROW,
//   - tmux's REAL status row = `_gridRows` (the coalescer's lastEmittedRows, the
//     rows LAST SENT to the PTY) vs the LIVE rendered grid (scrollbar.visible),
//   - viewInsets.bottom (did the emulator actually raise the keyboard),
//   - `controller.anchors` count + whether an anchor overlaps the tapped cell,
//   - whether the window actually switched (visibleRowsText → window-1 marker).
//
// KEY QUESTION: with the keyboard raised, does the SENT SGR ROW miss tmux's real
// status row (sizing desync → tap lands in the body → no switch), and/or does
// detection swallow the tap (anchor under the tap → copy, sentSgrCount==0)? The
// numbers are shown for every phase so the mechanism is visible even if GREEN.
//
// RED (bug reproduced) = with keyboard UP + detection ON the tap does NOT switch
// while keyboard UP + detection OFF switches. GREEN = negative result; the logged
// numbers say which device factor is still missing.
//
// Run: scripts/native-connect-test.sh integration_test/tmux_status_tap_keyboard_repro_test.dart

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
import 'package:mobissh/state/detection_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import 'support/connect_helpers.dart';

const int _rowsFallback = 24;

/// Decode the (col,row) of the LAST press-type SGR mouse report (`ESC[<Btn;C;RM`,
/// final `M` = press) in a `{tMs,b64}` recorder snapshot. null if none.
(int?, int?) _lastSgrPress(List<Map<String, Object?>> snap) {
  final re = RegExp(r'\x1b\[<\d+;(\d+);(\d+)M');
  int? col;
  int? row;
  for (final ev in snap) {
    final b64 = ev['b64'] as String?;
    if (b64 == null) continue;
    final text = utf8.decode(base64Decode(b64), allowMalformed: true);
    for (final m in re.allMatches(text)) {
      col = int.tryParse(m.group(1)!);
      row = int.tryParse(m.group(2)!);
    }
  }
  return (col, row);
}

List<String> _sgrStrings(List<Map<String, Object?>> snap) => snap
    .map((ev) {
      final b64 = ev['b64'] as String?;
      if (b64 == null) return '';
      return utf8
          .decode(base64Decode(b64), allowMalformed: true)
          .replaceAll('\x1b', r'\e');
    })
    .where((s) => s.isNotEmpty)
    .toList(growable: false);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'tmux status-tap-to-switch: detection OFF/ON × keyboard DOWN/UP — with body '
    'anchors and a raised keyboard (the +112 device state)',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        const DetectionSettings().detectUrls ||
            const DetectionSettings().detectPaths,
        isTrue,
        reason: 'kDetectionDisabled971 is still true — detection is force-off, '
            'so this A/B would be meaningless. Set it to false.',
      );
      container.read(detectionSettingsProvider.notifier).setEnabled(false);

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

      // tmux mouse ON, status bar ON (the window list is what we tap).
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

      // Two windows with device-like names. Each window BODY carries a real URL
      // and a real absolute path so detection ANCHORS on the content rows (the
      // #971 reason to run detection ON) — the prior harness had NOTHING to
      // detect (anchors=0). automatic-rename off so the body content doesn't
      // rewrite the window label.
      const w0Name = 'w0';
      const w1Name = 'w1';
      const m0 = 'AB_WIN_ZERO_ZZZ';
      const m1 = 'AB_WIN_ONE_OOO';
      const bodyUrl = 'https://example.com/some/really/long/path/page.html';
      const bodyPath = '/etc/passwd';
      send('tmux set-window-option -g automatic-rename off\n');
      await settle(4);
      send('tmux rename-window $w0Name\n');
      await settle(4);
      send('clear; printf "$m0\\n$bodyUrl\\n$bodyPath\\n"\n');
      await settle();
      send('tmux new-window -n $w1Name\n');
      await settle();
      send('clear; printf "$m1\\n$bodyUrl\\n$bodyPath\\n"\n');
      await settle();

      Future<bool> landOnWindow0() async {
        send('tmux select-window -t 0\n');
        for (var i = 0; i < 24; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (rendered().contains(m0)) return true;
        }
        return false;
      }

      expect(await landOnWindow0(), isTrue,
          reason: 'setup: never landed back on window 0 ($m0)');

      final recorder = GhosttyTerminalView.debugByteRecorders[sessionId];
      expect(recorder, isNotNull, reason: 'no byte recorder for the session');
      final coalescer = GhosttyTerminalView.debugResizeCoalescers[sessionId];
      expect(coalescer, isNotNull, reason: 'no resize coalescer for the session');

      // Raise the soft keyboard: focus the gesture router (its onTap raises the
      // IME) AND force TextInput.show for a headless emulator that ignores the
      // focus-driven show. Pump past the coalescer settle window so the keyboard-
      // aware grid is the LAST EMITTED size.
      Future<void> raiseKeyboard() async {
        final router = find.byType(GhosttyPointerGestureRouter);
        if (router.evaluate().isNotEmpty) {
          await tester.tap(router.first, warnIfMissed: false);
        }
        await SystemChannels.textInput.invokeMethod('TextInput.show');
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 120));
        }
      }

      // One phase: land on window 0, tap window 1's status label at the VISIBLE
      // BOTTOM of the terminal box, and capture the mechanism.
      Future<_Phase> runPhase(String label, bool detectionOn) async {
        container.read(detectionSettingsProvider.notifier).setEnabled(detectionOn);
        await settle();
        final landed = await landOnWindow0();
        await settle();

        final termRect = tester.getRect(
          find.byKey(Key('ghostty-terminal-$sessionId')),
        );
        final cell = GhosttyTerminalView.debugCellSizes[sessionId]!;
        final rows = visibleRows();
        final last = rows > 0 ? rows - 1 : 0;
        final statusText = controller.visibleRowsText(last, last);
        // Window 1's clickable label column (prefer the "1:w1" token, fall back
        // to the bare name).
        final tokenCol = statusText.indexOf('1:$w1Name');
        final nameCol = statusText.indexOf(w1Name);
        final labelCol = tokenCol >= 0 ? tokenCol : nameCol;
        expect(labelCol, greaterThanOrEqualTo(0),
            reason: '[$label] window-1 label not in status row "$statusText"');

        // Tap X: window 1's label cell. Tap Y: the VISIBLE BOTTOM of the terminal
        // box (where the status bar renders on-device), NOT a computed grid row —
        // this is the device gesture. If the keyboard shrank the box but tmux's
        // grid did not shrink, this pixel maps to a BODY row (the #922 desync).
        final tapX =
            termRect.left + kGhosttyTerminalPadding + (labelCol + 0.5) * cell.width;
        final tapY = termRect.bottom - cell.height * 0.5;
        final tapAt = Offset(tapX, tapY);

        // Which grid row does this pixel map to (replicating the cell map's
        // clamp to _gridRows = lastEmittedRows), and what does tmux think its
        // status row is (= _gridRows, status at bottom).
        final gridRows = coalescer!.lastEmittedRows ?? 0;
        final rawRow =
            ((tapY - termRect.top - kGhosttyTerminalPadding) / cell.height)
                .floor();
        final mappedRow =
            gridRows > 0 ? (rawRow + 1).clamp(1, gridRows) : rawRow + 1;

        // Detection presence AT the tapped cell + globally.
        final matchAtTap = controller.matchAt(row: mappedRow - 1, col: labelCol);
        final anchorCount = controller.anchors.length;

        final mq = tester.platformDispatcher.views.first;
        final inset = mq.viewInsets.bottom;

        final sgrBefore = recorder!.snapshotSentSgrTrace();
        final gLogBefore = gestureLogSnapshot().length;

        // The gesture under test: a discrete tap (the _onTapUp path).
        await tester.tapAt(tapAt);
        await settle();

        final sgrAfter = recorder.snapshotSentSgrTrace();
        final newSgr = sgrAfter.length > sgrBefore.length
            ? sgrAfter.sublist(sgrBefore.length)
            : const <Map<String, Object?>>[];
        final (sentCol, sentRow) = _lastSgrPress(newSgr);
        final switched = rendered().contains(m1);

        final gLog = gestureLogSnapshot();
        final newG = gLog.length > gLogBefore
            ? gLog.sublist(gLogBefore)
            : const <String>[];

        final phase = _Phase(
          label: label,
          detectionOn: detectionOn,
          landedOnW0: landed,
          statusText: statusText,
          intendedCol: labelCol,
          sentSgrCol: sentCol,
          sentSgrRow: sentRow,
          sentSgrCount: newSgr.length,
          gridRows: gridRows,
          liveRows: controller.scrollbar.visible,
          mappedRow: mappedRow,
          viewInsetBottom: inset,
          switched: switched,
          matchAtTapPattern: matchAtTap?.patternId,
          anchorCount: anchorCount,
          cellW: cell.width,
          cellH: cell.height,
          boxW: termRect.width,
          boxH: termRect.height,
        );

        debugPrint('KBREPRO[$label] ${phase.summary()}');
        debugPrint('KBREPRO[$label] statusRow="$statusText" tapAt=$tapAt');
        for (final s in _sgrStrings(newSgr)) {
          debugPrint('KBREPRO[$label] sentSGR: $s');
        }
        for (final g in newG) {
          debugPrint('KBREPRO[$label] gesture: $g');
        }
        return phase;
      }

      // Phase 1+2: keyboard DOWN (baseline — the prior harness state).
      final offDown = await runPhase('OFF_KBDOWN', false);
      final onDown = await runPhase('ON_KBDOWN', true);

      // Raise the keyboard, then re-run OFF/ON with the shrunk viewport.
      await raiseKeyboard();
      final offUp = await runPhase('OFF_KBUP', false);
      final onUp = await runPhase('ON_KBUP', true);

      debugPrint('KBREPRO SUMMARY OFF_KBDOWN: ${offDown.summary()}');
      debugPrint('KBREPRO SUMMARY ON_KBDOWN:  ${onDown.summary()}');
      debugPrint('KBREPRO SUMMARY OFF_KBUP:   ${offUp.summary()}');
      debugPrint('KBREPRO SUMMARY ON_KBUP:    ${onUp.summary()}');
      debugPrint('KBREPRO DIFF sentSgrRow: offDown=${offDown.sentSgrRow} '
          'onDown=${onDown.sentSgrRow} offUp=${offUp.sentSgrRow} '
          'onUp=${onUp.sentSgrRow} | gridRows: offDown=${offDown.gridRows} '
          'onDown=${onDown.gridRows} offUp=${offUp.gridRows} onUp=${onUp.gridRows} '
          '| switched: offDown=${offDown.switched} onDown=${onDown.switched} '
          'offUp=${offUp.switched} onUp=${onUp.switched} '
          '| anchors: offDown=${offDown.anchorCount} onDown=${onDown.anchorCount} '
          'offUp=${offUp.anchorCount} onUp=${onUp.anchorCount} '
          '| inset onUp=${onUp.viewInsetBottom}');

      // CONTROL: keyboard-DOWN, detection OFF must switch (else setup/timing).
      expect(offDown.switched, isTrue,
          reason: 'CONTROL (kb down, detection OFF): the status tap did not '
              'switch to window 1 — setup/timing, not the bug. '
              'OFF_KBDOWN=${offDown.summary()}');

      // Whether the keyboard actually rose. If the emulator produced no inset,
      // the keyboard-UP phases did not exercise the sizing state — that is the
      // negative result to report, not a pass.
      final keyboardRose =
          onUp.viewInsetBottom > 0 || offUp.viewInsetBottom > 0;

      if (!keyboardRose) {
        debugPrint('KBREPRO NEGATIVE: emulator produced NO keyboard inset '
            '(viewInsets.bottom==0 in both KBUP phases) — the raised-keyboard '
            'sizing state was NOT exercised. Missing device factor: a real IME '
            'inset that shrinks the viewport. The keyboard-DOWN A/B matched the '
            'prior negative result (both switched).');
        // Do not assert the repro on a state we never reached.
        expect(offUp.switched || onDown.switched, isTrue,
            reason: 'sanity: at least one non-control phase should have behaved');
        return;
      }

      // CONTROL for the keyboard-UP state: OFF must still switch with the
      // keyboard raised (else the harness cannot tap the status bar at all in
      // this state and the ON comparison is meaningless).
      expect(offUp.switched, isTrue,
          reason: 'kb UP, detection OFF: the status tap did not switch even with '
              'detection OFF — the harness cannot hit the status bar in the '
              'keyboard-up state (sizing missed for BOTH states), so the ON/OFF '
              'comparison is inconclusive. OFF_KBUP=${offUp.summary()} '
              'ON_KBUP=${onUp.summary()}');

      // REPRO: keyboard UP + detection ON must ALSO switch. RED here = the +112
      // bug reproduced. The phase summaries show WHY: either sentSgrRow missed
      // gridRows (sizing desync under detection) or sentSgrCount==0 with a
      // non-null matchAtTap (detection swallowed the tap as a copy).
      expect(
        onUp.switched,
        isTrue,
        reason: '+112 REPRO (keyboard UP, detection ON): the status-bar tap did '
            'NOT switch to window 1 while keyboard-UP + detection-OFF switched '
            'fine. MECHANISM — OFF_KBUP=${offUp.summary()} '
            'ON_KBUP=${onUp.summary()}',
      );
    },
  );
}

class _Phase {
  _Phase({
    required this.label,
    required this.detectionOn,
    required this.landedOnW0,
    required this.statusText,
    required this.intendedCol,
    required this.sentSgrCol,
    required this.sentSgrRow,
    required this.sentSgrCount,
    required this.gridRows,
    required this.liveRows,
    required this.mappedRow,
    required this.viewInsetBottom,
    required this.switched,
    required this.matchAtTapPattern,
    required this.anchorCount,
    required this.cellW,
    required this.cellH,
    required this.boxW,
    required this.boxH,
  });

  final String label;
  final bool detectionOn;
  final bool landedOnW0;
  final String statusText;
  final int intendedCol;
  final int? sentSgrCol;
  final int? sentSgrRow;
  final int sentSgrCount;
  final int gridRows;
  final int liveRows;
  final int mappedRow;
  final double viewInsetBottom;
  final bool switched;
  final String? matchAtTapPattern;
  final int anchorCount;
  final double cellW;
  final double cellH;
  final double boxW;
  final double boxH;

  String summary() =>
      'det=$detectionOn switched=$switched | intendedCol=$intendedCol '
      'sentSgrCol=$sentSgrCol sentSgrRow=$sentSgrRow (count=$sentSgrCount) '
      '| gridRows=$gridRows liveRows=$liveRows mappedRow=$mappedRow '
      '| anchors=$anchorCount matchAtTap=$matchAtTapPattern '
      '| inset=${viewInsetBottom.toStringAsFixed(0)} '
      'cell=${cellW.toStringAsFixed(1)}x${cellH.toStringAsFixed(1)} '
      'box=${boxW.toStringAsFixed(0)}x${boxH.toStringAsFixed(0)}';
}
