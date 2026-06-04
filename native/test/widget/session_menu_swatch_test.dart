// Per-row profile color swatch on the session menu (#739).
//
// Owner: in the session menu, each listed session should show its profile color
// swatch next to its row — for quick visual identification across multiple
// sessions, matching the colored dot already shown in the profile list + the
// session bar `● host` (#653).
//
// The color source is the per-session profile color seeded on connect (#653),
// read via `sessionColorProvider(sessionId)`. A session whose profile carries no
// color renders a NEUTRAL fallback swatch (theme `outlineVariant`) — NOT a real
// color, and NOT the theme accent the session bar falls back to. Issue #739:
// "don't force a default that looks like a real color".
//
// These tests assert per-row behaviour: with multiple sessions of different
// profile colors, each row's swatch shows THAT session's color; a colorless
// session shows the neutral fallback. The swatch must not disrupt the existing
// row (title, selected highlight, tap-to-activate).

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

Future<void> _pumpFrames(WidgetTester tester, {int count = 8}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Color? _swatchColor(WidgetTester tester, String sessionId) {
  final container = tester.widget<Container>(
    find.byKey(Key('session-menu-swatch-$sessionId')),
  );
  final decoration = container.decoration as BoxDecoration;
  return decoration.color;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Session menu profile color swatch (#739)', () {
    testWidgets(
      'each session row renders a swatch in that session profile color',
      (tester) async {
        final container = _makeContainer();
        final a = _add(container, 'host-a');
        final b = _add(container, 'host-b');

        const colorA = Color(0xFFFF8800);
        const colorB = Color(0xFF2196F3);
        container
            .read(sessionAppearanceProvider.notifier)
            .setColor(a.id, colorA);
        container
            .read(sessionAppearanceProvider.notifier)
            .setColor(b.id, colorB);

        await tester.pumpWidget(_host(container: container));
        await tester.tap(find.byKey(const Key('open-menu')));
        await _pumpFrames(tester);

        // One swatch per row, keyed by that row's session id.
        expect(find.byKey(Key('session-menu-swatch-${a.id}')), findsOneWidget);
        expect(find.byKey(Key('session-menu-swatch-${b.id}')), findsOneWidget);

        // Each swatch shows THAT session's profile color (no leakage).
        expect(_swatchColor(tester, a.id), colorA);
        expect(_swatchColor(tester, b.id), colorB);
      },
    );

    testWidgets('a colorless session renders the neutral fallback swatch', (
      tester,
    ) async {
      final container = _makeContainer();
      final a = _add(container, 'host-a');
      const colorA = Color(0xFFFF8800);
      container.read(sessionAppearanceProvider.notifier).setColor(a.id, colorA);
      // b gets no color seeded — its profile carries none.
      final b = _add(container, 'host-b');

      await tester.pumpWidget(_host(container: container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      // The neutral fallback is the theme's outlineVariant — a muted, clearly
      // non-real-color tone, distinct from the real color on row a.
      final neutral = Theme.of(
        tester.element(find.byKey(Key('session-menu-swatch-${b.id}'))),
      ).colorScheme.outlineVariant;

      expect(_swatchColor(tester, b.id), neutral);
      expect(_swatchColor(tester, a.id), colorA);
      // The fallback is NOT a real-looking color (must differ from the seeded one).
      expect(_swatchColor(tester, b.id), isNot(colorA));
    });

    testWidgets('the row still activates its session on tap', (tester) async {
      final container = _makeContainer();
      final a = _add(container, 'host-a');
      _add(container, 'host-b'); // b is active

      await tester.pumpWidget(_host(container: container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      // Tapping the (non-active) row a activates it.
      await tester.tap(find.byKey(Key('session-menu-row-${a.id}')));
      await _pumpFrames(tester);

      expect(container.read(sessionsProvider).activeId, a.id);
    });
  });
}
