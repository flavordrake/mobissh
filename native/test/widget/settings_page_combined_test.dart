// Widget tests for the Settings page (#897 reorg + #966 Play-Store cleanup).
//
// Asserts:
//   - Every user SETTING is a TOP-LEVEL control — present with NO expander tap.
//   - The terminal-engine SELECTOR is gone (#966 — Ghostty-only release; xterm
//     is an internal fallback, not user-facing).
//   - Diagnostics moved into a COLLAPSED "Advanced" expander: hidden until the
//     expander is tapped, then present.
//   - The destructive "Reset settings" action confirms, then returns a sample
//     pref (font size) to its default.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/state/detection_exceptions_providers.dart';
import 'package:mobissh/state/detection_style_providers.dart';
import 'package:mobissh/state/ui_prefs_providers.dart';
import 'package:mobissh/ui/detection_lab_screen.dart';
import 'package:mobissh/ui/settings_screen.dart';

Future<void> _pumpFrames(WidgetTester tester, {int count = 10}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _pumpPage(WidgetTester tester, ProviderContainer container) async {
  // Tall viewport so the whole flat page (incl. the bottom reset button + the
  // folded-in diagnostics block) lays out on-screen and is hit-testable.
  tester.view.physicalSize = const Size(1000, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: SettingsScreen())),
    ),
  );
  await _pumpFrames(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('every setting is a top-level control (no expander tap)', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await _pumpPage(tester, container);

    // Settings controls — all present without tapping any expander.
    for (final key in const [
      'app-version-tile',
      'keepalive-toggle',
      'battery-opt-tile',
      'font-size-slider',
      'tmux-control-mode-toggle',
      'detection-master-toggle',
      'detection-url-toggle',
      'detection-path-toggle',
      'detection-command-toggle',
      'settings-reset-button',
    ]) {
      expect(
        find.byKey(ValueKey(key)),
        findsOneWidget,
        reason: '$key must be a visible top-level control',
      );
    }
  });

  testWidgets('the terminal-engine selector is retired (#966 Ghostty-only)', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await _pumpPage(tester, container);

    // The user-facing selector is gone; xterm is an internal fallback only.
    expect(find.byKey(const ValueKey('terminal-backend-selector')), findsNothing);
    expect(find.byKey(const ValueKey('terminal-backend-tile')), findsNothing);
    expect(find.textContaining('xterm'), findsNothing);
    // Detection is no longer engine-qualified.
    expect(find.text('Detection'), findsOneWidget);
  });

  testWidgets('Diagnostics is tucked behind a collapsed Advanced expander', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await _pumpPage(tester, container);

    // Collapsed by default: the diagnostics controls are NOT on the page yet.
    expect(find.byKey(const ValueKey('diagnostics-section')), findsNothing);
    expect(find.byKey(const ValueKey('settings-advanced-tile')), findsOneWidget);

    // Expand Advanced → the folded-in diagnostics controls appear.
    await tester.tap(find.byKey(const ValueKey('settings-advanced-tile')));
    await _pumpFrames(tester);

    for (final key in const [
      'diagnostics-section',
      'connection-audit-button',
      'force-upload-button',
      'share-feedback-button',
    ]) {
      expect(
        find.byKey(ValueKey(key)),
        findsOneWidget,
        reason: '$key must appear once Advanced is expanded',
      );
    }
  });

  testWidgets('Reset settings confirms then returns a pref to default', (
    tester,
  ) async {
    // Seed a NON-default font size so the reset is observable.
    SharedPreferences.setMockInitialValues(<String, Object>{
      fontSizePrefKey: 22.0,
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await _pumpPage(tester, container);

    // Sanity: the stored non-default hydrated.
    expect(container.read(fontSizeProvider), 22.0);

    // Open the confirm dialog.
    await tester.tap(find.byKey(const ValueKey('settings-reset-button')));
    await _pumpFrames(tester);
    expect(find.byKey(const ValueKey('settings-reset-dialog')), findsOneWidget);

    // Confirm the reset.
    await tester.tap(find.byKey(const ValueKey('settings-reset-confirm')));
    await _pumpFrames(tester);

    // The sample pref is back to its documented default.
    expect(container.read(fontSizeProvider), fontSizeDefault);
  });

  testWidgets('#1031 slice 2: a Detection lab row opens the lab route', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await _pumpPage(tester, container);

    final row = find.byKey(const ValueKey('detection-lab-tile'));
    expect(row, findsOneWidget, reason: 'entry row under Detection');

    await tester.tap(row);
    await _pumpFrames(tester);
    expect(find.byType(DetectionLabScreen), findsOneWidget);
  });

  testWidgets('#1031 slice 2: Reset settings clears TUNED lab styles but '
      'authored exceptions survive', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await _pumpPage(tester, container);

    // Tune a lab style + author an exception report.
    await container
        .read(detectionStylesProvider.notifier)
        .setColorHex('url', '#e53935');
    await container.read(detectionExceptionsProvider.notifier).report(
          patternId: 'url',
          matchedText: 'https://not.a.link',
        );
    await _pumpFrames(tester);
    expect(container.read(detectionStylesProvider).isEmpty, isFalse);
    expect(container.read(detectionExceptionsProvider), hasLength(1));

    await tester.tap(find.byKey(const ValueKey('settings-reset-button')));
    await _pumpFrames(tester);
    await tester.tap(find.byKey(const ValueKey('settings-reset-confirm')));
    await _pumpFrames(tester);

    expect(
      container.read(detectionStylesProvider).isEmpty,
      isTrue,
      reason: 'tuned lab styles reset with settings',
    );
    expect(
      container.read(detectionExceptionsProvider),
      hasLength(1),
      reason: 'authored exception reports survive every reset (#995 rule)',
    );
  });

  testWidgets('Reset settings can be cancelled (no change)', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      fontSizePrefKey: 22.0,
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await _pumpPage(tester, container);
    expect(container.read(fontSizeProvider), 22.0);

    await tester.tap(find.byKey(const ValueKey('settings-reset-button')));
    await _pumpFrames(tester);

    // Cancel — Dialog dismisses, the pref is untouched.
    await tester.tap(find.text('Cancel'));
    await _pumpFrames(tester);

    expect(container.read(fontSizeProvider), 22.0);
  });
}
