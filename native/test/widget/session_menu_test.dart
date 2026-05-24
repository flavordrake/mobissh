// Widget tests for the SessionMenu (#518).
//
// Covers the contract the PWA's session menu exposes:
//   - tap-to-switch sets activeSessionId and dismisses the menu
//   - long-press opens the contextual actions sheet
//   - the keybar toggle flips the global preference
//   - the close affordance on each row removes the entry
//
// Tests pump bounded frames rather than `pumpAndSettle` — the modal bottom
// sheet's slide animation can leave the harness waiting forever for a
// terminal frame that never arrives, matching the keepalive-toggle test
// pattern.

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
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
    ],
  );
  addTearDown(() async {
    await pair.dispose();
  });
  return container;
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

  group('SessionMenu', () {
    testWidgets('lists every session and tapping a row activates + closes',
        (tester) async {
      final container = _makeContainer();
      addTearDown(container.dispose);

      final notifier = container.read(sessionsProvider.notifier);
      final a = notifier.addOrActivate(const SshConnectParams(
        host: 'host-a',
        port: 22,
        username: 'u',
        auth: SshAuth.password('p'),
      ));
      final b = notifier.addOrActivate(const SshConnectParams(
        host: 'host-b',
        port: 22,
        username: 'u',
        auth: SshAuth.password('p'),
      ));
      expect(container.read(sessionsProvider).activeId, b.id);

      await tester.pumpWidget(_host(container: container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      expect(find.byKey(const Key('session-menu')), findsOneWidget);
      expect(find.byKey(Key('session-menu-row-${a.id}')), findsOneWidget);
      expect(find.byKey(Key('session-menu-row-${b.id}')), findsOneWidget);

      await tester.tap(find.byKey(Key('session-menu-row-${a.id}')));
      await _pumpFrames(tester);

      expect(container.read(sessionsProvider).activeId, a.id);
      expect(find.byKey(const Key('session-menu')), findsNothing);
    });

    testWidgets('long-press opens the contextual actions sheet',
        (tester) async {
      final container = _makeContainer();
      addTearDown(container.dispose);

      final entry = container.read(sessionsProvider.notifier).addOrActivate(
            const SshConnectParams(
              host: 'host-a',
              port: 22,
              username: 'u',
              auth: SshAuth.password('p'),
            ),
          );

      await tester.pumpWidget(_host(container: container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      await tester.longPress(find.byKey(Key('session-menu-row-${entry.id}')));
      await _pumpFrames(tester);

      expect(find.byKey(const Key('session-menu-action-disconnect')),
          findsOneWidget);
      expect(find.byKey(const Key('session-menu-action-close')),
          findsOneWidget);
    });

    testWidgets('keybar toggle flips keybarVisibleProvider', (tester) async {
      final container = _makeContainer();
      addTearDown(container.dispose);

      container.read(sessionsProvider.notifier).addOrActivate(
            const SshConnectParams(
              host: 'host-a',
              port: 22,
              username: 'u',
              auth: SshAuth.password('p'),
            ),
          );

      // Default is visible.
      expect(container.read(keybarVisibleProvider), isTrue);

      await tester.pumpWidget(_host(container: container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      await tester.tap(find.byKey(const Key('session-menu-keybar-toggle')));
      await _pumpFrames(tester);

      expect(container.read(keybarVisibleProvider), isFalse);
    });

    testWidgets('tapping the close button removes the entry', (tester) async {
      final container = _makeContainer();
      addTearDown(container.dispose);

      final entry = container.read(sessionsProvider.notifier).addOrActivate(
            const SshConnectParams(
              host: 'host-a',
              port: 22,
              username: 'u',
              auth: SshAuth.password('p'),
            ),
          );

      await tester.pumpWidget(_host(container: container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      await tester.tap(find.byKey(Key('session-menu-close-${entry.id}')));
      await _pumpFrames(tester);

      expect(container.read(sessionsProvider).entries, isEmpty);
    });
  });

  group('SessionEntry label', () {
    test('falls back to user@host:port when no title is supplied', () {
      final container = _makeContainer();
      addTearDown(container.dispose);
      final entry = container.read(sessionsProvider.notifier).addOrActivate(
            const SshConnectParams(
              host: 'h',
              port: 22,
              username: 'u',
              auth: SshAuth.password('p'),
            ),
          );
      expect(entry.label, 'u@h:22');
    });

    test('uses the supplied title when present (#518)', () {
      final container = _makeContainer();
      addTearDown(container.dispose);
      final entry = container.read(sessionsProvider.notifier).addOrActivate(
            const SshConnectParams(
              host: 'h',
              port: 22,
              username: 'u',
              auth: SshAuth.password('p'),
            ),
            title: 'Work box',
          );
      expect(entry.label, 'Work box');
    });

    test('ignores empty title and falls back', () {
      final container = _makeContainer();
      addTearDown(container.dispose);
      final entry = container.read(sessionsProvider.notifier).addOrActivate(
            const SshConnectParams(
              host: 'h',
              port: 22,
              username: 'u',
              auth: SshAuth.password('p'),
            ),
            title: '',
          );
      expect(entry.label, 'u@h:22');
    });
  });
}
