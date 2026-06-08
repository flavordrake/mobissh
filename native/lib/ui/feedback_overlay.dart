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

import 'package:mobissh/diagnostics/connect_trace.dart';
import 'package:mobissh/diagnostics/feedback_bundle.dart' show scrubSecrets;
import 'package:mobissh/diagnostics/gesture_trace.dart';
import 'package:mobissh/diagnostics/session_byte_recorder.dart';
import 'package:mobissh/ui/top_toast.dart';

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
  List<String> frameDataUrls = const <String>[],
  List<String> connectLog = const <String>[],
  List<String> gestureLog = const <String>[],
  List<String> lifecycleLog = const <String>[],
  List<Map<String, Object?>> byteTrace = const <Map<String, Object?>>[],
  List<Map<String, Object?>> scrollTrace = const <Map<String, Object?>>[],
  Map<String, Object?>? grid,
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

  // The connect-trace ring (#539 connect path + #659 CTRACE659 `ui.fit659`
  // fill diagnostics). Attaching it is the whole point of the telemetry fix:
  // a device repro of the first-connect fill bug now carries the measured
  // render-box size / computed cols×rows / cellSize, so it can be fixed from
  // DATA instead of bouncing builds off the owner's phone. The server (#553)
  // persists this as `connectLogFile` + `connectLogEventCount`.
  //
  // Scrubbed of any credential-looking material (rules/security.md / #553
  // contract) — defense-in-depth even though ctrace logs lengths only.
  final scrubbedLog = connectLog.map(scrubSecrets).toList(growable: false);

  // #699: the gesture-trace ring (touch->cell mapping diagnostics for the
  // Ghostty selection-offset bug). The server persists it as `gestureLogFile` +
  // `gestureLogEventCount`, mirroring connectLog. Scrubbed of any credential-
  // looking material (rules/security.md / #553 contract) — defense in depth,
  // though gesture events carry only coords/sizes/SGR bytes.
  final scrubbedGestureLog = gestureLog
      .map(scrubSecrets)
      .toList(growable: false);

  // #759: dedicated lifecycle-event ring (resume-liveness probe outcomes,
  // reconnect decisions) — the durable record that survives the connect-ring
  // churn so a wake-frozen report carries the probe outcome. Scrubbed like the
  // others (defense in depth; lifecycle lines carry no credentials).
  final scrubbedLifecycleLog = lifecycleLog
      .map(scrubSecrets)
      .toList(growable: false);

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
    // #repro: a burst of frames recorded over ~10s so the owner can show a
    // MOVING repro (tmux/layout/wrap/scroll). The server saves each as a
    // numbered PNG; the orchestrator assembles them into a video with ffmpeg.
    if (frameDataUrls.isNotEmpty) 'frames': frameDataUrls,
    if (scrubbedLog.isNotEmpty) 'connectLog': scrubbedLog,
    if (scrubbedGestureLog.isNotEmpty) 'gestureLog': scrubbedGestureLog,
    if (scrubbedLifecycleLog.isNotEmpty) 'lifecycleLog': scrubbedLifecycleLog,
    // #790: the replay-harness trace. byteTrace = raw bytes that reached the
    // Terminal ({tMs,b64}); scrollTrace = scroll-offset events ({tMs,offset});
    // grid = the active session's viewport {cols,rows}. The server (#790)
    // persists these as `${ts}-bug-report.byte-trace.json` so the captured trace
    // can be replayed (#791) to reproduce a scrollback-render bug. The byte
    // stream is ALREADY scrubbed by SessionByteRecorder.snapshotByteTrace() at
    // snapshot time (rules/security.md). Omitted entirely when no session is
    // active (no empty-array / null noise).
    if (byteTrace.isNotEmpty) 'byteTrace': byteTrace,
    if (scrollTrace.isNotEmpty) 'scrollTrace': scrollTrace,
    'grid': ?grid,
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
typedef ScreenshotCapturer =
    Future<Uint8List> Function(GlobalKey boundaryKey, double pixelRatio);

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
    required this.navigatorKey,
    required this.messengerKey,
    this.submitter = const HttpFeedbackSubmitter(),
    this.versionResolver = _defaultVersionResolver,
    this.screenshotCapturer = _defaultScreenshotCapturer,
  });

  final Widget child;

  /// Key on the host [MaterialApp]'s Navigator. The overlay is mounted ABOVE
  /// the Navigator (via `MaterialApp.builder`), so its OWN `context` has no
  /// Navigator ancestor — calling `showModalBottomSheet` from it throws, the
  /// async error is swallowed, and the tap only "blinks" (the affordance
  /// hides then shows, no sheet). We show the sheet from the Navigator's
  /// OVERLAY context (a descendant of the Navigator) instead, which
  /// `Navigator.of` resolves correctly.
  final GlobalKey<NavigatorState> navigatorKey;

  /// Key on the host [MaterialApp]'s ScaffoldMessenger — used for the "sent"
  /// confirmation SnackBar. The overlay's own context can't resolve a
  /// messenger either (same above-the-Navigator reason).
  final GlobalKey<ScaffoldMessengerState> messengerKey;

  final FeedbackSubmitter submitter;
  final VersionResolver versionResolver;
  final ScreenshotCapturer screenshotCapturer;

  @override
  State<FeedbackOverlay> createState() => _FeedbackOverlayState();
}

class _FeedbackOverlayState extends State<FeedbackOverlay> {
  final GlobalKey _captureKey = GlobalKey();

  // #repro: long-press the Feedback pill to RECORD a ~10s burst of screenshots
  // (default). The owner performs the repro during the window; each frame is the
  // SAME RepaintBoundary the single-shot uses, so it captures the terminal
  // (flterm renders in-tree). The server saves the frames as a numbered PNG
  // sequence; the orchestrator assembles them into a video with ffmpeg. This is
  // the "show me a moving repro" tool — a static shot can't convey tmux/wrap/
  // scroll dynamics, and the device config differs from the emulator.
  static const Duration kReproDuration = Duration(seconds: 10);
  static const Duration kReproInterval = Duration(milliseconds: 200);
  static const int kReproMaxFrames = 50;
  // Capture frames at a REDUCED, DPR-independent resolution so ~50 PNGs stay a
  // manageable upload — a repro needs motion, not pixel fidelity.
  static const double kReproPixelRatio = 0.6;

  bool _recording = false;
  int _reproRemainingSecs = 0;

  /// Records a burst of frames over [kReproDuration] (or until stopped / capped),
  /// then opens the comment sheet with the frames attached. Tap (or long-press)
  /// while recording stops early.
  Future<void> _recordRepro() async {
    if (_recording) {
      setState(() => _recording = false); // long-press while recording → stop
      return;
    }
    // Trace rings snapshotted at the START — they keep accumulating during the
    // window, so the report carries what happened across the whole repro.
    final connectLog = connectLogSnapshot();
    final gestureLog = gestureLogSnapshot();
    final lifecycleLog = lifecycleLogSnapshot();
    // #790: the byte/scroll recorder is BACKWARD-looking, so snapshot it at the
    // END (just before the sheet) where the trace covers the bug the owner just
    // reproduced. Captured below after the frame burst.

    setState(() {
      _recording = true;
      _reproRemainingSecs = kReproDuration.inSeconds;
    });

    final frames = <Uint8List>[];
    final maxTicks =
        (kReproDuration.inMilliseconds / kReproInterval.inMilliseconds).ceil();
    final ticksPerSec =
        (1000 / kReproInterval.inMilliseconds).round().clamp(1, 1000);
    for (var i = 0; i < maxTicks && frames.length < kReproMaxFrames; i++) {
      if (!_recording || !mounted) break;
      final bytes =
          await widget.screenshotCapturer(_captureKey, kReproPixelRatio);
      if (!mounted) break;
      if (bytes.isNotEmpty) frames.add(bytes);
      if (i % ticksPerSec == 0) {
        final remaining = kReproDuration.inSeconds - (i ~/ ticksPerSec);
        setState(() => _reproRemainingSecs = remaining < 0 ? 0 : remaining);
      }
      await Future<void>.delayed(kReproInterval);
    }

    if (mounted) setState(() => _recording = false);
    if (!mounted) return;

    final frameUrls = <String>[];
    for (final f in frames) {
      final url = pngBytesToDataUrl(f);
      if (url != null) frameUrls.add(url);
    }
    if (frameUrls.isEmpty) return; // nothing captured — abort quietly

    final version = await widget.versionResolver();
    if (!mounted) return;
    await _showCommentSheet(
      dataUrl: frameUrls.last, // last frame doubles as the static screenshot
      frameDataUrls: frameUrls,
      version: version,
      connectLog: connectLog,
      gestureLog: gestureLog,
      lifecycleLog: lifecycleLog,
      // #790: backward-looking — snapshot NOW so the trace covers the bug just
      // reproduced during the burst.
      byteTrace: activeByteTraceSnapshot(),
      scrollTrace: activeScrollTraceSnapshot(),
      grid: activeGridSnapshot(),
    );
  }

  Future<void> _onTap() async {
    if (_recording) {
      setState(() => _recording = false); // tap while recording → stop
      return;
    }
    // Snapshot the connect-trace ring + rasterize the screen at the EXACT
    // moment of tap. We deliberately DON'T hide the affordance and pump a frame
    // first: that rebuild + extra frames can let a pending layout settle (e.g.
    // the #666 first-connect re-fit, or the keyboard inset) and capture the
    // screen AFTER the bug self-corrects — hiding the very thing being reported.
    // The owner saw exactly this: interacting with the feedback control changed
    // the layout before the shot. Capturing immediately is truer; the small
    // affordance pill appearing in its own screenshot is an acceptable trade.
    final connectLog = connectLogSnapshot();
    final gestureLog = gestureLogSnapshot();
    final lifecycleLog = lifecycleLogSnapshot();
    // #790: snapshot the byte/scroll recorder at the EXACT moment of tap — it's
    // backward-looking, so the rings hold the input + scroll that produced the
    // current (buggy) frame the owner is reporting.
    final byteTrace = activeByteTraceSnapshot();
    final scrollTrace = activeScrollTraceSnapshot();
    final grid = activeGridSnapshot();
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    final bytes = await widget.screenshotCapturer(_captureKey, dpr);
    if (!mounted) return;

    final dataUrl = pngBytesToDataUrl(bytes);
    final version = await widget.versionResolver();
    if (!mounted) return;

    await _showCommentSheet(
      dataUrl: dataUrl,
      version: version,
      connectLog: connectLog,
      gestureLog: gestureLog,
      lifecycleLog: lifecycleLog,
      byteTrace: byteTrace,
      scrollTrace: scrollTrace,
      grid: grid,
    );
  }

  Future<void> _showCommentSheet({
    required String? dataUrl,
    required String version,
    required List<String> connectLog,
    required List<String> gestureLog,
    required List<String> lifecycleLog,
    List<String> frameDataUrls = const <String>[],
    List<Map<String, Object?>> byteTrace = const <Map<String, Object?>>[],
    List<Map<String, Object?>> scrollTrace = const <Map<String, Object?>>[],
    Map<String, Object?>? grid,
  }) async {
    // Show the sheet from the Navigator's OVERLAY context — NOT this overlay's
    // own context, which sits above the Navigator (mounted via
    // MaterialApp.builder) and has no Navigator ancestor. Using the own
    // context here is the "just blinks" bug: showModalBottomSheet throws and
    // no sheet ever appears.
    final sheetContext = widget.navigatorKey.currentState?.overlay?.context;
    if (sheetContext == null) return;

    // The sheet returns the typed comment on Submit (null if dismissed).
    final comment = await showModalBottomSheet<String>(
      context: sheetContext,
      isScrollControlled: true,
      builder: (sheetCtx) => _FeedbackCommentSheet(version: version),
    );
    if (comment == null) return; // dismissed without submitting

    final payload = buildFeedbackPayload(
      comment: comment,
      version: version,
      screenshotDataUrl: dataUrl,
      frameDataUrls: frameDataUrls,
      connectLog: connectLog,
      gestureLog: gestureLog,
      lifecycleLog: lifecycleLog,
      byteTrace: byteTrace,
      scrollTrace: scrollTrace,
      grid: grid,
    );
    final ok = await widget.submitter.submit(payload);
    // Confirmation as a TOP toast (#667) so it doesn't occlude the bottom
    // controls. This overlay sits ABOVE the Navigator (MaterialApp.builder, the
    // #664 fix) and has no ScaffoldMessenger / ambient Overlay in its own
    // context, so we hand showTopToast the navigator's OverlayState directly.
    final overlay = widget.navigatorKey.currentState?.overlay;
    if (overlay != null) {
      showTopToastInOverlay(
        overlay,
        ok ? 'Feedback sent — thanks!' : 'Send failed — try again.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        RepaintBoundary(key: _captureKey, child: widget.child),
        // Top-center affordance. Low-opacity + small to stay unobtrusive. It is
        // captured AS-IS in its own screenshot (we no longer hide it for a
        // frame — that delay let the screen re-layout before capture, #666).
        Positioned(
          top: MediaQuery.of(context).padding.top + 4,
          left: 0,
          right: 0,
          child: Center(
            child: Opacity(
              opacity: _recording ? 0.95 : 0.5,
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  key: const Key('feedback-affordance'),
                  onTap: _onTap,
                  // #repro: long-press to record a ~10s burst; tap stops it early.
                  onLongPress: _recording ? null : _recordRepro,
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: _recording
                          ? Colors.red.shade600
                          : Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: _recording
                        ? Row(
                            key: const Key('feedback-recording'),
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.fiber_manual_record,
                                size: 14,
                                color: Colors.white,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'REC ${_reproRemainingSecs}s · tap to stop',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          )
                        : Row(
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
