// File browser per-entry context-menu widget tests (#952).
//
// Long-pressing a file/folder entry opens a context menu (replacing the old
// long-press→favorites menu, #632). Covers: the menu's items, copy full path /
// copy name writing to the clipboard, add-to-favorites persistence, the details
// sheet, and that directories omit the Download action.

import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  @override
  Future<void> close() async {}
}

Future<void> _pump(WidgetTester tester, {int count = 14}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

const Map<String, List<SftpEntry>> _tree = {
  '/': [
    SftpEntry(name: 'docs', path: '/docs', isDirectory: true),
    SftpEntry(
      name: 'a.txt',
      path: '/a.txt',
      isDirectory: false,
      size: 4,
      modifyTime: 1700000000,
    ),
  ],
};

const SshConnectParams _params = SshConnectParams(
  host: 'h',
  port: 22,
  username: 'u',
  auth: SshAuth.password('p'),
);
const String _profileKey = 'h:22:u';

class _Harness {
  _Harness(this.host, this.container);
  final SessionHost host;
  final ProviderContainer container;
  void dispose() {
    host.disposeSyncForTest();
    container.dispose();
  }
}

Future<_Harness> _mount(WidgetTester tester) async {
  final pair = InMemoryGatewayPair();
  final host = SessionHost(
    gateway: pair.taskSide,
    controllerFactory: _stubControllerFactory,
    sftpOpener: (_) async => _ScriptedSftpSession(_tree),
    snapshotInterval: const Duration(hours: 1),
  );
  final container = ProviderContainer(
    overrides: [taskSshGatewayProvider.overrideWithValue(pair.uiSide)],
  );
  final entry = container.read(sessionsProvider.notifier).addOrActivate(_params);
  entry.proxy.connect(_params);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: FileBrowserScreen(sessionId: entry.id)),
    ),
  );
  await _pump(tester);
  return _Harness(host, container);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Capture clipboard writes. Copy routes through the hardened `mobissh/clipboard`
  // native channel (#845); mock it (and the platform read-back) like
  // url_action_overlay_test.dart — without the mock the custom channel call has
  // no responder and HANGS the test.
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

  testWidgets('long-press a file shows the context menu with all items', (
    tester,
  ) async {
    final h = await _mount(tester);
    await tester.longPress(find.byKey(const Key('file-entry-a.txt')));
    await _pump(tester);

    expect(find.byKey(const Key('file-entry-context-menu')), findsOneWidget);
    expect(find.byKey(const Key('file-context-copy-path')), findsOneWidget);
    expect(find.byKey(const Key('file-context-copy-name')), findsOneWidget);
    expect(find.byKey(const Key('file-context-details')), findsOneWidget);
    expect(find.byKey(const Key('file-context-download')), findsOneWidget);
    expect(find.byKey(const Key('file-context-favorite')), findsOneWidget);

    h.dispose();
  });

  testWidgets('directory context menu omits Download', (tester) async {
    final h = await _mount(tester);
    await tester.longPress(find.byKey(const Key('file-entry-docs')));
    await _pump(tester);

    expect(find.byKey(const Key('file-entry-context-menu')), findsOneWidget);
    expect(find.byKey(const Key('file-context-download')), findsNothing);

    h.dispose();
  });

  testWidgets('copy full path writes the path to the clipboard', (tester) async {
    final h = await _mount(tester);
    await tester.longPress(find.byKey(const Key('file-entry-a.txt')));
    await _pump(tester);

    await tester.tap(find.byKey(const Key('file-context-copy-path')));
    await _pump(tester);

    expect(lastClipboard, '/a.txt');

    h.dispose();
  });

  testWidgets('copy name writes the name to the clipboard', (tester) async {
    final h = await _mount(tester);
    await tester.longPress(find.byKey(const Key('file-entry-a.txt')));
    await _pump(tester);

    await tester.tap(find.byKey(const Key('file-context-copy-name')));
    await _pump(tester);

    expect(lastClipboard, 'a.txt');

    h.dispose();
  });

  testWidgets('add to favorites persists the entry path', (tester) async {
    final h = await _mount(tester);
    await tester.longPress(find.byKey(const Key('file-entry-a.txt')));
    await _pump(tester);

    await tester.tap(find.byKey(const Key('file-context-favorite')));
    await _pump(tester);

    expect(await FavoritesStore().isFavorite(_profileKey, '/a.txt'), isTrue);

    h.dispose();
  });

  testWidgets('show details opens the details sheet', (tester) async {
    final h = await _mount(tester);
    await tester.longPress(find.byKey(const Key('file-entry-a.txt')));
    await _pump(tester);

    await tester.tap(find.byKey(const Key('file-context-details')));
    await _pump(tester);

    expect(find.byKey(const Key('file-details-sheet')), findsOneWidget);
    expect(find.text('/a.txt'), findsWidgets);
    expect(find.text('File'), findsOneWidget);

    h.dispose();
  });
}
