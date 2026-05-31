// In-app PDF viewer (#557).
//
// Opened from the SFTP file browser when a `.pdf` is tapped (via
// [pdfTapInterceptorProvider]). On mount it streams the remote PDF to a private
// TEMP file through [PdfFetcher] (which reuses the proxy's SFTP download path),
// then renders it with `pdfrx` (pdfium-backed): scrollable pages, pinch-zoom,
// page count in the AppBar, a back action. Corrupt / non-PDF files surface a
// graceful error instead of crashing. The temp file is deleted when the screen
// is disposed.
//
// Headless widget tests assert the routing + that the screen mounts and reaches
// `ready` with a fetched file; the real pdfium render + pinch-zoom is
// device-validated by the owner.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import '../services/pdf_fetcher.dart';
import '../services/session_messages.dart';

/// Builds the actual page-rendering widget for a fetched [file]. Production
/// returns a pdfium-backed [PdfViewer.file]; widget tests override this seam
/// with a lightweight placeholder so the headless harness never invokes the
/// native pdfium platform code. [onPageCount] reports the page count once the
/// document is ready; [onError] surfaces a render failure (corrupt / non-PDF).
typedef PdfRenderBuilder =
    Widget Function(
      BuildContext context,
      File file,
      PdfViewerController controller, {
      required void Function(int pageCount) onPageCount,
      required void Function(Object error) onError,
    });

Widget _defaultPdfRenderBuilder(
  BuildContext context,
  File file,
  PdfViewerController controller, {
  required void Function(int pageCount) onPageCount,
  required void Function(Object error) onError,
}) {
  return PdfViewer.file(
    file.path,
    controller: controller,
    params: PdfViewerParams(
      // pdfrx's InteractiveViewer handles pinch-zoom + scroll natively.
      maxScale: 8,
      onViewerReady: (document, controller) =>
          onPageCount(document.pages.length),
      errorBannerBuilder: (context, error, stackTrace, documentRef) {
        // Schedule out of build to avoid setState during layout.
        WidgetsBinding.instance.addPostFrameCallback((_) => onError(error));
        return const _ErrorView(message: 'Could not open this PDF');
      },
    ),
  );
}

/// Render seam. Tests override with a placeholder builder.
final pdfRenderBuilderProvider = Provider<PdfRenderBuilder>(
  (ref) => _defaultPdfRenderBuilder,
);

/// Full-screen preview route for a single remote PDF [entry] on [sessionId].
class PdfViewerScreen extends ConsumerStatefulWidget {
  const PdfViewerScreen({
    super.key,
    required this.sessionId,
    required this.entry,
  });

  final String sessionId;
  final SftpEntry entry;

  /// Best-effort temp-file cleanup. Public + static so widget tests can drive
  /// the exact deletion the framework runs on dispose — `dispose()` schedules
  /// real-IO that the fake-async test zone never executes.
  @visibleForTesting
  static Future<void> deleteTempFile(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      /* best-effort cleanup */
    }
  }

  @override
  ConsumerState<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

enum _Phase { fetching, ready, error }

class _PdfViewerScreenState extends ConsumerState<PdfViewerScreen> {
  final PdfViewerController _controller = PdfViewerController();

  _Phase _phase = _Phase.fetching;
  String? _errorMessage;
  File? _file;
  int _received = 0;
  int? _total;
  int? _pageCount;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_fetch());
  }

  Future<void> _fetch() async {
    final fetcher = ref.read(pdfFetcherProvider);
    try {
      final file = await fetcher.fetch(
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
      if (!mounted) {
        unawaited(PdfViewerScreen.deleteTempFile(file));
        return;
      }
      setState(() {
        _file = file;
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
  void dispose() {
    final f = _file;
    if (f != null) unawaited(PdfViewerScreen.deleteTempFile(f));
    super.dispose();
  }

  void _onRenderError(Object error) {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.error;
      _errorMessage = 'Could not open this PDF';
    });
  }

  @override
  Widget build(BuildContext context) {
    final pages = _pageCount;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.entry.name, overflow: TextOverflow.ellipsis),
        actions: [
          if (_phase == _Phase.ready && pages != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: Text(
                  key: const Key('pdf-viewer-page-count'),
                  '$pages ${pages == 1 ? 'page' : 'pages'}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
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
        final builder = ref.read(pdfRenderBuilderProvider);
        return KeyedSubtree(
          key: const Key('pdf-viewer-ready'),
          child: builder(
            context,
            _file!,
            _controller,
            onPageCount: (count) {
              if (!mounted) return;
              setState(() => _pageCount = count);
            },
            onError: _onRenderError,
          ),
        );
    }
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
      key: const Key('pdf-viewer-loading'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 160, child: LinearProgressIndicator(value: value)),
          const SizedBox(height: 16),
          Text('Loading PDF…', style: Theme.of(context).textTheme.bodyMedium),
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
      key: const Key('pdf-viewer-error'),
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
                  : 'Could not open this PDF',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
