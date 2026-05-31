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
