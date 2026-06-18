// tmux control mode (`tmux -CC`) protocol parser — Part A of the control-mode
// arc (issue #907, epic #906). This is a PURE Dart module: no Flutter, no SSH,
// no I/O. It consumes the raw `-CC` byte/line stream and emits TYPED events for
// the framing + every notification the session layer (Parts B/C) will need:
//   - command framing (%begin … %end / %error),
//   - per-pane output (%output, OCTAL-UNESCAPED to the real bytes),
//   - window/pane/session/layout notifications, and
//   - control-mode entry (DCS 1000p) / exit (%exit).
//
// WHY control mode (see epic #906): today's client GUESSES tmux's geometry and
// active window by scraping pixels and synthesizing SGR mouse clicks. Control
// mode has tmux PUSH its truth (%layout-change/%window-*/%session-window-changed)
// and lets the client SET size with `refresh-client -C`. Part A only PARSES and
// VALIDATES that the parsed geometry/active-window equals tmux's independent
// truth — it changes nothing in the render/gesture path. The whole feature is
// gated behind [tmuxControlMode] (default OFF); this parser is never wired into
// the live session until Part B.
//
// Design reference: Ghostty's open `ControlParser` (Ghostty #1935 / 1.3.0) —
// the state-machine shape (startup block → command queue), the %-notification
// dispatch, and the octal-unescape of %output. This is a from-scratch Dart
// implementation of the same protocol, not a port.
//
// RESILIENCE CONTRACT: the parser must NEVER throw on malformed or partial
// input. A line it doesn't understand becomes an [UnknownLine] event; a partial
// final line is buffered until the next feed completes it. A control-mode stream
// arriving over SSH can be chunked anywhere, including mid-line and mid-escape.
//
// Exercised entirely by `test/terminal/tmux_control_parser_test.dart` (fast unit
// gate) + the `scripts/validate-cc-parser.sh` parity spike.

import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Typed events
// ---------------------------------------------------------------------------

/// Base type for every event the parser emits. A sealed hierarchy so consumers
/// (Part B/C) can exhaustively switch.
sealed class TmuxControlEvent {
  const TmuxControlEvent();
}

/// Control mode was entered — the `\033P1000p` (DCS 1000p) sequence. Emitted
/// once when that prefix is seen at the start of the stream.
class ControlModeEntered extends TmuxControlEvent {
  const ControlModeEntered();
  @override
  String toString() => 'ControlModeEntered()';
}

/// Control mode is ending — the `%exit` notification. [reason] is the optional
/// trailing text (e.g. a detach reason), or null.
class ControlModeExit extends TmuxControlEvent {
  const ControlModeExit(this.reason);
  final String? reason;
  @override
  String toString() => 'ControlModeExit($reason)';
}

/// `%begin <ts> <num> <flags>` — start of a command's response block.
class CommandBegin extends TmuxControlEvent {
  const CommandBegin({required this.timestamp, required this.number, required this.flags});
  final int timestamp;
  final int number;
  final int flags;
  @override
  String toString() => 'CommandBegin(ts:$timestamp #$number flags:$flags)';
}

/// `%end`/`%error <ts> <num> <flags>` — end of a command's response block.
/// [isError] distinguishes `%error` (command failed) from `%end` (success).
/// [response] is the accumulated response body lines (verbatim, NOT unescaped —
/// command responses are plain text, not octal-escaped like %output).
class CommandEnd extends TmuxControlEvent {
  const CommandEnd({
    required this.timestamp,
    required this.number,
    required this.flags,
    required this.isError,
    required this.response,
  });
  final int timestamp;
  final int number;
  final int flags;
  final bool isError;
  final List<String> response;
  @override
  String toString() =>
      'CommandEnd(${isError ? 'error' : 'ok'} #$number, ${response.length} lines)';
}

/// `%output %<paneId> <data>` — pane output. [data] is the FULLY UNESCAPED bytes
/// (octal sequences like `\134` decoded back to `0x5C`). [paneId] is the numeric
/// tmux pane id (the `%N`).
class PaneOutput extends TmuxControlEvent {
  const PaneOutput({required this.paneId, required this.data});
  final int paneId;
  final Uint8List data;
  @override
  String toString() => 'PaneOutput(%$paneId, ${data.length}B)';
}

/// `%layout-change @<window> <layout> [<visible-layout> <flags>]`.
/// The parsed [WindowLayout] gives the window geometry + pane rects.
class LayoutChange extends TmuxControlEvent {
  const LayoutChange({required this.windowId, required this.layout, required this.raw});
  final int windowId;
  final WindowLayout layout;

  /// The raw layout string (checksum-prefixed) as tmux sent it — kept so the
  /// validation spike can compare byte-for-byte against `#{window_layout}`.
  final String raw;
  @override
  String toString() => 'LayoutChange(@$windowId, $layout)';
}

/// `%window-add @<window>`.
class WindowAdd extends TmuxControlEvent {
  const WindowAdd(this.windowId);
  final int windowId;
  @override
  String toString() => 'WindowAdd(@$windowId)';
}

/// `%window-close @<window>` OR `%unlinked-window-close @<window>`. tmux 3.4
/// emits the latter when an unlinked window is killed; both mean "this window is
/// gone", so they collapse to one event with [unlinked] recording which spelling.
class WindowClose extends TmuxControlEvent {
  const WindowClose(this.windowId, {this.unlinked = false});
  final int windowId;
  final bool unlinked;
  @override
  String toString() => 'WindowClose(@$windowId${unlinked ? ', unlinked' : ''})';
}

/// `%window-renamed @<window> <name>`.
class WindowRenamed extends TmuxControlEvent {
  const WindowRenamed({required this.windowId, required this.name});
  final int windowId;
  final String name;
  @override
  String toString() => 'WindowRenamed(@$windowId, "$name")';
}

/// `%window-pane-changed @<window> %<pane>` — the active pane in a window changed.
class WindowPaneChanged extends TmuxControlEvent {
  const WindowPaneChanged({required this.windowId, required this.paneId});
  final int windowId;
  final int paneId;
  @override
  String toString() => 'WindowPaneChanged(@$windowId, %$paneId)';
}

/// `%session-changed $<session> <name>`.
class SessionChanged extends TmuxControlEvent {
  const SessionChanged({required this.sessionId, required this.name});
  final int sessionId;
  final String name;
  @override
  String toString() => 'SessionChanged(\$$sessionId, "$name")';
}

/// `%session-window-changed $<session> @<window>` — the active window in a
/// session changed. This is the authoritative active-window signal (epic #906
/// uses it to kill the "gesture lands on the wrong row" bug).
class SessionWindowChanged extends TmuxControlEvent {
  const SessionWindowChanged({required this.sessionId, required this.windowId});
  final int sessionId;
  final int windowId;
  @override
  String toString() => 'SessionWindowChanged(\$$sessionId, @$windowId)';
}

/// `%sessions-changed` — the set of sessions changed (no args).
class SessionsChanged extends TmuxControlEvent {
  const SessionsChanged();
  @override
  String toString() => 'SessionsChanged()';
}

/// `%client-detached <client>` — a client detached.
class ClientDetached extends TmuxControlEvent {
  const ClientDetached(this.client);
  final String client;
  @override
  String toString() => 'ClientDetached($client)';
}

/// `%client-session-changed <client> $<session> <name>`.
class ClientSessionChanged extends TmuxControlEvent {
  const ClientSessionChanged({
    required this.client,
    required this.sessionId,
    required this.name,
  });
  final String client;
  final int sessionId;
  final String name;
  @override
  String toString() => 'ClientSessionChanged($client, \$$sessionId, "$name")';
}

/// Any `%`-line the parser recognizes as a notification but doesn't model with a
/// dedicated type yet (e.g. `%pane-mode-changed`, `%continue`, `%pause`,
/// `%config-error`). Carries the verb (without `%`) and the raw args. Keeps the
/// stream lossless without forcing every minor notification into the API.
class UnhandledNotification extends TmuxControlEvent {
  const UnhandledNotification({required this.verb, required this.args});
  final String verb;
  final String args;
  @override
  String toString() => 'UnhandledNotification(%$verb "$args")';
}

/// A line that didn't match any known shape (malformed / unexpected). The
/// resilience escape hatch — emitted instead of throwing. [line] is verbatim.
class UnknownLine extends TmuxControlEvent {
  const UnknownLine(this.line);
  final String line;
  @override
  String toString() => 'UnknownLine(${line.length}ch)';
}

// ---------------------------------------------------------------------------
// Layout model
// ---------------------------------------------------------------------------

/// A pane rectangle within a window layout: cell geometry + the tmux pane index.
class LayoutPane {
  const LayoutPane({
    required this.width,
    required this.height,
    required this.x,
    required this.y,
    required this.paneId,
  });
  final int width;
  final int height;
  final int x;
  final int y;

  /// tmux pane index for this rect, or null for an interior split node (tmux
  /// layout strings only carry a pane id on leaf cells).
  final int? paneId;

  @override
  String toString() => 'pane(${width}x$height@$x,$y${paneId == null ? '' : ' %$paneId'})';
}

/// A parsed tmux window layout: the window's overall cell geometry plus the flat
/// list of leaf panes. Parsed from a layout string like
/// `bdf2,80x24,0,0,1` or `0206,80x24,0,0{40x24,0,0,0,39x24,41,0,2}`.
class WindowLayout {
  const WindowLayout({
    required this.width,
    required this.height,
    required this.panes,
    required this.checksum,
  });

  /// Window width in cells (the top-level WxH of the layout).
  final int width;

  /// Window height in cells.
  final int height;

  /// All leaf panes (the cells that carry a pane id), in layout order.
  final List<LayoutPane> panes;

  /// The 4-hex-digit checksum tmux prefixes the layout with.
  final String checksum;

  @override
  String toString() => 'WindowLayout(${width}x$height, ${panes.length} panes)';
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

/// Streaming, resilient parser for the `tmux -CC` control-mode protocol.
///
/// Feed bytes (as decoded text — control mode is ASCII line-oriented) via [feed]
/// and read the typed events it emits. It maintains a small line buffer so a feed
/// can split anywhere. It also tracks a running view of [activeWindowId] and the
/// latest [WindowLayout] per window (the parity surface the spike validates).
///
/// PURE: no Flutter, no I/O, no SSH. Never throws.
class TmuxControlParser {
  TmuxControlParser();

  final StringBuffer _pending = StringBuffer();

  bool _entered = false;

  /// True while inside a `%begin … %end/%error` block (collecting response lines).
  bool _inBlock = false;
  int _blockTs = 0;
  int _blockNum = 0;
  int _blockFlags = 0;
  final List<String> _blockLines = <String>[];

  /// Last active window seen via %session-window-changed (authoritative).
  int? _activeWindowId;
  int? get activeWindowId => _activeWindowId;

  /// Latest layout per window id (from %layout-change). The geometry truth.
  final Map<int, WindowLayout> _layouts = <int, WindowLayout>{};
  Map<int, WindowLayout> get layouts => Map.unmodifiable(_layouts);

  /// Latest known session name (from %session-changed), or null.
  String? _sessionName;
  String? get sessionName => _sessionName;

  /// Feed a chunk of the control-mode stream. Returns the events parsed from the
  /// COMPLETE lines now available; a trailing partial line is buffered for the
  /// next feed. Never throws.
  List<TmuxControlEvent> feed(String chunk) {
    final events = <TmuxControlEvent>[];
    _pending.write(chunk);
    var buf = _pending.toString();

    // Handle the DCS 1000p entry prefix once, wherever it appears, before line
    // splitting (tmux prepends it to the first %begin without a newline).
    if (!_entered) {
      final idx = buf.indexOf('P1000p');
      if (idx >= 0) {
        _entered = true;
        events.add(const ControlModeEntered());
        buf = buf.substring(0, idx) + buf.substring(idx + 'P1000p'.length);
      }
    }

    // Split into complete lines; keep the trailing partial in _pending.
    final lines = <String>[];
    var start = 0;
    for (var i = 0; i < buf.length; i++) {
      final c = buf.codeUnitAt(i);
      if (c == 0x0a) {
        // \n
        var line = buf.substring(start, i);
        if (line.isNotEmpty && line.codeUnitAt(line.length - 1) == 0x0d) {
          line = line.substring(0, line.length - 1); // strip trailing \r
        }
        lines.add(line);
        start = i + 1;
      }
    }
    _pending
      ..clear()
      ..write(buf.substring(start));

    for (final line in lines) {
      _handleLine(line, events);
    }
    return events;
  }

  void _handleLine(String line, List<TmuxControlEvent> out) {
    // Inside a command block, every line that is not the closing %end/%error is
    // part of the response body (verbatim). The closing line is still a `%`
    // line, so check for it first.
    if (_inBlock) {
      if (line.startsWith('%end ') || line == '%end' ||
          line.startsWith('%error ') || line == '%error') {
        final isError = line.startsWith('%error');
        final parts = _afterVerb(line).trim();
        final nums = _ints(parts, 3);
        _inBlock = false;
        out.add(CommandEnd(
          timestamp: nums.isNotEmpty ? nums[0] : _blockTs,
          number: nums.length > 1 ? nums[1] : _blockNum,
          flags: nums.length > 2 ? nums[2] : _blockFlags,
          isError: isError,
          response: List<String>.unmodifiable(_blockLines),
        ));
        _blockLines.clear();
        return;
      }
      _blockLines.add(line);
      return;
    }

    if (!line.startsWith('%')) {
      // Outside a block, a non-% line is unexpected (e.g. the trailing `\` after
      // %exit, or stray output). Don't throw — surface it.
      if (line.isEmpty) return; // ignore blank separators
      out.add(UnknownLine(line));
      return;
    }

    // Dispatch on the verb (first whitespace-delimited token, sans `%`).
    final sp = line.indexOf(' ');
    final verb = (sp < 0 ? line : line.substring(0, sp)).substring(1);
    final args = sp < 0 ? '' : line.substring(sp + 1);

    switch (verb) {
      case 'begin':
        final nums = _ints(args, 3);
        _inBlock = true;
        _blockTs = nums.isNotEmpty ? nums[0] : 0;
        _blockNum = nums.length > 1 ? nums[1] : 0;
        _blockFlags = nums.length > 2 ? nums[2] : 0;
        _blockLines.clear();
        out.add(CommandBegin(timestamp: _blockTs, number: _blockNum, flags: _blockFlags));
        return;
      case 'output':
        _parseOutput(args, out);
        return;
      case 'layout-change':
        _parseLayoutChange(args, out);
        return;
      case 'window-add':
        final w = _firstId(args, '@');
        out.add(w != null ? WindowAdd(w) : UnknownLine(line));
        return;
      case 'window-close':
        final w = _firstId(args, '@');
        out.add(w != null ? WindowClose(w) : UnknownLine(line));
        return;
      case 'unlinked-window-close':
        final w = _firstId(args, '@');
        out.add(w != null ? WindowClose(w, unlinked: true) : UnknownLine(line));
        return;
      case 'window-renamed':
        _parseWindowRenamed(args, out, line);
        return;
      case 'window-pane-changed':
        _parseWindowPaneChanged(args, out, line);
        return;
      case 'session-changed':
        _parseSessionChanged(args, out, line);
        return;
      case 'session-window-changed':
        _parseSessionWindowChanged(args, out, line);
        return;
      case 'sessions-changed':
        out.add(const SessionsChanged());
        return;
      case 'client-detached':
        out.add(ClientDetached(args.trim()));
        return;
      case 'client-session-changed':
        _parseClientSessionChanged(args, out, line);
        return;
      case 'exit':
        final reason = args.trim();
        out.add(ControlModeExit(reason.isEmpty ? null : reason));
        return;
      default:
        // A recognized-but-unmodeled %notification (e.g. %pane-mode-changed,
        // %continue, %pause, %config-error). Keep the stream lossless.
        out.add(UnhandledNotification(verb: verb, args: args));
        return;
    }
  }

  void _parseOutput(String args, List<TmuxControlEvent> out) {
    // args = "%<paneId> <octal-escaped-data...>". The data may contain spaces;
    // only the FIRST space (after the pane id token) is the delimiter.
    if (!args.startsWith('%')) {
      out.add(UnknownLine('%output $args'));
      return;
    }
    final sp = args.indexOf(' ');
    if (sp < 0) {
      // %output with a pane but no data → empty output (valid).
      final id = int.tryParse(args.substring(1));
      if (id == null) {
        out.add(UnknownLine('%output $args'));
        return;
      }
      out.add(PaneOutput(paneId: id, data: Uint8List(0)));
      return;
    }
    final id = int.tryParse(args.substring(1, sp));
    if (id == null) {
      out.add(UnknownLine('%output $args'));
      return;
    }
    final data = _unescapeOctal(args.substring(sp + 1));
    out.add(PaneOutput(paneId: id, data: data));
  }

  void _parseLayoutChange(String args, List<TmuxControlEvent> out) {
    // args = "@<window> <layout> [<visible-layout> <flags>]"
    final tokens = args.split(' ');
    if (tokens.isEmpty) {
      out.add(UnknownLine('%layout-change $args'));
      return;
    }
    final w = _parseId(tokens[0], '@');
    final raw = tokens.length > 1 ? tokens[1] : '';
    final layout = parseLayout(raw);
    if (w == null || layout == null) {
      out.add(UnknownLine('%layout-change $args'));
      return;
    }
    _layouts[w] = layout;
    out.add(LayoutChange(windowId: w, layout: layout, raw: raw));
  }

  void _parseWindowRenamed(String args, List<TmuxControlEvent> out, String line) {
    final sp = args.indexOf(' ');
    if (sp < 0) {
      out.add(UnknownLine(line));
      return;
    }
    final w = _parseId(args.substring(0, sp), '@');
    if (w == null) {
      out.add(UnknownLine(line));
      return;
    }
    out.add(WindowRenamed(windowId: w, name: args.substring(sp + 1)));
  }

  void _parseWindowPaneChanged(String args, List<TmuxControlEvent> out, String line) {
    final tokens = args.split(' ');
    if (tokens.length < 2) {
      out.add(UnknownLine(line));
      return;
    }
    final w = _parseId(tokens[0], '@');
    final p = _parseId(tokens[1], '%');
    if (w == null || p == null) {
      out.add(UnknownLine(line));
      return;
    }
    out.add(WindowPaneChanged(windowId: w, paneId: p));
  }

  void _parseSessionChanged(String args, List<TmuxControlEvent> out, String line) {
    final sp = args.indexOf(' ');
    if (sp < 0) {
      out.add(UnknownLine(line));
      return;
    }
    final s = _parseId(args.substring(0, sp), '\$');
    if (s == null) {
      out.add(UnknownLine(line));
      return;
    }
    final name = args.substring(sp + 1);
    _sessionName = name;
    out.add(SessionChanged(sessionId: s, name: name));
  }

  void _parseSessionWindowChanged(String args, List<TmuxControlEvent> out, String line) {
    final tokens = args.split(' ');
    if (tokens.length < 2) {
      out.add(UnknownLine(line));
      return;
    }
    final s = _parseId(tokens[0], '\$');
    final w = _parseId(tokens[1], '@');
    if (s == null || w == null) {
      out.add(UnknownLine(line));
      return;
    }
    _activeWindowId = w;
    out.add(SessionWindowChanged(sessionId: s, windowId: w));
  }

  void _parseClientSessionChanged(String args, List<TmuxControlEvent> out, String line) {
    // "<client> $<session> <name>"
    final tokens = args.split(' ');
    if (tokens.length < 3) {
      out.add(UnknownLine(line));
      return;
    }
    final s = _parseId(tokens[1], '\$');
    if (s == null) {
      out.add(UnknownLine(line));
      return;
    }
    out.add(ClientSessionChanged(
      client: tokens[0],
      sessionId: s,
      name: tokens.sublist(2).join(' '),
    ));
  }

  // -- helpers -------------------------------------------------------------

  /// Return everything after the first space (the verb), or '' if none.
  static String _afterVerb(String line) {
    final sp = line.indexOf(' ');
    return sp < 0 ? '' : line.substring(sp + 1);
  }

  /// Parse up to [n] leading space-separated integers from [s] (stops at the
  /// first non-int token). Used for %begin/%end numeric headers.
  static List<int> _ints(String s, int n) {
    final out = <int>[];
    for (final tok in s.split(' ')) {
      if (out.length >= n) break;
      final v = int.tryParse(tok);
      if (v == null) break;
      out.add(v);
    }
    return out;
  }

  /// Parse `<prefix><digits>` (e.g. `@3`, `%12`, `$0`) into the int, or null.
  static int? _parseId(String token, String prefix) {
    if (!token.startsWith(prefix)) return null;
    return int.tryParse(token.substring(prefix.length));
  }

  /// First whitespace token of [args] parsed as `<prefix><id>`.
  static int? _firstId(String args, String prefix) {
    final sp = args.indexOf(' ');
    final tok = sp < 0 ? args : args.substring(0, sp);
    return _parseId(tok, prefix);
  }

  /// Unescape tmux's %output octal escaping: every `\NNN` (1–3 octal digits,
  /// tmux always emits 3) decodes to that byte; a `\` not followed by octal
  /// digits is kept literally. tmux escapes bytes < 0x20 and `\` itself
  /// (`\134`). Returns raw bytes (UTF-8 / control bytes preserved exactly).
  static Uint8List _unescapeOctal(String s) {
    final out = <int>[];
    final units = s.codeUnits;
    var i = 0;
    while (i < units.length) {
      final c = units[i];
      if (c == 0x5c /* \ */ && i + 1 < units.length && _isOctal(units[i + 1])) {
        var j = i + 1;
        var val = 0;
        var digits = 0;
        while (j < units.length && digits < 3 && _isOctal(units[j])) {
          val = val * 8 + (units[j] - 0x30);
          j++;
          digits++;
        }
        out.add(val & 0xff);
        i = j;
      } else if (c <= 0x7f) {
        out.add(c);
        i++;
      } else {
        // A non-ASCII code unit (shouldn't appear pre-unescape, but be safe):
        // re-encode as UTF-8 bytes.
        out.addAll(_utf8Byte(c));
        i++;
      }
    }
    return Uint8List.fromList(out);
  }

  static bool _isOctal(int c) => c >= 0x30 && c <= 0x37; // '0'..'7'

  static List<int> _utf8Byte(int codeUnit) {
    if (codeUnit < 0x80) return [codeUnit];
    if (codeUnit < 0x800) {
      return [0xc0 | (codeUnit >> 6), 0x80 | (codeUnit & 0x3f)];
    }
    return [
      0xe0 | (codeUnit >> 12),
      0x80 | ((codeUnit >> 6) & 0x3f),
      0x80 | (codeUnit & 0x3f),
    ];
  }

  /// Parse a tmux window-layout string into a [WindowLayout]. Format:
  ///   `<csum>,WxH,X,Y` (single pane) or
  ///   `<csum>,WxH,X,Y{<cell>,<cell>,...}` / `[...]` for splits.
  /// A leaf cell is `WxH,X,Y,<paneIndex>`; a split node is `WxH,X,Y{...}` /
  /// `WxH,X,Y[...]` (no pane index, has children). Returns null if it can't be
  /// parsed (never throws).
  ///
  /// Sibling cells inside a `{}`/`[]` split are separated by a SINGLE comma, but
  /// every cell ALSO contains commas (WxH,X,Y[,id]), so this is a recursive
  /// descent parse over a cursor — NOT a comma-split. The cursor [_LayoutCursor]
  /// tracks the position so each `_parseCell` consumes exactly one cell.
  static WindowLayout? parseLayout(String raw) {
    try {
      final comma = raw.indexOf(',');
      if (comma <= 0) return null;
      final checksum = raw.substring(0, comma);
      final cur = _LayoutCursor(raw, comma + 1);
      final panes = <LayoutPane>[];
      final root = _parseCell(cur, panes);
      if (root == null) return null;
      return WindowLayout(
        width: root.width,
        height: root.height,
        panes: panes,
        checksum: checksum,
      );
    } catch (_) {
      return null; // resilience: malformed layout never throws
    }
  }

  /// Parse a single layout cell at the cursor, advancing it past the cell.
  /// Appends every LEAF pane to [leaves]. Returns the cell's geometry. A cell is
  /// `WxH,X,Y` then one of: `,paneIdx` (leaf) / `{children}` (h-split) /
  /// `[children]` (v-split) / nothing-more (bare). Children are comma-separated
  /// cells parsed recursively.
  static LayoutPane? _parseCell(_LayoutCursor cur, List<LayoutPane> leaves) {
    final w = cur.readInt(stopAt: 0x78 /* x */);
    if (w == null || !cur.consume(0x78)) return null;
    final h = cur.readInt(stopAt: 0x2c /* , */);
    if (h == null || !cur.consume(0x2c)) return null;
    final x = cur.readInt(stopAt: 0x2c);
    if (x == null || !cur.consume(0x2c)) return null;
    final y = cur.readInt(); // reads digits, stops at any non-digit
    if (y == null) return null;

    final next = cur.peek();
    if (next == 0x7b /* { */ || next == 0x5b /* [ */) {
      final close = next == 0x7b ? 0x7d : 0x5d; // } or ]
      cur.advance(); // consume opener
      // Parse comma-separated child cells until the matching closer.
      while (true) {
        final child = _parseCell(cur, leaves);
        if (child == null) return null;
        final after = cur.peek();
        if (after == 0x2c) {
          cur.advance();
          continue;
        }
        if (after == close) {
          cur.advance();
          break;
        }
        return null; // malformed split
      }
      return LayoutPane(width: w, height: h, x: x, y: y, paneId: null);
    }

    if (next == 0x2c /* , */) {
      cur.advance();
      final id = cur.readInt();
      final pane = LayoutPane(width: w, height: h, x: x, y: y, paneId: id);
      leaves.add(pane);
      return pane;
    }

    // End-of-string or a closer: bare leaf with no pane id.
    final pane = LayoutPane(width: w, height: h, x: x, y: y, paneId: null);
    leaves.add(pane);
    return pane;
  }
}

/// Cursor over a layout string for the recursive-descent [TmuxControlParser.parseLayout].
class _LayoutCursor {
  _LayoutCursor(this.s, this.pos);
  final String s;
  int pos;

  int? peek() => pos < s.length ? s.codeUnitAt(pos) : null;
  void advance() => pos++;

  /// Consume the given code unit if present at the cursor; return whether it was.
  bool consume(int codeUnit) {
    if (pos < s.length && s.codeUnitAt(pos) == codeUnit) {
      pos++;
      return true;
    }
    return false;
  }

  /// Read a run of digits as an int, advancing the cursor. [stopAt] is unused
  /// beyond documentation — reading always stops at the first non-digit. Returns
  /// null if no digit is present.
  int? readInt({int? stopAt}) {
    final start = pos;
    while (pos < s.length && s.codeUnitAt(pos) >= 0x30 && s.codeUnitAt(pos) <= 0x39) {
      pos++;
    }
    if (pos == start) return null;
    return int.tryParse(s.substring(start, pos));
  }
}
