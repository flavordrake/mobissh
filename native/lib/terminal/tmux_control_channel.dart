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

/// Per-session control-mode render + resize adapter. Pure Dart; one instance per
/// hosted session, created when the flag is ON.
class TmuxControlChannel {
  TmuxControlChannel();

  final TmuxControlParser _parser = TmuxControlParser();

  /// Map of paneId → owning windowId, built from `%layout-change` events. Used
  /// to filter `%output %P` to the active window. A pane absent from this map has
  /// an UNKNOWN window and is rendered fail-open (see file header).
  final Map<int, int> _paneWindow = <int, int>{};

  /// The active window id, authoritative from `%session-window-changed`. Null
  /// until the first signal; while null every window's output renders (fail-open
  /// so the first frames before the first active-window notification are shown).
  int? _activeWindowId;

  /// The active window the channel is currently tracking. Exposed for tests +
  /// the host's redraw-on-switch wiring.
  int? get activeWindowId => _activeWindowId;

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
        case SessionWindowChanged():
          // AUTHORITATIVE active window. A real change flips the rendered window
          // and signals the host to force a redraw so the grid repaints.
          if (ev.windowId != _activeWindowId) {
            _activeWindowId = ev.windowId;
            activeChanged = true;
          }
        case PaneOutput():
          if (_shouldRender(ev.paneId)) render.add(ev.data);
        case WindowClose():
          _paneWindow.removeWhere((_, w) => w == ev.windowId);
        case ControlModeExit():
          exited = true;
        default:
          // CommandBegin/End, WindowAdd, renames, session/client notifications,
          // UnhandledNotification, UnknownLine, ControlModeEntered: no render
          // effect here (Part C consumes the window/pane notifications). The
          // parser already updated its own active-window/layout view.
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
