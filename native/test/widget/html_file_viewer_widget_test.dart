// Widget tests for the rendered HTML viewer + its registry routing (#1037).
//
// Assert:
//   - tapping a `.html` / `.htm` entry in the file browser routes to
//     [HtmlFileViewerScreen] (via the registry, ordered BEFORE the generic
//     text viewer — first match wins), NOT the text viewer and NOT download,
//   - the screen starts its loopback resolver and hands the stubbed WebView a
//     127.0.0.1 URI pointing at the opened file,
//   - the app bar's "view source" pushes the EXISTING monospace text viewer,
//   - disposing the route closes the loopback port.
//
// Mirrors markdown_file_viewer_widget_test.dart's wiring (InMemoryGatewayPair
// + FileBrowserScreen + injected fetchers). The platform WebView is stubbed
// via [htmlWebViewBuilder] — widget tests have no platform channel; the real
// HTTP surface is covered by the unit tests and the emulator test.

import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/sftp_image_fetcher.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/services/text_file_fetcher.dart';
import 'package:mobissh/ssh/sftp_session.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/file_browser_screen.dart';
import 'package:mobissh/ui/html_file_viewer.dart';
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
  Future<int> downloadFile(
    String remotePath,
    String localPath, {
    required void Function(int done, int total) onProgress,
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

class _CannedByteFetcher implements SftpImageFetcher {
  @override
  Future<Uint8List> fetch(
    String sessionId,
    String path, {
    int maxBytes = 8 * 1024 * 1024,
  }) async => Uint8List(0);
}

Future<void> _pump(WidgetTester tester, {int count = 12}) async {
  for (var i = 0; i < count; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 30));
  }
}

({ProviderContainer container, SessionEntry session, SessionHost host}) _wire(
  WidgetTester tester, {
  required Map<String, List<SftpEntry>> byPath,
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
      textFileFetcherProvider.overrideWithValue(
        _CannedTextFetcher('<html><body>hi</body></html>'),
      ),
      sftpImageFetcherProvider.overrideWithValue(_CannedByteFetcher()),
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final loadedUris = <Uri>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    loadedUris.clear();
    htmlWebViewBuilder = (uri, onBlocked) {
      loadedUris.add(uri);
      return const Text('stub-html-webview');
    };
  });

  tearDown(() {
    htmlWebViewBuilder = defaultHtmlWebViewBuilderForTest;
  });

  Future<SessionHost> openHtml(WidgetTester tester, String name) async {
    final w = _wire(
      tester,
      byPath: {
        '/': [
          SftpEntry(name: name, path: '/$name', isDirectory: false, size: 20),
        ],
      },
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: w.container,
        child: MaterialApp(home: FileBrowserScreen(sessionId: w.session.id)),
      ),
    );
    await _pump(tester);
    await tester.tap(find.byKey(Key('file-entry-$name')));
    await _pump(tester);
    return w.host;
  }

  testWidgets('.html routes to the rendered HTML viewer, not the text viewer', (
    tester,
  ) async {
    final host = await openHtml(tester, 'wireframes.html');
    expect(find.byType(HtmlFileViewerScreen), findsOneWidget);
    expect(find.byType(TextFileViewerScreen), findsNothing);
    expect(find.byType(MarkdownFileViewerScreen), findsNothing);
    host.disposeSyncForTest();
  });

  testWidgets('.htm routes to the rendered HTML viewer', (tester) async {
    final host = await openHtml(tester, 'page.HTM');
    expect(find.byType(HtmlFileViewerScreen), findsOneWidget);
    host.disposeSyncForTest();
  });

  testWidgets('the WebView is handed a loopback URI for the opened file', (
    tester,
  ) async {
    final host = await openHtml(tester, 'wireframes.html');
    expect(find.text('stub-html-webview'), findsOneWidget);
    expect(loadedUris, hasLength(1));
    final uri = loadedUris.single;
    expect(uri.scheme, 'http');
    expect(uri.host, '127.0.0.1');
    expect(uri.port, greaterThan(0));
    expect(uri.pathSegments, ['wireframes.html']);
    host.disposeSyncForTest();
  });

  testWidgets('view-source pushes the existing text viewer', (tester) async {
    final host = await openHtml(tester, 'wireframes.html');
    expect(find.byKey(const Key('html-view-source')), findsOneWidget);

    await tester.tap(find.byKey(const Key('html-view-source')));
    await _pump(tester);
    expect(find.byType(TextFileViewerScreen), findsOneWidget);
    // The raw source is shown by the text viewer's own fetch path.
    expect(find.textContaining('<html>'), findsOneWidget);

    // Back returns to the rendered viewer. (Not pageBack(): two stacked
    // routes each expose a back tooltip, which pageBack refuses.)
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await _pump(tester);
    expect(find.byType(HtmlFileViewerScreen), findsOneWidget);
    host.disposeSyncForTest();
  });

  testWidgets('closing the viewer route shuts the loopback server down', (
    tester,
  ) async {
    final host = await openHtml(tester, 'wireframes.html');
    expect(debugLastHtmlLoopbackServer, isNotNull);
    final server = debugLastHtmlLoopbackServer!;
    expect(server.port, isNotNull);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await _pump(tester);
    await tester.pump(const Duration(seconds: 1));
    await _pump(tester);
    expect(find.byType(HtmlFileViewerScreen), findsNothing);
    expect(server.port, isNull, reason: 'loopback port must close on dispose');
    expect(debugLastHtmlLoopbackServer, isNull);
    host.disposeSyncForTest();
  });
}
