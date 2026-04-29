/**
 * TDD tests for zombie session after failed reconnect (#341).
 *
 * Three bugs:
 * 1. switchSession doesn't call focusIME — survivor has no input
 * 2. closeSession bypasses state machine — skips AbortController abort
 * 3. _openWebSocket relies on activeSessionId instead of explicit sessionId
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { readFileSync } from 'fs';
import { resolve } from 'path';

const uiSrc = readFileSync(resolve(__dirname, '../ui.ts'), 'utf-8');
const connectionSrc = readFileSync(resolve(__dirname, '../connection.ts'), 'utf-8');

/** Extract a function body from source, handling type annotations. */
function extractFnBody(src: string, fnName: string): string {
  const fnStart = src.indexOf(fnName);
  if (fnStart === -1) return '';
  const sigEnd = src.indexOf('{', src.indexOf(')', fnStart));
  if (sigEnd === -1) return '';
  let depth = 0, fnEnd = sigEnd;
  for (let i = sigEnd; i < src.length; i++) {
    if (src[i] === '{') depth++;
    if (src[i] === '}') depth--;
    if (depth === 0) { fnEnd = i + 1; break; }
  }
  return src.slice(fnStart, fnEnd);
}

describe('Zombie session prevention (#341)', () => {

  // ── Bug 1: switchSession must call focusIME ──

  describe('switchSession calls focusIME', () => {
    it('switchSession function body contains focusIME call', () => {
      const body = extractFnBody(uiSrc, 'function switchSession');
      expect(body.length).toBeGreaterThan(50);
      expect(body).toContain('focusIME');
    });
  });

  // ── Bug 2: closeSession must use transitionSession, not sessions.delete ──

  describe('closeSession uses state machine', () => {
    it('closeSession does NOT directly call sessions.delete', () => {
      const body = extractFnBody(uiSrc, 'function closeSession');
      expect(body.length).toBeGreaterThan(50);
      // Should not have direct map deletion
      expect(body).not.toMatch(/sessions\.delete\s*\(/);
      expect(body).not.toMatch(/appState\.sessions\.delete\s*\(/);
    });

    it('closeSession calls transitionSession to closed', () => {
      const body = extractFnBody(uiSrc, 'function closeSession');
      expect(body.length).toBeGreaterThan(50);
      expect(body).toMatch(/transitionSession\s*\(/);
      expect(body).toContain("'closed'");
    });
  });

  // ── Bug 3: _openWebSocket takes explicit sessionId ──

  describe('_openWebSocket uses explicit sessionId', () => {
    it('_openWebSocket accepts sessionId parameter', () => {
      // The function signature should accept sessionId, not rely on currentSession()
      const fnStart = connectionSrc.indexOf('function _openWebSocket');
      expect(fnStart).toBeGreaterThan(-1);
      const sigEnd = connectionSrc.indexOf(')', fnStart);
      const signature = connectionSrc.slice(fnStart, sigEnd + 1);
      expect(signature).toMatch(/sessionId|session_id|sid/i);
    });

    it('_openWebSocket does not call currentSession() for its main session reference', () => {
      const body = extractFnBody(connectionSrc, 'function _openWebSocket');
      expect(body.length).toBeGreaterThan(100);
      // Should not use currentSession() to get the session it operates on.
      // It may still use currentSession() in callbacks for the ACTIVE session,
      // but the primary session variable should come from the parameter.
      // Check that `let session = currentSession()` or `const session = currentSession()`
      // at the top of the function is gone.
      expect(body).not.toMatch(/(?:let|const)\s+session\s*=\s*currentSession\s*\(\s*\)/);
    });

    it('visibilitychange handler passes sessionId to _openWebSocket', () => {
      // The visibilitychange handler should pass the session id explicitly
      // instead of mutating appState.activeSessionId
      const visStart = connectionSrc.indexOf('visibilitychange');
      expect(visStart).toBeGreaterThan(-1);
      const visBlock = connectionSrc.slice(visStart, visStart + 5000);
      // Should pass sid/sessionId to _openWebSocket via options object or argument
      const passesId = visBlock.includes('_openWebSocket(') &&
        (visBlock.match(/_openWebSocket\s*\(\s*\{[^}]*sessionId\s*:\s*sid/s) ||
         visBlock.match(/_openWebSocket\s*\(\s*sid/) ||
         visBlock.match(/_openWebSocket\s*\([^)]*sid[^)]*\)/));
      expect(passesId).toBeTruthy();
    });
  });
});
