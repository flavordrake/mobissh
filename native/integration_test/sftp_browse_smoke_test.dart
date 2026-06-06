// On-emulator SFTP FILE-BROWSER smoke (explorer Slice 0, #775).
//
// The file browser drives SFTP through the live session proxy (sftpList /
// sftpDownload over the FFT task isolate → the real dartssh2 SftpClient). The
// headless widget tests for file_browser_screen feed a fake gateway and never
// touch a real sshd, so they cannot catch a task-side SFTP regression (the same
// class of "shipped green, broke on device" gap as #539/#546/#547). This test
// runs the REAL app on the emulator against test-sshd and asserts the browser's
// state-machine TRANSITIONS end to end — list, descend, download bytes, ascend,
// and per-session isolation — not one happy-path screen mount.
//
// Network: scripts/native-connect-test.sh sets up
//   emulator 127.0.0.1:2222 → (adb reverse → socat) → test-sshd:22
//   emulator 127.0.0.1:2223 → (adb reverse → socat) → test-sshd:22   (2nd bridge)
// so two distinct host:port:username tuples both reach the Alpine test sshd.
// The 2nd bridge is wired by native-integration-suite.sh's needs_second_bridge.
//
// Seeding: there is no fixture filesystem to pre-stage — the browser reads the
// REAL test-sshd. So we seed a known tree THROUGH the live shell (proxy input),
// confirming completion with a sentinel echo before browsing. This keeps the
// seed in-fixture and reuses the existing bridge, per feedback_reuse_pwa_infra.
//
// Download bytes are asserted by overriding `downloadSinkFactoryProvider` with
// an in-memory capturing sink — proving the file round-trips, not merely that a
// download "fired".

@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/services/sftp_download.dart';
import 'package:mobissh/ssh/ssh_session.dart' show SshSessionState;
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/file_browser_screen.dart';

import 'support/connect_helpers.dart';

const _slice = Duration(milliseconds: 500);

/// An in-memory [FileDownloadSink] that records the assembled bytes so a test
/// can assert the exact content that round-tripped from test-sshd. Honors the
/// offset semantics of the real sinks (#591): chunks may arrive out of order.
class _CapturingSink implements FileDownloadSink {
  final List<int> _buf = <int>[];
  bool finished = false;

  Uint8List get bytes => Uint8List.fromList(_buf);

  @override
  Future<void> addChunk(Uint8List bytes, int offset) async {
    // Grow the buffer to fit and splice the chunk at its byte offset (#591:
    // chunks can arrive out of order, so write at the offset rather than append).
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
    return 'memory://capture';
  }

  @override
  Future<void> abort() async {}
}

/// Per-file capture registry keyed by the requested file NAME, so a test can
/// pull the bytes that were downloaded for a given file.
class _SinkRegistry {
  final Map<String, _CapturingSink> sinks = <String, _CapturingSink>{};

  Future<FileDownloadSink> factory(String fileName) async {
    final sink = _CapturingSink();
    sinks[fileName] = sink;
    return sink;
  }
}

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

/// Reach the terminal screen for a freshly-submitted connect, accepting the
/// host-key prompt. Returns once the session-menu AppBar button is present.
Future<bool> _reachTerminal(WidgetTester tester) {
  return _pumpUntil(
    tester,
    () => find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty,
  );
}

/// Assert real LOGIN (not just widget mount): the shell streams a prompt and a
/// typed marker echoes back through the proxy round-trip. Mirrors
/// shell_bytes_smoke_test — a mounted terminal with a dead PTY is NOT connected.
Future<void> _assertShellAlive(
  WidgetTester tester,
  SessionEntry entry, {
  required String marker,
}) async {
  final out = <int>[];
  final sub = entry.proxy.output.listen(out.addAll);
  addTearDown(sub.cancel);

  final gotPrompt = await _pumpUntil(tester, () => out.isNotEmpty, maxSlices: 40);
  expect(
    gotPrompt,
    isTrue,
    reason: 'terminal received ZERO bytes after connect — dead shell',
  );

  entry.proxy.sendInput(Uint8List.fromList(utf8.encode('echo $marker\n')));
  final sawMarker = await _pumpUntil(
    tester,
    () => utf8.decode(out, allowMalformed: true).contains(marker),
    maxSlices: 40,
  );
  expect(sawMarker, isTrue, reason: 'typed command never echoed — input dead');
}

/// Seed a directory tree on test-sshd THROUGH the live shell, then wait for a
/// sentinel echo confirming the seed completed. [root] is an absolute path under
/// /tmp; [content] is written into `root/<fileName>`; a subdir `sub/` is created
/// with a marker file so descend/ascend can be exercised.
Future<void> _seedTree(
  WidgetTester tester,
  SessionEntry entry, {
  required String root,
  required String fileName,
  required String content,
  required String subMarkerName,
}) async {
  final out = <int>[];
  final sub = entry.proxy.output.listen(out.addAll);
  addTearDown(sub.cancel);

  const done = 'MOBISSH_SEED_DONE_775';
  final b64 = base64Encode(utf8.encode(content));
  // One compound command: rm stale tree, mkdir root + sub, write the file via a
  // base64 decode (avoids quoting/newline hazards), drop the sub marker, echo
  // the sentinel. `set -e`-free so a benign rm miss doesn't abort.
  final script = StringBuffer()
    ..write('rm -rf $root; ')
    ..write('mkdir -p $root/sub; ')
    ..write("printf '%s' '$b64' | base64 -d > $root/$fileName; ")
    ..write('echo seedmarker > $root/sub/$subMarkerName; ')
    ..write('echo $done\n');
  entry.proxy.sendInput(Uint8List.fromList(utf8.encode(script.toString())));

  final seeded = await _pumpUntil(
    tester,
    () => utf8.decode(out, allowMalformed: true).contains(done),
    maxSlices: 40,
  );
  expect(seeded, isTrue, reason: 'seed never completed on test-sshd ($root)');
}

/// Navigate the OPEN file browser to [path] via the up/into controls is awkward
/// from an arbitrary cwd; instead we open a fresh browser already pointed at the
/// seeded path. Pumps until its listing renders.
Future<void> _openBrowserAt(
  WidgetTester tester,
  BuildContext context,
  String sessionId,
  String path,
) async {
  unawaited(
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FileBrowserScreen(
          key: const Key('itest-file-browser'),
          sessionId: sessionId,
          initialPath: path,
        ),
      ),
    ),
  );
  await _pumpUntil(
    tester,
    () => find.byKey(const Key('file-browser-list')).evaluate().isNotEmpty,
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'SFTP browser: list → descend → download bytes → ascend on test-sshd',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      final registry = _SinkRegistry();
      final container = ProviderContainer(
        overrides: [
          downloadSinkFactoryProvider.overrideWithValue(registry.factory),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MobisshApp(),
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      // 1) Connect + real login (shell bytes, not widget mount).
      await adhocPasswordConnect(
        tester,
        host: '127.0.0.1',
        port: '2222',
        user: 'testuser',
        pass: 'testpass',
      );
      expect(
        await _reachTerminal(tester),
        isTrue,
        reason: 'never reached the terminal screen',
      );
      final entry = container.read(sessionsProvider).active;
      expect(entry, isNotNull, reason: 'no active session after connect');
      await _assertShellAlive(tester, entry!, marker: 'MOBISSH_SHELL_OK_775');

      // Seed a known tree through the shell.
      const root = '/tmp/mobissh_itest_775';
      const fileName = 'hello.txt';
      const content = 'hello from test-sshd 775\nsecond line\n';
      await _seedTree(
        tester,
        entry,
        root: root,
        fileName: fileName,
        content: content,
        subMarkerName: 'inside.txt',
      );

      // 2) Open the browser at the seeded dir (entry point: FileBrowserScreen,
      //    same widget openFileBrowser pushes). 3) listing renders real entries.
      final ctx = tester.element(find.byKey(const Key('session-menu-button')));
      await _openBrowserAt(tester, ctx, entry.id, root);
      expect(
        find.byKey(const Key('file-entry-$fileName')),
        findsOneWidget,
        reason: 'seeded file not listed — listing did not render real entries',
      );
      expect(
        find.byKey(const Key('file-entry-sub')),
        findsOneWidget,
        reason: 'seeded subdir not listed',
      );

      // 4) Tap into the subdir → listing updates to show the sub marker.
      await tester.tap(find.byKey(const Key('file-entry-sub')));
      final descended = await _pumpUntil(
        tester,
        () =>
            find.byKey(const Key('file-entry-inside.txt')).evaluate().isNotEmpty,
      );
      expect(descended, isTrue, reason: 'descend into subdir did not update');

      // 6) Ascend (up) → back to the parent listing (hello.txt visible again).
      await tester.tap(find.byKey(const Key('file-browser-up')));
      final ascended = await _pumpUntil(
        tester,
        () =>
            find.byKey(const Key('file-entry-$fileName')).evaluate().isNotEmpty,
      );
      expect(ascended, isTrue, reason: 'ascend did not return to parent');

      // 5) Tap the small text file → download fires → captured bytes == seed.
      await tester.tap(find.byKey(const Key('file-entry-$fileName')));
      final downloaded = await _pumpUntil(
        tester,
        () => registry.sinks[fileName]?.finished == true,
      );
      expect(downloaded, isTrue, reason: 'file download never completed');
      final got = registry.sinks[fileName]!.bytes;
      expect(
        utf8.decode(got, allowMalformed: true),
        content,
        reason: 'downloaded bytes do not match the seeded file content',
      );
    },
  );

  testWidgets(
    'SFTP browser: per-session isolation — each session shows its own cwd',
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

      // Session A on port 2222.
      await adhocPasswordConnect(
        tester,
        host: '127.0.0.1',
        port: '2222',
        user: 'testuser',
        pass: 'testpass',
      );
      expect(await _reachTerminal(tester), isTrue, reason: 'session A no term');

      // Session B on port 2223 (2nd bridge → same test-sshd, distinct tuple).
      await tester.tap(find.byKey(const Key('session-menu-button')));
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(find.byKey(const Key('session-menu-new')));
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await adhocPasswordConnect(
        tester,
        host: '127.0.0.1',
        port: '2223',
        user: 'testuser',
        pass: 'testpass',
      );

      final bothConnected = await _pumpUntil(tester, () {
        final entries = container.read(sessionsProvider).entries;
        return entries.length == 2 &&
            entries.every(
              (e) => e.proxy.data.state == SshSessionState.connected,
            );
      });
      expect(bothConnected, isTrue, reason: 'two sessions did not establish');

      final entries = container.read(sessionsProvider).entries;
      expect(entries.length, 2);
      final a = entries.firstWhere((e) => e.port == 2222);
      final b = entries.firstWhere((e) => e.port == 2223);

      // Seed a DISTINCT tree per session, each with a uniquely-named marker file
      // so a cross-leak (browser A showing B's file or vice versa) is detectable.
      await _assertShellAlive(tester, a, marker: 'MOBISSH_A_OK_775');
      await _assertShellAlive(tester, b, marker: 'MOBISSH_B_OK_775');
      const rootA = '/tmp/mobissh_itest_775_a';
      const rootB = '/tmp/mobissh_itest_775_b';
      await _seedTree(
        tester,
        a,
        root: rootA,
        fileName: 'only_in_a.txt',
        content: 'A\n',
        subMarkerName: 'a_sub.txt',
      );
      await _seedTree(
        tester,
        b,
        root: rootB,
        fileName: 'only_in_b.txt',
        content: 'B\n',
        subMarkerName: 'b_sub.txt',
      );

      // Browser for A shows A's file and NOT B's.
      final ctx = tester.element(find.byKey(const Key('session-menu-button')));
      await _openBrowserAt(tester, ctx, a.id, rootA);
      expect(
        find.byKey(const Key('file-entry-only_in_a.txt')),
        findsOneWidget,
        reason: 'browser A missing A-only file',
      );
      expect(
        find.byKey(const Key('file-entry-only_in_b.txt')),
        findsNothing,
        reason: 'LEAK: browser A shows B-only file',
      );
      // Pop browser A.
      Navigator.of(ctx).pop();
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('file-browser-list')).evaluate().isEmpty,
      );

      // Browser for B shows B's file and NOT A's.
      final ctx2 = tester.element(find.byKey(const Key('session-menu-button')));
      await _openBrowserAt(tester, ctx2, b.id, rootB);
      expect(
        find.byKey(const Key('file-entry-only_in_b.txt')),
        findsOneWidget,
        reason: 'browser B missing B-only file',
      );
      expect(
        find.byKey(const Key('file-entry-only_in_a.txt')),
        findsNothing,
        reason: 'LEAK: browser B shows A-only file',
      );
    },
  );
}
