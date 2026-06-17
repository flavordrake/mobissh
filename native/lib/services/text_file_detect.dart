// Text/code file detection (#776).
//
// Pure helpers deciding whether a tapped SFTP entry should route to the in-app
// text viewer. Detection is by filename extension (case-insensitive) and/or an
// explicit text-ish MIME type. Kept dependency-free so it's trivially
// unit-testable and shared between the viewer registry and any future routing.

import 'session_messages.dart';

/// Extensions we treat as previewable text/code/markup. Lowercase, no leading
/// dot. Conservative on purpose: only formats that decode meaningfully as UTF-8.
const Set<String> _textExtensions = {
  'txt', 'text', 'log', 'md', 'markdown', 'rst',
  'dart', 'js', 'mjs', 'cjs', 'ts', 'tsx', 'jsx',
  'py', 'rb', 'go', 'rs', 'java', 'kt', 'kts', 'swift',
  'c', 'h', 'cc', 'cpp', 'hpp', 'cs', 'm', 'mm',
  'sh', 'bash', 'zsh', 'fish', 'ps1', 'bat',
  'json', 'jsonc', 'yaml', 'yml', 'toml', 'ini', 'cfg', 'conf', 'env',
  'xml', 'html', 'htm', 'css', 'scss', 'less', 'svg',
  'sql', 'csv', 'tsv', 'properties', 'gradle', 'lock',
  'gitignore', 'dockerfile', 'makefile',
};

/// True when [name] ends with a known text/code extension (case-insensitive).
/// Requires a real extension — a bare `txt` or `noext` does not match.
bool hasTextExtension(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return false;
  final ext = name.substring(dot + 1).toLowerCase();
  return _textExtensions.contains(ext);
}

/// Well-known filenames that carry no extension but are conventionally plain
/// text/config. Compared case-insensitively against the full name. Mirrors the
/// PWA's content-class fall-through for extensionless text (#893).
const Set<String> _extensionlessTextNames = {
  'config',
  'dockerfile',
  'makefile',
  'rakefile',
  'gemfile',
  'procfile',
  'license',
  'readme',
  'authorized_keys',
  'known_hosts',
  'hosts',
};

/// True when [name] has no real extension yet is conventionally text:
///   (a) a bare dotfile — leading dot, no inner dot (`.bashrc`, `.gitconfig`,
///       `.vimrc`). Files like `.tmux.conf` already match by their `.conf`
///       extension, so this only covers the no-extension case (PWA `isDotfile`).
///   (b) a well-known extensionless name (`config`, `Dockerfile`, `LICENSE`,
///       `known_hosts`, …), case-insensitive.
/// A bare `config` arriving as the basename of `~/.ssh/config` is the motivating
/// case (#893).
bool isExtensionlessTextName(String name) {
  if (name.isEmpty) return false;
  // (a) bare dotfile: leading dot and no further dot.
  if (name.startsWith('.') && name.indexOf('.', 1) == -1) return true;
  // (b) well-known extensionless names (must genuinely have no extension).
  final dot = name.lastIndexOf('.');
  if (dot > 0 && dot != name.length - 1) return false;
  return _extensionlessTextNames.contains(name.toLowerCase());
}

/// True when [mime] denotes textual content: any `text/*`, or a known textual
/// `application/*` type (json, xml, javascript, etc.). MIME parameters
/// (`; charset=…`) are ignored. Null / empty / binary types are false.
bool isTextMime(String? mime) {
  if (mime == null || mime.isEmpty) return false;
  final base = mime.split(';').first.trim().toLowerCase();
  if (base.startsWith('text/')) return true;
  const textApps = {
    'application/json',
    'application/xml',
    'application/javascript',
    'application/x-yaml',
    'application/yaml',
    'application/x-sh',
    'application/toml',
  };
  return textApps.contains(base);
}

/// True when [entry] is a regular file that looks like text, by a known
/// extension, a well-known extensionless name / bare dotfile, or an explicit
/// text [mime]. Directories are never text. This single classifier drives the
/// view router (and, once SFTP write lands, the edit gate) — matching the PWA's
/// single `getPreviewType()` (#893).
bool isTextEntry(SftpEntry entry, {String? mime}) {
  if (entry.isDirectory) return false;
  return hasTextExtension(entry.name) ||
      isExtensionlessTextName(entry.name) ||
      isTextMime(mime);
}

/// Markdown extensions (lowercase, no leading dot). A subset of
/// [_textExtensions] that the dedicated markdown viewer renders (#854).
const Set<String> _markdownExtensions = {'md', 'markdown'};

/// True when [name] ends with a markdown extension (`.md` / `.markdown`,
/// case-insensitive).
bool hasMarkdownExtension(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return false;
  return _markdownExtensions.contains(name.substring(dot + 1).toLowerCase());
}

/// True when [mime] denotes markdown content (`text/markdown` /
/// `text/x-markdown`). MIME parameters (`; charset=…`) are ignored.
bool isMarkdownMime(String? mime) {
  if (mime == null || mime.isEmpty) return false;
  final base = mime.split(';').first.trim().toLowerCase();
  return base == 'text/markdown' || base == 'text/x-markdown';
}

/// True when [entry] is a regular markdown file, by extension or an explicit
/// markdown [mime]. Directories are never markdown. Used by the viewer registry
/// to route `.md`/`.markdown` to the dedicated rendered markdown viewer (#854)
/// BEFORE the generic monospace text viewer (first-match-wins).
bool isMarkdownEntry(SftpEntry entry, {String? mime}) {
  if (entry.isDirectory) return false;
  return hasMarkdownExtension(entry.name) || isMarkdownMime(mime);
}
