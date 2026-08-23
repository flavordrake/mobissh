// Encrypted-backup RESTORE (#1125, Part C — codex-resolved semantics).
//
// Applies a DECRYPTED v2 backup payload (see backup.dart for the envelope and
// #1124's backup_payload.dart for the export-side gathering) to the local
// stores. Payload contract (all sections optional, unknown sections ignored):
//
//   payloadVersion: 1                       (required, exact)
//   profiles:            [SavedProfile.toJson ...]
//   keys:                [SavedKey.toJson ...]
//   secrets:             { vaultId: {password|data|privateKey, passphrase?} }
//   hostKeys:            { "host:port": fingerprint }
//   recents:             [RecentSessionEntry.toJson ...]
//   profileOrder:        [identityKey ...]
//   favorites:           { identityKey: [PathFavorite.toJson ...] }
//   detectionExceptions: [DetectionException.toJson ...]
//   customPatterns:      [CustomPattern.toJson ...]
//   detectionStyles:     { patternId: DetectionPatternStyle.toJson }
//   settings:            { prefsKey: value }   (typed allowlist below)
//
// Ordering + safety:
//   - EVERYTHING is staged and validated before any write.
//   - An in-memory pre-snapshot of every prefs key and vault entry to be
//     touched is taken; a write failure triggers a best-effort restore. (The
//     crash-safe journal is deferred — #1126.)
//   - Secrets are written first, settings last.
//
// Credential handles (#1106, tightened for v2): a profile's vaultId /
// keyVaultId is honored ONLY when that exact handle has a TYPE-CORRECT secret
// in THIS backup (password entry ⇒ string `password`; key entry ⇒ string
// `data` or `privateKey`) and is referenced by the importing profile. Only
// surviving handles and imported-key material are ever written to the vault —
// orphan secrets in a crafted backup are dropped.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../ssh/host_key_store.dart';
import '../ssh/public_key_info.dart';
import '../state/profile_order_providers.dart'
    show profileOrderPrefKey, decodeProfileOrder, encodeProfileOrder;
import '../state/recent_sessions.dart';
import 'custom_patterns_store.dart';
import 'detection_exceptions_store.dart';
import 'detection_styles_store.dart';
import 'favorites_store.dart';
import 'keys_store.dart';
import 'profiles_store.dart';
import 'secrets_store.dart';

/// The exact payload version this importer understands.
const int kBackupPayloadVersion = 1;

/// Settings allowlist (mirrors the export slice's key set, #1124). Key strings
/// are duplicated here deliberately: the storage layer stays free of UI-layer
/// imports (the source constants live in state/* provider files — same
/// precedent as SavedProfile inlining the font-size bounds). Value validation
/// mirrors each notifier's own hydrate rules; readers additionally clamp, so a
/// stale-but-typed value can never crash.
const Set<String> _allowedSettingKeys = {
  'mobissh.ui.fontSize', // fontSizePrefKey (double, 8..32)
  'mobissh.ui.fontFamily', // fontFamilyPrefKey (bundled family name)
  'mobissh.ui.terminalThemeIndex', // terminalThemePrefKey (int, reader clamps)
  'mobissh.ui.terminalBackend', // terminalBackendPrefKey (enum name)
  'mobissh.ui.composeBarVisible', // composeBarVisiblePrefKey (bool)
  'mobissh.keepalive.enabled', // keepaliveEnabledPrefKey (bool)
  'mobissh.ui.tmuxControlMode', // tmuxControlModePrefKey (bool)
  'mobissh.files.sort.v1', // filesSortPrefKey (versioned JSON blob string)
  'mobissh.detection.settings', // detectionSettingsPrefKey (JSON blob string)
};

/// Bundled terminal font families — kept in sync with
/// SavedProfile._knownFontFamilies / terminalFontFamilies.
const Set<String> _knownFontFamilies = {
  'JetBrainsMono',
  'FiraCode',
  'CascadiaCode',
};

/// Terminal backend ids — TerminalBackend.values names.
const Set<String> _knownTerminalBackends = {'xterm', 'ghostty'};

bool _isJsonObjectString(Object? v) {
  if (v is! String || v.isEmpty) return false;
  try {
    return jsonDecode(v) is Map;
  } on FormatException {
    return false;
  }
}

/// Returns a deferred prefs write for an allowlisted, VALID setting; null for
/// an invalid value. Callers must check [_allowedSettingKeys] membership first
/// (unknown keys are ignored entirely, not counted as skipped).
Future<void> Function()? _stageSetting(
  SharedPreferences prefs,
  String key,
  Object? value,
) {
  switch (key) {
    case 'mobissh.ui.fontSize':
      if (value is num && value.isFinite && value >= 8 && value <= 32) {
        final v = value.toDouble();
        return () => prefs.setDouble(key, v);
      }
      return null;
    case 'mobissh.ui.fontFamily':
      if (value is String && _knownFontFamilies.contains(value)) {
        return () => prefs.setString(key, value);
      }
      return null;
    case 'mobissh.ui.terminalThemeIndex':
      if (value is int && value >= 0) {
        return () => prefs.setInt(key, value);
      }
      return null;
    case 'mobissh.ui.terminalBackend':
      if (value is String && _knownTerminalBackends.contains(value)) {
        return () => prefs.setString(key, value);
      }
      return null;
    case 'mobissh.ui.composeBarVisible':
    case 'mobissh.keepalive.enabled':
    case 'mobissh.ui.tmuxControlMode':
      if (value is bool) {
        return () => prefs.setBool(key, value);
      }
      return null;
    case 'mobissh.files.sort.v1':
    case 'mobissh.detection.settings':
      if (_isJsonObjectString(value)) {
        return () => prefs.setString(key, value as String);
      }
      return null;
  }
  return null;
}

Future<void> _restorePref(
  SharedPreferences prefs,
  String key,
  Object? old,
) async {
  if (old == null) {
    await prefs.remove(key);
  } else if (old is bool) {
    await prefs.setBool(key, old);
  } else if (old is int) {
    await prefs.setInt(key, old);
  } else if (old is double) {
    await prefs.setDouble(key, old);
  } else if (old is String) {
    await prefs.setString(key, old);
  } else if (old is List<String>) {
    await prefs.setStringList(key, old);
  }
}

/// Apply a decrypted backup payload. Returns an [ImportResult] whose extended
/// counts (keysImported/pins/settings) describe the restore; `errors` is
/// non-empty (with zero writes) for a structurally unusable payload.
///
/// [restoreCommands] gates initialCommand ONLY — default OFF, the dialog's
/// "Also restore auto-run commands" checkbox. Port forwards restore
/// UNCONDITIONALLY (owner-directed): they are connection CONFIG that only
/// arms when the user connects, not an auto-executing payload like
/// initialCommand — and losing them broke the round trip in practice.
Future<ImportResult> applyBackupPayload(
  Map<String, Object?> payload, {
  required SecretsStore secrets,
  SharedPreferences? prefs,
  bool restoreCommands = false,
}) async {
  final p = prefs ?? await SharedPreferences.getInstance();

  // ── Stage 0: structural validation (abort ⇒ zero writes) ────────────────
  if (payload['payloadVersion'] != kBackupPayloadVersion) {
    return ImportResult(errors: ['Unsupported backup payload version.']);
  }
  final sectionErrors = <String>[];
  List<dynamic>? asList(String name) {
    final v = payload[name];
    if (v == null) return null;
    if (v is List) return v;
    sectionErrors.add('Backup section `$name` has the wrong type.');
    return null;
  }

  Map<String, Object?>? asMap(String name) {
    final v = payload[name];
    if (v == null) return null;
    if (v is Map) return Map<String, Object?>.from(v);
    sectionErrors.add('Backup section `$name` has the wrong type.');
    return null;
  }

  final profilesRaw = asList('profiles');
  final keysRaw = asList('keys');
  final secretsRaw = asMap('secrets');
  final hostKeysRaw = asMap('hostKeys');
  final recentsRaw = asList('recents');
  final orderRaw = asList('profileOrder');
  final favoritesRaw = asMap('favorites');
  final exceptionsRaw = asList('detectionExceptions');
  final patternsRaw = asList('customPatterns');
  final stylesRaw = asMap('detectionStyles');
  final settingsRaw = asMap('settings');
  final omissionsRaw = asList('omissions');
  if (sectionErrors.isNotEmpty) {
    return ImportResult(errors: sectionErrors);
  }

  // Partial-backup omissions manifest: vault ids the EXPORT skipped as
  // unreadable. A NEW profile referencing one keeps its handle — preserving
  // credential IDENTITY for the re-enter flow (which key, which entry) —
  // but ONLY when nothing exists locally at that vault id. If local material
  // exists, the handle is dropped: honoring it would point the imported
  // profile at ANOTHER credential, the exact #1106 theft vector.
  final omittedIds = <String>{
    if (omissionsRaw != null)
      for (final e in omissionsRaw)
        if (e is Map && e['vaultId'] is String) e['vaultId'] as String,
  };
  final omittedSafeIds = <String>{};
  for (final id in omittedIds) {
    if (await secrets.read(id) == null) omittedSafeIds.add(id);
  }

  final entryErrors = <String>[];

  // Secret typing helpers (#1106 tightened filter).
  Map<String, Object?>? secretEntry(String id) {
    final v = secretsRaw?[id];
    if (v is Map) return Map<String, Object?>.from(v);
    return null;
  }

  bool hasPasswordSecret(String id) => secretEntry(id)?['password'] is String;
  bool hasKeySecret(String id) {
    final e = secretEntry(id);
    return e != null && (e['data'] is String || e['privateKey'] is String);
  }

  // Only handles that survive the reference+type filter — plus imported-key
  // material at its (possibly rewritten) vault id — are ever written.
  final stagedSecretWrites = <String, Map<String, Object?>>{};

  // ── Stage 1: keys (id-conflict resolution BEFORE profiles, so profile
  //             keyVaultId references can be rewritten to clones) ──────────
  final keysStore = KeysStore(prefs: p);
  final localKeys = await keysStore.load();
  final mergedKeys = List<SavedKey>.from(localKeys);
  final takenIds = {for (final k in localKeys) k.id};
  // imported vault id → rewritten vault id (clone case).
  final keyVaultRewrites = <String, String>{};
  var keysImported = 0;

  String mintKeyId() {
    var ts = DateTime.now().microsecondsSinceEpoch;
    var id = 'k$ts';
    while (takenIds.contains(id)) {
      ts++;
      id = 'k$ts';
    }
    takenIds.add(id);
    return id;
  }

  for (final entry in keysRaw ?? const <dynamic>[]) {
    if (entry is! Map) continue;
    final SavedKey imported;
    try {
      imported = SavedKey.fromJson(Map<String, dynamic>.from(entry));
    } on FormatException catch (e) {
      entryErrors.add(e.message);
      continue;
    }
    final material =
        hasKeySecret(imported.vaultId) ? secretEntry(imported.vaultId) : null;
    // Fingerprint: derive from the imported private material when parseable,
    // else fall back to the stored metadata field.
    PublicKeyInfo? derived;
    if (material != null) {
      final pem = (material['data'] ?? material['privateKey']) as String?;
      final passphrase = material['passphrase'];
      if (pem != null) {
        derived = derivePublicKeyInfo(
          pem,
          passphrase: passphrase is String ? passphrase : null,
        );
      }
    }
    final importedFp = derived?.fingerprint ?? imported.fingerprint;

    final localIdx = mergedKeys.indexWhere((k) => k.id == imported.id);
    final local = localIdx >= 0 ? mergedKeys[localIdx] : null;
    final sameKey = local != null &&
        importedFp != null &&
        local.fingerprint != null &&
        importedFp == local.fingerprint;

    if (local == null || sameKey) {
      // Fresh id or same underlying key ⇒ upsert by id.
      final upserted = derived == null
          ? imported
          : imported.copyWith(
              algorithm: derived.algorithm,
              publicKey: derived.publicKeyLine,
              fingerprint: derived.fingerprint,
            );
      if (localIdx >= 0) {
        mergedKeys[localIdx] = upserted;
      } else {
        mergedKeys.add(upserted);
        takenIds.add(upserted.id);
      }
      if (material != null) {
        stagedSecretWrites[upserted.vaultId] = material;
      }
    } else {
      // Same id, DIFFERENT key (or unknown-vs-unknown, treated as different):
      // mint a new id + vault id, leave the local key untouched, and rewrite
      // the imported profiles' references to the clone.
      final newId = mintKeyId();
      final clone = SavedKey(
        id: newId,
        name: imported.name,
        algorithm: derived?.algorithm ?? imported.algorithm,
        publicKey: derived?.publicKeyLine ?? imported.publicKey,
        fingerprint: importedFp,
        createdAtMs: imported.createdAtMs,
      );
      mergedKeys.add(clone);
      keyVaultRewrites[imported.vaultId] = clone.vaultId;
      if (material != null) {
        stagedSecretWrites[clone.vaultId] = material;
      }
    }
    keysImported++;
  }

  // ── Stage 2: profiles (identity-keyed upsert, #1106-filtered handles) ───
  final profilesStore = ProfilesStore(prefs: p);
  final mergedProfiles = await profilesStore.load();
  final byIdentity = <String, int>{
    for (var i = 0; i < mergedProfiles.length; i++)
      mergedProfiles[i].identityKey: i,
  };
  var added = 0;
  var updated = 0;

  for (final entry in profilesRaw ?? const <dynamic>[]) {
    if (entry is! Map) continue;
    final SavedProfile raw;
    try {
      raw = SavedProfile.fromJson(Map<String, dynamic>.from(entry));
    } on FormatException catch (e) {
      entryErrors.add(e.message);
      continue;
    }

    // Handle survives when a type-correct secret travelled (#1106), OR when
    // the export explicitly OMITTED it and nothing exists locally at that id
    // (partial backup — identity preserved for re-entry, nothing to steal).
    final String? safeVaultId = (raw.vaultId != null &&
            (hasPasswordSecret(raw.vaultId!) ||
                omittedSafeIds.contains(raw.vaultId)))
        ? raw.vaultId
        : null;
    String? safeKeyVaultId = (raw.keyVaultId != null &&
            (hasKeySecret(raw.keyVaultId!) ||
                omittedSafeIds.contains(raw.keyVaultId)))
        ? raw.keyVaultId
        : null;
    // Omitted handles have NO material — nothing to stage; the handle alone
    // is kept for identity. They also must not count as "brought a secret":
    // on an existing-profile merge a dead handle must never replace a
    // working local one.
    if (safeVaultId != null && hasPasswordSecret(safeVaultId)) {
      stagedSecretWrites[safeVaultId] = secretEntry(safeVaultId)!;
    }
    if (safeKeyVaultId != null && hasKeySecret(safeKeyVaultId)) {
      final material = secretEntry(safeKeyVaultId)!;
      final rewritten = keyVaultRewrites[safeKeyVaultId] ?? safeKeyVaultId;
      stagedSecretWrites[rewritten] = material;
      safeKeyVaultId = rewritten;
    }
    final importBroughtSecret =
        (safeVaultId != null && hasPasswordSecret(safeVaultId)) ||
            (safeKeyVaultId != null &&
                stagedSecretWrites.containsKey(safeKeyVaultId));

    final existingIndex = byIdentity[raw.identityKey];
    if (existingIndex != null) {
      final prior = mergedProfiles[existingIndex];
      mergedProfiles[existingIndex] = SavedProfile(
        title: prior.title,
        host: prior.host,
        port: prior.port,
        username: prior.username,
        theme: raw.theme,
        fontSize: raw.fontSize,
        fontFamily: raw.fontFamily,
        color: raw.color,
        authType: importBroughtSecret ? raw.authType : prior.authType,
        vaultId: importBroughtSecret ? safeVaultId : prior.vaultId,
        keyVaultId: importBroughtSecret ? safeKeyVaultId : prior.keyVaultId,
        initialCommand:
            restoreCommands ? raw.initialCommand : prior.initialCommand,
        defaultPath: raw.defaultPath,
        // Forwards are config, import-wins like every other profile field.
        forwards: raw.forwards,
      );
      updated++;
    } else {
      final safe = SavedProfile(
        title: raw.title,
        host: raw.host,
        port: raw.port,
        username: raw.username,
        theme: raw.theme,
        fontSize: raw.fontSize,
        fontFamily: raw.fontFamily,
        color: raw.color,
        authType: raw.authType,
        vaultId: safeVaultId,
        keyVaultId: safeKeyVaultId,
        initialCommand: restoreCommands ? raw.initialCommand : null,
        defaultPath: raw.defaultPath,
        forwards: raw.forwards,
      );
      mergedProfiles.add(safe);
      byIdentity[safe.identityKey] = mergedProfiles.length - 1;
      added++;
    }
  }

  // ── Stage 3: host-key pins (ADD-ABSENT-ONLY) ────────────────────────────
  final pinsBackend = SharedPrefsHostKeyBackend(prefs: p);
  Map<String, String> mergedPins;
  var pinsAdded = 0;
  var pinsConflicting = 0;
  try {
    mergedPins = await pinsBackend.loadAll();
  } catch (_) {
    // Corrupt local pin store: merging into it would fail closed elsewhere
    // (#1108); refuse the whole restore rather than half-apply.
    return ImportResult(
      errors: ['Local host-key store is unreadable — restore aborted.'],
    );
  }
  hostKeysRaw?.forEach((key, value) {
    if (key.isEmpty || value is! String || value.isEmpty) return;
    final current = mergedPins[key];
    if (current == null) {
      mergedPins[key] = value;
      pinsAdded++;
    } else if (current != value) {
      pinsConflicting++; // NEVER modify an existing pin.
    }
  });

  // ── Stage 4: user data merges ───────────────────────────────────────────
  // Recents: identity dedupe keep-newest. The local list is newer than any
  // backup by definition (it reflects THIS device's latest connects), so on
  // collision the local entry wins; imported-only identities append. Cap per
  // the store's own rule.
  final recentsStore = RecentSessionsStore(prefs: p);
  List<RecentSessionEntry>? mergedRecents;
  if (recentsRaw != null) {
    final localRecents = await recentsStore.load();
    final imported = <RecentSessionEntry>[];
    for (final entry in recentsRaw) {
      if (entry is! Map) continue;
      try {
        imported.add(
          RecentSessionEntry.fromJson(Map<String, dynamic>.from(entry)),
        );
      } on FormatException {
        // drop the bad straggler, keep the rest
      }
    }
    final seen = <String>{};
    mergedRecents = <RecentSessionEntry>[];
    for (final e in [...localRecents, ...imported]) {
      if (mergedRecents.length >= maxRecentSessions) break;
      if (seen.add(e.identityKey)) mergedRecents.add(e);
    }
  }

  // Profile order: imported order first (deduped), then local-only
  // identities appended at the end.
  List<String>? mergedOrder;
  if (orderRaw != null) {
    final localOrder = decodeProfileOrder(p.getString(profileOrderPrefKey));
    final seen = <String>{};
    mergedOrder = <String>[];
    for (final e in orderRaw) {
      if (e is String && e.isNotEmpty && seen.add(e)) mergedOrder.add(e);
    }
    for (final e in localOrder) {
      if (seen.add(e)) mergedOrder.add(e);
    }
  }

  // Favorites: merge by (identity, path); import wins on exact-key collision.
  final importedFavorites = <String, List<PathFavorite>>{};
  favoritesRaw?.forEach((identity, value) {
    if (identity.isEmpty || value is! List) return;
    final favs = <PathFavorite>[];
    for (final f in value) {
      final fav = PathFavorite.fromJson(f);
      if (fav != null) favs.add(fav);
    }
    if (favs.isNotEmpty) importedFavorites[identity] = favs;
  });

  // Detection exceptions: merge by (family, text); import wins.
  final importedExceptions = <DetectionException>[];
  for (final entry in exceptionsRaw ?? const <dynamic>[]) {
    final e = DetectionException.fromJson(entry);
    if (e != null) importedExceptions.add(e);
  }

  // Custom patterns: merge by id; import wins on exact-id collision.
  List<CustomPattern>? mergedPatterns;
  final patternsStore = CustomPatternsStore(prefs: p);
  if (patternsRaw != null) {
    mergedPatterns = List<CustomPattern>.from(await patternsStore.load());
    for (final entry in patternsRaw) {
      final imported = CustomPattern.fromJson(entry);
      if (imported == null) continue;
      final idx = mergedPatterns.indexWhere((x) => x.id == imported.id);
      if (idx >= 0) {
        mergedPatterns[idx] = imported;
      } else {
        mergedPatterns.add(imported);
      }
    }
  }

  // Detection styles: merge by pattern id; import wins, locals survive.
  final importedStyles = <String, DetectionPatternStyle>{};
  stylesRaw?.forEach((id, value) {
    if (id.isEmpty) return;
    final style = DetectionPatternStyle.fromJson(value);
    if (style != null) importedStyles[id] = style;
  });

  // ── Stage 5: settings allowlist (unknown ignored, invalid counted) ──────
  var settingsApplied = 0;
  var settingsSkipped = 0;
  final settingWrites = <Future<void> Function()>[];
  final touchedSettingKeys = <String>{};
  settingsRaw?.forEach((key, value) {
    if (!_allowedSettingKeys.contains(key)) return; // unknown: ignored
    final write = _stageSetting(p, key, value);
    if (write == null) {
      settingsSkipped++;
      return;
    }
    settingsApplied++;
    touchedSettingKeys.add(key);
    settingWrites.add(write);
  });

  // ── Pre-write snapshot of everything about to be touched ────────────────
  final touchedPrefsKeys = <String>{
    if (profilesRaw != null) profilesPrefsKey,
    if (keysRaw != null) keysPrefsKey,
    if (hostKeysRaw != null) hostKeysPrefsKey,
    if (mergedRecents != null) recentSessionsPrefsKey,
    if (mergedOrder != null) profileOrderPrefKey,
    if (importedFavorites.isNotEmpty) favoritesPrefsKey,
    if (importedExceptions.isNotEmpty) detectionExceptionsPrefsKey,
    if (mergedPatterns != null) customPatternsPrefsKey,
    if (importedStyles.isNotEmpty) detectionStylesPrefsKey,
    ...touchedSettingKeys,
  };
  final prefsSnapshot = <String, Object?>{
    for (final k in touchedPrefsKeys) k: p.get(k),
  };
  final vaultSnapshot = <String, Map<String, Object?>?>{};
  for (final id in stagedSecretWrites.keys) {
    vaultSnapshot[id] = await secrets.read(id);
  }

  // ── Write phase (rollback best-effort on failure) ───────────────────────
  try {
    // Secrets before the profiles/keys that reference them (mirrors the v1
    // rationale in applyParsedImport).
    for (final entry in stagedSecretWrites.entries) {
      await secrets.write(entry.key, entry.value);
    }
    if (keysRaw != null) await keysStore.save(mergedKeys);
    if (profilesRaw != null) await profilesStore.save(mergedProfiles);
    if (hostKeysRaw != null) await pinsBackend.saveAll(mergedPins);
    if (mergedRecents != null) {
      await recentsStore.clear();
      // add() prepends — feed oldest-first to land newest-first.
      for (final e in mergedRecents.reversed) {
        await recentsStore.add(e);
      }
    }
    if (mergedOrder != null) {
      await p.setString(profileOrderPrefKey, encodeProfileOrder(mergedOrder));
    }
    if (importedFavorites.isNotEmpty) {
      final favStore = FavoritesStore(prefs: p);
      for (final entry in importedFavorites.entries) {
        for (final fav in entry.value) {
          // Import wins on the exact path key: drop any local twin first so
          // the imported label replaces it (add() is a no-op on duplicates).
          await favStore.remove(entry.key, fav.path);
          await favStore.add(entry.key, fav.path, label: fav.label);
        }
      }
    }
    if (importedExceptions.isNotEmpty) {
      final excStore = DetectionExceptionsStore(prefs: p);
      for (final e in importedExceptions) {
        await excStore.remove(
          patternId: e.patternId,
          matchedText: e.matchedText,
        );
        await excStore.add(e);
      }
    }
    if (mergedPatterns != null) await patternsStore.saveAll(mergedPatterns);
    if (importedStyles.isNotEmpty) {
      final stylesStore = DetectionStylesStore(prefs: p);
      for (final entry in importedStyles.entries) {
        await stylesStore.setPatternStyle(entry.key, entry.value);
      }
    }
    // Settings LAST.
    for (final write in settingWrites) {
      await write();
    }
  } catch (_) {
    for (final entry in prefsSnapshot.entries) {
      try {
        await _restorePref(p, entry.key, entry.value);
      } catch (_) {
        // best-effort — keep restoring the rest
      }
    }
    for (final entry in vaultSnapshot.entries) {
      try {
        if (entry.value == null) {
          await secrets.delete(entry.key);
        } else {
          await secrets.write(entry.key, entry.value!);
        }
      } catch (_) {
        // best-effort
      }
    }
    return ImportResult(
      errors: ['Restore failed while writing — previous state was restored.'],
    );
  }

  return ImportResult(
    added: added,
    updated: updated,
    errors: entryErrors,
    keysImported: keysImported,
    pinsAdded: pinsAdded,
    pinsConflicting: pinsConflicting,
    settingsApplied: settingsApplied,
    settingsSkipped: settingsSkipped,
  );
}
