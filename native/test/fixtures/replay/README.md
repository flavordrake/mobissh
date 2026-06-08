# Replay fixtures — captured terminal traces as regression tests

Two flavors of captured terminal data live here, both replayed into a **real**
flterm `TerminalController` headlessly under `flutter test` (the libghostty VT
parser loads on the host VM via the `ffi` tag, so these run on **every commit** —
no emulator, no SSH, no socket):

| Suffix | Source | Shape | Harness |
|---|---|---|---|
| `*.cast.json` | `scripts/capture-terminal-corpus.sh` (tmux `capture-pane`) | `{cols,rows,chunks:[{b64}]}` — one snapshot | `replay_url_detection_test.dart` (`loadCast`) |
| `*.byte-trace.json` | #790/#793 in-app recorder → server save | `{grid:{cols,rows}, byteTrace:[{tMs,b64}], scrollTrace:[{tMs,offset}], sentSgrTrace?:[…]}` — the raw PTY stream + the user's scroll gestures | `replay_trace_harness.dart` (`loadByteTrace` / `replayTrace`) |

The `.byte-trace.json` flavor is the **bug-report replay harness** (#791): it
reproduces scrollback-render bugs (#789 scroll-stuck, #772 cursor block, #773
delayed paint, outline-drift) deterministically, at the source.

## The loop — a reported repro becomes a permanent regression test

1. **Capture.** On a recorder-enabled build, the owner long-presses Feedback.
   The app uploads the trace; the server saves `${ts}-bug-report.byte-trace.json`
   into `test-results/uploads/`.
2. **Drop.** Copy that file into `native/test/fixtures/replay/` with a descriptive
   name (e.g. `scroll_render_55x28.byte-trace.json`). Do **not** synthesize a
   trace — the whole point is to validate the owner's REAL grid, not a printf
   (`reference_grid_url_extraction` §0; the +22..+28 URL saga is the cautionary
   tale).
3. **Assert.** Add a test that:
   ```dart
   final trace = loadByteTrace('test/fixtures/replay/<name>.byte-trace.json');
   final controller = await replayIntoNewController(trace); // or replayTrace(c, trace)
   addTearDown(controller.dispose);
   // …assert the render-relevant state the bug is about…
   ```
   Tag the test file `@Tags(['ffi'])` so it runs in the fast gate.
4. **Fix at the source, then pin.** Make the bug reproduce (red), fix it in
   flterm / the session layer, confirm green. The replayed trace now pins it
   forever.

## What you can assert (headless tier)

`replayTrace` writes every `byteTrace` chunk through `controller.write` in
timestamp order (LF→CRLF normalized, idempotent), then restores the user's final
`scrollTrace` offset. After it returns, read the **public** render-relevant state:

- **Grid / scroll:** `controller.config` (cols/rows), `controller.scrollbar`
  (`total` / `offset` / `visible`), `controller.scrollbackRows`,
  `controller.totalRows` — the axis #789 scroll-stuck lives on (offset honored,
  not snapped back). NOTE: a repainting full-screen TUI (Claude CLI, vim, htop)
  rewrites the **primary** screen in place and produces **no scrollback**
  (`scrollbackRows == 0`) even for a large trace; a streaming log (`cat`, `yes`)
  is the fixture that exercises the scrollback axis. The first fixture
  (`scroll_render_55x28.byte-trace.json`) is the repainting kind — assert what is
  actually true for the trace at hand.
- **Grid content:** `controller.selectAll(); controller.selectedText()` — proves
  the parser built the captured grid (distinctive tokens survive replay).
- **Soft-wrap:** `controller.viewportRowWraps`.
- **Structured anchors:** `controller.registerTextPattern(...)` then
  `controller.anchors` / `controller.matchAt(...)` / `controller.anchorRects(...)`
  — URL/path placement at the captured scroll offset.

The cursor cell (the #772 lead) lives on libghostty's internal `RenderState`,
**not** the public controller API; assert it via the widget tier below, or via
scroll/scrollback + extracted content here.

`sentSgrTrace` (recorder v2, #793) is parsed when present and ignored when absent
(`BugReportTrace.sentSgrTrace`). This first fixture predates it.

## Widget / emulator tier (STRETCH — follow-up)

Where **pixels** matter (cursor block paint, outline drift, delayed paint), mount
the real Terminal **widget**, replay the byte stream **and** the scroll-gesture
stream from `scrollTrace` / `sentSgrTrace`, then screenshot at the buggy moment
and assert the rendered pixels. The headless tier above does NOT block on this;
it is tracked as a follow-up so the every-commit tier ships first.
