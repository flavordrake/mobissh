# IME Compose Mode Research

## Problem Statement

MobiSSH's compose mode garbles terminal output when users tap a predictive text
correction after swipe-typing (#231). The symptom is duplicated prefix characters
(e.g., swipe "simulation", tap correction "stimulation" → terminal receives
"simulationtimulation"). A related gap is that Android voice dictation may drop
or duplicate words (#232) because interim recognition results fire as IME events
that the current handler treats as final committed text. Both problems stem from
the same root cause: MobiSSH forwards text to SSH at `compositionend` and on
every `input` event without handling subsequent correction or replacement events.

## Current MobiSSH Behavior

`src/modules/ime.ts` uses a hidden `<textarea id="imeInput">` as the IME capture
surface. The relevant logic:

- **`compositionstart`**: sets `appState.isComposing = true`.
- **`compositionupdate`**: shows the in-progress text in the IME preview strip.
- **`compositionend`**: clears `isComposing`, hides preview, reads `ime.value ||
  e.data`, clears the textarea, and calls `sendSSHInput(text)` immediately.
- **`input`** (non-composing): reads `ime.value`, clears it, and calls
  `sendSSHInput(text)` immediately.

Once `compositionend` fires and the text is forwarded, MobiSSH has no mechanism
to detect or handle a subsequent correction event that would replace that text.
There is no handling for `insertReplacementText`, `deleteWordBackward`, or any
diff-based reconciliation.

## Findings

### Correction Events (Gboard, iOS)

**Gboard (Android Chrome):**

After swipe-typing commits a word via `compositionend`, tapping a different
suggestion in the prediction bar causes the IME to send a `beforeinput` event
with `inputType: "insertReplacementText"`. The `event.data` field contains the
replacement word. `event.getTargetRanges()` returns a `StaticRange` covering the
original word in the textarea.

In some Gboard versions the correction sequence is instead:
1. `beforeinput` with `inputType: "deleteWordBackward"` (removes the committed
   word from the textarea)
2. `beforeinput` with `inputType: "insertText"` (inserts the replacement)

The W3C Input Events spec (Level 2) defines `"insertReplacementText"` as the
canonical type for "modifying all or partial text in an editor" via spell-check
or autocorrect. `"deleteWordBackward"` is defined as "delete a word directly
before the caret position."

CKEditor 5 issue #3131 (2019) documents that `beforeinput` with
`deleteContentBackward` is consistently available on Android 6+ (Chrome 67+),
confirming these events do fire reliably on modern Android.

**iOS Safari:**

iOS Safari fires `beforeinput` with `inputType: "insertReplacementText"` for
autocorrect replacements. The WebKit blog ("Enhanced Editing with Input Events")
explicitly describes `getTargetRanges()` as the mechanism to determine which
text is being replaced. Canceling `beforeinput` prevents the autocorrect.

iOS Safari also fires correction events outside of an active composition session;
the correction happens after `compositionend` has already fired and the text is
visible in the field.

**Key finding:** Both platforms converge on `insertReplacementText` as the
primary correction signal. `deleteWordBackward` is Gboard-specific and less
reliable as a sole signal.

### Voice Dictation Events

**Android Gboard voice (Chrome 65+):**

A 2018 W3C Editing Task Force discussion (Ryan Landay) documents the authoritative
behavior: Gboard opens a composition session for voice input via
`setComposingRegion()`, which now (Chrome 65+) fires `compositionstart` if no
composition is open and `compositionupdate` as interim words arrive. The interim
"composing" text appears underlined (purple on some Android versions). When the
user pauses or taps the checkmark, the session ends with `compositionend`.

The `isComposing` flag on `input` events is `true` during the session, so the
current MobiSSH handler correctly suppresses forwarding interim words to SSH. The
problem is that when voice dictation replaces a word (e.g., re-dictating a phrase),
the subsequent replacement fires as `insertReplacementText` after `compositionend`,
which MobiSSH ignores.

Voice input does *not* use the `SpeechRecognition` Web API internally — it goes
through the standard IME composition path.

**"Purple proposed text" (Android 12+):**

The underlined/colored interim text in newer Gboard is `compositionupdate` data
rendered by the browser's default IME highlight styling. It is not a separate API.
Chrome applies `text-decoration: underline` to the active composition range. This
is standard IME behavior, not a new event type. [INFERRED: exact color and styling
may vary by Android version and theme — not confirmed by source code.]

### CodeMirror 6 Approach

Source: `@codemirror/view` repository, `src/input.ts` and `src/domobserver.ts`.

CodeMirror 6 uses two parallel strategies depending on browser support:

**1. EditContext API mode (modern browsers):**

In `src/input.ts`, the `handlers.beforeinput` function explicitly handles
`insertReplacementText` when `view.observer.editContext` is available:

```typescript
if (event.inputType == "insertReplacementText" && view.observer.editContext) {
  let text = event.dataTransfer?.getData("text/plain"), ranges = event.getTargetRanges()
  if (text && ranges.length) {
    let r = ranges[0]
    let from = view.posAtDOM(r.startContainer, r.startOffset)
    let to = view.posAtDOM(r.endContainer, r.endOffset)
    applyDOMChangeInner(view, {from, to, insert: view.state.toText(text)}, null)
    return true
  }
}
```

It calls `event.getTargetRanges()` to get the `StaticRange` and maps DOM positions
to editor document positions using `view.posAtDOM()`, then applies the replacement
as a transaction. Crucially, the blog post "CodeMirror and Spell Checking: Solved"
(June 2025, chipx86.blog) notes that `getTargetRanges()` can return empty arrays
on some Chrome versions, so defensive empty-check guards are required.

**2. MutationObserver mode (fallback):**

In `src/domobserver.ts`, `processRecords()` aggregates `MutationRecord` objects
into a unified change range. `readChange()` returns a `DOMChange` object. The
`findDiff()` function (from `src/domchange.ts`) computes a minimal diff between
the editor's known content and the new DOM content. This handles corrections even
when `beforeinput` is unavailable or unreliable.

The `compositionend` observer in `src/input.ts` sets `compositionPendingChange =
view.observer.pendingRecords().length > 0` to detect whether mutations are waiting
to be processed, preventing premature state finalization.

**Key insight:** CodeMirror does *not* commit text at `compositionend` and then try
to reverse it. Instead, it defers finalization until after the browser has settled,
using mutation observation as the source of truth.

### ProseMirror/Monaco Approach

**ProseMirror (`prosemirror-view`):**

ProseMirror uses a `MutationObserver` on its content-editable div as the ground
truth for DOM changes. From the `prosemirror-view` CHANGELOG and GitHub issues:

- ProseMirror processes mutations on `compositionend` rather than on every
  `input` event. It reads the actual DOM content after the browser has applied
  IME changes and diffs it against the last known document state.
- It explicitly does *not* intercept `beforeinput` for corrections — it lets the
  browser apply the change to the DOM and then observes the result via
  `MutationObserver`.
- Known Safari-specific issues (#944, #1190) stem from `MutationObserver` firing
  before `compositionend` in Safari, causing ProseMirror to process mutations too
  early. The fix delays processing until after `compositionend`.
- Android Chrome issue #784 documents that `compositionend` can fire after `blur`
  on Android, causing the doc to drift. The mitigation is to flush pending
  mutations on `blur`.

**Monaco Editor:**

Monaco uses a `<textarea>` as its IME capture surface (similar to MobiSSH). It
intercepts `compositionstart`/`compositionend` and also handles `beforeinput`
for `insertReplacementText`. Monaco's `src/vs/editor/browser/controller/editContext/
textArea/textAreaEditContext.ts` contains the textarea-based IME handling. Monaco
tracks the textarea's `value` before and after input events and diffs the content
to determine what changed. [INFERRED: exact function names not confirmed from
direct source read — based on architecture descriptions.]

**Key insight:** Both editors use the post-mutation DOM state or textarea diff as
the source of truth, not the IME event data. This is more robust than forwarding
events directly.

### beforeinput Target Ranges

`InputEvent.getTargetRanges()` returns `StaticRange[]` during the `beforeinput`
event. For `insertReplacementText`, the ranges indicate which text will be replaced.

**Reliability on Android Chrome:**

- Supported in Chrome since the Input Events Level 1 implementation.
- A 2025 bug report (via the CodeMirror spell-checking post) notes that some
  Chrome versions returned empty arrays for `insertReplacementText` target ranges.
  The recommendation is to guard: `if (text && ranges.length) { ... }`.
- Chrome nullifies the ranges *after* event propagation finishes (per w3c/input-events
  issue #114). Ranges must be read synchronously inside the `beforeinput` handler.
- Range containers can be text nodes, parent elements, or the top-level editable
  element — do not assume `startContainer` is a text node.

**Reliability on iOS Safari:**

- Safari supports `getTargetRanges()` (Level 2 partial) and reliably provides
  ranges for `insertReplacementText` events from autocorrect.
- The WebKit blog explicitly cites `getTargetRanges()` as the canonical mechanism
  for determining what autocorrect will replace.

**Conclusion:** `getTargetRanges()` is usable as a signal but requires defensive
coding. For a textarea (vs. contenteditable), the target range maps to
`selectionStart`/`selectionEnd` of the textarea at the time `beforeinput` fires,
which is more straightforward than the DOM range conversion CodeMirror performs.

### SpeechRecognition Web API

`window.SpeechRecognition` (or `window.webkitSpeechRecognition`) is available in:

- **Chrome for Android (PWA):** Fully supported. Triggerable programmatically via
  `.start()` from a button click handler (no keyboard mic icon required).
- **Safari iOS (PWA / home screen):** Broken in PWA/WebView context. Works in
  Safari browser, but not when installed as a home screen PWA. This is a
  known limitation per the search results.

**Interim vs. final results:**

```javascript
const recognition = new webkitSpeechRecognition();
recognition.interimResults = true;  // enables partial results
recognition.onresult = (e) => {
  for (let i = e.resultIndex; i < e.results.length; i++) {
    const text = e.results[i][0].transcript;
    if (e.results[i].isFinal) { /* commit */ }
    else { /* show preview */ }
  }
};
```

Interim results (`isFinal === false`) can be overwritten or removed by subsequent
events. Final results (`isFinal === true`) are stable.

**Chrome 139 on-device mode (August 2025):** Chrome 139 added an optional
on-device speech recognition mode that avoids sending audio to Google servers.
This significantly improves latency and enables offline use. Feature-detected via
standard API; no API surface change.

**Key finding for MobiSSH:** `webkitSpeechRecognition` can support a dedicated
"voice compose" button that shows interim results in the compose field without
sending anything to SSH until the user confirms. This bypasses IME event
unreliability entirely for voice input.

### Textarea Diffing Pattern

The pattern is: maintain a `lastSentValue` variable tracking what text has been
forwarded to SSH. On each `input` event (including those from corrections),
compare `textarea.value` to `lastSentValue`:

```
oldValue = "simulation"   (lastSentValue after compositionend forwarded it)
newValue = "stimulation"  (textarea.value after correction event)

commonPrefixLen = 1       ("s")
charsToDelete = len("imulation") = 9
replacementText = "timulation"

→ send: \x7f * 9 + "timulation"
```

**How editors implement this:**

The diff algorithm finds the longest common prefix between `oldValue` and
`newValue`, then the longest common suffix. Everything in between is the
changed region. The number of backspaces equals `oldValue.length - prefix - suffix`.
The replacement text is `newValue[prefix .. newValue.length - suffix]`.

**Edge cases:**

- **Cursor position:** After a correction, `textarea.selectionStart` may not be
  at the end. The diff should use the full textarea value, not cursor position.
- **Undo:** Browser undo (`Ctrl+Z`) fires `input` with `inputType: "historyUndo"`.
  Diffing handles this correctly since it only cares about the net value change.
- **Selection replacement:** If the user selects text and types, the diff covers
  the deleted selection region. Works correctly with the prefix/suffix algorithm.
- **Simultaneous composition:** Do not run the diff while `isComposing` is true —
  interim composition characters should not be forwarded until `compositionend`.
- **Empty textarea reset:** After forwarding, the current code clears
  `textarea.value = ''`. With diffing, `lastSentValue` should be updated to the
  forwarded value instead of resetting to empty; the textarea value should also
  be cleared after forwarding so the next event starts fresh.

**Limitation:** This pattern works well for single-word corrections. For
voice dictation with long interim transcripts, diffing the full paragraph against
what was sent would generate many backspaces. For voice use, the `SpeechRecognition`
API with explicit send confirmation is a better fit.

## Recommended Approach

### Proven approach (safe to implement)

**1. Handle `insertReplacementText` in `beforeinput`:**

Add a `beforeinput` listener on `#imeInput`. When `inputType === "insertReplacementText"`:
- Read `event.data` (the replacement text).
- Read `event.getTargetRanges()` to get the selection range being replaced.
- Compute the number of backspaces needed: `selectionEnd - selectionStart` of the
  textarea at the time `beforeinput` fires (equivalent to the target range length
  for a textarea).
- Call `sendSSHInput('\x7f'.repeat(n) + replacementText)`.
- Call `event.preventDefault()` to stop the browser from also modifying the textarea.
- Guard: if `ranges.length === 0`, fall through to textarea diffing.

This directly fixes issue #231 for both Gboard and iOS Safari.

**2. Handle `deleteWordBackward` in `beforeinput`:**

When `inputType === "deleteWordBackward"`:
- Compute the word length before the caret using `textarea.value.slice(0, selectionStart)`.
- Send the appropriate number of `\x7f` characters.
- Call `event.preventDefault()`.

This handles the Gboard-specific correction sequence described above.

**3. Textarea diffing as fallback:**

If `beforeinput` target ranges are empty (some Chrome versions) or the event fires
without enough information, add a final `input` event handler that computes
`lastSentValue` vs `textarea.value` using the prefix/suffix diff algorithm above
and sends the corrective backspaces + replacement text.

### Needs device testing before committing [UNVERIFIED]

- Whether Gboard fires `insertReplacementText` or `deleteWordBackward + insertText`
  for swipe corrections on current Android versions (behavior may vary by Gboard
  version). Both should be handled.
- Whether `event.getTargetRanges()` reliably returns non-empty ranges for
  `insertReplacementText` on Android Chrome 120+ (the 2025 CodeMirror fix suggests
  it was unreliable on *some* versions — unclear which ones).
- Whether the `beforeinput` approach or textarea diffing produces more reliable
  results in practice on device.

### Voice input recommendation [SPECULATIVE]

Use `webkitSpeechRecognition` with `interimResults: true` for a dedicated voice
compose button. Show interim text in the compose field without forwarding to SSH.
On `isFinal`, forward the final transcript. This avoids IME event unreliability
entirely. Not viable for iOS PWA (broken in home screen PWA context).

## References

- MDN — InputEvent.inputType: https://developer.mozilla.org/en-US/docs/Web/API/InputEvent/inputType
- MDN — InputEvent.getTargetRanges(): https://developer.mozilla.org/en-US/docs/Web/API/InputEvent/getTargetRanges
- MDN — InputEvent.isComposing: https://developer.mozilla.org/en-US/docs/Web/API/InputEvent/isComposing
- W3C Input Events Level 2 spec: https://w3c.github.io/input-events/
- WebKit blog — Enhanced Editing with Input Events: https://webkit.org/blog/7358/enhanced-editing-with-input-events/
- CodeMirror view/src/input.ts (main): https://github.com/codemirror/view/blob/main/src/input.ts
- CodeMirror view/src/domobserver.ts (main): https://github.com/codemirror/view/blob/main/src/domobserver.ts
- CodeMirror spell checking post (June 2025): https://chipx86.blog/2025/06/26/codemirror-and-spell-checking-solved/
- W3C Editing TF — Gboard composition events (2018): https://lists.w3.org/Archives/Public/public-editing-tf/2018Feb/0000.html
- CKEditor 5 issue #3131 — beforeinput on Android: https://github.com/ckeditor/ckeditor5/issues/3131
- ProseMirror issue #784 — IME sync on Android Chrome: https://github.com/ProseMirror/prosemirror/issues/784
- ProseMirror issue #944 — duplicated chars Safari IME: https://github.com/ProseMirror/prosemirror/issues/944
- w3c/input-events issue #114 — getTargetRanges after propagation: https://github.com/w3c/input-events/issues/114
- MDN — Web Speech API: https://developer.mozilla.org/en-US/docs/Web/API/Web_Speech_API/Using_the_Web_Speech_API
- Chrome 139 on-device speech: https://medium.com/@roman_fedyskyi/on-device-speech-uis-in-chrome-139-4b9f0397b9c9
- Slate.js issue #2062 — Android soft keyboard IME: https://github.com/ianstormtaylor/slate/issues/2062
- w3c/input-events issue #176 — insertCompositionText and isComposing: https://github.com/w3c/input-events/issues/176
