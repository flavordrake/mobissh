// #1242 S1 — `mobissh://connect?…&tmux=<S>&window=@N&pane=%N` lands on an
// exact tmux window and pane of a session the owner attached BY HAND, on the
// emulator, real SSH (docs/deep-link-intents.md R6a, R22d, R22e, A18).
//
// Setup (run FIRST): scripts/deep-link-pane-1242-setup.sh
// Teardown (always): scripts/deep-link-pane-1242-teardown.sh
//
// Fixture (the owner's shell env, `feedback_reproduce_owner_shell_env`): tmux
// session `p1242` on test-sshd with window `alpha` (one pane, current) and
// window `beta` with two panes. The app is connected with a PLAIN link (no
// verb), then THIS TEST types `tmux attach` into the PTY — so the app never
// attached anything and `InitialCommandRunner.tmuxAttachedTo` is null: today
// that is the R23 dialog path. A second session `q1242` is created over the
// test's own exec connection. The oracle for every assertion is that same
// separate exec connection (never the PTY, never the app's own code).
//
// One test, sequential transitions on one saved, auto-allowed profile
// (127.0.0.1:2222:testuser):
//   land      `window=@beta&pane=%beta1` → the session is on beta, pane 1; no
//             R23 dialog, no confirm; sendNow stays 0.
//   stale     `window=@9999` → the neutral notice; nothing moved.
//   mismatch  `window=<a q1242 window id>` with `tmux=p1242` → the notice;
//             nothing moved; q1242's pane id likewise.
//   switch    `tmux=q1242&window=@q` → OUR client (found by the tty lookup)
//             is switched to q1242; no dialog.
// Throughout, the PTY's output never carries `select-window`, `select-pane`
// or `switch-client`: they all ran over exec. (`%` in a link is encoded `%25`.)

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
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
const _vaultId = 'deep-link-1242-testuser';
final _runDialog = find.byKey(const Key('link-verb-run-dialog'));
final _confirmDialog = find.byKey(const Key('link-confirm-dialog'));
final _trustPrompt = find.text('Trust + connect');

class _FakeLinkSource implements LinkIntentSource {
  final StreamController<String> controller = StreamController<String>();
  @override
  Stream<String> get links => controller.stream;
}

/// The oracle: one throwaway exec connection per call, straight to test-sshd.
Future<String> _serverExec(String cmd) async {
  final c = SSHClient(
    await SSHSocket.connect('127.0.0.1', 2222),
    username: 'testuser',
    onPasswordRequest: () => 'testpass',
  );
  try {
    return utf8.decode(await c.run(cmd)).trim();
  } finally {
    c.close();
  }
}

/// `<window_id> <pane_id>` the session `s` is on right now.
Future<String> _where(String s) => _serverExec(
    "tmux display-message -p -t '=$s:' '#{window_id} #{pane_id}'");

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('deep link window=@N&pane=%N lands on a hand-attached tmux '
      '(#1242)', (tester) async {
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

    // Fixture ids, from the server (the setup script fixes none).
    final panes = (await _serverExec(
            "tmux list-panes -a -F 'P #{session_name} #{window_name} "
            "#{window_id} #{pane_id} #{pane_index}'"))
        .split('\n')
        .where((l) => l.startsWith('P p1242 '))
        .map((l) => l.split(' '))
        .toList();
    final beta1 = panes.firstWhere((p) => p[2] == 'beta' && p[5] == '1');
    final betaWin = beta1[3];
    final betaPane = beta1[4];
    final alpha0 = panes.firstWhere((p) => p[2] == 'alpha');
    expect('${alpha0[3]} ${alpha0[4]}', await _where('p1242'),
        reason: 'fixture: p1242 must start on alpha');

    await _serverExec('tmux new-session -d -s q1242 -n qwin');
    final q = (await _serverExec(
            "tmux list-panes -t '=q1242' -F '#{window_id} #{pane_id}'"))
        .split(' ');
    final qWin = q[0];
    final qPane = q[1];

    source.controller.add(_base); // a PLAIN connect: no verb, nothing typed
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MobisshApp(),
      ),
    );

    final out = <int>[];
    StreamSubscription<Uint8List>? outSub;
    var connected = false;
    for (var i = 0; i < 90; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      final active = container.read(sessionsProvider).active;
      if (active != null && outSub == null) {
        outSub = active.proxy.output.listen(out.addAll);
      }
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
    expect(connected, isTrue, reason: 'plain link did not reach the shell');

    final entry = container.read(sessionsProvider).active!;
    final runner = container.read(initialCommandRunnerProvider);

    // Shell-ready sync: only the shell's evaluation prints 42 (the echo of the
    // typed line reads `$((6*7))`). Bounded poll, re-typed (#1178).
    var shellUp = false;
    for (var attempt = 0; attempt < 6 && !shellUp; attempt++) {
      final from = out.length;
      entry.proxy.sendInput(Uint8List.fromList(utf8.encode('echo R=\$((6*7))=\n')));
      for (var i = 0; i < 6 && !shellUp; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        shellUp = utf8
            .decode(out.sublist(from), allowMalformed: true)
            .contains('R=42=');
      }
    }
    expect(shellUp, isTrue, reason: 'the PTY shell never answered');

    // BY HAND: the test types the attach; the app did not.
    entry.proxy.sendInput(Uint8List.fromList(utf8.encode('tmux attach -t =p1242\n')));
    var attached = false;
    for (var i = 0; i < 30 && !attached; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      attached = (await _serverExec(
              "tmux list-clients -F 'K #{session_name}'"))
          .contains('K p1242');
    }
    expect(attached, isTrue, reason: 'hand attach to p1242 never showed up');
    expect(runner.tmuxAttachedTo(entry.id), isNull,
        reason: 'the app must not know about a hand-typed attach');
    final typedSoFar = out.length;

    Future<bool> sawDialog(int slices) async {
      var seen = false;
      for (var i = 0; i < slices; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (_runDialog.evaluate().isNotEmpty ||
            _confirmDialog.evaluate().isNotEmpty) {
          seen = true;
        }
      }
      return seen;
    }

    // land: beta, pane 1, by id.
    source.controller.add(
        '$_base&tmux=p1242&window=$betaWin&pane=${Uri.encodeComponent(betaPane)}');
    var landed = false;
    var dialog = false;
    for (var i = 0; i < 24 && !landed; i++) {
      dialog = await sawDialog(1) || dialog;
      landed = await _where('p1242') == '$betaWin $betaPane';
    }
    expect(landed, isTrue, reason: 'land: link did not select beta pane 1');
    expect(dialog, isFalse, reason: 'land: nothing is typed, so no dialog');
    expect(runner.sendNowCount(entry.id), 0, reason: 'land: nothing sent');
    expect(container.read(sessionsProvider).entries.length, 1);

    // stale id: notice, nothing moved.
    source.controller.add('$_base&tmux=p1242&window=@9999');
    final staleNotice = find.text('No window "@9999" in tmux session p1242');
    var sawStale = false;
    for (var i = 0; i < 24 && !sawStale; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      sawStale = staleNotice.evaluate().isNotEmpty;
    }
    expect(sawStale, isTrue, reason: 'stale: no notice shown');
    expect(await _where('p1242'), '$betaWin $betaPane',
        reason: 'stale: the session moved');

    // mismatch: a window id of ANOTHER session, then another session's pane.
    source.controller.add('$_base&tmux=p1242&window=$qWin');
    final mismatchNotice = find.text('No window "$qWin" in tmux session p1242');
    var sawMismatch = false;
    for (var i = 0; i < 24 && !sawMismatch; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      sawMismatch = mismatchNotice.evaluate().isNotEmpty;
    }
    expect(sawMismatch, isTrue, reason: 'mismatch: no notice shown');
    source.controller.add(
        '$_base&tmux=p1242&pane=${Uri.encodeComponent(qPane)}');
    final paneNotice = find.text('No pane "$qPane" in tmux session p1242');
    var sawPane = false;
    for (var i = 0; i < 24 && !sawPane; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      sawPane = paneNotice.evaluate().isNotEmpty;
    }
    expect(sawPane, isTrue, reason: 'mismatch: no pane notice shown');
    expect(await _where('p1242'), '$betaWin $betaPane',
        reason: 'mismatch: p1242 moved');
    expect(await _serverExec("tmux list-clients -F 'K #{session_name}'"),
        contains('K p1242'),
        reason: 'mismatch: our client left p1242');

    // switch: our client follows the link to another session.
    source.controller.add('$_base&tmux=q1242&window=$qWin');
    var switched = false;
    dialog = false;
    for (var i = 0; i < 24 && !switched; i++) {
      dialog = await sawDialog(1) || dialog;
      switched = (await _serverExec(
              "tmux list-clients -F 'K #{session_name}'"))
          .contains('K q1242');
    }
    expect(switched, isTrue, reason: 'switch: client never moved to q1242');
    expect(dialog, isFalse, reason: 'switch: no dialog');
    expect(await _where('q1242'), '$qWin $qPane');
    expect(runner.sendNowCount(entry.id), 0);

    // None of it went through the terminal.
    final ptyText =
        utf8.decode(out.sublist(typedSoFar), allowMalformed: true);
    for (final word in ['select-window', 'select-pane', 'switch-client']) {
      expect(ptyText.contains(word), isFalse,
          reason: '$word reached the PTY — it must run over exec');
    }
  });
}
