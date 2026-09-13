// #1139 (PR A of #1117) — `mobissh://` ConnectRequest parser + profile matcher.
//
// Implements docs/deep-link-intents.md R1–R11: the grammar (§3) and the
// field-wise profile matching (§4). Pure Dart: no Flutter, no I/O, no logging.
// The raw link string is never stored, logged or interpolated anywhere — it is
// split, decoded exactly once, validated, and either becomes a
// [ConnectRequest] of validated fields or a structured rejection reason.
//
// The split is hand-rolled rather than `Uri.parse` because `Uri` normalises
// percent-escapes and case on its own; R2 demands a single decode where a
// double-encoded `%252E` must survive as `%2E` and then fail the host rule.

import 'dart:convert';

import '../storage/profiles_store.dart';

enum ConnectVerb { connect, create }

/// A validated link. Every field already passed its R3–R6 rule; [host] is
/// canonical (lower-cased, IPv6 without brackets).
class ConnectRequest {
  const ConnectRequest({
    required this.verb,
    this.host,
    this.port = 22,
    this.user,
    this.name,
    this.tmux,
  });

  final ConnectVerb verb;
  final String? host;
  final int port;
  final String? user;

  /// Link alias on `connect` (R5), label on `create`.
  final String? name;

  /// Validated per R6. Grammar only — the v1.1 wiring lands in PR E.
  final String? tmux;
}

enum ConnectIntentReason { malformed, unknownVerb, badParam, duplicateKey, reserved }

sealed class ConnectIntentResult {
  const ConnectIntentResult();
}

final class ConnectIntentParsed extends ConnectIntentResult {
  const ConnectIntentParsed(this.request);
  final ConnectRequest request;
}

final class ConnectIntentRejected extends ConnectIntentResult {
  const ConnectIntentRejected(this.reason, {this.key});
  final ConnectIntentReason reason;

  /// The offending parameter for badParam / duplicateKey / reserved.
  final String? key;
}

const _scheme = 'mobissh://';

final _verbShape = RegExp(r'^[A-Za-z]+$');
final _label = RegExp(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$');
final _portShape = RegExp(r'^[0-9]{1,5}$');
final _userShape = RegExp(r'^[A-Za-z0-9._-]{1,64}$');
final _nameShape = RegExp(r'^[A-Za-z0-9_-]{1,32}$');
/// R6 tmux name shape; shared with `link_verb.dart` (R22 re-check).
final tmuxNameShape = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_-]{0,31}$');

/// Parse a `mobissh://` link per R1–R7. Never throws: any input that is not a
/// well-formed link yields [ConnectIntentRejected].
ConnectIntentResult parseConnectIntent(String link) {
  const malformed = ConnectIntentRejected(ConnectIntentReason.malformed);

  if (link.trim() != link || _hasControlChar(link)) return malformed;
  if (!link.startsWith(_scheme)) return malformed;

  final rest = link.substring(_scheme.length);
  final q = rest.indexOf('?');
  final verbText = q < 0 ? rest : rest.substring(0, q);
  if (!_verbShape.hasMatch(verbText)) return malformed;
  final verb = switch (verbText) {
    'connect' => ConnectVerb.connect,
    'create' => ConnectVerb.create,
    _ => null,
  };
  if (verb == null) {
    return const ConnectIntentRejected(ConnectIntentReason.unknownVerb);
  }

  final params = <String, String>{};
  if (q >= 0 && q + 1 < rest.length) {
    for (final pair in rest.substring(q + 1).split('&')) {
      final eq = pair.indexOf('=');
      final rawKey = eq < 0 ? pair : pair.substring(0, eq);
      final rawValue = eq < 0 ? '' : pair.substring(eq + 1);
      final key = _decodeOnce(rawKey);
      final value = _decodeOnce(rawValue);
      if (key == null || value == null || key.isEmpty) return malformed;
      if (_hasControlChar(key) || _hasControlChar(value)) return malformed;
      if (value.trim() != value) return malformed;
      if (params.containsKey(key)) {
        return ConnectIntentRejected(ConnectIntentReason.duplicateKey, key: key);
      }
      params[key] = value;
    }
  }

  // R7/R24: a reserved action rejects the whole link before anything else can
  // make it look like a plain connect.
  if (params.containsKey('claude')) {
    return const ConnectIntentRejected(ConnectIntentReason.reserved,
        key: 'claude');
  }

  String? host;
  if (params.containsKey('host')) {
    host = _canonicalLinkHost(params['host']!);
    if (host == null) return _bad('host');
  }

  var port = 22;
  if (params.containsKey('port')) {
    final text = params['port']!;
    final n = _portShape.hasMatch(text) ? int.parse(text) : 0;
    if (n < 1 || n > 65535) return _bad('port');
    port = n;
  }

  final user = params['user'];
  if (user != null && !_userShape.hasMatch(user)) return _bad('user');

  final name = params['name'];
  if (name != null && !_nameShape.hasMatch(name)) return _bad('name');

  final tmux = params['tmux'];
  if (tmux != null) {
    if (verb == ConnectVerb.create || !tmuxNameShape.hasMatch(tmux)) {
      return _bad('tmux');
    }
  }

  final required = switch (verb) {
    ConnectVerb.connect => host != null || name != null,
    ConnectVerb.create => host != null,
  };
  if (!required) return malformed;

  return ConnectIntentParsed(ConnectRequest(
    verb: verb,
    host: host,
    port: port,
    user: user,
    name: name,
    tmux: tmux,
  ));
}

ConnectIntentRejected _bad(String key) =>
    ConnectIntentRejected(ConnectIntentReason.badParam, key: key);

bool _hasControlChar(String s) {
  for (final c in s.codeUnits) {
    if (c < 0x20 || c == 0x7f) return true;
  }
  return false;
}

int _hexDigit(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  return -1;
}

/// Percent-decode exactly once. `+` stays literal. A dangling or non-hex
/// escape, or a byte sequence that is not UTF-8, yields null (malformed).
String? _decodeOnce(String s) {
  final bytes = <int>[];
  final text = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final c = s.codeUnitAt(i);
    if (c != 0x25) {
      text.writeCharCode(c);
      i++;
      continue;
    }
    if (i + 2 >= s.length) return null;
    final hi = _hexDigit(s.codeUnitAt(i + 1));
    final lo = _hexDigit(s.codeUnitAt(i + 2));
    if (hi < 0 || lo < 0) return null;
    bytes.addAll(utf8.encode(text.toString()));
    text.clear();
    bytes.add(hi * 16 + lo);
    i += 3;
  }
  bytes.addAll(utf8.encode(text.toString()));
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

/// R3: RFC 1123 labels or bracketed IPv6. Returns the canonical host (lower-
/// cased, brackets stripped) or null when the value is not a bare host.
String? _canonicalLinkHost(String raw) {
  if (raw.startsWith('[') && raw.endsWith(']')) {
    final inner = raw.substring(1, raw.length - 1);
    try {
      Uri.parseIPv6Address(inner);
    } on FormatException {
      return null;
    }
    return _canonicalHost(inner);
  }
  final host = _canonicalHost(raw);
  if (host.isEmpty) return null;
  for (final label in host.split('.')) {
    if (!_label.hasMatch(label)) return null;
  }
  return host;
}

/// The one canonical host form used on BOTH sides of a match (R8).
String _canonicalHost(String host) => host.toLowerCase();

sealed class ConnectMatch {
  const ConnectMatch();
}

final class Matched extends ConnectMatch {
  const Matched(this.profile);
  final SavedProfile profile;
}

final class Ambiguous extends ConnectMatch {
  const Ambiguous(this.candidates);
  final List<SavedProfile> candidates;
}

final class NoMatch extends ConnectMatch {
  const NoMatch();
}

final class AliasMiss extends ConnectMatch {
  const AliasMiss();
}

/// R8–R11. Field-wise identity match (host canonicalised on both sides, port
/// as an int, username byte-exact); `identityKey` is never parsed. `name` on
/// `connect` resolves through [alias] only — a duplicated alias is
/// [Ambiguous], never the first hit (R10). `create` walks the same identity
/// so an existing profile is [Matched] instead of duplicated (R11).
ConnectMatch matchConnectRequest(
  ConnectRequest request,
  List<SavedProfile> profiles, {
  required String? Function(SavedProfile) alias,
}) {
  if (request.verb == ConnectVerb.connect && request.name != null) {
    final hits = profiles.where((p) => alias(p) == request.name).toList();
    if (hits.isEmpty) return const AliasMiss();
    if (hits.length == 1) return Matched(hits.first);
    return Ambiguous(hits);
  }

  final host = request.host;
  if (host == null) return const NoMatch();
  final want = _canonicalHost(host);
  final hits = profiles
      .where((p) =>
          _canonicalHost(p.host) == want &&
          p.port == request.port &&
          (request.user == null || p.username == request.user))
      .toList();
  if (hits.isEmpty) return const NoMatch();
  if (hits.length == 1) return Matched(hits.first);
  return Ambiguous(hits);
}
