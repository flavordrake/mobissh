// SessionHost SFTP handler tests (#559).
//
// Exercises the task-side ls + download routing with a fake [SftpSession]
// injected via the host's `sftpOpener` seam — no real socket, no SSHClient.
// Verifies the host emits the right request-id-scoped events and that errors
// surface as SftpErrorEvent without tearing the session down.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/ssh/sftp_session.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/ssh/ssh_session_proxy.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';

/// Controller factory whose connect() never resolves a real socket — tests
/// drive state via debugSetConnectedForTest.
SshSessionController _stubControllerFactory() {
  return SshSessionController(
    socketOpener: (host, port, {timeout}) {
      return Future.delayed(const Duration(days: 1), () {
        throw Exception('socketOpener not used in SFTP tests');
      });
    },
  );
}

class FakeSftpSession implements SftpSession {
  FakeSftpSession({
    this.entries = const [],
    this.fileBytes = const [],
    this.throwOnList = false,
    this.throwOnDownload = false,
  });

  final List<SftpEntry> entries;
  final List<int> fileBytes;
  final bool throwOnList;
  final bool throwOnDownload;
  bool closed = false;
  String? lastListedPath;
  String? lastDownloadedPath;

  @override
  Future<List<SftpEntry>> list(String path) async {
    lastListedPath = path;
    if (throwOnList) throw Exception('boom-list');
    return entries;
  }

  @override
  Future<int?> sizeOf(String path) async => fileBytes.length;

  @override
  Future<int> download(
    String path, {
    required void Function(Uint8List chunk, int offset) onChunk,
    int chunkSize = 64 * 1024,
  }) async {
    lastDownloadedPath = path;
    if (throwOnDownload) throw Exception('boom-download');
    // Emit two chunks to exercise offset accounting.
    final all = Uint8List.fromList(fileBytes);
    final mid = (all.length / 2).ceil();
    if (all.isNotEmpty) {
      onChunk(Uint8List.sublistView(all, 0, mid), 0);
      if (mid < all.length) {
        onChunk(Uint8List.sublistView(all, mid), mid);
      }
    }
    return all.length;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  /// Build a host + proxy pair, with a session pre-marked connected so the
  /// SFTP opener seam is reached.
  Future<({SessionHost host, SshSessionProxy proxy, InMemoryGatewayPair pair})>
      setUpConnected(
    String sid,
    FakeSftpSession fake,
  ) async {
    final pair = InMemoryGatewayPair();
    final host = SessionHost(
      gateway: pair.taskSide,
      controllerFactory: _stubControllerFactory,
      sftpOpener: (_) async => fake,
      snapshotInterval: const Duration(hours: 1),
    );
    final proxy = SshSessionProxy(sessionId: sid, gateway: pair.uiSide);
    proxy.connect(const SshConnectParams(
      host: 'h',
      port: 22,
      username: 'u',
      auth: SshAuth.password('p'),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return (host: host, proxy: proxy, pair: pair);
  }

  test('sftpList emits a listing event with the entries', () async {
    final fake = FakeSftpSession(entries: const [
      SftpEntry(name: 'docs', path: '/docs', isDirectory: true),
      SftpEntry(name: 'a.txt', path: '/a.txt', isDirectory: false, size: 5),
    ]);
    final ctx = await setUpConnected('sid-ls', fake);
    addTearDown(ctx.pair.dispose);
    addTearDown(ctx.host.dispose);
    addTearDown(ctx.proxy.dispose);

    final events = <SshTaskEvent>[];
    final sub = ctx.proxy.sftpEvents.listen(events.add);

    ctx.proxy.sftpList(requestId: 'sid-ls#0', path: '/');
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final listing =
        events.whereType<SftpListingEvent>().toList();
    expect(listing, isNotEmpty);
    expect(listing.first.requestId, 'sid-ls#0');
    expect(listing.first.path, '/');
    expect(listing.first.entries.map((e) => e.name), ['docs', 'a.txt']);
    expect(fake.lastListedPath, '/');

    await sub.cancel();
  });

  test('sftpDownload streams chunks then a done event', () async {
    final fake = FakeSftpSession(fileBytes: List<int>.generate(10, (i) => i));
    final ctx = await setUpConnected('sid-dl', fake);
    addTearDown(ctx.pair.dispose);
    addTearDown(ctx.host.dispose);
    addTearDown(ctx.proxy.dispose);

    final chunks = <SftpDownloadChunkEvent>[];
    SftpDownloadDoneEvent? done;
    final sub = ctx.proxy.sftpEvents.listen((e) {
      if (e is SftpDownloadChunkEvent) chunks.add(e);
      if (e is SftpDownloadDoneEvent) done = e;
    });

    ctx.proxy.sftpDownload(requestId: 'sid-dl#0', path: '/a.bin');
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(chunks, isNotEmpty);
    // Reassembled bytes must equal the source file.
    final assembled = <int>[];
    for (final c in chunks) {
      expect(c.requestId, 'sid-dl#0');
      assembled.addAll(c.bytes);
    }
    expect(assembled, List<int>.generate(10, (i) => i));
    expect(done, isNotNull);
    expect(done!.totalBytes, 10);
    expect(chunks.first.totalBytes, 10); // size resolved up front
    expect(fake.lastDownloadedPath, '/a.bin');

    await sub.cancel();
  });

  test('list failure surfaces as SftpErrorEvent, session survives', () async {
    final fake = FakeSftpSession(throwOnList: true);
    final ctx = await setUpConnected('sid-err', fake);
    addTearDown(ctx.pair.dispose);
    addTearDown(ctx.host.dispose);
    addTearDown(ctx.proxy.dispose);

    SftpErrorEvent? err;
    final sub = ctx.proxy.sftpEvents.listen((e) {
      if (e is SftpErrorEvent) err = e;
    });

    ctx.proxy.sftpList(requestId: 'sid-err#0', path: '/nope');
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(err, isNotNull);
    expect(err!.requestId, 'sid-err#0');
    expect(err!.message, contains('List failed'));
    // The SSH session is still hosted — an SFTP error must not drop it.
    expect(ctx.host.sessionIds, contains('sid-err'));

    await sub.cancel();
  });

  test('SFTP op on an unhosted session emits not-connected error', () async {
    final pair = InMemoryGatewayPair();
    addTearDown(pair.dispose);
    final host = SessionHost(
      gateway: pair.taskSide,
      controllerFactory: _stubControllerFactory,
      sftpOpener: (_) async => FakeSftpSession(),
      snapshotInterval: const Duration(hours: 1),
    );
    addTearDown(host.dispose);
    final proxy = SshSessionProxy(sessionId: 'ghost', gateway: pair.uiSide);
    addTearDown(proxy.dispose);

    SftpErrorEvent? err;
    final sub = proxy.sftpEvents.listen((e) {
      if (e is SftpErrorEvent) err = e;
    });

    proxy.sftpList(requestId: 'ghost#0', path: '/');
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(err, isNotNull);
    expect(err!.message, contains('not connected'));

    await sub.cancel();
  });
}
