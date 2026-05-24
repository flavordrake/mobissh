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
        home: Scaffold(body: SettingsPanel()),
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

    // Open the ExpansionTile so the SwitchListTile is in the tree.
    await tester.tap(find.byKey(const ValueKey('settings-section')));
    await tester.pump(const Duration(milliseconds: 300));

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

    await tester.tap(find.byKey(const ValueKey('settings-section')));
    await tester.pump(const Duration(milliseconds: 300));

    final toggle = find.byKey(const ValueKey('keepalive-toggle'));
    final widget = tester.widget<SwitchListTile>(toggle);
    expect(widget.value, isFalse);
  });

  testWidgets('tapping toggle persists the new value', (tester) async {
    await pumpSettings(tester);

    // Open the ExpansionTile and wait for its expand animation to settle so
    // the inner SwitchListTile is hit-testable.
    await tester.tap(find.byKey(const ValueKey('settings-section')));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

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
