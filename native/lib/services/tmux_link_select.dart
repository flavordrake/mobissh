// #1242 S1 — land a deep link on an exact tmux session / window / pane, also
// when the owner attached tmux BY HAND in the PTY.
//
// Everything here runs on SEPARATE non-PTY exec channels of the session's own
// SSH connection; nothing is ever typed into the terminal. Every command line
// is a constant template plus tokens re-validated here (R6, window/pane ids,
// the tty shape), single-quoted anyway.
//
// Finding OUR client (live session only). tmux does not know which SSH
// connection a client came from, so the exec channel identifies our connection
// two ways, in order.
//
// 1. SSH_CONNECTION (#1299). Every channel of one TCP connection carries the
// same `client_ip client_port server_ip server_port`, set by OpenSSH and by
// Tailscale SSH alike; the shell and the `tmux attach` client started from it
// inherit it. The exec shell reads its own value and each tmux client's
// `/proc/<client_pid>/environ` (same uid), and emits only `M <tty> <session>`
// for clients that equal it: the value never leaves the host. Exactly one M is
// our client. Tailscale SSH needs this: each session is a `tailscaled
// be-child` under the one long-lived daemon, so there is no per-connection
// sshd to find.
//
// 2. The sshd process tree (#1242), when SSH_CONNECTION is empty or does not
// pick exactly one client. sshd runs a connection's channels as children of
// ONE per-connection process (`sshd` / `sshd-session`). Our PTY shell and this
// exec's shell are siblings under it, so walking up from the exec shell to the
// nearest `sshd*` ancestor reaches the process that parents OUR PTY. The
// children of that process with a unix98 pts controlling tty are the ptys this
// connection owns; the tty of a tmux client attached from our PTY is that same
// /dev/pts/N (`#{client_tty}`). Exactly one pty AND exactly one client on it.
//
// Anything else is AMBIGUOUS and the caller falls back to the R23 confirm.
// /proc is read directly (no `ps`): a minimal container or busybox box has
// /proc but not procps, and `--ppid` is GNU-only.

import 'dart:async';

import 'connect_intent.dart';

/// One finished exec: exit status and stdout.
typedef TmuxExecResult = ({int? exit, String out});

typedef TmuxExec = Future<TmuxExecResult> Function(String line);

enum TmuxLinkOutcome { selected, notFound, ambiguous }

final _ttyShape = RegExp(r'^/dev/pts/[0-9]{1,6}$');

/// A validated select target. Throws [ArgumentError] on any token outside the
/// grammar, so a forged IPC field never reaches a shell.
class TmuxLinkTarget {
  TmuxLinkTarget(this.session, {this.window, this.pane}) {
    if (!tmuxNameShape.hasMatch(session)) {
      throw ArgumentError.value(session, 'session', 'not a valid tmux name');
    }
    final w = window;
    if (w != null && !isTmuxWindowToken(w)) {
      throw ArgumentError.value(w, 'window', 'not a valid tmux window');
    }
    final p = pane;
    if (p != null && !tmuxPaneIdShape.hasMatch(p)) {
      throw ArgumentError.value(p, 'pane', 'not a valid tmux pane id');
    }
  }

  final String session;
  final String? window;
  final String? pane;

  bool get _windowIsId => window != null && tmuxWindowIdShape.hasMatch(window!);

  /// The tmux target for the window: an id as is, a name as an EXACT
  /// `=session:=name`.
  String? get windowTarget =>
      window == null ? null : (_windowIsId ? window : '=$session:=$window');
}

// The probe is one constant `sh -c` line: no tokens, no single quotes inside,
// busybox ash compatible. Output: `V <tmux -V>`, `M <client_tty> <session>` per
// client sharing our SSH_CONNECTION, `X nosshd|noproc` when the sshd walk
// fails (not fatal: the M lines may still answer), `T /dev/pts/N` per pts
// child of our connection process, `C <client_tty> <session>` per tmux
// client, or `X notmux`.
const _probeScript = [
  r'v=$(tmux -V 2>/dev/null) || { echo "X notmux"; exit 0; };',
  r'echo "V $v";',
  r'c=${SSH_CONNECTION-};',
  r'if [ -n "$c" ]; then',
  r'tmux list-clients -F "#{client_pid} #{client_tty} #{session_name}" 2>/dev/null |',
  r'while read -r cp ct cs; do',
  r'[ -r /proc/$cp/environ ] || continue;',
  r'e=$(tr "\0" "\n" < /proc/$cp/environ 2>/dev/null | sed -n "/^SSH_CONNECTION=/{s///p;q}");',
  r'[ "$e" = "$c" ] && echo "M $ct $cs";',
  r'done; fi;',
  r'p=$$; n=0; w=;',
  r'while :; do',
  r'[ "$p" -gt 1 ] 2>/dev/null || { w=nosshd; break; };',
  r'[ -r /proc/$p/stat ] || { w=noproc; break; };',
  r'case $(cat /proc/$p/comm 2>/dev/null) in sshd*) break;; esac;',
  r'n=$((n+1)); [ $n -lt 12 ] || { w=nosshd; break; };',
  r's=$(cat /proc/$p/stat); set -- ${s##*) }; p=$2;',
  r'done;',
  r'if [ -n "$w" ]; then echo "X $w"; else',
  r'for d in /proc/[0-9]*; do',
  r's=$(cat $d/stat 2>/dev/null) || continue; set -- ${s##*) };',
  r'[ "$2" = "$p" ] || continue;',
  r't=$5; m=$(( (t>>8)&4095 ));',
  r'[ $m -ge 136 ] && [ $m -le 143 ] || continue;',
  r'echo "T /dev/pts/$(( (m-136)*256 + ((t&255) | ((t>>12)&1048320)) ))";',
  r'done; fi;',
  r'tmux list-clients -F "C #{client_tty} #{session_name}" 2>/dev/null;',
  r'exit 0',
];

final String tmuxFindClientExecLine = "sh -c '${_probeScript.join(' ')}'";

/// What the probe concluded. [matched] iff [tty] is set; otherwise [reason] is
/// a short constant for telemetry (never data from the host).
class TmuxClientProbe {
  const TmuxClientProbe.matched(
      String this.tty, String this.session, String this.method)
      : reason = 'matched';
  const TmuxClientProbe.ambiguous(this.reason)
      : tty = null,
        session = null,
        method = null;

  final String? tty;
  final String? session;

  /// `ssh_connection` or `sshd_tree` when matched; a constant for telemetry.
  final String? method;
  final String reason;
  bool get matched => tty != null;
}

final _versionShape = RegExp(r'(\d+)\.(\d+)');

TmuxClientProbe parseTmuxClientProbe(String out) {
  String? version;
  String? walkFailure;
  final ptys = <String>{};
  final clients = <(String, String)>[];
  final byConnection = <(String, String)>[];
  (String, String)? split(String rest) {
    final sp = rest.indexOf(' ');
    return sp > 0 ? (rest.substring(0, sp), rest.substring(sp + 1)) : null;
  }

  for (final line in out.split('\n')) {
    if (line.startsWith('X ')) {
      switch (line.substring(2).trim()) {
        case 'notmux':
          return const TmuxClientProbe.ambiguous('no-tmux');
        case 'noproc':
          walkFailure = 'no-proc';
        default:
          walkFailure = 'no-sshd';
      }
    } else if (line.startsWith('V ')) {
      version = line.substring(2);
    } else if (line.startsWith('T ')) {
      final tty = line.substring(2).trim();
      if (_ttyShape.hasMatch(tty)) ptys.add(tty);
    } else if (line.startsWith('C ')) {
      final c = split(line.substring(2));
      if (c != null) clients.add(c);
    } else if (line.startsWith('M ')) {
      final m = split(line.substring(2));
      if (m != null && _ttyShape.hasMatch(m.$1)) byConnection.add(m);
    }
  }
  if (version == null) {
    return TmuxClientProbe.ambiguous(walkFailure ?? 'no-reply');
  }
  final v = _versionShape.firstMatch(version);
  if (v == null) return const TmuxClientProbe.ambiguous('version-unknown');
  final major = int.parse(v.group(1)!);
  final minor = int.parse(v.group(2)!);
  if (major < 3 || (major == 3 && minor < 2)) {
    return const TmuxClientProbe.ambiguous('old-tmux');
  }
  if (byConnection.length == 1) {
    return TmuxClientProbe.matched(
        byConnection.single.$1, byConnection.single.$2, 'ssh_connection');
  }
  if (walkFailure != null) return TmuxClientProbe.ambiguous(walkFailure);
  if (ptys.isEmpty) return const TmuxClientProbe.ambiguous('no-pty');
  if (ptys.length > 1) return const TmuxClientProbe.ambiguous('multi-pty');
  final ours = [
    for (final c in clients)
      if (c.$1 == ptys.single && _ttyShape.hasMatch(c.$1)) c,
  ];
  if (ours.isEmpty) return const TmuxClientProbe.ambiguous('no-client');
  if (ours.length > 1) return const TmuxClientProbe.ambiguous('multi-client');
  return TmuxClientProbe.matched(ours.single.$1, ours.single.$2, 'sshd_tree');
}

const _execTimeout = Duration(seconds: 10);

String _chomp(String s) => s.endsWith('\n') ? s.substring(0, s.length - 1) : s;

/// Verify, then (live only) switch our client, then select window and pane.
///
/// [live] true: first find our client; not exactly one → [ambiguous] with
/// nothing else run (the caller keeps today's R22b/R23 behaviour). false: the
/// shell is known to be attached to the session (a fresh connect after the
/// attach, or an attach a link made), so the verified selects run directly.
/// The ids are verified to belong to the session BEFORE anything changes, so
/// a mismatch or a stale id leaves tmux untouched. [log] gets one constant
/// line per stage: never the tty, an id, a name or the host.
Future<TmuxLinkOutcome> runTmuxLinkSelect({
  required TmuxLinkTarget target,
  required bool live,
  required TmuxExec exec,
  required void Function(String line) log,
}) async {
  Future<TmuxExecResult> run(String line) => exec(line).timeout(_execTimeout);

  TmuxClientProbe? probe;
  if (live) {
    var p = const TmuxClientProbe.ambiguous('exec-error');
    try {
      final r = await run(tmuxFindClientExecLine);
      p = r.exit == 0
          ? parseTmuxClientProbe(r.out)
          : const TmuxClientProbe.ambiguous('exec-failed');
    } on TimeoutException {
      p = const TmuxClientProbe.ambiguous('timeout');
    } catch (_) {
      // Any channel failure while probing is "cannot tell" → ambiguous.
    }
    if (!p.matched) {
      log('tmux link probe: ambiguous reason=${p.reason}');
      return TmuxLinkOutcome.ambiguous;
    }
    log('tmux link probe: matched method=${p.method}');
    probe = p;
  }

  final session = target.session;
  final window = target.window;
  final pane = target.pane;
  final wt = target.windowTarget;

  try {
    // Verify first: nothing changes unless every token belongs to [session].
    var verified = true;
    var stale = false;
    Future<void> check(String tmuxTarget, String format, String expected) async {
      if (!verified) return;
      final r = await run("tmux display -p -t '$tmuxTarget' '$format'");
      if (r.exit != 0) {
        verified = false;
        stale = true;
      } else if (_chomp(r.out) != expected) {
        verified = false;
      }
    }

    if (wt != null) await check(wt, '#{session_name}', session);
    if (pane != null) {
      if (window == null) {
        await check(pane, '#{session_name}', session);
      } else if (target._windowIsId) {
        await check(pane, '#{session_name} #{window_id}', '$session $window');
      } else {
        await check(pane, '#{session_name} #{window_name}', '$session $window');
      }
    }
    if (!verified) {
      log('tmux link verify: ${stale ? 'stale' : 'mismatch'}');
      return TmuxLinkOutcome.notFound;
    }
    log('tmux link verify: ok');

    Future<bool> ok(String line) async => (await run(line)).exit == 0;

    if (probe != null && probe.session != session) {
      if (!await ok("tmux switch-client -c '${probe.tty}' -t '=$session'")) {
        log('tmux link switch: failed');
        return TmuxLinkOutcome.notFound;
      }
    }
    // A pane alone still has to bring its window forward.
    final winSel = wt ?? pane;
    if (winSel != null && !await ok("tmux select-window -t '$winSel'")) {
      log('tmux link select: failed');
      return TmuxLinkOutcome.notFound;
    }
    if (pane != null && !await ok("tmux select-pane -t '$pane'")) {
      log('tmux link select: failed');
      return TmuxLinkOutcome.notFound;
    }
    return TmuxLinkOutcome.selected;
  } catch (_) {
    // Timeout or a dead channel mid-select: report "not selected" (the
    // neutral notice); the verify-first order means nothing half-applied
    // beyond at most a session switch.
    log('tmux link select: error');
    return TmuxLinkOutcome.notFound;
  }
}
