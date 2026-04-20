/**
 * Tests for files favorites storage (#470).
 *
 * Verifies the `favorites.ts` module:
 * 1. Stores favorites per-profile under the single localStorage key `filesFavorites`.
 * 2. `listFavorites(profileId)` returns [] for unknown / corrupt / missing data.
 * 3. `toggleFavorite(profileId, fav)` flips state and returns the NEW isFavorited boolean.
 * 4. `isFavorited(profileId, path)` reflects current state.
 * 5. Multiple profiles are isolated.
 *
 * Also includes structural tests (smoketests) for the files panel chrome DOM
 * additions (docs menu, close X, bookmark slot).
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const storage = new Map<string, string>();
vi.stubGlobal('localStorage', {
  getItem: (key: string) => storage.get(key) ?? null,
  setItem: (key: string, value: string) => { storage.set(key, value); },
  removeItem: (key: string) => { storage.delete(key); },
  clear: () => { storage.clear(); },
  get length() { return storage.size; },
  key: (_i: number) => null as string | null,
});

const FAVORITES_KEY = 'filesFavorites';

const { listFavorites, toggleFavorite, isFavorited, profileIdOf } = await import('../favorites.js');

describe('favorites module (#470)', () => {
  beforeEach(() => {
    storage.clear();
  });

  describe('profileIdOf', () => {
    it('returns "host:port:username" for a profile', () => {
      expect(profileIdOf({ host: 'ex.com', port: 22, username: 'alice' })).toBe('ex.com:22:alice');
    });

    it('handles non-default ports', () => {
      expect(profileIdOf({ host: '10.0.0.1', port: 2222, username: 'root' })).toBe('10.0.0.1:2222:root');
    });
  });

  describe('listFavorites', () => {
    it('returns [] when no favorites are stored', () => {
      expect(listFavorites('host:22:user')).toEqual([]);
    });

    it('returns [] when the stored value is corrupt JSON', () => {
      storage.set(FAVORITES_KEY, '{not valid json');
      expect(listFavorites('host:22:user')).toEqual([]);
    });

    it('returns [] when the stored value is the wrong shape', () => {
      storage.set(FAVORITES_KEY, JSON.stringify('a string, not an object'));
      expect(listFavorites('host:22:user')).toEqual([]);
    });

    it('returns [] for a profile that has no entry in the map', () => {
      storage.set(FAVORITES_KEY, JSON.stringify({
        'other:22:bob': [{ path: '/tmp', isFile: false }],
      }));
      expect(listFavorites('host:22:user')).toEqual([]);
    });

    it('returns the entries for the requested profile only', () => {
      storage.set(FAVORITES_KEY, JSON.stringify({
        'host:22:user': [
          { path: '/home/user', isFile: false },
          { path: '/etc/hosts', isFile: true },
        ],
        'other:22:bob': [{ path: '/tmp', isFile: false }],
      }));
      const favs = listFavorites('host:22:user');
      expect(favs).toHaveLength(2);
      expect(favs[0]?.path).toBe('/home/user');
      expect(favs[1]?.isFile).toBe(true);
    });
  });

  describe('isFavorited', () => {
    it('returns false when nothing is stored', () => {
      expect(isFavorited('host:22:user', '/tmp')).toBe(false);
    });

    it('returns true when the path is in the profile\'s list', () => {
      storage.set(FAVORITES_KEY, JSON.stringify({
        'host:22:user': [{ path: '/tmp', isFile: false }],
      }));
      expect(isFavorited('host:22:user', '/tmp')).toBe(true);
    });

    it('returns false when the path is in a different profile\'s list', () => {
      storage.set(FAVORITES_KEY, JSON.stringify({
        'other:22:bob': [{ path: '/tmp', isFile: false }],
      }));
      expect(isFavorited('host:22:user', '/tmp')).toBe(false);
    });
  });

  describe('toggleFavorite', () => {
    it('adds a favorite and returns true', () => {
      const result = toggleFavorite('host:22:user', { path: '/tmp', isFile: false });
      expect(result).toBe(true);
      expect(isFavorited('host:22:user', '/tmp')).toBe(true);
    });

    it('removes an existing favorite and returns false', () => {
      toggleFavorite('host:22:user', { path: '/tmp', isFile: false });
      const result = toggleFavorite('host:22:user', { path: '/tmp', isFile: false });
      expect(result).toBe(false);
      expect(isFavorited('host:22:user', '/tmp')).toBe(false);
    });

    it('persists the single key `filesFavorites`', () => {
      toggleFavorite('host:22:user', { path: '/tmp', isFile: false });
      const raw = storage.get(FAVORITES_KEY);
      expect(raw).toBeTruthy();
      const parsed = JSON.parse(raw!);
      expect(parsed['host:22:user']).toBeDefined();
      expect(parsed['host:22:user'][0].path).toBe('/tmp');
    });

    it('keeps profiles isolated when toggling', () => {
      toggleFavorite('host:22:user', { path: '/tmp', isFile: false });
      toggleFavorite('other:22:bob', { path: '/tmp', isFile: false });
      expect(listFavorites('host:22:user')).toHaveLength(1);
      expect(listFavorites('other:22:bob')).toHaveLength(1);
      // Remove from one profile; other should be unaffected
      toggleFavorite('host:22:user', { path: '/tmp', isFile: false });
      expect(listFavorites('host:22:user')).toEqual([]);
      expect(isFavorited('other:22:bob', '/tmp')).toBe(true);
    });

    it('survives corrupt existing data (overwrites with fresh map)', () => {
      storage.set(FAVORITES_KEY, '{not valid json');
      const result = toggleFavorite('host:22:user', { path: '/tmp', isFile: false });
      expect(result).toBe(true);
      expect(isFavorited('host:22:user', '/tmp')).toBe(true);
    });

    it('stores isFile flag correctly', () => {
      toggleFavorite('host:22:user', { path: '/etc/hosts', isFile: true });
      const favs = listFavorites('host:22:user');
      expect(favs[0]?.isFile).toBe(true);
      expect(favs[0]?.path).toBe('/etc/hosts');
    });

    it('preserves label when provided', () => {
      toggleFavorite('host:22:user', { path: '/', isFile: false, label: 'root' });
      const favs = listFavorites('host:22:user');
      expect(favs[0]?.label).toBe('root');
    });
  });
});

// ── Structural tests for files panel chrome (#470) ──────────────────────────

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const indexHtml = readFileSync(resolve(__dirname, '../../../public/index.html'), 'utf-8');
const uiSrc = readFileSync(resolve(__dirname, '../ui.ts'), 'utf-8');

describe('files panel chrome DOM (#470)', () => {
  it('#panel-files contains a close X button (#filesCloseBtn)', () => {
    expect(indexHtml).toContain('id="filesCloseBtn"');
  });

  it('#panel-files contains a docs menu button (#filesDocsMenuBtn)', () => {
    expect(indexHtml).toContain('id="filesDocsMenuBtn"');
  });

  it('#panel-files contains the docs menu dropdown (#filesDocsMenu)', () => {
    expect(indexHtml).toContain('id="filesDocsMenu"');
  });

  it('docs menu dropdown contains an Upload action', () => {
    const menuStart = indexHtml.indexOf('id="filesDocsMenu"');
    expect(menuStart).toBeGreaterThan(-1);
    const block = indexHtml.slice(menuStart, menuStart + 500);
    expect(block).toMatch(/data-action="upload"/);
  });

  it('#filesCloseBtn handler calls navigateToPanel(\'terminal\')', () => {
    const start = uiSrc.indexOf("getElementById('filesCloseBtn')");
    expect(start).toBeGreaterThan(-1);
    const block = uiSrc.slice(start, start + 200);
    expect(block).toMatch(/navigateToPanel\(['"]terminal['"]/);
  });

  it('ui.ts imports favorites helpers from ./favorites.js', () => {
    expect(uiSrc).toMatch(/from '\.\/favorites\.js'/);
    expect(uiSrc).toContain('listFavorites');
    expect(uiSrc).toContain('toggleFavorite');
    expect(uiSrc).toContain('isFavorited');
  });

  it('ui.ts renders a bookmark button in .files-breadcrumb', () => {
    expect(uiSrc).toContain('files-bookmark-btn');
  });

  it('ui.ts wires a long-press on sessionFilesBtn that shows favorites', () => {
    expect(uiSrc).toContain('_showFavoritesSubmenu');
    expect(uiSrc).toMatch(/sessionFilesBtn\?\.addEventListener\(['"]touchstart['"]/);
  });
});
