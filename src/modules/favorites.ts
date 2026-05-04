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
  return entries.filter((e) => typeof e.path === 'string' && typeof e.isFile === 'boolean');
}

/** True when the given path is favorited for the given profile. */
export function isFavorited(profileId: string, path: string): boolean {
  return listFavorites(profileId).some((f) => f.path === path);
}

/** Longest common path-segment prefix across `paths`. Always stops one
 *  segment short of the shortest path so a single common-parent set still
 *  shows distinguishable leaves. Returns '' when there's no shared prefix. */
export function commonPathPrefix(paths: string[]): string {
  if (paths.length < 2) return '';
  const splits = paths.map((p) => p.split('/'));
  const minLen = Math.min(...splits.map((s) => s.length));
  let i = 0;
  while (i < minLen - 1 && splits.every((s) => s[i] === splits[0]![i])) i++;
  if (i === 0) return '';
  return splits[0]!.slice(0, i).join('/');
}

/** Strip a leading common prefix from a path, replacing it with `…/`. */
export function collapsePrefix(path: string, prefix: string): string {
  if (!prefix) return path;
  if (!path.startsWith(prefix + '/')) return path;
  return '…/' + path.slice(prefix.length + 1);
}

/** Toggle favorite state. Returns the NEW isFavorited state (true = added, false = removed). */
export function toggleFavorite(profileId: string, fav: Favorite): boolean {
  const map = _readMap();
  const existing = map[profileId];
  const list = Array.isArray(existing) ? existing : [];
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
