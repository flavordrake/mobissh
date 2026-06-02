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
}
