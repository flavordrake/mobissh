// Session-menu per-session theme + font controls (#601, #571).
//
// The menu's Theme cycle row and the NEW font-size stepper must mutate ONLY the
// ACTIVE session. With two sessions open, operating the menu on the active one
// must leave the other's theme + font unchanged (isolation, not just presence).

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

      expect(find.byKey(const Key('session-menu-fontsize')), findsOneWidget);

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

    testWidgets('theme cycle changes ONLY the active session', (tester) async {
      final container = _makeContainer();
      final a = _add(container, 'host-a');
      final b = _add(container, 'host-b'); // b active

      await tester.pumpWidget(_host(container: container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      await tester.tap(find.byKey(const Key('session-menu-theme-cycle')));
      await _pumpFrames(tester);

      expect(container.read(sessionThemeProvider(b.id)), 1);
      expect(
        container.read(sessionThemeProvider(a.id)),
        terminalThemeDefault,
        reason: 'inactive session theme must be unchanged',
      );
    });

    testWidgets('font stepper shows the active session current value', (
      tester,
    ) async {
      final container = _makeContainer();
      _add(container, 'host-a');
      final b = _add(container, 'host-b');
      container.read(sessionAppearanceProvider.notifier).setFontSize(b.id, 17);

      await tester.pumpWidget(_host(container: container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      expect(find.text('17'), findsOneWidget);
    });
  });
}
