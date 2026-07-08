// Unit tests for the feedback bundle assembler (#553).
//
// The assembler gathers connect-log ring buffer + last crash report + crash
// environment + app version/git-hash + device/OS info into a single text/JSON
// blob, scrubbing any secret material. These tests pin two contracts:
//   1. The bundle CONTAINS the diagnostic essentials (version, git hash, a
//      sample connect-log line, device/OS info).
//   2. The bundle CONTAINS NO credential material — a planted fake password
//      must never survive into the output blob.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/diagnostics/crash_environment.dart';
import 'package:mobissh/diagnostics/feedback_bundle.dart';

void main() {
  const info = CrashEnvironmentInfo(
    appVersion: '1.4.2+57',
    buildSha: 'abc1234deadbeef',
    platformVersion: 'Android 34 (14)',
    deviceModel: 'Pixel TestDevice',
  );

  group('assembleFeedbackBundle', () {
    test('includes app version, git hash, device/OS info, and connect log', () {
      final blob = assembleFeedbackBundle(
        info: info,
        connectLog: const [
          '05:00:01.123 [ui.form] connect tapped host=example.com',
          '05:00:01.456 [ui.gw] handshake ok',
        ],
        crashJson: null,
      );

      expect(blob, contains('1.4.2+57'), reason: 'app version must be present');
      expect(
        blob,
        contains('abc1234deadbeef'),
        reason: 'git hash / build sha must be present',
      );
      expect(
        blob,
        contains('Android 34 (14)'),
        reason: 'platform/OS version must be present',
      );
      expect(
        blob,
        contains('Pixel TestDevice'),
        reason: 'device model must be present',
      );
      expect(
        blob,
        contains('[ui.gw] handshake ok'),
        reason: 'a sample connect-log line must be present',
      );
    });

    test('is valid JSON with a stable top-level shape', () {
      final blob = assembleFeedbackBundle(
        info: info,
        connectLog: const ['05:00:01.123 [ui.form] tapped'],
        crashJson: null,
      );

      final decoded = jsonDecode(blob) as Map<String, Object?>;
      expect(decoded['schema'], isNotNull);
      expect(decoded['kind'], 'feedback');
      expect(decoded['appVersion'], '1.4.2+57');
      expect(decoded['buildSha'], 'abc1234deadbeef');
      expect(decoded['platformVersion'], 'Android 34 (14)');
      expect(decoded['deviceModel'], 'Pixel TestDevice');
      expect(decoded['connectLog'], isA<List<Object?>>());
      expect(
        (decoded['connectLog'] as List).single,
        '05:00:01.123 [ui.form] tapped',
      );
      // ts present so the recipient knows when the bundle was assembled.
      expect(decoded['ts'], isA<String>());
    });

    test('includes the gesture-trace log when supplied (#699)', () {
      final blob = assembleFeedbackBundle(
        info: info,
        connectLog: const [],
        gestureLog: const [
          '06:00:00.000 longpress-start pos=(120.0,400.0) size=(393.0,700.0) '
              'grid=46x24 cell=(13,24) sgr=ESC[<0;13;24M mouse=any by=overlay',
        ],
        crashJson: null,
      );
      final decoded = jsonDecode(blob) as Map<String, Object?>;
      expect(decoded['gestureLog'], isA<List<Object?>>());
      expect((decoded['gestureLog'] as List).single, contains('cell=(13,24)'));
    });

    test('includes the lifecycle-event log when supplied (#759)', () {
      final blob = assembleFeedbackBundle(
        info: info,
        connectLog: const [],
        lifecycleLog: const [
          '19:22:19.001 [task.host] resume-liveness: '
              'STALE(no-bytes-after-nudge) → reconnect',
        ],
        crashJson: null,
      );
      final decoded = jsonDecode(blob) as Map<String, Object?>;
      expect(decoded['lifecycleLog'], isA<List<Object?>>());
      expect(
        (decoded['lifecycleLog'] as List).single,
        contains('STALE(no-bytes-after-nudge)'),
        reason:
            'the resume-liveness outcome must survive into the bundle so '
            'the next wake-frozen report is diagnosable (#759)',
      );
    });

    test('lifecycleLog defaults to an empty list when omitted (#759)', () {
      final blob = assembleFeedbackBundle(
        info: info,
        connectLog: const [],
        crashJson: null,
      );
      final decoded = jsonDecode(blob) as Map<String, Object?>;
      expect(decoded['lifecycleLog'], isA<List<Object?>>());
      expect((decoded['lifecycleLog'] as List), isEmpty);
    });

    test('includes the control-mode trace when supplied (#906)', () {
      final blob = assembleFeedbackBundle(
        info: info,
        connectLog: const [],
        controlModeTrace: const [
          '19:22:19.001 [cc] gesture raw=tapStatusCol col=45 cols=90 → '
              'dropped(reason=no-window-known) windows=[none]',
        ],
        crashJson: null,
      );
      final decoded = jsonDecode(blob) as Map<String, Object?>;
      expect(decoded['controlModeTrace'], isA<List<Object?>>());
      expect(
        (decoded['controlModeTrace'] as List).single,
        contains('no-window-known'),
        reason:
            'the control-mode trace must survive into the bundle so a "not '
            'switching" report is diagnosable from one report (#906)',
      );
    });

    test('controlModeTrace defaults to an empty list when omitted (#906)', () {
      final blob = assembleFeedbackBundle(
        info: info,
        connectLog: const [],
        crashJson: null,
      );
      final decoded = jsonDecode(blob) as Map<String, Object?>;
      expect(decoded['controlModeTrace'], isA<List<Object?>>());
      expect((decoded['controlModeTrace'] as List), isEmpty);
    });

    test('gestureLog defaults to an empty list when omitted (#699)', () {
      final blob = assembleFeedbackBundle(
        info: info,
        connectLog: const [],
        crashJson: null,
      );
      final decoded = jsonDecode(blob) as Map<String, Object?>;
      expect(decoded['gestureLog'], isA<List<Object?>>());
      expect((decoded['gestureLog'] as List), isEmpty);
    });

    test('embeds the last crash report when one is supplied', () {
      const crashJson =
          '{"schema":1,"kind":"flutter","error":"RangeError","ts":"x"}';
      final blob = assembleFeedbackBundle(
        info: info,
        connectLog: const [],
        crashJson: crashJson,
      );

      final decoded = jsonDecode(blob) as Map<String, Object?>;
      expect(
        decoded['lastCrash'],
        isNotNull,
        reason: 'crash report must be embedded when present',
      );
      // Embedded as parsed JSON so the bundle stays a single well-formed doc.
      final crash = decoded['lastCrash'] as Map<String, Object?>;
      expect(crash['error'], 'RangeError');
    });

    test('omits lastCrash (null) when no crash report is supplied', () {
      final blob = assembleFeedbackBundle(
        info: info,
        connectLog: const [],
        crashJson: null,
      );
      final decoded = jsonDecode(blob) as Map<String, Object?>;
      expect(decoded['lastCrash'], isNull);
    });

    test('keeps a non-JSON crash blob as a raw string without crashing', () {
      // Defensive: if the on-disk crash file is somehow corrupt/non-JSON, the
      // assembler must not throw — it preserves the raw text.
      final blob = assembleFeedbackBundle(
        info: info,
        connectLog: const [],
        crashJson: 'not-json-at-all',
      );
      final decoded = jsonDecode(blob) as Map<String, Object?>;
      expect(decoded['lastCrashRaw'], 'not-json-at-all');
      expect(decoded['lastCrash'], isNull);
    });

    test('includes the detection-exceptions corpus when supplied (#995)', () {
      final blob = assembleFeedbackBundle(
        info: info,
        connectLog: const [],
        detectionExceptions: const [
          'https://false.positive/x [url] host=test-sshd',
          '/config [path] host=test-sshd',
        ],
        crashJson: null,
      );
      final decoded = jsonDecode(blob) as Map<String, Object?>;
      expect(decoded['detectionExceptionCount'], 2);
      expect(decoded['detectionExceptions'], isA<List<Object?>>());
      expect(
        (decoded['detectionExceptions'] as List).first,
        contains('https://false.positive/x'),
        reason:
            'the saved false-positive reports are the corpus for improving '
            'the detector (#995)',
      );
    });

    test('detection exceptions default empty + recent list is capped (#995)', () {
      final none = assembleFeedbackBundle(
        info: info,
        connectLog: const [],
        crashJson: null,
      );
      final decodedNone = jsonDecode(none) as Map<String, Object?>;
      expect(decodedNone['detectionExceptionCount'], 0);
      expect(decodedNone['detectionExceptions'], isEmpty);

      final many = assembleFeedbackBundle(
        info: info,
        connectLog: const [],
        detectionExceptions: [
          for (var i = 0; i < 50; i++) 'https://fp.example/$i [url]',
        ],
        crashJson: null,
      );
      final decodedMany = jsonDecode(many) as Map<String, Object?>;
      expect(decodedMany['detectionExceptionCount'], 50);
      final recent = decodedMany['detectionExceptions'] as List;
      expect(recent.length, lessThanOrEqualTo(20));
      // The RECENT entries ride along (newest are at the end of the input).
      expect(recent.last, contains('/49 '));
    });

    test('detection exceptions are scrubbed like the other rings (#995)', () {
      const planted = 'hunter2-SUPER-SECRET-pw';
      final blob = assembleFeedbackBundle(
        info: info,
        connectLog: const [],
        detectionExceptions: const ['token=$planted [url]'],
        crashJson: null,
      );
      expect(blob.contains(planted), isFalse);
    });

    test('contains NO credential material (planted password is scrubbed)', () {
      const plantedPassword = 'hunter2-SUPER-SECRET-pw';
      const plantedKey = 'BEGIN OPENSSH PRIVATE KEY';
      // A maliciously-crafted log line carrying a secret should be redacted.
      final blob = assembleFeedbackBundle(
        info: info,
        connectLog: const [
          '05:00:01.000 [ui.form] password=$plantedPassword len=20',
          '05:00:02.000 [ui.proxy] privateKey: -----$plantedKey-----',
        ],
        crashJson:
            '{"schema":1,"error":"boom password=$plantedPassword token=abc"}',
      );

      expect(
        blob.contains(plantedPassword),
        isFalse,
        reason: 'a planted password must never survive into the bundle',
      );
      expect(
        blob.contains(plantedKey),
        isFalse,
        reason: 'private-key material must be scrubbed from the bundle',
      );
      // The scrubber leaves a marker so the line is still diagnostically useful.
      expect(
        blob,
        contains('[REDACTED]'),
        reason: 'scrubbed values are replaced with a redaction marker',
      );
    });
  });
}
