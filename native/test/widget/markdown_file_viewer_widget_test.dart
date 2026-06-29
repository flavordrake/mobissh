// Widget tests for the in-app markdown viewer + its registry routing (#854).
//
// Assert:
//   - tapping a `.md` / `.markdown` entry in the file browser routes to
//     [MarkdownFileViewerScreen] (via the registry, which orders markdown
//     BEFORE the generic text viewer — first match wins), NOT the text viewer
//     and NOT the download path,
//   - the viewer fetches the source via the injected fetcher and RENDERS it by
//     default (a `Markdown` widget is present; the literal source — `# `, `**`
//     — is NOT shown as raw text),
//   - the chrome toggle switches rendered ⇄ raw (raw shows the monospace
//     source verbatim),
//   - tapping a rendered link routes through the injected opener (url_launcher
//     seam), not a real platform channel.
//
// Mirrors the wiring in text_file_viewer_widget_test.dart (InMemoryGatewayPair
// + FileBrowserScreen + a canned TextFileFetcher override) so the markdown
// viewer is exercised through the same browser → registry → route path the user
// hits, without a real SSH socket.

import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/services/text_file_fetcher.dart';
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

/// Injectable text fetcher: returns canned markdown without touching SFTP.
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

({ProviderContainer container, SessionEntry session, SessionHost host}) _wire(
  WidgetTester tester, {
  required Map<String, List<SftpEntry>> byPath,
  required String markdown,
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
      textFileFetcherProvider.overrideWithValue(_CannedTextFetcher(markdown)),
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

const _sampleMarkdown =
    '# Heading One\n\n'
    'Some **bold** and *italic* text with a [link](https://example.com).\n\n'
    '- first item\n'
    '- second item\n\n'
    '```dart\nvoid main() {}\n```\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<SessionHost> openMarkdown(WidgetTester tester, String name) async {
    final w = _wire(
      tester,
      byPath: {
        '/': [
          SftpEntry(name: name, path: '/$name', isDirectory: false, size: 20),
        ],
      },
      markdown: _sampleMarkdown,
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
    // Returned so each test can dispose the host SYNCHRONOUSLY at the end of its
    // body (before the framework's pending-timer assertion) — the SessionHost's
    // periodic snapshot timer would otherwise trip "pending timers".
    return w.host;
  }

  testWidgets('.md routes to the markdown viewer, not the text viewer', (
    tester,
  ) async {
    final host = await openMarkdown(tester, 'README.md');
    expect(find.byType(MarkdownFileViewerScreen), findsOneWidget);
    expect(find.byType(TextFileViewerScreen), findsNothing);
    host.disposeSyncForTest();
  });

  testWidgets('.markdown routes to the markdown viewer', (tester) async {
    final host = await openMarkdown(tester, 'NOTES.markdown');
    expect(find.byType(MarkdownFileViewerScreen), findsOneWidget);
    host.disposeSyncForTest();
  });

  testWidgets('renders markdown by default (formatted, not raw source)', (
    tester,
  ) async {
    final host = await openMarkdown(tester, 'README.md');

    // Rendered: a Markdown widget is present.
    expect(find.byType(Markdown), findsOneWidget);
    expect(find.byKey(const Key('markdown-viewer-rendered')), findsOneWidget);
    // Raw monospace source is NOT shown.
    expect(find.byKey(const Key('markdown-viewer-raw')), findsNothing);
    // The heading TEXT is rendered (without the literal '# ' syntax).
    expect(find.textContaining('Heading One'), findsOneWidget);
    // The literal markdown syntax must NOT appear verbatim in rendered mode.
    expect(find.textContaining('# Heading One'), findsNothing);
    expect(find.textContaining('**bold**'), findsNothing);
    host.disposeSyncForTest();
  });

  testWidgets('toggle switches rendered ⇄ raw and back', (tester) async {
    final host = await openMarkdown(tester, 'README.md');

    // Default: rendered.
    expect(find.byKey(const Key('markdown-viewer-rendered')), findsOneWidget);
    expect(find.byKey(const Key('markdown-viewer-raw')), findsNothing);

    // Toggle → raw: the verbatim source (with '# ' and '**') is shown.
    await tester.tap(find.byKey(const Key('markdown-raw-toggle')));
    await _pump(tester);
    expect(find.byKey(const Key('markdown-viewer-raw')), findsOneWidget);
    expect(find.byKey(const Key('markdown-viewer-rendered')), findsNothing);
    expect(find.byType(Markdown), findsNothing);
    expect(find.textContaining('# Heading One'), findsOneWidget);

    // Toggle back → rendered.
    await tester.tap(find.byKey(const Key('markdown-raw-toggle')));
    await _pump(tester);
    expect(find.byKey(const Key('markdown-viewer-rendered')), findsOneWidget);
    expect(find.byKey(const Key('markdown-viewer-raw')), findsNothing);
    host.disposeSyncForTest();
  });

  testWidgets('empty markdown shows an empty-file placeholder', (tester) async {
    final w = _wire(
      tester,
      byPath: {
        '/': const [
          SftpEntry(
            name: 'EMPTY.md',
            path: '/EMPTY.md',
            isDirectory: false,
            size: 0,
          ),
        ],
      },
      markdown: '',
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: w.container,
        child: MaterialApp(home: FileBrowserScreen(sessionId: w.session.id)),
      ),
    );
    await _pump(tester);
    await tester.tap(find.byKey(const Key('file-entry-EMPTY.md')));
    await _pump(tester);

    expect(find.byType(MarkdownFileViewerScreen), findsOneWidget);
    expect(find.byKey(const Key('markdown-viewer-empty')), findsOneWidget);

    w.host.disposeSyncForTest();
  });

  testWidgets('tapping a rendered link routes through the link opener seam', (
    tester,
  ) async {
    // Build the viewer directly with an injected opener spy so we can assert the
    // url_launcher seam is invoked without a real platform channel.
    final opened = <String>[];
    final pair = InMemoryGatewayPair();
    addTearDown(pair.dispose);
    final host = SessionHost(
      gateway: pair.taskSide,
      controllerFactory: _stubControllerFactory,
      sftpOpener: (_) async => _ScriptedSftpSession(const {}),
      snapshotInterval: const Duration(hours: 1),
    );
    final container = ProviderContainer(
      overrides: [
        taskSshGatewayProvider.overrideWithValue(pair.uiSide),
        textFileFetcherProvider.overrideWithValue(
          _CannedTextFetcher('[click me](https://example.com)'),
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

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: MarkdownFileViewerScreen(
            sessionId: session.id,
            entry: const SftpEntry(
              name: 'L.md',
              path: '/L.md',
              isDirectory: false,
            ),
            openLink: (href) async {
              opened.add(href);
            },
          ),
        ),
      ),
    );
    await _pump(tester);

    expect(find.byType(Markdown), findsOneWidget);
    await tester.tap(find.textContaining('click me'));
    await _pump(tester);

    expect(opened, ['https://example.com']);
    host.disposeSyncForTest();
  });
}
