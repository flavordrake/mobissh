// On-emulator RED→GREEN gate for #982: control mode (`-CC`) must WORK — attach
// the pre-existing session with ZERO leak — in a NESTED tmux (the owner's real
// env where login auto-attaches a persistent tmux).
//
// THE BUG (RED, on the typed-entry path): the app opens an INTERACTIVE shell and
// TYPES `tmux -CC attach 2>/dev/null || tmux -CC new-session -A -s main` into its
// stdin. The login already auto-attached tmux, so (a) that inner shell is INSIDE
// tmux → `-CC attach` can never attach (nested), and (b) the typed entry LINE
// ECHOES into the tmux pane as visible text. The owner sees `tmux -CC attach…`
// leak into their persistent session on every connect.
//
// THE FIX (GREEN): enter `-CC` by running the tmux invocation AS the SSH
// channel's EXEC command (with a PTY), not by typing into an interactive shell.
// A non-interactive exec does NOT source `.bashrc`/`.bash_profile`, so the
// login's tmux auto-attach is SKIPPED → the exec is NOT nested → `tmux -CC
// attach` attaches the persistent session cleanly. Nothing is typed → no echo.
//
// This test connects with control mode ON to the NESTED fixture and asserts the
// WORKING case (not just fallback):
//   1. the pre-existing session's screen renders (its NESTED_SCREEN_MARKER shows)
//      — proof `-CC attach` + capture-pane painted the existing session, and
//   2. NO entry-command text (`tmux -CC attach`) leaked into the pane, and
//   3. NO raw `-CC` protocol (`%output`, `%layout-change`, `refresh-client`)
//      leaked as literal text — proof the stream was PARSED as `-CC`, not shown
//      raw (a stuck/scraped -CC stream would dump the protocol verbatim).
//
// On the typed-entry path (unmodified) the marker never renders via -CC AND the
// entry line leaks → RED. After the exec fix → GREEN.
//
// Setup (run FIRST): scripts/cc-nested-setup.sh
// Run: scripts/native-connect-test.sh integration_test/cc_nested_exec_test.dart
// Teardown (restore plain login): scripts/cc-nested-teardown.sh

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
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
    'control mode ON ATTACHES the pre-existing session via -CC exec — zero '
    'leak in a NESTED tmux (#982)',
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

      // Give the `-CC` exec channel time to hand-shake (P1000p DCS) and paint the
      // attached session via the attach capture-pane. This is the WORKING path —
      // it must NOT need the 4s scrape-fallback timeout to become usable.
      var sawMarker = false;
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (rendered().contains('NESTED_SCREEN_MARKER')) {
          sawMarker = true;
          break;
        }
      }

      // Hold on-screen for the emu-shot capture point.
      await tester.pump(const Duration(seconds: 2));

      final text = rendered();

      // 1. The pre-existing session rendered via `-CC` attach + capture.
      expect(sawMarker, isTrue,
          reason: 'the pre-existing NESTED session never rendered — `-CC attach` '
              'did not attach + capture the existing session (it was nested, or '
              'fell through to a fresh/blank session). Saw: $text');

      // 2. The entry command must NOT echo into the pane (the owner's leak).
      expect(text.contains('tmux -CC attach'), isFalse,
          reason: 'the entry command `tmux -CC attach…` leaked into the pane as '
              'literal text — it was typed into an interactive (nested) shell '
              'instead of run as the exec command. Saw: $text');

      // 3. Raw `-CC` protocol must NOT appear as literal text — proof the stream
      //    was PARSED as control mode, not dumped raw (scrape of the -CC stream).
      expect(text.contains('%output '), isFalse,
          reason: 'raw `%output` protocol leaked — the -CC stream was not parsed. '
              'Saw: $text');
      expect(text.contains('%layout-change'), isFalse,
          reason: 'raw `%layout-change` protocol leaked — the -CC stream was not '
              'parsed. Saw: $text');
      expect(text.contains('refresh-client -C'), isFalse,
          reason: 'a refresh-client control command leaked into the pane as text. '
              'Saw: $text');

      debugPrint('CC_NESTED_EXEC: control mode ATTACHED the pre-existing session '
          'via -CC exec in a nested tmux — rendered its content, ZERO leak');
    },
  );
}
