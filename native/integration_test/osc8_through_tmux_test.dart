// On-emulator END-TO-END validation of the DA2 hyperlink-advertise fix
// (#767 / PR #771). The owner's EXACT failing scenario: an OSC-8-emitting tool
// runs INSIDE tmux, and tmux only forwards OSC-8 to a client that advertises the
// `hyperlinks` feature — which tmux 3.4 enables from the DA2 reply (a client
// answering `ESC[>84;…c` identifies as tmux → gets `hyperlinks`). MobiSSH's
// Da2HyperlinkResponder intercepts tmux's DA2 query and answers `>84`, so tmux
// FORWARDS the OSC-8 instead of stripping it.
//
// This test connects, starts tmux, printfs an OSC-8 hyperlink whose visible text
// wraps, and asserts the controller exposes an `osc8` anchor with the EXACT full
// URI. That can ONLY happen if tmux forwarded the hyperlink to flterm — i.e. the
// DA2 responder worked end-to-end through the real SSH→tmux→flterm chain (NOT a
// synthetic printf straight to flterm). If the responder fails, tmux strips the
// link and no osc8 anchor appears (the device bug behind 0.1.10+22..+24).
//
// Run: scripts/native-connect-test.sh integration_test/osc8_through_tmux_test.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'an OSC-8 hyperlink emitted INSIDE tmux is forwarded to flterm and detected '
    '(DA2 hyperlink-advertise, #771)',
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
      expect(out.isNotEmpty, isTrue, reason: 'dead PTY');

      // Start tmux — its DA2 query fires on attach; the responder must answer >84
      // so tmux enables `hyperlinks` for this client and forwards OSC-8.
      entry.proxy.sendInput(
        Uint8List.fromList(utf8.encode('tmux new-session -A -s u\n')),
      );
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }

      const fullUri =
          'https://mobissh.tailbe5094.ts.net/mobissh-native-20260605T142124+0000.apk';
      const visible = fullUri; // long visible text → wraps in the pane
      entry.proxy.sendInput(Uint8List.fromList(utf8.encode('clear\n')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      // Emit an OSC-8 hyperlink from INSIDE tmux.
      final printfCmd =
          "printf '\\033]8;;$fullUri\\033\\\\$visible\\033]8;;\\033\\\\\\n'\n";
      entry.proxy.sendInput(Uint8List.fromList(utf8.encode(printfCmd)));

      bool detected() => controller.anchors
          .any((a) => a.patternId == 'osc8' && a.payload == fullUri);
      for (var i = 0; i < 60 && !detected(); i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(
        detected(),
        isTrue,
        reason:
            'OSC-8 emitted inside tmux was NOT detected as an osc8 anchor — tmux '
            'stripped the hyperlink, so the DA2 hyperlink-advertise did not take '
            'effect end-to-end (#771)',
      );
      final anchor =
          controller.anchors.firstWhere((a) => a.payload == fullUri);
      debugPrint('OSC8TMUX patternId=${anchor.patternId} '
          'ranges=${anchor.ranges.length} payload=${anchor.payload}');
    },
  );
}
