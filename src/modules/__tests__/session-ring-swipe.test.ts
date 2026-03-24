import { describe, it, expect } from 'vitest';

/**
 * Issue #287: ring-based session swipe — wrap around at ends.
 *
 * The swipe handler in ui.ts computes a target session index from the current
 * active session and the swipe direction. These tests verify the index
 * calculation logic: when swiping past the last session it should wrap to the
 * first, and vice versa.
 *
 * The function under test is a pure extraction of the index arithmetic that
 * the swipe handler should use once #287 is implemented.
 */

/**
 * Ring-swipe index calculation.
 *
 * @param current  Index of the active session in the keys array
 * @param count    Total number of sessions
 * @param direction  +1 (swipe left → next) or -1 (swipe right → prev)
 * @returns Target index, wrapped modulo count, or -1 if count <= 1
 */
function ringSwipeTarget(current: number, count: number, direction: 1 | -1): number {
  if (count <= 1) return -1;
  return (current + direction + count) % count;
}

describe('issue-287: ring-based session swipe', () => {
  describe('swipe past last session wraps to first', () => {
    it('3 sessions, at index 2, swipe left (next) → index 0', () => {
      expect(ringSwipeTarget(2, 3, 1)).toBe(0);
    });

    it('5 sessions, at index 4, swipe left (next) → index 0', () => {
      expect(ringSwipeTarget(4, 5, 1)).toBe(0);
    });
  });

  describe('swipe past first session wraps to last', () => {
    it('3 sessions, at index 0, swipe right (prev) → index 2', () => {
      expect(ringSwipeTarget(0, 3, -1)).toBe(2);
    });

    it('5 sessions, at index 0, swipe right (prev) → index 4', () => {
      expect(ringSwipeTarget(0, 5, -1)).toBe(4);
    });
  });

  describe('single session does not wrap to self', () => {
    it('returns -1 for swipe left with 1 session', () => {
      expect(ringSwipeTarget(0, 1, 1)).toBe(-1);
    });

    it('returns -1 for swipe right with 1 session', () => {
      expect(ringSwipeTarget(0, 1, -1)).toBe(-1);
    });

    it('returns -1 for zero sessions', () => {
      expect(ringSwipeTarget(0, 0, 1)).toBe(-1);
    });
  });

  describe('two sessions wrap correctly both directions', () => {
    it('at index 0, swipe left (next) → index 1', () => {
      expect(ringSwipeTarget(0, 2, 1)).toBe(1);
    });

    it('at index 1, swipe left (next) → index 0', () => {
      expect(ringSwipeTarget(1, 2, 1)).toBe(0);
    });

    it('at index 0, swipe right (prev) → index 1', () => {
      expect(ringSwipeTarget(0, 2, -1)).toBe(1);
    });

    it('at index 1, swipe right (prev) → index 0', () => {
      expect(ringSwipeTarget(1, 2, -1)).toBe(0);
    });
  });

  describe('non-boundary swipes still work (no regression)', () => {
    it('at index 1 of 3, swipe left (next) → index 2', () => {
      expect(ringSwipeTarget(1, 3, 1)).toBe(2);
    });

    it('at index 1 of 3, swipe right (prev) → index 0', () => {
      expect(ringSwipeTarget(1, 3, -1)).toBe(0);
    });
  });
});
