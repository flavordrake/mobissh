/**
 * modules/ui.ts — UI chrome
 *
 * Session menu, tab bar, key bar, connect form, status indicator,
 * toast utility, IME focus, Ctrl modifier, and Compose mode management.
 */

import type { UIDeps, ConnectionStatus, RootCSS, ThemeName, SftpEntry } from './types.js';
import { KEY_REPEAT, THEMES, THEME_ORDER, escHtml } from './constants.js';
import { appState, currentSession, isSessionConnected, onStateChange, transitionSession } from './state.js';
import { applyTheme, _addNotification, fireNotification, setSessionTitleBase, clearNotifications, getNotifications } from './terminal.js';
// eslint-disable-next-line @typescript-eslint/no-unused-vars -- backward compat: sendSftpUpload kept for legacy callers
import { sendSSHInput, sendSSHInputToAll, disconnect, reconnect, probeSession, cancelReconnect, sendSftpLs, setSftpHandler, sendSftpDownload, sendSftpUpload, sendSftpRename, sendSftpDelete, sendSftpRealpath, uploadFileChunked, sendSftpUploadCancel, getSessionHandle, removeSessionHandle } from './connection.js';
import { saveProfile, connectFromProfile, newConnection, loadProfiles, removeRecentSession, getRecentSessions, downloadProfilesExport, triggerProfileImport } from './profiles.js';
import { clearIMEPreview, restoreIMEOverlay } from './ime.js';
import { isPreviewable, createPreviewPanel } from './sftp-preview.js';

/** Update session menu button text without clobbering the notification badge (#458).
 * Delegates to setSessionTitleBase which preserves the current notification count. */
function _setMenuBtnText(text: string): void {
  setSessionTitleBase(text);
}

// ── Notifications review modal (#458) ───────────────────────────────────────

function _formatRelativeTime(ts: number): string {
  const delta = Date.now() - ts;
  const mins = Math.floor(delta / 60000);
  if (mins < 1) return 'just now';
  if (mins === 1) return '1 min ago';
  if (mins < 60) return `${String(mins)} mins ago`;
  const hours = Math.floor(mins / 60);
  return hours === 1 ? '1 hour ago' : `${String(hours)} hours ago`;
}

function _renderNotifModalList(): void {
  const list = document.getElementById('notifModalList');
  if (!list) return;
  const notifs = getNotifications();
  if (notifs.length === 0) {
    list.innerHTML = '<p class="notif-modal-empty">No notifications</p>';
    return;
  }
  list.innerHTML = notifs.slice().reverse().map((n) => {
    const age = _formatRelativeTime(n.time);
    return `<div class="notif-modal-item">`
      + `<div class="notif-modal-item-time">${escHtml(age)}</div>`
      + `<div class="notif-modal-item-message">${escHtml(n.message)}</div>`
      + `</div>`;
  }).join('');
}

/** Open the notifications review modal (#458). */
export function showNotifModal(): void {
  const modal = document.getElementById('notifModal');
  if (!modal) return;
  _renderNotifModalList();
  modal.classList.remove('hidden');
}

// ── Hash routing (#137) ─────────────────────────────────────────────────────

type PanelName = 'terminal' | 'connect' | 'files' | 'settings';

const VALID_PANELS: ReadonlySet<string> = new Set<PanelName>(['terminal', 'connect', 'files', 'settings']);

function _isValidPanel(hash: string): hash is PanelName {
  return VALID_PANELS.has(hash);
}

function _panelFromHash(): PanelName | null {
  const raw = location.hash.replace(/^#/, '');
  if (raw.startsWith('files/') || raw.startsWith('files%2F') || raw === 'files') return 'files';
  // Redirect legacy #keys to connect panel (#441)
  if (raw === 'keys') return 'connect';
  return _isValidPanel(raw) ? raw : null;
}

function _filePathFromHash(): string | null {
  const raw = location.hash.replace(/^#/, '');
  if (raw.startsWith('files/') || raw.startsWith('files%2F')) {
    const encoded = raw.slice('files'.length);
    try { return decodeURIComponent(encoded); } catch { return null; }
  }
  return null;
}

export function navigateToPanel(
  panel: PanelName,
  options?: { pushHistory?: boolean; updateHash?: boolean },
): void {
  const pushHistory = options?.pushHistory ?? false;
  const updateHash = options?.updateHash ?? true;

  document.querySelectorAll('.tab').forEach((t) => { t.classList.remove('active'); });
  document.querySelectorAll('.panel').forEach((p) => { p.classList.remove('active'); });

  document.querySelector<HTMLElement>(`[data-panel="${panel}"]`)?.classList.add('active');
  document.getElementById(`panel-${panel}`)?.classList.add('active');

  // Persistent session bar (#452): keep panel-terminal structurally "active"
  // when Files is showing so the chrome (handle strip + key bar) keeps
  // rendering beneath the overlay. DO NOT MOVE any DOM elements — xterm.js
  // and the ResizeObserver are coupled to the current structure.
  if (panel === 'files') {
    document.getElementById('panel-terminal')?.classList.add('active');
  }
  document.body.classList.toggle('files-overlay', panel === 'files');

  if (panel === 'terminal') {
    // Panel just became visible — fit the active session to real dimensions
    const s = currentSession();
    const handle = s ? getSessionHandle(s.id) : undefined;
    if (handle) {
      handle.fit();
    }
    focusIME();
    restoreIMEOverlay();
  }
  if (panel === 'connect') {
    // Only refresh if the form isn't already open (avoids clobbering edit-in-progress)
    const form = document.getElementById('connect-form-section') as HTMLDetailsElement | null;
    if (!form?.open) {
      loadProfiles();
    }
  }
  if (panel === 'files') {
    // Render the active session's files state whenever the panel is shown (#409)
    _activateFilesForCurrentSession();
  }
  // Respect user's explicit tab bar preference (#393). The handle bar toggle
  // persists to localStorage — don't override it on panel switch.

  if (updateHash) {
    const newHash = `#${panel}`;
    if (location.hash !== newHash) {
      if (pushHistory) {
        history.pushState(null, '', newHash);
      } else {
        history.replaceState(null, '', newHash);
      }
    }
  }
}

/** Resolve the initial panel on cold start (#137, #90). */
export function initRouting(hasProfiles: boolean): void {
  const fromHash = _panelFromHash();
  if (fromHash) {
    // Store deep link path for files panel — SFTP not ready yet at cold start
    if (fromHash === 'files') {
      _activeFilesState().deepLinkPath = _filePathFromHash();
    }
    navigateToPanel(fromHash);
  } else {
    // No hash — start on Connect panel (no lobby terminal)
    navigateToPanel('connect');
  }
}

// ── Module state ────────────────────────────────────────────────────────────

let _keyboardVisible = (): boolean => false;
let _ROOT_CSS: RootCSS = { tabHeight: '56px', keybarHeight: '34px' };
let _keybarRowPx = 34;
let _applyFontSize = (_size: number): void => {};
let _applyTheme = (_name: string, _opts?: { persist?: boolean }): void => {};

export function initUI({ keyboardVisible, ROOT_CSS, applyFontSize, applyTheme }: UIDeps): void {
  _keyboardVisible = keyboardVisible;
  _ROOT_CSS = ROOT_CSS;
  _keybarRowPx = parseInt(ROOT_CSS.keybarHeight, 10);
  _applyFontSize = applyFontSize;
  _applyTheme = applyTheme;
}

// ── Long-press tooltip (#111) ────────────────────────────────────────────────

let _tooltipEl: HTMLDivElement | null = null;
let _tooltipTimer: ReturnType<typeof setTimeout> | null = null;

function _getTooltipEl(): HTMLDivElement {
  if (!_tooltipEl) {
    _tooltipEl = document.createElement('div');
    _tooltipEl.className = 'toolbar-tooltip hidden';
    document.body.appendChild(_tooltipEl);
  }
  return _tooltipEl;
}

function _hideTooltip(): void {
  if (_tooltipTimer) { clearTimeout(_tooltipTimer); _tooltipTimer = null; }
  _getTooltipEl().classList.add('hidden');
}

export function initLongPressTooltips(): void {
  document.addEventListener('touchstart', (e: TouchEvent) => {
    const target = (e.target as Element).closest<HTMLElement>('[data-tooltip]');
    if (!target) return;
    const text = target.dataset['tooltip'];
    if (!text) return;

    // Prevent focus loss that would dismiss the keyboard (#124)
    if (_keyboardVisible()) e.preventDefault();

    if (_tooltipTimer) clearTimeout(_tooltipTimer);
    _tooltipTimer = setTimeout(() => {
      _tooltipTimer = null;
      const rect = target.getBoundingClientRect();
      const el = _getTooltipEl();
      el.textContent = text;
      el.classList.remove('hidden');
      // Position: centered horizontally over button, above it
      // CSS custom properties drive the position (no inline styles)
      const tipW = el.offsetWidth || 80;
      const left = Math.max(8, Math.min(rect.left + rect.width / 2 - tipW / 2, window.innerWidth - tipW - 8));
      const top = Math.max(8, rect.top - el.offsetHeight - 8);
      el.style.setProperty('--tooltip-left', `${String(left)}px`);
      el.style.setProperty('--tooltip-top', `${String(top)}px`);
    }, 500);
  });

  document.addEventListener('touchend', _hideTooltip, { passive: true });
  document.addEventListener('touchmove', _hideTooltip, { passive: true });
  document.addEventListener('touchcancel', _hideTooltip, { passive: true });
}

// ── Toast ────────────────────────────────────────────────────────────────────

let toastTimer: ReturnType<typeof setTimeout> | null = null;
export function toast(msg: string): void {
  let el = document.getElementById('toast');
  if (!el) {
    el = document.createElement('div');
    el.id = 'toast';
    document.body.appendChild(el);
  }
  el.textContent = msg;
  el.classList.add('show');
  if (toastTimer) clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.classList.remove('show'); }, 2500);
}

// ── Error dialog ────────────────────────────────────────────────────────────

export function showErrorDialog(message: string): void {
  const overlay = document.getElementById('errorDialogOverlay');
  const text = document.getElementById('errorDialogText');
  const dismiss = document.getElementById('errorDialogDismiss');
  if (!overlay || !text) return;
  text.textContent = message;
  overlay.classList.remove('hidden');
  dismiss?.addEventListener('click', () => {
    overlay.classList.add('hidden');
    // Cancel any background reconnect loop so it doesn't re-show the dialog (#417)
    cancelReconnect();
  }, { once: true });
}

// ── Status indicator ─────────────────────────────────────────────────────────

export function setStatus(state: ConnectionStatus, text: string): void {
  if (state === 'connected') {
    _setMenuBtnText(text);
  } else {
    // Only reset to 'MobiSSH' if NO session is connected — a background session
    // disconnecting shouldn't clobber the active connected session's name (#362)
    const anyConnected = Array.from(appState.sessions.values()).some(s => isSessionConnected(s));
    if (!anyConnected) _setMenuBtnText('MobiSSH');
  }
  const btn = document.getElementById('sessionMenuBtn');
  if (btn) btn.classList.toggle('connected', state === 'connected');
  // Enable/disable upload buttons based on connection state
  const connected = state === 'connected';
  document.querySelectorAll<HTMLButtonElement>('.files-upload-btn, #transferUploadBtn').forEach(b => {
    b.disabled = !connected;
  });
}

// ── Session list (#60) ───────────────────────────────────────────────────────

export function renderSessionList(): void {
  const container = document.getElementById('sessionList');
  if (!container) return;

  // Dedup safety net: only show one entry per host+port+username (#391)
  const seen = new Set<string>();
  const sessions = Array.from(appState.sessions.values()).filter((s) => {
    if (!s.profile) return true;
    const key = `${s.profile.host}:${String(s.profile.port || 22)}:${s.profile.username}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });

  container.classList.remove('hidden');

  const items = sessions.map((s) => {
    const label = s.profile
      ? escHtml(s.profile.title || `${s.profile.username}@${s.profile.host}`)
      : escHtml(s.id);
    const isActive = s.id === appState.activeSessionId;
    const activeClass = isActive ? ' active' : '';
    const dotClass = isSessionConnected(s) ? ' session-item-dot-connected' : '';
    // State-derived CSS class for session lifecycle (#324): session-connected, session-disconnected, etc.
    const stateClass = `session-${s.state}`;
    return `<div class="session-item${activeClass}" data-session-id="${escHtml(s.id)}" data-state="${s.state}" role="menuitem">
      <span class="session-item-dot ${stateClass}${dotClass}" aria-hidden="true"></span>
      <span class="session-item-label">${label}</span>
      <button class="session-item-close" data-close-id="${escHtml(s.id)}" aria-label="Close session">✕</button>
    </div>`;
  }).join('');

  container.innerHTML = items + '<button class="session-list-new" id="sessionListNewBtn" role="menuitem">+ New session</button>';

  container.querySelectorAll<HTMLElement>('.session-item').forEach((item) => {
    item.addEventListener('click', (e) => {
      // Don't switch if the close button was clicked
      const target = e.target as HTMLElement;
      if (target.closest('.session-item-close')) return;
      const id = item.dataset.sessionId;
      if (id) switchSession(id);
    });
  });

  container.querySelectorAll<HTMLElement>('.session-item-close').forEach((btn) => {
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      const id = btn.dataset.closeId;
      if (id) closeSession(id);
    });
  });

  document.getElementById('sessionListNewBtn')?.addEventListener('click', () => {
    document.getElementById('sessionMenu')?.classList.add('hidden');
    document.getElementById('menuBackdrop')?.classList.add('hidden');
    navigateToPanel('connect');
  });
}

export function switchSession(id: string): void {
  const session = appState.sessions.get(id);
  if (!session) return;

  appState.activeSessionId = id;

  // Hide all terminal containers, show the active one via SessionHandle (#374)
  for (const [sid] of appState.sessions) {
    const h = getSessionHandle(sid);
    if (h) {
      if (sid === id) h.show(); else h.hide();
    }
  }
  // Fallback for sessions without a handle (legacy)
  document.querySelectorAll<HTMLElement>('#terminal > [data-session-id]').forEach((el) => {
    if (!getSessionHandle(el.dataset.sessionId ?? '')) {
      el.classList.toggle('hidden', el.dataset.sessionId !== id);
    }
  });

  // Restore per-session theme (#104)
  applyTheme(session.activeThemeName);

  // Auto-reconnect on switch: if not connected, reconnect unconditionally (#354)
  if (!isSessionConnected(session) && session.profile) {
    // Force-close stale WS if it exists
    if (session.ws) {
      try { session.ws.close(); } catch { /* ignore */ }
      session.ws = null;
    }
    toast('Reconnecting…');
    void reconnect(id);
  }

  // No automatic fit — terminal stays at its current layout size.
  // show() above replays any buffered output.

  // Update session menu button text + badge dot (no state text — dot is the indicator)
  const btn = document.getElementById('sessionMenuBtn');
  if (btn && session.profile) {
    _setMenuBtnText(session.profile.title || `${session.profile.username}@${session.profile.host}`);
    btn.classList.remove('connected', 'disconnected', 'connecting');
    if (isSessionConnected(session)) {
      btn.classList.add('connected');
    } else if (session.state === 'connecting' || session.state === 'authenticating' || session.state === 'reconnecting') {
      btn.classList.add('connecting');
    } else {
      btn.classList.add('disconnected');
    }
  }

  // Close the menu
  document.getElementById('sessionMenu')?.classList.add('hidden');
  document.getElementById('menuBackdrop')?.classList.add('hidden');

  // Re-render session list to update active indicator
  renderSessionList();

  // Restore IME focus so keyboard input reaches the session (#341)
  focusIME();

  // If the files panel is active, re-render to reflect the new session's
  // files state (path, cached listing, or trigger first-activation) (#409)
  if (document.getElementById('panel-files')?.classList.contains('active')) {
    _activateFilesForCurrentSession();
  }
}

export function closeSession(id: string): void {
  const session = appState.sessions.get(id);
  if (!session) return;

  if (isSessionConnected(session)) {
    if (!confirm('Disconnect and close this session?')) return;
  }

  // Remove from recent sessions on explicit close (#385)
  if (session.profile) {
    removeRecentSession(session.profile.host, session.profile.port || 22, session.profile.username);
  }

  // Clean up SessionHandle (disposes terminal, removes container, disconnects RO) (#374)
  removeSessionHandle(id);

  // Drop per-session files state (#409)
  _dropFilesState(id);

  // Transition through state machine — handles WS close, AbortController abort,
  // timer cleanup, terminal dispose via the 'closed' effect (#341)
  if (session.state !== 'closed') {
    transitionSession(id, 'closed');
  }

  // Remove terminal DOM container (fallback for sessions without handle)
  const termContainer = document.querySelector<HTMLElement>(`#terminal [data-session-id="${CSS.escape(id)}"]`);
  termContainer?.remove();

  // If we just closed the active session, switch to another or go to Connect
  if (appState.activeSessionId === id) {
    const remaining = Array.from(appState.sessions.keys());
    if (remaining.length > 0) {
      switchSession(remaining[0]!);
    } else {
      appState.activeSessionId = null;
      _setMenuBtnText('MobiSSH');
      const btn = document.getElementById('sessionMenuBtn');
      if (btn) btn.classList.remove('connected');
      // Restore default theme from localStorage
      const defaultTheme = localStorage.getItem('termTheme') ?? 'dark';
      _applyTheme(defaultTheme);
      navigateToPanel('connect');
    }
  }

  renderSessionList();
}

// ── Focus IME ────────────────────────────────────────────────────────────────

export function focusIME(): void {
  const id = appState.imeMode ? 'imeInput' : 'directInput';
  document.getElementById(id)?.focus({ preventScroll: true });
}

// ── Session menu (#39) ───────────────────────────────────────────────────────

export function initSessionMenu(): void {
  const menuBtn = document.getElementById('sessionMenuBtn')!;
  const menu = document.getElementById('sessionMenu')!;
  const backdrop = document.getElementById('menuBackdrop')!;

  // Subscribe to session state changes to keep UI in sync (#334 — one-time registration)
  onStateChange((session, newState, _oldState) => {
    renderSessionList();
    loadProfiles();
    const btn = document.getElementById('sessionMenuBtn');
    if (btn && session.id === appState.activeSessionId && session.profile) {
      _setMenuBtnText(session.profile.title || `${session.profile.username}@${session.profile.host}`);
      btn.classList.remove('connected', 'disconnected', 'connecting');
      if (isSessionConnected(session)) {
        btn.classList.add('connected');
      } else if (newState === 'connecting' || newState === 'authenticating' || newState === 'reconnecting') {
        btn.classList.add('connecting');
      } else {
        btn.classList.add('disconnected');
      }
    }
  });

  // Stop touch events from leaking through the menu to parent gesture handlers
  menu.addEventListener('touchmove', (e) => { e.stopPropagation(); }, { passive: false });

  // Sync session menu theme label with the active theme
  const initialTheme = THEMES[appState.activeThemeName];
  const themeBtn = document.getElementById('sessionThemeBtn');
  if (themeBtn) themeBtn.textContent = `Theme: ${initialTheme.label} ▸`;

  // Prevent focus theft from any session-bar button when keyboard is visible (#115).
  // Container-level handler covers menuBtn, compose, preview, bell, hamburger.
  const handleBar = document.getElementById('key-bar-handle');
  if (handleBar) {
    handleBar.addEventListener('mousedown', (e) => {
      if (_keyboardVisible()) e.preventDefault();
    });
  }

  menuBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    const wasHidden = menu.classList.toggle('hidden');
    backdrop.classList.toggle('hidden', wasHidden);
    // Position menu bottom above the handle bar using actual element position
    if (!wasHidden) {
      const handleBar = document.getElementById('key-bar-handle');
      if (handleBar) {
        const handleTop = handleBar.getBoundingClientRect().top;
        menu.style.bottom = `${String(window.innerHeight - handleTop + 4)}px`;
      }
    }
  });

  function closeMenu(): void { menu.classList.add('hidden'); backdrop.classList.add('hidden'); }

  // ── Swipe left/right on session title to switch sessions ──────────────
  let _swipeX0: number | null = null;
  let _swipeClaimed = false;
  const _origText = { value: '' };

  menuBtn.addEventListener('touchstart', (e) => {
    if (appState.sessions.size <= 1) return;
    _swipeX0 = e.touches[0]!.clientX;
    _swipeClaimed = false;
    _origText.value = menuBtn.textContent || '';
  }, { passive: true });

  menuBtn.addEventListener('touchmove', (e) => {
    if (_swipeX0 === null) return;
    const dx = e.touches[0]!.clientX - _swipeX0;
    if (!_swipeClaimed && Math.abs(dx) > 30) {
      _swipeClaimed = true;
      e.preventDefault();
      // Peek: show next/prev session name
      const keys = Array.from(appState.sessions.keys());
      const idx = keys.indexOf(appState.activeSessionId ?? '');
      const targetIdx = (idx + (dx > 0 ? -1 : 1) + keys.length) % keys.length;
      const target = appState.sessions.get(keys[targetIdx]!);
      if (target?.profile) {
        menuBtn.textContent = `→ ${target.profile.title || `${target.profile.username}@${target.profile.host}`}`;
        menuBtn.style.opacity = '0.6';
      }
    }
  }, { passive: false });

  menuBtn.addEventListener('touchend', (e) => {
    if (!_swipeClaimed) { _swipeX0 = null; return; }
    // No swipe guard — the menu should NEVER be blocked
    const dx = (e.changedTouches[0]?.clientX ?? _swipeX0 ?? 0) - (_swipeX0 ?? 0);
    _swipeX0 = null;
    menuBtn.style.opacity = '';

    const keys = Array.from(appState.sessions.keys());
    const idx = keys.indexOf(appState.activeSessionId ?? '');
    const targetIdx = (idx + (dx > 0 ? -1 : 1) + keys.length) % keys.length;
    switchSession(keys[targetIdx]!);
    if ('vibrate' in navigator) navigator.vibrate(10);
  });

  // Hamburger ≡ button — opens the session menu (single entry point for
  // per-session controls, including Files) (#449).
  document.getElementById('handleMenuBtn')!.addEventListener('click', (e) => {
    e.stopPropagation();
    const wasHidden = menu.classList.toggle('hidden');
    backdrop.classList.toggle('hidden', wasHidden);
    if (!wasHidden) {
      const hb = document.getElementById('key-bar-handle');
      if (hb) {
        const handleTop = hb.getBoundingClientRect().top;
        menu.style.bottom = `${String(window.innerHeight - handleTop + 4)}px`;
      }
    }
  });

  // Swipe up on handle → show tab bar; swipe down → hide tab bar (#149).
  // Replaces the hamburger ≡ button as primary gesture surface.
  const handle = document.getElementById('key-bar-handle')!;
  let _swipeTouchId = -1;
  let _swipeStartY = 0;

  // Scrollable overlays that can overlap the handle strip (#268).
  const _scrollableOverlay = '#sessionMenu, .notif-drawer-list, .debug-panel-log, .files-body, .vault-file-list';

  handle.addEventListener('touchstart', (e) => {
    const t = e.touches[0];
    if (e.touches.length === 1 && t) {
      // If touch originated inside a scrollable overlay, let the overlay own the gesture (#268).
      const target = t.target as Element | null;
      if (target && target.closest(_scrollableOverlay)) return;
      _swipeTouchId = t.identifier;
      _swipeStartY = t.clientY;
    }
  }, { passive: true });

  handle.addEventListener('touchend', (e) => {
    const touch = Array.from(e.changedTouches).find((t) => t.identifier === _swipeTouchId);
    if (!touch) return;
    _swipeTouchId = -1;
    const deltaY = _swipeStartY - touch.clientY;
    // Upward swipe (deltaY > 30): reveal navbar first if hidden, else cycle depth (#449).
    if (deltaY > 30) {
      if (!appState.tabBarVisible) {
        appState.tabBarVisible = true;
        _applyTabBarVisibility();
      } else if (appState.keyBarDepth < 3) {
        setKeyBarDepth((appState.keyBarDepth + 1) as 0 | 1 | 2 | 3);
      }
    } else if (deltaY < -30 && appState.keyBarDepth > 0) {
      setKeyBarDepth((appState.keyBarDepth - 1) as 0 | 1 | 2 | 3);
    }
  }, { passive: true });

  // Down-swipe on the tab bar hides it (#449).
  const tabBarEl = document.getElementById('tabBar');
  if (tabBarEl) {
    let _tabSwipeTouchId = -1;
    let _tabSwipeStartY = 0;
    tabBarEl.addEventListener('touchstart', (e) => {
      const t = e.touches[0];
      if (e.touches.length === 1 && t) {
        _tabSwipeTouchId = t.identifier;
        _tabSwipeStartY = t.clientY;
      }
    }, { passive: true });
    tabBarEl.addEventListener('touchend', (e) => {
      const touch = Array.from(e.changedTouches).find((t) => t.identifier === _tabSwipeTouchId);
      if (!touch) return;
      _tabSwipeTouchId = -1;
      const deltaY = touch.clientY - _tabSwipeStartY;
      if (deltaY > 30 && appState.tabBarVisible) {
        appState.tabBarVisible = false;
        _applyTabBarVisibility();
      }
    }, { passive: true });
  }

  backdrop.addEventListener('mousedown', (e) => { if (_keyboardVisible()) e.preventDefault(); });
  backdrop.addEventListener('click', closeMenu);
  menu.addEventListener('mousedown', (e) => { if (_keyboardVisible()) e.preventDefault(); });

  // Font size +/− — menu stays open so user can tap repeatedly (#46)
  document.getElementById('fontDecBtn')!.addEventListener('click', (e) => {
    e.stopPropagation();
    _applyFontSize((parseInt(localStorage.getItem('fontSize') ?? '14') || 14) - 1);
  });
  document.getElementById('fontIncBtn')!.addEventListener('click', (e) => {
    e.stopPropagation();
    _applyFontSize((parseInt(localStorage.getItem('fontSize') ?? '14') || 14) + 1);
  });

  document.getElementById('sessionResetBtn')!.addEventListener('click', () => {
    closeMenu();
    const _cs = currentSession(); if (!_cs || !isSessionConnected(_cs)) return;
    sendSSHInput('\x1bc');
    currentSession()?.terminal?.reset();
  });

  document.getElementById('sessionClearBtn')!.addEventListener('click', () => {
    closeMenu();
    currentSession()?.terminal?.clear();
  });


  document.getElementById('sessionReconnectBtn')!.addEventListener('click', () => {
    closeMenu();
    if (appState.activeSessionId) void reconnect(appState.activeSessionId);
  });

  document.getElementById('sessionNavBarBtn')!.addEventListener('click', () => {
    closeMenu();
    toggleTabBar();
  });

  document.getElementById('sessionDisconnectBtn')!.addEventListener('click', () => {
    closeMenu();
    const sessionId = appState.activeSessionId;
    if (sessionId) disconnect(sessionId);
    if (sessionId) closeSession(sessionId);
  });

  // Theme cycle — persist to session so it survives switching (#104)
  document.getElementById('sessionThemeBtn')!.addEventListener('click', (e) => {
    e.stopPropagation();
    const idx = THEME_ORDER.indexOf(appState.activeThemeName);
    const next = THEME_ORDER[(idx + 1) % THEME_ORDER.length] as ThemeName;
    _applyTheme(next, { persist: false });
    const session = currentSession();
    if (session) session.activeThemeName = next;
  });
}

// ── Tab navigation ───────────────────────────────────────────────────────────

export function initTabBar(): void {
  const storedTabBar = localStorage.getItem('tabBarVisible');
  if (storedTabBar === 'false') appState.tabBarVisible = false;
  _applyTabBarVisibility();

  document.querySelectorAll<HTMLElement>('.tab').forEach((tab) => {
    tab.addEventListener('click', () => {
      const panelId = tab.dataset.panel;
      if (panelId && _isValidPanel(panelId)) {
        navigateToPanel(panelId, { pushHistory: true });
      }
    });
  });

  // Browser back/forward (#137, #90, #188)
  // Use popstate instead of hashchange so directory navigation coexists
  // with modal dismiss (detail sheet / context menu) history entries.
  window.addEventListener('popstate', (event) => {
    const state = event.state as Record<string, unknown> | null;

    // Modal dismiss entries are handled by their own popstate listeners
    // (_showDetailsPanel, _showContextMenu). Skip them here.
    if (state && (state.detailSheet === true || state.ctxMenu === true)) return;

    // Structured files state from _filesNavigateTo (#188)
    if (state && state.type === 'files' && typeof state.path === 'string') {
      navigateToPanel('files', { updateHash: false });
      _filesNavigateTo(state.path, { fromPopstate: true });
      return;
    }

    // Fallback: parse hash for panel navigation (#137)
    const panel = _panelFromHash();
    if (panel) {
      navigateToPanel(panel, { updateHash: false });
      if (panel === 'files') {
        const filePath = _filePathFromHash();
        if (filePath) {
          _filesNavigateTo(filePath, { fromPopstate: true });
        }
      }
    }
  });
}

export function _applyTabBarVisibility(): void {
  document.getElementById('tabBar')?.classList.toggle('hidden', !appState.tabBarVisible);
  document.documentElement.style.setProperty(
    '--tab-height',
    appState.tabBarVisible ? _ROOT_CSS.tabHeight : '0px'
  );
  // Only persist when value actually changes (called from 16+ sites)
  const stored = localStorage.getItem('tabBarVisible');
  const current = String(appState.tabBarVisible);
  if (stored !== current) localStorage.setItem('tabBarVisible', current);
}

function toggleTabBar(): void {
  appState.tabBarVisible = !appState.tabBarVisible;
  _applyTabBarVisibility();
  // ResizeObserver on #terminal handles fit() + resize message after layout settles.
}

/**
 * Attach focus/blur handlers that promote a field to type="password" only while
 * focused, then demote back to type="text" on blur.  This prevents Chrome from
 * detecting a login-form pattern at rest (username + password in same form) while
 * still suppressing IME/Gboard while the user is actively typing. (#147/#150)
 */
function _initPasswordFieldCloaking(field: HTMLInputElement): void {
  field.type = 'text';
  field.addEventListener('focus', () => { field.type = 'password'; });
  field.addEventListener('blur',  () => { field.type = 'text'; });
}

// ── Connect form ─────────────────────────────────────────────────────────────

export function initConnectForm(): void {
  const form = document.getElementById('connectForm')!;
  const authType = document.getElementById('authType') as HTMLSelectElement;

  authType.addEventListener('change', () => {
    const isKey = authType.value === 'key';
    document.getElementById('passwordGroup')!.classList.toggle('hidden', isKey);
    document.getElementById('keyGroup')!.classList.toggle('hidden', !isKey);
  });

  // Cloak password fields: type="text" at rest, type="password" only while focused (#150)
  _initPasswordFieldCloaking(document.getElementById('remote_c') as HTMLInputElement);
  const remotePp = document.getElementById('remote_pp') as HTMLInputElement | null;
  if (remotePp) _initPasswordFieldCloaking(remotePp);

  // Key dropdown: show/hide manual key entry based on selection
  const keyDropdown = document.getElementById('selectedKeyId') as HTMLSelectElement | null;
  const manualKeyGroup = document.getElementById('manualKeyGroup');
  keyDropdown?.addEventListener('change', () => {
    const showManual = keyDropdown.value === 'manual';
    manualKeyGroup?.classList.toggle('hidden', !showManual);
  });

  // Auto-populate profile name from hostname (#16)
  const hostInput = document.getElementById('host') as HTMLInputElement;
  const nameInput = document.getElementById('profileName') as HTMLInputElement;
  let nameManuallySet = false;

  nameInput.addEventListener('input', () => { nameManuallySet = true; });
  nameInput.addEventListener('focus', () => {
    if (!nameInput.value) nameManuallySet = false;
  });
  hostInput.addEventListener('input', () => {
    if (!nameManuallySet) {
      nameInput.value = hostInput.value.trim();
    }
  });

  form.addEventListener('submit', (e) => {
    e.preventDefault();

    const privateKeyEl = document.getElementById('privateKey') as HTMLTextAreaElement | null;
    const remotePpEl = document.getElementById('remote_pp') as HTMLInputElement | null;

    const profile = {
      title: (document.getElementById('profileName') as HTMLInputElement).value.trim() || 'Server',
      host: (document.getElementById('host') as HTMLInputElement).value.trim(),
      port: parseInt((document.getElementById('port') as HTMLInputElement).value) || 22,
      username: (document.getElementById('remote_a') as HTMLInputElement).value.trim(),
      authType: authType.value as 'password' | 'key',
      password: (document.getElementById('remote_c') as HTMLInputElement).value,
      privateKey: privateKeyEl?.value.trim() ?? '',
      passphrase: remotePpEl?.value ?? '',
      initialCommand: (document.getElementById('initialCommand') as HTMLInputElement).value.trim(),
    };

    (document.getElementById('remote_c') as HTMLInputElement).value = '';
    if (remotePpEl) remotePpEl.value = '';

    void saveProfile(profile).then(() => {
      // Collapse form after save
      const formSection = document.getElementById('connect-form-section') as HTMLDetailsElement | null;
      if (formSection) formSection.open = false;
    });
  });

  // Connect panel bottom navbar (#419)
  document.getElementById('connectNavbar')?.addEventListener('click', (e) => {
    const target = (e.target as HTMLElement).closest<HTMLElement>('[data-action]');
    if (!target) return;
    const action = target.dataset.action;
    if (action === 'new') newConnection();
    else if (action === 'import') triggerProfileImport();
    else if (action === 'export') downloadProfilesExport();
    // Keys button removed — key management is now inline in Connect panel (#441)
  });

  document.getElementById('profileList')!.addEventListener('click', (e) => {
    const target = (e.target as HTMLElement).closest<HTMLElement>('[data-action]');
    if (!target) return;
    const action = target.dataset.action;
    if (action === 'connect') {
      const idx = parseInt(target.dataset.idx ?? '0', 10);
      // Immediate visual feedback — shimmer animation (#318)
      target.classList.add('connecting');
      target.textContent = 'Connecting…';
      const clearAnim = (): void => { target.classList.remove('connecting'); target.textContent = 'Connect'; };
      // Clear when session reaches a terminal state (connected navigates away, failed/closed stays)
      onStateChange((_sess, newState) => {
        if (newState === 'connected' || newState === 'failed' || newState === 'closed' || newState === 'disconnected') clearAnim();
      });
      setTimeout(clearAnim, 30000); // Safety timeout
      void connectFromProfile(idx);
    } else if (action === 'switch') {
      const sessionId = target.dataset.sessionId;
      if (sessionId) {
        switchSession(sessionId);
        navigateToPanel('terminal');
      }
    } else if (action === 'disconnect') {
      const sessionId = target.dataset.sessionId;
      if (sessionId) {
        disconnect(sessionId);
        closeSession(sessionId);
        loadProfiles(); // Refresh to remove session actions
      }
    }
  });

  // Active sessions list click handler (#306)
  document.getElementById('activeSessionList')?.addEventListener('click', (e) => {
    const target = (e.target as HTMLElement).closest<HTMLElement>('[data-action]');
    if (!target) return;
    const action = target.dataset.action;
    const sessionId = target.dataset.sessionId;
    if (action === 'switch' && sessionId) {
      switchSession(sessionId);
      navigateToPanel('terminal');
    } else if (action === 'reconnect' && sessionId) {
      void reconnect(sessionId);
      target.classList.add('connecting');
      target.textContent = 'Reconnecting…';
      onStateChange((_sess, newState) => {
        if (newState === 'connected' || newState === 'failed' || newState === 'closed') {
          target.classList.remove('connecting');
          target.textContent = 'Reconnect';
          loadProfiles();
        }
      });
    } else if (action === 'close-session' && sessionId) {
      closeSession(sessionId);
      loadProfiles();
    } else if (action === 'reconnect-recent') {
      const idx = parseInt(target.dataset.idx ?? '0', 10);
      target.classList.add('connecting');
      target.textContent = 'Connecting…';
      void connectFromProfile(idx);
    } else if (action === 'reconnect-all-recent') {
      target.textContent = 'Connecting…';
      target.classList.add('connecting');
      const recent = getRecentSessions();
      void (async () => {
        for (const entry of recent) {
          await connectFromProfile(entry.profileIdx);
        }
        loadProfiles();
      })();
    } else if (action === 'reconnect-all') {
      target.textContent = 'Reconnecting…';
      target.classList.add('connecting');
      const promises: Promise<string>[] = [];
      for (const [sid, session] of appState.sessions) {
        if (!isSessionConnected(session) && session.profile) {
          promises.push(reconnect(sid));
        }
      }
      loadProfiles();
      void Promise.all(promises).then((results) => {
        const connected = results.filter(r => r === 'connected').length;
        const failed = results.filter(r => r !== 'connected').length;
        if (connected > 0 && failed === 0) toast(`${String(connected)} session(s) reconnected`);
        else if (connected > 0) toast(`${String(connected)} reconnected, ${String(failed)} failed`);
        else toast('Reconnect failed');
        loadProfiles();
      });
    }
  });
}

// ── Key bar ──────────────────────────────────────────────────────────────────

/** Pixels of pointer movement required to classify a gesture as scroll (not tap). */
const HAPTIC_SCROLL_THRESHOLD = 5;
/** Milliseconds to defer the haptic press callback — cancelled if scroll detected first. */
const HAPTIC_DEFER_MS = 50;

export function setCtrlActive(active: boolean): void {
  appState.ctrlActive = active;
  document.getElementById('keyCtrl')?.classList.toggle('active', active);
}

function _attachRepeat(element: HTMLElement, onRepeat: () => void, onPress?: () => void): void {
  let _delayTimer: ReturnType<typeof setTimeout> | null = null;
  let _intervalTimer: ReturnType<typeof setInterval> | null = null;
  let _hapticTimer: ReturnType<typeof setTimeout> | null = null;
  let _startX = 0;
  let _startY = 0;

  function _clear(): void {
    if (_delayTimer) clearTimeout(_delayTimer);
    if (_intervalTimer) clearInterval(_intervalTimer);
    if (_hapticTimer) { clearTimeout(_hapticTimer); _hapticTimer = null; }
    _delayTimer = _intervalTimer = null;
  }

  let _fired = false;
  let _cancelled = false;

  element.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    _startX = e.clientX;
    _startY = e.clientY;
    _fired = false;
    _cancelled = false;
    if (onPress) {
      _hapticTimer = setTimeout(() => { _hapticTimer = null; onPress(); }, HAPTIC_DEFER_MS);
    }
    // Don't fire immediately — wait for repeat delay. If the user lifts before
    // the delay, fire once on pointerup (tap). If they drag away, cancel.
    _delayTimer = setTimeout(() => {
      _fired = true;
      onRepeat(); // first repeat fires after delay
      _intervalTimer = setInterval(onRepeat, KEY_REPEAT.INTERVAL_MS);
    }, KEY_REPEAT.DELAY_MS);
  });

  element.addEventListener('pointermove', (e) => {
    const dx = Math.abs(e.clientX - _startX);
    const dy = Math.abs(e.clientY - _startY);
    // Cancel if dragged beyond threshold (user is scrolling, not tapping)
    if (dx > HAPTIC_SCROLL_THRESHOLD || dy > HAPTIC_SCROLL_THRESHOLD) {
      _cancelled = true;
      _clear();
      if (_hapticTimer !== null) {
        clearTimeout(_hapticTimer);
        _hapticTimer = null;
      }
    }
  });

  element.addEventListener('pointerup', () => {
    _clear();
    // If not cancelled and not already fired by repeat, fire once (tap)
    if (!_cancelled && !_fired) onRepeat();
    setTimeout(focusIME, 50);
  });
  element.addEventListener('pointercancel', () => { _cancelled = true; _clear(); });
  element.addEventListener('pointerleave', () => { _cancelled = true; _clear(); });
  element.addEventListener('contextmenu', (e) => { e.preventDefault(); });
}

export function initTerminalActions(): void {
  document.getElementById('keyCtrl')!.addEventListener('click', () => {
    if ('vibrate' in navigator) navigator.vibrate(10);
    setCtrlActive(!appState.ctrlActive);
    focusIME();
  });

  // Prevent key bar from stealing focus / dismissing keyboard (#225).
  // 1. tabindex="-1" makes buttons unfocusable (prevents Android keyboard dismiss)
  // 2. mousedown preventDefault handles desktop focus steal
  // No touchstart preventDefault — that blocks horizontal scroll.
  const keyBar = document.getElementById('key-bar');
  if (keyBar) {
    keyBar.addEventListener('mousedown', (e) => { e.preventDefault(); });
    keyBar.querySelectorAll<HTMLElement>('.key-btn').forEach((btn) => {
      btn.setAttribute('tabindex', '-1');
    });
  }

  const keys: Record<string, string> = {
    keyCtrlC:  '\x03',
    keyCtrlZ:  '\x1a',
    keyTab:    '\t',
    keySlash:  '/',
    keyPipe:   '|',
    keyDash:   '-',
    keyUp:     '\x1b[A',
    keyDown:   '\x1b[B',
    keyLeft:   '\x1b[D',
    keyRight:  '\x1b[C',
    keyHome:   '\x1b[H',
    keyEnd:    '\x1b[F',
    keyPgUp:   '\x1b[5~',
    keyPgDn:   '\x1b[6~',
    keyCtrlB:  '\x02',
    keyCtrlD:  '\x04',
    // Esc on row-keys (depth-1 primary)
    keyEscM2:  '\x1b',
    // Merged depth-1 row nav keys (same sequences, different element IDs)
    keyUpM:    '\x1b[A',
    keyDownM:  '\x1b[B',
    keyLeftM:  '\x1b[D',
    keyRightM: '\x1b[C',
    keyHomeM:  '\x1b[H',
    keyEndM:   '\x1b[F',
    keyPgUpM:  '\x1b[5~',
    keyPgDnM:  '\x1b[6~',
    keyCtrlBM: '\x02',
    keyCtrlDM: '\x04',
  };

  for (const [id, seq] of Object.entries(keys)) {
    const el = document.getElementById(id);
    if (!el) continue;
    _attachRepeat(
      el,
      () => {
        // Ctrl+key bypasses preview, sends to terminal directly
        if (appState.ctrlActive) {
          sendSSHInput(seq);
          return;
        }

        const ime = document.getElementById('imeInput') as HTMLTextAreaElement | null;
        if (ime && ime.classList.contains('ime-visible')) {
          // Route intelligently when IME preview is visible
          const start = ime.selectionStart;
          const end = ime.selectionEnd;

          // Arrow keys: move cursor in textarea, don't insert escape sequences
          const isArrow = seq === '\x1b[D' || seq === '\x1b[C'
            || seq === '\x1b[A' || seq === '\x1b[B';
          if (isArrow) {
            if (seq === '\x1b[D') {
              // left arrow
              const pos = Math.max(0, start - 1);
              ime.selectionStart = start - 1 >= 0 ? pos : 0;
              ime.selectionEnd = ime.selectionStart;
            } else if (seq === '\x1b[C') {
              // right arrow
              const pos = Math.min(ime.value.length, start + 1);
              ime.selectionStart = start + 1 <= ime.value.length ? pos : ime.value.length;
              ime.selectionEnd = ime.selectionStart;
            }
            // Up/Down arrows are no-ops in a single-line preview
            return;
          }

          // Backspace: delete char before cursor, don't send \x7f to terminal
          const isBackspace = seq === '\x7f' || seq === '\x08';
          if (isBackspace) {
            if (start > 0) {
              ime.value = ime.value.slice(0, start - 1) + ime.value.slice(end);
              ime.selectionStart = ime.selectionEnd = start - 1;
              ime.dispatchEvent(new Event('input', { bubbles: true }));
            }
            return;
          }

          // Enter: commit preview text then send carriage return, transition to idle
          const isEnter = seq === '\r' || seq === '\n';
          if (isEnter) {
            sendSSHInput(ime.value);
            sendSSHInput('\r');
            clearIMEPreview();
            return;
          }

          // Escape: dismiss preview (transition to idle), don't send to terminal
          const isEsc = seq === '\x1b';
          if (isEsc) {
            clearIMEPreview();
            return;
          }

          // Other printable keys: insert into textarea at cursor
          ime.value = ime.value.slice(0, start) + seq + ime.value.slice(ime.selectionEnd);
          ime.selectionStart = ime.selectionEnd = start + seq.length;
          ime.dispatchEvent(new Event('input', { bubbles: true }));
        } else {
          sendSSHInput(seq);
        }
      },
      () => { if ('vibrate' in navigator) navigator.vibrate(10); },
    );
  }
}

// ── Approval bar: Claude Code permission prompt responses ──────────────────

let _approvalTimer: ReturnType<typeof setInterval> | null = null;

function _clearApprovalTimer(): void {
  if (_approvalTimer) { clearInterval(_approvalTimer); _approvalTimer = null; }
}

export function initApprovalBar(): void {
  const bar = document.getElementById('approvalBar');
  const label = document.getElementById('approvalLabel');
  const buttons = document.getElementById('approvalButtons');
  const dismissBtn = document.getElementById('approvalDismiss');
  if (!bar || !label || !buttons) return;

  function dismiss(): void {
    _clearApprovalTimer();
    bar!.classList.add('hidden');
  }

  // Permanent dismiss — disables approval bar until re-enabled in Settings
  if (dismissBtn) {
    dismissBtn.addEventListener('click', () => {
      dismiss();
      localStorage.setItem('approvalBarDisabled', 'true');
      toast('Approval bar disabled. Re-enable in Settings.');
    });
    dismissBtn.addEventListener('mousedown', (ev) => { ev.preventDefault(); });
  }

  // Track the current approval's requestId for the gate response
  let _pendingRequestId: string | null = null;

  function sendAndDismiss(key: string): void {
    const decision = key === '1' ? 'allow' : 'deny';
    console.log(`[approval] button pressed: "${key}" → decision=${decision} requestId=${_pendingRequestId ?? 'none'}`);

    if (_pendingRequestId) {
      // Respond via HTTP to the approval gate — this unblocks the hook script
      void fetch('api/approval-respond', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ requestId: _pendingRequestId, decision }),
      }).catch(() => { /* network error — gate will timeout */ });
      _pendingRequestId = null;
    } else {
      // Fallback: no gate pending, send keystroke directly (legacy path)
      sendSSHInputToAll(key);
    }
    dismiss();
  }

  window.addEventListener('approval-prompt', ((e: CustomEvent) => {
    if (localStorage.getItem('approvalBarDisabled') === 'true') return;

    const { phase, sessionId, tool, detail, description, options, requestId } = e.detail as {
      phase: 'trigger' | 'ready';
      sessionId: string;
      requestId?: string;
      tool: string; detail: string; description: string;
      options: { key: string; label: string }[];
    };

    // Capture requestId for the gate response
    if (requestId) _pendingRequestId = requestId;

    // Deduplicate: SSE + WS both broadcast the same approval.
    const approvalKey = `${tool}:${detail}:${description}`;
    if (!bar.classList.contains('hidden') && bar.dataset.approvalKey === approvalKey) {
      return;
    }
    bar.dataset.approvalKey = approvalKey;

    // Build label
    let labelText = '';
    if (description) {
      labelText = description;
    } else if (tool) {
      labelText = detail ? `${tool}: ${detail}` : tool;
    }
    label.textContent = labelText || 'Approval required';

    const notifMsg = labelText || 'Approval required';
    _addNotification(`Approve: ${notifMsg}`);
    fireNotification('MobiSSH', `Approve: ${notifMsg}`);
    if ('vibrate' in navigator) navigator.vibrate([50, 80, 50]);

    console.log(`[approval] showing: "${notifMsg}"`);

    if (phase === 'trigger') {
      buttons.innerHTML = '<span class="approval-waiting">Waiting for options...</span>';
      bar.classList.remove('hidden');
      return;
    }

    // Phase: ready — show buttons
    _clearApprovalTimer();
    buttons.innerHTML = '';

    let yesKey = '';

    for (const opt of options) {
      const btn = document.createElement('button');
      btn.className = 'approval-btn';
      btn.setAttribute('tabindex', '-1');
      const lower = opt.label.toLowerCase();
      if (lower.includes('no') || lower.includes('deny') || lower.includes('reject')) {
        btn.classList.add('deny');
      } else if (!yesKey) {
        yesKey = opt.key;
      }
      btn.textContent = `(${opt.key}) ${opt.label}`;
      btn.addEventListener('click', () => { sendAndDismiss(opt.key); });
      btn.addEventListener('mousedown', (ev) => { ev.preventDefault(); });
      buttons.appendChild(btn);
    }

    // Auto-accept toggle — inline in the approval bar
    const autoRow = document.createElement('div');
    autoRow.className = 'approval-auto-row';
    const autoCheck = document.createElement('input');
    autoCheck.type = 'checkbox';
    autoCheck.id = 'approvalAutoToggle';
    const storedCountdown = parseInt(localStorage.getItem('approvalCountdown') ?? '0', 10);
    autoCheck.checked = storedCountdown > 0;
    const autoLabel = document.createElement('label');
    autoLabel.htmlFor = 'approvalAutoToggle';
    autoLabel.className = 'approval-auto-label';
    autoLabel.textContent = storedCountdown > 0 ? `Auto-accept (${String(storedCountdown)}s)` : 'Auto-accept';
    autoRow.appendChild(autoCheck);
    autoRow.appendChild(autoLabel);
    buttons.appendChild(autoRow);

    bar.classList.remove('hidden');

    let countdownEl: HTMLSpanElement | null = null;
    let targetBtn: HTMLButtonElement | null = null;

    function startCountdown(): void {
      if (!yesKey) return;
      const sec = parseInt(localStorage.getItem('approvalCountdown') ?? '10', 10) || 10;
      _clearApprovalTimer();

      targetBtn = Array.from(buttons!.querySelectorAll<HTMLButtonElement>('.approval-btn'))
        .find((b) => b.textContent?.includes(`(${yesKey})`)) ?? null; // eslint-disable-line @typescript-eslint/no-unnecessary-condition

      if (targetBtn) {
        targetBtn.classList.add('countdown-active');
      }

      // Insert VU-meter bar at bottom of approval bar
      let vuBar = bar!.querySelector<HTMLDivElement>('.approval-vu-bar');
      if (!vuBar) {
        vuBar = document.createElement('div');
        vuBar.className = 'approval-vu-bar';
        bar!.appendChild(vuBar);
      }
      vuBar.style.width = '100%';
      vuBar.style.transition = 'none';
      void vuBar.getBoundingClientRect();
      vuBar.style.transition = `width ${String(sec)}s linear`;
      vuBar.style.width = '0%';

      let remaining = sec;
      countdownEl = document.createElement('span');
      countdownEl.className = 'approval-countdown';
      countdownEl.textContent = `  (${String(remaining)}s)`;
      label!.appendChild(countdownEl);

      _approvalTimer = setInterval(() => {
        remaining--;
        if (remaining <= 0) {
          console.log(`[approval] auto-accept: "${yesKey}" after ${String(sec)}s`);
          sendAndDismiss(yesKey);
        } else if (countdownEl) {
          countdownEl.textContent = `  (${String(remaining)}s)`;
        }
      }, 1000);
    }

    function stopCountdown(): void {
      _clearApprovalTimer();
      if (countdownEl) { countdownEl.textContent = ''; countdownEl = null; }
      if (targetBtn) {
        targetBtn.classList.remove('countdown-active');
        targetBtn = null;
      }
      const vuBar = bar!.querySelector('.approval-vu-bar');
      if (vuBar) vuBar.remove();
    }

    autoCheck.addEventListener('change', () => {
      if (autoCheck.checked) {
        // Use stored value or default to 10s
        const val = parseInt(localStorage.getItem('approvalCountdown') ?? '0', 10);
        localStorage.setItem('approvalCountdown', val > 0 ? String(val) : '10');
        startCountdown();
      } else {
        localStorage.setItem('approvalCountdown', '0');
        stopCountdown();
      }
    });

    // Start countdown if auto-accept is already enabled
    if (autoCheck.checked && yesKey) {
      startCountdown();
    }
  }) as EventListener);
}

// Terminal resize observer removed (#374) — no automatic fitting.
// Each SessionHandle is a buffered terminal at its creation-time layout size.

// ── Key bar visibility (#1) + Compose/Direct mode (#146) ────────────────────

/**
 * One-time calibration listener that measures OS key repeat timing from
 * physical keyboard events and updates KEY_REPEAT in place.
 *
 * Collects TARGET_REPEATS auto-repeat events for a single held key, then:
 *   - delay   = time from initial keydown to first repeat (clamped 100–1000 ms)
 *   - interval = average gap between the subsequent repeats  (clamped 16–250 ms)
 *
 * Falls back to the hardcoded defaults if no physical key events occur.
 */
function _initKeyRepeatCalibration(): void {
  const TARGET_REPEATS = 4; // 1 delay sample + 3 interval samples

  let pressTime = 0;
  const repeatTimes: number[] = [];

  function handler(e: KeyboardEvent): void {
    if (!e.repeat) {
      // Fresh keydown — reset for a new measurement cycle.
      pressTime = e.timeStamp;
      repeatTimes.length = 0;
      return;
    }

    if (pressTime === 0) return;
    repeatTimes.push(e.timeStamp);
    if (repeatTimes.length < TARGET_REPEATS) return;

    // Enough samples — remove listener and apply calibration.
    window.removeEventListener('keydown', handler);

    const delayMs = Math.min(1000, Math.max(100, repeatTimes[0]! - pressTime));
    KEY_REPEAT.DELAY_MS = delayMs;

    if (repeatTimes.length >= 2) {
      let total = 0;
      for (let i = 1; i < repeatTimes.length; i++) {
        total += repeatTimes[i]! - repeatTimes[i - 1]!;
      }
      KEY_REPEAT.INTERVAL_MS = Math.min(250, Math.max(16, total / (repeatTimes.length - 1)));
    }
  }

  window.addEventListener('keydown', handler);
}

export function initKeyBar(): void {
  const stored = parseInt(localStorage.getItem('keyBarDepth') ?? '1', 10);
  appState.keyBarDepth = (stored >= 0 && stored <= 3) ? stored as 0 | 1 | 2 | 3 : 1;
  appState.imeMode = localStorage.getItem('imeMode') === 'ime';

  _applyKeyBarVisibility();
  if (appState.keyBarDepth === 3 && localStorage.getItem('tabBarVisible') !== 'false') {
    appState.tabBarVisible = true;
    _applyTabBarVisibility();
  }
  _applyComposeModeUI();
  _applyKeyControlsDock();
  _initKeyRepeatCalibration();

  document.getElementById('composeModeBtn')!.addEventListener('click', () => {
    toggleComposeMode();
    focusIME();
  });

}

function setKeyBarDepth(d: 0 | 1 | 2 | 3): void {
  appState.keyBarDepth = d;
  localStorage.setItem('keyBarDepth', String(d));
  _applyKeyBarVisibility();
  // Depth 3 shows tab bar; anything less hides it (when on terminal panel).
  const showTab = d === 3;
  if (appState.tabBarVisible !== showTab) {
    appState.tabBarVisible = showTab;
    _applyTabBarVisibility();
  }
  // ResizeObserver on #terminal handles fit() + resize message after layout settles.
}

function _applyKeyBarVisibility(): void {
  const bar = document.getElementById('key-bar')!;
  bar.classList.remove('depth-0', 'depth-1', 'depth-2', 'depth-3');
  bar.classList.add('depth-' + String(appState.keyBarDepth));
  // Depth 3 = two key rows + tab bar; key bar height same as depth 2.
  const keyRows = Math.min(appState.keyBarDepth, 2);
  document.documentElement.style.setProperty('--keybar-height', String(_keybarRowPx * keyRows) + 'px');
}

function _applyKeyControlsDock(): void {
  const dock = localStorage.getItem('keyControlsDock') ?? 'right';
  document.documentElement.classList.toggle('key-dock-left', dock === 'left');
}

export function toggleComposeMode(): void {
  appState.imeMode = !appState.imeMode;
  localStorage.setItem('imeMode', appState.imeMode ? 'ime' : 'direct');
  _applyComposeModeUI();
  // When leaving compose, clear any active preview
  if (!appState.imeMode) clearIMEPreview();
  focusIME();
}

function _applyComposeModeUI(): void {
  const btn = document.getElementById('composeModeBtn');
  if (!btn) return;
  btn.classList.toggle('compose-active', appState.imeMode);
  document.getElementById('key-bar')?.classList.toggle('compose-active', appState.imeMode);
  // Eye toggle only relevant in compose mode
  const previewBtn = document.getElementById('previewModeBtn');
  if (previewBtn) previewBtn.classList.toggle('hidden', !appState.imeMode);
}

// ── Files panel (#174, #175, #409) ───────────────────────────────────────────

/** Per-session files panel state (#409). One instance per active SSH session
 *  plus a synthetic "__default__" bucket used at cold start before any session
 *  exists (e.g., when a deep-link URL is opened but no connection is yet active). */
export interface FilesState {
  path: string;
  deepLinkPath: string | null;
  realpathReqId: string | null;
  firstActivated: boolean;
  cache: Map<string, SftpEntry[]>;
}

const _filesStateBySession = new Map<string, FilesState>();
const FILES_DEFAULT_KEY = '__default__';

function _makeFilesState(): FilesState {
  return {
    path: '/',
    deepLinkPath: null,
    realpathReqId: null,
    firstActivated: false,
    cache: new Map<string, SftpEntry[]>(),
  };
}

/** Return the per-session files state, creating it lazily on first access. */
export function _filesStateFor(sessionId: string): FilesState {
  let s = _filesStateBySession.get(sessionId);
  if (!s) { s = _makeFilesState(); _filesStateBySession.set(sessionId, s); }
  return s;
}

/** Return the files state for the currently active session, or a default
 *  bucket if no session is active (cold start / deep-link path). */
export function _activeFilesState(): FilesState {
  const id = appState.activeSessionId ?? FILES_DEFAULT_KEY;
  return _filesStateFor(id);
}

/** Drop a session's files state (called on close). */
export function _dropFilesState(sessionId: string): void {
  _filesStateBySession.delete(sessionId);
}

/** Maps outstanding files-panel requestIds to the sessionId that issued them,
 *  so the single SFTP handler can route results back to the right session's
 *  FilesState (#409). */
const _filesReqToSession = new Map<string, string>();

function _tagReq(reqId: string): void {
  const sid = appState.activeSessionId ?? FILES_DEFAULT_KEY;
  _filesReqToSession.set(reqId, sid);
}

function _stateForReq(reqId: string): FilesState | null {
  const sid = _filesReqToSession.get(reqId);
  if (sid === undefined) return null;
  return _filesStateFor(sid);
}
// Maps requestId -> path so SFTP ls responses can be matched to their requests
const _filesPending = new Map<string, string>();
// Maps requestId -> filename for pending downloads
const _downloadPending = new Map<string, string>();
// Set of requestIds that are preview downloads (not browser-save downloads)
const _previewPending = new Set<string>();
// Maps requestId -> remotePath for pending uploads
const _uploadPending = new Map<string, string>();
// Maps requestId -> parent dir for pending renames/deletes
const _renamePending = new Map<string, string>();
const _deletePending = new Map<string, string>();
// Long-press state
let _pressTimer: ReturnType<typeof setTimeout> | null = null;
let _longPressFired = false;
// Context menu dismiss handle (allows external callers to fully tear down)
let _ctxMenuDismiss: (() => void) | null = null;
let _uploadActive = false;
let _uploadCompleted = 0;
let _uploadTotal = 0;
let _transferStatus = '';
let _activeUploadRequestId: string | null = null;

interface TransferRecord {
  name: string;
  size: number;
  sent: number;
  status: 'active' | 'done' | 'failed';
  direction: 'upload' | 'download';
  error?: string;
  startTime: number;
}

export const _transferRecords = new Map<string, TransferRecord>();

let _transferRenderPending = false;
export function _renderTransferList(): void {
  if (_transferRenderPending) return;
  _transferRenderPending = true;
  requestAnimationFrame(() => {
    _transferRenderPending = false;
    _renderTransferListNow();
  });
}

const MAX_TRANSFER_RECORDS = 50;

function _evictOldTransfers(): void {
  if (_transferRecords.size <= MAX_TRANSFER_RECORDS) return;
  for (const [id, rec] of _transferRecords) {
    if (rec.status !== 'active' && _transferRecords.size > MAX_TRANSFER_RECORDS) {
      _transferRecords.delete(id);
    }
  }
}

function _renderTransferListNow(): void {
  _evictOldTransfers();
  const list = document.getElementById('transferList');
  if (!list) return;

  if (_transferRecords.size === 0) {
    list.innerHTML = '<div class="files-empty">No transfers yet.</div>';
    _updateTransferBadge();
    return;
  }

  const items: string[] = [];
  _transferRecords.forEach((rec, id) => {
    const pct = rec.size > 0 ? Math.round(rec.sent / rec.size * 100) : (rec.status === 'done' ? 100 : 0);
    const dirArrow = rec.direction === 'upload' ? '\u2191' : '\u2193';
    const dirClass = `transfer-direction transfer-direction-${rec.direction}`;
    let detail = '';
    if (rec.status === 'active' && rec.error) {
      detail = rec.error;
    } else if (rec.status === 'active') {
      const elapsed = (Date.now() - rec.startTime) / 1000;
      const rate = elapsed > 0 ? rec.sent / elapsed : 0;
      detail = `${_formatBytes(rec.sent)} / ${_formatBytes(rec.size)}  ${_formatBytes(rate)}/s`;
    } else if (rec.status === 'done') {
      const elapsed = (Date.now() - rec.startTime) / 1000;
      detail = `${_formatBytes(rec.size)}  ${elapsed > 0 ? _formatBytes(rec.size / elapsed) + '/s' : ''}`;
    } else {
      detail = rec.error ?? 'Failed';
    }
    items.push(`<div class="transfer-item" data-id="${escHtml(id)}">
      <div class="transfer-item-header">
        <span class="${dirClass}">${dirArrow}</span>
        <span class="transfer-item-name">${escHtml(rec.name)}</span>
        <span class="transfer-item-pct">${rec.status === 'active' ? String(pct) + '%' : rec.status === 'done' ? '\u2713' : '\u2717'}</span>
      </div>
      <div class="transfer-item-detail">${escHtml(detail)}</div>
      <div class="transfer-progress"><div class="transfer-progress-bar" style="width:${String(pct)}%"></div></div>
    </div>`);
  });
  list.innerHTML = items.join('');
  _updateTransferBadge();
}

function _updateTransferBadge(): void {
  let activeCount = 0;
  _transferRecords.forEach((rec) => { if (rec.status === 'active') activeCount++; });
  const badge = document.querySelector<HTMLElement>('.files-subtab[data-subtab="transfer"] .files-subtab-badge');
  if (activeCount > 0) {
    if (!badge) {
      const btn = document.querySelector<HTMLElement>('.files-subtab[data-subtab="transfer"]');
      if (btn) {
        const span = document.createElement('span');
        span.className = 'files-subtab-badge';
        span.textContent = String(activeCount);
        btn.appendChild(span);
      }
    } else {
      badge.textContent = String(activeCount);
    }
  } else {
    badge?.remove();
  }
}

/** Update the download button visibility based on file selection count. */
function _updateFileSelectionToolbar(panel: HTMLElement): void {
  const selected = panel.querySelectorAll('.files-entry.files-selected');
  const dlBtn = panel.querySelector<HTMLElement>('.files-download-btn');
  if (dlBtn) {
    if (selected.length > 0) {
      dlBtn.textContent = `Download (${String(selected.length)})`;
      dlBtn.classList.remove('hidden');
    } else {
      dlBtn.classList.add('hidden');
    }
  }
}

/** Download all selected files in the Explore panel. */
function _downloadSelectedFiles(panel: HTMLElement): void {
  const selected = panel.querySelectorAll<HTMLElement>('.files-entry.files-selected');
  selected.forEach((row) => {
    const filePath = row.dataset.path;
    if (!filePath) return;
    const filename = filePath.split('/').pop() ?? filePath;
    const reqId = `dl-${String(Date.now())}-${filename.slice(0, 8)}`;
    _downloadPending.set(reqId, filename);
    _transferRecords.set(reqId, { name: filename, size: 0, sent: 0, status: 'active', direction: 'download', startTime: Date.now() });
    sendSftpDownload(filePath, reqId);
    row.classList.remove('files-selected');
  });
  _renderTransferList();
  _updateFileSelectionToolbar(panel);
}

/** Wait for WS connection to be open, polling every 500ms up to timeoutMs. */
function _waitForConnection(timeoutMs: number): Promise<void> {
  return new Promise((resolve, reject) => {
    const ws = currentSession()?.ws;
    if (ws && ws.readyState === WebSocket.OPEN) { resolve(); return; }
    const start = Date.now();
    const interval = setInterval(() => {
      const sessionWs = currentSession()?.ws;
      if (sessionWs && sessionWs.readyState === WebSocket.OPEN) {
        clearInterval(interval);
        resolve();
      } else if (Date.now() - start > timeoutMs) {
        clearInterval(interval);
        reject(new Error('Connection timeout'));
      }
    }, 500);
  });
}

function _setTransferStatus(text: string): void {
  _transferStatus = text;
  const el = document.querySelector<HTMLElement>('.files-transfer-status');
  if (el) {
    el.textContent = text;
    el.classList.toggle('hidden', !text);
  }
  const cancelBtn = document.querySelector<HTMLElement>('.files-upload-cancel');
  if (cancelBtn) {
    cancelBtn.classList.toggle('hidden', !_uploadActive);
  }
}

function _triggerBlobDownload(filename: string, base64Data: string): void {
  const binary = atob(base64Data);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)!;
  const blob = new Blob([bytes]);
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => { URL.revokeObjectURL(url); }, 60_000);
}

function _formatBytes(n: number): string {
  if (n < 1024) return `${String(n)} B`;
  if (n < 1_048_576) return `${String(Math.round(n / 1024))} KB`;
  return `${(n / 1_048_576).toFixed(1)} MB`;
}

function _cancelActiveUpload(): void {
  if (_activeUploadRequestId) {
    sendSftpUploadCancel(_activeUploadRequestId);
    _uploadPending.delete(_activeUploadRequestId);
    _activeUploadRequestId = null;
    _uploadActive = false;
    _setTransferStatus('');
    toast('Upload cancelled');
  }
}

/** Pending upload queue — files added while an upload is in progress. */
const _uploadQueue: Array<{ file: File; remotePath: string }> = [];

async function _startUpload(files: FileList): Promise<void> {
  // Queue files — create transfer records immediately so they appear in the Transfer tab
  const newEntries: Array<{ file: File; remotePath: string; reqId: string }> = [];
  for (let i = 0; i < files.length; i++) {
    const file = files[i]!;
    const activePath = _activeFilesState().path;
    const remotePath = activePath === '/' ? `/${file.name}` : `${activePath}/${file.name}`;
    const reqId = `up-${String(Date.now())}-${String(i)}`;
    _transferRecords.set(reqId, { name: file.name, size: file.size, sent: 0, status: 'active', direction: 'upload', startTime: Date.now() });
    newEntries.push({ file, remotePath, reqId });
  }
  _renderTransferList();

  if (_uploadActive) {
    console.log('[upload] queuing', newEntries.length, 'files — upload already active');
    for (const e of newEntries) _uploadQueue.push({ file: e.file, remotePath: e.remotePath });
    return;
  }
  console.log('[upload] starting batch of', newEntries.length, 'files');

  _uploadActive = true;
  _uploadCompleted = 0;
  _uploadTotal = newEntries.length;

  for (const entry of newEntries) {
    // eslint-disable-next-line @typescript-eslint/no-unnecessary-condition -- mutated during await
    if (!_uploadActive) break; // cancelled
    const { file, remotePath, reqId } = entry;
    const name = file.name;
    _uploadCompleted++;
    const countStr = _uploadTotal > 1 ? ` (${String(_uploadCompleted)}/${String(_uploadTotal)})` : '';
    _setTransferStatus(`Uploading ${name} — 0 B / ${_formatBytes(file.size)}${countStr}`);

    _activeUploadRequestId = reqId;
    _uploadPending.set(reqId, remotePath);

    try {
      await uploadFileChunked(remotePath, file, reqId, (p) => {
        const pct = p.totalBytes > 0 ? Math.round(p.bytesSent / p.totalBytes * 100) : 0;
        _setTransferStatus(`Uploading ${name} — ${_formatBytes(p.bytesSent)} / ${_formatBytes(p.totalBytes)} (${String(pct)}%)${countStr}`);
        const rec = _transferRecords.get(reqId);
        if (rec) { rec.sent = p.bytesSent; _renderTransferList(); }
      });
      _uploadPending.delete(reqId);
      const rec = _transferRecords.get(reqId);
      if (rec) { rec.status = 'done'; rec.sent = rec.size; _renderTransferList(); }
    } catch (err) {
      _uploadPending.delete(reqId);
      const message = err instanceof Error ? err.message : String(err);
      const rec = _transferRecords.get(reqId);
      if (rec) { rec.status = 'failed'; rec.error = message; _renderTransferList(); }
      toast(`Upload failed: ${name}`);
      // Continue to next file instead of aborting the batch
      continue;
    }
  }

  _activeUploadRequestId = null;
  _uploadActive = false;
  _setTransferStatus('');
  const afs = _activeFilesState();
  afs.cache.delete(afs.path);
  _filesNavigateTo(afs.path);

  // Process queued uploads (files added while this batch was in progress)
  if (_uploadQueue.length > 0) {
    const queued = _uploadQueue.splice(0);
    const dt = new DataTransfer();
    for (const q of queued) dt.items.add(q.file);
    void _startUpload(dt.files);
  }
}

/** Request a file download for preview purposes. */
function _requestFilePreview(filePath: string): void {
  const filename = filePath.split('/').pop() ?? filePath;
  const reqId = `preview-${String(Date.now())}-${filename.slice(0, 8)}`;
  _downloadPending.set(reqId, filename);
  _previewPending.add(reqId);
  _transferRecords.set(reqId, { name: filename, size: 0, sent: 0, status: 'active', direction: 'download', startTime: Date.now() });
  _setTransferStatus('Loading preview...');
  _renderTransferList();
  sendSftpDownload(filePath, reqId);
}

/** Active preview panel cleanup handle. */
let _activePreviewCleanup: (() => void) | null = null;

/** Show a file preview in the filePreview container. */
function _showFilePreview(filename: string, data: Uint8Array): void {
  const containerEl = document.getElementById('filePreview');
  const exploreEl = document.getElementById('filesExplore');
  if (!containerEl || !exploreEl) return;
  // Local const bindings so closures see non-null types
  const container = containerEl;
  const explore = exploreEl;

  // Clean up any previous preview
  if (_activePreviewCleanup) {
    _activePreviewCleanup();
    _activePreviewCleanup = null;
  }

  const panel = createPreviewPanel(filename, data);

  // Build back button
  const backBtn = document.createElement('button');
  backBtn.className = 'preview-back-btn';
  backBtn.textContent = '\u2190 ' + filename;

  container.innerHTML = '';
  container.appendChild(backBtn);
  container.appendChild(panel);
  container.classList.remove('hidden');
  explore.classList.add('hidden');

  history.pushState({ type: 'preview' }, '');

  _activePreviewCleanup = (): void => { panel.cleanup(); };

  function closePreview(): void {
    panel.cleanup();
    _activePreviewCleanup = null;
    container.classList.add('hidden');
    container.innerHTML = '';
    explore.classList.remove('hidden');
    window.removeEventListener('popstate', onPopstate);
  }

  function onPopstate(): void {
    closePreview();
  }

  backBtn.addEventListener('click', () => {
    closePreview();
    history.back();
  });

  window.addEventListener('popstate', onPopstate);

  // Wire tab switching (event delegation on the panel)
  panel.addEventListener('click', (e) => {
    const tab = (e.target as HTMLElement).closest<HTMLElement>('.preview-tab');
    if (!tab) return;
    const target = tab.dataset.tab;
    panel.querySelectorAll('.preview-tab').forEach((t) => t.classList.toggle('active', t === tab));
    const srcView = panel.querySelector<HTMLElement>('.preview-source');
    const renView = panel.querySelector<HTMLElement>('.preview-rendered');
    if (target === 'source') {
      if (srcView) srcView.style.display = '';
      if (renView) renView.style.display = 'none';
    } else {
      if (srcView) srcView.style.display = 'none';
      if (renView) renView.style.display = '';
    }
  });
}

function _renderFilesPanel(path: string, bodyHtml: string): void {
  _dismissContextMenu();
  const panel = document.getElementById('filesExplore');
  if (!panel) return;

  const parts = path === '/' ? [] : path.split('/').slice(1);
  const rootCrumb = '<button class="files-crumb" data-path="/">/</button>';
  const partCrumbs = parts.map((seg, i) => {
    const segPath = '/' + parts.slice(0, i + 1).join('/');
    return `<span class="files-crumb-sep">/</span><button class="files-crumb" data-path="${escHtml(segPath)}">${escHtml(seg)}</button>`;
  }).join('');
  const breadcrumbHtml = rootCrumb + partCrumbs;
  const statusHidden = _transferStatus ? '' : ' hidden';

  panel.innerHTML = `
    <div class="files-breadcrumb">${breadcrumbHtml}</div>
    <div class="files-toolbar">
      <button class="files-upload-btn">Upload</button>
      <button class="files-download-btn hidden">Download</button>
      <input type="file" class="files-upload-input" multiple />
      <span class="files-transfer-status${statusHidden}">${escHtml(_transferStatus)}</span>
      <button class="files-upload-cancel${_uploadActive ? '' : ' hidden'}">Cancel</button>
    </div>
    <div class="files-body">${bodyHtml}</div>
  `;

  panel.querySelectorAll<HTMLElement>('.files-crumb').forEach((btn) => {
    btn.addEventListener('click', () => {
      const dest = btn.dataset.path;
      if (dest) _filesNavigateTo(dest);
    });
  });

  panel.querySelectorAll<HTMLElement>('.files-entry').forEach((row) => {
    row.addEventListener('contextmenu', (e) => { e.preventDefault(); });
    row.addEventListener('touchstart', (e) => {
      _pressTimer = setTimeout(() => {
        _pressTimer = null;
        _longPressFired = true;
        const touch = e.touches[0];
        const x = touch ? touch.clientX : 0;
        const y = touch ? touch.clientY : 0;
        _showContextMenu(x, y, row.dataset.path ?? '', row.dataset.dir === 'true');
      }, 500);
    });
    const cancelPress = (): void => { if (_pressTimer) { clearTimeout(_pressTimer); _pressTimer = null; } };
    row.addEventListener('touchend', cancelPress);
    row.addEventListener('touchmove', cancelPress);
    row.addEventListener('touchcancel', () => { cancelPress(); _longPressFired = false; });
  });

  panel.querySelectorAll<HTMLElement>('.files-entry[data-dir="true"]').forEach((row) => {
    row.addEventListener('click', () => {
      if (_longPressFired) { _longPressFired = false; return; }
      const dest = row.dataset.path;
      if (dest) _filesNavigateTo(dest);
    });
  });

  // Single tap on file: preview if previewable, otherwise toggle selection
  panel.querySelectorAll<HTMLElement>('.files-entry[data-dir="false"]').forEach((row) => {
    row.addEventListener('click', () => {
      if (_longPressFired) { _longPressFired = false; return; }
      const filePath = row.dataset.path ?? '';
      const filename = filePath.split('/').pop() ?? filePath;
      if (isPreviewable(filename)) {
        _requestFilePreview(filePath);
      } else {
        row.classList.toggle('files-selected');
        _updateFileSelectionToolbar(panel);
      }
    });
  });

  const uploadBtn = panel.querySelector<HTMLElement>('.files-upload-btn');
  const fileInput = panel.querySelector<HTMLInputElement>('.files-upload-input');
  uploadBtn?.addEventListener('click', () => { fileInput?.click(); });
  fileInput?.addEventListener('change', () => {
    if (fileInput.files?.length) {
      void _startUpload(fileInput.files);
      fileInput.value = '';
    }
  });
  const dlBtn = panel.querySelector<HTMLElement>('.files-download-btn');
  dlBtn?.addEventListener('click', () => { _downloadSelectedFiles(panel); });
  const cancelBtn = panel.querySelector<HTMLElement>('.files-upload-cancel');
  cancelBtn?.addEventListener('click', () => { _cancelActiveUpload(); });
}

function _filesNavigateTo(path: string, options?: { fromPopstate?: boolean }): void {
  const state = _activeFilesState();
  state.path = path;

  // Update URL hash for history (#90, #188)
  // Encode each path segment individually so '/' stays literal in the hash.
  if (!options?.fromPopstate) {
    const encodedPath = path.split('/').map(s => encodeURIComponent(s)).join('/');
    const newHash = '#files' + encodedPath;
    if (location.hash !== newHash) {
      history.pushState({ type: 'files', path }, '', newHash);
    }
  }

  const cached = state.cache.get(path);
  if (cached) {
    _renderFilesList(path, cached);
    return;
  }
  _renderFilesPanel(path, '<div class="files-loading">Loading...</div>');
  const reqId = `ls-${String(Date.now())}`;
  _filesPending.set(reqId, path);
  _tagReq(reqId);
  sendSftpLs(path, reqId);
}

function _renderFilesList(path: string, entries: SftpEntry[]): void {
  if (entries.length === 0) {
    _renderFilesPanel(path, '<div class="files-empty">Directory is empty</div>');
    return;
  }

  const sorted = [...entries].sort((a, b) => {
    if (a.isDir !== b.isDir) return a.isDir ? -1 : 1;
    return a.name.localeCompare(b.name);
  });

  const rows = sorted.map((e) => {
    const fullPath = path === '/' ? `/${e.name}` : `${path}/${e.name}`;
    const sizeStr = e.isDir ? '' : _formatSize(e.size);
    const dateStr = _formatDate(e.mtime);
    return `<div class="files-entry" data-dir="${String(e.isDir)}" data-path="${escHtml(fullPath)}">
      <span class="files-entry-icon">${e.isDir ? 'D' : 'F'}</span>
      <span class="files-entry-name">${escHtml(e.name)}</span>
      ${sizeStr ? `<span class="files-entry-size">${escHtml(sizeStr)}</span>` : ''}
      ${dateStr ? `<span class="files-entry-date">${escHtml(dateStr)}</span>` : ''}
    </div>`;
  }).join('');

  _renderFilesPanel(path, `<div class="files-list">${rows}</div>`);

  // Pre-cache visible subdirectories (up to 5)
  const dirs = sorted.filter((e) => e.isDir).slice(0, 5);
  const state = _activeFilesState();
  for (const dir of dirs) {
    const dirPath = path === '/' ? `/${dir.name}` : `${path}/${dir.name}`;
    if (!state.cache.has(dirPath)) {
      const preReqId = `pre-${String(Date.now())}-${dir.name}`;
      _filesPending.set(preReqId, dirPath);
      _tagReq(preReqId);
      sendSftpLs(dirPath, preReqId);
    }
  }
}

function _formatSize(bytes: number): string {
  if (bytes < 1024) return `${String(bytes)}B`;
  if (bytes < 1024 * 1024) return `${String(Math.round(bytes / 1024))}K`;
  return `${String(Math.round(bytes / (1024 * 1024)))}M`;
}

function _formatDate(mtime: string): string {
  const ts = Number(mtime);
  const d = isNaN(ts) ? new Date(mtime) : new Date(ts * 1000);
  if (isNaN(d.getTime())) return '';
  const now = new Date();
  if (d.getFullYear() === now.getFullYear()) {
    return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
  }
  return d.toISOString().slice(0, 10);
}

function _formatDateFull(ts: string): string {
  const n = Number(ts);
  const d = isNaN(n) ? new Date(ts) : new Date(n * 1000);
  if (isNaN(d.getTime())) return ts;
  return d.toLocaleString('en-US', { year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

function _formatPermissions(mode: number): string {
  const perms = mode & 0o7777;
  const octal = perms.toString(8).padStart(4, '0');
  const bits = ['---', '--x', '-w-', '-wx', 'r--', 'r-x', 'rw-', 'rwx'] as const;
  const rwx = [bits[(mode >> 6) & 7] ?? '---', bits[(mode >> 3) & 7] ?? '---', bits[mode & 7] ?? '---'].join('');
  const fmt = (mode & 0o170000) === 0o040000 ? 'd' : (mode & 0o170000) === 0o120000 ? 'l' : '-';
  return `${fmt}${rwx} (${octal})`;
}

function _showDetailsPanel(entry: SftpEntry, path: string): void {
  const overlay = document.createElement('div');
  overlay.className = 'files-detail-overlay';

  const sheet = document.createElement('div');
  sheet.className = 'files-detail-sheet';

  let typeLabel = entry.isDir ? 'Directory' : 'File';
  if (entry.isSymlink) typeLabel = 'Symlink';

  const rows: [string, string][] = [
    ['Name', entry.name],
    ['Path', path],
    ['Type', typeLabel],
  ];
  if (!entry.isDir) rows.push(['Size', `${_formatSize(entry.size)} (${String(entry.size)} bytes)`]);
  if (entry.permissions !== undefined) rows.push(['Permissions', _formatPermissions(entry.permissions)]);
  if (entry.uid !== undefined) rows.push(['Owner', `UID ${String(entry.uid)}`]);
  if (entry.gid !== undefined) rows.push(['Group', `GID ${String(entry.gid)}`]);
  rows.push(['Modified', entry.mtime ? _formatDateFull(entry.mtime) : '—']);
  if (entry.atime) rows.push(['Accessed', _formatDateFull(entry.atime)]);

  const tableRows = rows.map(([label, val]) =>
    `<tr><td>${escHtml(label)}</td><td>${escHtml(val)}</td></tr>`
  ).join('');

  sheet.innerHTML = `
    <div class="files-detail-title">${escHtml(entry.name)}</div>
    <table class="files-detail-table"><tbody>${tableRows}</tbody></table>
    <button class="files-detail-close">Close</button>
  `;

  document.body.appendChild(overlay);
  document.body.appendChild(sheet);
  history.pushState({ detailSheet: true }, '');

  let dismissed = false;
  function dismiss(): void {
    if (dismissed) return;
    dismissed = true;
    overlay.remove();
    sheet.remove();
    window.removeEventListener('popstate', onPopstate);
  }

  function onPopstate(): void {
    dismiss();
  }

  overlay.addEventListener('click', () => { dismiss(); history.back(); });
  sheet.querySelector('.files-detail-close')!.addEventListener('click', () => { dismiss(); history.back(); });
  window.addEventListener('popstate', onPopstate);
}

function _dismissContextMenu(): void {
  _ctxMenuDismiss?.();
  _ctxMenuDismiss = null;
}

function _showContextMenu(touchX: number, touchY: number, path: string, isDir: boolean): void {
  _dismissContextMenu();

  const overlay = document.createElement('div');
  overlay.id = 'filesCtxOverlay';
  overlay.className = 'ctx-overlay';

  const menu = document.createElement('div');
  menu.id = 'filesCtxMenu';
  menu.className = 'ctx-menu';

  const filename = path.split('/').pop() ?? path;
  const fileActions = isPreviewable(filename)
    ? ['preview', 'download', 'rename', 'delete', 'details', 'copy-path']
    : ['download', 'rename', 'delete', 'details', 'copy-path'];
  const actions = isDir
    ? ['rename', 'delete', 'details', 'copy-path']
    : fileActions;
  const labels: Record<string, string> = {
    preview: 'Preview', download: 'Download', rename: 'Rename', delete: 'Delete',
    details: 'Details', 'copy-path': 'Copy Path',
  };
  menu.innerHTML = actions.map(a => `<button class="ctx-menu-item" data-action="${a}">${labels[a]!}</button>`).join('');

  const vw = window.innerWidth;
  const vh = window.innerHeight;
  const menuH = actions.length * 44;
  const left = Math.max(8, Math.min(touchX, vw - 168));
  const top = Math.max(8, Math.min(touchY, vh - menuH - 8));
  menu.style.setProperty('--ctx-x', `${String(left)}px`);
  menu.style.setProperty('--ctx-y', `${String(top)}px`);

  document.body.appendChild(overlay);
  document.body.appendChild(menu);
  history.pushState({ ctxMenu: true }, '');

  let dismissed = false;
  function dismiss(): void {
    if (dismissed) return;
    dismissed = true;
    overlay.remove();
    menu.remove();
    window.removeEventListener('popstate', onPopstate);
    _ctxMenuDismiss = null;
  }

  function onPopstate(): void {
    dismiss();
  }

  _ctxMenuDismiss = dismiss;
  overlay.addEventListener('click', () => { dismiss(); history.back(); });
  window.addEventListener('popstate', onPopstate);

  menu.addEventListener('click', (e) => {
    const btn = (e.target as HTMLElement).closest<HTMLElement>('[data-action]');
    if (!btn) return;
    const action = btn.dataset.action ?? '';
    dismiss();
    history.back();
    switch (action) {
      case 'preview': {
        _requestFilePreview(path);
        break;
      }
      case 'download': {
        const filename = path.split('/').pop() ?? path;
        _setTransferStatus('Downloading...');
        const reqId = `dl-${String(Date.now())}`;
        _downloadPending.set(reqId, filename);
        _transferRecords.set(reqId, { name: filename, size: 0, sent: 0, status: 'active', direction: 'download', startTime: Date.now() });
        _renderTransferList();
        sendSftpDownload(path, reqId);
        break;
      }
      case 'rename': {
        const current = path.split('/').pop() ?? path;
        const newName = prompt(`Rename "${current}" to:`, current);
        if (!newName || newName === current) return;
        const dir = path.slice(0, path.lastIndexOf('/')) || '/';
        const newPath = dir === '/' ? `/${newName}` : `${dir}/${newName}`;
        const reqId = `ren-${String(Date.now())}`;
        _renamePending.set(reqId, dir);
        _tagReq(reqId);
        sendSftpRename(path, newPath, reqId);
        break;
      }
      case 'delete': {
        const name = path.split('/').pop() ?? path;
        if (!confirm(`Delete "${name}"?`)) return;
        const reqId = `del-${String(Date.now())}`;
        _deletePending.set(reqId, _activeFilesState().path);
        _tagReq(reqId);
        sendSftpDelete(path, reqId);
        break;
      }
      case 'details': {
        const name = path.split('/').pop() ?? path;
        const entries = _activeFilesState().cache.get(_activeFilesState().path) ?? [];
        const entry = entries.find(e => e.name === name);
        if (entry) {
          _showDetailsPanel(entry, path);
        } else {
          toast(path);
        }
        break;
      }
      case 'copy-path':
        void navigator.clipboard.writeText(path).then(() => { toast('Path copied'); });
        break;
    }
  });
}

export function initFilesPanel(): void {
  setSftpHandler((msg) => {
    if (msg.type === 'sftp_ls_result') {
      const path = _filesPending.get(msg.requestId);
      _filesPending.delete(msg.requestId);
      const targetState = _stateForReq(msg.requestId);
      _filesReqToSession.delete(msg.requestId);
      if (path && targetState) targetState.cache.set(path, msg.entries);
      // Only render if this response matches the currently-active session's current path
      const active = _activeFilesState();
      if (path === active.path && targetState === active) _renderFilesList(path, msg.entries);
    } else if (msg.type === 'sftp_download_result') {
      const filename = _downloadPending.get(msg.requestId);
      _downloadPending.delete(msg.requestId);
      _setTransferStatus('');
      if (filename && msg.data && _previewPending.has(msg.requestId)) {
        _previewPending.delete(msg.requestId);
        const binary = atob(msg.data);
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)!;
        _showFilePreview(filename, bytes);
      } else if (filename && msg.data) {
        _triggerBlobDownload(filename, msg.data);
      }
      const dlRec = _transferRecords.get(msg.requestId);
      if (dlRec) { dlRec.status = 'done'; _renderTransferList(); }
    } else if (msg.type === 'sftp_upload_result') {
      _uploadPending.delete(msg.requestId);
      if (!msg.ok) {
        _uploadActive = false;
        _activeUploadRequestId = null;
        _setTransferStatus('');
        toast('Upload failed');
      }
    } else if (msg.type === 'sftp_rename_result') {
      const dir = _renamePending.get(msg.requestId);
      _renamePending.delete(msg.requestId);
      const tState = _stateForReq(msg.requestId);
      _filesReqToSession.delete(msg.requestId);
      if (msg.ok && dir !== undefined && tState) {
        tState.cache.delete(dir);
        const active = _activeFilesState();
        if (dir === active.path && tState === active) _filesNavigateTo(dir);
      }
    } else if (msg.type === 'sftp_delete_result') {
      const dir = _deletePending.get(msg.requestId);
      _deletePending.delete(msg.requestId);
      const tState = _stateForReq(msg.requestId);
      _filesReqToSession.delete(msg.requestId);
      if (msg.ok && dir !== undefined && tState) {
        tState.cache.delete(dir);
        const active = _activeFilesState();
        if (dir === active.path && tState === active) _filesNavigateTo(dir);
      }
    } else if (msg.type === 'sftp_realpath_result') {
      const tState = _stateForReq(msg.requestId);
      if (tState && msg.requestId === tState.realpathReqId) {
        tState.realpathReqId = null;
        _filesReqToSession.delete(msg.requestId);
        tState.firstActivated = true;
        // Deep link path takes priority over home dir (#90)
        if (tState.deepLinkPath) {
          const deepPath = tState.deepLinkPath;
          tState.deepLinkPath = null;
          // Only navigate if this session is still the active one
          if (tState === _activeFilesState()) _filesNavigateTo(deepPath);
          else tState.path = deepPath;
        } else {
          const resolvedPath = msg.path || '/';
          if (tState === _activeFilesState()) _filesNavigateTo(resolvedPath);
          else tState.path = resolvedPath;
        }
      }
    } else if (msg.type === 'sftp_error') {
      // sftp_error — could be for ls, download, upload, rename, or delete
      if (_filesPending.has(msg.requestId)) {
        const path = _filesPending.get(msg.requestId);
        _filesPending.delete(msg.requestId);
        const tState = _stateForReq(msg.requestId);
        _filesReqToSession.delete(msg.requestId);
        const active = _activeFilesState();
        if (path === active.path && tState === active) {
          _renderFilesPanel(active.path, `<div class="files-error">${escHtml(msg.message)}</div>`);
        }
      } else if (_downloadPending.has(msg.requestId)) {
        _downloadPending.delete(msg.requestId);
        _setTransferStatus('');
        const dlErrRec = _transferRecords.get(msg.requestId);
        if (dlErrRec) { dlErrRec.status = 'failed'; dlErrRec.error = msg.message; _renderTransferList(); }
        toast(`Download failed: ${msg.message}`);
      } else if (_uploadPending.has(msg.requestId)) {
        _uploadPending.delete(msg.requestId);
        _uploadActive = false;
        _activeUploadRequestId = null;
        _setTransferStatus('');
        toast(`Upload failed: ${msg.message}`);
      } else if (_renamePending.has(msg.requestId)) {
        _renamePending.delete(msg.requestId);
        _filesReqToSession.delete(msg.requestId);
        toast(`Rename failed: ${msg.message}`);
      } else if (_deletePending.has(msg.requestId)) {
        _deletePending.delete(msg.requestId);
        _filesReqToSession.delete(msg.requestId);
        toast(`Delete failed: ${msg.message}`);
      } else {
        // Possibly a realpath error for some session
        const tState = _stateForReq(msg.requestId);
        if (tState && msg.requestId === tState.realpathReqId) {
          tState.realpathReqId = null;
          _filesReqToSession.delete(msg.requestId);
          if (tState === _activeFilesState()) _filesNavigateTo('/');
        }
      }
    }
  });

  // Sub-tab switching
  document.querySelectorAll<HTMLElement>('.files-subtab').forEach((btn) => {
    btn.addEventListener('click', () => {
      const target = btn.dataset.subtab;
      if (!target) return;
      document.querySelectorAll<HTMLElement>('.files-subtab').forEach((b) => b.classList.toggle('active', b === btn));
      const explore = document.getElementById('filesExplore');
      const transfer = document.getElementById('filesTransfer');
      if (target === 'explore') {
        explore?.classList.remove('hidden');
        explore?.classList.add('active');
        transfer?.classList.add('hidden');
        transfer?.classList.remove('active');
      } else {
        transfer?.classList.remove('hidden');
        transfer?.classList.add('active');
        explore?.classList.add('hidden');
        explore?.classList.remove('active');
        _renderTransferList();
      }
    });
  });

  // Transfer tab upload button
  document.getElementById('transferUploadBtn')?.addEventListener('click', () => {
    const fileInput = document.querySelector<HTMLInputElement>('#filesExplore .files-upload-input');
    fileInput?.click();
  });

  // Session menu: Files entry — opens the files panel for the active session (#409)
  document.getElementById('sessionFilesBtn')?.addEventListener('click', () => {
    document.getElementById('sessionMenu')?.classList.add('hidden');
    document.getElementById('menuBackdrop')?.classList.add('hidden');
    navigateToPanel('files');
  });

  // Session menu: Notifications entry — opens the review modal (#458)
  document.getElementById('sessionNotifBtn')?.addEventListener('click', () => {
    document.getElementById('sessionMenu')?.classList.add('hidden');
    document.getElementById('menuBackdrop')?.classList.add('hidden');
    showNotifModal();
  });

  document.getElementById('notifCloseBtn')?.addEventListener('click', () => {
    document.getElementById('notifModal')?.classList.add('hidden');
  });

  document.getElementById('notifClearAllModal')?.addEventListener('click', () => {
    clearNotifications();
    document.getElementById('notifModal')?.classList.add('hidden');
  });

  // Dismiss modal on backdrop click (but not when clicking modal content)
  document.getElementById('notifModal')?.addEventListener('click', (e) => {
    if (e.target === e.currentTarget) {
      (e.currentTarget as HTMLElement).classList.add('hidden');
    }
  });

  // Back-to-terminal button removed with the persistent session bar (#452).
  // The ≡ session menu in the handle strip is always reachable.
}

/** Resolve and render the files panel for the currently active session,
 *  issuing an sftp_realpath on first activation for that session (#409). */
function _activateFilesForCurrentSession(): void {
  const state = _activeFilesState();
  if (!state.firstActivated && state.realpathReqId === null) {
    const reqId = `rp-${String(Date.now())}`;
    state.realpathReqId = reqId;
    _tagReq(reqId);
    sendSftpRealpath(reqId);
    _renderFilesPanel(state.path, '<div class="files-loading">Loading...</div>');
  } else {
    // Session already activated — render its current path (from cache if available)
    const cached = state.cache.get(state.path);
    if (cached) _renderFilesList(state.path, cached);
    else _renderFilesPanel(state.path, '<div class="files-loading">Loading...</div>');
  }
}
