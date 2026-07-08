// On-emulator COMMAND-LINE detection + gutter chip (#998 slices C+D).
//
// Drives the real chain (SSH → shell echo → flterm scanner → gutter layer)
// against test-sshd:
//   1. ensure a STRONG-tier prompt (`user@host:~$ ` — the design's bash
//      userhost shape; exported explicitly so the test doesn't depend on the
//      fixture shell's default PS1), `clear`, then TYPE a real command at the
//      real prompt: `curl -fsSL <url> | tail -1`. The typed line at the prompt
//      IS the detection target (lexicon hit + flag + pipe = score 4 behind a
//      strong prompt); whether curl exists on the fixture is irrelevant.
//   2. assert the scanner anchors BOTH the whole command (block tier, payload
//      EXACTLY the typed command — paste-exact) AND the inner URL (span).
//   3. tap the command chip → clipboard = the FULL command. When the inner URL
//      shares the chip's viewport row the chip is the multi-match count badge
//      and the copy goes through the list sheet's "Copy command" action —
//      which is also where "Not a command" (#998 D) lives; both branches are
//      handled because the wrap point depends on the emulator grid width.
//   4. copy the URL through ITS affordance (own chip → URL menu → Copy, or the
//      shared sheet's URL "Copy") → clipboard = JUST the URL.
//
// SHOT998 debugPrints mark screenshot hold windows (scripts/emu-shot.sh).
//
// Run: scripts/native-connect-test.sh integration_test/command_chip_998_test.dart

import 'dart:convert';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/services/clipboard.dart' show clipboardChannel;
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/ghostty_terminal_decorators.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import 'support/connect_helpers.dart';

const _url = 'https://example.com/mobissh/998/x';
const _command = 'curl -fsSL $_url | tail -1';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'command chip copies the whole typed command; the inner URL keeps its own '
    'copy (#998 C+D)',
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

      void send(String line) {
        entry.proxy.sendInput(Uint8List.fromList(utf8.encode('$line\n')));
      }

      // A STRONG-tier prompt (the design's `user@host:path$ ` shape), set
      // explicitly so the test controls the tier instead of trusting the
      // fixture shell's default. Then clear away login noise + the export
      // line itself, so the typed command is the only detectable content.
      send(r"export PS1='testuser@test-sshd:~$ '");
      await tester.pump(const Duration(milliseconds: 800));
      send('clear');
      await tester.pump(const Duration(milliseconds: 800));

      // The REAL command, typed at the REAL prompt (echoed by the PTY). Score:
      // curl (lexicon +2) + -fsSL (flag +1) + | (operator +1) behind a strong
      // prompt → detected; payload must be the prompt-stripped typed line.
      send(_command);

      // Select by payload too: the `export PS1=…` line typed at an
      // already-strong fixture prompt may ALSO be anchored (export is in the
      // lexicon) but lives in cleared-away scrollback — anchors persist.
      StructuredAnchor? commandAnchor() {
        for (final a in controller.anchors) {
          if (a.patternId == kGhosttyCommandPatternId &&
              '${a.payload}'.startsWith('curl')) {
            return a;
          }
        }
        return null;
      }

      StructuredAnchor? urlAnchor() {
        for (final a in controller.anchors) {
          if (a.patternId == kGhosttyUrlPatternId && '${a.payload}' == _url) {
            return a;
          }
        }
        return null;
      }

      for (var i = 0;
          i < 60 && (commandAnchor() == null || urlAnchor() == null);
          i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      final cmd = commandAnchor();
      final url = urlAnchor();
      expect(cmd, isNotNull, reason: 'the typed command was never anchored');
      expect(url, isNotNull, reason: 'the inner URL was never anchored');
      expect(
        '${cmd!.payload}',
        _command,
        reason: 'the command payload must be the prompt-stripped typed line, '
            'paste-exact',
      );

      int? rowOf(StructuredAnchor a) {
        for (final r in a.ranges) {
          final row = controller.anchorGutterRow(r);
          if (row != null) return row;
        }
        return null;
      }

      final cmdRow = rowOf(cmd);
      final urlRow = rowOf(url!);
      expect(cmdRow, isNotNull, reason: 'command anchor has no on-screen row');
      expect(urlRow, isNotNull, reason: 'URL anchor has no on-screen row');
      debugPrint('CHIP998 rows: command=$cmdRow url=$urlRow');
      final sharedRow = cmdRow == urlRow;

      // Screenshot window: both affordances on screen (chips visible).
      debugPrint('SHOT998 chips hold');
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }

      // 1) COPY THE COMMAND via its chip.
      copied = null;
      await tester.tap(find.byKey(Key('gutter-mark-$cmdRow')));
      await tester.pump(const Duration(milliseconds: 400));
      if (sharedRow) {
        // Count-badge chip → the list sheet; "Copy command" + "Not a command".
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('gutter-pattern-list')),
          findsOneWidget,
          reason: 'shared-row chip did not open the multi-match sheet',
        );
        expect(
          find.byTooltip('Not a command'),
          findsOneWidget,
          reason: 'the command sheet item is missing "Not a command" (#998 D)',
        );
        // Screenshot window: the sheet with Copy command / Not a command.
        debugPrint('SHOT998 sheet hold');
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        await tester.tap(find.byTooltip('Copy command'));
        await tester.pumpAndSettle();
      }
      for (var i = 0; i < 10 && copied == null; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(
        copied,
        _command,
        reason: 'the command chip must copy the FULL command paste-exact',
      );

      // 2) COPY THE URL via its own affordance.
      copied = null;
      if (sharedRow) {
        await tester.tap(find.byKey(Key('gutter-mark-$cmdRow')));
        await tester.pumpAndSettle();
        // The URL row in the sheet: its plain "Copy" action.
        await tester.tap(find.byTooltip('Copy'));
        await tester.pumpAndSettle();
      } else {
        await tester.tap(find.byKey(Key('gutter-mark-$urlRow')));
        var menuShown = false;
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 300));
          if (find.byKey(const Key('url-action-menu')).evaluate().isNotEmpty) {
            menuShown = true;
            break;
          }
        }
        expect(menuShown, isTrue, reason: 'URL chip never opened the URL menu');
        // Screenshot window: the URL menu open beside the command chip.
        debugPrint('SHOT998 url-menu hold');
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        await tester.tap(find.byKey(const Key('url-action-copy')));
        await tester.pump(const Duration(milliseconds: 400));
      }
      for (var i = 0; i < 10 && copied == null; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(
        copied,
        _url,
        reason: 'the URL affordance must copy JUST the URL, not the command',
      );
    },
  );
}
