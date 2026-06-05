// Makes tmux forward OSC-8 hyperlinks to MobiSSH without any per-user
// `~/.tmux.conf`.
//
// THE PROBLEM (spike, verified on tmux 3.4)
// ----------------------------------------
// tmux PARSES and STORES OSC-8 hyperlinks but only FORWARDS them to a client
// whose terminal-features include `hyperlinks`. tmux decides that feature via
// the DA2 (Secondary Device Attributes) handshake, NOT via TERM:
//
//   * At attach, tmux sends the DA2 query  ESC [ > c  to the client.
//   * tmux's `tty_keys_device_attributes2` maps the reply's first parameter:
//       'T' (84) -> tmux,  'M' (77) -> mintty,  'U' (82) -> rxvt-unicode
//     and applies that terminal's built-in default-features. The "tmux" set
//     INCLUDES `hyperlinks`.
//   * Changing TERM does nothing useful here: TERM=xterm-256color/tmux do not
//     enable hyperlinks on their own, and exotic TERMs (xterm-ghostty, iTerm2,
//     wezterm, foot) have no terminfo entry on a typical host, so the client
//     cannot attach at all.
//
// xterm.dart answers DA2 with  ESC [ > 0 ; 0 ; 0 c  (model 0) — which tmux
// maps to nothing, so `hyperlinks` is never enabled and the OSC-8 sequences
// our (already-shipped) scanner looks for are stripped before they reach us.
//
// THE FIX
// -------
// Sit at the SSH byte boundary (above whichever terminal backend renders).
// When the remote sends the DA2 query, SWALLOW it (so the UI terminal never
// emits its own `>0` reply — tmux honors the FIRST reply it sees) and answer
// with  ESC [ > 84 ; 0 ; 0 c  ('T' = tmux). tmux then advertises `hyperlinks`
// to this client and forwards OSC-8 links unstripped.
//
// This is transparent and reversible: it is exactly the handshake tmux
// expects; we simply give the answer that advertises hyperlink support. It
// does not touch TERM, so colors, keys and mouse are unaffected. When the
// remote is NOT tmux (e.g. a bare shell), nothing sends the DA2 query, so the
// responder is inert.

import 'dart:typed_data';

/// The DA2 (Secondary Device Attributes) query a host terminal sends to ask
/// "what kind of terminal are you?": `ESC [ > c`. Some hosts include an
/// explicit `0` parameter (`ESC [ > 0 c`); both are handled.
const int _esc = 0x1b; // ESC
const int _lbracket = 0x5b; // [
const int _gt = 0x3e; // >
const int _c = 0x63; // c

/// The reply that makes tmux treat us as a `tmux`-class terminal and therefore
/// enable the `hyperlinks` feature: `ESC [ > 84 ; 0 ; 0 c` (84 = 'T').
final Uint8List kTmuxDa2Reply = Uint8List.fromList(<int>[
  _esc, _lbracket, _gt, // ESC [ >
  0x38, 0x34, // "84"
  0x3b, 0x30, // ";0"
  0x3b, 0x30, // ";0"
  _c, // c
]);

/// Result of feeding a chunk of remote bytes through [Da2HyperlinkResponder].
class Da2ScanResult {
  const Da2ScanResult(this.forward, this.replies);

  /// Bytes to forward on to the terminal/UI — the input with any DA2 query
  /// removed.
  final Uint8List forward;

  /// Reply chunks to write back to the remote (each is [kTmuxDa2Reply]), one
  /// per DA2 query detected. Empty when no query was seen.
  final List<Uint8List> replies;

  bool get hasReply => replies.isNotEmpty;
}

/// Stateful, chunk-boundary-safe detector for the tmux DA2 query in a stream
/// of remote PTY bytes.
///
/// The query (`ESC [ > [0] c`) can be split across [scan] calls, so a small
/// suffix of unmatched-but-still-possibly-a-prefix bytes is buffered until the
/// next call. Everything that cannot be the start of the query is forwarded
/// immediately.
class Da2HyperlinkResponder {
  /// Bytes held back because they form a proper prefix of the query and the
  /// rest may arrive in the next chunk.
  final List<int> _pending = <int>[];

  /// Whether we have already answered a DA2 query for the current shell. tmux
  /// only queries once per attach, but a reconnect re-attaches and re-queries,
  /// so the responder is reused per-shell and reset via [reset]. We still
  /// answer every query we see (cheap + correct); this flag is exposed only
  /// for observability/telemetry.
  int repliesSent = 0;

  /// Feed a chunk of remote bytes. Returns the bytes to forward to the
  /// terminal and any DA2 replies to send back to the remote.
  Da2ScanResult scan(Uint8List chunk) {
    // Work over [pending tail] + [chunk] so a query split across chunks is
    // still matched.
    final buf = <int>[..._pending, ...chunk];
    _pending.clear();

    final out = <int>[];
    final replies = <Uint8List>[];
    var i = 0;
    while (i < buf.length) {
      final b = buf[i];
      if (b != _esc) {
        out.add(b);
        i++;
        continue;
      }
      // Potential start of `ESC [ > [params] c`. Try to match from here.
      final match = _matchDa2(buf, i);
      if (match.kind == _MatchKind.full) {
        // Swallow the query; queue a reply. Advance past the matched bytes.
        replies.add(kTmuxDa2Reply);
        repliesSent++;
        i += match.length;
      } else if (match.kind == _MatchKind.partial) {
        // A proper prefix that runs to the end of the buffer — buffer it and
        // wait for the next chunk.
        _pending.addAll(buf.sublist(i));
        i = buf.length;
      } else {
        // ESC that is not the start of a DA2 query (e.g. a normal escape
        // sequence). Forward the ESC and continue scanning after it.
        out.add(b);
        i++;
      }
    }

    return Da2ScanResult(Uint8List.fromList(out), replies);
  }

  /// Flush any buffered partial bytes (e.g. on shell close) so they are not
  /// lost. Returns whatever was held back, to be forwarded as-is.
  Uint8List flush() {
    if (_pending.isEmpty) return Uint8List(0);
    final out = Uint8List.fromList(_pending);
    _pending.clear();
    return out;
  }

  /// Reset state for a fresh shell/attach (e.g. after reconnect).
  void reset() {
    _pending.clear();
    repliesSent = 0;
  }

  /// Attempt to match `ESC [ > [params] c` starting at [start].
  _Da2Match _matchDa2(List<int> buf, int start) {
    var i = start;
    // ESC
    if (i >= buf.length) return const _Da2Match(_MatchKind.partial, 0);
    if (buf[i] != _esc) return const _Da2Match(_MatchKind.none, 0);
    i++;
    // [
    if (i >= buf.length) return const _Da2Match(_MatchKind.partial, 0);
    if (buf[i] != _lbracket) return const _Da2Match(_MatchKind.none, 0);
    i++;
    // >
    if (i >= buf.length) return const _Da2Match(_MatchKind.partial, 0);
    if (buf[i] != _gt) return const _Da2Match(_MatchKind.none, 0);
    i++;
    // Optional run of parameter digits/semicolons. tmux itself sends a bare
    // `ESC[>c`, but tolerate `ESC[>0c` / `ESC[>0;0c` defensively.
    while (i < buf.length && (_isDigit(buf[i]) || buf[i] == 0x3b)) {
      i++;
    }
    if (i >= buf.length) return const _Da2Match(_MatchKind.partial, 0);
    // terminator c
    if (buf[i] == _c) {
      return _Da2Match(_MatchKind.full, (i - start) + 1);
    }
    return const _Da2Match(_MatchKind.none, 0);
  }

  bool _isDigit(int b) => b >= 0x30 && b <= 0x39;
}

enum _MatchKind { none, partial, full }

/// Outcome of [_matchDa2]: the match kind plus, for a full match, how many
/// bytes the query occupied.
class _Da2Match {
  const _Da2Match(this.kind, this.length);
  final _MatchKind kind;
  final int length;
}
