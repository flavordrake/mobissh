// #994 — file:// URLs detected in terminal output are REMOTE paths on the SSH
// host, not local/browser URLs. Pure conversion helpers (no Flutter imports)
// so the action-layer routing is unit-testable headless.

/// The bare absolute remote path a `file://` URI names, or null when [url] is
/// not a well-formed file URL (#994).
///
/// `ls --hyperlink` / eza emit `file://HOSTNAME/path` (the remote hostname as
/// authority); plain tooling emits `file:///path` (empty authority). Both
/// resolve to `/path` — on an SSH client the file lives on the CONNECTED
/// session's host, so the authority is stripped, never trusted. The path part
/// is percent-decoded (UTF-8). Malformed input — no path after the authority,
/// a bad percent escape, invalid UTF-8 — returns null so the caller falls
/// back to plain-URL handling rather than navigating somewhere wrong.
///
/// The scheme matches case-insensitively (RFC 3986). A trailing slash is
/// PRESERVED — it feeds the #999 dir-vs-file browse rule downstream.
String? fileUrlToRemotePath(String url) {
  final s = url.trim();
  const scheme = 'file://';
  if (s.length <= scheme.length) return null;
  if (s.substring(0, scheme.length).toLowerCase() != scheme) return null;
  final rest = s.substring(scheme.length);
  // The path begins at the first '/': index 0 means an EMPTY authority
  // (file:///path); a later index means a hostname authority to strip
  // (file://host/path). No '/' at all means no path — malformed.
  final slash = rest.indexOf('/');
  if (slash < 0) return null;
  final encoded = rest.substring(slash);
  try {
    // decodeComponent: %XX (incl. multi-byte UTF-8) → chars; '+' stays a
    // literal plus (this is a path, not a query).
    return Uri.decodeComponent(encoded);
  } on ArgumentError {
    return null; // truncated/invalid percent escape — reject, don't guess
  } on FormatException {
    return null; // invalid UTF-8 in the escape bytes — reject, don't guess
  }
}

/// The canonical `sftp://user@host[:port]/path` form of a remote [path] on
/// the session identified by [username]/[host]/[port] (#994).
///
/// The default SSH port 22 is omitted. Built via [Uri] so the userInfo/host/
/// path are percent-encoded correctly (a space in the path yields a valid URL).
String sftpUrlForRemotePath({
  required String username,
  required String host,
  required int port,
  required String path,
}) {
  return Uri(
    scheme: 'sftp',
    userInfo: username,
    host: host,
    port: port == 22 ? null : port,
    path: path,
  ).toString();
}
