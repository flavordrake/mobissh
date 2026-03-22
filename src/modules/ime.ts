/**
 * modules/ime.ts — IME input layer
 *
 * Handles all keyboard/IME input routing from hidden textarea (#imeInput)
 * and direct-mode text input (#directInput) to the SSH stream.
 *
 * State machine for IME input (#106):
 *   idle → composing → previewing → editing
 *
 *   idle:       textarea hidden, no text, input sent immediately to SSH
 *   composing:  IME composition in progress (isComposing=true), text accumulating
 *   previewing: composition ended, text visible with action buttons, not yet sent
 *   editing:    user tapped into textarea to manually edit before committing
 *
 * Also manages: touch/swipe gesture handlers (#32/#37/#16) and
 * pinch-to-zoom (#17). Selection is handled by selection.ts (#55).
 */

import type { IMEDeps } from './types.js';
import { KEY_MAP, isMediaKey } from './constants.js';
import { appState } from './state.js';
import { sendSSHInput } from './connection.js';
import { focusIME, setCtrlActive } from './ui.js';
import { isSelectionActive } from './selection.js';
import { computeDiff } from './ime-diff.js';

let _handleResize = (): void => {};
let _applyFontSize = (_size: number): void => {};
let _measureCtx: CanvasRenderingContext2D | null = null;

// ── IME state machine (#106) ────────────────────────────────────────────────
type IMEState = 'idle' | 'composing' | 'previewing' | 'editing';
let _imeState: IMEState = 'idle';

/** Whether "preview mode" is enabled — accumulate compositions for review. */
let _previewMode = localStorage.getItem('imePreviewMode') === 'true';

/** Idle grace period options (ms) (#181). */
export const PREVIEW_IDLE_DELAYS = [1000, 1500, 2000, 3000] as const;
type PreviewIdleDelay = typeof PREVIEW_IDLE_DELAYS[number];

/** Load persisted idle delay or default to 1500ms (#181). */
let _previewIdleDelay: PreviewIdleDelay = (() => {
  const stored = localStorage.getItem('imePreviewIdleDelay');
  const n = Number(stored);
  if (n === 1000 || n === 1500 || n === 2000 || n === 3000) return n;
  return 1500;
})();

/** Visible countdown durations in ms. Infinity = never auto-commit (#169). */
export const PREVIEW_DURATIONS = [3000, 5000, 10000, Infinity] as const;
type PreviewDuration = typeof PREVIEW_DURATIONS[number];

/** Load persisted countdown duration or default to 3000ms. */
let _previewTimeout: PreviewDuration = (() => {
  const stored = localStorage.getItem('imePreviewTimeout');
  if (stored === 'Infinity') return Infinity;
  const n = Number(stored);
  if (n === 3000 || n === 5000 || n === 10000) return n;
  return 3000;
})();

/** Get the current countdown duration (reads localStorage to pick up external changes). */
export function getPreviewTimeout(): PreviewDuration {
  const stored = localStorage.getItem('imePreviewTimeout');
  if (stored === 'Infinity') return (_previewTimeout = Infinity);
  const n = Number(stored);
  if (n === 3000 || n === 5000 || n === 10000) return (_previewTimeout = n);
  return _previewTimeout;
}

/** Set and persist the countdown duration (#181). */
export function setPreviewTimeout(val: PreviewDuration): void {
  _previewTimeout = val;
  localStorage.setItem('imePreviewTimeout', String(val));
}

/** Get the current idle delay (reads localStorage to pick up external changes). */
export function getPreviewIdleDelay(): PreviewIdleDelay {
  const stored = localStorage.getItem('imePreviewIdleDelay');
  const n = Number(stored);
  if (n === 1000 || n === 1500 || n === 2000 || n === 3000) return (_previewIdleDelay = n);
  return _previewIdleDelay;
}

/** Set and persist the idle delay (#181). */
export function setPreviewIdleDelay(val: number): void {
  if (val === 1000 || val === 1500 || val === 2000 || val === 3000) {
    _previewIdleDelay = val;
    localStorage.setItem('imePreviewIdleDelay', String(val));
  }
}

/** Cycle to the next countdown duration and persist. */
function _cyclePreviewDuration(): void {
  const idx = PREVIEW_DURATIONS.indexOf(_previewTimeout);
  _previewTimeout = PREVIEW_DURATIONS[(idx + 1) % PREVIEW_DURATIONS.length]!;
  localStorage.setItem('imePreviewTimeout', String(_previewTimeout));
  console.log('[ime] preview countdown:', _previewTimeout);
}

/** Preview textarea style: 'subtle' | 'accent' | 'glass' (#175). */
const PREVIEW_STYLES = ['subtle', 'accent', 'glass'] as const;
type PreviewStyle = typeof PREVIEW_STYLES[number];
let _previewStyle: PreviewStyle = (() => {
  const stored = localStorage.getItem('imePreviewStyle');
  if (stored === 'accent' || stored === 'glass') return stored;
  return 'subtle';
})();

export function isPreviewMode(): boolean { return _previewMode; }
/** Callback set by initIMEInput to clear preview state (commits text). */
let _clearPreviewCallback: (() => void) | null = null;

// ── Preview commit history ring buffer (#254) ────────────────────────────────
const HISTORY_MAX = 20;
const _commitHistory: string[] = [];
let _historyIndex = -1; // -1 = not browsing

/** Record a committed preview text into the history ring. */
function _recordCommit(text: string): void {
  if (!text) return;
  // Deduplicate consecutive identical commits
  if (_commitHistory.length > 0 && _commitHistory[_commitHistory.length - 1] === text) return;
  _commitHistory.push(text);
  if (_commitHistory.length > HISTORY_MAX) _commitHistory.shift();
  _historyIndex = -1;
}

/** Navigate commit history: -1 = older, +1 = newer. Returns text or null. */
function _navigateHistory(direction: -1 | 1): string | null {
  if (_commitHistory.length === 0) return null;
  if (_historyIndex === -1) {
    // Entering history browsing — start from the newest
    if (direction === -1) {
      _historyIndex = _commitHistory.length - 1;
    } else {
      return null; // can't go newer than current
    }
  } else {
    _historyIndex += direction;
  }
  // Clamp
  if (_historyIndex < 0) { _historyIndex = 0; return _commitHistory[0]!; }
  if (_historyIndex >= _commitHistory.length) { _historyIndex = -1; return null; }
  return _commitHistory[_historyIndex]!;
}

export function togglePreviewMode(): void {
  _previewMode = !_previewMode;
  localStorage.setItem('imePreviewMode', _previewMode ? 'true' : 'false');
  const btn = document.getElementById('previewModeBtn');
  if (btn) btn.classList.toggle('preview-active', _previewMode);
  // Toggle textarea visibility — nothing else. No commit, no discard, no state change.
  // Only show if we're actually in a holding state (previewing/editing) with content.
  const hasContent = _imeState === 'previewing' || _imeState === 'editing';
  const ime = document.getElementById('imeInput') as HTMLTextAreaElement | null;
  if (ime) ime.classList.toggle('ime-visible', _previewMode && hasContent);
  const actions = document.getElementById('imeActions');
  if (actions && !_previewMode) actions.classList.add('hidden');
  if (actions && _previewMode && hasContent) actions.classList.remove('hidden');
  console.log('[ime] preview mode:', _previewMode ? 'ON' : 'OFF');
}

/** Clear any active preview — called when compose mode is toggled off. */
export function clearIMEPreview(): void {
  if (_clearPreviewCallback) _clearPreviewCallback();
}

/** Query the current IME state (for tests and debugging). */
export function getIMEState(): IMEState { return _imeState; }

// ── Password-prompt detection — suppress keyboard suggestions (#123) ─────────
// Matches common password/passphrase/PIN prompts at the end of a terminal line.
const _PASSWORD_RE = /(?:password|passphrase|PIN)[^:]*:\s*$/i;
let _pwdListenerSetup = false;

function _checkPasswordPrompt(el: HTMLTextAreaElement): void {
  if (!appState.terminal) return;
  const buf = appState.terminal.buffer.active;
  const lastLine = (buf.getLine(buf.cursorY)?.translateToString(true) ?? '').trimEnd();
  el.setAttribute('autocomplete', _PASSWORD_RE.test(lastLine) ? 'new-password' : 'off');
}

export function initIME({ handleResize, applyFontSize }: IMEDeps): void {
  _handleResize = handleResize;
  _applyFontSize = applyFontSize;
}

/** Apply the current preview style class to the textarea, removing others. */
function _applyPreviewStyle(el: HTMLTextAreaElement): void {
  for (const s of PREVIEW_STYLES) el.classList.remove(`preview-${s}`);
  el.classList.add(`preview-${_previewStyle}`);
}

/** Cycle to the next preview style and persist. */
function _cyclePreviewStyle(el: HTMLTextAreaElement): void {
  const idx = PREVIEW_STYLES.indexOf(_previewStyle);
  _previewStyle = PREVIEW_STYLES[(idx + 1) % PREVIEW_STYLES.length]!;
  localStorage.setItem('imePreviewStyle', _previewStyle);
  _applyPreviewStyle(el);
  console.log('[ime] preview style:', _previewStyle);
}

/** Auto-resize textarea to fit content, growing before text wraps.
 *  Uses a hidden measurement span to detect when the current line is
 *  approaching the textarea width, adding a row proactively. */
function _autoResizeTextarea(el: HTMLTextAreaElement): void {
  const maxH = (window.visualViewport?.height ?? window.innerHeight) * 0.5;
  el.style.maxHeight = `${String(maxH)}px`;
  const lineH = parseFloat(getComputedStyle(el).lineHeight) || 22;
  const padY = parseFloat(getComputedStyle(el).paddingTop) + parseFloat(getComputedStyle(el).paddingBottom);
  const padX = parseFloat(getComputedStyle(el).paddingLeft) + parseFloat(getComputedStyle(el).paddingRight);
  const innerW = el.clientWidth - padX;

  // Measure the last line's text width using a temp canvas context
  const text = el.value;
  const lastNewline = text.lastIndexOf('\n');
  const lastLine = lastNewline >= 0 ? text.slice(lastNewline + 1) : text;
  if (!_measureCtx) _measureCtx = document.createElement('canvas').getContext('2d');
  const ctx = _measureCtx;
  let lastLineW = 0;
  if (ctx) {
    ctx.font = getComputedStyle(el).font;
    lastLineW = ctx.measureText(lastLine).width;
  }

  // Count wrapped lines: each line wraps at innerW
  const lines = text.split('\n');
  let totalLines = 0;
  for (const line of lines) {
    if (!ctx || !line) { totalLines += 1; continue; }
    const w = ctx.measureText(line).width;
    totalLines += Math.max(1, Math.ceil(w / innerW));
  }

  // Add an extra line if current line is >75% full (grow before wrap)
  if (lastLineW > innerW * 0.75) totalLines += 1;

  const contentH = Math.max(totalLines * lineH + padY, 48);
  el.style.height = `${String(Math.min(contentH, maxH))}px`;
}

export function initIMEInput(): void {
  const ime = document.getElementById('imeInput') as HTMLTextAreaElement;

  // Register cursor-move listener once the terminal is available, and re-check
  // whenever focus lands on the textarea (covers the "prompt just appeared" case).
  function _lazySetupPwdListener(): void {
    if (_pwdListenerSetup || !appState.terminal) return;
    _pwdListenerSetup = true;
    appState.terminal.onCursorMove(() => { _checkPasswordPrompt(ime); });
  }
  ime.addEventListener('focus', () => {
    _lazySetupPwdListener();
    _checkPasswordPrompt(ime);
  });

  // ── Preview touch: tap-to-edit vs vertical-swipe-to-scrollback (#254) ────
  // Vertical swipe on the preview textarea cycles through commit history.
  // Each 40px of accumulated movement triggers one history step (allows
  // multiple steps in a single long swipe). Tap = edit as before.
  let _imeTouchStartY: number | null = null;
  let _imeTouchClaimed = false;
  let _imeTouchSteps = 0; // how many 40px steps consumed so far

  /** Load a history entry into the preview textarea. */
  function _loadHistoryEntry(direction: -1 | 1): void {
    const text = _navigateHistory(direction);
    if (text !== null) {
      ime.value = text;
      _autoResizeTextarea(ime);
      if (_imeState === 'idle') _transition('previewing');
      _cancelTimers();
      if ('vibrate' in navigator) navigator.vibrate(10);
    } else if (direction === 1 && _historyIndex === -1) {
      ime.value = '';
      _transition('idle');
      if ('vibrate' in navigator) navigator.vibrate(10);
    }
  }

  ime.addEventListener('touchstart', (e) => {
    _imeTouchStartY = e.touches[0]!.clientY;
    _imeTouchClaimed = false;
    _imeTouchSteps = 0;
  }, { passive: true });

  ime.addEventListener('touchmove', (e) => {
    if (_imeTouchStartY === null) return;
    const dy = _imeTouchStartY - e.touches[0]!.clientY;
    const STEP_PX = 40;
    const targetSteps = Math.trunc(dy / STEP_PX);
    if (targetSteps !== _imeTouchSteps) {
      if (!_imeTouchClaimed) { _imeTouchClaimed = true; }
      e.preventDefault();
      // Each step change triggers one history navigation
      const stepDelta = targetSteps - _imeTouchSteps;
      const direction: -1 | 1 = stepDelta > 0 ? -1 : 1;
      const count = Math.abs(stepDelta);
      for (let i = 0; i < count; i++) _loadHistoryEntry(direction);
      _imeTouchSteps = targetSteps;
    }
  }, { passive: false });

  ime.addEventListener('touchend', () => {
    if (!_imeTouchClaimed && (_imeState === 'previewing' || _imeState === 'composing') && ime.value) {
      _transition('editing');
    }
    _imeTouchStartY = null;
    _imeTouchClaimed = false;
    _imeTouchSteps = 0;
  });

  // ── Preview mode toggle (#106) — wired here to avoid circular import ──
  const previewBtn = document.getElementById('previewModeBtn');
  if (previewBtn) {
    previewBtn.classList.toggle('preview-active', _previewMode);
    previewBtn.addEventListener('click', () => {
      togglePreviewMode();
      focusIME();
    });
    // Long-press cycles preview style (#175)
    let _longPressTimer: ReturnType<typeof setTimeout> | null = null;
    let _longPressFired = false;
    previewBtn.addEventListener('pointerdown', () => {
      _longPressFired = false;
      _longPressTimer = setTimeout(() => {
        _longPressFired = true;
        _cyclePreviewStyle(ime);
      }, 600);
    });
    previewBtn.addEventListener('pointerup', () => {
      if (_longPressTimer) { clearTimeout(_longPressTimer); _longPressTimer = null; }
    });
    previewBtn.addEventListener('pointercancel', () => {
      if (_longPressTimer) { clearTimeout(_longPressTimer); _longPressTimer = null; }
    });
    // Suppress click after long-press to avoid toggling preview mode
    previewBtn.addEventListener('click', (e) => {
      if (_longPressFired) { e.stopImmediatePropagation(); _longPressFired = false; }
    }, { capture: true });
  }

  // ── IME action buttons (#106) ────────────────────────────────────────
  const imeActions = document.getElementById('imeActions');
  const clearBtn = document.getElementById('imeClearBtn');
  const commitBtn = document.getElementById('imeCommitBtn');
  const historyUp = document.getElementById('imeHistoryUp');
  const historyDown = document.getElementById('imeHistoryDown');
  const dockToggle = document.getElementById('imeDockToggle');

  let _dockPosition: 'top' | 'bottom' = localStorage.getItem('imeDockPosition') === 'bottom' ? 'bottom' : 'top';
  let _manualDock = false;

  /**
   * Compute effective dock position: if the user explicitly toggled, use that.
   * Otherwise, auto-select based on terminal cursor position — place the preview
   * opposite the cursor so it doesn't obscure the active line.
   * Falls back to _dockPosition (persisted) when terminal is unavailable.
   */
  function _effectiveDock(): 'top' | 'bottom' {
    if (_manualDock) return _dockPosition;
    const term = appState.terminal;
    if (!term) return _dockPosition;
    const cursorY = term.buffer.active.cursorY;
    const rows = term.rows;
    // Cursor in top half → show preview at bottom; cursor in bottom half → show at top
    return cursorY < rows / 2 ? 'bottom' : 'top';
  }

  /** Position the textarea + action bar using visualViewport to avoid the keyboard. */
  function _positionIME(): void {
    const vv = window.visualViewport;
    const viewH = vv ? vv.height : window.innerHeight;
    const viewTop = vv ? vv.offsetTop : 0;
    const actionH = 36; // matches CSS .ime-action-btn height
    const dock = _effectiveDock();

    if (dock === 'top') {
      // Top: just below viewport top (extra margin to clear status bar)
      const top = viewTop + 12;
      ime.style.top = `${String(top)}px`;
      ime.style.bottom = 'auto';
      if (imeActions) {
        imeActions.style.top = `${String(top + ime.offsetHeight)}px`;
        imeActions.style.bottom = 'auto';
      }
    } else {
      // Bottom: above the keyboard
      const bottom = window.innerHeight - (viewTop + viewH) + 8;
      ime.style.bottom = `${String(bottom + actionH)}px`;
      ime.style.top = 'auto';
      if (imeActions) {
        imeActions.style.bottom = `${String(bottom)}px`;
        imeActions.style.top = 'auto';
      }
    }
  }

  // Re-position when viewport changes (keyboard open/close)
  if (window.visualViewport) {
    window.visualViewport.addEventListener('resize', () => {
      if (ime.classList.contains('ime-visible')) _positionIME();
    });
    window.visualViewport.addEventListener('scroll', () => {
      if (ime.classList.contains('ime-visible')) _positionIME();
    });
  }

  /** Show the action button bar and position everything. */
  function _showActions(): void {
    if (imeActions) imeActions.classList.remove('hidden');
    // Show/hide history buttons based on whether history exists
    const hasHistory = _commitHistory.length > 0;
    if (historyUp) historyUp.classList.toggle('hidden', !hasHistory);
    if (historyDown) historyDown.classList.toggle('hidden', !hasHistory);
    _positionIME();
  }
  /** Hide the action button bar. */
  function _hideActions(): void {
    if (imeActions) imeActions.classList.add('hidden');
  }

  // Prevent buttons from stealing focus (desktop: mousedown preventDefault).
  // On mobile: use touchend handlers directly since touchstart preventDefault
  // swallows the click event on Android.
  if (imeActions) {
    imeActions.addEventListener('mousedown', (e) => { e.preventDefault(); });
  }

  /** Wire an action button for both touch and click. */
  function _onAction(btn: HTMLElement | null, handler: () => void): void {
    if (!btn) return;
    let touchHandled = false;
    btn.addEventListener('touchend', (e) => {
      e.preventDefault(); // prevent click from also firing
      touchHandled = true;
      handler();
    });
    btn.addEventListener('click', () => {
      if (touchHandled) { touchHandled = false; return; }
      handler();
    });
  }

  _onAction(clearBtn, () => {
    // Erase what was already sent to SSH (if anything)
    if (_lastSentValue) sendSSHInput('\x7f'.repeat(_lastSentValue.length));
    _transition('idle');
    focusIME();
  });

  _onAction(commitBtn, () => {
    const text = ime.value;
    if (_imeState === 'editing') {
      // Editing: user rewrote text locally — send full text as-is
      if (text) sendSSHInput(text);
    } else {
      // Previewing/composing: erase any partial sends, send final text
      if (_lastSentValue) sendSSHInput('\x7f'.repeat(_lastSentValue.length));
      if (text) sendSSHInput(text);
    }
    _recordCommit(text);
    _transition('idle');
    focusIME();
  });

  _onAction(dockToggle, () => {
    // Determine what auto-positioning would choose, then flip from that
    const auto = _effectiveDock();
    _dockPosition = auto === 'top' ? 'bottom' : 'top';
    _manualDock = true;
    localStorage.setItem('imeDockPosition', _dockPosition);
    _positionIME();
    focusIME();
  });

  // ── History scroll buttons (#254) ──────────────────────────────────────
  _onAction(historyUp, () => {
    _loadHistoryEntry(-1);
    focusIME();
  });
  _onAction(historyDown, () => {
    _loadHistoryEntry(1);
    focusIME();
  });

  // ── Textarea diffing state (handles post-composition corrections) ──────
  let _lastSentValue = '';
  let _prevInputValue = '';  // tracks ime.value before each input event (#172)
  let _replacementHandled = false;
  let _clearTimer: ReturnType<typeof setTimeout> | null = null;
  /** Timestamp of most recent transition to idle — used to reject late browser
   *  re-insertion events that fire within a short window after compositionend. */
  let _idleTransitionTime = 0;

  // ── Preview countdown ring on commit button (#169) ─────────────────────
  const commitCountdown = commitBtn?.querySelector('.commit-countdown') as HTMLElement | null;
  const commitRingProgress = commitBtn?.querySelector('.commit-ring-progress') as SVGCircleElement | null;
  const RING_CIRCUMFERENCE = 100.53; // 2 * π * 16 (r=16 in SVG viewBox)
  let _timerInterval: ReturnType<typeof setInterval> | null = null;
  let _timerStart = 0;
  let _timerDuration = 0;

  /** Start the countdown ring animation on the commit button.
   *  Ring appears full and drains to empty — no fill-up animation. */
  function _startTimer(durationMs: number): void {
    if (!commitBtn) return;
    _stopTimerAnimation();
    if (!isFinite(durationMs)) {
      // "Never" mode — show ∞, full ring, no countdown
      commitBtn.classList.add('countdown-active');
      if (commitRingProgress) commitRingProgress.style.strokeDashoffset = '0';
      if (commitCountdown) { commitCountdown.textContent = '\u221E'; commitCountdown.classList.remove('hidden'); }
      return;
    }
    // Set ring to full immediately before showing
    if (commitRingProgress) commitRingProgress.style.strokeDashoffset = '0';
    commitBtn.classList.add('countdown-active');
    if (commitCountdown) commitCountdown.classList.remove('hidden');
    _timerStart = Date.now();
    _timerDuration = durationMs;
    if (commitCountdown) commitCountdown.textContent = String(Math.ceil(durationMs / 1000));
    _timerInterval = setInterval(_updateTimerDisplay, 50);
  }

  /** Update the SVG ring — drains from full to empty as time elapses. */
  function _updateTimerDisplay(): void {
    if (!_timerDuration) return;
    const elapsed = Date.now() - _timerStart;
    const remaining = Math.max(0, _timerDuration - elapsed);
    // strokeDashoffset: 0 = full, CIRCUMFERENCE = empty
    if (commitRingProgress) {
      commitRingProgress.style.strokeDashoffset = String(RING_CIRCUMFERENCE * (1 - remaining / _timerDuration));
    }
    if (commitCountdown) commitCountdown.textContent = String(Math.ceil(remaining / 1000));
  }

  /** Stop the timer animation interval. */
  function _stopTimerAnimation(): void {
    if (_timerInterval) { clearInterval(_timerInterval); _timerInterval = null; }
  }

  /** Reset the commit button to its normal state. */
  function _hideTimer(): void {
    _stopTimerAnimation();
    if (commitBtn) commitBtn.classList.remove('countdown-active');
    if (commitRingProgress) commitRingProgress.style.strokeDashoffset = String(RING_CIRCUMFERENCE);
    if (commitCountdown) commitCountdown.classList.add('hidden');
  }

  // Duration cycling removed from commit button — will be a regular setting.

  /** Transition the IME state machine. All state changes go through here. */
  function _transition(to: IMEState): void {
    const from = _imeState;
    // Always run idle cleanup even if already idle (commit after auto-clear)
    if (from === to && to !== 'idle') return;
    _imeState = to;

    // Cancel all pending timers on any transition
    _cancelTimers();

    switch (to) {
      case 'idle':
        ime.value = '';
        _lastSentValue = '';
        _prevInputValue = '';
        _idleTransitionTime = Date.now();
        ime.classList.remove('ime-visible', 'ime-editing');
        for (const s of PREVIEW_STYLES) ime.classList.remove(`preview-${s}`);
        if (imeActions) imeActions.classList.remove('ime-editing');
        ime.style.height = '';
        ime.style.maxHeight = '';
        _hideActions();
        _hideTimer();
        appState.isComposing = false;
        _manualDock = false;
        break;

      case 'composing':
        appState.isComposing = true;
        ime.classList.add('ime-visible');
        ime.classList.remove('ime-editing');
        if (imeActions) imeActions.classList.remove('ime-editing');
        _applyPreviewStyle(ime);
        _showActions();
        _positionIME();
        break;

      case 'previewing':
        appState.isComposing = false;
        ime.classList.add('ime-visible');
        ime.classList.remove('ime-editing');
        if (imeActions) imeActions.classList.remove('ime-editing');
        _applyPreviewStyle(ime);
        _showActions();
        _positionIME();
        break;

      case 'editing':
        appState.isComposing = false;
        ime.classList.add('ime-visible', 'ime-editing');
        if (imeActions) imeActions.classList.add('ime-editing');
        _applyPreviewStyle(ime);
        _showActions();
        _positionIME();
        break;
    }
  }

  /** Whether input should be held (not sent to SSH). */
  function _isHolding(): boolean {
    return _imeState === 'previewing' || _imeState === 'editing';
  }

  /** Whether the IME should stick indefinitely (no auto-clear). */
  function _isSticky(): boolean {
    return _imeState === 'editing';
  }

  /** Show the overlay and auto-size the textarea (only if preview mode is on). */
  function _showIMEOverlay(): void {
    if (!_previewMode) return;
    ime.classList.add('ime-visible');
    _applyPreviewStyle(ime);
    if (_imeState !== 'idle') _showActions();
    _positionIME();
    _autoResizeTextarea(ime);
  }

  /** Schedule a deferred clear — two phases for preview state:
   *  Phase 1: idle delay (2s) — no visual indicator, resets on new input.
   *  Phase 2: visible countdown ring (user-selected duration, default 4s).
   *  When the ring completes, text is auto-committed.
   *  Non-preview (composing without preview): simple 1.5s delay. */
  let _idleDelayTimer: ReturnType<typeof setTimeout> | null = null;

  function _cancelTimers(): void {
    if (_clearTimer) { clearTimeout(_clearTimer); _clearTimer = null; }
    if (_idleDelayTimer) { clearTimeout(_idleDelayTimer); _idleDelayTimer = null; }
    _hideTimer();
  }

  function _scheduleClear(): void {
    _cancelTimers();
    if (_isSticky()) return;

    // Non-preview: simple delay
    if (_imeState !== 'previewing') {
      _clearTimer = setTimeout(() => { _transition('idle'); }, 1500);
      return;
    }

    // "Never" mode — show ∞ ring, no auto-commit
    if (!isFinite(_previewTimeout)) {
      _startTimer(Infinity);
      return;
    }

    // Phase 1: idle grace period — wait for user to stop interacting
    _idleDelayTimer = setTimeout(() => {
      _idleDelayTimer = null;
      if (_imeState !== 'previewing') return;

      // Phase 2: start visible countdown ring
      _startTimer(_previewTimeout);
      _clearTimer = setTimeout(() => {
        if (_imeState === 'composing' || _imeState === 'editing') return;
        if (_imeState === 'previewing') {
          const text = ime.value;
          if (text) sendSSHInput(text);
          _recordCommit(text);
        }
        _transition('idle');
      }, _previewTimeout);
    }, _previewIdleDelay);
  }

  // Register callback so toggleComposeMode() can commit+clear active preview
  _clearPreviewCallback = () => {
    if (appState.isComposing) appState.isComposing = false;
    const text = ime.value;
    if (text) sendSSHInput(text);
    _recordCommit(text);
    _transition('idle');
  };


  /** Send text to SSH with Ctrl modifier handling. */
  function _sendIMEText(text: string): void {
    if (text === '\n') {
      sendSSHInput('\r');
      ime.setAttribute('autocomplete', 'off');
      _transition('idle');
      return;
    }
    if (appState.ctrlActive) {
      const code = text[0]!.toLowerCase().charCodeAt(0) - 96;
      sendSSHInput(code >= 1 && code <= 26 ? String.fromCharCode(code) : text);
      setCtrlActive(false);
    } else {
      sendSSHInput(text);
    }
  }

  /** Diff old vs new value: send backspaces to erase changed region + replacement text. */
  function _sendDiff(oldVal: string, newVal: string): void {
    const { deletions, insertion } = computeDiff(oldVal, newVal);
    if (deletions > 0) sendSSHInput('\x7f'.repeat(deletions));
    if (insertion) sendSSHInput(insertion);
  }

  // ── beforeinput: intercept IME corrections before they hit the textarea ──
  ime.addEventListener('beforeinput', (e: InputEvent) => {
    _replacementHandled = false;
    // When holding (previewing/editing), let the textarea update freely
    if (_isHolding()) return;

    // insertReplacementText: Gboard/iOS correction after swipe-type (#231)
    if (e.inputType === 'insertReplacementText' && e.data) {
      const ranges = e.getTargetRanges();
      if (ranges.length > 0) {
        const r = ranges[0]!;
        // For a textarea, startOffset/endOffset map to selectionStart/selectionEnd
        const deleteCount = r.endOffset - r.startOffset;
        if (deleteCount > 0) sendSSHInput('\x7f'.repeat(deleteCount));
        sendSSHInput(e.data);
        e.preventDefault();
        // Update tracking: replace the range in lastSentValue
        _lastSentValue = _lastSentValue.slice(0, r.startOffset) + e.data +
                         _lastSentValue.slice(r.endOffset);
        _replacementHandled = true;
        return;
      }
      // If ranges empty (some Chrome versions), fall through to textarea diff in input handler
    }

    // deleteWordBackward: Gboard-specific correction sequence (#231)
    if (e.inputType === 'deleteWordBackward' && !appState.isComposing) {
      const start = ime.selectionStart;
      const before = ime.value.slice(0, start);
      // Find word boundary
      const match = before.match(/\S+\s*$/);
      const deleteCount = match ? match[0].length : before.length;
      if (deleteCount > 0) {
        sendSSHInput('\x7f'.repeat(deleteCount));
        _lastSentValue = _lastSentValue.slice(0, start - deleteCount) + _lastSentValue.slice(start);
        _replacementHandled = true;
      }
      // Don't preventDefault — let the browser update the textarea so
      // the subsequent insertText has correct content to diff against
    }
  });

  // ── input event ─────────────────────────────────────────────────────────
  ime.addEventListener('input', () => {
    // Ctrl+key: send control char immediately, bypass hold/preview (#170)
    // Must be before 150ms guard — user intent, not stale re-insertion.
    if (appState.ctrlActive && ime.value) {
      _sendIMEText(ime.value);
      ime.value = '';
      _prevInputValue = '';
      _transition('idle');
      return;
    }
    // Browser can re-insert composed text after compositionend + _transition('idle').
    // Reject input events within 150ms of idle transition — covers all late re-insertion
    // without permanently blocking input (which caused first/every-other word loss).
    if (Date.now() - _idleTransitionTime < 150) {
      if (ime.value) { ime.value = ''; }
      return;
    }
    // When holding, just keep the overlay — don't send to SSH
    if (_isHolding()) {
      _showIMEOverlay();
      _prevInputValue = ime.value;
      // Reset countdown on every new input — user is still interacting
      if (_imeState === 'previewing') _scheduleClear();
      return;
    }
    if (appState.isComposing) {
      _showIMEOverlay();
      return;
    }

    // If beforeinput already handled this (insertReplacementText with ranges), skip
    if (_replacementHandled) {
      _replacementHandled = false;
      return;
    }

    const newVal = ime.value;
    if (!newVal) { _transition('idle'); return; }
    _showIMEOverlay();

    // Hold for preview: don't send, transition to previewing with auto-clear.
    // GBoard swipe may fire input events without composition events, so this
    // path must mirror the compositionend preview-hold logic.
    if (appState.imeMode && _previewMode) {
      _transition('previewing');
      _lastSentValue = '';
      _prevInputValue = ime.value;
      _scheduleClear();
      return;
    }

    // If we have a previous value to diff against, use textarea diffing
    // to detect corrections the beforeinput handler couldn't catch
    if (_lastSentValue) {
      _sendDiff(_lastSentValue, newVal);
      _lastSentValue = newVal;
    } else {
      // Fresh input (no prior value to diff against)
      _sendIMEText(newVal);
      _lastSentValue = newVal;
    }

    // No preview: clear after sending
    _transition('idle');
    _prevInputValue = ime.value;
  });

  // ── IME composition (multi-step input methods, e.g. CJK, Gboard swipe) ─
  ime.addEventListener('compositionstart', () => {
    console.log(`[ime:compositionstart] state=${_imeState} preview=${String(_previewMode)} value="${ime.value}"`);
    // New composition: clear any stale text that browser might have re-inserted
    if (_imeState === 'idle') ime.value = '';
    // Preserve editing state — user tapped in to edit, new composition should
    // stay sticky (no auto-clear). Only transition to composing from non-editing.
    if (_imeState !== 'editing') _transition('composing');
    else appState.isComposing = true;
    _showIMEOverlay();
  });

  ime.addEventListener('compositionupdate', () => {
    _showIMEOverlay();
  });

  ime.addEventListener('compositionend', (e: CompositionEvent) => {
    console.log(`[ime:compositionend] state=${_imeState} preview=${String(_previewMode)} holding=${String(_isHolding())} value="${ime.value}" data="${e.data}" lastSent="${_lastSentValue}"`);
    // If already holding (editing/previewing), stay — accumulate text
    if (_isHolding()) {
      appState.isComposing = false;
      _showIMEOverlay();
      // Reset countdown — user just added more text
      if (_imeState === 'previewing') _scheduleClear();
      return;
    }

    const text = ime.value || e.data;
    if (!text) { _transition('idle'); return; }

    // Ctrl+key: send control char immediately, bypass preview (#170)
    if (appState.ctrlActive) {
      appState.isComposing = false;
      _sendIMEText(text);
      ime.value = '';
      _transition('idle');
      return;
    }

    // Compose + preview: hold text for review (nothing sent until commit)
    if (appState.imeMode && _previewMode) {
      // Ensure textarea has the text — voice dictation may leave ime.value
      // empty while e.data carries the composed text (#163)
      if (!ime.value && e.data) ime.value = e.data;
      _transition('previewing');
      _lastSentValue = '';
      _scheduleClear();
      return;
    }

    // No preview: send immediately, but keep textarea alive briefly
    // so voice dictation sessions can continue across composition cycles.
    appState.isComposing = false;
    if (_lastSentValue) {
      // Continuation of a multi-word swipe/voice session — diff against
      // what was already sent so inter-word spaces aren't dropped (#162).
      _sendDiff(_lastSentValue, text);
    } else {
      _sendIMEText(text);
    }
    _lastSentValue = text;
    // Move to previewing (allows tap-to-edit and deferred idle timer)
    _imeState = 'previewing';
    // Deferred idle: if no new compositionstart within 1.5s, hide textarea
    if (_clearTimer) clearTimeout(_clearTimer);
    console.log(`[ime:compositionend-timer] 1500ms state=${_imeState} preview=${String(_previewMode)}`);
    _clearTimer = setTimeout(() => {
      console.log(`[ime:compositionend-timer-fired] state=${_imeState}`);
      if (_imeState === 'composing') return; // new composition started
      _transition('idle');
    }, 1500);
  });

  ime.addEventListener('compositioncancel' as keyof HTMLElementEventMap, () => {
    _transition('idle');
  });

  // ── keydown: special keys not captured by 'input' ─────────────────────
  ime.addEventListener('keydown', (e) => {
    // Never intercept hardware media/volume keys — let the system handle them (#221)
    if (isMediaKey(e.key)) return;

    // Enter: commit held text and send \r
    if (e.key === 'Enter') {
      ime.setAttribute('autocomplete', 'off');
      const text = ime.value;
      if (_isHolding() && text) {
        e.preventDefault();
        sendSSHInput(text);
        sendSSHInput('\r');
        _transition('idle');
        focusIME();
        return;
      }
      _transition('idle');
    }

    if (e.ctrlKey && !e.altKey && e.key.length === 1) {
      const code = e.key.toLowerCase().charCodeAt(0) - 96;
      if (code >= 1 && code <= 26) {
        sendSSHInput(String.fromCharCode(code));
        _transition('idle');
        e.preventDefault();
        return;
      }
    }

    const mapped = KEY_MAP[e.key];
    if (mapped) {
      // In editing/previewing state, let editing keys work natively in the textarea
      const isNav = e.key.startsWith('Arrow') || e.key === 'Home' || e.key === 'End';
      if (appState.imeMode && isNav) return;
      if (_isHolding() && e.key === 'Backspace') {
        if (ime.value) return;
        sendSSHInput('\x7f');
        e.preventDefault();
        return;
      }
      sendSSHInput(mapped);
      _transition('idle');
      e.preventDefault();
      return;
    }

    // Sticky Ctrl in compose mode: intercept before textarea captures the key (#170)
    if (appState.imeMode && appState.ctrlActive && e.key.length === 1 && !e.ctrlKey && !e.altKey && !e.metaKey) {
      const code = e.key.toLowerCase().charCodeAt(0) - 96;
      sendSSHInput(code >= 1 && code <= 26 ? String.fromCharCode(code) : e.key);
      setCtrlActive(false);
      e.preventDefault();
      _transition('idle');
      return;
    }

    if (!appState.imeMode && e.key.length === 1 && !e.ctrlKey && !e.altKey && !e.metaKey) {
      if (appState.ctrlActive) {
        const code = e.key.toLowerCase().charCodeAt(0) - 96;
        sendSSHInput(code >= 1 && code <= 26 ? String.fromCharCode(code) : e.key);
        setCtrlActive(false);
      } else {
        sendSSHInput(e.key);
      }
      e.preventDefault();
      _transition('idle');
    }
  });

  // termEl used by gesture handlers and pinch-to-zoom
  const termEl = document.getElementById('terminal')!;

  // ── Tap + swipe gestures on terminal (#32/#37/#16) ────────────────────

  termEl.addEventListener('click', () => { if (!isSelectionActive()) focusIME(); });

  let _touchStartY: number | null = null;
  let _touchStartX: number | null = null;
  let _lastTouchY: number | null = null;
  let _lastTouchX: number | null = null;
  let _isTouchScroll = false;
  let _scrolledLines = 0;
  let _pendingLines = 0;
  let _pendingSGR: { btn: number; col: number; row: number; count: number } | null = null;
  let _scrollRafId: number | null = null;

  function _flushScroll(): void {
    _scrollRafId = null;
    if (_pendingLines !== 0 && appState.terminal) {
      console.log('[scroll] flush scrollLines=', _pendingLines);
      appState.terminal.scrollLines(_pendingLines);
      _pendingLines = 0;
    }
    if (_pendingSGR && _pendingSGR.count > 0) {
      const { btn, col, row, count } = _pendingSGR;
      console.log('[scroll] flush SGR btn=', btn, 'count=', count, 'col=', col, 'row=', row);
      for (let i = 0; i < count; i++) sendSSHInput(`\x1b[<${String(btn)};${String(col)};${String(row)}M`);
      _pendingSGR = null;
    }
  }

  function _scheduleScrollFlush(): void {
    if (!_scrollRafId) _scrollRafId = requestAnimationFrame(_flushScroll);
  }

  // nosemgrep: duplicate-event-listener -- scroll (1-finger) and pinch (2-finger) are separate gestures
  termEl.addEventListener('touchstart', (e) => {
    if (isSelectionActive()) return;
    console.log('[scroll] touchstart y=', e.touches[0]!.clientY, 'touches=', e.touches.length);
    _touchStartY = _lastTouchY = e.touches[0]!.clientY;
    _touchStartX = _lastTouchX = e.touches[0]!.clientX;
    _isTouchScroll = false;
    _scrolledLines = 0;
    _pendingLines = 0;
    _pendingSGR = null;
    if (_scrollRafId) { cancelAnimationFrame(_scrollRafId); _scrollRafId = null; }
  }, { passive: true, capture: true });

  // nosemgrep: duplicate-event-listener
  termEl.addEventListener('touchmove', (e) => {
    if (isSelectionActive()) return;
    if (_touchStartY === null || _touchStartX === null) return;
    const totalDy = _touchStartY - e.touches[0]!.clientY;
    const totalDx = _touchStartX - e.touches[0]!.clientX;

    if (!_isTouchScroll && Math.abs(totalDy) > 12 && Math.abs(totalDy) > Math.abs(totalDx)) {
      _isTouchScroll = true;
      console.log('[scroll] gesture claimed, totalDy=', totalDy);
    }

    // Once we've claimed this gesture as a terminal scroll, prevent the
    // browser's native scroll/bounce so it doesn't fight our handler.
    if (_isTouchScroll) e.preventDefault();

    if (_isTouchScroll && appState.terminal) {
      const cellH = Math.max(20, (appState.terminal.options.fontSize ?? 14) * 1.5);
      const targetLines = Math.round(totalDy / cellH);
      const delta = targetLines - _scrolledLines;
      if (delta !== 0) {
        _scrolledLines = targetLines;
        // eslint-disable-next-line @typescript-eslint/no-unsafe-member-access -- xterm modes is untyped
        const termUnk = appState.terminal as unknown as Record<string, unknown>;
        const mouseMode = termUnk.modes &&
          (termUnk.modes as Record<string, unknown>).mouseTrackingMode;
        console.log('[scroll] delta=', delta, 'mouseMode=', mouseMode);
        if (mouseMode && mouseMode !== 'none') {
          const natural = _naturalVerticalScroll();
          // delta>0 = finger UP, delta<0 = finger DOWN
          // Natural: finger down(-delta) = see older = WheelUp(64)
          // Traditional: finger up(+delta) = see older = WheelUp(64)
          const btn = natural
            ? (delta > 0 ? 65 : 64)
            : (delta > 0 ? 64 : 65);
          const rect = termEl.getBoundingClientRect();
          const col = Math.max(1, Math.min(appState.terminal.cols,
            Math.floor((e.touches[0]!.clientX - rect.left) / (rect.width / appState.terminal.cols)) + 1));
          const row = Math.max(1, Math.min(appState.terminal.rows,
            Math.floor((e.touches[0]!.clientY - rect.top) / (rect.height / appState.terminal.rows)) + 1));
          const count = Math.abs(delta);
          if (_pendingSGR?.btn === btn) {
            _pendingSGR.count += count;
          } else {
            _pendingSGR = { btn, col, row, count };
          }
          console.log('[scroll] SGR queued btn=', btn, 'count=', count);
        } else {
          // Natural: delta maps directly (finger down = -delta = scrollLines(-) = older)
          // Traditional: invert (finger up = +delta → -delta = scrollLines(-) = older)
          _pendingLines += _naturalVerticalScroll() ? delta : -delta;
          console.log('[scroll] scrollLines queued=', _pendingLines);
        }
        _scheduleScrollFlush();
      }
    }

    _lastTouchY = e.touches[0]!.clientY;
    _lastTouchX = e.touches[0]!.clientX;
  }, { passive: false, capture: true });

  // nosemgrep: duplicate-event-listener
  termEl.addEventListener('touchend', () => {
    if (isSelectionActive()) return;
    const wasScroll = _isTouchScroll;
    const finalDx = (_lastTouchX ?? _touchStartX ?? 0) - (_touchStartX ?? 0);
    const finalDy = (_lastTouchY ?? _touchStartY ?? 0) - (_touchStartY ?? 0);

    _touchStartY = _touchStartX = _lastTouchY = _lastTouchX = null;
    _isTouchScroll = false;
    _scrolledLines = 0;
    // Flush any remaining scroll deltas before clearing — if the last touchmove
    // queued lines that rAF hasn't flushed yet, discarding them loses the scroll.
    _flushScroll();
    _pendingLines = 0;
    _pendingSGR = null;
    if (_scrollRafId) { cancelAnimationFrame(_scrollRafId); _scrollRafId = null; }

    if (!wasScroll) {
      if (Math.abs(finalDx) > 40 && Math.abs(finalDx) > Math.abs(finalDy)) {
        const hNatural = _naturalHorizontalScroll();
        const hCmd = hNatural
          ? (finalDx < 0 ? '\x02p' : '\x02n')   // natural: finger left = prev
          : (finalDx < 0 ? '\x02n' : '\x02p');   // traditional: finger left = next
        sendSSHInput(hCmd);
      } else {
        setTimeout(focusIME, 50);
      }
    }
  }, { capture: true });

  // ── Pinch-to-zoom → font size (#17) — behind enablePinchZoom setting ────
  let _pinchStartDist: number | null = null;
  let _pinchStartSize: number | null = null;

  function _pinchEnabled(): boolean {
    return localStorage.getItem('enablePinchZoom') !== 'false';
  }

  function _naturalVerticalScroll(): boolean {
    return localStorage.getItem('naturalVerticalScroll') !== 'false';
  }

  function _naturalHorizontalScroll(): boolean {
    return localStorage.getItem('naturalHorizontalScroll') !== 'false';
  }

  function _pinchDist(touches: TouchList): number {
    const dx = touches[0]!.clientX - touches[1]!.clientX;
    const dy = touches[0]!.clientY - touches[1]!.clientY;
    return Math.sqrt(dx * dx + dy * dy);
  }

  termEl.addEventListener('touchstart', (e) => {
    if (e.touches.length !== 2 || !_pinchEnabled()) return;
    _pinchStartDist = _pinchDist(e.touches);
    _pinchStartSize = appState.terminal
      ? (appState.terminal.options.fontSize ?? 14)
      : (parseInt(localStorage.getItem('fontSize') ?? '14') || 14);
    e.preventDefault();
  }, { passive: false });

  termEl.addEventListener('touchmove', (e) => {
    if (e.touches.length !== 2 || _pinchStartDist === null || _pinchStartSize === null) return;
    e.preventDefault();
    const newSize = Math.round(_pinchStartSize * (_pinchDist(e.touches) / _pinchStartDist));
    _applyFontSize(newSize);
  }, { passive: false });

  termEl.addEventListener('touchend', () => {
    _pinchStartDist = null;
    _pinchStartSize = null;
  });

  termEl.addEventListener('touchcancel', () => {
    _pinchStartDist = null;
    _pinchStartSize = null;
  });

  // ── Direct input (type="password") — char-by-char mode (#44/#48/#155) ──
  // type="password" suppresses Gboard predictions so typed characters don't
  // leak into the keyboard suggestion bar.  Characters are also intercepted
  // via beforeinput so they never reach the field value.
  const directEl = document.getElementById('directInput') as HTMLInputElement;

  /** Send direct-mode text to SSH, handling sticky Ctrl modifier. */
  function _sendDirectText(text: string): void {
    if (text === '\n') { sendSSHInput('\r'); return; }
    if (appState.ctrlActive) {
      const code = text[0]!.toLowerCase().charCodeAt(0) - 96;
      sendSSHInput(code >= 1 && code <= 26 ? String.fromCharCode(code) : text);
      setCtrlActive(false);
    } else {
      sendSSHInput(text);
    }
  }

  // Intercept text BEFORE it modifies the field value — characters never
  // appear in the input, so Chrome autocomplete sees nothing to suggest.
  // Always preventDefault() — we never want the browser to modify this field.
  let _sentByBeforeInput = false;
  directEl.addEventListener('beforeinput', (e) => {
    e.preventDefault();
    _sentByBeforeInput = false;
    if (e.inputType === 'insertText' && e.data) {
      _sendDirectText(e.data);
      _sentByBeforeInput = true;
    } else if (e.inputType === 'insertLineBreak' || e.inputType === 'insertParagraph') {
      sendSSHInput('\r');
      _sentByBeforeInput = true;
    } else if (e.inputType === 'deleteContentBackward') {
      sendSSHInput('\x7f');
      _sentByBeforeInput = true;
    }
  });

  // Fallback: clear any characters that slip past beforeinput (non-cancelable
  // composition events or very old browsers without beforeinput support).
  directEl.addEventListener('input', () => {
    const text = directEl.value;
    directEl.value = '';
    if (_sentByBeforeInput) { _sentByBeforeInput = false; return; }
    if (text) _sendDirectText(text);
  });

  directEl.addEventListener('keydown', (e) => {
    // Never intercept hardware media/volume keys — let the system handle them (#221)
    if (isMediaKey(e.key)) return;

    if (e.ctrlKey && !e.altKey && e.key.length === 1) {
      const code = e.key.toLowerCase().charCodeAt(0) - 96;
      if (code >= 1 && code <= 26) {
        sendSSHInput(String.fromCharCode(code));
        e.preventDefault();
        return;
      }
    }
    const mapped = KEY_MAP[e.key];
    if (mapped) {
      sendSSHInput(mapped);
      e.preventDefault();
      return;
    }
    // Mobile soft keyboards often fire keydown with key='Unidentified'.
    // Fall back to keyCode for Enter (13) and Backspace (8).
    if (e.key === 'Unidentified') {
      // eslint-disable-next-line @typescript-eslint/no-deprecated -- keyCode is the only signal mobile soft keyboards provide for Unidentified keys
      if (e.keyCode === 13) { sendSSHInput('\r'); e.preventDefault(); return; }
      // eslint-disable-next-line @typescript-eslint/no-deprecated
      if (e.keyCode === 8) { sendSSHInput('\x7f'); e.preventDefault(); return; }
    }
    if (!appState.imeMode && e.key.length === 1 && !e.ctrlKey && !e.altKey && !e.metaKey) {
      if (appState.ctrlActive) {
        const code = e.key.toLowerCase().charCodeAt(0) - 96;
        sendSSHInput(code >= 1 && code <= 26 ? String.fromCharCode(code) : e.key);
        setCtrlActive(false);
      } else {
        sendSSHInput(e.key);
      }
      e.preventDefault();
      directEl.value = '';
    }
  });
}
