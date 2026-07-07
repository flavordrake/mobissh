// Unit tests for the in-app feedback payload builder (#661).
//
// The whole point of #661 is to KILL the web form's first-line truncation:
// the FULL multi-line comment must reach the server untruncated. These tests
// lock that contract on the pure payload builder (no platform channels).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/ui/feedback_overlay.dart';

void main() {
  group('displayBuildNumber (strips the ABI-split versionCode offset)', () {
    test('recovers the pubspec build from a per-ABI versionCode', () {
      expect(displayBuildNumber('2114'), '114'); // arm64 (2000 + 114)
      expect(displayBuildNumber('2113'), '113');
      expect(displayBuildNumber('1114'), '114'); // armeabi-v7a
      expect(displayBuildNumber('4114'), '114'); // x86_64
    });
    test('passes a non-split / small build through unchanged', () {
      expect(displayBuildNumber('114'), '114');
      expect(displayBuildNumber('64'), '64');
    });
    test('returns non-numeric input as-is', () {
      expect(displayBuildNumber('abc'), 'abc');
      expect(displayBuildNumber(''), '');
    });
  });

  group('formatFeedbackVersion', () {
    test('combines build + hash into [build hash]', () {
      expect(
        formatFeedbackVersion('1.2.3+45', 'abc1234'),
        '[1.2.3+45 abc1234]',
      );
    });

    test('degrades when a part is missing', () {
      expect(formatFeedbackVersion('1.2.3+45', ''), '[1.2.3+45]');
      expect(formatFeedbackVersion('', 'abc1234'), '[abc1234]');
      expect(formatFeedbackVersion('', ''), '[unknown]');
    });
  });

  group('buildFeedbackPayload', () {
    test('preserves the FULL multi-line comment — no truncation', () {
      // A long, multi-line note exactly like the owner's tails that the web
      // form was cutting at ~100 chars on the first line.
      final longComment = StringBuffer()
        ..writeln(
          'First line that the web form would have used as a title and '
          'then sliced at around one hundred characters losing everything '
          'after this point entirely.',
        )
        ..writeln('Second line with more detail.')
        ..writeln('Third line: also charact...');
      final comment = longComment.toString();

      final payload = buildFeedbackPayload(
        comment: comment,
        version: '[1.0.0+9 deadbee]',
      );

      // The full comment survives verbatim in BOTH the comment field (the
      // source of truth the server persists) and the logs sidecar mirror.
      expect(payload['comment'], comment);
      expect(payload['logs'], comment);
      // And it is NOT truncated to the first line.
      expect((payload['comment'] as String).contains('Third line'), isTrue);
      expect((payload['comment'] as String).length, comment.length);
    });

    test('title is a one-line summary prefixed with the version', () {
      final payload = buildFeedbackPayload(
        comment: 'Scroll is broken\nmore detail here',
        version: '[2.0.0+1 cafef00]',
      );
      expect(payload['title'], '[2.0.0+1 cafef00] Scroll is broken');
      // Title summary uses the first NON-EMPTY line.
      final payload2 = buildFeedbackPayload(
        comment: '\n\n  Real first line  \nsecond',
        version: '[v]',
      );
      expect(payload2['title'], '[v] Real first line');
    });

    test('empty comment still yields a sensible title and empty body', () {
      final payload = buildFeedbackPayload(comment: '', version: '[v h]');
      expect(payload['title'], 'In-app feedback [v h]');
      expect(payload['comment'], '');
    });

    test('embeds the version stamp and marks the native source', () {
      final payload = buildFeedbackPayload(
        comment: 'x',
        version: '[1.0.0+9 deadbee]',
      );
      expect(payload['version'], '[1.0.0+9 deadbee]');
      expect(payload['source'], 'native-in-app');
    });

    test(
      'includes the screenshot data URL when provided, omits it otherwise',
      () {
        final withShot = buildFeedbackPayload(
          comment: 'x',
          version: '[v]',
          screenshotDataUrl: 'data:image/png;base64,AAAA',
        );
        expect(withShot['screenshot'], 'data:image/png;base64,AAAA');

        final without = buildFeedbackPayload(comment: 'x', version: '[v]');
        expect(without.containsKey('screenshot'), isFalse);

        final emptyShot = buildFeedbackPayload(
          comment: 'x',
          version: '[v]',
          screenshotDataUrl: '',
        );
        expect(emptyShot.containsKey('screenshot'), isFalse);
      },
    );

    test('attaches the connect-trace log when present, omits it when empty', () {
      final withLog = buildFeedbackPayload(
        comment: 'fill broken',
        version: '[v]',
        connectLog: const [
          '08:23:01.123 [ui.fit659] connect: arming fit burst (shell ready)',
          '08:23:02.456 [ui.fit659] burst-700ms: view=393.0x300.0 cell=8.4x18.0 '
              'computed=46x16 cur=46x16 noop font=JetBrainsMono settled=true',
        ],
      );
      // Server (#553) persists this as connectLogFile + connectLogEventCount.
      final log = withLog['connectLog'] as List;
      expect(log.length, 2);
      expect((log[1] as String).contains('view=393.0x300.0'), isTrue);

      // No log → the field is omitted entirely (no empty array noise).
      final without = buildFeedbackPayload(comment: 'x', version: '[v]');
      expect(without.containsKey('connectLog'), isFalse);
    });

    test('scrubs credential-looking material out of the connect log', () {
      // Defense-in-depth: even though ctrace logs lengths only, a stray secret
      // in a trace line must never leave the device (rules/security.md / #553).
      final payload = buildFeedbackPayload(
        comment: 'x',
        version: '[v]',
        connectLog: const [
          '10:00:00.000 [ui.form] password=hunter2 entered',
          '10:00:01.000 [ui.ssh] token: abc.def.ghi',
        ],
      );
      final log = (payload['connectLog'] as List).cast<String>();
      expect(log.every((l) => !l.contains('hunter2')), isTrue);
      expect(log.every((l) => !l.contains('abc.def.ghi')), isTrue);
      expect(log.any((l) => l.contains('[REDACTED]')), isTrue);
    });

    test('payload JSON-encodes cleanly (server consumes JSON)', () {
      final payload = buildFeedbackPayload(
        comment: 'line1\nline2 "quoted"\nline3',
        version: '[v h]',
        screenshotDataUrl: 'data:image/png;base64,AAAA',
      );
      final decoded = jsonDecode(jsonEncode(payload)) as Map<String, dynamic>;
      expect(decoded['comment'], 'line1\nline2 "quoted"\nline3');
    });

    test(
      'attaches the gesture-trace log when present, omits it when empty (#699)',
      () {
        final withLog = buildFeedbackPayload(
          comment: 'selection lands above the press',
          version: '[v]',
          gestureLog: const [
            '08:23:01.123 longpress-start pos=(120.0,400.0) size=(393.0,700.0) '
                'grid=46x24 cell=(13,24) sgr=ESC[<0;13;24M mouse=any by=overlay',
          ],
        );
        // Server persists this as gestureLogFile + gestureLogEventCount (#699),
        // mirroring connectLog.
        final log = withLog['gestureLog'] as List;
        expect(log.length, 1);
        expect((log.single as String).contains('cell=(13,24)'), isTrue);

        // No gesture log → the field is omitted entirely.
        final without = buildFeedbackPayload(comment: 'x', version: '[v]');
        expect(without.containsKey('gestureLog'), isFalse);
      },
    );

    test(
      'scrubs credential-looking material out of the gesture log (#699)',
      () {
        final payload = buildFeedbackPayload(
          comment: 'x',
          version: '[v]',
          gestureLog: const [
            '10:00:00.000 tap pos=(1.0,1.0) password=hunter2 by=overlay',
          ],
        );
        final log = (payload['gestureLog'] as List).cast<String>();
        expect(log.every((l) => !l.contains('hunter2')), isTrue);
        expect(log.any((l) => l.contains('[REDACTED]')), isTrue);
      },
    );

    test(
      'attaches byteTrace / scrollTrace / grid when present, omits when empty '
      '(#790)',
      () {
        final withTrace = buildFeedbackPayload(
          comment: 'scroll stuck',
          version: '[v]',
          byteTrace: const [
            {'tMs': 0, 'b64': 'aGVsbG8='}, // "hello"
            {'tMs': 16, 'b64': 'd29ybGQ='}, // "world"
          ],
          scrollTrace: const [
            {'tMs': 0, 'offset': 0},
            {'tMs': 32, 'offset': 120},
          ],
          grid: const {'cols': 80, 'rows': 24},
        );
        final bytes = withTrace['byteTrace'] as List;
        expect(bytes, hasLength(2));
        expect((bytes.first as Map)['b64'], 'aGVsbG8=');
        final scroll = withTrace['scrollTrace'] as List;
        expect(scroll, hasLength(2));
        expect((scroll.last as Map)['offset'], 120);
        expect(withTrace['grid'], {'cols': 80, 'rows': 24});

        // No trace → all three fields omitted (no empty-array / null noise).
        final without = buildFeedbackPayload(comment: 'x', version: '[v]');
        expect(without.containsKey('byteTrace'), isFalse);
        expect(without.containsKey('scrollTrace'), isFalse);
        expect(without.containsKey('grid'), isFalse);
      },
    );
  });

  group('buildFeedbackPayload — #967 include/exclude gating', () {
    Map<String, Object?> full({bool images = true, bool traces = true}) =>
        buildFeedbackPayload(
          comment: 'note',
          version: '[v]',
          screenshotDataUrl: 'data:image/png;base64,AAAA',
          frameDataUrls: const ['data:image/png;base64,AAAA', 'data:image/png;base64,BBBB'],
          connectLog: const ['ui.fit659 something'],
          gestureLog: const ['gesture line'],
          lifecycleLog: const ['lifecycle line'],
          byteTrace: const [{'tMs': 1, 'b64': 'zz'}],
          scrollTrace: const [{'tMs': 1, 'offset': 3}],
          sentSgrTrace: const [{'tMs': 1, 'b64': 'yy'}],
          grid: const {'cols': 80, 'rows': 24},
          includeImages: images,
          includeTraces: traces,
        );

    test('defaults include everything (report quality preserved)', () {
      final p = full();
      for (final k in const [
        'screenshot', 'frames', 'connectLog', 'gestureLog', 'lifecycleLog',
        'byteTrace', 'scrollTrace', 'sentSgrTrace', 'grid',
      ]) {
        expect(p.containsKey(k), isTrue, reason: '$k present by default');
      }
    });

    test('excludeImages OMITS screenshot + frames, keeps traces + comment', () {
      final p = full(images: false);
      expect(p.containsKey('screenshot'), isFalse);
      expect(p.containsKey('frames'), isFalse);
      // Traces + the note remain.
      expect(p.containsKey('byteTrace'), isTrue);
      expect(p.containsKey('connectLog'), isTrue);
      expect(p['comment'], 'note');
    });

    test('excludeTraces OMITS all logs/traces/grid, keeps images + comment', () {
      final p = full(traces: false);
      for (final k in const [
        'connectLog', 'gestureLog', 'lifecycleLog',
        'byteTrace', 'scrollTrace', 'sentSgrTrace', 'grid',
      ]) {
        expect(p.containsKey(k), isFalse, reason: '$k must be omitted');
      }
      // Images + the note remain.
      expect(p.containsKey('screenshot'), isTrue);
      expect(p.containsKey('frames'), isTrue);
      expect(p['comment'], 'note');
    });

    test('excluding both leaves only comment/version/title/logs/source', () {
      final p = full(images: false, traces: false);
      expect(p.containsKey('screenshot'), isFalse);
      expect(p.containsKey('frames'), isFalse);
      expect(p.containsKey('byteTrace'), isFalse);
      expect(p.containsKey('connectLog'), isFalse);
      expect(p['comment'], 'note');
      expect(p['version'], '[v]');
    });
  });

  group('pngBytesToDataUrl', () {
    test('produces a data URL for non-empty bytes', () {
      final url = pngBytesToDataUrl(Uint8List.fromList([1, 2, 3]));
      expect(url, isNotNull);
      expect(url!.startsWith('data:image/png;base64,'), isTrue);
    });

    test('returns null for empty bytes', () {
      expect(pngBytesToDataUrl(Uint8List(0)), isNull);
    });
  });
}
