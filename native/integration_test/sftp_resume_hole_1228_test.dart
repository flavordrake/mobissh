// On-emulator: resumable upload over an interrupted `.part` WITH A HOLE (#1228).
//
// Setup (run FIRST): scripts/sftp-bytes-1225-setup.sh
// Teardown (always): scripts/sftp-bytes-1225-teardown.sh
//
// Split out of sftp_bytes_roundtrip_1225_test.dart (#1225, whose download fix
// made this phase observable): it shares that test's fixture, which seeds two
// interrupted-upload leftovers under /home/testuser/bytes_1225/:
//
//   up_hole.bin.part   65,536 formula bytes with 32,768..49,151 zeroed
//   up_hole2.bin.part  65,536 formula bytes with 16,384..32,767 zeroed
//
// dartssh2's writeBytes sends each 64 KiB chunk as concurrent 16 KiB writes, so
// a cut upload can leave a `.part` whose SIZE spans never-written bytes.
// `uploadFile` resumes from the `.part` size and publishes the hole. The
// result must equal the formula and the `.part` must be gone. Known red until
// #1228 is fixed (BASELINE.manifest).
//
//   byte i = (i * 31 + i ~/ 251) & 0xff  (shared with the setup script)
//
// Network: scripts/native-connect-test.sh sets up
//   emulator 127.0.0.1:2222 → (adb reverse → socat) → test-sshd:22

@Tags(['integration'])
library;

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

import 'support/connect_helpers.dart';

const _slice = Duration(milliseconds: 500);
const _root = '/home/testuser/bytes_1225';

Uint8List _formula(int n) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = (i * 31 + i ~/ 251) & 0xff;
  }
  return out;
}

String? _diff(String label, List<int> got, List<int> want) {
  final n = got.length < want.length ? got.length : want.length;
  for (var i = 0; i < n; i++) {
    if (got[i] != want[i]) {
      return '$label: first mismatch at offset $i (got ${got[i]}, want '
          '${want[i]}); got ${got.length} bytes, want ${want.length}';
    }
  }
  if (got.length != want.length) {
    return '$label: length ${got.length}, want ${want.length}';
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

String? _requestIdOf(SshTaskEvent e) => switch (e) {
  SftpDownloadDoneEvent() => e.requestId,
  SftpUploadDoneEvent() => e.requestId,
  SftpListingEvent() => e.requestId,
  _ => null,
};

Future<T> _await<T extends SshTaskEvent>(
  WidgetTester tester,
  SessionEntry entry,
  String requestId,
  void Function() send,
) async {
  T? done;
  SftpErrorEvent? err;
  final sub = entry.proxy.sftpEvents.listen((e) {
    if (e is T && _requestIdOf(e) == requestId) done = e;
    if (e is SftpErrorEvent && e.requestId == requestId) err = e;
  });
  send();
  final settled =
      await _pumpUntil(tester, () => done != null || err != null, maxSlices: 240);
  await sub.cancel();
  expect(settled, isTrue, reason: '$requestId never settled');
  expect(err, isNull, reason: '$requestId errored: ${err?.message}');
  return done!;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'resumable upload over a .part with a hole publishes the full file (#1228)',
    timeout: const Timeout(Duration(minutes: 10)),
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

      final local = await Directory.systemTemp.createTemp('hole_1228_');
      addTearDown(() async {
        if (await local.exists()) await local.delete(recursive: true);
      });

      var seq = 0;
      final failures = <String>[];
      void record(String label, String? diff) {
        if (diff == null) {
          debugPrint('HOLE1228 PASS $label');
        } else {
          failures.add(diff);
          debugPrint('HOLE1228 FAIL $diff');
        }
      }

      Future<int?> serverSize(String dir, String name) async {
        final id = 'it1228#ls${seq++}';
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

      Future<Uint8List> downloadToDisk(String remote) async {
        final id = 'it1228#dlf${seq++}';
        final file = File('${local.path}/${id.replaceAll('#', '_')}.bin');
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

      for (final (name, holeLo) in [
        ('up_hole.bin', 32768),
        ('up_hole2.bin', 16384),
      ]) {
        const n = 94915;
        final want = _formula(n);
        final src = File('${local.path}/src_hole_$name');
        await src.writeAsBytes(want, flush: true);
        final id = 'it1228#uph${seq++}';
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
        final size = await serverSize(_root, name);
        record('$name server size',
            size == n ? null : '$name server size: got $size, want $n');
        final part = await serverSize(_root, '$name.part');
        record('$name .part removed',
            part == null ? null : '$name .part still present ($part bytes)');
        final got = await downloadToDisk('$_root/$name');
        final holeEnd = holeLo + 16384;
        final holeZero = got.length >= holeEnd &&
            got.sublist(holeLo, holeEnd).every((b) => b == 0);
        record(
          '$name readback',
          _diff(
            '$name readback (seeded hole $holeLo..${holeEnd - 1} all-zero in '
            'result: $holeZero)',
            got,
            want,
          ),
        );
      }

      expect(failures, isEmpty,
          reason: 'resume over a holed .part published wrong bytes:\n'
              '${failures.join('\n')}');

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
