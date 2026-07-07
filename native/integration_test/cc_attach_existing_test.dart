// On-emulator tmux control-mode (`-CC`) ATTACH-EXISTING parity (#906).
//
// The device "zero gestures" bug was a session-model mismatch: control mode used
// to enter `tmux -CC new-session -A -s mobissh`, which forced a SEPARATE empty
// `mobissh` session — NOT the persistent session the owner actually had windows
// in. The fix (#906) makes the entry command `tmux -CC attach || tmux -CC
// new-session -A -s main`, attaching the owner's EXISTING (most-recent) session —
// the same one `tmux attach` gives on their laptop.
//
// `cc_gestures_test` creates its OWN windows AFTER attaching, so it never proves
// attach-EXISTING. This test does: a PERSISTENT `main` session with TWO windows
// is created ON test-sshd BEFORE the app connects (by scripts/cc-attach-setup.sh
// — NOT a session the app made). Then the app connects with control mode ON.
//
// OBSERVABILITY NOTE (measured against test-sshd tmux): `tmux -CC attach` does
// NOT push the existing pane content or window list on attach — it emits only
// `%session-changed`. Real -CC clients (iTerm2) query the screen themselves
// (capture-pane); MobiSSH's render path shows only NEW `%output`. So we PROVE the
// attach by producing new output in the attached session: a `send-keys` that
// prints tmux's OWN `#{session_name}` / `#{session_windows}` / `#{window_index}`
// into the active pane (rendered as `%output`). Attaching the pre-existing `main`
// yields `sess=main` + `nwin=2`; the OLD `-s mobissh` would yield `sess=mobissh`
// + `nwin=1` — so these assertions are RED against the old behavior, GREEN on
// main. A window switch then moves the active window index between the two
// PRE-EXISTING windows.
//
// The orchestrator runs this FLAG-ON; the shipped build keeps the flag OFF.
//
// Setup (run FIRST): scripts/cc-attach-setup.sh
// Run: scripts/native-connect-test.sh integration_test/cc_attach_existing_test.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

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
    '-CC attaches the PRE-EXISTING session, not a separate one (#906)',
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

      // Deterministically enable control mode THROUGH the provider, AFTER the
      // widget tree built the notifier (whose constructor + async hydrate reset
      // the raw global to the OFF default — the setUp flag alone races that and
      // is unreliable). `set(true)` persists the choice AND syncs the global, so
      // the proxy's connect-time read carries controlMode=true to the host.
      await container.read(tmuxControlModeProvider.notifier).set(true);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(tmuxControlMode, isTrue,
          reason: 'control-mode global must be ON before connect');

      // Control mode is ON → the entry command is `tmux -CC attach ...`, which
      // must grab the PRE-EXISTING `main` (created by scripts/cc-attach-setup.sh).
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

      // Raw stdin — in `-CC` a newline-terminated line IS a tmux command (the
      // proven-reliable path cc_gestures uses).
      void send(String s) =>
          entry.proxy.sendInput(Uint8List.fromList(utf8.encode(s)));

      Future<bool> waitFor(String marker, {int ticks = 50}) async {
        for (var i = 0; i < ticks; i++) {
          await tester.pump(const Duration(milliseconds: 500));
          if (rendered().contains(marker)) return true;
        }
        return false;
      }

      // Wait until the attached pane produces %output (its prompt) — this is the
      // "-CC is live + attached" signal. On attach tmux pushes no screen, so we
      // wait for the first pane redraw before issuing commands.
      var painted = false;
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (out.isNotEmpty) {
          painted = true;
          break;
        }
      }
      expect(painted, isTrue,
          reason: 'control-mode pane produced ZERO %output — did not attach. '
              '`main` may not have been pre-created (run cc-attach-setup.sh).');

      // Ask the ACTIVE pane to print tmux's OWN session identity. Attaching the
      // pre-existing `main` yields sess=main + nwin=2; a fresh empty `mobissh`
      // (the OLD behavior) would yield sess=mobissh + nwin=1. `#` is not
      // space-preceded so the shell does not treat #{...} as a comment.
      out.clear();
      send('send-keys "tmux display-message -p '
          'CCP1sess=#{session_name}nwin=#{session_windows}win=#{window_index}" '
          'Enter\n');
      expect(await waitFor('CCP1sess=mainnwin=2'), isTrue,
          reason: 'control mode did not attach the PRE-EXISTING `main` session '
              '(old `-s mobissh` would print sess=mobisshnwin=1). '
              'Saw: ${rendered()}');
      final win1 = RegExp(r'CCP1sess=mainnwin=2win=(\d+)').firstMatch(rendered());
      expect(win1, isNotNull, reason: 'no CCP1 window index. Saw: ${rendered()}');

      // A SWITCH gesture moves the active window to the OTHER pre-existing window.
      // Re-query identity and confirm the index CHANGED — the switch landed on a
      // window the app did NOT create (2 real pre-existing windows to move
      // between; a fresh 1-window session could not switch).
      out.clear();
      entry.proxy.sendTmuxGesture(TmuxWindowGesture.previousWindow);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      send('send-keys "tmux display-message -p '
          'CCP2sess=#{session_name}win=#{window_index}" Enter\n');
      expect(await waitFor('CCP2sess=mainwin='), isTrue,
          reason: 'no CCP2 identity after previous-window. Saw: ${rendered()}');
      final win2 = RegExp(r'CCP2sess=mainwin=(\d+)').firstMatch(rendered());
      expect(win2, isNotNull, reason: 'no CCP2 window index. Saw: ${rendered()}');
      expect(win2!.group(1), isNot(win1!.group(1)),
          reason: 'previous-window did not switch to a DIFFERENT pre-existing '
              'window (index unchanged ${win1.group(1)}). Saw: ${rendered()}');

      // Brief hold on the attached state (emu-shot capture point).
      await tester.pump(const Duration(seconds: 3));

      expect(find.byKey(const Key('session-menu-button')), findsOneWidget,
          reason: 'session torn down during the attach-existing sequence');

      debugPrint('CC_ATTACH_EXISTING: control mode attached the PRE-EXISTING '
          '`main` (sess=main, 2 windows) and switched between them');
    },
  );
}
