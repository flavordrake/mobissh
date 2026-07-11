// On-emulator #1042 — command wrap recall + the maybeIncomplete affordances.
//
// Drives the real chain (SSH → shell echo → flterm scanner → gutter layer)
// against test-sshd:
//   1. CASE A (full copy, NO mark): a strong bash prompt, then a REAL long
//      command typed at the prompt that SOFT-WRAPS across the grid (length
//      derived from the live $COLUMNS so the last row lands mid-grid). The
//      anchor's payload must be the FULL typed line (the wrap flag join),
//      maybeIncomplete=false, the chip is the normal terminal glyph, and the
//      tap toast is the plain "Copied: …".
//   2. CASE B (unjoinable → honest mark): printf paints the OWNER-TRACE shape
//      (2026-07-11T02-32-14): a `⎿  $ echo …` strong-prompt line whose
//      genuinely multi-line command continues at a DEEPER band no boundary
//      evidence can join. The anchor stays first-line-only, carries
//      maybeIncomplete=true, the chip renders the ellipsis variant, and the
//      tap toast reads "Copied — may be incomplete".
//      (A plain-shell PS2/heredoc does NOT mark — bare `>` is excluded by
//      design (#998) and a heredoc's `cat <<EOF` head shows no wrap evidence;
//      the owner's actual construct is this TUI band, reproduced verbatim.)
//
// SHOT1042 debugPrints mark screenshot hold windows (scripts/emu-shot.sh).
//
// Run: scripts/native-connect-test.sh integration_test/command_incomplete_1042_test.dart

import 'dart:convert';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icon, Icons;
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/services/clipboard.dart' show clipboardChannel;
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/ghostty_gutter_layer.dart'
    show kGutterIncompleteIcon;
import 'package:mobissh/ui/ghostty_terminal_decorators.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import 'support/connect_helpers.dart';

const _caseBFirstLine = 'echo "one two three"';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a soft-wrapped command copies FULLY unmarked; the owner-trace TUI band '
    'marks maybeIncomplete with the ellipsis chip + hedged toast (#1042)',
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

      // Strong prompt under the test's control (#998 precedent), then clear.
      send(r"export PS1='testuser@test-sshd:~$ '");
      await tester.pump(const Duration(milliseconds: 800));
      send('clear');
      await tester.pump(const Duration(milliseconds: 800));

      // Grid width from the live shell, so CASE A's soft-wrapped command can
      // deterministically land its LAST row mid-grid (a boundary-hugging last
      // row is exactly the honesty signal — this test wants the clean case).
      send(r'echo "COLS=$COLUMNS"');
      int? cols;
      for (var i = 0; i < 30 && cols == null; i++) {
        await tester.pump(const Duration(milliseconds: 400));
        final m = RegExp(r'COLS=(\d{2,3})\b')
            .firstMatch(utf8.decode(out, allowMalformed: true));
        if (m != null) cols = int.parse(m.group(1)!);
      }
      expect(cols, isNotNull, reason: r'shell never reported $COLUMNS');
      debugPrint('CHIP1042 cols=$cols');

      // ---- CASE A: a REAL soft-wrapped command → FULL copy, no mark. ----
      // Prompt is 22 chars; size the command so it wraps once and its last
      // row ends near mid-grid: total (prompt+command) = 2.5 * cols.
      const promptLen = 22; // 'testuser@test-sshd:~$ '
      const fixedA = 'echo m1042'; // lexicon hit (+2) behind a strong prompt
      const tailA = ' | tail -1'; // flag + operator for good measure
      var pad = (cols! * 5) ~/ 2 - promptLen - fixedA.length - tailA.length - 1;
      if (pad < 8) pad = 8;
      final commandA = '$fixedA ${'a' * pad}$tailA';
      send(commandA);

      StructuredAnchor? anchorWhere(bool Function(String payload) test) {
        for (final a in controller.anchors) {
          if (a.patternId == kGhosttyCommandPatternId &&
              test('${a.payload}')) {
            return a;
          }
        }
        return null;
      }

      StructuredAnchor? anchorA() =>
          anchorWhere((p) => p == commandA);
      for (var i = 0; i < 60 && anchorA() == null; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      final cmdA = anchorA();
      expect(cmdA, isNotNull,
          reason: 'the soft-wrapped command must anchor with its FULL '
              'payload (found: '
              '${controller.anchors.map((a) => a.payload).toList()})');
      expect(cmdA!.maybeIncomplete, isFalse,
          reason: 'a flag-joined wrap left nothing behind — no hedge');

      int? rowOf(StructuredAnchor a) {
        for (final r in a.ranges) {
          final row = controller.anchorGutterRow(r);
          if (row != null) return row;
        }
        return null;
      }

      final rowA = rowOf(cmdA);
      expect(rowA, isNotNull, reason: 'case-A anchor has no on-screen row');
      final iconA = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(Key('gutter-mark-$rowA')),
          matching: find.byType(Icon),
        ),
      );
      expect(iconA.icon, Icons.terminal,
          reason: 'a complete command keeps the normal chip glyph');

      debugPrint('SHOT1042 full-chip hold');
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }

      copied = null;
      await tester.tap(find.byKey(Key('gutter-mark-$rowA')));
      for (var i = 0; i < 10 && copied == null; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(copied, commandA,
          reason: 'the chip must copy the FULL soft-wrapped command');
      // The toast overlay inserts AFTER the async clipboard write resolves —
      // give it frames to build before asserting its text.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('may be incomplete'), findsNothing,
          reason: 'the clean case gets the plain toast');
      expect(find.textContaining('Copied:'), findsOneWidget);
      // Drain the toast.
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 400));

      // ---- CASE B: the owner-trace TUI band → honest incomplete mark. ----
      send('clear');
      await tester.pump(const Duration(milliseconds: 800));
      // Paint the 2026-07-11 owner shape: strong `⎿  $ ` head, then the
      // deeper continuation band a boundary-gated join must reject. The `⎿`
      // is sent as its literal UTF-8 bytes (portable across printf builds);
      // inside single quotes the `$` and quotes are literal, `\n` is printf's.
      send("printf '  ⎿  \$ echo \"one two three\"\\n"
          "     ssh pve rest of the block here\\n\\n'");

      StructuredAnchor? anchorB() =>
          anchorWhere((p) => p == _caseBFirstLine);
      for (var i = 0; i < 60 && anchorB() == null; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      final cmdB = anchorB();
      expect(cmdB, isNotNull,
          reason: 'the painted `⎿  \$ echo …` head must anchor first-line-only '
              '(found: '
              '${controller.anchors.map((a) => a.payload).toList()})');
      expect(cmdB!.maybeIncomplete, isTrue,
          reason: 'the deeper-band successor was rejected as a continuation '
              '— the anchor must carry the honesty flag (#1042)');

      final rowB = rowOf(cmdB);
      expect(rowB, isNotNull, reason: 'case-B anchor has no on-screen row');
      final iconB = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(Key('gutter-mark-$rowB')),
          matching: find.byType(Icon),
        ),
      );
      expect(iconB.icon, kGutterIncompleteIcon,
          reason: 'the likely-truncated anchor renders the ellipsis variant');

      debugPrint('SHOT1042 incomplete-chip hold');
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }

      copied = null;
      await tester.tap(find.byKey(Key('gutter-mark-$rowB')));
      for (var i = 0; i < 10 && copied == null; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(copied, _caseBFirstLine,
          reason: 'the copy is still the best honest payload (line 1)');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Copied — may be incomplete'), findsOneWidget,
          reason: 'the toast must hedge (#1042)');

      debugPrint('SHOT1042 incomplete-toast hold');
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
    },
  );
}
