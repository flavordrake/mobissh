// On-emulator check for #993: gutter chips must TRACK their line while the
// user scrolls — never sit pinned to a fixed viewport row while the text moves
// under them.
//
// Flow (real SSH → shell → flterm chain):
//   1. connect to test-sshd, print one URL line (VISIT993 …/track993),
//   2. `seq 200` → the URL line scrolls ~200 rows up into scrollback,
//   3. SWIPE-scroll back up in steps; at every sampled frame assert that every
//      RENDERED gutter mark row is one the controller itself resolves for a
//      live anchor at the current (or immediately previous — one-frame notify
//      lag) painted offset. A mark at any other row = pinned to a wrong line.
//   4. assert the URL's mark was observed at >= 2 DISTINCT viewport rows while
//      scrolling (it tracked), and at least one sample was mid-scroll
//      (isScrolling) with marks visible (tracking, not hide-on-scroll),
//   5. settle and assert the mark sits exactly on the re-resolved row.
//
// Screenshot windows (the orchestrator runs `scripts/emu-shot.sh` during each
// hold and reviews the PNGs): GUTTER993_MIDSCROLL_WINDOW_OPEN (slow continuous
// oscillating scroll — chips must ride their lines) and
// GUTTER993_SETTLED_WINDOW_OPEN (stationary, chips on the correct lines).
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
// Run: scripts/native-connect-test.sh integration_test/gutter_track_scroll_993_test.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import 'support/connect_helpers.dart';

const _url = 'https://example.com/track993';

/// The viewport rows the gutter is CURRENTLY rendering a mark on (parsed from
/// the `gutter-mark-<row>` keys).
Set<int> _renderedRows(WidgetTester tester) {
  final rows = <int>{};
  final marks = find.byWidgetPredicate((w) {
    final k = w.key;
    return k is ValueKey<String> && k.value.startsWith('gutter-mark-');
  });
  for (final e in marks.evaluate()) {
    final v = (e.widget.key! as ValueKey<String>).value;
    final row = int.tryParse(v.substring('gutter-mark-'.length));
    if (row != null) rows.add(row);
  }
  return rows;
}

/// The rows the controller resolves for every live anchor at the CURRENT
/// painted offset — the ground truth a rendered mark must belong to.
Set<int> _expectedRows(TerminalController c) {
  final rows = <int>{};
  for (final a in c.anchors) {
    for (final r in a.ranges) {
      final row = c.anchorGutterRow(r);
      if (row != null) {
        rows.add(row);
        break;
      }
    }
  }
  return rows;
}

/// The URL anchor's current viewport row (null when off-screen/undetected).
/// CONTAINS-match: the detector may capture trailing shell-line characters or
/// normalize the payload, so equality against the echoed URL is too strict.
int? _urlRow(TerminalController c) {
  for (final a in c.anchors) {
    if (!'${a.payload}'.contains('track993')) continue;
    for (final r in a.ranges) {
      final row = c.anchorGutterRow(r);
      if (row != null) return row;
    }
  }
  return null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'gutter chips track their line while scrolling — never pinned (#993)',
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

      TerminalController? ctrlOf() =>
          GhosttyTerminalView.debugControllers[sessionId];
      for (var i = 0; i < 40 && ctrlOf() == null; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      final maybeController = ctrlOf();
      expect(
        maybeController,
        isNotNull,
        reason: 'no ghostty controller for session',
      );
      final controller = maybeController!;

      // Wait for a live shell prompt.
      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      for (var i = 0; i < 40 && out.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(out.isNotEmpty, isTrue, reason: 'no shell prompt — dead PTY');

      // The URL line SANDWICHED mid-history (100 lines either side): scrolled
      // back to it, it can occupy ANY viewport row — required for observing the
      // mark at several distinct rows. (At the very top of the buffer it could
      // only ever render at row 0 — the run-6 dead end.)
      entry.proxy.sendInput(
        Uint8List.fromList(
          utf8.encode('clear; seq 100; echo VISIT993 $_url; seq 200\n'),
        ),
      );
      var tailSeen = false;
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (utf8.decode(out, allowMalformed: true).contains('\n200')) {
          tailSeen = true;
          break;
        }
      }
      expect(tailSeen, isTrue, reason: 'seq 200 output never arrived');
      // Let detection + paint settle at the tail. (The URL is now ~200 rows up
      // in scrollback — outside the bounded detection window, so its anchor may
      // have been evicted; scrolling back up re-detects it via the debounced
      // rescan once it re-enters the window.)
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }

      final termFinder = find.byKey(Key('ghostty-terminal-$sessionId'));
      expect(termFinder, findsOneWidget, reason: 'no ghostty terminal view');
      final rect = tester.getRect(termFinder);
      final bodyX = rect.left + rect.width * 0.35;

      // Sample ground truth vs rendered marks. Called only when the painted
      // offset is QUIESCENT (finger held still, or post-release micro-settle):
      // the decoration notify lands post-frame, so two pumps after the last
      // move guarantee the rendered marks reflect the current offset. The
      // PREVIOUS sample's expected rows stay legal as slack for a stray vsync.
      var prevExpected = _expectedRows(controller);
      final urlRowsSeenRendered = <int>{};
      var sawMarksMidScroll = false;
      Future<void> sample(String phase) async {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        final expected = _expectedRows(controller);
        final rendered = _renderedRows(tester);
        final legal = {...expected, ...prevExpected};
        final rogue = rendered.difference(legal);
        expect(
          rogue,
          isEmpty,
          reason: '[$phase] gutter mark(s) PINNED to wrong line(s) $rogue — '
              'rendered=$rendered expected=$expected prev=$prevExpected '
              'oPaint=${controller.paintedViewportOffset} '
              'isScrolling=${controller.isScrolling} (#993)',
        );
        final u = _urlRow(controller);
        if (u != null && rendered.contains(u)) urlRowsSeenRendered.add(u);
        if (controller.isScrolling && rendered.isNotEmpty) {
          sawMarksMidScroll = true;
        }
        prevExpected = expected;
      }

      // PHASE 1: swipe-scroll back up until the URL line re-enters the
      // detection window and its anchor resolves on-screen. Every step still
      // runs the pinned-mark subset assertion.
      var urlOnScreen = false;
      for (var s = 0; s < 30 && !urlOnScreen; s++) {
        final g = await tester.startGesture(
          Offset(bodyX, rect.top + rect.height * 0.30),
        );
        for (var i = 1; i <= 6; i++) {
          await g.moveTo(
            Offset(bodyX, rect.top + rect.height * (0.30 + 0.09 * i)),
          );
          await sample('swipe$s.move$i');
        }
        await g.up();
        // Post-release: let any fling coast + the debounced rescan (~120ms)
        // re-anchor before checking.
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 60));
        }
        await sample('swipe$s.up');
        urlOnScreen = _urlRow(controller) != null;
        debugPrint(
          'GUTTER993 swipe$s: oPaint=${controller.paintedViewportOffset} '
          'oScroll=${controller.scrollbar.offset} '
          'anchors=${controller.anchors.length} urlRow=${_urlRow(controller)} '
          'rendered=${_renderedRows(tester)} '
          'payloads=${[for (final a in controller.anchors) '${a.patternId}:${a.payload}']}',
        );
      }
      expect(
        urlOnScreen,
        isTrue,
        reason: 'never scrolled the VISIT993 URL line back on-screen / '
            're-detected — cannot assert tracking',
      );

      // PHASE 2: with the URL on-screen, HELD small drag steps: after each
      // move the finger stays down and the offset holds, but isScrolling stays
      // true for its 140ms settle window — the exact mid-scroll state. The URL
      // row must be observed RENDERED at several distinct rows.
      for (var s = 0; s < 6 && urlRowsSeenRendered.length < 3; s++) {
        final down = s.isEven; // alternate so the URL stays near mid-screen
        final startY = rect.top + rect.height * (down ? 0.30 : 0.70);
        final g = await tester.startGesture(Offset(bodyX, startY));
        for (var i = 1; i <= 5; i++) {
          final dy = rect.height * 0.06 * i * (down ? 1 : -1);
          await g.moveTo(Offset(bodyX, startY + dy));
          await sample('track$s.move$i');
        }
        await g.up();
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 60));
        }
        await sample('track$s.up');
      }

      debugPrint(
        'GUTTER993 scroll pass: urlRowsSeenRendered=$urlRowsSeenRendered '
        'sawMarksMidScroll=$sawMarksMidScroll '
        'oPaint=${controller.paintedViewportOffset}',
      );
      expect(
        sawMarksMidScroll,
        isTrue,
        reason: 'marks must stay VISIBLE and track mid-scroll (#993 tracking '
            'mode) — never rendered while isScrolling means hide-on-scroll',
      );
      expect(
        urlRowsSeenRendered.length,
        greaterThanOrEqualTo(2),
        reason: 'the URL mark must be observed at >=2 distinct viewport rows '
            'across the scroll (it TRACKS its line, #993) — saw '
            '$urlRowsSeenRendered',
      );

      // MID-SCROLL screenshot window: keep the content slowly oscillating so
      // the external emu-shot lands on an in-flight scroll with chips riding
      // their lines. Assertions keep running throughout.
      debugPrint('GUTTER993_MIDSCROLL_WINDOW_OPEN');
      for (var o = 0; o < 24; o++) {
        final down = o.isEven;
        final startY = rect.top + rect.height * (down ? 0.35 : 0.65);
        final g = await tester.startGesture(Offset(bodyX, startY));
        for (var i = 1; i <= 5; i++) {
          final dy = rect.height * 0.05 * i * (down ? 1 : -1);
          await g.moveTo(Offset(bodyX, startY + dy));
          await sample('osc$o.move$i');
        }
        await g.up();
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 60));
        }
        await sample('osc$o.rest');
      }
      debugPrint('GUTTER993_MIDSCROLL_WINDOW_CLOSED');

      // SETTLE: the marks must sit exactly on the re-resolved rows.
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(controller.isScrolling, isFalse, reason: 'never settled');
      final settledExpected = _expectedRows(controller);
      final settledRendered = _renderedRows(tester);
      final settledUrlRow = _urlRow(controller);
      debugPrint(
        'GUTTER993 settled: rendered=$settledRendered '
        'expected=$settledExpected urlRow=$settledUrlRow',
      );
      expect(
        settledRendered.difference(settledExpected),
        isEmpty,
        reason: 'settled marks must all sit on controller-resolved rows — '
            'rendered=$settledRendered expected=$settledExpected',
      );
      if (settledUrlRow != null) {
        expect(
          settledRendered,
          contains(settledUrlRow),
          reason: 'the on-screen URL line must carry its mark once settled',
        );
      }

      // SETTLED screenshot window.
      debugPrint('GUTTER993_SETTLED_WINDOW_OPEN');
      for (var i = 0; i < 48; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      debugPrint('GUTTER993_SETTLED_WINDOW_CLOSED');
    },
  );
}
