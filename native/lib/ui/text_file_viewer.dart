// In-app text/code viewer (#776).
//
// Opened from the SFTP file browser when a text/code/markdown file is tapped
// (via the [fileViewerRegistryProvider]). On mount it streams the remote file
// into memory through a [TextFileFetcher] (which reuses the proxy's SFTP
// download path), decodes it as UTF-8 (lossy), and renders it READ-ONLY in a
// scrollable, selectable monospace view — matching the terminal aesthetic the
// PWA uses. A fetch error surfaces a graceful error state rather than crashing.
//
// READ-ONLY for this slice (#776): no editing, no save. Editing is a later
// slice. State is per-screen (sessionId + entry) — no global viewer state.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/session_messages.dart';
import '../services/text_file_fetcher.dart';

/// Full-screen read-only preview route for a single remote text [entry] on
/// [sessionId].
class TextFileViewerScreen extends ConsumerStatefulWidget {
  const TextFileViewerScreen({
    super.key,
    required this.sessionId,
    required this.entry,
  });

  final String sessionId;
  final SftpEntry entry;

  @override
  ConsumerState<TextFileViewerScreen> createState() =>
      _TextFileViewerScreenState();
}

enum _Phase { fetching, ready, error }

class _TextFileViewerScreenState extends ConsumerState<TextFileViewerScreen> {
  _Phase _phase = _Phase.fetching;
  String? _errorMessage;
  String? _content;
  int _received = 0;
  int? _total;
  bool _started = false;

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.entry.name, overflow: TextOverflow.ellipsis),
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
        return _TextContent(text: _content ?? '');
    }
  }
}

class _TextContent extends StatelessWidget {
  const _TextContent({required this.text});

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
            key: const Key('text-viewer-content'),
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
      key: const Key('text-viewer-loading'),
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
      key: const Key('text-viewer-error'),
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
