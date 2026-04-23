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
import { showSettingsOverview, showSettingsSection } from './settings.js';
// eslint-disable-next-line @typescript-eslint/no-unused-vars -- backward compat: sendSftpUpload kept for legacy callers
import { sendSSHInput, sendSSHInputToAll, disconnect, reconnect, probeSession, cancelReconnect, sendSftpLs, setSftpHandler, sendSftpDownload, sendSftpDownloadStart, sendSftpUpload, sendSftpRename, sendSftpDelete, sendSftpRealpath, uploadFileChunked, sendSftpUploadCancel, getSessionHandle, removeSessionHandle } from './connection.js';
import { saveProfile, connectFromProfile, newConnection, loadProfiles, removeRecentSession, getRecentSessions, downloadProfilesExport, triggerProfileImport, profileColor } from './profiles.js';
import { clearIMEPreview, restoreIMEOverlay } from './ime.js';
import { isPreviewable, createPreviewPanel, MIME_MAP, extOf, SFTP_INLINE_IMG_ATTR, SFTP_RELATIVE_LINK_ATTR } from './sftp-preview.js';
import { listFavorites, toggleFavorite, isFavorited, profileIdOf } from './favorites.js';
import type { Favorite } from './types.js';

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
    return '<div class="notif-modal-item">'
      + `<div class="notif-modal-item-time">${escHtml(age)}</div>`
      + `<div class="notif-modal-item-message">${escHtml(n.message)}</div>`
      + '</div>';
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
  if (raw.startsWith('settings/') || raw === 'settings') return 'settings';
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

function _settingsSectionFromHash(): string | null {
  const raw = location.hash.replace(/^#/, '');
  if (!raw.startsWith('settings/')) return null;
  const section = raw.slice('settings/'.length);
  return section || null;
}

export function navigateToPanel(
  panel: PanelName,
  options?: { pushHistory?: boolean; updateHash?: boolean },
): void {
  const pushHistory = options?.pushHistory ?? false;
  const updateHash = options?.updateHash ?? true;

  // Capture whether the target panel was already active BEFORE the re-render
  // pass below strips .active. A true panel CHANGE warrants side effects like
  // focusIME; a re-entry (e.g. popstate after selection dismiss) should not.
  const panelAlreadyActive = document.getElementById(`panel-${panel}`)?.classList.contains('active') ?? false;

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

  // Per-session panel memory (#468): each session remembers which panel it was in.
  if (panel === 'terminal' || panel === 'files') {
    const s = currentSession();
    if (s) s.activePanel = panel;
  }

  // Theme is a pure function of (panel, active session):
  //   session-bound panel + active session → session's theme
  //   otherwise → default theme from localStorage
  // Previously `switchSession` alone drove theme changes, so navigating to
  // Connect/Settings left the session's theme painted on app chrome.
  const sessionBoundPanel = panel === 'terminal' || panel === 'files';
  const themeSession = sessionBoundPanel ? currentSession() : null;
  const targetTheme = themeSession?.activeThemeName
    ?? localStorage.getItem('termTheme')
    ?? 'dark';
  if (appState.activeThemeName !== targetTheme) {
    applyTheme(targetTheme);
  }

  if (panel === 'terminal') {
    // Panel just became visible — fit the active session to real dimensions
    const s = currentSession();
    const handle = s ? getSessionHandle(s.id) : undefined;
    if (handle) {
      handle.fit();
    }
    // Only re-focus the IME when the terminal panel actually became active.
    // Skipping on re-entry prevents popstate artifacts (e.g. selection-dismiss
    // history.back()) from surprise-popping the keyboard.
    if (!panelAlreadyActive) {
      focusIME();
      restoreIMEOverlay();
    }
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
  if (panel === 'settings') {
    // Sync overview/detail to hash on every (re-)entry so tab-bar navigation
    // and deep links both land on the right subview.
    const section = _settingsSectionFromHash();
    if (section) showSettingsSection(section);
    else showSettingsOverview();
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

/** Apply a session's theme to `:root` only if the currently-visible panel
 *  paints with session scope (terminal/files). Non-session views (connect,
 *  settings) should keep the default theme even when a background session
 *  connects or the user swipes among sessions. */
export function applySessionThemeIfVisible(session: { activeThemeName: ThemeName }): void {
  const panelTerminal = document.getElementById('panel-terminal');
  const panelFiles = document.getElementById('panel-files');
  const sessionBoundVisible = (panelTerminal?.classList.contains('active') ?? false)
    || (panelFiles?.classList.contains('active') ?? false);
  // #panel-terminal is kept structurally active under the Files overlay
  // (#452); here we want the actual user-facing panel. When Settings or
  // Connect is the active panel, neither session-bound panel will have it.
  const panelConnect = document.getElementById('panel-connect');
  const panelSettings = document.getElementById('panel-settings');
  const nonSessionVisible = (panelConnect?.classList.contains('active') ?? false)
    || (panelSettings?.classList.contains('active') ?? false);
  if (nonSessionVisible || !sessionBoundVisible) return;
  if (appState.activeThemeName !== session.activeThemeName) {
    applyTheme(session.activeThemeName);
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
    // Settings deep link: land on the specified detail section (#473 follow-up)
    if (fromHash === 'settings') {
      const section = _settingsSectionFromHash();
      if (section) showSettingsSection(section);
    }
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
    // Preserve the active session's title even when disconnected — losing
    // the title loses context of what session you were in. Only fall back
    // to "MobiSSH" if there is no active session at all.
    const active = appState.activeSessionId ? appState.sessions.get(appState.activeSessionId) : null;
    if (!active?.profile) {
      _setMenuBtnText('MobiSSH');
    }
  }
  const btn = document.getElementById('sessionMenuBtn');
  if (btn) btn.classList.toggle('connected', state === 'connected');

  // Drive the separator-bar status indicator via body data-attribute
  const active = appState.activeSessionId ? appState.sessions.get(appState.activeSessionId) : null;
  const stateAttr = active ? active.state : '';
  document.body.dataset.sessionState = stateAttr;

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
    // Profile color replaces the generic connected-green dot. State still
    // drives opacity/pulse via CSS classes; the hue identifies which profile.
    const color = s.profile ? profileColor(s.profile) : 'var(--accent)';
    return `<div class="session-item${activeClass}" data-session-id="${escHtml(s.id)}" data-state="${s.state}" role="menuitem" style="--profile-color:${escHtml(color)}">
      <span class="session-item-dot ${stateClass}${dotClass}" style="background:${escHtml(color)}" aria-hidden="true"></span>
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

  // Restore the session's last-active panel (#468). Without this, the files
  // overlay and panel state from the previous session leaks across the swipe.
  const targetPanel = session.activePanel;
  const bodyInFiles = document.body.classList.contains('files-overlay');
  if (targetPanel === 'files' && !bodyInFiles) {
    navigateToPanel('files', { updateHash: false });
  } else if (targetPanel === 'terminal' && bodyInFiles) {
    navigateToPanel('terminal', { updateHash: false });
  } else if (targetPanel === 'files' && bodyInFiles) {
    // Still in files, but the active session changed — re-render its files state.
    _activateFilesForCurrentSession();
  }

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

  // Apply the session's theme only if the user is actually looking at a
  // session-bound view. If they're in Settings/Connect, the default theme
  // should stick — background session activity (reconnect, approval events)
  // shouldn't repaint app chrome.
  applySessionThemeIfVisible(session);

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
  // Drive the separator-bar status indicator
  document.body.dataset.sessionState = session.state;

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
      document.body.dataset.sessionState = '';
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
      // Drive the separator-bar status indicator for the active session
      document.body.dataset.sessionState = newState;
    }
    // On the transition INTO 'connected', dismiss any stale "Host unreachable"
    // dialog. Gating on the transition avoids a DOM write on every state change.
    if (newState === 'connected' && _oldState !== 'connected') {
      document.getElementById('errorDialogOverlay')?.classList.add('hidden');
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

  // Flag set by swipe touchend to suppress the synthesized click that follows
  // (prevents menu from opening when user swipes to switch sessions).
  let _suppressNextClick = false;

  menuBtn.addEventListener('click', (e) => {
    if (_suppressNextClick) {
      _suppressNextClick = false;
      e.stopPropagation();
      e.preventDefault();
      return;
    }
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
      // Session-switch list is at the bottom of the menu (thumb-reach). Scroll
      // to it on open so the user doesn't have to scroll down to switch.
      menu.scrollTop = menu.scrollHeight;
    }
  });

  function closeMenu(): void {
    menu.classList.add('hidden');
    document.getElementById('navMenu')?.classList.add('hidden');
    backdrop.classList.add('hidden');
  }

  // ── Swipe left/right on session title to switch sessions ──────────────
  let _swipeX0: number | null = null;
  let _swipeClaimed = false;

  menuBtn.addEventListener('touchstart', (e) => {
    if (appState.sessions.size <= 1) return;
    _swipeX0 = e.touches[0]!.clientX;
    _swipeClaimed = false;
  }, { passive: true });

  menuBtn.addEventListener('touchmove', (e) => {
    if (_swipeX0 === null) return;
    const dx = e.touches[0]!.clientX - _swipeX0;
    if (!_swipeClaimed && Math.abs(dx) > 30) {
      _swipeClaimed = true;
      e.preventDefault();
      // Optimistic preview (peek) was removed — it was causing confusion where
      // the first swipe appeared to preview but not commit. Touchend now does
      // the work; visual feedback via opacity only.
      menuBtn.style.opacity = '0.6';
    }
  }, { passive: false });

  menuBtn.addEventListener('touchend', (e) => {
    if (!_swipeClaimed) { _swipeX0 = null; return; }
    // Swipe was claimed — suppress the click that will follow so the menu doesn't open
    _suppressNextClick = true;
    const dx = (e.changedTouches[0]?.clientX ?? _swipeX0 ?? 0) - (_swipeX0 ?? 0);
    _swipeX0 = null;
    _swipeClaimed = false;
    menuBtn.style.opacity = '';

    const keys = Array.from(appState.sessions.keys());
    const idx = keys.indexOf(appState.activeSessionId ?? '');
    const targetIdx = (idx + (dx > 0 ? -1 : 1) + keys.length) % keys.length;
    switchSession(keys[targetIdx]!);
    if ('vibrate' in navigator) navigator.vibrate(10);
  });

  // Hamburger ≡ button — opens the top-level nav menu (Terminal/Connect/Settings).
  // Session-specific controls live on the MobiSSH button (#sessionMenuBtn).
  const navMenu = document.getElementById('navMenu');
  document.getElementById('handleMenuBtn')!.addEventListener('click', (e) => {
    e.stopPropagation();
    if (!navMenu) return;
    // Close session menu if open
    menu.classList.add('hidden');
    const wasHidden = navMenu.classList.toggle('hidden');
    backdrop.classList.toggle('hidden', wasHidden);
    if (!wasHidden) {
      const hb = document.getElementById('key-bar-handle');
      if (hb) {
        const handleTop = hb.getBoundingClientRect().top;
        navMenu.style.bottom = `${String(window.innerHeight - handleTop + 4)}px`;
      }
    }
  });

  // Wire nav menu items
  document.querySelectorAll<HTMLElement>('#navMenu .nav-menu-item').forEach((btn) => {
    btn.addEventListener('click', () => {
      const panel = btn.dataset.panel as 'terminal' | 'connect' | 'settings' | undefined;
      navMenu?.classList.add('hidden');
      backdrop.classList.add('hidden');
      if (panel) navigateToPanel(panel, { pushHistory: true });
    });
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
      } else if (panel === 'settings') {
        // Back from a detail lands on #settings (no section) → show overview.
        // Deep-link forward to #settings/<x> → show that section.
        const section = _settingsSectionFromHash();
        if (section) showSettingsSection(section);
        else showSettingsOverview();
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
    } else if (action === 'remove-recent') {
      const host = target.dataset.host ?? '';
      const port = parseInt(target.dataset.port ?? '22', 10);
      const username = target.dataset.username ?? '';
      if (host && username) {
        removeRecentSession(host, port, username);
        loadProfiles();
      }
    } else if (action === 'reconnect-all-recent') {
      target.textContent = 'Connecting…';
      target.classList.add('connecting');
      const recent = getRecentSessions();
      // Parallel with allSettled: one blocking/failing host must not block others (#478).
      // The earlier `for await` loop stalled the whole queue if any single host stuck on
      // a vault prompt, passphrase prompt, or any other await inside connectFromProfile.
      const attempts = recent.map((entry) => connectFromProfile(entry.profileIdx));
      void Promise.allSettled(attempts).then((results) => {
        loadProfiles();
        const started = results.filter((r) => r.status === 'fulfilled' && r.value).length;
        const skipped = results.length - started;
        if (started > 0 && skipped === 0) toast(`${String(started)} session(s) reconnecting`);
        else if (started > 0) toast(`${String(started)} reconnecting, ${String(skipped)} skipped`);
        else toast('No sessions reconnected');
      });
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
// reqId -> full remote path for preview downloads. Presence = preview; absence = browser-save download.
const _previewPathPending = new Map<string, string>();
// Pending inline image fetches for markdown <img data-sftp-src>; reqId -> <img>
const _inlineImagePending = new Map<string, HTMLImageElement>();
// Chunk buffer for streaming sftp_download_start transfers. reqId -> accumulated
// Uint8Array pieces; assembled into a single blob on sftp_download_end (#474).
const _downloadChunks = new Map<string, Uint8Array[]>();
// Blob URLs created for the currently-mounted preview's inline images (revoked on close).
let _activeInlineImageBlobs: string[] = [];
const _INLINE_IMG_TIMEOUT_MS = 15_000;
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
  /** Full remote path — used to overlay progress on the matching file-explorer row. */
  path: string;
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
  _updateFilesEntryProgress();
}

const _PROGRESS_CIRCUMFERENCE = 2 * Math.PI * 8; // r=8

/** Overlay a circular progress indicator + rate on each file-explorer row whose
 *  full path matches an active transfer. Remove overlay rows that have finished. */
function _updateFilesEntryProgress(): void {
  const explore = document.getElementById('filesExplore');
  if (!explore) return;

  const activeByPath = new Map<string, TransferRecord>();
  _transferRecords.forEach((rec) => {
    if (rec.status === 'active') activeByPath.set(rec.path, rec);
  });

  explore.querySelectorAll<HTMLElement>('.files-entry').forEach((row) => {
    const path = row.dataset.path ?? '';
    const rec = activeByPath.get(path);
    const existing = row.querySelector<HTMLElement>('.files-entry-progress');

    if (!rec) {
      // No active transfer for this row — strip any stale overlay.
      if (existing) {
        const icon = document.createElement('span');
        icon.className = 'files-entry-icon';
        icon.textContent = row.dataset.dir === 'true' ? 'D' : 'F';
        existing.replaceWith(icon);
      }
      row.querySelector<HTMLElement>('.files-entry-rate')?.remove();
      return;
    }

    // Ensure progress overlay exists in place of the icon.
    let progress = existing;
    if (!progress) {
      progress = document.createElement('span');
      progress.className = 'files-entry-progress';
      progress.innerHTML = '<svg viewBox="0 0 20 20" class="files-progress-svg" aria-hidden="true">'
        + '<circle class="files-progress-track" cx="10" cy="10" r="8" fill="none"></circle>'
        + '<circle class="files-progress-fill" cx="10" cy="10" r="8" fill="none" transform="rotate(-90 10 10)"></circle>'
        + '</svg>';
      row.querySelector('.files-entry-icon')?.replaceWith(progress);
    }
    const pct = rec.size > 0 ? rec.sent / rec.size : 0;
    const fill = progress.querySelector<SVGCircleElement>('.files-progress-fill');
    if (fill) {
      fill.style.strokeDasharray = String(_PROGRESS_CIRCUMFERENCE);
      fill.style.strokeDashoffset = String(_PROGRESS_CIRCUMFERENCE * (1 - pct));
    }

    // Rate label (appended; replaces nothing else).
    const elapsed = (Date.now() - rec.startTime) / 1000;
    const rate = elapsed > 0 ? rec.sent / elapsed : 0;
    let rateEl = row.querySelector<HTMLElement>('.files-entry-rate');
    if (!rateEl) {
      rateEl = document.createElement('span');
      rateEl.className = 'files-entry-rate';
      row.appendChild(rateEl);
    }
    rateEl.textContent = `${_formatBytes(rate)}/s`;
  });
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
    _transferRecords.set(reqId, { name: filename, path: filePath, size: 0, sent: 0, status: 'active', direction: 'download', startTime: Date.now() });
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
    _transferRecords.set(reqId, { name: file.name, path: remotePath, size: file.size, sent: 0, status: 'active', direction: 'upload', startTime: Date.now() });
    newEntries.push({ file, remotePath, reqId });
  }
  _renderTransferList();
  // Re-render the current file list so ghost upload rows show immediately.
  {
    const state = _activeFilesState();
    const cached = state.cache.get(state.path);
    if (cached) _renderFilesList(state.path, cached);
  }

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
  _previewPathPending.set(reqId, filePath);
  _transferRecords.set(reqId, { name: filename, path: filePath, size: 0, sent: 0, status: 'active', direction: 'download', startTime: Date.now() });
  _downloadChunks.set(reqId, []);
  _setTransferStatus('Loading preview...');
  _renderTransferList();
  sendSftpDownloadStart(filePath, reqId);
}

/** Decode base64 (from the SFTP bridge) to Uint8Array. */
function _b64ToBytes(b64: string): Uint8Array {
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)!;
  return bytes;
}

/** Resolve a relative path against a base file path (the currently-previewing file).
 *  Supports `./`, `../`, bare relative (`foo/bar`), and absolute (`/path`). */
function _resolveRelativePath(baseFilePath: string, relative: string): string {
  if (relative.startsWith('/')) return relative;
  const baseDir = baseFilePath.includes('/')
    ? baseFilePath.slice(0, baseFilePath.lastIndexOf('/'))
    : '';
  const parts = (baseDir ? baseDir.split('/') : []).filter(Boolean);
  for (const seg of relative.split('/')) {
    if (seg === '' || seg === '.') continue;
    if (seg === '..') { parts.pop(); continue; }
    parts.push(seg);
  }
  return '/' + parts.join('/');
}

/** Path of the file currently shown in the preview panel — for resolving relative links. */
let _activePreviewPath: string | null = null;

/** Replace an unloadable inline image with a visible placeholder. `<img>` is a
 *  replaced element so CSS ::after can't show the alt text — swap the tag instead. */
function _markInlineImgFailed(img: HTMLImageElement): void {
  const placeholder = document.createElement('span');
  placeholder.className = 'sftp-inline-img-failed';
  placeholder.textContent = `${img.alt || 'image'} (unavailable)`;
  img.replaceWith(placeholder);
}

/** Kick off SFTP downloads for each inline image in the preview panel.
 *  Each request has a timeout so the <img> doesn't sit blank forever if the bridge stalls. */
let _inlineImgCounter = 0;
function _fetchInlineImages(panel: HTMLElement, basePath: string): void {
  const imgs = panel.querySelectorAll<HTMLImageElement>(`img[${SFTP_INLINE_IMG_ATTR}]`);
  imgs.forEach((img) => {
    const rel = img.dataset.sftpSrc ?? '';
    if (!rel) return;
    const resolved = _resolveRelativePath(basePath, rel);
    _inlineImgCounter++;
    const reqId = `inline-img-${String(_inlineImgCounter)}`;
    _inlineImagePending.set(reqId, img);
    setTimeout(() => {
      if (_inlineImagePending.delete(reqId)) _markInlineImgFailed(img);
    }, _INLINE_IMG_TIMEOUT_MS);
    sendSftpDownload(resolved, reqId);
  });
}

/** Active preview panel cleanup handle. */
let _activePreviewCleanup: (() => void) | null = null;

/** Show a file preview in the filePreview container. */
function _showFilePreview(filename: string, data: Uint8Array, fullPath?: string): void {
  _activePreviewPath = fullPath ?? filename;
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
  for (const url of _activeInlineImageBlobs) URL.revokeObjectURL(url);
  _activeInlineImageBlobs = [];

  const panel = createPreviewPanel(filename, data);

  // Build back button — large triangular left arrow (filename shown in the
  // file list page behind the preview, no need to repeat it here).
  const backBtn = document.createElement('button');
  backBtn.className = 'preview-back-btn';
  backBtn.setAttribute('aria-label', `Back to ${filename}`);
  backBtn.innerHTML = '<svg viewBox="0 0 24 24" width="28" height="28" aria-hidden="true">'
    + '<polygon points="16,4 6,12 16,20" fill="currentColor"></polygon>'
    + '</svg>';

  container.innerHTML = '';
  container.appendChild(backBtn);
  container.appendChild(panel);
  container.classList.remove('hidden');
  explore.classList.add('hidden');

  history.pushState({ type: 'preview' }, '');

  _activePreviewCleanup = (): void => { panel.cleanup(); };

  // Kick off async SFTP fetches for any relative <img data-sftp-src>.
  _fetchInlineImages(panel, _activePreviewPath);

  // Video preview: when the <video> can't render (unsupported codec, moov
  // atom at the end of the file, etc.), swap the element for a fallback
  // message so the Save button is the obvious next action. On mobile, the
  // silent-fail path is real: some browsers never fire 'error' for a blob
  // whose MIME they don't support — metadata simply never loads.
  panel.querySelectorAll<HTMLVideoElement>('.preview-video').forEach((video) => {
    const wrap = video.closest('.preview-video-wrap');
    const detailEl = wrap?.querySelector<HTMLElement>('.preview-video-fallback-detail') ?? null;
    const markFailed = (detail: string): void => {
      if (detailEl) detailEl.textContent = detail;
      wrap?.classList.add('video-failed');
    };
    video.addEventListener('error', () => {
      const err = video.error;
      const codeNames: Record<number, string> = {
        1: 'aborted',
        2: 'network error',
        3: 'decode error',
        4: 'source not supported',
      };
      const label = err ? (codeNames[err.code] ?? `code ${String(err.code)}`) : 'unknown';
      const msg = err?.message ? `${label}: ${err.message}` : label;
      markFailed(`Reason: ${msg}. Save it to your device to view in your media app.`);
    });
    // Extended watchdog: mobile browsers can take ~10s to parse metadata for
    // a large file and not fire any events. 20s with readyState still 0 is a
    // strong signal the browser silently refused.
    const metadataTimeout = setTimeout(() => {
      if (video.readyState === 0) {
        markFailed('The browser did not load video metadata within 20 seconds — likely an unsupported codec.');
      }
    }, 20000);
    video.addEventListener('loadedmetadata', () => { clearTimeout(metadataTimeout); });
    // Hide the save link proactively once playback works — keeps the UI clean.
    video.addEventListener('playing', () => {
      wrap?.querySelector<HTMLElement>('.preview-video-save')?.classList.add('hidden');
    });
  });

  function closePreview(): void {
    panel.cleanup();
    for (const url of _activeInlineImageBlobs) URL.revokeObjectURL(url);
    _activeInlineImageBlobs = [];
    // Drop any in-flight preview / inline-image requests so a late response
    // doesn't resurrect the panel or mutate a detached <img>.
    for (const reqId of _previewPathPending.keys()) {
      _downloadPending.delete(reqId);
      _transferRecords.delete(reqId);
    }
    _previewPathPending.clear();
    _inlineImagePending.clear();
    _activePreviewCleanup = null;
    _activePreviewPath = null;
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

  // Wire tab switching + relative-link intercept (event delegation on the panel)
  panel.addEventListener('click', (e) => {
    const target = e.target as HTMLElement;
    const relLink = target.closest<HTMLAnchorElement>(`a[${SFTP_RELATIVE_LINK_ATTR}="true"]`);
    if (relLink) {
      e.preventDefault();
      const href = relLink.getAttribute('href') ?? '';
      if (href && _activePreviewPath) {
        const activeWs = currentSession()?.ws;
        if (!activeWs || activeWs.readyState !== WebSocket.OPEN) {
          toast('Not connected — can\'t fetch file');
          return;
        }
        const resolved = _resolveRelativePath(_activePreviewPath, href);
        closePreview();
        _requestFilePreview(resolved);
      }
      return;
    }
    const tab = target.closest<HTMLElement>('.preview-tab');
    if (!tab) return;
    const tabKey = tab.dataset.tab;
    panel.querySelectorAll('.preview-tab').forEach((t) => t.classList.toggle('active', t === tab));
    const srcView = panel.querySelector<HTMLElement>('.preview-source');
    const renView = panel.querySelector<HTMLElement>('.preview-rendered');
    if (tabKey === 'source') {
      if (srcView) srcView.style.display = '';
      if (renView) renView.style.display = 'none';
    } else {
      if (srcView) srcView.style.display = 'none';
      if (renView) renView.style.display = '';
    }
  });
}

/** Per-path scroll position for `.files-body` so navigating back from a
 *  preview or a re-render doesn't lose the user's place. */
const _scrollByPath = new Map<string, number>();

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
  const bookmarked = _isCurrentPathFavorited(path);
  const bookmarkClass = bookmarked ? 'files-bookmark-btn filled' : 'files-bookmark-btn';
  const bookmarkLabel = bookmarked ? 'Remove from favorites' : 'Add to favorites';

  panel.innerHTML = `
    <div class="files-breadcrumb">
      <div class="files-breadcrumb-crumbs">${breadcrumbHtml}</div>
      <button class="${bookmarkClass}" aria-label="${bookmarkLabel}" title="${bookmarkLabel}" data-path="${escHtml(path)}">★</button>
    </div>
    <div class="files-toolbar">
      <button class="files-download-btn hidden">Download</button>
      <input type="file" class="files-upload-input" multiple />
      <span class="files-transfer-status${statusHidden}">${escHtml(_transferStatus)}</span>
      <button class="files-upload-cancel${_uploadActive ? '' : ' hidden'}">Cancel</button>
    </div>
    <div class="files-body">${bodyHtml}</div>
  `;

  // Scroll retention: restore saved position and track future scrolls.
  const body = panel.querySelector<HTMLElement>('.files-body');
  if (body) {
    const saved = _scrollByPath.get(path);
    if (saved !== undefined) body.scrollTop = saved;
    body.addEventListener('scroll', () => {
      _scrollByPath.set(path, body.scrollTop);
    }, { passive: true });
  }

  // Re-apply any filter the user has typed in the persistent top-bar input.
  _applyFilesFilter();

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

  const fileInput = panel.querySelector<HTMLInputElement>('.files-upload-input');
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

  // Bookmark star in breadcrumb (#470)
  const bookmarkBtn = panel.querySelector<HTMLElement>('.files-bookmark-btn');
  bookmarkBtn?.addEventListener('click', () => {
    const profId = _activeProfileId();
    if (!profId) { toast('Connect a session to bookmark paths'); return; }
    const fav: Favorite = { path, isFile: false };
    toggleFavorite(profId, fav);
    _renderFilesPanel(path, bodyHtml);
  });
}

/** Resolve the active session's profile id for favorites keying, or null. */
function _activeProfileId(): string | null {
  const session = currentSession();
  if (!session?.profile) return null;
  return profileIdOf(session.profile);
}

/** True if the current files path is favorited for the active profile. */
function _isCurrentPathFavorited(path: string): boolean {
  const profId = _activeProfileId();
  if (!profId) return false;
  return isFavorited(profId, path);
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
    // Show cached immediately for snappy UX, but still fire an ls so the
    // view reflects any filesystem changes since last browse.
    _renderFilesList(path, cached);
  } else {
    _renderFilesPanel(path, '<div class="files-loading">Loading...</div>');
  }
  const reqId = `ls-${String(Date.now())}`;
  _filesPending.set(reqId, path);
  _tagReq(reqId);
  sendSftpLs(path, reqId);
}

/** Apply the current filter-input value to visible file-entry rows.
 *  Case-insensitive substring match on `data-name`. Safe to call any time. */
function _applyFilesFilter(): void {
  const input = document.getElementById('filesFilterInput') as HTMLInputElement | null;
  const q = input?.value.toLowerCase().trim() ?? '';
  document.querySelectorAll<HTMLElement>('#filesExplore .files-entry').forEach((row) => {
    if (!q) { row.classList.remove('filter-hidden'); return; }
    const name = row.dataset.name ?? '';
    row.classList.toggle('filter-hidden', !name.includes(q));
  });
}

/** Prompt the user for an absolute path and navigate there. Used by the
 *  docs menu "Go to path…" action. */
function _showFilesGotoPrompt(): void {
  const overlay = document.getElementById('filesGotoOverlay');
  const input = document.getElementById('filesGotoInput') as HTMLInputElement | null;
  const okBtn = document.getElementById('filesGotoOk');
  const cancelBtn = document.getElementById('filesGotoCancel');
  if (!overlay || !input || !okBtn || !cancelBtn) return;

  const current = _activeFilesState().path;
  input.value = current === '/' ? '/' : current;
  overlay.classList.remove('hidden');
  // Select everything so pasted text replaces the prefill; fall back to focus on old iOS.
  setTimeout(() => {
    input.focus();
    try { input.setSelectionRange(0, input.value.length); } catch (_) { /* ignore */ }
  }, 50);

  function cleanup(): void {
    overlay!.classList.add('hidden');
    okBtn!.removeEventListener('click', onOk);
    cancelBtn!.removeEventListener('click', onCancel);
    input!.removeEventListener('keydown', onKeydown);
  }

  function onOk(): void {
    const raw = input!.value.trim();
    if (!raw) { cleanup(); return; }
    // Normalize: must start with /, collapse double slashes, strip trailing / (except root).
    let target = raw.startsWith('/') ? raw : `/${raw}`;
    target = target.replace(/\/+/g, '/');
    if (target.length > 1 && target.endsWith('/')) target = target.slice(0, -1);
    cleanup();
    _filesNavigateTo(target);
  }

  function onCancel(): void { cleanup(); }

  function onKeydown(e: KeyboardEvent): void {
    if (e.key === 'Enter') { e.preventDefault(); onOk(); }
    else if (e.key === 'Escape') { e.preventDefault(); onCancel(); }
  }

  okBtn.addEventListener('click', onOk);
  cancelBtn.addEventListener('click', onCancel);
  input.addEventListener('keydown', onKeydown);
}

/** Force a fresh ls of the current directory, bypassing cache. Used by the
 *  docs menu Refresh action. */
function _refreshFiles(): void {
  const state = _activeFilesState();
  const path = state.path;
  state.cache.delete(path);
  _renderFilesPanel(path, '<div class="files-loading">Loading...</div>');
  const reqId = `ls-${String(Date.now())}`;
  _filesPending.set(reqId, path);
  _tagReq(reqId);
  sendSftpLs(path, reqId);
}

function _renderFilesList(path: string, entries: SftpEntry[]): void {
  // Ghost rows for in-flight uploads landing directly in this directory.
  // The ghost's data-path matches the destination path, so
  // _updateFilesEntryProgress populates the same filling circle used for downloads.
  const ghostRows: string[] = [];
  _transferRecords.forEach((rec) => {
    if (rec.direction !== 'upload' || rec.status !== 'active') return;
    const lastSlash = rec.path.lastIndexOf('/');
    if (lastSlash < 0) return;
    const parent = lastSlash === 0 ? '/' : rec.path.slice(0, lastSlash);
    if (parent !== path) return;
    // Skip if a real entry with the same name already exists (post-completion
    // refresh race) — real entry will naturally replace the ghost.
    const name = rec.path.slice(lastSlash + 1);
    if (entries.some((e) => e.name === name)) return;
    const sizeStr = _formatSize(rec.size);
    ghostRows.push(`<div class="files-entry files-entry-upload" data-dir="false" data-path="${escHtml(rec.path)}" data-name="${escHtml(name.toLowerCase())}">
      <span class="files-entry-icon">F</span>
      <span class="files-entry-name">${escHtml(name)}</span>
      <span class="files-entry-size">${escHtml(sizeStr)}</span>
    </div>`);
  });

  if (entries.length === 0 && ghostRows.length === 0) {
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
    const relStr = _formatRelative(e.mtime);
    const dateHtml = dateStr
      ? '<span class="files-entry-date">'
        + `<span class="files-entry-date-abs">${escHtml(dateStr)}</span>`
        + (relStr ? `<span class="files-entry-date-rel">${escHtml(relStr)}</span>` : '')
        + '</span>'
      : '';
    return `<div class="files-entry" data-dir="${String(e.isDir)}" data-path="${escHtml(fullPath)}" data-name="${escHtml(e.name.toLowerCase())}">
      <span class="files-entry-icon">${e.isDir ? 'D' : 'F'}</span>
      <span class="files-entry-name">${escHtml(e.name)}</span>
      ${sizeStr ? `<span class="files-entry-size">${escHtml(sizeStr)}</span>` : ''}
      ${dateHtml}
    </div>`;
  }).join('');

  _renderFilesPanel(path, `<div class="files-list">${ghostRows.join('')}${rows}</div>`);
  // Re-apply progress overlays after the list DOM was rebuilt.
  _updateFilesEntryProgress();

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

/** Short relative time for a parsed mtime. "10s ago", "3m ago", "2h ago",
 *  "yesterday", "3d ago", "2w ago", "5mo ago", "1y ago". */
function _formatRelative(mtime: string): string {
  const ts = Number(mtime);
  const d = isNaN(ts) ? new Date(mtime) : new Date(ts * 1000);
  if (isNaN(d.getTime())) return '';
  const delta = Date.now() - d.getTime();
  if (delta < 0) return 'just now';
  const secs = Math.floor(delta / 1000);
  if (secs < 60) return `${String(secs)}s ago`;
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${String(mins)}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${String(hours)}h ago`;
  const days = Math.floor(hours / 24);
  if (days === 1) return 'yesterday';
  if (days < 7) return `${String(days)}d ago`;
  const weeks = Math.floor(days / 7);
  if (weeks < 5) return `${String(weeks)}w ago`;
  const months = Math.floor(days / 30);
  if (months < 12) return `${String(months)}mo ago`;
  const years = Math.floor(days / 365);
  return `${String(years)}y ago`;
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
        _transferRecords.set(reqId, { name: filename, path, size: 0, sent: 0, status: 'active', direction: 'download', startTime: Date.now() });
        _downloadChunks.set(reqId, []);
        _renderTransferList();
        sendSftpDownloadStart(path, reqId);
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

/** Render the favorites submenu anchored near the Files menu item. (#470) */
function _showFavoritesSubmenu(_touchX: number, touchY: number): void {
  _dismissContextMenu();
  const profId = _activeProfileId();
  if (!profId) return;
  // Dedupe on path — multiple entries with the same path are redundant.
  const seen = new Set<string>();
  const favs = listFavorites(profId).filter((f) => {
    if (seen.has(f.path)) return false;
    seen.add(f.path);
    return true;
  });
  if (favs.length === 0) return;

  const overlay = document.createElement('div');
  overlay.id = 'filesFavOverlay';
  overlay.className = 'ctx-overlay';

  const menu = document.createElement('div');
  menu.id = 'filesFavMenu';
  menu.className = 'ctx-menu files-fav-menu';
  menu.innerHTML = favs.map((f) => {
    const label = f.label ?? f.path;
    const icon = f.isFile ? 'F' : 'D';
    return `<button class="ctx-menu-item files-fav-item" data-path="${escHtml(f.path)}" data-is-file="${String(f.isFile)}"><span class="files-fav-icon">${icon}</span>${escHtml(label)}</button>`;
  }).join('');

  // Fill horizontally: 8px inset on each side; only vertical position varies.
  const vh = window.innerHeight;
  const menuH = Math.min(favs.length * 44, vh - 16);
  const top = Math.max(8, Math.min(touchY, vh - menuH - 8));
  menu.style.setProperty('--ctx-y', `${String(top)}px`);

  document.body.appendChild(overlay);
  document.body.appendChild(menu);
  history.pushState({ favMenu: true }, '');

  let dismissed = false;
  function dismiss(): void {
    if (dismissed) return;
    dismissed = true;
    overlay.remove();
    menu.remove();
    window.removeEventListener('popstate', onPopstate);
    _ctxMenuDismiss = null;
  }
  function onPopstate(): void { dismiss(); }
  _ctxMenuDismiss = dismiss;
  overlay.addEventListener('click', () => { dismiss(); history.back(); });
  window.addEventListener('popstate', onPopstate);

  menu.addEventListener('click', (e) => {
    const btn = (e.target as HTMLElement).closest<HTMLElement>('[data-path]');
    if (!btn) return;
    const favPath = btn.dataset.path ?? '';
    const isFile = btn.dataset.isFile === 'true';
    // Dismiss the submenu (and its popstate listener) before navigating.
    // Do NOT call history.back() — its async popstate races with the
    // subsequent navigateToPanel/_filesNavigateTo and can re-route away from
    // the target. Leaving the favMenu pushState in history is harmless.
    dismiss();
    document.getElementById('sessionMenu')?.classList.add('hidden');
    document.getElementById('menuBackdrop')?.classList.add('hidden');

    if (isFile) {
      navigateToPanel('files');
      _requestFilePreview(favPath);
      return;
    }
    // For directories: if the session hasn't been activated yet, the realpath
    // request fires on navigateToPanel and its response would overwrite our
    // target path with the resolved home dir. Stash favPath as deepLinkPath
    // so the realpath handler routes to the favorite instead.
    const state = _activeFilesState();
    if (state.firstActivated) {
      navigateToPanel('files');
      _filesNavigateTo(favPath);
    } else {
      state.deepLinkPath = favPath;
      navigateToPanel('files');
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
    } else if (msg.type === 'sftp_download_meta') {
      // Server declared total size — update record so the circle can animate.
      const rec = _transferRecords.get(msg.requestId);
      if (rec) { rec.size = msg.size; _renderTransferList(); }
    } else if (msg.type === 'sftp_download_chunk') {
      // Buffer bytes and advance progress. _renderTransferList() is rAF-batched
      // internally so per-chunk calls don't thrash the DOM.
      const chunks = _downloadChunks.get(msg.requestId);
      if (!chunks) return;
      // connection.ts attaches pre-decoded bytes when the chunk arrived as a
      // binary WS frame (sftp_download_chunk_bin path). Otherwise fall back
      // to decoding the base64 `data` field for backwards-compat.
      const binPayload = (msg as unknown as { payload?: Uint8Array }).payload;
      const bytes = binPayload ?? _b64ToBytes(msg.data);
      chunks.push(bytes);
      const rec = _transferRecords.get(msg.requestId);
      if (rec) {
        rec.sent = msg.offset + bytes.length;
        _renderTransferList();
      }
    } else if (msg.type === 'sftp_download_end') {
      // All chunks received — concatenate and route as a single blob through
      // the same preview/save path the single-shot download already uses.
      const chunks = _downloadChunks.get(msg.requestId);
      _downloadChunks.delete(msg.requestId);
      const filename = _downloadPending.get(msg.requestId);
      _downloadPending.delete(msg.requestId);
      const previewPath = _previewPathPending.get(msg.requestId);
      _previewPathPending.delete(msg.requestId);
      _setTransferStatus('');
      if (chunks && filename) {
        let total = 0;
        for (const c of chunks) total += c.length;
        const merged = new Uint8Array(total);
        let off = 0;
        for (const c of chunks) { merged.set(c, off); off += c.length; }
        if (previewPath) {
          _showFilePreview(filename, merged, previewPath);
        } else {
          // Browser-save path still uses base64 via an <a download>; build it here
          // so the server can keep streaming chunks rather than sending a mega-blob.
          let binary = '';
          const BLOCK = 0x8000;
          for (let i = 0; i < merged.length; i += BLOCK) {
            const slice = merged.subarray(i, Math.min(i + BLOCK, merged.length));
            binary += String.fromCharCode.apply(null, slice as unknown as number[]);
          }
          _triggerBlobDownload(filename, btoa(binary));
        }
      }
      const dlRec = _transferRecords.get(msg.requestId);
      if (dlRec) { dlRec.status = 'done'; dlRec.sent = dlRec.size; _renderTransferList(); }
    } else if (msg.type === 'sftp_download_result') {
      // Inline markdown image fetch — decode to blob URL and swap <img src>.
      const inlineImg = _inlineImagePending.get(msg.requestId);
      if (inlineImg) {
        _inlineImagePending.delete(msg.requestId);
        if (msg.data) {
          const rel = inlineImg.dataset.sftpSrc ?? '';
          const mime = MIME_MAP[extOf(rel)] ?? 'application/octet-stream';
          const blob = new Blob([_b64ToBytes(msg.data) as BlobPart], { type: mime });
          const url = URL.createObjectURL(blob);
          _activeInlineImageBlobs.push(url);
          inlineImg.src = url;
          inlineImg.removeAttribute(SFTP_INLINE_IMG_ATTR);
        } else {
          _markInlineImgFailed(inlineImg);
        }
        return;
      }
      const filename = _downloadPending.get(msg.requestId);
      _downloadPending.delete(msg.requestId);
      const previewPath = _previewPathPending.get(msg.requestId);
      _previewPathPending.delete(msg.requestId);
      // Clean up any streaming buffer if the chunked flow errored mid-stream
      // (server sends sftp_download_result with ok:false on read errors).
      const hadChunks = _downloadChunks.delete(msg.requestId);
      _setTransferStatus('');
      if (filename && msg.data && previewPath) {
        _showFilePreview(filename, _b64ToBytes(msg.data), previewPath);
      } else if (filename && msg.data) {
        _triggerBlobDownload(filename, msg.data);
      } else if (filename && hadChunks) {
        toast(`Download failed: ${filename}${msg.error ? ` — ${msg.error}` : ''}`);
      }
      const dlRec = _transferRecords.get(msg.requestId);
      if (dlRec) {
        dlRec.status = msg.ok === false ? 'failed' : 'done';
        if (msg.ok === false && msg.error) dlRec.error = msg.error;
        _renderTransferList();
      }
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
        const attemptedPath = _previewPathPending.get(msg.requestId);
        _previewPathPending.delete(msg.requestId);
        _downloadChunks.delete(msg.requestId);
        _setTransferStatus('');
        const dlErrRec = _transferRecords.get(msg.requestId);
        if (dlErrRec) { dlErrRec.status = 'failed'; dlErrRec.error = msg.message; _renderTransferList(); }
        const pathSuffix = attemptedPath ? ` (${attemptedPath})` : '';
        toast(`Download failed${pathSuffix}: ${msg.message}`);
      } else if (_inlineImagePending.has(msg.requestId)) {
        const failedImg = _inlineImagePending.get(msg.requestId)!;
        _inlineImagePending.delete(msg.requestId);
        _markInlineImgFailed(failedImg);
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

  // Close button (#459) — return to terminal
  document.getElementById('filesCloseBtn')?.addEventListener('click', () => {
    navigateToPanel('terminal');
  });

  // Filter input in the top bar — live-filters visible entries; Enter on a
  // single remaining match triggers its default action (nav to dir / preview
  // file) via a synthetic click.
  const filterInput = document.getElementById('filesFilterInput') as HTMLInputElement | null;
  filterInput?.addEventListener('input', _applyFilesFilter);
  filterInput?.addEventListener('keydown', (e) => {
    if (e.key !== 'Enter') return;
    const visible = Array.from(
      document.querySelectorAll<HTMLElement>('#filesExplore .files-entry'),
    ).filter((r) => !r.classList.contains('filter-hidden'));
    if (visible.length !== 1) return;
    e.preventDefault();
    filterInput.value = '';
    _applyFilesFilter();
    visible[0]!.click();
  });

  // Docs menu (#470) — top-right dropdown holding actions such as Upload
  const docsMenuBtn = document.getElementById('filesDocsMenuBtn');
  const docsMenu = document.getElementById('filesDocsMenu');
  docsMenuBtn?.addEventListener('click', (e) => {
    e.stopPropagation();
    if (!docsMenu) return;
    const willHide = docsMenu.classList.toggle('hidden');
    docsMenuBtn.setAttribute('aria-expanded', willHide ? 'false' : 'true');
  });
  document.addEventListener('click', (e) => {
    if (!docsMenu || docsMenu.classList.contains('hidden')) return;
    if (e.target instanceof Node && (docsMenu.contains(e.target) || docsMenuBtn?.contains(e.target))) return;
    docsMenu.classList.add('hidden');
    docsMenuBtn?.setAttribute('aria-expanded', 'false');
  });
  docsMenu?.querySelectorAll<HTMLElement>('.files-docs-menu-item').forEach((item) => {
    item.addEventListener('click', () => {
      const action = item.dataset.action;
      docsMenu.classList.add('hidden');
      docsMenuBtn?.setAttribute('aria-expanded', 'false');
      if (action === 'upload') {
        const fileInput = document.querySelector<HTMLInputElement>('#filesExplore .files-upload-input');
        fileInput?.click();
      } else if (action === 'refresh') {
        _refreshFiles();
      } else if (action === 'goto') {
        _showFilesGotoPrompt();
      }
    });
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

  // Session menu: Files entry — opens the files panel (#409) / favorites on long-press (#470)
  const sessionFilesBtn = document.getElementById('sessionFilesBtn');
  let filesLongPressFired = false;
  let filesPressTimer: ReturnType<typeof setTimeout> | null = null;
  sessionFilesBtn?.addEventListener('click', () => {
    if (filesLongPressFired) { filesLongPressFired = false; return; }
    navigateToPanel('files');
    document.getElementById('sessionMenu')?.classList.add('hidden');
    document.getElementById('menuBackdrop')?.classList.add('hidden');
  });
  sessionFilesBtn?.addEventListener('touchstart', (e) => {
    filesPressTimer = setTimeout(() => {
      filesPressTimer = null;
      filesLongPressFired = true;
      const touch = e.touches[0];
      _showFavoritesSubmenu(touch ? touch.clientX : 0, touch ? touch.clientY : 0);
    }, 500);
  }, { passive: true });
  const filesCancelPress = (): void => { if (filesPressTimer) { clearTimeout(filesPressTimer); filesPressTimer = null; } };
  sessionFilesBtn?.addEventListener('touchend', filesCancelPress);
  sessionFilesBtn?.addEventListener('touchmove', filesCancelPress);
  sessionFilesBtn?.addEventListener('touchcancel', () => { filesCancelPress(); filesLongPressFired = false; });

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
