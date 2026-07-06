// tmux_status_tap_detection_ab_test.dart — the +112 device repro: "tmux tap-to-
// switch works with URL detection OFF but NOT with detection ON."
//
// Device telemetry (build +112, high confidence): the status-bar tap sends a
// byte-perfect SGR click (complete press `ESC[<0;C;RM` + release `…m`) at the
// status row, grid==sent (no size mismatch), the click reaches tmux, and the
// client repaints (rebuilt=32) — YET with detection ON the window does not
// switch. The sent bytes look identical on and off, so the cause is not visible
// in that telemetry.
//
// This harness does a clean A/B on the SAME computed pixel (window 1's status-
// bar label): tap it with detection OFF, then tap it with detection ON, and logs
// for EACH state:
//   - the sent SGR press COLUMN (decoded from the byte recorder) vs the intended
//     label column — does detection shift the tap->cell column? (the gutter
//     hypothesis)
//   - whether the tap forwarded ANY SGR at all (did detection's urlAtCell swallow
//     the tap as a copy?)
//   - controller.matchAt at the tapped cell + live anchor count (detection
//     presence at the tap point)
//   - the controller cols/box/cell in each state
//   - whether the rendered viewport switched to window 1's marker
//
// GOAL: a red repro of "detection ON -> no switch, detection OFF -> switch", plus
// the MECHANISM. If BOTH states behave the same, that is an important negative
// result (the harness lacks the device trigger — say so).
//
// Run: scripts/native-connect-test.sh integration_test/tmux_status_tap_detection_ab_test.dart

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

/// Fallback viewport row count if the controller has not reported a visible
/// scrollback extent yet.
const int _rowsFallback = 24;

/// Decode the SGR-press COLUMN of the LAST press-type SGR mouse report in a
/// recorder snapshot (`{tMs, b64}` list). A press is `ESC[<Btn;Col;RowM` (final
/// `M` = press, `m` = release). Returns null if none found.
int? _lastSgrPressCol(List<Map<String, Object?>> snap) {
  final re = RegExp(r'\x1b\[<\d+;(\d+);(\d+)M');
  int? col;
  for (final ev in snap) {
    final b64 = ev['b64'] as String?;
    if (b64 == null) continue;
    final text = utf8.decode(base64Decode(b64), allowMalformed: true);
    for (final m in re.allMatches(text)) {
      col = int.tryParse(m.group(1)!);
    }
  }
  return col;
}

/// All SGR reports (press+release) in a snapshot, as printable strings, for the
/// log. `ESC` shown as `\e` so the byte stream is legible.
List<String> _sgrStrings(List<Map<String, Object?>> snap) {
  return snap.map((ev) {
    final b64 = ev['b64'] as String?;
    if (b64 == null) return '';
    final text = utf8.decode(base64Decode(b64), allowMalformed: true);
    return text.replaceAll('\x1b', r'\e');
  }).where((s) => s.isNotEmpty).toList(growable: false);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'A/B: tmux status-bar tap-to-switch with detection OFF vs ON',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      final container = ProviderContainer();
      addTearDown(container.dispose);
      // Sanity: the #971 kill switch must be OFF or detection is force-off and
      // the A/B is meaningless.
      expect(
        const DetectionSettings().detectUrls ||
            const DetectionSettings().detectPaths,
        isTrue,
        reason: 'kDetectionDisabled971 is still true — detection is force-off, '
            'so this A/B would be meaningless. Set it to false.',
      );
      // Start with detection OFF; we flip it per phase below.
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

      String statusRowText() {
        final rows = visibleRows();
        final last = rows > 0 ? rows - 1 : 0;
        return controller.visibleRowsText(last, last);
      }

      // Two windows, SHORT distinct names so the window list sits at predictable
      // columns. Window 0 renders m0; window 1 renders m1.
      const w0Name = 'w0';
      const w1Name = 'w1';
      const m0 = 'AB_WIN_ZERO_ZZZ';
      const m1 = 'AB_WIN_ONE_OOO';
      send('tmux rename-window $w0Name\n');
      await settle();
      send('clear; printf "$m0\\n"\n');
      await settle();
      send('tmux new-window -n $w1Name\n');
      await settle();
      send('clear; printf "$m1\\n"\n');
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

      // One A/B phase: land on window 0, compute window-1's label pixel, tap it,
      // and report everything. Returns the phase result for the final compare.
      // [tapToken] is the status-row substring whose FIRST char we tap (window 1's
      // label). [onTokenCharOffset] shifts the tap N cells into the token (so we
      // can land ON a detectable path, not the leading "1:").
      Future<_Phase> runPhase(
        String label,
        bool detectionOn, {
        String tapToken = '1:w1',
        int onTokenCharOffset = 0,
      }) async {
        container.read(detectionSettingsProvider.notifier).setEnabled(detectionOn);
        await settle();
        // Always start the phase on window 0 (the previous phase may have moved).
        final landed = await landOnWindow0();
        await settle();

        final termRect = tester.getRect(
          find.byKey(Key('ghostty-terminal-$sessionId')),
        );
        final cell = GhosttyTerminalView.debugCellSizes[sessionId]!;
        final statusText = statusRowText();
        // Window 1's clickable region. Prefer the exact token; fall back to the
        // bare name so the tap still lands in window 1's status range.
        final tokenCol = statusText.indexOf(tapToken);
        final nameCol = statusText.indexOf(w1Name);
        final baseCol = tokenCol >= 0 ? tokenCol : nameCol;
        final labelCol = baseCol >= 0 ? baseCol + onTokenCharOffset : baseCol;
        final bottomRow = visibleRows() - 1;

        expect(labelCol, greaterThanOrEqualTo(0),
            reason: '[$label] window-1 label ("$tapToken"/"$w1Name") not in '
                'status row "$statusText"');

        final tapX =
            termRect.left + kGhosttyTerminalPadding + (labelCol + 0.5) * cell.width;
        final tapY = termRect.top +
            kGhosttyTerminalPadding +
            (bottomRow + 0.5) * cell.height;
        final tapAt = Offset(tapX, tapY);

        // Detection presence AT the tapped cell (0-based viewport col/row) and
        // globally (anchor count) — the "does detection sit under the tap?" probe.
        final matchAtTap =
            controller.matchAt(row: bottomRow, col: labelCol);
        final anchorCount = controller.anchors.length;

        final sgrBefore = recorder!.snapshotSentSgrTrace();
        final gestureLogBefore = gestureLogSnapshot().length;

        // The gesture under test: a discrete tap (tester.tapAt = quick press+up,
        // the _onTapUp path — the same path the device's status tap takes).
        await tester.tapAt(tapAt);
        await settle();

        final sgrAfter = recorder.snapshotSentSgrTrace();
        // The NEW SGR reports this tap produced (suffix after the baseline).
        final newSgr = sgrAfter.length > sgrBefore.length
            ? sgrAfter.sublist(sgrBefore.length)
            : const <Map<String, Object?>>[];
        final sentSgrCol = _lastSgrPressCol(newSgr);
        final switched = rendered().contains(m1);

        final gestureLog = gestureLogSnapshot();
        final newGesture = gestureLog.length > gestureLogBefore
            ? gestureLog.sublist(gestureLogBefore)
            : const <String>[];

        final phase = _Phase(
          label: label,
          detectionOn: detectionOn,
          landedOnW0: landed,
          statusText: statusText,
          intendedCol: labelCol,
          sentSgrCol: sentSgrCol,
          sentSgrCount: newSgr.length,
          switched: switched,
          matchAtTapPattern:
              matchAtTap == null ? null : matchAtTap.patternId,
          anchorCount: anchorCount,
          cols: controller.scrollbar.visible,
          cellW: cell.width,
          cellH: cell.height,
          boxW: termRect.width,
          boxH: termRect.height,
        );

        debugPrint('AB[$label] detectionOn=$detectionOn '
            'status="$statusText" intendedCol=$labelCol '
            'sentSgrCol=$sentSgrCol sentSgrCount=${newSgr.length} '
            'switched=$switched matchAtTap=${phase.matchAtTapPattern} '
            'anchors=$anchorCount cols=${controller.scrollbar.visible} '
            'cell=${cell.width.toStringAsFixed(2)}x${cell.height.toStringAsFixed(2)} '
            'box=${termRect.width.toStringAsFixed(0)}x${termRect.height.toStringAsFixed(0)} '
            'tapAt=$tapAt');
        for (final s in _sgrStrings(newSgr)) {
          debugPrint('AB[$label] sentSGR: $s');
        }
        for (final g in newGesture) {
          debugPrint('AB[$label] gesture: $g');
        }
        return phase;
      }

      final off = await runPhase('OFF', false);
      final on = await runPhase('ON', true);

      // PHASE C — the sharper repro: make window 1's STATUS LABEL a DETECTABLE
      // absolute path so a tap on the label cell coincides with a detection
      // match. This is the ONE detection-specific branch in the tap path
      // (`_onTapUp`: `urlAtCell` non-null -> `onUrlTap` copy + SWALLOW, no SGR).
      // `automatic-rename off` so the shell's own title doesn't clobber it.
      const w1Path = '/etc/hostname';
      // Free the full status width for the window list so the path label renders
      // in FULL (the default status-right clock truncated it to "1:/etc>").
      send("tmux set -g status-right ''\n");
      await settle(4);
      send("tmux set -g status-left ''\n");
      await settle(4);
      send('tmux set-window-option -t 1 automatic-rename off\n');
      await settle(4);
      send('tmux rename-window -t 1 $w1Path\n');
      await settle();
      // Tap a few cells INTO the path (past the "1:") so the tapped cell is
      // squarely inside the detectable token, not the index prefix.
      final onPath = await runPhase(
        'ON_PATHLABEL',
        true,
        tapToken: '1:$w1Path',
        onTokenCharOffset: 4, // skip "1:/e" -> land inside /etc/hostname
      );

      debugPrint('AB SUMMARY OFF:         ${off.summary()}');
      debugPrint('AB SUMMARY ON:          ${on.summary()}');
      debugPrint('AB SUMMARY ON_PATHLABEL:${onPath.summary()}');
      debugPrint('AB DIFF: intendedCol off=${off.intendedCol} on=${on.intendedCol} '
          'onPath=${onPath.intendedCol} '
          '| sentSgrCol off=${off.sentSgrCol} on=${on.sentSgrCol} '
          'onPath=${onPath.sentSgrCol} '
          '| sentSgrCount off=${off.sentSgrCount} on=${on.sentSgrCount} '
          'onPath=${onPath.sentSgrCount} '
          '| switched off=${off.switched} on=${on.switched} '
          'onPath=${onPath.switched} '
          '| matchAtTap off=${off.matchAtTapPattern} on=${on.matchAtTapPattern} '
          'onPath=${onPath.matchAtTapPattern} '
          '| anchors off=${off.anchorCount} on=${on.anchorCount} '
          'onPath=${onPath.anchorCount}');

      // CONTROL: detection OFF must switch (else it's a setup/timing issue).
      expect(off.switched, isTrue,
          reason: 'CONTROL (detection OFF): the status-bar tap did not switch to '
              'window 1 ($m1) — setup/timing issue, not the bug. OFF=${off.summary()}');

      // REPRO: with a DETECTABLE label under the tap, detection ON must still
      // switch. Red here = the +112 bug reproduced (the tap was swallowed as a
      // detection copy instead of forwarding the SGR window-switch click).
      // matchAtTap non-null + sentSgrCount==0 + switched==false is the mechanism.
      expect(
        onPath.switched,
        isTrue,
        reason: '+112 REPRO (detection ON, detectable status label): the '
            'status-bar tap did NOT switch to window 1 while detection OFF '
            'switched fine — detection swallowed the tap. '
            'OFF=${off.summary()} ON_PATHLABEL=${onPath.summary()}',
      );
    },
  );
}

/// One A/B phase's captured state, for logging + the final diff.
class _Phase {
  _Phase({
    required this.label,
    required this.detectionOn,
    required this.landedOnW0,
    required this.statusText,
    required this.intendedCol,
    required this.sentSgrCol,
    required this.sentSgrCount,
    required this.switched,
    required this.matchAtTapPattern,
    required this.anchorCount,
    required this.cols,
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
  final int sentSgrCount;
  final bool switched;
  final String? matchAtTapPattern;
  final int anchorCount;
  final int cols;
  final double cellW;
  final double cellH;
  final double boxW;
  final double boxH;

  String summary() => 'intendedCol=$intendedCol sentSgrCol=$sentSgrCol '
      'sentSgrCount=$sentSgrCount switched=$switched '
      'matchAtTap=$matchAtTapPattern anchors=$anchorCount cols=$cols '
      'cell=${cellW.toStringAsFixed(2)}x${cellH.toStringAsFixed(2)} '
      'box=${boxW.toStringAsFixed(0)}x${boxH.toStringAsFixed(0)}';
}
