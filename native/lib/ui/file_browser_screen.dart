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
//   - Upload / mkdir / rename / folder download (Slice 2): not here yet. Add
//     actions to the AppBar + long-press menu and new proxy commands.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/session_messages.dart';
import '../services/sftp_download.dart';
import '../ssh/ssh_session_proxy.dart';
import '../state/favorites_providers.dart';
import '../state/profiles_providers.dart';
import '../state/sessions.dart';
import '../state/ui_prefs_providers.dart';
import '../storage/favorites_store.dart';
import 'file_viewer_registry.dart';
import 'pdf_viewer_screen.dart';
import 'top_toast.dart';

/// Resolves the destination sink for downloads. Overridden in widget tests to
/// avoid touching the real filesystem; production uses the app Downloads dir.
final downloadSinkFactoryProvider = Provider<DownloadSinkFactory>(
  (ref) => defaultDownloadSinkFactory,
);

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

  /// Monotonic counter → request id, so a late listing for a directory we've
  /// already navigated away from is dropped.
  int _seq = 0;
  String? _listRequestId;

  /// In-flight download request id (null when idle). One at a time in Slice 1.
  String? _downloadRequestId;
  int _downloadReceived = 0;
  int? _downloadTotal;
  FileDownloadSink? _downloadSink;
  String? _downloadName;

  /// Serializes sink writes so a `done` event flushes only after every chunk
  /// write has completed. Chunks can arrive reordered over the gateway (#591);
  /// the sink writes each at its byte offset so order doesn't affect the bytes,
  /// but chaining keeps `finish` strictly after the last write.
  Future<void> _downloadWrites = Future<void>.value();

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
    // Abort any partial download so we don't leak a half-written file.
    unawaited(_downloadSink?.abort());
    super.dispose();
  }

  String _nextRequestId() => '${widget.sessionId}#${_seq++}';

  void _list(String path) {
    final proxy = _proxy;
    if (proxy == null) return;
    final reqId = _nextRequestId();
    setState(() {
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
      case SftpDownloadChunkEvent():
        if (event.requestId != _downloadRequestId) return;
        _onChunk(event);
      case SftpDownloadDoneEvent():
        if (event.requestId != _downloadRequestId) return;
        unawaited(_onDownloadDone(event));
      case SftpErrorEvent():
        _onSftpError(event);
      default:
        break;
    }
  }

  void _onChunk(SftpDownloadChunkEvent event) {
    final sink = _downloadSink;
    if (sink == null) return;
    final bytes = event.bytes;
    final offset = event.offset;
    // Write at the chunk's byte offset (#591). Chain writes so `done` only
    // flushes after they all complete.
    _downloadWrites = _downloadWrites.then((_) => sink.addChunk(bytes, offset));
    if (!mounted) return;
    setState(() {
      _downloadReceived += bytes.length;
      _downloadTotal = event.totalBytes;
    });
  }

  Future<void> _onDownloadDone(SftpDownloadDoneEvent event) async {
    final sink = _downloadSink;
    final name = _downloadName ?? 'file';
    _downloadSink = null;
    String? location;
    var failed = false;
    if (sink != null) {
      try {
        await _downloadWrites; // drain all chunk writes first
        location = await sink.finish(expectedTotal: event.totalBytes);
      } catch (e) {
        // Length mismatch / write failure → the file is corrupt. Clean up and
        // report failure rather than claiming a successful download (#591).
        failed = true;
        await sink.abort();
        location = null;
      }
    }
    _downloadWrites = Future<void>.value();
    if (!mounted) return;
    setState(() {
      _downloadRequestId = null;
      _downloadReceived = 0;
      _downloadTotal = null;
      _downloadName = null;
    });
    if (failed) {
      _snack('Download failed: $name was incomplete');
      return;
    }
    final msg = location != null
        ? 'Downloaded $name → $location'
        : 'Downloaded $name';
    _snack(msg);
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
      unawaited(_downloadSink?.abort());
      _downloadSink = null;
      if (!mounted) return;
      setState(() {
        _downloadRequestId = null;
        _downloadReceived = 0;
        _downloadTotal = null;
        _downloadName = null;
      });
      _snack('Download failed: ${event.message}');
    }
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
    final reqId = _nextRequestId();
    final factory = ref.read(downloadSinkFactoryProvider);
    FileDownloadSink sink;
    try {
      sink = await factory(entry.name);
    } catch (e) {
      _snack('Could not start download: $e');
      return;
    }
    if (!mounted) {
      await sink.abort();
      return;
    }
    setState(() {
      _downloadRequestId = reqId;
      _downloadSink = sink;
      _downloadName = entry.name;
      _downloadReceived = 0;
      _downloadTotal = entry.size;
    });
    proxy.sftpDownload(requestId: reqId, path: entry.path);
  }

  void _goUp() {
    if (_path == '/' || _path.isEmpty) return;
    var p = _path;
    if (p.endsWith('/')) p = p.substring(0, p.length - 1);
    final idx = p.lastIndexOf('/');
    final parent = idx <= 0 ? '/' : p.substring(0, idx);
    _list(parent);
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
    var favs = await _favStore.favoritesFor(key);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.star),
                    title: const Text('Favorites'),
                    trailing: TextButton(
                      key: const Key('favorites-clear-all'),
                      onPressed: favs.isEmpty
                          ? null
                          : () async {
                              await _favStore.clear(key);
                              await _refreshFavorites();
                              favs = const [];
                              setSheetState(() {});
                            },
                      child: const Text('Clear all'),
                    ),
                  ),
                  const Divider(height: 1),
                  if (favs.isEmpty)
                    const Padding(
                      key: Key('favorites-empty'),
                      padding: EdgeInsets.all(24),
                      child: Text('No favorites yet'),
                    )
                  else
                    Flexible(
                      child: ListView(
                        key: const Key('favorites-list'),
                        shrinkWrap: true,
                        children: [
                          for (final f in favs)
                            ListTile(
                              key: Key('favorite-item-${f.path}'),
                              leading: const Icon(Icons.folder_outlined),
                              title: Text(
                                f.display,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: (f.label != null && f.label!.isNotEmpty)
                                  ? Text(f.path, overflow: TextOverflow.ellipsis)
                                  : null,
                              onTap: () {
                                Navigator.of(sheetContext).pop();
                                _navigateToFavorite(f.path);
                              },
                              // Long-press a favorite = REMOVE it (#632 bullet 4).
                              onLongPress: () async {
                                await _favStore.remove(key, f.path);
                                await _refreshFavorites();
                                favs = await _favStore.favoritesFor(key);
                                setSheetState(() {});
                              },
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final downloading = _downloadRequestId != null;
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
    return Scaffold(
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
            ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
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
    if (_entries.isEmpty) {
      return const Center(
        key: Key('file-browser-empty'),
        child: Text('Empty directory'),
      );
    }
    return ListView.builder(
      key: const Key('file-browser-list'),
      itemCount: _entries.length,
      itemBuilder: (context, i) {
        final e = _entries[i];
        return _EntryTile(
          entry: e,
          onTap: () => _onEntryTap(e),
          // Long-press a file/folder entry opens the SAME unified favorites
          // menu as long-pressing the star (#632 bullet 3). ListTile routes
          // long-press separately from onTap, so it never also navigates.
          onLongPress: _openFavoritesMenu,
        );
      },
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
    required this.entry,
    required this.onTap,
    this.onLongPress,
  });

  final SftpEntry entry;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final icon = entry.isDirectory
        ? Icons.folder
        : (entry.isSymlink ? Icons.link : Icons.insert_drive_file_outlined);
    return ListTile(
      key: Key('file-entry-${entry.name}'),
      leading: Icon(icon),
      title: Text(entry.name, overflow: TextOverflow.ellipsis),
      subtitle: entry.isDirectory ? null : Text(_formatSize(entry.size)),
      trailing: entry.isDirectory ? const Icon(Icons.chevron_right) : null,
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }

  static String _formatSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

class _DownloadProgress extends StatelessWidget {
  const _DownloadProgress({
    super.key,
    required this.name,
    required this.received,
    required this.total,
  });

  final String name;
  final int received;
  final int? total;

  @override
  Widget build(BuildContext context) {
    final t = total;
    final value = (t != null && t > 0) ? (received / t).clamp(0.0, 1.0) : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
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
    );
  }
}
