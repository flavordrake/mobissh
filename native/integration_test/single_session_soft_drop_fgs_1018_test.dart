// On-emulator #1018: a SINGLE-session soft drop must not kill the keepalive
// foreground service mid-reconnect.
//
// Pre-fix race (found while building the #1014 repro, which deliberately used
// TWO sessions to sidestep it): `_holdsService()` counted only
// connected|reconnecting, so the lone session's `connected → softDisconnected`
// dipped the holder count 1→0 and scheduled an unawaited stop; the
// `reconnecting` transition 1ms later saw the service still running and
// skipped its start, then the scheduled stop landed — task isolate gone, UI
// gateway not-ready, every reconnect command buffered forever.
//
// Shape (single session, REAL transport drop, same kill mechanism as #1014):
//   1. connect ONE session (127.0.0.1:2222 bridge to test-sshd)
//   2. kill its `sshd: testuser@pts/N` via a throwaway dartssh2 EXEC
//      connection (exec = @notty, so the killer can never match itself)
//   3. assert the session leaves `connected` (the soft drop happened),
//      the FGS keeps running through the drop, and the held-params
//      reconnect revives a `connected` session — with the FGS still up.
//
// Pre-fix, step 3 fails: the FGS dies within the drop→reconnecting window and
// the revive never happens (reconnect buffers into a dead task isolate).
//
// Bridge: scripts/native-connect-test.sh \
//     integration_test/single_session_soft_drop_fgs_1018_test.dart

import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/sessions.dart';

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'single-session transport drop: FGS survives softDisconnected and the '
    'session revives (#1018)',
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

      /// Pump in 500ms slices until [test] passes or [maxSlices] elapse,
      /// accepting any host-key trust prompt along the way.
      Future<bool> pumpUntil(bool Function() test, {int maxSlices = 60}) async {
        for (var i = 0; i < maxSlices; i++) {
          await tester.pump(const Duration(milliseconds: 500));
          final trust = find.text('Trust + connect');
          if (trust.evaluate().isNotEmpty) {
            await tester.tap(trust.first);
            await tester.pump(const Duration(milliseconds: 300));
          }
          if (test()) return true;
        }
        return false;
      }

      // The ONE session — no second holder to mask the 1→0 dip.
      await adhocPasswordConnect(
        tester,
        host: '127.0.0.1',
        port: '2222',
        user: 'testuser',
        pass: 'testpass',
      );
      final reached = await pumpUntil(
        () => find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty,
      );
      expect(reached, isTrue, reason: 'session never reached the terminal');
      final entry = container.read(sessionsProvider).active!;
      final connected = await pumpUntil(
        () => entry.proxy.data.state == SshSessionState.connected,
      );
      expect(connected, isTrue, reason: 'session never connected');
      expect(await FlutterForegroundTask.isRunningService, isTrue,
          reason: 'precondition: FGS must be up while connected');

      // REAL transport drop: kill the pty-backed sshd process (only our
      // session has a pty; the killer runs over exec = @notty).
      final killer = SSHClient(
        await SSHSocket.connect('127.0.0.1', 2222),
        username: 'testuser',
        onPasswordRequest: () => 'testpass',
      );
      final killOut = utf8.decode(
        await killer.run(
          r'pkill -9 -f "sshd: testuser@pts/"; echo KILLED',
        ),
      );
      debugPrint('#1018 transport kill: $killOut');
      killer.close();

      final dropped = await pumpUntil(
        () => entry.proxy.data.state != SshSessionState.connected,
        maxSlices: 40,
      );
      expect(dropped, isTrue,
          reason: 'transport kill never dropped the session ($killOut)');

      // THE #1018 ASSERT (part 1): the drop schedules NO service stop — the
      // FGS must still be running while the lone session is reconnect-bound.
      // Poll a few slices so a pre-fix unawaited stop has time to land.
      var fgsSurvived = true;
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (!await FlutterForegroundTask.isRunningService) {
          fgsSurvived = false;
          break;
        }
      }
      expect(fgsSurvived, isTrue,
          reason: '#1018: the single-session soft drop killed the keepalive '
              'FGS mid-reconnect (transient 1→0 holder count)');

      // Held-params revive (force-now skips the reconnect backoff). Pre-fix
      // this buffers into a dead task isolate and never lands.
      entry.proxy.reconnect();
      final revived = await pumpUntil(
        () => entry.proxy.data.state == SshSessionState.connected,
        maxSlices: 80,
      );
      expect(revived, isTrue,
          reason: '#1018: held-params reconnect never revived the session — '
              'the reconnect command buffered into a dead task isolate');

      // THE #1018 ASSERT (part 2): still exactly one FGS, still running.
      expect(await FlutterForegroundTask.isRunningService, isTrue,
          reason: 'FGS must still be running after the revive');
    },
  );
}
