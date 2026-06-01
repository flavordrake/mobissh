// File browser widget test (#559).
//
// Renders [FileBrowserScreen] against a real proxy wired to a task-side
// [SessionHost] with a fake [SftpSession]. Verifies:
//   - the browser lists the directory entries it receives,
//   - tapping a directory navigates into it,
//   - tapping a file triggers the download path (chunks assembled into an
//     injected in-memory sink, success snackbar shown).
//
// The download sink is overridden so no real filesystem is touched.

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
import 'package:mobissh/ssh/sftp_session.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/file_browser_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

SshSessionController _stubControllerFactory() {
  return SshSessionController(
    // Never completes AND creates no timer (a bare Completer.future), so the
    // connect() stays parked without leaving a pending fake_async timer.
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
  Future<void> close() async {}
}

/// In-memory sink so the download path runs without a real filesystem. Honors
/// the chunk byte offset (#591) by writing into an offset-indexed buffer, so it
/// faithfully mirrors the real [OffsetFileSink] semantics.
class _MemSink implements FileDownloadSink {
  final List<int> _buf = <int>[];
  bool finished = false;
  int? finishExpectedTotal;

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

  Uint8List toBytes() => Uint8List.fromList(_buf);

  @override
  Future<String> finish({int? expectedTotal}) async {
    finished = true;
    finishExpectedTotal = expectedTotal;
    return '/test/Download/captured';
  }

  @override
  Future<void> abort() async {}
}

Future<void> _pump(WidgetTester tester, {int count = 10}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('lists entries; navigates into a dir; tapping a file downloads', (
    tester,
  ) async {
    final pair = InMemoryGatewayPair();
    addTearDown(pair.dispose);

    final fileBytes = List<int>.generate(12, (i) => i + 1);
    final fake = _ScriptedSftpSession({
      '/': const [
        SftpEntry(name: 'docs', path: '/docs', isDirectory: true),
        SftpEntry(name: 'a.txt', path: '/a.txt', isDirectory: false, size: 12),
      ],
      '/docs': const [
        SftpEntry(
          name: 'inner.bin',
          path: '/docs/inner.bin',
          isDirectory: false,
          size: 12,
        ),
      ],
    }, fileBytes);

    final host = SessionHost(
      gateway: pair.taskSide,
      controllerFactory: _stubControllerFactory,
      sftpOpener: (_) async => fake,
      snapshotInterval: const Duration(hours: 1),
    );

    final memSink = _MemSink();
    final container = ProviderContainer(
      overrides: [
        taskSshGatewayProvider.overrideWithValue(pair.uiSide),
        downloadSinkFactoryProvider.overrideWithValue((name) async => memSink),
      ],
    );
    addTearDown(container.dispose);

    const params = SshConnectParams(
      host: 'h',
      port: 22,
      username: 'u',
      auth: SshAuth.password('p'),
    );
    final entry = container
        .read(sessionsProvider.notifier)
        .addOrActivate(params);
    // Register the session on the host so its SFTP opener can resolve. (The
    // controller's connect never reaches a real socket; we only need the host
    // to hold the session entry.)
    entry.proxy.connect(params);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: FileBrowserScreen(sessionId: entry.id)),
      ),
    );
    await _pump(tester);

    // Root listing rendered both entries.
    expect(find.byKey(const Key('file-browser-list')), findsOneWidget);
    expect(find.byKey(const Key('file-entry-docs')), findsOneWidget);
    expect(find.byKey(const Key('file-entry-a.txt')), findsOneWidget);

    // Navigate into the directory.
    await tester.tap(find.byKey(const Key('file-entry-docs')));
    await _pump(tester);
    expect(find.byKey(const Key('file-entry-inner.bin')), findsOneWidget);
    expect(find.text('/docs'), findsOneWidget);

    // Go back up to root.
    await tester.tap(find.byKey(const Key('file-browser-up')));
    await _pump(tester);
    expect(find.byKey(const Key('file-entry-a.txt')), findsOneWidget);

    // Tap the file → download runs through the injected sink.
    await tester.tap(find.byKey(const Key('file-entry-a.txt')));
    await _pump(tester);

    expect(memSink.finished, isTrue);
    expect(memSink.toBytes(), Uint8List.fromList(fileBytes));
    // Success snackbar.
    expect(find.textContaining('Downloaded a.txt'), findsOneWidget);

    // Cancel the host's periodic snapshot timer before the framework's
    // pending-timer invariant check (matches multi_session_rebind_test).
    host.disposeSyncForTest();
  });

  testWidgets('a list error renders the error state', (tester) async {
    final pair = InMemoryGatewayPair();
    addTearDown(pair.dispose);

    final host = SessionHost(
      gateway: pair.taskSide,
      controllerFactory: _stubControllerFactory,
      sftpOpener: (_) async => _ThrowingSftpSession(),
      snapshotInterval: const Duration(hours: 1),
    );

    final container = ProviderContainer(
      overrides: [taskSshGatewayProvider.overrideWithValue(pair.uiSide)],
    );
    addTearDown(container.dispose);

    const params = SshConnectParams(
      host: 'h',
      port: 22,
      username: 'u',
      auth: SshAuth.password('p'),
    );
    final entry = container
        .read(sessionsProvider.notifier)
        .addOrActivate(params);
    entry.proxy.connect(params);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: FileBrowserScreen(sessionId: entry.id)),
      ),
    );
    await _pump(tester);

    expect(find.byKey(const Key('file-browser-error')), findsOneWidget);

    host.disposeSyncForTest();
  });
}

class _ThrowingSftpSession implements SftpSession {
  @override
  Future<List<SftpEntry>> list(String path) async => throw Exception('nope');
  @override
  Future<int?> sizeOf(String path) async => null;
  @override
  Future<int> download(
    String path, {
    required void Function(Uint8List chunk, int offset) onChunk,
    int chunkSize = 64 * 1024,
  }) async => 0;
  @override
  Future<void> close() async {}
}
