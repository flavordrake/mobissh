// Persistent host-key trust store (#565).
//
// Trust-on-first-use registry that survives connects AND app launches. The
// SYNC verify path (`SshSessionController._onVerifyHostKey`) reads an in-memory
// map; an async backend hydrates that map on construction and persists every
// trust/forget decision.
//
// Why SharedPreferences (not flutter_secure_storage): host PUBLIC-key
// fingerprints are SHA-256 hashes of public keys — they are not secret. Storing
// them in plain SharedPreferences is the simplest fit and mirrors
// `profiles_store.dart`. Private keys / passphrases NEVER touch this store
// (those live in `secrets_store.dart`, Keystore-backed). Per .claude security
// rules: fingerprints are fine to persist; secrets are not.

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// shared_preferences key. Versioned so a future schema change can migrate
/// in-place (per .claude/rules code-style: version inside the value/key, never
/// bump to fix cache issues).
const String hostKeysPrefsKey = 'mobissh.hostkeys.v1';

/// Pluggable persistence backend for trusted host fingerprints.
///
/// The map is keyed by `"host:port"` → fingerprint hex. Production uses
/// [SharedPrefsHostKeyBackend]; tests inject [InMemoryHostKeyBackend].
abstract class HostKeyBackend {
  /// Load the full trust map. Returns `{}` when nothing is stored.
  Future<Map<String, String>> loadAll();

  /// Persist the full trust map, overwriting any prior value.
  Future<void> saveAll(Map<String, String> map);
}

/// Production backend: a JSON map under [hostKeysPrefsKey] in
/// shared_preferences. Corrupt data falls back to an empty map (no crash).
class SharedPrefsHostKeyBackend implements HostKeyBackend {
  SharedPrefsHostKeyBackend({SharedPreferences? prefs}) : _prefs = prefs;

  // ignore_for_file: prefer_initializing_formals
  SharedPreferences? _prefs;

  Future<SharedPreferences> _ensure() async =>
      _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<Map<String, String>> loadAll() async {
    final prefs = await _ensure();
    final raw = prefs.getString(hostKeysPrefsKey);
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      final out = <String, String>{};
      decoded.forEach((k, v) {
        if (k is String && v is String) out[k] = v;
      });
      return out;
    } on FormatException {
      return <String, String>{};
    }
  }

  @override
  Future<void> saveAll(Map<String, String> map) async {
    final prefs = await _ensure();
    await prefs.setString(hostKeysPrefsKey, jsonEncode(map));
  }
}

/// In-memory backend for tests. Pass the SAME instance to two HostKeyStores to
/// simulate an app relaunch (second store hydrates what the first persisted).
class InMemoryHostKeyBackend implements HostKeyBackend {
  InMemoryHostKeyBackend([Map<String, String>? seed])
    : _store = <String, String>{...?seed};

  final Map<String, String> _store;

  @override
  Future<Map<String, String>> loadAll() async =>
      Map<String, String>.from(_store);

  @override
  Future<void> saveAll(Map<String, String> map) async {
    _store
      ..clear()
      ..addAll(map);
  }
}

/// Trust-on-first-use host-key registry.
///
/// Keyed by `"host:port"` -> fingerprint string (caller decides format —
/// SshSessionController hands us hex of the SHA-256 fingerprint that dartssh2
/// provides via `SSHHostkeyVerifyHandler`).
///
/// The in-memory [_trusted] map is the authoritative source for the SYNC
/// [isTrusted] verify path. Construction eagerly hydrates it from [_backend];
/// [trust]/[forget] mutate it synchronously and persist asynchronously. Callers
/// on the verify path MUST `await ready` first so a freshly-constructed store
/// (e.g. a new session after app launch) doesn't re-prompt before hydration.
class HostKeyStore {
  HostKeyStore({HostKeyBackend? backend})
    : _backend = backend ?? SharedPrefsHostKeyBackend() {
    _ready = _hydrate();
  }

  final HostKeyBackend _backend;
  final Map<String, String> _trusted = <String, String>{};
  late final Future<void> _ready;
  bool _hydrated = false;

  /// Resolves once persisted trust has been loaded into the in-memory map.
  /// Idempotent to await repeatedly. The verify path awaits this ONLY when
  /// [isHydrated] is still false, so the common (already-loaded) path stays
  /// synchronous and emits `awaitingHostKey` without an extra event-loop turn.
  Future<void> get ready => _ready;

  /// True once hydration has completed. Lets the verify path skip the
  /// `await ready` gap when the map is already loaded (the normal case —
  /// hydration starts at construction, long before the first verify).
  bool get isHydrated => _hydrated;

  Future<void> _hydrate() async {
    Map<String, String> loaded;
    try {
      loaded = await _backend.loadAll();
    } catch (_) {
      // Backend unavailable (e.g. no platform channel in a unit test, or a
      // transient storage error). Degrade to an empty trust map rather than
      // throwing on the verify path — worst case the user re-confirms once.
      loaded = const <String, String>{};
    }
    // Don't clobber any trust decisions that landed between ctor and hydrate
    // completion — in-memory writes win, hydration only fills gaps.
    loaded.forEach((k, v) => _trusted.putIfAbsent(k, () => v));
    _hydrated = true;
  }

  void _persist() {
    // Fire-and-forget snapshot of the full map. saveAll is overwrite semantics
    // so concurrent calls converge on the latest in-memory state. Swallow
    // backend errors so a failed write never crashes the verify path.
    unawaited(
      _backend
          .saveAll(Map<String, String>.from(_trusted))
          .catchError((Object _) {}),
    );
  }

  /// Returns true iff [fingerprint] matches the previously-trusted value for
  /// `host:port`. SYNC by design — reads the hydrated in-memory map.
  bool isTrusted(String host, int port, String fingerprint) {
    final stored = _trusted['$host:$port'];
    return stored != null && stored == fingerprint;
  }

  /// Returns the trusted fingerprint for `host:port`, or null if none.
  String? trustedFingerprint(String host, int port) => _trusted['$host:$port'];

  /// Persist a trust decision. Overwrites any prior entry. Updates the
  /// in-memory map synchronously and schedules an async backend write.
  void trust(String host, int port, String fingerprint) {
    _trusted['$host:$port'] = fingerprint;
    _persist();
  }

  /// Remove a trust entry (e.g. user rejected a rotated key).
  void forget(String host, int port) {
    final removed = _trusted.remove('$host:$port');
    if (removed != null) _persist();
  }

  /// Number of trusted hosts. Useful in tests.
  int get length => _trusted.length;
}
