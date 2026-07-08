// #990 — SessionPathVerifier: the per-session "does this detected path exist
// on the CONNECTED host" cache that upgrades a path anchor from the plain
// "detected" shade to the bolder VERIFIED shade.
//
// Pure unit level: the verifier talks to a fake `sendStat` seam (production
// wires `SshSessionProxy.sftpStat`) and results are injected via
// `onStatResult` — no gateway, no widget. Timing (debounce, TTL, request
// timeout) runs under FakeAsync.
//
// Covered per the issue's test plan:
//   - debounce: a burst of noted paths → ONE batched drain after the window
//   - cache TTL: fresh results are not re-requested; expired ones are
//   - fail-open: a stat error/timeout leaves the path in the "detected" state
//   - per-session isolation: two verifiers never share state
//   - in-flight cap: at most maxInFlight outstanding stats; queue drains as
//     results free slots

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/path_verifier.dart';

void main() {
  const debounce = Duration(milliseconds: 250);
  const ttl = Duration(seconds: 30);
  const requestTimeout = Duration(seconds: 6);

  /// Build a verifier wired to a recording sendStat seam.
  ({SessionPathVerifier verifier, List<({String requestId, String path})> sent})
  build(
    FakeAsync async, {
    String sessionId = 'host:22:user:1',
    int maxInFlight = 4,
  }) {
    final sent = <({String requestId, String path})>[];
    final verifier = SessionPathVerifier(
      sessionId: sessionId,
      sendStat: ({required String requestId, required String path}) =>
          sent.add((requestId: requestId, path: path)),
      ttl: ttl,
      debounce: debounce,
      requestTimeout: requestTimeout,
      maxInFlight: maxInFlight,
      // FakeAsync fakes Timers but NOT DateTime.now — drive the TTL clock off
      // the same virtual timeline via the injectable `now` seam.
      now: () => async.getClock(DateTime(2026)).now(),
    );
    return (verifier: verifier, sent: sent);
  }

  test('a burst of noted paths is DEBOUNCED into one batched drain', () {
    fakeAsync((async) {
      final t = build(async);
      t.verifier.notePaths(['/etc/hosts']);
      t.verifier.notePaths(['/etc/hosts', '/tmp/a']);
      t.verifier.notePaths(['/tmp/b']);
      // Inside the debounce window nothing is sent yet.
      expect(t.sent, isEmpty);
      async.elapse(debounce + const Duration(milliseconds: 1));
      // One drain, each unique path exactly once.
      expect(t.sent.map((s) => s.path).toList()..sort(), [
        '/etc/hosts',
        '/tmp/a',
        '/tmp/b',
      ]);
      t.verifier.dispose();
    });
  });

  test('a positive result upgrades the path to VERIFIED and notifies', () {
    fakeAsync((async) {
      final t = build(async);
      var notified = 0;
      t.verifier.addListener(() => notified++);
      t.verifier.notePaths(['/etc/hosts']);
      async.elapse(debounce * 2);
      expect(t.verifier.isVerified('/etc/hosts'), isFalse);
      t.verifier.onStatResult(requestId: t.sent.single.requestId, exists: true);
      expect(t.verifier.isVerified('/etc/hosts'), isTrue);
      expect(notified, 1);
      t.verifier.dispose();
    });
  });

  test('fail-open: a NEGATIVE/errored stat leaves the path detected', () {
    fakeAsync((async) {
      final t = build(async);
      t.verifier.notePaths(['/no/such/path']);
      async.elapse(debounce * 2);
      t.verifier.onStatResult(requestId: t.sent.single.requestId, exists: false);
      expect(t.verifier.isVerified('/no/such/path'), isFalse);
      t.verifier.dispose();
    });
  });

  test('a fresh cached result is NOT re-requested; an expired one is', () {
    fakeAsync((async) {
      final t = build(async);
      t.verifier.notePaths(['/etc/hosts']);
      async.elapse(debounce * 2);
      t.verifier.onStatResult(requestId: t.sent.single.requestId, exists: true);

      // Re-noting inside the TTL sends nothing new.
      t.verifier.notePaths(['/etc/hosts']);
      async.elapse(debounce * 2);
      expect(t.sent, hasLength(1));
      expect(t.verifier.isVerified('/etc/hosts'), isTrue);

      // After TTL expiry the verified state lapses and a re-note re-stats.
      async.elapse(ttl + const Duration(seconds: 1));
      expect(
        t.verifier.isVerified('/etc/hosts'),
        isFalse,
        reason: 'an expired entry must not keep claiming verified',
      );
      t.verifier.notePaths(['/etc/hosts']);
      async.elapse(debounce * 2);
      expect(t.sent, hasLength(2));
      t.verifier.dispose();
    });
  });

  test('fail-open on TIMEOUT: an unanswered stat frees its slot and the path '
      'stays detected', () {
    fakeAsync((async) {
      final t = build(async, maxInFlight: 1);
      t.verifier.notePaths(['/a', '/b']);
      async.elapse(debounce * 2);
      // Cap 1: only the first is in flight.
      expect(t.sent, hasLength(1));
      // Never answer it — after the request timeout the slot frees and the
      // queued path goes out; the timed-out path reads as NOT verified.
      async.elapse(requestTimeout + const Duration(seconds: 1));
      expect(t.sent, hasLength(2));
      expect(t.verifier.isVerified(t.sent.first.path), isFalse);
      t.verifier.dispose();
    });
  });

  test('in-flight cap: at most maxInFlight outstanding; results drain the '
      'queue', () {
    fakeAsync((async) {
      final t = build(async, maxInFlight: 2);
      t.verifier.notePaths(['/a', '/b', '/c', '/d']);
      async.elapse(debounce * 2);
      expect(t.sent, hasLength(2), reason: 'cap must bound outstanding stats');
      t.verifier.onStatResult(requestId: t.sent[0].requestId, exists: true);
      expect(t.sent, hasLength(3), reason: 'a result frees a slot → next sent');
      t.verifier.onStatResult(requestId: t.sent[1].requestId, exists: false);
      expect(t.sent, hasLength(4));
      t.verifier.dispose();
    });
  });

  test('per-session isolation: the same path verified on host A is NOT '
      'verified on host B', () {
    fakeAsync((async) {
      final a = build(async, sessionId: 'hostA:22:user:1');
      final b = build(async, sessionId: 'hostB:22:user:1');
      a.verifier.notePaths(['/etc/hosts']);
      b.verifier.notePaths(['/etc/hosts']);
      async.elapse(debounce * 2);
      a.verifier.onStatResult(requestId: a.sent.single.requestId, exists: true);
      b.verifier.onStatResult(requestId: b.sent.single.requestId, exists: false);
      expect(a.verifier.isVerified('/etc/hosts'), isTrue);
      expect(
        b.verifier.isVerified('/etc/hosts'),
        isFalse,
        reason: 'verification state must be scoped per (session, path)',
      );
      // Request ids are namespaced per session so a cross-routed result can
      // never be attributed to the wrong session's cache.
      expect(a.sent.single.requestId, isNot(b.sent.single.requestId));
      a.verifier.dispose();
      b.verifier.dispose();
    });
  });

  // #990 visibility gate (owner report on +121): single-segment root matches
  // (`/config`) are SUPPRESSED until verified, so consumers need the full
  // tri-state — pending (no fresh answer) / verified / missing — not just the
  // isVerified bool.
  group('status() tri-state', () {
    test('pending before any result, verified/missing after, pending again '
        'after TTL expiry', () {
      fakeAsync((async) {
        final t = build(async);
        expect(t.verifier.status('/etc'), PathVerification.pending);
        t.verifier.notePaths(['/etc', '/config']);
        async.elapse(debounce * 2);
        expect(t.verifier.status('/etc'), PathVerification.pending);
        t.verifier.onStatResult(requestId: t.sent[0].requestId, exists: true);
        t.verifier.onStatResult(requestId: t.sent[1].requestId, exists: false);
        expect(t.verifier.status('/etc'), PathVerification.verified);
        expect(t.verifier.status('/config'), PathVerification.missing);
        async.elapse(ttl + const Duration(seconds: 1));
        expect(t.verifier.status('/etc'), PathVerification.pending);
        expect(t.verifier.status('/config'), PathVerification.pending);
        t.verifier.dispose();
      });
    });

    test('a MISSING result notifies listeners (suppression consumers must '
        'repaint on it, not only on upgrades)', () {
      fakeAsync((async) {
        final t = build(async);
        var notified = 0;
        t.verifier.addListener(() => notified++);
        t.verifier.notePaths(['/config']);
        async.elapse(debounce * 2);
        t.verifier.onStatResult(
          requestId: t.sent.single.requestId,
          exists: false,
        );
        expect(
          notified,
          greaterThanOrEqualTo(1),
          reason: 'pending → missing is a status change a visibility gate '
              'depends on',
        );
        t.verifier.dispose();
      });
    });
  });

  test('a stale/unknown requestId is ignored (no crash, no state change)', () {
    fakeAsync((async) {
      final t = build(async);
      t.verifier.notePaths(['/etc/hosts']);
      async.elapse(debounce * 2);
      t.verifier.onStatResult(requestId: 'pathstat-bogus-99', exists: true);
      expect(t.verifier.isVerified('/etc/hosts'), isFalse);
      t.verifier.dispose();
    });
  });
}
