// Resolving a pasted config's `ProxyJump` hops against the saved profiles
// (#1184, spec docs/jump-host.md R18/R20).
//
// The parser (ssh_config_parser.dart) says WHAT the config asks for; this says
// whether this device can express it. The model is a reference — one
// `jumpIdentityKey` per profile (#1183 D1/D2) — so an imported hop has to
// resolve to a profile that EXISTS. It deliberately fails closed: an
// unresolved hop imports NO link at all, because a dangling reference reads
// back as "no jump host" (R1) and would silently connect DIRECT to a host the
// config says must be reached through a bastion.
//
// Pure resolution, no storage and no widgets — the editor turns [notes] into
// visible guidance and writes [chainLinks] when the user saves.

import 'package:flutter/foundation.dart';

import '../storage/profiles_store.dart';
import 'jump_host.dart';
import 'ssh_config_parser.dart';

/// One intermediate link an imported CHAIN needs (R20): [hop] must point at
/// [jumpIdentityKey] for `ProxyJump a,b` to actually route a → b → target.
@immutable
class JumpChainLink {
  const JumpChainLink({required this.hop, required this.jumpIdentityKey});

  /// The profile whose `jumpIdentityKey` has to be (re)written.
  final SavedProfile hop;

  /// The identity key it must point at (the hop one step further OUT).
  final String jumpIdentityKey;
}

/// What an import can do with the parsed hops.
@immutable
class JumpImportOutcome {
  const JumpImportOutcome({
    this.jumpIdentityKey,
    this.chainLinks = const <JumpChainLink>[],
    this.missing = const <SshJumpHop>[],
    this.notes = const <String>[],
  });

  /// The edited profile's own `jumpIdentityKey`, or null when nothing could be
  /// imported. Null is ALWAYS safe: it means "no jump host", never a dangling
  /// reference.
  final String? jumpIdentityKey;

  /// Intermediate links to write when the user saves (R20).
  final List<JumpChainLink> chainLinks;

  /// Hops with no matching profile — R18's "create this profile first".
  final List<SshJumpHop> missing;

  /// Human-readable reasons, shown by the editor. Empty when the import was
  /// clean (or when the config named no jump host at all).
  final List<String> notes;
}

/// Resolve [hops] (outermost-first, as [parseSshConfig] returns them) against
/// [profiles] for the profile being edited ([target]).
///
/// [entries] are the other stanzas from the SAME paste: a bare alias hop names
/// a `Host` stanza, so `ProxyJump bastion` + `Host bastion / HostName 10.0.0.5`
/// resolves to the profile at 10.0.0.5 even though no profile is called
/// "bastion".
///
/// Alias lookup order is `linkAlias` → the pasted stanza's own HostName →
/// host/port/user identity. `linkAlias` (#1140) is the only field in this app
/// that IS an alias and is what the deep-link router already matches on
/// (`connect_link_router.dart`); `title` is free text (spaces, `user@host`) and
/// so cannot be an ssh `Host` token — matching it would resolve a hop by a
/// coincidence of display names.
JumpImportOutcome resolveImportedJumpHops({
  required SavedProfile target,
  required List<SshJumpHop> hops,
  required List<SavedProfile> profiles,
  List<SshConfigEntry> entries = const <SshConfigEntry>[],
}) {
  if (hops.isEmpty) return const JumpImportOutcome();

  // R20 + R3: the depth cap is the connect path's, so refuse the import rather
  // than silently truncating a chain into a different route.
  if (hops.length > kMaxJumpHops) {
    return JumpImportOutcome(notes: <String>[
      'ProxyJump names ${hops.length} hops; MobiSSH connects through at most '
      '$kMaxJumpHops — no jump host was imported.',
    ]);
  }

  final resolved = <SavedProfile>[];
  final missing = <SshJumpHop>[];
  final notes = <String>[];

  for (final hop in hops) {
    final match = _resolveHop(hop, profiles, entries);
    if (match == null) {
      missing.add(hop);
      notes.add(
        'No saved profile matches jump host "${hop.spec}" — create that '
        'profile first, then set it as this profile\'s jump host.',
      );
    } else {
      resolved.add(match);
    }
  }

  // One unresolved hop invalidates the WHOLE chain: importing the reachable
  // part would route the session somewhere the config never named.
  if (missing.isNotEmpty) {
    return JumpImportOutcome(missing: missing, notes: notes);
  }

  // R4 parity: the link must not close a loop. `jumpHostCandidates` is slice
  // 1's own eligibility rule, so the importer and the picker agree by
  // construction.
  bool legal(SavedProfile owner, SavedProfile jump) => jumpHostCandidates(
        owner,
        profiles,
      ).any((p) => p.identityKey == jump.identityKey);

  final direct = resolved.last;
  if (!legal(target, direct)) {
    notes.add(
      'Jump host "${direct.title}" would create a jump-host loop — not '
      'imported.',
    );
    return JumpImportOutcome(notes: notes);
  }

  final links = <JumpChainLink>[];
  for (var i = 0; i + 1 < resolved.length; i++) {
    final outer = resolved[i];
    final inner = resolved[i + 1];
    if (inner.jumpIdentityKey == outer.identityKey) continue; // already linked
    if (!legal(inner, outer)) {
      notes.add(
        'Jump chain "${outer.title}" → "${inner.title}" would create a '
        'jump-host loop — not imported.',
      );
      return JumpImportOutcome(notes: notes);
    }
    links.add(
      JumpChainLink(hop: inner, jumpIdentityKey: outer.identityKey),
    );
  }

  return JumpImportOutcome(
    jumpIdentityKey: direct.identityKey,
    chainLinks: links,
    notes: notes,
  );
}

/// One hop → a saved profile, or null when nothing matches.
SavedProfile? _resolveHop(
  SshJumpHop hop,
  List<SavedProfile> profiles,
  List<SshConfigEntry> entries,
) {
  if (hop.isBareAlias) {
    for (final p in profiles) {
      if (p.linkAlias != null && p.linkAlias == hop.host) return p;
    }
    // The alias may name another stanza in the same paste, which knows the
    // real host.
    for (final e in entries) {
      if (e.isWildcard || e.alias != hop.host) continue;
      final viaStanza = _matchProfile(
        profiles,
        host: e.effectiveHost,
        port: e.port,
        user: e.user,
      );
      if (viaStanza != null) return viaStanza;
    }
  }
  return _matchProfile(
    profiles,
    host: hop.host,
    port: hop.port,
    user: hop.user,
  );
}

/// First profile whose host matches, narrowed by port/user when the spec gave
/// them. An unspecified port/user matches any: `ProxyJump bastion.example.com`
/// names a host, and the saved profile holds the port and account it is
/// reached on.
SavedProfile? _matchProfile(
  List<SavedProfile> profiles, {
  required String host,
  int? port,
  String? user,
}) {
  final wanted = host.toLowerCase();
  for (final p in profiles) {
    if (p.host.toLowerCase() != wanted) continue;
    if (port != null && p.port != port) continue;
    if (user != null && user.isNotEmpty && p.username != user) continue;
    return p;
  }
  return null;
}
