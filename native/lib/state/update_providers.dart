// Riverpod wiring for the self-update (#1216). See services/self_update.dart.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../services/self_update.dart';

final updatePlatformProvider = Provider<UpdatePlatform>(
  (ref) => const ChannelUpdatePlatform(),
);

/// B of the running build (R2). Null → never offered an update.
final runningBuildProvider = Provider<int?>(
  (ref) => runningBuildFromDefine(mobisshBuildDefine),
);

final updateHttpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

final updateCheckerProvider = Provider<UpdateChecker>(
  (ref) => UpdateChecker(
    client: ref.watch(updateHttpClientProvider),
    platform: ref.watch(updatePlatformProvider),
    runningBuild: ref.watch(runningBuildProvider),
  ),
);

final updateInstallerProvider = Provider<UpdateInstaller>(
  (ref) => UpdateInstaller(
    client: ref.watch(updateHttpClientProvider),
    platform: ref.watch(updatePlatformProvider),
  ),
);

/// The latest check (R5). Invalidated on resume and by Settings → Updates.
/// Never errors: every failure is a [UpdateCheckResult] kind.
final updateCheckProvider = FutureProvider<UpdateCheckResult>(
  (ref) => ref.watch(updateCheckerProvider).check(),
);

/// `x.y.z+B` of the running build, for the banner's `Update A → B` title.
final installedVersionLabelProvider = FutureProvider<String>((ref) async {
  final build = ref.watch(runningBuildProvider);
  final info = await PackageInfo.fromPlatform();
  return build == null ? info.version : '${info.version}+$build';
});

/// The build the user said "Later" to — memory only, so a relaunch re-offers
/// and a newer build (different B) is a fresh offer (R7).
final dismissedUpdateBuildProvider = StateProvider<int?>((ref) => null);

/// Drives one install; the banner and Settings both watch it.
class UpdateDownloadNotifier extends Notifier<UpdateProgress> {
  @override
  UpdateProgress build() => UpdateProgress.idle;

  Future<void> start(UpdateManifest manifest) async {
    if (state.isBusy) return;
    state = const UpdateProgress(stage: UpdateStage.downloading);
    await for (final p in ref.read(updateInstallerProvider).install(manifest)) {
      state = p;
    }
  }
}

final updateDownloadProvider =
    NotifierProvider<UpdateDownloadNotifier, UpdateProgress>(
      UpdateDownloadNotifier.new,
    );
