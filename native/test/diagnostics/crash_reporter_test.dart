// Unit tests for CrashReporter.
//
// These tests exercise the on-disk persistence + upload contract using a
// `FakeCrashEnvironment` that points at a tempfile dir, and a `MockClient`
// from `package:http/testing` for the upload seam. No platform channels.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:mobissh/diagnostics/crash_environment.dart';
import 'package:mobissh/diagnostics/crash_reporter.dart';

void main() {
  late Directory tempRoot;
  late FakeCrashEnvironment env;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('mobissh_crash_test_');
    final crashDir = Directory('${tempRoot.path}/crashes');
    await crashDir.create(recursive: true);
    env = FakeCrashEnvironment(dir: crashDir);
    CrashReporter.reset();
  });

  tearDown(() async {
    CrashReporter.reset();
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {
      // Best-effort cleanup; don't fail tests on OS lock contention.
    }
  });

  group('recordError', () {
    test('persists a JSON file with the expected schema', () async {
      CrashReporter.configure(
        env: env,
        httpClient: MockClient((req) async => http.Response('ok', 200)),
        endpoint: 'http://fake/endpoint',
      );

      await CrashReporter.recordError(
        error: StateError('boom'),
        stack: StackTrace.fromString('stack-line-1\nstack-line-2'),
        context: 'unit-test',
      );

      final files = await env.dir.list().toList();
      expect(files, hasLength(1), reason: 'one crash file should be written');
      final body = await (files.single as File).readAsString();
      final parsed = jsonDecode(body) as Map<String, dynamic>;
      expect(parsed['schema'], CrashReporter.schemaVersion);
      expect(parsed['kind'], 'dart');
      expect(parsed['error'], contains('boom'));
      expect(parsed['stack'], contains('stack-line-1'));
      expect(parsed['context'], 'unit-test');
      expect(parsed['appVersion'], 'test+1');
      expect(parsed['deviceModel'], 'TestVendor TestModel');
    });

    test('multiple crashes accumulate as separate files', () async {
      CrashReporter.configure(env: env);

      await CrashReporter.recordError(error: 'first');
      // Ensure different timestamps even on fast clocks.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await CrashReporter.recordError(error: 'second');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await CrashReporter.recordError(error: 'third');

      final files = await env.dir.list().toList();
      expect(files, hasLength(3));
    });

    test('error inside a missing dir is recovered by creating the dir',
        () async {
      // Point env at a dir that doesn't yet exist.
      final freshDir = Directory('${tempRoot.path}/not-yet-created');
      final freshEnv = FakeCrashEnvironment(dir: freshDir);
      CrashReporter.configure(env: freshEnv);

      await CrashReporter.recordError(error: 'recover');

      expect(await freshDir.exists(), isTrue);
      final files = await freshDir.list().toList();
      expect(files, hasLength(1));
    });
  });

  group('uploadPending', () {
    test('successful upload deletes the file', () async {
      final calls = <String>[];
      CrashReporter.configure(
        env: env,
        httpClient: MockClient((req) async {
          calls.add(req.body);
          return http.Response('{"ok":true}', 200);
        }),
        endpoint: 'http://fake/endpoint',
      );

      await CrashReporter.recordError(error: 'upload-me');
      final summary = await CrashReporter.uploadPending();

      expect(summary.uploaded, 1);
      expect(summary.failed, 0);
      expect(summary.scanned, 1);
      expect(calls, hasLength(1));
      final remaining = await env.dir.list().toList();
      expect(remaining, isEmpty,
          reason: 'uploaded file should be deleted on 2xx');
    });

    test('failed upload leaves the file in place', () async {
      CrashReporter.configure(
        env: env,
        httpClient: MockClient((req) async {
          return http.Response('server error', 500);
        }),
        endpoint: 'http://fake/endpoint',
      );

      await CrashReporter.recordError(error: 'leave-me');
      final summary = await CrashReporter.uploadPending();

      expect(summary.uploaded, 0);
      expect(summary.failed, 1);
      expect(summary.scanned, 1);
      final remaining = await env.dir.list().toList();
      expect(remaining, hasLength(1),
          reason: 'failed upload should retain file for next attempt');
    });

    test('exception from the HTTP client leaves the file in place',
        () async {
      CrashReporter.configure(
        env: env,
        httpClient: MockClient((req) async {
          throw const SocketException('bridge unreachable');
        }),
        endpoint: 'http://fake/endpoint',
      );

      await CrashReporter.recordError(error: 'no-network');
      final summary = await CrashReporter.uploadPending();

      expect(summary.uploaded, 0);
      expect(summary.failed, 1);
      final remaining = await env.dir.list().toList();
      expect(remaining, hasLength(1));
    });

    test('idempotent: second call with no pending crashes is a no-op',
        () async {
      var calls = 0;
      CrashReporter.configure(
        env: env,
        httpClient: MockClient((req) async {
          calls++;
          return http.Response('ok', 200);
        }),
        endpoint: 'http://fake/endpoint',
      );

      await CrashReporter.recordError(error: 'once');
      final first = await CrashReporter.uploadPending();
      final second = await CrashReporter.uploadPending();

      expect(first.uploaded, 1);
      expect(second.scanned, 0);
      expect(second.uploaded, 0);
      expect(calls, 1, reason: 'no second upload should fire');
    });

    test('re-entrancy guard skips a concurrent invocation', () async {
      // Use a completer to hold the first upload open while we kick off
      // the second.
      final completer = Completer<http.Response>();
      CrashReporter.configure(
        env: env,
        httpClient: MockClient((req) async => completer.future),
        endpoint: 'http://fake/endpoint',
      );

      await CrashReporter.recordError(error: 'concurrent');
      final firstFuture = CrashReporter.uploadPending();
      // Let the first call enter the body and flip uploadInFlight.
      await Future<void>.delayed(Duration.zero);
      final second = await CrashReporter.uploadPending();
      expect(second.skippedInFlight, isTrue);

      completer.complete(http.Response('ok', 200));
      final first = await firstFuture;
      expect(first.uploaded, 1);
    });
  });

  group('latestCrashFile', () {
    test('returns null when nothing has been recorded', () async {
      CrashReporter.configure(env: env);
      expect(await CrashReporter.latestCrashFile(), isNull);
    });

    test('returns the lexicographically-latest file (timestamped names)',
        () async {
      CrashReporter.configure(env: env);
      await CrashReporter.recordError(error: 'first');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await CrashReporter.recordError(error: 'second');

      final latest = await CrashReporter.latestCrashFile();
      expect(latest, isNotNull);
      final body = await latest!.readAsString();
      expect(body, contains('second'));
    });
  });

  group('pendingCrashCount', () {
    test('counts only crash JSON files', () async {
      CrashReporter.configure(env: env);
      await CrashReporter.recordError(error: 'one');
      await CrashReporter.recordError(error: 'two');
      // Drop a non-JSON file to make sure it's not counted.
      await File('${env.dir.path}/README.txt').writeAsString('ignore me');

      expect(await CrashReporter.pendingCrashCount(), 2);
    });
  });

  group('pendingCrashSummary', () {
    test('formats zero, one, many', () async {
      CrashReporter.configure(env: env);
      expect(await CrashReporter.pendingCrashSummary(), 'No crashes pending.');
      await CrashReporter.recordError(error: 'x');
      expect(
          await CrashReporter.pendingCrashSummary(), '1 crash pending upload.');
      await CrashReporter.recordError(error: 'y');
      expect(await CrashReporter.pendingCrashSummary(),
          '2 crashes pending upload.');
    });
  });

  group('defensiveness', () {
    test('crashesDir returning null does not throw', () async {
      final nullEnv = _NullDirEnvironment();
      CrashReporter.configure(env: nullEnv);
      // Should complete without throwing.
      await CrashReporter.recordError(error: 'no-dir');
      expect(await CrashReporter.latestCrashFile(), isNull);
      expect(await CrashReporter.pendingCrashCount(), 0);
      final summary = await CrashReporter.uploadPending();
      expect(summary.uploaded, 0);
    });
  });
}

class _NullDirEnvironment implements CrashEnvironment {
  @override
  Future<Directory?> crashesDir() async => null;

  @override
  Future<CrashEnvironmentInfo> snapshot() async => const CrashEnvironmentInfo(
        appVersion: '',
        buildSha: '',
        platformVersion: '',
        deviceModel: '',
      );
}
