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
  })  : error = null,
        unreadableSecretCount = 0;

  const BackupPayloadResult.failure({
    required String this.error,
    required this.unreadableSecretCount,
  })  : payload = null,
        profileCount = 0,
        keyCount = 0;

  /// The plaintext payload to encrypt, or null when the export was aborted.
  final Map<String, Object?>? payload;

  /// User-facing abort reason (null on success).
  final String? error;

  /// How many REFERENCED vault ids could not be read (abort case).
  final int unreadableSecretCount;

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
}) async {
  final profileList = await profiles.load();
  final keyList = await keys.load();

  // Referenced vault ids: exported profiles' vaultId/keyVaultId + every
  // library key's vault id. Sorted for a deterministic payload.
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

  final secretsOut = <String, Object?>{};
  var unreadable = 0;
  for (final vaultId in referenced.toList()..sort()) {
    final secret = await secrets.read(vaultId);
    if (secret == null) {
      // Absent OR undecryptable (#1118 maps both to null) — either way a
      // profile/key points at material we cannot export. Count and abort.
      unreadable++;
      continue;
    }
    secretsOut[vaultId] = secret;
  }
  if (unreadable > 0) {
    return BackupPayloadResult.failure(
      error: '$unreadable stored secret${unreadable == 1 ? '' : 's'} could '
          'not be read — backup not created. Re-enter the affected '
          'credentials, then export again.',
      unreadableSecretCount: unreadable,
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
    'profiles': profileList.map((p) => p.toJson()).toList(),
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
  };
  return BackupPayloadResult.success(
    payload: payload,
    profileCount: profileList.length,
    keyCount: keyList.length,
  );
}
