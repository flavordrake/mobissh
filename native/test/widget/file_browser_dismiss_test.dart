// File browser / viewer "close to terminal" widget tests (#855).
//
// The owner wants a single top-right X that returns straight to the terminal
// regardless of folder depth or whether a file is open — NOT a level-by-level
// back-out. These tests assert:
//   - the X (Icons.close) is present in the browser AND both viewers
//     (markdown + text/code),
//   - tapping the X from a DEEPLY-NESTED browser directory lands back on the
//     terminal in ONE pop (the browser navigates in-place, so its stack depth
//     never grows — one route above the terminal),
//   - tapping the X from an OPEN viewer collapses the WHOLE browser→viewer
//     stack in one action (not viewer→browser→…→terminal).
//
// Reuses the same InMemoryGatewayPair + scripted SFTP wiring the other browser
// widget tests use, but mounts the browser via openFileBrowser ON TOP of a
// "terminal" base route so the dismissal target is observable.

import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/text_file_fetcher.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/sftp_session.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/file_browser_screen.dart';
import 'package:mobissh/ui/markdown_file_viewer.dart';
import 'package:mobissh/ui/text_file_viewer.dart';
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
  Future<void> close() async {}
}

class _CannedTextFetcher implements TextFileFetcher {
  _CannedTextFetcher(this.text);
  final String text;

  @override
  Future<String> fetch(
    String sessionId,
    SftpEntry entry, {
    int maxBytes = 2 * 1024 * 1024,
    void Function(int received, int? total)? onProgress,
  }) async => text;
}

Future<void> _pump(WidgetTester tester, {int count = 12}) async {
  for (var i = 0; i < count; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 30));
  }
}

/// Advances frames enough to drive a route-pop transition to completion
/// (without runAsync, so the route animation's ticker is actually pumped).
Future<void> _settleRoutes(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

({ProviderContainer container, SessionEntry session, SessionHost host}) _wire(
  WidgetTester tester, {
  required Map<String, List<SftpEntry>> byPath,
  String text = 'hello world',
}) {
  final pair = InMemoryGatewayPair();
  addTearDown(pair.dispose);
  final host = SessionHost(
    gateway: pair.taskSide,
    controllerFactory: _stubControllerFactory,
    sftpOpener: (_) async => _ScriptedSftpSession(byPath),
    snapshotInterval: const Duration(hours: 1),
  );
  final container = ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      textFileFetcherProvider.overrideWithValue(_CannedTextFetcher(text)),
    ],
  );
  addTearDown(container.dispose);
  const params = SshConnectParams(
    host: 'h',
    port: 22,
    username: 'u',
    auth: SshAuth.password('p'),
  );
  final session = container.read(sessionsProvider.notifier).addOrActivate(
    params,
  );
  session.proxy.connect(params);
  return (container: container, session: session, host: host);
}

/// Mounts a "terminal" base route, then pushes the file browser on top of it
/// via [openFileBrowser] (the same entry point the session menu uses). The
/// terminal route carries a finder key so dismissal back to it is observable.
Future<
  ({ProviderContainer container, SessionEntry session, SessionHost host})
>
_mountBrowserOverTerminal(
  WidgetTester tester, {
  required Map<String, List<SftpEntry>> byPath,
  String text = 'hello world',
}) async {
  final w = _wire(tester, byPath: byPath, text: text);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: w.container,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const Key('open-browser'),
                onPressed: () => openFileBrowser(context, w.session.id),
                child: const Text('terminal', key: Key('terminal-marker')),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await _pump(tester);
  // The terminal base is showing; the browser is not yet pushed.
  expect(find.byKey(const Key('terminal-marker')), findsOneWidget);
  expect(find.byType(FileBrowserScreen), findsNothing);

  await tester.tap(find.byKey(const Key('open-browser')));
  await _pump(tester);
  expect(find.byType(FileBrowserScreen), findsOneWidget);
  return w;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('browser app bar has a top-right close-to-terminal X', (
    tester,
  ) async {
    final w = await _mountBrowserOverTerminal(
      tester,
      byPath: {
        '/': const [
          SftpEntry(name: 'docs', path: '/docs', isDirectory: true),
        ],
      },
    );
    final closeKey = find.byKey(const Key('file-browser-close-to-terminal'));
    expect(closeKey, findsOneWidget);
    // It is the Material `close` glyph (monochrome, no emoji).
    final icon = tester.widget<Icon>(
      find.descendant(of: closeKey, matching: find.byType(Icon)),
    );
    expect(icon.icon, Icons.close);
    w.host.disposeSyncForTest();
  });

  testWidgets(
    'X from a deeply-nested folder returns to terminal in ONE pop',
    (tester) async {
      final w = await _mountBrowserOverTerminal(
        tester,
        byPath: {
          '/': const [SftpEntry(name: 'a', path: '/a', isDirectory: true)],
          '/a': const [SftpEntry(name: 'b', path: '/a/b', isDirectory: true)],
          '/a/b': const [
            SftpEntry(name: 'c', path: '/a/b/c', isDirectory: true),
          ],
          '/a/b/c': const [
            SftpEntry(name: 'leaf', path: '/a/b/c/leaf', isDirectory: true),
          ],
        },
      );

      // Navigate deep: a → b → c. Browsing is IN-PLACE (no new routes), so the
      // browser stays a single route above the terminal.
      await tester.tap(find.byKey(const Key('file-entry-a')));
      await _pump(tester);
      await tester.tap(find.byKey(const Key('file-entry-b')));
      await _pump(tester);
      await tester.tap(find.byKey(const Key('file-entry-c')));
      await _pump(tester);
      expect(find.byKey(const Key('file-browser-path')), findsOneWidget);
      expect(find.text('/a/b/c'), findsOneWidget);

      // ONE tap on the X → back on the terminal, browser gone.
      await tester.tap(find.byKey(const Key('file-browser-close-to-terminal')));
      await _settleRoutes(tester);

      expect(find.byType(FileBrowserScreen), findsNothing);
      expect(find.byKey(const Key('terminal-marker')), findsOneWidget);
      w.host.disposeSyncForTest();
    },
  );

  testWidgets(
    'X from an open MARKDOWN viewer collapses the whole stack in one tap',
    (tester) async {
      final w = await _mountBrowserOverTerminal(
        tester,
        byPath: {
          '/': const [
            SftpEntry(
              name: 'README.md',
              path: '/README.md',
              isDirectory: false,
              size: 10,
            ),
          ],
        },
        text: '# Title\n\nbody',
      );

      // Open the markdown viewer (browser → viewer = 2 routes above terminal).
      await tester.tap(find.byKey(const Key('file-entry-README.md')));
      await _pump(tester);
      expect(find.byType(MarkdownFileViewerScreen), findsOneWidget);

      // The viewer chrome has the close X.
      final closeKey = find.byKey(
        const Key('markdown-viewer-close-to-terminal'),
      );
      expect(closeKey, findsOneWidget);
      final icon = tester.widget<Icon>(
        find.descendant(of: closeKey, matching: find.byType(Icon)),
      );
      expect(icon.icon, Icons.close);

      // ONE tap → past the viewer AND the browser, straight to terminal.
      await tester.tap(closeKey);
      await _settleRoutes(tester);

      expect(find.byType(MarkdownFileViewerScreen), findsNothing);
      expect(find.byType(FileBrowserScreen), findsNothing);
      expect(find.byKey(const Key('terminal-marker')), findsOneWidget);
      w.host.disposeSyncForTest();
    },
  );

  testWidgets(
    'X from an open TEXT viewer collapses the whole stack in one tap',
    (tester) async {
      final w = await _mountBrowserOverTerminal(
        tester,
        byPath: {
          '/': const [
            SftpEntry(
              name: 'main.dart',
              path: '/main.dart',
              isDirectory: false,
              size: 10,
            ),
          ],
        },
        text: 'void main() {}',
      );

      await tester.tap(find.byKey(const Key('file-entry-main.dart')));
      await _pump(tester);
      expect(find.byType(TextFileViewerScreen), findsOneWidget);

      final closeKey = find.byKey(const Key('text-viewer-close-to-terminal'));
      expect(closeKey, findsOneWidget);
      final icon = tester.widget<Icon>(
        find.descendant(of: closeKey, matching: find.byType(Icon)),
      );
      expect(icon.icon, Icons.close);

      await tester.tap(closeKey);
      await _settleRoutes(tester);

      expect(find.byType(TextFileViewerScreen), findsNothing);
      expect(find.byType(FileBrowserScreen), findsNothing);
      expect(find.byKey(const Key('terminal-marker')), findsOneWidget);
      w.host.disposeSyncForTest();
    },
  );
}
