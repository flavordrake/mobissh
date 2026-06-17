// On-emulator DETECTION TOGGLE gate (#888 Part A).
//
// #888 Part A makes in-terminal structured-text detection toggleable: the
// Ghostty view reads the GLOBAL detectionSettingsProvider when registering
// flterm TextPatterns, and re-applies LIVE (clearTextPatterns + re-register)
// when the settings change. URL detection OFF ⇒ neither the osc8 nor the url
// pattern is registered ⇒ a printed URL produces NO `url` anchor (zero scan,
// zero decoration). Turning it back ON re-scans the current cells.
//
// This is the device-class assertion a headless unit test cannot make: it
// drives a REAL flterm controller over a live PTY and reads its anchors, and it
// exercises the build() ref.listen live-re-apply path. Reuses the #767
// detection harness (debugControllers + connect helpers). ONE connect (no
// double-connect flake): connect once, then flip the global toggle through the
// notifier and watch the anchors clear / return.
//
// The ghostty backend is the DEFAULT (#727), so no backend override is needed.
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
// Run: scripts/native-connect-test.sh integration_test/detection_toggle_test.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/detection_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const url = 'https://example.com/some/longish/path/that/may/wrap';

  testWidgets(
    'URL detection toggle gates the url anchor (ON→OFF→ON), live (#888)',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      // Default detection settings (all-true) — the notifier hydrates the
      // all-true default with no stored value on a fresh app data dir.
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
      for (var i = 0; i < 80; i++) {
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

      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      for (var i = 0; i < 40 && out.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(out.isNotEmpty, isTrue, reason: 'no shell prompt — dead PTY');

      bool hasUrlAnchor() => controller!.anchors.any(
            (a) => a.patternId == 'url' && a.payload == url,
          );

      // --- Detection ON (default): a printed URL is anchored. ---
      entry.proxy.sendInput(
        Uint8List.fromList(utf8.encode('echo MARKER888 $url\n')),
      );
      for (var i = 0; i < 40 && !hasUrlAnchor(); i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(
        hasUrlAnchor(),
        isTrue,
        reason: 'with detection ON the printed URL was not anchored',
      );

      // --- Flip URL detection OFF: live re-apply clears the url anchor. ---
      await container.read(detectionSettingsProvider.notifier).setUrl(false);
      // Pump build() so the ref.listen fires (clearTextPatterns + re-register),
      // then let the controller's scan settle on the empty pattern set.
      for (var i = 0; i < 20 && hasUrlAnchor(); i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      // Re-print the URL to give the (now-absent) url pattern every chance to
      // (incorrectly) anchor it, then assert it does NOT.
      entry.proxy.sendInput(
        Uint8List.fromList(utf8.encode('echo MARKER888B $url\n')),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(
        hasUrlAnchor(),
        isFalse,
        reason:
            'with URL detection OFF the url pattern must NOT be registered, so '
            'no url anchor exists (#888 Part A live re-apply)',
      );

      // --- Flip URL detection back ON: live re-apply re-scans + re-anchors. ---
      await container.read(detectionSettingsProvider.notifier).setUrl(true);
      for (var i = 0; i < 40 && !hasUrlAnchor(); i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(
        hasUrlAnchor(),
        isTrue,
        reason:
            'turning URL detection back ON did not re-scan the cells and '
            're-anchor the URL (#888 live re-apply)',
      );
    },
  );
}
