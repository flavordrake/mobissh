// #1279 S1 — `sftp://` link parser (docs/deep-link-intents.md §15: F1, F2, F6).
//
// Pure Dart, no I/O, no logging. Same posture as `connect_intent.dart`: the
// split is hand-rolled (no `Uri.parse`, which normalises escapes and dot
// segments on its own), every component is percent-decoded exactly once, and
// the result is either a [ConnectRequest] of validated fields with
// `verb: sftp` or a structured rejection. The raw link is never stored.
//
//   sftp://[user[;c-param*(,c-param)]@]host[:port][/path]
//
// - F2: any `:` in the userinfo (a password, even an empty one) rejects the
//   WHOLE link (owner decision D2). It is not stripped and continued.
// - F1/D5: `;fingerprint=` is shape-checked and then ignored; it never trusts
//   or pre-fills a host key. Unknown c-params are ignored (R7).
// - F6: a query or fragment rejects; the path is split on `/` BEFORE decoding,
//   so an encoded separator (`%2F`) is caught; `.`/`..`/empty segments, C0 and
//   DEL reject; `~` / `~/x` are home-relative and `~user` rejects. `;` in the
//   path is a literal character (`;type=` is not interpreted, D5).

import 'dart:convert';

import 'connect_intent.dart';

/// F6 limits.
const int maxLinkLength = 8192;
const int maxLinkPathBytes = 4096;
const int maxLinkSegmentBytes = 255;
const int maxLinkSegments = 64;

const _scheme = 'sftp://';
const _malformed = ConnectIntentRejected(ConnectIntentReason.malformed);
const _badPath = ConnectIntentRejected(ConnectIntentReason.badPath);
const _credential =
    ConnectIntentRejected(ConnectIntentReason.credentialInLink);

final _cParamName = RegExp(r'^[A-Za-z0-9-]+$');
final _fingerprintShape = RegExp(r'^[A-Za-z0-9-]{1,256}$');

ConnectIntentRejected _bad(String key) =>
    ConnectIntentRejected(ConnectIntentReason.badParam, key: key);

/// Every inbound link goes through here: `sftp://` (any case, RFC 3986) to
/// [parseSftpUri], everything else to [parseConnectIntent] (R1 unchanged).
ConnectIntentResult parseLink(String link) {
  if (link.length > maxLinkLength) {
    return const ConnectIntentRejected(ConnectIntentReason.tooLong);
  }
  if (link.toLowerCase().startsWith(_scheme)) return parseSftpUri(link);
  return parseConnectIntent(link);
}

/// Parse an `sftp://` link per F1/F2/F6. Never throws.
ConnectIntentResult parseSftpUri(String link) {
  if (link.length > maxLinkLength) {
    return const ConnectIntentRejected(ConnectIntentReason.tooLong);
  }
  if (link.trim() != link || hasLinkControlChar(link)) return _malformed;
  if (!link.toLowerCase().startsWith(_scheme)) return _malformed;

  final rest = link.substring(_scheme.length);
  if (rest.contains('?') || rest.contains('#')) return _malformed;
  final slash = rest.indexOf('/');
  final authority = slash < 0 ? rest : rest.substring(0, slash);
  final rawPath = slash < 0 ? null : rest.substring(slash);

  String? user;
  var hostPort = authority;
  final at = authority.indexOf('@');
  if (at >= 0) {
    if (authority.indexOf('@', at + 1) >= 0) return _malformed;
    hostPort = authority.substring(at + 1);
    final info = _parseSshInfo(authority.substring(0, at));
    if (info.rejected != null) return info.rejected!;
    user = info.user;
  }

  String rawHost;
  String? rawPort;
  if (hostPort.startsWith('[')) {
    final close = hostPort.indexOf(']');
    if (close < 0) return _bad('host');
    rawHost = hostPort.substring(0, close + 1);
    final after = hostPort.substring(close + 1);
    if (after.isNotEmpty) {
      if (!after.startsWith(':')) return _bad('host');
      rawPort = after.substring(1);
    }
  } else {
    final colon = hostPort.indexOf(':');
    rawHost = colon < 0 ? hostPort : hostPort.substring(0, colon);
    rawPort = colon < 0 ? null : hostPort.substring(colon + 1);
  }
  final decodedHost = decodeLinkOnce(rawHost);
  if (decodedHost == null) return _malformed;
  final host = canonicalLinkHost(decodedHost);
  if (host == null) return _bad('host');

  var port = 22;
  if (rawPort != null) {
    final p = parseLinkPort(rawPort);
    if (p == null) return _bad('port');
    port = p;
  }

  String? path;
  if (rawPath != null) {
    path = _sftpPath(rawPath);
    if (path == null) return _badPath;
  }

  return ConnectIntentParsed(ConnectRequest(
    verb: ConnectVerb.sftp,
    host: host,
    port: port,
    user: user,
    path: path,
  ));
}

/// `ssh-info = [userinfo] [";" c-param *("," c-param)]`.
({String? user, ConnectIntentRejected? rejected}) _parseSshInfo(String info) {
  ({String? user, ConnectIntentRejected? rejected}) no(
          ConnectIntentRejected r) =>
      (user: null, rejected: r);

  // F2: checked on the raw text first, so the value is never decoded/kept.
  if (info.contains(':')) return no(_credential);
  final semi = info.indexOf(';');
  final rawUser = semi < 0 ? info : info.substring(0, semi);
  final rawParams = semi < 0 ? null : info.substring(semi + 1);

  String? user;
  if (rawUser.isEmpty) {
    if (rawParams == null) return no(_bad('user'));
  } else {
    final decoded = decodeLinkOnce(rawUser);
    if (decoded == null) return no(_malformed);
    if (decoded.contains(':')) return no(_credential);
    if (!linkUserShape.hasMatch(decoded)) return no(_bad('user'));
    user = decoded;
  }

  if (rawParams != null) {
    final seen = <String>{};
    for (final pair in rawParams.split(',')) {
      final eq = pair.indexOf('=');
      if (eq <= 0) return no(_malformed);
      final name = pair.substring(0, eq).toLowerCase();
      if (!_cParamName.hasMatch(name)) return no(_malformed);
      if (!seen.add(name)) {
        return no(ConnectIntentRejected(ConnectIntentReason.duplicateKey,
            key: name));
      }
      final value = decodeLinkOnce(pair.substring(eq + 1));
      if (value == null) return no(_malformed);
      // F1/D5: shape-checked, then ignored. Never compared, never trusted.
      if (name == 'fingerprint' && !_fingerprintShape.hasMatch(value)) {
        return no(_bad('fingerprint'));
      }
    }
  }
  return (user: user, rejected: null);
}

/// The sftp:// path (starting with `/`) → the request path, or null.
String? _sftpPath(String rawPath) {
  if (rawPath == '/') return '/';
  final decoded = <String>[];
  for (final seg in rawPath.substring(1).split('/')) {
    final d = decodeLinkOnce(seg);
    // An encoded separator would turn one segment into two after the dot and
    // empty-segment checks ran; reject it rather than guess.
    if (d == null || d.contains('/')) return null;
    decoded.add(d);
  }
  final first = decoded.first;
  final String candidate;
  if (first == '~') {
    candidate = decoded.join('/'); // `~` or `~/rest`: the draft's home rule
  } else if (first.startsWith('~')) {
    return null; // `~user`: another account's home is never addressable
  } else {
    candidate = '/${decoded.join('/')}';
  }
  return validateLinkPath(candidate);
}

/// F6 path rules on an already-decoded path. Returns the path unchanged when
/// it is absolute (`/…`) or home-relative (`~`, `~/…`) and every segment is
/// clean; null otherwise. One trailing `/` is kept (a directory hint, #999).
String? validateLinkPath(String path) {
  if (path.isEmpty || hasLinkControlChar(path)) return null;
  if (utf8.encode(path).length > maxLinkPathBytes) return null;
  final String body;
  if (path.startsWith('/')) {
    body = path.substring(1);
  } else if (path == '~') {
    return path;
  } else if (path.startsWith('~/')) {
    body = path.substring(2);
  } else {
    return null; // relative, or `~user`
  }
  if (body.isEmpty) return path;
  final segments = body.split('/');
  var count = 0;
  for (var i = 0; i < segments.length; i++) {
    final s = segments[i];
    if (s.isEmpty) {
      if (i == segments.length - 1) continue;
      return null;
    }
    if (s == '.' || s == '..') return null;
    if (utf8.encode(s).length > maxLinkSegmentBytes) return null;
    if (++count > maxLinkSegments) return null;
  }
  return path;
}
