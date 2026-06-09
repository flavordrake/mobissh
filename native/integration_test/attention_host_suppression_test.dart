// On-emulator HOST-LEVEL attention suppression (#847).
//
// #840 shipped attention notifications; on-device the owner had TWO sessions to
// the SAME host (fd-dev) and a single Claude bell reached BOTH PTYs → two
// stacked identical alerts, with NO suppression even though he was foregrounded
// looking at one of them. #847 makes the unit of attention the HOST: while the
// app is FOREGROUNDED on any session to a host, a bell from ANY session to that
// SAME host is suppressed (and cross-session repeats dedup to one slot).
//
// This test connects TWO sessions to the same test-sshd via two ports
// (127.0.0.1:2222 and :2223 — both resolve to the SAME host `127.0.0.1`), keeps
// the app FOREGROUNDED with one session active, then emits an OSC 9 bell over
// EACH session's live PTY and asserts ZERO attention-notification POSTS were
// logged — every bell is host-suppressed. Observed via the task-isolate
// `clifecycle` ring (forwarded to the UI ring, #766): the host logs
// `suppressed (foreground same-host)` at the decision point and NEVER
// `posted notification` while foregrounded on that host.
//
// We can't read the system tray from an integration test (mirrors the Slice-1
// measurement style: lenient but real — it asserts the POLICY decision, not the
// OS render). The FGS "Connected — …" text (Part 1) is covered by unit tests
// (`keepalive_task_test.dart`) since `updateService` output isn't tray-readable.
//
// Bridge: scripts/native-connect-test.sh with BRIDGE_PORT2=2223 (two socat+adb
// reverses → the one Alpine test-sshd).

@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/ssh/ssh_session.dart' show SshSessionState;
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/diagnostics/connect_trace.dart';

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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'two sessions to the SAME host, foregrounded on one → bells on both are '
    'HOST-suppressed (zero posts) (#847)',
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

      bool bothConnected() {
        final entries = container.read(sessionsProvider).entries;
        return entries.length == 2 &&
            entries.every(
              (e) => e.proxy.data.state == SshSessionState.connected,
            );
      }

      // Session A on 127.0.0.1:2222.
      await adhocPasswordConnect(
        tester,
        host: '127.0.0.1',
        port: '2222',
        user: 'testuser',
        pass: 'testpass',
      );
      final reachedA = await _pumpUntil(
        tester,
        () => find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty,
      );
      expect(reachedA, isTrue, reason: 'session A never reached the terminal');

      // New session → session B on 127.0.0.1:2223 (SAME host, different port).
      await tester.tap(find.byKey(const Key('session-menu-button')));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(find.byKey(const Key('session-menu-new')));
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await adhocPasswordConnect(
        tester,
        host: '127.0.0.1',
        port: '2223',
        user: 'testuser',
        pass: 'testpass',
      );
      final connectedBoth = await _pumpUntil(tester, bothConnected);
      expect(
        connectedBoth,
        isTrue,
        reason: 'both same-host sessions did not reach connected',
      );

      final entries = container.read(sessionsProvider).entries;
      expect(entries.length, 2);
      final sessA = entries.firstWhere((e) => e.port == 2222);
      final sessB = entries.firstWhere((e) => e.port == 2223);

      // FOREGROUNDED, active session = A (host 127.0.0.1). The unit of attention
      // is the host, so a bell on EITHER session (both host 127.0.0.1) must be
      // suppressed. main.dart pushes activeHost on the activeId change, but drive
      // it explicitly here so the test owns the foreground+active state.
      sessA.proxy.setActive(
        true,
        activeSessionId: sessA.id,
        activeHost: sessA.host,
      );
      await tester.pump(const Duration(milliseconds: 300));

      // Wait for both PTYs to be live (prompt bytes).
      final outA = <int>[];
      final outB = <int>[];
      final subA = sessA.proxy.output.listen(outA.addAll);
      final subB = sessB.proxy.output.listen(outB.addAll);
      addTearDown(subA.cancel);
      addTearDown(subB.cancel);
      for (var i = 0; i < 40 && (outA.isEmpty || outB.isEmpty); i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(outA.isNotEmpty && outB.isNotEmpty, isTrue,
          reason: 'a PTY never produced a prompt — dead shell');

      final before = lifecycleLogSnapshot().length;

      void bell(dynamic proxy) => proxy.sendInput(
            Uint8List.fromList(
              utf8.encode("printf '\\033]9;Claude needs attention\\007'\n"),
            ),
          );

      // One bell on each same-host session.
      bell(sessA.proxy);
      await tester.pump(const Duration(milliseconds: 300));
      bell(sessB.proxy);

      // Let the byte round-trip + scanner + suppression decision log.
      var suppressedCount = 0;
      var postedCount = 0;
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        final ring = lifecycleLogSnapshot();
        suppressedCount = 0;
        postedCount = 0;
        for (var j = before; j < ring.length; j++) {
          final line = ring[j];
          if (!line.contains('[attention]')) continue;
          if (line.contains('posted notification')) postedCount++;
          if (line.contains('suppressed') || line.contains('deduped')) {
            suppressedCount++;
          }
        }
        if (suppressedCount >= 1) break;
      }

      final sb = StringBuffer();
      sb.writeln('HOST847 ===== HOST-SUPPRESSION FINDINGS (#847) =====');
      sb.writeln('HOST847 hostA=${sessA.host} hostB=${sessB.host}');
      sb.writeln('HOST847 suppressed=$suppressedCount posted=$postedCount');
      for (final line in lifecycleLogSnapshot()) {
        if (line.contains('[attention]')) sb.writeln('HOST847 $line');
      }
      debugPrint(sb.toString());

      // The POLICY assertion: foregrounded on this host → NO attention post for
      // any same-host session.
      expect(
        postedCount,
        0,
        reason: 'a bell was POSTED while foregrounded on the same host — '
            'host-level suppression did not fire. Findings:\n$sb',
      );
      expect(
        suppressedCount,
        greaterThanOrEqualTo(1),
        reason: 'expected at least one suppressed/deduped attention decision. '
            'Findings:\n$sb',
      );
    },
  );
}
