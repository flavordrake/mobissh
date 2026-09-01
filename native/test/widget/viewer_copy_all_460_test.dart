// Verify-first widget tests for the "Copy all" affordance in the text/code and
// markdown file viewers (#460).
//
// Assert:
//   - the text viewer's AppBar exposes a Copy-all action (keyed
//     `text-viewer-copy-all`, aria/tooltip "Copy all") and tapping it writes the
//     FULL file content to the clipboard,
//   - the markdown viewer exposes the same action (keyed `markdown-viewer-copy-all`)
//     and copies the full RAW source (regardless of rendered/raw view mode).
//
// Clipboard copy routes through the hardened `mobissh/clipboard` native channel
// (#845); mock it (and the platform read-back) exactly like
// file_browser_context_menu_test.dart — without the mock the custom channel call
// has no responder and HANGS the test.

import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// Injectable text fetcher: returns canned content without touching SFTP.
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

({ProviderContainer container, SessionEntry session, SessionHost host}) _wire(
  WidgetTester tester, {
  required Map<String, List<SftpEntry>> byPath,
  required String content,
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
      textFileFetcherProvider.overrideWithValue(_CannedTextFetcher(content)),
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

Future<SessionHost> _open(
  WidgetTester tester, {
  required String name,
  required String content,
}) async {
  final w = _wire(
    tester,
    byPath: {
      '/': [
        SftpEntry(name: name, path: '/$name', isDirectory: false, size: 20),
      ],
    },
    content: content,
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String? lastClipboard;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    lastClipboard = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('mobissh/clipboard'),
      (call) async {
        if (call.method == 'setText') {
          lastClipboard = (call.arguments as Map)['text'] as String?;
          return true;
        }
        return null;
      },
    );
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        lastClipboard = (call.arguments as Map)['text'] as String?;
      }
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': lastClipboard};
      }
      return null;
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('mobissh/clipboard'),
      null,
    );
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('text viewer exposes a Copy-all action that copies the full file', (
    tester,
  ) async {
    const content = 'line one\nline two\nline three\n';
    final host = await _open(tester, name: 'notes.txt', content: content);

    final btn = find.byKey(const Key('text-viewer-copy-all'));
    expect(btn, findsOneWidget);
    // Discoverable affordance labelled "Copy all".
    expect(
      tester.widget<IconButton>(btn).tooltip,
      'Copy all',
    );

    await tester.tap(btn);
    await _pump(tester);

    expect(lastClipboard, content);
    host.disposeSyncForTest();
  });

  testWidgets(
    'markdown viewer exposes a Copy-all action that copies the full raw source',
    (tester) async {
      const content = '# Title\n\nSome **bold** body.\n\n- a\n- b\n';
      final host = await _open(tester, name: 'README.md', content: content);

      final btn = find.byKey(const Key('markdown-viewer-copy-all'));
      expect(btn, findsOneWidget);
      expect(
        tester.widget<IconButton>(btn).tooltip,
        'Copy all',
      );

      await tester.tap(btn);
      await _pump(tester);

      // The FULL raw markdown source, not the rendered/flattened text.
      expect(lastClipboard, content);
      host.disposeSyncForTest();
    },
  );
}
