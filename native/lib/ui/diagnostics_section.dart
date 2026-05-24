// Diagnostics section: visible "share crash report" + manual upload button.
//
// Lives at the bottom of the Connect form. Defensive contract: every
// interaction with [CrashReporter] is wrapped in try/catch so a UI tap can
// never crash the form.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../diagnostics/crash_reporter.dart';
import 'connection_audit.dart';

class DiagnosticsSection extends StatefulWidget {
  /// Allows tests to inject a fake share function so we don't open the real
  /// platform share sheet.
  final Future<void> Function(File file)? onShare;

  const DiagnosticsSection({super.key, this.onShare});

  @override
  State<DiagnosticsSection> createState() => _DiagnosticsSectionState();
}

class _DiagnosticsSectionState extends State<DiagnosticsSection> {
  Future<_DiagnosticsSnapshot>? _future;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _future = _load();
    });
  }

  Future<_DiagnosticsSnapshot> _load() async {
    final count = await CrashReporter.pendingCrashCount();
    final latest = await CrashReporter.latestCrashFile();
    return _DiagnosticsSnapshot(pendingCount: count, latest: latest);
  }

  Future<void> _share(File file) async {
    try {
      final handler = widget.onShare;
      if (handler != null) {
        await handler(file);
        return;
      }
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/json')],
        subject: 'MobiSSH crash report',
        text: 'Crash report from MobiSSH (#501).',
      );
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Share failed: $err')),
      );
    }
  }

  Future<void> _forceUpload() async {
    UploadSummary summary;
    try {
      summary = await CrashReporter.uploadPending();
    } catch (err) {
      summary = const UploadSummary();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $err')),
        );
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(summary.toString())),
      );
    }
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_DiagnosticsSnapshot>(
      future: _future,
      builder: (context, snap) {
        final data = snap.data;
        final pending = data?.pendingCount ?? 0;
        final latest = data?.latest;
        return ExpansionTile(
          key: const ValueKey('diagnostics-section'),
          leading: const Icon(Icons.bug_report_outlined),
          title: const Text('Diagnostics'),
          subtitle: Text(
            pending == 0
                ? 'No crashes pending upload.'
                : '$pending crash report${pending == 1 ? '' : 's'} pending upload.',
          ),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (latest != null)
                    OutlinedButton.icon(
                      key: const ValueKey('share-last-crash-button'),
                      onPressed: () => _share(latest),
                      icon: const Icon(Icons.share),
                      label: const Text('Share last crash report'),
                    ),
                  if (latest == null)
                    const Text(
                      'No crash report on disk.',
                      style: TextStyle(fontStyle: FontStyle.italic),
                    ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('force-upload-button'),
                    onPressed: _forceUpload,
                    icon: const Icon(Icons.cloud_upload_outlined),
                    label: const Text('Force upload pending crashes'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('connection-audit-button'),
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const ConnectionAuditScreen(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.show_chart),
                    label: const Text('Connection Audit'),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DiagnosticsSnapshot {
  final int pendingCount;
  final File? latest;

  const _DiagnosticsSnapshot({required this.pendingCount, this.latest});
}
