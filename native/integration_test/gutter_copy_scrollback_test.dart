// On-emulator reproduction of the P0 copy bug (#962): a gutter line-copy made
// while SCROLLED UP must yield the VISIBLE lines — not the live tail.
//
// Device saga: three builds (+90 painted-offset, +91 scrollbar-offset, +92
// instrumented) all copied the wrong region ("something totally not visible")
// when the user had scrolled back into scrollback. The suspicion is that, after
// a SWIPE-scroll, the offset used to map a viewport row → absolute buffer row
// does not reflect what's painted, so the copy reads the bottom of the buffer.
//
// This drives the EXACT flow over a real SSH→shell→flterm chain:
//   1. print 300 uniquely-numbered lines (L1_zz .. L300_zz) → scrollback,
//   2. SWIPE-scroll up to near the top (low-numbered lines visible, tail off),
//   3. gutter-drag the right strip to select a few visible rows,
//   4. read the clipboard and assert it is the LOW-numbered visible lines and
//      NOT the tail (L300_zz/L299_zz).
//
// It also debugPrints the candidate offsets + what each would copy, so the run
// itself tells us which offset matches the visible screen (the fix).
//
// Run: scripts/native-connect-test.sh integration_test/gutter_copy_scrollback_test.dart

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
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'gutter copy while scrolled up yields the VISIBLE lines, not the tail (#962)',
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
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          if (call.method == 'Clipboard.getData') {
            return <String, dynamic>{'text': copied ?? ''};
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          clipboardChannel,
          null,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
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
      expect(out.isNotEmpty, isTrue, reason: 'dead PTY — no shell prompt');

      // Fill the MAIN-screen scrollback with DISTINCT markers FIRST, so that if
      // the gutter copy mistakenly reads the main screen (instead of the active
      // alt screen tmux/Claude-Code paints), we SEE main markers in the clip —
      // the owner's "copied something totally not visible". (Both screens held
      // identical echoes before, hiding which one was read.)
      entry.proxy.sendInput(
        Uint8List.fromList(
          utf8.encode(
            "clear; for i in \$(seq 1 300); do echo \"MAIN\${i}_xx\"; done\n",
          ),
        ),
      );
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        if (utf8.decode(out, allowMalformed: true).contains('MAIN300_xx')) break;
      }
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }

      // Reproduce the OWNER's environment: tmux with mouse ON (the "Home-IT"
      // tab). tmux drives the ALTERNATE screen + its own scrollback/copy-mode —
      // a different scroll model than plain-shell scrollback (which the emulator
      // already proved copies correctly). status OFF so its ~1s clock redraw
      // doesn't race the scroll.
      entry.proxy.sendInput(
        Uint8List.fromList(
          utf8.encode(
            'tmux kill-server 2>/dev/null; tmux set -g mouse on \\; new -s s\n',
          ),
        ),
      );
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (controller.mouseTracking != MouseTracking.none) break;
      }
      expect(
        controller.mouseTracking,
        isNot(MouseTracking.none),
        reason: 'tmux mouse mode never engaged — not the owner environment',
      );
      // Let the tmux shell come up + settle before driving it.
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      // Status bar OFF (separate command, mirrors the #828 test) so its ~1s clock
      // redraw doesn't race the scroll.
      entry.proxy.sendInput(
        Uint8List.fromList(utf8.encode('tmux set -g status off\n')),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      // 300 DISTINCT alt-screen lines INSIDE tmux (ALTn_yy) → the visible alt
      // screen; tmux scrollback several screens tall, tail ALT300_yy at bottom.
      entry.proxy.sendInput(
        Uint8List.fromList(
          utf8.encode(
            "clear; for i in \$(seq 1 300); do echo \"ALT\${i}_yy\"; done\n",
          ),
        ),
      );
      var tailSeen = false;
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 300));
        if (utf8.decode(out, allowMalformed: true).contains('ALT300_yy')) {
          tailSeen = true;
          break;
        }
      }
      expect(tailSeen, isTrue, reason: 'the alt-screen marker lines never echoed');
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      final termFinder = find.byKey(Key('ghostty-terminal-$sessionId'));
      expect(termFinder, findsOneWidget, reason: 'no ghostty terminal view');
      final rect = tester.getRect(termFinder);

      String topAt(int off) {
        final t = controller.textForRows(0 + off, 2 + off);
        final line = t.split('\n').firstWhere(
              (l) => l.trim().isNotEmpty,
              orElse: () => '',
            );
        return line.length > 40 ? line.substring(0, 40) : line;
      }

      // SWIPE-scroll up a FEW pages (land MID-buffer, not pinned at the top), so
      // the painted offset is non-zero and any post-scroll LAG is visible.
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

      // IMMEDIATE (one frame) — the "just scrolled" window the owner copies in.
      await tester.pump(const Duration(milliseconds: 16));
      final oPaintNow = controller.paintedViewportOffset;
      debugPrint(
        'GUTTER962 IMMEDIATE: oPaint=$oPaintNow oScroll=${controller.scrollbar.offset} '
        'isScrolling=${controller.isScrolling} top="${topAt(oPaintNow)}"',
      );

      // Gutter-drag + copy RIGHT NOW (minimal settle) — reproduce the timing.
      final gx = rect.right - 14;
      final gy = rect.top + rect.height * 0.4;
      final gg = await tester.startGesture(Offset(gx, gy));
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 1; i <= 6; i++) {
        await gg.moveTo(Offset(gx, gy + 8.0 * i));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gg.up();
      await tester.pump(const Duration(milliseconds: 120));
      final copiedImmediate = copied;
      debugPrint('GUTTER962 copied(immediate)="$copiedImmediate"');

      // Now SETTLE fully and read the ground-truth offset/top. If the immediate
      // paint offset LAGGED, oPaint changes here and the immediate copy was off.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      final oPaintSettled = controller.paintedViewportOffset;
      debugPrint(
        'GUTTER962 SETTLED: oPaint=$oPaintSettled top="${topAt(oPaintSettled)}" '
        '(immediate oPaint was $oPaintNow)',
      );
      copied = copiedImmediate;
      debugPrint('GUTTER962 copied="$copied"');

      expect(
        copied,
        isNotNull,
        reason: 'gutter copy wrote nothing to the clipboard',
      );
      // The copy must read the ALT screen (what tmux paints / is visible) — NOT
      // the MAIN-screen scrollback (the owner's "totally not visible" content).
      expect(
        copied!.contains('MAIN'),
        isFalse,
        reason:
            'gutter copy read the MAIN-screen scrollback while the alt screen is '
            'active — the #962 wrong-screen bug. copied="$copied"',
      );
      expect(
        copied!.contains('ALT'),
        isTrue,
        reason:
            'gutter copy did not read the visible alt-screen lines — copied="$copied"',
      );
      // …and not the alt-screen TAIL (we scrolled far up).
      expect(
        copied!.contains('ALT300_yy') || copied!.contains('ALT299_yy'),
        isFalse,
        reason:
            'gutter copy returned the alt-screen TAIL while scrolled up (#962). '
            'copied="$copied"',
      );
    },
  );
}
