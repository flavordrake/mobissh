// Markdown file detection (#854).
//
// Pure helpers deciding whether a tapped SFTP entry should route to the
// dedicated rendered markdown viewer (vs the generic monospace text viewer).
// Detection is by `.md`/`.markdown` extension (case-insensitive) and/or an
// explicit `text/markdown` MIME type. Dependency-free for trivial unit testing.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/text_file_detect.dart';

void main() {
  SftpEntry file(String name) =>
      SftpEntry(name: name, path: '/$name', isDirectory: false);
  SftpEntry dir(String name) =>
      SftpEntry(name: name, path: '/$name', isDirectory: true);

  group('hasMarkdownExtension', () {
    test('matches .md and .markdown', () {
      expect(hasMarkdownExtension('README.md'), isTrue);
      expect(hasMarkdownExtension('NOTES.markdown'), isTrue);
      expect(hasMarkdownExtension('a/b/CHANGELOG.md'), isTrue);
    });

    test('is case-insensitive', () {
      expect(hasMarkdownExtension('README.MD'), isTrue);
      expect(hasMarkdownExtension('Notes.Markdown'), isTrue);
    });

    test('does not match other text extensions', () {
      for (final n in ['a.txt', 'main.dart', 'config.yaml', 'page.html']) {
        expect(hasMarkdownExtension(n), isFalse, reason: n);
      }
    });

    test('does not match a bare name or a dotfile-only name', () {
      expect(hasMarkdownExtension('README'), isFalse);
      expect(hasMarkdownExtension('md'), isFalse);
      expect(hasMarkdownExtension('.md'), isFalse);
      expect(hasMarkdownExtension('trailing.'), isFalse);
    });
  });

  group('isMarkdownMime', () {
    test('matches text/markdown and text/x-markdown', () {
      expect(isMarkdownMime('text/markdown'), isTrue);
      expect(isMarkdownMime('text/x-markdown'), isTrue);
      expect(isMarkdownMime('text/markdown; charset=utf-8'), isTrue);
      expect(isMarkdownMime('TEXT/MARKDOWN'), isTrue);
    });

    test('does not match other text mimes or null/empty', () {
      expect(isMarkdownMime('text/plain'), isFalse);
      expect(isMarkdownMime('application/json'), isFalse);
      expect(isMarkdownMime(null), isFalse);
      expect(isMarkdownMime(''), isFalse);
    });
  });

  group('isMarkdownEntry', () {
    test('matches markdown files by extension', () {
      expect(isMarkdownEntry(file('README.md')), isTrue);
      expect(isMarkdownEntry(file('NOTES.markdown')), isTrue);
    });

    test('matches by explicit markdown mime even without the extension', () {
      expect(isMarkdownEntry(file('README'), mime: 'text/markdown'), isTrue);
    });

    test('does not match non-markdown text files', () {
      expect(isMarkdownEntry(file('a.txt')), isFalse);
      expect(isMarkdownEntry(file('main.dart')), isFalse);
    });

    test('never matches directories', () {
      expect(isMarkdownEntry(dir('docs.md')), isFalse);
      expect(isMarkdownEntry(dir('docs'), mime: 'text/markdown'), isFalse);
    });
  });
}
