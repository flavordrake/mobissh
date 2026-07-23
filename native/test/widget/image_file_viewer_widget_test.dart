// Widget tests for the in-app image viewer + its registry routing (#1093).
//
// Assert:
//   - tapping an image entry (png/gif/…) in the file browser routes to
//     [ImageFileViewerScreen] via the registry, NOT the text viewer / download,
//   - the screen fetches the bytes over the SFTP image seam and hands the
//     stubbed WebView an HTML shell embedding them as a data: URI,
//   - the close-to-terminal action is present.
//
// Mirrors html_file_viewer_widget_test.dart's wiring. The platform WebView is
// stubbed via [imageWebViewBuilder]; real pinch-zoom + GIF playback are device-
// validated (#1093, device label).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/image_detect.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/sftp_image_fetcher.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/sftp_session.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/file_browser_screen.dart';
import 'package:mobissh/ui/image_file_viewer.dart';
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

class _CannedImageFetcher implements SftpImageFetcher {
  _CannedImageFetcher(this.bytes);
  final Uint8List bytes;

  @override
  Future<Uint8List> fetch(
    String sessionId,
    String path, {
    int maxBytes = 8 * 1024 * 1024,
  }) async => bytes;
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
  required Uint8List imageBytes,
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
      sftpImageFetcherProvider.overrideWithValue(
        _CannedImageFetcher(imageBytes),
      ),
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

  final loadedHtml = <String>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    loadedHtml.clear();
    imageWebViewBuilder = (html) {
      loadedHtml.add(html);
      return const Text('stub-image-webview');
    };
  });

  tearDown(() {
    imageWebViewBuilder = defaultImageWebViewBuilderForTest;
  });

  Future<SessionHost> openImage(
    WidgetTester tester,
    String name, {
    Uint8List? bytes,
  }) async {
    final w = _wire(
      tester,
      byPath: {
        '/': [
          SftpEntry(name: name, path: '/$name', isDirectory: false, size: 3),
        ],
      },
      imageBytes: bytes ?? Uint8List.fromList(const [1, 2, 3]),
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

  testWidgets('.png routes to the image viewer, not the text viewer', (
    tester,
  ) async {
    final host = await openImage(tester, 'photo.png');
    expect(find.byType(ImageFileViewerScreen), findsOneWidget);
    expect(find.byType(TextFileViewerScreen), findsNothing);
    host.disposeSyncForTest();
  });

  testWidgets('.gif routes to the image viewer', (tester) async {
    final host = await openImage(tester, 'loop.GIF');
    expect(find.byType(ImageFileViewerScreen), findsOneWidget);
    host.disposeSyncForTest();
  });

  testWidgets('the WebView is handed an HTML shell with the image data URI', (
    tester,
  ) async {
    final host = await openImage(
      tester,
      'photo.png',
      bytes: Uint8List.fromList(const [1, 2, 3]),
    );
    expect(find.text('stub-image-webview'), findsOneWidget);
    expect(loadedHtml, hasLength(1));
    final html = loadedHtml.single;
    // [1,2,3] → base64 "AQID"; png → image/png media type.
    expect(html, contains('data:image/png;base64,${base64Encode(const [
          1,
          2,
          3,
        ])}'));
    expect(html, contains('user-scalable=yes')); // pinch-zoom permitted
    host.disposeSyncForTest();
  });

  testWidgets('jpg uses the image/jpeg media type', (tester) async {
    final host = await openImage(tester, 'snap.jpg');
    expect(loadedHtml.single, contains('data:image/jpeg;base64,'));
    host.disposeSyncForTest();
  });

  testWidgets('the viewer exposes close-to-terminal', (tester) async {
    final host = await openImage(tester, 'photo.png');
    expect(
      find.byKey(const Key('image-viewer-close-to-terminal')),
      findsOneWidget,
    );
    host.disposeSyncForTest();
  });

  test('buildImageHtml embeds the bytes + mime and permits zoom', () {
    final html = buildImageHtml(const [0, 255, 16], 'image/gif');
    expect(html, contains('data:image/gif;base64,${base64Encode(const [
          0,
          255,
          16,
        ])}'));
    expect(html, contains('user-scalable=yes'));
    expect(html, contains('<img'));
    // Styling lives in a <style> block (CSS), not inline style attributes.
    expect(html, contains('<style>'));
    expect(html, isNot(contains('style="')));
  });

  test('imageMimeForName maps extensions used by the viewer', () {
    expect(imageMimeForName('a.png'), 'image/png');
    expect(imageMimeForName('a.gif'), 'image/gif');
    expect(imageMimeForName('a.webp'), 'image/webp');
  });
}
