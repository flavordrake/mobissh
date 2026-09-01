// File browser sort widget tests (#951).
//
// Renders [FileBrowserScreen] against the same scripted SFTP harness as
// file_browser_favorites_test.dart and exercises the app-bar sort menu:
//   - the row subtitle shows the modification time
//   - choosing a sort key re-orders the list (UI-side, no refetch)
//   - the direction toggle reverses the order
//   - directories stay pinned first regardless

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

Future<void> _pump(WidgetTester tester, {int count = 14}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

// Recent mtimes so the relative-time subtitle renders deterministically.
final int _nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

final Map<String, List<SftpEntry>> _tree = {
  '/': [
    SftpEntry(name: 'docs', path: '/docs', isDirectory: true),
    SftpEntry(
      name: 'a.txt',
      path: '/a.txt',
      isDirectory: false,
      size: 10,
      modifyTime: _nowSec - 3600,
    ),
    SftpEntry(
      name: 'b.txt',
      path: '/b.txt',
      isDirectory: false,
      size: 5000,
      modifyTime: _nowSec - 7200,
    ),
    SftpEntry(
      name: 'c.txt',
      path: '/c.txt',
      isDirectory: false,
      size: 100,
      modifyTime: _nowSec - 60,
    ),
  ],
};

const SshConnectParams _params = SshConnectParams(
  host: 'h',
  port: 22,
  username: 'u',
  auth: SshAuth.password('p'),
);

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

double _dyOf(WidgetTester tester, String name) =>
    tester.getTopLeft(find.byKey(Key('file-entry-$name'))).dy;

Future<void> _selectSort(WidgetTester tester, Key itemKey) async {
  await tester.tap(find.byKey(const Key('file-browser-sort-button')));
  await _pump(tester);
  await tester.tap(find.byKey(itemKey));
  await _pump(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('row subtitle shows modification time', (tester) async {
    final h = await _mount(tester);
    // c.txt is 60s old → "… ago" appears in its subtitle.
    expect(find.textContaining('ago'), findsWidgets);
    h.dispose();
  });

  testWidgets('default order is name ascending, dirs first', (tester) async {
    final h = await _mount(tester);
    expect(_dyOf(tester, 'docs') < _dyOf(tester, 'a.txt'), isTrue);
    expect(_dyOf(tester, 'a.txt') < _dyOf(tester, 'b.txt'), isTrue);
    expect(_dyOf(tester, 'b.txt') < _dyOf(tester, 'c.txt'), isTrue);
    h.dispose();
  });

  testWidgets('sort by size ascending re-orders files (dir stays first)', (
    tester,
  ) async {
    final h = await _mount(tester);
    await _selectSort(tester, const Key('sort-key-size'));
    // Sizes: a=10, c=100, b=5000 → a, c, b. docs (dir) pinned first.
    expect(_dyOf(tester, 'docs') < _dyOf(tester, 'a.txt'), isTrue);
    expect(_dyOf(tester, 'a.txt') < _dyOf(tester, 'c.txt'), isTrue);
    expect(_dyOf(tester, 'c.txt') < _dyOf(tester, 'b.txt'), isTrue);
    h.dispose();
  });

  testWidgets('direction toggle reverses the order', (tester) async {
    final h = await _mount(tester);
    await _selectSort(tester, const Key('sort-key-size'));
    await _selectSort(tester, const Key('sort-dir-toggle'));
    // Size descending: b, c, a. docs still first (dirs pinned).
    expect(_dyOf(tester, 'docs') < _dyOf(tester, 'b.txt'), isTrue);
    expect(_dyOf(tester, 'b.txt') < _dyOf(tester, 'c.txt'), isTrue);
    expect(_dyOf(tester, 'c.txt') < _dyOf(tester, 'a.txt'), isTrue);
    h.dispose();
  });
}
