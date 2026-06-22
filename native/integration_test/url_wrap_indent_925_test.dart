// On-emulator GHOSTTY in-terminal detection of an INDENTED, soft-wrapped URL
// (#925, device-confirmed v0.1.10+66).
//
// The device bug: a long URL EMITTED as terminal output inside the Claude TUI
// soft-wraps across several INDENTED rows (the TUI re-indents each continuation
// row at a fixed left margin). Tap-copy returned ONLY the first visual row (~48
// chars) because the wrap-join (a) rejected the join when the indented
// continuation row's col 0 was blank and (b) injected the continuation row's
// leading indent as spaces between the URL halves, breaking the `[^\s]+` regex.
//
// A raw SSH soft-wrap continues at col 0 (no re-indent), so it does NOT
// reproduce the indented case. To replay the TUI's INDENTED wrap faithfully on
// real libghostty, this test reads the live grid width, then emits the URL
// PRE-WRAPPED into indented fragment lines that each FILL the grid width — the
// exact shape the TUI produces (indented rows, NO soft-wrap flag, the width
// fallback must join them). It then asserts ONE `url` anchor whose payload is the
// FULL URL (not the first-row truncation) and that it spans MULTIPLE rows.
//
// The ghostty backend is the DEFAULT (#727), so no backend override is needed.
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
// Run: scripts/native-connect-test.sh integration_test/url_wrap_indent_925_test.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'an INDENTED soft-wrapped URL is detected as ONE anchor carrying the FULL '
    'url, not just the first row (#925)',
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

      // Reach the terminal screen, accepting the host-key prompt if shown.
      var connected = false;
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        final accept = find.text('Trust + connect');
        if (accept.evaluate().isNotEmpty) {
          await tester.tap(accept.first);
          await tester.pump(const Duration(milliseconds: 300));
        }
        if (find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty) {
          connected = true;
          break;
        }
      }
      expect(connected, isTrue, reason: 'never reached the terminal screen');

      final entry = container.read(sessionsProvider).active;
      expect(entry, isNotNull, reason: 'no active session after connect');
      final sessionId = entry!.id;

      TerminalController? controllerOf() =>
          GhosttyTerminalView.debugControllers[sessionId];
      for (var i = 0; i < 40 && controllerOf() == null; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      final controller = controllerOf();
      expect(controller, isNotNull, reason: 'no ghostty controller for session');

      // Wait for a live shell prompt.
      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      for (var i = 0; i < 40 && out.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(out.isNotEmpty, isTrue, reason: 'no shell prompt — dead PTY');

      // Learn the live grid width so the emitted indented fragments FILL to it
      // (each non-final row reaches the wrap column, triggering the width-join).
      int? gridCols() =>
          GhosttyTerminalView.debugResizeCoalescers[sessionId]?.pendingCols;
      for (var i = 0; i < 40 && (gridCols() ?? 0) <= 0; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      final cols = gridCols() ?? 0;
      expect(cols, greaterThan(0), reason: 'never learned the live grid width');

      // Build a URL that, PRE-WRAPPED into indented fragments, spans 3 rows.
      const indent = 4;
      const indentStr = '    '; // matches `indent`
      // Per-row URL chars: ~55% of the grid width so each non-final row is "long"
      // (past the half-width wrapCol threshold) yet stays WELL UNDER the grid edge
      // — so the live flterm grid does NOT re-soft-wrap a fragment (which would
      // interleave extra rows and break the controlled shape). All non-final rows
      // share the SAME content-end column, which becomes the inferred wrap column
      // that the indent-aware width-join keys off.
      final content = (cols * 55) ~/ 100 - indent;
      expect(content, greaterThan(10), reason: 'grid too narrow for the test');
      // A no-whitespace URL long enough to span 3 fragment rows.
      final tail = 'x' * (content * 2 + (content ~/ 2));
      final url = 'https://example.com/$tail';

      // PRE-WRAP into indented fragments: each non-final fragment is `indent` +
      // exactly `content` URL chars (so they share one content-end column); the
      // final fragment carries the remainder.
      final fragments = <String>[];
      var pos = 0;
      while (pos < url.length) {
        final take = (url.length - pos) < content ? (url.length - pos) : content;
        fragments.add('$indentStr${url.substring(pos, pos + take)}');
        pos += take;
      }
      expect(fragments.length, greaterThanOrEqualTo(3),
          reason: 'expected the URL to wrap across at least 3 indented rows');

      // Emit each fragment on its OWN line (hard newline → rowWrap=false), so the
      // grid shows the indented, app-wrapped shape the device reported.
      final block = '${fragments.join('\n')}\n';
      // `printf %s` to emit the block verbatim (no shell mangling of the URL).
      entry.proxy.sendInput(
        Uint8List.fromList(utf8.encode("printf '%s' '$block'\n")),
      );

      // Wait until the in-terminal scanner detects the URL with the FULL payload.
      bool detectedFull() =>
          controller!.anchors.any((a) => a.patternId == 'url' && a.payload == url);
      for (var i = 0; i < 60 && !detectedFull(); i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      // Diagnose on failure: show what payloads WERE found (the bug yields the
      // first-row truncation, not the full URL).
      final found = controller!.anchors
          .where((a) => a.patternId == 'url')
          .map((a) => a.payload)
          .toList();
      expect(
        detectedFull(),
        isTrue,
        reason:
            'the INDENTED wrapped URL was NOT detected as one FULL-payload anchor '
            '(#925). url anchors found: $found',
      );

      // The full match must span MULTIPLE rows (one HighlightRange per wrapped
      // row) — proving the join crossed the indented continuation rows.
      final anchor =
          controller.anchors.firstWhere((a) => a.payload == url);
      expect(
        anchor.ranges.length,
        greaterThanOrEqualTo(2),
        reason: 'the full URL anchor must span the wrapped rows',
      );

      // matchAt on a SECOND-row cell of the URL must resolve the FULL url — the
      // device symptom was the second/third rows not being part of the match.
      final secondRowRange = anchor.ranges.length >= 2 ? anchor.ranges[1] : null;
      expect(secondRowRange, isNotNull);
      final offset = controller.scrollbar.offset;
      final viewRow = secondRowRange!.startRow - offset;
      if (viewRow >= 0) {
        final match = controller.matchAt(
          row: viewRow,
          col: secondRowRange.startCol,
        );
        expect(
          match?.payload,
          url,
          reason:
              'matchAt on a CONTINUATION row of the indented wrapped URL must '
              'resolve the FULL url (#925 first-row-only regression)',
        );
      }
    },
    // SKIPPED: faithfully reproducing the device's INDENTED app-wrap on the
    // emulator is unreliable — no app on test-sshd RE-INDENTS soft-wrapped
    // continuation rows (a raw SSH soft-wrap resumes at col 0), so this test
    // hand-emits pre-indented fragment lines whose exact content-end vs the LIVE
    // flterm grid width (which drifts with keyboard/resize) and the wrapping
    // command-echo are not controllable enough to deterministically form the
    // 3-indented-row shape the width-join keys off. The #925 logic is instead
    // validated AUTHORITATIVELY headless: (a) the pure-Dart unit suite
    // third_party/flterm/test/foundation/structured_text_wrap_indent_925_test.dart
    // (indented 3-row no-flag join → full payload, true-column ranges, rowWrap
    // fast path, col-0 soft-wrap continuation, #764 different-indent + bullet
    // guards), and (b) the REAL device-captured-grid replay
    // test/terminal/replay_url_miss_834_test.dart, where an actual owner bug-report
    // tmux grid with an indented hard-wrapped URL now joins to the FULL
    // `…/comms-digest-2026-06-08`. This test is kept as executable documentation of
    // the intended on-device behavior (mirrors url_copy_navigate_test.dart's
    // skip-for-unreproducible-path precedent).
    skip: true,
  );
}
