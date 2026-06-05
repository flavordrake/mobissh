// On-emulator GHOSTTY OSC-8 hyperlink detection smoke (#767 Slice B).
//
// #767 Slice B makes the OSC-8 HYPERLINK the PRIMARY, exact URL source. Many
// tools (Claude CLI, gh, …) emit OSC-8 hyperlinks — `ESC]8;;<FULL-URI>ESC\
// <visible text>ESC]8;;ESC\` — and libghostty attaches the FULL exact URI to
// EVERY cell of the link, including the wrapped continuation rows. Reading the
// URI off the cells (`GridRef.hyperlinkUri` → `CellReader.hyperlinkAt` → the
// `osc8` scanner source) yields an EXACT match that spans all wrapped rows by
// construction — no regex, no wrap/width heuristic — and copy/open get the real
// full URL even when the VISIBLE text wraps and is itself only a partial URL.
//
// This validates the device-class behaviour a headless test cannot: print an
// OSC-8 hyperlink whose VISIBLE text WRAPS across rows but whose URI is the full
// link, then assert the controller exposes ONE `osc8` anchor whose payload is
// the EXACT full URI spanning the wrapped rows, and `matchAt` on the
// CONTINUATION row resolves that same full URI (the copy-partial bug fixed).
//
// The ghostty backend is the DEFAULT (#727), so no backend override is needed.
// GhosttyTerminalView.debugControllers (test-only) exposes the live controller.
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
// Run: scripts/native-connect-test.sh integration_test/ghostty_osc8_hyperlink_test.dart

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
    'an OSC-8 hyperlink whose visible text wraps is detected as ONE osc8 anchor '
    'carrying the EXACT full URI spanning the wrapped rows (#767 Slice B)',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      // Ghostty is the default backend (#727) — no override needed.
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

      // The ghostty view exposes its controller for the test.
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

      // The EXACT full URI behind the hyperlink. The VISIBLE text is long enough
      // to WRAP across terminal rows, but the URI stays the full link on every
      // cell — so the osc8 source must recover the full URI, not the (wrapping)
      // visible text. The visible text is deliberately a long path so it spans
      // multiple rows on the emulator's grid width.
      const fullUri =
          'https://mobissh.example.ts.net/mobissh-native-20260605T131127.apk';
      const visible =
          'short visible text that is intentionally long enough to wrap across '
          'several terminal rows on a typical phone grid width abcdefghijklmnop';

      // Emit an OSC-8 hyperlink: ESC]8;;<URI>ESC\<VISIBLE>ESC]8;;ESC\ . We send a
      // shell `printf` whose backslash-escapes the shell expands into the real
      // ESC bytes. (Dart string: each '\\' is one literal backslash for printf.)
      final printfCmd =
          "printf '\\033]8;;$fullUri\\033\\\\$visible\\033]8;;\\033\\\\\\n'\n";
      entry.proxy.sendInput(Uint8List.fromList(utf8.encode(printfCmd)));

      // Wait until the terminal detects the hyperlink as an `osc8` anchor whose
      // payload is the EXACT full URI (NOT the wrapping visible text).
      bool detected() => controller!.anchors.any(
            (a) => a.patternId == 'osc8' && a.payload == fullUri,
          );
      for (var i = 0; i < 50 && !detected(); i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(
        detected(),
        isTrue,
        reason:
            'OSC-8 hyperlink was not detected as an osc8 anchor carrying the '
            'exact full URI (#767 Slice B)',
      );

      // EXACTLY ONE anchor carries the full URI (the de-dup suppressed any
      // partial regex `url` match over the same hyperlinked cells, so there is
      // no second partial bubble beside it).
      final osc8Anchors = controller!.anchors
          .where((a) => a.payload == fullUri)
          .toList();
      expect(
        osc8Anchors,
        hasLength(1),
        reason: 'the hyperlink yielded more than one anchor (de-dup failed)',
      );
      final anchor = osc8Anchors.single;
      expect(anchor.patternId, 'osc8');

      // The anchor SPANS the wrapped rows: more than one per-row range, since the
      // long visible text wraps across the grid width.
      expect(
        anchor.ranges.length,
        greaterThan(1),
        reason:
            'the wrapping hyperlink did not span multiple rows — the osc8 run '
            'should cover every wrapped row (#767 Slice B)',
      );

      // matchAt on the CONTINUATION row (a non-first range) resolves the SAME
      // exact full URI — the copy-partial bug is fixed: a tap/long-press on the
      // wrapped continuation gets the real, full link.
      final offset = controller.scrollbar.offset;
      final continuation = anchor.ranges.last;
      final viewRow = continuation.startRow - offset;
      expect(
        viewRow,
        greaterThanOrEqualTo(0),
        reason: 'continuation row scrolled out of view — cannot hit-test it',
      );
      final match = controller.matchAt(
        row: viewRow,
        col: continuation.startCol,
      );
      expect(
        match?.payload,
        fullUri,
        reason:
            'matchAt on the CONTINUATION row did not resolve the full URI — '
            'copy/open would get a partial link (#767 Slice B)',
      );
    },
  );
}
