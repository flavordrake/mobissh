import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart' hide Key;
import 'package:libghostty/libghostty.dart' hide Listenable;

import '../foundation.dart';
import 'terminal_controller_impl.dart';

/// Manages a terminal instance and bridges it with [TerminalView].
///
/// Create a controller, wire up [onOutput] to your backend, pass the
/// controller to a [TerminalView], and feed backend data into [write].
/// The controller handles input encoding, selection, focus, and all
/// terminal state.
///
/// Dispose when no longer needed.
///
/// ```dart
/// final controller = TerminalController()
///   ..onOutput = (bytes) => pty.write(bytes)
///   ..onBell = () => playSound()
///   ..onTitleChanged = () => updateTitle(controller.title);
///
/// TerminalView(controller: controller);
///
/// pty.onData = (bytes) => controller.write(bytes);
/// controller.sendText('ls -la\n');
/// ```
abstract class TerminalController extends ChangeNotifier
    implements TerminalRenderObserver {
  /// Called with bytes to send to the backend (PTY, SSH, socket).
  ///
  /// Set this before calling [write]. Fires during [write], [sendKey],
  /// [sendText], and [paste].
  ValueChanged<Uint8List>? onOutput;

  /// Called when the terminal receives a BEL character (0x07).
  VoidCallback? onBell;

  /// Called when the terminal title changes. Read [title] for the value.
  VoidCallback? onTitleChanged;

  /// Called when the grid dimensions change. Forward to your backend.
  OnResize? onResize;

  /// Creates a controller with the given [config].
  ///
  /// The terminal is created immediately with dimensions and scrollback
  /// from [config]. Disposed when the controller is disposed.
  factory TerminalController({TerminalConfig config}) = TerminalControllerImpl;

  @internal
  TerminalController.base();

  /// Active screen buffer (primary or alternate).
  ///
  /// Full-screen programs (vim, less, htop) use the alternate screen.
  /// Scrollback is only available on the primary screen.
  TerminalScreen get activeScreen;

  /// Current terminal configuration.
  TerminalConfig get config;

  /// Replaces the configuration.
  ///
  /// Applies mode and encoder changes without recreating the terminal.
  /// Screen content, scrollback, and cursor position are preserved.
  set config(TerminalConfig config);

  /// Current soft keyboard state.
  KeyboardState get keyboardState;

  /// Current mouse tracking mode requested by the terminal program.
  ///
  /// When active, mouse events are encoded and sent to the program
  /// instead of performing selection. Hold Shift to bypass.
  MouseTracking get mouseTracking;

  /// Working directory reported by the shell (OSC 7). Empty if unset.
  String get pwd;

  /// Number of scrollback rows above the viewport.
  int get scrollbackRows;

  /// Scrollbar state: total rows, visible rows, and current offset.
  Scrollbar get scrollbar;

  @override
  TerminalSelection? get selection;

  /// Sets the text selection.
  set selection(TerminalSelection? value);

  @override
  List<HighlightRange> get highlights;

  /// Sets the structured-text highlight ranges drawn over the grid.
  ///
  /// Additive overlay used for URL / path / regex highlights detected by the
  /// host. Ranges use ABSOLUTE buffer rows (same frame as [selection]) and
  /// are painted with the terminal's real cell metrics, so they pixel-align
  /// to the glyph cells and track scroll, wrap, and resize for free. Pass an
  /// empty list to clear. Does not affect terminal state or selection.
  set highlights(List<HighlightRange> value);

  /// Returns the highlight range covering the viewport cell at ([row], [col]),
  /// or null when no range covers it.
  ///
  /// [row] and [col] are VIEWPORT-relative (row 0 is the top visible row),
  /// matching the coordinates a gesture detector produces from a pointer
  /// position. The controller maps them to the absolute buffer frame via the
  /// PAINTED viewport offset (`absRow = row + paintedViewportOffset`) — the SAME
  /// offset [anchorRects] / the [HighlightPainter] resolve the on-screen rects
  /// against — so the hit-test and the paint geometry stay unified and a tap
  /// never lands a row off the drawn highlight (#863). The returned range's
  /// [HighlightRange.payload] recovers what the cells represent (e.g. the URL
  /// behind a tap). When ranges overlap, the last matching range in
  /// [highlights] wins.
  HighlightRange? highlightAt({required int row, required int col});

  /// Registers a structured-text [pattern] for in-terminal detection (#767).
  ///
  /// The terminal scans its OWN cells (content + authoritative soft-wrap +
  /// wide-char width) for the pattern's regex on a DEBOUNCED tick driven by the
  /// same cell-update cycle that fires [highlights]/notify, and assigns the
  /// resulting [HighlightRange]s (in absolute buffer coords) to [highlights] so
  /// the existing painter draws them — tracking scroll, wrap, resize, and
  /// scrollback eviction for free. Registering a pattern with an [TextPattern.id]
  /// that already exists replaces it. Triggers an immediate re-scan.
  ///
  /// This is the in-fork replacement for app-side detection that re-pushed
  /// highlights on every notify (the #748/#750/#751/#764 drift root cause).
  void registerTextPattern(TextPattern pattern);

  /// Removes all registered structured-text patterns and clears any highlights
  /// they produced (#767). Use this, then [registerTextPattern], to
  /// re-REGISTER detection (a pattern-set / regex / lexicon change). For a
  /// pure STYLE change use [restyleDetectionHighlights] — no rescan.
  void clearTextPatterns();

  /// #1045: per-MATCH style resolver for the detection highlight bake.
  ///
  /// When set, every time detection matches are baked into [highlights] (a
  /// settled re-scan, a prune, or [restyleDetectionHighlights]) each match is
  /// resolved through this callback INSTEAD of its pattern's static
  /// [TextPattern.style]:
  ///   * a [HighlightStyle] styles all the match's ranges (background /
  ///     underline / capsule geometry; capsule caps land on the true
  ///     first/last ranges);
  ///   * null SUPPRESSES the match — it paints NOTHING (the #990/#995
  ///     visibility gates), while [anchors] / [matchAt] still expose it
  ///     (hit-testing and the gutter marks are not the fill's business).
  ///
  /// A static per-pattern style cannot express per-anchor state (the #990
  /// verified alpha, a #995 exception, Detection Lab live-apply) — this seam
  /// resolves ON CHANGE (bake time), never per frame, so the paint path stays
  /// a dumb fill. Null (the default) keeps the pattern-style bake.
  HighlightStyle? Function(StructuredMatch match)? get detectionHighlightStyleOf;
  set detectionHighlightStyleOf(
      HighlightStyle? Function(StructuredMatch match)? value);

  /// #1045: re-bake [highlights] from the CURRENT detection matches through
  /// [detectionHighlightStyleOf] — no rescan, no debounce. Call when app-side
  /// style state changes out-of-band (a path verification lands, a Detection
  /// Lab style is tuned, an exception is filed/removed). A no-op (no listener
  /// churn) when the resulting ranges are unchanged, so callers may invoke it
  /// opportunistically (e.g. on every build).
  void restyleDetectionHighlights();

  /// #1044: monotonic counters over the detection scan/prune hot path — scan
  /// invocations, rows read, µs, cache hits, prune re-validations, identity
  /// reuse. The replay perf suite asserts on these ("pure scroll = 0 scans")
  /// and bug-report telemetry snapshots them. Counters only; resetting is the
  /// caller's business (tests bracket a measured phase with `reset()`).
  DetectionScanStats get detectionScanStats;

  /// Returns the structured-text match covering the VIEWPORT cell at
  /// ([row], [col]), or null when none covers it (#767).
  ///
  /// [row]/[col] are VIEWPORT-relative (row 0 is the top visible row); the
  /// controller maps them to the absolute buffer frame via the PAINTED viewport
  /// offset (`absRow = row + paintedViewportOffset`) — the SAME offset the URL
  /// bubble's paint geometry uses ([anchorRects] / [AnchorGeometry.rectsFor]:
  /// `viewRow = absRow - paintedViewportOffset`) — and snaps [col] to a
  /// wide-character boundary before hit-testing. Using the painted offset (not
  /// the live `scrollbar.offset`, which can lead the painted glyphs by a frame
  /// during a tmux-redraw scroll, #803) keeps the tappable cell unified with the
  /// drawn bubble, so a tap anywhere on a painted URL (incl. a `:port` URL or a
  /// wrapped multi-row URL) resolves to its match instead of landing a row off
  /// (#863). The returned [StructuredMatch.payload] recovers what the cells
  /// represent (e.g. the URL behind a tap/long-press).
  ///
  /// TIER preference (#998 slice A): when the cell is covered by both a
  /// SPAN-tier match (url/path/OSC-8) and a BLOCK-tier match containing it (a
  /// command line, #998 B), the SPAN match wins — an inline tap never routes
  /// to the containing block. Pass [tier] to scope the query to one tier (e.g.
  /// `tier: TextTier.block` resolves the containing command at a cell whose
  /// default answer is the inner URL); null on a scoped query means no match
  /// of that tier covers the cell. WITHIN a tier, overlapping matches keep
  /// today's rule: the last detected one wins.
  StructuredMatch? matchAt({required int row, required int col, TextTier? tier});

  /// The current detected structured-text ANCHORS (#767 Slice B).
  ///
  /// One [StructuredAnchor] per match the last cell re-scan produced, in
  /// detection order, each carrying its [TextPattern.id], opaque payload, and
  /// per-row absolute-coordinate [HighlightRange]s. The fork OWNS the persistent
  /// cell-sequence anchoring (re-scan re-anchors across scroll/wrap/resize/
  /// eviction); this getter EXPOSES the anchors so the WIDGET layer can inject
  /// its own per-pattern decorators (a URL bubble/chip, a future path/commit-sha
  /// treatment) instead of every pattern being forced through the one built-in
  /// [highlights] paint pass. Empty when nothing is detected.
  List<StructuredAnchor> get anchors;

  /// Resolves a [HighlightRange] to its CURRENT viewport pixel rects (#767 B).
  ///
  /// Given one of an anchor's per-row [HighlightRange]s (absolute buffer coords),
  /// returns the logical-pixel [Rect]s — one per VISIBLE row segment, hugging the
  /// matched cells — in the grid's padded local space (the [TerminalView]'s
  /// padding offset is already applied), using the live [CellMetrics] and the
  /// current viewport scroll offset. Rows scrolled out of view contribute no
  /// rect, so a fully off-screen range returns an EMPTY list. Recomputes from the
  /// live offset/metrics every call, so a decorator built over these rects tracks
  /// scroll/wrap/resize/eviction with NO re-detection ("without constant
  /// maintenance"). Empty when the grid is not laid out yet.
  List<Rect> anchorRects(HighlightRange range);

  /// The viewport offset the render box LAST PAINTED the text with (#803).
  ///
  /// Mirrors the `viewportOffset` the fork's [HighlightPainter] reads from the
  /// frame snapshot — the offset of the glyphs currently on screen, NOT the live
  /// `scrollbar.offset` (which may already point at a frame not yet painted
  /// during a tmux-redraw scroll). The render box reports it each frame via
  /// [reportPaintedViewportOffset]; the controller notifies listeners post-frame
  /// when it changes. [anchorRects] resolves against THIS by default so a
  /// widget-layer decorator's geometry stays in lockstep with the painted text.
  /// Defaults to 0 before the first paint.
  int get paintedViewportOffset;

  /// Whether the PAINTED viewport offset is actively CHANGING — a scroll, including
  /// a tmux-redraw "scroll" where the remote rewrites the grid (#812).
  ///
  /// True from the moment the painted offset moves until it has held still for a
  /// short trailing debounce (~140ms). A widget-layer decorator HIDES while this is
  /// true and SHOWS once it settles, so the decorator never draws during the moment
  /// it cannot reliably track the offset — the robust fix for the off-by-line drift
  /// the during-scroll position chase (#784/#803/#807) kept reintroducing. Tap-to-
  /// copy is UNAFFECTED: [matchAt] / [anchors] are independent of the draw, so a
  /// link stays tappable throughout a scroll even while its bubble is hidden.
  /// Defaults to false before the first paint (a static screen draws normally).
  ///
  /// #1044: also gates the detection RESCAN — a scan that fires mid-scroll is
  /// deferred to the settle edge instead of competing with fling frames.
  @override
  bool get isScrolling;

  /// A [Listenable] that fires ONLY when the inputs a widget-layer decorator
  /// reads have changed (#805): the detected [anchors] set, or the
  /// [paintedViewportOffset] the decorator resolves [anchorRects] against.
  ///
  /// The controller itself ([this] as a `ChangeNotifier`) notifies on EVERY
  /// terminal change — cursor blink, mouse-mode toggle, output write, scroll —
  /// roughly 15×/sec while a full-repaint TUI streams a scroll. A decorator
  /// layer listening to the controller rebuilds (re-resolves every anchor's
  /// rects) on all of those, even when nothing it draws changed. Listening to
  /// THIS narrower notifier instead coalesces the decorator's per-redraw work
  /// onto only the frames where the decoration geometry actually moves — the
  /// detection re-scan settles (debounced) or the painted offset advances — so a
  /// streaming scroll stops re-resolving the markup on every redraw chunk. The
  /// final, settled decoration is identical; only the redundant mid-fling
  /// rebuilds are dropped.
  Listenable get decorationListenable;

  /// The VIEWPORT row index a gutter decorator for [range] should mark, or null
  /// when the range is fully off-screen (#767 Slice B, #955).
  ///
  /// The top visible row the range occupies (its first row still inside the
  /// viewport), resolved against the PAINTED viewport offset so the gutter mark
  /// stays in lockstep with the painted rows (#955; the same frame snapshot
  /// [anchorRects]/[matchAt] use, never a frame ahead during a tmux-redraw
  /// scroll). The `GhosttyGutterLayer` reads this to place a right-edge margin
  /// mark beside each matched line.
  int? anchorGutterRow(HighlightRange range);

  /// #958: the top visible row expressed in the SCREEN coordinate space that
  /// detection anchors / selections use (`PointTag.screen`, row 0 = the oldest
  /// PRIMARY-screen scrollback line; the ALTERNATE screen's rows sit AFTER that
  /// history).
  ///
  /// On the primary screen this is the painted viewport offset (frame-synced
  /// scrollback offset). On the alternate screen the scrollbar/painted offsets
  /// are ALT-LOCAL (always 0 — no scrollback), while the alt viewport actually
  /// starts at `scrollbackRows` in screen space — so this is the history length
  /// there. Convert `viewportRow = screenRow - screenViewportTop` (and back)
  /// with THIS, never with `scrollbar.offset`, or every anchor resolves
  /// off-screen on a tmux screen (the #958 no-marks / dead-long-press class).
  int get screenViewportTop;

  /// The AUTHORITATIVE per-visible-row soft-wrap flags for the active screen.
  ///
  /// Element `[r]` is `true` iff visible row `r` is soft-wrapped onto row
  /// `r + 1` (a long logical line continued with no break character), as
  /// reported by libghostty's `rowGetWrap` — the same source the selection
  /// logic walks for logical-line boundaries. The list length equals the
  /// viewport row count; the last element is always `false` (no row below to
  /// wrap into).
  ///
  /// Callers pair this with the per-row text from
  /// `createFormatter(unwrap: false)` to join soft-wrapped rows EXACTLY (no
  /// width/trailing-pad guessing): join row `r` into `r + 1` iff
  /// `viewportRowWraps[r]` is true. Used by the URL detector (#764) so a
  /// wrapped URL spans precisely its rows and adjacent URLs never bleed.
  List<bool> get viewportRowWraps;

  /// Terminal title set by the running program.
  String get title;

  /// Total rows: viewport plus scrollback.
  int get totalRows;

  /// Virtual modifier keys for on-screen keyboard UIs.
  ///
  /// Merged with physical modifiers when encoding input. Cleared
  /// automatically after [sendKey] or [sendText] produces output.
  ///
  /// ```dart
  /// controller.toggleMod(const Mods.ctrl());
  /// controller.sendKey(Key.c); // Sends Ctrl+C, clears the mod.
  /// ```
  Mods get virtualMods;

  /// Clears scrollback and sends a form feed via [onOutput].
  ///
  /// No-op on the alternate screen.
  void clear();

  /// Clears the current selection.
  void clearSelection();

  /// Clears all virtual modifiers.
  void clearVirtualMods();

  /// Creates a [Formatter] for extracting terminal content.
  ///
  /// Supports plain text, HTML, and VT sequence output via [format].
  /// Set [unwrap] to join soft-wrapped lines, [trim] to strip trailing
  /// whitespace.
  Formatter createFormatter({
    required FormatterFormat format,
    bool unwrap = false,
    bool trim = false,
    FormatterExtra extra = const FormatterExtra(),
  });

  /// Hides the soft keyboard and keeps it hidden.
  ///
  /// Stays hidden until [showKeyboard] is called. Focus changes alone
  /// will not re-show it.
  void disableKeyboard();

  /// Hides the soft keyboard. Re-shows on next focus gain.
  void hideKeyboard();

  /// Returns the live value of a terminal [mode].
  ///
  /// May differ from [config] if the running program changed it.
  bool modeGet(TerminalMode mode);

  /// Sets a terminal [mode] at runtime.
  ///
  /// Not persisted in [config]. May be overwritten when the terminal
  /// restores modes (e.g. exiting the alternate screen).
  void modeSet(TerminalMode mode, {required bool value});

  /// Sends paste data to the terminal via [onOutput].
  ///
  /// Wraps the text in bracketed paste sequences when the terminal
  /// has bracketed paste mode enabled. Scrolls to bottom based on
  /// [TerminalConfig.scrollToBottom] policy.
  void paste(String text);

  /// Requests keyboard focus for the attached [TerminalView].
  void requestFocus();

  /// Scrolls the viewport to the bottom (most recent content).
  void scrollToBottom();

  /// Scrolls the viewport to the top of the scrollback history.
  void scrollToTop();

  /// Selects all terminal content including scrollback.
  void selectAll();

  /// Returns the text within the current [selection], or empty string
  /// when there is no selection.
  ///
  /// [format] controls the output encoding:
  /// - [FormatterFormat.plain]: unstyled text, suitable for the clipboard
  ///   (default).
  /// - [FormatterFormat.vt]: VT escape sequences preserving colors, styles,
  ///   and hyperlinks.
  /// - [FormatterFormat.html]: HTML with inline styles.
  ///
  /// In normal selection mode, soft-wrapped lines are joined into a single
  /// line without an inserted newline. In block mode, every row is kept
  /// separate regardless of wrapping.
  String selectedText({FormatterFormat format = .plain});

  /// Extracts full-width plain text of ABSOLUTE (top-anchored, row 0 = oldest)
  /// buffer rows [topRowAbs]..[bottomRowAbs] inclusive, independently of the
  /// live [selection] — so it paints nothing. Soft-wrapped runs are joined
  /// (line granularity). Out-of-range rows clamp; an inverted range normalises.
  /// Used by the paint-free gutter line-copy (#962) + its offset telemetry.
  String textForRows(
    int topRowAbs,
    int bottomRowAbs, {
    FormatterFormat format = .plain,
  });

  /// Reads the VISIBLE viewport rows [topViewRow]..[bottomViewRow] inclusive
  /// VERBATIM (row 0 = the top visible row), independently of selection,
  /// scrollback offset, or paint timing — via `PointTag.viewport`, which is
  /// what's on screen RIGHT NOW. Trailing blanks per row are trimmed; rows are
  /// joined with '\n'. This is the "copy exactly the visible lines I dragged
  /// over" path (#962) — no absolute-row / offset machinery.
  String visibleRowsText(int topViewRow, int bottomViewRow);

  /// Encodes a key press and sends it via [onOutput].
  ///
  /// [mods] are merged with [virtualMods]. Virtual modifiers are cleared
  /// after output is produced.
  void sendKey(Key key, {Mods mods = const Mods.none()});

  /// Sends literal UTF-8 text via [onOutput].
  ///
  /// No key encoding is applied. Use [sendKey] for individual key
  /// presses that need proper escape sequence encoding.
  void sendText(String text);

  /// Shows the soft keyboard and re-enables it if disabled.
  void showKeyboard();

  /// Toggles a virtual modifier on or off.
  void toggleMod(Mods mod);

  /// Removes keyboard focus from the attached [TerminalView].
  void unfocus();

  /// Feeds raw bytes from the backend into the terminal.
  ///
  /// Call this with data received from your PTY, SSH channel, or socket.
  /// The terminal processes the bytes and may call [onOutput] with
  /// response data (e.g. for device attribute queries).
  void write(Uint8List data);
}
