/**
 * Tests for fixupTerminalCopy — round-trip terminal-copied text into one
 * clean executable line by collapsing soft-wrap artifacts.
 */
import { describe, it, expect } from 'vitest';
import { fixupTerminalCopy } from '../ime-fixup.js';

describe('fixupTerminalCopy', () => {
  it('returns plain text unchanged', () => {
    expect(fixupTerminalCopy('hello world')).toBe('hello world');
  });

  it('normalizes CRLF to LF before processing', () => {
    expect(fixupTerminalCopy('a\r\nb')).toBe('ab');
  });

  it('normalizes lone CR to LF', () => {
    expect(fixupTerminalCopy('a\rb')).toBe('ab');
  });

  it('collapses newline + leading indent into a single space (canonical xterm soft-wrap)', () => {
    expect(fixupTerminalCopy('curl https://example.com\n   path/to/thing')).toBe(
      'curl https://example.com path/to/thing'
    );
  });

  it('collapses newline + tab indent into a single space', () => {
    expect(fixupTerminalCopy('foo\n\tbar')).toBe('foo bar');
  });

  it('joins terminal-hard-wrapped URLs (newline with no indent → no separator)', () => {
    const url = 'https://example.com/v1/' + 'a'.repeat(40) + '/' + 'b'.repeat(40);
    const wrapped = 'https://example.com/v1/' + 'a'.repeat(40) + '/\n' + 'b'.repeat(40);
    expect(fixupTerminalCopy(wrapped)).toBe(url);
  });

  it('preserves paragraph breaks (double newline → single newline)', () => {
    expect(fixupTerminalCopy('paragraph one\n\nparagraph two')).toBe('paragraph one\nparagraph two');
  });

  it('handles 3+ consecutive newlines as a single paragraph break', () => {
    expect(fixupTerminalCopy('a\n\n\n\nb')).toBe('a\nb');
  });

  it('strips trailing whitespace before each newline', () => {
    expect(fixupTerminalCopy('foo   \n   bar')).toBe('foo bar');
  });

  // Note: not strictly idempotent on text containing paragraph breaks — the
  // first pass collapses `\n\n+` → `\n`, and a second pass treats that lone
  // `\n` as a soft wrap. That's expected: the function is designed for a
  // single clean-up pass on freshly pasted terminal output.

  it('flattens a multi-line indented bash command into one line', () => {
    const raw = 'docker run --rm \\\n  -v $(pwd):/work \\\n  alpine sh';
    expect(fixupTerminalCopy(raw)).toBe('docker run --rm \\ -v $(pwd):/work \\ alpine sh');
  });

  it('joins a base64/API key split across lines without indent', () => {
    const key = 'sk_live_' + 'a'.repeat(50) + 'b'.repeat(20);
    const wrapped = 'sk_live_' + 'a'.repeat(50) + '\n' + 'b'.repeat(20);
    expect(fixupTerminalCopy(wrapped)).toBe(key);
  });

  it('empty string → empty string', () => {
    expect(fixupTerminalCopy('')).toBe('');
  });

  it('only whitespace stays only whitespace (trimmed at line ends)', () => {
    expect(fixupTerminalCopy('   ')).toBe('   ');
  });
});
