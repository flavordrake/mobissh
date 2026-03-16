/**
 * modules/ime-diff.ts — cursor-relative diff for IME autocorrect
 *
 * Computes the minimal {deletions, insertion} to transform oldVal → newVal
 * assuming the cursor is at the end of oldVal and deletions are backspaces.
 *
 * Extracted from _sendDiff in ime.ts for testability (#177).
 */

export interface DiffResult {
  /** Number of backspace (DEL) characters to send. */
  deletions: number;
  /** Text to insert after backspacing. */
  insertion: string;
}

/**
 * Compute the diff between oldVal and newVal as cursor-relative operations.
 *
 * Since backspace deletes from the end (cursor position), only a common prefix
 * can be preserved. A "common suffix" in string terms would require the cursor
 * to skip over it, which backspace cannot do. So we only use the common prefix.
 */
export function computeDiff(oldVal: string, newVal: string): DiffResult {
  if (oldVal === newVal) return { deletions: 0, insertion: '' };

  // Find longest common prefix — this is the only part we can keep,
  // because backspace always deletes from the end.
  let prefix = 0;
  while (prefix < oldVal.length && prefix < newVal.length && oldVal[prefix] === newVal[prefix]) {
    prefix++;
  }

  // Everything after the common prefix in oldVal must be deleted (backspaced from end).
  const deletions = oldVal.length - prefix;
  // Everything after the common prefix in newVal must be inserted.
  const insertion = newVal.slice(prefix);

  return { deletions, insertion };
}
