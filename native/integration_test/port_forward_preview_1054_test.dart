// On-emulator: port-forward sheet live preview + direction semantics (#1054).
//
// UI-only refinement over #1047. Drives the real app on the emulator: connect,
// open the Port forwards sheet, type 8888 / hostname / 8250, and assert the
// add-form effect line reads `8888  →  hostname:8250` with a plain-language
// direction sentence naming the session host. Then Add and assert the list row
// renders the same compact mapping. The sheet is HELD on screen (~8s) at each
// checkpoint so an external `scripts/emu-shot.sh` captures the review artifact.

@Tags(['integration'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/sessions.dart';

import 'support/connect_helpers.dart';

const _slice = Duration(milliseconds: 500);

Future<bool> _pumpUntil(
  WidgetTester tester,
  bool Function() test, {
  int maxSlices = 80,
}) async {
  for (var i = 0; i < maxSlices; i++) {
    await tester.pump(_slice);
    final trust = find.text('Trust + connect');
    if (trust.evaluate().isNotEmpty) {
      await tester.tap(trust.first);
      await tester.pump(const Duration(milliseconds: 300));
    }
    if (test()) return true;
  }
  return false;
}

Future<void> _openSessionMenu(WidgetTester tester) async {
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump(const Duration(milliseconds: 200));
  final trigger = find.byKey(const Key('session-bar-open-menu'));
  await tester.ensureVisible(trigger);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(trigger, warnIfMissed: false);
  await _pumpUntil(
    tester,
    () => find.byKey(const Key('session-menu-new')).evaluate().isNotEmpty,
    maxSlices: 20,
  );
}

String _previewText(WidgetTester tester) {
  return tester.widget<Text>(find.byKey(const Key('forward-preview'))).data!;
}

String _semanticsText(WidgetTester tester) {
  return tester
      .widget<Text>(find.byKey(const Key('forward-preview-semantics')))
      .data!;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'port-forward sheet shows live 8888 → hostname:8250 preview + semantics (#1054)',
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
      final reached = await _pumpUntil(
        tester,
        () =>
            find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty,
      );
      expect(reached, isTrue, reason: 'never reached the terminal screen');
      final entry = container.read(sessionsProvider).active;
      expect(entry, isNotNull, reason: 'no active session after connect');

      // Open the Port forwards sheet.
      await _openSessionMenu(tester);
      await tester.tap(find.byKey(const Key('session-menu-port-forwards')));
      final sheetUp = await _pumpUntil(
        tester,
        () =>
            find.byKey(const Key('port-forwards-sheet')).evaluate().isNotEmpty,
        maxSlices: 20,
      );
      expect(sheetUp, isTrue, reason: 'Port forwards sheet never opened');

      // Type the owner's example endpoints; the preview updates live.
      await tester.enterText(
        find.byKey(const Key('forward-local-port')),
        '8888',
      );
      await tester.enterText(
        find.byKey(const Key('forward-remote-host')),
        'hostname',
      );
      await tester.enterText(
        find.byKey(const Key('forward-remote-port')),
        '8250',
      );
      await tester.pump();

      expect(_previewText(tester), '8888  →  hostname:8250');
      final semantics = _semanticsText(tester);
      expect(semantics, contains('127.0.0.1:8888'));
      expect(semantics, contains('hostname:8250'));
      expect(semantics, contains(entry!.host),
          reason: 'semantics line must name the session host');

      // Screenshot hold #1: the add form WITH the live preview.
      debugPrint('PF_PREVIEW_HOLD_BEGIN');
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      debugPrint('PF_PREVIEW_HOLD_END');

      // Add it → the list row renders the same compact mapping.
      await tester.tap(find.byKey(const Key('forward-add-submit')));
      final rowUp = await _pumpUntil(
        tester,
        () => find.byKey(const Key('forward-row-8888')).evaluate().isNotEmpty,
        maxSlices: 30,
      );
      expect(rowUp, isTrue, reason: 'forward row never rendered');
      expect(find.text('8888  →  hostname:8250'), findsOneWidget);

      // Screenshot hold #2: the list row mapping.
      debugPrint('PF_ROW_HOLD_BEGIN');
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      debugPrint('PF_ROW_HOLD_END');
    },
  );
}
