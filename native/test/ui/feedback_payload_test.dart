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
  group('formatFeedbackVersion', () {
    test('combines build + hash into [build hash]', () {
      expect(formatFeedbackVersion('1.2.3+45', 'abc1234'), '[1.2.3+45 abc1234]');
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
        ..writeln('First line that the web form would have used as a title and '
            'then sliced at around one hundred characters losing everything '
            'after this point entirely.')
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

    test('includes the screenshot data URL when provided, omits it otherwise',
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
