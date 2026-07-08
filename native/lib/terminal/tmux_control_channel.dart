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

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'tmux_control_parser.dart';

/// The kind of an outstanding `-CC` control command whose `%begin…%end` response
/// block the channel is waiting on (#906 Stage 1). tmux emits exactly ONE
/// command-output block per client command, IN ORDER, so the channel keeps a
/// FIFO of the kinds it has sent and pops the front on each block: a
/// [_PendingKind.capture] block carries pane content to RENDER; anything else
/// ([_PendingKind.other] — resize, gesture, control) is a plain ack we discard.
/// This is exactly how iTerm2 correlates responses (a queue popped per block),
/// not a guess at tmux's opaque command number.
enum _PendingKind { capture, other }

/// The result of [TmuxControlChannel.ingest]: the bytes to render now, plus the
/// authoritative active-window signal so the host can force a redraw on switch.
class TmuxIngestResult {
  const TmuxIngestResult({
    required this.renderBytes,
    required this.activeWindowChanged,
    required this.exited,
    this.captureRequested = false,
    this.handshakeConfirmed = false,
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

  /// True when this chunk warrants a `capture-pane` request — an ATTACH
  /// (`%session-changed`) or an active-window SWITCH (`%session-window-changed`)
  /// (#906 Stage 1). Real `-CC` clients (iTerm2) render the pane by REQUESTING
  /// `capture-pane` and drawing the response themselves; `tmux -CC attach` pushes
  /// NO initial screen (only `%session-changed`) and a switched-to idle window
  /// emits no `%output`, so without this the grid stays blank/stale. The host
  /// responds by sending [TmuxControlChannel.frameCapture]; the correlated
  /// `%begin…%end` response is rendered (clear + write) back through [ingest].
  final bool captureRequested;

  /// True on the FIRST chunk in which tmux's `-CC` handshake was confirmed — the
  /// `\x1bP1000p` DCS that ONLY a real control-mode session emits (#982). Until
  /// this fires the host must NOT write ANY `-CC` command (refresh-client /
  /// capture / control): in a NESTED tmux `tmux -CC attach` fails, the DCS never
  /// arrives, and any command written into the plain/nested pane LEAKS as literal
  /// text (the owner's brick). The entry command is the only pre-handshake write.
  final bool handshakeConfirmed;
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

  /// FIFO of the outstanding client commands' kinds (#906 Stage 1). Every
  /// command the host writes to the `-CC` channel is FIRST registered here (via
  /// [frameCapture]/[frameCaptureRange]/[frameResize]/[frameControl], in send
  /// order); each `%begin…%end` block pops the front and — iff it was a
  /// [_PendingKind.capture] — renders the captured pane. A block that arrives
  /// with an EMPTY queue is tmux's startup block (or a stray) → ignored. This is
  /// the order-based correlation real `-CC` clients use.
  final Queue<_PendingKind> _pending = Queue<_PendingKind>();

  /// The number of outstanding (un-answered) command blocks. Exposed for unit
  /// tests of the block-correlation FIFO.
  int get pendingCommandCount => _pending.length;

  /// Lines the scrollback view is offset ABOVE the live bottom (#906 Stage 2).
  /// 0 = live (following `%output`); >0 = showing captured history that many
  /// lines back. Only [frameScroll] mutates it; a window switch resets it.
  int _scrollOffset = 0;
  int get scrollOffset => _scrollOffset;

  /// Whether the grid is currently showing a scrolled-back HISTORY view (#906
  /// Stage 2). While true, live `%output` is NOT rendered (it would clobber the
  /// history window at the bottom, like copy-mode freezing the view); rendering
  /// resumes — with a fresh live capture — when the user scrolls back to bottom.
  bool get scrolledBack => _scrollOffset > 0;

  /// An incomplete trailing UTF-8 sequence carried between [ingest] calls (#982).
  /// tmux can split a multi-byte UTF-8 char across two `%output` events (and thus
  /// two SSH chunks / two [ingest] calls); each renderBytes chunk is decoded
  /// INDEPENDENTLY UI-side (`utf8.decode` per SshOutputEvent), so a chunk that
  /// ENDS mid-char corrupts to `â??`. We hold the incomplete tail here and prepend
  /// it to the next chunk so every emitted renderBytes ends on a UTF-8 boundary.
  List<int> _utf8Carry = const <int>[];

  /// Whether tmux's `-CC` handshake (the `\x1bP1000p` DCS) has been observed on
  /// this channel yet (#982). The host gates every `-CC` write on this.
  bool _handshakeConfirmed = false;
  bool get handshakeConfirmed => _handshakeConfirmed;

  /// Hard cap on how far back a swipe can scroll (#906 Stage 2). tmux clamps to
  /// the real history itself (a too-old `-S` just returns the oldest lines), so
  /// this only bounds the offset integer from running away on a long fling.
  static const int _maxScrollOffset = 100000;

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
  /// mode. ATTACH the owner's EXISTING (most-recent) session — the SAME one they
  /// attach on their laptop (`tmux attach`) — so a persistent session follows
  /// them across mobile↔laptop moves and control mode operates on the windows
  /// they actually have. Falls back to creating/attaching `main` ONLY when no
  /// server/session exists yet (first ever connect); stderr is dropped so the
  /// "no server running" message never reaches the `-CC` stdout parser. This
  /// replaces the old `new-session -A -s mobissh`, which forced a SEPARATE empty
  /// session → the device "zero gestures" (nothing to switch, not your windows).
  /// A trailing newline submits the line to the login shell. (#906)
  static Uint8List get entryCommand => Uint8List.fromList(
    utf8.encode('tmux -CC attach 2>/dev/null || tmux -CC new-session -A -s main\n'),
  );

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

  /// The `capture-pane -p -e -J` command line (#906 Stage 1) — dump the ACTIVE
  /// pane's VISIBLE screen with escape sequences (`-e`, colours) and wrapped
  /// lines joined (`-J`), to stdout (`-p`) as the command's `%begin…%end`
  /// response. No `-t` target: `-CC`'s current pane IS the attached session's
  /// active pane (and follows `select-window`), so this always captures what the
  /// user is looking at. This is what real `-CC` clients request to paint the
  /// screen tmux does NOT push on attach.
  static Uint8List capturePaneCommand() =>
      controlCommand('capture-pane -p -e -J');

  /// The `capture-pane -p -e -S <start> -E <end>` command line (#906 Stage 2) —
  /// a WINDOW into the active pane's history, from line [start] to [end]
  /// (tmux line numbers: 0 is the top visible row, NEGATIVE indices reach into
  /// scrollback, so a start of `-40` is 40 lines back). Renders the scrollback
  /// view the local grid can't (control mode gets no `%output` for copy-mode
  /// scroll).
  static Uint8List capturePaneRangeCommand(int start, int end) =>
      controlCommand('capture-pane -p -e -S $start -E $end');

  /// Register + frame a `capture-pane` request (#906 Stage 1). Pushes a
  /// [_PendingKind.capture] so the correlated response block renders, and returns
  /// the bytes for the host to write. The host MUST send framed commands in the
  /// order it frames them so the FIFO stays aligned with tmux's block order.
  Uint8List frameCapture() {
    _pending.add(_PendingKind.capture);
    return capturePaneCommand();
  }

  /// Register + frame a scrollback `capture-pane -S -E` request (#906 Stage 2).
  Uint8List frameCaptureRange(int start, int end) {
    _pending.add(_PendingKind.capture);
    return capturePaneRangeCommand(start, end);
  }

  /// Register + frame a `refresh-client -C` resize (#906 Stage 1). Its response
  /// block is a plain ack ([_PendingKind.other]) — registered so it can't be
  /// mistaken for a capture response and consume a real capture out of order.
  Uint8List frameResize(int cols, int rows) {
    _pending.add(_PendingKind.other);
    return resizeCommand(cols, rows);
  }

  /// Register + frame an arbitrary control command line (gesture / select-window
  /// / user command, #906 Stage 1). Its response block is a plain ack.
  Uint8List frameControl(String line) {
    _pending.add(_PendingKind.other);
    return controlCommand(line);
  }

  /// Advance the scrollback view by [deltaLines] and frame the `capture-pane`
  /// that renders it (#906 Stage 2). [deltaLines] > 0 scrolls BACK into history
  /// (older; a downward swipe); < 0 scrolls toward live. [rows] is the current
  /// viewport height so the captured window is exactly one screen tall.
  ///
  /// At offset 0 (scrolled back to the bottom) this captures the LIVE visible
  /// screen (`capture-pane -p -e -J`) so the current state repaints and `%output`
  /// rendering resumes; otherwise it captures the `rows`-tall history window
  /// ending [scrollOffset] lines above the bottom (`-S -offset -E -offset+rows-1`,
  /// tmux line numbers: 0 = top of the visible screen, negatives reach history).
  /// Always registers a capture block so the correlated response renders.
  Uint8List frameScroll(int deltaLines, int rows) {
    final r = rows < 1 ? 1 : rows;
    _scrollOffset = (_scrollOffset + deltaLines).clamp(0, _maxScrollOffset);
    _pending.add(_PendingKind.capture);
    if (_scrollOffset == 0) {
      // Snapped to live — repaint the current visible screen; %output resumes.
      return capturePaneCommand();
    }
    final start = -_scrollOffset;
    final end = start + r - 1;
    return capturePaneRangeCommand(start, end);
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
    var captureRequested = false;
    var handshakeConfirmed = false;

    for (final ev in events) {
      switch (ev) {
        case ControlModeEntered():
          // #982: the `\x1bP1000p` DCS — proof a real `-CC` session opened. Only
          // now may the host write `-CC` commands (refresh-client / capture /
          // control); before this a nested/plain shell would echo them as text.
          if (!_handshakeConfirmed) {
            _handshakeConfirmed = true;
            handshakeConfirmed = true;
          }
        case CommandEnd():
          // #906 Stage 1: a command-output block completed. Correlate it to the
          // client command that produced it by FIFO order (tmux emits exactly one
          // block per command, in order). A capture block carries the pane content
          // to RENDER (clear + write); any other ack is discarded. An EMPTY queue
          // means this is tmux's startup block (or a stray) → ignore.
          if (_pending.isNotEmpty) {
            final kind = _pending.removeFirst();
            if (kind == _PendingKind.capture && !ev.isError) {
              render.add(_renderCapture(ev.response));
            }
          }
        case SessionChanged():
          // #906 Stage 1: ATTACH or a session SWITCH. tmux pushes no screen on
          // `-CC attach` (or when the client moves to another session), so ask
          // for one — the host sends `capture-pane` and the response renders.
          // #4 (owner: "a tmux session that started after connect doesn't respond
          // to gestures — when does control mode wire up?"): RESET the window/pane
          // maps here. They belong to the OUTGOING session; the incoming session
          // re-emits its own `%window-add`/`%layout-change`/`%session-window-
          // changed`, which repopulate them, so a status-bar tap maps to the NEW
          // session's windows instead of the stale old ones (a tap was silently
          // targeting a window that no longer exists). Drop the active window +
          // any scrollback view too so the new session starts clean at its live
          // bottom.
          _windowOrder.clear();
          _paneWindow.clear();
          _windowNames.clear();
          _activeWindowId = null;
          _scrollOffset = 0;
          _utf8Carry = const <int>[]; // #982: drop any partial char from the old session.
          captureRequested = true;
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
            // #906 Stage 1: the switched-to window may be IDLE (no `%output`), so
            // capture its screen to repaint — the same request iTerm2 makes on a
            // window switch.
            captureRequested = true;
            // #906 Stage 2: a switch lands at the new window's LIVE bottom.
            _scrollOffset = 0;
          }
        case PaneOutput():
          // #906 Stage 2: while showing a scrolled-back history view, freeze the
          // live view — dropping `%output` keeps the history window from being
          // clobbered at the bottom (copy-mode semantics). Snapping to live
          // re-captures + resumes.
          if (!scrolledBack && _shouldRender(ev.paneId)) render.add(ev.data);
        case WindowClose():
          _paneWindow.removeWhere((_, w) => w == ev.windowId);
          // #911: drop the closed window from the order + names so a tap can't
          // target a gone window and the status mapping stays correct.
          _windowOrder.remove(ev.windowId);
          _windowNames.remove(ev.windowId);
        case ControlModeExit():
          exited = true;
        default:
          // CommandBegin, client notifications, UnhandledNotification,
          // UnknownLine: no render or window-tracking effect here. The parser
          // already updated its own active-window/layout view.
          break;
      }
    }

    return TmuxIngestResult(
      renderBytes: _emitOnUtf8Boundary(render.toBytes()),
      activeWindowChanged: activeChanged,
      exited: exited,
      captureRequested: captureRequested,
      handshakeConfirmed: handshakeConfirmed,
    );
  }

  /// Prepend any carried partial UTF-8 sequence to [bytes], then split off a NEW
  /// incomplete trailing sequence to carry to the next chunk, so the returned
  /// bytes always end on a UTF-8 char boundary (#982). This stops a multi-byte
  /// char that tmux split across two `%output` chunks from being decoded as two
  /// malformed halves UI-side (`utf8.decode` runs per SshOutputEvent).
  Uint8List _emitOnUtf8Boundary(Uint8List bytes) {
    if (_utf8Carry.isEmpty && bytes.isEmpty) return bytes;
    final Uint8List combined;
    if (_utf8Carry.isEmpty) {
      combined = bytes;
    } else {
      combined = Uint8List(_utf8Carry.length + bytes.length)
        ..setRange(0, _utf8Carry.length, _utf8Carry)
        ..setRange(_utf8Carry.length, _utf8Carry.length + bytes.length, bytes);
      _utf8Carry = const <int>[];
    }
    final hold = _incompleteUtf8TailLength(combined);
    if (hold == 0) return combined;
    final cut = combined.length - hold;
    _utf8Carry = combined.sublist(cut);
    return Uint8List.sublistView(combined, 0, cut);
  }

  /// The number of trailing bytes of [b] that form an INCOMPLETE UTF-8 sequence
  /// (a lead byte whose continuation bytes have not all arrived yet), or 0 when
  /// the buffer ends on a complete char / ASCII / an undecodable byte (#982).
  /// UTF-8 chars are at most 4 bytes, so scanning back at most 3 bytes for the
  /// lead byte is sufficient.
  static int _incompleteUtf8TailLength(Uint8List b) {
    final n = b.length;
    for (var back = 1; back <= 3 && back <= n; back++) {
      final c = b[n - back];
      if (c < 0x80) return 0; // ASCII byte — complete.
      if ((c & 0xc0) == 0x80) continue; // continuation — keep seeking the lead.
      final int need; // this is the lead byte; how many bytes the char needs.
      if ((c & 0xe0) == 0xc0) {
        need = 2;
      } else if ((c & 0xf0) == 0xe0) {
        need = 3;
      } else if ((c & 0xf8) == 0xf0) {
        need = 4;
      } else {
        return 0; // invalid lead — let allowMalformed handle it, don't stall.
      }
      return back < need ? back : 0; // hold only if not all bytes are present.
    }
    return 0;
  }

  /// Turn a `capture-pane` response (the visible pane rows, verbatim with SGR
  /// from `-e`) into the bytes that repaint the grid (#906 Stage 1): reset
  /// attributes, clear the whole screen + scrollback, home the cursor, then write
  /// the rows joined by CRLF. `\x1b[3J` clears flterm's scrollback too so a
  /// re-capture (window switch / Stage-2 scroll snap-back) can't leave stale rows
  /// above. The response strings are LATIN-1 code units (the channel decodes the
  /// stream 1:1), so each maps back to one byte.
  static Uint8List _renderCapture(List<String> lines) {
    final sb = StringBuffer('\x1b[m\x1b[3J\x1b[2J\x1b[H');
    sb.write(lines.join('\r\n'));
    final s = sb.toString();
    final out = Uint8List(s.length);
    for (var i = 0; i < s.length; i++) {
      out[i] = s.codeUnitAt(i) & 0xff;
    }
    return out;
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

/// The trailing-edge settle window that coalesces a BURST of control-mode
/// RESIZE `refresh-client -C` writes into ONE final-size write (#916). On a real
/// multi-client host a resize can fire many times in quick succession (the
/// multi-client size clamp makes tmux re-lay-out + push `%layout-change`, which
/// re-fires our resize → a feedback STORM, the `58,57 ↔ 58,34` alternation the
/// owner saw). This settle outlasts that churn so a burst of differing sizes
/// collapses to one write at the size things settled at. Matches
/// `kGhosttyResizeSettle` (the PTY path's keyboard-settle, #903) so control mode
/// is tamed the SAME way the scrape path was — the very thing #903/#905 fixed,
/// now applied to refresh-client.
///
/// NOTE (#916 regression fix): the active-window-SWITCH repaint does NOT go
/// through this coalescer. A switch must repaint PROMPTLY and re-emits
/// `refresh-client -C` at the SAME dims, which this coalescer's same-size dedup
/// (and 250ms settle) would swallow — blanking the new window. The host writes
/// the switch redraw DIRECTLY (see `session_host.dart`'s `activeWindowChanged`
/// branch). This coalescer is therefore dedicated to RESIZE only.
const Duration kRefreshClientSettle = Duration(milliseconds: 250);

/// Per-session coalescer for control-mode `refresh-client -C` writes (#916).
///
/// PURE Dart, mirrors `GhosttyResizeCoalescer` (the PTY-path coalescer) so the
/// control-mode resize primitive gets the IDENTICAL trailing-edge-settle taming:
/// [submit] each desired (cols, rows); once the size has been STABLE for [settle]
/// the coalescer invokes [onSettled] ONCE with the FINAL size (never dropped —
/// the #903/#905 lesson). Intermediate sizes in a burst never reach [onSettled].
/// A size equal to the last EMITTED one is dropped (dedup) — correct for resize.
/// [cancel] drops a pending write on shell drop / reconnect so a dead channel
/// never storms.
///
/// This coalescer is RESIZE-ONLY (#916 regression fix): the active-window-switch
/// repaint is written DIRECTLY by the host (it re-emits at the SAME dims, which
/// the dedup here would swallow). [requestRedraw] — a same-size forced emit —
/// remains as a tested capability but is NOT on the switch path anymore.
class RefreshClientCoalescer {
  RefreshClientCoalescer({
    required this.onSettled,
    this.settle = kRefreshClientSettle,
    Timer Function(Duration, void Function())? scheduleTimer,
  }) : _scheduleTimer = scheduleTimer ?? Timer.new;

  /// Called with the FINAL settled (cols, rows) once the size stops changing for
  /// [settle]. In the host this writes `refresh-client -C cols,rows` to the shell.
  final void Function(int cols, int rows) onSettled;

  /// The settle window the size must stay stable for before [onSettled] fires.
  final Duration settle;

  final Timer Function(Duration, void Function()) _scheduleTimer;

  Timer? _timer;
  int? _pendingCols;
  int? _pendingRows;
  bool _forceNextEmit = false;

  int? _lastEmittedCols;
  int? _lastEmittedRows;

  /// Test/telemetry: how many times [onSettled] actually fired. A storm of N
  /// switches / resizes must increment this by AT MOST one per settled size.
  int sendCount = 0;

  /// Record a desired size (a UI resize). Resets the settle timer; the
  /// refresh-client is sent only once the size stops changing for [settle].
  void submit(int cols, int rows) {
    _pendingCols = cols;
    _pendingRows = rows;
    _timer?.cancel();
    _timer = _scheduleTimer(settle, _fire);
  }

  /// Request a coalesced REDRAW at the current pending size (an active-window
  /// switch). Like [submit] but FORCES the next settled emit even if the dims
  /// equal the last emitted size — a window switch must repaint the new window's
  /// content. Still debounced: a storm of switches collapses to ONE write. Falls
  /// back to [cols]/[rows] when no size has been submitted yet (first frames).
  void requestRedraw(int cols, int rows) {
    _pendingCols ??= cols;
    _pendingRows ??= rows;
    _forceNextEmit = true;
    _timer?.cancel();
    _timer = _scheduleTimer(settle, _fire);
  }

  void _fire() {
    _timer = null;
    final cols = _pendingCols;
    final rows = _pendingRows;
    if (cols == null || rows == null) return;
    final force = _forceNextEmit;
    _forceNextEmit = false;
    if (!force && cols == _lastEmittedCols && rows == _lastEmittedRows) return;
    _lastEmittedCols = cols;
    _lastEmittedRows = rows;
    sendCount += 1;
    onSettled(cols, rows);
  }

  /// Cancel any pending write (shell drop / reconnect / teardown). Does NOT emit
  /// — a dead channel must never storm a stale refresh-client.
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _forceNextEmit = false;
  }
}
