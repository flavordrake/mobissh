// On-emulator "Not a URL" detection-exception flow (#995).
//
// Validates the device-class behaviour end-to-end against test-sshd:
//   1. a printed URL is detected → its right-edge gutter chip renders
//   2. tapping the chip opens the URL action menu; tapping the LAST item
//      ("Not a URL") persists a detection exception and the chip disappears
//      IMMEDIATELY — while the scanner's anchor is untouched (the suppression
//      is the app-layer visibility gate, composing with #990, not a scanner
//      change)
//   3. close + reconnect → the SAME text is detected by the scanner again but
//      shows NO affordance (the exception persisted across sessions)
//   4. removing the exception in Settings restores detection: a third session
//      printing the same URL gets its chip back
//
// The viewport is `clear`ed before each echo so the ONLY detectable content on
// screen is the printed URL (login MOTD noise scrolls away; the gutter marks
// viewport rows only) — chip presence ⇔ the URL's affordance.
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
// Run: scripts/native-connect-test.sh integration_test/detection_exception_995_test.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/detection_exceptions_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import 'support/connect_helpers.dart';

const _url = 'https://example.com/mobissh/995/exception';

Finder _gutterChips() => find.byWidgetPredicate(
  (w) => w.key != null && w.key.toString().contains('gutter-mark-'),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Not a URL persists an exception, suppresses across reconnect, and '
    'Settings remove restores detection (#995)',
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

      Future<SessionEntry> connect() async {
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
          if (find
              .byKey(const Key('session-menu-button'))
              .evaluate()
              .isNotEmpty) {
            connected = true;
            break;
          }
        }
        expect(connected, isTrue, reason: 'never reached the terminal screen');
        final entry = container.read(sessionsProvider).active;
        expect(entry, isNotNull, reason: 'no active session after connect');
        // Wait for the live shell prompt (bytes flowing).
        final out = <int>[];
        final sub = entry!.proxy.output.listen(out.addAll);
        for (var i = 0; i < 40 && out.isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        await sub.cancel();
        expect(out.isNotEmpty, isTrue, reason: 'no shell prompt — dead PTY');
        return entry;
      }

      TerminalController controllerFor(SessionEntry entry) {
        TerminalController? c;
        c = GhosttyTerminalView.debugControllers[entry.id];
        expect(c, isNotNull, reason: 'no ghostty controller for session');
        return c!;
      }

      /// Clear the viewport, print the URL, and wait for the scanner's anchor.
      Future<void> printAndDetect(SessionEntry entry) async {
        final controller = controllerFor(entry);
        entry.proxy.sendInput(Uint8List.fromList(utf8.encode('clear\n')));
        await tester.pump(const Duration(milliseconds: 800));
        entry.proxy.sendInput(
          Uint8List.fromList(utf8.encode('echo M995 $_url\n')),
        );
        bool anchored() => controller.anchors.any((a) => a.payload == _url);
        for (var i = 0; i < 40 && !anchored(); i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(
          anchored(),
          isTrue,
          reason: 'the printed URL was never detected (no anchor)',
        );
      }

      Future<bool> chipsAppear() async {
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 300));
          if (_gutterChips().evaluate().isNotEmpty) return true;
        }
        return false;
      }

      Future<bool> chipsGone() async {
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 300));
          if (_gutterChips().evaluate().isEmpty) return true;
        }
        return false;
      }

      // 1) First session: detect → chip present.
      final first = await connect();
      await printAndDetect(first);
      expect(
        await chipsAppear(),
        isTrue,
        reason: 'no gutter chip for the detected URL',
      );

      // 2) Chip tap → URL action menu → LAST item "Not a URL".
      await tester.pump(const Duration(milliseconds: 600)); // settle scroll
      await tester.tap(_gutterChips().first);
      var menuShown = false;
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 300));
        if (find.byKey(const Key('url-action-menu')).evaluate().isNotEmpty) {
          menuShown = true;
          break;
        }
      }
      expect(menuShown, isTrue, reason: 'chip tap never opened the URL menu');
      expect(
        find.byKey(const Key('url-action-not-url')),
        findsOneWidget,
        reason: 'the URL menu is missing the Not a URL item',
      );
      // Screenshot window: hold the open menu (stays under its 6s
      // auto-dismiss) so the orchestrator can `scripts/emu-shot.sh` it.
      debugPrint('SHOT995 menu-open hold');
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.tap(find.byKey(const Key('url-action-not-url')));
      await tester.pump(const Duration(milliseconds: 500));

      // Persisted + immediately suppressed: record exists, chips vanish, and
      // the SCANNER anchor is untouched (app-layer gate, not a scanner change).
      final exceptions = container.read(detectionExceptionsProvider);
      expect(exceptions, hasLength(1));
      expect(exceptions.single.matchedText, _url);
      expect(
        await chipsGone(),
        isTrue,
        reason: 'gutter chip survived the Not a URL report',
      );
      expect(
        controllerFor(first).anchors.any((a) => a.payload == _url),
        isTrue,
        reason:
            'the scanner anchor disappeared — suppression must be the '
            'app-layer visibility gate, not a scanner change',
      );

      // 3) Reconnect: the same text is re-detected but shows NO affordance.
      container.read(sessionsProvider.notifier).close(first.id);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (find.byKey(const Key('new-connection')).evaluate().isNotEmpty) {
          break;
        }
      }
      final second = await connect();
      await printAndDetect(second);
      // Give the gutter every chance to (wrongly) render, then assert absence.
      await tester.pump(const Duration(seconds: 2));
      expect(
        _gutterChips(),
        findsNothing,
        reason: 'the persisted exception did not suppress after reconnect',
      );

      // 4) Remove in Settings → detection returns in a fresh session.
      container.read(sessionsProvider.notifier).close(second.id);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (find.byKey(const Key('home-nav-settings')).evaluate().isNotEmpty) {
          break;
        }
      }
      await tester.tap(find.byKey(const Key('home-nav-settings')));
      await tester.pump(const Duration(milliseconds: 800));
      final removeButton = find.byKey(
        const ValueKey('detection-exception-remove-0'),
      );
      await tester.ensureVisible(removeButton);
      await tester.pump(const Duration(milliseconds: 300));
      // Screenshot window: hold the rendered exceptions list.
      debugPrint('SHOT995 settings-list hold');
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.tap(removeButton);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (container.read(detectionExceptionsProvider).isEmpty) break;
      }
      expect(
        container.read(detectionExceptionsProvider),
        isEmpty,
        reason: 'Settings remove did not clear the exception',
      );
      await tester.tap(find.byKey(const Key('home-nav-profiles')));
      await tester.pump(const Duration(milliseconds: 800));

      final third = await connect();
      await printAndDetect(third);
      expect(
        await chipsAppear(),
        isTrue,
        reason: 'detection did not return after removing the exception',
      );
    },
  );
}
