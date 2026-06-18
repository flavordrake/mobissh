// Unit tests for the tmux control-mode (`tmux -CC`) parser — Part A of the
// control-mode arc (#907, epic #906). PURE: no Flutter, no I/O (except reading
// the captured fixture from disk). Covers:
//   - the real captured fixture (native/test/fixtures/tmux_cc/capture.cc) →
//     correct typed events + parsed geometry that matches truth-windows.txt,
//   - octal-unescape (incl. `\134` → `\` and control chars),
//   - multi-line %output / interleaved notifications inside a command block,
//   - %begin/%end and %begin/%error framing,
//   - malformed / partial-line resilience (never throws).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/terminal/tmux_control_parser.dart';
import 'package:mobissh/terminal/tmux_control_mode_flag.dart';

/// Feed a whole string and collect every event.
List<TmuxControlEvent> parseAll(String s) {
  final p = TmuxControlParser();
  return p.feed(s);
}

void main() {
  group('feature flag', () {
    test('tmuxControlMode defaults OFF (scrape path stays default)', () {
      expect(tmuxControlMode, isFalse);
    });
  });

  group('octal unescape (%output)', () {
    test(r'\134 decodes to a single backslash', () {
      final ev = parseAll('%output %0 a\\134b\n').single as PaneOutput;
      expect(ev.paneId, 0);
      expect(ev.data, utf8.encode('a\\b'));
    });

    test('control chars (CR/LF) decode to their bytes', () {
      // \015 = CR (0x0d), \012 = LF (0x0a)
      final ev = parseAll('%output %2 ls\\015\\012\n').single as PaneOutput;
      expect(ev.data, Uint8List.fromList([0x6c, 0x73, 0x0d, 0x0a])); // "ls\r\n"
    });

    test('ESC + CSI sequence decodes to raw bytes', () {
      // \033[?2004h
      final ev = parseAll('%output %0 \\033[?2004h\n').single as PaneOutput;
      expect(ev.data, Uint8List.fromList([0x1b, 0x5b, 0x3f, 0x32, 0x30, 0x30, 0x34, 0x68]));
    });

    test('a lone backslash not followed by octal digits is kept literally', () {
      // Trailing `\` (tmux would escape it, but be resilient): "\x" stays.
      final ev = parseAll('%output %0 a\\x\n').single as PaneOutput;
      expect(ev.data, utf8.encode('a\\x'));
    });

    test('%output data may contain spaces (only first space is the delimiter)', () {
      final ev = parseAll('%output %1 echo hello world\n').single as PaneOutput;
      expect(ev.paneId, 1);
      expect(utf8.decode(ev.data), 'echo hello world');
    });

    test('%output with empty data yields zero bytes', () {
      final ev = parseAll('%output %3\n').single as PaneOutput;
      expect(ev.paneId, 3);
      expect(ev.data, isEmpty);
    });
  });

  group('command framing (%begin / %end / %error)', () {
    test('%begin … %end wraps response body lines', () {
      const stream = '%begin 1781790162 302 0\n'
          'line one\n'
          'line two\n'
          '%end 1781790162 302 0\n';
      final evs = parseAll(stream);
      expect(evs[0], isA<CommandBegin>());
      expect((evs[0] as CommandBegin).number, 302);
      final end = evs[1] as CommandEnd;
      expect(end.isError, isFalse);
      expect(end.number, 302);
      expect(end.response, ['line one', 'line two']);
    });

    test('%begin … %error marks the block as an error', () {
      const stream = '%begin 100 5 0\nbad command\n%error 100 5 0\n';
      final evs = parseAll(stream);
      final end = evs.last as CommandEnd;
      expect(end.isError, isTrue);
      expect(end.response, ['bad command']);
    });

    test('a notification interleaved INSIDE a block is body text, not parsed', () {
      // tmux does not interleave async notifications inside a command block; a
      // line that merely LOOKS like one inside the block must be treated as
      // verbatim response text, and the block must still close correctly.
      const stream = '%begin 1 2 0\n%output %0 not-a-real-notification\n%end 1 2 0\n';
      final evs = parseAll(stream);
      expect(evs.whereType<PaneOutput>(), isEmpty);
      final end = evs.last as CommandEnd;
      expect(end.response, ['%output %0 not-a-real-notification']);
    });
  });

  group('notifications', () {
    test('%session-changed', () {
      final ev = parseAll('%session-changed \$0 main\n').single as SessionChanged;
      expect(ev.sessionId, 0);
      expect(ev.name, 'main');
    });

    test('%session-window-changed sets active window', () {
      final p = TmuxControlParser();
      final ev = p.feed('%session-window-changed \$0 @3\n').single as SessionWindowChanged;
      expect(ev.windowId, 3);
      expect(p.activeWindowId, 3);
    });

    test('%window-add / %window-close / %unlinked-window-close', () {
      expect((parseAll('%window-add @5\n').single as WindowAdd).windowId, 5);
      final close = parseAll('%window-close @5\n').single as WindowClose;
      expect(close.windowId, 5);
      expect(close.unlinked, isFalse);
      final unlinked = parseAll('%unlinked-window-close @7\n').single as WindowClose;
      expect(unlinked.windowId, 7);
      expect(unlinked.unlinked, isTrue);
    });

    test('%window-renamed keeps spaces in the name', () {
      final ev = parseAll('%window-renamed @2 my window name\n').single as WindowRenamed;
      expect(ev.windowId, 2);
      expect(ev.name, 'my window name');
    });

    test('%window-pane-changed', () {
      final ev = parseAll('%window-pane-changed @0 %2\n').single as WindowPaneChanged;
      expect(ev.windowId, 0);
      expect(ev.paneId, 2);
    });

    test('%sessions-changed (no args)', () {
      expect(parseAll('%sessions-changed\n').single, isA<SessionsChanged>());
    });

    test('%client-detached', () {
      expect((parseAll('%client-detached /dev/pts/3\n').single as ClientDetached).client,
          '/dev/pts/3');
    });

    test('%exit with and without reason', () {
      expect((parseAll('%exit\n').single as ControlModeExit).reason, isNull);
      expect((parseAll('%exit server exited\n').single as ControlModeExit).reason,
          'server exited');
    });

    test('an unmodeled %notification surfaces as UnhandledNotification', () {
      final ev = parseAll('%pane-mode-changed %1\n').single as UnhandledNotification;
      expect(ev.verb, 'pane-mode-changed');
      expect(ev.args, '%1');
    });
  });

  group('layout parsing', () {
    test('single-pane layout → window geometry + one pane', () {
      final ev = parseAll('%layout-change @1 b25e,80x24,0,0,1\n').single as LayoutChange;
      expect(ev.windowId, 1);
      expect(ev.layout.width, 80);
      expect(ev.layout.height, 24);
      expect(ev.layout.panes, hasLength(1));
      expect(ev.layout.panes.single.paneId, 1);
    });

    test('horizontal split → two panes, correct rects', () {
      final ev = parseAll(
              '%layout-change @0 0206,80x24,0,0{40x24,0,0,0,39x24,41,0,2} '
              '0206,80x24,0,0{40x24,0,0,0,39x24,41,0,2} *\n')
          .single as LayoutChange;
      expect(ev.layout.width, 80);
      expect(ev.layout.height, 24);
      expect(ev.layout.panes, hasLength(2));
      final p0 = ev.layout.panes[0];
      expect([p0.width, p0.height, p0.x, p0.y, p0.paneId], [40, 24, 0, 0, 0]);
      final p1 = ev.layout.panes[1];
      expect([p1.width, p1.height, p1.x, p1.y, p1.paneId], [39, 24, 41, 0, 2]);
    });

    test('vertical split [] parses too', () {
      final layout = TmuxControlParser.parseLayout('abcd,80x24,0,0[80x12,0,0,0,80x11,0,13,1]');
      expect(layout, isNotNull);
      expect(layout!.panes, hasLength(2));
      expect(layout.panes[1].y, 13);
    });

    test('nested split → all leaf panes flattened', () {
      // 3 panes: left full-height, right split top/bottom.
      const raw = 'eeee,80x24,0,0{40x24,0,0,0,39x24,41,0[39x12,41,0,1,39x11,41,13,2]}';
      final layout = TmuxControlParser.parseLayout(raw);
      expect(layout, isNotNull);
      expect(layout!.panes.map((p) => p.paneId).toList(), [0, 1, 2]);
    });

    test('malformed layout returns null, never throws', () {
      expect(TmuxControlParser.parseLayout('garbage'), isNull);
      expect(TmuxControlParser.parseLayout(''), isNull);
      expect(TmuxControlParser.parseLayout('abcd,80x'), isNull);
    });
  });

  group('resilience', () {
    test('a malformed % line becomes UnknownLine, parser keeps going', () {
      const stream = '%output garbage-no-pane\n%window-add @9\n';
      final evs = parseAll(stream);
      expect(evs[0], isA<UnknownLine>());
      expect((evs[1] as WindowAdd).windowId, 9);
    });

    test('a non-% line outside a block becomes UnknownLine', () {
      expect(parseAll('just some text\n').single, isA<UnknownLine>());
    });

    test('a partial final line is buffered until completed by the next feed', () {
      final p = TmuxControlParser();
      final first = p.feed('%window-ad'); // split mid-line
      expect(first, isEmpty);
      final second = p.feed('d @4\n');
      expect((second.single as WindowAdd).windowId, 4);
    });

    test('a chunk split mid-octal-escape still decodes correctly', () {
      final p = TmuxControlParser();
      expect(p.feed('%output %0 a\\13'), isEmpty);
      final ev = p.feed('4b\n').single as PaneOutput;
      expect(ev.data, utf8.encode('a\\b'));
    });

    test('empty / blank lines are ignored', () {
      expect(parseAll('\n\n'), isEmpty);
    });
  });

  group('control-mode entry', () {
    test('the DCS 1000p prefix emits ControlModeEntered once', () {
      final p = TmuxControlParser();
      final evs = p.feed('P1000p%begin 1 1 0\n%end 1 1 0\n');
      expect(evs.first, isA<ControlModeEntered>());
      expect(evs.whereType<ControlModeEntered>(), hasLength(1));
      // A later feed does not re-emit it.
      final more = p.feed('%window-add @1\n');
      expect(more.whereType<ControlModeEntered>(), isEmpty);
    });
  });

  group('captured real -CC fixture', () {
    // Captured by scripts/capture-tmux-cc.sh against a THROWAWAY tmux session
    // (never the owner's live `main`). truth-windows.txt holds tmux's
    // independent `list-windows -F` truth for the SAME final state.
    const fixturePath = 'test/fixtures/tmux_cc/capture.cc';
    const truthPath = 'test/fixtures/tmux_cc/truth-windows.txt';

    test('fixture parses without throwing and emits the expected event types', () {
      final raw = File(fixturePath).readAsStringSync();
      final p = TmuxControlParser();
      final evs = p.feed(raw);

      expect(evs, isNotEmpty);
      expect(evs.whereType<ControlModeEntered>(), hasLength(1));
      expect(evs.whereType<CommandBegin>(), isNotEmpty);
      expect(evs.whereType<CommandEnd>(), isNotEmpty);
      expect(evs.whereType<PaneOutput>(), isNotEmpty);
      expect(evs.whereType<LayoutChange>(), isNotEmpty);
      expect(evs.whereType<SessionChanged>(), isNotEmpty);
      expect(evs.whereType<SessionWindowChanged>(), isNotEmpty);
      expect(evs.whereType<WindowAdd>(), isNotEmpty);
      expect(evs.whereType<WindowRenamed>(), isNotEmpty);
      expect(evs.whereType<WindowClose>(), isNotEmpty); // %unlinked-window-close
      expect(evs.whereType<ControlModeExit>(), hasLength(1));
      // No UnknownLine in a clean capture (the trailing `\` after %exit is the
      // only candidate; assert at most that one and nothing more).
      expect(evs.whereType<UnknownLine>().length, lessThanOrEqualTo(1));
    });

    test('parsed active window == tmux truth (the parity assertion)', () {
      final raw = File(fixturePath).readAsStringSync();
      final p = TmuxControlParser();
      p.feed(raw);

      // tmux truth: the `*`/active row in list-windows. truth-windows.txt cols:
      // "<index> <name> <active> <WxH> <layout>".
      final truth = File(truthPath).readAsLinesSync().where((l) => l.trim().isNotEmpty);
      final activeTruth = truth.firstWhere((l) => l.split(' ')[2] == '1');
      final activeLayoutRaw = activeTruth.split(' ').last;
      final truthLayout = TmuxControlParser.parseLayout(activeLayoutRaw)!;

      // The parser's layout for the active window must equal tmux's geometry.
      final aw = p.activeWindowId;
      expect(aw, isNotNull, reason: 'parser must have an active window from %session-window-changed');
      final parsedLayout = p.layouts[aw];
      expect(parsedLayout, isNotNull,
          reason: 'parser must have a layout for the active window from %layout-change');
      expect(parsedLayout!.width, truthLayout.width);
      expect(parsedLayout.height, truthLayout.height);
      expect(parsedLayout.panes.length, truthLayout.panes.length);
    });
  });
}
