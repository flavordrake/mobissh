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
}
