// Export saved profiles AS `~/.ssh/config` text (#1185, slice 3 of #1182 —
// R21-R24). The inverse of the paste-to-import path: pure serialisation over
// the SAME directives [parseSshConfig] understands, so the output re-imports
// to the profiles it came from (R24).
//
// R22 is the point of this file: it takes SavedProfiles (metadata) and NOTHING
// else. No vault, no SecretsStore, no key material is reachable from here, so
// no password, private key or passphrase can be written — the guarantee is
// structural, not a field-by-field skip list. Key auth exports an
// `IdentityFile` HINT only when the profile's attached library key is NAMED
// like a path on the receiving machine (`~/.ssh/id_ed25519`); otherwise the
// directive is omitted and the profile is NAMED in the header, because an
// export that looks complete but cannot authenticate is worse than one that
// says what it is missing.

import 'package:flutter/foundation.dart';

import '../storage/keys_store.dart';
import '../storage/profiles_store.dart';
import 'ssh_config_parser.dart';

/// Suggested file name for the shared artifact.
const String sshConfigExportFileName = 'mobissh-ssh-config.txt';

/// Max length of a generated `Host` token (mirrors
/// [SavedProfile.linkAliasPattern]'s cap so generated and explicit aliases
/// share one grammar).
const int _aliasMaxLength = 32;

/// Characters legal in a generated `Host` token. Deliberately narrower than
/// ssh's own grammar: no whitespace (would split the token), no `*`/`?` (would
/// make the stanza a wildcard DEFAULT rather than a host), no `#` (comment).
final RegExp _aliasIllegal = RegExp(r'[^a-z0-9_.\-]+');

/// A key NAME that is usable as an `IdentityFile` hint: an absolute, `~`- or
/// `.`-relative path with no whitespace. A friendly name ("work laptop") is
/// not a path and must never be emitted as one.
final RegExp _pathLikeHint = RegExp(r'^(~|\.{1,2})?/\S*$');

/// The rendered export plus what it could NOT express.
@immutable
class SshConfigExport {
  const SshConfigExport({
    required this.text,
    required this.aliasByIdentityKey,
    required this.needsManualKey,
    required this.unresolvedJumps,
  });

  /// The full `~/.ssh/config` document: a header comment block, then one
  /// `Host` stanza per profile in the order given.
  final String text;

  /// Profile [SavedProfile.identityKey] → the `Host` token it was exported
  /// under. The link between the exported text and the profiles it came from
  /// (used by the round-trip assertion and by the preview).
  final Map<String, String> aliasByIdentityKey;

  /// Aliases of key-auth profiles exported WITHOUT an `IdentityFile` — they
  /// need a key configured by hand on the receiving machine (R22).
  final List<String> needsManualKey;

  /// Aliases of profiles whose jump host is not part of this export, so their
  /// `ProxyJump` had to be dropped (R21).
  final List<String> unresolvedJumps;
}

/// Render [profiles] as ssh_config text (R21-R24).
///
/// [keys] is the key LIBRARY (#1088) — used ONLY to read an attached key's
/// NAME for the `IdentityFile` hint. Key material lives in the vault and is
/// not reachable from this function.
SshConfigExport buildSshConfigExport(
  List<SavedProfile> profiles, {
  List<SavedKey> keys = const <SavedKey>[],
}) {
  final aliasByIdentityKey = _assignAliases(profiles);
  final keyNameByVaultId = <String, String>{
    for (final k in keys) k.vaultId: k.name,
  };
  final exported = <String>{for (final p in profiles) p.identityKey};

  final needsManualKey = <String>[];
  final unresolvedJumps = <String>[];
  final stanzas = StringBuffer();

  for (final p in profiles) {
    final alias = aliasByIdentityKey[p.identityKey]!;

    String? hint;
    if (_isKeyAuth(p)) {
      final name = p.keyVaultId == null ? null : keyNameByVaultId[p.keyVaultId];
      if (name != null && _pathLikeHint.hasMatch(name.trim())) {
        hint = name.trim();
      } else {
        needsManualKey.add(alias);
      }
    }

    String? jump;
    final jumpKey = p.jumpIdentityKey;
    if (jumpKey != null && jumpKey.isNotEmpty) {
      if (exported.contains(jumpKey)) {
        jump = aliasByIdentityKey[jumpKey];
      } else {
        // The hop is not in this export (deleted, or a partial selection):
        // emitting its alias would produce a config that cannot resolve it.
        unresolvedJumps.add(alias);
      }
    }

    stanzas.write(formatSshConfig(
      alias: alias,
      host: p.host,
      port: p.port,
      user: p.username,
      identityFile: hint,
      proxyJump: jump,
    ));
    stanzas.write('\n');
  }

  final header = StringBuffer()
    ..write('# MobiSSH export — ${profiles.length} '
        '${profiles.length == 1 ? 'host' : 'hosts'}\n')
    ..write('# Contains NO secrets. Nothing from the credential vault is '
        'written here.\n');
  if (needsManualKey.isNotEmpty) {
    header.write('# Configure a key by hand for: '
        '${needsManualKey.join(', ')}\n');
  }
  if (unresolvedJumps.isNotEmpty) {
    header.write('# Jump host not included in this export, ProxyJump dropped: '
        '${unresolvedJumps.join(', ')}\n');
  }
  header.write('\n');

  return SshConfigExport(
    text: '$header$stanzas',
    aliasByIdentityKey: Map<String, String>.unmodifiable(aliasByIdentityKey),
    needsManualKey: List<String>.unmodifiable(needsManualKey),
    unresolvedJumps: List<String>.unmodifiable(unresolvedJumps),
  );
}

/// Key auth: the explicit `authType`, or a legacy profile that merely has a key
/// attached. Either way the export cannot carry the key itself.
bool _isKeyAuth(SavedProfile p) =>
    p.authType == 'key' || (p.keyVaultId != null && p.keyVaultId!.isNotEmpty);

/// `linkAlias` (#1140) when set — it is the name the user already chose for
/// this profile — else a slug of the title, else a slug of the host. Explicit
/// aliases are assigned FIRST so a generated slug yields to them on collision;
/// every alias in the result is distinct (a duplicate `Host` token would make
/// two profiles one).
Map<String, String> _assignAliases(List<SavedProfile> profiles) {
  final taken = <String>{};
  final result = <String, String>{};

  for (final p in profiles) {
    final explicit = p.linkAlias;
    if (explicit != null && explicit.isNotEmpty) {
      result[p.identityKey] = _uniquify(explicit, taken);
    }
  }
  for (final p in profiles) {
    if (result.containsKey(p.identityKey)) continue;
    var base = _slugify(p.title);
    if (base.isEmpty) base = _slugify(p.host);
    if (base.isEmpty) base = 'host';
    result[p.identityKey] = _uniquify(base, taken);
  }
  return result;
}

String _slugify(String raw) {
  var s = raw.trim().toLowerCase().replaceAll(_aliasIllegal, '-');
  if (s.length > _aliasMaxLength) s = s.substring(0, _aliasMaxLength);
  return s.replaceAll(RegExp(r'^[-.]+'), '').replaceAll(RegExp(r'[-.]+$'), '');
}

String _uniquify(String base, Set<String> taken) {
  if (taken.add(base)) return base;
  for (var n = 2;; n++) {
    final suffix = '-$n';
    final head = base.length + suffix.length > _aliasMaxLength
        ? base.substring(0, _aliasMaxLength - suffix.length)
        : base;
    final candidate = '$head$suffix';
    if (taken.add(candidate)) return candidate;
  }
}
