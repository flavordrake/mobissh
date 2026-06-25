// #922 (REOPEN, device 0.1.10+71) — switching tmux WINDOWS repeatedly leaves the
// OLD window's content on screen: "first tab switch succeeded, second through n
// failed to refresh", "every other tap refreshes". So it ALTERNATES — some
// switches repaint, some strand the previous window. Detect-URLs ON (default),
// tmux control mode OFF (the SCRAPE path, the owner's repro).
//
// The +71 STRUCTURAL fix added a `_damageUnsettled` carry-forward in
// terminal_frame_builder.dart whose HEADLESS A->B->A->B pipeline test passes
// (window_switch_no_starve_922_test.dart) — it models exactly TWO syncs per
// switch ([consume, paint]). But on real frames the per-switch sync cadence is
// richer (cursor blink, scroll/offset correction, atlas onImageReady repaint, the
// #803 painted-offset post-frame notify, the #918 output settle tick), and the
// single-bool carry-forward settles after the FIRST switch then reads CLEAN and
// SKIPS the full re-read on subsequent switches — the device alternation.
//
// This is the device-class assertion the headless pipeline test cannot make: it
// drives the REAL SSH->host->tmux->flterm chain on the DEFAULT scrape path,
// detection ON, runs an actual tmux session with >=2 windows of DISTINCT content,
// and switches windows REPEATEDLY via a RELIABLE tmux PREFIX next-window sequence
// (`\x02n`) so the switch ALWAYS lands and we isolate the REPAINT. After EACH
// switch it asserts the visible grid REPAINTED to the new window
// (`box.debugRowsRebuiltLastSync > 0`) and counts stranded switches.
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 -> socat -> test-sshd).
// Run: scripts/native-connect-test.sh integration_test/window_switch_repaint_922_test.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart' show TerminalRenderBox, TerminalRenderer;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/detection_providers.dart';
import 'package:mobissh/state/sessions.dart';

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // `TerminalRenderBox` is a RenderObject (not a Widget), reached via the
  // `TerminalRenderer` LeafRenderObjectWidget's render object.
  TerminalRenderBox? findRenderBox(WidgetTester tester) {
    final renderers = find.byType(TerminalRenderer);
    if (renderers.evaluate().isEmpty) return null;
    final obj = tester.renderObject(renderers.first);
    return obj is TerminalRenderBox ? obj : null;
  }

  testWidgets(
    'scrape path, detection ON: switching tmux windows REPEATEDLY repaints the '
    'grid EVERY time — no A/B alternation, no stranded window (#922)',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      // Default detection settings (all-true) — detection ON, the #922 failing
      // condition (the owner's default).
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MobisshApp(),
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      // Force detection (URLs) ON regardless of any stored setting from a prior
      // run on the same data dir.
      await container.read(detectionSettingsProvider.notifier).setUrl(true);
      await tester.pump(const Duration(milliseconds: 300));

      await adhocPasswordConnect(
        tester,
        host: '127.0.0.1',
        port: '2222',
        user: 'testuser',
        pass: 'testpass',
      );

      var connected = false;
      for (var i = 0; i < 80; i++) {
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
      void send(String s) =>
          entry.proxy.sendInput(Uint8List.fromList(utf8.encode(s)));

      // Accumulate ALL shell output so we can confirm a switch's redraw bytes
      // actually arrived (the switch landed) before asserting the repaint.
      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      String outText() => utf8.decode(out, allowMalformed: true);

      for (var i = 0; i < 40 && out.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(out, isNotEmpty, reason: 'shell never produced output');

      final box = findRenderBox(tester);
      expect(box, isNotNull,
          reason: 'flterm TerminalRenderBox not found — wrong backend? (ghostty '
              'is the default)');

      // Detection wires onto the render box from the URL/path pattern
      // registration; let the post-frame wiring apply.
      for (var i = 0; i < 20 && !box!.detectionActive; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(box!.detectionActive, isTrue,
          reason: 'detectionActive was never wired onto the render box with URL '
              'detection ON — the #922 double-update race would not engage');

      // Drives an output round-trip and waits until the expected marker appears
      // in the accumulated PTY output (the command actually ran), so the grid is
      // settled before we measure a switch repaint.
      Future<void> waitForOutput(String marker, {int maxFrames = 60}) async {
        for (var i = 0; i < maxFrames; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (outText().contains(marker)) return;
        }
      }

      // Start tmux with TWO windows of DISTINCT content. Window 0 = WIN_A,
      // window 1 = WIN_B. Disable the status bar so a switch is a pure alt-screen
      // content redraw (no status churn the test would mistake for the switch).
      send('tmux kill-server 2>/dev/null; '
          'tmux new-session -d -s s -x 80 -y 24; '
          'tmux set -g status off; '
          "tmux send-keys -t s:0 'clear; printf \"WIN_A_MARKER_LINE\\n\"' Enter; "
          "tmux new-window -t s:1; "
          "tmux send-keys -t s:1 'clear; printf \"WIN_B_MARKER_LINE\\n\"' Enter; "
          'tmux attach -t s\n');
      // Let tmux attach + draw the alternate screen.
      await waitForOutput('WIN_', maxFrames: 80);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }

      // Settle to a quiet baseline before the first measured switch.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      // CORE #922 ASSERTION: switch windows REPEATEDLY with the tmux PREFIX
      // next-window sequence (Ctrl-b n = `\x02n`) — a RELIABLE switch that always
      // lands, isolating the REPAINT (not a flaky guessed status-row tap). After
      // EACH switch the visible grid MUST re-read rows (repaint to the new
      // window). Count how many switches stranded (re-read 0 rows).
      //
      // We measure the PAINTING-sync repaint in a TIGHT window that excludes the
      // #918 80ms settle-tick heal (which forces a full re-read independently),
      // so a transient strand the tick later masks is still caught. The bug is a
      // PERSISTENT stale window on device, so if the immediate switch sync reads
      // 0 it is the defect even if a later tick heals it.
      const switches = 10;
      var strandedImmediate = 0; // before the 80ms settle tick could heal
      var strandedSettled = 0; // even after the full settle window
      final immediate = <int>[];
      final settled = <int>[];

      for (var n = 0; n < switches; n++) {
        final before = out.length;
        send('\x02n'); // tmux next-window — always lands on the OTHER window.

        // Wait for the switch's redraw bytes to arrive (the switch landed).
        var sawBytes = false;
        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          if (out.length > before) {
            sawBytes = true;
            break;
          }
        }
        expect(sawBytes, isTrue,
            reason: 'switch #$n produced NO PTY redraw bytes — the tmux '
                'next-window did not land; cannot measure the repaint');

        // IMMEDIATE window: ~60ms of short pumps, strictly BEFORE the 80ms #918
        // settle tick can fire its forced re-read. Catches the painting sync's
        // own rebuild count.
        var maxImmediate = 0;
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 10));
          final r = box.debugRowsRebuiltLastSync;
          if (r > maxImmediate) maxImmediate = r;
        }
        immediate.add(maxImmediate);
        if (maxImmediate == 0) strandedImmediate++;

        // SETTLED window: let the settle tick + any later frame run; if the grid
        // is STILL never re-read, the new window is persistently stale (the
        // device symptom).
        var maxSettled = maxImmediate;
        for (var i = 0; i < 24; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          final r = box.debugRowsRebuiltLastSync;
          if (r > maxSettled) maxSettled = r;
        }
        settled.add(maxSettled);
        if (maxSettled == 0) strandedSettled++;

        // Quiet before the next switch so each measurement starts settled.
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      debugPrint('WINDOW_SWITCH_922 immediate rows-rebuilt: $immediate '
          '(stranded-immediate $strandedImmediate/$switches)');
      debugPrint('WINDOW_SWITCH_922 settled rows-rebuilt: $settled '
          '(stranded-settled $strandedSettled/$switches)');

      // The hard failure is a PERSISTENTLY stale window: the grid never re-read
      // across the whole settle window. That is the on-screen staleness the owner
      // reports.
      expect(strandedSettled, equals(0),
          reason: 'with detection ON, $strandedSettled of $switches tmux window '
              'switches NEVER re-read the grid (persistently stale window — the '
              '#922 device symptom). Settled rebuild counts: $settled');

      // Softer signal: a switch whose PAINTING sync stranded (healed only by the
      // later settle tick) is the alternation flicker. Surfaced separately so a
      // transient strand fails the test even if the tick papers over it.
      expect(strandedImmediate, equals(0),
          reason: 'with detection ON, $strandedImmediate of $switches tmux window '
              'switches re-read ZERO rows on the immediate painting sync (the '
              '#922 alternation — old window shown until a later tick heals it). '
              'Immediate rebuild counts: $immediate');
    },
  );
}
