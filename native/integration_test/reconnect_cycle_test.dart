// On-emulator connect → disconnect → reconnect cycle (#564).
//
// Device bug: after tapping the terminal Disconnect button (returns to the
// connect form), a SECOND connect did nothing — stuck at idle. Cause: the
// AppBar Disconnect only called proxy.disconnect() and left the dead entry in
// the collection; the re-connect deduped to it in addOrActivate and skipped
// ensureStarted(), so once the foreground task isolate had stopped (last
// session gone) the re-connect command hit a dead isolate. Fix: Disconnect now
// close()s the session (remove the entry) and addOrActivate restarts the
// service defensively.
//
// PASS = both the first AND the second connect reach a LIVE shell (bytes flow).

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/sessions.dart';

Future<void> _fillForm(WidgetTester tester) async {
  await tester.enterText(find.byKey(const Key('connect-host')), '127.0.0.1');
  await tester.enterText(find.byKey(const Key('connect-port')), '2222');
  await tester.enterText(find.byKey(const Key('connect-username')), 'testuser');
  await tester.enterText(find.byKey(const Key('connect-password')), 'testpass');
  await tester.pump();
}

/// Submit and poll until the terminal screen mounts AND the shell streams
/// bytes. Accepts the host-key prompt if shown. Returns the bytes seen.
Future<bool> _connectAndProveShell(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.tap(find.byKey(const Key('connect-submit')));
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
  if (!connected) return false;

  final entry = container.read(sessionsProvider).active;
  if (entry == null) return false;
  final out = <int>[];
  final sub = entry.proxy.output.listen(out.addAll);
  var gotBytes = false;
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (out.isNotEmpty) {
      gotBytes = true;
      break;
    }
  }
  await sub.cancel();
  return gotBytes;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('connect, disconnect, then reconnect reaches a live shell again',
      (tester) async {
    FlutterForegroundTask.initCommunicationPort();
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const MobisshApp()),
    );
    await tester.pump(const Duration(seconds: 1));

    // First connect — must reach a live shell on the FIRST submit (no double-tap).
    await _fillForm(tester);
    final first = await _connectAndProveShell(tester, container);
    expect(first, isTrue,
        reason: 'first connect did not reach a live shell on a single tap');

    // Disconnect via the AppBar button → should remove the session + return to
    // the connect form.
    await tester.tap(find.byKey(const Key('terminal-disconnect-button')));
    var backAtForm = false;
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.byKey(const Key('connect-submit')).evaluate().isNotEmpty) {
        backAtForm = true;
        break;
      }
    }
    expect(backAtForm, isTrue, reason: 'disconnect did not return to the form');
    expect(container.read(sessionsProvider).entries, isEmpty,
        reason: 'disconnect must remove the session entry (#564)');

    // Reconnect — the bug: this did nothing, stuck at idle. Must reach a live
    // shell again.
    await _fillForm(tester);
    final second = await _connectAndProveShell(tester, container);
    expect(second, isTrue,
        reason: 'RECONNECT after disconnect did not reach a live shell — '
            'the #564 stuck-at-idle bug');
  });
}
