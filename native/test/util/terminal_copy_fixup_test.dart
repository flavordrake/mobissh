// Unit tests for fixupTerminalCopy — the "Fix" pill behavior (#638).
// Mirrors the PWA's ime-fixup semantics: collapse terminal soft-wrap artifacts
// into one clean line, preserve genuine paragraph breaks, token-aware joins.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/util/terminal_copy_fixup.dart';

void main() {
  group('fixupTerminalCopy', () {
    test('joins a URL wrapped mid-token with NO separator', () {
      // xterm hard-wrapped a long URL; the join must be lossless.
      const wrapped = 'https://example.com/very/long/\n    path?query=value';
      expect(
        fixupTerminalCopy(wrapped),
        'https://example.com/very/long/path?query=value',
      );
    });

    test('joins wrapped prose with a single space', () {
      const wrapped = 'the quick brown\n    fox jumps';
      expect(fixupTerminalCopy(wrapped), 'the quick brown fox jumps');
    });

    test('preserves a genuine paragraph break (blank line)', () {
      const text = 'first line\n\nsecond line';
      expect(fixupTerminalCopy(text), 'first line\nsecond line');
    });

    test('normalizes CRLF and trims trailing whitespace', () {
      const text = 'echo hello   \r\n    world';
      expect(fixupTerminalCopy(text), 'echo hello world');
    });

    test('trims leading prompt indent and trailing newline', () {
      const text = '   ls -la\n';
      expect(fixupTerminalCopy(text), 'ls -la');
    });

    test('leaves an already-clean single line unchanged', () {
      const text = 'git status';
      expect(fixupTerminalCopy(text), 'git status');
    });

    test('empty input stays empty', () {
      expect(fixupTerminalCopy(''), '');
    });
  });

  // Owner report (rc.4, 2026-09-07): a two-command paste lost the newline
  // between `…99-bc125at.rules` and `sudo udevadm …` (`.rulessudo`). The
  // heuristic treated EVERY single newline as a soft wrap. With the terminal
  // width known, a line that does not fill a row — or that could not have
  // been a row at all — ends in a genuine newline, which must survive.
  group('fixupTerminalCopy with cols: hard breaks survive', () {
    const udevLine =
        'echo \'ACTION=="add", ATTRS{idVendor}=="1965",ATTRS{idProduct}=="0017", '
        'RUN+="/bin/sh -c \'"\'"\'echo 1965 0017 > /sys/bus/usb/drivers/cdc_acm/'
        'new_id\'"\'"\'"\' | sudo tee /etc/udev/rules.d/99-bc125at.rules';
    const reloadLine = 'sudo udevadm control --reload';

    test('owner case: a long line (wider than the terminal) then a short '
        'command keep their newline and every quote', () {
      const text = '$udevLine\n$reloadLine';
      expect(fixupTerminalCopy(text, cols: 50), text);
    });

    test('soft-wrapped rows join, the partial last row keeps its newline', () {
      // The same command as copied out of a 50-column terminal: full rows
      // are exactly 50 cells, the remainder is short, then the next command.
      const w = 50;
      final rows = <String>[];
      for (var i = 0; i < udevLine.length; i += w) {
        rows.add(
          udevLine.substring(i, i + w > udevLine.length ? udevLine.length : i + w),
        );
      }
      expect(rows.last.length, lessThan(w), reason: 'fixture needs a partial row');
      final text = '${rows.join('\n')}\n$reloadLine';
      expect(fixupTerminalCopy(text, cols: w), '$udevLine\n$reloadLine');
    });

    test('a long line plus a short one at any width keep their newline', () {
      // The first line is wider than the terminal → it was never a row here.
      final long = 'x' * 120;
      expect(
        fixupTerminalCopy('$long\nls -la', cols: 80),
        '$long\nls -la',
      );
    });

    test('text that never reaches the terminal edge falls back to the '
        'legacy heuristic (wrapped elsewhere, e.g. an indented URL)', () {
      // Deliberate trade-off: the width says nothing about this text, so the
      // #638 behavior stands — including that two short commands still fuse.
      expect(
        fixupTerminalCopy('https://example.com/long/\n    path?q=1', cols: 80),
        'https://example.com/long/path?q=1',
      );
    });

    test('a full row whose trailing space was trimmed by the copy still '
        'reads as a soft wrap', () {
      // 39 chars + the space that sat in cell 40 (trimmed) → 40 columns.
      const row = 'the quick brown fox jumps over the lazy';
      expect(row.length, 39);
      expect(
        fixupTerminalCopy('$row\ndog and runs', cols: 40),
        'the quick brown fox jumps over the lazy dog and runs',
      );
    });

    test('a full row broken mid-token joins with no separator', () {
      const row = 'https://example.com/a/very/long/path/th';
      expect(row.length, 39);
      expect(
        fixupTerminalCopy('$row\nat/continues', cols: 39),
        'https://example.com/a/very/long/path/that/continues',
      );
    });

    test('a full row followed by a row starting with a space keeps that '
        'space — it is content, not indent', () {
      // `echo 1965 0017` char-wrapped at 9 columns: cell 10 (the space)
      // starts the next row. Legacy indent-stripping would have kept it only
      // by luck of the prose rule; the char-wrap model keeps it by design.
      expect(
        fixupTerminalCopy('echo 1965\n 0017 > x', cols: 9),
        'echo 1965 0017 > x',
      );
    });

    test('intra-line whitespace is never touched', () {
      const text = 'echo 1965  0017\tx';
      expect(fixupTerminalCopy(text, cols: 50), text);
    });

    test('paragraph breaks still collapse to one newline', () {
      expect(
        fixupTerminalCopy('first\n\n\nsecond', cols: 80),
        'first\nsecond',
      );
    });
  });
}
