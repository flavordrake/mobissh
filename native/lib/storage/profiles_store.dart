// Saved-profile persistence for the native client (#501).
//
// Mirrors the PWA's `getProfiles` / `saveProfile` pattern: a JSON-encoded list
// of connection metadata persisted in shared_preferences under the key
// `mobissh.profiles.v1`. Identity-only fields plus optional vault references
// (vaultId / keyVaultId / authType / initialCommand) introduced for #510 so
// the native connect path can look up secrets by vaultId. Credentials
// themselves live in `flutter_secure_storage` (see `secrets_store.dart`).
//
// The matching PWA export shape (see `exportProfilesJson` in
// src/modules/profiles.ts) is `{ version: 1, exportedAt, profiles: [...] }`.
// The richer backup-envelope shape additionally carries a `vault` field with
// PBKDF2+AES-GCM encrypted secrets; see `parseBackupEnvelope` / `applyBackup`.

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'secrets_store.dart';
import 'vault.dart';

/// Persisted profile shape. Connection metadata + optional visual identity +
/// optional vault references. Equality is by (host, port, username) — the
/// natural identity used for dedupe everywhere else in the app.
class SavedProfile {
  SavedProfile({
    required this.title,
    required this.host,
    required this.port,
    required this.username,
    this.theme,
    this.color,
    this.authType,
    this.vaultId,
    this.keyVaultId,
    this.initialCommand,
  });

  final String title;
  final String host;
  final int port;
  final String username;
  final String? theme;
  final String? color;

  /// 'password' or 'key'. Optional — older saved profiles omit it.
  final String? authType;

  /// Reference to a secret in `SecretsStore`. Populated when the profile
  /// came from a backup-envelope import and its credentials were decrypted
  /// + persisted. When null, the connect path falls back to prompting.
  final String? vaultId;

  /// Separate reference for a key's secret material when both a password and
  /// a key are stored. Mirrors the PWA field of the same name.
  final String? keyVaultId;

  /// Optional command to send after auth — preserved verbatim from the PWA.
  final String? initialCommand;

  /// Identity key for dedupe / lookup. Matches the PWA's behavior of treating
  /// (host:port:username) as the unique constraint.
  String get identityKey => '$host:$port:$username';

  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{
      'title': title,
      'host': host,
      'port': port,
      'username': username,
    };
    if (theme != null) out['theme'] = theme;
    if (color != null) out['color'] = color;
    if (authType != null) out['authType'] = authType;
    if (vaultId != null) out['vaultId'] = vaultId;
    if (keyVaultId != null) out['keyVaultId'] = keyVaultId;
    if (initialCommand != null && initialCommand!.isNotEmpty) {
      out['initialCommand'] = initialCommand;
    }
    return out;
  }

  factory SavedProfile.fromJson(Map<String, dynamic> json) {
    final hostRaw = json['host'];
    final usernameRaw = json['username'];
    if (hostRaw is! String || hostRaw.isEmpty) {
      throw const FormatException('profile missing required field: host');
    }
    if (usernameRaw is! String || usernameRaw.isEmpty) {
      throw const FormatException('profile missing required field: username');
    }

    // Port: JSON numbers parse as int OR double depending on encoder. Accept
    // either, fall back to 22.
    int port = 22;
    final portRaw = json['port'];
    if (portRaw is int) {
      port = portRaw;
    } else if (portRaw is double) {
      port = portRaw.toInt();
    } else if (portRaw is String) {
      port = int.tryParse(portRaw) ?? 22;
    }
    if (port <= 0 || port > 65535) port = 22;

    final titleRaw = json['title'];
    final title = (titleRaw is String && titleRaw.isNotEmpty)
        ? titleRaw
        : '$usernameRaw@$hostRaw';

    String? theme;
    final themeRaw = json['theme'];
    if (themeRaw is String && themeRaw.isNotEmpty) theme = themeRaw;

    String? color;
    final colorRaw = json['color'];
    if (colorRaw is String && colorRaw.isNotEmpty) color = colorRaw;

    String? authType;
    final authTypeRaw = json['authType'];
    if (authTypeRaw is String &&
        (authTypeRaw == 'password' || authTypeRaw == 'key')) {
      authType = authTypeRaw;
    }

    String? vaultId;
    final vaultIdRaw = json['vaultId'];
    if (vaultIdRaw is String && vaultIdRaw.isNotEmpty) vaultId = vaultIdRaw;

    String? keyVaultId;
    final keyVaultIdRaw = json['keyVaultId'];
    if (keyVaultIdRaw is String && keyVaultIdRaw.isNotEmpty) {
      keyVaultId = keyVaultIdRaw;
    }

    String? initialCommand;
    final initialCommandRaw = json['initialCommand'];
    if (initialCommandRaw is String && initialCommandRaw.isNotEmpty) {
      initialCommand = initialCommandRaw;
    }

    return SavedProfile(
      title: title,
      host: hostRaw,
      port: port,
      username: usernameRaw,
      theme: theme,
      color: color,
      authType: authType,
      vaultId: vaultId,
      keyVaultId: keyVaultId,
      initialCommand: initialCommand,
    );
  }

  SavedProfile copyWith({
    String? title,
    String? vaultId,
    String? keyVaultId,
  }) {
    return SavedProfile(
      title: title ?? this.title,
      host: host,
      port: port,
      username: username,
      theme: theme,
      color: color,
      authType: authType,
      vaultId: vaultId ?? this.vaultId,
      keyVaultId: keyVaultId ?? this.keyVaultId,
      initialCommand: initialCommand,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SavedProfile &&
          other.host == host &&
          other.port == port &&
          other.username == username);

  @override
  int get hashCode => Object.hash(host, port, username);

  @override
  String toString() => 'SavedProfile($title, $username@$host:$port)';
}

/// Result of an import operation. Mirrors the PWA's `ImportResult` shape so
/// the UI can show parallel toast messages.
class ImportResult {
  ImportResult({this.added = 0, this.skipped = 0, this.errors = const []});
  final int added;
  final int skipped;
  final List<String> errors;
}

/// Outcome of a sync envelope-shape scan. The UI uses this to decide whether
/// to render a master-password prompt before committing the import.
class ParsedImport {
  ParsedImport({
    required this.profileEntries,
    this.vaultEncryptedJson,
    this.vaultMetaJson,
    this.errors = const [],
  });

  /// Raw profile maps as decoded from the envelope. Validation happens at
  /// apply-time, not parse-time, so the user sees one set of errors.
  final List<Map<String, dynamic>> profileEntries;

  /// `vault.encrypted` field if the envelope contained one. Null otherwise.
  final String? vaultEncryptedJson;

  /// `vault.meta` field if the envelope contained one. Null otherwise.
  final String? vaultMetaJson;

  /// Parse-time errors (non-JSON, wrong shape). When non-empty and there are
  /// no profiles either, the UI surfaces these in an inline error.
  final List<String> errors;

  /// True when this envelope carries an encrypted vault — caller must prompt
  /// for the master password before [ProfilesStore.applyParsedImport].
  bool get hasVault =>
      vaultEncryptedJson != null && vaultMetaJson != null;
}

/// shared_preferences key. Versioned so a future schema change can migrate
/// in-place without colliding with v1 data.
const String profilesPrefsKey = 'mobissh.profiles.v1';

/// Persistence layer for saved profiles. UI consumers go through
/// `profilesStoreProvider` (state/profiles_providers.dart) so they can be
/// observed via Riverpod; tests inject a [SharedPreferences] via
/// [SharedPreferences.setMockInitialValues] and construct directly.
class ProfilesStore {
  ProfilesStore({SharedPreferences? prefs}) : _prefs = prefs;

  // Cached SharedPreferences. Lazily replaced by [_ensure] on first call when
  // the constructor wasn't given an explicit instance. Tests may pass in a
  // pre-seeded prefs handle to skip async resolution.
  SharedPreferences? _prefs;
  // ignore_for_file: prefer_initializing_formals

  Future<SharedPreferences> _ensure() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  /// Read all profiles from storage. Returns [] when nothing is stored or
  /// the stored JSON is malformed (corrupt-resilience per .claude/rules).
  Future<List<SavedProfile>> load() async {
    final prefs = await _ensure();
    final raw = prefs.getString(profilesPrefsKey);
    if (raw == null || raw.isEmpty) return <SavedProfile>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <SavedProfile>[];
      final out = <SavedProfile>[];
      for (final entry in decoded) {
        if (entry is! Map) continue;
        try {
          out.add(SavedProfile.fromJson(Map<String, dynamic>.from(entry)));
        } on FormatException {
          // Skip corrupt entries silently — they would have been quarantined
          // at write time anyway; tolerate stragglers.
        }
      }
      return out;
    } on FormatException {
      return <SavedProfile>[];
    }
  }

  /// Overwrite the entire profile list. The native UI calls `save(list)`
  /// after each mutating operation; there's no incremental update API.
  Future<void> save(List<SavedProfile> profiles) async {
    final prefs = await _ensure();
    final encoded = jsonEncode(profiles.map((p) => p.toJson()).toList());
    await prefs.setString(profilesPrefsKey, encoded);
  }

  /// Side-effect-free first stage of import. Detects envelope shape, extracts
  /// profile entries, and surfaces vault material for the UI to prompt-on.
  ///
  /// Returns a [ParsedImport] with either populated profile entries + vault
  /// fields, or a non-empty `errors` list explaining why the input was
  /// unusable. Never throws on bad input — the UI relies on the errors list.
  static ParsedImport parseImport(String json) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException catch (e) {
      return ParsedImport(
        profileEntries: const [],
        errors: ['Not valid JSON: ${e.message}'],
      );
    }

    if (decoded is List) {
      return ParsedImport(
        profileEntries: _coerceEntries(decoded),
      );
    }

    if (decoded is! Map) {
      return ParsedImport(
        profileEntries: const [],
        errors: ['Wrong file shape — expected an export envelope or profile array.'],
      );
    }

    final version = decoded['version'];
    if (version != null && version != 1) {
      return ParsedImport(
        profileEntries: const [],
        errors: ['Unsupported export version: $version (this client supports v1).'],
      );
    }

    final profilesRaw = decoded['profiles'];
    if (profilesRaw is! List) {
      return ParsedImport(
        profileEntries: const [],
        errors: ['Export envelope missing `profiles` array.'],
      );
    }

    String? vaultEncryptedJson;
    String? vaultMetaJson;
    final vaultRaw = decoded['vault'];
    if (vaultRaw is Map) {
      final enc = vaultRaw['encrypted'];
      final meta = vaultRaw['meta'];
      // Both fields must be strings for the envelope to be useful; if either
      // is missing we treat the envelope as "metadata-only" and fall through.
      if (enc is String && enc.isNotEmpty && meta is String && meta.isNotEmpty) {
        vaultEncryptedJson = enc;
        vaultMetaJson = meta;
      }
    }

    return ParsedImport(
      profileEntries: _coerceEntries(profilesRaw),
      vaultEncryptedJson: vaultEncryptedJson,
      vaultMetaJson: vaultMetaJson,
    );
  }

  static List<Map<String, dynamic>> _coerceEntries(List<dynamic> raw) {
    final out = <Map<String, dynamic>>[];
    for (final entry in raw) {
      if (entry is Map) {
        out.add(Map<String, dynamic>.from(entry));
      }
    }
    return out;
  }

  /// Apply a parsed import. When [parsed.hasVault] is true, [password] is
  /// required and the vault is decrypted before any persistence happens —
  /// the wrong password aborts cleanly with no partial state.
  ///
  /// [secrets] is required when persisting decrypted secrets; tests pass an
  /// [InMemorySecretsBackend]-backed store.
  Future<ImportResult> applyParsedImport(
    ParsedImport parsed, {
    String? password,
    SecretsStore? secrets,
    VaultDecryptor? decryptor,
  }) async {
    if (parsed.errors.isNotEmpty && parsed.profileEntries.isEmpty) {
      return ImportResult(errors: parsed.errors);
    }

    // If the envelope carries a vault, decrypt it BEFORE writing anything.
    // A failed decrypt must leave the store untouched.
    Map<String, Map<String, Object?>> decryptedVault =
        <String, Map<String, Object?>>{};
    if (parsed.hasVault) {
      if (password == null || password.isEmpty) {
        return ImportResult(errors: ['Master password required to decrypt vault.']);
      }
      if (secrets == null) {
        return ImportResult(errors: ['Secrets store unavailable.']);
      }
      try {
        decryptedVault = await (decryptor ?? VaultDecryptor()).decryptEnvelope(
          encryptedJson: parsed.vaultEncryptedJson!,
          metaJson: parsed.vaultMetaJson!,
          password: password,
        );
      } on VaultDecryptException catch (e) {
        return ImportResult(errors: [e.message]);
      } on VaultEnvelopeException catch (e) {
        return ImportResult(errors: ['Vault envelope is malformed: ${e.message}']);
      }
    }

    final existing = await load();
    final existingKeys = existing.map((p) => p.identityKey).toSet();
    final errors = <String>[...parsed.errors];
    int added = 0;
    int skipped = 0;

    for (final entry in parsed.profileEntries) {
      try {
        final profile = SavedProfile.fromJson(entry);
        if (existingKeys.contains(profile.identityKey)) {
          skipped++;
          continue;
        }
        existing.add(profile);
        existingKeys.add(profile.identityKey);
        added++;
      } on FormatException catch (e) {
        errors.add(e.message);
      }
    }

    // Persist secrets before profiles. If profile save fails (it shouldn't),
    // we'd rather leak an extra secret blob than have a profile without its
    // secret. Either way, the same vaultId would just be overwritten on a
    // re-import.
    if (secrets != null) {
      for (final entry in decryptedVault.entries) {
        await secrets.write(entry.key, entry.value);
      }
    }

    if (added > 0) {
      await save(existing);
    }

    return ImportResult(added: added, skipped: skipped, errors: errors);
  }

  /// Backwards-compatible single-shot importer. Accepts the
  /// `{ version, profiles[] }` envelope or a legacy bare array, ignores
  /// any vault payload (for that, the UI calls [parseImport] +
  /// [applyParsedImport] with a password).
  ///
  /// Returns an [ImportResult] enumerating added/skipped/errors. Does NOT
  /// throw on malformed input — that's a user-recoverable error reported via
  /// the result.
  Future<ImportResult> importFromJson(String json) async {
    final parsed = parseImport(json);
    if (parsed.errors.isNotEmpty && parsed.profileEntries.isEmpty) {
      return ImportResult(errors: parsed.errors);
    }
    // Without a password we cannot decrypt; the UI is expected to use the
    // two-stage path for vault envelopes. Re-emit a non-vault parsed import
    // so the existing call sites keep their behavior.
    return applyParsedImport(ParsedImport(
      profileEntries: parsed.profileEntries,
      errors: parsed.errors,
    ));
  }

  /// Delete a single profile by identity. Persists if anything was removed.
  Future<void> remove({
    required String host,
    required int port,
    required String username,
  }) async {
    final list = await load();
    final before = list.length;
    list.removeWhere(
      (p) => p.host == host && p.port == port && p.username == username,
    );
    if (list.length != before) {
      await save(list);
    }
  }
}

/// Decrypted credentials for a saved profile, ready to drop into the connect
/// form / dartssh2 client. All fields are optional — callers handle null.
///
/// `privateKey` is the PEM-encoded key bytes (string form so callers can
/// utf8-encode it before handing to dartssh2's `SSHKeyPair.fromPem`).
class ProfileCredentials {
  ProfileCredentials({this.password, this.privateKey, this.passphrase});
  final String? password;
  final String? privateKey;
  final String? passphrase;

  bool get isEmpty =>
      password == null && privateKey == null && passphrase == null;
}

/// Load decrypted credentials for [profile] from [secrets].
///
/// Resolves the bug in #519: a `key`-auth profile imported from the PWA has
/// its private-key blob stored under `profile.keyVaultId` (NOT `vaultId`).
/// Prior to this helper, the connect path only read `vaultId`, so the key
/// blob sat unused in flutter_secure_storage and the user was re-prompted.
///
/// Shape contract (mirrors PWA `src/modules/profiles.ts:450-493`):
///   `vault.encrypted[vaultId]`    → `{password?, privateKey?, passphrase?}`
///   `vault.encrypted[keyVaultId]` → `{data: <PEM>, passphrase?}`
///
/// The keyVaultId entry's `data` field holds the PEM-encoded private key.
/// A legacy `privateKey` field is also accepted to tolerate alternative
/// import paths. The keyVaultId entry's passphrase takes precedence over
/// the vaultId entry's passphrase for a `key`-auth profile.
Future<ProfileCredentials> loadProfileCredentials(
  SecretsStore secrets,
  SavedProfile profile,
) async {
  String? password;
  String? privateKey;
  String? passphrase;

  // Pass 1: vaultId entry (typically `{password, passphrase?}` shape for a
  // password-auth profile; may also carry a privateKey for legacy profiles
  // that bundled key + password into one entry).
  final vaultId = profile.vaultId;
  if (vaultId != null && vaultId.isNotEmpty) {
    final entry = await secrets.read(vaultId);
    if (entry != null) {
      final pw = entry['password'];
      if (pw is String && pw.isNotEmpty) password = pw;
      final pk = entry['privateKey'];
      if (pk is String && pk.isNotEmpty) privateKey = pk;
      final pp = entry['passphrase'];
      if (pp is String && pp.isNotEmpty) passphrase = pp;
    }
  }

  // Pass 2: keyVaultId entry (PWA shape: `{data: <PEM>, passphrase?}`).
  // Overrides any privateKey / passphrase pulled from the vaultId entry,
  // since this is the key-specific entry by design.
  final keyVaultId = profile.keyVaultId;
  if (keyVaultId != null && keyVaultId.isNotEmpty) {
    final entry = await secrets.read(keyVaultId);
    if (entry != null) {
      // PWA canonical key field is `data` (see profiles.ts:482). Fall back
      // to `privateKey` for resilience against alternative import paths.
      final data = entry['data'];
      if (data is String && data.isNotEmpty) {
        privateKey = data;
      } else {
        final legacy = entry['privateKey'];
        if (legacy is String && legacy.isNotEmpty) {
          privateKey = legacy;
        }
      }
      final pp = entry['passphrase'];
      if (pp is String && pp.isNotEmpty) passphrase = pp;
    }
  }

  return ProfileCredentials(
    password: password,
    privateKey: privateKey,
    passphrase: passphrase,
  );
}
