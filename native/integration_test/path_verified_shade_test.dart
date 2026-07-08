// On-emulator smoke for #990 — detected vs VERIFIED path shades, plus the
// single-segment VISIBILITY gate (owner report on +121: `/config` bubbled).
//
// Connects to test-sshd and prints four references:
//   /etc/hosts        — REAL multi-segment  → detected shade, upgrades to bold
//   /no/such/path990  — FAKE multi-segment  → stays detected (fail-open)
//   /etc              — REAL single-segment → suppressed until its stat lands,
//                       then visible (verified)
//   /config           — FAKE single-segment (a TUI slash-command shape) →
//                       stat resolves MISSING → suppressed forever
// The session's SessionPathVerifier (GhosttyTerminalView.debugPathVerifiers)
// is the production instance the layers read; its status() drives both the
// shade and the visibility gate. This exercises the WHOLE production chain the
// headless tests fake: anchor rescan → notePaths → debounce → sftpStat IPC →
// task-side stat over the live SftpSession → SftpStatResultEvent → cache →
// shade/visibility predicates.
//
// After the assertions the test HOLDS the terminal on screen so the
// orchestrator can run `scripts/emu-shot.sh path-verified` and review that the
// two shades are distinguishable at phone density (bold ring on the verified
// row's gutter chip; thicker stroke + fill wash on its bubble).
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
// Run: scripts/native-connect-test.sh integration_test/path_verified_shade_test.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/services/path_verifier.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a REAL printed path upgrades to the verified shade; a FAKE one stays '
    'detected (#990)',
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

      const realPath = '/etc/hosts';
      const fakePath = '/no/such/path990';
      const realSingle = '/etc';
      const fakeSingle = '/config';
      entry.proxy.sendInput(
        Uint8List.fromList(
          utf8.encode(
            'echo REAL990 $realPath; echo FAKE990 $fakePath; '
            'echo DIR990 $realSingle; echo CMD990 $fakeSingle\n',
          ),
        ),
      );

      // Both paths must be DETECTED (path anchors) regardless of existence.
      bool bothDetected() =>
          controller!.anchors.any(
            (a) => a.patternId == 'path' && '${a.payload}' == realPath,
          ) &&
          controller.anchors.any(
            (a) => a.patternId == 'path' && '${a.payload}' == fakePath,
          );
      for (var i = 0; i < 40 && !bothDetected(); i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(
        bothDetected(),
        isTrue,
        reason: 'both printed paths must be DETECTED as path anchors '
            '(detection is syntactic — existence only affects the shade)',
      );

      // The session's verifier is the production instance the layers read.
      final verifier = GhosttyTerminalView.debugPathVerifiers[sessionId];
      expect(verifier, isNotNull, reason: 'no path verifier for session');

      // The REAL path upgrades to verified once its SFTP stat lands (debounce
      // + stat round-trip — give it a generous window).
      var realVerified = false;
      for (var i = 0; i < 40 && !realVerified; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        realVerified = verifier!.isVerified(realPath);
      }
      expect(
        realVerified,
        isTrue,
        reason: '$realPath exists on test-sshd — its anchor must upgrade to '
            'the VERIFIED shade',
      );

      // By now the fake path's stat has also resolved (same batch) — it must
      // read NOT verified (fail-open keeps the plain detected shade).
      expect(
        verifier!.isVerified(fakePath),
        isFalse,
        reason: '$fakePath does not exist — it must stay in the detected shade',
      );

      // #990 visibility gate — REAL single-segment (`/etc`): suppressed until
      // its stat lands, then VISIBLE (status verified drives the gate).
      var singleVerified = false;
      for (var i = 0; i < 40 && !singleVerified; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        singleVerified =
            verifier.status(realSingle) == PathVerification.verified;
      }
      expect(
        singleVerified,
        isTrue,
        reason: '$realSingle exists on test-sshd — its affordance must appear '
            'after verification',
      );

      // FAKE single-segment (`/config`, the slash-command shape): if the
      // scanner anchored it at all, its stat must resolve MISSING — the
      // visibility gate keeps it affordance-free forever (pending and missing
      // are both suppressed; the rendering side is asserted headlessly in the
      // gutter/bubble layer widget tests).
      final configAnchored = controller!.anchors.any(
        (a) => a.patternId == 'path' && '${a.payload}' == fakeSingle,
      );
      if (configAnchored) {
        var configResolved = false;
        for (var i = 0; i < 40 && !configResolved; i++) {
          await tester.pump(const Duration(milliseconds: 500));
          configResolved =
              verifier.status(fakeSingle) == PathVerification.missing;
        }
        expect(
          configResolved,
          isTrue,
          reason: '$fakeSingle must resolve MISSING (stat fails) so the '
              'visibility gate never shows its affordance',
        );
        expect(verifier.isVerified(fakeSingle), isFalse);
      }

      // Screenshot HOLD: keep both shades on screen for the external emu-shot.
      debugPrint('PATH990_SHOT_WINDOW_OPEN');
      for (var i = 0; i < 90; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      debugPrint('PATH990_SHOT_WINDOW_CLOSED');
    },
  );
}
