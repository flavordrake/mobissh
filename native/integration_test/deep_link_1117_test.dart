// #1142 (PR D of #1117) — `mobissh://` deep links on the emulator, real SSH.
//
// docs/deep-link-intents.md §12 A7–A9 (+ R12 / R26). A10/R20 (Back returns to
// the caller) needs a REAL Android intent from a caller task, which `flutter
// test` on the device cannot issue — that half lives in
// scripts/deep-link-acceptance.sh (`adb shell am start -a VIEW -d`).
//
// Delivery seam: `linkIntentSourceProvider` (PR C). The fake is a plain
// (non-broadcast) StreamController, so a link emitted before the app's
// `_initLinks` subscribes is buffered and replayed on first listen — exactly
// how app_links replays the cold-start link. Every link below takes the same
// `ConnectLinkRouter.deliver` path production takes for cold AND warm.
//
// One test, sequential STATE TRANSITIONS on one saved profile
// (127.0.0.1:2222:testuser, credential seeded through the stores — the same
// shape "Save & connect" persists — with linkAutoConnect=true, which tests may
// seed directly; the only in-app setter is the R12 "Always allow" answer).
//   A9    FIRST connect on the fresh install (host-key trust lives in the task
//         isolate's own prefs, so the only reliable "unknown key" state is a
//         fresh install) + link → "Trust + connect" prompt (R15, not bypassed
//         by linkAutoConnect) → accept → shell. Disconnect.
//   A7b   linkAutoConnect=false + link → R12 dialog shown → "Connect once"
//         → shell; profile STAYS linkAutoConnect=false. Disconnect.
//   A7    linkAutoConnect=true + link → NO dialog, NO TOFU, terminal, shell bytes.
//   A8    same link while that session is live → session count does not grow,
//         active id unchanged (R17 focus). Disconnect.
//   A9b   `claude=x` link → `link-rejected-banner` visible, zero sessions (R26/R27).
//
// NOTE: run via `scripts/native-connect-test.sh integration_test/deep_link_1117_test.dart`.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/services/session_attention_notification.dart';
import 'package:mobissh/state/link_providers.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/storage/profiles_store.dart';

const _link = 'mobissh://connect?host=127.0.0.1&port=2222&user=testuser';
const _rejectedLink = 'mobissh://connect?host=127.0.0.1&claude=x';
const _identity = '127.0.0.1:2222:testuser';
const _vaultId = 'deep-link-1142-testuser';
final _confirmDialog = find.byKey(const Key('link-confirm-dialog'));
final _trustPrompt = find.text('Trust + connect');

class _FakeLinkSource implements LinkIntentSource {
  final StreamController<String> controller = StreamController<String>();
  @override
  Stream<String> get links => controller.stream;
}

/// Poll until the terminal mounts AND the shell streams bytes. Records whether
/// the R12 confirm dialog and the TOFU prompt were seen on the way; taps the
/// requested one when asked.
Future<({bool reachedShell, bool sawConfirm, bool sawTrust})> _awaitShell(
  WidgetTester tester,
  ProviderContainer container, {
  bool tapConnectOnce = false,
  bool acceptTrust = false,
}) async {
  var connected = false;
  var sawConfirm = false;
  var sawTrust = false;
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (_confirmDialog.evaluate().isNotEmpty) {
      sawConfirm = true;
      if (tapConnectOnce) {
        await tester.tap(find.byKey(const Key('link-confirm-once')));
        await tester.pump(const Duration(milliseconds: 300));
      }
    }
    if (_trustPrompt.evaluate().isNotEmpty) {
      sawTrust = true;
      if (acceptTrust) {
        await tester.tap(_trustPrompt.first);
        await tester.pump(const Duration(milliseconds: 300));
      }
    }
    if (find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty) {
      connected = true;
      break;
    }
  }
  if (!connected) {
    return (reachedShell: false, sawConfirm: sawConfirm, sawTrust: sawTrust);
  }
  final entry = container.read(sessionsProvider).active;
  if (entry == null) {
    return (reachedShell: false, sawConfirm: sawConfirm, sawTrust: sawTrust);
  }
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
  return (reachedShell: gotBytes, sawConfirm: sawConfirm, sawTrust: sawTrust);
}

/// Session menu → Disconnect → wait for the chooser (#607 menu placement).
Future<void> _disconnect(WidgetTester tester) async {
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
  expect(backAtChooser, isTrue, reason: 'disconnect did not return to chooser');
}

/// Flip `linkAutoConnect` on the saved profile through the store, keeping its
/// vault reference.
Future<void> _setAutoConnect(ProviderContainer container, bool value) async {
  final store = container.read(profilesStoreProvider);
  final saved = (await store.load()).firstWhere(
    (p) => p.identityKey == _identity,
  );
  await store.upsert(saved.copyWith(linkAutoConnect: value));
  container.invalidate(savedProfilesProvider);
}

Future<bool> _autoConnectOf(ProviderContainer container) async {
  final profiles = await container.read(profilesStoreProvider).load();
  return profiles.firstWhere((p) => p.identityKey == _identity).linkAutoConnect;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mobissh://connect link: A9 TOFU, A7b confirm once, A7 cold '
      'auto-allow, A8 warm focus, A9b rejected (#1142)', (tester) async {
    FlutterForegroundTask.initCommunicationPort();
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final source = _FakeLinkSource();
    final container = ProviderContainer(
      overrides: [
        linkIntentSourceProvider.overrideWithValue(source),
        // In-memory pending record: a stale FFT record from a prior run must
        // not be consumed at boot as a phantom link.
        linkPendingStoreProvider.overrideWithValue(MapKeyValueStore()),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(source.controller.close);

    // Seed the saved, auto-allowed profile with its credential BEFORE boot so
    // the first link is the cold-start delivery the router sees in production.
    await container
        .read(secretsStoreProvider)
        .write(_vaultId, <String, Object?>{'password': 'testpass'});
    await container.read(profilesStoreProvider).upsert(SavedProfile(
      title: 'test-sshd',
      host: '127.0.0.1',
      port: 2222,
      username: 'testuser',
      authType: 'password',
      vaultId: _vaultId,
      linkAutoConnect: true,
    ));
    source.controller.add(_link);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MobisshApp(),
      ),
    );

    // A9 (R15): cold-start link to an auto-allowed profile whose host key is
    // unknown (fresh install) stops at TOFU — the router never bypasses it.
    var promptShown = false;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (_trustPrompt.evaluate().isNotEmpty) {
        promptShown = true;
        break;
      }
      expect(find.byKey(const Key('session-menu-button')), findsNothing,
          reason: 'A9: router bypassed TOFU — terminal mounted without a prompt');
    }
    expect(promptShown, isTrue, reason: 'A9: no "Trust + connect" prompt');
    expect(_confirmDialog, findsNothing, reason: 'A9: auto-allowed must not confirm');
    final tofu = await _awaitShell(tester, container, acceptTrust: true);
    expect(tofu.reachedShell, isTrue, reason: 'A9: accept did not reach shell');
    expect(container.read(sessionsProvider).entries.length, 1);
    await _disconnect(tester);
    expect(container.read(sessionsProvider).entries, isEmpty);

    // A7b (R12): a not-yet-allowed profile confirms; "Connect once" connects
    // and leaves linkAutoConnect false.
    await _setAutoConnect(container, false);
    source.controller.add(_link);
    final once = await _awaitShell(tester, container, tapConnectOnce: true);
    expect(once.sawConfirm, isTrue,
        reason: 'A7b: linkAutoConnect=false must show the R12 confirm dialog');
    expect(once.reachedShell, isTrue, reason: 'A7b: Connect once did not reach shell');
    expect(once.sawTrust, isFalse, reason: 'A7b: trusted host re-prompted TOFU');
    expect(await _autoConnectOf(container), isFalse,
        reason: 'A7b: Connect once must not persist linkAutoConnect');
    await _disconnect(tester);

    // A7: auto-allowed profile + link → NO prompt, terminal, shell bytes.
    await _setAutoConnect(container, true);
    source.controller.add(_link);
    final cold = await _awaitShell(tester, container);
    expect(cold.sawConfirm, isFalse,
        reason: 'A7: auto-allowed profile must not show the confirm dialog');
    expect(cold.sawTrust, isFalse, reason: 'A7: trusted host re-prompted TOFU');
    expect(cold.reachedShell, isTrue, reason: 'A7: link connect did not reach shell');
    expect(_confirmDialog, findsNothing);
    final liveId = container.read(sessionsProvider).activeId;
    expect(liveId, isNotNull);
    expect(container.read(sessionsProvider).entries.length, 1);

    // A8 (R17): warm delivery with that session live focuses it; no growth.
    source.controller.add(_link);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(_confirmDialog, findsNothing, reason: 'A8: warm link must not confirm');
    expect(container.read(sessionsProvider).entries.length, 1,
        reason: 'A8: warm link grew the session count');
    expect(container.read(sessionsProvider).activeId, liveId,
        reason: 'A8: warm link changed the active session');
    expect(find.byKey(const Key('session-menu-button')), findsOneWidget,
        reason: 'A8: terminal must still be showing');
    await _disconnect(tester);

    // A9b (R26/R27): a rejected link shows the banner and creates nothing.
    source.controller.add(_rejectedLink);
    var sawBanner = false;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.byKey(const Key('link-rejected-banner')).evaluate().isNotEmpty) {
        sawBanner = true;
        break;
      }
    }
    expect(sawBanner, isTrue, reason: 'A9b: rejected link must show the banner');
    expect(container.read(sessionsProvider).entries, isEmpty,
        reason: 'A9b: rejected link created a session');
    expect(_confirmDialog, findsNothing);
    expect(await _autoConnectOf(container), isTrue,
        reason: 'A9b: rejected link must not touch linkAutoConnect');
  });
}
