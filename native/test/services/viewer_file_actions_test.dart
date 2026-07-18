// Unit tests for the shared viewer Download + Share service (#1038).
//
// Assert:
//   - mime mapping for share (delegates to the loopback content-type table,
//     parameters stripped, `.mmd` covered, unknown → octet-stream),
//   - a BytesFileSource download writes the bytes through the injected
//     download sink (offset 0, verified total) and returns the sink's
//     location,
//   - shareFile stages a REAL local temp file and hands its path + mime + name
//     to the share launcher seam (the file must exist with the exact content
//     when the launcher runs — the share sheet receives a file, not a path
//     string),
//   - a RemoteFileSource streams over the live proxy machinery (the same
//     InMemoryGatewayPair harness the browser tests use) and assembles
//     out-of-order chunks correctly (#591 semantics).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/sftp_download.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/services/viewer_file_actions.dart';
import 'package:mobissh/ssh/sftp_session.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory offset-honoring sink (same contract as the emulator tests').
class _CapturingSink implements FileDownloadSink {
  final List<int> _buf = <int>[];
  bool finished = false;
  int? expectedTotalSeen;

  Uint8List get bytes => Uint8List.fromList(_buf);

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
    expectedTotalSeen = expectedTotal;
    return 'memory://capture';
  }

  @override
  Future<void> abort() async {}
}

SshSessionController _stubControllerFactory() {
  return SshSessionController(
    socketOpener: (host, port, {timeout}) => Completer<SSHSocket>().future,
  );
}

/// Scripted SFTP session whose download emits [content] in two chunks in
/// REVERSE order — the service must reassemble by offset (#591).
class _ChunkedSftpSession implements SftpSession {
  _ChunkedSftpSession(this.content);
  final Uint8List content;

  @override
  Future<List<SftpEntry>> list(String path) async => const [];
  @override
  Future<int?> sizeOf(String path) async => content.length;
  @override
  Future<int> download(
    String path, {
    required void Function(Uint8List chunk, int offset) onChunk,
    int chunkSize = 64 * 1024,
  }) async {
    final split = content.length ~/ 2;
    onChunk(content.sublist(split), split); // tail FIRST
    onChunk(content.sublist(0, split), 0); // head second
    return content.length;
  }

  @override
  Future<int> upload(String path, Uint8List bytes) async => bytes.length;
  @override
  Future<int> uploadFile(
    String localPath,
    String remotePath, {
    required void Function(int sent, int total) onProgress,
    int chunkSize = 64 * 1024,
  }) async => 0;
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('viewerShareMimeType', () {
    test('maps common extensions and strips charset parameters', () {
      expect(viewerShareMimeType('a.txt'), 'text/plain');
      expect(viewerShareMimeType('b.PNG'), 'image/png');
      expect(viewerShareMimeType('c.pdf'), 'application/pdf');
      expect(viewerShareMimeType('d.md'), 'text/markdown');
      expect(viewerShareMimeType('e.html'), 'text/html');
    });

    test('covers mermaid sources and falls back to octet-stream', () {
      expect(viewerShareMimeType('diagram.mmd'), 'text/plain');
      expect(viewerShareMimeType('mystery.zzz'), 'application/octet-stream');
      expect(viewerShareMimeType('noext'), 'application/octet-stream');
    });
  });

  test('BytesFileSource download writes through the download sink', () async {
    final sink = _CapturingSink();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = ProxyFileViewerActionService(
      container.read(_refProvider),
      downloadSinkFactory: (name) async => sink,
      shareStageFactory: (name) async => throw UnimplementedError(),
      shareLauncher: (path, mime, name) async => throw UnimplementedError(),
    );

    final bytes = Uint8List.fromList(utf8.encode('graph TD;\nA-->B;\n'));
    final location = await service.downloadToDevice(
      BytesFileSource(fileName: 'diagram.mmd', bytes: bytes),
    );

    expect(location, 'memory://capture');
    expect(sink.finished, isTrue);
    expect(sink.bytes, bytes);
    expect(sink.expectedTotalSeen, bytes.length);
  });

  test('shareFile stages a real temp file and launches with mime + name', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final stageDir = await Directory.systemTemp.createTemp('mobissh_1038_');
    addTearDown(() => stageDir.delete(recursive: true));

    String? launchedPath;
    String? launchedMime;
    String? launchedName;
    String? contentAtLaunch;

    final service = ProxyFileViewerActionService(
      container.read(_refProvider),
      downloadSinkFactory: (name) async => throw UnimplementedError(),
      shareStageFactory: (name) async =>
          OffsetFileSink.create(File('${stageDir.path}/$name')),
      shareLauncher: (path, mime, name) async {
        launchedPath = path;
        launchedMime = mime;
        launchedName = name;
        contentAtLaunch = await File(path).readAsString();
      },
    );

    const content = 'hello share 1038';
    await service.shareFile(
      BytesFileSource(
        fileName: 'note.txt',
        bytes: Uint8List.fromList(utf8.encode(content)),
      ),
    );

    expect(launchedPath, isNotNull);
    expect(contentAtLaunch, content, reason: 'the FILE must exist when shared');
    expect(launchedMime, 'text/plain');
    expect(launchedName, 'note.txt');
  });

  test('RemoteFileSource streams via the proxy, reassembling by offset', () async {
    SharedPreferences.setMockInitialValues({});
    final content = Uint8List.fromList(
      utf8.encode('0123456789abcdefghij REMOTE 1038'),
    );
    final pair = InMemoryGatewayPair();
    addTearDown(pair.dispose);
    final host = SessionHost(
      gateway: pair.taskSide,
      controllerFactory: _stubControllerFactory,
      sftpOpener: (_) async => _ChunkedSftpSession(content),
      snapshotInterval: const Duration(hours: 1),
    );
    addTearDown(host.disposeSyncForTest);
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
    final session = container.read(sessionsProvider.notifier).addOrActivate(
      params,
    );
    session.proxy.connect(params);

    final sink = _CapturingSink();
    final progress = <int>[];
    final service = ProxyFileViewerActionService(
      container.read(_refProvider),
      downloadSinkFactory: (name) async => sink,
      shareStageFactory: (name) async => throw UnimplementedError(),
      shareLauncher: (path, mime, name) async => throw UnimplementedError(),
    );

    final location = await service.downloadToDevice(
      RemoteFileSource(
        sessionId: session.id,
        entry: const SftpEntry(
          name: 'remote.txt',
          path: '/remote.txt',
          isDirectory: false,
        ),
      ),
      onProgress: (received, total) => progress.add(received),
    );

    expect(location, 'memory://capture');
    expect(sink.bytes, content, reason: 'chunks must reassemble by offset');
    expect(progress, isNotEmpty, reason: 'progress must be reported');
  });
}

/// Expose a [Ref] for constructing the production service directly in tests.
final _refProvider = Provider<Ref>((ref) => ref);
