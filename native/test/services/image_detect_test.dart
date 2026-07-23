// Unit tests for image detection (#1093).

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/image_detect.dart';
import 'package:mobissh/services/session_messages.dart';

SftpEntry _file(String name) =>
    SftpEntry(name: name, path: '/$name', isDirectory: false);

void main() {
  group('hasImageExtension', () {
    test('matches known raster extensions, case-insensitive', () {
      for (final n in [
        'a.png',
        'A.PNG',
        'photo.jpg',
        'photo.jpeg',
        'scan.JFIF',
        'loop.gif',
        'pic.webp',
        'old.bmp',
        'new.avif',
        'anim.apng',
        'fav.ico',
      ]) {
        expect(hasImageExtension(n), isTrue, reason: n);
      }
    });

    test('rejects non-image and malformed names', () {
      for (final n in [
        'notes.txt',
        'archive.zip',
        'movie.mp4',
        'diagram.svg', // SVG routes to the text viewer, not the image viewer
        'png', // bare extension, no dot
        'trailingdot.', // trailing dot, no extension
        '.png', // dotfile: no real extension
        'noext',
      ]) {
        expect(hasImageExtension(n), isFalse, reason: n);
      }
    });
  });

  group('isImageMime', () {
    test('accepts image/* and ignores parameters', () {
      expect(isImageMime('image/png'), isTrue);
      expect(isImageMime('image/gif; charset=binary'), isTrue);
      expect(isImageMime('IMAGE/WEBP'), isTrue);
    });

    test('rejects svg, non-image, null/empty', () {
      expect(isImageMime('image/svg+xml'), isFalse);
      expect(isImageMime('text/plain'), isFalse);
      expect(isImageMime('application/pdf'), isFalse);
      expect(isImageMime(null), isFalse);
      expect(isImageMime(''), isFalse);
    });
  });

  group('isImageEntry', () {
    test('true by extension or by mime', () {
      expect(isImageEntry(_file('a.png')), isTrue);
      expect(isImageEntry(_file('blob'), mime: 'image/jpeg'), isTrue);
    });

    test('directories are never images', () {
      expect(
        isImageEntry(const SftpEntry(name: 'a.png', path: '/a.png',
            isDirectory: true)),
        isFalse,
      );
    });

    test('svg is not an image entry (stays with text viewer)', () {
      expect(isImageEntry(_file('logo.svg')), isFalse);
      expect(isImageEntry(_file('logo.svg'), mime: 'image/svg+xml'), isFalse);
    });
  });

  group('imageMimeForName', () {
    test('maps known extensions', () {
      expect(imageMimeForName('a.png'), 'image/png');
      expect(imageMimeForName('a.JPG'), 'image/jpeg');
      expect(imageMimeForName('a.jpeg'), 'image/jpeg');
      expect(imageMimeForName('a.gif'), 'image/gif');
      expect(imageMimeForName('a.webp'), 'image/webp');
      expect(imageMimeForName('a.ico'), 'image/x-icon');
    });

    test('falls back to image/png for unknown extensions', () {
      expect(imageMimeForName('mystery'), 'image/png');
    });
  });
}
