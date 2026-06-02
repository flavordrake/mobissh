// In-app feedback capture (#661).
//
// A slim, always-available affordance pinned to the TOP-CENTER of the app,
// floating over ANY screen (chooser / terminal / files) via an OverlayEntry
// mounted in the app shell ([FeedbackOverlay.wrap], used by main.dart). ONE tap:
//
//   tap → capture a screenshot of the current screen → show a comment sheet
//   (multi-line, NO maxLength) → Submit → brief "sent" confirmation.
//
// The note is submitted to the SAME pipeline the web form (public/native-
// feedback.js) uses: POST <prod>/api/bug-report. The server (#661) persists the
// FULL comment into the bug-report.json the orchestrator's watcher reads, so the
// owner's note is never truncated to a first-line title again.
//
// Why an OverlayEntry rather than a per-screen widget: the affordance must be
// app-wide and must survive route pushes (the file browser / pdf viewer push
// new routes over the terminal). An overlay entry mounted once at the app shell
// floats above every route.

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// Prod endpoint that ingests bug reports (same one the web form posts to).
/// The orchestrator's watcher polls the files this endpoint writes.
const String feedbackEndpoint =
    'https://mobissh.tailbe5094.ts.net/api/bug-report';

/// Formats the baked build identifiers into the `[<build> <hash>]` shape the
/// existing reports use (see public/native-feedback.js `data-version`). The
/// hash comes from `PackageInfo.buildSignature` (the git hash baked at build
/// time). Either part may be empty; the result degrades gracefully.
String formatFeedbackVersion(String appVersion, String buildSha) {
  final v = appVersion.trim();
  final h = buildSha.trim();
  if (v.isEmpty && h.isEmpty) return '[unknown]';
  if (h.isEmpty) return '[$v]';
  if (v.isEmpty) return '[$h]';
  return '[$v $h]';
}

/// Builds the POST body for `/api/bug-report`.
///
/// Contract (#661):
///   - `comment` carries the FULL multi-line note — UNTRUNCATED. This is the
///     field the server (#661) persists into the bug-report.json verbatim.
///   - `title` is a one-line summary (first non-empty line, prefixed with the
///     build version) purely for display in the watcher / uploads listing. It
///     is NOT the source of truth for the note any more.
///   - `logs` mirrors the full note so the existing `.log` sidecar still gets
///     the complete text and the endpoint stays back-compatible with readers
///     that only look at `logs`.
///   - `version` is the `[<build> <hash>]` stamp.
///   - `screenshot` is a base64 data URL (`data:image/png;base64,...`) or null.
///
/// Pure / synchronous so it can be unit-tested without any platform channels.
Map<String, Object?> buildFeedbackPayload({
  required String comment,
  required String version,
  String? screenshotDataUrl,
}) {
  final fullComment = comment;
  // First non-empty line → title summary. Never truncate the comment itself.
  String firstLine = '';
  for (final line in fullComment.split('\n')) {
    final t = line.trim();
    if (t.isNotEmpty) {
      firstLine = t;
      break;
    }
  }
  final title = firstLine.isEmpty
      ? 'In-app feedback $version'
      : '$version $firstLine';

  return <String, Object?>{
    'title': title,
    // FULL comment — the server stores this untruncated (#661).
    'comment': fullComment,
    // Mirror into logs for the .log sidecar + back-compat readers.
    'logs': fullComment,
    'version': version,
    'source': 'native-in-app',
    if (screenshotDataUrl != null && screenshotDataUrl.isNotEmpty)
      'screenshot': screenshotDataUrl,
  };
}

/// Encodes raw PNG [bytes] as a `data:image/png;base64,...` URL. Returns null
/// for empty input so the payload omits the screenshot field cleanly.
String? pngBytesToDataUrl(Uint8List bytes) {
  if (bytes.isEmpty) return null;
  return 'data:image/png;base64,${base64Encode(bytes)}';
}

/// Submits a feedback payload to the bug-report pipeline. Abstracted so the
/// widget tests can inject a fake that records the payload without a network.
abstract class FeedbackSubmitter {
  Future<bool> submit(Map<String, Object?> payload);
}

/// Production submitter: POSTs JSON to [feedbackEndpoint] via the existing
/// `http` dependency.
class HttpFeedbackSubmitter implements FeedbackSubmitter {
  const HttpFeedbackSubmitter({this.endpoint = feedbackEndpoint, this.client});

  final String endpoint;
  final http.Client? client;

  @override
  Future<bool> submit(Map<String, Object?> payload) async {
    final c = client ?? http.Client();
    try {
      final res = await c.post(
        Uri.parse(endpoint),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (err) {
      debugPrint('[feedback] submit failed: $err');
      return false;
    } finally {
      if (client == null) c.close();
    }
  }
}

/// Resolves the baked build version, formatted as `[<build> <hash>]`.
typedef VersionResolver = Future<String> Function();

/// Rasterizes the current screen to PNG bytes. Injected so widget tests can
/// bypass `RenderRepaintBoundary.toImage` (which does not complete under the
/// default test binding). [boundaryKey] is the key on the root RepaintBoundary.
typedef ScreenshotCapturer = Future<Uint8List> Function(
  GlobalKey boundaryKey,
  double pixelRatio,
);

/// Production screenshot capture: rasterizes the root RepaintBoundary. Returns
/// empty bytes on any failure (capture is best-effort — feedback must still
/// submit the comment even if rasterization fails).
Future<Uint8List> _defaultScreenshotCapturer(
  GlobalKey boundaryKey,
  double pixelRatio,
) async {
  try {
    final obj = boundaryKey.currentContext?.findRenderObject();
    if (obj is! RenderRepaintBoundary) return Uint8List(0);
    final image = await obj.toImage(pixelRatio: pixelRatio);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return byteData?.buffer.asUint8List() ?? Uint8List(0);
  } catch (err) {
    debugPrint('[feedback] capture failed: $err');
    return Uint8List(0);
  }
}

Future<String> _defaultVersionResolver() async {
  try {
    final pkg = await PackageInfo.fromPlatform();
    final appVersion = '${pkg.version}+${pkg.buildNumber}';
    final sha = pkg.buildSignature;
    return formatFeedbackVersion(appVersion, sha);
  } catch (err) {
    debugPrint('[feedback] version resolve failed: $err');
    return '[unknown]';
  }
}

/// Mounts the app-wide feedback affordance above [child]. Use this to wrap the
/// `home` of the [MaterialApp] (via `MaterialApp.builder`).
///
/// The whole subtree is wrapped in a [RepaintBoundary] keyed by
/// [feedbackCaptureKey] so the affordance can rasterize the CURRENT screen on
/// demand. The affordance hides itself for one frame during capture so it does
/// NOT appear in its own screenshot.
class FeedbackOverlay extends StatefulWidget {
  const FeedbackOverlay({
    super.key,
    required this.child,
    this.submitter = const HttpFeedbackSubmitter(),
    this.versionResolver = _defaultVersionResolver,
    this.screenshotCapturer = _defaultScreenshotCapturer,
  });

  final Widget child;
  final FeedbackSubmitter submitter;
  final VersionResolver versionResolver;
  final ScreenshotCapturer screenshotCapturer;

  @override
  State<FeedbackOverlay> createState() => _FeedbackOverlayState();
}

class _FeedbackOverlayState extends State<FeedbackOverlay> {
  final GlobalKey _captureKey = GlobalKey();

  /// Hides the affordance for the frame in which we rasterize, so the button
  /// never shows up inside its own screenshot.
  bool _captureInProgress = false;

  Future<void> _onTap() async {
    // Hide the affordance, let the next frame paint (so the button is gone),
    // then rasterize the screen WITHOUT the affordance in it.
    setState(() => _captureInProgress = true);
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    final bytes = await widget.screenshotCapturer(_captureKey, dpr);
    if (mounted) setState(() => _captureInProgress = false);
    if (!mounted) return;

    final dataUrl = pngBytesToDataUrl(bytes);
    final version = await widget.versionResolver();
    if (!mounted) return;

    await _showCommentSheet(dataUrl: dataUrl, version: version);
  }

  Future<void> _showCommentSheet({
    required String? dataUrl,
    required String version,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);

    // The sheet returns the typed comment on Submit (null if dismissed).
    final comment = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => _FeedbackCommentSheet(version: version),
    );
    if (comment == null) return; // dismissed without submitting

    final payload = buildFeedbackPayload(
      comment: comment,
      version: version,
      screenshotDataUrl: dataUrl,
    );
    final ok = await widget.submitter.submit(payload);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          ok ? 'Feedback sent — thanks!' : 'Send failed — try again.',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        RepaintBoundary(key: _captureKey, child: widget.child),
        // Top-center affordance. Hidden during capture so it never appears in
        // its own screenshot. Low-opacity + small to stay unobtrusive.
        if (!_captureInProgress)
          Positioned(
            top: MediaQuery.of(context).padding.top + 4,
            left: 0,
            right: 0,
            child: Center(
              child: Opacity(
                opacity: 0.5,
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    key: const Key('feedback-affordance'),
                    onTap: _onTap,
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(Icons.feedback_outlined, size: 14),
                          SizedBox(width: 4),
                          Text('Feedback', style: TextStyle(fontSize: 11)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The comment-capture sheet. Owns its [TextEditingController] and disposes it
/// in [State.dispose] — so it can never be used-after-dispose during the sheet's
/// own dismissal animation. Returns the typed comment to the caller via
/// `Navigator.pop` on Submit.
class _FeedbackCommentSheet extends StatefulWidget {
  const _FeedbackCommentSheet({required this.version});

  final String version;

  @override
  State<_FeedbackCommentSheet> createState() => _FeedbackCommentSheetState();
}

class _FeedbackCommentSheetState extends State<_FeedbackCommentSheet> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Feedback', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(widget.version, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          TextField(
            key: const Key('feedback-comment-field'),
            controller: _controller,
            autofocus: true,
            // Multi-line, NO maxLength — the full note must be captured
            // (#661 kills the web form's first-line truncation).
            maxLines: 6,
            minLines: 3,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(
              hintText: 'What happened? (full note — nothing is truncated)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('feedback-submit-button'),
            onPressed: () => Navigator.of(context).pop(_controller.text),
            child: const Text('Submit'),
          ),
        ],
      ),
    );
  }
}
