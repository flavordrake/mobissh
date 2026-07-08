// path_verifier.dart — per-session detected-path VERIFICATION cache (#990).
//
// A detected file-path anchor renders in the plain "detected" shade; once this
// verifier confirms the path EXISTS ON THE CONNECTED HOST (one SFTP stat via
// the session's `sftpStat` probe) the anchor upgrades to the bolder VERIFIED
// shade. The presentation layers never see WHY a path is verified — they get
// an opaque predicate + this ChangeNotifier — so the meaning of "verified"
// can later change (e.g. "downloaded locally") without touching paint code.
//
// Contract (issue #990):
//   - per-session: one verifier per session; state is keyed (session, path).
//     A path valid on host A says nothing about host B.
//   - debounced: a burst of anchor updates collapses into one batched drain.
//   - cached with a short TTL: a fresh answer (either way) is never re-probed;
//     an expired one lapses back to "detected" until re-confirmed.
//   - capped: at most [maxInFlight] outstanding stats; the rest queue.
//   - fail-open: a negative/errored/timed-out stat leaves the path in the
//     "detected" shade. Never blocks rendering (pure lookups, async fills).

import 'dart:async';

import 'package:flutter/foundation.dart';

/// Sends one stat probe. Production wires `SshSessionProxy.sftpStat`; tests
/// record the calls.
typedef PathStatSender =
    void Function({required String requestId, required String path});

/// The tri-state a consumer can read for a path (#990 visibility gate):
///   - [pending]  — no FRESH answer (never probed, awaiting one, or expired).
///   - [verified] — a fresh stat confirmed the path exists on this host.
///   - [missing]  — a fresh stat failed (no such path / denied / errored /
///                  timed out — all fail-open equivalents).
/// The SHADE predicate only cares about [verified]; the single-segment
/// VISIBILITY gate suppresses both [pending] and [missing].
enum PathVerification { pending, verified, missing }

/// One cached stat answer: [exists] until [expiresAt].
class _CacheEntry {
  _CacheEntry({required this.exists, required this.expiresAt});

  final bool exists;
  final DateTime expiresAt;
}

/// One outstanding probe, so a result/timeout can resolve back to its path.
class _InFlight {
  _InFlight({required this.path, required this.timeout});

  final String path;
  final Timer timeout;
}

/// Per-session verification cache for detected path anchors (#990).
///
/// Feed it the currently-anchored paths via [notePaths] (cheap, debounced);
/// read [isVerified] from paint code (synchronous map lookup); listen for
/// upgrades (it notifies when any path's verified state changes).
class SessionPathVerifier extends ChangeNotifier {
  SessionPathVerifier({
    required this.sessionId,
    required this.sendStat,
    this.ttl = const Duration(seconds: 30),
    this.debounce = const Duration(milliseconds: 250),
    this.requestTimeout = const Duration(seconds: 6),
    this.maxInFlight = 4,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// The session this verifier is scoped to. Also namespaces request ids so a
  /// cross-routed result can never land in another session's cache.
  final String sessionId;

  /// How long a stat answer (either way) stays fresh. Short by design: a path
  /// can be created/deleted at any time; the anchor set re-notes on every
  /// decoration change so a hot path re-probes soon after expiry.
  final Duration ttl;

  /// The batching window for [notePaths] bursts (anchors arrive per detection
  /// rescan — several notifies per output burst).
  final Duration debounce;

  /// Fail-open deadline for one probe: an unanswered stat is treated as
  /// "not verified" and its slot freed.
  final Duration requestTimeout;

  /// Cap on outstanding probes; the rest queue until a slot frees.
  final int maxInFlight;

  /// Fires one stat probe (production: `SshSessionProxy.sftpStat`).
  final PathStatSender sendStat;

  final DateTime Function() _now;

  final Map<String, _CacheEntry> _cache = {};
  final Set<String> _pending = {};
  final Map<String, _InFlight> _inFlight = {};
  Timer? _debounceTimer;
  int _seq = 0;
  bool _disposed = false;

  /// Whether [path] is currently verified (exists on this session's host, per
  /// a FRESH stat answer). Pure lookup — never triggers I/O, safe from paint.
  bool isVerified(String path) => status(path) == PathVerification.verified;

  /// The full tri-state for [path] (#990 visibility gate). Pure lookup.
  PathVerification status(String path) {
    final entry = _cache[path];
    if (entry == null) return PathVerification.pending;
    if (!entry.expiresAt.isAfter(_now())) return PathVerification.pending;
    return entry.exists ? PathVerification.verified : PathVerification.missing;
  }

  /// Note the currently-anchored detected paths. Cheap and idempotent: paths
  /// with a fresh cached answer or an outstanding probe are skipped; the rest
  /// are probed after the debounce window, at most [maxInFlight] at a time.
  void notePaths(Iterable<String> paths) {
    if (_disposed) return;
    var added = false;
    for (final path in paths) {
      if (path.isEmpty) continue;
      added = _pending.add(path) || added;
    }
    if (!added && _debounceTimer != null) return;
    _debounceTimer ??= Timer(debounce, () {
      _debounceTimer = null;
      _drain();
    });
  }

  /// Deliver one probe answer. Wire this to the session proxy's
  /// [SftpStatResultEvent]s. Unknown/stale request ids are ignored.
  void onStatResult({required String requestId, required bool exists}) {
    if (_disposed) return;
    final inFlight = _inFlight.remove(requestId);
    if (inFlight == null) return;
    inFlight.timeout.cancel();
    _store(inFlight.path, exists);
    _drain();
  }

  void _store(String path, bool exists) {
    // Notify on ANY status change (pending→missing included): the #990
    // visibility gate suppresses pending single-segment matches, so a missing
    // verdict is as paint-relevant as an upgrade.
    final was = status(path);
    _cache[path] = _CacheEntry(exists: exists, expiresAt: _now().add(ttl));
    if (status(path) != was) notifyListeners();
  }

  void _drain() {
    if (_disposed) return;
    final now = _now();
    // Evict expired cache entries so the map stays bounded by live anchors.
    _cache.removeWhere((_, e) => !e.expiresAt.isAfter(now));
    final drained = <String>[];
    for (final path in _pending) {
      if (_inFlight.length >= maxInFlight) break;
      if (_cache.containsKey(path)) {
        drained.add(path);
        continue;
      }
      if (_inFlight.values.any((f) => f.path == path)) {
        drained.add(path);
        continue;
      }
      final requestId = 'pathstat-$sessionId-${_seq++}';
      _inFlight[requestId] = _InFlight(
        path: path,
        // Fail-open: an unanswered probe resolves to "not verified" and frees
        // its slot so the queue keeps moving. The negative is CACHED (normal
        // TTL) so a dead SFTP channel isn't hammered every rescan.
        timeout: Timer(requestTimeout, () {
          final timedOut = _inFlight.remove(requestId);
          if (timedOut == null) return;
          _store(timedOut.path, false);
          _drain();
        }),
      );
      drained.add(path);
      sendStat(requestId: requestId, path: path);
    }
    _pending.removeAll(drained);
  }

  @override
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    for (final f in _inFlight.values) {
      f.timeout.cancel();
    }
    _inFlight.clear();
    _pending.clear();
    super.dispose();
  }
}
