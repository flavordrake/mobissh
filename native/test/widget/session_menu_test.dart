// Widget tests for the SessionMenu (#518).
//
// Covers the contract the PWA's session menu exposes:
//   - tap-to-switch sets activeSessionId and dismisses the menu
//   - the keybar toggle flips ONLY the active session's keybar (#573)
//   - the close affordance on each row removes the entry
//
// #817: the long-press contextual actions sheet was removed — the row's
// Disconnect/Close are now always-visible per-row affordances (the ✕ button,
// plus a Reconnect button for dropped sessions). A dropped session must be
// directly actionable, not hidden behind a long-press. The Active-Sessions UI
// state surface (status dot + per-state action) is covered by
// `session_menu_active_state_test.dart`.
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
    overrides: [taskSshGatewayProvider.overrideWithValue(pair.uiSide)],
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
    testWidgets('lists every session and tapping a row activates + closes', (
      tester,
    ) async {
      final container = _makeContainer();
      addTearDown(container.dispose);

      final notifier = container.read(sessionsProvider.notifier);
      final a = notifier.addOrActivate(
        const SshConnectParams(
          host: 'host-a',
          port: 22,
          username: 'u',
          auth: SshAuth.password('p'),
        ),
      );
      final b = notifier.addOrActivate(
        const SshConnectParams(
          host: 'host-b',
          port: 22,
          username: 'u',
          auth: SshAuth.password('p'),
        ),
      );
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

    testWidgets('each row exposes an always-visible close (✕) affordance (#817)', (
      tester,
    ) async {
      final container = _makeContainer();
      addTearDown(container.dispose);

      final entry = container
          .read(sessionsProvider.notifier)
          .addOrActivate(
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

      // The close (✕) action is directly on the row — no long-press needed.
      expect(
        find.byKey(Key('session-menu-close-${entry.id}')),
        findsOneWidget,
      );
      // The old long-press contextual sheet is gone (#817).
      await tester.longPress(find.byKey(Key('session-menu-row-${entry.id}')));
      await _pumpFrames(tester);
      expect(
        find.byKey(const Key('session-menu-action-disconnect')),
        findsNothing,
      );
    });

    testWidgets(
      'keybar toggle flips ONLY the active session, not siblings (#573)',
      (tester) async {
        final container = _makeContainer();
        addTearDown(container.dispose);

        final notifier = container.read(sessionsProvider.notifier);
        final a = notifier.addOrActivate(
          const SshConnectParams(
            host: 'host-a',
            port: 22,
            username: 'u',
            auth: SshAuth.password('p'),
          ),
        );
        final b = notifier.addOrActivate(
          const SshConnectParams(
            host: 'host-b',
            port: 22,
            username: 'u',
            auth: SshAuth.password('p'),
          ),
        );
        // b is the active session.
        expect(container.read(sessionsProvider).activeId, b.id);

        // Both sessions default to visible (PWA parity).
        expect(container.read(sessionKeybarVisibleProvider(a.id)), isTrue);
        expect(container.read(sessionKeybarVisibleProvider(b.id)), isTrue);

        await tester.pumpWidget(_host(container: container));
        await tester.tap(find.byKey(const Key('open-menu')));
        await _pumpFrames(tester);

        // Toggle hides the keybar — for the ACTIVE session (b) only.
        await tester.tap(find.byKey(const Key('session-menu-keybar-toggle')));
        await _pumpFrames(tester);

        expect(
          container.read(sessionKeybarVisibleProvider(b.id)),
          isFalse,
          reason: 'active session keybar should be hidden after toggle',
        );
        expect(
          container.read(sessionKeybarVisibleProvider(a.id)),
          isTrue,
          reason: 'sibling session keybar must NOT change (no leakage, #573)',
        );

        // Switch active to a and toggle: a flips, b stays hidden — each session
        // carries its own keybar state.
        notifier.setActive(a.id);
        await _pumpFrames(tester);
        await tester.tap(find.byKey(const Key('session-menu-keybar-toggle')));
        await _pumpFrames(tester);

        expect(container.read(sessionKeybarVisibleProvider(a.id)), isFalse);
        expect(
          container.read(sessionKeybarVisibleProvider(b.id)),
          isFalse,
          reason: 'toggling a must not re-show b',
        );
      },
    );

    testWidgets('tapping the close button removes the entry', (tester) async {
      final container = _makeContainer();
      addTearDown(container.dispose);

      final entry = container
          .read(sessionsProvider.notifier)
          .addOrActivate(
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

    // #585 regression guard: opening the menu must NOT steal focus from the
    // terminal's text input — otherwise the soft keyboard drops and the screen
    // reflows ("jumpiness"). The old `showModalBottomSheet` route swapped the
    // focus scope and this assertion would FAIL; the non-modal overlay keeps
    // the editable focused so the keyboard stays up.
    testWidgets(
      'opening the menu keeps the focused editable (keyboard stays)',
      (tester) async {
        final container = _makeContainer();
        addTearDown(container.dispose);
        container
            .read(sessionsProvider.notifier)
            .addOrActivate(
              const SshConnectParams(
                host: 'host-a',
                port: 22,
                username: 'u',
                auth: SshAuth.password('p'),
              ),
            );

        final focusNode = FocusNode();
        addTearDown(focusNode.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (ctx) => Column(
                    children: [
                      TextField(
                        key: const Key('terminal-input-stand-in'),
                        focusNode: focusNode,
                      ),
                      ElevatedButton(
                        key: const Key('open-menu'),
                        onPressed: () => showSessionMenu(ctx),
                        child: const Text('open'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );

        // Focus the editable (this is what raises the keyboard on a device).
        focusNode.requestFocus();
        await _pumpFrames(tester);
        expect(focusNode.hasFocus, isTrue);

        // Open the menu — must NOT pull focus off the editable.
        await tester.tap(find.byKey(const Key('open-menu')));
        await _pumpFrames(tester);

        expect(find.byKey(const Key('session-menu')), findsOneWidget);
        expect(
          focusNode.hasFocus,
          isTrue,
          reason: 'session menu stole focus → keyboard would drop (#585)',
        );
      },
    );
  });

  group('SessionEntry label', () {
    test('falls back to user@host:port when no title is supplied', () {
      final container = _makeContainer();
      addTearDown(container.dispose);
      final entry = container
          .read(sessionsProvider.notifier)
          .addOrActivate(
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
      final entry = container
          .read(sessionsProvider.notifier)
          .addOrActivate(
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
      final entry = container
          .read(sessionsProvider.notifier)
          .addOrActivate(
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
