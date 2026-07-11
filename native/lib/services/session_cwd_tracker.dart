// session_cwd_tracker.dart — per-session WORKING-DIRECTORY tracking (#1036).
//
// Relative-path anchors (`relpath`, the fork's TextPattern.relativePath) only
// mean something against the session's cwd. This tracker keeps a best-effort
// cwd per terminal session from a LADDER of sources:
//
//   1. OSC 7 — the shell's `file://host/path` cwd advisory, surfaced by
//      libghostty as `TerminalController.pwd` (empty when never set). The
//      strongest signal: shells that emit it do so on every prompt.
//   2. Prompt-derived — the #998 STRONG bash prompt shape `user@host:PATH$ `
//      scanned off the visible rows; PATH is extracted verbatim (`~`-relative
//      forms kept as-is).
//   3. Last-known — both sources are STICKY: a non-prompt line or an empty
//      advisory never clears an earlier answer.
//   4. Home — represented UI-side as `~`. No realpath IPC exists (and none is
//      added): the task-side SFTP layer (#867 expandTilde in sftp_session.dart)
//      expands `~`/`~/x` at the single seam every stat/list/download routes
//      through, so a `~`-prefixed resolved path verifies and navigates
//      correctly without the UI ever knowing the literal home directory.
//
// STALENESS IS TOLERATED BY DESIGN (#1036): a wrong cwd only means the
// resolved candidate fails its #990 SFTP stat, and the relpath anchor simply
// never shows an affordance. Precision lives in the verifier, not here.
//
// Pure Dart (no FFI, no widgets) so the ladder, the OSC 7 / prompt parsing,
// and the resolution join are unit-testable headless.

/// Parse an OSC 7 cwd advisory [raw] (the `TerminalController.pwd` string)
/// to an absolute path, or null when it is unset / unusable.
///
/// Accepts `file://host/path`, `file:///path`, and a bare `/path` (some
/// terminals store the already-stripped path). Percent-decodes the path.
/// Anything else — empty, relative junk, malformed encoding — is null (the
/// ladder treats it as "no advisory"), never a throw.
String? osc7Cwd(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  String path;
  if (s.startsWith('file://')) {
    final rest = s.substring('file://'.length);
    final slash = rest.indexOf('/');
    if (slash < 0) return null; // no path component at all
    path = rest.substring(slash);
  } else if (s.startsWith('/')) {
    path = s;
  } else {
    return null;
  }
  try {
    path = Uri.decodeComponent(path);
  } catch (_) {
    return null; // malformed percent-encoding — treat as unset
  }
  return path.startsWith('/') ? path : null;
}

/// The #998 STRONG bash-prompt shape, anchored at line START, with the PATH
/// captured: `user@host:PATH$ ` / `user@host:PATH# `. Mirrors the fork's
/// `_kStrongPromptAlt` first alternative (`[\w.\-]+@[\w.\-]+:[^\s#$]*[#$]\s`)
/// — the weak `$`/`❯` shapes carry no path, so only the strong shape feeds
/// the cwd ladder.
final RegExp _kStrongPromptPath = RegExp(r'^[\w.\-]+@[\w.\-]+:([^\s#$]*)[#$]');

/// Extract the PATH from a strong `user@host:PATH$` prompt [line], or null
/// when the line is not a strong prompt. `~` / `~/sub` forms are returned
/// verbatim (resolution keeps the `~`; the task-side SFTP seam expands it).
/// An empty PATH (degenerate `user@host:$`) is null.
String? promptCwd(String line) {
  final m = _kStrongPromptPath.firstMatch(line);
  if (m == null) return null;
  final path = m.group(1)!;
  if (path.isEmpty) return null;
  // Only absolute or home-relative prompt paths are usable as a cwd.
  if (!path.startsWith('/') && !path.startsWith('~')) return null;
  return path;
}

/// Join [cwd] and a RELATIVE [relative] into one normalized path (#1036).
///
/// Collapses `.` and `..` segments; `..` never pops past the root (`/`) or
/// the `~` home marker. A trailing slash on [relative] survives (the
/// dir-vs-file browse rule keys off it, #999). [cwd] may be absolute or a
/// `~`-prefixed home form (expanded task-side, #867).
String resolveRelativePath(String cwd, String relative) {
  var base = cwd.isEmpty ? '~' : cwd;
  while (base.length > 1 && base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  final trailingSlash = relative.endsWith('/');
  // The root/home HEAD is fixed: `..` never pops it.
  final String head;
  String rest;
  if (base.startsWith('/')) {
    head = '/';
    rest = base.substring(1);
  } else if (base.startsWith('~')) {
    final slash = base.indexOf('/');
    head = slash < 0 ? base : base.substring(0, slash);
    rest = slash < 0 ? '' : base.substring(slash + 1);
  } else {
    head = '';
    rest = base;
  }
  final segments = [
    for (final s in rest.split('/'))
      if (s.isNotEmpty) s,
  ];
  for (final s in relative.split('/')) {
    if (s.isEmpty || s == '.') continue;
    if (s == '..') {
      if (segments.isNotEmpty) segments.removeLast();
      continue; // never pops past the head
    }
    segments.add(s);
  }
  final joined = segments.join('/');
  var out = head == '/' ? '/$joined' : (joined.isEmpty ? head : '$head/$joined');
  if (trailingSlash && !out.endsWith('/')) out = '$out/';
  return out;
}

/// Per-session cwd state: feed it OSC 7 advisories + candidate prompt lines,
/// read [cwd] / [resolve]. One instance per terminal view == per session, so
/// host A's cwd never bleeds onto host B (the same scoping as the #990
/// SessionPathVerifier).
class SessionCwdTracker {
  String? _osc7;
  String? _prompt;

  /// The current best-effort cwd: OSC 7 > prompt-derived > home (`~`).
  /// Both sources are sticky (last-known wins over nothing).
  String get cwd => _osc7 ?? _prompt ?? '~';

  /// Note an OSC 7 advisory (the controller's `pwd` string). Unparseable /
  /// empty values are ignored (sticky last-known). Returns true when the
  /// effective [cwd] changed.
  bool noteOsc7(String raw) {
    final parsed = osc7Cwd(raw);
    if (parsed == null) return false;
    final before = cwd;
    _osc7 = parsed;
    return cwd != before;
  }

  /// Note a candidate PROMPT line (a visible row's text). Non-prompt lines
  /// are ignored (sticky last-known). Returns true when the effective [cwd]
  /// changed.
  bool notePromptLine(String line) {
    final parsed = promptCwd(line);
    if (parsed == null) return false;
    final before = cwd;
    _prompt = parsed;
    return cwd != before;
  }

  /// Resolve a RELATIVE detected payload against the current [cwd].
  String resolve(String relative) => resolveRelativePath(cwd, relative);
}
