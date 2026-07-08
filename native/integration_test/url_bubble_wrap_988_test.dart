// On-emulator acceptance for #988 — the restored inline URL BUBBLE + single-tap
// copy, wrap-aware, on the post-#985 painted-offset geometry.
//
// Device-class behaviour a headless test cannot cover: a REAL ~200-char URL
// soft-wrapped by the live libghostty grid (authoritative rowWrap flags, real
// cell metrics, real scroll offsets), the bubble layer painting over it, a real
// tap routed through the gesture router at a bubble rect, and the system
// clipboard receiving the EXACT wrap-joined URL. Then the #930 regression
// guard: stream output to scroll the URL away (bubble must be HIDDEN or
// aligned — never misaligned), scroll back, and tap-copy again at the freshly
// resolved bubble rect: if the bubble/hit geometry drifted, the tap misses and
// the clipboard keeps its sentinel.
//
// The URL is delivered via base64 so the typed COMMAND ECHO never contains the
// URL text — exactly ONE detected anchor carries the payload.
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
// Run: scripts/native-connect-test.sh integration_test/url_bubble_wrap_988_test.dart

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
    'a wrapped ~200-char URL bubbles across its rows, a single tap copies it '
    'exactly, and the bubble never drifts across a scroll (#988)',
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

      // A ~200-char no-whitespace URL: on any sane emulator grid width it
      // soft-wraps across >= 3 rows (authoritative rowWrap flags). The length
      // is PRIME (197) so NO grid width can leave the last row flush with the
      // right edge — a flush last row triggers the scanner's width-join
      // fallback onto the next (prompt) line and corrupts the payload.
      final url = 'https://example.com/${'b' * 177}';
      expect(url.length, 197);
      // Deliver via base64 so the typed command echo never contains the URL —
      // exactly ONE anchor will carry the payload. The encoded text INCLUDES
      // the trailing newline: without it the shell prompt prints on the SAME
      // row as the URL tail and the regex swallows it into the payload.
      final b64 = base64Encode(utf8.encode('$url\n'));
      entry.proxy.sendInput(
        Uint8List.fromList(utf8.encode('echo $b64 | base64 -d\n')),
      );

      // Wait until the in-terminal scanner detects the FULL wrap-joined URL.
      StructuredAnchor? anchorOf() {
        for (final a in controller!.anchors) {
          if (a.payload == url) return a;
        }
        return null;
      }

      for (var i = 0; i < 60 && anchorOf() == null; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      final found = [
        for (final a in controller!.anchors)
          if (a.patternId == 'url') '${a.payload}'.length,
      ];
      expect(
        anchorOf(),
        isNotNull,
        reason:
            'the wrapped URL was never detected with its FULL payload — '
            'url anchor payload lengths found: $found',
      );

      // The anchor spans the wrapped rows: one per-row range each (#925).
      var anchor = anchorOf()!;
      expect(
        anchor.ranges.length,
        greaterThanOrEqualTo(3),
        reason: 'a 200-char URL must wrap across >= 3 rows',
      );

      // Wait for the scroll-settle so the bubble layer is SHOWN, then assert
      // the bubble paint exists and its geometry spans ALL wrapped rows.
      Finder bubble() => find.byKey(const Key('ghostty-bubble-paint'));
      for (var i = 0;
          i < 30 && (controller.isScrolling || bubble().evaluate().isEmpty);
          i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(
        bubble(),
        findsOneWidget,
        reason: 'the bubble layer never painted for the detected anchor',
      );

      List<Rect> bubbleRects() => [
        for (final range in anchorOf()!.ranges)
          ...controller.anchorRects(range),
      ];
      var rects = bubbleRects();
      expect(
        rects.length,
        anchor.ranges.length,
        reason: 'one on-screen rect per wrapped row (all rows visible)',
      );
      for (var i = 1; i < rects.length; i++) {
        expect(
          rects[i].top,
          greaterThan(rects[i - 1].top),
          reason: 'per-row rects stack top-to-bottom (one per wrapped row)',
        );
      }

      // Hold with the bubble on screen (~20s) so the host can screenshot it.
      debugPrint('BUBBLE_HOLD_988 bubble visible, rows=${rects.length} '
          '(screenshot now)');
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      // Single TAP on a CONTINUATION-row bubble segment copies the EXACT URL.
      // Seed the clipboard with a sentinel so a missed tap is detectable.
      await Clipboard.setData(const ClipboardData(text: 'SEED-988-A'));
      final viewOrigin = tester.getTopLeft(find.byType(TerminalView));
      rects = bubbleRects();
      final tapLocal = rects[1].center;
      await tester.tapAt(viewOrigin + tapLocal);
      String? clip;
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 300));
        clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
        if (clip == url) break;
      }
      expect(
        clip,
        url,
        reason:
            'a single tap on the continuation-row bubble must copy the EXACT '
            'wrap-joined URL (no injected whitespace); clipboard: '
            '${clip == null ? 'null' : '${clip.length} chars'}',
      );

      // #930 regression guard, part 1: stream a screenful+ so the URL scrolls
      // into scrollback. Mid-stream the bubble must be HIDDEN whenever the
      // controller reports scrolling (hidden is acceptable — misaligned is
      // not), and once the anchor is fully off-screen the bubble paints
      // NOTHING (no stale outline over unrelated text).
      entry.proxy.sendInput(Uint8List.fromList(utf8.encode('seq 1 200\n')));
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (!controller.isScrolling) continue;
        // The hide is driven by the controller's POST-FRAME decoration notify
        // (#812 rising edge): isScrolling flips during the paint that moved
        // the offset, and the layer rebuilds one frame later. Grant exactly
        // that frame, then (still scrolling) the bubble MUST be gone.
        await tester.pump();
        if (!controller.isScrolling) continue; // settled in the meantime
        expect(
          bubble(),
          findsNothing,
          reason: 'mid-scroll the bubble must hide, never drift (#930)',
        );
      }
      expect(
        anchorOf(),
        isNotNull,
        reason: 'the URL anchor vanished from the scanned window (#767)',
      );
      expect(
        bubbleRects(),
        isEmpty,
        reason: 'the URL is in scrollback — no on-screen rects expected',
      );
      expect(
        bubble(),
        findsNothing,
        reason: 'no stale bubble may remain once its anchor is off-screen',
      );

      // Part 2: scroll BACK to the URL and prove paint+hit still agree — the
      // freshly resolved bubble rect is tappable and copies the exact URL. A
      // drifted bubble would put the rect off the glyphs and the tap would
      // miss (clipboard keeps the sentinel).
      controller.scrollToTop();
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 300));
        if (!controller.isScrolling && bubbleRects().isNotEmpty) break;
      }
      anchor = anchorOf()!;
      rects = bubbleRects();
      expect(
        rects,
        isNotEmpty,
        reason: 'after scrolling back the anchor must resolve on-screen rects',
      );
      expect(
        bubble(),
        findsOneWidget,
        reason: 'the bubble must re-show on scroll settle',
      );

      // Up to 3 attempts, each RE-RESOLVING the rect first: the earlier tap
      // focused the terminal, so a soft-keyboard inset animation can still be
      // shifting rows between resolve and tap. Re-resolving absorbs that
      // transient; a genuinely DRIFTED bubble (rect off its glyphs) fails all
      // attempts because the rect itself points at the wrong cells.
      clip = null;
      for (var attempt = 0; attempt < 3 && clip != url; attempt++) {
        await Clipboard.setData(const ClipboardData(text: 'SEED-988-B'));
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 300));
          if (!controller.isScrolling && bubbleRects().isNotEmpty) break;
        }
        final fresh = bubbleRects();
        if (fresh.isEmpty) continue;
        await tester.tapAt(viewOrigin + fresh.first.center);
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 300));
          clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
          if (clip == url) break;
        }
      }
      expect(
        clip,
        url,
        reason:
            'after a scroll round-trip the tap at the re-resolved bubble rect '
            'must still copy the exact URL — a miss means the bubble drifted '
            'off its glyphs (#930); clipboard: '
            '${clip == null ? 'null' : '${clip.length} chars'}',
      );
    },
  );
}
