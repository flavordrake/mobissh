// On-emulator smoke for the shared color picker (#1030).
//
// Flow: open the new-connection editor → open the shared picker from the
// color section's custom swatch → interact with the HSV surface (real gesture
// routing, not a widget-test synthetic) → type a custom hex → Apply →
// Save & connect → assert the SESSION BAR swatch renders the picked color
// (the "live preview of where the color lands" contract, end to end through
// SavedProfile.color → connect seeding → sessionColorProvider).
//
// Screenshot window: while the picker sheet is open the test prints
// PICKER1030_SHOT_WINDOW_OPEN and holds ~30s so the runner can take
// `scripts/emu-shot.sh picker-1030` for thumb-target review.
//
// Network: scripts/native-connect-test.sh sets up
//   emulator 127.0.0.1:2222 → (adb reverse → socat) → test-sshd:22
// Credentials: testuser/testpass (see CLAUDE.md → Test SSH).

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
const _pickedHex = '#ff3366';
const _pickedColor = Color(0xFFFF3366);

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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'picker: HSV + hex → Apply → connect → session bar shows the color (#1030)',
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

      // Editor with connection fields filled but NOT yet submitted.
      await openNewConnectionEditor(tester);
      await tester.enterText(
        find.byKey(const Key('profile-editor-host')),
        '127.0.0.1',
      );
      await tester.enterText(
        find.byKey(const Key('profile-editor-port')),
        '2222',
      );
      await tester.enterText(
        find.byKey(const Key('profile-editor-username')),
        'testuser',
      );
      await tester.enterText(
        find.byKey(const Key('profile-editor-password')),
        'testpass',
      );
      await tester.pump(const Duration(milliseconds: 300));

      // Open the shared picker from the color section's custom swatch.
      final custom = find.byKey(const Key('profile-editor-color-custom'));
      await tester.ensureVisible(custom);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(custom, warnIfMissed: false);
      final pickerOpened = await _pumpUntil(
        tester,
        () =>
            find.byKey(const Key('color-picker-panel')).evaluate().isNotEmpty,
        maxSlices: 20,
      );
      expect(pickerOpened, isTrue, reason: 'picker sheet never opened');

      // Real-gesture HSV interaction: tap inside the SV square and the hue
      // bar; the hex field must track (proves the CustomPaint surfaces receive
      // touches through the sheet, which widget tests cannot fully vouch for).
      final hexField = find.byKey(const Key('color-picker-hex'));
      String hexText() =>
          tester.widget<TextField>(hexField).controller?.text ?? '';
      final beforeSv = hexText();
      final svRect = tester.getRect(find.byKey(const Key('color-picker-sv')));
      await tester.tapAt(svRect.center + const Offset(40, -30));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        hexText(),
        isNot(beforeSv),
        reason: 'SV square tap did not change the color on device',
      );
      final beforeHue = hexText();
      await tester.tapAt(
        tester.getCenter(find.byKey(const Key('color-picker-hue'))),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        hexText(),
        isNot(beforeHue),
        reason: 'hue slider tap did not change the color on device',
      );

      // Screenshot HOLD: picker open with a live selection for emu-shot.
      debugPrint('PICKER1030_SHOT_WINDOW_OPEN');
      for (var i = 0; i < 60; i++) {
        await tester.pump(_slice);
      }
      debugPrint('PICKER1030_SHOT_WINDOW_CLOSED');

      // Deterministic final value via hex entry, then Apply. Focusing the hex
      // field raises the REAL soft keyboard on-device, which occludes the
      // action row (first run failed exactly here: the apply tap derived an
      // offset that no longer hit-tested) — dismiss the keyboard and re-reveal
      // Apply inside the sheet's scroll view before tapping.
      await tester.enterText(hexField, _pickedHex);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump(const Duration(milliseconds: 500));
      final apply = find.byKey(const Key('color-picker-apply'));
      await tester.ensureVisible(apply);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(apply, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 500));

      // The editor's backing hex field carries the picked value.
      final editorField = tester.widget<TextField>(
        find.byKey(const Key('profile-editor-color')),
      );
      expect(editorField.controller?.text, _pickedHex);

      // Save & connect.
      final submit = find.byKey(const Key('connect-submit'));
      await tester.ensureVisible(submit);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(submit);
      final reached = await _pumpUntil(
        tester,
        () => find
            .byKey(const Key('session-menu-button'))
            .evaluate()
            .isNotEmpty,
      );
      expect(reached, isTrue, reason: 'never reached the terminal screen');
      final entry = container.read(sessionsProvider).active;
      expect(entry, isNotNull, reason: 'no active session after connect');

      // The session bar swatch — where the profile color lands — must render
      // the picked color, not the theme-accent fallback.
      final swatch = find.byKey(const Key('session-bar-swatch'));
      expect(swatch, findsOneWidget, reason: 'session bar swatch missing');
      final decoration =
          tester.widget<Container>(swatch).decoration! as BoxDecoration;
      expect(
        decoration.color,
        _pickedColor,
        reason: 'session bar swatch does not show the picked profile color',
      );

      // Teardown: close the session so the suite leaves a clean slate.
      final notifier = container.read(sessionsProvider.notifier);
      notifier.close(entry!.id);
      await _pumpUntil(
        tester,
        () => container.read(sessionsProvider).entries.isEmpty,
        maxSlices: 20,
      );
    },
  );
}
