// SessionHost SFTP handler tests (#559).
//
// Exercises the task-side ls + download routing with a fake [SftpSession]
// injected via the host's `sftpOpener` seam — no real socket, no SSHClient.
// Verifies the host emits the right request-id-scoped events and that errors
// surface as SftpErrorEvent without tearing the session down.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
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
    this.throwOnUpload = false,
    this.throwOnMkdir = false,
    this.mkdirError,
    this.listError,
  });

  final List<SftpEntry> entries;
  final List<int> fileBytes;
  final bool throwOnList;
  final bool throwOnDownload;
  final bool throwOnUpload;
  final bool throwOnMkdir;

  /// #1133: when set, [mkdir] throws THIS instead of the generic boom — used to
  /// prove the server's own message (permission denied / already exists)
  /// survives the isolate hop into the UI's error event.
  final Object? mkdirError;

  /// When set, [list] throws this instead of the generic boom (#867: exercise
  /// the SftpStatusError → friendly-message mapping through the host).
  final Object? listError;
  bool closed = false;
  String? lastListedPath;
  String? lastDownloadedPath;

  /// Records the streaming file-download call (#976): the remote + local paths.
  /// The fake writes [fileBytes] to the local staging path in TWO chunks — the
  /// bytes are written to DISK task-side, never returned across the gateway.
  String? lastDownloadFileRemote;
  String? lastDownloadFileLocal;

  /// #990: when set, [sizeOf] (the stat seam the host's sftpStat handler uses)
  /// succeeds ONLY for paths in this set and throws for anything else —
  /// modelling a real server's "No such file" stat error.
  Set<String>? statExisting;

  /// Records what the host wrote (#892): the resolved-or-literal path and the
  /// exact bytes, so a test can assert the upload reached the wrapper intact.
  String? lastUploadedPath;
  Uint8List? lastUploadedBytes;

  /// Records the chunked file-upload call (#960): the local + remote paths, and
  /// the total reported via [uploadFileTotal]. The fake emits a 0→total
  /// progress pair so the host's progress-forwarding can be asserted.
  String? lastUploadLocalPath;
  String? lastUploadRemotePath;
  int uploadFileTotal = 0;

  /// #1133: every directory the host asked us to create, in order — so a test
  /// can assert EXACTLY one mkdir with the joined absolute path.
  final List<String> createdDirs = [];

  @override
  Future<List<SftpEntry>> list(String path) async {
    lastListedPath = path;
    if (listError != null) throw listError!;
    if (throwOnList) throw Exception('boom-list');
    return entries;
  }

  @override
  Future<int?> sizeOf(String path) async {
    final existing = statExisting;
    if (existing != null && !existing.contains(path)) {
      throw Exception('No such file: $path');
    }
    return fileBytes.length;
  }

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
  Future<int> downloadFile(
    String remotePath,
    String localPath, {
    required void Function(int done, int total) onProgress,
    int chunkSize = 64 * 1024,
  }) async {
    lastDownloadFileRemote = remotePath;
    lastDownloadFileLocal = localPath;
    if (throwOnDownload) throw Exception('boom-download');
    // Stream the bytes to the staging file in two chunks (task-side), emitting
    // a monotonic 0 → mid → total progress sequence. Mirrors the real
    // DartSshSftpSession.downloadFile: the file is written to DISK here and only
    // (done, total) counters are handed back — the bytes never leave this side.
    final all = Uint8List.fromList(fileBytes);
    final total = all.length;
    final sink = File(localPath).openWrite();
    onProgress(0, total);
    if (total > 0) {
      final mid = (total / 2).ceil();
      sink.add(Uint8List.sublistView(all, 0, mid));
      onProgress(mid, total);
      if (mid < total) sink.add(Uint8List.sublistView(all, mid));
    }
    onProgress(total, total);
    await sink.close();
    return total;
  }

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
    lastUploadLocalPath = localPath;
    lastUploadRemotePath = remotePath;
    if (throwOnUpload) throw Exception('boom-upload');
    onProgress(0, uploadFileTotal);
    onProgress(uploadFileTotal, uploadFileTotal);
    return uploadFileTotal;
  }

  @override
  Future<void> mkdir(String path) async {
    createdDirs.add(path);
    if (mkdirError != null) throw mkdirError!;
    if (throwOnMkdir) throw Exception('boom-mkdir');
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

  test(
      'sftpDownloadFile streams to a staging file + emits progress, ZERO file '
      'bytes cross the gateway (#976 Slice A)', () async {
    // A "large" file: big enough that had bytes crossed (base64) the total wire
    // traffic would dwarf the handful of tiny progress envelopes.
    final big = List<int>.generate(512 * 1024, (i) => i & 0xff);
    final fake = FakeSftpSession(fileBytes: big);
    final ctx = await setUpConnected('sid-dlf', fake);
    addTearDown(ctx.pair.dispose);
    addTearDown(ctx.host.dispose);
    addTearDown(ctx.proxy.dispose);

    final tmp = await Directory.systemTemp.createTemp('mobissh_dlf_');
    addTearDown(() => tmp.delete(recursive: true));
    final localPath = '${tmp.path}/staged.bin';

    // Capture EVERY raw task→UI envelope so we can prove no file bytes crossed.
    final rawFromTask = <Map<String, dynamic>>[];
    final rawSub = ctx.pair.uiSide.incoming.listen(rawFromTask.add);

    final progress = <SftpDownloadProgressEvent>[];
    final chunks = <SftpDownloadChunkEvent>[];
    SftpDownloadDoneEvent? done;
    final sub = ctx.proxy.sftpEvents.listen((e) {
      if (e is SftpDownloadProgressEvent) progress.add(e);
      if (e is SftpDownloadChunkEvent) chunks.add(e);
      if (e is SftpDownloadDoneEvent) done = e;
    });

    ctx.proxy.sftpDownloadFile(
      requestId: 'sid-dlf#0',
      remotePath: '~/videos/big.mp4',
      localPath: localPath,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Progress-only path: NO chunk events at all.
    expect(chunks, isEmpty,
        reason: 'the new path must never ship SftpDownloadChunkEvent');
    // Monotonic progress, keyed by request id, ending exactly at total.
    expect(progress, isNotEmpty);
    expect(progress.every((p) => p.requestId == 'sid-dlf#0'), isTrue);
    expect(progress.every((p) => p.totalBytes == big.length), isTrue);
    final dones = progress.map((p) => p.done).toList();
    for (var i = 1; i < dones.length; i++) {
      expect(dones[i] >= dones[i - 1], isTrue, reason: 'progress must be monotonic');
    }
    expect(dones.last, big.length);
    // Terminal done event, keyed by request id.
    expect(done, isNotNull);
    expect(done!.requestId, 'sid-dlf#0');
    expect(done!.totalBytes, big.length);

    // The staging file was written task-side with the FULL bytes.
    final staged = await File(localPath).readAsBytes();
    expect(staged.length, big.length);
    expect(staged, big);
    expect(fake.lastDownloadFileRemote, '~/videos/big.mp4');
    expect(fake.lastDownloadFileLocal, localPath);

    // KEY assertion: ZERO file bytes crossed the gateway. Every task→UI envelope
    // is a tiny control message — none carries a 'bytes' field, and the TOTAL
    // serialized size is a small constant, independent of the 512KB file. The
    // retired chunk path would have base64'd ~700KB across here.
    final totalWire =
        rawFromTask.fold<int>(0, (a, m) => a + jsonEncode(m).length);
    expect(rawFromTask.any((m) => m.containsKey('bytes')), isFalse,
        reason: 'no task→UI envelope may carry file bytes');
    expect(totalWire, lessThan(4096),
        reason: 'progress-only wire traffic must stay tiny vs the 512KB file');

    await rawSub.cancel();
    await sub.cancel();
  });

  test('sftpUpload records path + bytes then emits a done event', () async {
    final fake = FakeSftpSession();
    final ctx = await setUpConnected('sid-up', fake);
    addTearDown(ctx.pair.dispose);
    addTearDown(ctx.host.dispose);
    addTearDown(ctx.proxy.dispose);

    SftpUploadDoneEvent? done;
    final sub = ctx.proxy.sftpEvents.listen((e) {
      if (e is SftpUploadDoneEvent) done = e;
    });

    final payload = Uint8List.fromList(utf8.encode('hello world\n'));
    ctx.proxy.sftpUpload(
      requestId: 'sid-up#write0',
      path: '~/.ssh/config',
      bytes: payload,
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(fake.lastUploadedPath, '~/.ssh/config');
    expect(fake.lastUploadedBytes, payload);
    expect(done, isNotNull);
    expect(done!.requestId, 'sid-up#write0');
    expect(done!.totalBytes, payload.length);

    await sub.cancel();
  });

  test('sftpMkdir creates the joined path then emits a done event (#1133)',
      () async {
    final fake = FakeSftpSession();
    final ctx = await setUpConnected('sid-mk', fake);
    addTearDown(ctx.pair.dispose);
    addTearDown(ctx.host.dispose);
    addTearDown(ctx.proxy.dispose);

    SftpMkdirDoneEvent? done;
    final sub = ctx.proxy.sftpEvents.listen((e) {
      if (e is SftpMkdirDoneEvent) done = e;
    });

    ctx.proxy.sftpMkdir(
      requestId: 'sid-mk#mkdir0',
      path: '/home/u/projects/new folder',
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(fake.createdDirs, ['/home/u/projects/new folder']);
    expect(done, isNotNull);
    expect(done!.requestId, 'sid-mk#mkdir0');
    expect(done!.path, '/home/u/projects/new folder');

    await sub.cancel();
  });

  test('sftpMkdir failure carries the SERVER message, session survives (#1133)',
      () async {
    // The two errors the owner actually hits. The message must NOT collapse to
    // a bool/generic string on its way across the isolate boundary.
    final fake = FakeSftpSession(
      mkdirError: SftpStatusError(3, 'Permission denied'),
    );
    final ctx = await setUpConnected('sid-mkerr', fake);
    addTearDown(ctx.pair.dispose);
    addTearDown(ctx.host.dispose);
    addTearDown(ctx.proxy.dispose);

    SftpErrorEvent? err;
    final sub = ctx.proxy.sftpEvents.listen((e) {
      if (e is SftpErrorEvent) err = e;
    });

    ctx.proxy.sftpMkdir(requestId: 'sid-mkerr#mkdir0', path: '/etc/nope');
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(err, isNotNull);
    expect(err!.requestId, 'sid-mkerr#mkdir0');
    expect(err!.message, contains('Permission denied'));
    expect(ctx.host.sessionIds, contains('sid-mkerr'));

    await sub.cancel();
  });

  test('sftpMkdir on an unhosted session emits not-connected error (#1133)',
      () async {
    final pair = InMemoryGatewayPair();
    addTearDown(pair.dispose);
    final host = SessionHost(
      gateway: pair.taskSide,
      controllerFactory: _stubControllerFactory,
      sftpOpener: (_) async => FakeSftpSession(),
      snapshotInterval: const Duration(hours: 1),
    );
    addTearDown(host.dispose);
    final proxy = SshSessionProxy(sessionId: 'ghost-mk', gateway: pair.uiSide);
    addTearDown(proxy.dispose);

    SftpErrorEvent? err;
    final sub = proxy.sftpEvents.listen((e) {
      if (e is SftpErrorEvent) err = e;
    });

    proxy.sftpMkdir(requestId: 'ghost-mk#mkdir0', path: '/x/y');
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(err, isNotNull);
    expect(err!.message, contains('not connected'));

    await sub.cancel();
  });

  test('sftpStat replies exists=true for a path the server can stat (#990)',
      () async {
    final fake = FakeSftpSession()..statExisting = {'/etc/hosts'};
    final ctx = await setUpConnected('sid-st', fake);
    addTearDown(ctx.pair.dispose);
    addTearDown(ctx.host.dispose);
    addTearDown(ctx.proxy.dispose);

    final results = <SftpStatResultEvent>[];
    final sub = ctx.proxy.sftpEvents.listen((e) {
      if (e is SftpStatResultEvent) results.add(e);
    });

    ctx.proxy.sftpStat(requestId: 'sid-st#0', path: '/etc/hosts');
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(results, hasLength(1));
    expect(results.single.requestId, 'sid-st#0');
    expect(results.single.path, '/etc/hosts');
    expect(results.single.exists, isTrue);

    await sub.cancel();
  });

  test('sftpStat replies exists=false (fail-open) when the stat errors (#990)',
      () async {
    final fake = FakeSftpSession()..statExisting = {'/etc/hosts'};
    final ctx = await setUpConnected('sid-st2', fake);
    addTearDown(ctx.pair.dispose);
    addTearDown(ctx.host.dispose);
    addTearDown(ctx.proxy.dispose);

    final results = <SftpStatResultEvent>[];
    final errors = <SftpErrorEvent>[];
    final sub = ctx.proxy.sftpEvents.listen((e) {
      if (e is SftpStatResultEvent) results.add(e);
      if (e is SftpErrorEvent) errors.add(e);
    });

    ctx.proxy.sftpStat(requestId: 'sid-st2#0', path: '/no/such/path990');
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(results, hasLength(1));
    expect(results.single.exists, isFalse);
    // Fail-open is a RESULT, not an error — a missing path must not surface
    // an SFTP error banner anywhere.
    expect(errors, isEmpty);

    await sub.cancel();
  });

  test('sftpStat replies exists=false for a session with no live client (#990)',
      () async {
    final fake = FakeSftpSession();
    final pair = InMemoryGatewayPair();
    addTearDown(pair.dispose);
    final host = SessionHost(
      gateway: pair.taskSide,
      controllerFactory: _stubControllerFactory,
      // Opener returning null = "session not connected" (matches production).
      sftpOpener: (_) async => null,
      snapshotInterval: const Duration(hours: 1),
    );
    addTearDown(host.dispose);
    final proxy = SshSessionProxy(sessionId: 'sid-st3', gateway: pair.uiSide);
    addTearDown(proxy.dispose);
    proxy.connect(const SshConnectParams(
      host: 'h',
      port: 22,
      username: 'u',
      auth: SshAuth.password('p'),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final results = <SftpStatResultEvent>[];
    final sub = proxy.sftpEvents.listen((e) {
      if (e is SftpStatResultEvent) results.add(e);
    });

    proxy.sftpStat(requestId: 'sid-st3#0', path: '/etc/hosts');
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(results, hasLength(1));
    expect(results.single.exists, isFalse,
        reason: 'no client → fail-open result, never a hang or an error event');
    expect(fake.closed, isFalse);

    await sub.cancel();
  });

  test('sftpUploadFile forwards progress then a done event (#960)', () async {
    final fake = FakeSftpSession()..uploadFileTotal = 4096;
    final ctx = await setUpConnected('sid-upf', fake);
    addTearDown(ctx.pair.dispose);
    addTearDown(ctx.host.dispose);
    addTearDown(ctx.proxy.dispose);

    final progress = <SftpUploadProgressEvent>[];
    SftpUploadDoneEvent? done;
    final sub = ctx.proxy.sftpEvents.listen((e) {
      if (e is SftpUploadProgressEvent) progress.add(e);
      if (e is SftpUploadDoneEvent) done = e;
    });

    ctx.proxy.sftpUploadFile(
      requestId: 'sid-upf#0',
      localPath: '/data/local/bigfile.iso',
      remotePath: '~/uploads/bigfile.iso',
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(fake.lastUploadLocalPath, '/data/local/bigfile.iso');
    expect(fake.lastUploadRemotePath, '~/uploads/bigfile.iso');
    // The fake emits 0→total; the host forwards both, keyed by request id.
    expect(progress.map((p) => p.sent), [0, 4096]);
    expect(progress.every((p) => p.totalBytes == 4096), isTrue);
    expect(progress.every((p) => p.requestId == 'sid-upf#0'), isTrue);
    expect(done, isNotNull);
    expect(done!.requestId, 'sid-upf#0');
    expect(done!.totalBytes, 4096);

    await sub.cancel();
  });

  test('upload failure surfaces as SftpErrorEvent, session survives', () async {
    final fake = FakeSftpSession(throwOnUpload: true);
    final ctx = await setUpConnected('sid-uperr', fake);
    addTearDown(ctx.pair.dispose);
    addTearDown(ctx.host.dispose);
    addTearDown(ctx.proxy.dispose);

    SftpErrorEvent? err;
    final sub = ctx.proxy.sftpEvents.listen((e) {
      if (e is SftpErrorEvent) err = e;
    });

    ctx.proxy.sftpUpload(
      requestId: 'sid-uperr#write0',
      path: '/etc/hosts',
      bytes: Uint8List.fromList([1, 2, 3]),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(err, isNotNull);
    expect(err!.requestId, 'sid-uperr#write0');
    expect(err!.message, contains('Upload failed'));
    // An SFTP error must not drop the SSH session.
    expect(ctx.host.sessionIds, contains('sid-uperr'));

    await sub.cancel();
  });

  test('upload on an unhosted session emits not-connected error', () async {
    final pair = InMemoryGatewayPair();
    addTearDown(pair.dispose);
    final host = SessionHost(
      gateway: pair.taskSide,
      controllerFactory: _stubControllerFactory,
      sftpOpener: (_) async => FakeSftpSession(),
      snapshotInterval: const Duration(hours: 1),
    );
    addTearDown(host.dispose);
    final proxy = SshSessionProxy(sessionId: 'ghost-up', gateway: pair.uiSide);
    addTearDown(proxy.dispose);

    SftpErrorEvent? err;
    final sub = proxy.sftpEvents.listen((e) {
      if (e is SftpErrorEvent) err = e;
    });

    proxy.sftpUpload(
      requestId: 'ghost-up#write0',
      path: '/x',
      bytes: Uint8List.fromList([0]),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(err, isNotNull);
    expect(err!.message, contains('not connected'));

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
    // #867: a generic (non-SftpStatusError) list failure surfaces the clean
    // "Couldn't open <path>" message, not a raw exception dump.
    expect(err!.message, "Couldn't open /nope");
    // The SSH session is still hosted — an SFTP error must not drop it.
    expect(ctx.host.sessionIds, contains('sid-err'));

    await sub.cancel();
  });

  test('#867 SftpStatusError(code 2) surfaces a friendly "not found"',
      () async {
    final fake = FakeSftpSession(
      listError: SftpStatusError(2, 'No such file'),
    );
    final ctx = await setUpConnected('sid-nf', fake);
    addTearDown(ctx.pair.dispose);
    addTearDown(ctx.host.dispose);
    addTearDown(ctx.proxy.dispose);

    SftpErrorEvent? err;
    final sub = ctx.proxy.sftpEvents.listen((e) {
      if (e is SftpErrorEvent) err = e;
    });

    ctx.proxy.sftpList(requestId: 'sid-nf#0', path: '/home/ra/.claude/missing');
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(err, isNotNull);
    // The clean empty-state message, NOT the raw "SftpStatusError: …(code 2)".
    expect(err!.message, 'Folder not found: /home/ra/.claude/missing');
    expect(err!.message, isNot(contains('SftpStatusError')));

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

  test('concurrent SFTP ops share ONE subsystem open (#1092 dedupe)', () async {
    // Regression for the poison-the-session bug: a first open that STALLS left
    // `sftp` null, so every later op fired ANOTHER parallel open. The in-flight
    // guard must collapse concurrent ops onto a single open.
    var openCount = 0;
    final gate = Completer<void>();
    final fake = FakeSftpSession(entries: const [
      SftpEntry(name: 'a', path: '/a', isDirectory: false, size: 1),
    ]);
    final pair = InMemoryGatewayPair();
    addTearDown(pair.dispose);
    final host = SessionHost(
      gateway: pair.taskSide,
      controllerFactory: _stubControllerFactory,
      sftpOpener: (_) async {
        openCount++;
        await gate.future; // hold the open until BOTH ops are queued
        return fake;
      },
      snapshotInterval: const Duration(hours: 1),
    );
    addTearDown(host.dispose);
    final proxy = SshSessionProxy(sessionId: 'sid-dedupe', gateway: pair.uiSide);
    addTearDown(proxy.dispose);
    proxy.connect(const SshConnectParams(
      host: 'h',
      port: 22,
      username: 'u',
      auth: SshAuth.password('p'),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final events = <SshTaskEvent>[];
    final sub = proxy.sftpEvents.listen(events.add);

    // Fire two listings back-to-back, before the first open resolves.
    proxy.sftpList(requestId: 'sid-dedupe#0', path: '/');
    proxy.sftpList(requestId: 'sid-dedupe#1', path: '/');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(openCount, 1, reason: 'concurrent ops must share one open');
    final listings = events.whereType<SftpListingEvent>().toList();
    expect(
      listings.map((e) => e.requestId),
      containsAll(<String>['sid-dedupe#0', 'sid-dedupe#1']),
    );

    await sub.cancel();
  });

  test('a stalled subsystem open times out into an SftpError (#1092)',
      () async {
    // The core fix: without a bound, a subsystem open that never completes left
    // the browser spinning forever. It must surface a real error instead.
    final never = Completer<SftpSession?>(); // deliberately never completes
    final pair = InMemoryGatewayPair();
    addTearDown(pair.dispose);
    final host = SessionHost(
      gateway: pair.taskSide,
      controllerFactory: _stubControllerFactory,
      sftpOpener: (_) => never.future,
      sftpOpenTimeout: const Duration(milliseconds: 40),
      snapshotInterval: const Duration(hours: 1),
    );
    addTearDown(host.dispose);
    final proxy =
        SshSessionProxy(sessionId: 'sid-timeout', gateway: pair.uiSide);
    addTearDown(proxy.dispose);
    proxy.connect(const SshConnectParams(
      host: 'h',
      port: 22,
      username: 'u',
      auth: SshAuth.password('p'),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    SftpErrorEvent? err;
    final sub = proxy.sftpEvents.listen((e) {
      if (e is SftpErrorEvent) err = e;
    });

    proxy.sftpList(requestId: 'sid-timeout#0', path: '/');
    await Future<void>.delayed(const Duration(milliseconds: 140));

    expect(err, isNotNull, reason: 'open must not hang forever');
    expect(err!.requestId, 'sid-timeout#0');
    expect(err!.message.toLowerCase(), contains('busy'));

    await sub.cancel();
  });
}
