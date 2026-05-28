// On-emulator multi-session connect (goal leg 2).
//
// The CORE acceptance for the multi-session goal: a user can connect a SECOND
// session through the UI ("New session" affordance in the session menu) while
// the first is already connected, and BOTH sessions reach `connected`. This
// path crosses the FFT task-isolate boundary, exercises the host-key prompt
// for each session, and validates that the keepalive controller's service
// lifecycle does NOT close the first session when the second one starts (the
// keepaliveControllerProvider rebuild bug the prior wiring had). Headless
// widget tests cannot reach any of this — they all use InMemoryGatewayPair
// and never invoke real platform channels or a real foreground service.
//
// Network: scripts/native-connect-test.sh (run with BRIDGE_PORT2=2223) sets up
//   emulator 127.0.0.1:2222 → (adb reverse → socat) → test-sshd:22
//   emulator 127.0.0.1:2223 → (adb reverse → socat) → test-sshd:22
// so two DISTINCT host:port:username tuples both reach the Alpine test sshd.
// Two ports = two profileKeys = two genuinely separate sessions (the session
// notifier dedups on host:port:username), without needing a 2nd sshd container.
//
// Flow:
//   1. Connect session A (127.0.0.1:2222) → terminal screen.
//   2. Session menu → "New session" → connect session B (127.0.0.1:2223).
//   3. Assert BOTH proxies reach `connected`.
//
// Out of scope here (covered elsewhere):
//   - Tap-to-switch swap UI: `session_menu_test.dart` at widget level.
//   - AppLifecycleState paused/resumed proxy rebind: `app_lifecycle_test.dart`
//     and `foreground_task_lifecycle_test.dart` at unit level.
//   - Real OS-level app-swap / Doze survival: human device validation (the
//     `device` label on #357 — emulator lifecycle-state simulation is not the
//     same as Android actually backgrounding the activity + Doze throttling).

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/ssh/ssh_session.dart' show SshSessionState;
import 'package:mobissh/state/sessions.dart';

const _slice = Duration(milliseconds: 500);

Future<void> _pumpFrames(WidgetTester tester, int count) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Pump in 500ms slices until [test] returns true or [maxSlices] elapse.
/// Accepts any host-key trust prompt that surfaces along the way (new-host
/// trust-on-first-use), so the caller doesn't have to interleave that.
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

Future<void> _fillAndSubmit(
  WidgetTester tester, {
  required String host,
  required String port,
  required String user,
  required String pass,
}) async {
  await tester.enterText(find.byKey(const Key('connect-host')), host);
  await tester.enterText(find.byKey(const Key('connect-port')), port);
  await tester.enterText(find.byKey(const Key('connect-username')), user);
  await tester.enterText(find.byKey(const Key('connect-password')), pass);
  await tester.pump();
  await tester.tap(find.byKey(const Key('connect-submit')));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('two sessions connect via the New session UI on emulator',
      (tester) async {
    FlutterForegroundTask.initCommunicationPort();

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const MobisshApp()),
    );
    await tester.pump(const Duration(seconds: 1));

    bool bothConnected() {
      final entries = container.read(sessionsProvider).entries;
      return entries.length == 2 &&
          entries.every((e) => e.proxy.data.state == SshSessionState.connected);
    }

    // 1. Session A on port 2222.
    await _fillAndSubmit(
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
    expect(reachedA, isTrue,
        reason: 'session A never reached the terminal screen');

    // 2. New session → session B on port 2223.
    await tester.tap(find.byKey(const Key('session-menu-button')));
    await _pumpFrames(tester, 12);
    expect(find.byKey(const Key('session-menu-new')), findsOneWidget,
        reason: 'no "New session" affordance — leg 2 is UI-unreachable');
    await tester.tap(find.byKey(const Key('session-menu-new')));
    await _pumpFrames(tester, 16);
    expect(find.byKey(const Key('new-session-page')), findsOneWidget);

    await _fillAndSubmit(
      tester,
      host: '127.0.0.1',
      port: '2223',
      user: 'testuser',
      pass: 'testpass',
    );

    // 3. Both sessions reach connected (leg 2).
    final connectedBoth = await _pumpUntil(tester, bothConnected);
    expect(
      connectedBoth,
      isTrue,
      reason: 'both sessions did not reach connected — the New session path '
          'cannot establish a 2nd connection',
    );

    // Sanity: the collection holds two distinct entries on the right ports.
    final entries = container.read(sessionsProvider).entries;
    expect(entries.length, 2);
    expect(entries.any((e) => e.port == 2222), isTrue);
    expect(entries.any((e) => e.port == 2223), isTrue);
  });
}
