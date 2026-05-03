import { describe, it, expect, beforeEach, vi } from 'vitest';

/**
 * Configurable text-pattern detection (#478).
 *
 * Storage round-trip, host glob matching, URL templating, and regex matching
 * (including soft-wrap reassembly) for the user-defined link rules.
 */

const storage = new Map<string, string>();
const localStorageMock = {
  getItem: (key: string) => storage.get(key) ?? null,
  setItem: (key: string, value: string) => { storage.set(key, value); },
  removeItem: (key: string) => { storage.delete(key); },
  clear: () => { storage.clear(); },
  get length() { return storage.size; },
  key: (_i: number) => null as string | null,
};
vi.stubGlobal('localStorage', localStorageMock);

const {
  getPatternRules,
  getActiveRulesForHost,
  addPatternRule,
  updatePatternRule,
  deletePatternRule,
  setPatternRules,
  hostMatches,
  buildLinkUrl,
  findRuleMatches,
  reassembleSoftWrap,
} = await import('../pattern-links.js');

const KEY = 'mobissh.patternRules';

describe('pattern-links: storage round-trip', () => {
  beforeEach(() => { storage.clear(); });

  it('returns [] when nothing stored', () => {
    expect(getPatternRules()).toEqual([]);
  });

  it('add → read returns the rule with assigned id', () => {
    const id = addPatternRule({
      name: 'Issue links',
      pattern: '#(\\d+)',
      urlTemplate: 'https://github.com/owner/repo/issues/{match}',
      hostGlob: '*',
    });
    expect(id).toMatch(/^pl_/);
    const rules = getPatternRules();
    expect(rules).toHaveLength(1);
    expect(rules[0]).toMatchObject({
      id,
      name: 'Issue links',
      pattern: '#(\\d+)',
      enabled: true,
    });
  });

  it('persists across re-reads (writes a versioned envelope)', () => {
    addPatternRule({ name: 'a', pattern: 'foo', urlTemplate: 'http://x/{match}', hostGlob: '' });
    const raw = storage.get(KEY)!;
    const parsed = JSON.parse(raw) as { version: number; rules: unknown[] };
    expect(parsed.version).toBe(1);
    expect(parsed.rules).toHaveLength(1);
  });

  it('update merges patch fields, leaves the rest alone', () => {
    const id = addPatternRule({ name: 'a', pattern: 'foo', urlTemplate: 'http://x/{match}', hostGlob: '' });
    updatePatternRule(id, { name: 'renamed', enabled: false });
    const r = getPatternRules()[0]!;
    expect(r.name).toBe('renamed');
    expect(r.enabled).toBe(false);
    expect(r.pattern).toBe('foo');
  });

  it('update with unknown id is a no-op', () => {
    const id = addPatternRule({ name: 'a', pattern: 'foo', urlTemplate: 'http://x/{match}', hostGlob: '' });
    updatePatternRule('pl_missing', { name: 'should not apply' });
    expect(getPatternRules()[0]!.id).toBe(id);
    expect(getPatternRules()[0]!.name).toBe('a');
  });

  it('delete removes the rule, idempotent for unknown ids', () => {
    const id = addPatternRule({ name: 'a', pattern: 'foo', urlTemplate: 'http://x/{match}', hostGlob: '' });
    deletePatternRule(id);
    expect(getPatternRules()).toEqual([]);
    deletePatternRule(id);
    expect(getPatternRules()).toEqual([]);
  });

  it('setPatternRules replaces the full list and re-sanitizes', () => {
    setPatternRules([
      { id: 'pl_keep', name: 'k', pattern: 'p', urlTemplate: 't', hostGlob: '', enabled: true },
      // missing pattern → dropped
      { id: 'pl_drop', name: 'd', pattern: '', urlTemplate: 't', hostGlob: '', enabled: true },
    ]);
    const out = getPatternRules();
    expect(out).toHaveLength(1);
    expect(out[0]!.id).toBe('pl_keep');
  });
});

describe('pattern-links: schema tolerance', () => {
  beforeEach(() => { storage.clear(); });

  it('tolerates a bare-array value (older export shape)', () => {
    storage.set(KEY, JSON.stringify([
      { id: 'pl_x', name: 'x', pattern: 'foo', urlTemplate: 'http://x', hostGlob: '', enabled: true },
    ]));
    const rules = getPatternRules();
    expect(rules).toHaveLength(1);
    expect(rules[0]!.id).toBe('pl_x');
  });

  it('drops malformed records (missing pattern or urlTemplate)', () => {
    storage.set(KEY, JSON.stringify({
      version: 1,
      rules: [
        { name: 'no pattern', urlTemplate: 'http://x' },
        { name: 'no template', pattern: 'foo' },
        { name: 'ok', pattern: 'foo', urlTemplate: 'http://x' },
      ],
    }));
    const rules = getPatternRules();
    expect(rules).toHaveLength(1);
    expect(rules[0]!.name).toBe('ok');
  });

  it('returns [] on JSON parse failure', () => {
    storage.set(KEY, 'this-is-not-json');
    expect(getPatternRules()).toEqual([]);
  });
});

describe('pattern-links: host glob matching', () => {
  it('empty glob matches everything', () => {
    expect(hostMatches('', 'anything')).toBe(true);
    expect(hostMatches('', '')).toBe(true);
  });

  it('"*" matches everything', () => {
    expect(hostMatches('*', 'foo.example.com')).toBe(true);
  });

  it('exact match (case-insensitive)', () => {
    expect(hostMatches('foo.example.com', 'foo.example.com')).toBe(true);
    expect(hostMatches('FOO.example.com', 'foo.example.com')).toBe(true);
    expect(hostMatches('foo.example.com', 'bar.example.com')).toBe(false);
  });

  it('prefix wildcard "prefix*"', () => {
    expect(hostMatches('foo.*', 'foo.example.com')).toBe(true);
    expect(hostMatches('foo.*', 'foo')).toBe(false);
    expect(hostMatches('foo.*', 'bar.example.com')).toBe(false);
  });

  it('suffix wildcard "*suffix"', () => {
    expect(hostMatches('*.example.com', 'foo.example.com')).toBe(true);
    expect(hostMatches('*.example.com', 'example.com')).toBe(false);
    expect(hostMatches('*.example.com', 'foo.example.org')).toBe(false);
  });

  it('middle wildcard "*middle*"', () => {
    expect(hostMatches('*ts.net*', 'nv-dev.tailbe5094.ts.net')).toBe(true);
    expect(hostMatches('*ts.net*', 'foo.example.com')).toBe(false);
  });

  it('does not let regex metacharacters in the glob match arbitrary strings', () => {
    // A literal `.` in a glob means a literal `.`, NOT "any character".
    expect(hostMatches('foo.example.com', 'fooXexampleXcom')).toBe(false);
  });
});

describe('pattern-links: getActiveRulesForHost', () => {
  beforeEach(() => { storage.clear(); });

  it('filters by enabled and host glob', () => {
    addPatternRule({ name: 'all', pattern: 'a', urlTemplate: 't', hostGlob: '*' });
    const dis = addPatternRule({ name: 'disabled', pattern: 'b', urlTemplate: 't', hostGlob: '*' });
    updatePatternRule(dis, { enabled: false });
    addPatternRule({ name: 'corp-only', pattern: 'c', urlTemplate: 't', hostGlob: '*.corp' });

    const corp = getActiveRulesForHost('host.corp');
    expect(corp.map((r) => r.name).sort()).toEqual(['all', 'corp-only']);

    const home = getActiveRulesForHost('home.lan');
    expect(home.map((r) => r.name)).toEqual(['all']);
  });
});

describe('pattern-links: buildLinkUrl', () => {
  it('substitutes {match} with URL-encoded text', () => {
    expect(buildLinkUrl('https://x/{match}', 'a b/c', 'host')).toBe('https://x/a%20b%2Fc');
  });

  it('substitutes {host}', () => {
    expect(buildLinkUrl('https://{host}/path', 'm', 'foo.bar')).toBe('https://foo.bar/path');
  });

  it('substitutes both, repeating placeholders', () => {
    expect(buildLinkUrl('{host}/{match}/{match}', 'x', 'h')).toBe('h/x/x');
  });
});

describe('pattern-links: findRuleMatches', () => {
  it('returns each occurrence of a regex match', () => {
    const rule = {
      id: 'r', name: 'issue', pattern: '#(\\d+)', urlTemplate: 't', hostGlob: '*', enabled: true,
    };
    const matches = findRuleMatches(rule, 'fixed #12 broke #345 again');
    expect(matches).toHaveLength(2);
    expect(matches[0]!.text).toBe('12');
    expect(matches[1]!.text).toBe('345');
    expect(matches[0]!.start).toBe(6);
    expect(matches[0]!.length).toBe(3); // "#12"
  });

  it('uses the whole match when there is no capture group', () => {
    const rule = {
      id: 'r', name: 'url', pattern: 'https?://\\S+', urlTemplate: 't', hostGlob: '*', enabled: true,
    };
    const matches = findRuleMatches(rule, 'see https://example.com here');
    expect(matches).toHaveLength(1);
    expect(matches[0]!.text).toBe('https://example.com');
  });

  it('returns [] for an invalid regex (does not throw)', () => {
    const rule = {
      id: 'r', name: 'bad', pattern: '(', urlTemplate: 't', hostGlob: '*', enabled: true,
    };
    expect(findRuleMatches(rule, 'anything')).toEqual([]);
  });

  it('does not infinite-loop on a zero-width regex', () => {
    const rule = {
      id: 'r', name: 'zw', pattern: 'a*', urlTemplate: 't', hostGlob: '*', enabled: true,
    };
    // Should terminate. We don't care about the exact match list, just that it
    // returns within a reasonable time.
    const matches = findRuleMatches(rule, 'bcd');
    expect(Array.isArray(matches)).toBe(true);
  });
});

describe('pattern-links: reassembleSoftWrap', () => {
  it('joins consecutive full-width rows into one logical line', () => {
    const cols = 10;
    const rows = ['1234567890', '12345', 'next'];
    const out = reassembleSoftWrap(rows, cols);
    expect(out).toHaveLength(2);
    expect(out[0]!.text).toBe('123456789012345');
    expect(out[0]!.origins).toHaveLength(15);
    expect(out[0]!.origins[0]).toEqual({ row: 0, col: 0 });
    expect(out[0]!.origins[10]).toEqual({ row: 1, col: 0 });
    expect(out[1]!.text).toBe('next');
  });

  it('does not join when a row is shorter than cols', () => {
    const out = reassembleSoftWrap(['short', 'next'], 10);
    expect(out).toHaveLength(2);
    expect(out[0]!.text).toBe('short');
    expect(out[1]!.text).toBe('next');
  });

  it('returns an empty array for no rows', () => {
    expect(reassembleSoftWrap([], 80)).toEqual([]);
  });
});
