// On-emulator acceptance for #999 — a single TAP on a detected PATH anchor
// NAVIGATES: it opens this app's SFTP file browser on the session's host at
// the path's browse target (a file-like path lands in its PARENT directory).
// No clipboard write happens for a path tap (copy moved to the long-press /
// gutter menus). URL tap-copy is covered by url_bubble_wrap_988_test.
//
// Device-class behaviour a headless test cannot cover: the live libghostty
// grid detecting the echoed path, a real tap routed through the gesture router
// at the bubble rect, the real navigation push, and a real SFTP listing of
// /etc arriving over the wire.
//
// The path is delivered via base64 so the typed COMMAND ECHO never contains
// the path text — exactly ONE detected anchor carries the payload.
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
// Run: scripts/native-connect-test.sh integration_test/path_tap_navigate_999_test.dart

import 'dart:convert';

import 'package:flterm/flterm.dart' hide Key;
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
    'a single tap on a detected /etc/hosts anchor opens the file browser at '
    '/etc (listing visible) and never writes the clipboard (#999)',
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

      final entry = container.read(sessionsProvider).active;
      expect(entry, isNotNull, reason: 'no active session after connect');
      final sessionId = entry!.id;

      TerminalController? controllerOf() =>
          GhosttyTerminalView.debugControllers[sessionId];
      for (var i = 0; i < 40 && controllerOf() == null; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      final controller = controllerOf();
      expect(controller, isNotNull, reason: 'no ghostty controller for session');

      // Wait for a live shell prompt.
      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      for (var i = 0; i < 40 && out.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(out.isNotEmpty, isTrue, reason: 'no shell prompt — dead PTY');

      // Let the first-connect resize storm settle (50x44 → 50x25 churn on the
      // emulator) BEFORE echoing, so the output lands in a stable grid and the
      // scanner's window isn't redrawn out from under the fresh rows.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      // Print the path via base64 so the typed command echo never contains it
      // — exactly ONE anchor will carry '/etc/hosts'. Trailing newline keeps
      // the prompt off the path's row (the regex would swallow it).
      //
      // TWO steps: decode into a shell variable first, then print with a SHORT
      // command. A single `echo <b64> | base64 -d` line is ~49 cols — the
      // scanner's inferred-wrap-col heuristic (#764/#925, tmux hard-wrap
      // support) then treats the near-full command row as WRAPPED onto the
      // output row, gluing `…base64 -d` to `/etc/hosts`, and the path regex's
      // lookbehind rejects the joined token (diagnosed from the anchors dump:
      // /etc/motd detected, the echoed path not). A short `echo "$v"` row can
      // never reach the inferred wrap column, so the output row stays its own
      // logical line.
      const path = '/etc/hosts';
      final b64 = base64Encode(utf8.encode('$path\n'));
      entry.proxy.sendInput(
        Uint8List.fromList(utf8.encode('v=\$(echo $b64 | base64 -d)\n')),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      entry.proxy.sendInput(Uint8List.fromList(utf8.encode('echo "\$v"\n')));

      // Wait until the in-terminal scanner detects the path anchor.
      StructuredAnchor? anchorOf() {
        for (final a in controller!.anchors) {
          if (a.patternId == 'path' && '${a.payload}' == path) return a;
        }
        return null;
      }

      for (var i = 0; i < 60 && anchorOf() == null; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      // Diagnostics on miss: what DID the scanner anchor, and what is actually
      // painted? (One-shot diagnosable failure instead of a blind rerun.)
      final anchorDump = [
        for (final a in controller!.anchors) '${a.patternId}:"${a.payload}"',
      ];
      final visible = controller.visibleRowsText(
        0,
        controller.scrollbar.visible - 1,
      );
      final visibleDump = visible
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .join(' | ');
      expect(
        anchorOf(),
        isNotNull,
        reason:
            'the echoed $path was never detected as a path anchor — '
            'anchors: $anchorDump; visible rows: "$visibleDump"',
      );

      // Wait for scroll-settle so the bubble geometry is live and resolvable.
      List<Rect> anchorRects() => [
        for (final range in anchorOf()!.ranges)
          ...controller.anchorRects(range),
      ];
      for (var i = 0;
          i < 30 && (controller.isScrolling || anchorRects().isEmpty);
          i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      final rects = anchorRects();
      expect(rects, isNotEmpty, reason: 'no on-screen rect for the path anchor');

      // Seed the clipboard with a sentinel: a #999-correct path tap must NOT
      // touch the clipboard, so the sentinel must survive the tap.
      const sentinel = 'SEED-999-NAVIGATE';
      await Clipboard.setData(const ClipboardData(text: sentinel));

      // Single TAP on the path bubble → the file browser must open.
      final viewOrigin = tester.getTopLeft(find.byType(TerminalView));
      await tester.tapAt(viewOrigin + rects.first.center);

      // The browser opens on the pushed route and lists /etc over real SFTP.
      var browserOpen = false;
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byKey(const Key('file-browser-path')).evaluate().isNotEmpty) {
          browserOpen = true;
          break;
        }
      }
      expect(
        browserOpen,
        isTrue,
        reason: 'the path tap never opened the file browser (#999)',
      );

      // The browse target for the FILE /etc/hosts is its PARENT dir /etc.
      final pathText = tester.widget<Text>(
        find.byKey(const Key('file-browser-path')),
      );
      expect(
        pathText.data,
        '/etc',
        reason: 'a file-like path must open its PARENT directory (v1 rule)',
      );

      // The real /etc listing renders. `hosts` is a FILE and sorts after the
      // many /etc subdirectories, and ListView.builder only builds VISIBLE
      // rows (run-3 failure) — so wait for the list, then scroll until the
      // row is built.
      var listMounted = false;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byKey(const Key('file-browser-list')).evaluate().isNotEmpty) {
          listMounted = true;
          break;
        }
      }
      expect(listMounted, isTrue, reason: 'the /etc listing never rendered');
      await tester.dragUntilVisible(
        find.text('hosts'),
        find.byKey(const Key('file-browser-list')),
        const Offset(0, -250),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text('hosts'),
        findsWidgets,
        reason: 'the /etc listing never showed the hosts entry',
      );

      // The clipboard sentinel survived — the path tap copied NOTHING.
      final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      expect(
        clip,
        sentinel,
        reason: 'a path tap must navigate, not copy (#999); clipboard changed',
      );

      // Hold with the browser open (~15s) so the host can screenshot it.
      debugPrint('BROWSE_HOLD_999 file browser open at /etc (screenshot now)');
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
    },
  );
}
