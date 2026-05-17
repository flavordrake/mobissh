/**
 * Profile order persistence (#481): a separate localStorage array of vaultIds
 * controls the display order of saved profiles.
 *
 * Contract enforced by these tests:
 * - Round-trip: setProfileOrder/getProfileOrder preserves order.
 * - sortProfilesByOrder: sorted profiles match the order array; profiles
 *   missing from the order append at the end (stable insertion-order
 *   relative to the input).
 * - moveProfileToPosition: 0 = top, -1 = bottom, n = insert at index.
 * - removeProfileFromOrder: cleanly drops the id from the order.
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';

// Minimal localStorage stub — profile-order.ts has no other browser deps.
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
  getProfileOrder,
  setProfileOrder,
  sortProfilesByOrder,
  moveProfileToPosition,
  removeProfileFromOrder,
} = await import('../profile-order.js');

interface MinimalProfile {
  vaultId: string;
  title: string;
  host: string;
  port: number;
  username: string;
  authType: string;
  initialCommand: string;
}

function p(vaultId: string): MinimalProfile {
  return { vaultId, title: vaultId, host: `${vaultId}.example`, port: 22, username: 'u', authType: 'password', initialCommand: '' };
}

beforeEach(() => {
  localStorage.clear();
});

describe('profile order — storage round-trip', () => {
  it('returns empty array when no order is set', () => {
    expect(getProfileOrder()).toEqual([]);
  });

  it('round-trips a list of vaultIds', () => {
    setProfileOrder(['a', 'b', 'c']);
    expect(getProfileOrder()).toEqual(['a', 'b', 'c']);
  });

  it('returns empty array on corrupt localStorage value', () => {
    localStorage.setItem('profileOrder', 'not-json');
    expect(getProfileOrder()).toEqual([]);
  });

  it('filters non-string entries defensively', () => {
    localStorage.setItem('profileOrder', JSON.stringify(['a', 42, null, 'b']));
    expect(getProfileOrder()).toEqual(['a', 'b']);
  });
});

describe('sortProfilesByOrder', () => {
  it('returns the input unchanged when no order is set', () => {
    const profiles = [p('a'), p('b'), p('c')];
    expect(sortProfilesByOrder(profiles).map((x) => x.vaultId)).toEqual(['a', 'b', 'c']);
  });

  it('sorts profiles to match the order array', () => {
    setProfileOrder(['c', 'a', 'b']);
    const profiles = [p('a'), p('b'), p('c')];
    expect(sortProfilesByOrder(profiles).map((x) => x.vaultId)).toEqual(['c', 'a', 'b']);
  });

  it('appends profiles missing from the order at the end (insertion order preserved)', () => {
    setProfileOrder(['b']);
    const profiles = [p('a'), p('b'), p('c')];
    // 'b' first per order; 'a' and 'c' append in their original input order.
    expect(sortProfilesByOrder(profiles).map((x) => x.vaultId)).toEqual(['b', 'a', 'c']);
  });

  it('skips order entries that no longer exist in the profile list', () => {
    setProfileOrder(['gone', 'a', 'also-gone', 'b']);
    const profiles = [p('a'), p('b')];
    expect(sortProfilesByOrder(profiles).map((x) => x.vaultId)).toEqual(['a', 'b']);
  });
});

describe('moveProfileToPosition', () => {
  it('writes a fresh order with the moved id at the requested position', () => {
    setProfileOrder(['a', 'b', 'c']);
    moveProfileToPosition('c', 0, [p('a'), p('b'), p('c')]);
    expect(getProfileOrder()).toEqual(['c', 'a', 'b']);
  });

  it('-1 means move to bottom', () => {
    setProfileOrder(['a', 'b', 'c']);
    moveProfileToPosition('a', -1, [p('a'), p('b'), p('c')]);
    expect(getProfileOrder()).toEqual(['b', 'c', 'a']);
  });

  it('seeds order from raw profiles when none was set yet (move-to-top with empty order)', () => {
    moveProfileToPosition('b', 0, [p('a'), p('b'), p('c')]);
    expect(getProfileOrder()).toEqual(['b', 'a', 'c']);
  });

  it('clamps overshoot to end position', () => {
    setProfileOrder(['a', 'b', 'c']);
    moveProfileToPosition('a', 99, [p('a'), p('b'), p('c')]);
    expect(getProfileOrder()).toEqual(['b', 'c', 'a']);
  });
});

describe('removeProfileFromOrder', () => {
  it('drops the id and preserves remaining order', () => {
    setProfileOrder(['a', 'b', 'c']);
    removeProfileFromOrder('b');
    expect(getProfileOrder()).toEqual(['a', 'c']);
  });

  it('is idempotent for ids not in the order', () => {
    setProfileOrder(['a', 'b']);
    removeProfileFromOrder('not-there');
    expect(getProfileOrder()).toEqual(['a', 'b']);
  });
});
