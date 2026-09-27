// #1211 — `mobissh://connect?…&tmux=<session>&window=<name>` on the emulator,
// real SSH (docs/deep-link-intents.md R22a–R22c, A15).
//
// Setup (run FIRST): scripts/deep-link-window-1211-setup.sh
//
// The fixture pre-creates tmux session `w1211` on test-sshd with windows
// `alpha` (current) and `beta`. One test, sequential state transitions on one
// saved, auto-allowed profile (127.0.0.1:2222:testuser):
//   fresh   `tmux=w1211&window=beta` on a fresh install → TOFU accept → shell
//           attached to w1211 AND on window beta (asserted with
//           `tmux display-message -p '#W'` typed by the TEST over the same
//           session). The PTY never carries `select-window`: the app selects
//           over a separate exec channel. A fresh connect arms, never sendNow.
//   live    `window=alpha` while that session is live and link-attached to
//           w1211 → no R23 run dialog, no second attach (sendNow stays 0),
//           session count unchanged, window now alpha.
//   nomatch `window=nope` → the neutral notice, window still alpha, and w1211
//           still has exactly two windows (nothing created).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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

const _base = 'mobissh://connect?host=127.0.0.1&port=2222&user=testuser';
const _vaultId = 'deep-link-1211-testuser';
final _runDialog = find.byKey(const Key('link-verb-run-dialog'));
final _confirmDialog = find.byKey(const Key('link-confirm-dialog'));
final _trustPrompt = find.text('Trust + connect');

String _windowLink(String window) => '$_base&tmux=w1211&window=$window';

class _FakeLinkSource implements LinkIntentSource {
  final StreamController<String> controller = StreamController<String>();
  @override
  Stream<String> get links => controller.stream;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('deep link window= selects the tmux window over exec (#1211)',
      (tester) async {
    FlutterForegroundTask.initCommunicationPort();
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final source = _FakeLinkSource();
    final container = ProviderContainer(
      overrides: [
        linkIntentSourceProvider.overrideWithValue(source),
        linkPendingStoreProvider.overrideWithValue(MapKeyValueStore()),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(source.controller.close);

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
    source.controller.add(_windowLink('beta'));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MobisshApp(),
      ),
    );

    // Capture the PTY output from the moment the session exists, so any
    // `select-window` that went through the terminal would be seen.
    final out = <int>[];
    StreamSubscription<Uint8List>? outSub;
    var sawConfirm = false;
    var connected = false;
    for (var i = 0; i < 90; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      final active = container.read(sessionsProvider).active;
      if (active != null && outSub == null) {
        outSub = active.proxy.output.listen(out.addAll);
      }
      if (_confirmDialog.evaluate().isNotEmpty) sawConfirm = true;
      if (_trustPrompt.evaluate().isNotEmpty) {
        await tester.tap(_trustPrompt.first);
        await tester.pump(const Duration(milliseconds: 300));
      }
      if (find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty &&
          out.isNotEmpty) {
        connected = true;
        break;
      }
    }
    addTearDown(() => outSub?.cancel());
    expect(connected, isTrue, reason: 'fresh: window link did not reach shell');
    expect(sawConfirm, isFalse,
        reason: 'fresh: auto-allowed profile must not confirm');

    final entry = container.read(sessionsProvider).active!;
    final runner = container.read(initialCommandRunnerProvider);
    expect(runner.hasFired(entry.id), isTrue,
        reason: 'fresh: attach verb did not fire on shell-ready');
    expect(runner.sendNowCount(entry.id), 0,
        reason: 'fresh: a fresh connect must arm, never sendNow');
    expect(await _tmuxAnswer(tester, entry, out, 'S1', '#S', 'w1211'), isTrue,
        reason: 'fresh: shell is not attached to tmux session w1211');
    expect(await _tmuxAnswer(tester, entry, out, 'W1', '#W', 'beta'), isTrue,
        reason: 'fresh: window=beta did not select window beta');
    expect(runner.tmuxAttachedTo(entry.id), 'w1211');

    // live: same tmux session, another window → select only.
    source.controller.add(_windowLink('alpha'));
    var sawRun = false;
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (_runDialog.evaluate().isNotEmpty) sawRun = true;
    }
    expect(sawRun, isFalse,
        reason: 'live: attached session must select without the R23 dialog');
    expect(runner.sendNowCount(entry.id), 0,
        reason: 'live: no second attach may be sent');
    expect(container.read(sessionsProvider).entries.length, 1,
        reason: 'live: window link grew the session count');
    expect(container.read(sessionsProvider).activeId, entry.id);
    expect(await _tmuxAnswer(tester, entry, out, 'W2', '#W', 'alpha'), isTrue,
        reason: 'live: window=alpha did not select window alpha');

    // nomatch: neutral notice, nothing created, nothing changed.
    source.controller.add(_windowLink('nope'));
    final notice = find.text('No window "nope" in tmux session w1211');
    var sawNotice = false;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (notice.evaluate().isNotEmpty) {
        sawNotice = true;
        break;
      }
    }
    expect(sawNotice, isTrue, reason: 'nomatch: no notice shown');
    expect(_runDialog, findsNothing);
    expect(runner.sendNowCount(entry.id), 0);
    expect(await _tmuxAnswer(tester, entry, out, 'W3', '#W', 'alpha'), isTrue,
        reason: 'nomatch: the current window changed');
    expect(
        await _tmuxAnswer(
            tester, entry, out, 'N1', '#{session_windows}', '2'),
        isTrue,
        reason: 'nomatch: a window was created');

    // The selection never went through the terminal.
    expect(utf8.decode(out, allowMalformed: true).contains('select-window'),
        isFalse,
        reason: 'select-window reached the PTY — it must run over exec');
  });
}

/// Ask tmux, through the SAME session, for [format] (typed by the test, not
/// the app) and wait for `<tag>=<want>=`. The echo of the typed line reads
/// `<tag>=<format>=`, so only tmux's answer can match. Re-typed a few times:
/// the tmux client may still be starting.
Future<bool> _tmuxAnswer(
  WidgetTester tester,
  SessionEntry entry,
  List<int> out,
  String tag,
  String format,
  String want,
) async {
  for (var attempt = 0; attempt < 3; attempt++) {
    final from = out.length;
    entry.proxy.sendInput(Uint8List.fromList(
      utf8.encode("tmux display-message -p '$tag=$format='\n"),
    ));
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      final text = utf8.decode(out.sublist(from), allowMalformed: true);
      if (text.contains('$tag=$want=')) return true;
    }
  }
  return false;
}
