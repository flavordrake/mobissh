/**
 * modules/favorites.ts — Files panel favorites (#470)
 *
 * Per-profile bookmarks for SFTP paths. Single localStorage key `filesFavorites`
 * holds a map of `"host:port:username"` → `Favorite[]`. All reads guard against
 * corrupt / malformed data and fall back to an empty list.
 */

import type { Favorite } from './types.js';

const FAVORITES_KEY = 'filesFavorites';

type FavoritesMap = Record<string, Favorite[]>;

/** Canonical profile identity for favorites keying. */
export function profileIdOf(profile: { host: string; port: number; username: string }): string {
  return `${profile.host}:${String(profile.port)}:${profile.username}`;
}

/** Read the whole favorites map from localStorage. Returns {} on any failure. */
function _readMap(): FavoritesMap {
  try {
    const raw = localStorage.getItem(FAVORITES_KEY);
    if (!raw) return {};
    const parsed: unknown = JSON.parse(raw);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return {};
    return parsed as FavoritesMap;
  } catch {
    return {};
  }
}

function _writeMap(map: FavoritesMap): void {
  localStorage.setItem(FAVORITES_KEY, JSON.stringify(map));
}

/** List favorites for a given profile id. Empty list for unknown profile. */
export function listFavorites(profileId: string): Favorite[] {
  const map = _readMap();
  const entries = map[profileId];
  if (!Array.isArray(entries)) return [];
  return entries.filter((e) => e && typeof e.path === 'string' && typeof e.isFile === 'boolean');
}

/** True when the given path is favorited for the given profile. */
export function isFavorited(profileId: string, path: string): boolean {
  return listFavorites(profileId).some((f) => f.path === path);
}

/** Toggle favorite state. Returns the NEW isFavorited state (true = added, false = removed). */
export function toggleFavorite(profileId: string, fav: Favorite): boolean {
  const map = _readMap();
  const list = Array.isArray(map[profileId]) ? map[profileId]! : [];
  const idx = list.findIndex((f) => f.path === fav.path);
  if (idx >= 0) {
    list.splice(idx, 1);
    map[profileId] = list;
    _writeMap(map);
    return false;
  }
  list.push({ path: fav.path, isFile: fav.isFile, ...(fav.label ? { label: fav.label } : {}) });
  map[profileId] = list;
  _writeMap(map);
  return true;
}
