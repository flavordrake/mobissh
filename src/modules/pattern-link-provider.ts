/**
 * modules/pattern-link-provider.ts — Bridge user-defined PatternRules to xterm
 * via Terminal.registerLinkProvider (#478).
 *
 * Reads the rule set lazily on each provideLinks call so live edits in the
 * settings UI take effect on the next mouse hover. Soft-wrap is handled by
 * walking back to the unwrapped row, joining wrapped continuations, running
 * the regex on the joined text, and mapping match offsets back to per-row
 * IBufferRange spans (xterm's own way of highlighting wrapped links).
 */

import type { PatternRule } from './pattern-links.js';
import { getActiveRulesForHost, findRuleMatches, buildLinkUrl } from './pattern-links.js';

interface XLink {
  range: { start: { x: number; y: number }; end: { x: number; y: number } };
  text: string;
  activate(event: MouseEvent, text: string): void;
}

interface XLinkProvider {
  provideLinks(bufferLineNumber: number, callback: (links: XLink[] | undefined) => void): void;
}

/** Build an xterm ILinkProvider for a session. The provider re-reads the
 *  rule set on every invocation so settings changes take effect immediately. */
export function makePatternLinkProvider(opts: {
  terminal: Terminal;
  getHost: () => string;
  open?: (url: string) => void;
}): XLinkProvider {
  const { terminal, getHost } = opts;
  const open = opts.open ?? ((url: string) => { window.open(url, '_blank', 'noopener,noreferrer'); });

  return {
    provideLinks(bufferLineNumber, callback): void {
      const rules = getActiveRulesForHost(getHost());
      if (rules.length === 0) { callback(undefined); return; }

      const buf = terminal.buffer.active;
      // xterm gives us a 1-based line number; getLine() expects 0-based.
      const startY = bufferLineNumber - 1;
      const startLine = buf.getLine(startY);
      if (!startLine) { callback(undefined); return; }

      // Walk back to the unwrapped origin so we don't run regex twice on the
      // same logical line (once from each wrapped row would double-report).
      let originY = startY;
      while (originY > 0) {
        const prev = buf.getLine(originY);
        if (!prev?.isWrapped) break;
        originY -= 1;
      }
      if (originY !== startY) { callback(undefined); return; }

      // Join the unwrapped row with any subsequent wrapped continuations.
      const rowTexts: string[] = [];
      let y = originY;
      while (y < buf.length) {
        const ln = buf.getLine(y);
        if (!ln) break;
        if (y !== originY && !ln.isWrapped) break;
        rowTexts.push(ln.translateToString(false));
        y += 1;
      }

      const cols = terminal.cols;
      const joined = rowTexts.join('');
      if (joined.length === 0) { callback(undefined); return; }

      const links: XLink[] = [];
      for (const rule of rules) {
        for (const m of findRuleMatches(rule, joined)) {
          const url = buildLinkUrl(rule.urlTemplate, m.text, getHost());
          // Map joined-string offsets back to (row, col). xterm rows and cols
          // are 1-based; offset within a row is 0-based, so col = offset + 1.
          const startRow = originY + Math.floor(m.start / cols);
          const startCol = (m.start % cols) + 1;
          const endOffset = m.start + m.length - 1;
          const endRow = originY + Math.floor(endOffset / cols);
          const endCol = (endOffset % cols) + 1;
          links.push(splitLink(rule, m.text, url, startRow, startCol, endRow, endCol, open));
        }
      }
      callback(links.length > 0 ? links : undefined);
    },
  };
}

/** xterm only highlights a contiguous range on a single row — for a wrapped
 *  match we emit one ILink per row covered. The activate handler is shared
 *  so clicking any row of the wrapped match opens the same URL. */
function splitLink(
  _rule: PatternRule,
  text: string,
  url: string,
  startRow: number,
  startCol: number,
  endRow: number,
  endCol: number,
  open: (url: string) => void,
): XLink {
  if (startRow === endRow) {
    return {
      range: { start: { x: startCol, y: startRow + 1 }, end: { x: endCol, y: endRow + 1 } },
      text,
      activate(): void { open(url); },
    };
  }
  // Multi-row case: xterm only renders one range per ILink. Returning the
  // first row keeps it visually consistent with native web links — a wrapped
  // URL highlights the head only, but the click still works.
  return {
    range: { start: { x: startCol, y: startRow + 1 }, end: { x: Number.MAX_SAFE_INTEGER, y: startRow + 1 } },
    text,
    activate(): void { open(url); },
  };
}
