// On-emulator SFTP DEFAULT-PATH smoke (#891).
//
// A saved profile carries an optional `defaultPath` (the file-browser starting
// directory). When set, opening the file browser for that session must land at
// `defaultPath`, NOT the SFTP home — crucial for VPS/seedbox hosts (Whatbox)
// where the home dir isn't where you work. When unset, the browser opens at the
// SFTP home (the `~` realpath), the unchanged behaviour.
//
// Headless widget tests feed a fake gateway and never touch a real sshd, so a
// task-side SFTP regression (e.g. defaultPath not expanded/resolved) only shows
// on the emulator. This test runs the REAL app against test-sshd: it saves a
// profile with `defaultPath=/tmp` through the editor, connects, opens the file
// browser via the session-menu "Files" affordance (the SAME entry point #891
// wires — openFileBrowserForSession), and asserts the first listing IS `/tmp`.
// A second case connects WITHOUT a defaultPath and asserts the browser opens at
// the resolved home (not `/`).
//
// Network: scripts/native-connect-test.sh sets up
//   emulator 127.0.0.1:2222 → (adb reverse → socat) → test-sshd:22
// Credentials: testuser/testpass (see CLAUDE.md → Test SSH).
//
// NOTE: written as the RED baseline; the orchestrator runs this on-device — the
// develop agent does NOT run integration_test on the busy emulator.

@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/sessions.dart';

import 'support/connect_helpers.dart';

const _slice = Duration(milliseconds: 500);

/// Pump in 500ms slices until [test] is true or [maxSlices] elapse, accepting a
/// host-key trust prompt ("Trust + connect") whenever it surfaces.
Future<bool> _pumpUntil(
  WidgetTester tester,
  bool Function() test, {
  int maxSlices = 80,
}) async {
  for (var i = 0; i < maxSlices; i++) {
    await tester.pump(_slice);
    final trust = find.text('Trust + connect');
    if (trust.evaluate().isNotEmpty) {
      await tester.tap(trust.first);
      await tester.pump(const Duration(milliseconds: 300));
    }
    if (test()) return true;
  }
  return false;
}

/// Reach the terminal screen for a freshly-submitted connect.
Future<bool> _reachTerminal(WidgetTester tester) {
  return _pumpUntil(
    tester,
    () => find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty,
  );
}

/// Assert real LOGIN (not just widget mount): a typed marker echoes back.
Future<void> _assertShellAlive(
  WidgetTester tester,
  SessionEntry entry, {
  required String marker,
}) async {
  final out = <int>[];
  final sub = entry.proxy.output.listen(out.addAll);
  addTearDown(sub.cancel);
  await tester.pump(const Duration(milliseconds: 200));
  entry.proxy.sendInput(Uint8List.fromList(utf8.encode('echo $marker\n')));
  final sawMarker = await _pumpUntil(
    tester,
    () => utf8.decode(out, allowMalformed: true).contains(marker),
    maxSlices: 40,
  );
  expect(sawMarker, isTrue, reason: 'typed command never echoed — dead shell');
}

/// Open the session menu reliably (#782) and tap the per-row "Files" affordance
/// so the browser opens via the REAL #891 entry point (openFileBrowserForSession
/// → resolves the profile's defaultPath). Returns once the menu overlay shows.
Future<void> _openSessionMenu(WidgetTester tester) async {
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump(const Duration(milliseconds: 200));
  final trigger = find.byKey(const Key('session-bar-open-menu'));
  await tester.ensureVisible(trigger);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(trigger, warnIfMissed: false);
  await _pumpUntil(
    tester,
    () => find.byKey(const Key('session-menu-new')).evaluate().isNotEmpty,
    maxSlices: 20,
  );
}

/// Tap the Files button for [sessionId]'s row in the open session menu, then
/// wait for the browser listing to render. This is the #891 entry point.
Future<void> _openFilesForSession(
  WidgetTester tester,
  String sessionId,
) async {
  final files = find.byKey(Key('session-menu-files-$sessionId'));
  await tester.ensureVisible(files);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(files);
  await _pumpUntil(
    tester,
    () => find.byKey(const Key('file-browser-list')).evaluate().isNotEmpty,
    maxSlices: 60,
  );
}

/// Fill + save-and-connect an ad-hoc password profile that ALSO sets the
/// editor's optional default-directory field (#891), so the saved profile
/// carries [defaultPath]. Mirrors [adhocPasswordConnect] but adds the new field.
Future<void> _connectWithDefaultPath(
  WidgetTester tester, {
  required String host,
  required String port,
  required String user,
  required String pass,
  required String defaultPath,
}) async {
  await openNewConnectionEditor(tester);
  await tester.enterText(find.byKey(const Key('profile-editor-host')), host);
  await tester.enterText(find.byKey(const Key('profile-editor-port')), port);
  await tester.enterText(
    find.byKey(const Key('profile-editor-username')),
    user,
  );
  await tester.enterText(
    find.byKey(const Key('profile-editor-password')),
    pass,
  );
  final pathField = find.byKey(const Key('profile-editor-default-path'));
  await tester.ensureVisible(pathField);
  await tester.enterText(pathField, defaultPath);
  await tester.pump();
  final submit = find.byKey(const Key('connect-submit'));
  await tester.ensureVisible(submit);
  await tester.pump();
  await tester.tap(submit);
}

Future<void> _disconnectAll(
  WidgetTester tester,
  ProviderContainer container,
) async {
  final notifier = container.read(sessionsProvider.notifier);
  final ids = container
      .read(sessionsProvider)
      .entries
      .map((e) => e.id)
      .toList(growable: false);
  for (final id in ids) {
    notifier.close(id);
  }
  await _pumpUntil(
    tester,
    () => container.read(sessionsProvider).entries.isEmpty,
    maxSlices: 20,
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'profile defaultPath=/tmp → file browser opens at /tmp, not home (#891)',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MobisshApp(),
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      // Connect via a SAVED profile carrying defaultPath=/tmp.
      await _connectWithDefaultPath(
        tester,
        host: '127.0.0.1',
        port: '2222',
        user: 'testuser',
        pass: 'testpass',
        defaultPath: '/tmp',
      );
      expect(
        await _reachTerminal(tester),
        isTrue,
        reason: 'never reached the terminal screen',
      );
      final entry = container.read(sessionsProvider).active;
      expect(entry, isNotNull, reason: 'no active session after connect');
      await _assertShellAlive(tester, entry!, marker: 'MOBISSH_SHELL_OK_891');

      // Open Files via the session menu (the #891 entry point) and assert the
      // FIRST listing is /tmp — the profile's default dir, not the SFTP home.
      await _openSessionMenu(tester);
      await _openFilesForSession(tester, entry.id);
      expect(
        find.byKey(const Key('file-browser-list')),
        findsOneWidget,
        reason: 'browser listing never rendered',
      );
      expect(
        find.text('/tmp'),
        findsOneWidget,
        reason: 'browser did not open at the profile defaultPath (/tmp)',
      );

      await _disconnectAll(tester, container);
    },
  );

  testWidgets(
    'empty defaultPath → file browser opens at the SFTP home, not "/" (#891)',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MobisshApp(),
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      // Connect WITHOUT a defaultPath (the unchanged behaviour).
      await adhocPasswordConnect(
        tester,
        host: '127.0.0.1',
        port: '2222',
        user: 'testuser',
        pass: 'testpass',
      );
      expect(await _reachTerminal(tester), isTrue, reason: 'no terminal');
      final entry = container.read(sessionsProvider).active;
      expect(entry, isNotNull, reason: 'no active session after connect');
      await _assertShellAlive(tester, entry!, marker: 'MOBISSH_HOME_OK_891');

      await _openSessionMenu(tester);
      await _openFilesForSession(tester, entry.id);
      expect(
        find.byKey(const Key('file-browser-list')),
        findsOneWidget,
        reason: 'browser listing never rendered',
      );
      // With no defaultPath the browser opens at the SFTP home: the path bar
      // shows the `~` home sentinel (resolved server-side to the realpath home
      // for the listing) and NOT the root `/`. The home listing rendering at
      // all (above) proves `~` resolved to a real directory, not an error.
      expect(
        find.byKey(const Key('file-browser-path')),
        findsOneWidget,
        reason: 'path bar missing',
      );
      expect(
        find.text('~'),
        findsOneWidget,
        reason: 'empty defaultPath should open at the home (~), not "/"',
      );
      expect(
        find.text('/'),
        findsNothing,
        reason: 'empty defaultPath should open at home, not the root "/"',
      );

      await _disconnectAll(tester, container);
    },
  );
}
