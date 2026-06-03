// Session-menu per-session theme + font controls (#601, #571, #724).
//
// The menu's Theme PICKER (#724) and the font-size stepper must mutate ONLY the
// ACTIVE session. With two sessions open, operating the menu on the active one
// must leave the other's theme + font unchanged (isolation, not just presence).
//
// #724: the theme control is now a PICKER (bottom sheet of all palettes with the
// current marked), not a blind advance-to-next cycle; the font-size stepper no
// longer shows a numeric value (just − / +).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/ui_prefs_providers.dart';
import 'package:mobissh/ui/session_menu.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host({required ProviderContainer container}) {
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

ProviderContainer _makeContainer() {
  final pair = InMemoryGatewayPair();
  final container = ProviderContainer(
    overrides: [taskSshGatewayProvider.overrideWithValue(pair.uiSide)],
  );
  addTearDown(() async {
    await pair.dispose();
  });
  addTearDown(container.dispose);
  return container;
}

SessionEntry _add(ProviderContainer c, String host) {
  return c
      .read(sessionsProvider.notifier)
      .addOrActivate(
        SshConnectParams(
          host: host,
          port: 22,
          username: 'u',
          auth: const SshAuth.password('p'),
        ),
      );
}

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

  group('SessionMenu appearance controls', () {
    testWidgets('font + / - changes ONLY the active session', (tester) async {
      final container = _makeContainer();
      final a = _add(container, 'host-a');
      final b = _add(container, 'host-b'); // b active

      await tester.pumpWidget(_host(container: container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      // #724: the font-size control shows − / + with NO numeric value.
      expect(find.byKey(const Key('session-menu-fontsize')), findsNothing);
      expect(
        find.byKey(const Key('session-menu-fontsize-dec')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('session-menu-fontsize-inc')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('session-menu-fontsize-inc')));
      await _pumpFrames(tester);

      expect(
        container.read(sessionFontSizeProvider(b.id)),
        greaterThan(fontSizeDefault),
        reason: 'active session font should grow',
      );
      expect(
        container.read(sessionFontSizeProvider(a.id)),
        fontSizeDefault,
        reason: 'inactive session font must be unchanged',
      );

      await tester.tap(find.byKey(const Key('session-menu-fontsize-dec')));
      await tester.tap(find.byKey(const Key('session-menu-fontsize-dec')));
      await _pumpFrames(tester);

      expect(
        container.read(sessionFontSizeProvider(b.id)),
        lessThan(fontSizeDefault),
      );
      expect(container.read(sessionFontSizeProvider(a.id)), fontSizeDefault);
    });

    testWidgets('theme picker changes ONLY the active session (#724)', (
      tester,
    ) async {
      final container = _makeContainer();
      final a = _add(container, 'host-a');
      final b = _add(container, 'host-b'); // b active

      await tester.pumpWidget(_host(container: container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      // Tapping the theme control opens a picker rather than cycling.
      await tester.tap(find.byKey(const Key('session-menu-theme-cycle')));
      await _pumpFrames(tester);

      // Picker lists every palette; the current one is marked. Pick the third.
      expect(
        find.byKey(const Key('picker-option-0')),
        findsOneWidget,
        reason: 'picker should list palette options',
      );
      await tester.tap(find.byKey(const Key('picker-option-2')));
      await _pumpFrames(tester);

      expect(
        container.read(sessionThemeProvider(b.id)),
        2,
        reason: 'active session theme set to the picked palette',
      );
      expect(
        container.read(sessionThemeProvider(a.id)),
        terminalThemeDefault,
        reason: 'inactive session theme must be unchanged',
      );
    });

    testWidgets(
      'theme picker marks the active session current palette (#724)',
      (tester) async {
        final container = _makeContainer();
        _add(container, 'host-a');
        final b = _add(container, 'host-b');
        container.read(sessionAppearanceProvider.notifier).setTheme(b.id, 4);

        await tester.pumpWidget(_host(container: container));
        await tester.tap(find.byKey(const Key('open-menu')));
        await _pumpFrames(tester);

        // The control label reflects the active session's current palette.
        expect(find.text(terminalPalettes[4].label), findsWidgets);

        await tester.tap(find.byKey(const Key('session-menu-theme-cycle')));
        await _pumpFrames(tester);

        // The current palette's row carries the check (selected) icon.
        final selectedTile = tester.widget<ListTile>(
          find.byKey(const Key('picker-option-4')),
        );
        expect(
          selectedTile.selected,
          isTrue,
          reason: 'the current palette must be marked in the picker',
        );
      },
    );
  });
}
