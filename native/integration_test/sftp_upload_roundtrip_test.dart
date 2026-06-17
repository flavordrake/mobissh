// On-emulator SFTP UPLOAD round-trip (#892).
//
// Proves the WRITE chain end to end against the REAL test-sshd, BEFORE any
// editor UI exists: connect → upload bytes to a temp path through the session
// proxy's `sftpUpload` → download the same path back through `sftpDownload` →
// assert byte-identical. A second case proves a `~`-relative path (#867)
// resolves on write: upload to `~/<file>`, then read it back via an absolute
// `$HOME/<file>` path and confirm the bytes match — so the tilde expansion in
// the SFTP wrapper actually landed the file in the home directory.
//
// This is the writer-seam mirror of sftp_browse_smoke_test.dart's download
// assertion. It drives the proxy directly (no editor widget) because #892 is
// the infra slice; the editor UI (#859) is a later issue that builds on this.
//
// Network: scripts/native-connect-test.sh sets up
//   emulator 127.0.0.1:2222 → (adb reverse → socat) → test-sshd:22
// so the ad-hoc connect tuple reaches the Alpine test sshd.
//
// Orchestrator runs this on a booted emulator via the native integration suite;
// the develop agent only WRITES it (the suite/emulator is busy). Fast gate does
// not run integration-tagged files.

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

/// Pump in 500ms slices until [test] is true or [maxSlices] elapse, accepting a
/// host-key trust prompt ("Trust + connect") whenever it surfaces.
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

Future<bool> _reachTerminal(WidgetTester tester) {
  return _pumpUntil(
    tester,
    () => find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty,
  );
}

/// Assert real LOGIN (not just widget mount): a typed marker echoes back
/// through the proxy round-trip (mirror of the browse smoke's liveness check).
Future<void> _assertShellAlive(
  WidgetTester tester,
  SessionEntry entry, {
  required String marker,
}) async {
  final out = <int>[];
  final sub = entry.proxy.output.listen(out.addAll);
  addTearDown(sub.cancel);
  await tester.pump(const Duration(milliseconds: 200));
  entry.proxy.sendInput(Uint8List.fromList(utf8.encode('echo $marker\n')));
  final sawMarker = await _pumpUntil(
    tester,
    () => utf8.decode(out, allowMalformed: true).contains(marker),
    maxSlices: 40,
  );
  expect(sawMarker, isTrue,
      reason: 'typed command never echoed — dead shell / input dead');
}

/// Upload [bytes] to [path] via the proxy's write chain (#892); pump until the
/// matching [SftpUploadDoneEvent] arrives. Returns the reported byte count.
Future<int> _upload(
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
  addTearDown(sub.cancel);

  entry.proxy.sftpUpload(requestId: requestId, path: path, bytes: bytes);
  final settled = await _pumpUntil(
    tester,
    () => done != null || err != null,
    maxSlices: 40,
  );
  expect(settled, isTrue, reason: 'upload to $path never settled');
  expect(err, isNull, reason: 'upload to $path errored: ${err?.message}');
  return done!.totalBytes;
}

/// Download [path] via the proxy's read chain; pump until the
/// [SftpDownloadDoneEvent] arrives, assembling chunks at their byte offsets
/// (#591). Returns the assembled bytes.
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
  addTearDown(sub.cancel);

  entry.proxy.sftpDownload(requestId: requestId, path: path);
  final settled = await _pumpUntil(
    tester,
    () => done != null || err != null,
    maxSlices: 40,
  );
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

  testWidgets(
    'SFTP upload → download round-trip is byte-identical on test-sshd',
    (tester) async {
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
      expect(await _reachTerminal(tester), isTrue,
          reason: 'never reached the terminal screen');
      final entry = container.read(sessionsProvider).active;
      expect(entry, isNotNull, reason: 'no active session after connect');
      expect(entry!.proxy.data.state, SshSessionState.connected);
      await _assertShellAlive(tester, entry, marker: 'MOBISSH_SHELL_OK_892');

      // 1) ABSOLUTE-PATH round-trip. Include CR/LF + non-ASCII so a lossy
      //    encode/transfer would be caught.
      const absPath = '/tmp/mobissh_itest_892_abs.txt';
      final content = utf8.encode('hello 892 round-trip\r\nsécond line é\n');
      final payload = Uint8List.fromList(content);

      final written = await _upload(
        tester,
        entry,
        requestId: 'itest892#write-abs',
        path: absPath,
        bytes: payload,
      );
      expect(written, payload.length, reason: 'upload wrote the wrong size');

      final readBack = await _download(
        tester,
        entry,
        requestId: 'itest892#read-abs',
        path: absPath,
      );
      expect(readBack, payload,
          reason: 'downloaded bytes differ from uploaded bytes');

      // 2) ~-RELATIVE round-trip (#867): upload to `~/<file>` (must resolve to
      //    the home dir on WRITE), then download via the same `~/<file>` path
      //    and assert the same bytes. If tilde expansion didn't apply on write,
      //    the write would land at a literal `~` dir / fail, and the read would
      //    miss or differ.
      const tildePath = '~/mobissh_itest_892_tilde.txt';
      final tildeBytes =
          Uint8List.fromList(utf8.encode('tilde-resolved 892\n'));

      final tildeWritten = await _upload(
        tester,
        entry,
        requestId: 'itest892#write-tilde',
        path: tildePath,
        bytes: tildeBytes,
      );
      expect(tildeWritten, tildeBytes.length);

      final tildeReadBack = await _download(
        tester,
        entry,
        requestId: 'itest892#read-tilde',
        path: tildePath,
      );
      expect(tildeReadBack, tildeBytes,
          reason: '~-relative upload did not resolve to the home dir');

      // Clean up the session + foreground service so a later test connects
      // clean (mirror of the browse smoke teardown).
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
    },
  );
}
