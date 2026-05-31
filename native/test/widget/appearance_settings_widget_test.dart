// Widget tests for #552 terminal-appearance UI:
//   - SettingsPanel exposes a font-size slider that reflects + persists value.
//   - SessionMenu exposes a theme-cycle item that advances the palette.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/ui_prefs_providers.dart';
import 'package:mobissh/ui/session_menu.dart';
import 'package:mobissh/ui/settings_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpFrames(WidgetTester tester, {int count = 8}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('SettingsPanel font size', () {
    testWidgets('renders the font-size slider with the default value', (
      tester,
    ) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: Scaffold(body: SettingsPanel())),
        ),
      );
      await _pumpFrames(tester);

      await tester.tap(find.byKey(const ValueKey('settings-section')));
      await _pumpFrames(tester, count: 12);

      final slider = find.byKey(const ValueKey('font-size-slider'));
      expect(slider, findsOneWidget);
      final widget = tester.widget<Slider>(slider);
      expect(widget.value, fontSizeDefault);
      expect(widget.min, kFontSizeMin);
      expect(widget.max, kFontSizeMax);
    });

    testWidgets('reflects a stored font size', (tester) async {
      SharedPreferences.setMockInitialValues({fontSizePrefKey: 22.0});

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: Scaffold(body: SettingsPanel())),
        ),
      );
      await _pumpFrames(tester);

      await tester.tap(find.byKey(const ValueKey('settings-section')));
      await _pumpFrames(tester, count: 12);

      final widget = tester.widget<Slider>(
        find.byKey(const ValueKey('font-size-slider')),
      );
      expect(widget.value, 22.0);
    });

    testWidgets('dragging the slider persists a new value', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: SettingsPanel())),
        ),
      );
      await _pumpFrames(tester);

      await tester.tap(find.byKey(const ValueKey('settings-section')));
      await _pumpFrames(tester, count: 12);

      // Drag the slider thumb to the far right (max).
      final slider = find.byKey(const ValueKey('font-size-slider'));
      await tester.drag(slider, const Offset(500, 0));
      await _pumpFrames(tester);

      final value = container.read(fontSizeProvider);
      expect(value, kFontSizeMax);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(fontSizePrefKey), kFontSizeMax);
    });
  });

  group('SessionMenu theme cycle', () {
    Widget host(ProviderContainer container) {
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Center(
                child: ElevatedButton(
                  key: const Key('open-menu'),
                  onPressed: () => showSessionMenu(ctx),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
    }

    ProviderContainer makeContainer() {
      final pair = InMemoryGatewayPair();
      final container = ProviderContainer(
        overrides: [taskSshGatewayProvider.overrideWithValue(pair.uiSide)],
      );
      addTearDown(() async => pair.dispose());
      return container;
    }

    testWidgets('theme-cycle item present and advances palette', (
      tester,
    ) async {
      final container = makeContainer();
      addTearDown(container.dispose);

      container
          .read(sessionsProvider.notifier)
          .addOrActivate(
            const SshConnectParams(
              host: 'h',
              port: 22,
              username: 'u',
              auth: SshAuth.password('p'),
            ),
          );

      expect(container.read(terminalThemeProvider), terminalThemeDefault);

      await tester.pumpWidget(host(container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      final item = find.byKey(const Key('session-menu-theme-cycle'));
      expect(item, findsOneWidget);

      await tester.tap(item);
      await _pumpFrames(tester);

      expect(container.read(terminalThemeProvider), 1);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(terminalThemePrefKey), 1);
    });
  });
}
