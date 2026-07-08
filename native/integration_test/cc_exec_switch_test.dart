// On-emulator gate for #906: control mode (`-CC`) window-list determinism +
// telemetry on a PRE-EXISTING (pre-populated) tmux session attached via exec.
//
// PROTOCOL GAP (verified against real tmux -CC, scripts probe): on `tmux -CC
// attach` to a session whose windows existed BEFORE the client attached, tmux
// emits NO `%window-add`/`%layout-change` for those windows — only
// `%session-changed` + `%output`. So the channel window order is EMPTY right
// after attach. The app currently only recovers because its startup grid
// RESIZE triggers a `refresh-client -C`, which makes tmux re-lay-out and emit
// `%layout-change` for every window — a FRAGILE, incidental population (it never
// happens if the device grid already matches the session size). The fix QUERIES
// `list-windows` on attach and parses it into the ordered list, so the status-
// tap mapping is populated DETERMINISTICALLY, independent of any resize.
//
// RED→GREEN discriminator (deterministic): the control-mode trace ring (#906,
// forwarded task→UI) must, after attach, contain `list-windows parsed` + a
// `windowList @0(alpha) @1(bravo) @2(charlie)` snapshot. On main there is NO
// control-mode telemetry AT ALL (the coordinator's exact complaint — "the bug
// report has NO task-side control-mode state") and `list-windows` is never
// queried → the ring is EMPTY → RED. With the change → GREEN. The behavioral
// switch (tap LAST segment → charlie repaints) is asserted as a GREEN
// confirmation; note it can ALSO pass on main via the incidental resize path,
// so the trace — not the switch — is the load-bearing discriminator.
//
// Setup (run FIRST): scripts/cc-exec-switch-setup.sh
// Run: scripts/native-connect-test.sh integration_test/cc_exec_switch_test.dart

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/diagnostics/connect_trace.dart' show controlModeLogSnapshot;
import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/services/session_messages.dart' show TmuxWindowGesture;
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/tmux_control_mode_setting.dart';
import 'package:mobissh/terminal/tmux_control_mode_flag.dart';

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late bool prevFlag;
  setUp(() => prevFlag = setTmuxControlModeForTest(true));
  tearDown(() => setTmuxControlModeForTest(prevFlag));

  testWidgets(
    'control mode ON: a status-bar tap switches windows on a PRE-EXISTING '
    'session (list-windows on attach) (#906)',
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

      // Turn control mode ON through the provider — the widget's provider init
      // resets the per-isolate global to its stored default (false), so the
      // setUp flag alone is overwritten during pump (the cc_nested pattern).
      await container.read(tmuxControlModeProvider.notifier).set(true);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(tmuxControlMode, isTrue,
          reason: 'control-mode global must be ON before connect');

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
      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      String rendered() => utf8.decode(out, allowMalformed: true);

      Future<bool> waitFor(String marker, {int ticks = 40}) async {
        for (var i = 0; i < ticks; i++) {
          await tester.pump(const Duration(milliseconds: 500));
          if (rendered().contains(marker)) return true;
        }
        return false;
      }

      // The pre-existing session's ACTIVE window (alpha) is painted by the
      // attach capture-pane — proof `-CC attach` attached the pre-populated
      // session. (charlie's marker is NOT here: capture-pane paints only the
      // ACTIVE window, so charlie can only appear AFTER a real switch.)
      expect(await waitFor('WIN_ALPHA_MARKER'), isTrue,
          reason: 'the pre-existing ACTIVE window never rendered — attach '
              'capture failed. Saw: ${rendered()}');

      // DETERMINISTIC RED→GREEN: the control-mode trace ring (forwarded task→UI)
      // must show `list-windows` was queried on attach and built the ordered
      // window list. On main there is NO control-mode telemetry at all AND
      // list-windows is never queried, so this ring is EMPTY → RED. With the
      // change the ring carries the whole decision path → GREEN. This is the
      // load-bearing discriminator (the behavioral switch below can also pass on
      // main via the incidental startup-resize %layout-change path).
      var traceOk = false;
      for (var i = 0; i < 20 && !traceOk; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        final trace = controlModeLogSnapshot().join('\n');
        traceOk = trace.contains('list-windows parsed') &&
            trace.contains('windowList @0(alpha) @1(bravo) @2(charlie)');
      }
      expect(traceOk, isTrue,
          reason: 'the control-mode trace never showed list-windows building the '
              'window order on attach — either the fix is absent (order left to '
              'the fragile resize path) or the task→UI trace forwarding is '
              'broken. Trace: ${controlModeLogSnapshot().join('\n')}');

      // BEHAVIORAL confirmation: tap the LAST status segment → window 2
      // (charlie), which must repaint charlie's marker. Retry across a generous
      // window so a single dropped envelope can't flake it.
      var switched = false;
      for (var attempt = 0; attempt < 6 && !switched; attempt++) {
        out.clear();
        entry.proxy.sendTmuxGesture(
          TmuxWindowGesture.tapStatusCol,
          statusCol: 85,
          statusCols: 90,
        );
        switched = await waitFor('WIN_CHARLIE_MARKER', ticks: 16);
      }

      await tester.pump(const Duration(seconds: 2)); // hold for emu-shot

      expect(switched, isTrue,
          reason: 'the status-bar tap did not switch to the tapped window — '
              'charlie never repainted. Saw: ${rendered()}');

      // The gesture RESOLUTION must be in the trace too (one report diagnoses it).
      expect(controlModeLogSnapshot().join('\n'),
          contains('resolved=select-window'),
          reason: 'the gesture resolution was not recorded in the control-mode '
              'trace. Trace: ${controlModeLogSnapshot().join('\n')}');

      debugPrint('CC_EXEC_SWITCH: list-windows built the order on attach '
          '(deterministic, in the trace); status-bar tap switched to charlie');
    },
  );
}
