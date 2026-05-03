/**
 * modules/profile-order.ts — profile display ordering (#481)
 *
 * Pure storage + array helpers for ordering profile cards. Kept separate from
 * profiles.ts so the storage logic is unit-testable without pulling in the
 * full settings/UI/connection import chain.
 *
 * Storage shape: a JSON array of profile vaultIds in display order, persisted
 * at localStorage[profileOrder]. Profiles missing from the order array fall
 * to the end (preserves "new profile appears" semantics on cold-import).
 */

const PROFILE_ORDER_KEY = 'profileOrder';

interface ProfileLike {
  vaultId: string;
}

/** Read the ordered list of profile vaultIds from localStorage. */
export function getProfileOrder(): string[] {
  try {
    const raw = localStorage.getItem(PROFILE_ORDER_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed.filter((x): x is string => typeof x === 'string');
  } catch {
    return [];
  }
}

/** Write the ordered list of profile vaultIds to localStorage. */
export function setProfileOrder(order: string[]): void {
  localStorage.setItem(PROFILE_ORDER_KEY, JSON.stringify(order));
}

/** Return profiles sorted by `profileOrder`, with unordered profiles appended
 *  at the end in their stored (insertion) order. Profiles whose vaultId no
 *  longer exists are skipped. Idempotent: safe to call repeatedly. */
export function sortProfilesByOrder<T extends ProfileLike>(profiles: T[]): T[] {
  const order = getProfileOrder();
  if (order.length === 0) return profiles;
  const byVaultId = new Map<string, T>();
  for (const p of profiles) {
    if (p.vaultId) byVaultId.set(p.vaultId, p);
  }
  const sorted: T[] = [];
  const seen = new Set<string>();
  for (const id of order) {
    const p = byVaultId.get(id);
    if (p) {
      sorted.push(p);
      seen.add(id);
    }
  }
  for (const p of profiles) {
    if (!p.vaultId || !seen.has(p.vaultId)) sorted.push(p);
  }
  return sorted;
}

/** Move a profile (by vaultId) to a specific position in the order. Position
 *  -1 means "to end" / "to bottom"; 0 means "to top". Other indices reorder
 *  within the array. New positions clamp to the valid range. Pass the full
 *  profile list so the helper can seed an order from raw insertion order
 *  when none was set yet. */
export function moveProfileToPosition(
  vaultId: string,
  position: number,
  profiles: ProfileLike[],
): void {
  const allIds = profiles.map((p) => p.vaultId).filter((id): id is string => Boolean(id));
  const current = getProfileOrder().filter((id) => allIds.includes(id) && id !== vaultId);
  for (const id of allIds) {
    if (id !== vaultId && !current.includes(id)) current.push(id);
  }
  const insertAt = position < 0 || position > current.length ? current.length : position;
  current.splice(insertAt, 0, vaultId);
  setProfileOrder(current);
}

/** Remove a vaultId from the order array — call when a profile is deleted. */
export function removeProfileFromOrder(vaultId: string): void {
  const order = getProfileOrder().filter((id) => id !== vaultId);
  setProfileOrder(order);
}
