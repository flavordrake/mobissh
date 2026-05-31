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
import '../state/sessions.dart';

/// Resolves the destination sink for downloads. Overridden in widget tests to
/// avoid touching the real filesystem; production uses the app Downloads dir.
final downloadSinkFactoryProvider = Provider<DownloadSinkFactory>(
  (ref) => defaultDownloadSinkFactory,
);

/// Optional `.pdf` tap interceptor (#557 seam). When non-null, tapping a
/// `.pdf` file invokes this instead of downloading. The PDF viewer feature
/// overrides this provider to push its preview route.
typedef PdfTapInterceptor = void Function(BuildContext context, SftpEntry entry);

final pdfTapInterceptorProvider = Provider<PdfTapInterceptor?>((ref) => null);

/// Push the file browser for [sessionId]. The session menu's "Files" item and
/// any future caller use this single entry point (#559 bullet 4).
Future<void> openFileBrowser(BuildContext context, String sessionId) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => FileBrowserScreen(sessionId: sessionId),
    ),
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
        break;
      }
    }
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
        unawaited(_onChunk(event));
      case SftpDownloadDoneEvent():
        if (event.requestId != _downloadRequestId) return;
        unawaited(_onDownloadDone(event));
      case SftpErrorEvent():
        _onSftpError(event);
      default:
        break;
    }
  }

  Future<void> _onChunk(SftpDownloadChunkEvent event) async {
    final sink = _downloadSink;
    if (sink == null) return;
    await sink.addChunk(event.bytes);
    if (!mounted) return;
    setState(() {
      _downloadReceived += event.bytes.length;
      _downloadTotal = event.totalBytes;
    });
  }

  Future<void> _onDownloadDone(SftpDownloadDoneEvent event) async {
    final sink = _downloadSink;
    final name = _downloadName ?? 'file';
    _downloadSink = null;
    String? location;
    if (sink != null) {
      try {
        location = await sink.finish();
      } catch (e) {
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _onEntryTap(SftpEntry entry) {
    if (entry.isDirectory) {
      _list(entry.path);
      return;
    }
    _onFileTap(entry);
  }

  void _onFileTap(SftpEntry entry) {
    // #557 seam: a registered PDF interceptor handles `.pdf` files (e.g. opens
    // an in-app preview) instead of downloading. Falls through otherwise.
    final pdfHandler = ref.read(pdfTapInterceptorProvider);
    if (pdfHandler != null && entry.name.toLowerCase().endsWith('.pdf')) {
      pdfHandler(context, entry);
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

  @override
  Widget build(BuildContext context) {
    final downloading = _downloadRequestId != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Files'),
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
        );
      },
    );
  }
}

class _PathBar extends StatelessWidget {
  const _PathBar({required this.path, required this.canGoUp, required this.onUp});

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
  const _EntryTile({required this.entry, required this.onTap});

  final SftpEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final icon = entry.isDirectory
        ? Icons.folder
        : (entry.isSymlink ? Icons.link : Icons.insert_drive_file_outlined);
    return ListTile(
      key: Key('file-entry-${entry.name}'),
      leading: Icon(icon),
      title: Text(entry.name, overflow: TextOverflow.ellipsis),
      subtitle: entry.isDirectory
          ? null
          : Text(_formatSize(entry.size)),
      trailing: entry.isDirectory ? const Icon(Icons.chevron_right) : null,
      onTap: onTap,
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
          Text('Downloading $name…',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: value),
        ],
      ),
    );
  }
}
