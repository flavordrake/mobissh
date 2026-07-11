// On-emulator ssh -L port-forward integration (#1047).
//
// The REAL proof: the headless engine/host tests fake the direct-tcpip
// channel, so only this test exercises dartssh2's `forwardLocal` over a live
// SSH connection. It drives the real app on the emulator against test-sshd:
//
//   1. Connect (Save & connect → a saved profile exists for the star toggle).
//   2. Seed a TCP marker server ON test-sshd through the live shell:
//      a nohup'd busybox `nc -l -p 8088` loop serving PF_OK_1047 per connect
//      (nohup so the loop survives the deliberate session drop in step 6).
//   3. Session menu → Port forwards sheet → add 18088 → 127.0.0.1:8088.
//   4. HONEST probe: the test driver runs IN the app process, so a dart:io
//      Socket connect to 127.0.0.1:18088 goes through the app's loopback
//      listener → direct-tcpip channel → test-sshd's nc → asserts the marker.
//   5. Star the forward as a profile default (store write, end to end).
//   6. Drop the connection SERVER-side (kill the session's sshd from the
//      shell) → auto-reconnect → the forward RE-ARMS → probe again.
//   7. Remove the forward → connection refused + empty table.
//
// Screenshot: after step 4 the test HOLDS the sheet on screen (~8s, logged
// with PF_SHEET_HOLD markers) so an external `scripts/emu-shot.sh` captures
// the sheet with an ACTIVE forward — screenshots ARE the review artifact.
//
// Network: scripts/native-connect-test.sh bridges emulator 127.0.0.1:2222 →
// test-sshd:22. The forwarded target (127.0.0.1:8088) is test-sshd's OWN
// loopback — reachable only through the tunnel, so a passing probe cannot be
// a bridge artifact.

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

import 'support/connect_helpers.dart';

const _slice = Duration(milliseconds: 500);
const _marker = 'PF_OK_1047';

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

Future<bool> _reachTerminal(WidgetTester tester) {
  return _pumpUntil(
    tester,
    () => find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty,
  );
}

/// Open the session menu via the bottom bar (#782 idiom — see
/// sftp_browse_smoke_test.dart for why the InkWell, not the icon Row).
Future<void> _openSessionMenu(WidgetTester tester) async {
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump(const Duration(milliseconds: 200));
  final trigger = find.byKey(const Key('session-bar-open-menu'));
  await tester.ensureVisible(trigger);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(trigger, warnIfMissed: false);
  await _pumpUntil(
    tester,
    () => find.byKey(const Key('session-menu-new')).evaluate().isNotEmpty,
    maxSlices: 20,
  );
}

/// Send [command] through the live PTY and wait for [sentinel] to echo back.
Future<void> _shellRun(
  WidgetTester tester,
  SessionEntry entry, {
  required String command,
  required String sentinel,
  int maxSlices = 40,
}) async {
  final out = <int>[];
  final sub = entry.proxy.output.listen(out.addAll);
  addTearDown(sub.cancel);
  await tester.pump(const Duration(milliseconds: 200));
  entry.proxy.sendInput(Uint8List.fromList(utf8.encode('$command\n')));
  final ok = await _pumpUntil(
    tester,
    () => utf8.decode(out, allowMalformed: true).contains(sentinel),
    maxSlices: maxSlices,
  );
  expect(ok, isTrue, reason: 'shell command never echoed sentinel $sentinel');
}

/// The honest probe: dial the FORWARDED local port from inside the app
/// process and read everything until the far side closes.
Future<String> _probeForwardedPort(int port) async {
  final socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    port,
    timeout: const Duration(seconds: 5),
  );
  final got = <int>[];
  final done = Completer<void>();
  socket.listen(
    got.addAll,
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
    onError: (Object _) {
      if (!done.isCompleted) done.complete();
    },
  );
  await done.future.timeout(
    const Duration(seconds: 8),
    onTimeout: () => socket.destroy(),
  );
  socket.destroy();
  return utf8.decode(got, allowMalformed: true);
}

ForwardInfo? _forwardOf(SessionEntry entry, int localPort) {
  for (final f in entry.proxy.forwards) {
    if (f.localPort == localPort) return f;
  }
  return null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'ssh -L: add via sheet → marker through tunnel; survives drop→reconnect; '
    'remove → refused (#1047)',
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

      // 1) Connect. Save & connect persists a profile, so the star toggle
      // (profile default) is exercisable later.
      await adhocPasswordConnect(
        tester,
        host: '127.0.0.1',
        port: '2222',
        user: 'testuser',
        pass: 'testpass',
      );
      expect(await _reachTerminal(tester), isTrue,
          reason: 'never reached the terminal screen');
      final entry = container.read(sessionsProvider).active;
      expect(entry, isNotNull, reason: 'no active session after connect');

      // 2) Marker server on test-sshd's loopback. nohup: the loop must
      // survive the deliberate session drop in step 6.
      await _shellRun(
        tester,
        entry!,
        command:
            "nohup sh -c 'while true; do echo $_marker | nc -l -p 8088; done' "
            '>/dev/null 2>&1 & echo SRV_UP_1047',
        sentinel: 'SRV_UP_1047',
      );

      // 3) Session menu → Port forwards sheet → add 18088 → 127.0.0.1:8088.
      await _openSessionMenu(tester);
      await tester.tap(find.byKey(const Key('session-menu-port-forwards')));
      final sheetUp = await _pumpUntil(
        tester,
        () =>
            find.byKey(const Key('port-forwards-sheet')).evaluate().isNotEmpty,
        maxSlices: 20,
      );
      expect(sheetUp, isTrue, reason: 'Port forwards sheet never opened');

      await tester.enterText(
        find.byKey(const Key('forward-local-port')),
        '18088',
      );
      await tester.enterText(
        find.byKey(const Key('forward-remote-host')),
        '127.0.0.1',
      );
      await tester.enterText(
        find.byKey(const Key('forward-remote-port')),
        '8088',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('forward-add-submit')));

      final active = await _pumpUntil(
        tester,
        () => _forwardOf(entry, 18088)?.status == ForwardStatus.active,
        maxSlices: 30,
      );
      expect(active, isTrue,
          reason: 'forward 18088 never went ACTIVE '
              '(table: ${entry.proxy.forwards.map((f) => '${f.localPort}:${f.status.name} ${f.error ?? ''}')})');
      expect(find.byKey(const Key('forward-row-18088')), findsOneWidget);

      // 4) The honest probe: through the app's loopback listener → tunnel →
      // test-sshd's nc. The marker proves the direct-tcpip path end to end.
      final body = await _probeForwardedPort(18088);
      expect(body, contains(_marker),
          reason: 'forwarded fetch did not return the marker');

      // Screenshot hold: keep the sheet + ACTIVE row on screen for the
      // external emu-shot (see file header).
      debugPrint('PF_SHEET_HOLD_BEGIN');
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      debugPrint('PF_SHEET_HOLD_END');

      // 5) Star it as a profile default (store write, end to end).
      await tester.tap(find.byKey(const Key('forward-default-18088')));
      await tester.pump(const Duration(milliseconds: 300));

      // 6) Drop the connection SERVER-side: kill this session's sshd. The
      // controller auto-reconnects (softDisconnected → reconnecting →
      // connected) and the host re-arms the retained forward config.
      entry.proxy.sendInput(
        Uint8List.fromList(utf8.encode('kill -9 \$PPID\n')),
      );
      final dropped = await _pumpUntil(
        tester,
        () => entry.proxy.data.state != SshSessionState.connected,
        maxSlices: 30,
      );
      expect(dropped, isTrue, reason: 'server-side kill never dropped session');
      // While dropped, the forward must NOT be active (died with the session).
      final reconnected = await _pumpUntil(
        tester,
        () =>
            entry.proxy.data.state == SshSessionState.connected &&
            _forwardOf(entry, 18088)?.status == ForwardStatus.active,
        maxSlices: 80,
      );
      expect(reconnected, isTrue,
          reason: 'forward did not re-arm after auto-reconnect '
              '(state=${entry.proxy.data.state.name}, '
              'table: ${entry.proxy.forwards.map((f) => '${f.localPort}:${f.status.name}')})');

      final bodyAfter = await _probeForwardedPort(18088);
      expect(bodyAfter, contains(_marker),
          reason: 'forward re-armed but the tunnel did not carry the marker');

      // 7) Remove → refused + empty table. The sheet stayed open (modal
      // route, unaffected by the reconnect underneath).
      await tester.tap(find.byKey(const Key('forward-remove-18088')));
      final removed = await _pumpUntil(
        tester,
        () => _forwardOf(entry, 18088) == null,
        maxSlices: 20,
      );
      expect(removed, isTrue, reason: 'forward never left the table');
      await tester.pump(const Duration(milliseconds: 500));
      await expectLater(
        Socket.connect(
          InternetAddress.loopbackIPv4,
          18088,
          timeout: const Duration(seconds: 3),
        ),
        throwsA(isA<SocketException>()),
      );
    },
  );
}
