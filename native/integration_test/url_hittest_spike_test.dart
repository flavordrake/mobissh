// SPIKE (#570/#631) on-emulator proof: terminal URL HIT-TESTING.
//
// THE RISKY UNKNOWN this test de-risks: can a long-press on the live
// TerminalView be mapped to a buffer cell, and that cell matched against a
// detected URL — on a REAL rendered terminal (real cell metrics, real scroll
// offset), not a synthetic widget-test surface?
//
// Flow:
//   1. Connect to test-sshd (reusing the connect harness).
//   2. `echo see https://example.com/path` so a known URL lands on a known row.
//   3. Find that URL's on-screen pixel rect from xterm's PUBLIC
//      RenderTerminal.getOffset(CellOffset) (the inverse of getCellOffset the
//      production hit-test uses) + cellSize, convert to global, long-press its
//      center.
//   4. Assert `debugLastHitUrl == 'https://example.com/path'`.
//
// Also long-presses an EMPTY cell and asserts the hit clears to null — proving
// the hit-test discriminates URL from non-URL, not just "any long-press fires".
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
// Run: scripts/native-connect-test.sh integration_test/url_hittest_spike_test.dart
//
// DO NOT MERGE the spike wiring as-is — this is the orchestrator's emulator gate.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:xterm/xterm.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/terminal_screen.dart' as term_screen;

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('long-press on a printed URL resolves it via cell hit-test', (
    tester,
  ) async {
    FlutterForegroundTask.initCommunicationPort();
    term_screen.debugLastHitUrl = null;

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

    // Reach the terminal screen (accept the host-key prompt on first use).
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
    final terminal = entry!.terminal;

    // Wait for the shell prompt so the PTY is live.
    final out = <int>[];
    final sub = entry.proxy.output.listen(out.addAll);
    addTearDown(sub.cancel);
    for (var i = 0; i < 40 && out.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(out.isNotEmpty, isTrue, reason: 'no shell prompt — dead PTY');

    // Print a line carrying a KNOWN URL. A leading marker token makes the line
    // easy to locate in the buffer regardless of prompt text.
    const url = 'https://example.com/path';
    const marker = 'URLSPIKE';
    entry.proxy.sendInput(
      Uint8List.fromList(utf8.encode('echo $marker $url\n')),
    );

    // Wait until the printed line (not the typed echo of the command) is in the
    // buffer. We look for a buffer row that contains BOTH the marker and the URL
    // and is NOT the command line (the command line contains "echo ").
    int? urlRow;
    int? urlCol;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      final b = terminal.buffer;
      for (var y = b.height - 1; y >= 0; y--) {
        final text = b.lines[y].toString();
        if (text.contains(marker) &&
            text.contains(url) &&
            !text.contains('echo ')) {
          urlRow = y;
          urlCol = text.indexOf(url);
          break;
        }
      }
      if (urlRow != null) break;
    }
    expect(
      urlRow,
      isNotNull,
      reason: 'printed URL line never appeared in the terminal buffer',
    );

    // Find the live RenderTerminal to convert (row,col) → screen pixels. This is
    // the INVERSE of the production hit-test (which goes pixels → cell), so a
    // round-trip through both proves the mapping is consistent.
    final termFinder = find.byKey(Key('terminal-view-${entry.id}'));
    expect(termFinder, findsOneWidget);
    final box = _findRenderTerminal(tester, termFinder);
    expect(box, isNotNull, reason: 'could not locate RenderTerminal');

    // Pixel position of a cell mid-URL. getOffset gives the cell's top-left in
    // RenderTerminal-local coords; add half a cell to hit its center.
    final cell = CellOffset(urlCol! + 3, urlRow!);
    final localTopLeft = (box! as dynamic).getOffset(cell) as Offset;
    final cellSize = (box as dynamic).cellSize as Size;
    final localCenter = localTopLeft +
        Offset(cellSize.width / 2, cellSize.height / 2);
    final global = box.localToGlobal(localCenter);

    // Long-press the URL cell. Long-press (not tap/drag) is the spike gesture so
    // it never competes with xterm's vertical-scroll pan.
    term_screen.debugLastHitUrl = null;
    await tester.longPressAt(global);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }

    expect(
      term_screen.debugLastHitUrl,
      url,
      reason:
          'long-press on the printed URL cell did NOT resolve the URL — '
          'cell hit-test failed (row=$urlRow col=$urlCol)',
    );

    // NEGATIVE CHECK: long-press an empty cell far to the right of any text —
    // the hit-test must clear to null (URL vs non-URL discrimination).
    final emptyCell = CellOffset(terminal.viewWidth - 1, urlRow);
    final emptyLocal = ((box as dynamic).getOffset(emptyCell) as Offset) +
        Offset(cellSize.width / 2, cellSize.height / 2);
    term_screen.debugLastHitUrl = url; // seed non-null to prove it clears
    await tester.longPressAt(box.localToGlobal(emptyLocal));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(
      term_screen.debugLastHitUrl,
      isNull,
      reason: 'long-press on an empty cell wrongly reported a URL',
    );
  });
}

/// Locate the live `RenderTerminal` render object under [finder]. The type is
/// not exported from package:xterm, so we walk the render subtree and match by
/// the presence of the public `getCellOffset`/`getOffset` API via duck typing.
RenderBox? _findRenderTerminal(WidgetTester tester, Finder finder) {
  final element = finder.evaluate().first;
  RenderBox? result;
  void visit(RenderObject node) {
    if (result != null) return;
    if (node is RenderBox) {
      // RenderTerminal exposes getOffset(CellOffset) + cellSize. Probe by name.
      try {
        final dynamic d = node;
        final probe = d.cellSize;
        if (probe is Size) {
          result = node;
          return;
        }
      } catch (_) {
        // not RenderTerminal — keep descending
      }
    }
    node.visitChildren(visit);
  }

  element.renderObject?.let(visit);
  return result;
}

extension _Let<T extends Object> on T {
  void let(void Function(T) fn) => fn(this);
}
