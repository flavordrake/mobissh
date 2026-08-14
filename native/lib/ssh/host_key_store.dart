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

/// Classification of an offered host key against stored trust (#1108).
///
/// The old boolean [HostKeyStore.isTrusted] collapsed [unknown] and [mismatch]
/// into a single `false`, so a CHANGED key (the MITM signal) was shown the same
/// trust-on-first-use prompt as a brand-new host. This enum keeps them distinct
/// and adds [storeUnavailable] so an unreadable store fails CLOSED instead of
/// masquerading as a fresh host.
enum HostKeyStatus {
  /// No entry for `host:port` — genuine first contact (TOFU prompt).
  unknown,

  /// Stored fingerprint equals the offered one — proceed silently.
  match,

  /// An entry exists but the offered fingerprint DIFFERS — refuse by default.
  mismatch,

  /// Trust could not be loaded (corrupt/unavailable storage) — fail closed.
  storeUnavailable,
}

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
/// shared_preferences. Corrupt data THROWS so the store can fail closed (#1108)
/// rather than silently degrade a known trust map to empty.
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
    // Corrupt data THROWS (jsonDecode's FormatException, or the not-a-Map guard)
    // rather than degrading to an empty map: an empty map would downgrade every
    // KNOWN host to "unknown" and re-open the accept prompt (fails open).
    // [HostKeyStore._hydrate] catches the throw and marks the store UNAVAILABLE
    // so the verify path fails CLOSED (#1108).
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('host key store: not a JSON object');
    }
    final out = <String, String>{};
    decoded.forEach((k, v) {
      if (k is String && v is String) out[k] = v;
    });
    return out;
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

  /// False once hydration failed to read the backend (corrupt/unavailable
  /// storage). Drives [status] → [HostKeyStatus.storeUnavailable] so the verify
  /// path fails CLOSED instead of treating known hosts as unknown (#1108).
  bool _storeAvailable = true;

  /// Serializes persistence so fire-and-forget writes can't complete OUT OF
  /// ORDER (#1108) — a forgotten entry must not be resurrected by a slower
  /// earlier write, nor a trust lost.
  Future<void> _writeChain = Future<void>.value();

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
      // Backend unavailable (no platform channel, a transient storage error, or
      // CORRUPT data). Mark the store unavailable so the verify path fails
      // CLOSED (#1108) — degrading to an empty map would turn KNOWN hosts into
      // "unknown" and re-open the accept prompt (fails open).
      _storeAvailable = false;
      _hydrated = true;
      return;
    }
    // Don't clobber any trust decisions that landed between ctor and hydrate
    // completion — in-memory writes win, hydration only fills gaps.
    loaded.forEach((k, v) => _trusted.putIfAbsent(k, () => v));
    _hydrated = true;
  }

  void _persist() {
    // Snapshot the map at call time and queue the write behind any in-flight
    // one, so serialized saves land in call order (#1108). saveAll is overwrite
    // semantics; the last-queued snapshot wins. Backend errors are swallowed so
    // a failed write never crashes the verify path.
    final snapshot = Map<String, String>.from(_trusted);
    _writeChain = _writeChain.then(
      (_) => _backend.saveAll(snapshot).catchError((Object _) {}),
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

  /// Classify [fingerprint] for `host:port` (#1108). Distinguishes first contact
  /// ([HostKeyStatus.unknown]) from a CHANGED key ([HostKeyStatus.mismatch]) —
  /// the two the boolean [isTrusted] collapsed — and reports
  /// [HostKeyStatus.storeUnavailable] when trust couldn't be loaded, so the
  /// verify path can fail CLOSED instead of prompting.
  HostKeyStatus status(String host, int port, String fingerprint) {
    if (!_storeAvailable) return HostKeyStatus.storeUnavailable;
    final stored = _trusted['$host:$port'];
    if (stored == null) return HostKeyStatus.unknown;
    return stored == fingerprint ? HostKeyStatus.match : HostKeyStatus.mismatch;
  }

  /// Trust [fingerprint] for `host:port` ONLY when the host is currently UNKNOWN
  /// (compare-and-set). Returns whether it trusted. The ordinary accept prompt
  /// calls this so a CHANGED key can NEVER be trusted through it (#1108) —
  /// re-trusting a rotated key requires the deliberate [forget] + [trust]
  /// affordance. Refuses while the store is unavailable (fail closed).
  bool trustIfUnknown(String host, int port, String fingerprint) {
    if (status(host, port, fingerprint) != HostKeyStatus.unknown) return false;
    trust(host, port, fingerprint);
    return true;
  }

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
