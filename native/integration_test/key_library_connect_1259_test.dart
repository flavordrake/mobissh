// On-emulator SSH KEY LIBRARY → attach → connect (#1259 gap 1).
//
// connect_key_smoke_test pastes the PEM straight into the profile editor. The
// library path — Settings → SSH keys → Add, then attach that key to a new
// profile — was headless-only (keys_screen_test, key_setup_1259_test). This
// drives it through the real UI against test-sshd and asserts shell bytes:
//   1. Add an INVALID key → refused in place (inline error, nothing listed).
//   2. Add the test-sshd key → "Key added", listed by name.
//   3. New connection → Key auth: the new library key is preselected (#1259).
//   4. Save & connect → trust the host key → a real shell echoes a marker.
//
// The key is the throwaway fixture docker/test-sshd/testuser_id_ed25519 (same
// as connect_key_smoke_test) — NOT a real secret; it only authenticates
// testuser against the local Alpine test-sshd container. Bridge: 127.0.0.1:2222
// → socat → test-sshd:22 (scripts/native-connect-test.sh).

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

const _testKeyPem = '''-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACB85qILD6Ykve+v2FrQWtcrsjW1baL6CXJ4LD5mmiDTdgAAAJgTrJmWE6yZ
lgAAAAtzc2gtZWQyNTUxOQAAACB85qILD6Ykve+v2FrQWtcrsjW1baL6CXJ4LD5mmiDTdg
AAAEBbgsew/IHGlnh7mBUSl/1dndeVjG9AmMGYWl0TNGsVK3zmogsPpiS976/YWtBa1yuy
NbVtovoJcngsPmaaINN2AAAAFXRlc3R1c2VyQG1vYmlzc2gtdGVzdA==
-----END OPENSSH PRIVATE KEY-----''';

const _keyName = 'test-sshd key';
const _slice = Duration(milliseconds: 500);

/// Pump until [test] holds, accepting a host-key prompt along the way.
Future<bool> _pumpUntil(
  WidgetTester tester,
  bool Function() test, {
  int maxSlices = 60,
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

bool _present(Finder f) => f.evaluate().isNotEmpty;

Future<void> _fillAddDialog(WidgetTester tester, String pem) async {
  await tester.enterText(find.byKey(const ValueKey('keys-add-name')), _keyName);
  await tester.enterText(find.byKey(const ValueKey('keys-add-pem')), pem);
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('keys-add-save')));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('library key: invalid refused, valid added, attached to a new '
      'profile, key-auth connect reaches a shell', (tester) async {
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

    // Settings → SSH keys.
    await tester.tap(find.byKey(const Key('home-nav-settings')));
    expect(
      await _pumpUntil(
          tester, () => _present(find.byKey(const ValueKey('ssh-keys-tile')))),
      isTrue,
      reason: 'Settings never showed the SSH keys row',
    );
    await tester.tap(find.byKey(const ValueKey('ssh-keys-tile')));
    expect(
      await _pumpUntil(
          tester, () => _present(find.byKey(const ValueKey('keys-add-fab')))),
      isTrue,
      reason: 'Keys screen never opened',
    );

    // 1. An invalid key is refused in place: inline error, dialog stays open.
    await tester.tap(find.byKey(const ValueKey('keys-add-fab')));
    await _pumpUntil(
        tester, () => _present(find.byKey(const ValueKey('keys-add-pem'))),
        maxSlices: 10);
    await _fillAddDialog(tester, 'this is not a private key');
    expect(
      await _pumpUntil(
          tester, () => _present(find.byKey(const ValueKey('keys-add-error'))),
          maxSlices: 10),
      isTrue,
      reason: 'an invalid key must show an inline error, not "Key added"',
    );
    expect(find.text('Key added'), findsNothing);
    expect(find.byKey(const ValueKey('keys-add-dialog')), findsOneWidget);

    // 2. The real key is accepted and listed.
    await _fillAddDialog(tester, _testKeyPem);
    expect(
      await _pumpUntil(
        tester,
        () =>
            !_present(find.byKey(const ValueKey('keys-add-dialog'))) &&
            _present(find.text(_keyName)),
        maxSlices: 20,
      ),
      isTrue,
      reason: 'the valid key never landed in the library list',
    );

    // Back to Profiles.
    await tester.pageBack();
    await _pumpUntil(
        tester, () => _present(find.byKey(const Key('home-nav-profiles'))),
        maxSlices: 10);
    await tester.tap(find.byKey(const Key('home-nav-profiles')));
    await _pumpUntil(
        tester, () => _present(find.byKey(const Key('new-connection'))),
        maxSlices: 10);

    // 3. New connection, Key auth: the library key is preselected.
    await openNewConnectionEditor(tester);
    await tester.enterText(
        find.byKey(const Key('profile-editor-host')), '127.0.0.1');
    await tester.enterText(find.byKey(const Key('profile-editor-port')), '2222');
    await tester.enterText(
        find.byKey(const Key('profile-editor-username')), 'testuser');
    await tester.tap(find.text('Key'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const Key('profile-editor-stored-key-note')),
      findsOneWidget,
      reason: 'switching to Key should attach the newest library key',
    );
    expect(find.text('Library: $_keyName'), findsWidgets);
    expect(find.byKey(const Key('profile-editor-key')), findsNothing);

    // 4. Save & connect, trust the host key, reach the terminal.
    final submit = find.byKey(const Key('connect-submit'));
    await tester.ensureVisible(submit);
    await tester.pump();
    await tester.tap(submit);
    expect(
      await _pumpUntil(tester,
          () => _present(find.byKey(const Key('session-menu-button')))),
      isTrue,
      reason: 'the library-key profile never reached the terminal',
    );

    // Real shell bytes: the marker is computed by the shell, so an echo of
    // the typed command alone can't satisfy it.
    final entry = container.read(sessionsProvider).active;
    expect(entry, isNotNull, reason: 'no active session after connect');
    final out = <int>[];
    final sub = entry!.proxy.output.listen(out.addAll);
    addTearDown(sub.cancel);
    expect(await _pumpUntil(tester, () => out.isNotEmpty, maxSlices: 40),
        isTrue,
        reason: 'no shell bytes over the key-auth session');
    out.clear();
    entry.proxy
        .sendInput(Uint8List.fromList(utf8.encode('echo keylib-\$((6*7))\n')));
    final sawMarker = await _pumpUntil(
      tester,
      () => utf8.decode(out, allowMalformed: true).contains('keylib-42'),
      maxSlices: 40,
    );
    expect(sawMarker, isTrue,
        reason: 'shell never ran the command. Got: '
            '${utf8.decode(out, allowMalformed: true)}');
  });
}
