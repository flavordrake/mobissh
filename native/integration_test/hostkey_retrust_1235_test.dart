// On-emulator CHANGED-host-key re-trust (#1235, owner P0 lockout).
//
// Owner report on 0.1.12-rc.4+195: a rebuilt host showed only "HOST KEY
// CHANGED … Forget the old key to re-trust." with no action to take, so the
// owner was locked out. The fix adds a persistent Review action, a warned
// forget, and a reconnect that lands on the ORDINARY first-contact prompt.
//
// Flow under test (the transitions, not just end states):
//   1. A WRONG fingerprint is stored for test-sshd before the app starts.
//   2. Connect → fails closed: CHANGED, NO trust prompt, Review action shown.
//   3. Review → dialog shows the stored (wrong) and offered keys → Forget.
//   4. The reconnect reaches the first-contact prompt with the OFFERED key.
//   5. Accept → connected, shell bytes flow.
//   6. Disconnect + reconnect → silent (no prompt): the new key persisted.
//
// Seeding goes through the REAL SharedPreferences (no setMockInitialValues):
// on Android the trust store lives in the foreground-task isolate, which reads
// the on-disk prefs, so a UI-isolate mock would never reach it. The entry is
// removed in tearDown so hostkey_persist_test still sees a fresh store.
//
// Run: scripts/native-connect-test.sh integration_test/hostkey_retrust_1235_test.dart

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/ssh/host_key_store.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/sessions.dart';

import 'support/connect_helpers.dart';

/// test-sshd as the device sees it (adb reverse).
const _hostPort = '127.0.0.1:2222';

/// Deliberately WRONG stored key: a "rebuilt host" from the app's view. It must
/// be SHA256 text (#1226): a 32-hex MD5 value now means a LEGACY entry, which
/// gets the format re-confirm prompt instead of the CHANGED failure.
const _wrongFingerprint = 'SHA256:WrongKeyRebuiltHost000000000000000000000000';

const _reviewText = 'Host key changed — Review';

Future<({bool reachedShell, bool sawPrompt})> _awaitShell(
  WidgetTester tester,
  ProviderContainer container, {
  required bool acceptPromptIfShown,
}) async {
  var connected = false;
  var sawPrompt = false;
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    final accept = find.text('Trust + connect');
    if (accept.evaluate().isNotEmpty) {
      sawPrompt = true;
      if (acceptPromptIfShown) {
        await tester.tap(accept.first);
        await tester.pump(const Duration(milliseconds: 300));
      }
    }
    if (find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty) {
      connected = true;
      break;
    }
  }
  if (!connected) return (reachedShell: false, sawPrompt: sawPrompt);

  final entry = container.read(sessionsProvider).active;
  if (entry == null) return (reachedShell: false, sawPrompt: sawPrompt);
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
  return (reachedShell: gotBytes, sawPrompt: sawPrompt);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(hostKeysPrefsKey);
  });

  testWidgets(
    'CHANGED key → Review → Forget → first-contact prompt → accept → shell; '
    'reconnect silent (#1235)',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        hostKeysPrefsKey,
        jsonEncode(<String, String>{_hostPort: _wrongFingerprint}),
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

      // 2. Connect → CHANGED, fail closed, Review shown, never a trust prompt.
      await adhocPasswordConnect(
        tester,
        host: '127.0.0.1',
        port: '2222',
        user: 'testuser',
        pass: 'testpass',
      );
      var sawReview = false;
      var promptedEarly = false;
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.text('Trust + connect').evaluate().isNotEmpty) {
          promptedEarly = true;
        }
        if (find.text(_reviewText).evaluate().isNotEmpty) {
          sawReview = true;
          break;
        }
      }
      expect(
        promptedEarly,
        isFalse,
        reason: 'a CHANGED key must never reach the trust prompt (#1108)',
      );
      expect(sawReview, isTrue, reason: 'no Review action on the CHANGED failure');

      final entry = container.read(sessionsProvider).active;
      expect(entry, isNotNull);
      final mismatch = entry!.proxy.data.hostKeyMismatch;
      // `disconnected` too: the failed first connect stops the foreground
      // service, and its teardown can move the session on.
      expect(
        entry.proxy.data.state,
        anyOf(SshSessionState.failed, SshSessionState.disconnected),
      );
      expect(mismatch, isNotNull, reason: 'mismatch must cross IPC structured');
      expect(mismatch!.storedFingerprint, _wrongFingerprint);
      expect(mismatch.offeredFingerprint, isNot(_wrongFingerprint));
      final offered = mismatch.offeredFingerprint;

      // 3. Review → both keys shown → Forget.
      await tester.tap(find.text(_reviewText).first);
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('hostkey-mismatch-dialog')), findsOneWidget);
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const Key('hostkey-mismatch-stored')),
            )
            .data,
        _wrongFingerprint,
      );
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const Key('hostkey-mismatch-offered')),
            )
            .data,
        offered,
      );
      await tester.tap(find.byKey(const Key('hostkey-mismatch-forget')));
      await tester.pump(const Duration(milliseconds: 300));

      // 4. The reconnect reaches the ORDINARY first-contact prompt, showing the
      // offered key, and nothing is trusted until the user accepts.
      var prompt = false;
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.text('Trust + connect').evaluate().isNotEmpty) {
          prompt = true;
          break;
        }
      }
      expect(prompt, isTrue, reason: 'forget did not lead to the trust prompt');
      final pending = entry.proxy.data.pendingHostKey;
      expect(entry.proxy.data.state, SshSessionState.awaitingHostKey);
      expect(pending?.fingerprint, offered);
      expect(find.textContaining(offered), findsWidgets);

      // 5. Accept → live shell.
      final first = await _awaitShell(
        tester,
        container,
        acceptPromptIfShown: true,
      );
      expect(first.reachedShell, isTrue, reason: 'accept did not reach a shell');

      // 6. Disconnect + reconnect: the accepted key persisted → no prompt.
      await tester.tap(find.byKey(const Key('session-bar-open-menu')));
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('terminal-disconnect-button')));
      var backAtChooser = false;
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byKey(const Key('new-connection')).evaluate().isNotEmpty) {
          backAtChooser = true;
          break;
        }
      }
      expect(backAtChooser, isTrue, reason: 'disconnect did not reach chooser');

      await tester.tap(
        find.byKey(const Key('profile-tile-127.0.0.1:2222:testuser')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final second = await _awaitShell(
        tester,
        container,
        acceptPromptIfShown: false,
      );
      expect(second.reachedShell, isTrue, reason: 'reconnect reached no shell');
      expect(
        second.sawPrompt,
        isFalse,
        reason: 'the re-trusted key must persist: reconnect is silent',
      );
    },
  );
}
