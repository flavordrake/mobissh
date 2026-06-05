// On-emulator GHOSTTY in-terminal URL detection smoke (#767 Slice A).
//
// #767 moved URL detection INSIDE the forked flterm terminal: a registered
// `url` TextPattern scans the terminal's OWN cells, stores marks in ABSOLUTE
// buffer coords, and assigns `controller.highlights`. flterm's own painter
// re-reads the viewport offset each frame, so a detected highlight tracks
// scroll / wrap / resize / scrollback EVICTION for free — no app-side re-sync
// (the #748/#750/#751/#764 drift root cause is gone).
//
// This validates the device-class behaviour a headless test cannot: print a
// (potentially wrapping) URL, push it UP into scrollback by streaming more
// output, then assert the controller STILL detects + highlights the URL and
// `matchAt` resolves it on the row it now occupies — i.e. the mark followed its
// content instead of drifting or vanishing.
//
// The ghostty backend is the DEFAULT (#727), so no backend override is needed.
// The view exposes its live flterm controller via
// GhosttyTerminalView.debugControllers (test-only) so this can read highlights /
// matchAt directly.
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
// Run: scripts/native-connect-test.sh integration_test/ghostty_url_detection_test.dart

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
    'a printed URL is detected in-terminal and the highlight tracks scroll '
    'into scrollback (#767)',
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

      const url = 'https://example.com/some/longish/path/that/may/wrap';
      entry.proxy.sendInput(
        Uint8List.fromList(utf8.encode('echo MARKER767 $url\n')),
      );

      // Wait until the terminal detects the URL (highlight populated with the
      // URL payload). The controller's debounced re-scan does this off its own
      // notify cycle.
      bool detected() => controller!.highlights.any((r) => r.payload == url);
      for (var i = 0; i < 40 && !detected(); i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(
        detected(),
        isTrue,
        reason: 'in-terminal URL detection never highlighted the printed URL',
      );

      // Record the URL's absolute start row BEFORE scrolling it away.
      HighlightRange urlRange() =>
          controller!.highlights.firstWhere((r) => r.payload == url);
      final beforeAbsRow = urlRange().startRow;

      // Push the URL UP into scrollback by streaming a screenful+ of output.
      entry.proxy.sendInput(Uint8List.fromList(utf8.encode('seq 1 200\n')));
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }

      // The URL row scrolled out of the bottom viewport, but it is still within
      // the scanned scrollback window, so detection must STILL find it — and its
      // absolute row must NOT have drifted upward arbitrarily (it tracks content,
      // shifting only on real eviction). Assert it is still detected.
      expect(
        detected(),
        isTrue,
        reason:
            'the URL highlight VANISHED after scrolling into scrollback — the '
            'in-terminal mark did not track its content (#767)',
      );

      // The absolute row only changes by scrollback eviction; on a 200-line
      // stream past the cap it shifts DOWN (toward 0) by the evicted count, never
      // up. Assert it did not increase (no drift away from its content).
      final afterAbsRow = urlRange().startRow;
      expect(
        afterAbsRow <= beforeAbsRow,
        isTrue,
        reason:
            'URL absolute row INCREASED ($beforeAbsRow → $afterAbsRow) — the '
            'mark drifted instead of tracking its content (#767)',
      );

      // Scroll the viewport up so the URL row is visible again, then hit-test it.
      controller!.scrollToTop();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      // After scrollToTop the offset is 0; the URL's absolute row IS its viewport
      // row. matchAt is viewport-relative, so row = afterAbsRow - offset.
      final offset = controller.scrollbar.offset;
      final viewRow = urlRange().startRow - offset;
      if (viewRow >= 0) {
        final match = controller.matchAt(
          row: viewRow,
          col: urlRange().startCol,
        );
        expect(
          match?.payload,
          url,
          reason: 'matchAt on the URL cell after scroll did not resolve it',
        );
      }
    },
  );
}
