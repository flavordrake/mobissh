// PDF detection (#557).
//
// Pure helpers deciding whether a tapped SFTP entry should route to the in-app
// PDF viewer. Detection is by filename extension (case-insensitive) and/or an
// explicit MIME type. Kept dependency-free so it's trivially unit-testable and
// shared between the tap interceptor and any future preview routing.

import 'session_messages.dart';

/// True when [name] ends with a `.pdf` extension (case-insensitive). Requires a
/// real extension — a bare `pdf` or `mypdf` does not match.
bool hasPdfExtension(String name) => name.toLowerCase().endsWith('.pdf');

/// True when [mime] denotes a PDF (`application/pdf`, possibly with parameters
/// like `; charset=binary`). Null / empty / other types are false.
bool isPdfMime(String? mime) {
  if (mime == null || mime.isEmpty) return false;
  final base = mime.split(';').first.trim().toLowerCase();
  return base == 'application/pdf';
}

/// True when [entry] is a regular file that looks like a PDF, by extension or
/// by an explicit [mime]. Directories are never PDFs.
bool isPdfEntry(SftpEntry entry, {String? mime}) {
  if (entry.isDirectory) return false;
  return hasPdfExtension(entry.name) || isPdfMime(mime);
}
