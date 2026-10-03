// Self-update UI (#1216): the home-screen banner (R7) and Settings → Updates
// (R6/R7/R9). Both render [updateCheckProvider] + [updateDownloadProvider];
// neither exists on a build without the updater (R13 → `unsupported`).
// #1258: the in-session entry (session-menu row + one-time snackbar) and the
// post-update "Updated to <version>" snackbar with "What's new".

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/self_update.dart';
import '../state/update_providers.dart';
import 'settings_subheader.dart';

/// `Update <installed> → <new>` with Later / Install. Absent unless there is a
/// newer build for this device that the user has not put off (R6: an
/// unreachable host is not the user's problem to read here).
class UpdateBanner extends ConsumerStatefulWidget {
  const UpdateBanner({super.key});

  @override
  ConsumerState<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends ConsumerState<UpdateBanner> {
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    // R5: re-check on resume (the RootRouter also invalidates, for when the
    // banner is not mounted under a live terminal).
    _lifecycle = AppLifecycleListener(
      onResume: () => ref.invalidate(updateCheckProvider),
    );
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = ref.watch(updateCheckProvider).valueOrNull;
    final manifest = result?.manifest;
    if (result == null ||
        result.kind != UpdateCheckKind.available ||
        manifest == null ||
        ref.watch(dismissedUpdateBuildProvider) == manifest.build) {
      return const SizedBox.shrink();
    }
    final installed = ref.watch(installedVersionLabelProvider).valueOrNull;
    final progress = ref.watch(updateDownloadProvider);
    final ready = progress.stage == UpdateStage.ready;
    final title = installed == null
        ? 'Update ${ready ? 'ready' : 'available'}: ${manifest.version}'
        : '${ready ? 'Update ready: ' : 'Update '}'
              '$installed → ${manifest.version}';

    return MaterialBanner(
      key: const Key('update-banner'),
      leading: const Icon(Icons.system_update_outlined),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title),
          ..._progressLines(context, progress),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('update-later'),
          onPressed: progress.isBusy
              ? null
              : () => ref.read(dismissedUpdateBuildProvider.notifier).state =
                    manifest.build,
          child: const Text('Later'),
        ),
        FilledButton(
          key: const Key('update-install'),
          onPressed: progress.isBusy
              ? null
              : () => ref.read(updateDownloadProvider.notifier).start(manifest),
          child: const Text('Install'),
        ),
      ],
    );
  }
}

/// The offered manifest, or null when there is nothing to install.
UpdateManifest? _offered(WidgetRef ref) {
  final result = ref.watch(updateCheckProvider).valueOrNull;
  return result?.kind == UpdateCheckKind.available ? result!.manifest : null;
}

/// #1258: the session menu's "Install update B" row, present while an update
/// is on offer (whether or not the banner was put off with Later), so a user
/// who lives in the terminal reaches it without leaving the session.
class UpdateMenuRow extends ConsumerWidget {
  const UpdateMenuRow({super.key, required this.onClose});

  /// Closes the menu before the install starts.
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manifest = _offered(ref);
    if (manifest == null) return const SizedBox.shrink();
    final progress = ref.watch(updateDownloadProvider);
    return ListTile(
      key: const Key('session-menu-update'),
      dense: true,
      leading: const Icon(Icons.system_update_outlined),
      title: Text('Install update ${manifest.version}'),
      subtitle: progress.message == null ? null : Text(progress.message!),
      enabled: !progress.isBusy,
      onTap: () {
        onClose();
        ref.read(updateDownloadProvider.notifier).start(manifest);
      },
    );
  }
}

/// #1258: a one-time snackbar, "Update B available" with Install, when an
/// update is on offer while a session is in front. Once per build per process
/// ([updateSessionOfferShownProvider]); nothing after Later. Mounted by the
/// terminal screen; renders nothing itself.
class UpdateSessionOffer extends ConsumerStatefulWidget {
  const UpdateSessionOffer({super.key});

  @override
  ConsumerState<UpdateSessionOffer> createState() => _UpdateSessionOfferState();
}

class _UpdateSessionOfferState extends ConsumerState<UpdateSessionOffer> {
  @override
  void initState() {
    super.initState();
    ref.listenManual<AsyncValue<UpdateCheckResult>>(
      updateCheckProvider,
      (_, next) => _offer(next.valueOrNull),
      fireImmediately: true,
    );
  }

  void _offer(UpdateCheckResult? result) {
    final manifest = result?.manifest;
    if (result?.kind != UpdateCheckKind.available ||
        manifest == null ||
        ref.read(dismissedUpdateBuildProvider) == manifest.build ||
        ref.read(updateSessionOfferShownProvider) == manifest.build) {
      return;
    }
    ref.read(updateSessionOfferShownProvider.notifier).state = manifest.build;
    // Not during the listener's own build/notify phase.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          key: const Key('update-session-snackbar'),
          content: Text('Update ${manifest.version} available'),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
            label: 'Install',
            onPressed: () =>
                ref.read(updateDownloadProvider.notifier).start(manifest),
          ),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// #1258 R16: on launch, the post-update snackbar if this is the first run of
/// a newer build (decision + store in `post_update_notice.dart`).
Future<void> showPostUpdateNoticeIfAny(BuildContext context, WidgetRef ref) async {
  final notice = await ref
      .read(postUpdateStoreProvider)
      .evaluate(ref.read(runningBuildProvider));
  if (notice == null || !context.mounted) return;
  final String version =
      notice.version ?? await ref.read(installedVersionLabelProvider.future);
  if (!context.mounted) return;
  showPostUpdateSnackBar(context, version: version, notes: notice.notes);
}

/// #1258 R16: `Updated to <version>`, with "What's new" when [notes] are
/// known (saved at hand-off, so they show offline).
void showPostUpdateSnackBar(
  BuildContext context, {
  required String version,
  String notes = '',
}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      key: const Key('post-update-snackbar'),
      content: Text('Updated to $version'),
      duration: const Duration(seconds: 6),
      action: notes.trim().isEmpty
          ? null
          : SnackBarAction(
              label: "What's new",
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                showDragHandle: true,
                builder: (_) => _WhatsNewSheet(version: version, notes: notes),
              ),
            ),
    ),
  );
}

class _WhatsNewSheet extends StatelessWidget {
  const _WhatsNewSheet({required this.version, required this.notes});
  final String version;
  final String notes;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: SingleChildScrollView(
          key: const Key('whats-new-sheet'),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "What's new in $version",
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              // The top section of native-release-notes.md (markdown).
              MarkdownBody(data: notes),
            ],
          ),
        ),
      ),
    );
  }
}

/// Progress bar while busy; the stage message (handed off / needs permission /
/// failure reason) otherwise. Persistent until the next attempt (R11).
List<Widget> _progressLines(BuildContext context, UpdateProgress progress) {
  final theme = Theme.of(context);
  return [
    if (progress.isBusy)
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: LinearProgressIndicator(
          key: const Key('update-progress'),
          value: progress.stage == UpdateStage.downloading
              ? progress.fraction
              : null,
        ),
      ),
    if (!progress.isBusy && progress.message != null)
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          progress.message!,
          key: const Key('update-message'),
          style: progress.stage == UpdateStage.failed
              ? theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                )
              : theme.textTheme.bodyMedium,
        ),
      ),
  ];
}

/// Settings → Updates: Installed / Latest, Install, and why not (R6/R7/R9).
/// Tapping the Latest line checks again.
class UpdateSettingsSection extends ConsumerWidget {
  const UpdateSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final check = ref.watch(updateCheckProvider);
    final result = check.valueOrNull;
    // R13: nothing at all on a build without the updater. While the very first
    // check is loading we do not know yet, so render nothing rather than flash.
    if (result == null || result.kind == UpdateCheckKind.unsupported) {
      return const SizedBox.shrink();
    }
    final installed = ref.watch(installedVersionLabelProvider).valueOrNull;
    final progress = ref.watch(updateDownloadProvider);
    final manifest = result.manifest;
    final latestLine = switch (result.kind) {
      UpdateCheckKind.available => 'Latest: ${manifest!.version}',
      UpdateCheckKind.upToDate => 'Latest: up to date',
      UpdateCheckKind.notOffered => manifest == null
          ? 'Latest: not offered — ${result.reason}'
          : 'Latest: ${manifest.version} — not offered: ${result.reason}',
      UpdateCheckKind.unreachable => 'Latest: unreachable — ${result.reason}',
      UpdateCheckKind.unsupported => '',
    };

    return Column(
      key: const Key('update-settings-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SettingsSubheader('Updates'),
        ListTile(
          key: const Key('update-settings-tile'),
          title: Text(
            'Installed: ${installed ?? '…'}',
            key: const Key('update-installed-line'),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(latestLine, key: const Key('update-latest-line')),
              if (result.kind == UpdateCheckKind.available)
                ..._progressLines(context, progress),
            ],
          ),
          trailing: check.isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : result.kind == UpdateCheckKind.available
              ? FilledButton(
                  key: const Key('update-settings-install'),
                  onPressed: progress.isBusy
                      ? null
                      : () => ref
                            .read(updateDownloadProvider.notifier)
                            .start(manifest!),
                  child: const Text('Install'),
                )
              : null,
          onTap: check.isLoading
              ? null
              : () => ref.invalidate(updateCheckProvider),
        ),
      ],
    );
  }
}
