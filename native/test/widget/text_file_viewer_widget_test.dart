// Widget tests for the in-app text/code viewer + the file viewer registry
// (#776).
//
// Assert:
//   - tapping a `.txt` / `.dart` / `.md` entry in the file browser routes to
//     [TextFileViewerScreen] (via the registry), NOT the download path,
//   - the viewer fetches the bytes through an injected fetcher and renders the
//     decoded content (assert the actual text, not just a mount),
//   - tapping a `.pdf` still routes to the PDF viewer (registry regression),
//   - tapping an unknown binary file falls through to the download path.

import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/sftp_download.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/services/text_file_fetcher.dart';
import 'package:mobissh/ssh/sftp_session.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/file_browser_screen.dart';
import 'package:mobissh/ui/markdown_file_viewer.dart';
import 'package:mobissh/ui/pdf_viewer_screen.dart';
import 'package:mobissh/ui/text_file_viewer.dart';
import 'package:shared_preferences/shared_preferences.dart';

SshSessionController _stubControllerFactory() {
  return SshSessionController(
    socketOpener: (host, port, {timeout}) => Completer<SSHSocket>().future,
  );
}

class _ScriptedSftpSession implements SftpSession {
  _ScriptedSftpSession(this._byPath, this._fileBytes);
  final Map<String, List<SftpEntry>> _byPath;
  final List<int> _fileBytes;

  @override
  Future<List<SftpEntry>> list(String path) async => _byPath[path] ?? const [];
  @override
  Future<int?> sizeOf(String path) async => _fileBytes.length;
  @override
  Future<int> download(
    String path, {
    required void Function(Uint8List chunk, int offset) onChunk,
    int chunkSize = 64 * 1024,
  }) async {
    onChunk(Uint8List.fromList(_fileBytes), 0);
    return _fileBytes.length;
  }

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

class _MemSink implements FileDownloadSink {
  final List<int> _buf = <int>[];
  bool finished = false;

  @override
  Future<void> addChunk(Uint8List bytes, int offset) async {
    final end = offset + bytes.length;
    while (_buf.length < end) {
      _buf.add(0);
    }
    for (var i = 0; i < bytes.length; i++) {
      _buf[offset + i] = bytes[i];
    }
  }

  @override
  Future<String> finish({int? expectedTotal}) async {
    finished = true;
    return '/test/Download/captured';
  }

  @override
  Future<void> abort() async {}
}

/// Injectable text fetcher: returns canned text without touching SFTP.
class _CannedTextFetcher implements TextFileFetcher {
  _CannedTextFetcher(this.text);
  final String text;
  SftpEntry? lastEntry;

  @override
  Future<String> fetch(
    String sessionId,
    SftpEntry entry, {
    int maxBytes = 2 * 1024 * 1024,
    void Function(int received, int? total)? onProgress,
  }) async {
    lastEntry = entry;
    return text;
  }
}

Future<void> _pump(WidgetTester tester, {int count = 12}) async {
  for (var i = 0; i < count; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 30));
  }
}

({ProviderContainer container, SessionEntry session, SessionHost host})
_wire(
  WidgetTester tester, {
  required Map<String, List<SftpEntry>> byPath,
  List<int> fileBytes = const [],
  List<Override> overrides = const [],
}) {
  final pair = InMemoryGatewayPair();
  addTearDown(pair.dispose);
  final host = SessionHost(
    gateway: pair.taskSide,
    controllerFactory: _stubControllerFactory,
    sftpOpener: (_) async => _ScriptedSftpSession(byPath, fileBytes),
    snapshotInterval: const Duration(hours: 1),
  );
  final container = ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      ...overrides,
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

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('tapping a .txt routes to the text viewer and renders content', (
    tester,
  ) async {
    const content = 'hello world\nsecond line';
    final fetcher = _CannedTextFetcher(content);
    final w = _wire(
      tester,
      byPath: {
        '/': const [
          SftpEntry(name: 'a.txt', path: '/a.txt', isDirectory: false, size: 5),
        ],
      },
      overrides: [textFileFetcherProvider.overrideWithValue(fetcher)],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: w.container,
        child: MaterialApp(home: FileBrowserScreen(sessionId: w.session.id)),
      ),
    );
    await _pump(tester);

    expect(find.byKey(const Key('file-entry-a.txt')), findsOneWidget);
    await tester.tap(find.byKey(const Key('file-entry-a.txt')));
    await _pump(tester);

    // Routed to the text viewer, not the download path.
    expect(find.byType(TextFileViewerScreen), findsOneWidget);
    expect(find.textContaining('Downloaded'), findsNothing);
    // Content rendered (assert the actual bytes, not just a mount).
    expect(fetcher.lastEntry?.name, 'a.txt');
    expect(find.byKey(const Key('text-viewer-content')), findsOneWidget);
    expect(find.textContaining('hello world'), findsOneWidget);
    expect(find.textContaining('second line'), findsOneWidget);

    w.host.disposeSyncForTest();
  });

  Future<void> routesToTextViewer(WidgetTester tester, String name) async {
    final fetcher = _CannedTextFetcher('void main() {}');
    final w = _wire(
      tester,
      byPath: {
        '/': [
          SftpEntry(name: name, path: '/$name', isDirectory: false, size: 3),
        ],
      },
      overrides: [textFileFetcherProvider.overrideWithValue(fetcher)],
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

    expect(find.byType(TextFileViewerScreen), findsOneWidget, reason: name);
    w.host.disposeSyncForTest();
  }

  testWidgets('tapping a .dart routes to the text viewer', (tester) async {
    await routesToTextViewer(tester, 'main.dart');
  });

  testWidgets('tapping a .md routes to the markdown viewer (#854)', (
    tester,
  ) async {
    // #854: `.md` now routes to the dedicated rendered markdown viewer, NOT the
    // generic monospace text viewer — even though `isTextEntry` also matches it
    // (the registry orders markdown first; first match wins).
    final fetcher = _CannedTextFetcher('# Title\n\nbody');
    final w = _wire(
      tester,
      byPath: {
        '/': const [
          SftpEntry(
            name: 'README.md',
            path: '/README.md',
            isDirectory: false,
            size: 14,
          ),
        ],
      },
      overrides: [textFileFetcherProvider.overrideWithValue(fetcher)],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: w.container,
        child: MaterialApp(home: FileBrowserScreen(sessionId: w.session.id)),
      ),
    );
    await _pump(tester);

    await tester.tap(find.byKey(const Key('file-entry-README.md')));
    await _pump(tester);

    expect(find.byType(MarkdownFileViewerScreen), findsOneWidget);
    expect(find.byType(TextFileViewerScreen), findsNothing);

    w.host.disposeSyncForTest();
  });

  testWidgets('tapping a .pdf still routes to the PDF viewer (registry)', (
    tester,
  ) async {
    final w = _wire(
      tester,
      byPath: {
        '/': const [
          SftpEntry(
            name: 'doc.pdf',
            path: '/doc.pdf',
            isDirectory: false,
            size: 10,
          ),
        ],
      },
      fileBytes: '%PDF-1.4'.codeUnits,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: w.container,
        child: MaterialApp(home: FileBrowserScreen(sessionId: w.session.id)),
      ),
    );
    await _pump(tester);

    await tester.tap(find.byKey(const Key('file-entry-doc.pdf')));
    await _pump(tester);

    expect(find.byType(PdfViewerScreen), findsOneWidget);
    expect(find.byType(TextFileViewerScreen), findsNothing);

    w.host.disposeSyncForTest();
  });

  testWidgets('tapping an unknown binary falls through to download', (
    tester,
  ) async {
    final memSink = _MemSink();
    final bytes = List<int>.generate(8, (i) => i + 1);
    final w = _wire(
      tester,
      byPath: {
        '/': const [
          SftpEntry(
            name: 'app.bin',
            path: '/app.bin',
            isDirectory: false,
            size: 8,
          ),
        ],
      },
      fileBytes: bytes,
      overrides: [
        downloadSinkFactoryProvider.overrideWithValue((name) async => memSink),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: w.container,
        child: MaterialApp(home: FileBrowserScreen(sessionId: w.session.id)),
      ),
    );
    await _pump(tester);

    await tester.tap(find.byKey(const Key('file-entry-app.bin')));
    await _pump(tester);

    // No viewer; download path ran.
    expect(find.byType(TextFileViewerScreen), findsNothing);
    expect(find.byType(PdfViewerScreen), findsNothing);
    expect(memSink.finished, isTrue);
    expect(find.textContaining('Downloaded app.bin'), findsOneWidget);

    w.host.disposeSyncForTest();
  });
}
