// In-band agent-attention signal detector (#840, Slice 1).
//
// Claude Code (and other tools) signal "I want your attention" through the PTY
// byte stream in several forms. The PWA handles these in-band via xterm.js
// `onBell` + `registerOscHandler(9)` + `registerOscHandler(777)`
// (src/modules/terminal.ts). The native app has no server subscription, so it
// must detect the same signals by scanning the raw dartssh2 byte stream BEFORE
// the bytes reach the terminal renderer.
//
// This scanner is OBSERVE-ONLY: it never alters the forwarded bytes. It runs in
// the task isolate alongside [Da2HyperlinkResponder] so it sees output for ALL
// sessions, including backgrounded ones.
//
// FORMS DETECTED
// --------------
//   * bare BEL          0x07
//   * OSC 9             ESC ] 9 ; <text> (BEL | ST)            ST = ESC \
//   * OSC 777 (notify)  ESC ] 777 ; notify ; <title> ; <body> (BEL | ST)
//   * notify-bell line  CR ESC [ K "# <message>" BEL
//     (the exact sequence `~/.claude/hooks/notify-bell.sh` writes:
//      `\r\033[K# <message>\a`)
//
// CHUNK BOUNDARIES
// ----------------
// A BEL or OSC can straddle two `output.listen` chunks, so a small suffix that
// could still be the start of a sequence is buffered until the next [feed].
//
// FRAMING ORDER (no double-fire)
// ------------------------------
// OSC sequences are stripped FIRST. An OSC terminated by BEL must NOT also fire
// as a bare-BEL signal — so the OSC's terminating BEL is consumed as part of the
// OSC match and never re-examined as a standalone bell.
//
// DEDUP
// -----
// A 2-second per-scanner cooldown (mirroring the host `notify-bell.sh` lockfile)
// collapses a burst of signals into one. The clock is injectable so unit tests
// can drive it deterministically with `fake_async`.

import 'dart:convert';

/// The kind of attention signal detected in the PTY stream.
enum AttentionKind {
  /// A bare `0x07` BEL not consumed by an OSC terminator.
  bell,

  /// `ESC ] 9 ; <text> (BEL|ST)` — carries a human-readable message.
  osc9,

  /// `ESC ] 777 ; notify ; <title> ; <body> (BEL|ST)`.
  osc777,

  /// The `\r\033[K# <message>\a` line written by `notify-bell.sh`.
  hookLine,
}

/// A single detected attention signal: its [kind] and any parsed [text]
/// (the message body, with framing stripped). [text] is null for a bare bell.
class AttentionSignal {
  const AttentionSignal(this.kind, this.text);

  final AttentionKind kind;
  final String? text;

  @override
  String toString() {
    final t = text;
    return t == null ? kind.name : '${kind.name} "$t"';
  }

  @override
  bool operator ==(Object other) =>
      other is AttentionSignal && other.kind == kind && other.text == text;

  @override
  int get hashCode => Object.hash(kind, text);
}

const int _bel = 0x07; // BEL \a
const int _esc = 0x1b; // ESC
const int _rbracket = 0x5d; // ]
const int _backslash = 0x5c; // \  (ST = ESC \)
const int _cr = 0x0d; // CR \r
const int _lbracket = 0x5b; // [
const int _k = 0x4b; // K
const int _hash = 0x23; // #

/// Per-session, stateful, chunk-boundary-safe attention-signal detector.
///
/// Feed each remote-output chunk into [feed]; it returns every NEW signal seen
/// (after dedup). State (partial-sequence tail, last-signal time) persists
/// across calls and is cleared by [reset] on a fresh shell attach.
class AttentionSignalScanner {
  AttentionSignalScanner({
    int Function()? nowMs,
    this.cooldownMs = 2000,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// Injected clock (ms since epoch). Tests pass a `fake_async`-driven closure.
  final int Function() _nowMs;

  /// Per-scanner dedup window (ms). A signal within [cooldownMs] of the last
  /// emitted one is collapsed away. Mirrors the host notify-bell lockfile.
  final int cooldownMs;

  /// Bytes held back because they form a proper prefix of some signal and the
  /// rest may arrive in the next chunk.
  final List<int> _pending = <int>[];

  /// Wall-clock (ms) of the last EMITTED signal, or null if none yet.
  int? _lastEmitMs;

  /// Feed a chunk of remote bytes. Returns the (deduped) signals detected.
  /// Never throws on malformed input — unmatched bytes are simply consumed.
  List<AttentionSignal> feed(List<int> bytes) {
    final buf = <int>[..._pending, ...bytes];
    _pending.clear();

    final raw = <AttentionSignal>[];
    var i = 0;
    while (i < buf.length) {
      final b = buf[i];

      // 1) OSC: ESC ] ... (BEL | ST). Strip framing FIRST so a terminating BEL
      //    is consumed here and never re-fires as a bare bell.
      if (b == _esc) {
        final osc = _matchOsc(buf, i);
        if (osc.kind == _MatchKind.full) {
          final sig = _classifyOsc(osc.payload);
          if (sig != null) raw.add(sig);
          i += osc.length;
          continue;
        }
        if (osc.kind == _MatchKind.partial) {
          _pending.addAll(buf.sublist(i));
          i = buf.length;
          continue;
        }
        // Not an OSC (some other escape sequence). Skip the lone ESC; the bytes
        // that follow are examined normally on subsequent iterations.
        i++;
        continue;
      }

      // 2) notify-bell line: CR ESC[K "# <message>" BEL. Detect from the CR so
      //    the `# message` text + its terminating BEL are consumed as one unit
      //    (the BEL must not also fire as a bare bell).
      if (b == _cr) {
        final hook = _matchHookLine(buf, i);
        if (hook.kind == _MatchKind.full) {
          raw.add(AttentionSignal(AttentionKind.hookLine, hook.payload));
          i += hook.length;
          continue;
        }
        if (hook.kind == _MatchKind.partial) {
          _pending.addAll(buf.sublist(i));
          i = buf.length;
          continue;
        }
        // A CR that isn't the start of a hook line — ordinary byte.
        i++;
        continue;
      }

      // 3) bare BEL.
      if (b == _bel) {
        raw.add(const AttentionSignal(AttentionKind.bell, null));
        i++;
        continue;
      }

      // Ordinary byte.
      i++;
    }

    return _dedup(raw);
  }

  /// Flush state for a fresh shell/attach (e.g. after reconnect).
  void reset() {
    _pending.clear();
    _lastEmitMs = null;
  }

  /// Apply the per-scanner cooldown: collapse a burst into one signal. The
  /// FIRST signal of a burst is emitted; subsequent ones within [cooldownMs]
  /// are dropped. The cooldown clock advances to each emitted signal's time.
  List<AttentionSignal> _dedup(List<AttentionSignal> signals) {
    if (signals.isEmpty) return const <AttentionSignal>[];
    final out = <AttentionSignal>[];
    for (final s in signals) {
      final now = _nowMs();
      final last = _lastEmitMs;
      if (last == null || (now - last) >= cooldownMs) {
        out.add(s);
        _lastEmitMs = now;
      }
    }
    return out;
  }

  /// Match an OSC sequence starting at [start] (`buf[start]` is ESC).
  ///
  /// Shape: `ESC ] <params> (BEL | ESC \)`. [_OscMatch.payload] is the params
  /// between `ESC ]` and the terminator. A bare `ESC` (no `]` yet, or `]`
  /// without a terminator) at the end of the buffer is reported as partial so
  /// the caller buffers it for the next chunk.
  _OscMatch _matchOsc(List<int> buf, int start) {
    var i = start;
    // ESC
    if (i >= buf.length) return const _OscMatch(_MatchKind.partial, 0, '');
    if (buf[i] != _esc) return const _OscMatch(_MatchKind.none, 0, '');
    i++;
    // ]
    if (i >= buf.length) return const _OscMatch(_MatchKind.partial, 0, '');
    if (buf[i] != _rbracket) return const _OscMatch(_MatchKind.none, 0, '');
    i++;
    // params up to BEL or ST (ESC \). Cap the scan so an unterminated OSC can't
    // buffer unboundedly — a real notify OSC is short.
    final payloadStart = i;
    const maxPayload = 4096;
    while (i < buf.length) {
      final c = buf[i];
      if (c == _bel) {
        final payload = _decode(buf.sublist(payloadStart, i));
        return _OscMatch(_MatchKind.full, (i - start) + 1, payload);
      }
      if (c == _esc) {
        // Possible ST (ESC \).
        if (i + 1 >= buf.length) {
          return const _OscMatch(_MatchKind.partial, 0, '');
        }
        if (buf[i + 1] == _backslash) {
          final payload = _decode(buf.sublist(payloadStart, i));
          return _OscMatch(_MatchKind.full, (i + 2 - start), payload);
        }
        // An embedded ESC that isn't ST — give up on this OSC; treat the
        // leading ESC as a non-OSC byte so we don't swallow real output.
        return const _OscMatch(_MatchKind.none, 0, '');
      }
      i++;
      if (i - payloadStart > maxPayload) {
        // Too long to be a notify OSC — abandon (treat ESC as ordinary).
        return const _OscMatch(_MatchKind.none, 0, '');
      }
    }
    // Ran out of bytes before a terminator — buffer for the next chunk.
    return const _OscMatch(_MatchKind.partial, 0, '');
  }

  /// Classify an OSC payload (the text between `ESC ]` and the terminator) into
  /// an OSC 9 / OSC 777 attention signal, or null if it's an unrelated OSC
  /// (e.g. OSC 4/7/8/12 handled elsewhere).
  AttentionSignal? _classifyOsc(String payload) {
    // OSC 9 ; <text>
    if (payload == '9' || payload.startsWith('9;')) {
      final text = payload.length > 2 ? payload.substring(2) : '';
      return AttentionSignal(AttentionKind.osc9, text);
    }
    // OSC 777 ; notify ; <title> ; <body>
    if (payload.startsWith('777;')) {
      final parts = payload.split(';');
      // parts[0] = '777', parts[1] = 'notify', parts[2] = title, rest = body.
      if (parts.length >= 2 && parts[1] == 'notify') {
        final title = parts.length >= 3 ? parts[2] : '';
        final body = parts.length >= 4 ? parts.sublist(3).join(';') : '';
        final text = body.isEmpty
            ? title
            : (title.isEmpty ? body : '$title: $body');
        return AttentionSignal(AttentionKind.osc777, text);
      }
    }
    return null;
  }

  /// Match the notify-bell line `CR ESC[K "# <message>" BEL` starting at the CR.
  /// Returns the message with the leading `# ` stripped.
  _HookMatch _matchHookLine(List<int> buf, int start) {
    var i = start;
    // CR
    if (i >= buf.length) return const _HookMatch(_MatchKind.partial, 0, '');
    if (buf[i] != _cr) return const _HookMatch(_MatchKind.none, 0, '');
    i++;
    // ESC
    if (i >= buf.length) return const _HookMatch(_MatchKind.partial, 0, '');
    if (buf[i] != _esc) return const _HookMatch(_MatchKind.none, 0, '');
    i++;
    // [
    if (i >= buf.length) return const _HookMatch(_MatchKind.partial, 0, '');
    if (buf[i] != _lbracket) return const _HookMatch(_MatchKind.none, 0, '');
    i++;
    // K (clear-to-EOL). notify-bell writes `\033[K` (no leading param).
    if (i >= buf.length) return const _HookMatch(_MatchKind.partial, 0, '');
    if (buf[i] != _k) return const _HookMatch(_MatchKind.none, 0, '');
    i++;
    // '#'
    if (i >= buf.length) return const _HookMatch(_MatchKind.partial, 0, '');
    if (buf[i] != _hash) return const _HookMatch(_MatchKind.none, 0, '');
    i++;
    // Message bytes up to BEL.
    final msgStart = i;
    const maxMsg = 4096;
    while (i < buf.length) {
      if (buf[i] == _bel) {
        final msg = _decode(buf.sublist(msgStart, i)).trimLeft();
        return _HookMatch(_MatchKind.full, (i - start) + 1, msg);
      }
      i++;
      if (i - msgStart > maxMsg) {
        return const _HookMatch(_MatchKind.none, 0, '');
      }
    }
    // No terminating BEL yet — buffer for the next chunk.
    return const _HookMatch(_MatchKind.partial, 0, '');
  }

  String _decode(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);
}

enum _MatchKind { none, partial, full }

class _OscMatch {
  const _OscMatch(this.kind, this.length, this.payload);
  final _MatchKind kind;
  final int length;
  final String payload;
}

class _HookMatch {
  const _HookMatch(this.kind, this.length, this.payload);
  final _MatchKind kind;
  final int length;
  final String payload;
}
