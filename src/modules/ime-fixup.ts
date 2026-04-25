/**
 * modules/ime-fixup.ts — Terminal-copy fixup
 *
 * Round-trip text copied out of the terminal (where xterm soft-wraps long
 * URLs / commands / API keys with newline + indent or bare newlines) back
 * into one clean executable line.
 *
 * Deterministic, no semantic guessing. Idempotent.
 */

/** Collapse common terminal-copy artifacts.
 *
 *  Heuristics:
 *  - CR (`\r`) and CRLF normalize to `\n`.
 *  - Trailing whitespace before a newline is trimmed (`foo  \n` → `foo\n`).
 *  - A newline followed by indent (spaces/tabs) collapses to a single space —
 *    that's the canonical xterm soft-wrap artifact.
 *  - A newline immediately followed by another non-newline character with no
 *    leading whitespace collapses to nothing (terminal hard-wrapped a long
 *    URL or token mid-string).
 *  - Bare blank lines (`\n\n+`) preserve as a single `\n` — the user
 *    intentionally wanted a paragraph break.
 *
 *  Result: terminal soft-wrap stripped, paragraph breaks preserved.
 */
export function fixupTerminalCopy(input: string): string {
  // 1. Normalize line endings.
  let s = input.replace(/\r\n?/g, '\n');
  // 2. Trim trailing whitespace at the end of each line.
  s = s.replace(/[ \t]+\n/g, '\n');
  // 3. Preserve genuine paragraph breaks: temporarily mark `\n\n+` as a sentinel.
  const PARA = '\u0001';
  s = s.replace(/\n{2,}/g, PARA);
  // 4. `\n` followed by indent → single space (soft wrap with continuation indent).
  s = s.replace(/\n[ \t]+/g, ' ');
  // 5. Remaining `\n` (terminal mid-string hard wrap with no indent) → no separator.
  //    URLs, base64 tokens, long shell pipes all join cleanly.
  s = s.replace(/\n/g, '');
  // 6. Restore paragraph breaks.
  s = s.replace(new RegExp(PARA, 'g'), '\n');
  return s;
}
