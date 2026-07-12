// On-emulator acceptance for #1071 (owner P0, build +143) — DISCOVERY STARVATION.
//
// The #1069 rollback debounces DISCOVERY (~120ms) and re-arms that debounce on
// EVERY terminal notify. A continuously-repainting TUI (Claude Code streaming
// output / a spinner updating faster than 120ms) pushes the trailing edge out
// forever, so `_rescanDetections` NEVER fires: no new match is discovered, and
// with synchronous eviction the busy screen shows ZERO washes. Owner report:
// "the URLs toggle seems to change nothing. bubbles are missing." (+143).
//
// The #1069 acceptance did NOT catch this — its remote loop dwells `sleep 0.6`
// per tick, a 600ms quiet window that lets the debounce fire every tick. This
// test reproduces the owner's ACTUAL environment: a URL sits persistently on one
// row while ANOTHER row repaints CONTINUOUSLY at ~30ms (well under the 120ms
// debounce, never a quiet window). The #1071 max-wait ceiling must still force
// discovery, so the persistent URL DOES wash despite the never-pausing churn.
// On +143 (no ceiling) urlWashFrames would be 0; with the ceiling it climbs.
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
// Run: scripts/native-connect-test.sh integration_test/wash_discovery_ceiling_1071_shot_test.dart
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

const _persistentUrl = 'example.com/persistent/link';

bool _urlWashVisible(TerminalController c) => c.highlights
    .any((r) => r.capsule && '${r.payload}'.contains(_persistentUrl));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a URL persistently on screen still washes while ANOTHER row repaints '
    'continuously below the debounce window — the max-wait ceiling forces the '
    'discovery the perpetually-cancelled debounce never delivers (#1071)',
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

      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      for (var i = 0; i < 40 && out.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(out.isNotEmpty, isTrue, reason: 'no shell prompt — dead PTY');

      // Paint a URL ONCE on row 6 (never overwritten → the only reason it fails
      // to wash is starved discovery), then repaint row 8 CONTINUOUSLY at ~30ms
      // for ~200 ticks (~6s). 30ms << 120ms debounce → the discovery debounce is
      // re-armed before it can ever fire; only the #1071 ceiling can deliver it.
      entry.proxy.sendInput(Uint8List.fromList(utf8.encode(
        'clear; '
        'printf "\\033[6;1H\\033[2Kvisit https://$_persistentUrl here"; '
        'for i in \$(seq 1 200); do '
        'printf "\\033[8;1H\\033[2Kworking tick=\$i streaming output ..."; '
        'sleep 0.03; done; '
        // DONE marker split across two literals so the PTY echo of the command
        // line does not contain the contiguous token (only the printf output).
        'printf "\\033[20;1H\\033[2KDONE""1071\\n"\n',
      )));

      TerminalController c() => controller!;
      var urlWashFrames = 0;
      var firstWashTick = -1;

      Future<void> sample(int f) async {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        c().reportPaintedViewportOffset(c().scrollbar.offset);
        if (_urlWashVisible(c())) {
          urlWashFrames++;
          if (firstWashTick < 0) firstWashTick = f;
        }
      }

      // ---- Continuous-churn window: sample across the whole remote loop. ----
      debugPrint('WASH1071_CHURN_WINDOW_OPEN');
      var done = false;
      for (var f = 0; f < 300 && !done; f++) {
        await sample(f);
        await tester.pump(const Duration(milliseconds: 50));
        if (utf8.decode(out, allowMalformed: true).contains('DONE1071')) {
          done = true;
        }
      }
      debugPrint('WASH1071_CHURN_WINDOW_CLOSED');
      expect(done, isTrue, reason: 'the remote repaint loop never finished');

      // THE #1071 assertion: the persistent URL washed DURING the continuous
      // sub-debounce churn. On +143 (no ceiling) this is 0 — discovery starved.
      // The ceiling forces a rescan within ~500ms, so once discovered the wash
      // persists (its cells never change) and the count climbs for the rest of
      // the loop.
      expect(urlWashFrames, greaterThan(10),
          reason: 'the persistent URL never washed under continuous repaint — '
              'discovery starved (the #1071 bug: "bubbles are missing" on a '
              'continuously-repainting TUI). firstWashTick=$firstWashTick');
      debugPrint('WASH1071 pass: urlWashFrames=$urlWashFrames '
          'firstWashTick=$firstWashTick (ceiling delivered discovery under '
          'continuous churn)');

      // Settle and hold for a screenshot: row 6 URL still washed, row 8 idle.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      c().reportPaintedViewportOffset(c().scrollbar.offset);
      expect(_urlWashVisible(c()), isTrue,
          reason: 'the URL wash must remain after the churn settles');
      debugPrint('WASH1071_SETTLED_WINDOW_OPEN');
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      debugPrint('WASH1071_SETTLED_WINDOW_CLOSED');
    },
  );
}
