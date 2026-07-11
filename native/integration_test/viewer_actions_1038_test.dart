// On-emulator smoke for the viewer Download + Share actions (#1038).
//
// The headless widget tests spy the action service; this test drives the REAL
// app against test-sshd and asserts the production pipeline end to end:
//   - open a seeded text file → the TEXT VIEWER (registry route) shows both
//     app-bar actions,
//   - hold a screenshot window (orchestrator runs `scripts/emu-shot.sh
//     viewer-actions-1038` during the hold) so the app bar is reviewable,
//   - tap Download → the bytes round-trip into the download sink (the same
//     capturing-sink override pattern as sftp_browse_smoke_test.dart — the
//     MediaStore publish itself is device-owner validated),
//   - tap Share → the staged temp FILE exists with the seeded content and the
//     correct mime when the launcher fires (the launcher provider is the ONLY
//     stubbed hop: the system share sheet can't be dismissed from
//     integration_test, so the real sheet is device-owner validated).
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
// Run: scripts/native-connect-test.sh integration_test/viewer_actions_1038_test.dart

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
import 'package:mobissh/services/sftp_download.dart';
import 'package:mobissh/services/viewer_file_actions.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/file_browser_screen.dart';
import 'package:mobissh/ui/text_file_viewer.dart';

import 'support/connect_helpers.dart';

const _slice = Duration(milliseconds: 500);

/// In-memory offset-honoring sink (same contract as sftp_browse_smoke_test).
class _CapturingSink implements FileDownloadSink {
  final List<int> _buf = <int>[];
  bool finished = false;

  Uint8List get bytes => Uint8List.fromList(_buf);

  @override
  Future<void> addChunk(Uint8List bytes, int offset) async {
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

class _SinkRegistry {
  final Map<String, _CapturingSink> sinks = <String, _CapturingSink>{};

  Future<FileDownloadSink> factory(String fileName) async {
    final sink = _CapturingSink();
    sinks[fileName] = sink;
    return sink;
  }
}

/// Records the share launcher invocation + a snapshot of the staged file's
/// content AT LAUNCH TIME (the contract: the FILE exists when shared).
class _ShareRecorder {
  String? path;
  String? mime;
  String? name;
  String? contentAtLaunch;

  Future<void> launch(String p, String m, String n) async {
    path = p;
    mime = m;
    name = n;
    contentAtLaunch = await File(p).readAsString();
  }
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

/// Seed `root/<fileName>` with [content] through the live shell; confirm via
/// sentinel echo (same in-fixture pattern as sftp_browse_smoke_test).
Future<void> _seedFile(
  WidgetTester tester,
  SessionEntry entry, {
  required String root,
  required String fileName,
  required String content,
}) async {
  final out = <int>[];
  final sub = entry.proxy.output.listen(out.addAll);
  addTearDown(sub.cancel);

  const done = 'MOBISSH_SEED_DONE_1038';
  final b64 = base64Encode(utf8.encode(content));
  final script = StringBuffer()
    ..write('rm -rf $root; ')
    ..write('mkdir -p $root; ')
    ..write("printf '%s' '$b64' | base64 -d > $root/$fileName; ")
    ..write('echo $done\n');

  // Input sent before the PTY's shellReady is silently dropped (observed on
  // the first run of this test: `send input` landed 2 events before
  // `shellReady`). The seed script is idempotent (rm/mkdir/printf), so RETRY
  // it until the sentinel echoes instead of racing the shell.
  var seeded = false;
  for (var attempt = 0; attempt < 4 && !seeded; attempt++) {
    entry.proxy.sendInput(Uint8List.fromList(utf8.encode(script.toString())));
    seeded = await _pumpUntil(
      tester,
      () => utf8.decode(out, allowMalformed: true).contains(done),
      maxSlices: 20,
    );
  }
  expect(seeded, isTrue, reason: 'seed never completed on test-sshd ($root)');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'viewer Download + Share act on the open preview (#1038)',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      final registry = _SinkRegistry();
      final share = _ShareRecorder();
      final container = ProviderContainer(
        overrides: [
          downloadSinkFactoryProvider.overrideWithValue(registry.factory),
          viewerShareLauncherProvider.overrideWithValue(share.launch),
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

      // Connect + reach the terminal.
      await adhocPasswordConnect(
        tester,
        host: '127.0.0.1',
        port: '2222',
        user: 'testuser',
        pass: 'testpass',
      );
      final connected = await _pumpUntil(
        tester,
        () =>
            find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty,
      );
      expect(connected, isTrue, reason: 'never reached the terminal screen');
      final entry = container.read(sessionsProvider).active;
      expect(entry, isNotNull, reason: 'no active session after connect');

      // Seed a known text file.
      const root = '/tmp/mobissh_itest_1038';
      const fileName = 'hello.txt';
      const content = 'hello from test-sshd 1038\nsecond line\n';
      await _seedFile(
        tester,
        entry!,
        root: root,
        fileName: fileName,
        content: content,
      );

      // Open the browser at the seeded dir and tap the file → text viewer.
      final ctx = tester.element(find.byKey(const Key('session-menu-button')));
      unawaited(
        Navigator.of(ctx).push(
          MaterialPageRoute<void>(
            builder: (_) => FileBrowserScreen(
              sessionId: entry.id,
              initialPath: root,
            ),
          ),
        ),
      );
      final listed = await _pumpUntil(
        tester,
        () => find.byKey(const Key('file-entry-$fileName')).evaluate().isNotEmpty,
      );
      expect(listed, isTrue, reason: 'seeded file not listed');

      await tester.tap(find.byKey(const Key('file-entry-$fileName')));
      final viewerOpen = await _pumpUntil(
        tester,
        () => find.byType(TextFileViewerScreen).evaluate().isNotEmpty,
      );
      expect(viewerOpen, isTrue, reason: 'text viewer never opened');

      // Both actions present in the open preview's app bar.
      expect(find.byKey(const Key('viewer-action-download')), findsOneWidget);
      expect(find.byKey(const Key('viewer-action-share')), findsOneWidget);

      // Screenshot HOLD: orchestrator runs emu-shot during this window.
      debugPrint('VIEWER1038_SHOT_WINDOW_OPEN');
      for (var i = 0; i < 24; i++) {
        await tester.pump(_slice);
      }
      debugPrint('VIEWER1038_SHOT_WINDOW_CLOSED');

      // Download from the viewer — bytes round-trip into the sink.
      await tester.tap(find.byKey(const Key('viewer-action-download')));
      final downloaded = await _pumpUntil(
        tester,
        () => registry.sinks[fileName]?.finished == true,
      );
      expect(downloaded, isTrue, reason: 'viewer download never completed');
      expect(
        utf8.decode(registry.sinks[fileName]!.bytes, allowMalformed: true),
        content,
        reason: 'downloaded bytes do not match the seeded file',
      );

      // Share from the viewer — a REAL staged temp file reaches the launcher.
      await tester.tap(find.byKey(const Key('viewer-action-share')));
      final sharedFired = await _pumpUntil(
        tester,
        () => share.path != null,
      );
      expect(sharedFired, isTrue, reason: 'share launcher never invoked');
      expect(
        share.contentAtLaunch,
        content,
        reason: 'staged share file content mismatch',
      );
      expect(share.mime, 'text/plain');
      expect(share.name, fileName);
    },
  );
}
