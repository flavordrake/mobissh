// File browser back-gesture history tests (#1102).
//
// The browser navigates by STATE (one route above the terminal, #740), so the
// system back gesture used to pop the WHOLE browser and lose the browsing
// position. Back must now walk the directory HISTORY — the directory you came
// FROM, not the parent — and only leave the browser when the history is empty.
//
// These drive the route's pop path (`handlePopRoute`, i.e. the system back)
// rather than tapping a widget, so the PopScope is what's exercised.

import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/sftp_session.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/storage/favorites_store.dart';
import 'package:mobissh/ui/file_browser_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

SshSessionController _stubControllerFactory() {
  return SshSessionController(
    socketOpener: (host, port, {timeout}) => Completer<SSHSocket>().future,
  );
}

class _ScriptedSftpSession implements SftpSession {
  _ScriptedSftpSession(this._byPath);
  final Map<String, List<SftpEntry>> _byPath;

  @override
  Future<List<SftpEntry>> list(String path) async => _byPath[path] ?? const [];
  @override
  Future<int?> sizeOf(String path) async => 0;
  @override
  Future<int> download(
    String path, {
    required void Function(Uint8List chunk, int offset) onChunk,
    int chunkSize = 64 * 1024,
  }) async => 0;
  @override
  Future<int> upload(String path, Uint8List bytes) async => bytes.length;
  @override
  Future<int> uploadFile(
    String localPath,
    String remotePath, {
    required void Function(int sent, int total) onProgress,
    int chunkSize = 64 * 1024,
  }) async {
    onProgress(0, 0);
    return 0;
  }

  @override
  Future<int> downloadFile(
    String remotePath,
    String localPath, {
    required void Function(int done, int total) onProgress,
    int chunkSize = 64 * 1024,
  }) async {
    onProgress(0, 0);
    return 0;
  }

  // #1133 widened the SftpSession seam with mkdir; this fake doesn't
  // exercise directory creation.
  @override
  Future<void> mkdir(String path) async {}

  @override
  Future<void> close() async {}
}

/// `host:port:username` of [_params] — the favorites identity key.
const String _profileKey = 'h:22:u';

const SshConnectParams _params = SshConnectParams(
  host: 'h',
  port: 22,
  username: 'u',
  auth: SshAuth.password('p'),
);

/// `/` → `a/` → `a/b/`, plus an unrelated `x/y/` branch for the favorite jump.
const Map<String, List<SftpEntry>> _tree = {
  '/': [
    SftpEntry(name: 'a', path: '/a', isDirectory: true),
    SftpEntry(name: 'x', path: '/x', isDirectory: true),
  ],
  '/a': [SftpEntry(name: 'b', path: '/a/b', isDirectory: true)],
  '/a/b': [SftpEntry(name: 'deep', path: '/a/b/deep', isDirectory: true)],
  '/x': [SftpEntry(name: 'y', path: '/x/y', isDirectory: true)],
  '/x/y': [],
};

Future<void> _pump(WidgetTester tester, {int count = 12}) async {
  for (var i = 0; i < count; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Future<void> _settleRoutes(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The system back gesture: drive the route pop path so the browser's PopScope
/// is what decides, not a tapped affordance.
Future<void> _systemBack(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await _pump(tester);
  await _settleRoutes(tester);
}

String _currentPath(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('file-browser-path'))).data ?? '';

/// Mounts a "terminal" base route and pushes the browser on top via the real
/// entry point, so "back leaves the browser" is observable.
Future<({ProviderContainer container, SessionHost host})>
_mountBrowserOverTerminal(WidgetTester tester) async {
  final pair = InMemoryGatewayPair();
  addTearDown(pair.dispose);
  final host = SessionHost(
    gateway: pair.taskSide,
    controllerFactory: _stubControllerFactory,
    sftpOpener: (_) async => _ScriptedSftpSession(_tree),
    snapshotInterval: const Duration(hours: 1),
  );
  final container = ProviderContainer(
    overrides: [taskSshGatewayProvider.overrideWithValue(pair.uiSide)],
  );
  addTearDown(container.dispose);
  final session = container
      .read(sessionsProvider.notifier)
      .addOrActivate(_params);
  session.proxy.connect(_params);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const Key('open-browser'),
                onPressed: () => openFileBrowser(context, session.id),
                child: const Text('terminal', key: Key('terminal-marker')),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await _pump(tester);
  await tester.tap(find.byKey(const Key('open-browser')));
  await _pump(tester);
  expect(find.byType(FileBrowserScreen), findsOneWidget);
  return (container: container, host: host);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('back walks the directory history instead of leaving (#1102)', (
    tester,
  ) async {
    final w = await _mountBrowserOverTerminal(tester);

    await tester.tap(find.byKey(const Key('file-entry-a')));
    await _pump(tester);
    await tester.tap(find.byKey(const Key('file-entry-b')));
    await _pump(tester);
    expect(_currentPath(tester), '/a/b');

    // Back → the directory we came from, browser still on screen.
    await _systemBack(tester);
    expect(find.byType(FileBrowserScreen), findsOneWidget);
    expect(_currentPath(tester), '/a');

    // Again → root, still in the browser.
    await _systemBack(tester);
    expect(find.byType(FileBrowserScreen), findsOneWidget);
    expect(_currentPath(tester), '/');

    // History exhausted → back finally leaves the browser.
    await _systemBack(tester);
    expect(find.byType(FileBrowserScreen), findsNothing);
    expect(find.byKey(const Key('terminal-marker')), findsOneWidget);

    w.host.disposeSyncForTest();
  });

  testWidgets('back at the opening directory leaves the browser (#1102)', (
    tester,
  ) async {
    final w = await _mountBrowserOverTerminal(tester);
    expect(_currentPath(tester), '/');

    await _systemBack(tester);

    expect(find.byType(FileBrowserScreen), findsNothing);
    expect(find.byKey(const Key('terminal-marker')), findsOneWidget);

    w.host.disposeSyncForTest();
  });

  testWidgets(
    'back after a favorite jump returns to where we were, not the parent (#1102)',
    (tester) async {
      await FavoritesStore().add(_profileKey, '/x/y');
      final w = await _mountBrowserOverTerminal(tester);

      await tester.tap(find.byKey(const Key('file-entry-a')));
      await _pump(tester);
      await tester.tap(find.byKey(const Key('file-entry-b')));
      await _pump(tester);
      expect(_currentPath(tester), '/a/b');

      // Quick-nav to a favorite deep in an unrelated branch.
      await tester.longPress(find.byKey(const Key('file-browser-star')));
      await _pump(tester);
      await tester.tap(find.byKey(const Key('favorite-item-/x/y')));
      await _pump(tester);
      expect(_currentPath(tester), '/x/y');

      // Back = where we CAME FROM (/a/b), not the favorite's parent (/x).
      await _systemBack(tester);
      expect(find.byType(FileBrowserScreen), findsOneWidget);
      expect(_currentPath(tester), '/a/b');

      w.host.disposeSyncForTest();
    },
  );

  testWidgets('up-arrow goes to the parent and back does not bounce (#1102)', (
    tester,
  ) async {
    final w = await _mountBrowserOverTerminal(tester);

    await tester.tap(find.byKey(const Key('file-entry-a')));
    await _pump(tester);
    await tester.tap(find.byKey(const Key('file-entry-b')));
    await _pump(tester);
    expect(_currentPath(tester), '/a/b');

    // Up = PARENT (a distinct affordance from back).
    await tester.tap(find.byKey(const Key('file-browser-up')));
    await _pump(tester);
    expect(_currentPath(tester), '/a');

    // Back must NOT bounce forward into /a/b — it continues outward to root.
    await _systemBack(tester);
    expect(find.byType(FileBrowserScreen), findsOneWidget);
    expect(_currentPath(tester), '/');

    w.host.disposeSyncForTest();
  });

  testWidgets('the close affordance still collapses out of the browser (#855)', (
    tester,
  ) async {
    final w = await _mountBrowserOverTerminal(tester);

    await tester.tap(find.byKey(const Key('file-entry-a')));
    await _pump(tester);
    await tester.tap(find.byKey(const Key('file-entry-b')));
    await _pump(tester);
    expect(_currentPath(tester), '/a/b');

    // Deep history, but the X is the EXPLICIT close: straight out, one action.
    await tester.tap(find.byKey(const Key('file-browser-close-to-terminal')));
    await _settleRoutes(tester);

    expect(find.byType(FileBrowserScreen), findsNothing);
    expect(find.byKey(const Key('terminal-marker')), findsOneWidget);

    w.host.disposeSyncForTest();
  });
}
