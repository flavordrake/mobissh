// On-emulator check for #1155 (link highlight options slice 2): the gutter
// SIDE and the dedicated-COLUMN mode have a real geometric effect end to end
// (real SSH → shell → flterm → gutter layer → PTY resize).
//
// Flow:
//   1. connect to test-sshd, print one short URL line (U1155 …/g1155) and wait
//      for its gutter chip (`gutter-mark-<row>`) on the right edge,
//   2. open the link-highlight sheet (session menu → detection glyph), tap
//      `link-highlight-side-left` → the chip's centre x is in the LEFT half of
//      the terminal and the wash rect's x is UNCHANGED (R15/R18: overlay mode
//      moves only the chips, never the text),
//   3. tap `link-highlight-mode-column` → the PTY shrinks by EXACTLY
//      floor(innerW/cellW) - floor((innerW - 28)/cellW) columns (R19), read
//      back from the kernel winsize (`stty size`) AND the view's last-sent
//      grid; the chip still sits on the URL's row (R21),
//   4. back to overlay → the cols grow back to the original count.
//
// Screenshot windows (the orchestrator runs `scripts/emu-shot.sh` during each
// hold): GEOM1155_SHOT_LEFT_OPEN (chips on the left, overlay) and
// GEOM1155_SHOT_COLUMN_OPEN (dedicated left column, text inset by 28dp).
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
// Run: scripts/with-fleet-emulator.sh -- scripts/integration-subset.sh \
//        integration_test/link_highlight_gutter_geometry_test.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/detection_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/ghostty_gutter_layer.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import 'support/connect_helpers.dart';

// Short on purpose: it must NOT re-wrap when the grid loses a few columns.
const _url = 'https://x.io/g1155';

Future<void> _pumps(WidgetTester tester, int n,
    [Duration d = const Duration(milliseconds: 100)]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(d);
  }
}

/// The URL anchor's current viewport row (null when off-screen/undetected).
int? _urlRow(TerminalController c) {
  for (final a in c.anchors) {
    if (!'${a.payload}'.contains('g1155')) continue;
    for (final r in a.ranges) {
      final row = c.anchorGutterRow(r);
      if (row != null) return row;
    }
  }
  return null;
}

/// The URL anchor's first wash rect in WASH-LAYER coordinates (the same rects
/// `GhosttyWashLayer` paints), or null when undetected.
Rect? _urlWashRect(TerminalController c) {
  for (final a in c.anchors) {
    if (!'${a.payload}'.contains('g1155')) continue;
    for (final r in a.ranges) {
      final rects = c.anchorRects(r);
      if (rects.isNotEmpty) return rects.first;
    }
  }
  return null;
}

Finder _mark(int row) => find.byKey(ValueKey<String>('gutter-mark-$row'));

/// Wait until the URL's gutter mark is rendered; returns its row.
Future<int> _awaitUrlMark(WidgetTester tester, TerminalController c) async {
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 200));
    final row = _urlRow(c);
    if (row != null && _mark(row).evaluate().isNotEmpty) return row;
  }
  fail('the U1155 URL line never got a gutter mark — urlRow=${_urlRow(c)} '
      'payloads=${[for (final a in c.anchors) '${a.patternId}:${a.payload}']}');
}

/// Open the link-highlight OPTIONS sheet (#1154 R1): session menu → tap the
/// detection glyph.
Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('session-menu-button')));
  await _pumps(tester, 8);
  await tester.tap(find.byKey(const Key('session-menu-detection-toggle')));
  await _pumps(tester, 10);
  expect(find.byKey(const Key('link-highlight-menu')), findsOneWidget,
      reason: 'the link-highlight sheet must open from the detection glyph');
}

Future<void> _closeSheet(WidgetTester tester) async {
  final sheet = find.byKey(const Key('link-highlight-menu'));
  if (sheet.evaluate().isEmpty) return;
  Navigator.of(tester.element(sheet)).pop();
  await _pumps(tester, 10);
  expect(find.byKey(const Key('link-highlight-menu')), findsNothing);
}

/// Read the PTY's column count back from the KERNEL winsize (`stty size` is
/// busybox-safe; bash's $COLUMNS depends on readline having seen SIGWINCH).
/// Sends the probe once per second until the marker's answer arrives.
Future<int> _ptyCols(
  WidgetTester tester,
  SessionEntry entry,
  List<int> out,
  String marker,
) async {
  final re = RegExp('$marker=(\\d+) (\\d+)');
  for (var attempt = 0; attempt < 10; attempt++) {
    entry.proxy.sendInput(
      Uint8List.fromList(utf8.encode('echo $marker=\$(stty size)\n')),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      final text = utf8.decode(out, allowMalformed: true);
      final m = re.allMatches(text).lastOrNull;
      if (m != null) return int.parse(m.group(2)!);
    }
  }
  fail('no $marker=<rows> <cols> readback from the shell');
}

/// Wait until the view's LAST-SENT cols equals [want] (the #903 coalescer
/// debounces the resize), then return the grid snapshot.
Future<List<int>> _awaitSentCols(
  WidgetTester tester,
  String sessionId,
  int want,
) async {
  List<int>? grid;
  for (var i = 0; i < 50; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    grid = GhosttyTerminalView.debugGrids[sessionId];
    if (grid != null && grid.length >= 3 && grid[2] == want) return grid;
  }
  fail('last-sent cols never reached $want — grid=$grid');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'gutter side moves the chips (R15/R18); column mode shrinks the PTY by '
    'the strip delta and grows back (R19/R21) — #1155',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      final container = ProviderContainer();
      addTearDown(container.dispose);
      // Persisted prefs survive on the device between runs: force the
      // pre-#1155 defaults on entry AND restore them on exit.
      final notifier = container.read(detectionSettingsProvider.notifier);
      await notifier.setEnabled(true);
      await notifier.setGutterSide(GutterSide.right);
      await notifier.setGutterMode(GutterMode.overlay);
      addTearDown(() async {
        await notifier.setGutterSide(GutterSide.right);
        await notifier.setGutterMode(GutterMode.overlay);
      });

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

      final entry = container.read(sessionsProvider).active;
      expect(entry, isNotNull, reason: 'no active session after connect');
      final sessionId = entry!.id;

      TerminalController? ctrlOf() =>
          GhosttyTerminalView.debugControllers[sessionId];
      for (var i = 0; i < 40 && ctrlOf() == null; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      final controller = ctrlOf();
      expect(controller, isNotNull, reason: 'no ghostty controller');

      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      for (var i = 0; i < 40 && out.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(out.isNotEmpty, isTrue, reason: 'no shell prompt — dead PTY');

      // Baseline geometry: the laid-out box, the measured cell, the grid.
      final termFinder = find.byKey(Key('ghostty-terminal-$sessionId'));
      expect(termFinder, findsOneWidget, reason: 'no ghostty terminal view');
      final termRect = tester.getRect(termFinder);
      final midX = termRect.left + termRect.width / 2;
      Size? cell;
      for (var i = 0; i < 40 && cell == null; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        cell = GhosttyTerminalView.debugCellSizes[sessionId];
      }
      expect(cell, isNotNull, reason: 'no measured cell size');
      final cellW = cell!.width;
      expect(cellW, greaterThan(1.0));
      final innerW = termRect.width - 2 * kGhosttyTerminalPadding;
      final overlayCols = (innerW / cellW).floor();
      final columnCols = ((innerW - kGutterStripWidth) / cellW).floor();
      final delta = overlayCols - columnCols;
      expect(delta, greaterThanOrEqualTo(1),
          reason: 'fixture geometry must lose >= 1 col in column mode');

      // Print the URL line and wait for its right-edge chip.
      entry.proxy.sendInput(
        Uint8List.fromList(utf8.encode('clear; echo U1155 $_url\n')),
      );
      final row0 = await _awaitUrlMark(tester, controller!);
      final rightChipX = tester.getCenter(_mark(row0)).dx;
      expect(rightChipX, greaterThan(midX),
          reason: 'default side is RIGHT — chip centre in the right half');
      final washRect0 = _urlWashRect(controller);
      expect(washRect0, isNotNull, reason: 'the URL has no wash rect');
      final washLayerX0 =
          tester.getTopLeft(find.byKey(const Key('ghostty-wash-paint'))).dx;
      final cols0 = await _ptyCols(tester, entry, out, 'W1155A');
      expect(cols0, overlayCols,
          reason: 'baseline PTY cols must equal floor(innerW/cellW)');
      debugPrint('GEOM1155 baseline: cell=$cell inner=$innerW cols=$cols0 '
          'delta=$delta urlRow=$row0 chipX=$rightChipX wash=$washRect0');

      // R15/R18: side → LEFT through the sheet. Chips cross to the left half;
      // the wash (text) does not move.
      await _openSheet(tester);
      await tester.tap(find.byKey(const Key('link-highlight-side-left')));
      await _pumps(tester, 5);
      expect(container.read(detectionSettingsProvider).gutterSide,
          GutterSide.left);
      await _closeSheet(tester);
      final rowL = await _awaitUrlMark(tester, controller);
      expect(rowL, row0, reason: 'R21: the chip stays on the URL row');
      final leftChipX = tester.getCenter(_mark(rowL)).dx;
      expect(leftChipX, lessThan(midX),
          reason: 'R15: side=left → chip centre in the LEFT half');
      expect(leftChipX, lessThan(termRect.left + kGutterStripWidth + 20),
          reason: 'the chip hugs the left edge');
      final washRectL = _urlWashRect(controller);
      final washLayerXL =
          tester.getTopLeft(find.byKey(const Key('ghostty-wash-paint'))).dx;
      expect(washRectL, isNotNull);
      expect(washLayerXL + washRectL!.left, washLayerX0 + washRect0!.left,
          reason: 'R18: overlay side switch never moves the text/wash');
      final colsL = await _ptyCols(tester, entry, out, 'W1155L');
      expect(colsL, overlayCols, reason: 'R18: overlay keeps the PTY width');

      debugPrint('GEOM1155_SHOT_LEFT_OPEN');
      await _pumps(tester, 6, const Duration(milliseconds: 500));
      debugPrint('GEOM1155_SHOT_LEFT_CLOSED');

      // R19: mode → COLUMN. The PTY loses exactly `delta` cols; the chip is
      // still on the URL's row; the wash moves RIGHT by the strip (text inset).
      await _openSheet(tester);
      await tester.tap(find.byKey(const Key('link-highlight-mode-column')));
      await _pumps(tester, 5);
      expect(container.read(detectionSettingsProvider).gutterMode,
          GutterMode.column);
      await _closeSheet(tester);
      final gridC = await _awaitSentCols(tester, sessionId, columnCols);
      expect(gridC[0], columnCols, reason: 'R19: grid cols shrink by $delta');
      final colsC = await _ptyCols(tester, entry, out, 'W1155C');
      expect(colsC, overlayCols - delta,
          reason: 'R19: kernel winsize cols shrink by exactly $delta');
      final rowC = await _awaitUrlMark(tester, controller);
      expect(rowC, row0, reason: 'R21: the chip stays on the URL row');
      expect(tester.getCenter(_mark(rowC)).dx, lessThan(midX));
      final washRectC = _urlWashRect(controller);
      final washLayerXC =
          tester.getTopLeft(find.byKey(const Key('ghostty-wash-paint'))).dx;
      expect(washRectC, isNotNull);
      expect(
        washLayerXC + washRectC!.left,
        closeTo(washLayerX0 + washRect0.left + kGutterStripWidth, 1.0),
        reason: 'R19: column mode insets the text by the 28dp strip',
      );
      debugPrint('GEOM1155 column: grid=$gridC cols=$colsC urlRow=$rowC '
          'wash=$washRectC');

      debugPrint('GEOM1155_SHOT_COLUMN_OPEN');
      await _pumps(tester, 6, const Duration(milliseconds: 500));
      debugPrint('GEOM1155_SHOT_COLUMN_CLOSED');

      // Back to OVERLAY: the cols grow back to the original count.
      await _openSheet(tester);
      await tester.tap(find.byKey(const Key('link-highlight-mode-overlay')));
      await _pumps(tester, 5);
      expect(container.read(detectionSettingsProvider).gutterMode,
          GutterMode.overlay);
      await _closeSheet(tester);
      await _awaitSentCols(tester, sessionId, overlayCols);
      final colsO = await _ptyCols(tester, entry, out, 'W1155O');
      expect(colsO, overlayCols, reason: 'R19: overlay restores the PTY width');
      final rowO = await _awaitUrlMark(tester, controller);
      expect(rowO, row0, reason: 'R21: the chip stays on the URL row');
    },
  );
}
