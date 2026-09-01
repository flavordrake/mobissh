// Widget tests for the shared Download + Share viewer actions (#1038).
//
// Assert:
//   - DRIFT GUARD: every viewer registered in [fileViewerRegistryProvider]
//     renders BOTH app-bar actions (a viewer without them is a bug), and the
//     registry size is pinned so adding a viewer type without covering it here
//     fails loudly,
//   - tapping Download / Share invokes the [FileViewerActionService] seam with
//     the viewed file (spy service — no filesystem, no share sheet),
//   - the tap-to-fill viewer (#946) carries the actions when it has a file
//     source: inline SFTP images pass their already-fetched bytes, mermaid
//     passes its diagram source as `diagram.mmd`.
//
// Mirrors html_file_viewer_widget_test.dart's wiring (InMemoryGatewayPair +
// FileBrowserScreen + injected fetchers). Platform surfaces (WebView, pdfium)
// are stubbed exactly as the per-viewer tests do.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/pdf_fetcher.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/sftp_image_fetcher.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/services/text_file_fetcher.dart';
import 'package:mobissh/services/viewer_file_actions.dart';
import 'package:mobissh/ssh/sftp_session.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/file_browser_screen.dart';
import 'package:mobissh/ui/file_viewer_registry.dart';
import 'package:mobissh/ui/fill_media_viewer.dart';
import 'package:mobissh/ui/html_file_viewer.dart';
import 'package:mobissh/ui/image_file_viewer.dart';
import 'package:mobissh/ui/markdown_file_viewer.dart';
import 'package:mobissh/ui/mermaid_diagram_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

// A minimal valid 1x1 transparent PNG.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
  '+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

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

/// PDF fetch that never completes — the actions must be present in EVERY
/// viewer phase, including while fetching, so this is sufficient (and keeps
/// pdfium/path_provider out of the harness).
class _HangingPdfFetcher implements PdfFetcher {
  @override
  Future<File> fetch(
    String sessionId,
    SftpEntry entry, {
    void Function(int received, int? total)? onProgress,
  }) => Completer<File>().future;
}

/// Spy action service: records the sources each action was invoked with.
class _SpyActionService implements FileViewerActionService {
  final List<ViewerFileSource> downloads = [];
  final List<ViewerFileSource> shares = [];

  @override
  Future<String> downloadToDevice(
    ViewerFileSource source, {
    void Function(int received, int? total)? onProgress,
  }) async {
    downloads.add(source);
    return 'Downloads/spy';
  }

  @override
  Future<void> shareFile(
    ViewerFileSource source, {
    void Function(int received, int? total)? onProgress,
  }) async {
    shares.add(source);
  }
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
  required _SpyActionService spy,
  String cannedText = 'hello world',
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
      textFileFetcherProvider.overrideWithValue(_CannedTextFetcher(cannedText)),
      sftpImageFetcherProvider.overrideWithValue(_CannedImageFetcher(_png)),
      pdfFetcherProvider.overrideWithValue(_HangingPdfFetcher()),
      fileViewerActionServiceProvider.overrideWithValue(spy),
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

/// Open the file browser for a single [name] entry and tap it, routing through
/// the REAL viewer registry.
Future<
  ({ProviderContainer container, SessionEntry session, SessionHost host})
>
_openViewer(WidgetTester tester, String name, _SpyActionService spy) async {
  final w = _wire(
    tester,
    byPath: {
      '/': [
        SftpEntry(name: name, path: '/$name', isDirectory: false, size: 11),
      ],
    },
    spy: spy,
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
  return w;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    htmlWebViewBuilder = (uri, onBlocked) => const Text('stub-html-webview');
    imageWebViewBuilder = (html) => const Text('stub-image-webview');
    mermaidWebViewBuilder = (source) => const Text('stub-mermaid');
    mermaidFillBuilder = (source) => const Text('stub-mermaid-fill');
  });

  tearDown(() {
    htmlWebViewBuilder = defaultHtmlWebViewBuilderForTest;
    imageWebViewBuilder = defaultImageWebViewBuilderForTest;
    mermaidWebViewBuilder = defaultMermaidWebViewBuilderForTest;
    mermaidFillBuilder = defaultMermaidFillBuilderForTest;
  });

  testWidgets(
    'DRIFT GUARD: every registered viewer renders Download + Share',
    (tester) async {
      // One fixture per registered viewer, in registry terms:
      //   PDF (#557), markdown (#854), HTML (#1037), image (#1093),
      //   text/code (#776).
      const fixtures = [
        'report.pdf',
        'notes.md',
        'page.html',
        'photo.png',
        'script.txt',
      ];

      for (final name in fixtures) {
        final spy = _SpyActionService();
        final w = await _openViewer(tester, name, spy);
        expect(
          find.byKey(const Key('viewer-action-download')),
          findsOneWidget,
          reason: '$name viewer is missing the Download action (#1038)',
        );
        expect(
          find.byKey(const Key('viewer-action-share')),
          findsOneWidget,
          reason: '$name viewer is missing the Share action (#1038)',
        );
        // Pin the registry size: a NEW viewer type must be added to `fixtures`
        // above (and must include FileViewerActions) or this fails.
        expect(
          w.container.read(fileViewerRegistryProvider).viewers.length,
          fixtures.length,
          reason:
              'viewer registry grew — cover the new viewer in this drift '
              'guard and give it FileViewerActions (#1038)',
        );
        w.host.disposeSyncForTest();
        await tester.pumpWidget(const SizedBox.shrink());
        await _pump(tester, count: 4);
      }
    },
  );

  testWidgets('Download invokes the service with the viewed file', (
    tester,
  ) async {
    final spy = _SpyActionService();
    final w = await _openViewer(tester, 'script.txt', spy);

    await tester.tap(find.byKey(const Key('viewer-action-download')));
    await _pump(tester, count: 4);

    expect(spy.downloads, hasLength(1));
    final source = spy.downloads.single;
    expect(source, isA<RemoteFileSource>());
    final remote = source as RemoteFileSource;
    expect(remote.entry.path, '/script.txt');
    expect(remote.sessionId, w.session.id);
    expect(spy.shares, isEmpty);
    w.host.disposeSyncForTest();
  });

  testWidgets('Share invokes the service with the viewed file', (
    tester,
  ) async {
    final spy = _SpyActionService();
    final w = await _openViewer(tester, 'notes.md', spy);

    await tester.tap(find.byKey(const Key('viewer-action-share')));
    await _pump(tester, count: 4);

    expect(spy.shares, hasLength(1));
    final source = spy.shares.single;
    expect(source, isA<RemoteFileSource>());
    expect((source as RemoteFileSource).entry.name, 'notes.md');
    expect(spy.downloads, isEmpty);
    w.host.disposeSyncForTest();
  });

  testWidgets('fill viewer with a source shows the actions and routes them', (
    tester,
  ) async {
    final spy = _SpyActionService();
    final source = BytesFileSource(fileName: 'a.png', bytes: _png);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [fileViewerActionServiceProvider.overrideWithValue(spy)],
        child: MaterialApp(
          home: FillMediaViewer(
            source: source,
            child: const SizedBox(width: 10, height: 10),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('viewer-action-download')), findsOneWidget);
    expect(find.byKey(const Key('viewer-action-share')), findsOneWidget);

    await tester.tap(find.byKey(const Key('viewer-action-share')));
    await _pump(tester, count: 4);
    expect(spy.shares, hasLength(1));
    final shared = spy.shares.single as BytesFileSource;
    expect(shared.fileName, 'a.png');
    expect(shared.bytes, _png);
  });

  testWidgets('fill viewer without a source shows no actions', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: FillMediaViewer(child: SizedBox(width: 10, height: 10)),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('viewer-action-download')), findsNothing);
    expect(find.byKey(const Key('viewer-action-share')), findsNothing);
    expect(find.byKey(const Key('fill-media-close')), findsOneWidget);
  });

  testWidgets('inline SFTP image fill passes the fetched image bytes', (
    tester,
  ) async {
    final spy = _SpyActionService();
    final w = _wire(
      tester,
      byPath: {
        '/': [
          const SftpEntry(
            name: 'doc.md',
            path: '/doc.md',
            isDirectory: false,
            size: 10,
          ),
        ],
      },
      spy: spy,
      cannedText: '![alt](img/a.png)',
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: w.container,
        child: MaterialApp(
          home: MarkdownFileViewerScreen(
            sessionId: w.session.id,
            entry: const SftpEntry(
              name: 'doc.md',
              path: '/doc.md',
              isDirectory: false,
            ),
          ),
        ),
      ),
    );
    await _pump(tester);

    final image = find.byKey(const Key('markdown-inline-image'));
    expect(image, findsOneWidget);
    // Raw-pointer tap (the inline image uses a Listener, not GestureDetector).
    final center = tester.getCenter(image);
    final gesture = await tester.startGesture(center);
    await gesture.up();
    await _pump(tester, count: 6);

    expect(find.byKey(const Key('fill-media-viewer')), findsOneWidget);
    // Scope to the fill overlay — the markdown app bar underneath carries its
    // own (correct) pair of actions.
    final fillDownload = find.descendant(
      of: find.byKey(const Key('fill-media-viewer')),
      matching: find.byKey(const Key('viewer-action-download')),
    );
    expect(fillDownload, findsOneWidget);
    await tester.tap(fillDownload);
    await _pump(tester, count: 4);

    expect(spy.downloads, hasLength(1));
    final source = spy.downloads.single as BytesFileSource;
    expect(source.fileName, 'a.png');
    expect(source.bytes, _png);
    w.host.disposeSyncForTest();
  });

  testWidgets('mermaid fill passes the diagram source as diagram.mmd', (
    tester,
  ) async {
    final spy = _SpyActionService();
    const mermaidSource = 'graph TD;\n  A-->B;\n';
    final w = _wire(
      tester,
      byPath: {'/': const []},
      spy: spy,
      cannedText: '```mermaid\n$mermaidSource```\n',
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: w.container,
        child: MaterialApp(
          home: MarkdownFileViewerScreen(
            sessionId: w.session.id,
            entry: const SftpEntry(
              name: 'diagram.md',
              path: '/diagram.md',
              isDirectory: false,
            ),
          ),
        ),
      ),
    );
    await _pump(tester);

    await tester.tap(find.byKey(const Key('mermaid-tap-to-fill')));
    await _pump(tester, count: 6);

    expect(find.byKey(const Key('fill-media-viewer')), findsOneWidget);
    // Scope to the fill overlay — the markdown app bar underneath carries its
    // own (correct) pair of actions.
    final fillShare = find.descendant(
      of: find.byKey(const Key('fill-media-viewer')),
      matching: find.byKey(const Key('viewer-action-share')),
    );
    expect(fillShare, findsOneWidget);
    await tester.tap(fillShare);
    await _pump(tester, count: 4);

    expect(spy.shares, hasLength(1));
    final source = spy.shares.single as BytesFileSource;
    expect(source.fileName, 'diagram.mmd');
    expect(utf8.decode(source.bytes), contains('A-->B'));
    w.host.disposeSyncForTest();
  });
}
