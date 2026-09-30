// On-emulator legacy host-key migration through a JUMP HOST (#1226, #1183).
//
// Every hop is verified against the same HostKeyStore (R9), so a pre-upgrade
// install holds legacy 32-hex MD5 entries for the BASTION and the TARGET. Both
// must re-confirm once — each dialog naming its own host (R10) — and neither
// may fail as HOST KEY CHANGED or fall back to the first-contact prompt. After
// that the jumped connect is silent.
//
// Topology as jump_host_1183_test.dart: the bastion is test-sshd via the
// 127.0.0.1:2222 bridge; the target is `jump-target:22`, reachable only from
// inside the bastion (fixture: docker-compose.test.yml `jump-target`).
//
// Run: scripts/with-fleet-emulator.sh -- scripts/integration-subset.sh \
//   integration_test/hostkey_format_migration_jump_1226_test.dart

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

import 'support/connect_helpers.dart';

const _slice = Duration(milliseconds: 500);
const _targetHost = 'jump-target';
const _legacyBastion = '0123456789abcdef0123456789abcdef';
const _legacyTarget = 'fedcba9876543210fedcba9876543210';

/// Pump until the terminal mounts, confirming every re-confirm dialog and
/// recording which host each one named. Also records any plain TOFU prompt.
Future<({bool connected, Set<String> reconfirmed, bool plainTrust})> _drive(
  WidgetTester tester, {
  int maxSlices = 120,
}) async {
  final reconfirmed = <String>{};
  var plainTrust = false;
  for (var i = 0; i < maxSlices; i++) {
    await tester.pump(_slice);
    if (find.text('Trust + connect').evaluate().isNotEmpty) {
      plainTrust = true;
      // Don't hang the test on a wrong prompt — decline it and let the
      // assertion below report what happened.
      await tester.tap(find.text('Cancel').first);
      await tester.pump(const Duration(milliseconds: 300));
    }
    final dialog = find.byKey(const Key('host-key-reconfirm-dialog'));
    if (dialog.evaluate().isNotEmpty) {
      for (final h in <String>['127.0.0.1', _targetHost]) {
        final named = find.descendant(
          of: dialog,
          matching: find.textContaining(h),
        );
        if (named.evaluate().isNotEmpty) reconfirmed.add(h);
      }
      await tester.tap(find.text('Confirm + connect').first);
      await tester.pump(const Duration(milliseconds: 300));
    }
    if (find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty) {
      return (connected: true, reconfirmed: reconfirmed, plainTrust: plainTrust);
    }
  }
  return (connected: false, reconfirmed: reconfirmed, plainTrust: plainTrust);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('legacy MD5 entries on BOTH hops re-confirm once, then the '
      'jumped connect is silent (#1226)', (tester) async {
    FlutterForegroundTask.initCommunicationPort();

    // REAL prefs, seeded before the foreground-task isolate (which owns the
    // HostKeyStore) first reads them. Fresh install per test file.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      hostKeysPrefsKey,
      jsonEncode(<String, String>{
        '127.0.0.1:2222': _legacyBastion,
        '$_targetHost:22': _legacyTarget,
      }),
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

    // Save the BASTION profile (plain Save, no connect).
    await openNewConnectionEditor(tester);
    await tester.enterText(find.byKey(const Key('profile-editor-title')), 'Bastion');
    await tester.enterText(find.byKey(const Key('profile-editor-host')), '127.0.0.1');
    await tester.enterText(find.byKey(const Key('profile-editor-port')), '2222');
    await tester.enterText(
      find.byKey(const Key('profile-editor-username')),
      'testuser',
    );
    await tester.enterText(
      find.byKey(const Key('profile-editor-password')),
      'testpass',
    );
    await tester.pump();
    final save = find.byKey(const Key('profile-editor-save'));
    await tester.ensureVisible(save);
    await tester.pump();
    await tester.tap(save);
    for (var i = 0; i < 20; i++) {
      await tester.pump(_slice);
      if (find.byKey(const Key('new-connection')).evaluate().isNotEmpty) break;
    }

    // Create the TARGET behind the bastion and connect.
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

    final first = await _drive(tester);
    expect(first.plainTrust, isFalse,
        reason: 'a legacy entry must never get the first-contact prompt');
    expect(first.connected, isTrue,
        reason: 'the jumped connect never reached the terminal — a legacy hop '
            'entry must not fail as HOST KEY CHANGED');
    expect(first.reconfirmed, containsAll(<String>['127.0.0.1', _targetHost]),
        reason: 'R9/R10 — the BASTION hop and the TARGET each re-confirm, '
            'each dialog naming its host');

    // Disconnect, then reconnect the saved target: both entries were replaced
    // with their SHA256, so the whole chain is silent.
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

    await tester.tap(
      find.byKey(const Key('profile-tile-$_targetHost:22:testuser')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    final second = await _drive(tester);
    expect(second.connected, isTrue, reason: 'jumped reconnect failed');
    expect(second.reconfirmed, isEmpty,
        reason: 'the re-confirm is ONE-TIME per hop');
    expect(second.plainTrust, isFalse);
  });
}
