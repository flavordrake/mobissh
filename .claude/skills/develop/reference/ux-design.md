# UX Design & CSS Best Practices — MobiSSH

## Design Philosophy
Mobile-first SSH terminal. Every pixel serves the terminal. UI chrome (tabs, key bar,
panels) is minimal and gets out of the way during active sessions.

## CSS Architecture

### Custom Properties (Design Tokens)
All colors, sizes, and layout values are CSS custom properties in `:root`:
```css
:root {
  --bg-deep: #0d0d1a;      /* deepest background */
  --bg-panel: #1a1a2e;     /* panel/sidebar background */
  --bg-card: #16213e;      /* card/input container */
  --bg-input: #0f3460;     /* input field background */
  --accent: #00ff88;       /* primary accent (green) */
  --accent-dim: #00cc6a;   /* muted accent */
  --danger: #ff4444;       /* destructive actions */
  --text: #e0e0e0;         /* primary text */
  --text-dim: #888;        /* secondary text */
  --border: #2a2a4a;       /* borders */
  --terminal-bg: #000;     /* terminal background (theme-aware) */
}
```
**Never hardcode colors.** Always use `var(--token-name)`.

### Theme System
Themes are defined in `src/modules/constants.ts` as `THEMES` object. Each theme provides
xterm.js colors and app chrome colors. `applyTheme()` sets CSS custom properties:
```typescript
style.setProperty('--terminal-bg', t.theme.background);
style.setProperty('--bg-deep', t.app.bgDeep);
// etc.
```
New UI elements must use these variables to be theme-aware.

### Layout Rules
```css
/* Dynamic viewport height — handles mobile keyboard */
height: 100dvh;

/* Safe area insets — handles notch/Dynamic Island */
padding-top: env(safe-area-inset-top);
padding-bottom: env(safe-area-inset-bottom);

/* Flexbox column layout — terminal fills remaining space */
#app { display: flex; flex-direction: column; }
#terminal { flex: 1; }
```

### Touch Targets
- Minimum 44px for interactive elements (WCAG 2.5.5)
- `touch-action: manipulation` on buttons (prevents double-tap zoom)
- `touch-action: none` on terminal (JS handles all gestures)

### No Inline Styles — Hard Rule
```html
<!-- BAD -->
<div style="background: red; padding: 10px;">

<!-- GOOD -->
<div class="error-banner">
```
```css
.error-banner { background: var(--danger); padding: 10px; }
```

## Mobile-Specific Patterns

### Keyboard Detection
```typescript
// Use visualViewport, NOT window.innerHeight
window.visualViewport.addEventListener('resize', () => {
  const vv = window.visualViewport!;
  keyboardVisible = vv.height < window.outerHeight * 0.75;
});
```

### Hidden Input for IME
```css
#imeInput {
  position: fixed;
  opacity: 0;
  font-size: 16px;  /* Prevents iOS auto-zoom on focus */
  pointer-events: none;
}
```

### Panel Visibility
Panels use `display: none` / `.active { display: flex }` — no CSS transitions on
display. Transitions use `height`, `opacity`, or `transform` only.

### Tab Bar Hide During Terminal Focus
```css
#tabBar.hidden { height: 0; border-top: none; }
```
Transition on `height` with `overflow: hidden` — no layout jump.

## Animation Guidelines
- Keep animations under 200ms for UI feedback
- Use `ease-out` for entrances, `ease-in` for exits
- No animations on layout-critical elements during keyboard transitions
- Respect `prefers-reduced-motion`:
```css
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { animation-duration: 0.01ms !important; }
}
```

## Common UX Mistakes to Avoid
- Don't use `position: fixed` for elements that need to move with the keyboard
- Don't use `vh` units — use `dvh` for dynamic viewport
- Don't rely on `hover` states — mobile has no hover
- Don't use small text — minimum 14px for body, 12px for labels
- Don't put critical actions behind long-press — discoverability is poor
- Don't use `overflow: scroll` on the terminal — xterm handles its own scrolling
- Don't add new panels without considering how they interact with the keyboard

## Adding New UI Elements
1. Define styles in `public/app.css` using existing custom properties
2. Use semantic HTML (`<button>`, `<dialog>`, `<nav>`) — not `div` with click handlers
3. Test on pixel-7 (Android), iphone-14 (iOS), and chromium (desktop) projects
4. Verify with keyboard visible and hidden
5. Check safe area insets on iPhone (notch handling)
