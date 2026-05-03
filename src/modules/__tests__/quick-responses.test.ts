/**
 * Quick-response storage helpers (#480).
 *
 * Contract:
 * - Add/update/delete/reorder operate on the same persisted JSON array.
 * - Schema version lives INSIDE the value (per project rule), not in the key.
 * - Bare-array values from older exports are tolerated and re-wrapped.
 * - getEnabledQuickResponses filters disabled entries.
 * - sanitize drops malformed records (missing label/text) without throwing.
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';

const storage = new Map<string, string>();
vi.stubGlobal('localStorage', {
  getItem: (key: string) => storage.get(key) ?? null,
  setItem: (key: string, value: string) => { storage.set(key, value); },
  removeItem: (key: string) => { storage.delete(key); },
  clear: () => { storage.clear(); },
  get length() { return storage.size; },
  key: (_i: number) => null as string | null,
});

const {
  getQuickResponses,
  getEnabledQuickResponses,
  addQuickResponse,
  updateQuickResponse,
  deleteQuickResponse,
  reorderQuickResponse,
  setQuickResponses,
} = await import('../quick-responses.js');

beforeEach(() => {
  storage.clear();
});

describe('quick responses — storage round-trip', () => {
  it('returns empty array when nothing is saved', () => {
    expect(getQuickResponses()).toEqual([]);
  });

  it('add + get round-trips an entry with default flags', () => {
    const id = addQuickResponse('Go', 'go');
    const all = getQuickResponses();
    expect(all).toHaveLength(1);
    expect(all[0]).toMatchObject({ id, label: 'Go', text: 'go', appendEnter: true, enabled: true });
  });

  it('appendEnter=false is honored', () => {
    addQuickResponse('No Enter', 'set foo=bar', false);
    expect(getQuickResponses()[0]?.appendEnter).toBe(false);
  });

  it('persists across re-reads (storage round-trip)', () => {
    addQuickResponse('A', 'a');
    addQuickResponse('B', 'b');
    expect(getQuickResponses().map((q) => q.label)).toEqual(['A', 'B']);
  });
});

describe('quick responses — enabled filter', () => {
  it('hides disabled entries from the enabled-only list', () => {
    const a = addQuickResponse('A', 'a');
    addQuickResponse('B', 'b');
    updateQuickResponse(a, { enabled: false });
    const enabled = getEnabledQuickResponses();
    expect(enabled.map((q) => q.label)).toEqual(['B']);
    // Full list still includes both.
    expect(getQuickResponses()).toHaveLength(2);
  });
});

describe('quick responses — update / delete', () => {
  it('updateQuickResponse patches fields', () => {
    const id = addQuickResponse('Old', 'old text');
    updateQuickResponse(id, { label: 'New', text: 'new text', appendEnter: false });
    const entry = getQuickResponses()[0]!;
    expect(entry.label).toBe('New');
    expect(entry.text).toBe('new text');
    expect(entry.appendEnter).toBe(false);
  });

  it('updateQuickResponse for unknown id is a no-op', () => {
    addQuickResponse('A', 'a');
    updateQuickResponse('not-real', { label: 'X' });
    expect(getQuickResponses()[0]?.label).toBe('A');
  });

  it('deleteQuickResponse removes by id and is idempotent', () => {
    const id = addQuickResponse('A', 'a');
    deleteQuickResponse(id);
    expect(getQuickResponses()).toEqual([]);
    deleteQuickResponse(id); // no throw
    expect(getQuickResponses()).toEqual([]);
  });
});

describe('quick responses — reorder', () => {
  it('moves an entry from one position to another', () => {
    addQuickResponse('A', 'a');
    addQuickResponse('B', 'b');
    addQuickResponse('C', 'c');
    reorderQuickResponse(2, 0); // move C to top
    expect(getQuickResponses().map((q) => q.label)).toEqual(['C', 'A', 'B']);
  });

  it('clamps overshoot to last index', () => {
    addQuickResponse('A', 'a');
    addQuickResponse('B', 'b');
    reorderQuickResponse(0, 99);
    expect(getQuickResponses().map((q) => q.label)).toEqual(['B', 'A']);
  });

  it('no-ops when from === to', () => {
    addQuickResponse('A', 'a');
    addQuickResponse('B', 'b');
    reorderQuickResponse(1, 1);
    expect(getQuickResponses().map((q) => q.label)).toEqual(['A', 'B']);
  });
});

describe('quick responses — schema tolerance', () => {
  it('reads a bare-array value (older export) and re-wraps on next write', () => {
    storage.set('quickResponses', JSON.stringify([
      { id: 'x', label: 'A', text: 'a', appendEnter: true, enabled: true },
    ]));
    expect(getQuickResponses().map((q) => q.label)).toEqual(['A']);
    addQuickResponse('B', 'b');
    // After a write, value is the schema-wrapped shape.
    const stored = JSON.parse(storage.get('quickResponses') ?? '{}') as { version: number; entries: unknown[] };
    expect(stored.version).toBe(1);
    expect(stored.entries).toHaveLength(2);
  });

  it('drops malformed records without throwing', () => {
    storage.set('quickResponses', JSON.stringify({
      version: 1,
      entries: [
        { id: '1', label: 'OK', text: 'ok', appendEnter: true, enabled: true },
        { id: '2', label: 'no text here' }, // missing text
        { id: '3', text: 'no label' }, // missing label
        null,
        'not-an-object',
      ],
    }));
    expect(getQuickResponses().map((q) => q.label)).toEqual(['OK']);
  });

  it('returns empty array on JSON parse failure', () => {
    storage.set('quickResponses', '{not valid json');
    expect(getQuickResponses()).toEqual([]);
  });
});

describe('setQuickResponses', () => {
  it('replaces the full list and re-sanitizes', () => {
    addQuickResponse('A', 'a');
    setQuickResponses([
      { id: '1', label: 'New', text: 'new', appendEnter: true, enabled: true },
      { id: '2', label: '', text: 'no label' } as unknown as never, // dropped
    ]);
    expect(getQuickResponses().map((q) => q.label)).toEqual(['New']);
  });
});
