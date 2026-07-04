// golden_flow_tui_test.dart — THE canonical end-to-end flow gate (owner
// directive 2026-07-01): session creation → connect → tmux (mouse on) → run a
// TUI → detection → scroll → gutter copy, over a REAL SSH → shell → flterm
// chain. This flow is the daily driver and it has broken "in new ways" across
// +90..+98; this test pins every link at once so a regression in any of them
// is one red run, not a device bug report.
//
// What it asserts that no other test does:
//   1. A TUI-SHAPED screen (box-drawing, forced 2-space margins, hard-wrapped
//      URL — painted by test-sshd's `fake-tui`, mirroring Claude Code in tmux),
//      not plain `echo` output.
//   2. DETECTION RENDERS: not just `controller.anchors` (data — the existing
//      url-detection test) but the actual right-edge `gutter-mark-*` WIDGET
//      (render). #958 shipped because no test asserted the mark itself.
//   3. COPY IS VERBATIM: interior spaces survive (`TUI_007 alpha beta gamma
//      delta`, the +98 blank-cell-collapse class), and a scrolled-up copy
//      yields the VISIBLE lines, not the live tail (#962 class).
//   4. The gutter gesture contract itself: LONG-PRESS (≥500ms) then drag — if
//      the gesture model changes again, this goes red instead of the owner's
//      thumb finding out.
//
// Run: scripts/native-connect-test.sh integration_test/golden_flow_tui_test.dart
// (or as part of scripts/terminal-flow-gate.sh / the #589 full suite).

import 'dart:convert';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/services/clipboard.dart' show clipboardChannel;
import 'package:mobissh/state/detection_providers.dart' show kDetectionDisabled971;
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'golden flow: connect → tmux → TUI → detection renders → scroll → verbatim gutter copy',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        clipboardChannel,
        (call) async {
          if (call.method == 'setText') {
            copied = (call.arguments as Map)['text'] as String?;
            return true;
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          clipboardChannel,
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

      // ── 1. SESSION CREATION + CONNECT (the #539-class link) ──────────────
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
      String seen() => utf8.decode(out, allowMalformed: true);
      for (var i = 0; i < 40 && out.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(out.isNotEmpty, isTrue, reason: 'dead PTY — no shell output');

      void send(String cmd) {
        entry.proxy.sendInput(Uint8List.fromList(utf8.encode(cmd)));
      }

      // ── 2. TMUX (mouse on, alt screen — the owner environment) ───────────
      send('tmux kill-server 2>/dev/null; tmux set -g mouse on \\; new -s g\n');
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (controller.mouseTracking != MouseTracking.none) break;
      }
      expect(
        controller.mouseTracking,
        isNot(MouseTracking.none),
        reason: 'tmux mouse mode never engaged',
      );
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      send('tmux set -g status off\n');
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      // ── 3. RUN THE TUI (short stream, exit to prompt: hold=0) ────────────
      // Header (~16 rows incl. box + margins + URL) + 6 stream lines + DONE:
      // the hard-wrapped Docs URL is still ON the visible screen when it ends.
      send('fake-tui 6 0.1 0\n');
      var tuiDone = false;
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (seen().contains('TUI_DONE')) {
          tuiDone = true;
          break;
        }
      }
      expect(tuiDone, isTrue, reason: 'fake-tui never completed — fixture missing from test-sshd image?');
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }

      // ── 4. DETECTION: anchors (data) AND the gutter mark (render) ────────
      final gutterMark = find.byWidgetPredicate((w) {
        final k = w.key;
        return k is ValueKey<String> && k.value.startsWith('gutter-mark-');
      });
      if (kDetectionDisabled971) {
        // #971: detection is force-disabled by the kill switch — no pattern is
        // registered, so there are NO anchors and NO gutter mark. Assert it
        // stays OFF (the detect-renders asserts below can't pass while killed).
        // When the const flips back to false the full assertions return.
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(controller.anchors, isEmpty,
            reason: '#971 kill switch: detection must register nothing');
        expect(gutterMark, findsNothing,
            reason: '#971 kill switch: no gutter mark should mount');
      } else {
        var urlAnchored = false;
        for (var i = 0; i < 30; i++) {
          urlAnchored = controller.anchors.any(
            (a) => '${a.payload}'.contains('docs.example.com'),
          );
          if (urlAnchored) break;
          await tester.pump(const Duration(milliseconds: 300));
        }
        for (final a in controller.anchors) {
          debugPrint('GOLDEN anchor: "${a.payload}"');
          for (final r in a.ranges) {
            debugPrint(
              'GOLDEN   range rows=${r.topRow}..${r.bottomRow} '
              '→ gutterRow=${controller.anchorGutterRow(r)}',
            );
          }
        }
        debugPrint(
          'GOLDEN layer inputs: isScrolling=${controller.isScrolling} '
          'scrollbar(offset=${controller.scrollbar.offset} '
          'visible=${controller.scrollbar.visible} '
          'total=${controller.scrollbar.total}) '
          'painted=${controller.paintedViewportOffset}',
        );
        expect(
          urlAnchored,
          isTrue,
          reason: 'the on-screen Docs URL was never detected (no anchor)',
        );
        // The #958 assertion: the RIGHT-EDGE MARK actually renders. Anchors
        // existing while no mark mounts is exactly the device bug class.
        var markVisible = false;
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 300));
          if (gutterMark.evaluate().isNotEmpty) {
            markVisible = true;
            break;
          }
        }
        expect(
          markVisible,
          isTrue,
          reason:
              'URL anchor exists but NO gutter-mark widget rendered — the #958 '
              'class (anchor→viewport-row resolution or mark mounting broken)',
        );
      }

      // ── 5. BULK OUTPUT → SCROLL UP → VERBATIM GUTTER COPY ────────────────
      // 200 distinct lines WITH INTERIOR SPACES (the +98 class needs them).
      send('i=1; while [ \$i -le 200 ]; do echo "SCROLL_\$i aa bb cc"; i=\$((i+1)); done\n');
      var tailSeen = false;
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (seen().contains('SCROLL_200 aa bb cc')) {
          tailSeen = true;
          break;
        }
      }
      expect(tailSeen, isTrue, reason: 'bulk scroll lines never echoed');
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      final termFinder = find.byKey(Key('ghostty-terminal-$sessionId'));
      expect(termFinder, findsOneWidget);
      final rect = tester.getRect(termFinder);

      // Swipe-scroll up several pages (tmux copy-mode via wheel SGR).
      final bodyX = rect.left + rect.width * 0.35;
      for (var s = 0; s < 8; s++) {
        final g = await tester.startGesture(
          Offset(bodyX, rect.top + rect.height * 0.30),
        );
        for (var i = 1; i <= 6; i++) {
          await g.moveTo(
            Offset(bodyX, rect.top + rect.height * (0.30 + 0.09 * i)),
          );
          await tester.pump(const Duration(milliseconds: 12));
        }
        await g.up();
        await tester.pump(const Duration(milliseconds: 30));
      }
      await tester.pump(const Duration(milliseconds: 500));

      // Gutter LONG-PRESS (≥500ms hold, the +94 gesture contract) then drag a
      // TALL band (~half the screen). WHERE the tmux copy-mode scroll lands is
      // not deterministic across tmux versions/wheel step sizes, so the copy
      // asserts are LOCATION-TOLERANT: any half-screen band of this session
      // contains at least one known space-bearing line (TUI stream, SCROLL bulk,
      // or the margined bullet text) — enough to prove verbatim interior spaces
      // without assuming which region is visible.
      final gx = rect.right - 14;
      final gy = rect.top + rect.height * 0.25;
      final gg = await tester.startGesture(Offset(gx, gy));
      await tester.pump(const Duration(milliseconds: 700));
      for (var i = 1; i <= 10; i++) {
        await gg.moveTo(Offset(gx, gy + rect.height * 0.05 * i));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gg.up();
      await tester.pump(const Duration(milliseconds: 200));

      debugPrint('GOLDEN copied="$copied"');
      expect(copied, isNotNull, reason: 'gutter copy wrote nothing');
      // VERBATIM (+98 class): a full known line survives with its interior
      // spaces intact, whichever region the scroll landed on.
      final verbatimSpaced = RegExp(r'TUI_\d{3} alpha beta gamma delta')
              .hasMatch(copied!) ||
          RegExp(r'SCROLL_\d+ aa bb cc').hasMatch(copied!) ||
          copied!.contains('reader-only so exposure stays');
      expect(
        verbatimSpaced,
        isTrue,
        reason:
            'no known line survived with interior spaces — the +98 '
            'blank-cell-collapse class (or the band landed on no known '
            'content). copied="$copied"',
      );
      // VISIBLE-not-tail (#962 class): we scrolled far up.
      expect(
        copied!.contains('SCROLL_200') || copied!.contains('SCROLL_199'),
        isFalse,
        reason:
            'gutter copy returned the live TAIL while scrolled up (#962 '
            'class). copied="$copied"',
      );
    },
  );
}
