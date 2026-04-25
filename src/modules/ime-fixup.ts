/**
 * modules/ime-fixup.ts — Terminal-copy fixup
 *
 * Round-trip text copied out of the terminal (where xterm soft-wraps long
 * URLs / commands / API keys with newline + indent or bare newlines) back
 * into one clean executable line.
 *
 * Two strategies:
 *
 * 1. `reconstructFromBuffer(terminal, range)` — preferred. Walks xterm's
 *    own buffer using `IBufferLine.isWrapped` to distinguish soft-wrap
 *    artifacts (true) from genuine newlines written by the producer (false).
 *    Lossless and deterministic — no heuristics involved.
 *
 * 2. `fixupTerminalCopy(text)` — heuristic fallback. Used when we only
 *    have the post-copy clipboard string (e.g. text pasted in from the IME
 *    preview). Best-effort.
 *
 * Both are deterministic; neither does semantic guessing.
 */

// Minimal structural types so this module doesn't have to depend on the
// full @xterm/xterm typings (kept tree-shakeable for tests).
interface IBufferLineLike {
  isWrapped: boolean;
  translateToString(trimRight?: boolean, startCol?: number, endCol?: number): string;
}
interface IBufferLike {
  getLine(y: number): IBufferLineLike | undefined;
}
interface ITerminalLike {
  cols: number;
  buffer: { active: IBufferLike };
}
interface IBufferRangeLike {
  start: { x: number; y: number };
  end:   { x: number; y: number };
}

/** Reconstruct a selection's text from xterm's buffer using `isWrapped`
 *  metadata. A row whose next row has `isWrapped=true` was a soft wrap
 *  inserted by xterm because content overflowed the right margin — the join
 *  is lossless. A row whose next row has `isWrapped=false` was a real
 *  newline written by the producer, preserved as `\n`.
 *
 *  Range coordinates are inclusive on both ends (xterm convention). */
export function reconstructFromBuffer(
  terminal: ITerminalLike,
  range: IBufferRangeLike,
): string {
  const buf = terminal.buffer.active;
  const cols = terminal.cols;
  const startY = range.start.y;
  const startX = range.start.x;
  const endY = range.end.y;
  // xterm reports end.x as exclusive in some flows and inclusive in others;
  // clamp to [0, cols] either way.
  const endX = Math.max(0, Math.min(cols, range.end.x));

  if (endY < startY) return '';

  let out = '';
  for (let y = startY; y <= endY; y++) {
    const line = buf.getLine(y);
    if (!line) continue;
    const sCol = y === startY ? startX : 0;
    const eCol = y === endY ? endX : cols;
    if (eCol <= sCol && y !== endY) continue;
    // translateToString(trimRight, startCol, endCol) — endCol exclusive.
    const slice = line.translateToString(false, sCol, eCol);
    out += slice;
    if (y < endY) {
      const next = buf.getLine(y + 1);
      // Soft wrap: the next row tells us *it* is a continuation. Join lossless.
      if (next?.isWrapped) {
        // no separator
      } else {
        out += '\n';
      }
    }
  }
  return out;
}

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
