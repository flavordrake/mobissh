// Widget tests for the Settings panel keep-alive toggle (#512).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/keepalive_providers.dart';
import 'package:mobissh/ui/settings_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> pumpSettings(WidgetTester tester) async {
  await tester.pumpWidget(
    const ProviderScope(
      child: MaterialApp(
        // Mirror production (settings_screen.dart): the panel lives in a
        // SingleChildScrollView. Mounting it bare in a bounded Scaffold body
        // overflows now that the panel has grown (the Detection group, #888).
        home: Scaffold(
          body: SingleChildScrollView(child: SettingsPanel()),
        ),
      ),
    ),
  );
  // Bounded pumps to let the hydrate Future + initial frame resolve.
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('toggle defaults to ON when no preference is stored',
      (tester) async {
    await pumpSettings(tester);

    // #897: the toggle is a top-level control — visible with no expander tap.
    final toggle = find.byKey(const ValueKey('keepalive-toggle'));
    expect(toggle, findsOneWidget);
    final widget = tester.widget<SwitchListTile>(toggle);
    expect(widget.value, isTrue, reason: 'default is ON');
  });

  testWidgets('toggle reflects a stored OFF preference', (tester) async {
    SharedPreferences.setMockInitialValues({
      keepaliveEnabledPrefKey: false,
    });

    await pumpSettings(tester);

    final toggle = find.byKey(const ValueKey('keepalive-toggle'));
    final widget = tester.widget<SwitchListTile>(toggle);
    expect(widget.value, isFalse);
  });

  testWidgets('tapping toggle persists the new value', (tester) async {
    await pumpSettings(tester);

    await tester.tap(find.byKey(const ValueKey('keepalive-toggle')));
    // Settle the StateNotifier emission and SharedPreferences write.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(keepaliveEnabledPrefKey), isFalse);

    final toggle = find.byKey(const ValueKey('keepalive-toggle'));
    final widget = tester.widget<SwitchListTile>(toggle);
    expect(widget.value, isFalse);
  });
}
