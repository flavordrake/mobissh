// On-emulator acceptance for #1067 (owner DEFINITIVE P0) — the detection WASH
// must STAY VISIBLE and TRACK its token every paint (scroll AND churn), with the
// glyphs ON TOP (undimmed). This SUPERSEDES the hide-on-scroll (#1062) / quiesce
// (#1064) / miss-grace (#1060) machinery that HID the wash.
//
// Drives a REAL SSH → shell → flterm chain against the live device paint stack.
// It prints a URL + a multi-segment path sandwiched mid-history, then:
//   * PHASE SCROLL — swipes them back on-screen and oscillates. Every frame the
//     painter must resolve the wash onto EXACTLY the on-screen anchor rows
//     (`renderBox.debugWashViewRows == { absRow - paintedOffset }`) — never a
//     hidden frame, never a stale band. Holds a MID-SCROLL window for an
//     external screenshot (wash on its moving token, text legible on top).
//   * PHASE CHURN — streams output continuously (a live TUI repaint) with a URL
//     in the stream. Same per-frame lockstep + never-hidden invariant. Holds a
//     MID-CHURN window for an external screenshot.
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
// Run: scripts/native-connect-test.sh integration_test/wash_live_tracking_1067_shot_test.dart
// Screenshots: fire scripts/emu-shot.sh while a *_WINDOW_OPEN marker is logged.

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
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import 'support/connect_helpers.dart';

const _url = 'https://example.com/track1067';
const _path = '/usr/local/lib/python3.11/site-packages';

/// The set of VIEWPORT rows every on-screen highlight range occupies at
/// [offset] — the LIVE-resolved rows the wash painter must have drawn this
/// frame (mirrors the painter's `absRow - offset` map + on-screen clip).
Set<int> _expectedWashViewRows(TerminalController c, int offset) {
  final visible = c.scrollbar.visible;
  final out = <int>{};
  for (final r in c.highlights) {
    for (var absRow = r.topRow; absRow <= r.bottomRow; absRow++) {
      final viewRow = absRow - offset;
      if (viewRow < 0 || viewRow >= visible) continue;
      out.add(viewRow);
    }
  }
  return out;
}

/// Every ON-SCREEN capsule wash cell-run that sits over cells NOT holding (part
/// of) its payload, at [offset]. Empty == every visible wash is on its glyphs.
List<String> _driftedWashes(TerminalController c, int offset) {
  final visible = c.scrollbar.visible;
  final out = <String>[];
  for (final r in c.highlights) {
    if (!r.capsule) continue;
    final payload = '${r.payload}';
    for (var absRow = r.topRow; absRow <= r.bottomRow; absRow++) {
      final viewRow = absRow - offset;
      if (viewRow < 0 || viewRow >= visible) continue;
      final rowText = c.visibleRowsText(viewRow, viewRow);
      final startCol = absRow == r.topRow ? r.topCol : 0;
      final endCol = absRow == r.bottomRow ? r.bottomCol : rowText.length;
      final s = startCol.clamp(0, rowText.length);
      final e = endCol.clamp(0, rowText.length);
      final slice = (e > s ? rowText.substring(s, e) : '').trim();
      final onGlyph = slice.isNotEmpty &&
          (payload.contains(slice) || slice.contains(payload));
      if (!onGlyph) out.add('view=$viewRow "$slice" payload=$payload');
    }
  }
  return out;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'the detection wash stays VISIBLE and tracks its token per-frame through '
    'scroll AND churn, text on top (#1067)',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(detectionSettingsProvider.notifier).setEnabled(true);

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
      expect(controller, isNotNull, reason: 'no ghostty controller for session');

      final termKey = find.byKey(Key('ghostty-terminal-$sessionId'));
      expect(termKey, findsOneWidget, reason: 'no ghostty terminal view');
      TerminalRenderBox renderBox() => tester.renderObject<TerminalRenderBox>(
            find.descendant(of: termKey, matching: find.byType(TerminalRenderer)),
          );

      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      for (var i = 0; i < 40 && out.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(out.isNotEmpty, isTrue, reason: 'no shell prompt — dead PTY');

      // A TALL block of URL anchors sandwiched mid-history so scrolling back
      // places many washes across the viewport at once — a small oscillation
      // then keeps several on-screen for the whole screenshot window.
      entry.proxy.sendInput(
        Uint8List.fromList(utf8.encode(
          'clear; seq 100; for i in \$(seq 1 12); do echo VISIT1067 \$i $_url; '
          'done; echo PATH1067 $_path; seq 200\n',
        )),
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
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }

      final rect = tester.getRect(termKey);
      final bodyX = rect.left + rect.width * 0.35;
      var lockstepFrames = 0;

      // Per-frame invariant: the painter resolved EXACTLY the on-screen anchor
      // rows (never hidden, never stale), and every visible wash is on-glyph.
      Future<void> sample(String phase) async {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        controller!.reportPaintedViewportOffset(controller.scrollbar.offset);
        final offset = controller.paintedViewportOffset;
        final expected = _expectedWashViewRows(controller, offset);
        final painted = renderBox().debugWashViewRows.toSet();
        expect(painted, equals(expected),
            reason: '[$phase] painted wash rows $painted != live-resolved '
                '$expected (offset=$offset) — not tracking per-frame');
        if (expected.isNotEmpty) {
          lockstepFrames++;
          final drift = _driftedWashes(controller, offset);
          expect(drift, isEmpty,
              reason: '[$phase] a visible wash sat off its token: $drift');
        }
      }

      bool washVisible() => controller!.highlights.any((r) =>
          r.capsule &&
          ('${r.payload}'.contains('track1067') ||
              '${r.payload}'.contains('site-packages')));

      // ---- PHASE SCROLL: swipe a wash anchor back on-screen. ----
      var washOnScreen = false;
      for (var s = 0; s < 30 && !washOnScreen; s++) {
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
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 60));
        }
        await sample('swipe$s.up');
        washOnScreen = washVisible();
      }
      expect(washOnScreen, isTrue,
          reason: 'never scrolled a wash anchor back on-screen');

      // MID-SCROLL screenshot window: small swipe oscillation. The TALL URL
      // block spans the viewport, so a few-row scroll each way keeps many washes
      // on-screen while they MOVE — an external shot lands on a moving wash with
      // legible text on top. Assertions run throughout (never hidden, lockstep).
      // A small up-swipe re-centers if the block ever drifts fully off.
      debugPrint('WASH1067_MIDSCROLL_WINDOW_OPEN');
      for (var o = 0; o < 44; o++) {
        final down = (o ~/ 3).isEven;
        final startY = rect.top + rect.height * (down ? 0.40 : 0.60);
        final g = await tester.startGesture(Offset(bodyX, startY));
        for (var i = 1; i <= 3; i++) {
          final dy = rect.height * 0.04 * i * (down ? 1 : -1);
          await g.moveTo(Offset(bodyX, startY + dy));
          await sample('midscroll$o.move$i');
        }
        await g.up();
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        await sample('midscroll$o.rest');
        if (!washVisible()) {
          final g2 = await tester.startGesture(
              Offset(bodyX, rect.top + rect.height * 0.35));
          for (var i = 1; i <= 4; i++) {
            await g2.moveTo(
                Offset(bodyX, rect.top + rect.height * (0.35 + 0.10 * i)));
            await sample('midscroll$o.recover$i');
          }
          await g2.up();
          for (var i = 0; i < 4; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
        }
      }
      debugPrint('WASH1067_MIDSCROLL_WINDOW_CLOSED');

      // Settle so the churn phase starts from a stable frame at the bottom.
      entry.proxy.sendInput(Uint8List.fromList(utf8.encode('clear\n')));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }

      // ---- PHASE CHURN: stream output continuously (a live TUI repaint) with a
      // URL in the stream; the wash must stay visible + track it each frame. ----
      debugPrint('WASH1067_MIDCHURN_WINDOW_OPEN');
      for (var f = 0; f < 60; f++) {
        if (f % 3 == 0) {
          entry.proxy.sendInput(Uint8List.fromList(
              utf8.encode('echo churn $f see $_url now\n')));
        } else {
          entry.proxy.sendInput(Uint8List.fromList(
              utf8.encode('echo churn $f filler filler filler\n')));
        }
        await sample('churn$f');
      }
      debugPrint('WASH1067_MIDCHURN_WINDOW_CLOSED');

      // Settle + final on-glyph check.
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      controller!.reportPaintedViewportOffset(controller.scrollbar.offset);
      expect(controller.isScrolling, isFalse, reason: 'never settled');
      expect(_driftedWashes(controller, controller.paintedViewportOffset),
          isEmpty,
          reason: 'after everything settles every wash must sit on its token');
      expect(lockstepFrames, greaterThan(20),
          reason: 'too few frames had a visible wash — acceptance is vacuous');
      debugPrint('WASH1067 pass: lockstepFrames=$lockstepFrames '
          '(never hidden, per-frame lockstep through scroll AND churn)');

      // Final settled hold for a stationary reference screenshot.
      debugPrint('WASH1067_SETTLED_WINDOW_OPEN');
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      debugPrint('WASH1067_SETTLED_WINDOW_CLOSED');
    },
  );
}
