// Bug-report outbox (#1259): reports that could not be sent are kept on disk
// and sent automatically later.
//
// Mirrors the crash-report pending queue (crash_reporter.dart, #1243): one
// file per report in an app-private directory, retried on app launch, on a
// successful SSH connect and on app resume; a 401/403 marks the file
// `.rejected` (kept, never retried). Every send goes THROUGH the outbox — the
// report is on disk before the network is touched — so a failure needs no
// second write and Retry re-sends the same entry.
//
// File states (suffix → meaning):
//   .json        pending: will be sent by the next flush
//   .sending     claimed by an upload in progress (rename = the lock)
//   .unconfirmed a `.sending` left by a process that died mid-upload. The
//                server has no idempotency key, so whether it arrived is
//                unknowable; it is kept but NEVER resent automatically, so a
//                report is never duplicated by a crash (at-most-once).
//   .rejected    the relay refused this build's key (401/403); kept, no retry
//   .corrupt     not valid JSON; kept for inspection, never sent
//   .tmp         an atomic write in progress (temp, then rename to .json)
//
// Privacy: reports carry screenshots and terminal traces. They live only in
// an app-private dir that is excluded from backup and device transfer
// (Android no_backup, #1271), are deleted after 30 days, and their contents
// are never logged — only file names and counts are. They are not encrypted
// at rest: app-private + never backed up is the boundary.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'diagnostics_config.dart' show feedbackEndpoint, feedbackKey;

/// Outcome of one POST of a report body.
enum FeedbackPostOutcome {
  /// 2xx — the relay has it.
  delivered,

  /// 401/403 — permanent for this build's key; never retried.
  rejected,

  /// Network error, timeout, or any other status — retried later.
  failed,
}

/// Posts one report body (the exact JSON text) to the relay.
typedef FeedbackPoster = Future<FeedbackPostOutcome> Function(String body);

/// Production poster: POST [body] verbatim to [endpoint] (`/api/bug-report`)
/// with the shared `X-MobiSSH-Key`. The 60s bound is longer than the crash
/// uploader's 15s because a report can carry ~50 screenshot frames; without a
/// bound a stalled socket would hold the sheet in "Sending…" indefinitely.
Future<FeedbackPostOutcome> postFeedbackBody(
  String body, {
  String endpoint = feedbackEndpoint,
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  try {
    final res = await c
        .post(
          Uri.parse(endpoint),
          headers: {
            'Content-Type': 'application/json',
            if (feedbackKey.isNotEmpty) 'X-MobiSSH-Key': feedbackKey,
          },
          body: body,
        )
        .timeout(const Duration(seconds: 60));
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return FeedbackPostOutcome.delivered;
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      return FeedbackPostOutcome.rejected;
    }
    return FeedbackPostOutcome.failed;
  } catch (err) {
    debugPrint('[feedback] post failed: ${err.runtimeType}');
    return FeedbackPostOutcome.failed;
  } finally {
    if (client == null) c.close();
  }
}

/// Result of [FeedbackOutbox.submit].
class OutboxSubmitResult {
  const OutboxSubmitResult({
    required this.id,
    required this.outcome,
    this.evicted = 0,
    this.expired = 0,
  });

  /// The outbox entry, or null when the report could not be written to disk
  /// (it was still POSTed once).
  final String? id;
  final FeedbackPostOutcome outcome;

  /// How many OLDER saved reports were dropped to stay within the caps.
  final int evicted;

  /// How many saved reports were dropped for being older than
  /// [FeedbackOutbox.maxAge] (#1271).
  final int expired;
}

/// Counts for the "N bug reports waiting to send" line.
class OutboxStatus {
  const OutboxStatus({
    this.pending = 0,
    this.rejected = 0,
    this.unconfirmed = 0,
    this.corrupt = 0,
  });

  final int pending;
  final int rejected;
  final int unconfirmed;
  final int corrupt;

  int get total => pending + rejected + unconfirmed + corrupt;
}

/// Result of [FeedbackOutbox.flush].
class OutboxFlushResult {
  const OutboxFlushResult({
    this.sent = 0,
    this.failed = 0,
    this.rejected = 0,
    this.expired = 0,
    this.skipped = false,
  });

  final int sent;
  final int failed;
  final int rejected;

  /// Saved reports deleted for being older than [FeedbackOutbox.maxAge].
  final int expired;

  /// True when the flush did nothing: backoff window, or one already running.
  final bool skipped;
}

const String _pending = '.json';
const String _sending = '.sending';
const String _unconfirmed = '.unconfirmed';
const String _rejected = '.rejected';
const String _corrupt = '.corrupt';
const String _tmp = '.tmp';

class FeedbackOutbox {
  FeedbackOutbox({
    required this.dir,
    required this.poster,
    this.maxReports = 10,
    this.maxBytes = 50 * 1024 * 1024,
    this.maxAge = const Duration(days: 30),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Production instance: [resolveDefaultDir], POSTed to the baked
  /// [feedbackEndpoint].
  static final FeedbackOutbox instance = FeedbackOutbox(
    dir: _defaultDir,
    poster: postFeedbackBody,
  );

  static const String _dirName = 'feedback-outbox';
  static const MethodChannel _pathsChannel = MethodChannel('mobissh/paths');
  static Future<Directory?>? _resolved;

  static Future<Directory?> _defaultDir() async {
    final d = await (_resolved ??= resolveDefaultDir());
    if (d == null) _resolved = null; // transient: try again next time
    return d;
  }

  /// #1271: where the production outbox lives.
  ///
  /// Android: `<getNoBackupFilesDir()>/feedback-outbox`. The documents dir
  /// (`app_flutter/`) is included in Auto Backup and device-to-device
  /// transfer, and reports carry screenshots and terminal traces. Reports an
  /// older build saved there are moved over (once). When the no-backup dir
  /// cannot be resolved there is NO outbox (a send is still tried once) —
  /// never a fallback to the backed-up dir.
  ///
  /// Other platforms: `<app documents>/feedback-outbox`, unchanged.
  @visibleForTesting
  static Future<Directory?> resolveDefaultDir({bool? android}) async {
    Directory? legacy;
    try {
      final docs = await getApplicationDocumentsDirectory();
      legacy = Directory('${docs.path}${Platform.pathSeparator}$_dirName');
    } catch (_) {}
    if (!(android ?? Platform.isAndroid)) return legacy;
    final String? base;
    try {
      base = await _pathsChannel.invokeMethod<String>('noBackupDir');
    } catch (err) {
      _log('no-backup dir unavailable: ${err.runtimeType}');
      return null;
    }
    if (base == null || base.isEmpty) return null;
    final target = Directory('$base${Platform.pathSeparator}$_dirName');
    if (legacy != null) await _migrate(legacy, target);
    return target;
  }

  /// Move every file from [from] into [to], then remove [from]. A file that
  /// cannot be moved stays where it was (and keeps [from]); nothing is lost.
  static Future<void> _migrate(Directory from, Directory to) async {
    try {
      if (!await from.exists()) return;
      await to.create(recursive: true);
      var moved = 0;
      for (final f in (await from.list().toList()).whereType<File>()) {
        final name = f.path.split(Platform.pathSeparator).last;
        final dest = '${to.path}${Platform.pathSeparator}$name';
        try {
          await f.rename(dest);
        } on FileSystemException {
          await f.copy(dest); // rename fails across filesystems
          await f.delete();
        }
        moved++;
      }
      await from.delete();
      _log('moved $moved report(s) out of the backed-up dir');
    } catch (err) {
      _log('outbox migration incomplete: ${err.runtimeType}');
    }
  }

  final Future<Directory?> Function() dir;
  final FeedbackPoster poster;
  final int maxReports;
  final int maxBytes;

  /// Saved reports (any state) older than this are deleted (#1271).
  final Duration maxAge;
  final DateTime Function() _now;

  static const Duration _baseBackoff = Duration(seconds: 30);
  static const Duration _maxBackoff = Duration(minutes: 30);

  int _seq = 0;
  int _autoFailures = 0;
  DateTime? _nextAutoAt;
  bool _flushing = false;

  /// Ids this process is uploading right now — a `.sending` NOT in this set
  /// was left by a dead process.
  final Set<String> _inFlight = <String>{};

  /// #1271: ids the user discarded (Discard / Share instead). An upload of one
  /// that is in flight deletes it when it settles instead of re-queueing it.
  final Set<String> _discarded = <String>{};

  /// Write [body] to the outbox (atomically; replacing entry [id] when given)
  /// and send it once. Delivered → the file is deleted. Rejected → `.rejected`.
  /// Failed → it stays pending for the next flush.
  Future<OutboxSubmitResult> submit(String body, {String? id}) async {
    if (id != null) _discarded.remove(id); // an explicit re-send wins
    Directory? d;
    try {
      d = await _ensureDir();
    } catch (_) {
      d = null;
    }
    if (d == null) {
      // No storage: still try the network once rather than losing the report.
      return OutboxSubmitResult(id: null, outcome: await _post(body));
    }
    final entryId = id ?? _mintId();
    var evicted = 0;
    var expired = 0;
    try {
      await _writeAtomic(d, entryId, body);
      expired = await _expire(d, keep: entryId);
      evicted = await _enforceCaps(d, keep: entryId);
    } catch (err) {
      _log('write failed for $entryId: ${err.runtimeType}');
      return OutboxSubmitResult(id: null, outcome: await _post(body));
    }
    final outcome = await _sendEntry(d, entryId);
    return OutboxSubmitResult(
      id: entryId,
      outcome: outcome ?? FeedbackPostOutcome.failed,
      evicted: evicted,
      expired: expired,
    );
  }

  /// Send every pending report. [auto] (launch / connect / resume) honours a
  /// bounded exponential backoff after failures; a user's "Send now" passes
  /// false and always runs. Never runs two at once.
  Future<OutboxFlushResult> flush({bool auto = true}) async {
    final now = _now();
    if (_flushing) return const OutboxFlushResult(skipped: true);
    if (auto && _nextAutoAt != null && now.isBefore(_nextAutoAt!)) {
      return const OutboxFlushResult(skipped: true);
    }
    _flushing = true;
    var sent = 0;
    var failed = 0;
    var rejected = 0;
    var expired = 0;
    try {
      final d = await dir();
      if (d == null || !await d.exists()) return const OutboxFlushResult();
      await _quarantineOrphans(d);
      expired = await _expire(d);
      for (final entryId in await _idsWith(d, _pending)) {
        final outcome = await _sendEntry(d, entryId);
        switch (outcome) {
          case FeedbackPostOutcome.delivered:
            sent++;
          case FeedbackPostOutcome.rejected:
            rejected++;
          case FeedbackPostOutcome.failed:
            failed++;
          case null:
            break; // claimed elsewhere or corrupt
        }
      }
    } catch (err) {
      _log('flush error: ${err.runtimeType}');
    } finally {
      _flushing = false;
    }
    if (failed > 0) {
      _autoFailures++;
      final ms = math.min(
        _baseBackoff.inMilliseconds * (1 << math.min(_autoFailures - 1, 10)),
        _maxBackoff.inMilliseconds,
      );
      _nextAutoAt = _now().add(Duration(milliseconds: ms));
    } else {
      _autoFailures = 0;
      _nextAutoAt = null;
    }
    return OutboxFlushResult(
      sent: sent,
      failed: failed,
      rejected: rejected,
      expired: expired,
    );
  }

  /// Remove one entry in whatever state it is in. An upload of it in flight
  /// deletes it when it settles (#1271) — it is never re-queued.
  Future<void> discard(String id) async {
    _discarded.add(id);
    final d = await dir();
    if (d == null) return;
    for (final suffix in const [
      _pending,
      _rejected,
      _unconfirmed,
      _corrupt,
      _tmp,
      _sending,
    ]) {
      // The in-flight upload owns its .sending and deletes it on settling.
      if (suffix == _sending && _inFlight.contains(id)) continue;
      final f = File(_path(d, id, suffix));
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  /// Remove every saved report (the "Discard" action).
  Future<void> discardAll() async {
    _discarded.addAll(_inFlight);
    final d = await dir();
    if (d == null || !await d.exists()) return;
    for (final f in await _files(d)) {
      final id = _idOf(f.path);
      if (_inFlight.contains(id)) {
        _discarded.add(id);
        continue;
      }
      try {
        await f.delete();
      } catch (_) {}
    }
  }

  Future<OutboxStatus> status() async {
    try {
      final d = await dir();
      if (d == null || !await d.exists()) return const OutboxStatus();
      var pending = 0, rejected = 0, unconfirmed = 0, corrupt = 0;
      for (final f in await _files(d)) {
        final p = f.path;
        if (p.endsWith(_pending) || p.endsWith(_sending)) pending++;
        if (p.endsWith(_rejected)) rejected++;
        if (p.endsWith(_unconfirmed)) unconfirmed++;
        if (p.endsWith(_corrupt)) corrupt++;
      }
      return OutboxStatus(
        pending: pending,
        rejected: rejected,
        unconfirmed: unconfirmed,
        corrupt: corrupt,
      );
    } catch (_) {
      return const OutboxStatus();
    }
  }

  // Claim (rename .json → .sending), validate, POST, settle.
  Future<FeedbackPostOutcome?> _sendEntry(Directory d, String id) async {
    final pendingFile = File(_path(d, id, _pending));
    final sendingPath = _path(d, id, _sending);
    final File claimed;
    try {
      claimed = await pendingFile.rename(sendingPath);
    } catch (_) {
      return null; // someone else claimed it, or it is gone
    }
    _inFlight.add(id);
    try {
      final body = await claimed.readAsString();
      try {
        jsonDecode(body);
      } on FormatException {
        _log('corrupt report $id kept, not sent');
        await claimed.rename(_path(d, id, _corrupt));
        return null;
      }
      final outcome = await _post(body);
      if (_discarded.contains(id)) {
        // Discarded mid-upload (#1271): whatever the outcome, keep nothing.
        await claimed.delete();
        return outcome;
      }
      switch (outcome) {
        case FeedbackPostOutcome.delivered:
          await claimed.delete();
        case FeedbackPostOutcome.rejected:
          _log('report $id rejected by the relay; not retrying');
          await claimed.rename(_path(d, id, _rejected));
        case FeedbackPostOutcome.failed:
          await claimed.rename(pendingFile.path);
      }
      return outcome;
    } catch (err) {
      _log('send error for $id: ${err.runtimeType}');
      try {
        if (await claimed.exists()) {
          if (_discarded.contains(id)) {
            await claimed.delete();
          } else {
            await claimed.rename(pendingFile.path);
          }
        }
      } catch (_) {}
      return FeedbackPostOutcome.failed;
    } finally {
      _inFlight.remove(id);
    }
  }

  Future<FeedbackPostOutcome> _post(String body) async {
    try {
      return await poster(body);
    } catch (_) {
      return FeedbackPostOutcome.failed;
    }
  }

  /// A `.sending` this process does not own was left by a crash mid-upload.
  Future<void> _quarantineOrphans(Directory d) async {
    for (final id in await _idsWith(d, _sending)) {
      if (_inFlight.contains(id)) continue;
      try {
        await File(_path(d, id, _sending)).rename(_path(d, id, _unconfirmed));
        _log('report $id was interrupted mid-upload; kept, not resent');
      } catch (_) {}
    }
  }

  /// Delete entries (any state, never [keep] or one in flight) last written
  /// more than [maxAge] ago. Returns how many were dropped.
  Future<int> _expire(Directory d, {String? keep}) async {
    final cutoff = _now().subtract(maxAge);
    var expired = 0;
    for (final f in await _files(d)) {
      final id = _idOf(f.path);
      if (id == keep || _inFlight.contains(id)) continue;
      try {
        if ((await f.lastModified()).isBefore(cutoff)) {
          await f.delete();
          expired++;
        }
      } catch (_) {}
    }
    if (expired > 0) {
      _log('dropped $expired report(s) older than ${maxAge.inDays} days');
    }
    return expired;
  }

  /// Drop the OLDEST entries (any state, never [keep] or one in flight) until
  /// within [maxReports] and [maxBytes]. Returns how many were dropped.
  Future<int> _enforceCaps(Directory d, {required String keep}) async {
    final files = (await _files(d))
        .where((f) => !f.path.endsWith(_tmp))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    var count = files.length;
    var bytes = 0;
    for (final f in files) {
      bytes += await f.length();
    }
    var evicted = 0;
    for (final f in files) {
      if (count <= maxReports && bytes <= maxBytes) break;
      final id = _idOf(f.path);
      if (id == keep || _inFlight.contains(id)) continue;
      final len = await f.length();
      try {
        await f.delete();
        count--;
        bytes -= len;
        evicted++;
      } catch (_) {}
    }
    if (evicted > 0) _log('outbox full: dropped $evicted oldest report(s)');
    return evicted;
  }

  Future<void> _writeAtomic(Directory d, String id, String body) async {
    final tmp = File(_path(d, id, _tmp));
    await tmp.writeAsString(body, flush: true);
    await tmp.rename(_path(d, id, _pending));
  }

  Future<Directory?> _ensureDir() async {
    final d = await dir();
    if (d == null) return null;
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<List<File>> _files(Directory d) async =>
      (await d.list().toList()).whereType<File>().toList();

  Future<List<String>> _idsWith(Directory d, String suffix) async {
    final ids = [
      for (final f in await _files(d))
        if (f.path.endsWith(suffix)) _idOf(f.path),
    ]..sort();
    return ids;
  }

  /// Sortable by age: zero-padded microseconds + a per-process sequence.
  String _mintId() {
    final us = _now().microsecondsSinceEpoch.toString().padLeft(17, '0');
    final seq = (_seq++).toString().padLeft(4, '0');
    return 'report-$us-$seq';
  }

  static String _path(Directory d, String id, String suffix) =>
      '${d.path}${Platform.pathSeparator}$id$suffix';

  static String _idOf(String path) {
    final name = path.split(Platform.pathSeparator).last;
    final dot = name.indexOf('.');
    return dot < 0 ? name : name.substring(0, dot);
  }

  static void _log(String msg) => debugPrint('[feedback-outbox] $msg');
}
