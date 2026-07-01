// wrap_join_copy_test.dart — gutter copy resolves SOFT WRAP into one logical
// line (owner ask 2026-07-01: "any hope of detecting a wrapped command line and
// resolving soft wrap to remove new line?").
//
// Ghostty records soft wrap per row (`rowWrap` = "this row is soft-wrapped to
// the next row" — its own bookkeeping, not a heuristic). `visibleRowsText` now
// consults it: a wrapped row joins the next row with NO '\n' and NO trailing
// trim (a wrapped row is full-width; a boundary space is real content). So a
// long command/URL that the terminal wrapped across rows copies as ONE line.
//
// This runs in a PLAIN shell (no tmux): that's where genuine soft wrap occurs.
// TUI-layout "wraps" (hard newlines + margins — tmux/Claude-Code repaints)
// carry rowWrap=false and correctly KEEP their breaks; joining those is the
// smart-copy massager's job (#963), not the verbatim read's.
//
// Run: scripts/native-connect-test.sh integration_test/wrap_join_copy_test.dart

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/services/clipboard.dart' show clipboardChannel;
import 'package:mobissh/state/sessions.dart';

import 'support/connect_helpers.dart';

/// Deterministic marker LONGER than any realistic emulator column count, so the
/// shell soft-wraps it across at least two rows. Interior structure lets the
/// assertion detect a stray '\n' anywhere inside.
const String _marker =
    'WRAPJOIN_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA_MID_'
    'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB_END';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a soft-wrapped output line gutter-copies as ONE logical line (no \\n)',
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
      for (var i = 0; i < 40 && out.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(out.isNotEmpty, isTrue, reason: 'dead PTY — no shell output');

      // Echo the marker via a VARIABLE so the typed command line itself never
      // contains the assembled marker — only the soft-wrapped OUTPUT line does.
      // The clear puts it near the top, safely inside the gutter band below.
      entry.proxy.sendInput(
        Uint8List.fromList(
          utf8.encode(
            'clear; M_A=WRAPJOIN_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA; '
            'M_B=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB_END; '
            'echo "\${M_A}_MID_\${M_B}"\n',
          ),
        ),
      );
      var markerSeen = false;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (utf8.decode(out, allowMalformed: true).contains('_MID_')) {
          markerSeen = true;
          break;
        }
      }
      expect(markerSeen, isTrue, reason: 'marker line never echoed');
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      final termFinder = find.byKey(Key('ghostty-terminal-$sessionId'));
      expect(termFinder, findsOneWidget);
      final rect = tester.getRect(termFinder);

      // Gutter LONG-PRESS (≥500ms) then drag a tall band from near the top —
      // covers the wrapped marker rows wherever exactly they landed.
      final gx = rect.right - 14;
      final gy = rect.top + rect.height * 0.05;
      final gg = await tester.startGesture(Offset(gx, gy));
      await tester.pump(const Duration(milliseconds: 700));
      for (var i = 1; i <= 10; i++) {
        await gg.moveTo(Offset(gx, gy + rect.height * 0.05 * i));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gg.up();
      await tester.pump(const Duration(milliseconds: 200));

      debugPrint('WRAPJOIN copied="$copied"');
      expect(copied, isNotNull, reason: 'gutter copy wrote nothing');
      expect(
        copied!.contains(_marker),
        isTrue,
        reason:
            'the soft-wrapped line was not joined into one logical line — a '
            "'\\n' (or truncation) sits inside the marker. copied=\"$copied\"",
      );
    },
  );
}
