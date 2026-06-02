// Slim session menu (#567) + non-modal-overlay regression guard (#585).
//
// #567 (owner's stated #2 priority, re-raised 2026-05-31): the session menu's
// secondary section had regrown into a stack of full-width ListTiles (keybar,
// theme, font, files, disconnect) plus a verbose user@host:port subtitle on
// every session row. This tightens it back to the PWA's slim direction:
//   - session rows show the LABEL only (no user@host:port subtitle clutter),
//   - the per-session controls collapse into ONE compact icon-button row
//     (`session-menu-controls`) instead of five stacked tiles,
//   - every ESSENTIAL control is KEPT and addressable by its existing key:
//     theme cycle, font -, font +, files, keybar toggle, disconnect.
//
// #585: the menu must remain a NON-MODAL overlay that never steals focus from
// the terminal's editable (otherwise the soft keyboard drops + the screen
// reflows). The structural fix already shipped (commit 4832544); this guards it
// against the slim rework.

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('SessionMenu slim layout (#567)', () {
    testWidgets('keeps every essential control, addressable by key', (
      tester,
    ) async {
      final container = _makeContainer();
      _add(container, 'host-a');

      await tester.pumpWidget(_host(container: container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      // Switch (the session row) + new session.
      expect(find.byKey(const Key('session-menu-new')), findsOneWidget);
      // Per-session controls — KEPT (owner: don't drop these).
      expect(find.byKey(const Key('session-menu-theme-cycle')), findsOneWidget);
      expect(
        find.byKey(const Key('session-menu-fontsize-dec')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('session-menu-fontsize-inc')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('session-menu-files')), findsOneWidget);
      expect(
        find.byKey(const Key('session-menu-keybar-toggle')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('terminal-disconnect-button')),
        findsOneWidget,
      );
    });

    testWidgets('per-session controls collapse into one compact row', (
      tester,
    ) async {
      final container = _makeContainer();
      _add(container, 'host-a');

      await tester.pumpWidget(_host(container: container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      // The slim layout exposes a single controls row rather than five stacked
      // full-width tiles. This is the structural slim assertion.
      expect(find.byKey(const Key('session-menu-controls')), findsOneWidget);

      // Clutter removed: the old stacked secondary tiles must NOT appear as
      // full ListTiles (they are now compact icon-buttons inside the row).
      expect(find.widgetWithText(ListTile, 'Keybar'), findsNothing);
      expect(find.widgetWithText(ListTile, 'Font size'), findsNothing);
      expect(find.widgetWithText(ListTile, 'Theme'), findsNothing);
    });

    testWidgets('session rows drop the user@host:port subtitle clutter', (
      tester,
    ) async {
      final container = _makeContainer();
      // Give the session an explicit title so the LABEL ('Prod box') differs
      // from the user@host:port string — then the only place 'u@host-a:22'
      // could render is the (now-removed) subtitle line.
      container
          .read(sessionsProvider.notifier)
          .addOrActivate(
            const SshConnectParams(
              host: 'host-a',
              port: 22,
              username: 'u',
              auth: SshAuth.password('p'),
            ),
            title: 'Prod box',
          );

      await tester.pumpWidget(_host(container: container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      // Label still shows; the verbose subtitle line is gone.
      expect(find.text('Prod box'), findsOneWidget);
      expect(find.text('u@host-a:22'), findsNothing);
    });

    testWidgets('font +/- still mutates only the active session', (
      tester,
    ) async {
      final container = _makeContainer();
      final a = _add(container, 'host-a');
      final b = _add(container, 'host-b'); // b active

      await tester.pumpWidget(_host(container: container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      await tester.tap(find.byKey(const Key('session-menu-fontsize-inc')));
      await _pumpFrames(tester);

      expect(
        container.read(sessionFontSizeProvider(b.id)),
        greaterThan(fontSizeDefault),
      );
      expect(container.read(sessionFontSizeProvider(a.id)), fontSizeDefault);
    });
  });

  group('SessionMenu non-modal overlay (#585 guard)', () {
    testWidgets('opening the slim menu keeps the focused editable', (
      tester,
    ) async {
      final container = _makeContainer();
      _add(container, 'host-a');

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

      focusNode.requestFocus();
      await _pumpFrames(tester);
      expect(focusNode.hasFocus, isTrue);

      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      expect(find.byKey(const Key('session-menu')), findsOneWidget);
      expect(
        focusNode.hasFocus,
        isTrue,
        reason: 'slim menu must not steal focus -> keyboard stays up (#585)',
      );
    });
  });
}
