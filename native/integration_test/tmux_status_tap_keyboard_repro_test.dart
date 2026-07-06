// tmux_status_tap_keyboard_repro_test.dart — the +112 device repro, second
// attempt. The prior A/B (tmux_status_tap_detection_ab_test.dart) switched fine
// in BOTH detection states and could NOT reproduce (anchors=0, gutter did not
// shift the column). This harness adds the two device factors it LACKED:
//   1. REAL URLs/paths in the terminal BODY (so detection actually anchors —
//      `controller.anchors` > 0, matching why the device user runs detection ON),
//   2. a RAISED soft keyboard: on this emulator the IME inset is persistently up
//      (viewInsets.bottom ~= 883 throughout), so every tap here is a keyboard-UP
//      status-bar tap — the #903/#922 state (logged per tap so it is visible).
//
// It repeatedly taps window 1's status-bar label at the VISIBLE BOTTOM of the
// terminal box — exactly where the device user taps the status bar — ALTERNATING
// detection OFF/ON, ALWAYS re-landing on window 0 first, and for each tap logs the
// MECHANISM:
//   - landed (did we re-land on w0), preMarker/postMarker (m0/m1 rendered
//     before/after the tap) → a REAL switch is m0→m1,
//   - intended window-1 label COLUMN vs the SENT SGR press COLUMN and ROW,
//   - tmux's REAL status row = gridRows (the coalescer's lastEmittedRows) vs the
//     LIVE rendered grid (scrollbar.visible),
//   - sentSgrCount (0 == the tap forwarded NOTHING — swallowed),
//   - the tap's gesture TRACE TYPE (tap / tap-url-copy / tap-dismiss-selection),
//   - `urlAtCell` at the ACTUAL mapped cell + anchor count + selection state,
//   - viewInsets.bottom (keyboard up).
//
// First run's finding (build 399b885): a detection-ON tap on the status cell
// forwarded ZERO SGR (count=0) while detection-OFF forwarded normally at the SAME
// cell — the device-bug shape. This run isolates WHY (trace type + selection).
//
// RED (bug reproduced) = a detection-ON tap fails the m0→m1 switch while the
// detection-OFF taps switch. GREEN = negative result; the per-tap numbers say
// which factor is still missing.
//
// Run: scripts/native-connect-test.sh integration_test/tmux_status_tap_keyboard_repro_test.dart

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
    'tmux status-tap-to-switch, keyboard up + body anchors: detection OFF taps '
    'switch; does any detection-ON tap forward nothing (the +112 shape)?',
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
      // detect. automatic-rename off so the body content doesn't rewrite the
      // window label.
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
        for (var attempt = 0; attempt < 3; attempt++) {
          send('tmux select-window -t 0\n');
          for (var i = 0; i < 24; i++) {
            await tester.pump(const Duration(milliseconds: 250));
            final r = rendered();
            if (r.contains(m0) && !r.contains(m1)) return true;
          }
        }
        return false;
      }

      expect(await landOnWindow0(), isTrue,
          reason: 'setup: never landed back on window 0 ($m0)');

      final recorder = GhosttyTerminalView.debugByteRecorders[sessionId];
      expect(recorder, isNotNull, reason: 'no byte recorder for the session');
      final coalescer = GhosttyTerminalView.debugResizeCoalescers[sessionId];
      expect(coalescer, isNotNull, reason: 'no resize coalescer for the session');

      String whichWindow() {
        final r = rendered();
        final has0 = r.contains(m0);
        final has1 = r.contains(m1);
        if (has0 && !has1) return 'w0';
        if (has1 && !has0) return 'w1';
        if (has0 && has1) return 'both';
        return 'none';
      }

      // One tap: land on window 0, tap window 1's status label at the VISIBLE
      // BOTTOM of the terminal box, and capture the mechanism.
      Future<_Tap> runTap(String label, bool detectionOn,
          {String? labelToken, int tokenCharOffset = 0}) async {
        container.read(detectionSettingsProvider.notifier).setEnabled(detectionOn);
        await settle();
        final landed = await landOnWindow0();
        await settle();
        final preMarker = whichWindow();

        final termRect = tester.getRect(
          find.byKey(Key('ghostty-terminal-$sessionId')),
        );
        final cell = GhosttyTerminalView.debugCellSizes[sessionId]!;
        final rows = visibleRows();
        final last = rows > 0 ? rows - 1 : 0;
        final statusText = controller.visibleRowsText(last, last);
        final token = labelToken ?? '1:$w1Name';
        final tokenCol = statusText.indexOf(token);
        final nameCol = statusText.indexOf(w1Name);
        final baseCol = tokenCol >= 0 ? tokenCol : nameCol;
        final labelCol = baseCol >= 0 ? baseCol + tokenCharOffset : baseCol;
        expect(labelCol, greaterThanOrEqualTo(0),
            reason: '[$label] window-1 label ("$token") not in status row '
                '"$statusText"');

        // Tap X: window 1's label cell. Tap Y: the VISIBLE BOTTOM of the terminal
        // box (where the status bar renders on-device).
        final tapX =
            termRect.left + kGhosttyTerminalPadding + (labelCol + 0.5) * cell.width;
        final tapY = termRect.bottom - cell.height * 0.5;
        final tapAt = Offset(tapX, tapY);

        // The grid row/col this pixel maps to (replicating the cell map's clamp to
        // gridRows/gridCols = lastEmitted), and tmux's real status row (=gridRows).
        final gridRows = coalescer!.lastEmittedRows ?? 0;
        final gridCols = coalescer.lastEmittedCols ?? 0;
        final rawRow =
            ((tapY - termRect.top - kGhosttyTerminalPadding) / cell.height)
                .floor();
        final rawCol =
            ((tapX - termRect.left - kGhosttyTerminalPadding) / cell.width)
                .floor();
        final mappedRow =
            gridRows > 0 ? (rawRow + 1).clamp(1, gridRows) : rawRow + 1;
        final mappedCol =
            gridCols > 0 ? (rawCol + 1).clamp(1, gridCols) : rawCol + 1;

        // Detection presence AT the ACTUAL mapped cell (the exact cell _onTapUp
        // hit-tests via urlAtCell) + at the intended label cell + globally.
        final matchAtMapped =
            controller.matchAt(row: mappedRow - 1, col: mappedCol - 1);
        final matchAtLabel = controller.matchAt(row: mappedRow - 1, col: labelCol);
        final anchorCount = controller.anchors.length;
        final selBefore = controller.selection != null;

        final mq = tester.platformDispatcher.views.first;
        final inset = mq.viewInsets.bottom;

        final sgrBefore = recorder!.snapshotSentSgrTrace();
        final gLogBefore = gestureLogSnapshot();

        // The gesture under test: a discrete tap (the _onTapUp path).
        await tester.tapAt(tapAt);
        await settle();

        final sgrAfter = recorder.snapshotSentSgrTrace();
        // The SGR ring evicts by AGE and capacity (kSentSgrRecorderMaxEvents),
        // so once saturated `sgrAfter.length == sgrBefore.length` even though new
        // reports were added (old ones aged out) — a length-delta then yields
        // nothing. Diff by CONTENT (b64) so the tap's real SGR is captured, and
        // decode the last press from that content diff.
        final beforeKeys = sgrBefore.map((e) => '${e['tMs']}:${e['b64']}').toSet();
        final newSgr = sgrAfter
            .where((e) => !beforeKeys.contains('${e['tMs']}:${e['b64']}'))
            .toList(growable: false);
        final (sentCol, sentRow) = _lastSgrPress(newSgr);
        final postMarker = whichWindow();
        final selAfter = controller.selection != null;

        // The gesture ring can saturate (constant length), so diff by CONTENT,
        // not length — find events present now but not before, and classify the
        // tap's trace TYPE (the leading token: tap / tap-url-copy / etc).
        final gLogAfter = gestureLogSnapshot();
        final beforeSet = gLogBefore.toSet();
        final newG =
            gLogAfter.where((e) => !beforeSet.contains(e)).toList(growable: false);
        String? traceType;
        for (final e in newG) {
          // Format: "<hh:mm:ss.mmm> <type> pos=(...) ...".
          final parts = e.split(' ');
          if (parts.length >= 2) traceType = parts[1];
        }

        final t = _Tap(
          label: label,
          detectionOn: detectionOn,
          landed: landed,
          preMarker: preMarker,
          postMarker: postMarker,
          statusText: statusText,
          intendedCol: labelCol,
          mappedCol: mappedCol,
          mappedRow: mappedRow,
          sentSgrCol: sentCol,
          sentSgrRow: sentRow,
          sentSgrCount: newSgr.length,
          gridRows: gridRows,
          gridCols: gridCols,
          liveRows: controller.scrollbar.visible,
          viewInsetBottom: inset,
          anchorCount: anchorCount,
          matchAtMapped: matchAtMapped?.patternId,
          matchAtLabel: matchAtLabel?.patternId,
          selBefore: selBefore,
          selAfter: selAfter,
          traceType: traceType,
          cellW: cell.width,
          cellH: cell.height,
          boxW: termRect.width,
          boxH: termRect.height,
        );

        debugPrint('KBREPRO[$label] ${t.summary()}');
        debugPrint('KBREPRO[$label] statusRow="$statusText" tapAt=$tapAt');
        for (final s in _sgrStrings(newSgr)) {
          debugPrint('KBREPRO[$label] sentSGR: $s');
        }
        for (final g in newG) {
          debugPrint('KBREPRO[$label] gesture: $g');
        }
        return t;
      }

      // Alternate OFF/ON taps, always re-landing on w0. If detection ON ever
      // fails the m0→m1 switch while OFF taps switch, that is the +112 repro.
      final taps = <_Tap>[];
      final plan = <(String, bool)>[
        ('OFF_1', false),
        ('ON_1', true),
        ('OFF_2', false),
        ('ON_2', true),
        ('ON_3', true),
        ('OFF_3', false),
      ];
      for (final (lbl, det) in plan) {
        taps.add(await runTap(lbl, det));
      }

      // ATTEMPT #3 — the ONE detection-dependent branch in _onTapUp is the
      // `urlAtCell` swallow: a tap on a cell carrying a detected match COPIES it
      // and forwards NO SGR (no window switch). That can only bite a status tap
      // if detection ANCHORS the tmux STATUS row. So make window 1's LABEL itself
      // a detectable absolute path and re-tap it: if matchAtLabel becomes
      // non-null AND the tap fails to switch, that IS the +112 repro. If
      // matchAtLabel stays null, detection structurally never anchors the status
      // row and the swallow cannot fire on a status tap — a decisive finding.
      const w1Path = '/etc/hostname';
      send("tmux set -g status-right ''\n");
      await settle(4);
      send("tmux set -g status-left ''\n");
      await settle(4);
      send('tmux set-window-option -t 1 automatic-rename off\n');
      await settle(4);
      send('tmux rename-window -t 1 $w1Path\n');
      await settle();
      // Tap a few cells INTO the path (past "1:") so the tapped cell is squarely
      // inside the detectable token, not the "1:" index prefix.
      final pathTap = await runTap('ON_PATHLABEL', true,
          labelToken: '1:$w1Path', tokenCharOffset: 4);
      taps.add(pathTap);

      for (final t in taps) {
        debugPrint('KBREPRO SUMMARY ${t.label}: ${t.summary()}');
      }
      debugPrint('KBREPRO PATHLABEL: statusText="${pathTap.statusText}" '
          'matchAtLabel=${pathTap.matchAtLabel} '
          'matchAtMapped=${pathTap.matchAtMapped} '
          'anchors=${pathTap.anchorCount} '
          'sentSgrRow=${pathTap.sentSgrRow} switched pre=${pathTap.preMarker} '
          'post=${pathTap.postMarker}');

      bool switched(_Tap t) =>
          t.landed && t.preMarker == 'w0' && t.postMarker == 'w1';

      final offTaps = taps.where((t) => !t.detectionOn).toList();
      final onTaps = taps.where((t) => t.detectionOn).toList();
      final offSwitched = offTaps.where(switched).length;
      final onSwitched = onTaps.where(switched).length;
      final onSwallowed =
          onTaps.where((t) => t.sentSgrCount == 0).map((t) => t.label).toList();
      debugPrint('KBREPRO RESULT: OFF switched $offSwitched/${offTaps.length}, '
          'ON switched $onSwitched/${onTaps.length}, '
          'ON forwarded-nothing(count=0): $onSwallowed');

      // CONTROL: detection OFF taps must switch (else setup/timing — not the bug).
      // Require the landing to have worked for the OFF taps we count.
      final offLanded = offTaps.where((t) => t.landed && t.preMarker == 'w0');
      expect(offLanded.isNotEmpty, isTrue,
          reason: 'CONTROL: no detection-OFF tap even re-landed on window 0 — '
              'setup/timing problem, cannot evaluate the bug');
      expect(offLanded.every(switched), isTrue,
          reason: 'CONTROL (detection OFF): a status tap that started on window 0 '
              'did not switch to window 1 — setup/timing, not the bug. '
              'OFF taps: ${offTaps.map((t) => t.summary()).join(" || ")}');

      // REPRO: every detection-ON tap that re-landed on window 0 must ALSO switch.
      // RED here = the +112 bug reproduced. The per-tap summaries show WHY:
      // sentSgrCount==0 (tap forwarded nothing), the traceType (url-copy /
      // dismiss-selection), or sentSgrRow != gridRows (sizing miss).
      final onLanded = onTaps.where((t) => t.landed && t.preMarker == 'w0');
      expect(onLanded.isNotEmpty, isTrue,
          reason: 'no detection-ON tap re-landed on window 0 — inconclusive');
      expect(
        onLanded.every(switched),
        isTrue,
        reason: '+112 REPRO (keyboard up, detection ON): a status-bar tap that '
            'started on window 0 did NOT switch to window 1 while detection-OFF '
            'taps switched fine. MECHANISM per ON tap: '
            '${onTaps.map((t) => t.summary()).join(" || ")}',
      );
    },
  );
}

class _Tap {
  _Tap({
    required this.label,
    required this.detectionOn,
    required this.landed,
    required this.preMarker,
    required this.postMarker,
    required this.statusText,
    required this.intendedCol,
    required this.mappedCol,
    required this.mappedRow,
    required this.sentSgrCol,
    required this.sentSgrRow,
    required this.sentSgrCount,
    required this.gridRows,
    required this.gridCols,
    required this.liveRows,
    required this.viewInsetBottom,
    required this.anchorCount,
    required this.matchAtMapped,
    required this.matchAtLabel,
    required this.selBefore,
    required this.selAfter,
    required this.traceType,
    required this.cellW,
    required this.cellH,
    required this.boxW,
    required this.boxH,
  });

  final String label;
  final bool detectionOn;
  final bool landed;
  final String preMarker;
  final String postMarker;
  final String statusText;
  final int intendedCol;
  final int mappedCol;
  final int mappedRow;
  final int? sentSgrCol;
  final int? sentSgrRow;
  final int sentSgrCount;
  final int gridRows;
  final int gridCols;
  final int liveRows;
  final double viewInsetBottom;
  final int anchorCount;
  final String? matchAtMapped;
  final String? matchAtLabel;
  final bool selBefore;
  final bool selAfter;
  final String? traceType;
  final double cellW;
  final double cellH;
  final double boxW;
  final double boxH;

  String summary() =>
      'det=$detectionOn landed=$landed pre=$preMarker post=$postMarker '
      '| intendedCol=$intendedCol mappedCol=$mappedCol mappedRow=$mappedRow '
      'sentSgrCol=$sentSgrCol sentSgrRow=$sentSgrRow (count=$sentSgrCount) '
      'trace=$traceType '
      '| gridRows=$gridRows gridCols=$gridCols liveRows=$liveRows '
      '| anchors=$anchorCount matchMapped=$matchAtMapped matchLabel=$matchAtLabel '
      'sel=$selBefore→$selAfter '
      '| inset=${viewInsetBottom.toStringAsFixed(0)} '
      'cell=${cellW.toStringAsFixed(1)}x${cellH.toStringAsFixed(1)} '
      'box=${boxW.toStringAsFixed(0)}x${boxH.toStringAsFixed(0)}';
}
