// On-emulator legacy host-key migration (#1226): a pre-upgrade MD5 entry
// re-confirms ONCE, then connects silently.
//
// dartssh2 >= 2.18 hands `onVerifyHostKey` the OpenSSH `SHA256:<b64>` text
// where 2.17 gave raw MD5 bytes (which we stored as 32 hex). An install that
// trusted test-sshd before the upgrade therefore holds a value that can never
// equal what the server now reports. Without the migration every saved host
// fails "HOST KEY CHANGED"; with it the user sees one distinct re-confirm.
//
//   1. Seed a legacy 32-hex MD5 for 127.0.0.1:2222 in the REAL
//      SharedPreferences before the app (and its foreground-task isolate,
//      which owns the HostKeyStore) starts. A fresh install per test file
//      guarantees nothing else is stored.
//   2. Connect → the RE-CONFIRM dialog appears (not "Trust + connect", not a
//      CHANGED failure), showing a SHA256 fingerprint. Confirm → live shell.
//   3. Disconnect, reconnect the saved tile → NO prompt of any kind, shell.
//
// Run: scripts/with-fleet-emulator.sh -- scripts/integration-subset.sh \
//   integration_test/hostkey_format_migration_1226_test.dart

@Tags(['integration'])
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/ssh/host_key_store.dart' show hostKeysPrefsKey;
import 'package:mobissh/state/sessions.dart';

import 'support/connect_helpers.dart';

const _slice = Duration(milliseconds: 500);

/// What a pre-#1226 install stored: hex of a 16-byte MD5.
const _legacyMd5 = '0123456789abcdef0123456789abcdef';

typedef _Seen = ({bool reconfirm, bool plainTrust, bool sha256});

/// Pump until the terminal mounts, recording (and optionally confirming) any
/// host-key prompt on the way.
Future<(bool, _Seen)> _connectAndWatch(
  WidgetTester tester, {
  required bool confirm,
}) async {
  var reconfirm = false;
  var plainTrust = false;
  var sha256 = false;
  var connected = false;
  for (var i = 0; i < 80; i++) {
    await tester.pump(_slice);
    if (find.text('Trust + connect').evaluate().isNotEmpty) plainTrust = true;
    final confirmBtn = find.text('Confirm + connect');
    if (confirmBtn.evaluate().isNotEmpty) {
      reconfirm = true;
      if (find.textContaining('older fingerprint format').evaluate().isNotEmpty &&
          find.textContaining('SHA256:').evaluate().isNotEmpty) {
        sha256 = true;
      }
      if (confirm) {
        await tester.tap(confirmBtn.first);
        await tester.pump(const Duration(milliseconds: 300));
      }
    }
    if (find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty) {
      connected = true;
      break;
    }
  }
  return (connected, (reconfirm: reconfirm, plainTrust: plainTrust, sha256: sha256));
}

Future<bool> _shellBytes(WidgetTester tester, ProviderContainer c) async {
  final entry = c.read(sessionsProvider).active;
  if (entry == null) return false;
  final out = <int>[];
  final sub = entry.proxy.output.listen(out.addAll);
  for (var i = 0; i < 40 && out.isEmpty; i++) {
    await tester.pump(_slice);
  }
  await sub.cancel();
  return out.isNotEmpty;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('legacy MD5 entry → one re-confirm, then silent (#1226)', (
    tester,
  ) async {
    FlutterForegroundTask.initCommunicationPort();

    // REAL prefs (no setMockInitialValues): the HostKeyStore lives in the
    // foreground-task isolate, which reads the platform store on first use.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      hostKeysPrefsKey,
      jsonEncode(<String, String>{'127.0.0.1:2222': _legacyMd5}),
    );

    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MobisshApp(),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    // 1st connect: the saved key is legacy → one distinct re-confirm.
    await adhocPasswordConnect(
      tester,
      host: '127.0.0.1',
      port: '2222',
      user: 'testuser',
      pass: 'testpass',
    );
    final (firstOk, first) = await _connectAndWatch(tester, confirm: true);
    expect(firstOk, isTrue,
        reason: 'never reached the terminal — a legacy entry must not fail '
            'as HOST KEY CHANGED');
    expect(first.reconfirm, isTrue,
        reason: 'a legacy MD5 entry must raise the re-confirm prompt');
    expect(first.plainTrust, isFalse,
        reason: 'not the first-contact prompt — that would hide the history');
    expect(first.sha256, isTrue,
        reason: 'the re-confirm names the older format and shows SHA256:<b64>');
    expect(await _shellBytes(tester, container), isTrue,
        reason: 'no shell bytes after confirming');

    // Disconnect (session menu → Disconnect) back to the chooser.
    await tester.tap(find.byKey(const Key('session-bar-open-menu')));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('terminal-disconnect-button')));
    var backAtChooser = false;
    for (var i = 0; i < 30 && !backAtChooser; i++) {
      await tester.pump(_slice);
      backAtChooser =
          find.byKey(const Key('new-connection')).evaluate().isNotEmpty;
    }
    expect(backAtChooser, isTrue, reason: 'disconnect did not return home');

    // 2nd connect: the entry was replaced with the SHA256 → no prompt at all.
    await tester.tap(
      find.byKey(const Key('profile-tile-127.0.0.1:2222:testuser')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    final (secondOk, second) = await _connectAndWatch(tester, confirm: false);
    expect(secondOk, isTrue, reason: 'reconnect did not reach the terminal');
    expect(second.reconfirm || second.plainTrust, isFalse,
        reason: 'the re-confirm is ONE-TIME — the replaced entry must match');
    expect(await _shellBytes(tester, container), isTrue);
  });
}
