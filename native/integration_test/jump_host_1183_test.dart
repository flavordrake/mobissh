// A8 — on-emulator JUMP HOST acceptance (#1183, spec docs/jump-host.md,
// slice 1 acceptance). R7, R9, R10, R16.
//
// The real proof. Headless tests fake the hop client, so this is the only
// place dartssh2's `forwardLocal` + a nested `SSHClient` handshake actually
// runs over two live SSH connections.
//
// Topology:
//
//   emulator 127.0.0.1:2222 --(adb reverse)--> fd-dev --(socat)--> test-sshd
//        [ the BASTION profile ]                                   (the hop)
//                                                                      |
//                                              direct-tcpip channel    v
//                                                          jump-target:22
//                                                     [ the TARGET profile ]
//
// The device has NO route to `jump-target` — it is a Docker DNS name on the
// `mobissh` network, resolvable only from inside the bastion. So a connect
// that reaches a shell on `jump-target-host` CANNOT be a bridge artifact: it
// proves the session rode the bastion's channel. That is the whole point of
// picking an unreachable-by-the-device target.
//
// `uname -n` is the discriminator (R7: the session is the TARGET's). The
// bastion's hostname is its container id; the target's is pinned to
// `jump-target-host` in docker-compose.test.yml.
//
// Fixture: docker-compose.test.yml `jump-target` service +
// tests/emulator/sshd-fixture.js `ensureJumpTarget()`. Run with
//   scripts/with-fleet-emulator.sh -- scripts/integration-subset.sh \
//     integration_test/jump_host_1183_test.dart

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
import 'package:mobissh/state/sessions.dart';

import 'support/connect_helpers.dart';

const _slice = Duration(milliseconds: 500);

/// Pinned in docker-compose.test.yml so this assertion means something.
const _targetHostname = 'jump-target-host';

/// Docker DNS name of the target, resolved BY the bastion — never by the device.
const _targetHost = 'jump-target';

/// Pump until [test] holds, accepting any host-key prompt along the way.
/// A jumped connect raises TWO prompts (R9: every hop is verified), so the
/// loop must keep accepting rather than accept once.
Future<bool> _pumpUntil(
  WidgetTester tester,
  bool Function() test, {
  int maxSlices = 120,
  List<String>? promptedHosts,
}) async {
  for (var i = 0; i < maxSlices; i++) {
    await tester.pump(_slice);
    final trust = find.text('Trust + connect');
    if (trust.evaluate().isNotEmpty) {
      // R10: the prompt must NAME the host it is asking about. Record what it
      // said so the test can prove both hops were named.
      if (promptedHosts != null) {
        if (find.textContaining('127.0.0.1').evaluate().isNotEmpty) {
          promptedHosts.add('127.0.0.1');
        }
        if (find.textContaining(_targetHost).evaluate().isNotEmpty) {
          promptedHosts.add(_targetHost);
        }
      }
      await tester.tap(trust.first);
      await tester.pump(const Duration(milliseconds: 300));
    }
    if (test()) return true;
  }
  return false;
}

/// Fill the create-mode editor and tap plain "Save" (no connect).
Future<void> _saveProfile(
  WidgetTester tester, {
  required String title,
  required String host,
  required String port,
  required String user,
  required String pass,
}) async {
  await openNewConnectionEditor(tester);
  await tester.enterText(find.byKey(const Key('profile-editor-title')), title);
  await tester.enterText(find.byKey(const Key('profile-editor-host')), host);
  await tester.enterText(find.byKey(const Key('profile-editor-port')), port);
  await tester.enterText(find.byKey(const Key('profile-editor-username')), user);
  await tester.enterText(find.byKey(const Key('profile-editor-password')), pass);
  await tester.pump();
  final save = find.byKey(const Key('profile-editor-save'));
  await tester.ensureVisible(save);
  await tester.pump();
  await tester.tap(save);
  await _pumpUntil(
    tester,
    () => find.byKey(const Key('new-connection')).evaluate().isNotEmpty,
    maxSlices: 20,
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a profile with a jump host reaches a shell on the TARGET '
      'through the bastion (R7, R9, R10)', (tester) async {
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

    // 1. Save the BASTION profile (the only host the device can actually dial).
    await _saveProfile(
      tester,
      title: 'Bastion',
      host: '127.0.0.1',
      port: '2222',
      user: 'testuser',
      pass: 'testpass',
    );

    // 2. Create the TARGET profile, pick the bastion as its jump host, connect.
    await openNewConnectionEditor(tester);
    await tester.enterText(find.byKey(const Key('profile-editor-title')), 'Target');
    await tester.enterText(find.byKey(const Key('profile-editor-host')), _targetHost);
    await tester.enterText(find.byKey(const Key('profile-editor-port')), '22');
    await tester.enterText(
      find.byKey(const Key('profile-editor-username')),
      'testuser',
    );
    await tester.enterText(
      find.byKey(const Key('profile-editor-password')),
      'testpass',
    );
    await tester.pump();

    final picker = find.byKey(const Key('profile-editor-jump-host'));
    await tester.ensureVisible(picker);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(picker);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Bastion').last);
    await tester.pump(const Duration(milliseconds: 400));

    final submit = find.byKey(const Key('connect-submit'));
    await tester.ensureVisible(submit);
    await tester.pump();
    await tester.tap(submit);

    // 3. Both hops' host keys are unknown on a fresh install — R9 means TWO
    //    prompts, each naming its own host (R10).
    final prompted = <String>[];
    final connected = await _pumpUntil(
      tester,
      () => find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty,
      promptedHosts: prompted,
    );
    expect(
      connected,
      isTrue,
      reason: 'never reached the terminal through the jump host — the device '
          'has no route to $_targetHost, so this can only succeed via the '
          'bastion channel',
    );
    expect(
      prompted.toSet(),
      containsAll(<String>['127.0.0.1', _targetHost]),
      reason: 'R9/R10 — every hop is verified and every prompt names its host',
    );

    // 4. Real shell bytes, from the TARGET.
    final entry = container.read(sessionsProvider).active;
    expect(entry, isNotNull, reason: 'no active session after a jumped connect');

    final out = <int>[];
    final sub = entry!.proxy.output.listen(out.addAll);
    addTearDown(sub.cancel);

    final gotPrompt = await _pumpUntil(tester, () => out.isNotEmpty, maxSlices: 40);
    expect(gotPrompt, isTrue, reason: 'no shell bytes over the jumped session');

    out.clear();
    entry.proxy.sendInput(Uint8List.fromList(utf8.encode('uname -n\n')));
    final sawHostname = await _pumpUntil(
      tester,
      () => utf8.decode(out, allowMalformed: true).contains(_targetHostname),
      maxSlices: 60,
    );
    final text = utf8.decode(out, allowMalformed: true);
    expect(
      sawHostname,
      isTrue,
      reason: 'the shell must be the TARGET\'s ($_targetHostname), not the '
          "bastion's. Got: $text",
    );

    // 5. R7: the session's identity stays the TARGET's — a jump is transport,
    //    not a second session tab (D3).
    expect(entry.host, _targetHost);
    expect(
      container.read(sessionsProvider).entries,
      hasLength(1),
      reason: 'D3 — the bastion must not appear as its own session',
    );
  });
}
