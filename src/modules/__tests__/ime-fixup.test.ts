/**
 * Tests for fixupTerminalCopy — round-trip terminal-copied text into one
 * clean executable line by collapsing soft-wrap artifacts.
 */
import { describe, it, expect } from 'vitest';
import { fixupTerminalCopy, reconstructFromBuffer } from '../ime-fixup.js';

// ── reconstructFromBuffer fixture helpers ──────────────────────────────────
// Build a fake xterm-like buffer: rows is an array of [text, isWrapped].
// translateToString(trimRight, startCol, endCol) honors the start/end slice.
function makeTerm(rows: Array<[string, boolean]>, cols = 80): {
  cols: number;
  buffer: { active: { getLine: (y: number) => { isWrapped: boolean; translateToString: (t?: boolean, s?: number, e?: number) => string } | undefined } };
} {
  return {
    cols,
    buffer: {
      active: {
        getLine(y: number) {
          const r = rows[y];
          if (!r) return undefined;
          const [text, isWrapped] = r;
          return {
            isWrapped,
            translateToString(_trim?: boolean, s?: number, e?: number): string {
              const start = s ?? 0;
              const end = e ?? text.length;
              return text.slice(start, end);
            },
          };
        },
      },
    },
  };
}

describe('fixupTerminalCopy', () => {
  it('returns plain text unchanged', () => {
    expect(fixupTerminalCopy('hello world')).toBe('hello world');
  });

  it('normalizes CRLF to LF before processing (prose joins with space)', () => {
    expect(fixupTerminalCopy('a\r\nb')).toBe('a b');
  });

  it('normalizes lone CR to LF (prose joins with space)', () => {
    expect(fixupTerminalCopy('a\rb')).toBe('a b');
  });

  it('joins URL + path across a soft-wrap with no separator (URL is a token)', () => {
    expect(fixupTerminalCopy('curl https://example.com\n   path/to/thing')).toBe(
      'curl https://example.compath/to/thing'
    );
  });

  it('collapses newline + tab indent into a single space when both sides are prose', () => {
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

  it('strips trailing whitespace before each newline (prose joins with space)', () => {
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

  it('only whitespace collapses to empty after trim', () => {
    expect(fixupTerminalCopy('   ')).toBe('');
  });

  it('trims leading and trailing whitespace from the result', () => {
    expect(fixupTerminalCopy('  hello world  ')).toBe('hello world');
  });

  it('joins a Google-Docs-style URL split with newline + single space mid-token', () => {
    // Real-world regression case: terminal soft-wrapped a long Google Docs
    // URL such that the next line started with one space before the rest of
    // the doc ID. Old rule "newline + indent → space" introduced a space
    // mid-URL.
    const messy = '  https://docs.google.com/document/d/1p4FsyWN2LOjhN\n JBHGW3jsf-TxAjYor9aDSixbGRUDho/edit';
    expect(fixupTerminalCopy(messy)).toBe('https://docs.google.com/document/d/1p4FsyWN2LOjhNJBHGW3jsf-TxAjYor9aDSixbGRUDho/edit');
  });

  it('still uses a space when wrapping prose (non-token chars on both sides)', () => {
    // "see the\n   following text" — these aren't tokens, so the rule
    // collapses to single space as before.
    expect(fixupTerminalCopy('see the\n   following text')).toBe('see the following text');
  });

  it('joins when one side has token punct (URL-y context)', () => {
    expect(fixupTerminalCopy('url:\n  here')).toBe('url:here');
  });
});

describe('reconstructFromBuffer', () => {
  it('joins a soft-wrapped URL across two rows without a separator', () => {
    const term = makeTerm([
      ['https://example.com/api/v1/abc', false],
      ['def/long/path/here', true],   // wrapped continuation
    ], 80);
    const out = reconstructFromBuffer(term, {
      start: { x: 0, y: 0 },
      end:   { x: 18, y: 1 },
    });
    expect(out).toBe('https://example.com/api/v1/abcdef/long/path/here');
  });

  it('preserves a hard newline when the next row is NOT wrapped', () => {
    const term = makeTerm([
      ['line one', false],
      ['line two', false],   // hard newline, not a wrap
    ], 80);
    const out = reconstructFromBuffer(term, {
      start: { x: 0, y: 0 },
      end:   { x: 8, y: 1 },
    });
    expect(out).toBe('line one\nline two');
  });

  it('joins multiple consecutive wrapped rows', () => {
    const term = makeTerm([
      ['curl https://example.com/v1/', false],
      ['supercalifragilistic-key-', true],
      ['expialidocious-suffix', true],
    ], 80);
    const out = reconstructFromBuffer(term, {
      start: { x: 0, y: 0 },
      end:   { x: 21, y: 2 },
    });
    expect(out).toBe('curl https://example.com/v1/supercalifragilistic-key-expialidocious-suffix');
  });

  it('honors start/end columns within the first and last rows', () => {
    const term = makeTerm([
      ['XXXhello', false],
      ['worldYYY', true],
    ], 80);
    const out = reconstructFromBuffer(term, {
      start: { x: 3, y: 0 },
      end:   { x: 5, y: 1 },
    });
    expect(out).toBe('helloworld');
  });

  it('returns empty for inverted range', () => {
    const term = makeTerm([['x', false]]);
    const out = reconstructFromBuffer(term, {
      start: { x: 0, y: 1 },
      end:   { x: 0, y: 0 },
    });
    expect(out).toBe('');
  });

  it('mixes soft-wrap and hard newlines correctly', () => {
    // Row 0 + 1 are a soft-wrapped URL; row 2 is a separate command.
    const term = makeTerm([
      ['https://example.com/abcdefghij', false],
      ['klmnopqrstuvwxyz', true],
      ['echo done', false],
    ], 80);
    const out = reconstructFromBuffer(term, {
      start: { x: 0, y: 0 },
      end:   { x: 9, y: 2 },
    });
    expect(out).toBe('https://example.com/abcdefghijklmnopqrstuvwxyz\necho done');
  });

  it('single-row selection just returns the column slice', () => {
    const term = makeTerm([['abcdefghij', false]], 80);
    const out = reconstructFromBuffer(term, {
      start: { x: 2, y: 0 },
      end:   { x: 7, y: 0 },
    });
    expect(out).toBe('cdefg');
  });
});
