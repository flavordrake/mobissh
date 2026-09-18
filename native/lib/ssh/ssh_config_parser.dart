// Minimal parser for pasted OpenSSH `~/.ssh/config` entries (goal: quick
// profile import). It understands only the directives that map onto a
// [SavedProfile] — `Host`, `HostName`, `Port`, `User`, `IdentityFile`,
// `ProxyJump` — and ignores everything else (ForwardAgent, …) rather than
// failing, so pasting a real-world block that carries extra directives still
// imports the fields we support.
//
// `ProxyJump` (#1184, spec docs/jump-host.md R17-R20) is the one exception to
// "ignore what we don't support": it maps onto the jump-host model (#1183), so
// it parses into [SshConfigEntry.proxyJump]. `ProxyCommand` is read ONLY for
// its legacy `ssh -W %h:%p <hop>` spelling of the same thing (R19); any other
// ProxyCommand yields a NAMED reason in [SshConfigEntry.proxyCommandNote]
// rather than a silent drop — silently dropping it would produce a profile
// that connects differently from the config it came from.
//
// Deliberately NOT a full ssh_config implementation: no `Match`, no `Include`,
// no wildcard resolution against a real hostname. A pasted block is a set of
// literal `Host` stanzas the user wants to turn into profiles; we surface each
// concrete stanza and let the editor map one onto its fields.

import 'package:flutter/foundation.dart';

/// One hop from a `ProxyJump` chain (R17): either a bare alias naming another
/// `Host` stanza / saved profile, or a literal `[user@]host[:port]`.
///
/// The two cases are not distinguished by a flag the config carries — ssh
/// itself resolves a bare token against the config's `Host` patterns and falls
/// back to treating it as a hostname. [isBareAlias] records "no user and no
/// port were given", which is exactly the case the importer has to look up
/// before it can write a reference.
@immutable
class SshJumpHop {
  const SshJumpHop({required this.host, this.user, this.port});

  /// The alias token, or the literal hostname.
  final String host;

  /// `user@` prefix, when the spec carried one.
  final String? user;

  /// `:port` suffix, when the spec carried one.
  final int? port;

  /// True when the spec was a bare token — an alias OR a hostname; the
  /// importer decides which by looking it up.
  bool get isBareAlias => user == null && port == null;

  /// The spec as ssh would write it — used in user-facing messages so the note
  /// names the hop exactly as the pasted config did.
  String get spec =>
      '${user == null ? '' : '$user@'}$host${port == null ? '' : ':$port'}';

  @override
  bool operator ==(Object other) =>
      other is SshJumpHop &&
      other.host == host &&
      other.user == user &&
      other.port == port;

  @override
  int get hashCode => Object.hash(host, user, port);

  @override
  String toString() => 'SshJumpHop($spec)';
}

/// Parse one `[user@]host[:port]` hop spec. Returns null when the spec is
/// malformed — a malformed hop is DROPPED (R17: ignored like any other
/// unsupported value, never a throw), because importing half a hop would point
/// the connection somewhere the config never named.
SshJumpHop? parseJumpHopSpec(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return null;

  String? user;
  final at = s.lastIndexOf('@');
  if (at >= 0) {
    user = s.substring(0, at).trim();
    s = s.substring(at + 1).trim();
    if (user.isEmpty) return null; // '@host'
  }
  if (s.isEmpty) return null; // 'user@'

  int? port;
  if (s.startsWith('[')) {
    // Bracketed IPv6, optionally `]:port`.
    final close = s.indexOf(']');
    if (close < 0) return null;
    final rest = s.substring(close + 1).trim();
    if (rest.isNotEmpty) {
      if (!rest.startsWith(':')) return null;
      port = int.tryParse(rest.substring(1));
      if (port == null) return null;
    }
    s = s.substring(1, close).trim();
  } else {
    final lastColon = s.lastIndexOf(':');
    // Several colons and no brackets = a bare IPv6 literal, not host:port.
    if (lastColon >= 0 && s.indexOf(':') == lastColon) {
      port = int.tryParse(s.substring(lastColon + 1));
      if (port == null) return null;
      s = s.substring(0, lastColon).trim();
    }
  }
  if (s.isEmpty || s.contains(RegExp(r'\s'))) return null;
  if (port != null && (port < 1 || port > 65535)) return null;
  return SshJumpHop(host: s, user: user, port: port);
}

/// ssh flags that consume the following token — needed so the legacy
/// `ProxyCommand` reader can tell a flag's ARGUMENT from the hop.
const Set<String> _sshFlagsWithArg = <String>{
  '-b', '-c', '-e', '-F', '-i', '-l', '-m', '-o', '-p', '-Q', '-S', '-w',
};

/// R19: recognise `ProxyCommand ssh [-flags] -W %h:%p [-p N] [-l user] <hop>`
/// — the pre-`ProxyJump` spelling of the same thing — and return its hop.
/// Returns null for ANY other ProxyCommand; the caller turns that into a named
/// reason rather than dropping it silently.
SshJumpHop? _hopFromProxyCommand(String value) {
  final tokens = value
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList(growable: false);
  if (tokens.isEmpty) return null;
  // `ssh`, `/usr/bin/ssh`, … — anything else is a different program entirely.
  if (tokens.first.split('/').last != 'ssh') return null;

  var sawForward = false;
  String? flagUser;
  int? flagPort;
  String? hopToken;

  for (var i = 1; i < tokens.length; i++) {
    final t = tokens[i];
    if (t == '-W' || t == '-W%h:%p') {
      if (t == '-W') {
        if (i + 1 >= tokens.length || tokens[i + 1] != '%h:%p') return null;
        i++;
      }
      sawForward = true;
      continue;
    }
    if (_sshFlagsWithArg.contains(t)) {
      if (i + 1 >= tokens.length) return null;
      final arg = tokens[i + 1];
      if (t == '-p') {
        flagPort = int.tryParse(arg);
        if (flagPort == null) return null;
      } else if (t == '-l') {
        flagUser = arg;
      }
      i++;
      continue;
    }
    if (t.startsWith('-')) continue; // a bare flag or flag bundle (-q, -nT)
    if (hopToken != null) return null; // two operands — not a plain hop
    hopToken = t;
  }

  if (!sawForward || hopToken == null) return null;
  final hop = parseJumpHopSpec(hopToken);
  if (hop == null) return null;
  // An explicit `user@host:port` in the operand wins over -l / -p.
  return SshJumpHop(
    host: hop.host,
    user: hop.user ?? flagUser,
    port: hop.port ?? flagPort,
  );
}

/// One parsed `Host` stanza. [alias] is the first pattern on the `Host` line
/// (what the user typed after `Host`); the connect target is [effectiveHost]
/// (the `HostName` when given, else the alias — matching ssh's own fallback).
@immutable
class SshConfigEntry {
  const SshConfigEntry({
    required this.alias,
    this.hostName,
    this.port,
    this.user,
    this.identityFile,
    this.proxyJump = const <SshJumpHop>[],
    this.proxyCommandNote,
  });

  /// First pattern token from the `Host` line (e.g. `prod` in `Host prod db`).
  final String alias;

  /// `HostName` directive — the real host to dial. Null when the stanza relies
  /// on the alias BEING the hostname (common for one-off `Host <fqdn>` blocks).
  final String? hostName;

  /// `Port` directive, if a valid integer was given.
  final int? port;

  /// `User` directive.
  final String? user;

  /// `IdentityFile` path. A hint only: it names a file on the machine the
  /// config came FROM (a desktop), which this device cannot read — the editor
  /// uses it to prompt "pick a stored key or paste the secret", never to load a
  /// file.
  final String? identityFile;

  /// `ProxyJump` hops in ssh's own order — OUTERMOST FIRST (R17/R20): index 0
  /// is dialled first, the last hop is the one that reaches this host. Empty
  /// when the stanza names no jump host (or names `none`, ssh's own "no
  /// proxy" value), or when the value was malformed.
  final List<SshJumpHop> proxyJump;

  /// R19: a human-readable reason naming a `ProxyCommand` that was NOT the
  /// legacy `ssh -W %h:%p` spelling and so could not be imported. Null when
  /// there was no ProxyCommand, or when it mapped onto [proxyJump]. The
  /// importer must SHOW this: a profile that silently drops its ProxyCommand
  /// connects differently from the config it came from.
  final String? proxyCommandNote;

  /// The host to connect to: [hostName] when present and non-empty, else the
  /// [alias] (ssh falls back to the Host pattern when HostName is absent).
  String get effectiveHost =>
      (hostName != null && hostName!.trim().isNotEmpty) ? hostName!.trim() : alias;

  /// True when the alias is a glob pattern (`Host *`, `Host 10.0.*`). These are
  /// defaults in a real config, not a single importable host — the UI skips
  /// them when offering entries to import.
  bool get isWildcard => alias.contains('*') || alias.contains('?');

  @override
  bool operator ==(Object other) =>
      other is SshConfigEntry &&
      other.alias == alias &&
      other.hostName == hostName &&
      other.port == port &&
      other.user == user &&
      other.identityFile == identityFile &&
      listEquals(other.proxyJump, proxyJump) &&
      other.proxyCommandNote == proxyCommandNote;

  @override
  int get hashCode => Object.hash(
        alias,
        hostName,
        port,
        user,
        identityFile,
        Object.hashAll(proxyJump),
        proxyCommandNote,
      );

  @override
  String toString() =>
      'SshConfigEntry(alias: $alias, hostName: $hostName, port: $port, '
      'user: $user, identityFile: $identityFile, '
      'proxyJump: ${proxyJump.map((h) => h.spec).toList()}, '
      'proxyCommandNote: $proxyCommandNote)';
}

/// Render a profile's ssh-mappable fields as an OpenSSH `~/.ssh/config` Host
/// block, copy-ready. The inverse of [parseSshConfig] over the directives this
/// app understands (Host/HostName/Port/User/IdentityFile): feeding the output
/// back through [parseSshConfig] yields the same fields.
///
/// [port] is emitted only when non-default (22) — idiomatic configs omit the
/// default and the parser restores 22 when `Port` is absent. [user] and
/// [identityFile] are emitted only when non-empty. Two-space indent matches the
/// import hint the editor shows.
String formatSshConfig({
  required String alias,
  required String host,
  int port = 22,
  String? user,
  String? identityFile,
}) {
  final b = StringBuffer('Host ${alias.trim()}\n');
  b.write('  HostName ${host.trim()}\n');
  if (port != 22) b.write('  Port $port\n');
  final u = user?.trim() ?? '';
  if (u.isNotEmpty) b.write('  User $u\n');
  final id = identityFile?.trim() ?? '';
  if (id.isNotEmpty) b.write('  IdentityFile $id\n');
  return b.toString();
}

/// Parse pasted ssh-config [text] into its `Host` stanzas, in file order.
///
/// Directives before the first `Host` line (global defaults in a real config)
/// are ignored — a pasted import is about concrete host blocks. Unknown
/// directives inside a block are ignored. Both `Keyword value` and
/// `Keyword=value` forms are accepted, values may be double-quoted, and
/// keywords are case-insensitive (ssh treats them so). A `Host` line with
/// several patterns contributes ONE entry keyed by its first pattern.
List<SshConfigEntry> parseSshConfig(String text) {
  final entries = <SshConfigEntry>[];

  String? alias;
  String? hostName;
  int? port;
  String? user;
  String? identityFile;
  // R19 precedence: an explicit ProxyJump wins over a legacy ProxyCommand, as
  // it does in ssh — so both are collected and resolved at flush time.
  List<SshJumpHop>? proxyJump;
  String? proxyCommand;

  void flush() {
    if (alias != null) {
      var hops = proxyJump;
      String? note;
      if (hops == null && proxyCommand != null) {
        final hop = _hopFromProxyCommand(proxyCommand!);
        if (hop != null) {
          hops = <SshJumpHop>[hop];
        } else {
          note =
              'Ignored ProxyCommand "$proxyCommand" — only the legacy '
              '`ssh -W %h:%p <host>` form imports as a jump host. Set this '
              "profile's jump host by hand if it needs one.";
        }
      }
      entries.add(SshConfigEntry(
        alias: alias!,
        hostName: hostName,
        port: port,
        user: user,
        identityFile: identityFile,
        proxyJump: hops ?? const <SshJumpHop>[],
        proxyCommandNote: note,
      ));
    }
    alias = null;
    hostName = null;
    port = null;
    user = null;
    identityFile = null;
    proxyJump = null;
    proxyCommand = null;
  }

  for (final rawLine in text.split('\n')) {
    var line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;

    // Split "Keyword value" or "Keyword=value" into keyword + remainder.
    final eq = line.indexOf('=');
    final sp = line.indexOf(RegExp(r'\s'));
    int splitAt;
    if (eq >= 0 && (sp < 0 || eq < sp)) {
      splitAt = eq;
    } else if (sp >= 0) {
      splitAt = sp;
    } else {
      // A bare keyword with no value — nothing to apply.
      continue;
    }
    final keyword = line.substring(0, splitAt).toLowerCase();
    var value = line.substring(splitAt + 1).trim();
    if (value.isEmpty) continue;
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }

    switch (keyword) {
      case 'host':
        // A new stanza starts — commit the one in progress first.
        flush();
        // Host may list several patterns; the first is the entry's identity.
        alias = value.split(RegExp(r'\s+')).first;
        break;
      case 'hostname':
        if (alias != null) hostName = value;
        break;
      case 'port':
        if (alias != null) port = int.tryParse(value);
        break;
      case 'user':
        if (alias != null) user = value;
        break;
      case 'identityfile':
        // One path per directive; a config may repeat it — first one wins
        // (matches ssh trying them in order). The whole value is the path, so a
        // quoted path containing a space stays intact.
        if (alias != null) identityFile ??= value;
        break;
      case 'proxyjump':
        // First directive wins (ssh's own first-obtained-value rule). `none`
        // is ssh's explicit "no proxy" value; a malformed hop is dropped, so a
        // wholly malformed value reads as "no jump host" rather than throwing.
        if (alias != null) {
          proxyJump ??= value.toLowerCase() == 'none'
              ? const <SshJumpHop>[]
              : <SshJumpHop>[
                  for (final part in value.split(',')) ?parseJumpHopSpec(part),
                ];
        }
        break;
      case 'proxycommand':
        if (alias != null) proxyCommand ??= value;
        break;
      default:
        break; // ignore unsupported directives
    }
  }
  flush();
  return entries;
}
