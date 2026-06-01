// On-emulator TMUX SCROLLBACK smoke (#617).
//
// The device bug: a vertical touch-drag inside a tmux session (mouse mode ON
// server-side) does NOT scroll back through tmux history, even though the same
// session scrolls fine in the PWA. tmux runs in the ALTERNATE screen buffer, so
// scrollback is driven by xterm.dart forwarding wheel SGR reports to the PTY —
// NOT by xterm's own scrollback Scrollable.
//
// This test connects, starts tmux with `mouse on`, fills the screen with
// numbered lines, then performs a vertical drag on the TerminalView and asserts
// that tmux entered copy-mode + scrolled back (the visible buffer changes to
// show OLDER lines). It also logs the diagnostic state (mouseMode,
// isUsingAltBuffer) at drag time so an A-vs-B root cause can be read off the
// device log.
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).

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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('vertical drag in a tmux session scrolls back through history', (
    tester,
  ) async {
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
    final terminal = entry!.terminal;

    // Capture the exact bytes the UI sends to the PTY (terminal keystrokes /
    // wheel reports). sessions.dart wires terminal.onOutput → proxy.sendInput;
    // we wrap it so the drag's emitted wheel SGR is observable on the device
    // log without changing behaviour.
    final sentToPty = <int>[];
    final origOnOutput = terminal.onOutput;
    terminal.onOutput = (data) {
      sentToPty.addAll(utf8.encode(data));
      origOnOutput?.call(data);
    };
    addTearDown(() => terminal.onOutput = origOnOutput);

    // Wait for the shell prompt.
    final out = <int>[];
    final sub = entry.proxy.output.listen(out.addAll);
    addTearDown(sub.cancel);
    for (var i = 0; i < 40 && out.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(out.isNotEmpty, isTrue, reason: 'no shell prompt — dead PTY');

    // Start tmux WITH mouse on, fill the visible screen + scrollback with
    // numbered lines. `\; new -s t` enables mouse globally then opens a session
    // in the alternate buffer.
    entry.proxy.sendInput(
      Uint8List.fromList(
        utf8.encode(
          "tmux kill-server 2>/dev/null; tmux set -g mouse on \\; new -s t\n",
        ),
      ),
    );
    // Give tmux time to take over the alternate buffer + send mode-enable seqs.
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (terminal.isUsingAltBuffer) break;
    }
    // Generate 200 lines so there is real scrollback to page through.
    entry.proxy.sendInput(Uint8List.fromList(utf8.encode('seq 1 200\n')));
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    // ── DIAGNOSTIC: read the decisive A-vs-B state at drag time. ────────────
    // (A) mouseMode==none → tmux's ?1002h/?1006h never parsed/applied.
    // (B) mouseMode is upDownScroll* (good) → look at whether the drag emits
    //     wheel bytes; if not, the drag isn't reaching xterm's InfiniteScroll.
    debugPrint('CTRACE617 isUsingAltBuffer=${terminal.isUsingAltBuffer}');
    debugPrint('CTRACE617 mouseMode=${terminal.mouseMode}');

    // Snapshot the visible buffer BEFORE the drag (bottom of history: the
    // tail of `seq` output, e.g. "200").
    String visibleText() {
      final b = terminal.buffer;
      final sb = StringBuffer();
      for (var y = 0; y < terminal.viewHeight; y++) {
        sb.writeln(
          b.lines[b.height - terminal.viewHeight + y].toString().trimRight(),
        );
      }
      return sb.toString();
    }

    final before = visibleText();
    debugPrint('CTRACE617 before-drag tail:\n$before');

    sentToPty.clear();

    // Perform a vertical drag DOWNWARD on the terminal — in tmux a wheel-up
    // (drag content down) enters copy-mode and pages BACK through history.
    final termFinder = find.byKey(Key('terminal-view-${entry.id}'));
    expect(termFinder, findsOneWidget);
    final center = tester.getCenter(termFinder);
    // Drag down by ~10 lines worth of pixels to trigger several wheel events.
    await tester.dragFrom(center, const Offset(0, 300));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    debugPrint(
      'CTRACE617 bytes-sent-on-drag='
      '${sentToPty.map((b) => b).toList()}',
    );
    debugPrint(
      'CTRACE617 bytes-sent-on-drag-ascii='
      '${utf8.decode(sentToPty, allowMalformed: true).replaceAll('\x1b', 'ESC')}',
    );

    final after = visibleText();
    debugPrint('CTRACE617 after-drag tail:\n$after');

    // ACCEPTANCE: scrollback moved — the visible content changed (tmux is now
    // showing OLDER lines / a copy-mode banner). If mouseMode were none and no
    // wheel bytes were sent, `after == before` and this fails (documenting B/A).
    expect(
      after != before,
      isTrue,
      reason:
          'tmux scrollback did NOT move on a vertical drag — mouseMode='
          '${terminal.mouseMode}, alt=${terminal.isUsingAltBuffer}, '
          'bytes sent=${sentToPty.length}',
    );
  });
}
