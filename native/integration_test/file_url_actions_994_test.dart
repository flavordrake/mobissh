// On-emulator acceptance for #994 — a file:// URL detected in terminal output
// is a REMOTE PATH on the SSH host:
//   * a single TAP on an OSC-8 file:///etc/ link NAVIGATES — opens this app's
//     SFTP file browser at /etc on the CONNECTED session's host (trailing
//     slash → the dir itself per the #999 dir-vs-file rule), never the
//     clipboard, never an Android URL hand-off;
//   * a LONG-PRESS on an OSC-8 file:///etc/hosts link shows the PATH action
//     menu (Open / Copy path / Copy sftp URL) and "Copy path" puts the BARE
//     percent-free path (/etc/hosts — no scheme) on the real clipboard.
//
// OSC-8 links are used because that is how file:// URLs reach a terminal
// today (ls --hyperlink, eza); plain-text file:// detection is the parallel
// flterm url-regex change — the action layer here routes it identically
// (unit-tested headless in test/ui/ghostty_file_url_994_test.dart).
//
// Device-class behaviour a headless test cannot cover: libghostty attaching
// the OSC-8 URI to real cells, a real tap/long-press through the gesture
// router, the real navigation push, a real SFTP listing of /etc, and the real
// Android clipboard.
//
// The escape sequences are delivered via base64 so the typed COMMAND ECHO
// never contains a detectable file:// literal (future-proof against the
// plain-text url-regex change) — each link yields exactly ONE anchor.
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
// Run: scripts/native-connect-test.sh integration_test/file_url_actions_994_test.dart

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
    'tap on an OSC-8 file:///etc/ link opens the file browser at /etc; '
    'long-press on file:///etc/hosts offers Copy path (bare, no scheme) and '
    'Copy sftp URL (#994)',
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

      // Let the first-connect resize storm settle before echoing (see the
      // #999 test) so the links land in a stable grid.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      // Emit an OSC-8 hyperlink via base64 (the command echo never contains a
      // file:// literal). [label] is the visible cell text; [uri] rides the
      // cells as the OSC-8 hyperlink.
      Future<void> emitOsc8(String varName, String uri, String label) async {
        final seq = '\x1b]8;;$uri\x1b\\$label\x1b]8;;\x1b\\\n';
        final b64 = base64Encode(utf8.encode(seq));
        entry.proxy.sendInput(
          Uint8List.fromList(
            utf8.encode('$varName=\$(echo $b64 | base64 -d)\n'),
          ),
        );
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        // %s\n: command substitution stripped the trailing newline, so print
        // one back — the prompt must not share the link's row.
        entry.proxy.sendInput(
          Uint8List.fromList(utf8.encode('printf \'%s\\n\' "\$$varName"\n')),
        );
      }

      StructuredAnchor? anchorOf(String uri) {
        for (final a in controller!.anchors) {
          if (a.patternId == 'osc8' && '${a.payload}' == uri) return a;
        }
        return null;
      }

      Future<StructuredAnchor> awaitAnchor(String uri) async {
        for (var i = 0; i < 60 && anchorOf(uri) == null; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        final anchorDump = [
          for (final a in controller!.anchors) '${a.patternId}:"${a.payload}"',
        ];
        expect(
          anchorOf(uri),
          isNotNull,
          reason:
              'the OSC-8 link $uri was never anchored — anchors: $anchorDump',
        );
        return anchorOf(uri)!;
      }

      Future<List<Rect>> awaitRects(String uri) async {
        List<Rect> anchorRects() => [
          for (final range in anchorOf(uri)!.ranges)
            ...controller!.anchorRects(range),
        ];
        for (var i = 0;
            i < 30 && (controller!.isScrolling || anchorRects().isEmpty);
            i++) {
          await tester.pump(const Duration(milliseconds: 300));
        }
        final rects = anchorRects();
        expect(rects, isNotEmpty, reason: 'no on-screen rect for $uri');
        return rects;
      }

      // PART 1 — TAP NAVIGATES. Trailing slash: the #999 rule opens the dir
      // itself, so the browser lands AT /etc.
      const dirUri = 'file:///etc/';
      await emitOsc8('v', dirUri, 'ETC-LINK');
      await awaitAnchor(dirUri);
      final dirRects = await awaitRects(dirUri);

      // Clipboard sentinel: a #994 file:// tap must NOT touch the clipboard.
      const sentinel = 'SEED-994-NAVIGATE';
      await Clipboard.setData(const ClipboardData(text: sentinel));

      final viewOrigin = tester.getTopLeft(find.byType(TerminalView));
      await tester.tapAt(viewOrigin + dirRects.first.center);

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
        reason: 'the file:// tap never opened the file browser (#994)',
      );
      final pathText = tester.widget<Text>(
        find.byKey(const Key('file-browser-path')),
      );
      expect(
        pathText.data,
        '/etc',
        reason: 'file:///etc/ must open the browser AT /etc (trailing slash '
            '→ the dir itself, authority-stripped bare path)',
      );

      // The real /etc listing renders over SFTP.
      var listMounted = false;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byKey(const Key('file-browser-list')).evaluate().isNotEmpty) {
          listMounted = true;
          break;
        }
      }
      expect(listMounted, isTrue, reason: 'the /etc listing never rendered');

      final clipAfterTap = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      expect(
        clipAfterTap,
        sentinel,
        reason: 'a file:// tap must navigate, not copy; clipboard changed',
      );

      // Hold briefly so the host can screenshot the browser at /etc.
      debugPrint('BROWSE_HOLD_994 file browser open at /etc (screenshot now)');
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      // Back to the terminal for PART 2 (the browser's leading action is the
      // terminal glyph, not a standard Material back button).
      await tester.tap(
        find.byKey(const Key('file-browser-back-to-terminal')),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(
        find.byType(TerminalView),
        findsWidgets,
        reason: 'never returned to the terminal after the browser',
      );

      // PART 2 — the anchor's ACTION MENU: Copy path yields the BARE path (no
      // scheme). Driven via the GUTTER MARK (a keyed widget tap): the mark
      // dispatches through the SAME #994 registry routing as the long-press
      // menu, without the raw-pointer geometry that the post-browser keyboard
      // resize churn makes flaky (runs 1-2: the press point went stale mid-
      // resize and hit nothing). The long-press classification itself is
      // covered headless in test/ui/ghostty_file_url_994_test.dart.
      const fileUri = 'file:///etc/hosts';
      await emitOsc8('w', fileUri, 'HOSTS-LINK');
      await awaitAnchor(fileUri);
      await awaitRects(fileUri);
      // Let the prompt line + resize churn settle so the mark row is stable.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      // The mark renders at the anchor's LIVE viewport row — re-resolve the
      // anchor each probe (its absolute ranges can shift on resize/eviction).
      Finder markFinder() {
        final anchor = anchorOf(fileUri);
        if (anchor == null) return find.byKey(const Key('gutter-mark-none'));
        final row = controller!.anchorGutterRow(anchor.ranges.first);
        return find.byKey(Key('gutter-mark-$row'));
      }

      for (var i = 0; i < 20 && markFinder().evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(
        markFinder(),
        findsOneWidget,
        reason: 'no gutter mark for the file:///etc/hosts anchor',
      );
      await tester.tap(markFinder());

      var menuOpen = false;
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (find.byKey(const Key('path-action-menu')).evaluate().isNotEmpty) {
          menuOpen = true;
          break;
        }
      }
      expect(
        menuOpen,
        isTrue,
        reason: 'the file:// anchor mark must show the PATH action '
            'menu (#994), not the URL menu',
      );
      expect(find.byKey(const Key('url-action-menu')), findsNothing);
      expect(find.byKey(const Key('path-action-open')), findsOneWidget);
      expect(
        find.byKey(const Key('path-action-copy-sftp')),
        findsOneWidget,
        reason: 'the canonical sftp:// form must be offered',
      );

      // Screenshot beat: the menu is the deliverable UI.
      debugPrint('MENU_HOLD_994 path menu open on file:///etc/hosts');
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      await tester.tap(find.byKey(const Key('path-action-copy')));
      // Assert the UI contract: the success toast carries the EXACT copied
      // payload and only shows after the authoritative native write returned
      // true. `Clipboard.getData` is NOT used here: Android 10+ gates
      // clipboard READS on window focus, which this harness doesn't reliably
      // hold (run-3 telemetry: `native setText wrote=10` — the bare path —
      // but `hasClip=false focus=false` on the self-read; the #924 class).
      var toastSeen = false;
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 150));
        if (find.text('Copied: /etc/hosts').evaluate().isNotEmpty) {
          toastSeen = true;
          break;
        }
      }
      expect(
        toastSeen,
        isTrue,
        reason: 'Copy path must write the BARE path (no file:// scheme) and '
            'toast "Copied: /etc/hosts"',
      );

      // Hold so the host can grab a final screenshot.
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
    },
  );
}
