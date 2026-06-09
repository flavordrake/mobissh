// On-emulator ATTENTION-SIGNAL MEASUREMENT test (#840, Slice 1) — THE EXPERIMENT.
//
// Slice 1 ships a detector ONLY (no notification). The open empirical question
// is: of the four in-band signal forms (bare BEL, OSC 9, OSC 777, the
// notify-bell `# <message>` line), WHICH ones actually reach the MobiSSH PTY
// stream, and does tmux forward/swallow them differently when the signal is
// emitted in the ACTIVE vs a BACKGROUND tmux window?
//
// This test emits each form over a live session in THREE positions:
//   (a) plain interactive shell (no tmux)
//   (b) inside `tmux`, signal emitted in the ACTIVE window
//   (c) inside `tmux`, signal emitted in a BACKGROUND window (we create a 2nd
//       window, emit there, and STAY focused on window 0)
// then reads back the task-isolate `clifecycle` ring (forwarded to the UI ring,
// #766) to see whether the AttentionSignalScanner fired, and prints a findings
// table.
//
// A "background-window bell/text NOT received" result is a VALID, expected
// finding — tmux's bell-action / window isolation may legitimately swallow it.
// This test does NOT assert every cell is detected; it RECORDS what was, and
// only hard-fails if NOTHING is detected even in the plain-shell baseline (which
// would mean the detector or its wiring is dead).
//
// tmux may be ABSENT on the Alpine test-sshd target. We try to install it over
// the live session (`apk add tmux`). If that fails, the tmux cases are reported
// as "tmux-unavailable" (NOT silently skipped) and only the plain-shell cases
// run.
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).

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
import 'package:mobissh/diagnostics/connect_trace.dart';

import 'support/connect_helpers.dart';

/// The four signal forms under test, with the shell command that emits each.
/// `printf` is used over the live PTY so the bytes hit the stream verbatim.
class _Form {
  const _Form(this.label, this.emit, this.expectText);
  final String label;

  /// The shell snippet (no trailing newline) that emits the signal.
  final String emit;

  /// A substring expected in the parsed signal text, or null for the bare bell.
  final String? expectText;
}

const _msg = 'Claude is waiting';

const _forms = <_Form>[
  _Form('bell', "printf '\\a'", null),
  _Form('osc9', "printf '\\033]9;$_msg\\007'", _msg),
  _Form('osc777', "printf '\\033]777;notify;MobiSSH;$_msg\\007'", _msg),
  // The exact notify-bell.sh pattern: CR, clear-to-EOL, "# message", BEL.
  _Form('hookLine', "printf '\\r\\033[K# $_msg\\a'", _msg),
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('measure which attention-signal forms reach the scanner '
      'across plain / tmux-active / tmux-background positions', (tester) async {
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

    await adhocPasswordConnect(
      tester,
      host: '127.0.0.1',
      port: '2222',
      user: 'testuser',
      pass: 'testpass',
    );

    // Reach the terminal screen, accepting the host-key prompt if shown.
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
    expect(connected, isTrue, reason: 'never reached the terminal screen');

    final entry = container.read(sessionsProvider).active;
    expect(entry, isNotNull, reason: 'no active session after connect');
    final proxy = entry!.proxy;

    final out = <int>[];
    final sub = proxy.output.listen(out.addAll);
    addTearDown(sub.cancel);

    Future<void> settle(int pumps) async {
      for (var i = 0; i < pumps; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
    }

    void send(String cmd) =>
        proxy.sendInput(Uint8List.fromList(utf8.encode(cmd)));

    // Wait for the shell prompt (proves the PTY is live).
    for (var i = 0; i < 40 && out.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(out.isNotEmpty, isTrue, reason: 'no shell prompt — dead PTY');

    // The dedup cooldown is 2s per scanner; we wait >2.5s between emissions so
    // each form is counted independently and a prior emission can't swallow the
    // next under the cooldown.
    Future<void> cooldown() => settle(12); // 12 * 250ms = 3s

    // Count `attention:` lines for [kind] currently in the lifecycle ring.
    int countKind(String kind, int sinceLen) {
      final ring = lifecycleLogSnapshot();
      var n = 0;
      for (var i = sinceLen; i < ring.length; i++) {
        if (ring[i].contains('[attention]') && ring[i].contains(' $kind ')) {
          n++;
        }
      }
      return n;
    }

    // result[position][formLabel] = detected?
    final results = <String, Map<String, bool>>{
      'plain': {},
      'tmux-active': {},
      'tmux-bg': {},
    };
    var tmuxStatus = 'not-attempted';

    Future<bool> emitAndDetect(String emitCmd, String kind) async {
      await cooldown();
      final before = lifecycleLogSnapshot().length;
      send('$emitCmd\n');
      // Give the byte round-trip + scanner time to log.
      await settle(16); // 4s
      final got = countKind(kind, before) > 0;
      return got;
    }

    // ── (a) PLAIN SHELL ────────────────────────────────────────────────────
    for (final f in _forms) {
      results['plain']![f.label] = await emitAndDetect(f.emit, f.label);
    }

    // ── Provision tmux (best-effort) ────────────────────────────────────────
    // Check for tmux; install via apk if missing. The test-sshd is Alpine.
    send('command -v tmux >/dev/null 2>&1 && echo MOBISSH_TMUX_YES '
        '|| echo MOBISSH_TMUX_NO\n');
    await settle(12);
    var tmuxPresent =
        utf8.decode(out, allowMalformed: true).contains('MOBISSH_TMUX_YES');
    if (!tmuxPresent) {
      // Try to install. apk may need root; testuser may or may not have it.
      send('apk add --no-cache tmux >/dev/null 2>&1 || '
          'sudo apk add --no-cache tmux >/dev/null 2>&1; '
          'command -v tmux >/dev/null 2>&1 && echo MOBISSH_TMUX_INSTALLED '
          '|| echo MOBISSH_TMUX_FAIL\n');
      // apk fetch can be slow; allow a generous window.
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        final s = utf8.decode(out, allowMalformed: true);
        if (s.contains('MOBISSH_TMUX_INSTALLED')) {
          tmuxPresent = true;
          break;
        }
        if (s.contains('MOBISSH_TMUX_FAIL')) break;
      }
    }
    tmuxStatus = tmuxPresent ? 'available' : 'unavailable';

    if (tmuxPresent) {
      // Start a clean tmux session, mouse off (not needed). Window 0 is active.
      send('tmux kill-server 2>/dev/null; tmux new -d -s m; tmux attach -t m\n');
      await settle(20); // let tmux take the alternate buffer

      // ── (b) tmux ACTIVE window ────────────────────────────────────────────
      // We're attached to window 0; emit directly into its pane (the shell we
      // are typing into is that pane).
      for (final f in _forms) {
        results['tmux-active']![f.label] =
            await emitAndDetect(f.emit, f.label);
      }

      // ── (c) tmux BACKGROUND window ────────────────────────────────────────
      // Create window 1, send the emit command to it via `tmux send-keys -t`,
      // but STAY focused on window 0. Whether tmux forwards a background
      // window's BEL/OSC to the attached client is exactly what we measure.
      // First create the second window and immediately switch back to 0.
      send('tmux neww -t m: \\; selectw -t m:0\n');
      await settle(12);
      for (final f in _forms) {
        await cooldown();
        final before = lifecycleLogSnapshot().length;
        // send-keys to window 1 (background), literal command + Enter.
        // Escape single quotes for the tmux send-keys argument layer.
        final inner = f.emit.replaceAll("'", "'\\''");
        send("tmux send-keys -t m:1 '$inner' Enter\n");
        await settle(16);
        results['tmux-bg']![f.label] =
            countKind(f.label, before) > 0;
      }

      send('tmux kill-server 2>/dev/null\n');
      await settle(8);
    } else {
      for (final f in _forms) {
        results['tmux-active']![f.label] = false;
        results['tmux-bg']![f.label] = false;
      }
    }

    // ── FINDINGS TABLE ───────────────────────────────────────────────────────
    final sb = StringBuffer();
    sb.writeln('ATTENTION840 ===== MEASUREMENT FINDINGS (#840 Slice 1) =====');
    sb.writeln('ATTENTION840 tmux: $tmuxStatus');
    sb.writeln('ATTENTION840 form      | plain | tmux-active | tmux-bg');
    for (final f in _forms) {
      String cell(String pos) => (results[pos]![f.label] ?? false) ? 'YES' : 'no ';
      sb.writeln('ATTENTION840 ${f.label.padRight(9)} |  ${cell('plain')}  '
          '|     ${cell('tmux-active')}     |   ${cell('tmux-bg')}');
    }
    sb.writeln('ATTENTION840 (lifecycle ring tail follows)');
    for (final line in lifecycleLogSnapshot()) {
      if (line.contains('[attention]')) sb.writeln('ATTENTION840 $line');
    }
    debugPrint(sb.toString());

    // ── ACCEPTANCE (minimal) ─────────────────────────────────────────────────
    // The detector + wiring must be ALIVE: at least one form must be detected
    // in the plain-shell baseline. (We do NOT require tmux cells — those are the
    // empirical unknowns this test exists to measure.)
    final anyPlain = _forms.any((f) => results['plain']![f.label] == true);
    expect(
      anyPlain,
      isTrue,
      reason:
          'NO attention signal detected even in the plain shell — the scanner '
          'or its session_host wiring is dead. Findings:\n$sb',
    );
  });
}
