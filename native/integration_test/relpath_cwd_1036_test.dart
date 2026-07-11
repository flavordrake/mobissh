// On-emulator acceptance for #1036 — RELATIVE paths detected via per-session
// cwd tracking, VERIFICATION-GATED visibility.
//
// Flow (test-sshd):
//   1. Prepare /tmp/relpath1036/sub/real.txt, `cd` into /tmp/relpath1036 and
//      advertise the cwd (OSC 7 printf + a strong `user@host:$PWD$` PS1 — the
//      tracker's ladder accepts either).
//   2. Echo `sub/real.txt` (delivered base64 so the typed command echo never
//      contains the token) → a `relpath` anchor appears, the tracker's cwd is
//      /tmp/relpath1036, and the verifier confirms the RESOLVED
//      /tmp/relpath1036/sub/real.txt → the anchor is verified (visible).
//   3. Echo `no/such.txt` → anchored at the shape level but its resolved path
//      stats MISSING → never verified (never visible). This is the design:
//      shape-level recall is broad; the stat is the precision gate.
//   4. `cd /tmp` and re-echo `sub/real.txt` → the tracker follows the cwd and
//      the NEW resolved key /tmp/sub/real.txt stats missing (cwd tracked).
//   5. `cd` back, single TAP on the verified anchor → the file browser opens
//      at the RESOLVED parent dir /tmp/relpath1036/sub with real.txt listed;
//      the clipboard is untouched (#999 navigate semantics on the resolved
//      path). Hold for the screenshot.
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
// Run: scripts/native-connect-test.sh integration_test/relpath_cwd_1036_test.dart

import 'dart:convert';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/services/path_verifier.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a relative path verifies against the tracked cwd, a fake one never '
    'shows, a cd re-resolves, and a tap opens the browser at the resolved '
    'dir (#1036)',
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

      // Let the first-connect resize storm settle before echoing.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      void send(String line) {
        entry.proxy.sendInput(Uint8List.fromList(utf8.encode('$line\n')));
      }

      Future<void> settle([int ticks = 4]) async {
        for (var i = 0; i < ticks; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
      }

      // 1. Prepare the fixture dir, cd into it, advertise the cwd through BOTH
      // ladder sources: an OSC 7 printf (file://host$PWD) and a strong
      // `user@host:$PWD$ ` PS1 (ash expands PS1 variables at display time).
      // The tracker accepts whichever the terminal surfaces.
      const dir = '/tmp/relpath1036';
      send('mkdir -p $dir/sub; touch $dir/sub/real.txt');
      await settle();
      send(r"export PS1='testuser@relhost:$PWD$ '");
      await settle();
      send('cd $dir');
      await settle();
      send(r"printf '\033]7;file://t%s\033\\' " '"\$PWD"; echo cwdset');
      await settle();

      // 2. Deliver the RELATIVE tokens via base64 variables (the typed command
      // echo must never contain the token — exactly one anchor per echo; the
      // short `echo "$v"` row also stays clear of the inferred-wrap-col
      // heuristic, see path_tap_navigate_999_test).
      const realRel = 'sub/real.txt';
      const fakeRel = 'no/such.txt';
      final realB64 = base64Encode(utf8.encode('$realRel\n'));
      final fakeB64 = base64Encode(utf8.encode('$fakeRel\n'));
      send('v=\$(echo $realB64 | base64 -d)');
      await settle();
      send('echo "\$v"');

      // The scanner must anchor the relative token under the relpath id.
      StructuredAnchor? relAnchorOf(String payload) {
        StructuredAnchor? last;
        for (final a in controller!.anchors) {
          if (a.patternId == 'relpath' && '${a.payload}' == payload) last = a;
        }
        return last;
      }

      for (var i = 0; i < 60 && relAnchorOf(realRel) == null; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      final anchorDump = [
        for (final a in controller!.anchors) '${a.patternId}:"${a.payload}"',
      ];
      final visibleDump = controller
          .visibleRowsText(0, controller.scrollbar.visible - 1)
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .join(' | ');
      expect(
        relAnchorOf(realRel),
        isNotNull,
        reason: 'the echoed $realRel was never detected as a relpath anchor — '
            'anchors: $anchorDump; visible rows: "$visibleDump"',
      );

      // The cwd tracker must have followed the cd (OSC 7 or prompt ladder;
      // the refresh runs on the same decoration notify that noted the anchor).
      final tracker = GhosttyTerminalView.debugCwdTrackers[sessionId];
      expect(tracker, isNotNull, reason: 'no cwd tracker for session');
      var cwdTracked = false;
      for (var i = 0; i < 40 && !cwdTracked; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        cwdTracked = tracker!.cwd == dir;
      }
      expect(
        cwdTracked,
        isTrue,
        reason: 'cwd ladder never tracked the cd — tracker.cwd="${tracker!.cwd}" '
            '(expected $dir); controller.pwd="${controller.pwd}"',
      );

      // The verifier confirms the RESOLVED absolute → the anchor is verified.
      final verifier = GhosttyTerminalView.debugPathVerifiers[sessionId];
      expect(verifier, isNotNull, reason: 'no path verifier for session');
      const resolvedReal = '$dir/sub/real.txt';
      var realVerified = false;
      for (var i = 0; i < 40 && !realVerified; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        realVerified = verifier!.isVerified(resolvedReal);
      }
      expect(
        realVerified,
        isTrue,
        reason: '$resolvedReal exists on test-sshd — the relative anchor must '
            'verify (and only then become visible)',
      );

      // 3. A FAKE relative token: anchored at the shape level, but its
      // resolved path stats MISSING → never verified, never visible.
      send('w=\$(echo $fakeB64 | base64 -d)');
      await settle();
      send('echo "\$w"');
      for (var i = 0; i < 60 && relAnchorOf(fakeRel) == null; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(
        relAnchorOf(fakeRel),
        isNotNull,
        reason: 'shape-level recall is broad by design — $fakeRel must anchor '
            '(the verifier, not the shape, hides it)',
      );
      const resolvedFake = '$dir/no/such.txt';
      var fakeResolvedMissing = false;
      for (var i = 0; i < 40 && !fakeResolvedMissing; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        fakeResolvedMissing =
            verifier!.status(resolvedFake) == PathVerification.missing;
      }
      expect(
        fakeResolvedMissing,
        isTrue,
        reason: '$resolvedFake must stat MISSING so the anchor stays hidden',
      );
      expect(verifier!.isVerified(resolvedFake), isFalse);

      // 4. cd ELSEWHERE and re-echo the real token: the tracker follows, the
      // new resolved key /tmp/sub/real.txt stats missing (cwd is tracked, not
      // frozen at first sight).
      send('cd /tmp');
      await settle();
      send(r"printf '\033]7;file://t%s\033\\' " '"\$PWD"; echo cwdset2');
      await settle();
      send('echo "\$v"');
      var movedTracked = false;
      for (var i = 0; i < 40 && !movedTracked; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        movedTracked = tracker.cwd == '/tmp';
      }
      expect(
        movedTracked,
        isTrue,
        reason: 'cwd ladder never tracked the second cd — '
            'tracker.cwd="${tracker.cwd}"',
      );
      var movedMissing = false;
      for (var i = 0; i < 40 && !movedMissing; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        movedMissing =
            verifier.status('/tmp/sub/real.txt') == PathVerification.missing;
      }
      expect(
        movedMissing,
        isTrue,
        reason: 'after cd /tmp the re-resolved /tmp/sub/real.txt must stat '
            'MISSING — the anchor must not show against the stale cwd',
      );

      // 5. cd BACK, re-echo, and TAP the verified anchor: the browser opens
      // at the RESOLVED parent dir; the clipboard stays untouched.
      send('cd $dir');
      await settle();
      send(r"printf '\033]7;file://t%s\033\\' " '"\$PWD"; echo cwdset3');
      await settle();
      send('echo "\$v"');
      var backTracked = false;
      for (var i = 0; i < 40 && !backTracked; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        backTracked = tracker.cwd == dir && verifier.isVerified(resolvedReal);
      }
      expect(
        backTracked,
        isTrue,
        reason: 'cwd never tracked back to $dir with the anchor verified — '
            'tracker.cwd="${tracker.cwd}"',
      );

      List<Rect> anchorRects() => [
        for (final range in relAnchorOf(realRel)!.ranges)
          ...controller.anchorRects(range),
      ];
      for (var i = 0;
          i < 30 && (controller.isScrolling || anchorRects().isEmpty);
          i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      final rects = anchorRects();
      expect(rects, isNotEmpty, reason: 'no on-screen rect for the anchor');

      // Hold BEFORE the tap so the host can screenshot the VERIFIED relative
      // anchor (wash + gutter chip) on the terminal itself.
      debugPrint('RELPATH1036_ANCHOR_WINDOW_OPEN');
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      debugPrint('RELPATH1036_ANCHOR_WINDOW_CLOSED');

      const sentinel = 'SEED-1036-NAVIGATE';
      await Clipboard.setData(const ClipboardData(text: sentinel));

      final viewOrigin = tester.getTopLeft(find.byType(TerminalView));
      await tester.tapAt(viewOrigin + rects.first.center);

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
        reason: 'the relpath tap never opened the file browser',
      );
      final pathText = tester.widget<Text>(
        find.byKey(const Key('file-browser-path')),
      );
      expect(
        pathText.data,
        '$dir/sub',
        reason: 'a relpath tap must navigate to the RESOLVED parent dir',
      );

      var listMounted = false;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byKey(const Key('file-browser-list')).evaluate().isNotEmpty) {
          listMounted = true;
          break;
        }
      }
      expect(listMounted, isTrue, reason: 'the $dir/sub listing never rendered');
      expect(
        find.text('real.txt'),
        findsWidgets,
        reason: 'the resolved dir listing never showed real.txt',
      );

      final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      expect(
        clip,
        sentinel,
        reason: 'a relpath tap must navigate, not copy; clipboard changed',
      );

      // Hold for the external emu-shot (verified relative anchor + browser).
      debugPrint('RELPATH1036_SHOT_WINDOW_OPEN');
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      debugPrint('RELPATH1036_SHOT_WINDOW_CLOSED');
    },
  );
}
