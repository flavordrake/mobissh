// SSH key library — first-class, named, reusable keys managed independently of
// any profile (#1088). Mirrors profiles_store: METADATA (id, name, public key,
// fingerprint) lives here in SharedPreferences (NON-secret, schema-versioned,
// corrupt-data-resilient); the PRIVATE key material NEVER touches this store —
// it lives only in the encrypted vault (secrets_store) under [keyVaultIdFor].
//
// A profile attaches a key by pointing its `keyVaultId` at the key's vault id;
// many profiles can share one key.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The vault id under which key [id]'s PRIVATE material (PEM + optional
/// passphrase) is stored in secrets_store. Stable per id so a profile's
/// `keyVaultId` and this store agree.
String keyVaultIdFor(String id) => 'key-$id';

/// SharedPreferences key for the key-library METADATA list (v1). Never holds
/// private key bytes.
const String keysPrefsKey = 'mobissh.keys.v1';

/// A named SSH key in the library. Carries only NON-secret metadata; the private
/// key bytes live in the vault under [vaultId].
@immutable
class SavedKey {
  const SavedKey({
    required this.id,
    required this.name,
    String? vaultId,
    this.algorithm,
    this.publicKey,
    this.fingerprint,
    this.createdAtMs = 0,
    // Deliberately a plain param, not an initializing formal: the nullable
    // `vaultId` feeds the getter's `key-<id>` default (see [vaultId]).
  }) : _vaultId = vaultId; // ignore: prefer_initializing_formals

  /// Explicit vault id override. Null for a natively-created library key (whose
  /// material lives at `key-<id>`); SET when a pre-existing per-profile key was
  /// ADOPTED into the library in place (its material stays at the original
  /// `profile-key-<identity>` id — no re-keying, no vault movement, #1088).
  final String? _vaultId;

  /// Stable identity (minted once at creation). Also keys the vault entry.
  final String id;

  /// Human label shown in the picker / manager.
  final String name;

  /// e.g. `ed25519`, `rsa` — informational, may be null for an imported key we
  /// didn't parse.
  final String? algorithm;

  /// The `ssh-ed25519 AAAA… comment` public-key line — NON-secret, used for
  /// display and deploy (ssh-copy-id, #1088 Slice 3). Null until known.
  final String? publicKey;

  /// A `SHA256:…` fingerprint for at-a-glance identification. Null until known.
  final String? fingerprint;

  /// Creation time (ms since epoch), for stable sort. 0 when unknown.
  final int createdAtMs;

  /// Vault id holding this key's PRIVATE material. A profile attaches by setting
  /// its `keyVaultId` to this. Defaults to `key-<id>` for a natively-created key;
  /// an adopted per-profile key keeps its original vault id (see [_vaultId]).
  String get vaultId => _vaultId ?? keyVaultIdFor(id);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        // Persist the vault id ONLY when it's an explicit override (adopted key)
        // — a native key derives `key-<id>` on read, so omitting keeps old
        // metadata forward-compatible.
        if (_vaultId != null) 'vaultId': _vaultId,
        if (algorithm != null) 'algorithm': algorithm,
        if (publicKey != null) 'publicKey': publicKey,
        if (fingerprint != null) 'fingerprint': fingerprint,
        'createdAtMs': createdAtMs,
      };

  /// Parse one metadata entry. Throws [FormatException] for a missing/invalid
  /// id or name so the store can quarantine the corrupt entry (never a secret).
  factory SavedKey.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.isEmpty || name is! String) {
      throw const FormatException('SavedKey requires a non-empty string id + name');
    }
    return SavedKey(
      id: id,
      name: name,
      vaultId: json['vaultId'] is String ? json['vaultId'] as String : null,
      algorithm: json['algorithm'] is String ? json['algorithm'] as String : null,
      publicKey: json['publicKey'] is String ? json['publicKey'] as String : null,
      fingerprint:
          json['fingerprint'] is String ? json['fingerprint'] as String : null,
      createdAtMs: (json['createdAtMs'] as num?)?.toInt() ?? 0,
    );
  }

  SavedKey copyWith({
    String? name,
    String? algorithm,
    String? publicKey,
    String? fingerprint,
  }) =>
      SavedKey(
        id: id,
        name: name ?? this.name,
        // vaultId is immutable identity — always preserved, never a copyWith arg.
        vaultId: _vaultId,
        algorithm: algorithm ?? this.algorithm,
        publicKey: publicKey ?? this.publicKey,
        fingerprint: fingerprint ?? this.fingerprint,
        createdAtMs: createdAtMs,
      );

  @override
  bool operator ==(Object other) =>
      other is SavedKey &&
      other.id == id &&
      other.name == name &&
      other.vaultId == vaultId &&
      other.algorithm == algorithm &&
      other.publicKey == publicKey &&
      other.fingerprint == fingerprint &&
      other.createdAtMs == createdAtMs;

  @override
  int get hashCode => Object.hash(
      id, name, vaultId, algorithm, publicKey, fingerprint, createdAtMs);
}

/// Persists the key-library METADATA list. Private key bytes are the vault's
/// job — this store never sees them. Mirrors [ProfilesStore]'s corrupt-data
/// resilience: malformed storage → empty, bad entries skipped.
class KeysStore {
  // ignore: prefer_initializing_formals
  KeysStore({SharedPreferences? prefs}) : _prefs = prefs;

  SharedPreferences? _prefs;

  Future<SharedPreferences> _ensure() async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// Read all key metadata. Returns [] on nothing-stored or malformed JSON.
  Future<List<SavedKey>> load() async {
    final prefs = await _ensure();
    final raw = prefs.getString(keysPrefsKey);
    if (raw == null || raw.isEmpty) return <SavedKey>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <SavedKey>[];
      final out = <SavedKey>[];
      for (final entry in decoded) {
        if (entry is! Map) continue;
        try {
          out.add(SavedKey.fromJson(Map<String, dynamic>.from(entry)));
        } on FormatException {
          // Skip a corrupt entry rather than losing the whole library.
        }
      }
      return out;
    } on FormatException {
      return <SavedKey>[];
    }
  }

  /// Overwrite the whole metadata list (the UI mutates then saves).
  Future<void> save(List<SavedKey> keys) async {
    final prefs = await _ensure();
    await prefs.setString(
      keysPrefsKey,
      jsonEncode(keys.map((k) => k.toJson()).toList()),
    );
  }

  /// Insert or replace by [SavedKey.id].
  Future<void> upsert(SavedKey key) async {
    final list = await load();
    final idx = list.indexWhere((k) => k.id == key.id);
    if (idx >= 0) {
      list[idx] = key;
    } else {
      list.add(key);
    }
    await save(list);
  }

  /// Remove the metadata entry for [id]. No-op if absent. (The caller also
  /// deletes the vault blob — this store only owns metadata.)
  Future<void> remove(String id) async {
    final list = await load();
    list.removeWhere((k) => k.id == id);
    await save(list);
  }
}
