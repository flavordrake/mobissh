// On-emulator SFTP UPLOAD smoke (#960).
//
// The headless tests drive a fake gateway; they can't catch a real chunked
// `.part`/rename transfer against a live SFTP server. This runs the REAL app on
// the emulator against test-sshd and exercises the upload path end to end:
//   - pick a LOCAL file (stubbed picker) → chunked sftpUploadFile into the
//     current remote dir → the file lands byte-count- and content-correct
//     (multi-chunk, so it exercises offset writes), via `.part` + atomic rename;
//   - a pre-seeded `.part` (interrupted upload) → the next upload produces the
//     CORRECT full file and the `.part` is gone (resume/replace correctness).
//
// Shell verification is ECHO-SAFE: results are wrapped in `$(...)` so the
// terminal's command echo can't match the sentinel (only the executed output
// can), and each command is RE-SENT until it lands (the first input can race the
// shell-ready signal, #619).

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
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/file_browser_screen.dart';

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

Future<bool> _reachTerminal(WidgetTester tester) => _pumpUntil(
      tester,
      () => find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty,
    );

/// Run [command] on the live shell, RE-SENDING it until [pattern] matches the
/// output (the first input can race shell-ready, #619). Returns the match.
/// Callers wrap dynamic results in `$(...)` so the terminal's command echo never
/// matches [pattern] — only the executed output does.
Future<RegExpMatch> _sh(
  WidgetTester tester,
  SessionEntry entry,
  String command,
  RegExp pattern, {
  int maxSlices = 120,
}) async {
  final out = <int>[];
  final sub = entry.proxy.output.listen(out.addAll);
  final bytes = Uint8List.fromList(utf8.encode('$command\n'));
  RegExpMatch? m;
  for (var i = 0; i < maxSlices; i++) {
    if (i % 14 == 0) entry.proxy.sendInput(bytes); // (re)send until it lands
    await tester.pump(_slice);
    final trust = find.text('Trust + connect');
    if (trust.evaluate().isNotEmpty) {
      await tester.tap(trust.first);
      await tester.pump(const Duration(milliseconds: 300));
    }
    m = pattern.firstMatch(utf8.decode(out, allowMalformed: true));
    if (m != null) break;
  }
  await sub.cancel();
  expect(m, isNotNull, reason: 'shell never matched /${pattern.pattern}/: $command');
  return m!;
}

Future<void> _openBrowserAt(
  WidgetTester tester,
  BuildContext context,
  String sessionId,
  String path,
) async {
  unawaited(
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            FileBrowserScreen(sessionId: sessionId, initialPath: path),
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

  testWidgets('uploads a multi-chunk file (.part → rename) + resume-correct', (
    tester,
  ) async {
    FlutterForegroundTask.initCommunicationPort();
    const root = '/tmp/mobissh_itest_960';
    const half = 100 * 1024;
    const total = half * 2;

    // Multi-chunk local file (>64 KB): 100 KB of 'A' then 100 KB of 'B'.
    final localBytes = Uint8List(total)
      ..fillRange(0, half, 0x41)
      ..fillRange(half, total, 0x42);
    final dir = await Directory.systemTemp.createTemp('mobissh_up_960');
    final localFile = File('${dir.path}/payload.bin');
    await localFile.writeAsBytes(localBytes);

    final container = ProviderContainer(
      overrides: [
        fileUploadPickerProvider.overrideWithValue(
          () async => (path: localFile.path, name: 'payload.bin'),
        ),
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

    await adhocPasswordConnect(
      tester,
      host: '127.0.0.1',
      port: '2222',
      user: 'testuser',
      pass: 'testpass',
    );
    expect(await _reachTerminal(tester), isTrue, reason: 'no terminal');
    final entry = container.read(sessionsProvider).active;
    expect(entry, isNotNull);

    // Seed the dir (and confirm the shell is live) — echo-safe sentinel.
    await _sh(
      tester,
      entry!,
      'rm -rf $root; mkdir -p $root; echo Z\$(echo ok)Z',
      RegExp('Z(ok)Z'),
    );

    final ctx = tester.element(find.byKey(const Key('session-menu-button')));
    await _openBrowserAt(tester, ctx, entry.id, root);

    // 1) Upload via the AppBar button (picker stubbed to our local file).
    await tester.tap(find.byKey(const Key('file-browser-upload')));
    expect(
      await _pumpUntil(
        tester,
        () =>
            find.byKey(const Key('file-entry-payload.bin')).evaluate().isNotEmpty,
        maxSlices: 120,
      ),
      isTrue,
      reason: 'uploaded file never appeared in the listing',
    );

    Future<void> verifyRemoteCorrect() async {
      // Byte count == full (echo-safe: command echo holds `Z$(wc..)Z`, not Z<n>Z).
      final size = await _sh(
        tester,
        entry,
        'echo Z\$(wc -c < $root/payload.bin)Z',
        RegExp(r'Z(\d+)Z'),
      );
      expect(size.group(1), '$total', reason: 'wrong uploaded byte count');
      // Content spans correctly: first byte 'A', last byte 'B'.
      final ends = await _sh(
        tester,
        entry,
        'echo Z\$(head -c 1 $root/payload.bin)\$(tail -c 1 $root/payload.bin)Z',
        RegExp('Z(AB)Z'),
      );
      expect(ends.group(1), 'AB', reason: 'uploaded content boundaries wrong');
      // No leftover `.part` → the atomic rename happened. `[ -e ]; echo $?` is
      // 0 when present, 1 when gone; %d keeps the sentinel out of the echo.
      final part = await _sh(
        tester,
        entry,
        'printf "PART%d\\n" \$([ -e $root/payload.bin.part ]; echo \$?)',
        RegExp('PART([01])'),
      );
      expect(part.group(1), '1', reason: '.part was left behind');
    }

    await verifyRemoteCorrect();

    // 2) Resume/replace: pre-seed a half-size `.part`, remove the final, upload
    // again → the engine continues into the `.part` and renames; final correct.
    await _sh(
      tester,
      entry,
      'head -c $half /dev/zero | tr "\\0" A > $root/payload.bin.part; '
          'rm -f $root/payload.bin; echo Z\$(echo ok)Z',
      RegExp('Z(ok)Z'),
    );
    await tester.tap(find.byKey(const Key('file-browser-upload')));
    expect(
      await _pumpUntil(
        tester,
        () =>
            find.byKey(const Key('file-entry-payload.bin')).evaluate().isNotEmpty,
        maxSlices: 120,
      ),
      isTrue,
      reason: 'resume upload never produced the file',
    );
    await verifyRemoteCorrect();
  });
}
