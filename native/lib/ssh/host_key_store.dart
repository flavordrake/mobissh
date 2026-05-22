// In-memory host-key trust store.
//
// Phase 1 (#501): plain in-memory map. Phase 3 will swap the backing store
// for flutter_secure_storage so trusted fingerprints survive app restarts.

/// Trust-on-first-use host-key registry.
///
/// Keyed by `"host:port"` -> fingerprint string (caller decides format —
/// SshSessionController hands us hex of the SHA-256 fingerprint that
/// dartssh2 provides via `SSHHostkeyVerifyHandler`).
class HostKeyStore {
  // TODO(#501 phase 3): persist via flutter_secure_storage.
  final Map<String, String> _trusted = <String, String>{};

  /// Returns true iff [fingerprint] matches the previously-trusted value
  /// for `host:port`.
  bool isTrusted(String host, int port, String fingerprint) {
    final stored = _trusted['$host:$port'];
    return stored != null && stored == fingerprint;
  }

  /// Returns the trusted fingerprint for `host:port`, or null if none.
  String? trustedFingerprint(String host, int port) =>
      _trusted['$host:$port'];

  /// Persist a trust decision. Overwrites any prior entry.
  void trust(String host, int port, String fingerprint) {
    _trusted['$host:$port'] = fingerprint;
  }

  /// Remove a trust entry (e.g. user rejected a rotated key).
  void forget(String host, int port) {
    _trusted.remove('$host:$port');
  }

  /// Number of trusted hosts. Useful in tests.
  int get length => _trusted.length;
}
