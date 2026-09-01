// Writer-seam tests for the SFTP upload chain (#892).
//
// Exercises [ProxyTextFileWriter] end-to-end through a real [SessionHost] wired
// to a [FakeSftpSession] over an [InMemoryGatewayPair] — the same seam the file
// editor will save through. Asserts the writer:
//   - completes with the byte count on a matching SftpUploadDoneEvent,
//   - errors on a matching SftpErrorEvent,
//   - IGNORES events carrying a different requestId (a concurrent op on the
//     same session must not complete/abort this write).
//
// The fake records the path + bytes the host wrote, proving the String → UTF-8
// → upload path is intact (the mirror of the text_file_fetcher read seam).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/services/text_file_writer.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/ssh/sftp_session.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';

/// Controller factory whose connect() never resolves a real socket.
SshSessionController _stubControllerFactory() {
  return SshSessionController(
    socketOpener: (host, port, {timeout}) {
      return Future.delayed(const Duration(days: 1), () {
        throw Exception('socketOpener not used in writer tests');
      });
    },
  );
}

/// Records what the host asked the SFTP layer to write; lets a test override
/// the done/error response so the writer's stream-matching can be exercised.
class _RecordingSftpSession implements SftpSession {
  _RecordingSftpSession({this.throwOnUpload = false});

  final bool throwOnUpload;
  String? lastUploadedPath;
  Uint8List? lastUploadedBytes;

  @override
  Future<List<SftpEntry>> list(String path) async => const [];

  @override
  Future<int?> sizeOf(String path) async => null;

  @override
  Future<int> download(
    String path, {
    required void Function(Uint8List chunk, int offset) onChunk,
    int chunkSize = 64 * 1024,
  }) async =>
      0;

  @override
  Future<int> upload(String path, Uint8List bytes) async {
    lastUploadedPath = path;
    lastUploadedBytes = Uint8List.fromList(bytes);
    if (throwOnUpload) throw Exception('boom-upload');
    return bytes.length;
  }

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

void main() {
  /// Build a container whose [sessionsProvider] holds one connected session
  /// whose proxy round-trips SFTP over a real [SessionHost] + the fake. Returns
  /// the container, the session id, the fake, and the task-side gateway (so a
  /// test can inject a stray event).
  Future<
      ({
        ProviderContainer container,
        String sessionId,
        _RecordingSftpSession fake,
        InMemoryGatewayPair pair,
      })> setUpConnected({bool throwOnUpload = false}) async {
    final pair = InMemoryGatewayPair();
    final fake = _RecordingSftpSession(throwOnUpload: throwOnUpload);
    // Task side: real host with the fake SFTP opener.
    SessionHost(
      gateway: pair.taskSide,
      controllerFactory: _stubControllerFactory,
      sftpOpener: (_) async => fake,
      snapshotInterval: const Duration(hours: 1),
    );
    // UI side: container wired to the same gateway pair.
    final container = ProviderContainer(overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
    ]);
    // addOrActivate creates the proxy but the CALLER drives connect; drive it so
    // the session is HOSTED task-side and the SFTP opener seam is reachable.
    final entry = container.read(sessionsProvider.notifier).addOrActivate(
          const SshConnectParams(
            host: 'h',
            port: 22,
            username: 'u',
            auth: SshAuth.password('p'),
          ),
        );
    entry.proxy.connect(const SshConnectParams(
      host: 'h',
      port: 22,
      username: 'u',
      auth: SshAuth.password('p'),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return (
      container: container,
      sessionId: entry.id,
      fake: fake,
      pair: pair,
    );
  }

  test('write completes with the byte count and uploads UTF-8 bytes', () async {
    final ctx = await setUpConnected();
    addTearDown(ctx.container.dispose);
    addTearDown(ctx.pair.dispose);

    final writer = ctx.container.read(textFileWriterProvider);
    const content = 'first line\nsecond line\n';
    final written = await writer.write(ctx.sessionId, '~/.ssh/config', content);

    expect(written, utf8.encode(content).length);
    expect(ctx.fake.lastUploadedPath, '~/.ssh/config');
    expect(ctx.fake.lastUploadedBytes, Uint8List.fromList(utf8.encode(content)));
  });

  test('write throws when the host reports an SFTP error', () async {
    final ctx = await setUpConnected(throwOnUpload: true);
    addTearDown(ctx.container.dispose);
    addTearDown(ctx.pair.dispose);

    final writer = ctx.container.read(textFileWriterProvider);
    await expectLater(
      writer.write(ctx.sessionId, '/etc/hosts', 'data'),
      throwsA(isA<Exception>()),
    );
  });

  test('write ignores upload-done events for a DIFFERENT requestId', () async {
    final ctx = await setUpConnected();
    addTearDown(ctx.container.dispose);
    addTearDown(ctx.pair.dispose);

    final writer = ctx.container.read(textFileWriterProvider);

    // Fire a stray upload-done with a mismatched requestId. If the writer
    // matched on kind alone (not requestId) it would complete with the WRONG
    // byte count (999) or complete before the real upload finished.
    ctx.pair.taskSide.send(
      SftpUploadDoneEvent(
        sessionId: ctx.sessionId,
        requestId: 'some-other-request',
        totalBytes: 999,
      ).toJson(),
    );

    const content = 'real content\n';
    final written = await writer.write(ctx.sessionId, '/tmp/x', content);

    // The real op's byte count, NOT the stray 999.
    expect(written, utf8.encode(content).length);
    expect(written, isNot(999));
  });
}
