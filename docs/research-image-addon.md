# Research: xterm.js ImageAddon for Image Passthrough

Research spike for issue #3. Evaluates `@xterm/addon-image` for inline image
display in MobiSSH's terminal.

## 1. Supported Image Protocols

The ImageAddon supports two protocols:

| Protocol | Status | Description |
|---|---|---|
| **SIXEL** | Beta | DEC SIXEL graphics. Widely supported by CLI tools (`libsixel`, `img2sixel`, `chafa`, `viu`). Data arrives as DCS escape sequences. |
| **iTerm2 Inline Image Protocol (IIP)** | Alpha | OSC 1337 escape sequence with base64-encoded image data. Supported by iTerm2, WezTerm, and various terminal emulators. |
| **Kitty Graphics Protocol** | Not supported | The addon does not implement Kitty's graphics protocol. No public plans to add it. |

Sources:
- [GitHub: jerch/xterm-addon-image](https://github.com/jerch/xterm-addon-image)
- [GitHub: xtermjs/xterm.js addons/addon-image](https://github.com/xtermjs/xterm.js/tree/master/addons/addon-image)
- [npm: @xterm/addon-image](https://www.npmjs.com/package/@xterm/addon-image)

## 2. Version Compatibility

**MobiSSH current state:**
- xterm.js version: **6.0.0** (vendored at `public/vendor/xterm.min.js`, declared as `@xterm/xterm@^6.0.0` in `package.json`)
- Addons in use: `@xterm/addon-fit`, `@xterm/addon-clipboard`

**ImageAddon versions:**
- Latest release: **0.9.0** (published ~Jan 2026)
- The addon was originally a standalone package (`xterm-addon-image` by jerch), then merged into the main xterm.js monorepo as `@xterm/addon-image` starting with xterm.js 5.3.0.
- `@xterm/addon-image@0.9.0` is published alongside `@xterm/xterm@6.0.0` from the same monorepo, so version compatibility is confirmed.

**Version history:**
- `0.1.x` -> xterm.js 4.16-4.19
- `0.2.x` -> xterm.js 5.0
- `0.8.0` -> xterm.js 5.5.0
- `0.9.0` -> xterm.js 6.0.0

Source: [npm: @xterm/addon-image](https://www.npmjs.com/package/@xterm/addon-image)

## 3. Loading the Addon

The addon follows the standard xterm.js addon pattern:

```typescript
import { ImageAddon } from '@xterm/addon-image';

const imageAddon = new ImageAddon({
  enableSizeReports: true,    // CSI t size reports (default: true)
  pixelLimit: 16_777_216,     // max pixels per image (default: 16M = 4096x4096)
  sixelPaletteLimit: 4096,    // max SIXEL palette registers (default: 256, max: 4096)
  storageLimit: 128,          // image cache size in MB (default: 128)
});

terminal.loadAddon(imageAddon);
```

For MobiSSH's vendored-script approach (no bundler), the addon would need to be
downloaded as a UMD/IIFE bundle to `public/vendor/` and loaded via `<script>` tag,
similar to how FitAddon and ClipboardAddon are loaded today.

## 4. Known Limitations

### Renderer requirement

The ImageAddon works with xterm.js's **canvas-based renderers** (CanvasAddon or WebglAddon). It does **not** work with the DOM renderer.

MobiSSH currently uses the **default DOM renderer** (no CanvasAddon or WebglAddon is loaded in `terminal.ts`). Enabling ImageAddon would require also loading either `@xterm/addon-canvas` or `@xterm/addon-webgl`.

- `@xterm/addon-canvas`: Uses 2D canvas. Broader compatibility, works as WebGL fallback.
- `@xterm/addon-webgl`: Uses WebGL2. Better performance but reduced browser support (WebGL2 not available on all mobile devices).

### Image storage

The addon implements a FIFO cache for rendered images. When `storageLimit` (default 128 MB) is exceeded, oldest images are evicted. On mobile devices with limited memory, this may need to be tuned down.

### Image sizing

Images are sized based on terminal cell dimensions. The `pixelLimit` default of 16M pixels (e.g., 4096x4096) is generous and may need to be reduced for mobile to avoid memory pressure.

### No animated GIF support

Only the first frame of animated GIFs is rendered (confirmed for both SIXEL and IIP).

### SIXEL palette

Default palette is 256 registers (per DEC spec). Can be increased to 4096 for higher color fidelity but uses more memory per image.

## 5. Mobile Browser Compatibility

### Critical: Chrome/Android rendering bug

**Issue [#5343](https://github.com/xtermjs/xterm.js/issues/5343)** (opened May 2025, unresolved as of this writing): Loading `@xterm/addon-image` on Chrome/Android causes images to hide terminal text, making the terminal **unusable**. This was reported with `@xterm/xterm@5.5.0` + `@xterm/addon-image@0.8.0`. The issue status is unconfirmed/open with no fix available.

**This is a blocking issue for MobiSSH**, which is a mobile-first application primarily targeting Chrome/Android.

### Compatibility matrix

| Browser | Canvas renderer | WebGL renderer | ImageAddon | Notes |
|---|---|---|---|---|
| Chrome Desktop | Yes | Yes | Works | Reference platform |
| Chrome Android | Yes | Yes (WebGL2 varies) | **Broken** (issue #5343) | Text hidden behind images |
| Safari iOS 16+ | Yes (slower) | Limited WebGL2 | Untested | iOS stuck with slower DOM renderer historically; canvas addon may work on iOS 16+ |
| Firefox Android | Yes | Yes | Untested | No known issues reported |
| Samsung Internet | Yes | Likely | Untested | Chromium-based, likely same #5343 bug |

**Confirmed facts vs. speculation:**
- CONFIRMED: Chrome/Android has a rendering bug with ImageAddon (GitHub issue with reproduction).
- CONFIRMED: The addon requires canvas or WebGL renderer, not DOM.
- SPECULATION: Safari iOS may work with canvas renderer but has not been tested with ImageAddon specifically.
- SPECULATION: The Chrome/Android bug may be fixed in addon 0.9.0 / xterm 6.0.0 (no evidence either way).

## 6. Server-Side Passthrough

### Current architecture

MobiSSH's server (`server/index.js`) proxies SSH shell data as JSON messages:
```javascript
stream.on('data', (chunk) => {
  send({ type: 'output', data: chunk.toString('utf8') });
});
```

### The problem: UTF-8 encoding

SIXEL data is transmitted as DCS (Device Control String) escape sequences containing
binary-ish data (bytes 0x3F-0x7E for SIXEL pixel data). The current `chunk.toString('utf8')`
conversion should handle this correctly because SIXEL uses only ASCII-range bytes.

However, the iTerm2 IIP protocol uses base64-encoded data within an OSC sequence, which
is also pure ASCII and passes through UTF-8 encoding without issues.

**Both protocols use escape sequences composed of ASCII-printable characters**, so the
current `toString('utf8')` passthrough in `server/index.js` should work without
modification. The ssh2 library delivers shell data as Buffers; the escape sequences are
embedded in the normal terminal data stream.

### WebSocket framing

The current JSON-over-WebSocket protocol sends terminal output as:
```json
{"type": "output", "data": "<escape sequences + text>"}
```

This works for image data because:
1. SIXEL and IIP escape sequences are ASCII-safe
2. JSON string encoding handles any special characters
3. No binary WebSocket frames are needed

**No server changes required** for basic image passthrough.

### Potential concern: large payloads

A single SIXEL image can generate many kilobytes of escape sequence data. The server's
`MAX_MESSAGE_SIZE` is 4 MB, which should be sufficient for most inline images. Very large
images (e.g., high-resolution photos via `img2sixel`) could exceed this and would need
chunked delivery (the ssh2 stream naturally chunks data, and the client reassembles via
xterm.js's parser).

## 7. Addon Conflicts

### FitAddon

No known conflicts. FitAddon manages terminal dimensions; ImageAddon renders within
those dimensions. Both are commonly used together (e.g., in VS Code's integrated terminal).

### ClipboardAddon

No known conflicts. ClipboardAddon handles OSC 52 (clipboard access). ImageAddon handles
DCS (SIXEL) and OSC 1337 (IIP). Different OSC/DCS handlers, no overlap.

### Renderer addons

ImageAddon **requires** a canvas or WebGL renderer addon to be loaded. This would be a new
dependency for MobiSSH, which currently uses the default DOM renderer. Adding CanvasAddon
or WebglAddon changes the rendering pipeline and could affect:
- Performance characteristics (canvas is generally faster than DOM)
- Memory usage (canvas allocates off-screen buffers)
- Text rendering quality (canvas may render fonts slightly differently)

## Recommendation

### Do not implement now

The ImageAddon is **not ready for MobiSSH** due to:

1. **Chrome/Android rendering bug** (issue #5343) makes it unusable on MobiSSH's primary target platform. This is a show-stopper.
2. **Renderer dependency** requires adding CanvasAddon or WebglAddon, which changes the rendering pipeline for all users, not just those viewing images.
3. **Mobile memory concerns** need investigation before deploying image caching on resource-constrained devices.

### Suggested approach

1. **Monitor issue #5343** for a fix. If resolved in a future xterm.js release, re-evaluate.
2. **Consider a feature flag** approach: load ImageAddon + CanvasAddon only when the user enables an "Inline images" setting, so it doesn't affect users who don't need it.
3. **Test on real devices** before any merge: the Chrome/Android bug was discovered on a Pixel 7 Pro, which is representative of MobiSSH's target hardware.
4. **No Kitty protocol**: if Kitty graphics support is needed, it would require a different addon or custom parser hooks, since ImageAddon does not support it.

### If proceeding despite risks

Minimal integration would require:
1. Vendor `@xterm/addon-image@0.9.0` and `@xterm/addon-canvas@0.9.0` to `public/vendor/`
2. Add `<script>` tags in `index.html`
3. In `terminal.ts`, load CanvasAddon before ImageAddon:
   ```typescript
   appState.terminal.loadAddon(new CanvasAddon.CanvasAddon());
   appState.terminal.loadAddon(new ImageAddon.ImageAddon({ pixelLimit: 4_194_304 }));
   ```
4. Reduce `pixelLimit` to ~4M pixels (2048x2048) for mobile memory safety
5. No server changes needed

Sources:
- [npm: @xterm/addon-image](https://www.npmjs.com/package/@xterm/addon-image)
- [GitHub: jerch/xterm-addon-image](https://github.com/jerch/xterm-addon-image)
- [GitHub: xtermjs/xterm.js addon-image](https://github.com/xtermjs/xterm.js/tree/master/addons/addon-image)
- [xterm.js Encoding Guide](https://xtermjs.org/docs/guides/encoding/)
- [Issue #5343: addon-image unusable on Chrome/Android](https://github.com/xtermjs/xterm.js/issues/5343)
- [VS Code terminal image support PR #182442](https://github.com/microsoft/vscode/pull/182442)
- [Are We Sixel Yet?](https://www.arewesixelyet.com/)
