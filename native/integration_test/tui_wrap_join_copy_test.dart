// tui_wrap_join_copy_test.dart — a URL that wraps at a FORCED margin (tmux /
// TUI, ghostty rowWrap=FALSE) gutter-copies as ONE joined URL, not two lines
// with a '\n' inside (owner ask 2026-07-02: "all copied text that contains soft
// wraps should default to being joined ... URLs still often get broken as does
// command lines").
//
// This is the case wrap_join_copy_test.dart does NOT cover: that test uses a
// plain shell where ghostty sets rowWrap=true. Here fake-tui (in tmux) paints a
// long Docs URL that reaches the right edge and continues on the next row
// WITHOUT rowWrap — the daily-driver shape. `visibleRowsText` now infers the
// wrap from the row being full-width (endFilled) and joins, so the URL pastes
// back intact.
//
// Run: scripts/native-connect-test.sh integration_test/tui_wrap_join_copy_test.dart

import 'dart:convert';

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

import 'support/connect_helpers.dart';

// The exact URL fake-tui paints (docker/test-sshd/fake-tui.sh line 42). Longer
// than any phone-emulator column count → it wraps across ≥2 rows at the margin.
const String _url =
    'https://docs.example.com/agent-hub/enrollment/getting-started#writer-jwt-mint';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a margin-wrapped URL (rowWrap=false) gutter-copies as one joined URL',
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
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          clipboardChannel,
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

      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      String seen() => utf8.decode(out, allowMalformed: true);
      for (var i = 0; i < 40 && out.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(out.isNotEmpty, isTrue, reason: 'dead PTY — no shell output');

      void send(String cmd) =>
          entry.proxy.sendInput(Uint8List.fromList(utf8.encode(cmd)));

      // tmux (mouse on, status off) — the forced-margin environment.
      send('tmux kill-server 2>/dev/null; tmux set -g mouse on \\; new -s w\n');
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      send('tmux set -g status off\n');
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      // Short TUI that exits to the prompt (hold=0) — the header + wrapped Docs
      // URL stay near the top of the visible screen.
      send('fake-tui 3 0.1 0\n');
      var tuiDone = false;
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (seen().contains('TUI_DONE')) {
          tuiDone = true;
          break;
        }
      }
      expect(tuiDone, isTrue, reason: 'fake-tui never completed');
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }

      final termFinder = find.byKey(Key('ghostty-terminal-$sessionId'));
      expect(termFinder, findsOneWidget);
      final rect = tester.getRect(termFinder);

      // Gutter LONG-PRESS then drag a TALL band from near the top to near the
      // bottom — the wrapped Docs URL spans two rows and BOTH must be inside the
      // band for the join to be observable (a short band that stops on the URL's
      // first row copies only the prefix and never exercises the join).
      final gx = rect.right - 14;
      final gy = rect.top + rect.height * 0.02;
      final gg = await tester.startGesture(Offset(gx, gy));
      await tester.pump(const Duration(milliseconds: 700));
      for (var i = 1; i <= 18; i++) {
        await gg.moveTo(Offset(gx, gy + rect.height * 0.05 * i));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gg.up();
      await tester.pump(const Duration(milliseconds: 200));

      debugPrint('TUIWRAP copied="$copied"');
      expect(copied, isNotNull, reason: 'gutter copy wrote nothing');
      // The whole URL is contiguous — no '\n' (or dropped char) at the wrap.
      expect(
        copied!.contains(_url),
        isTrue,
        reason:
            'the margin-wrapped URL was not joined — a newline sits inside it. '
            'copied="$copied"',
      );
    },
  );
}
