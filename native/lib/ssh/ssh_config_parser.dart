// Minimal parser for pasted OpenSSH `~/.ssh/config` entries (goal: quick
// profile import). It understands only the directives that map onto a
// [SavedProfile] — `Host`, `HostName`, `Port`, `User`, `IdentityFile` — and
// ignores everything else (ProxyJump, ForwardAgent, …) rather than failing, so
// pasting a real-world block that carries extra directives still imports the
// fields we support.
//
// Deliberately NOT a full ssh_config implementation: no `Match`, no `Include`,
// no wildcard resolution against a real hostname. A pasted block is a set of
// literal `Host` stanzas the user wants to turn into profiles; we surface each
// concrete stanza and let the editor map one onto its fields.

import 'package:flutter/foundation.dart';

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
      other.identityFile == identityFile;

  @override
  int get hashCode => Object.hash(alias, hostName, port, user, identityFile);

  @override
  String toString() =>
      'SshConfigEntry(alias: $alias, hostName: $hostName, port: $port, '
      'user: $user, identityFile: $identityFile)';
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

  void flush() {
    if (alias != null) {
      entries.add(SshConfigEntry(
        alias: alias!,
        hostName: hostName,
        port: port,
        user: user,
        identityFile: identityFile,
      ));
    }
    alias = null;
    hostName = null;
    port = null;
    user = null;
    identityFile = null;
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
      default:
        break; // ignore unsupported directives
    }
  }
  flush();
  return entries;
}
