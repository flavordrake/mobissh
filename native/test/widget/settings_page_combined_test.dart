// Widget tests for the #897 settings reorg: ONE flat Settings page that folds
// the Diagnostics section in at the bottom.
//
// Asserts:
//   - Every setting is a TOP-LEVEL control — present with NO expander tap.
//   - The terminal-engine subtitle says Ghostty is the default (was wrongly
//     "xterm is the default").
//   - The folded-in Diagnostics section's controls are present.
//   - The destructive "Reset settings" action confirms, then returns a sample
//     pref (font size) to its default.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/state/ui_prefs_providers.dart';
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
      'terminal-backend-selector',
      'tmux-control-mode-toggle',
      'detection-master-toggle',
      'detection-url-toggle',
      'detection-path-toggle',
      'settings-reset-button',
    ]) {
      expect(
        find.byKey(ValueKey(key)),
        findsOneWidget,
        reason: '$key must be a visible top-level control',
      );
    }
  });

  testWidgets('terminal-engine subtitle says Ghostty is the default', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await _pumpPage(tester, container);

    // #897 fix: the stale "xterm is the default" copy is gone.
    expect(find.textContaining('Ghostty (flterm) is the default'), findsOneWidget);
    expect(find.textContaining('xterm is the default'), findsNothing);
  });

  testWidgets('Diagnostics section is folded into the Settings page', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await _pumpPage(tester, container);

    for (final key in const [
      'diagnostics-section',
      'connection-audit-button',
      'force-upload-button',
      'share-feedback-button',
    ]) {
      expect(
        find.byKey(ValueKey(key)),
        findsOneWidget,
        reason: '$key must be present in the folded-in diagnostics section',
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
