// File browser download: task-side streaming path (#976).
//
// Slice B repoints the browser's download-to-file path off the old
// SftpDownloadChunkEvent firehose (raw bytes base64 across the isolate per
// chunk → UI-isolate saturation → ANR/force-quit) onto the task-side
// SftpDownloadFileCommand + SftpDownloadProgressEvent path landed in Slice A.
//
// These tests assert the STRUCTURAL root-cause fix (no chunk events for a
// download), the progress-update throttle, and the size-gate + cancel affordances.

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
    socketOpener: (host, port, {timeout}) => Completer<SSHSocket>().future,
  );
}

/// Scripted SFTP session for the download path. [download] (chunk firehose) must
/// never be called by the browser after Slice B; [downloadFile] (task-side
/// stream) is the new path. [blockDownload] parks [downloadFile] after the first
/// progress event so an in-flight cancel can be exercised.
class _DlSftp implements SftpSession {
  _DlSftp({
    required this.entries,
    required this.fileSize,
    this.blockDownload = false,
  });

  final List<SftpEntry> entries;
  final int fileSize;
  final bool blockDownload;
  final Completer<void> release = Completer<void>();

  bool downloadCalled = false;
  bool downloadFileCalled = false;

  @override
  Future<List<SftpEntry>> list(String path) async =>
      path == '/' ? entries : const [];

  @override
  Future<int?> sizeOf(String path) async => fileSize;

  @override
  Future<int> download(
    String path, {
    required void Function(Uint8List chunk, int offset) onChunk,
    int chunkSize = 64 * 1024,
  }) async {
    downloadCalled = true;
    onChunk(Uint8List.fromList(List<int>.filled(fileSize, 1)), 0);
    return fileSize;
  }

  @override
  Future<int> downloadFile(
    String remotePath,
    String localPath, {
    required void Function(int done, int total) onProgress,
    int chunkSize = 64 * 1024,
  }) async {
    downloadFileCalled = true;
    onProgress(0, fileSize);
    if (blockDownload) await release.future;
    onProgress(fileSize, fileSize);
    return fileSize;
  }

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

/// Fake task-side destination: no filesystem, no platform channel.
class _FakeTarget implements FileDownloadTarget {
  _FakeTarget(this.localPath);

  @override
  final String localPath;

  bool published = false;
  bool aborted = false;

  @override
  Future<String> publish() async {
    published = true;
    return '/test/Download/${localPath.split('/').last}';
  }

  @override
  Future<void> abort() async {
    aborted = true;
  }
}

Future<void> _pump(WidgetTester tester, {int count = 12}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

/// Wires a browser over a real proxy → task-side host with [fake], overriding
/// the download target factory with [target]. Returns the session entry.
Future<SessionEntry> _mountBrowser(
  WidgetTester tester, {
  required InMemoryGatewayPair pair,
  required _DlSftp fake,
  required _FakeTarget target,
  required void Function(SessionHost) captureHost,
}) async {
  final host = SessionHost(
    gateway: pair.taskSide,
    controllerFactory: _stubControllerFactory,
    sftpOpener: (_) async => fake,
    snapshotInterval: const Duration(hours: 1),
  );
  captureHost(host);

  final container = ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      downloadTargetFactoryProvider.overrideWithValue((name) async => target),
    ],
  );
  addTearDown(container.dispose);

  const params = SshConnectParams(
    host: 'h',
    port: 22,
    username: 'u',
    auth: SshAuth.password('p'),
  );
  final entry = container.read(sessionsProvider.notifier).addOrActivate(params);
  entry.proxy.connect(params);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: FileBrowserScreen(sessionId: entry.id)),
    ),
  );
  await _pump(tester);
  return entry;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'download uses the task-side path — progress events, NEVER chunk events',
    (tester) async {
      final pair = InMemoryGatewayPair();
      addTearDown(pair.dispose);

      final fake = _DlSftp(
        entries: const [
          SftpEntry(
            name: 'a.bin',
            path: '/a.bin',
            isDirectory: false,
            size: 12,
          ),
        ],
        fileSize: 12,
      );
      final target = _FakeTarget('/tmp/mobissh_test/a.bin');
      late SessionHost host;
      final entry = await _mountBrowser(
        tester,
        pair: pair,
        fake: fake,
        target: target,
        captureHost: (h) => host = h,
      );

      // Spy on the SFTP event stream (broadcast) alongside the browser.
      final events = <SshTaskEvent>[];
      final spy = entry.proxy.sftpEvents.listen(events.add);
      addTearDown(spy.cancel);

      await tester.tap(find.byKey(const Key('file-entry-a.bin')));
      await _pump(tester);

      // The structural root-cause fix: the download rode the streaming path.
      expect(fake.downloadFileCalled, isTrue);
      expect(fake.downloadCalled, isFalse,
          reason: 'the chunk firehose must not be used for a download');
      expect(events.whereType<SftpDownloadChunkEvent>(), isEmpty,
          reason: 'no file bytes may cross the isolate');
      expect(events.whereType<SftpDownloadProgressEvent>(), isNotEmpty);
      expect(events.whereType<SftpDownloadDoneEvent>(), isNotEmpty);
      expect(target.published, isTrue);
      expect(find.textContaining('Downloaded a.bin'), findsOneWidget);

      host.disposeSyncForTest();
    },
  );

  testWidgets('a file at/above the threshold prompts a confirm; cancel aborts',
      (tester) async {
    final pair = InMemoryGatewayPair();
    addTearDown(pair.dispose);

    final bigSize = kLargeDownloadThresholdBytes + 1;
    final fake = _DlSftp(
      entries: [
        SftpEntry(
          name: 'big.bin',
          path: '/big.bin',
          isDirectory: false,
          size: bigSize,
        ),
      ],
      fileSize: bigSize,
    );
    final target = _FakeTarget('/tmp/mobissh_test/big.bin');
    late SessionHost host;
    await _mountBrowser(
      tester,
      pair: pair,
      fake: fake,
      target: target,
      captureHost: (h) => host = h,
    );

    await tester.tap(find.byKey(const Key('file-entry-big.bin')));
    await _pump(tester);

    // Confirm dialog gates the large transfer.
    expect(find.byKey(const Key('large-download-confirm')), findsOneWidget);

    // Cancelling the gate starts nothing.
    await tester.tap(find.byKey(const Key('large-download-cancel')));
    await _pump(tester);
    expect(find.byKey(const Key('large-download-confirm')), findsNothing);
    expect(fake.downloadFileCalled, isFalse);
    expect(
      find.byKey(const Key('file-browser-download-progress')),
      findsNothing,
    );

    host.disposeSyncForTest();
  });

  testWidgets('a small file downloads with no confirm dialog', (tester) async {
    final pair = InMemoryGatewayPair();
    addTearDown(pair.dispose);

    final fake = _DlSftp(
      entries: const [
        SftpEntry(name: 's.bin', path: '/s.bin', isDirectory: false, size: 12),
      ],
      fileSize: 12,
    );
    final target = _FakeTarget('/tmp/mobissh_test/s.bin');
    late SessionHost host;
    await _mountBrowser(
      tester,
      pair: pair,
      fake: fake,
      target: target,
      captureHost: (h) => host = h,
    );

    await tester.tap(find.byKey(const Key('file-entry-s.bin')));
    await _pump(tester);

    expect(find.byKey(const Key('large-download-confirm')), findsNothing);
    expect(fake.downloadFileCalled, isTrue);
    expect(target.published, isTrue);

    host.disposeSyncForTest();
  });

  testWidgets('cancel aborts an in-flight transfer', (tester) async {
    final pair = InMemoryGatewayPair();
    addTearDown(pair.dispose);

    final fake = _DlSftp(
      entries: const [
        SftpEntry(name: 's.bin', path: '/s.bin', isDirectory: false, size: 12),
      ],
      fileSize: 12,
      blockDownload: true,
    );
    addTearDown(() {
      if (!fake.release.isCompleted) fake.release.complete();
    });
    final target = _FakeTarget('/tmp/mobissh_test/s.bin');
    late SessionHost host;
    await _mountBrowser(
      tester,
      pair: pair,
      fake: fake,
      target: target,
      captureHost: (h) => host = h,
    );

    await tester.tap(find.byKey(const Key('file-entry-s.bin')));
    await _pump(tester);
    // The transfer is parked mid-stream; the progress bar (with cancel) shows.
    expect(
      find.byKey(const Key('file-browser-download-progress')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('file-browser-download-cancel')));
    await _pump(tester);

    expect(target.aborted, isTrue);
    expect(
      find.byKey(const Key('file-browser-download-progress')),
      findsNothing,
    );
    expect(find.textContaining('cancelled'), findsOneWidget);

    // Release the parked transfer so it finishes within the test; the terminal
    // done event no longer matches the (cleared) request id and is ignored.
    fake.release.complete();
    await _pump(tester);

    host.disposeSyncForTest();
  });

  group('DownloadProgressThrottle', () {
    test('first event and terminal 100% always emit', () {
      final t = DownloadProgressThrottle();
      expect(t.shouldEmit(0, 1000, Duration.zero), isTrue);
      // Well within the interval + fraction (1 byte of 1000) → suppressed.
      expect(
        t.shouldEmit(1, 1000, const Duration(milliseconds: 5)),
        isFalse,
      );
      // Terminal always emits regardless of interval/fraction.
      expect(
        t.shouldEmit(1000, 1000, const Duration(milliseconds: 6)),
        isTrue,
      );
    });

    test('emits by time OR by fraction, otherwise suppresses', () {
      final t = DownloadProgressThrottle(
        minInterval: const Duration(milliseconds: 100),
        minFraction: 0.1,
      );
      expect(t.shouldEmit(0, 1000, Duration.zero), isTrue);
      // +5ms, +1% → below both thresholds → suppressed.
      expect(
        t.shouldEmit(10, 1000, const Duration(milliseconds: 5)),
        isFalse,
      );
      // +120ms → time threshold crossed → emit.
      expect(
        t.shouldEmit(20, 1000, const Duration(milliseconds: 120)),
        isTrue,
      );
      // +5ms but +15% since last emit → fraction threshold crossed → emit.
      expect(
        t.shouldEmit(170, 1000, const Duration(milliseconds: 125)),
        isTrue,
      );
    });

    test('a burst of tiny updates collapses to few emits', () {
      final t = DownloadProgressThrottle(
        minInterval: const Duration(milliseconds: 100),
        minFraction: 0.5,
      );
      var emits = 0;
      // 100 updates, 1ms apart, 1 byte each of a 1000-byte file: no interval and
      // no fraction threshold crossed → only the first emits (terminal not hit).
      for (var i = 0; i < 100; i++) {
        if (t.shouldEmit(i, 1000, Duration(milliseconds: i))) emits++;
      }
      expect(emits, lessThan(5));
    });
  });
}
