// Stream-path backfill for the three SFTP fetchers (#1159, coverage U1):
// ProxyPdfFetcher (#557), ProxyTextFileFetcher (#776/#893) and
// ProxySftpImageFetcher (#946).
//
// All three share a hand-written pattern: mint a `'$sessionId#<kind><seq>'`
// requestId, subscribe `proxy.sftpEvents`, consume ONLY events carrying that
// requestId, reassemble chunks by byte offset (#591), complete on `done`, fail
// on `error`, and cancel the subscription in `finally`. None of that had a test.
//
// The test IS the task side: a real `SshSessionProxy` is bound to
// `InMemoryGatewayPair.uiSide` (via `sessionsProvider.addOrActivate`, the same
// mount the file-browser widget tests use), the `sftpDownload` command is
// captured on `taskSide.incoming`, and chunk/done/error events are replayed
// through `taskSide.send(...)` — so bytes cross the same base64 JSON codec as
// production. The PDF fetcher's `TempFileSink.create` resolves the temp dir via
// path_provider; that method channel is mocked to a per-test temp directory so
// the real `OffsetFileSink` writes to disk and the file can be verified.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/pdf_fetcher.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/sftp_image_fetcher.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/services/text_file_fetcher.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:shared_preferences/shared_preferences.dart';

const SshConnectParams _params = SshConnectParams(
  host: 'h',
  port: 22,
  username: 'u',
  auth: SshAuth.password('p'),
);

const SftpEntry _pdfEntry = SftpEntry(
  name: 'doc.pdf',
  path: '/srv/doc.pdf',
  isDirectory: false,
);
const SftpEntry _txtEntry = SftpEntry(
  name: 'notes.txt',
  path: '/srv/notes.txt',
  isDirectory: false,
);

/// A captured `sftpDownload` command as seen by the task side.
typedef _Request = ({String requestId, String path});

/// Real proxy + in-memory gateway; the test plays the task side by hand.
class _Harness {
  _Harness() {
    pair = InMemoryGatewayPair();
    container = ProviderContainer(
      overrides: [taskSshGatewayProvider.overrideWithValue(pair.uiSide)],
    );
    entry = container.read(sessionsProvider.notifier).addOrActivate(_params);
    _cmdSub = pair.taskSide.incoming.listen((payload) {
      if (payload['kind'] == SshTaskCommandKind.sftpDownload.name) {
        requests.add((
          requestId: payload['requestId'] as String,
          path: payload['path'] as String,
        ));
      }
    });
  }

  late final InMemoryGatewayPair pair;
  late final ProviderContainer container;
  late final SessionEntry entry;
  late final StreamSubscription<Map<String, dynamic>> _cmdSub;

  /// Every `sftpDownload` command the UI side sent, in order.
  final List<_Request> requests = <_Request>[];

  String get sid => entry.id;

  /// Wait until at least [n] download commands have crossed the gateway.
  Future<void> awaitRequests(int n) async {
    for (var i = 0; i < 50 && requests.length < n; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(requests.length, greaterThanOrEqualTo(n),
        reason: 'expected $n sftpDownload command(s) on the task side');
  }

  /// Task → UI: one download chunk for [requestId] at byte [offset].
  void chunk(String requestId, List<int> bytes, int offset, {int? total}) {
    pair.taskSide.send(
      SftpDownloadChunkEvent(
        sessionId: sid,
        requestId: requestId,
        bytes: Uint8List.fromList(bytes),
        offset: offset,
        totalBytes: total,
      ).toJson(),
    );
  }

  /// Task → UI: transfer complete, [total] bytes.
  void done(String requestId, int total) {
    pair.taskSide.send(
      SftpDownloadDoneEvent(
        sessionId: sid,
        requestId: requestId,
        totalBytes: total,
      ).toJson(),
    );
  }

  /// Task → UI: transfer failed.
  void error(String requestId, String message) {
    pair.taskSide.send(
      SftpErrorEvent(
        sessionId: sid,
        requestId: requestId,
        message: message,
      ).toJson(),
    );
  }

  /// Let queued gateway events drain to the fetcher's listener.
  Future<void> settle() async {
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> dispose() async {
    await _cmdSub.cancel();
    container.dispose();
    await pair.dispose();
  }
}

/// Track whether a future has settled without awaiting it.
class _Settled<T> {
  _Settled(Future<T> f) {
    f.then((v) {
      value = v;
      completed = true;
    }, onError: (Object e) {
      error = e;
      completed = true;
    });
  }
  bool completed = false;
  T? value;
  Object? error;
}

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Harness h;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    h = _Harness();
  });

  tearDown(() async {
    await h.dispose();
  });

  group('ProxyTextFileFetcher', () {
    late TextFileFetcher fetcher;
    setUp(() => fetcher = h.container.read(textFileFetcherProvider));

    test('mints "<sessionId>#text<seq>" and downloads the entry path',
        () async {
      final f = fetcher.fetch(h.sid, _txtEntry);
      await h.awaitRequests(1);
      expect(h.requests.single.requestId, '${h.sid}#text0');
      expect(h.requests.single.path, '/srv/notes.txt');
      h.chunk(h.requests.single.requestId, _bytes('ok'), 0, total: 2);
      h.done(h.requests.single.requestId, 2);
      expect(await f, 'ok');
    });

    test('(b) reordered chunks reassemble by offset; progress is cumulative',
        () async {
      final progress = <(int, int?)>[];
      final f = fetcher.fetch(
        h.sid,
        _txtEntry,
        onProgress: (r, t) => progress.add((r, t)),
      );
      await h.awaitRequests(1);
      final rid = h.requests.single.requestId;
      const text = 'alpha\nbravo\ncharlie café\n';
      final src = _bytes(text);
      // Three chunks delivered 2, 0, 1 — the #591 reorder case.
      final a = src.sublist(0, 6), b = src.sublist(6, 12), c = src.sublist(12);
      h.chunk(rid, c, 12, total: src.length);
      h.chunk(rid, a, 0, total: src.length);
      h.chunk(rid, b, 6, total: src.length);
      h.done(rid, src.length);
      expect(await f, text);
      expect(progress, [
        (c.length, src.length),
        (c.length + a.length, src.length),
        (src.length, src.length),
      ]);
    });

    test('(a) events for a sibling requestId on the same session are ignored',
        () async {
      final f = fetcher.fetch(h.sid, _txtEntry);
      await h.awaitRequests(1);
      final rid = h.requests.single.requestId;
      final settled = _Settled(f);
      // A sibling fetch's stream on the SAME session must not leak in.
      h.chunk('${h.sid}#text99', _bytes('WRONG'), 0);
      h.done('${h.sid}#text99', 5);
      await h.settle();
      expect(settled.completed, isFalse,
          reason: 'sibling done must not complete this fetch');
      h.chunk(rid, _bytes('mine'), 0);
      h.done(rid, 4);
      expect(await f, 'mine');
    });

    test('(d) exceeding maxBytes throws StateError; exactly maxBytes is fine',
        () async {
      final ok = fetcher.fetch(h.sid, _txtEntry, maxBytes: 4);
      await h.awaitRequests(1);
      final rid0 = h.requests[0].requestId;
      h.chunk(rid0, _bytes('abcd'), 0);
      h.done(rid0, 4);
      expect(await ok, 'abcd');

      final big = fetcher.fetch(h.sid, _txtEntry, maxBytes: 4);
      await h.awaitRequests(2);
      final rid1 = h.requests[1].requestId;
      h.chunk(rid1, _bytes('abcd'), 0);
      h.chunk(rid1, _bytes('e'), 4);
      await expectLater(
        big,
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          'File is too large to preview',
        )),
      );
      // A late done for the failed request is harmless.
      h.done(rid1, 5);
      await h.settle();
    });

    test('(d) binary content (NUL byte) throws BinaryFileException', () async {
      final f = fetcher.fetch(h.sid, _txtEntry);
      await h.awaitRequests(1);
      final rid = h.requests.single.requestId;
      h.chunk(rid, [0x48, 0x69, 0x00, 0x21], 0);
      h.done(rid, 4);
      await expectLater(f, throwsA(isA<BinaryFileException>()));
    });

    test('(e) error event rethrows with the task message', () async {
      final f = fetcher.fetch(h.sid, _txtEntry);
      await h.awaitRequests(1);
      final rid = h.requests.single.requestId;
      h.chunk(rid, _bytes('partial'), 0);
      h.error(rid, 'Permission denied');
      await expectLater(
        f,
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'toString',
          contains('Permission denied'),
        )),
      );
      // Late events after failure neither throw nor resurrect the fetch.
      h.chunk(rid, _bytes('late'), 7);
      h.done(rid, 11);
      await h.settle();
    });

    test('(f) two concurrent fetches get distinct seq and own results',
        () async {
      final f0 = fetcher.fetch(h.sid, _txtEntry);
      final f1 = fetcher.fetch(h.sid, _txtEntry);
      await h.awaitRequests(2);
      final rid0 = h.requests[0].requestId;
      final rid1 = h.requests[1].requestId;
      expect(rid0, '${h.sid}#text0');
      expect(rid1, '${h.sid}#text1');
      // Finish the SECOND request first.
      h.chunk(rid1, _bytes('second'), 0);
      h.done(rid1, 6);
      expect(await f1, 'second');
      final s0 = _Settled(f0);
      await h.settle();
      expect(s0.completed, isFalse);
      h.chunk(rid0, _bytes('first'), 0);
      h.done(rid0, 5);
      expect(await f0, 'first');
    });

    test('unknown session throws StateError before any command is sent',
        () async {
      await expectLater(
        fetcher.fetch('nope:22:x:0', _txtEntry),
        throwsA(isA<StateError>()),
      );
      await h.settle();
      expect(h.requests, isEmpty);
    });
  });

  group('ProxySftpImageFetcher', () {
    late SftpImageFetcher fetcher;
    setUp(() => fetcher = h.container.read(sftpImageFetcherProvider));

    test('mints "<sessionId>#img<seq>" and downloads the given path',
        () async {
      final f = fetcher.fetch(h.sid, '/srv/a.png');
      await h.awaitRequests(1);
      expect(h.requests.single.requestId, '${h.sid}#img0');
      expect(h.requests.single.path, '/srv/a.png');
      h.chunk(h.requests.single.requestId, [1, 2], 0);
      h.done(h.requests.single.requestId, 2);
      expect(await f, [1, 2]);
    });

    test('(b) reordered chunks reassemble by offset; raw bytes, no binary '
        'rejection', () async {
      final f = fetcher.fetch(h.sid, '/srv/a.png');
      await h.awaitRequests(1);
      final rid = h.requests.single.requestId;
      // PNG-ish header with NUL bytes — a text fetcher would reject this.
      final src = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
      ]);
      h.chunk(rid, src.sublist(8), 8, total: 16);
      h.chunk(rid, src.sublist(0, 4), 0, total: 16);
      h.chunk(rid, src.sublist(4, 8), 4, total: 16);
      h.done(rid, 16);
      expect(await f, src);
    });

    test('(a) events for a sibling requestId are ignored', () async {
      final f = fetcher.fetch(h.sid, '/srv/a.png');
      await h.awaitRequests(1);
      final rid = h.requests.single.requestId;
      final settled = _Settled(f);
      h.chunk('${h.sid}#img7', [9, 9, 9], 0);
      h.done('${h.sid}#img7', 3);
      h.error('${h.sid}#text0', 'other kind');
      await h.settle();
      expect(settled.completed, isFalse);
      h.chunk(rid, [4, 2], 0);
      h.done(rid, 2);
      expect(await f, [4, 2]);
    });

    test('(d) exceeding maxBytes throws StateError; exactly maxBytes is fine',
        () async {
      final ok = fetcher.fetch(h.sid, '/srv/a.png', maxBytes: 3);
      await h.awaitRequests(1);
      final rid0 = h.requests[0].requestId;
      h.chunk(rid0, [1, 2, 3], 0);
      h.done(rid0, 3);
      expect(await ok, [1, 2, 3]);

      final big = fetcher.fetch(h.sid, '/srv/a.png', maxBytes: 3);
      await h.awaitRequests(2);
      final rid1 = h.requests[1].requestId;
      h.chunk(rid1, [1, 2], 0);
      h.chunk(rid1, [3, 4], 2);
      await expectLater(
        big,
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          'Image is too large to preview',
        )),
      );
      h.done(rid1, 4);
      await h.settle();
    });

    test('(e) error event rethrows with the task message', () async {
      final f = fetcher.fetch(h.sid, '/srv/a.png');
      await h.awaitRequests(1);
      final rid = h.requests.single.requestId;
      h.error(rid, 'No such file');
      await expectLater(
        f,
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'toString',
          contains('No such file'),
        )),
      );
      h.chunk(rid, [1], 0);
      h.done(rid, 1);
      await h.settle();
    });

    test('(f) two concurrent fetches get distinct seq and own results',
        () async {
      final f0 = fetcher.fetch(h.sid, '/srv/a.png');
      final f1 = fetcher.fetch(h.sid, '/srv/b.png');
      await h.awaitRequests(2);
      final rid0 = h.requests[0].requestId;
      final rid1 = h.requests[1].requestId;
      expect(rid0, '${h.sid}#img0');
      expect(rid1, '${h.sid}#img1');
      expect(h.requests[1].path, '/srv/b.png');
      h.chunk(rid1, [2], 0);
      h.done(rid1, 1);
      expect(await f1, [2]);
      h.chunk(rid0, [1], 0);
      h.done(rid0, 1);
      expect(await f0, [1]);
    });

    test('unknown session throws StateError', () async {
      await expectLater(
        fetcher.fetch('nope:22:x:0', '/srv/a.png'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('ProxyPdfFetcher', () {
    late PdfFetcher fetcher;
    late Directory tmp;
    const channel = MethodChannel('plugins.flutter.io/path_provider');

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('mobissh_pdf_1159_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getTemporaryDirectory') return tmp.path;
        return null;
      });
      fetcher = h.container.read(pdfFetcherProvider);
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    /// Files currently staged under the fetcher's `mobissh_pdf` subdir.
    Future<List<File>> staged() async {
      final dir = Directory('${tmp.path}/mobissh_pdf');
      if (!await dir.exists()) return const [];
      return (await dir.list().toList()).whereType<File>().toList();
    }

    test('mints "<sessionId>#pdf<seq>" and downloads the entry path',
        () async {
      final f = fetcher.fetch(h.sid, _pdfEntry);
      await h.awaitRequests(1);
      expect(h.requests.single.requestId, '${h.sid}#pdf0');
      expect(h.requests.single.path, '/srv/doc.pdf');
      h.chunk(h.requests.single.requestId, _bytes('%PDF'), 0);
      h.done(h.requests.single.requestId, 4);
      final file = await f;
      expect(file.path, endsWith('-doc.pdf'));
      expect(file.path, startsWith('${tmp.path}/mobissh_pdf/'));
      expect(await file.readAsString(), '%PDF');
    });

    test('(c) reordered chunks land at their offsets; finish runs after every '
        'write; progress is cumulative', () async {
      final progress = <(int, int?)>[];
      final f = fetcher.fetch(
        h.sid,
        _pdfEntry,
        onProgress: (r, t) => progress.add((r, t)),
      );
      await h.awaitRequests(1);
      final rid = h.requests.single.requestId;
      // 8 x 1 KiB chunks of distinct fill bytes, delivered in scrambled order.
      final src = Uint8List(8 * 1024);
      for (var i = 0; i < src.length; i++) {
        src[i] = i ~/ 1024;
      }
      for (final i in [5, 0, 7, 2, 6, 1, 3, 4]) {
        h.chunk(rid, src.sublist(i * 1024, (i + 1) * 1024), i * 1024,
            total: src.length);
      }
      h.done(rid, src.length);
      final file = await f;
      expect(await file.readAsBytes(), src);
      expect(progress.length, 8);
      expect(progress.last, (src.length, src.length));
      expect(progress.first, (1024, src.length));
    });

    test('(c) done with a total that does not match the bytes written fails '
        'and deletes the temp file', () async {
      final f = fetcher.fetch(h.sid, _pdfEntry);
      await h.awaitRequests(1);
      final rid = h.requests.single.requestId;
      h.chunk(rid, _bytes('0123456789'), 0, total: 20);
      // The task claims 20 bytes but only 10 arrived (truncated transfer).
      h.done(rid, 20);
      await expectLater(
        f,
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'toString',
          contains('Download incomplete'),
        )),
      );
      expect(await staged(), isEmpty,
          reason: 'a truncated PDF must not be left on disk');
    });

    test('(e) error event rethrows, aborts the sink and deletes the temp file',
        () async {
      final f = fetcher.fetch(h.sid, _pdfEntry);
      await h.awaitRequests(1);
      final rid = h.requests.single.requestId;
      h.chunk(rid, _bytes('%PDF-1.4'), 0);
      await h.settle();
      expect(await staged(), hasLength(1),
          reason: 'the temp file exists while the transfer is in flight');
      h.error(rid, 'Connection reset');
      await expectLater(
        f,
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'toString',
          contains('Connection reset'),
        )),
      );
      expect(await staged(), isEmpty);
      // Late events after failure are harmless.
      h.chunk(rid, _bytes('x'), 8);
      h.done(rid, 9);
      await h.settle();
    });

    test('(a) events for a sibling requestId are ignored', () async {
      final f = fetcher.fetch(h.sid, _pdfEntry);
      await h.awaitRequests(1);
      final rid = h.requests.single.requestId;
      final settled = _Settled(f);
      h.chunk('${h.sid}#pdf42', _bytes('WRONG'), 0);
      h.done('${h.sid}#pdf42', 5);
      h.error('${h.sid}#pdf43', 'not mine');
      await h.settle();
      expect(settled.completed, isFalse);
      expect(await staged(), hasLength(1),
          reason: 'a sibling error must not abort this sink');
      h.chunk(rid, _bytes('mine'), 0);
      h.done(rid, 4);
      expect(await (await f).readAsString(), 'mine');
    });

    test('(f) two concurrent fetches get distinct seq, files and contents',
        () async {
      final f0 = fetcher.fetch(h.sid, _pdfEntry);
      final f1 = fetcher.fetch(h.sid, _pdfEntry);
      await h.awaitRequests(2);
      final rid0 = h.requests[0].requestId;
      final rid1 = h.requests[1].requestId;
      expect(rid0, '${h.sid}#pdf0');
      expect(rid1, '${h.sid}#pdf1');
      h.chunk(rid1, _bytes('second'), 0);
      h.done(rid1, 6);
      final file1 = await f1;
      h.chunk(rid0, _bytes('first'), 0);
      h.done(rid0, 5);
      final file0 = await f0;
      expect(file0.path, isNot(file1.path));
      expect(await file0.readAsString(), 'first');
      expect(await file1.readAsString(), 'second');
    });

    test('unknown session throws StateError and stages nothing', () async {
      await expectLater(
        fetcher.fetch('nope:22:x:0', _pdfEntry),
        throwsA(isA<StateError>()),
      );
      expect(await staged(), isEmpty);
    });
  });
}
