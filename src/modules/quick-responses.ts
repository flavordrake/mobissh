/**
 * modules/quick-responses.ts — User-defined one-tap response buttons (#480)
 *
 * The user can save short phrases (e.g., "go", "status versus goal") that
 * become floating chips above the keybar. Tap a chip → send the stored text
 * (and optionally `\r`) to the active terminal.
 *
 * Storage: localStorage('quickResponses') — JSON array, schema versioned in
 * the value (per the project's "no key bumping for migration" rule). The
 * helpers here only know about storage + the data model. Render and send
 * are wired up in ui.ts where the active session and the input pipeline
 * are reachable.
 */

const STORAGE_KEY = 'quickResponses';
const SCHEMA_VERSION = 1;

export interface QuickResponse {
  /** Stable id used for edit/delete/reorder operations. */
  id: string;
  /** Short text shown on the chip. */
  label: string;
  /** Text sent when the chip is tapped. */
  text: string;
  /** Append `\r` after the text on send. Defaults to true. */
  appendEnter: boolean;
  /** When false, the entry is hidden from the chip strip but kept in storage
   *  (so the user can toggle without losing the phrase). */
  enabled: boolean;
}

interface StorageShape {
  version: number;
  entries: QuickResponse[];
}

function _read(): StorageShape {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return { version: SCHEMA_VERSION, entries: [] };
    const parsed = JSON.parse(raw) as unknown;
    // Tolerate a bare array (older personal exports / hand-written localStorage)
    // by wrapping it in the current schema shape.
    if (Array.isArray(parsed)) {
      return { version: SCHEMA_VERSION, entries: _sanitize(parsed as unknown[]) };
    }
    if (parsed && typeof parsed === 'object' && Array.isArray((parsed as StorageShape).entries)) {
      return { version: SCHEMA_VERSION, entries: _sanitize((parsed as StorageShape).entries as unknown[]) };
    }
  } catch {
    // fall through
  }
  return { version: SCHEMA_VERSION, entries: [] };
}

function _sanitize(raw: unknown[]): QuickResponse[] {
  const out: QuickResponse[] = [];
  for (const item of raw) {
    if (!item || typeof item !== 'object') continue;
    const r = item as Record<string, unknown>;
    // Require non-empty label and text — entries with only one of the two,
    // or empty strings, are partial drafts and shouldn't render as chips.
    if (typeof r.label !== 'string' || r.label === '') continue;
    if (typeof r.text !== 'string' || r.text === '') continue;
    out.push({
      id: typeof r.id === 'string' && r.id ? r.id : _newId(),
      label: r.label,
      text: r.text,
      appendEnter: r.appendEnter !== false,
      enabled: r.enabled !== false,
    });
  }
  return out;
}

function _newId(): string {
  return `qr_${Math.random().toString(36).slice(2, 10)}`;
}

function _write(entries: QuickResponse[]): void {
  const data: StorageShape = { version: SCHEMA_VERSION, entries };
  localStorage.setItem(STORAGE_KEY, JSON.stringify(data));
}

/** All saved quick-responses, including disabled ones. */
export function getQuickResponses(): QuickResponse[] {
  return _read().entries;
}

/** Only entries that should currently render as chips. */
export function getEnabledQuickResponses(): QuickResponse[] {
  return getQuickResponses().filter((q) => q.enabled);
}

/** Add a new entry to the end of the list. Returns the assigned id. */
export function addQuickResponse(label: string, text: string, appendEnter = true): string {
  const entries = getQuickResponses();
  const id = _newId();
  entries.push({ id, label, text, appendEnter, enabled: true });
  _write(entries);
  return id;
}

/** Update an existing entry. Pass only the fields you want to change. */
export function updateQuickResponse(id: string, patch: Partial<Omit<QuickResponse, 'id'>>): void {
  const entries = getQuickResponses();
  const idx = entries.findIndex((q) => q.id === id);
  if (idx < 0) return;
  entries[idx] = { ...entries[idx]!, ...patch };
  _write(entries);
}

/** Delete an entry by id. Idempotent. */
export function deleteQuickResponse(id: string): void {
  const entries = getQuickResponses().filter((q) => q.id !== id);
  _write(entries);
}

/** Reorder by moving the entry at `fromIdx` to `toIdx`. Indices clamp. */
export function reorderQuickResponse(fromIdx: number, toIdx: number): void {
  const entries = getQuickResponses();
  if (fromIdx < 0 || fromIdx >= entries.length) return;
  const clamped = Math.max(0, Math.min(toIdx, entries.length - 1));
  if (clamped === fromIdx) return;
  const [moved] = entries.splice(fromIdx, 1);
  if (moved) entries.splice(clamped, 0, moved);
  _write(entries);
}

/** Replace the full list — used by settings UI batch-save flows. */
export function setQuickResponses(entries: QuickResponse[]): void {
  _write(_sanitize(entries));
}
