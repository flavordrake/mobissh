// Unit tests for the tmux control-mode RENDER channel — Part B (#909, epic #906).
// PURE: no Flutter widget, no SSH, no I/O. Covers the render demux + the
// refresh-client -C resize primitive + the trailing-edge final-size contract.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/terminal/tmux_control_channel.dart';

Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));
String text(Uint8List b) => utf8.decode(b, allowMalformed: true);

void main() {
  group('entry + resize commands', () {
    test('entryCommand enters control mode via tmux -CC', () {
      final cmd = text(TmuxControlChannel.entryCommand);
      expect(cmd, startsWith('tmux -CC'));
      expect(cmd, endsWith('\n'));
    });

    test('entryCommand attaches the EXISTING session, create-fallback (#906)', () {
      // Owner request: control mode must match the PERSISTENT session so it
      // follows moves between mobile + laptop. `tmux -CC attach` grabs the
      // most-recent session (the same one `tmux attach` gives on the laptop);
      // the `|| new-session -A -s main` keeps it robust on a fresh host with no
      // server (a bare `attach` would fail "no sessions"). Was
      // `new-session -A -s mobissh`, which forced a SEPARATE empty session → the
      // device "zero gestures" (nothing to switch, not the owner's windows).
      expect(
        text(TmuxControlChannel.entryCommand),
        'tmux -CC attach 2>/dev/null || tmux -CC new-session -A -s main\n',
      );
      // Still safe on a host with no running tmux — the fallback CREATES one.
      expect(
        text(TmuxControlChannel.entryCommand),
        contains('new-session -A'),
        reason: 'must create-or-attach so a fresh host does not fail "no sessions"',
      );
    });

    test('resizeCommand is the refresh-client -C single resize primitive', () {
      expect(
        text(TmuxControlChannel.resizeCommand(120, 40)),
        'refresh-client -C 120,40\n',
      );
    });

    test('resizeCommand clamps non-positive dims (tmux rejects 0/negative)', () {
      expect(text(TmuxControlChannel.resizeCommand(0, -3)), 'refresh-client -C 1,1\n');
    });

    test('FINAL settled size is delivered verbatim — never dropped (#903/#905)', () {
      // The UI coalescer fires onSettled with the final size; the host turns
      // that into exactly one refresh-client -C carrying that final size.
      const finalCols = 95, finalRows = 31;
      expect(
        text(TmuxControlChannel.resizeCommand(finalCols, finalRows)),
        'refresh-client -C $finalCols,$finalRows\n',
      );
    });
  });

  group('capture-pane command builders (#906 Stage 1/2)', () {
    test('capturePaneCommand is capture-pane -p -e -J, one trailing newline', () {
      expect(
        text(TmuxControlChannel.capturePaneCommand()),
        'capture-pane -p -e -J\n',
      );
    });

    test('capturePaneRangeCommand carries -S start -E end (scroll window)', () {
      expect(
        text(TmuxControlChannel.capturePaneRangeCommand(-40, -10)),
        'capture-pane -p -e -S -40 -E -10\n',
      );
    });

    test('frameCapture returns the capture line AND registers a pending block', () {
      final ch = TmuxControlChannel();
      expect(ch.pendingCommandCount, 0);
      expect(text(ch.frameCapture()), 'capture-pane -p -e -J\n');
      expect(ch.pendingCommandCount, 1);
    });

    test('frameResize/frameControl register a (non-capture) pending block', () {
      final ch = TmuxControlChannel();
      expect(text(ch.frameResize(80, 24)), 'refresh-client -C 80,24\n');
      expect(text(ch.frameControl('next-window')), 'next-window\n');
      expect(ch.pendingCommandCount, 2);
    });
  });

  group('capture-pane response correlation → render (#906 Stage 1)', () {
    test('ATTACH (%session-changed) requests a capture', () {
      final ch = TmuxControlChannel();
      final r = ch.ingest(bytes('%session-changed \$0 main\n'));
      expect(r.captureRequested, isTrue);
    });

    test('the capture response block renders (clear + captured rows)', () {
      final ch = TmuxControlChannel();
      // Host framed a capture (registers the pending block); tmux answers with a
      // %begin…%end command-output block carrying the pane rows.
      ch.frameCapture();
      final r = ch.ingest(bytes(
        '%begin 1 7 1\nline one\nline two\n%end 1 7 1\n',
      ));
      final out = text(r.renderBytes);
      expect(out, contains('line one\r\nline two'));
      // A screen clear precedes the rows so no stale content bleeds through.
      expect(out, contains('\x1b[2J'));
    });

    test('tmux STARTUP block (no client command outstanding) does NOT render', () {
      final ch = TmuxControlChannel();
      // On entering control mode tmux emits an initial block with an EMPTY queue.
      final r = ch.ingest(bytes(
        '\x1bP1000p%begin 1 0 1\n%end 1 0 1\n',
      ));
      expect(text(r.renderBytes), isEmpty);
    });

    test('a NON-capture ack block is discarded (does not render)', () {
      final ch = TmuxControlChannel();
      ch.frameResize(80, 24); // pending: other
      final r = ch.ingest(bytes('%begin 1 3 1\nok\n%end 1 3 1\n'));
      expect(text(r.renderBytes), isEmpty);
      expect(ch.pendingCommandCount, 0);
    });

    test('FIFO order: resize ack then capture render, correlated by order', () {
      final ch = TmuxControlChannel();
      // Host sends a resize, then a capture (the switch-repaint ordering).
      ch.frameResize(80, 24);
      ch.frameCapture();
      // First block correlates to the resize (discarded)…
      final r1 = ch.ingest(bytes('%begin 1 1 1\n%end 1 1 1\n'));
      expect(text(r1.renderBytes), isEmpty);
      // …the second to the capture (rendered).
      final r2 = ch.ingest(bytes('%begin 1 2 1\nCAPTURED\n%end 1 2 1\n'));
      expect(text(r2.renderBytes), contains('CAPTURED'));
      expect(ch.pendingCommandCount, 0);
    });

    test('a %error capture block does not render (failed capture)', () {
      final ch = TmuxControlChannel();
      ch.frameCapture();
      final r = ch.ingest(bytes('%begin 1 4 1\nboom\n%error 1 4 1\n'));
      expect(text(r.renderBytes), isEmpty);
    });
  });

  group('%output → render demux', () {
    test('renders active window %output unescaped to the grid', () {
      final ch = TmuxControlChannel();
      // \110\145 = "He" (octal) interleaved with plain — only %output is escaped.
      final r = ch.ingest(bytes('%output %1 hello\\040world\n'));
      expect(text(r.renderBytes), 'hello world');
      expect(r.activeWindowChanged, isFalse);
      expect(r.exited, isFalse);
    });

    test('before any active-window signal, output renders (fail-open)', () {
      final ch = TmuxControlChannel();
      final r = ch.ingest(bytes('%output %7 boot\n'));
      expect(text(r.renderBytes), 'boot');
    });

    test('filters %output to the ACTIVE window once layout + active are known', () {
      final ch = TmuxControlChannel();
      // Two windows: @0 has pane %0, @1 has pane %1.
      ch.ingest(bytes('%layout-change @0 abcd,80x24,0,0,0\n'));
      ch.ingest(bytes('%layout-change @1 bcde,80x24,0,0,1\n'));
      // Make @0 the active window.
      ch.ingest(bytes('%session-window-changed \$0 @0\n'));
      // Output for the ACTIVE window renders; output for @1's pane is filtered.
      final active = ch.ingest(bytes('%output %0 IN-ACTIVE\n'));
      expect(text(active.renderBytes), 'IN-ACTIVE');
      final other = ch.ingest(bytes('%output %1 OFFSCREEN\n'));
      expect(text(other.renderBytes), isEmpty);
    });

    test('window switch repaints: active changes + new window output renders', () {
      final ch = TmuxControlChannel();
      ch.ingest(bytes('%layout-change @0 abcd,80x24,0,0,0\n'));
      ch.ingest(bytes('%layout-change @1 bcde,80x24,0,0,1\n'));
      ch.ingest(bytes('%session-window-changed \$0 @0\n'));
      expect(ch.activeWindowId, 0);

      // Switch to @1 — the host uses activeWindowChanged to force a redraw.
      final sw = ch.ingest(bytes('%session-window-changed \$0 @1\n'));
      expect(sw.activeWindowChanged, isTrue);
      expect(ch.activeWindowId, 1);

      // Now @1's pane renders, @0's is filtered.
      expect(text(ch.ingest(bytes('%output %1 NEWWIN\n')).renderBytes), 'NEWWIN');
      expect(ch.ingest(bytes('%output %0 OLDWIN\n')).renderBytes, isEmpty);
    });

    test('re-asserting the SAME active window is not a change (no redundant redraw)', () {
      final ch = TmuxControlChannel();
      ch.ingest(bytes('%session-window-changed \$0 @2\n'));
      final again = ch.ingest(bytes('%session-window-changed \$0 @2\n'));
      expect(again.activeWindowChanged, isFalse);
    });

    test('%exit surfaces so the host can close the session', () {
      final ch = TmuxControlChannel();
      final r = ch.ingest(bytes('%exit detached\n'));
      expect(r.exited, isTrue);
    });

    test('window-close drops the window panes (stale id cannot stay active)', () {
      final ch = TmuxControlChannel();
      ch.ingest(bytes('%layout-change @1 bcde,80x24,0,0,1\n'));
      ch.ingest(bytes('%session-window-changed \$0 @0\n'));
      ch.ingest(bytes('%window-close @1\n'));
      // %1's window is now unknown → fail-open render (not silently blanked).
      expect(text(ch.ingest(bytes('%output %1 X\n')).renderBytes), 'X');
    });

    test('chunked feed across a line boundary still renders (resilient parser)', () {
      final ch = TmuxControlChannel();
      ch.ingest(bytes('%output %1 par'));
      final r = ch.ingest(bytes('tial\n'));
      expect(text(r.renderBytes), 'partial');
    });
  });

  group('atomic control-command framing (#911 Step 1)', () {
    test('a multi-token command survives intact, terminated by ONE newline', () {
      // The Part B failure: a multi-token command (`select-window -t @1`) split
      // across the gateway and its tail hit the pane shell. The framing must keep
      // the WHOLE line together with exactly one trailing newline.
      final framed = text(TmuxControlChannel.controlCommand('select-window -t @1'));
      expect(framed, 'select-window -t @1\n');
      // No mid-line newline that would submit a partial line to tmux.
      expect('\n'.allMatches(framed).length, 1);
    });

    test('strips caller trailing newlines/whitespace to exactly one newline', () {
      expect(
        text(TmuxControlChannel.controlCommand('next-window\n')),
        'next-window\n',
      );
      expect(
        text(TmuxControlChannel.controlCommand('next-window\r\n\n')),
        'next-window\n',
      );
    });

    test('preserves interior spaces + quotes (no token splitting)', () {
      final framed =
          text(TmuxControlChannel.controlCommand('rename-window "my work"'));
      expect(framed, 'rename-window "my work"\n');
    });

    test('next/previous window command lines', () {
      expect(TmuxControlChannel.nextWindowCommand, 'next-window');
      expect(TmuxControlChannel.previousWindowCommand, 'previous-window');
    });
  });

  group('window-list tracking from notifications (#911 Step 2)', () {
    test('tracks windows in tmux index/status order from %window-add', () {
      final ch = TmuxControlChannel();
      ch.ingest(bytes('%window-add @0\n'));
      ch.ingest(bytes('%window-add @1\n'));
      ch.ingest(bytes('%window-add @2\n'));
      expect(ch.windows.map((w) => w.id).toList(), [0, 1, 2]);
    });

    test('tracks a window first seen via %layout-change (fail-open)', () {
      final ch = TmuxControlChannel();
      ch.ingest(bytes('%layout-change @5 abcd,80x24,0,0,0\n'));
      expect(ch.windows.map((w) => w.id).toList(), [5]);
    });

    test('records window names from %window-renamed', () {
      final ch = TmuxControlChannel();
      ch.ingest(bytes('%window-add @0\n'));
      ch.ingest(bytes('%window-renamed @0 editor\n'));
      expect(ch.windows.single.name, 'editor');
    });

    test('%window-close drops the window from the order', () {
      final ch = TmuxControlChannel();
      ch.ingest(bytes('%window-add @0\n'));
      ch.ingest(bytes('%window-add @1\n'));
      ch.ingest(bytes('%window-close @0\n'));
      expect(ch.windows.map((w) => w.id).toList(), [1]);
    });

    test('does not duplicate a window seen via multiple notifications', () {
      final ch = TmuxControlChannel();
      ch.ingest(bytes('%window-add @3\n'));
      ch.ingest(bytes('%layout-change @3 abcd,80x24,0,0,0\n'));
      ch.ingest(bytes('%session-window-changed \$0 @3\n'));
      expect(ch.windows.map((w) => w.id).toList(), [3]);
    });

    test('active window updates from %session-window-changed', () {
      final ch = TmuxControlChannel();
      ch.ingest(bytes('%window-add @0\n'));
      ch.ingest(bytes('%window-add @1\n'));
      final r = ch.ingest(bytes('%session-window-changed \$0 @1\n'));
      expect(r.activeWindowChanged, isTrue);
      expect(ch.activeWindowId, 1);
    });
  });

  group('status-col → window mapping (#911 Step 2)', () {
    TmuxControlChannel threeWindows() {
      final ch = TmuxControlChannel();
      ch.ingest(bytes('%window-add @0\n'));
      ch.ingest(bytes('%window-add @1\n'));
      ch.ingest(bytes('%window-add @2\n'));
      return ch;
    }

    test('partitions the status width across windows in order', () {
      final ch = threeWindows();
      // 3 windows over 90 cols → segments [1..30]=0, [31..60]=1, [61..90]=2.
      expect(ch.windowIndexForStatusCol(1, 90), 0);
      expect(ch.windowIndexForStatusCol(30, 90), 0);
      expect(ch.windowIndexForStatusCol(45, 90), 1);
      expect(ch.windowIndexForStatusCol(90, 90), 2);
    });

    test('select-window command targets the STABLE window id of the tapped seg', () {
      final ch = threeWindows();
      expect(ch.selectWindowCommandForStatusCol(5, 90), 'select-window -t @0');
      expect(ch.selectWindowCommandForStatusCol(45, 90), 'select-window -t @1');
      expect(ch.selectWindowCommandForStatusCol(85, 90), 'select-window -t @2');
    });

    test('clamps out-of-range columns into the valid window set', () {
      final ch = threeWindows();
      expect(ch.windowIndexForStatusCol(0, 90), 0);
      expect(ch.windowIndexForStatusCol(999, 90), 2);
    });

    test('null when no windows are known yet', () {
      final ch = TmuxControlChannel();
      expect(ch.windowIndexForStatusCol(5, 90), isNull);
      expect(ch.selectWindowCommandForStatusCol(5, 90), isNull);
    });

    test('select-window uses the stable id after a lower-index window closes', () {
      final ch = threeWindows();
      ch.ingest(bytes('%window-close @0\n')); // now order is [@1, @2]
      // First segment now maps to @1 (the leftmost remaining), not the gone @0.
      expect(ch.selectWindowCommandForStatusCol(5, 90), 'select-window -t @1');
      expect(ch.selectWindowCommandForStatusCol(85, 90), 'select-window -t @2');
    });
  });

  // ---- #916: refresh-client -C coalescer (kills the multi-client storm) ----
  group('RefreshClientCoalescer (#916)', () {
    // A synchronous fake scheduler: captures the pending callback (and honours
    // cancellation, so a cancelled timer's callback never fires) so the test
    // drives the "settle window elapsed" edge deterministically. Mirrors the
    // GhosttyResizeCoalescer test idiom — each submit cancels the prior timer.
    late List<_FakeTimer> armed;
    Timer fakeSchedule(Duration d, void Function() cb) {
      final t = _FakeTimer(cb);
      armed.add(t);
      return t;
    }

    void settle() {
      // The coalescer keeps exactly one live timer at a time (each submit /
      // requestRedraw cancels the prior). Fire the most-recently-armed timer
      // that is still active; a cancel() makes it inactive so nothing fires.
      for (final t in armed.reversed) {
        if (t.active) {
          t.active = false;
          t.callback();
          break;
        }
      }
    }

    setUp(() {
      armed = <_FakeTimer>[];
    });

    test('a BURST of resizes collapses to ONE settled refresh-client', () {
      final emitted = <(int, int)>[];
      final c = RefreshClientCoalescer(
        onSettled: (cols, rows) => emitted.add((cols, rows)),
        scheduleTimer: fakeSchedule,
      );
      // 5 animation-frame sizes from a keyboard toggle (58,57 → … → 58,34).
      c.submit(58, 57);
      c.submit(58, 50);
      c.submit(58, 44);
      c.submit(58, 38);
      c.submit(58, 34);
      expect(emitted, isEmpty, reason: 'nothing emits before the settle window');
      settle();
      expect(emitted, [(58, 34)], reason: 'only the FINAL settled size is sent');
      expect(c.sendCount, 1);
    });

    test('an unchanged settled size is DEDUPED (no spurious refresh-client)', () {
      final emitted = <(int, int)>[];
      final c = RefreshClientCoalescer(
        onSettled: (cols, rows) => emitted.add((cols, rows)),
        scheduleTimer: fakeSchedule,
      );
      c.submit(80, 24);
      settle();
      // A 24→26→24 excursion that returns to the last emitted size emits nothing.
      c.submit(80, 26);
      c.submit(80, 24);
      settle();
      expect(emitted, [(80, 24)], reason: 'the no-op return is deduped');
      expect(c.sendCount, 1);
    });

    test('requestRedraw FORCES one settled emit even at the same size', () {
      final emitted = <(int, int)>[];
      final c = RefreshClientCoalescer(
        onSettled: (cols, rows) => emitted.add((cols, rows)),
        scheduleTimer: fakeSchedule,
      );
      c.submit(80, 24);
      settle();
      // A window switch needs a repaint at the SAME size — requestRedraw must
      // override the dedup so the new window paints.
      c.requestRedraw(80, 24);
      settle();
      expect(emitted, [(80, 24), (80, 24)]);
      expect(c.sendCount, 2);
    });

    test('a STORM of window switches collapses to ONE redraw', () {
      final emitted = <(int, int)>[];
      final c = RefreshClientCoalescer(
        onSettled: (cols, rows) => emitted.add((cols, rows)),
        scheduleTimer: fakeSchedule,
      );
      c.submit(58, 34);
      settle();
      emitted.clear();
      // The multi-client-clamp feedback: many %session-window-changed in a burst.
      for (var i = 0; i < 10; i++) {
        c.requestRedraw(58, 34);
      }
      expect(emitted, isEmpty, reason: 'debounced — nothing mid-burst');
      settle();
      expect(emitted, [(58, 34)], reason: 'one coalesced redraw, not ten');
    });

    test('cancel drops a pending write (dead/reconnected shell never storms)', () {
      final emitted = <(int, int)>[];
      final c = RefreshClientCoalescer(
        onSettled: (cols, rows) => emitted.add((cols, rows)),
        scheduleTimer: fakeSchedule,
      );
      c.submit(90, 30);
      c.cancel();
      settle();
      expect(emitted, isEmpty);
      expect(c.sendCount, 0);
    });
  });
}

/// A controllable fake [Timer] for the coalescer tests: it never auto-fires;
/// the test drives the settle edge. `cancel()` marks it inactive so a cancelled
/// timer's callback is never invoked — modelling `Timer.cancel()` faithfully.
class _FakeTimer implements Timer {
  _FakeTimer(this.callback);
  final void Function() callback;
  bool active = true;

  @override
  void cancel() => active = false;

  @override
  bool get isActive => active;

  @override
  int get tick => 0;
}
