// On-emulator SFTP BYTES IN / BYTES OUT round-trip (#1225).
//
// Setup (run FIRST): scripts/sftp-bytes-1225-setup.sh
//
// #1225 (owner data loss): downloads over 32 KiB silently truncated with a
// success snackbar — 94,915 bytes arrived as 62,147, bytes 32,768..65,535
// missing. Every headless test passed because the fakes return full chunks;
// only a REAL sshd replies short. This test runs against the real test-sshd
// through the real app, task isolate and IPC, and compares every transfer
// byte-for-byte against content the test knows INDEPENDENTLY — the setup
// script and this file compute the same formulas; nothing is verified by
// comparing one download with another through the same reader.
//
//   bin/bin_<n>.bin  byte i = (i * 31 + i ~/ 251) & 0xff
//   md/doc.md        "# bytes 1225\n\n" + 1650 lines of
//                    "line %05d ascii café ✓ 日本語 🎉 the quick brown fox\n"
//
// Phases:
//   A. streaming download to disk (#976, the file browser Download path:
//      `sftpDownloadFile`) of every size → local file == formula.
//   B. chunk path (`sftpDownload`, the viewer/editor fetch) reassembled BY
//      OFFSET → == formula.
//   C. upload whole-file (`sftpUpload`) and chunked/resumable (`sftpUploadFile`,
//      the browser Upload path) → server listing size == n AND a phase-A
//      download == formula (A is proven against independent bytes first).
//   D. editor through the UI: open md/doc.md in the markdown viewer, assert the
//      editor loaded the FULL document, append a line through the field, Save
//      → server bytes == original + line.
//   E. create file (#1222) → upload known bytes into it → verify as C.
//   F. resumable upload over a seeded interrupted `.part` WITH A HOLE (a lost
//      16 KiB concurrent write) → final file == formula, `.part` gone.
//
// Data mismatches are COLLECTED and asserted once at the end so a single run
// reports every size and phase; transport failures (never settled / error
// events) stay hard failures — those are harness, not #1225.
//
// Network: scripts/native-connect-test.sh sets up
//   emulator 127.0.0.1:2222 → (adb reverse → socat) → test-sshd:22

@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
import 'package:mobissh/ui/file_browser_screen.dart';
import 'package:mobissh/ui/markdown_file_viewer.dart';

import 'support/connect_helpers.dart';

const _slice = Duration(milliseconds: 500);
const _root = '/home/testuser/bytes_1225';
const _sizes = [1, 32767, 32768, 32769, 65535, 65536, 65537, 94915, 1048589];
const _uploadSizes = [32769, 94915, 1048589];

/// The fixture formula, shared with scripts/sftp-bytes-1225-setup.sh.
Uint8List _formula(int n) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = (i * 31 + i ~/ 251) & 0xff;
  }
  return out;
}

/// The fixture markdown, shared with scripts/sftp-bytes-1225-setup.sh.
String _docText() {
  final b = StringBuffer('# bytes 1225\n\n');
  for (var k = 0; k < 1650; k++) {
    b.write(
      'line ${k.toString().padLeft(5, '0')} ascii café ✓ 日本語 🎉 '
      'the quick brown fox\n',
    );
  }
  return b.toString();
}

/// Null when identical; otherwise a line naming the sizes and the first
/// mismatching offset.
String? _diff(String label, List<int> got, List<int> want) {
  final n = got.length < want.length ? got.length : want.length;
  for (var i = 0; i < n; i++) {
    if (got[i] != want[i]) {
      return '$label: first mismatch at offset $i (got ${got[i]}, want '
          '${want[i]}); got ${got.length} bytes, want ${want.length}';
    }
  }
  if (got.length != want.length) {
    return '$label: length ${got.length}, want ${want.length} (identical '
        'through offset ${n - 1}; first mismatch at offset $n)';
  }
  return null;
}

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

/// Wait for one request's terminal event; fail hard on an error / no answer.
Future<T> _await<T extends SshTaskEvent>(
  WidgetTester tester,
  SessionEntry entry,
  String requestId,
  void Function() send, {
  void Function(SshTaskEvent e)? onEvent,
  int maxSlices = 240,
}) async {
  T? done;
  SftpErrorEvent? err;
  final sub = entry.proxy.sftpEvents.listen((e) {
    onEvent?.call(e);
    if (e is T && _requestIdOf(e) == requestId) done = e;
    if (e is SftpErrorEvent && e.requestId == requestId) err = e;
  });
  send();
  final settled = await _pumpUntil(
    tester,
    () => done != null || err != null,
    maxSlices: maxSlices,
  );
  await sub.cancel();
  expect(settled, isTrue, reason: '$requestId never settled');
  expect(err, isNull, reason: '$requestId errored: ${err?.message}');
  return done!;
}

String? _requestIdOf(SshTaskEvent e) => switch (e) {
  SftpDownloadDoneEvent() => e.requestId,
  SftpUploadDoneEvent() => e.requestId,
  SftpListingEvent() => e.requestId,
  SftpCreateFileDoneEvent() => e.requestId,
  _ => null,
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'SFTP bytes in == bytes out: download, upload, edit, create (#1225)',
    timeout: const Timeout(Duration(minutes: 20)),
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
      expect(
        await _pumpUntil(
          tester,
          () => find
              .byKey(const Key('session-menu-button'))
              .evaluate()
              .isNotEmpty,
        ),
        isTrue,
        reason: 'never reached the terminal screen',
      );
      final entry = container.read(sessionsProvider).active;
      expect(entry, isNotNull, reason: 'no active session after connect');
      expect(entry!.proxy.data.state, SshSessionState.connected);

      final local = await Directory.systemTemp.createTemp('bytes_1225_');
      addTearDown(() async {
        if (await local.exists()) await local.delete(recursive: true);
      });

      final failures = <String>[];
      final passes = <String>[];
      void check(String label, List<int> got, List<int> want) {
        final d = _diff(label, got, want);
        if (d == null) {
          passes.add(label);
          debugPrint('BYTES1225 PASS $label');
        } else {
          failures.add(d);
          debugPrint('BYTES1225 FAIL $d');
        }
      }

      void checkEq(String label, Object? got, Object? want) {
        if (got == want) {
          passes.add(label);
          debugPrint('BYTES1225 PASS $label');
        } else {
          final d = '$label: got $got, want $want';
          failures.add(d);
          debugPrint('BYTES1225 FAIL $d');
        }
      }

      var seq = 0;

      // Streaming download to a local file (the #976 browser Download path).
      Future<Uint8List> downloadToDisk(String remote) async {
        final id = 'it1225#dlf${seq++}';
        final file = File('${local.path}/$id.bin'.replaceAll('#', '_'));
        await _await<SftpDownloadDoneEvent>(
          tester,
          entry,
          id,
          () => entry.proxy.sftpDownloadFile(
            requestId: id,
            remotePath: remote,
            localPath: file.path,
          ),
        );
        return file.readAsBytes();
      }

      // Chunk-event download reassembled BY OFFSET (the viewer/editor fetch).
      Future<Uint8List> downloadChunks(String remote) async {
        final id = 'it1225#dlc${seq++}';
        final byOffset = <int, Uint8List>{};
        await _await<SftpDownloadDoneEvent>(
          tester,
          entry,
          id,
          () => entry.proxy.sftpDownload(requestId: id, path: remote),
          onEvent: (e) {
            if (e is SftpDownloadChunkEvent && e.requestId == id) {
              byOffset[e.offset] = e.bytes;
            }
          },
        );
        final buf = BytesBuilder(copy: false);
        for (final o in byOffset.keys.toList()..sort()) {
          buf.add(byOffset[o]!);
        }
        return buf.takeBytes();
      }

      // Server-reported size from a directory listing (stat via readdir — not
      // the read path under test).
      Future<int?> serverSize(String dir, String name) async {
        final id = 'it1225#ls${seq++}';
        final ev = await _await<SftpListingEvent>(
          tester,
          entry,
          id,
          () => entry.proxy.sftpList(requestId: id, path: dir),
        );
        for (final e in ev.entries) {
          if (e.name == name) return e.size;
        }
        return null;
      }

      // Phase A: streaming download to disk.
      for (final n in _sizes) {
        final got = await downloadToDisk('$_root/bin/bin_$n.bin');
        check('A downloadFile size=$n', got, _formula(n));
      }

      // Phase B: chunk path, reassembled by offset.
      for (final n in _sizes) {
        final got = await downloadChunks('$_root/bin/bin_$n.bin');
        check('B download(chunks) size=$n', got, _formula(n));
      }

      // Phase C: uploads, verified by server size + a phase-A download.
      for (final n in _uploadSizes) {
        final want = _formula(n);

        final wholeName = 'whole_$n.bin';
        final wid = 'it1225#upw${seq++}';
        await _await<SftpUploadDoneEvent>(
          tester,
          entry,
          wid,
          () => entry.proxy.sftpUpload(
            requestId: wid,
            path: '$_root/up/$wholeName',
            bytes: want,
          ),
        );
        checkEq(
          'C upload(whole) size=$n server size',
          await serverSize('$_root/up', wholeName),
          n,
        );
        check(
          'C upload(whole) size=$n readback',
          await downloadToDisk('$_root/up/$wholeName'),
          want,
        );

        final chunkName = 'chunked_$n.bin';
        final src = File('${local.path}/src_$n.bin');
        await src.writeAsBytes(want, flush: true);
        final cid = 'it1225#upc${seq++}';
        await _await<SftpUploadDoneEvent>(
          tester,
          entry,
          cid,
          () => entry.proxy.sftpUploadFile(
            requestId: cid,
            localPath: src.path,
            remotePath: '$_root/up/$chunkName',
          ),
        );
        checkEq(
          'C uploadFile(chunked) size=$n server size',
          await serverSize('$_root/up', chunkName),
          n,
        );
        check(
          'C uploadFile(chunked) size=$n readback',
          await downloadToDisk('$_root/up/$chunkName'),
          want,
        );
      }

      // Phase E: create file (#1222), then upload known bytes into it.
      {
        const name = 'created_1225.md';
        const path = '$_root/up/$name';
        final cid = 'it1225#cf${seq++}';
        await _await<SftpCreateFileDoneEvent>(
          tester,
          entry,
          cid,
          () => entry.proxy.sftpCreateFile(requestId: cid, path: path),
        );
        final want = _formula(94915);
        final uid = 'it1225#upe${seq++}';
        await _await<SftpUploadDoneEvent>(
          tester,
          entry,
          uid,
          () => entry.proxy.sftpUpload(requestId: uid, path: path, bytes: want),
        );
        checkEq(
          'E create+upload size=94915 server size',
          await serverSize('$_root/up', name),
          94915,
        );
        check(
          'E create+upload size=94915 readback',
          await downloadToDisk(path),
          want,
        );
      }

      // Phase F: resume over an interrupted `.part` WITH A HOLE. dartssh2's
      // writeBytes sends each 64 KiB chunk as four concurrent 16 KiB writes, so
      // a cut upload can leave a `.part` whose size spans never-written bytes;
      // resuming from that size publishes the hole. The setup seeded two such
      // leftovers. up_hole2's hole (16,384..32,767) lies in the range the
      // pre-fix reader still returns, so its red is visible even before the
      // download fix; up_hole's (32,768..49,151, the state #1225 names) is
      // hidden by the download truncation until that is fixed.
      for (final (name, holeLo) in [
        ('up_hole.bin', 32768),
        ('up_hole2.bin', 16384),
      ]) {
        const n = 94915;
        final want = _formula(n);
        final src = File('${local.path}/src_hole_$name');
        await src.writeAsBytes(want, flush: true);
        final id = 'it1225#uph${seq++}';
        await _await<SftpUploadDoneEvent>(
          tester,
          entry,
          id,
          () => entry.proxy.sftpUploadFile(
            requestId: id,
            localPath: src.path,
            remotePath: '$_root/$name',
          ),
        );
        checkEq(
          'F resume-over-hole $name size=$n server size',
          await serverSize(_root, name),
          n,
        );
        checkEq(
          'F resume-over-hole $name .part removed',
          await serverSize(_root, '$name.part'),
          null,
        );
        final got = await downloadToDisk('$_root/$name');
        final holeEnd = holeLo + 16384;
        final holeZero = got.length >= holeEnd &&
            got.sublist(holeLo, holeEnd).every((b) => b == 0);
        check(
          'F resume-over-hole $name size=$n readback '
          '(seeded hole $holeLo..${holeEnd - 1} all-zero in result: $holeZero)',
          got,
          want,
        );
      }

      // Phase D: the editor workflow through the UI.
      {
        final original = _docText();
        final originalBytes = utf8.encode(original);
        const appended = 'appended 1225 ✓ 日本語 🎉 end\n';

        final ctx = tester.element(find.byKey(const Key('session-menu-button')));
        unawaited(
          Navigator.of(ctx).push(
            MaterialPageRoute<void>(
              builder: (_) => FileBrowserScreen(
                sessionId: entry.id,
                initialPath: '$_root/md',
              ),
            ),
          ),
        );
        expect(
          await _pumpUntil(
            tester,
            () => find
                .byKey(const Key('file-entry-doc.md'))
                .evaluate()
                .isNotEmpty,
          ),
          isTrue,
          reason: 'md/doc.md not listed in the file browser',
        );
        await tester.tap(find.byKey(const Key('file-entry-doc.md')));
        expect(
          await _pumpUntil(
            tester,
            () =>
                find.byType(MarkdownFileViewerScreen).evaluate().isNotEmpty &&
                find
                    .byKey(const Key('markdown-edit-toggle'))
                    .evaluate()
                    .isNotEmpty,
            maxSlices: 240,
          ),
          isTrue,
          reason: 'markdown viewer never finished loading doc.md',
        );

        await tester.tap(find.byKey(const Key('markdown-edit-toggle')));
        await tester.pump(const Duration(milliseconds: 500));
        final editor = find.byKey(const Key('markdown-viewer-editor'));
        expect(editor, findsOneWidget, reason: 'edit mode never opened');
        final loaded = tester.widget<TextField>(editor).controller!.text;
        check(
          'D editor loaded doc.md size=${originalBytes.length}',
          utf8.encode(loaded),
          originalBytes,
        );

        await tester.enterText(editor, '$loaded$appended');
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(find.byKey(const Key('markdown-viewer-save')));
        final saved = await _pumpUntil(
          tester,
          () =>
              find.byKey(const Key('markdown-viewer-editor')).evaluate().isEmpty ||
              find
                  .byKey(const Key('markdown-viewer-save-error'))
                  .evaluate()
                  .isNotEmpty,
          maxSlices: 240,
        );
        expect(saved, isTrue, reason: 'editor Save never settled');
        expect(
          find.byKey(const Key('markdown-viewer-save-error')),
          findsNothing,
          reason: 'editor Save reported an error',
        );

        final wantSaved = utf8.encode('$original$appended');
        checkEq(
          'D editor save server size',
          await serverSize('$_root/md', 'doc.md'),
          wantSaved.length,
        );
        check(
          'D editor save size=${wantSaved.length} readback',
          await downloadToDisk('$_root/md/doc.md'),
          wantSaved,
        );
      }

      debugPrint('BYTES1225 SUMMARY passed=${passes.length} '
          'failed=${failures.length}');
      expect(
        failures,
        isEmpty,
        reason: 'SFTP bytes differ from the independently known content:\n'
            '${failures.join('\n')}',
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
    },
  );
}
