// On-emulator EDITOR INTEGRITY: load → edit → save never rewrites bytes the
// user did not edit (#1227).
//
// Setup (run FIRST): scripts/editor-integrity-1227-setup.sh
//
// #1227 (owner data loss, found by the 2026-09-30 byte audit after #1225): the
// markdown editor decoded with `allowMalformed: true`, so a Latin-1 file loaded
// as U+FFFD mojibake and a Save wrote the replacement characters over the
// server's bytes; Dart's `utf8.decode` also drops a leading BOM, so a BOM file
// lost its BOM on save. This test drives the REAL app, task isolate and IPC
// against the real test-sshd and compares every server byte against content
// the test knows INDEPENDENTLY — the setup script and this file compute the
// same recipes; nothing is verified by comparing one transfer with another
// through the same reader.
//
//   utf8.md    BOM + "# edit 1227 café ✓ 日本語 🎉\r\n\r\n" + 43-byte ASCII CRLF
//              lines; before each of 32768 / 65536, pad with "x" to B-2 then
//              "🎉\r\n" so a 4-byte character STRADDLES the boundary; lines
//              until >= 100000 bytes.
//   latin1.md  "# latin1 1227\r\n\r\n" + 40 × "café naïve résumé © 2026\r\n"
//              as ISO-8859-1 — NOT valid UTF-8.
//
// Phases:
//   A. utf8.md through the UI: open in the markdown viewer, Edit is ENABLED,
//      the editor holds exactly the decoded text (CRLF intact, no BOM char),
//      append a line, Save → server size and bytes == BOM + original + line,
//      and no `utf8.md.part` is left behind (#1228's atomic save, once merged,
//      must clean up after itself; today's direct write leaves none either).
//   B. latin1.md through the UI: the viewer opens it read-only — Edit is
//      DISABLED with the persistent explanation, tapping it opens no editor —
//      and the server file is byte-identical afterwards.
//
// Data mismatches are COLLECTED and asserted once at the end so a single run
// reports every phase; transport failures stay hard failures.
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
const _root = '/home/testuser/edit_1227';

/// The utf8.md recipe, shared with scripts/editor-integrity-1227-setup.sh.
Uint8List _utf8Doc() {
  final out = BytesBuilder(copy: false);
  out.add(const [0xEF, 0xBB, 0xBF]);
  out.add(utf8.encode('# edit 1227 café ✓ 日本語 🎉\r\n\r\n'));
  var k = 0;
  List<int> line() => ascii.encode(
    'line ${(k++).toString().padLeft(5, '0')} the quick brown fox jumps over'
    '\r\n',
  );
  for (final b in const [32768, 65536]) {
    while (out.length + 43 <= b - 2) {
      out.add(line());
    }
    out.add(List<int>.filled(b - 2 - out.length, 0x78)); // 'x'
    out.add(utf8.encode('🎉\r\n'));
  }
  while (out.length < 100000) {
    out.add(line());
  }
  return out.takeBytes();
}

/// The latin1.md recipe, shared with scripts/editor-integrity-1227-setup.sh.
Uint8List _latin1Doc() => Uint8List.fromList(
  latin1.encode('# latin1 1227\r\n\r\n${'café naïve résumé © 2026\r\n' * 40}'),
);

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
  int maxSlices = 240,
}) async {
  T? done;
  SftpErrorEvent? err;
  final sub = entry.proxy.sftpEvents.listen((e) {
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
  SftpListingEvent() => e.requestId,
  _ => null,
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'editor never rewrites bytes the user did not edit: BOM/CRLF/4-byte '
    'round-trip, Latin-1 refused (#1227)',
    timeout: const Timeout(Duration(minutes: 15)),
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

      final local = await Directory.systemTemp.createTemp('edit_1227_');
      addTearDown(() async {
        if (await local.exists()) await local.delete(recursive: true);
      });

      final failures = <String>[];
      final passes = <String>[];
      void check(String label, List<int> got, List<int> want) {
        final d = _diff(label, got, want);
        if (d == null) {
          passes.add(label);
          debugPrint('EDIT1227 PASS $label');
        } else {
          failures.add(d);
          debugPrint('EDIT1227 FAIL $d');
        }
      }

      void checkEq(String label, Object? got, Object? want) {
        if (got == want) {
          passes.add(label);
          debugPrint('EDIT1227 PASS $label');
        } else {
          final d = '$label: got $got, want $want';
          failures.add(d);
          debugPrint('EDIT1227 FAIL $d');
        }
      }

      var seq = 0;

      // Streaming download to a local file (the #976 browser Download path,
      // proven byte-exact against independent content by #1225's test).
      Future<Uint8List> downloadToDisk(String remote) async {
        final id = 'it1227#dlf${seq++}';
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

      // Server-side listing: name → size (stat via readdir, not the read path).
      Future<Map<String, int?>> listing(String dir) async {
        final id = 'it1227#ls${seq++}';
        final ev = await _await<SftpListingEvent>(
          tester,
          entry,
          id,
          () => entry.proxy.sftpList(requestId: id, path: dir),
        );
        return {for (final e in ev.entries) e.name: e.size};
      }

      Future<void> openInViewer(String name) async {
        await tester.tap(find.byKey(Key('file-entry-$name')));
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
          reason: 'markdown viewer never finished loading $name',
        );
      }

      IconButton editToggle() =>
          tester.widget<IconButton>(find.byKey(const Key('markdown-edit-toggle')));

      final ctx = tester.element(find.byKey(const Key('session-menu-button')));
      unawaited(
        Navigator.of(ctx).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                FileBrowserScreen(sessionId: entry.id, initialPath: _root),
          ),
        ),
      );
      expect(
        await _pumpUntil(
          tester,
          () => find
              .byKey(const Key('file-entry-utf8.md'))
              .evaluate()
              .isNotEmpty,
        ),
        isTrue,
        reason: 'utf8.md not listed in the file browser',
      );

      // Phase A: the valid UTF-8 file (BOM, CRLF, 4-byte straddlers).
      {
        final original = _utf8Doc();
        final body = original.sublist(3); // what the editor shows (no BOM)
        const appended = 'appended 1227 ✓ 日本語 🎉\r\n';

        await openInViewer('utf8.md');
        checkEq('A utf8.md Edit enabled', editToggle().onPressed != null, true);
        checkEq(
          'A utf8.md no read-only banner',
          find.byKey(const Key('markdown-viewer-edit-disabled')).evaluate().isEmpty,
          true,
        );

        await tester.tap(find.byKey(const Key('markdown-edit-toggle')));
        await tester.pump(const Duration(milliseconds: 500));
        final editor = find.byKey(const Key('markdown-viewer-editor'));
        expect(editor, findsOneWidget, reason: 'edit mode never opened');
        final loaded = tester.widget<TextField>(editor).controller!.text;
        check(
          'A editor loaded utf8.md body size=${body.length}',
          utf8.encode(loaded),
          body,
        );
        checkEq(
          'A editor buffer has no BOM character',
          loaded.startsWith('﻿'),
          false,
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

        final wantSaved = Uint8List.fromList([
          ...original,
          ...utf8.encode(appended),
        ]);
        final names = await listing(_root);
        checkEq('A utf8.md server size', names['utf8.md'], wantSaved.length);
        checkEq(
          'A utf8.md no .part left behind',
          names.containsKey('utf8.md.part'),
          false,
        );
        check(
          'A utf8.md saved bytes == BOM + original + edit size=${wantSaved.length}',
          await downloadToDisk('$_root/utf8.md'),
          wantSaved,
        );
      }

      // Back to the browser for phase B.
      await tester.pageBack();
      expect(
        await _pumpUntil(
          tester,
          () => find
              .byKey(const Key('file-entry-latin1.md'))
              .evaluate()
              .isNotEmpty,
        ),
        isTrue,
        reason: 'latin1.md not listed after returning to the browser',
      );

      // Phase B: the Latin-1 file is viewable, NOT editable, and untouched.
      {
        final original = _latin1Doc();
        await openInViewer('latin1.md');
        checkEq('B latin1.md Edit disabled', editToggle().onPressed, null);
        checkEq(
          'B latin1.md read-only banner shown',
          find
              .byKey(const Key('markdown-viewer-edit-disabled'))
              .evaluate()
              .isNotEmpty,
          true,
        );
        checkEq(
          'B latin1.md explanation text',
          find.textContaining("isn't valid UTF-8").evaluate().isNotEmpty,
          true,
        );
        await tester.tap(
          find.byKey(const Key('markdown-edit-toggle')),
          warnIfMissed: false,
        );
        await tester.pump(const Duration(milliseconds: 500));
        checkEq(
          'B latin1.md tapping Edit opens no editor',
          find.byKey(const Key('markdown-viewer-editor')).evaluate().isEmpty,
          true,
        );

        final names = await listing(_root);
        checkEq('B latin1.md server size', names['latin1.md'], original.length);
        checkEq(
          'B latin1.md no .part left behind',
          names.containsKey('latin1.md.part'),
          false,
        );
        check(
          'B latin1.md byte-identical afterwards size=${original.length}',
          await downloadToDisk('$_root/latin1.md'),
          original,
        );
      }

      debugPrint(
        'EDIT1227 SUMMARY passed=${passes.length} failed=${failures.length}',
      );
      for (final p in passes) {
        debugPrint('EDIT1227 SUMMARY-PASS $p');
      }
      for (final f in failures) {
        debugPrint('EDIT1227 SUMMARY-FAIL $f');
      }
      expect(
        failures,
        isEmpty,
        reason: 'editor integrity violated:\n${failures.join('\n')}',
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
