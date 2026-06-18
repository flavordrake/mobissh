// Unit tests for the tmux control-mode RENDER channel — Part B (#909, epic #906).
// PURE: no Flutter widget, no SSH, no I/O. Covers the render demux + the
// refresh-client -C resize primitive + the trailing-edge final-size contract.

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

    test('entryCommand is attach-OR-create (#913) — never a bare attach', () {
      // `new-session -A -s mobissh` attaches to an existing `mobissh` session if
      // present, else CREATES it. A bare `attach` fails with "no sessions" on a
      // host with no running tmux (e.g. a fresh test-sshd), so the rollout entry
      // MUST be attach-or-create. Lock the exact string.
      expect(
        text(TmuxControlChannel.entryCommand),
        'tmux -CC new-session -A -s mobissh\n',
      );
      expect(
        text(TmuxControlChannel.entryCommand),
        isNot(contains('attach')),
        reason: 'a bare `attach` fails "no sessions" on a host without tmux',
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
}
