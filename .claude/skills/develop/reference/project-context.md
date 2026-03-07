# MobiSSH Project Context

## What This Is
Mobile-first SSH PWA. Node.js WebSocket bridge proxies SSH connections; xterm.js renders
the terminal in-browser. Designed for Android/iOS home screen install over Tailscale.

## Architecture
- `server/index.js` — plain JS Node.js process: HTTP static files + WebSocket SSH bridge (port 8081)
- `src/modules/*.ts` — TypeScript source, compiles to `public/modules/*.js` via `tsc`
- `public/` — PWA frontend (ES modules loaded by `index.html`)
- `tests/` — Playwright browser tests + Vitest unit tests

## Module Map
| Module | Responsibility | Key exports |
|---|---|---|
| `app.ts` | Boot orchestrator, DI wiring | — |
| `types.ts` | All shared interfaces/types | `SSHProfile`, `AppState`, `ConnectionStatus`, etc. |
| `state.ts` | Centralized mutable state | `appState` |
| `constants.ts` | Pure constants, themes, config | `THEMES`, `getDefaultWsUrl()` |
| `vault.ts` | AES-GCM credential vault (DEK+KEK) | `createVault()`, `unlockVault()`, `encrypt()`, `decrypt()` |
| `terminal.ts` | xterm.js init, theming, fit | `initTerminal()`, `applyTheme()` |
| `connection.ts` | WebSocket/SSH lifecycle | `connectSSH()`, `disconnect()` |
| `ime.ts` | Mobile keyboard input handling | `initIME()` |
| `ui.ts` | Panels, tab bar, modals | `initUI()`, `showPanel()` |
| `profiles.ts` | SSH profile CRUD | `initProfiles()`, `loadProfiles()`, `getProfiles()` |
| `settings.ts` | User preferences panel | `initSettingsPanel()` |
| `selection.ts` | Copy/paste, text selection | `initSelection()` |
| `recording.ts` | Session recording | `initRecording()` |

## Dependency Injection Pattern
Modules export `initXxx(deps)` functions. `app.ts` calls them at boot with concrete deps:
```typescript
initConnection({ toast, setStatus, focusIME, applyTabBarVisibility });
```
Deps are stored in module-level `let _toast = ...` variables. This avoids circular imports.

## State Management
Single `appState` object in `state.ts`. Modules import and mutate directly:
```typescript
import { appState } from './state.js';
appState.sshConnected = true;
```

## WebSocket Protocol
```
Client → Server: { type: 'connect' | 'input' | 'resize' | 'disconnect', ... }
Server → Client: { type: 'connected' | 'output' | 'error' | 'hostkey' | 'disconnected', ... }
```

## Boot Sequence
1. Init core modules (terminal, UI, IME, selection)
2. DI wiring (pass toast/setStatus/etc to each module)
3. Data load (profiles, keys, service worker)
4. Vault unlock
5. Signal `window.__appReady()` for tests
6. First-run vault setup prompt
7. Routing + theme

## Key Design Decisions
- Single port for static + WS (no separate API server)
- No bundler — tsc only, ES modules loaded directly
- `Cache-Control: no-store` + network-first SW (never stale)
- Vault uses PBKDF2 (600k iterations) for password → KEK, AES-GCM for DEK wrapping
- `visualViewport.height` for keyboard detection (not `window.innerHeight`)
- Touch: `touch-action: none` on terminal for JS gesture handling
- All layout via CSS custom properties, never inline styles
