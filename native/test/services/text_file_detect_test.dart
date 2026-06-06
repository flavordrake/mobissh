// Text/code file detection (#776).
//
// Pure helpers deciding whether a tapped SFTP entry should route to the in-app
// text viewer. Detection is by filename extension (case-insensitive) and/or an
// explicit text-ish MIME type. Kept dependency-free for trivial unit testing.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/text_file_detect.dart';

void main() {
  SftpEntry file(String name) =>
      SftpEntry(name: name, path: '/$name', isDirectory: false);

  group('hasTextExtension', () {
    test('matches common text/code/markdown extensions', () {
      for (final n in [
        'a.txt',
        'README.md',
        'main.dart',
        'app.js',
        'index.ts',
        'config.yaml',
        'data.json',
        'notes.LOG',
        'style.css',
        'page.html',
        'script.sh',
        'Makefile.txt',
      ]) {
        expect(hasTextExtension(n), isTrue, reason: n);
      }
    });

    test('is case-insensitive', () {
      expect(hasTextExtension('A.TXT'), isTrue);
      expect(hasTextExtension('Main.DART'), isTrue);
    });

    test('does not match binary / unknown extensions', () {
      for (final n in ['photo.png', 'archive.zip', 'doc.pdf', 'app.bin']) {
        expect(hasTextExtension(n), isFalse, reason: n);
      }
    });

    test('requires a real extension', () {
      expect(hasTextExtension('txt'), isFalse);
      expect(hasTextExtension('noext'), isFalse);
    });
  });

  group('isTextMime', () {
    test('matches text/* and known textual application types', () {
      expect(isTextMime('text/plain'), isTrue);
      expect(isTextMime('text/markdown; charset=utf-8'), isTrue);
      expect(isTextMime('application/json'), isTrue);
      expect(isTextMime('application/xml'), isTrue);
      expect(isTextMime('application/javascript'), isTrue);
    });

    test('rejects binary types and null/empty', () {
      expect(isTextMime('application/pdf'), isFalse);
      expect(isTextMime('image/png'), isFalse);
      expect(isTextMime(null), isFalse);
      expect(isTextMime(''), isFalse);
    });
  });

  group('isTextEntry', () {
    test('true for a text-extension file', () {
      expect(isTextEntry(file('a.txt')), isTrue);
    });

    test('true for a text MIME even without a text extension', () {
      expect(isTextEntry(file('blob'), mime: 'text/plain'), isTrue);
    });

    test('false for directories', () {
      expect(
        isTextEntry(
          const SftpEntry(name: 'd', path: '/d', isDirectory: true),
          mime: 'text/plain',
        ),
        isFalse,
      );
    });

    test('false for binary files', () {
      expect(isTextEntry(file('app.bin')), isFalse);
      expect(isTextEntry(file('doc.pdf')), isFalse);
    });
  });
}
