/**
 * modules/pattern-links.ts — Configurable text-pattern detection (#478).
 *
 * v1 scope: detect terminal-rendered text matching user-defined regexes and
 * turn them into clickable links via xterm's link provider API. No resolver
 * (no shell-command execution like `pwd` for relative-path resolution); URL
 * templates are static with `{match}` and `{host}` placeholders.
 *
 * Storage: localStorage('mobissh.patternRules') — `{ version, rules[] }`
 * with the schema version inside the value (project rule).
 *
 * Active-host filter: rules carry a `hostGlob` string; an empty string or
 * `*` matches any host. Glob supports a single `*` wildcard and exact match.
 */

const STORAGE_KEY = 'mobissh.patternRules';
const SCHEMA_VERSION = 1;

export interface PatternRule {
  /** Stable id for edit/delete. */
  id: string;
  /** Display name in settings UI. */
  name: string;
  /** Source regex string (we wrap it with `g` and a single capture group for
   *  the matched text — author should write the regex with that in mind). */
  pattern: string;
  /** URL template. Supports `{match}` (the captured text) and `{host}` (the
   *  active session's profile.host). */
  urlTemplate: string;
  /** Glob restricting which session hosts this rule applies to. Empty
   *  string and `*` mean "all hosts". Otherwise a single `*` wildcard or
   *  exact-equality match. */
  hostGlob: string;
  /** Toggle without deleting. */
  enabled: boolean;
}

interface StorageShape {
  version: number;
  rules: PatternRule[];
}

function _read(): StorageShape {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return { version: SCHEMA_VERSION, rules: [] };
    const parsed = JSON.parse(raw) as unknown;
    if (Array.isArray(parsed)) {
      return { version: SCHEMA_VERSION, rules: _sanitize(parsed as unknown[]) };
    }
    if (parsed && typeof parsed === 'object' && Array.isArray((parsed as StorageShape).rules)) {
      return { version: SCHEMA_VERSION, rules: _sanitize((parsed as StorageShape).rules as unknown[]) };
    }
  } catch {
    // fall through
  }
  return { version: SCHEMA_VERSION, rules: [] };
}

function _sanitize(raw: unknown[]): PatternRule[] {
  const out: PatternRule[] = [];
  for (const item of raw) {
    if (!item || typeof item !== 'object') continue;
    const r = item as Record<string, unknown>;
    if (typeof r.pattern !== 'string' || r.pattern === '') continue;
    if (typeof r.urlTemplate !== 'string' || r.urlTemplate === '') continue;
    out.push({
      id: typeof r.id === 'string' && r.id ? r.id : _newId(),
      name: typeof r.name === 'string' ? r.name : '',
      pattern: r.pattern,
      urlTemplate: r.urlTemplate,
      hostGlob: typeof r.hostGlob === 'string' ? r.hostGlob : '',
      enabled: r.enabled !== false,
    });
  }
  return out;
}

function _newId(): string {
  return `pl_${Math.random().toString(36).slice(2, 10)}`;
}

function _write(rules: PatternRule[]): void {
  const data: StorageShape = { version: SCHEMA_VERSION, rules };
  localStorage.setItem(STORAGE_KEY, JSON.stringify(data));
}

/** All saved rules (enabled and disabled). */
export function getPatternRules(): PatternRule[] {
  return _read().rules;
}

/** Rules that should currently apply to a given host. */
export function getActiveRulesForHost(host: string): PatternRule[] {
  return getPatternRules().filter((r) => r.enabled && hostMatches(r.hostGlob, host));
}

/** Add a new rule. */
export function addPatternRule(rule: Omit<PatternRule, 'id' | 'enabled'> & Partial<Pick<PatternRule, 'enabled'>>): string {
  const rules = getPatternRules();
  const id = _newId();
  rules.push({
    id,
    name: rule.name,
    pattern: rule.pattern,
    urlTemplate: rule.urlTemplate,
    hostGlob: rule.hostGlob,
    enabled: rule.enabled !== false,
  });
  _write(rules);
  return id;
}

export function updatePatternRule(id: string, patch: Partial<Omit<PatternRule, 'id'>>): void {
  const rules = getPatternRules();
  const idx = rules.findIndex((r) => r.id === id);
  if (idx < 0) return;
  rules[idx] = { ...rules[idx]!, ...patch };
  _write(rules);
}

export function deletePatternRule(id: string): void {
  _write(getPatternRules().filter((r) => r.id !== id));
}

export function setPatternRules(rules: PatternRule[]): void {
  _write(_sanitize(rules));
}

/** Match a host against a glob.
 *  - empty string or `*` matches everything
 *  - `prefix*`, `*suffix`, `*middle*` — substring match around the wildcard
 *  - otherwise exact equality (case-insensitive)
 */
export function hostMatches(glob: string, host: string): boolean {
  if (!glob || glob === '*') return true;
  const g = glob.toLowerCase();
  const h = host.toLowerCase();
  if (!g.includes('*')) return g === h;
  // Convert glob to a regex with `*` as `.*`. Anchor at start/end.
  // Escape any other regex metacharacters to prevent injection.
  const escaped = g.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*');
  return new RegExp(`^${escaped}$`).test(h);
}

/** Substitute `{match}` and `{host}` in a URL template. */
export function buildLinkUrl(template: string, match: string, host: string): string {
  return template
    .replace(/\{match\}/g, encodeURIComponent(match))
    .replace(/\{host\}/g, encodeURIComponent(host));
}

/** Find all matches of a rule's regex within a single line of text.
 *  Returns each match's start index, length, and captured/match text. The
 *  rule's regex is compiled with `g` flag; if it doesn't have a capture
 *  group, the whole match is used. Errors compiling the regex return []
 *  so a bad rule can't break the link provider. */
export function findRuleMatches(rule: PatternRule, line: string): { start: number; length: number; text: string }[] {
  let re: RegExp;
  try {
    re = new RegExp(rule.pattern, 'g');
  } catch {
    return [];
  }
  const out: { start: number; length: number; text: string }[] = [];
  let m: RegExpExecArray | null;
  while ((m = re.exec(line)) !== null) {
    if (m[0] === '') {
      // Avoid zero-length infinite loops.
      re.lastIndex++;
      continue;
    }
    const text = m[1] ?? m[0];
    out.push({ start: m.index, length: m[0].length, text });
  }
  return out;
}

/** Reassemble soft-wrapped runs in a list of terminal rows. xterm reports
 *  each visible row as a separate string; if a long token wrapped across
 *  rows, the regex would miss it. This helper joins consecutive rows when
 *  a row is exactly `cols` chars long (suggesting wrap rather than newline)
 *  and returns both the joined text and an offset map back to row+col so
 *  the caller can highlight the original spans. */
export interface ReassembledRow {
  text: string;
  /** For each char in `text`, which source row+col it came from. Same length as text. */
  origins: { row: number; col: number }[];
}
export function reassembleSoftWrap(rows: string[], cols: number): ReassembledRow[] {
  const out: ReassembledRow[] = [];
  let i = 0;
  while (i < rows.length) {
    const startRow = i;
    let combined = rows[i] ?? '';
    const origins: { row: number; col: number }[] = [];
    for (let c = 0; c < combined.length; c++) origins.push({ row: i, col: c });
    while (i + 1 < rows.length && rows[i] !== undefined && rows[i]!.length >= cols) {
      i++;
      const next = rows[i] ?? '';
      for (let c = 0; c < next.length; c++) origins.push({ row: i, col: c });
      combined += next;
    }
    out.push({ text: combined, origins });
    void startRow;
    i++;
  }
  return out;
}
