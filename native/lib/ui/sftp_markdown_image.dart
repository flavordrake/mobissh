// Inline image for the markdown viewer's `imageBuilder` (#946).
//
// Renders an `![](src)` reference inline at a bounded size, and is TAP-TO-FILL:
// tapping pushes the shared [FillMediaViewer] with the full image, where
// pinch-zoom + pan are forced.
//
// Resolution policy (offline-first, mirrors the link policy):
//   - relative / absolute SFTP path → fetched as BYTES over the SAME SFTP
//     session that fetched the .md (via [sftpImageFetcherProvider]); relative
//     paths resolve against the .md's directory ([resolveSftpImagePath]),
//   - explicit `http(s)://` URL → `Image.network` (the only allowed network
//     fetch),
//   - anything else / broken / missing / oversized → a graceful placeholder,
//     never a crash.
//
// Monochrome Material glyphs only (no emoji).

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/sftp_image_fetcher.dart';
import 'fill_media_viewer.dart';

/// Max height of the inline thumbnail; the full image is shown in the fill
/// viewer. Width is bounded by the available column width.
const double _inlineMaxHeight = 280;

class SftpMarkdownImage extends ConsumerStatefulWidget {
  const SftpMarkdownImage({
    super.key,
    required this.sessionId,
    required this.mdPath,
    required this.uri,
    this.alt,
  });

  /// Session whose SFTP connection fetched the .md (reused for the image).
  final String sessionId;

  /// Absolute remote path of the .md file — relative image src resolves here.
  final String mdPath;

  /// The image reference as parsed by the markdown renderer.
  final Uri uri;

  /// Alt text (used as the accessible label / placeholder caption).
  final String? alt;

  @override
  ConsumerState<SftpMarkdownImage> createState() => _SftpMarkdownImageState();
}

enum _ImgPhase { loading, ready, broken }

class _SftpMarkdownImageState extends ConsumerState<SftpMarkdownImage> {
  _ImgPhase _phase = _ImgPhase.loading;
  Uint8List? _bytes;
  bool _isNetwork = false;
  String? _networkUrl;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _resolve();
  }

  void _resolve() {
    final raw = widget.uri.toString();
    final lower = raw.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      // Explicit absolute network URL — the only allowed network fetch.
      setState(() {
        _isNetwork = true;
        _networkUrl = raw;
        _phase = _ImgPhase.ready;
      });
      return;
    }
    final path = resolveSftpImagePath(widget.mdPath, raw);
    if (path == null) {
      setState(() => _phase = _ImgPhase.broken);
      return;
    }
    _fetchSftp(path);
  }

  Future<void> _fetchSftp(String path) async {
    try {
      final fetcher = ref.read(sftpImageFetcherProvider);
      final bytes = await fetcher.fetch(widget.sessionId, path);
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _phase = _ImgPhase.ready;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _phase = _ImgPhase.broken);
    }
  }

  void _openFill() {
    final Widget full;
    if (_isNetwork && _networkUrl != null) {
      full = Image.network(
        _networkUrl!,
        errorBuilder: (_, _, _) => _fillBroken(),
      );
    } else if (_bytes != null) {
      full = Image.memory(_bytes!, errorBuilder: (_, _, _) => _fillBroken());
    } else {
      return;
    }
    showFillMediaViewer(context, child: full, label: widget.alt);
  }

  Widget _fillBroken() => const Icon(
    Icons.broken_image_outlined,
    color: Colors.white54,
    size: 64,
  );

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _ImgPhase.loading:
        return const Padding(
          key: Key('markdown-image-loading'),
          padding: EdgeInsets.symmetric(vertical: 8),
          child: SizedBox(
            height: 48,
            width: 48,
            child: Center(
              child: SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        );
      case _ImgPhase.broken:
        return _Placeholder(alt: widget.alt);
      case _ImgPhase.ready:
        return _buildInline(context);
    }
  }

  Widget _buildInline(BuildContext context) {
    final Widget image;
    if (_isNetwork && _networkUrl != null) {
      image = Image.network(
        _networkUrl!,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => _Placeholder(alt: widget.alt),
      );
    } else {
      image = Image.memory(
        _bytes!,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => _Placeholder(alt: widget.alt),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: GestureDetector(
        key: const Key('markdown-inline-image'),
        onTap: _openFill,
        child: Stack(
          alignment: Alignment.bottomRight,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: _inlineMaxHeight),
              child: image,
            ),
            // Discoverability affordance: a small monochrome "expand" badge.
            const IgnorePointer(
              child: Padding(
                padding: EdgeInsets.all(4),
                child: _ZoomBadge(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Graceful placeholder for a broken / missing / non-resolvable image. Never
/// throws — the document stays usable.
class _Placeholder extends StatelessWidget {
  const _Placeholder({this.alt});

  final String? alt;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final caption = (alt != null && alt!.trim().isNotEmpty)
        ? alt!.trim()
        : 'Image unavailable';
    return Container(
      key: const Key('markdown-image-placeholder'),
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined, size: 18, color: scheme.outline),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              caption,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _ZoomBadge extends StatelessWidget {
  const _ZoomBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: const BoxDecoration(
        color: Colors.black54,
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.zoom_out_map, size: 16, color: Colors.white),
    );
  }
}
