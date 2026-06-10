// In-app markdown viewer (#854) — PWA parity.
//
// Opened from the SFTP file browser when a `.md` / `.markdown` file is tapped
// (via the [fileViewerRegistryProvider], which routes markdown here BEFORE the
// generic monospace [TextFileViewerScreen]). On mount it streams the remote file
// into memory through the shared [TextFileFetcher] (the same SFTP download seam
// the text/code viewer uses), then renders it.
//
// Two view modes, mirroring the PWA's markdown viewer:
//   - RENDERED (default): markdown formatted to headings / bold / italic /
//     lists / links / code blocks / tables, via `flutter_markdown_plus`. Links
//     open in the system browser through url_launcher (externalApplication —
//     the same idiom as the terminal URL handler).
//   - RAW: the monospace source (identical to the text/code viewer), reachable
//     via a single chrome toggle in the AppBar (a monochrome Material glyph, no
//     emoji).
//
// READ-ONLY in this slice (#854 render+toggle). Editable SFTP round-trip is a
// focused follow-up — it needs a new SFTP WRITE path through the UI↔task IPC
// (no write/upload seam exists yet). State is per-route (sessionId + entry) —
// no global viewer state, so multiple sessions don't share preview state.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/session_messages.dart';
import '../services/text_file_fetcher.dart';
import 'file_browser_screen.dart';

/// Opens a markdown link [href] in the system browser (externalApplication).
/// Mirrors the terminal URL handler idiom. Injected as a typedef so widget
/// tests can spy on launches without a platform channel.
typedef MarkdownLinkOpener = Future<void> Function(String href);

Future<void> _defaultOpenMarkdownLink(String href) async {
  final uri = Uri.tryParse(href);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Full-screen markdown preview route for a single remote [entry] on
/// [sessionId]. Rendered by default; toggle to raw source.
class MarkdownFileViewerScreen extends ConsumerStatefulWidget {
  const MarkdownFileViewerScreen({
    super.key,
    required this.sessionId,
    required this.entry,
    this.openLink = _defaultOpenMarkdownLink,
  });

  final String sessionId;
  final SftpEntry entry;

  /// Seam for opening tapped links — production launches the system browser;
  /// tests inject a spy.
  final MarkdownLinkOpener openLink;

  @override
  ConsumerState<MarkdownFileViewerScreen> createState() =>
      _MarkdownFileViewerScreenState();
}

enum _Phase { fetching, ready, error }

class _MarkdownFileViewerScreenState
    extends ConsumerState<MarkdownFileViewerScreen> {
  _Phase _phase = _Phase.fetching;
  String? _errorMessage;
  String? _content;
  int _received = 0;
  int? _total;
  bool _started = false;

  /// View mode: rendered (default) vs raw source. Per-route — no global state.
  bool _raw = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_fetch());
  }

  Future<void> _fetch() async {
    final fetcher = ref.read(textFileFetcherProvider);
    try {
      final text = await fetcher.fetch(
        widget.sessionId,
        widget.entry,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _content = text;
        _phase = _Phase.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _errorMessage = e.toString();
      });
    }
  }

  void _toggleRaw() {
    setState(() => _raw = !_raw);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.entry.name, overflow: TextOverflow.ellipsis),
        actions: [
          if (_phase == _Phase.ready)
            IconButton(
              key: const Key('markdown-raw-toggle'),
              // Monochrome Material glyph (no emoji): show the "code" glyph to
              // switch INTO raw source, the "article" glyph to switch back to
              // the rendered document.
              icon: Icon(_raw ? Icons.article_outlined : Icons.code),
              tooltip: _raw ? 'Show rendered' : 'Show raw source',
              onPressed: _toggleRaw,
            ),
          // #855: one-tap return to the terminal (collapses the whole
          // browser/viewer stack) — conventional top-right close, rightmost.
          IconButton(
            key: const Key('markdown-viewer-close-to-terminal'),
            tooltip: 'Close — back to terminal',
            icon: const Icon(Icons.close),
            onPressed: () => dismissFileBrowserStack(context),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    switch (_phase) {
      case _Phase.fetching:
        return _Fetching(received: _received, total: _total);
      case _Phase.error:
        return _ErrorView(message: _errorMessage);
      case _Phase.ready:
        final text = _content ?? '';
        return _raw
            ? _RawContent(text: text)
            : _RenderedContent(text: text, openLink: widget.openLink);
    }
  }
}

/// Rendered markdown. `flutter_markdown_plus` does its own scrolling +
/// selection; links route through [openLink].
class _RenderedContent extends StatelessWidget {
  const _RenderedContent({required this.text, required this.openLink});

  final String text;
  final MarkdownLinkOpener openLink;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) {
      return const Center(
        key: Key('markdown-viewer-empty'),
        child: Text('(empty file)'),
      );
    }
    return Markdown(
      key: const Key('markdown-viewer-rendered'),
      data: text,
      selectable: true,
      padding: const EdgeInsets.all(12),
      // `Markdown` defaults extensionSet to gitHubFlavored — tables,
      // strikethrough, fenced code blocks, etc. (PWA-parity feature set).
      onTapLink: (txt, href, title) {
        if (href != null && href.isNotEmpty) {
          unawaited(openLink(href));
        }
      },
    );
  }
}

/// Raw monospace source — the read-only fallback, identical to the text/code
/// viewer's presentation so toggling feels seamless.
class _RawContent extends StatelessWidget {
  const _RawContent({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final style =
        Theme.of(context).textTheme.bodyMedium?.copyWith(
          fontFamily: 'monospace',
          fontFamilyFallback: const ['RobotoMono', 'monospace'],
        ) ??
        const TextStyle(fontFamily: 'monospace');
    return Scrollbar(
      child: SingleChildScrollView(
        primary: true,
        padding: const EdgeInsets.all(12),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText(
            text.isEmpty ? '(empty file)' : text,
            key: const Key('markdown-viewer-raw'),
            style: style,
          ),
        ),
      ),
    );
  }
}

class _Fetching extends StatelessWidget {
  const _Fetching({required this.received, this.total});

  final int received;
  final int? total;

  @override
  Widget build(BuildContext context) {
    final t = total;
    final value = (t != null && t > 0) ? (received / t).clamp(0.0, 1.0) : null;
    return Center(
      key: const Key('markdown-viewer-loading'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 160, child: LinearProgressIndicator(value: value)),
          const SizedBox(height: 16),
          Text('Loading…', style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      key: const Key('markdown-viewer-error'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, size: 48, color: scheme.error),
            const SizedBox(height: 12),
            Text(
              message?.isNotEmpty == true
                  ? message!
                  : 'Could not open this file',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
