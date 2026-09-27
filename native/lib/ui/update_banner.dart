// Self-update UI (#1216): the home-screen banner (R7) and Settings → Updates
// (R6/R7/R9). Both render [updateCheckProvider] + [updateDownloadProvider];
// neither exists on a build without the updater (R13 → `unsupported`).

import 'package:flutter/material.dart';
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
    final title = installed == null
        ? 'Update available: ${manifest.version}'
        : 'Update $installed → ${manifest.version}';

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
