// On-emulator acceptance (#570 "copy & navigate URLs" — Slice 1): terminal URL
// long-press → identify the URL → Copy/Open action menu, on a REAL rendered
// terminal (real cell metrics, real scroll offset), not a synthetic widget-test
// surface.
//
// Flow:
//   1. Connect to test-sshd (reusing the connect harness).
//   2. `echo URLSPIKE https://example.com/path` so a known URL lands on a known
//      row.
//   3. Find that URL's on-screen pixel rect from xterm's PUBLIC
//      RenderTerminal.getOffset(CellOffset) + cellSize, convert to global,
//      long-press its center.
//   4. Assert `debugLastHitUrl == 'https://example.com/path'` (the cell→URL
//      hit-test fired) AND the Copy/Open action menu appeared.
//   5. Tap Copy → assert the system clipboard holds the URL.
//   6. NEGATIVE: long-press an EMPTY cell → the hit clears to null (URL vs
//      non-URL discrimination, no menu).
//
// Open is NOT exercised against a real browser here — the launcher is overridden
// (debugUrlOpenerOverride) so the emulator gate never leaves the app.
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
// Run: scripts/native-connect-test.sh integration_test/url_copy_navigate_test.dart

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:xterm/xterm.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/terminal_screen.dart' as term_screen;
import 'package:mobissh/ui/url_action_overlay.dart' as url_overlay;

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('long-press a printed URL → identify + Copy/Open menu', (
    tester,
  ) async {
    FlutterForegroundTask.initCommunicationPort();
    term_screen.debugLastHitUrl = null;
    // Open must not leave the app on the emulator gate — capture instead.
    url_overlay.debugUrlOpenerOverride = (u) async => true;
    addTearDown(() => url_overlay.debugUrlOpenerOverride = null);

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

    // Print a line carrying a KNOWN URL behind a marker token.
    const url = 'https://example.com/path';
    const marker = 'URLSPIKE';
    entry.proxy.sendInput(
      Uint8List.fromList(utf8.encode('echo $marker $url\n')),
    );

    // Wait until the PRINTED line (not the typed echo of the command) is in the
    // buffer: a row containing BOTH marker and URL that is NOT the command line.
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

    // Locate the live RenderTerminal to convert (row,col) → screen pixels — the
    // INVERSE of the production hit-test (pixels → cell), so a round-trip
    // through both proves the mapping is consistent.
    final termFinder = find.byKey(Key('terminal-view-${entry.id}'));
    expect(termFinder, findsOneWidget);
    final box = _findRenderTerminal(tester, termFinder);
    expect(box, isNotNull, reason: 'could not locate RenderTerminal');

    final cell = CellOffset(urlCol! + 3, urlRow!);
    final localTopLeft = (box! as dynamic).getOffset(cell) as Offset;
    final cellSize = (box as dynamic).cellSize as Size;
    final localCenter =
        localTopLeft + Offset(cellSize.width / 2, cellSize.height / 2);
    final global = box.localToGlobal(localCenter);

    // Long-press the URL cell.
    term_screen.debugLastHitUrl = null;
    await tester.longPressAt(global);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }

    // (a) the cell→URL hit-test resolved the URL,
    expect(
      term_screen.debugLastHitUrl,
      url,
      reason:
          'long-press on the printed URL cell did NOT resolve the URL — '
          'cell hit-test failed (row=$urlRow col=$urlCol)',
    );
    // (b) the Copy/Open action menu appeared.
    expect(
      find.byKey(const Key('url-action-menu')),
      findsOneWidget,
      reason: 'no action menu after long-press on a URL',
    );
    expect(find.byKey(const Key('url-action-copy')), findsOneWidget);
    expect(find.byKey(const Key('url-action-open')), findsOneWidget);

    // (c) Copy writes the URL to the system clipboard.
    await tester.tap(find.byKey(const Key('url-action-copy')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    expect(
      clip?.text,
      url,
      reason: 'Copy did not put the URL on the system clipboard',
    );

    // NEGATIVE CHECK: long-press an empty cell far to the right of any text —
    // the hit-test clears to null and no menu appears (URL discrimination).
    final emptyCell = CellOffset(terminal.viewWidth - 1, urlRow);
    final emptyLocal =
        ((box as dynamic).getOffset(emptyCell) as Offset) +
        Offset(cellSize.width / 2, cellSize.height / 2);
    term_screen.debugLastHitUrl = url; // seed non-null to prove it clears
    await tester.longPressAt(box.localToGlobal(emptyLocal));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(
      term_screen.debugLastHitUrl,
      isNull,
      reason: 'long-press on an empty cell wrongly reported a URL',
    );
    expect(
      find.byKey(const Key('url-action-menu')),
      findsNothing,
      reason: 'action menu wrongly appeared on a non-URL long-press',
    );
  });
}

/// Locate the live `RenderTerminal` render object under [finder]. The type is
/// not exported from package:xterm, so we walk the render subtree and match by
/// the presence of the public `getOffset`/`cellSize` API via duck typing.
RenderBox? _findRenderTerminal(WidgetTester tester, Finder finder) {
  final element = finder.evaluate().first;
  RenderBox? result;
  void visit(RenderObject node) {
    if (result != null) return;
    if (node is RenderBox) {
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
