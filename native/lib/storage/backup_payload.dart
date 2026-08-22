// Backup payload gathering (#1124, export path).
//
// Composes the PLAINTEXT payload that goes inside the v2 backup envelope
// (backup.dart). Everything here is destined for the ciphertext — including
// `createdAt` / `appVersion`, which must never appear in the outer envelope.
//
// Design points (issue #1124 spec):
// - Stores are injected so tests run against in-memory fakes.
// - `secrets` exports ONLY vault ids referenced by exported profiles
//   (`vaultId` / `keyVaultId`) and library keys (`SavedKey.vaultId`) — never
//   unreferenced orphans.
// - An unreadable REFERENCED secret (SecretsStore.read → null, which also
//   covers post-migration decrypt failures per #1118) ABORTS the export with
//   an error naming the count: a "backup" silently missing credentials is
//   worse than no backup.
// - `settings` is a TYPED allowlist of prefs keys ([kBackupSettingsAllowlist])
//   — never a prefs dump, so store blobs and future secrets can't leak in.
//
// Callers gather the payload ONLY after the passphrase dialog is submitted and
// hand it straight to `encryptBackupEnvelope` (UI path wraps that call in
// Isolate.run — Argon2id at 19 MiB is CPU-heavy).

import 'package:shared_preferences/shared_preferences.dart';

import '../ssh/host_key_store.dart';
import '../state/detection_providers.dart';
import '../state/files_sort_providers.dart';
import '../state/keepalive_providers.dart';
import '../state/profile_order_providers.dart';
import '../state/recent_sessions.dart';
import '../state/terminal_backend.dart';
import '../state/tmux_control_mode_setting.dart';
import '../state/ui_prefs_providers.dart';
import 'custom_patterns_store.dart';
import 'detection_exceptions_store.dart';
import 'detection_styles_store.dart';
import 'favorites_store.dart';
import 'keys_store.dart';
import 'profiles_store.dart';
import 'secrets_store.dart';

/// Version of the payload schema INSIDE the ciphertext (independent of the
/// envelope's `version: 2` framing).
const int kBackupPayloadVersion = 1;

/// The TYPED allowlist of app-settings prefs keys exported in the `settings`
/// section. Deliberately explicit — a new setting is exported only when its
/// key is added here (and store blobs / secrets can never ride along).
const List<String> kBackupSettingsAllowlist = <String>[
  fontSizePrefKey,
  fontFamilyPrefKey,
  terminalThemePrefKey,
  terminalBackendPrefKey,
  composeBarVisiblePrefKey,
  keepaliveEnabledPrefKey,
  tmuxControlModePrefKey,
  filesSortPrefKey,
  detectionSettingsPrefKey,
];

/// Result of [buildBackupPayload]: either a complete [payload] (plus the
/// profile/key counts for the success toast), or an [error] with NO payload.
class BackupPayloadResult {
  const BackupPayloadResult.success({
    required Map<String, Object?> this.payload,
    required this.profileCount,
    required this.keyCount,
    this.omittedLabels = const <String>[],
  })  : error = null,
        unreadableSecretCount = 0,
        affected = const <String>[];

  const BackupPayloadResult.failure({
    required String this.error,
    required this.unreadableSecretCount,
    this.affected = const <String>[],
  })  : payload = null,
        profileCount = 0,
        keyCount = 0,
        omittedLabels = const <String>[];

  /// The plaintext payload to encrypt, or null when the export was aborted.
  final Map<String, Object?>? payload;

  /// User-facing abort reason (null on success).
  final String? error;

  /// How many REFERENCED vault ids could not be read (abort case).
  final int unreadableSecretCount;

  /// Display labels for the unreadable entries (#1129) — profile titles /
  /// identities / key names, NEVER secret material. Empty on success.
  final List<String> affected;

  /// Labels of entries SKIPPED by an allowMissing export (partial backup).
  /// Empty for a complete backup.
  final List<String> omittedLabels;

  /// Exported profile / key counts (success toast: "N profiles, M keys").
  final int profileCount;
  final int keyCount;

  bool get isError => payload == null;
}

/// Gather every backup section from the injected stores. See the module
/// comment for the abort and allowlist rules.
Future<BackupPayloadResult> buildBackupPayload({
  required ProfilesStore profiles,
  required KeysStore keys,
  required SecretsStore secrets,
  required HostKeyBackend hostKeys,
  required RecentSessionsStore recents,
  required FavoritesStore favorites,
  required DetectionExceptionsStore detectionExceptions,
  required CustomPatternsStore customPatterns,
  required DetectionStylesStore detectionStyles,
  required SharedPreferences prefs,
  required String appVersion,
  DateTime Function()? now,
  // Owner-directed partial export: when true, unreadable referenced secrets
  // are SKIPPED instead of aborting; the payload carries an `omissions`
  // manifest (inside the ciphertext) so the import side knows what's missing
  // and the affected profiles keep their credential identity for re-entry.
  bool allowMissing = false,
}) async {
  final profileList = await profiles.load();
  final keyList = await keys.load();

  final cls = await _classifySecrets(profileList, keyList, secrets);
  final secretsOut = <String, Object?>{...cls.readable};
  if (cls.blockingIds.isNotEmpty && !allowMissing) {
    // Name the culprits (#1129): a bare count leaves the user hunting through
    // every profile for the poisoned entries. Labels are NON-secret (titles /
    // identities / key names).
    final n = cls.blockingIds.length;
    const cap = 6;
    final shown = cls.blockingLabels.take(cap).join('; ');
    final more = n > cap ? '; …and ${n - cap} more' : '';
    return BackupPayloadResult.failure(
      error: '$n stored secret${n == 1 ? '' : 's'} could not be read — '
          'backup not created. Affected: $shown$more. Re-enter these '
          'credentials, then export again.',
      unreadableSecretCount: n,
      affected: cls.blockingLabels,
    );
  }

  // TOFU pin map. A corrupt/unavailable store has no recoverable pins — export
  // an empty map rather than aborting the (far more valuable) credential
  // backup.
  Map<String, String> hostKeyMap;
  try {
    hostKeyMap = await hostKeys.loadAll();
  } catch (_) {
    hostKeyMap = const <String, String>{};
  }

  final recentList = await recents.load();
  final favoritesModel = await favorites.load();
  final exceptionList = await detectionExceptions.load();
  final patternList = await customPatterns.load();
  final styles = await detectionStyles.load();
  final order = decodeProfileOrder(prefs.getString(profileOrderPrefKey));

  final settingsOut = <String, Object?>{};
  for (final key in kBackupSettingsAllowlist) {
    final value = prefs.get(key);
    // JSON-encodable scalars only — prefs lists aren't part of the allowlist
    // and anything else would break the envelope's jsonEncode.
    if (value is bool || value is int || value is double || value is String) {
      settingsOut[key] = value;
    }
  }

  final payload = <String, Object?>{
    'payloadVersion': kBackupPayloadVersion,
    'createdAt': (now?.call() ?? DateTime.now().toUtc()).toIso8601String(),
    'appVersion': appVersion,
    // Vestigial handles (a stale slot the profile's auth doesn't use — e.g.
    // an old password vaultId on a now-key-auth profile) are STRIPPED from
    // the export: connect ignores them locally, and carrying a dead
    // reference into a restore would only resurrect confusion.
    'profiles': profileList.map((p) {
      final json = p.toJson();
      if (cls.vestigialIds.contains(p.vaultId)) json.remove('vaultId');
      if (cls.vestigialIds.contains(p.keyVaultId)) json.remove('keyVaultId');
      return json;
    }).toList(),
    'keys': keyList.map((k) => k.toJson()).toList(),
    'secrets': secretsOut,
    'hostKeys': hostKeyMap,
    'recents': recentList.map((r) => r.toJson()).toList(),
    'profileOrder': order,
    'favorites': <String, Object?>{
      for (final e in favoritesModel.entries)
        e.key: e.value.map((f) => f.toJson()).toList(),
    },
    'detectionExceptions': exceptionList.map((e) => e.toJson()).toList(),
    'customPatterns': patternList.map((p) => p.toJson()).toList(),
    'detectionStyles': <String, Object?>{
      for (final e in styles.byPattern.entries) e.key: e.value.toJson(),
    },
    'settings': settingsOut,
    // Partial-export manifest (inside the ciphertext): unreadable ids whose
    // absence MATTERS — connect-blocking profile credentials the user chose
    // to skip, plus library keys whose material is gone (metadata-only).
    // The import side uses this to preserve credential IDENTITY (a profile
    // keeps its handle for the re-enter flow) without any material.
    if (cls.blockingIds.isNotEmpty || cls.deadKeyIds.isNotEmpty)
      'omissions': [
        for (var i = 0; i < cls.blockingIds.length; i++)
          {'vaultId': cls.blockingIds[i], 'label': cls.blockingLabels[i]},
        for (var i = 0; i < cls.deadKeyIds.length; i++)
          {'vaultId': cls.deadKeyIds[i], 'label': cls.deadKeyLabels[i]},
      ],
  };
  return BackupPayloadResult.success(
    payload: payload,
    profileCount: profileList.length,
    keyCount: keyList.length,
    omittedLabels: cls.blockingLabels,
  );
}

/// Non-secret owner labels for vault ids (#1129): profile title/identity
/// first, a library key's name when no profile owns it, raw id last resort.
List<String> _labelsFor(
  List<String> vaultIds,
  List<SavedProfile> profileList,
  List<SavedKey> keyList,
) {
  final out = <String>[];
  for (final vaultId in vaultIds) {
    final owners = <String>[];
    for (final p in profileList) {
      if (p.vaultId == vaultId || p.keyVaultId == vaultId) {
        owners.add(p.title.trim().isEmpty ? p.identityKey : p.title.trim());
      }
    }
    for (final k in keyList) {
      if (k.vaultId == vaultId && owners.isEmpty) {
        owners.add('key "${k.name}"');
      }
    }
    out.add(owners.isEmpty ? vaultId : owners.join(', '));
  }
  return out;
}

/// Shared readability classification — mirrors CONNECT semantics (the
/// connect form's auth-kind resolution + loadProfileCredentials' shape
/// contract). Owner-reported bug: profiles that connected fine were flagged
/// unexportable because a STALE second slot (e.g. an old password vaultId on
/// a now-key-auth profile) read null. A profile is exportable when the slot
/// its auth actually uses is readable:
/// - blocking:  the profile could not connect either — genuinely unreadable.
/// - vestigial: a dead slot connect ignores — stripped from the export.
/// - dead key:  a library key with metadata but no material — exported as
///   metadata + an omissions entry; never blocks (there is nothing readable
///   to lose, and any profile that NEEDS it is caught as blocking).
class _SecretClassification {
  const _SecretClassification({
    required this.readable,
    required this.blockingIds,
    required this.blockingLabels,
    required this.vestigialIds,
    required this.deadKeyIds,
    required this.deadKeyLabels,
  });
  final Map<String, Map<String, Object?>> readable;
  final List<String> blockingIds;
  final List<String> blockingLabels;
  final Set<String> vestigialIds;
  final List<String> deadKeyIds;
  final List<String> deadKeyLabels;
}

Future<_SecretClassification> _classifySecrets(
  List<SavedProfile> profileList,
  List<SavedKey> keyList,
  SecretsStore secrets,
) async {
  final referenced = <String>{};
  for (final p in profileList) {
    final v = p.vaultId;
    if (v != null && v.isNotEmpty) referenced.add(v);
    final kv = p.keyVaultId;
    if (kv != null && kv.isNotEmpty) referenced.add(kv);
  }
  for (final k in keyList) {
    referenced.add(k.vaultId);
  }
  // Sorted read for a deterministic payload/section order.
  final readable = <String, Map<String, Object?>>{};
  for (final id in referenced.toList()..sort()) {
    final v = await secrets.read(id);
    if (v != null) readable[id] = v;
  }

  bool passwordUsable(String? id) =>
      id != null && readable[id]?['password'] is String;
  bool keyUsableAt(String? id) {
    final e = id == null ? null : readable[id];
    return e != null && (e['data'] is String || e['privateKey'] is String);
  }

  final blockingIds = <String>[];
  final vestigial = <String>{};
  for (final p in profileList) {
    final v = (p.vaultId == null || p.vaultId!.isEmpty) ? null : p.vaultId;
    final kv =
        (p.keyVaultId == null || p.keyVaultId!.isEmpty) ? null : p.keyVaultId;
    if (v == null && kv == null) continue; // no creds saved — nothing to check
    // Mirrors _connectFromProfile: explicit authType wins; otherwise a key
    // reference implies key auth.
    final wantsKey =
        p.authType == 'key' || (p.authType != 'password' && kv != null);
    final usable = wantsKey
        // Legacy vaultId entries may carry a privateKey (loadProfileCredentials
        // pass 1) — accept either slot for key auth, like connect does.
        ? (keyUsableAt(kv) || keyUsableAt(v))
        : passwordUsable(v);
    for (final id in [v, kv]) {
      if (id == null || readable.containsKey(id)) continue;
      if (usable) {
        vestigial.add(id);
      } else if (!blockingIds.contains(id)) {
        blockingIds.add(id);
      }
    }
  }
  // A handle another profile genuinely NEEDS is blocking, never vestigial.
  vestigial.removeWhere(blockingIds.contains);

  final deadKeyIds = <String>[];
  for (final k in keyList) {
    if (!readable.containsKey(k.vaultId) &&
        !blockingIds.contains(k.vaultId) &&
        !deadKeyIds.contains(k.vaultId)) {
      deadKeyIds.add(k.vaultId);
    }
  }

  return _SecretClassification(
    readable: readable,
    blockingIds: blockingIds,
    blockingLabels: _labelsFor(blockingIds, profileList, keyList),
    vestigialIds: vestigial,
    deadKeyIds: deadKeyIds,
    deadKeyLabels: _labelsFor(deadKeyIds, const [], keyList),
  );
}

/// Readability preflight for the export dialog (owner-directed: never ask for
/// a passphrase before knowing the export can be built). Reads each referenced
/// vault id ONLY to classify it readable/unreadable — values are discarded
/// immediately; nothing is retained while the dialog is open.
class BackupPreflight {
  const BackupPreflight({
    required this.profileCount,
    required this.keyCount,
    required this.readableSecretCount,
    required this.unreadableLabels,
  });
  final int profileCount;
  final int keyCount;
  final int readableSecretCount;

  /// Non-secret owner labels of unreadable referenced entries (empty = clean).
  final List<String> unreadableLabels;

  bool get clean => unreadableLabels.isEmpty;
}

Future<BackupPreflight> preflightBackup({
  required ProfilesStore profiles,
  required KeysStore keys,
  required SecretsStore secrets,
}) async {
  final profileList = await profiles.load();
  final keyList = await keys.load();
  // Same classification the export uses (connect-mirroring): only
  // CONNECT-BLOCKING unreadables surface; vestigial slots and metadata-only
  // library keys never gate the passphrase. Values are discarded with the
  // classification — nothing retained while the dialog is open.
  final cls = await _classifySecrets(profileList, keyList, secrets);
  return BackupPreflight(
    profileCount: profileList.length,
    keyCount: keyList.length,
    readableSecretCount: cls.readable.length,
    unreadableLabels: cls.blockingLabels,
  );
}
