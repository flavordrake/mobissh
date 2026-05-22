// Crash capture + auto-upload (#501).
//
// The native rewrite shipped crashing on launch for the user. We need a
// telemetry path that:
//   1. Captures errors at all four Flutter/Dart layers (Flutter framework,
//      top-level Dart, zoned, native Kotlin) without any user action.
//   2. Persists each crash to disk before anything async happens, so a crash
//      at app start doesn't lose its own report.
//   3. Auto-uploads on next successful launch — *and* on next successful SSH
//      connect, because if the bridge is unreachable at boot we still want a
//      second shot once the user proves they have network.
//   4. Exposes an in-app "share crash report" fallback for cases where
//      auto-upload can't reach the bridge at all (e.g. Tailscale is down).
//
// **Defensiveness contract.** Every public entry point on this class catches
// `Object` and logs to stderr/print(). The crash reporter must never throw —
// a crash reporter that crashes is worse than no crash reporter at all.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'crash_environment.dart';

/// Default endpoint for crash uploads. Pointed at the production bridge.
/// Overridable via [CrashReporter.configure] for tests/dev.
const String _defaultEndpoint =
    'https://mobissh.tail-scale.ts.net/api/native-crash';

/// JSON file extension we expect under the crashes dir.
const String _crashFileSuffix = '.json';

/// Internal singleton holding configuration + collaborators. Tests inject
/// their own values via [CrashReporter.configure] / [CrashReporter.reset].
class _ReporterState {
  CrashEnvironment env;
  http.Client httpClient;
  String endpoint;
  bool bootstrapped;
  bool uploadInFlight;

  _ReporterState({
    required this.env,
    required this.httpClient,
    required this.endpoint,
  })  : bootstrapped = false,
        uploadInFlight = false;
}

/// Top-level crash capture + auto-upload pipeline.
///
/// Usage in `main()`:
/// ```dart
/// void main() {
///   CrashReporter.runGuarded(() async {
///     WidgetsFlutterBinding.ensureInitialized();
///     await CrashReporter.bootstrap();
///     unawaited(CrashReporter.uploadPending());
///     runApp(...);
///   });
/// }
/// ```
class CrashReporter {
  CrashReporter._();

  static _ReporterState? _state;

  /// Schema version stamped into every crash JSON. Bump when the format
  /// changes so the bridge can detect mismatches.
  static const int schemaVersion = 1;

  /// Configure (or reconfigure) the reporter. The first call wins for the
  /// `env` parameter unless [reset] is called first. Useful for tests.
  static void configure({
    CrashEnvironment? env,
    http.Client? httpClient,
    String? endpoint,
  }) {
    final existing = _state;
    if (existing == null) {
      _state = _ReporterState(
        env: env ?? const DefaultCrashEnvironment(),
        httpClient: httpClient ?? http.Client(),
        endpoint: endpoint ?? _defaultEndpoint,
      );
    } else {
      if (env != null) existing.env = env;
      if (httpClient != null) existing.httpClient = httpClient;
      if (endpoint != null) existing.endpoint = endpoint;
    }
  }

  /// Tear down state — tests only. The next call to a public method will
  /// re-create the default state.
  @visibleForTesting
  static void reset() {
    _state = null;
  }

  static _ReporterState _ensureState() {
    return _state ??= _ReporterState(
      env: const DefaultCrashEnvironment(),
      httpClient: http.Client(),
      endpoint: _defaultEndpoint,
    );
  }

  /// Install Flutter + Dart error handlers. Safe to call multiple times.
  static Future<void> bootstrap() async {
    final state = _ensureState();
    if (state.bootstrapped) return;
    state.bootstrapped = true;

    try {
      FlutterError.onError = (FlutterErrorDetails details) {
        // Keep Flutter's default logging too — devs reading the console still
        // want the framework error to scroll past.
        FlutterError.presentError(details);
        // Fire-and-forget; do NOT await inside an error handler.
        unawaited(_recordError(
          error: details.exception,
          stack: details.stack,
          context: details.context?.toDescription() ?? 'flutter',
          kind: 'flutter',
        ));
      };

      PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
        unawaited(_recordError(
          error: error,
          stack: stack,
          context: 'platform-dispatcher',
          kind: 'dart',
        ));
        // Return true: we've handled it. Don't surface to the engine, which
        // would terminate the isolate.
        return true;
      };
    } catch (err, st) {
      _safeLog('bootstrap failed: $err\n$st');
    }
  }

  /// Wrap a callback in `runZonedGuarded` so any uncaught Dart errors land in
  /// the reporter. The callback is invoked synchronously; async work inside
  /// it is still covered.
  static R? runGuarded<R>(R Function() body) {
    R? result;
    runZonedGuarded<void>(() {
      result = body();
    }, (Object error, StackTrace stack) {
      unawaited(_recordError(
        error: error,
        stack: stack,
        context: 'zone-guard',
        kind: 'dart',
      ));
    });
    return result;
  }

  /// Persist an error to disk. Public for explicit `try/catch` use sites
  /// (e.g. SSH connect path that wants to log a non-fatal anomaly).
  static Future<void> recordError({
    required Object error,
    StackTrace? stack,
    String? context,
    String kind = 'dart',
  }) {
    return _recordError(
      error: error,
      stack: stack,
      context: context,
      kind: kind,
    );
  }

  static Future<void> _recordError({
    required Object error,
    StackTrace? stack,
    String? context,
    required String kind,
  }) async {
    final state = _ensureState();
    try {
      final docs = await state.env.crashesDir();
      if (docs == null) {
        _safeLog('crashesDir unavailable; cannot persist error: $error');
        return;
      }
      if (!await docs.exists()) {
        await docs.create(recursive: true);
      }
      final stamp = _compactStamp(DateTime.now().toUtc());
      final file = File(
        '${docs.path}${Platform.pathSeparator}$stamp-$kind$_crashFileSuffix',
      );
      final body = await _serialize(
        env: state.env,
        kind: kind,
        error: error,
        stack: stack,
        context: context,
      );
      // flush:false — fsync isn't necessary; a crash file we lose on power
      // cut is the same as if it had never been written. Keeping it false
      // also avoids a class of flaky hangs under flutter_test.
      await file.writeAsString(body);
      _safeLog('crash recorded: ${file.path}');
    } catch (err, st) {
      _safeLog('failed to persist error: $err\n$st');
    }
  }

  /// Serialize a single error into the on-disk JSON shape. Exposed for tests
  /// to assert schema stability.
  @visibleForTesting
  static Future<String> serializeForTest({
    required CrashEnvironment env,
    required String kind,
    required Object error,
    StackTrace? stack,
    String? context,
  }) {
    return _serialize(
      env: env,
      kind: kind,
      error: error,
      stack: stack,
      context: context,
    );
  }

  static Future<String> _serialize({
    required CrashEnvironment env,
    required String kind,
    required Object error,
    StackTrace? stack,
    String? context,
  }) async {
    final info = await env.snapshot();
    final payload = <String, Object?>{
      'schema': schemaVersion,
      'kind': kind,
      'ts': DateTime.now().toUtc().toIso8601String(),
      'appVersion': info.appVersion,
      'buildSha': info.buildSha,
      'platformVersion': info.platformVersion,
      'deviceModel': info.deviceModel,
      'error': error.toString(),
      'errorType': error.runtimeType.toString(),
      'stack': stack?.toString() ?? '',
      'context': context ?? '',
    };
    return jsonEncode(payload);
  }

  /// Sweep the crashes directory and upload every file. On success, delete
  /// the file. On failure, leave it for the next attempt. Idempotent and
  /// re-entrancy-guarded — a second call while the first is in-flight is a
  /// no-op so the connect-success hook can't pile up duplicate uploads.
  static Future<UploadSummary> uploadPending() async {
    final state = _ensureState();
    if (state.uploadInFlight) {
      return const UploadSummary(skippedInFlight: true);
    }
    state.uploadInFlight = true;
    int uploaded = 0;
    int failed = 0;
    int scanned = 0;
    try {
      final docs = await state.env.crashesDir();
      if (docs == null) return const UploadSummary();
      if (!await docs.exists()) return const UploadSummary();
      final entries = await docs.list().toList();
      for (final entry in entries) {
        if (entry is! File) continue;
        if (!entry.path.endsWith(_crashFileSuffix)) continue;
        scanned++;
        try {
          final body = await entry.readAsString();
          final resp = await state.httpClient
              .post(
                Uri.parse(state.endpoint),
                headers: {'Content-Type': 'application/json'},
                body: body,
              )
              .timeout(const Duration(seconds: 15));
          if (resp.statusCode >= 200 && resp.statusCode < 300) {
            try {
              await entry.delete();
            } catch (delErr) {
              _safeLog('uploaded but failed to delete ${entry.path}: $delErr');
            }
            uploaded++;
          } else {
            _safeLog('upload non-2xx (${resp.statusCode}) for ${entry.path}');
            failed++;
          }
        } catch (uploadErr) {
          _safeLog('upload failed for ${entry.path}: $uploadErr');
          failed++;
        }
      }
    } catch (err, st) {
      _safeLog('uploadPending error: $err\n$st');
    } finally {
      state.uploadInFlight = false;
    }
    return UploadSummary(
      uploaded: uploaded,
      failed: failed,
      scanned: scanned,
    );
  }

  /// Returns the most recently-modified crash file under the crashes dir, or
  /// null if no crashes are pending upload. Used by the "Share last crash"
  /// UI affordance.
  static Future<File?> latestCrashFile() async {
    final state = _ensureState();
    try {
      final docs = await state.env.crashesDir();
      if (docs == null) return null;
      if (!await docs.exists()) return null;
      // Use `.list().toList()` rather than `await for` — the latter doesn't
      // always terminate cleanly under flutter_test's fake async runner.
      final entries = await docs.list().toList();
      final files = entries
          .whereType<File>()
          .where((f) => f.path.endsWith(_crashFileSuffix))
          .toList();
      if (files.isEmpty) return null;
      files.sort((a, b) => b.path.compareTo(a.path));
      return files.first;
    } catch (err, st) {
      _safeLog('latestCrashFile failed: $err\n$st');
      return null;
    }
  }

  /// Lightweight count of pending crash files. Cheap enough to call from
  /// `setState`. Returns 0 on any failure.
  static Future<int> pendingCrashCount() async {
    final state = _ensureState();
    try {
      final docs = await state.env.crashesDir();
      if (docs == null) return 0;
      if (!await docs.exists()) return 0;
      final entries = await docs.list().toList();
      return entries
          .whereType<File>()
          .where((f) => f.path.endsWith(_crashFileSuffix))
          .length;
    } catch (_) {
      return 0;
    }
  }

  /// Short human-readable summary of pending crashes — used in the
  /// diagnostics section in [ConnectForm].
  static Future<String> pendingCrashSummary() async {
    final count = await pendingCrashCount();
    if (count == 0) return 'No crashes pending.';
    if (count == 1) return '1 crash pending upload.';
    return '$count crashes pending upload.';
  }

  static String _compactStamp(DateTime utc) {
    final y = utc.year.toString().padLeft(4, '0');
    final mo = utc.month.toString().padLeft(2, '0');
    final d = utc.day.toString().padLeft(2, '0');
    final h = utc.hour.toString().padLeft(2, '0');
    final mi = utc.minute.toString().padLeft(2, '0');
    final s = utc.second.toString().padLeft(2, '0');
    final ms = utc.millisecond.toString().padLeft(3, '0');
    return '$y$mo${d}T$h$mi$s-$ms';
  }

  static void _safeLog(String msg) {
    try {
      // ignore: avoid_print
      print('[CrashReporter] $msg');
    } catch (_) {
      // Stdout could fail under exotic conditions; ignore.
    }
  }
}

/// Return value of [CrashReporter.uploadPending]. Used by the UI snackbar.
class UploadSummary {
  final int uploaded;
  final int failed;
  final int scanned;
  final bool skippedInFlight;

  const UploadSummary({
    this.uploaded = 0,
    this.failed = 0,
    this.scanned = 0,
    this.skippedInFlight = false,
  });

  bool get isEmpty => uploaded == 0 && failed == 0 && scanned == 0;

  @override
  String toString() {
    if (skippedInFlight) return 'Upload already in progress';
    if (isEmpty) return 'No crashes to upload';
    return 'Uploaded $uploaded of $scanned (failed: $failed)';
  }
}
