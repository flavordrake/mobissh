import { describe, it, expect } from 'vitest';

/**
 * Media/volume key guard — ensures hardware media keys are never
 * intercepted by the PWA keydown handlers (#221).
 *
 * The guard is a pure function exported from constants.ts so it can be
 * unit-tested without wiring up DOM event listeners.
 */
const { isMediaKey } = await import('../constants.js');

describe('media key guard (#221)', () => {
  const MEDIA_KEYS = [
    'AudioVolumeUp',
    'AudioVolumeDown',
    'AudioVolumeMute',
    'MediaPlayPause',
    'MediaStop',
    'MediaTrackNext',
    'MediaTrackPrevious',
  ];

  for (const key of MEDIA_KEYS) {
    it(`recognises "${key}" as a media key`, () => {
      expect(isMediaKey(key)).toBe(true);
    });
  }

  const NON_MEDIA_KEYS = ['Enter', 'a', 'ArrowUp', 'Escape', 'Tab', 'F1', 'Backspace'];

  for (const key of NON_MEDIA_KEYS) {
    it(`does not flag "${key}" as a media key`, () => {
      expect(isMediaKey(key)).toBe(false);
    });
  }
});
