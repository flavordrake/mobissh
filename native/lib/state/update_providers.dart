// Riverpod wiring for the self-update (#1216, #1258). See
// services/self_update.dart and services/post_update_notice.dart.

import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../services/post_update_notice.dart';
import '../services/self_update.dart';
import 'lifecycle_providers.dart';

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

/// R16: the last-run build and the notes saved at hand-off.
final postUpdateStoreProvider = Provider<PostUpdateStore>(
  (ref) => PostUpdateStore(),
);

final updateInstallerProvider = Provider<UpdateInstaller>(
  (ref) => UpdateInstaller(
    client: ref.watch(updateHttpClientProvider),
    platform: ref.watch(updatePlatformProvider),
    onHandoff: ref.watch(postUpdateStoreProvider).savePending,
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

/// The build the in-session snackbar was shown for: once per build per
/// process (#1258).
final updateSessionOfferShownProvider = StateProvider<int?>((ref) => null);

/// Drives one install; the banner, Settings and the session menu watch it.
class UpdateDownloadNotifier extends Notifier<UpdateProgress> {
  UpdateManifest? _manifest;
  Future<void>? _prefetching;
  bool _resuming = false;

  @override
  UpdateProgress build() {
    // R15: back from the "install unknown apps" screen → continue.
    ref.listen<AppLifecycleState>(lifecycleProvider, (_, next) {
      if (next == AppLifecycleState.resumed) unawaited(resumeAfterGrant());
    });
    return UpdateProgress.idle;
  }

  /// R14: pre-download on an unmetered network. Quiet on any failure: the
  /// Install tap then downloads as before.
  Future<void> prefetch(UpdateManifest manifest) {
    final running = _prefetching;
    if (running != null) return running;
    // Idle, or a failure of a DIFFERENT (older) build. Never over a busy,
    // handed-off, needs-permission or ready state, and never re-fetch the
    // build that just failed on every resume.
    final before = state;
    final fresh = before.stage == UpdateStage.idle ||
        (before.stage == UpdateStage.failed &&
            _manifest?.build != manifest.build);
    if (!fresh) return Future<void>.value();
    _manifest = manifest;
    final f = ref.read(updateInstallerProvider).prefetch(manifest).then((p) {
      // Only if nothing (a tap, a failure) happened meanwhile.
      if (p.stage == UpdateStage.ready && identical(state, before)) state = p;
    });
    return _prefetching = f.whenComplete(() => _prefetching = null);
  }

  Future<void> start(UpdateManifest manifest) async {
    if (state.isBusy) return;
    _manifest = manifest;
    // A pre-downloaded build is only re-hashed before the hand-off.
    state = UpdateProgress(
      stage: state.stage == UpdateStage.ready
          ? UpdateStage.verifying
          : UpdateStage.downloading,
    );
    // A pre-download in flight finishes first; install() then reuses its file.
    await _prefetching;
    await for (final p in ref.read(updateInstallerProvider).install(manifest)) {
      state = p;
    }
  }

  /// R15: on resume after [UpdateStage.needsPermission], hand the kept file
  /// off once the grant is in — exactly once. Without the grant, nothing.
  Future<void> resumeAfterGrant() async {
    final manifest = _manifest;
    if (_resuming ||
        manifest == null ||
        state.stage != UpdateStage.needsPermission) {
      return;
    }
    _resuming = true;
    try {
      if (await ref.read(updatePlatformProvider).canInstallPackages()) {
        await start(manifest);
      }
    } finally {
      _resuming = false;
    }
  }
}

final updateDownloadProvider =
    NotifierProvider<UpdateDownloadNotifier, UpdateProgress>(
      UpdateDownloadNotifier.new,
    );

/// R5/R14: watched by the app root, so the check runs on start and resume
/// even with a session in front (not only when the home banner is on screen),
/// and an offered build is pre-downloaded on an unmetered network.
final updatePrefetchProvider = Provider<void>((ref) {
  ref.listen<AsyncValue<UpdateCheckResult>>(updateCheckProvider, (_, next) {
    final result = next.valueOrNull;
    final manifest = result?.manifest;
    if (result?.kind == UpdateCheckKind.available && manifest != null) {
      unawaited(ref.read(updateDownloadProvider.notifier).prefetch(manifest));
    }
  }, fireImmediately: true);
});
