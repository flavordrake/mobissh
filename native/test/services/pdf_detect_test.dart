// Unit tests for PDF detection (#557).
//
// `isPdfEntry` decides whether a tapped SFTP entry should route to the in-app
// PDF viewer. Detection is by filename extension (case-insensitive) and/or an
// explicit MIME type when one is available. Directories are never PDFs.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/pdf_detect.dart';
import 'package:mobissh/services/session_messages.dart';

SftpEntry _file(String name) =>
    SftpEntry(name: name, path: '/$name', isDirectory: false);

void main() {
  group('isPdfEntry by extension', () {
    test('lowercase .pdf is a PDF', () {
      expect(isPdfEntry(_file('report.pdf')), isTrue);
    });

    test('uppercase .PDF is a PDF (case-insensitive)', () {
      expect(isPdfEntry(_file('REPORT.PDF')), isTrue);
    });

    test('mixed case .Pdf is a PDF', () {
      expect(isPdfEntry(_file('Report.Pdf')), isTrue);
    });

    test('name containing pdf but not as extension is not a PDF', () {
      expect(isPdfEntry(_file('pdf-notes.txt')), isFalse);
      expect(isPdfEntry(_file('mypdf')), isFalse);
    });

    test('non-pdf extension is not a PDF', () {
      expect(isPdfEntry(_file('image.png')), isFalse);
      expect(isPdfEntry(_file('archive.pdf.zip')), isFalse);
    });

    test('a directory named foo.pdf is not a PDF', () {
      const dir = SftpEntry(
        name: 'foo.pdf',
        path: '/foo.pdf',
        isDirectory: true,
      );
      expect(isPdfEntry(dir), isFalse);
    });
  });

  group('isPdfEntry by MIME', () {
    test('application/pdf mime makes it a PDF even without extension', () {
      expect(isPdfMime('application/pdf'), isTrue);
    });

    test('mime with parameters still matches', () {
      expect(isPdfMime('application/pdf; charset=binary'), isTrue);
    });

    test('uppercase mime matches', () {
      expect(isPdfMime('Application/PDF'), isTrue);
    });

    test('non-pdf mime does not match', () {
      expect(isPdfMime('text/plain'), isFalse);
      expect(isPdfMime(null), isFalse);
      expect(isPdfMime(''), isFalse);
    });
  });

  group('hasPdfExtension', () {
    test('matches .pdf suffix only', () {
      expect(hasPdfExtension('a.pdf'), isTrue);
      expect(hasPdfExtension('a.PDF'), isTrue);
      expect(hasPdfExtension('a.txt'), isFalse);
      expect(hasPdfExtension('pdf'), isFalse);
      expect(hasPdfExtension(''), isFalse);
    });
  });
}
