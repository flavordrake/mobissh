import { describe, it, expect } from 'vitest';
import { computeDiff } from '../ime-diff.js';

describe('computeDiff — autocorrect word replacement (#177)', () => {
  it('returns empty for identical strings', () => {
    expect(computeDiff('hello', 'hello')).toEqual({ deletions: 0, insertion: '' });
  });

  it('handles simple append', () => {
    expect(computeDiff('hel', 'hello')).toEqual({ deletions: 0, insertion: 'lo' });
  });

  it('handles suffix-only fix (typo correction)', () => {
    // "terminl" → "terminal": backspace 1 char, type "al"
    expect(computeDiff('terminl', 'terminal')).toEqual({ deletions: 1, insertion: 'al' });
  });

  it('handles full word replacement with no common chars', () => {
    // "terminal" → "preview": backspace entire word, type new word
    expect(computeDiff('terminal', 'preview')).toEqual({ deletions: 8, insertion: 'preview' });
  });

  it('handles word replacement with misleading common suffix', () => {
    // "test" → "best": common suffix "est" in string terms, but backspace works
    // from cursor (end), so we can't skip over the suffix. Must delete all 4
    // chars and retype "best".
    const result = computeDiff('test', 'best');
    expect(result.deletions).toBe(4);
    expect(result.insertion).toBe('best');
  });

  it('handles partial word replacement with common prefix', () => {
    // "hello world" → "hello earth": common prefix "hello ", delete "world" (5), type "earth"
    expect(computeDiff('hello world', 'hello earth')).toEqual({ deletions: 5, insertion: 'earth' });
  });

  it('handles replacement where common suffix misleads (cat→bat)', () => {
    // "cat" → "bat": suffix "at" is common in string terms, but backspace from
    // end deletes "at" not "c". Must delete 3 chars and type "bat".
    const result = computeDiff('cat', 'bat');
    expect(result.deletions).toBe(3);
    expect(result.insertion).toBe('bat');
  });

  it('handles replacement with common prefix AND misleading suffix', () => {
    // "testing" → "tearing": prefix "te", then must delete "sting" (5) and type "aring"
    const result = computeDiff('testing', 'tearing');
    expect(result.deletions).toBe(5);
    expect(result.insertion).toBe('aring');
  });

  it('handles simple deletion', () => {
    expect(computeDiff('hello', 'hell')).toEqual({ deletions: 1, insertion: '' });
  });

  it('handles empty old value', () => {
    expect(computeDiff('', 'hello')).toEqual({ deletions: 0, insertion: 'hello' });
  });

  it('handles empty new value', () => {
    expect(computeDiff('hello', '')).toEqual({ deletions: 5, insertion: '' });
  });
});
