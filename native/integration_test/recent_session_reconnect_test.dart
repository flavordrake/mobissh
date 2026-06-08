// On-emulator Recent Sessions quick-connect smoke (#796, PWA parity #385).
//
// Proves the recents feature end-to-end against the REAL app + REAL task
// isolate + REAL dartssh2 socket (the only tier that catches device-class
// bugs — headless widget tests inject an InMemoryGatewayPair, see #539/#546):
//
//   1. Ad-hoc connect to test-sshd (saves the profile + records a recent on
//      the `connected` transition — the connect-success seam in
//      connect_form.dart `_armSaveRecentOnConnected`).
//   2. Close the session (the SessionsNotifier.close seam) — this is the path
//      that returns to the chooser. NOTE: per the PWA `state.ts` close effect,
//      close ALSO removes the recent; we re-add it by NOT closing the LAST
//      session here — instead we connect a SECOND time to verify the recent is
//      present, then quick-connect from it.
//
// Because close-removes-recent mirrors the PWA exactly, the durable on-device
// assertion is: after a successful connect the recents store HAS the entry, and
// tapping the rendered Recent Sessions row reaches a live shell (bytes flow).
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
//
// Tagged `integration` so the fast gate excludes it; the orchestrator runs it
// on the emulator as the device gate.
@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/recent_sessions.dart';
import 'package:mobissh/state/sessions.dart';

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('recent quick-connect reaches a live shell', (tester) async {
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

    // 1) Ad-hoc connect — saves the profile AND records a recent on connect.
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
    expect(connected, isTrue, reason: 'first connect never reached terminal');

    // The recent must have been recorded on the `connected` transition.
    final firstEntry = container.read(sessionsProvider).active;
    expect(firstEntry, isNotNull);
    var recents = <RecentSessionEntry>[];
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      recents = await container.read(recentSessionsStoreProvider).load();
      if (recents.any((r) => r.identityKey == firstEntry!.profileKey)) break;
    }
    expect(
      recents.any((r) => r.identityKey == firstEntry!.profileKey),
      isTrue,
      reason: 'successful connect did not record a recent session',
    );

    // 2) Close the session → back to the chooser. close() ALSO removes the
    // recent (PWA parity). Re-prove the round-trip by re-loading from the
    // store: it must no longer contain the closed identity.
    final closedKey = firstEntry!.profileKey;
    container.read(sessionsProvider.notifier).close(firstEntry.id);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      recents = await container.read(recentSessionsStoreProvider).load();
      if (!recents.any((r) => r.identityKey == closedKey)) break;
    }
    expect(
      recents.any((r) => r.identityKey == closedKey),
      isFalse,
      reason: 'close did not remove the session from recents (PWA #385)',
    );

    // 3) Seed a recent directly (the saved profile still exists), re-render the
    // chooser, and quick-connect from the rendered Recent Sessions row. This
    // exercises the one-tap path: render → tap → connect → shell bytes.
    await container.read(recentSessionsStoreProvider).add(
          RecentSessionEntry(
            title: 'testuser@127.0.0.1',
            host: '127.0.0.1',
            port: 2222,
            username: 'testuser',
          ),
        );
    container.invalidate(recentSessionsProvider);
    // Let the chooser rebuild (no active session now → recents group shows).
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (find.text('Recent Sessions').evaluate().isNotEmpty) break;
    }
    expect(
      find.byKey(const Key('recent-tile-127.0.0.1:2222:testuser')),
      findsOneWidget,
      reason: 'recent row did not render on the chooser',
    );

    await tester.tap(
      find.byKey(const Key('recent-tile-127.0.0.1:2222:testuser')),
    );

    // Reconnect must reach a live shell (bytes flow) — the real proof.
    var reconnected = false;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      final accept = find.text('Trust + connect');
      if (accept.evaluate().isNotEmpty) {
        await tester.tap(accept.first);
        await tester.pump(const Duration(milliseconds: 300));
      }
      if (find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty) {
        reconnected = true;
        break;
      }
    }
    expect(reconnected, isTrue,
        reason: 'recent quick-connect never reached the terminal screen');

    final entry = container.read(sessionsProvider).active;
    expect(entry, isNotNull, reason: 'no active session after recent connect');
    final out = <int>[];
    final sub = entry!.proxy.output.listen(out.addAll);
    addTearDown(sub.cancel);

    var gotPrompt = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (out.isNotEmpty) {
        gotPrompt = true;
        break;
      }
    }
    expect(
      gotPrompt,
      isTrue,
      reason:
          'recent quick-connect reached the screen but the shell produced '
          'ZERO bytes — not actually logged in',
    );

    // Echo round-trip proves stdin is wired to the reconnected PTY.
    const marker = 'MOBISSH_RECENT_OK_42';
    entry.proxy.sendInput(
      Uint8List.fromList(utf8.encode('echo $marker\n')),
    );
    var sawMarker = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (utf8.decode(out, allowMalformed: true).contains(marker)) {
        sawMarker = true;
        break;
      }
    }
    expect(sawMarker, isTrue,
        reason: 'typed command never echoed back after recent quick-connect');
  });
}
