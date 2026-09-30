// On-emulator SFTP CREATE FILE, never overwrite (#1222).
//
// Proves against the REAL test-sshd (OpenSSH sftp-server) that the exclusive
// open behind `sftpCreateFile` does what the headless fakes assume:
//   1) a new name creates an EMPTY file (read back: zero bytes);
//   2) creating that same name again is REFUSED as "Already exists" — OpenSSH
//      reports EEXIST as a generic FAILURE, so this pins the stat-to-name-it
//      mapping in DartSshSftpSession.createFile;
//   3) creating over a file WITH content is refused and its bytes are
//      byte-identical afterwards (the no-overwrite guarantee).
//
// Drives the session proxy directly (like sftp_upload_roundtrip_test.dart) —
// the dialog/menu wiring is covered headless in
// test/widget/file_browser_new_file_test.dart. No fixture scripts: every path
// is unique per run under /tmp in the throwaway test-sshd container, so there
// is nothing to clean up.
//
// Network: scripts/native-connect-test.sh sets up
//   emulator 127.0.0.1:2222 → (adb reverse → socat) → test-sshd:22

@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/ssh/ssh_session.dart' show SshSessionState;
import 'package:mobissh/state/sessions.dart';

import 'support/connect_helpers.dart';

const _slice = Duration(milliseconds: 500);

Future<bool> _pumpUntil(
  WidgetTester tester,
  bool Function() test, {
  int maxSlices = 80,
}) async {
  for (var i = 0; i < maxSlices; i++) {
    await tester.pump(_slice);
    final trust = find.text('Trust + connect');
    if (trust.evaluate().isNotEmpty) {
      await tester.tap(trust.first);
      await tester.pump(const Duration(milliseconds: 300));
    }
    if (test()) return true;
  }
  return false;
}

/// Make the per-run scratch dir over SFTP. The first cut typed `mkdir` into the
/// shell and waited for an echoed marker; on the leased emulator the marker
/// never came back (the SFTP channel was fine), so that red was about the shell
/// round-trip, not #1222. SFTP-only keeps this test about SFTP.
Future<void> _mkdir(
  WidgetTester tester,
  SessionEntry entry, {
  required String requestId,
  required String path,
}) async {
  SftpMkdirDoneEvent? done;
  SftpErrorEvent? err;
  final sub = entry.proxy.sftpEvents.listen((e) {
    if (e is SftpMkdirDoneEvent && e.requestId == requestId) done = e;
    if (e is SftpErrorEvent && e.requestId == requestId) err = e;
  });
  entry.proxy.sftpMkdir(requestId: requestId, path: path);
  final settled = await _pumpUntil(
    tester,
    () => done != null || err != null,
    maxSlices: 40,
  );
  await sub.cancel();
  expect(settled, isTrue, reason: 'mkdir of $path never settled');
  expect(err, isNull, reason: 'mkdir of $path errored: ${err?.message}');
}

/// Create [path] via the proxy; returns the error message, or null on success.
Future<String?> _create(
  WidgetTester tester,
  SessionEntry entry, {
  required String requestId,
  required String path,
}) async {
  SftpCreateFileDoneEvent? done;
  SftpErrorEvent? err;
  final sub = entry.proxy.sftpEvents.listen((e) {
    if (e is SftpCreateFileDoneEvent && e.requestId == requestId) done = e;
    if (e is SftpErrorEvent && e.requestId == requestId) err = e;
  });
  entry.proxy.sftpCreateFile(requestId: requestId, path: path);
  final settled = await _pumpUntil(
    tester,
    () => done != null || err != null,
    maxSlices: 40,
  );
  await sub.cancel();
  expect(settled, isTrue, reason: 'create of $path never settled');
  return err?.message;
}

Future<void> _upload(
  WidgetTester tester,
  SessionEntry entry, {
  required String requestId,
  required String path,
  required Uint8List bytes,
}) async {
  SftpUploadDoneEvent? done;
  SftpErrorEvent? err;
  final sub = entry.proxy.sftpEvents.listen((e) {
    if (e is SftpUploadDoneEvent && e.requestId == requestId) done = e;
    if (e is SftpErrorEvent && e.requestId == requestId) err = e;
  });
  entry.proxy.sftpUpload(requestId: requestId, path: path, bytes: bytes);
  final settled = await _pumpUntil(
    tester,
    () => done != null || err != null,
    maxSlices: 40,
  );
  await sub.cancel();
  expect(settled, isTrue, reason: 'seed upload to $path never settled');
  expect(err, isNull, reason: 'seed upload errored: ${err?.message}');
}

Future<Uint8List> _download(
  WidgetTester tester,
  SessionEntry entry, {
  required String requestId,
  required String path,
}) async {
  final byOffset = <int, Uint8List>{};
  SftpDownloadDoneEvent? done;
  SftpErrorEvent? err;
  final sub = entry.proxy.sftpEvents.listen((e) {
    if (e is SftpDownloadChunkEvent && e.requestId == requestId) {
      byOffset[e.offset] = e.bytes;
    }
    if (e is SftpDownloadDoneEvent && e.requestId == requestId) done = e;
    if (e is SftpErrorEvent && e.requestId == requestId) err = e;
  });
  entry.proxy.sftpDownload(requestId: requestId, path: path);
  final settled = await _pumpUntil(
    tester,
    () => done != null || err != null,
    maxSlices: 40,
  );
  await sub.cancel();
  expect(settled, isTrue, reason: 'download of $path never settled');
  expect(err, isNull, reason: 'download of $path errored: ${err?.message}');
  final buf = BytesBuilder(copy: false);
  for (final offset in byOffset.keys.toList()..sort()) {
    buf.add(byOffset[offset]!);
  }
  return buf.takeBytes();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('SFTP create file: empty on create, never overwrites (#1222)', (
    tester,
  ) async {
    FlutterForegroundTask.initCommunicationPort();
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MobisshApp(),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    await adhocPasswordConnect(
      tester,
      host: '127.0.0.1',
      port: '2222',
      user: 'testuser',
      pass: 'testpass',
    );
    expect(
      await _pumpUntil(
        tester,
        () =>
            find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty,
      ),
      isTrue,
      reason: 'never reached the terminal screen',
    );
    final entry = container.read(sessionsProvider).active;
    expect(entry, isNotNull, reason: 'no active session after connect');
    expect(entry!.proxy.data.state, SshSessionState.connected);

    final run = DateTime.now().millisecondsSinceEpoch;
    final dir = '/tmp/mobissh_itest_1222_$run';
    await _mkdir(tester, entry, requestId: 'it1222#m1', path: dir);

    // 1) New name → an EMPTY file.
    final fresh = '$dir/README.md';
    expect(
      await _create(tester, entry, requestId: 'it1222#c1', path: fresh),
      isNull,
      reason: 'creating a new name must succeed',
    );
    expect(
      await _download(tester, entry, requestId: 'it1222#d1', path: fresh),
      isEmpty,
      reason: 'a new file is created EMPTY',
    );

    // 2) Same name again → refused, named as "Already exists".
    final again = await _create(
      tester,
      entry,
      requestId: 'it1222#c2',
      path: fresh,
    );
    expect(again, isNotNull, reason: 'an existing name must be refused');
    expect(again, contains('Already exists'));

    // 3) Over a file WITH content → refused, bytes untouched.
    final kept = '$dir/kept.md';
    final original = Uint8List.fromList(utf8.encode('# keep me 1222\n'));
    await _upload(
      tester,
      entry,
      requestId: 'it1222#u1',
      path: kept,
      bytes: original,
    );
    final over = await _create(
      tester,
      entry,
      requestId: 'it1222#c3',
      path: kept,
    );
    expect(over, contains('Already exists'));
    expect(
      await _download(tester, entry, requestId: 'it1222#d3', path: kept),
      original,
      reason: 'the existing file must never be overwritten',
    );

    final notifier = container.read(sessionsProvider.notifier);
    for (final id in container
        .read(sessionsProvider)
        .entries
        .map((e) => e.id)
        .toList(growable: false)) {
      notifier.close(id);
    }
    await _pumpUntil(
      tester,
      () => container.read(sessionsProvider).entries.isEmpty,
      maxSlices: 20,
    );
  });
}
