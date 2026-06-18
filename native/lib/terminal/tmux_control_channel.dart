// tmux control-mode (`tmux -CC`) RENDER channel — Part B of the control-mode
// arc (issue #909, epic #906).
//
// This is the session-layer adapter that turns the PURE [TmuxControlParser]
// (Part A, #907) into a live render + resize driver, behind the
// [tmuxControlMode] flag (default OFF). It is deliberately PURE Dart (no Flutter,
// no SSH, no I/O): the task-side session host (`session_host.dart`) owns the SSH
// channel and calls into this adapter:
//
//   - [entryCommand]      — the bytes to write into the freshly-opened shell
//                           stdin to ENTER control mode (`tmux -CC new-session`).
//   - [ingest]            — feed each raw shell-output chunk; returns the
//                           octal-UNESCAPED bytes of the ACTIVE window's panes,
//                           demultiplexed per-pane, ready to write to the grid
//                           EXACTLY as the scrape path's bytes are. The host
//                           forwards them as an `SshOutputEvent` unchanged, so
//                           the UI render path (flterm/ghostty `controller.write`)
//                           is byte-identical and UNTOUCHED.
//   - [resizeCommand]     — translate a (cols, rows) resize into the tmux
//                           `refresh-client -C cols,rows` command line: the
//                           SINGLE resize primitive in control mode. tmux owns
//                           the layout math, so the app grid and tmux size cannot
//                           diverge (the #903/#905 lesson). The host writes these
//                           bytes to the channel instead of a PTY winsize resize.
//
// WHY task-side: keeping ALL control-mode logic in the host's two seams (the
// output listener + the resize handler) plus this one adapter means the UI
// render/gesture path needs ZERO changes — so the flag-OFF path is provably
// unchanged (the host's control-mode branches are simply not taken). It also
// keeps the gesture rewrite (Part C) cleanly separable.
//
// ACTIVE-WINDOW DEMUX (the authoritative active-window contract, epic #906):
//   - `%session-window-changed $S @W` is the AUTHORITATIVE active window. When it
//     fires we switch the rendered window to @W. The host then forces a redraw
//     (a `refresh-client -C` at the current size) so the grid repaints to the new
//     window's content — covered by the host wiring, not this pure adapter.
//   - `%layout-change @W <layout>` carries the pane set for window @W (the
//     cursor-parsed leaf panes). We map paneId → window so a `%output %P` can be
//     filtered to "is %P in the ACTIVE window?". Before any layout for a window
//     is known, we render that window's output anyway (fail-open: never blank the
//     screen because a layout notification was missed / arrived late).
//   - `%output %P <data>` is the ONLY octal-escaped payload; its `data` is
//     already unescaped to real bytes by the parser. We emit it iff %P belongs to
//     the active window (or its window is unknown — fail-open).
//   - `%unlinked-window-close` / `%window-close @W` drop the window's panes from
//     the map so a stale id can't masquerade as active.
//
// Exercised by `test/terminal/tmux_control_channel_test.dart` (fast unit gate)
// and the on-emulator `integration_test/cc_render_test.dart` parity test.

import 'dart:convert';
import 'dart:typed_data';

import 'tmux_control_parser.dart';

/// The result of [TmuxControlChannel.ingest]: the bytes to render now, plus the
/// authoritative active-window signal so the host can force a redraw on switch.
class TmuxIngestResult {
  const TmuxIngestResult({
    required this.renderBytes,
    required this.activeWindowChanged,
    required this.exited,
  });

  /// The octal-UNESCAPED bytes of the ACTIVE window's panes, demultiplexed and
  /// concatenated in arrival order — write these to the grid exactly as the
  /// scrape path's bytes. Empty when this chunk produced no active-window output.
  final Uint8List renderBytes;

  /// True when `%session-window-changed` switched the active window in THIS
  /// chunk. The host responds by forcing a `refresh-client -C` redraw so the
  /// grid repaints to the new window's content (the switch-repaint contract).
  final bool activeWindowChanged;

  /// True when `%exit` was seen — control mode ended (tmux detached / server
  /// died). The host treats this like a shell close.
  final bool exited;
}

/// An ordered tmux window the control channel knows about (Part C, #911). Built
/// from the `%window-add` / `%layout-change` / `%window-renamed` notifications so
/// a status-bar tap can be mapped to a real window WITHOUT pixel guessing. [id]
/// is the STABLE tmux window id (`@N`); [name] is the latest name from
/// `%window-renamed` (null until renamed — diagnostic only).
class TmuxWindow {
  const TmuxWindow({required this.id, this.name});
  final int id;
  final String? name;

  @override
  bool operator ==(Object other) =>
      other is TmuxWindow && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'TmuxWindow(@$id${name == null ? '' : ' "$name"'})';
}

/// Per-session control-mode render + resize adapter. Pure Dart; one instance per
/// hosted session, created when the flag is ON.
class TmuxControlChannel {
  TmuxControlChannel();

  final TmuxControlParser _parser = TmuxControlParser();

  /// Map of paneId → owning windowId, built from `%layout-change` events. Used
  /// to filter `%output %P` to the active window. A pane absent from this map has
  /// an UNKNOWN window and is rendered fail-open (see file header).
  final Map<int, int> _paneWindow = <int, int>{};

  /// Ordered window ids the channel knows about (Part C, #911). Insertion order
  /// matches tmux's window index/status order: tmux assigns indices 0..N in
  /// creation order and renders the status bar left→right in the same order, so
  /// the Nth entry here is the window at status position N. Built from
  /// `%window-add` and (fail-open) the first `%layout-change` for an as-yet-unseen
  /// window; pruned on `%window-close`. This is what lets a status-bar tap map to
  /// a REAL window with no pixel guessing — the wrong-row bug this part dissolves.
  final List<int> _windowOrder = <int>[];

  /// Latest name per window id, from `%window-renamed`. Diagnostic only — the
  /// status-col mapping uses ORDER, not names.
  final Map<int, String> _windowNames = <int, String>{};

  /// The active window id, authoritative from `%session-window-changed`. Null
  /// until the first signal; while null every window's output renders (fail-open
  /// so the first frames before the first active-window notification are shown).
  int? _activeWindowId;

  /// The active window the channel is currently tracking. Exposed for tests +
  /// the host's redraw-on-switch wiring.
  int? get activeWindowId => _activeWindowId;

  /// The ordered windows the channel knows about (Part C, #911), in tmux
  /// index/status order. A snapshot — mutating it does not affect the channel.
  List<TmuxWindow> get windows => List<TmuxWindow>.unmodifiable(
        _windowOrder.map((id) => TmuxWindow(id: id, name: _windowNames[id])),
      );

  /// Record window [id] in creation/status order if not already known. Idempotent.
  void _trackWindow(int id) {
    if (!_windowOrder.contains(id)) _windowOrder.add(id);
  }

  /// The bytes to write into the shell stdin once it opens, to ENTER control
  /// mode. `new-session -A -s mobissh` attaches to an existing `mobissh` session
  /// if present (idempotent across reconnects) or creates it, all under `-CC`.
  /// A trailing newline submits the line to the login shell.
  static Uint8List get entryCommand =>
      Uint8List.fromList(utf8.encode('tmux -CC new-session -A -s mobissh\n'));

  /// Build the `refresh-client -C cols,rows` command line — the SINGLE resize
  /// primitive in control mode (issue #909). The host writes these bytes to the
  /// control channel on a TRAILING-EDGE keyboard-settle (the existing
  /// `GhosttyResizeCoalescer` guarantees the FINAL size is delivered — never
  /// dropped, the #903/#905 lesson). tmux then re-lays-out and pushes a
  /// `%layout-change` + fresh `%output`, so the app grid and tmux size can't
  /// diverge. Non-positive dims are clamped to 1 (tmux rejects 0/negative).
  static Uint8List resizeCommand(int cols, int rows) {
    final c = cols < 1 ? 1 : cols;
    final r = rows < 1 ? 1 : rows;
    return Uint8List.fromList(utf8.encode('refresh-client -C $c,$r\n'));
  }

  /// Frame an arbitrary `-CC` command LINE for ATOMIC delivery (Part C Step 1,
  /// #911). The whole line — however many tokens / spaces — is encoded as ONE
  /// byte buffer terminated with EXACTLY ONE `\n`, so the host writes it in a
  /// single `transport.send` and tmux's control-command parser sees one complete
  /// line. Part B (#909) found that delivering a command through the UI→isolate
  /// `sendInput` keystroke path can FRAGMENT it across the gateway, so a
  /// multi-token command (`select-window -t @1`) split mid-line and the tail hit
  /// the pane shell (`-bash: send-keys: command not found`). Routing every control
  /// command through THIS single-write primitive is the fix. Any trailing
  /// newlines/whitespace the caller passed are trimmed first so exactly one
  /// newline terminates the line (a bare `\n` mid-buffer would submit a partial).
  static Uint8List controlCommand(String line) {
    final trimmed = line.replaceAll(RegExp(r'[\r\n]+$'), '');
    return Uint8List.fromList(utf8.encode('$trimmed\n'));
  }

  /// The `next-window` control-command line (Part C, #911) — a horizontal swipe
  /// RIGHT advances to the next window. No window-list lookup needed; tmux steps
  /// the session's active window itself and pushes `%session-window-changed`.
  static String get nextWindowCommand => 'next-window';

  /// The `previous-window` control-command line (Part C, #911) — a horizontal
  /// swipe LEFT goes to the previous window.
  static String get previousWindowCommand => 'previous-window';

  /// Map a TAP at status-bar column [col] (1-based) over a status line [totalCols]
  /// wide to a `select-window -t @<id>` command for the tapped window, or null if
  /// no window is known yet (Part C, #911). We do NOT guess pixels: tmux renders
  /// the windows left→right in [windows] order, so we partition the status width
  /// into equal segments and pick the window whose segment the tap falls in. The
  /// RESULT is only a best-effort target — the AUTHORITATIVE active window is read
  /// back from `%session-window-changed`, so an off-by-one tap self-corrects on
  /// the next notification (no wrong-row dead-end). Targets the STABLE window id
  /// (`@N`), which `select-window -t` accepts, so it is immune to index renumber.
  String? selectWindowCommandForStatusCol(int col, int totalCols) {
    final idx = windowIndexForStatusCol(col, totalCols);
    if (idx == null) return null;
    return 'select-window -t @${_windowOrder[idx]}';
  }

  /// The 0-based index into [windows] a tap at 1-based [col] over a [totalCols]-
  /// wide status line falls in, or null if no windows are known (Part C, #911).
  /// Equal-width partition of the status line across the ordered windows. Pure +
  /// exposed for unit tests of the mapping in isolation.
  int? windowIndexForStatusCol(int col, int totalCols) {
    final n = _windowOrder.length;
    if (n == 0) return null;
    if (totalCols <= 0) return 0;
    final c = col < 1 ? 1 : (col > totalCols ? totalCols : col);
    // 1-based col → 0-based segment; clamp into range.
    final seg = ((c - 1) * n) ~/ totalCols;
    return seg < 0 ? 0 : (seg >= n ? n - 1 : seg);
  }

  /// Feed a raw shell-output chunk (the `-CC` protocol stream). Returns the
  /// active-window render bytes + the active-window-change / exit signals.
  ///
  /// The chunk is decoded as LATIN-1 (1:1 byte↔code-unit, lossless) so the
  /// line-oriented parser sees the exact bytes; `%output` payloads are then
  /// octal-unescaped by the parser back to real bytes. Never throws — the parser
  /// is resilient and an unknown line becomes an [UnknownLine] (ignored here).
  TmuxIngestResult ingest(Uint8List chunk) {
    final events = _parser.feed(latin1.decode(chunk, allowInvalid: true));
    final render = BytesBuilder(copy: false);
    var activeChanged = false;
    var exited = false;

    for (final ev in events) {
      switch (ev) {
        case LayoutChange():
          // Record which window each leaf pane belongs to so %output can be
          // filtered to the active window.
          for (final p in ev.layout.panes) {
            final id = p.paneId;
            if (id != null) _paneWindow[id] = ev.windowId;
          }
          // #911: fail-open window tracking — a layout for an as-yet-unseen window
          // (e.g. we missed/lagged its %window-add) still registers it so a tap
          // can target it. Insertion order tracks tmux's index/status order.
          _trackWindow(ev.windowId);
        case WindowAdd():
          // #911: a new window enters the status bar (next index/position).
          _trackWindow(ev.windowId);
        case WindowRenamed():
          // #911: track + record the latest name (diagnostic; mapping uses order).
          _trackWindow(ev.windowId);
          _windowNames[ev.windowId] = ev.name;
        case SessionWindowChanged():
          // AUTHORITATIVE active window. A real change flips the rendered window
          // and signals the host to force a redraw so the grid repaints. Also
          // track it (#911) — the active window is necessarily a real window.
          _trackWindow(ev.windowId);
          if (ev.windowId != _activeWindowId) {
            _activeWindowId = ev.windowId;
            activeChanged = true;
          }
        case PaneOutput():
          if (_shouldRender(ev.paneId)) render.add(ev.data);
        case WindowClose():
          _paneWindow.removeWhere((_, w) => w == ev.windowId);
          // #911: drop the closed window from the order + names so a tap can't
          // target a gone window and the status mapping stays correct.
          _windowOrder.remove(ev.windowId);
          _windowNames.remove(ev.windowId);
        case ControlModeExit():
          exited = true;
        default:
          // CommandBegin/End, session/client notifications, UnhandledNotification,
          // UnknownLine, ControlModeEntered: no render or window-tracking effect
          // here. The parser already updated its own active-window/layout view.
          break;
      }
    }

    return TmuxIngestResult(
      renderBytes: render.toBytes(),
      activeWindowChanged: activeChanged,
      exited: exited,
    );
  }

  /// Whether a `%output %paneId` should render: yes when no active window is
  /// known yet (fail-open — show the first frames), when the pane's window is
  /// unknown (a layout we haven't seen — fail-open rather than blank), or when
  /// the pane belongs to the active window.
  bool _shouldRender(int paneId) {
    final active = _activeWindowId;
    if (active == null) return true;
    final w = _paneWindow[paneId];
    if (w == null) return true;
    return w == active;
  }
}
