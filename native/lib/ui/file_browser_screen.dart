// SFTP file browser screen (#559) — Slice 1 foundation.
//
// Lists a remote directory, navigates into/up, and downloads a single tapped
// file to the device via a [FileDownloadSink]. Drives everything through the
// session's [SshSessionProxy] (sftpList / sftpDownload + the sftpEvents
// stream), so the heavy lifting (the SftpClient) lives task-side.
//
// Seams left open on purpose:
//   - `.pdf` tap interception (#557): see [_onFileTap]. A file ending in
//     `.pdf` routes through [pdfTapInterceptor] when one is registered; today
//     it falls through to download.
//   - Rename / folder download (Slice 2): not here yet. Add actions to the
//     AppBar + long-press menu and new proxy commands. Upload (#960) and CREATE
//     FOLDER (#1133) have landed on that pattern.

import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/clipboard.dart';
import '../services/session_messages.dart';
import '../services/sftp_download.dart';
import '../ssh/sftp_session.dart';
import '../ssh/ssh_session_proxy.dart';
import '../state/favorites_providers.dart';
import '../state/files_sort_providers.dart';
import '../state/profiles_providers.dart';
import '../state/sessions.dart';
import '../state/ui_prefs_providers.dart';
import '../storage/favorites_store.dart';
import '../util/relative_time.dart';
import 'favorites_menu_sheet.dart';
import 'file_viewer_registry.dart';
import 'pdf_viewer_screen.dart';
import 'top_toast.dart';

// `downloadSinkFactoryProvider` moved to services/sftp_download.dart (#1038):
// the browser AND every viewer's Download action resolve the same seam, so a
// single test override covers both. Re-exported here so existing importers
// (tests) keep working unchanged.
export '../services/sftp_download.dart' show downloadSinkFactoryProvider;

/// Files at or above this size (#976) prompt a confirm dialog before download —
/// large transfers are the ones that saturated the UI isolate and force-quit
/// the app. Discoverable/tunable in one place. Default 50 MB.
const int kLargeDownloadThresholdBytes = 50 * 1024 * 1024;

/// Coalesces the task's frequent download-progress events into bounded UI
/// rebuilds (#976). The old chunk path did one `setState` per chunk; the
/// streaming path can emit progress just as often, so throttle: emit at most
/// once per [minInterval] OR when progress advances by [minFraction] of the
/// total, and always the terminal 100%. Pure + deterministic (the caller passes
/// elapsed time) so it's unit-testable without a clock.
class DownloadProgressThrottle {
  DownloadProgressThrottle({
    this.minInterval = const Duration(milliseconds: 100),
    this.minFraction = 0.01,
  });

  final Duration minInterval;
  final double minFraction;

  Duration? _lastAt;
  int _lastDone = 0;

  /// Whether a progress update of [done]/[total] bytes at elapsed [now] warrants
  /// a rebuild. The first update and the terminal (done >= total) always emit.
  bool shouldEmit(int done, int total, Duration now) {
    if (total > 0 && done >= total) {
      _lastAt = now;
      _lastDone = done;
      return true;
    }
    final last = _lastAt;
    if (last == null) {
      _lastAt = now;
      _lastDone = done;
      return true;
    }
    final byTime = now - last >= minInterval;
    final byFraction =
        total > 0 && (done - _lastDone) >= (total * minFraction);
    if (byTime || byFraction) {
      _lastAt = now;
      _lastDone = done;
      return true;
    }
    return false;
  }
}

/// Picks a single LOCAL file to upload (#960). Returns its on-device path +
/// display name, or null when the user cancels. The task isolate reads the path
/// and streams it chunk-by-chunk, so we ask for the path only (withData:false) —
/// large files never load into memory. Injected via [fileUploadPickerProvider]
/// so widget tests stub the choice without the platform file-picker channel.
typedef FileUploadPicker = Future<({String path, String name})?> Function();

Future<({String path, String name})?> _defaultFileUploadPicker() async {
  final file = await openFile();
  if (file == null) return null;
  return (path: file.path, name: file.name);
}

final fileUploadPickerProvider = Provider<FileUploadPicker>(
  (ref) => _defaultFileUploadPicker,
);

/// Validate a typed new-folder name (#1133). Returns null when the (trimmed)
/// name is usable, otherwise the reason it is not — shown inline in the dialog,
/// where the user can act on it, rather than in a toast that vanishes.
///
/// Deliberately does NOT check the current listing for a name collision: the
/// SERVER is the authority on whether a create is legal, and a stale listing
/// must never block a legitimate one. "Already exists" comes back as the
/// server's own error.
String? validateNewFolderName(String raw) {
  final name = raw.trim();
  if (name.isEmpty) return 'Enter a folder name';
  if (name == '.' || name == '..') return '"$name" is not a folder name';
  if (name.contains('/')) return "A folder name can't contain '/'";
  if (name.contains('\u0000')) return "A folder name can't contain NUL";
  return null;
}

/// `.pdf` tap interceptor (#557). When non-null, tapping a PDF file invokes
/// this instead of downloading. Receives the [sessionId] so it can resolve the
/// proxy for the in-app fetch. Defaults to [_pushPdfViewer], which opens the
/// in-app viewer route; tests override it with null (fall through to download)
/// or a spy.
typedef PdfTapInterceptor =
    void Function(BuildContext context, String sessionId, SftpEntry entry);

/// Route name shared by every screen in the file-browser stack (the browser
/// itself plus every in-app viewer it pushes — text, markdown, PDF). The
/// top-right close affordance (#855) pops the WHOLE stack back to the terminal
/// in one tap via [dismissFileBrowserStack], regardless of folder depth or
/// whether a file is open. Naming every stack route the same lets a single
/// [Navigator.popUntil] collapse the stack and stop at the terminal route
/// (which is NOT named this).
const String kFileBrowserRouteName = 'mobissh.fileBrowserStack';

/// Pops the entire file-browser/viewer stack back to the terminal in one
/// action (#855). Every route pushed within the file browser is named
/// [kFileBrowserRouteName]; [Navigator.popUntil] removes all of them and stops
/// at the first route below (the terminal), so depth and open viewers don't
/// matter — it's always a single pop action.
void dismissFileBrowserStack(BuildContext context) {
  Navigator.of(
    context,
  ).popUntil((route) => route.settings.name != kFileBrowserRouteName);
}

/// Default interceptor: push the in-app PDF viewer route.
void _pushPdfViewer(BuildContext context, String sessionId, SftpEntry entry) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: kFileBrowserRouteName),
      builder: (_) => PdfViewerScreen(sessionId: sessionId, entry: entry),
    ),
  );
}

final pdfTapInterceptorProvider = Provider<PdfTapInterceptor?>(
  (ref) => _pushPdfViewer,
);

/// Push the file browser for [sessionId]. The session menu's "Files" item and
/// any future caller use this single entry point (#559 bullet 4).
///
/// [initialPath] (#778) opens the browser AT a directory other than `/` — a tap
/// on a detected absolute file path passes the path so the explorer lands there.
/// Defaults to `/` (the unchanged session-menu behaviour).
Future<void> openFileBrowser(
  BuildContext context,
  String sessionId, {
  String initialPath = '/',
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: kFileBrowserRouteName),
      builder: (_) =>
          FileBrowserScreen(sessionId: sessionId, initialPath: initialPath),
    ),
  );
}

/// Resolve a saved profile's [defaultPath] (#891) to the browser's initial
/// listing path. A non-empty path opens the browser THERE; an empty one falls
/// back to `'~'` (the SFTP home), which the SFTP layer's `_resolve()`/
/// [expandTilde] (#867) turns into the session's realpath home. `~`/relative
/// paths and absolutes pass straight through to the same resolver, and an
/// invalid path surfaces as the browser's friendly empty-state — never a crash.
String resolveBrowserInitialPath(String defaultPath) {
  final trimmed = defaultPath.trim();
  return trimmed.isEmpty ? '~' : trimmed;
}

/// Open the file browser for [sessionId] starting at its saved profile's
/// `defaultPath` (#891), falling back to the SFTP home when unset. Looks the
/// profile up by the session's `host:port:username` identity via
/// [profilesStoreProvider]; an ad-hoc (never-saved) session simply has no match
/// and opens at home. This is the entry point the session menu + terminal "Files"
/// affordances use — the absolute-tap path (#778) still calls [openFileBrowser]
/// with an explicit `initialPath` and is unaffected.
Future<void> openFileBrowserForSession(
  BuildContext context,
  WidgetRef ref,
  String sessionId,
) async {
  var defaultPath = '';
  // Find the session's identity (host:port:username) so we can match a profile.
  String? profileKey;
  for (final e in ref.read(sessionsProvider).entries) {
    if (e.id == sessionId) {
      profileKey = e.profileKey;
      break;
    }
  }
  if (profileKey != null) {
    try {
      final profiles = await ref.read(profilesStoreProvider).load();
      for (final p in profiles) {
        if (p.identityKey == profileKey) {
          defaultPath = p.defaultPath;
          break;
        }
      }
    } catch (_) {
      // Profile lookup failure degrades to home — never block opening the
      // browser on a storage hiccup.
    }
  }
  if (!context.mounted) return;
  await openFileBrowser(
    context,
    sessionId,
    initialPath: resolveBrowserInitialPath(defaultPath),
  );
}

class FileBrowserScreen extends ConsumerStatefulWidget {
  const FileBrowserScreen({
    super.key,
    required this.sessionId,
    this.initialPath = '/',
  });

  final String sessionId;
  final String initialPath;

  @override
  ConsumerState<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends ConsumerState<FileBrowserScreen> {
  SshSessionProxy? _proxy;
  StreamSubscription<SshTaskEvent>? _sub;

  String _path = '/';
  List<SftpEntry> _entries = const [];
  bool _loading = true;
  String? _error;

  /// Profile identity (`host:port:username`) this browser's session belongs to.
  /// Favorites are keyed by this (#632) — a profile's sessions share one set.
  /// Null only when the session has gone away.
  String? _profileKey;

  /// Normalized paths currently favorited for [_profileKey]. Drives the app-bar
  /// star's filled/outline state; refreshed after every favorites mutation.
  Set<String> _favoritePaths = const {};

  /// Directories visited before [_path], most recent last (#1102). The back
  /// gesture walks THIS, not the parent chain — "previous" is where you came
  /// FROM (a favorite quick-nav returns you to where you were, not to the
  /// favorite's parent). Per-browser-instance, so per-session isolation holds
  /// without any global state. Empty ⇒ back leaves the browser (the old
  /// behaviour: one route above the terminal, #740).
  final List<String> _history = [];

  /// Monotonic counter → request id, so a late listing for a directory we've
  /// already navigated away from is dropped.
  int _seq = 0;
  String? _listRequestId;

  /// In-flight download request id (null when idle). One at a time in Slice 1.
  String? _downloadRequestId;
  int _downloadReceived = 0;
  int? _downloadTotal;
  FileDownloadTarget? _downloadTarget;
  String? _downloadName;

  /// Coalesces the task's frequent progress events into bounded rebuilds (#976)
  /// so we don't `setState` per event. Non-null only during a download.
  DownloadProgressThrottle? _downloadThrottle;
  Stopwatch? _downloadStopwatch;

  /// In-flight chunked upload (#960), null when idle. One at a time. The bytes
  /// are streamed task-side; the UI only tracks progress by request id.
  String? _uploadRequestId;
  String? _uploadName;
  int _uploadSent = 0;
  int _uploadTotal = 0;

  /// In-flight mkdir request id (#1133), null when idle. One at a time — the
  /// toolbar button disables while a create is outstanding.
  String? _mkdirRequestId;
  String? _mkdirName;

  /// Path of the just-created folder (#1133). The matching row renders
  /// `selected` and is scrolled into view once the refreshed listing lands, so
  /// the result of the create is obvious in a long directory. Cleared on any
  /// navigation away.
  String? _highlightPath;
  final GlobalKey _highlightKey = GlobalKey();

  bool _attached = false;

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Attach once, after the InheritedWidget (ProviderScope) is available. This
    // runs before the first build's frame, so the initial listing request fires
    // immediately rather than waiting on a post-frame callback (which made the
    // first directory load flaky to observe).
    if (_attached) return;
    _attached = true;
    final entries = ref.read(sessionsProvider).entries;
    SshSessionProxy? proxy;
    for (final e in entries) {
      if (e.id == widget.sessionId) {
        proxy = e.proxy;
        _profileKey = e.profileKey;
        break;
      }
    }
    // Load this profile's favorites so the star renders correctly on first
    // build (#632). Fire-and-forget: setState lands when it resolves.
    unawaited(_refreshFavorites());
    if (proxy == null) {
      // No setState here — didChangeDependencies runs before build, so just
      // set the fields and let the imminent build render the error.
      _loading = false;
      _error = 'Session is no longer available';
      return;
    }
    _proxy = proxy;
    _sub = proxy.sftpEvents.listen(_onSftpEvent);
    // Send the initial listing WITHOUT setState (we're pre-build). The fields
    // are set directly; the first build reads them.
    final reqId = _nextRequestId();
    _listRequestId = reqId;
    _loading = true;
    _error = null;
    proxy.sftpList(requestId: reqId, path: _path);
  }

  @override
  void dispose() {
    _sub?.cancel();
    // Abort any partial download so we don't leak a half-written staging file.
    unawaited(_downloadTarget?.abort());
    super.dispose();
  }

  String _nextRequestId() => '${widget.sessionId}#${_seq++}';

  /// List [path]. EVERY directory change funnels through here (descend, up,
  /// favorite quick-nav, post-upload refresh), so this is where the back
  /// history (#1102) is recorded. [recordHistory] is false only for
  /// history-driven navigation — re-pushing there would loop back and forth.
  void _list(String path, {bool recordHistory = true}) {
    final proxy = _proxy;
    if (proxy == null) return;
    final reqId = _nextRequestId();
    final from = _path;
    setState(() {
      if (recordHistory && path != from) {
        // Navigating back to the directory we just came from (the up-arrow
        // after descending) CONSUMES that history entry instead of growing the
        // stack — otherwise back would bounce forward into the dir we just left.
        if (_history.isNotEmpty && _history.last == path) {
          _history.removeLast();
        } else {
          _history.add(from);
        }
      }
      if (path != from) _highlightPath = null;
      _path = path;
      _loading = true;
      _error = null;
      _listRequestId = reqId;
    });
    proxy.sftpList(requestId: reqId, path: path);
  }

  void _onSftpEvent(SshTaskEvent event) {
    if (!mounted) return;
    switch (event) {
      case SftpListingEvent():
        if (event.requestId != _listRequestId) return; // stale
        setState(() {
          _entries = event.entries;
          _loading = false;
          _error = null;
        });
        _revealHighlighted();
      case SftpDownloadProgressEvent():
        if (event.requestId != _downloadRequestId) return;
        _onDownloadProgress(event);
      case SftpDownloadDoneEvent():
        if (event.requestId != _downloadRequestId) return;
        unawaited(_onDownloadDone(event));
      case SftpUploadProgressEvent():
        if (event.requestId != _uploadRequestId) return;
        if (!mounted) return;
        setState(() {
          _uploadSent = event.sent;
          _uploadTotal = event.totalBytes;
        });
      case SftpUploadDoneEvent():
        // Our upload (matched by id); the editor writer's uploads use other ids.
        if (event.requestId != _uploadRequestId) return;
        _onUploadDone();
      case SftpMkdirDoneEvent():
        if (event.requestId != _mkdirRequestId) return;
        _onMkdirDone(event);
      case SftpErrorEvent():
        _onSftpError(event);
      default:
        break;
    }
  }

  /// #1133: the server created the folder. Refresh the listing (the server is
  /// the only source of truth for what is there now) and mark the new folder so
  /// the refreshed list selects + scrolls to it.
  void _onMkdirDone(SftpMkdirDoneEvent event) {
    final name = _mkdirName ?? 'folder';
    setState(() {
      _mkdirRequestId = null;
      _mkdirName = null;
      _highlightPath = event.path;
    });
    _snack('Created $name');
    _list(_path);
  }

  /// Scroll the highlighted row (#1133) into view once it has been built. Best
  /// effort: a row far off-screen in a `ListView.builder` has no context yet,
  /// and the selection styling still marks it when the user scrolls there.
  void _revealHighlighted() {
    if (_highlightPath == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _highlightKey.currentContext;
      if (ctx == null) return;
      unawaited(
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 200),
          alignment: 0.3,
        ),
      );
    });
  }

  void _onUploadDone() {
    final name = _uploadName ?? 'file';
    if (mounted) {
      setState(() {
        _uploadRequestId = null;
        _uploadName = null;
        _uploadSent = 0;
        _uploadTotal = 0;
      });
    }
    _snack('Uploaded $name');
    // Refresh the current listing so the freshly-uploaded file appears.
    _list(_path);
  }

  /// Progress for the task-side streaming download (#976). The bytes stayed
  /// task-side; this only advances the bar. Throttled so a fast transfer's
  /// stream of progress events doesn't `setState` per event (the UI-isolate
  /// saturation that used to force-quit the app).
  void _onDownloadProgress(SftpDownloadProgressEvent event) {
    final throttle = _downloadThrottle;
    final elapsed = _downloadStopwatch?.elapsed ?? Duration.zero;
    if (throttle != null &&
        !throttle.shouldEmit(event.done, event.totalBytes, elapsed)) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _downloadReceived = event.done;
      if (event.totalBytes > 0) _downloadTotal = event.totalBytes;
    });
  }

  Future<void> _onDownloadDone(SftpDownloadDoneEvent event) async {
    final target = _downloadTarget;
    final name = _downloadName ?? 'file';
    _downloadTarget = null;
    _downloadThrottle = null;
    _downloadStopwatch?.stop();
    _downloadStopwatch = null;
    // The task already wrote the whole file to the staging path; publish it into
    // the user-visible Downloads collection and report where it landed.
    String? location;
    if (target != null) {
      try {
        location = await target.publish();
      } catch (_) {
        location = null;
      }
    }
    if (!mounted) return;
    setState(() {
      _downloadRequestId = null;
      _downloadReceived = 0;
      _downloadTotal = null;
      _downloadName = null;
    });
    final msg = location != null
        ? 'Downloaded $name → $location'
        : 'Downloaded $name';
    _snack(msg);
  }

  /// Cancel an in-flight download (#976). Stops tracking the request (later
  /// progress/done events no longer match the request id) and deletes the
  /// partial staging file. There is no task-side mid-stream cancel command to
  /// reuse today — the task keeps streaming to the staging file, which
  /// [FileDownloadTarget.abort] removes; a task-side cancel is a follow-up.
  Future<void> _cancelDownload() async {
    final target = _downloadTarget;
    _downloadTarget = null;
    _downloadThrottle = null;
    _downloadStopwatch?.stop();
    _downloadStopwatch = null;
    if (mounted) {
      setState(() {
        _downloadRequestId = null;
        _downloadReceived = 0;
        _downloadTotal = null;
        _downloadName = null;
      });
    }
    await target?.abort();
    _snack('Download cancelled');
  }

  void _onSftpError(SftpErrorEvent event) {
    // A listing error fails the directory view; a download error aborts the
    // transfer. Match by the active request ids.
    if (event.requestId == _listRequestId) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = event.message;
      });
      return;
    }
    if (event.requestId == _downloadRequestId) {
      unawaited(_downloadTarget?.abort());
      _downloadTarget = null;
      _downloadThrottle = null;
      _downloadStopwatch?.stop();
      _downloadStopwatch = null;
      if (!mounted) return;
      setState(() {
        _downloadRequestId = null;
        _downloadReceived = 0;
        _downloadTotal = null;
        _downloadName = null;
      });
      _snack('Download failed: ${event.message}');
      return;
    }
    if (event.requestId == _uploadRequestId) {
      // The remote `.part` is left in place so a retry RESUMES (#960) rather
      // than restarting from zero.
      if (!mounted) return;
      setState(() {
        _uploadRequestId = null;
        _uploadName = null;
        _uploadSent = 0;
        _uploadTotal = 0;
      });
      _snack('Upload failed: ${event.message}');
      return;
    }
    if (event.requestId == _mkdirRequestId) {
      // The listing is left exactly as it was — nothing was created, so there
      // is nothing to refresh, and re-listing would only hide the error.
      if (!mounted) return;
      setState(() {
        _mkdirRequestId = null;
        _mkdirName = null;
      });
      _snack(event.message);
    }
  }

  /// Pick a local file and upload it INTO the current directory (#960). Streams
  /// task-side (large-file safe) to `<name>.part` then atomic-renames; a retry
  /// after an interruption resumes from the `.part`.
  Future<void> _pickAndUpload() async {
    if (_uploadRequestId != null) {
      _snack('An upload is already in progress');
      return;
    }
    final proxy = _proxy;
    if (proxy == null) return;
    final picked = await ref.read(fileUploadPickerProvider)();
    if (picked == null || !mounted) return;
    final dir = _path;
    final remotePath =
        dir.endsWith('/') ? '$dir${picked.name}' : '$dir/${picked.name}';
    final reqId = _nextRequestId();
    setState(() {
      _uploadRequestId = reqId;
      _uploadName = picked.name;
      _uploadSent = 0;
      _uploadTotal = 0;
    });
    proxy.sftpUploadFile(
      requestId: reqId,
      localPath: picked.path,
      remotePath: remotePath,
    );
  }

  /// Ask for a name, then create a folder under [parentPath] (#1133).
  /// [parentPath] is the CURRENT directory for the toolbar button and for a
  /// long-pressed file; it is the entry's own path when a DIRECTORY was
  /// long-pressed. The absolute path is joined with [joinRemotePath] (never
  /// string concat — the root would double its slash).
  Future<void> _promptNewFolder(String parentPath) async {
    if (_mkdirRequestId != null) {
      _snack('A folder is already being created');
      return;
    }
    final proxy = _proxy;
    if (proxy == null) return;
    final name = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => _NewFolderDialog(parentPath: parentPath),
    );
    if (name == null || !mounted) return;
    final reqId = _nextRequestId();
    setState(() {
      _mkdirRequestId = reqId;
      _mkdirName = name;
    });
    proxy.sftpMkdir(requestId: reqId, path: joinRemotePath(parentPath, name));
  }

  void _snack(String message) {
    if (!mounted) return;
    showTopToast(context, message);
  }

  void _onEntryTap(SftpEntry entry) {
    if (entry.isDirectory) {
      _list(entry.path);
      return;
    }
    _onFileTap(entry);
  }

  void _onFileTap(SftpEntry entry) {
    // #776: consult the file viewer registry. A registered viewer (PDF #557,
    // text/code #776, …) opens an in-app preview instead of downloading. No
    // match falls through to the existing download behavior.
    final viewer = ref.read(fileViewerRegistryProvider).viewerFor(entry);
    if (viewer != null) {
      viewer.open(context, widget.sessionId, entry);
      return;
    }
    unawaited(_startDownload(entry));
  }

  Future<void> _startDownload(SftpEntry entry) async {
    final proxy = _proxy;
    if (proxy == null) return;
    if (_downloadRequestId != null) {
      _snack('A download is already in progress');
      return;
    }
    // Size gate (#976): large transfers are the ones that used to hang the app —
    // confirm before starting.
    final size = entry.size;
    if (size != null && size >= kLargeDownloadThresholdBytes) {
      final proceed = await _confirmLargeDownload(entry.name, size);
      if (!proceed || !mounted) return;
    }
    final reqId = _nextRequestId();
    final factory = ref.read(downloadTargetFactoryProvider);
    FileDownloadTarget target;
    try {
      target = await factory(entry.name);
    } catch (e) {
      _snack('Could not start download: $e');
      return;
    }
    if (!mounted) {
      await target.abort();
      return;
    }
    _downloadThrottle = DownloadProgressThrottle();
    _downloadStopwatch = Stopwatch()..start();
    setState(() {
      _downloadRequestId = reqId;
      _downloadTarget = target;
      _downloadName = entry.name;
      _downloadReceived = 0;
      _downloadTotal = entry.size;
    });
    // Task-side streaming download (#976): the task reads the remote file and
    // writes it straight to `target.localPath` on disk, emitting only
    // lightweight progress events. The file bytes NEVER cross the isolate — the
    // fix for the large-file force-quit (contrast the old sftpDownload chunk
    // firehose).
    proxy.sftpDownloadFile(
      requestId: reqId,
      remotePath: entry.path,
      localPath: target.localPath,
    );
  }

  /// Confirm before downloading a large file (#976). Returns true to proceed.
  Future<bool> _confirmLargeDownload(String name, int size) async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        key: const Key('large-download-confirm'),
        title: const Text('Download large file?'),
        content: Text('$name is ${formatSize(size)}. Download it?'),
        actions: [
          TextButton(
            key: const Key('large-download-cancel'),
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('large-download-confirm-ok'),
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text('Download'),
          ),
        ],
      ),
    );
    return proceed ?? false;
  }

  void _goUp() {
    if (_path == '/' || _path.isEmpty) return;
    var p = _path;
    if (p.endsWith('/')) p = p.substring(0, p.length - 1);
    final idx = p.lastIndexOf('/');
    final parent = idx <= 0 ? '/' : p.substring(0, idx);
    _list(parent);
  }

  /// Back gesture (#1102): navigate to the PREVIOUSLY-VISITED directory. Only
  /// fires while [_history] is non-empty (otherwise `canPop` lets the real pop
  /// through and back leaves the browser, as before). Distinct from the
  /// up-arrow, which goes to the PARENT.
  void _backToPreviousDirectory() {
    if (_history.isEmpty) return;
    final previous = _history.removeLast();
    _list(previous, recordHistory: false);
  }

  /// #740: return to THIS session's terminal — make the browsed session active
  /// (so the terminal screen's IndexedStack shows the right one in a
  /// multi-session setup) and dismiss back to it. Browsing happens in-place
  /// (one route above the terminal), so from the browser this is a single pop;
  /// from a viewer route the stack collapses (#855). Falls back gracefully if
  /// the session has since gone away.
  void _backToTerminal() {
    final notifier = ref.read(sessionsProvider.notifier);
    final exists = ref
        .read(sessionsProvider)
        .entries
        .any((e) => e.id == widget.sessionId);
    if (exists) notifier.setActive(widget.sessionId);
    dismissFileBrowserStack(context);
  }

  // --- Favorites (#632) -----------------------------------------------------

  FavoritesStore get _favStore => ref.read(favoritesStoreProvider);

  /// Re-read the profile's favorites into [_favoritePaths] so the star + menu
  /// reflect the persisted set. No-op without a profile identity.
  Future<void> _refreshFavorites() async {
    final key = _profileKey;
    if (key == null) return;
    final favs = await _favStore.favoritesFor(key);
    if (!mounted) return;
    setState(() {
      _favoritePaths = favs.map((f) => f.path).toSet();
    });
    // shared_preferences isn't reactive: nudge the session-menu favorites star
    // (and any other watcher) so it reflects this add/remove/clear (#950).
    ref.invalidate(profileFavoritesProvider(key));
  }

  bool get _currentFavorited => _favoritePaths.contains(normalizePath(_path));

  /// Star TAP: toggle whether the CURRENT directory is favorited for this
  /// profile. Filled star = favorited; outline = not (#632 bullet 1).
  Future<void> _toggleStar() async {
    final key = _profileKey;
    if (key == null) return;
    final pathAtTap = _path;
    final nowFavorited = await _favStore.toggle(key, pathAtTap);
    await _refreshFavorites();
    if (!mounted) return;
    _snack(
      nowFavorited
          ? 'Favorited $pathAtTap'
          : 'Removed favorite $pathAtTap',
    );
  }

  /// Navigate the files view to a favorited [path] — drives the SAME `_list`
  /// sink that `widget.initialPath` feeds on open (the deepLink seam #570/#572
  /// use). The favorites menu is dismissed by the caller before this runs.
  void _navigateToFavorite(String path) => _list(path);

  /// Unified favorites menu (#632 bullets 2–5): surfaced from BOTH a long-press
  /// on the app-bar star AND a long-press on any file/folder entry. Tapping a
  /// favorite instantly navigates there; long-pressing a favorite removes it;
  /// "Clear all" empties the profile's set.
  Future<void> _openFavoritesMenu() async {
    final key = _profileKey;
    if (key == null) return;
    // #950: the menu is now the shared profile-scoped sheet. In the browser a
    // tapped favorite navigates IN PLACE; onChanged keeps the app-bar star + the
    // session-menu star provider in sync.
    await showFavoritesMenu(
      context,
      store: _favStore,
      profileKey: key,
      onNavigate: _navigateToFavorite,
      onChanged: _refreshFavorites,
    );
  }

  // --- Per-entry context menu (#952) ----------------------------------------

  /// Long-press a file/folder entry → a context menu (#952). REPLACES the old
  /// long-press→favorites-menu (#632); favoriting this specific entry is now one
  /// item here. The favorites MENU itself stays reachable via the app-bar star
  /// (and the session star). Items: copy full path, copy name, show details,
  /// download (files only), add to favorites.
  Future<void> _openEntryContextMenu(SftpEntry entry) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              key: const Key('file-entry-context-menu'),
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(
                    entry.isDirectory
                        ? Icons.folder
                        : (entry.isSymlink
                              ? Icons.link
                              : Icons.insert_drive_file_outlined),
                  ),
                  title: Text(entry.name, overflow: TextOverflow.ellipsis),
                  subtitle: Text(entry.path, overflow: TextOverflow.ellipsis),
                ),
                const Divider(height: 1),
                ListTile(
                  key: const Key('file-context-copy-path'),
                  leading: const Icon(Icons.content_copy),
                  title: const Text('Copy full path'),
                  onTap: () async {
                    Navigator.of(sheetCtx).pop();
                    final ok = await copyToClipboard(entry.path);
                    if (ok) _snack('Copied path');
                  },
                ),
                ListTile(
                  key: const Key('file-context-copy-name'),
                  leading: const Icon(Icons.drive_file_rename_outline),
                  title: const Text('Copy name'),
                  onTap: () async {
                    Navigator.of(sheetCtx).pop();
                    final ok = await copyToClipboard(entry.name);
                    if (ok) _snack('Copied name');
                  },
                ),
                ListTile(
                  key: const Key('file-context-details'),
                  leading: const Icon(Icons.info_outline),
                  title: const Text('Show details'),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    unawaited(_showEntryDetails(entry));
                  },
                ),
                ListTile(
                  key: const Key('file-context-new-folder'),
                  leading: const Icon(Icons.create_new_folder_outlined),
                  title: const Text('New folder'),
                  // Where it lands is never ambiguous: a DIRECTORY creates
                  // inside itself, a FILE creates in the directory being listed.
                  subtitle: Text(
                    entry.isDirectory ? 'Inside ${entry.path}' : 'In $_path',
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    unawaited(
                      _promptNewFolder(entry.isDirectory ? entry.path : _path),
                    );
                  },
                ),
                if (!entry.isDirectory)
                  ListTile(
                    key: const Key('file-context-download'),
                    leading: const Icon(Icons.download),
                    title: const Text('Download'),
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      unawaited(_startDownload(entry));
                    },
                  ),
                ListTile(
                  key: const Key('file-context-favorite'),
                  leading: const Icon(Icons.star_border),
                  title: const Text('Add to favorites'),
                  onTap: () async {
                    Navigator.of(sheetCtx).pop();
                    await _addEntryFavorite(entry);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Favorite this specific entry's path for the profile (#952) — the per-entry
  /// favorite that long-press used to reach via the favorites menu.
  Future<void> _addEntryFavorite(SftpEntry entry) async {
    final key = _profileKey;
    if (key == null) return;
    await _favStore.add(key, entry.path);
    await _refreshFavorites();
    if (!mounted) return;
    _snack('Favorited ${entry.path}');
  }

  /// Details sheet (#952): name, full path, size, modification time (absolute +
  /// relative), and type.
  Future<void> _showEntryDetails(SftpEntry entry) async {
    final rel = formatRelative(entry.modifyTime);
    final mtime = entry.modifyTime;
    final String modifiedText;
    if (mtime == null || mtime <= 0) {
      modifiedText = '—';
    } else {
      final abs = DateTime.fromMillisecondsSinceEpoch(mtime * 1000).toString();
      modifiedText = rel.isEmpty ? abs : '$abs ($rel)';
    }
    final sizeText = entry.size == null ? '—' : formatSize(entry.size);
    final typeText = entry.isDirectory
        ? 'Directory'
        : (entry.isSymlink ? 'Symlink' : 'File');
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              key: const Key('file-details-sheet'),
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(
                    entry.isDirectory
                        ? Icons.folder
                        : (entry.isSymlink
                              ? Icons.link
                              : Icons.insert_drive_file_outlined),
                  ),
                  title: Text(entry.name, overflow: TextOverflow.ellipsis),
                ),
                const Divider(height: 1),
                _DetailRow(label: 'Path', value: entry.path),
                _DetailRow(label: 'Size', value: sizeText),
                _DetailRow(label: 'Modified', value: modifiedText),
                _DetailRow(label: 'Type', value: typeText),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final downloading = _downloadRequestId != null;
    // #951: per-profile sort preference. Sorting is UI-side (see [sortEntries]
    // below) so changing it re-renders without an SFTP refetch. An ad-hoc
    // session with no profile identity falls back to the default (not persisted).
    final profileKey = _profileKey;
    final sortPref = profileKey != null
        ? ref.watch(filesSortProvider(profileKey))
        : filesSortDefault;
    // #740: resolve which server this browser is for so the header names it and
    // the swatch matches the session bar (#653). The browser already knows its
    // [widget.sessionId]; reuse the same label + color sources as terminal_screen.
    SessionEntry? entry;
    for (final e in ref.watch(sessionsProvider).entries) {
      if (e.id == widget.sessionId) {
        entry = e;
        break;
      }
    }
    final label = entry?.label ?? 'Files';
    final swatchColor =
        ref.watch(sessionColorProvider(widget.sessionId)) ??
        ref.watch(sessionTerminalThemeProvider(widget.sessionId)).theme.cursor;
    // #1102: back walks the directory history. `canPop` mirrors the history so
    // the platform (predictive back included) knows whether this route really
    // pops; with history left, the pop is intercepted and consumed here. The
    // explicit close affordances still collapse straight out — they go through
    // Navigator.pop/popUntil, which bypasses PopScope by design.
    return PopScope(
      canPop: _history.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _backToPreviousDirectory();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            key: const Key('file-browser-back-to-terminal'),
            tooltip: 'Back to terminal',
            icon: const Icon(Icons.terminal),
            onPressed: _backToTerminal,
          ),
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                key: const Key('file-browser-swatch'),
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: swatchColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  key: const Key('file-browser-title'),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          actions: [
            // Sort menu (#951): radio-style key (Name/Modified/Size/Type) + a
            // direction toggle. Per-profile, persisted. Disabled (no profile) for
            // an ad-hoc session. Monochrome glyph.
            PopupMenuButton<String>(
              key: const Key('file-browser-sort-button'),
              icon: const Icon(Icons.sort),
              tooltip: 'Sort',
              enabled: profileKey != null,
              onSelected: (value) {
                if (profileKey == null) return;
                final notifier = ref.read(
                  filesSortProvider(profileKey).notifier,
                );
                switch (value) {
                  case 'name':
                    notifier.setKey(FilesSortKey.name);
                  case 'modified':
                    notifier.setKey(FilesSortKey.modified);
                  case 'size':
                    notifier.setKey(FilesSortKey.size);
                  case 'type':
                    notifier.setKey(FilesSortKey.type);
                  case 'dir':
                    notifier.toggleDirection();
                }
              },
              itemBuilder: (context) => [
                CheckedPopupMenuItem<String>(
                  key: const Key('sort-key-name'),
                  value: 'name',
                  checked: sortPref.key == FilesSortKey.name,
                  child: const Text('Name'),
                ),
                CheckedPopupMenuItem<String>(
                  key: const Key('sort-key-modified'),
                  value: 'modified',
                  checked: sortPref.key == FilesSortKey.modified,
                  child: const Text('Modified'),
                ),
                CheckedPopupMenuItem<String>(
                  key: const Key('sort-key-size'),
                  value: 'size',
                  checked: sortPref.key == FilesSortKey.size,
                  child: const Text('Size'),
                ),
                CheckedPopupMenuItem<String>(
                  key: const Key('sort-key-type'),
                  value: 'type',
                  checked: sortPref.key == FilesSortKey.type,
                  child: const Text('Type'),
                ),
                const PopupMenuDivider(),
                PopupMenuItem<String>(
                  key: const Key('sort-dir-toggle'),
                  value: 'dir',
                  child: Row(
                    children: [
                      Icon(
                        sortPref.ascending
                            ? Icons.arrow_upward
                            : Icons.arrow_downward,
                      ),
                      const SizedBox(width: 8),
                      Text(sortPref.ascending ? 'Ascending' : 'Descending'),
                    ],
                  ),
                ),
              ],
            ),
            // Create a folder in the current directory (#1133). Disabled
            // while a create is in flight (one at a time). Monochrome glyph.
            IconButton(
              key: const Key('file-browser-new-folder'),
              tooltip: 'New folder',
              icon: const Icon(Icons.create_new_folder_outlined),
              onPressed: _mkdirRequestId != null
                  ? null
                  : () => unawaited(_promptNewFolder(_path)),
            ),
            // Upload a local file INTO the current directory (#960). Disabled
            // while an upload is in flight (one at a time). Monochrome glyph.
            IconButton(
              key: const Key('file-browser-upload'),
              tooltip: 'Upload a file here',
              icon: const Icon(Icons.upload_file),
              onPressed: _uploadRequestId != null ? null : _pickAndUpload,
            ),
            // Favorites star (#632): TAP toggles favoriting the current path for
            // this profile; LONG-PRESS opens the unified favorites menu. Built on
            // a single InkResponse so both gestures are owned by ONE recognizer
            // set — an IconButton's `tooltip` wraps it in a Tooltip that would eat
            // the long-press, so we don't use IconButton here. Accessibility is
            // preserved via the Semantics label.
            Semantics(
              button: true,
              label: _currentFavorited
                  ? 'Unfavorite this folder'
                  : 'Favorite this folder',
              child: InkResponse(
                key: const Key('file-browser-star'),
                radius: 24,
                onTap: _toggleStar,
                onLongPress: _openFavoritesMenu,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Icon(
                    _currentFavorited ? Icons.star : Icons.star_border,
                  ),
                ),
              ),
            ),
            IconButton(
              key: const Key('file-browser-close-to-terminal'),
              tooltip: 'Close — back to terminal',
              icon: const Icon(Icons.close),
              onPressed: _backToTerminal,
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(48),
            child: _PathBar(
              path: _path,
              canGoUp: _path != '/' && _path.isNotEmpty,
              onUp: _goUp,
            ),
          ),
        ),
        body: Column(
          children: [
            if (downloading)
              _DownloadProgress(
                key: const Key('file-browser-download-progress'),
                name: _downloadName ?? '',
                received: _downloadReceived,
                total: _downloadTotal,
                onCancel: _cancelDownload,
              ),
            if (_uploadRequestId != null)
              _UploadProgress(
                key: const Key('file-browser-upload-progress'),
                name: _uploadName ?? '',
                sent: _uploadSent,
                total: _uploadTotal,
              ),
            Expanded(child: _buildBody(sortEntries(_entries, sortPref))),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(List<SftpEntry> entries) {
    if (_loading) {
      return const Center(
        key: Key('file-browser-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (_error != null) {
      return Center(
        key: const Key('file-browser-error'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    if (entries.isEmpty) {
      return const Center(
        key: Key('file-browser-empty'),
        child: Text('Empty directory'),
      );
    }
    return ListView.builder(
      key: const Key('file-browser-list'),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final e = entries[i];
        final highlighted = e.path == _highlightPath;
        return _EntryTile(
          key: highlighted ? _highlightKey : null,
          entry: e,
          highlighted: highlighted,
          onTap: () => _onEntryTap(e),
          // Long-press a file/folder entry opens the per-entry context menu
          // (#952) — copy path/name, details, download, add to favorites. This
          // REPLACES the old long-press→favorites-menu (#632); the favorites
          // menu itself stays reachable via the app-bar star. ListTile routes
          // long-press separately from onTap, so it never also navigates.
          onLongPress: () => _openEntryContextMenu(e),
        );
      },
    );
  }
}

/// Name-entry dialog for a new folder (#1133). Validation is inline and
/// PERSISTENT (a toast the user must act on would vanish before they could):
/// the reason a name was rejected sits under the field until it is fixed. The
/// dialog pops the TRIMMED name; it never pops an invalid one, so the caller
/// can send it straight to the server.
class _NewFolderDialog extends StatefulWidget {
  const _NewFolderDialog({required this.parentPath});

  final String parentPath;

  @override
  State<_NewFolderDialog> createState() => _NewFolderDialogState();
}

class _NewFolderDialogState extends State<_NewFolderDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final raw = _controller.text;
    final problem = validateNewFolderName(raw);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.of(context).pop(raw.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('new-folder-dialog'),
      title: const Text('New folder'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'In ${widget.parentPath}',
            key: const Key('new-folder-target'),
            style: Theme.of(context).textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('new-folder-name-field'),
            controller: _controller,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(labelText: 'Folder name'),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                key: const Key('new-folder-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('new-folder-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('new-folder-create'),
          onPressed: _submit,
          child: const Text('Create'),
        ),
      ],
    );
  }
}

class _PathBar extends StatelessWidget {
  const _PathBar({
    required this.path,
    required this.canGoUp,
    required this.onUp,
  });

  final String path;
  final bool canGoUp;
  final VoidCallback onUp;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          IconButton(
            key: const Key('file-browser-up'),
            tooltip: 'Up',
            icon: const Icon(Icons.arrow_upward),
            onPressed: canGoUp ? onUp : null,
          ),
          Expanded(
            child: Text(
              path,
              key: const Key('file-browser-path'),
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    super.key,
    required this.entry,
    required this.onTap,
    this.onLongPress,
    this.highlighted = false,
  });

  final SftpEntry entry;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// The just-created folder (#1133) — rendered with the theme's selected-row
  /// treatment (no ad-hoc colors) so the result of a create is obvious.
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final icon = entry.isDirectory
        ? Icons.folder
        : (entry.isSymlink ? Icons.link : Icons.insert_drive_file_outlined);
    final subtitle = _subtitle();
    return ListTile(
      key: Key('file-entry-${entry.name}'),
      leading: Icon(icon),
      title: Text(entry.name, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: entry.isDirectory ? const Icon(Icons.chevron_right) : null,
      selected: highlighted,
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }

  /// Row subtitle (#951): files show `size · relativeTime`; directories show
  /// `relativeTime`. When the mtime is missing/invalid the time segment is
  /// dropped (files fall back to size-only, dirs to no subtitle) — never a 1969
  /// date.
  String? _subtitle() {
    final rel = formatRelative(entry.modifyTime);
    if (entry.isDirectory) {
      return rel.isEmpty ? null : rel;
    }
    final size = formatSize(entry.size);
    if (rel.isEmpty) return size;
    return '$size · $rel';
  }
}

/// One label/value row in the details sheet (#952).
class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      title: Text(label, style: Theme.of(context).textTheme.labelMedium),
      subtitle: Text(value),
    );
  }
}

/// Human-readable byte size for a file (#559). Empty string for a null size
/// (directories / when the server omits it).
String formatSize(int? bytes) {
  if (bytes == null) return '';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

class _DownloadProgress extends StatelessWidget {
  const _DownloadProgress({
    super.key,
    required this.name,
    required this.received,
    required this.total,
    required this.onCancel,
  });

  final String name;
  final int received;
  final int? total;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final t = total;
    final value = (t != null && t > 0) ? (received / t).clamp(0.0, 1.0) : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Downloading $name…',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(value: value),
              ],
            ),
          ),
          IconButton(
            key: const Key('file-browser-download-cancel'),
            tooltip: 'Cancel download',
            icon: const Icon(Icons.close),
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}

/// Determinate upload progress (#960), mirroring [_DownloadProgress]. [total] is
/// the local file size (0 before the first progress event → indeterminate bar);
/// [sent] starts at the resume offset when resuming a `.part`.
class _UploadProgress extends StatelessWidget {
  const _UploadProgress({
    super.key,
    required this.name,
    required this.sent,
    required this.total,
  });

  final String name;
  final int sent;
  final int total;

  @override
  Widget build(BuildContext context) {
    final value = total > 0 ? (sent / total).clamp(0.0, 1.0) : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Uploading $name…',
            key: const Key('file-browser-upload-label'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: value),
        ],
      ),
    );
  }
}
