// Binary-guard unit tests for the text fetcher (#893).
//
// The fetcher decodes downloaded bytes as lossy UTF-8 for the read-only text
// viewer. Before rendering it must reject binary content (NUL byte or a high
// proportion of non-printable bytes in the leading sample) so the viewer
// surfaces a "download instead" state rather than mojibake. `isBinaryContent`
// is a pure helper so this is trivially unit-testable, emulator-free.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/text_file_fetcher.dart';

void main() {
  group('isBinaryContent', () {
    test('detects a NUL byte as binary', () {
      final bytes = Uint8List.fromList([0x48, 0x69, 0x00, 0x21]); // "Hi\0!"
      expect(isBinaryContent(bytes), isTrue);
    });

    test('detects mostly-non-printable buffer as binary', () {
      // 0x80..0x8F are non-printable control/high bytes (not valid lone UTF-8
      // printables); a buffer dominated by them is binary.
      final bytes = Uint8List.fromList(
        List<int>.generate(100, (i) => 0x01 + (i % 7)),
      );
      expect(isBinaryContent(bytes), isTrue);
    });

    test('accepts normal ASCII/UTF-8 text', () {
      final bytes = Uint8List.fromList(
        utf8.encode('Host example\n  User me\n  Port 22\n'),
      );
      expect(isBinaryContent(bytes), isFalse);
    });

    test('accepts UTF-8 with multibyte characters and common whitespace', () {
      final bytes = Uint8List.fromList(
        utf8.encode('café ☕\tline2\r\nrésumé naïve\n'),
      );
      expect(isBinaryContent(bytes), isFalse);
    });

    test('treats an empty buffer as text (not binary)', () {
      expect(isBinaryContent(Uint8List(0)), isFalse);
    });

    test('tolerates a small fraction of non-printable bytes in text', () {
      // Mostly printable ASCII with a couple of stray control bytes (< 30%).
      final list = <int>[];
      for (var i = 0; i < 100; i++) {
        list.add(i % 25 == 0 ? 0x07 : 0x41 + (i % 26));
      }
      expect(isBinaryContent(Uint8List.fromList(list)), isFalse);
    });
  });
}
