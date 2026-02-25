import { describe, it, expect } from 'vitest';
import { escHtml } from '../constants.js';

describe('escHtml', () => {
  it('escapes ampersands', () => {
    expect(escHtml('a&b')).toBe('a&amp;b');
  });

  it('escapes angle brackets', () => {
    expect(escHtml('<script>')).toBe('&lt;script&gt;');
  });

  it('escapes double quotes', () => {
    expect(escHtml('"hello"')).toBe('&quot;hello&quot;');
  });

  it('handles all special chars together', () => {
    expect(escHtml('<a href="x&y">')).toBe('&lt;a href=&quot;x&amp;y&quot;&gt;');
  });

  it('returns empty string unchanged', () => {
    expect(escHtml('')).toBe('');
  });

  it('passes through safe strings unchanged', () => {
    expect(escHtml('hello world 123')).toBe('hello world 123');
  });

  it('prevents XSS via img onerror', () => {
    const xss = '<img src=x onerror="alert(1)">';
    expect(escHtml(xss)).not.toContain('<img');
  });
});
