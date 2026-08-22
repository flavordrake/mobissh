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

import '../diagnostics/connect_trace.dart';
import 'backup.dart';
import 'secrets_store.dart';
import 'vault.dart';

/// One profile-default LOCAL port forward (ssh -L, #1047): listen on
/// 127.0.0.1:[localPort] on the device, tunnel to [remoteHost]:[remotePort]
/// as reachable from the SSH server. Armed automatically on (re)connect.
/// Identity within a profile is [localPort] (one listener per port).
class ProfileForward {
  const ProfileForward({
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
  });

  final int localPort;
  final String remoteHost;
  final int remotePort;

  Map<String, dynamic> toJson() => {
    'localPort': localPort,
    'remoteHost': remoteHost,
    'remotePort': remotePort,
  };

  /// Validating decode: null for anything unusable (corrupt-resilience per
  /// .claude/rules — a bad entry is dropped, never a crash). An absent/empty
  /// remoteHost defaults to 127.0.0.1 (the ssh -L default target).
  static ProfileForward? fromJson(Map<String, dynamic> json) {
    final lp = _coercePort(json['localPort']);
    final rp = _coercePort(json['remotePort']);
    if (lp == null || rp == null) return null;
    final hostRaw = json['remoteHost'];
    final host = (hostRaw is String && hostRaw.trim().isNotEmpty)
        ? hostRaw.trim()
        : '127.0.0.1';
    return ProfileForward(localPort: lp, remoteHost: host, remotePort: rp);
  }

  static int? _coercePort(Object? raw) {
    final int v;
    if (raw is int) {
      v = raw;
    } else if (raw is double) {
      v = raw.toInt();
    } else if (raw is String) {
      final parsed = int.tryParse(raw);
      if (parsed == null) return null;
      v = parsed;
    } else {
      return null;
    }
    if (v < 1 || v > 65535) return null;
    return v;
  }
}

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
    this.fontSize,
    this.fontFamily,
    this.color,
    this.authType,
    this.vaultId,
    this.keyVaultId,
    this.initialCommand,
    this.defaultPath = '',
    this.forwards = const [],
  });

  final String title;
  final String host;
  final int port;
  final String username;
  final String? theme;

  /// Per-profile terminal font size in logical px (#640). Null when the user
  /// hasn't customized it — the session then opens at the app default
  /// ([fontSizeDefault] in ui_prefs_providers.dart). Persisted alongside
  /// [theme] (#613): both are per-profile appearance, seeded into a session on
  /// connect. Validated/clamped on read to [_fontSizeMin]..[_fontSizeMax].
  final double? fontSize;

  /// Per-profile terminal font family (#679) — one of the bundled families
  /// (`JetBrainsMono`/`FiraCode`/`CascadiaCode`). Null when the user hasn't
  /// picked one — the session then opens at the app default
  /// ([fontFamilyDefault]). Persisted alongside [theme]/[fontSize] (all
  /// per-profile appearance, seeded into a session on connect). Validated on
  /// read against the known bundled families; an unknown value yields null so
  /// the session falls back to the default face (no missing-font render).
  final String? fontFamily;

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

  /// Optional file-browser starting directory (#891). Empty string = current
  /// behaviour (open at the SFTP home). Crucial for VPS/seedbox hosts (Whatbox)
  /// where the SFTP home is NOT where you work — you want to land in e.g.
  /// `/files` or `~/downloads`. Per-PROFILE (a property of the host), seeded
  /// into the file browser's initial listing on open and resolved through the
  /// SFTP `_resolve()` chokepoint (#867 — `~`/relative expand against the
  /// session home; absolute passes through; invalid → friendly empty-state).
  ///
  /// Stored as a plain string; an absent field on an OLD profile JSON reads
  /// back as '' (migration via [_coerceDefaultPath] — no key bump, per
  /// .claude/rules code-style), so legacy profiles keep their current behaviour.
  final String defaultPath;

  /// Profile-default LOCAL port forwards (ssh -L, #1047), armed on every
  /// (re)connect of a session matching this profile. Empty for legacy
  /// profiles (absent field reads back as [] via [_coerceForwards] — the
  /// schema migration, no key bump per .claude/rules code-style).
  final List<ProfileForward> forwards;

  /// Identity key for dedupe / lookup. Matches the PWA's behavior of treating
  /// (host:port:username) as the unique constraint.
  String get identityKey => '$host:$port:$username';

  /// Clamp bounds for [fontSize], mirroring the PWA `FONT_SIZE` constant
  /// (`{ MIN: 8, MAX: 32 }` in src/modules/constants.ts) and the native
  /// [kFontSizeMin]/[kFontSizeMax] in ui_prefs_providers.dart. Inlined here so
  /// the storage layer stays free of a UI-providers import.
  static const double _fontSizeMin = 8.0;
  static const double _fontSizeMax = 32.0;

  /// Validate + clamp a raw stored font size. Accepts int or double (JSON
  /// encoders vary); anything non-numeric yields null (corrupt -> default
  /// fallback, per .claude/rules config-system policy — no crash).
  static double? _coerceFontSize(Object? raw) {
    final double v;
    if (raw is int) {
      v = raw.toDouble();
    } else if (raw is double) {
      v = raw;
    } else {
      return null;
    }
    if (v.isNaN || v.isInfinite) return null;
    return v.clamp(_fontSizeMin, _fontSizeMax);
  }

  /// The bundled terminal font families (#679). Inlined here (mirrors the
  /// _fontSize* bounds) so the storage layer stays free of a UI-providers
  /// import; kept in sync with [terminalFontFamilies] in ui_prefs_providers.dart.
  static const Set<String> _knownFontFamilies = {
    'JetBrainsMono',
    'FiraCode',
    'CascadiaCode',
  };

  /// Validate a raw stored font family. Returns the value only when it is a
  /// known bundled family; anything else (null, typo, removed face) yields null
  /// so the session falls back to the default face (corrupt-resilience, per
  /// .claude/rules config-system policy — no crash, no missing-font render).
  static String? _coerceFontFamily(Object? raw) {
    if (raw is String && _knownFontFamilies.contains(raw)) return raw;
    return null;
  }

  /// Validate a raw stored forwards list (#1047). Non-list / absent → [];
  /// corrupt entries inside the list are dropped individually (per
  /// [ProfileForward.fromJson]). This IS the schema migration for the
  /// absent-field case — no key bump.
  static List<ProfileForward> _coerceForwards(Object? raw) {
    if (raw is! List) return const [];
    final out = <ProfileForward>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final fwd = ProfileForward.fromJson(Map<String, dynamic>.from(entry));
      if (fwd != null) out.add(fwd);
    }
    return out;
  }

  /// Validate a raw stored default path (#891). Returns the trimmed string when
  /// it's a non-empty String; anything else (null, absent on an OLD profile,
  /// non-String) yields '' so legacy profiles + corrupt values fall back to the
  /// SFTP-home behaviour (corrupt-resilience per .claude/rules — no crash, no
  /// key bump). This IS the schema migration for the absent-field case.
  static String _coerceDefaultPath(Object? raw) {
    if (raw is String) return raw.trim();
    return '';
  }

  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{
      'title': title,
      'host': host,
      'port': port,
      'username': username,
    };
    if (theme != null) out['theme'] = theme;
    if (fontSize != null) out['fontSize'] = fontSize;
    if (fontFamily != null) out['fontFamily'] = fontFamily;
    if (color != null) out['color'] = color;
    if (authType != null) out['authType'] = authType;
    if (vaultId != null) out['vaultId'] = vaultId;
    if (keyVaultId != null) out['keyVaultId'] = keyVaultId;
    if (initialCommand != null && initialCommand!.isNotEmpty) {
      out['initialCommand'] = initialCommand;
    }
    // #891: omit when empty so old profiles + default-empty ones stay byte-for-
    // byte identical (absent field is the migration signal, not a key bump).
    if (defaultPath.isNotEmpty) out['defaultPath'] = defaultPath;
    // #1047: same omit-when-empty policy for the default forwards.
    if (forwards.isNotEmpty) {
      out['forwards'] = forwards.map((f) => f.toJson()).toList();
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

    final double? fontSize = _coerceFontSize(json['fontSize']);
    final String? fontFamily = _coerceFontFamily(json['fontFamily']);

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

    final String defaultPath = _coerceDefaultPath(json['defaultPath']);
    final List<ProfileForward> forwards = _coerceForwards(json['forwards']);

    return SavedProfile(
      title: title,
      host: hostRaw,
      port: port,
      username: usernameRaw,
      theme: theme,
      fontSize: fontSize,
      fontFamily: fontFamily,
      color: color,
      authType: authType,
      vaultId: vaultId,
      keyVaultId: keyVaultId,
      initialCommand: initialCommand,
      defaultPath: defaultPath,
      forwards: forwards,
    );
  }

  SavedProfile copyWith({
    String? title,
    String? vaultId,
    String? keyVaultId,
    double? fontSize,
    String? fontFamily,
    String? theme,
    String? defaultPath,
    List<ProfileForward>? forwards,
  }) {
    return SavedProfile(
      title: title ?? this.title,
      host: host,
      port: port,
      username: username,
      theme: theme ?? this.theme,
      fontSize: fontSize ?? this.fontSize,
      fontFamily: fontFamily ?? this.fontFamily,
      color: color,
      authType: authType,
      vaultId: vaultId ?? this.vaultId,
      keyVaultId: keyVaultId ?? this.keyVaultId,
      initialCommand: initialCommand,
      defaultPath: defaultPath ?? this.defaultPath,
      forwards: forwards ?? this.forwards,
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
///
/// `updated` (#547) counts existing profiles that were upserted in place — an
/// incoming entry whose identity (host:port:username) matched a stored profile
/// and refreshed its authType/vaultId/keyVaultId/theme/color/initialCommand.
/// It is additive: existing callers that read [added]/[skipped] keep working.
class ImportResult {
  ImportResult({
    this.added = 0,
    this.updated = 0,
    this.skipped = 0,
    this.errors = const [],
    this.keysImported = 0,
    this.pinsAdded = 0,
    this.pinsConflicting = 0,
    this.settingsApplied = 0,
    this.settingsSkipped = 0,
  });
  final int added;
  final int updated;
  final int skipped;
  final List<String> errors;

  // #1125 encrypted-backup restore counts (additive — always 0 for the v1
  // profile-import paths, so existing callers/tests are unaffected).

  /// Library keys upserted or cloned from the backup.
  final int keysImported;

  /// Host-key pins added (add-absent-only).
  final int pinsAdded;

  /// Host-key pins that conflicted with a local pin and were KEPT local.
  final int pinsConflicting;

  /// Allowlisted settings applied.
  final int settingsApplied;

  /// Allowlisted settings skipped for an invalid value/type.
  final int settingsSkipped;
}

/// Outcome of a sync envelope-shape scan. The UI uses this to decide whether
/// to render a master-password prompt before committing the import.
class ParsedImport {
  ParsedImport({
    required this.profileEntries,
    this.vaultEncryptedJson,
    this.vaultMetaJson,
    this.errors = const [],
    this.isEncryptedBackup = false,
    this.envelopeJson,
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

  /// True when the input is a v2 encrypted-backup envelope (#1125). The
  /// caller prompts for the backup passphrase, decrypts [envelopeJson] via
  /// `decryptBackupEnvelope`, and applies with `applyBackupPayload`
  /// (backup_restore.dart) — NOT [ProfilesStore.applyParsedImport].
  final bool isEncryptedBackup;

  /// The raw envelope JSON when [isEncryptedBackup]; null otherwise. Carried
  /// verbatim so decrypt-at-password-submit re-parses the exact bytes.
  final String? envelopeJson;

  /// True when this envelope carries an encrypted vault — caller must prompt
  /// for the master password before [ProfilesStore.applyParsedImport].
  bool get hasVault => vaultEncryptedJson != null && vaultMetaJson != null;
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
    // #1125: cap BEFORE any JSON work — a hostile multi-MB file must not get
    // to allocate a parse tree (mirrors decryptBackupEnvelope's own cap).
    if (json.length > kBackupMaxEnvelopeBytes) {
      return ParsedImport(
        profileEntries: const [],
        errors: ['File is too large to be a MobiSSH backup.'],
      );
    }
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
      return ParsedImport(profileEntries: _coerceEntries(decoded));
    }

    if (decoded is! Map) {
      return ParsedImport(
        profileEntries: const [],
        errors: [
          'Wrong file shape — expected an export envelope or profile array.',
        ],
      );
    }

    // #1125: v2 encrypted-backup envelope. Recognized by its `format` field —
    // and then required to be the EXACT outer schema. An object that mixes v1
    // markers (profiles/vault) with the v2 format field, adds extra fields, or
    // drops one is rejected outright rather than guessed at.
    if (decoded['format'] == kBackupFormat) {
      const allowed = {'format', 'version', 'kdf', 'cipher', 'ciphertext'};
      final keys = decoded.keys.whereType<String>().toSet();
      final exact = keys.length == decoded.length &&
          keys.length == allowed.length &&
          keys.containsAll(allowed);
      if (!exact || !looksLikeBackupEnvelope(Map<String, dynamic>.from(decoded))) {
        return ParsedImport(
          profileEntries: const [],
          errors: ['Not a valid MobiSSH backup file.'],
        );
      }
      return ParsedImport(
        profileEntries: const [],
        isEncryptedBackup: true,
        envelopeJson: json,
      );
    }

    final version = decoded['version'];
    if (version != null && version != 1) {
      return ParsedImport(
        profileEntries: const [],
        errors: [
          'Unsupported export version: $version (this client supports v1).',
        ],
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
      if (enc is String &&
          enc.isNotEmpty &&
          meta is String &&
          meta.isNotEmpty) {
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
        return ImportResult(
          errors: ['Master password required to decrypt vault.'],
        );
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
        return ImportResult(
          errors: ['Vault envelope is malformed: ${e.message}'],
        );
      }
    }

    final existing = await load();
    // Index existing profiles by identity for in-place upsert (#547).
    final byIdentity = <String, int>{
      for (var i = 0; i < existing.length; i++) existing[i].identityKey: i,
    };
    final errors = <String>[...parsed.errors];
    int added = 0;
    int updated = 0;
    int withVault = 0;
    int withKeyVaultId = 0;
    int withAuthType = 0;

    for (final entry in parsed.profileEntries) {
      try {
        final raw = SavedProfile.fromJson(entry);

        // #1106: a credential handle from imported JSON is trustworthy ONLY if
        // the secret it names actually travelled WITH this import (present in
        // the just-decrypted vault). Vault ids are predictable
        // (`profile-<host>:<port>:<username>`), so an unbacked handle can name
        // some OTHER host's stored secret — connect would then authenticate to
        // the attacker's host with the victim's password/key. The plain
        // no-vault path has an empty [decryptedVault], so every handle is
        // dropped there; only a password-decrypted backup envelope carries
        // trusted handles.
        final String? safeVaultId =
            (raw.vaultId != null && decryptedVault.containsKey(raw.vaultId))
                ? raw.vaultId
                : null;
        final String? safeKeyVaultId = (raw.keyVaultId != null &&
                decryptedVault.containsKey(raw.keyVaultId))
            ? raw.keyVaultId
            : null;
        final bool importBroughtSecret =
            safeVaultId != null || safeKeyVaultId != null;
        if (safeVaultId != null) withVault++;
        if (safeKeyVaultId != null) withKeyVaultId++;

        final existingIndex = byIdentity[raw.identityKey];
        if (existingIndex != null) {
          // #547: re-import over a (possibly stale identity-only) profile is an
          // UPSERT, not a skip — refresh the non-secret visual/endpoint
          // identity. Preserve the user's existing title.
          //
          // #1106: NEVER let an untrusted import overwrite an existing local
          // profile's credential bundle (authType/vaultId/keyVaultId) or its
          // auto-run config (initialCommand/forwards). Binding a handle from
          // untrusted JSON would rebind the profile to an arbitrary stored
          // secret (the theft vector); flipping authType would connect it in a
          // mode pointing at that rebound secret. Only a genuine backup restore
          // (the secret travelled with the import, so the handle is backed by
          // the decrypted vault) may adopt the import's validated bundle in
          // place. Auto-run config is never installed by import. Only the
          // non-secret display/endpoint metadata is refreshed.
          final prior = existing[existingIndex];
          final String? mergedAuthType;
          final String? mergedVaultId;
          final String? mergedKeyVaultId;
          if (importBroughtSecret) {
            mergedAuthType = raw.authType;
            mergedVaultId = safeVaultId;
            mergedKeyVaultId = safeKeyVaultId;
          } else {
            mergedAuthType = prior.authType;
            mergedVaultId = prior.vaultId;
            mergedKeyVaultId = prior.keyVaultId;
          }
          if (mergedAuthType != null) withAuthType++;
          existing[existingIndex] = SavedProfile(
            title: prior.title,
            host: prior.host,
            port: prior.port,
            username: prior.username,
            theme: raw.theme,
            fontSize: raw.fontSize,
            fontFamily: raw.fontFamily,
            color: raw.color,
            authType: mergedAuthType,
            vaultId: mergedVaultId,
            keyVaultId: mergedKeyVaultId,
            initialCommand: prior.initialCommand,
            defaultPath: raw.defaultPath,
            forwards: prior.forwards,
          );
          updated++;
          continue;
        }
        // #1106: a NEW identity arrives credential-less unless a trusted secret
        // travelled with it, and never carries imported auto-run config. It
        // keeps its descriptive authType so a key profile prompts for its key
        // on first connect rather than silently downgrading to password (#961).
        if (raw.authType != null) withAuthType++;
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
          initialCommand: null,
          defaultPath: raw.defaultPath,
          forwards: const [],
        );
        existing.add(safe);
        byIdentity[safe.identityKey] = existing.length - 1;
        added++;
      } on FormatException catch (e) {
        errors.add(e.message);
      }
    }

    ctrace(
      'ui.import',
      'profiles=${parsed.profileEntries.length} added=$added '
          'updated=$updated withVault=$withVault '
          'withKeyVaultId=$withKeyVaultId withAuthType=$withAuthType',
    );

    // Persist secrets before profiles. If profile save fails (it shouldn't),
    // we'd rather leak an extra secret blob than have a profile without its
    // secret. Either way, the same vaultId would just be overwritten on a
    // re-import. Secrets are written for BOTH added and updated profiles —
    // an upserted key profile that just gained its keyVaultId needs the secret
    // re-stored, not only freshly-added ones (#547).
    if (secrets != null) {
      for (final entry in decryptedVault.entries) {
        await secrets.write(entry.key, entry.value);
      }
    }

    if (added > 0 || updated > 0) {
      await save(existing);
    }

    return ImportResult(
      added: added,
      updated: updated,
      skipped: 0,
      errors: errors,
    );
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
    return applyParsedImport(
      ParsedImport(
        profileEntries: parsed.profileEntries,
        errors: parsed.errors,
      ),
    );
  }

  /// Upsert a single profile by identity (#579 profile editor).
  ///
  /// When [previousIdentityKey] is supplied and differs from the incoming
  /// profile's identity, the old entry (matched by that key) is removed first
  /// — this is the rename case where the editor changed host/port/username.
  /// Otherwise the matching identity is updated in place; a brand-new identity
  /// is appended. Mirrors the import upsert semantics (identity-keyed).
  Future<void> upsert(
    SavedProfile profile, {
    String? previousIdentityKey,
  }) async {
    final list = await load();
    final prevKey = previousIdentityKey ?? profile.identityKey;
    final idx = list.indexWhere((p) => p.identityKey == prevKey);
    if (idx >= 0) {
      list[idx] = profile;
    } else {
      // Identity didn't match the previous key — maybe the new identity
      // already exists (collision). Update that in place if so, else append.
      final collision = list.indexWhere(
        (p) => p.identityKey == profile.identityKey,
      );
      if (collision >= 0) {
        list[collision] = profile;
      } else {
        list.add(profile);
      }
    }
    await save(list);
  }

  /// Persist a per-profile terminal font size (#640) onto the profile matching
  /// [identityKey] (`host:port:username`). The font is clamped/validated by
  /// [SavedProfile.fromJson]'s rules on the next read; we store the raw value
  /// here (the menu stepper already clamps to [kFontSizeMin]..[kFontSizeMax]).
  ///
  /// NO-OP when no saved profile matches — an ad-hoc connect (host typed into
  /// the form, never saved) must NOT be materialized as a saved profile just
  /// because the user stepped its font. Returns true iff a profile was updated.
  Future<bool> setFontSize(String identityKey, double size) async {
    final list = await load();
    final idx = list.indexWhere((p) => p.identityKey == identityKey);
    if (idx < 0) return false;
    list[idx] = list[idx].copyWith(fontSize: size);
    await save(list);
    return true;
  }

  /// Persist a per-profile terminal font family (#679) onto the profile
  /// matching [identityKey] (`host:port:username`). Mirrors [setFontSize]: the
  /// session-menu picker calls this so the chosen face survives restart/
  /// reconnect. The value is round-trip-validated by [SavedProfile.fromJson]'s
  /// rules on the next read (an unknown family reads back as null → default).
  ///
  /// NO-OP when no saved profile matches — an ad-hoc connect (host typed into
  /// the form, never saved) must NOT be materialized as a saved profile just
  /// because the user picked its font. Returns true iff a profile was updated.
  Future<bool> setFontFamily(String identityKey, String family) async {
    final list = await load();
    final idx = list.indexWhere((p) => p.identityKey == identityKey);
    if (idx < 0) return false;
    list[idx] = list[idx].copyWith(fontFamily: family);
    await save(list);
    return true;
  }

  /// Persist a per-profile terminal theme (#613, #724) onto the profile matching
  /// [identityKey] (`host:port:username`). [themeKey] is the PWA `ThemeName` key
  /// (e.g. 'dracula') that connect maps back to a palette via
  /// [paletteIndexForThemeName]. Mirrors [setFontFamily]: the session-menu theme
  /// picker calls this so the chosen palette survives restart/reconnect.
  ///
  /// NO-OP when no saved profile matches — an ad-hoc connect (host typed into
  /// the form, never saved) must NOT be materialized as a saved profile just
  /// because the user picked its theme. Returns true iff a profile was updated.
  Future<bool> setTheme(String identityKey, String themeKey) async {
    final list = await load();
    final idx = list.indexWhere((p) => p.identityKey == identityKey);
    if (idx < 0) return false;
    list[idx] = list[idx].copyWith(theme: themeKey);
    await save(list);
    return true;
  }

  /// Persist the profile-default port forwards (#1047) onto the profile
  /// matching [identityKey] (`host:port:username`). The sheet's per-forward
  /// "profile default" toggle calls this with the full desired list (an empty
  /// list clears them).
  ///
  /// NO-OP when no saved profile matches — an ad-hoc connect must NOT be
  /// materialized as a saved profile just because the user armed a forward
  /// (mirrors [setFontSize]/[setTheme]). Returns true iff a profile updated.
  Future<bool> setForwards(
    String identityKey,
    List<ProfileForward> forwards,
  ) async {
    final list = await load();
    final idx = list.indexWhere((p) => p.identityKey == identityKey);
    if (idx < 0) return false;
    list[idx] = list[idx].copyWith(forwards: forwards);
    await save(list);
    return true;
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
